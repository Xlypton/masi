import 'dart:async';
import 'dart:convert';

import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/core/db/storage_durability_provider.dart';
import 'package:masi/core/storage/storage_persistence_providers.dart';
import 'package:masi/core/storage/storage_persistence_types.dart';
import 'package:masi/features/account/application/auth_providers.dart';
import 'package:masi/features/account/application/pwa_install_providers.dart';
import 'package:masi/features/account/application/pwa_install_types.dart';
import 'package:masi/features/account/data/auth_repository.dart';
import 'package:masi/features/account/presentation/account_screen.dart';
import 'package:masi/features/backup/application/sync_orchestrator.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/library/data/library_crud_repository.dart';
import 'package:masi/features/library/presentation/topos_screen.dart';
import 'package:masi/shared/presentation/masi_async_view.dart';
import 'package:masi/shared/presentation/masi_loading_indicator.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException, SystemChannels;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;
import '../../../support/async_drain.dart';

/// A [SyncOrchestrator] whose `build()` short-circuits to a fixed
/// [SyncOrchestratorState] — never watches `appDatabaseProvider`/subscribes
/// to `tableUpdates()`/listens to `authStateProvider`, so tests can drive
/// `AccountScreen`'s `sync-status` line against an arbitrary status without
/// wiring up a database or real (or even fake) [SyncService] at all.
class _FixedSyncOrchestrator extends SyncOrchestrator {
  _FixedSyncOrchestrator(this._state);

  final SyncOrchestratorState _state;

  @override
  SyncOrchestratorState build() => _state;
}

/// A [StorageDurabilityNotifier] whose `build()` short-circuits to a fixed
/// [StorageDurability] verdict — the #54 B5 diagnostics-row tests below drive
/// every verdict shape (a clean backend, a measured-but-stalled
/// `unavailableOver`, missing features) without ever running the real
/// connection layer.
class _FixedStorageDurabilityNotifier extends StorageDurabilityNotifier {
  _FixedStorageDurabilityNotifier(this._fixed);

  final StorageDurability _fixed;

  @override
  StorageDurability build() => _fixed;
}

/// A [StoragePersistenceController] whose `build()` short-circuits to a fixed
/// [StoragePersistenceStatus] and which RECORDS every [refresh]/
/// [requestPersistenceOnce] call instead of touching
/// `storagePersistenceServiceProvider` — lets the #54 B5 diagnostics-row
/// tests assert the Refresh action calls exactly the right method (see
/// assertion 6: `refresh()`, never `requestPersistenceOnce()`).
class _RecordingStoragePersistenceController
    extends StoragePersistenceController {
  _RecordingStoragePersistenceController(this._fixed);

  final StoragePersistenceStatus _fixed;

  int refreshCalls = 0;
  int requestPersistenceOnceCalls = 0;

  @override
  StoragePersistenceStatus build() => _fixed;

  @override
  Future<void> refresh() async {
    refreshCalls++;
  }

  @override
  Future<void> requestPersistenceOnce() async {
    requestPersistenceOnceCalls++;
  }
}

/// In-memory [AuthRepository] test double: no [SupabaseClient], no network.
///
/// [authStateChanges] is backed by a single-subscription
/// [StreamController], which — unlike a broadcast controller — buffers any
/// event added before a listener attaches and delivers it on the first
/// `listen()`. That lets the constructor seed [initial] synchronously (via
/// `_controller.add`) and still have it reliably reach `authStateProvider`'s
/// listener, which only subscribes once `ref.watch` first runs. The same
/// controller keeps delivering every subsequent [emit] to that same listener
/// for the rest of the test — a single-subscription controller supports any
/// number of `add()` calls, before or after `listen()`, as long as it is
/// only ever listened to once (which `authStateProvider` — a `StreamProvider`
/// that subscribes exactly once and stays subscribed — guarantees here).
class FakeAuthRepository implements AuthRepository {
  /// [seedImmediately] `false` withholds the initial emission, leaving
  /// `authStateProvider` in its first-load state indefinitely — the only way
  /// to observe `AccountScreen`'s loading placeholder, since a seeded
  /// controller resolves it on the first pump. Call [emit] to release it.
  FakeAuthRepository(AuthSessionState initial, {bool seedImmediately = true})
    : _current = initial {
    if (seedImmediately) _controller.add(initial);
  }

  final _controller = StreamController<AuthSessionState>();

  /// Backs [currentSession] with whatever was last passed to the
  /// constructor or [emit] — a synchronous test double for Supabase's own
  /// synchronous `auth.currentSession` getter.
  AuthSessionState _current;

  @override
  AuthSessionState get currentSession => _current;

  /// Every email passed to [sendMagicLink], in call order.
  final List<String> sendMagicLinkCalls = [];

  /// Number of times [signOut] has been called.
  int signOutCalls = 0;

  /// Number of times [signInWithGoogle] has been called.
  int googleSignInCalls = 0;

  /// When non-null, the next call(s) to [sendMagicLink] throw this instead
  /// of succeeding — lets a test simulate a failed/rate-limited send (e.g.
  /// the MAJOR-1 stale-"link sent"-plus-error regression test below).
  Object? sendMagicLinkError;

  /// When non-null, the next call(s) to [signInWithGoogle] throw this
  /// instead of succeeding — lets a test simulate a failed OAuth start.
  Object? googleSignInError;

  /// Number of times [verifyEmailOtp] has been called.
  int verifyEmailOtpCalls = 0;

  /// Every (email, code) pair passed to [verifyEmailOtp], in call order.
  final List<(String, String)> verifyEmailOtpArgs = [];

  /// When non-null, the next call(s) to [verifyEmailOtp] throw this instead
  /// of succeeding — lets a test simulate a wrong/expired code.
  Object? verifyEmailOtpError;

  @override
  Stream<AuthSessionState> authStateChanges() => _controller.stream;

  @override
  Future<void> sendMagicLink(String email) async {
    sendMagicLinkCalls.add(email);
    final error = sendMagicLinkError;
    if (error != null) {
      throw error;
    }
  }

  /// When non-null, [signOut] blocks on it — lets a test hold the screen in
  /// its "signing out" state long enough to assert on the pending cue.
  Completer<void>? signOutGate;

  @override
  Future<void> signOut() async {
    signOutCalls++;
    final gate = signOutGate;
    if (gate != null) await gate.future;
  }

  /// Holds `signInWithGoogle` open so its pending cue can be inspected.
  Completer<void>? googleSignInGate;

  @override
  Future<void> signInWithGoogle() async {
    googleSignInCalls++;
    if (googleSignInError != null) throw googleSignInError!;
    final gate = googleSignInGate;
    if (gate != null) await gate.future;
  }

  @override
  Future<void> verifyEmailOtp(String email, String code) async {
    verifyEmailOtpCalls++;
    verifyEmailOtpArgs.add((email, code));
    if (verifyEmailOtpError != null) throw verifyEmailOtpError!;
  }

  /// Emits a new [AuthSessionState] on the live [authStateChanges] stream,
  /// simulating e.g. Supabase's `onAuthStateChange` reporting a session
  /// change some time after the constructor-seeded initial state — see the
  /// "S2-b (flip)" test below, which is the only way to prove the screen
  /// actually rebuilds on a live signed-out -> signed-in transition rather
  /// than just rendering whatever state it happened to be constructed with.
  void emit(AuthSessionState state) {
    _current = state;
    _controller.add(state);
  }

  /// Pushes an error onto [authStateChanges], driving `authStateProvider` into
  /// a value-less `AsyncError` — the shape `main()`'s
  /// Supabase.initialize-failed fallback produces.
  void failStream(Object error) => _controller.addError(error);

  Future<void> dispose() => _controller.close();
}

/// Wraps [child] in a [ProviderScope] bound to [container] plus a
/// [MaterialApp] carrying the real [MasiTheme] — required because
/// `AccountScreen` reads `MasiColors.of(context)`, which throws if no
/// `MasiColors` extension is registered on the ambient theme (mirrors
/// `topos_screen_test.dart`'s `_wrap`).
Widget _wrap(ProviderContainer container, Widget child) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(theme: MasiTheme.light, home: child),
  );
}

/// Pumps real time forward under `tester.runAsync` before pumping the
/// widget tree, then settles — needed for the #18 display-name tests below,
/// which (unlike every other test in this file) watch a real
/// `myDisplayNameProvider` StreamProvider backed by a real in-memory Drift
/// database. That's genuine `dart:ffi` I/O, which — per this project's own
/// "never drive real I/O under fake-async" rule (see `CLAUDE.md`) — needs
/// real time to actually resolve rather than hanging under `flutter_test`'s
/// default fake clock. Mirrors `community_screen_test.dart`'s/
/// `topos_screen_test.dart`'s identically-named helper.
Future<void> _drain(WidgetTester tester) async {
  await drainAsync(tester, rounds: 6, settle: false);
  await tester.pumpAndSettle();
}

/// Taps "Continue with Google" under [theme], holds the sign-in open, and
/// returns the colour its pending cue is actually painted in.
///
/// The button wears `MasiPendingButton.filled` over a `surface2` fill, which is
/// exactly the combination the old hardcoded `onAccent` spinner made invisible
/// (white on #FBFAFE in light, #1A1226 on #251F34 in dark).
Future<Color?> _googleCueColor(WidgetTester tester, ThemeData theme) async {
  final fakeRepo = FakeAuthRepository(const AuthSessionState.signedOut());
  addTearDown(fakeRepo.dispose);
  final gate = Completer<void>();
  fakeRepo.googleSignInGate = gate;
  final container = ProviderContainer(
    overrides: [authRepositoryProvider.overrideWithValue(fakeRepo)],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: theme, home: const AccountScreen()),
    ),
  );
  await tester.pumpAndSettle();

  // `.filled`, i.e. an ElevatedButton: the M3 elevation the `.text` workaround
  // gave up to get a visible spinner.
  expect(
    find.descendant(
      of: find.byKey(const Key('account-google-signin')),
      matching: find.byType(ElevatedButton),
    ),
    findsOneWidget,
  );

  await tester.tap(find.byKey(const Key('account-google-signin')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
  final arc = tester.widget<CircularProgressIndicator>(
    find.descendant(
      of: find.byKey(MasiLoadingIndicator.spinnerKey),
      matching: find.byType(CircularProgressIndicator),
    ),
  );
  gate.complete();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  return arc.color;
}

void main() {
  group('S2-a: signed-out magic-link flow', () {
    testWidgets(
      'renders the email field + send-link button; entering an email and '
      'tapping send calls sendMagicLink with that email and shows the sent '
      'confirmation',
      (tester) async {
        final fakeRepo = FakeAuthRepository(
          const AuthSessionState.signedOut(),
        );
        addTearDown(fakeRepo.dispose);
        final container = ProviderContainer(
          overrides: [authRepositoryProvider.overrideWithValue(fakeRepo)],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(_wrap(container, const AccountScreen()));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('account-email-field')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('account-send-link')), findsOneWidget);
        expect(find.byKey(const Key('account-link-sent')), findsNothing);
        // Must not render the signed-in body at the same time.
        expect(find.byKey(const Key('account-email-label')), findsNothing);
        expect(find.byKey(const Key('account-sign-out')), findsNothing);

        await tester.enterText(
          find.byKey(const Key('account-email-field')),
          'climber@example.com',
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('account-send-link')));
        await tester.pumpAndSettle();

        expect(fakeRepo.sendMagicLinkCalls, ['climber@example.com']);
        expect(find.byKey(const Key('account-link-sent')), findsOneWidget);
      },
    );

    testWidgets(
      'an empty email is a no-op: sendMagicLink is never called and no '
      'confirmation is shown',
      (tester) async {
        final fakeRepo = FakeAuthRepository(
          const AuthSessionState.signedOut(),
        );
        addTearDown(fakeRepo.dispose);
        final container = ProviderContainer(
          overrides: [authRepositoryProvider.overrideWithValue(fakeRepo)],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(_wrap(container, const AccountScreen()));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('account-send-link')));
        await tester.pumpAndSettle();

        expect(fakeRepo.sendMagicLinkCalls, isEmpty);
        expect(find.byKey(const Key('account-link-sent')), findsNothing);
      },
    );

    testWidgets(
      'an invalid email format ("notanemail") is rejected client-side: '
      'sendMagicLink is never called and a validation message is shown',
      (tester) async {
        final fakeRepo = FakeAuthRepository(
          const AuthSessionState.signedOut(),
        );
        addTearDown(fakeRepo.dispose);
        final container = ProviderContainer(
          overrides: [authRepositoryProvider.overrideWithValue(fakeRepo)],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(_wrap(container, const AccountScreen()));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('account-email-field')),
          'notanemail',
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('account-send-link')));
        await tester.pumpAndSettle();

        expect(fakeRepo.sendMagicLinkCalls, isEmpty);
        expect(find.text('Enter a valid email address.'), findsOneWidget);
        expect(find.byKey(const Key('account-link-sent')), findsNothing);
      },
    );

    testWidgets(
      'a failed send after a previous successful send clears the stale '
      '"link sent" confirmation, so it never renders at the same time as '
      'the new error (regression for MAJOR-1: stale confirmation + error '
      'rendered simultaneously)',
      (tester) async {
        final fakeRepo = FakeAuthRepository(
          const AuthSessionState.signedOut(),
        );
        addTearDown(fakeRepo.dispose);
        final container = ProviderContainer(
          overrides: [authRepositoryProvider.overrideWithValue(fakeRepo)],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(_wrap(container, const AccountScreen()));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('account-email-field')),
          'climber@example.com',
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('account-send-link')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('account-link-sent')), findsOneWidget);

        // Simulate a second send (e.g. a double-tap hitting Supabase's OTP
        // rate-limit) that fails.
        fakeRepo.sendMagicLinkError = Exception('rate limited');
        await tester.tap(find.byKey(const Key('account-send-link')));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('account-link-sent')),
          findsNothing,
          reason:
              'the stale confirmation from the earlier successful send '
              'must be cleared once a new send attempt fails',
        );
        expect(find.textContaining('Could not send the link'), findsOneWidget);
      },
    );
  });

  group('#google sign-in', () {
    testWidgets('its pending cue is painted in the LIGHT ink, not in the '
        'invisible onAccent white', (tester) async {
      expect(
        await _googleCueColor(tester, MasiTheme.light),
        MasiColors.light.ink,
      );
    });

    testWidgets('its pending cue is painted in the DARK ink, not in the '
        'invisible near-black onAccent', (tester) async {
      expect(
        await _googleCueColor(tester, MasiTheme.dark),
        MasiColors.dark.ink,
      );
    });

    testWidgets(
      'the Continue with Google button is shown when signed out',
      (tester) async {
        final fakeRepo = FakeAuthRepository(
          const AuthSessionState.signedOut(),
        );
        addTearDown(fakeRepo.dispose);
        final container = ProviderContainer(
          overrides: [authRepositoryProvider.overrideWithValue(fakeRepo)],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(_wrap(container, const AccountScreen()));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('account-google-signin')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'tapping Continue with Google calls signInWithGoogle once',
      (tester) async {
        final fakeRepo = FakeAuthRepository(
          const AuthSessionState.signedOut(),
        );
        addTearDown(fakeRepo.dispose);
        final container = ProviderContainer(
          overrides: [authRepositoryProvider.overrideWithValue(fakeRepo)],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(_wrap(container, const AccountScreen()));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('account-google-signin')));
        // pump (not pumpAndSettle) to avoid any animation hang.
        await tester.pump();

        expect(fakeRepo.googleSignInCalls, 1);
      },
    );

    testWidgets(
      'a failing Google sign-in shows an error and does not throw',
      (tester) async {
        final fakeRepo = FakeAuthRepository(
          const AuthSessionState.signedOut(),
        );
        addTearDown(fakeRepo.dispose);
        fakeRepo.googleSignInError = Exception('boom');
        final container = ProviderContainer(
          overrides: [authRepositoryProvider.overrideWithValue(fakeRepo)],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(_wrap(container, const AccountScreen()));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('account-google-signin')));
        // pump (not pumpAndSettle) to avoid any animation hang.
        await tester.pump();

        // The failure is caught, not rethrown, and the screen stays on the
        // signed-out body offering the sign-in form again.
        expect(fakeRepo.googleSignInCalls, 1);
        expect(
          find.text('Google sign-in failed. Please try again.'),
          findsOneWidget,
        );
        expect(find.byKey(const Key('account-email-field')), findsOneWidget);
      },
    );
  });

  group('S2-b: signed-in state', () {
    testWidgets(
      'a signed-in session flips the screen to the signed-in body: shows '
      "the user's email and a working Sign out button",
      (tester) async {
        final fakeRepo = FakeAuthRepository(
          const AuthSessionState.signedIn('climber@example.com'),
        );
        addTearDown(fakeRepo.dispose);
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [
            authRepositoryProvider.overrideWithValue(fakeRepo),
            appDatabaseProvider.overrideWithValue(db),
            // A real `appDatabaseProvider` override means the REAL
            // `SyncOrchestrator` would otherwise see this test's own
            // writes via its `db.tableUpdates()` subscription and
            // schedule a real 2s debounced push `Timer` that outlives the
            // test (flutter_test's "Timer still pending" failure) — swap
            // in the fixed, listener-free fake used by the `E1d`/`#18`
            // groups; this test only cares about the signed-in body/sign
            // out button, not sync.
            syncOrchestratorProvider.overrideWith(
              () => _FixedSyncOrchestrator(const SyncOrchestratorState()),
            ),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(_wrap(container, const AccountScreen()));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('account-email-label')),
          findsOneWidget,
        );
        expect(find.text('climber@example.com'), findsOneWidget);
        expect(find.byKey(const Key('account-sign-out')), findsOneWidget);
        // Must not render the signed-out body at the same time.
        expect(find.byKey(const Key('account-email-field')), findsNothing);
        expect(find.byKey(const Key('account-send-link')), findsNothing);

        await tester.tap(find.byKey(const Key('account-sign-out')));
        await tester.pumpAndSettle();

        expect(fakeRepo.signOutCalls, 1);
      },
    );

    testWidgets(
      'shows an initials avatar derived from the signed-in email (mirrors '
      "the Topos-home account entry's email_initials.dart usage)",
      (tester) async {
        final fakeRepo = FakeAuthRepository(
          const AuthSessionState.signedIn('climber@example.com'),
        );
        addTearDown(fakeRepo.dispose);
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [
            authRepositoryProvider.overrideWithValue(fakeRepo),
            appDatabaseProvider.overrideWithValue(db),
            // A real `appDatabaseProvider` override means the REAL
            // `SyncOrchestrator` would otherwise see this test's own
            // writes via its `db.tableUpdates()` subscription and
            // schedule a real 2s debounced push `Timer` that outlives the
            // test (flutter_test's "Timer still pending" failure) — swap
            // in the fixed, listener-free fake used by the `E1d`/`#18`
            // groups; this test only cares about the avatar initials, not
            // sync.
            syncOrchestratorProvider.overrideWith(
              () => _FixedSyncOrchestrator(const SyncOrchestratorState()),
            ),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(_wrap(container, const AccountScreen()));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('account-avatar')), findsOneWidget);
        // 'climber@example.com' -> single local-part segment 'climber' ->
        // first two chars, uppercased (see email_initials.dart).
        expect(find.text('CL'), findsOneWidget);
      },
    );

    testWidgets(
      'S2-b (flip): a signed-out screen rebuilds to signed-in when the '
      'auth stream emits a session while mounted',
      (tester) async {
        final fakeRepo = FakeAuthRepository(
          const AuthSessionState.signedOut(),
        );
        addTearDown(fakeRepo.dispose);
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [
            authRepositoryProvider.overrideWithValue(fakeRepo),
            appDatabaseProvider.overrideWithValue(db),
            // The stream flip below lands this screen on the signed-in
            // body, so a real `appDatabaseProvider` would otherwise let
            // the REAL `SyncOrchestrator` see this test's writes via its
            // `db.tableUpdates()` subscription and schedule a real 2s
            // debounced push `Timer` that outlives the test (flutter_test's
            // "Timer still pending" failure) — swap in the fixed,
            // listener-free fake used by the `E1d`/`#18` groups; this test
            // only cares about the live signed-out->signed-in rebuild, not
            // sync.
            syncOrchestratorProvider.overrideWith(
              () => _FixedSyncOrchestrator(const SyncOrchestratorState()),
            ),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(_wrap(container, const AccountScreen()));
        await tester.pumpAndSettle();

        // Starts signed-out.
        expect(find.byKey(const Key('account-email-field')), findsOneWidget);
        expect(find.byKey(const Key('account-send-link')), findsOneWidget);
        expect(find.byKey(const Key('account-email-label')), findsNothing);
        expect(find.byKey(const Key('account-sign-out')), findsNothing);

        // A later stream event (e.g. the user tapped the magic link in
        // another app/tab and Supabase's onAuthStateChange reports the new
        // session) must flip the already-mounted screen live, not require a
        // fresh pumpWidget/rebuild from scratch.
        fakeRepo.emit(const AuthSessionState.signedIn('climber@example.com'));
        await tester.pump();
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('account-email-label')), findsOneWidget);
        expect(find.text('climber@example.com'), findsOneWidget);
        expect(find.byKey(const Key('account-sign-out')), findsOneWidget);
        // The signed-out body must be gone, not layered underneath.
        expect(find.byKey(const Key('account-email-field')), findsNothing);
        expect(find.byKey(const Key('account-send-link')), findsNothing);
      },
    );
  });

  group('#20: keyboard dismissal', () {
    testWidgets(
      'sending a magic link drops focus/keyboard from the email field '
      '(regression: keyboard stuck after tapping Send)',
      (tester) async {
        final fakeRepo = FakeAuthRepository(
          const AuthSessionState.signedOut(),
        );
        addTearDown(fakeRepo.dispose);
        final container = ProviderContainer(
          overrides: [authRepositoryProvider.overrideWithValue(fakeRepo)],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(_wrap(container, const AccountScreen()));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('account-email-field')),
          'climber@example.com',
        );
        await tester.pump();
        expect(
          tester.testTextInput.hasAnyClients,
          isTrue,
          reason: 'entering text must have focused the field',
        );

        await tester.tap(find.byKey(const Key('account-send-link')));
        await tester.pumpAndSettle();

        expect(fakeRepo.sendMagicLinkCalls, ['climber@example.com']);
        expect(
          tester.testTextInput.hasAnyClients,
          isFalse,
          reason: 'sending the link must dismiss the keyboard',
        );
      },
    );

    testWidgets(
      'a signed-out -> signed-in transition while the email field is '
      'focused drops focus/keyboard (regression: keyboard stuck after '
      'login, from the focused field being torn out of the tree)',
      (tester) async {
        final fakeRepo = FakeAuthRepository(
          const AuthSessionState.signedOut(),
        );
        addTearDown(fakeRepo.dispose);
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [
            authRepositoryProvider.overrideWithValue(fakeRepo),
            appDatabaseProvider.overrideWithValue(db),
            // The stream flip below lands this screen on the signed-in
            // body, so a real `appDatabaseProvider` would otherwise let
            // the REAL `SyncOrchestrator` see this test's writes via its
            // `db.tableUpdates()` subscription and schedule a real 2s
            // debounced push `Timer` that outlives the test (flutter_test's
            // "Timer still pending" failure) — swap in the fixed,
            // listener-free fake used by the `E1d`/`#18` groups; this test
            // only cares about focus/keyboard dismissal, not sync.
            syncOrchestratorProvider.overrideWith(
              () => _FixedSyncOrchestrator(const SyncOrchestratorState()),
            ),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(_wrap(container, const AccountScreen()));
        await tester.pumpAndSettle();

        // Focus the email field without submitting (mirrors the user
        // typing, then getting signed in via a magic link tapped in
        // another tab, without ever pressing Send here).
        await tester.tap(find.byKey(const Key('account-email-field')));
        await tester.pump();
        expect(tester.testTextInput.hasAnyClients, isTrue);

        fakeRepo.emit(const AuthSessionState.signedIn('climber@example.com'));
        await tester.pump();
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('account-email-label')), findsOneWidget);
        expect(
          tester.testTextInput.hasAnyClients,
          isFalse,
          reason:
              'the sign-in transition must release focus/dismiss the '
              'keyboard even though the focused field was torn out of '
              'the tree',
        );
      },
    );
  });

  group('nav: Topos home -> Account', () {
    testWidgets(
      'tapping topos-account-button on the Topos home navigates to '
      '/account (closes the gap where the Account screen existed but '
      "nothing verified the home's entry point actually reaches it)",
      (tester) async {
        final fakeRepo = FakeAuthRepository(
          const AuthSessionState.signedOut(),
        );
        addTearDown(fakeRepo.dispose);
        final container = ProviderContainer(
          overrides: [
            authRepositoryProvider.overrideWithValue(fakeRepo),
            // Decode-free / no real network or database: ToposScreen only
            // needs *some* loaded (AsyncData) topo list to enable its
            // button-disabled logic; an empty list is enough since this
            // test never taps "New topo".
            toposProvider.overrideWith((ref) => Stream.value(const <TopoRef>[])),
          ],
        );
        addTearDown(container.dispose);

        final router = GoRouter(
          initialLocation: '/',
          routes: [
            GoRoute(
              path: '/',
              builder: (context, state) => const ToposScreen(),
            ),
            GoRoute(
              path: '/account',
              builder: (context, state) => const AccountScreen(),
            ),
          ],
        );

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp.router(
              theme: MasiTheme.light,
              routerConfig: router,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(ToposScreen), findsOneWidget);
        expect(find.byKey(const Key('topos-account-button')), findsOneWidget);

        await tester.tap(find.byKey(const Key('topos-account-button')));
        await tester.pumpAndSettle();

        expect(find.byType(AccountScreen), findsOneWidget);
        expect(find.byType(ToposScreen), findsNothing);
        // Signed-out body renders, matching the fake's seeded state.
        expect(find.byKey(const Key('account-email-field')), findsOneWidget);
      },
    );
  });

  group('E1d: sync-status line', () {
    ProviderContainer makeContainer(SyncOrchestratorState fixedState) {
      final fakeRepo = FakeAuthRepository(
        const AuthSessionState.signedIn('climber@example.com'),
      );
      addTearDown(fakeRepo.dispose);
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [
          authRepositoryProvider.overrideWithValue(fakeRepo),
          appDatabaseProvider.overrideWithValue(db),
          syncOrchestratorProvider.overrideWith(
            () => _FixedSyncOrchestrator(fixedState),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    testWidgets('renders "Syncing…" while a push/pull is in flight', (
      tester,
    ) async {
      final container = makeContainer(
        const SyncOrchestratorState(status: SyncStatus.syncing),
      );

      await tester.pumpWidget(_wrap(container, const AccountScreen()));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('sync-status')), findsOneWidget);
      expect(find.text('Syncing…'), findsOneWidget);
    });

    testWidgets(
      'a sync in flight gets an activity cue next to the label — but only '
      'after the reveal delay, so a fast debounced push stays silent',
      (tester) async {
        final container = makeContainer(
          const SyncOrchestratorState(status: SyncStatus.syncing),
        );

        await tester.pumpWidget(_wrap(container, const AccountScreen()));
        await tester.pump();

        expect(
          find.byKey(MasiLoadingIndicator.spinnerKey),
          findsNothing,
          reason: 'a sync that finishes inside the reveal delay shows nothing',
        );

        // `pump`, not `pumpAndSettle`: the revealed arc spins forever.
        await tester.pump(const Duration(milliseconds: 250));

        expect(find.byKey(MasiLoadingIndicator.spinnerKey), findsOneWidget);
        expect(find.text('Syncing…'), findsOneWidget);
      },
    );

    testWidgets(
      'a FAILED sync gets no activity cue — "Sync error" is not in flight, '
      'and spinning at a failure reads as "still trying"',
      (tester) async {
        final container = makeContainer(
          const SyncOrchestratorState(status: SyncStatus.error),
        );

        await tester.pumpWidget(_wrap(container, const AccountScreen()));
        // Bare pump FIRST to deliver the auth state (otherwise the clock
        // advance is spent on the loading gate and the signed-in body has not
        // been built yet), then advance past the reveal delay.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        expect(find.text('Sync error'), findsOneWidget);
        expect(find.byKey(MasiLoadingIndicator.spinnerKey), findsNothing);
      },
    );

    testWidgets('being OFFLINE gets no activity cue either', (tester) async {
      final container = makeContainer(
        const SyncOrchestratorState(status: SyncStatus.offline),
      );

      await tester.pumpWidget(_wrap(container, const AccountScreen()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('Offline'), findsOneWidget);
      expect(find.byKey(MasiLoadingIndicator.spinnerKey), findsNothing);
    });

    testWidgets('renders "Offline" when the wifiOnly gate skipped a push', (
      tester,
    ) async {
      final container = makeContainer(
        const SyncOrchestratorState(status: SyncStatus.offline),
      );

      await tester.pumpWidget(_wrap(container, const AccountScreen()));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('sync-status')), findsOneWidget);
      expect(find.text('Offline'), findsOneWidget);
    });

    testWidgets('renders "Sync error" after a failed push/pull', (
      tester,
    ) async {
      final container = makeContainer(
        const SyncOrchestratorState(status: SyncStatus.error),
      );

      await tester.pumpWidget(_wrap(container, const AccountScreen()));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('sync-status')), findsOneWidget);
      expect(find.text('Sync error'), findsOneWidget);
    });

    testWidgets(
      'renders a "Synced • …" line once a push/pull has completed '
      'successfully (idle status with a non-null lastSyncedAt)',
      (tester) async {
        final container = makeContainer(
          SyncOrchestratorState(
            status: SyncStatus.idle,
            lastSyncedAt: DateTime.now(),
          ),
        );

        await tester.pumpWidget(_wrap(container, const AccountScreen()));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('sync-status')), findsOneWidget);
        expect(find.textContaining('Synced'), findsOneWidget);
      },
    );

    testWidgets(
      'renders "Not synced yet" for idle status with no lastSyncedAt (never '
      'attempted a sync)',
      (tester) async {
        final container = makeContainer(const SyncOrchestratorState());

        await tester.pumpWidget(_wrap(container, const AccountScreen()));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('sync-status')), findsOneWidget);
        expect(find.text('Not synced yet'), findsOneWidget);
      },
    );

    testWidgets(
      'S1: an idle state carrying a lastPushError renders "Sync error", never '
      '"Synced • …" — a successful PULL legitimately produces idle + a fresh '
      'lastSyncedAt, but local changes that never reached the cloud must not '
      'read as synced',
      (tester) async {
        final container = makeContainer(
          SyncOrchestratorState(
            status: SyncStatus.idle,
            lastSyncedAt: DateTime.now(),
            lastPushError: 'Sync failed: 3 change(s) not uploaded — areas: …',
          ),
        );

        await tester.pumpWidget(_wrap(container, const AccountScreen()));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('sync-status')), findsOneWidget);
        expect(find.text('Sync error'), findsOneWidget);
        expect(
          find.textContaining('Synced'),
          findsNothing,
          reason: 'this is the exact S1 lie the label must no longer tell',
        );
      },
    );

    testWidgets(
      'a clean idle state (lastPushError null) still renders "Synced • …" — '
      'per D-2 nothing is added to this line, the lying case is just removed',
      (tester) async {
        final container = makeContainer(
          SyncOrchestratorState(
            status: SyncStatus.idle,
            lastSyncedAt: DateTime.now(),
          ),
        );

        await tester.pumpWidget(_wrap(container, const AccountScreen()));
        await tester.pumpAndSettle();

        expect(find.textContaining('Synced'), findsOneWidget);
        expect(find.text('Sync error'), findsNothing);
        expect(find.byKey(const Key('sync-warning')), findsNothing);
      },
    );

    testWidgets(
      'L6: a lastPushWarning renders as its own line ALONGSIDE "Synced • …" — '
      'the push genuinely landed everything retryable, so the status must '
      'stay "Synced", but a photo whose pixels are gone from this device is '
      'permanently not backed up and the user has to be told',
      (tester) async {
        final container = makeContainer(
          SyncOrchestratorState(
            status: SyncStatus.idle,
            lastSyncedAt: DateTime.now(),
            lastPushWarning:
                '1 photo has no image data left on this device, so it could '
                'not be backed up. The topo details were saved.',
          ),
        );

        await tester.pumpWidget(_wrap(container, const AccountScreen()));
        await tester.pumpAndSettle();

        expect(
          find.textContaining('Synced'),
          findsOneWidget,
          reason: 'nothing retryable failed — this is not an error state',
        );
        expect(find.text('Sync error'), findsNothing);
        expect(
          find.byKey(const Key('sync-warning')),
          findsOneWidget,
          reason:
              'and yet the user must still learn the photo is not in the '
              'cloud and is not going to be',
        );
        expect(
          find.textContaining('could not be backed up'),
          findsOneWidget,
        );
      },
    );
  });

  group('PWA install affordance', () {
    ProviderContainer makeContainer(PwaInstallStatus status) {
      final fakeRepo = FakeAuthRepository(
        const AuthSessionState.signedIn('climber@example.com'),
      );
      addTearDown(fakeRepo.dispose);
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [
          authRepositoryProvider.overrideWithValue(fakeRepo),
          pwaInstallStatusProvider.overrideWithValue(status),
          appDatabaseProvider.overrideWithValue(db),
          // A real `appDatabaseProvider` override means the REAL
          // `SyncOrchestrator` would otherwise see this test's own writes
          // via its `db.tableUpdates()` subscription and schedule a real
          // 2s debounced push `Timer` that outlives the test (flutter_test's
          // "Timer still pending" failure) — swap in the fixed,
          // listener-free fake used by the `E1d`/`#18` groups; this group
          // only cares about the PWA install affordance, not sync.
          syncOrchestratorProvider.overrideWith(
            () => _FixedSyncOrchestrator(const SyncOrchestratorState()),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    testWidgets(
      'the default/native status (not standalone, cannot prompt, platform '
      'other) shows neither the install button nor the iOS hint — native '
      'regression guard: the stub status must never render either '
      'affordance',
      (tester) async {
        final container = makeContainer(
          const PwaInstallStatus(
            isStandalone: false,
            canPrompt: false,
            platform: PwaPlatform.other,
          ),
        );

        await tester.pumpWidget(_wrap(container, const AccountScreen()));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('account-install-button')),
          findsNothing,
        );
        expect(find.byKey(const Key('account-install-hint')), findsNothing);
      },
    );

    testWidgets(
      'canPrompt=true (Chromium/Android deferred install prompt ready) '
      'shows the real "Install app" button, not the iOS hint',
      (tester) async {
        final container = makeContainer(
          const PwaInstallStatus(
            isStandalone: false,
            canPrompt: true,
            platform: PwaPlatform.android,
          ),
        );

        await tester.pumpWidget(_wrap(container, const AccountScreen()));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('account-install-button')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('account-install-hint')), findsNothing);
      },
    );

    testWidgets(
      'platform=ios with canPrompt=false (Safari has no programmatic '
      'install API) shows the "Add to Home Screen" hint, not the prompt '
      'button',
      (tester) async {
        final container = makeContainer(
          const PwaInstallStatus(
            isStandalone: false,
            canPrompt: false,
            platform: PwaPlatform.ios,
          ),
        );

        await tester.pumpWidget(_wrap(container, const AccountScreen()));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('account-install-hint')), findsOneWidget);
        expect(
          find.byKey(const Key('account-install-button')),
          findsNothing,
        );
      },
    );

    testWidgets(
      'isStandalone=true (already installed) shows neither affordance, '
      'even when canPrompt is also true — nothing left to offer',
      (tester) async {
        final container = makeContainer(
          const PwaInstallStatus(
            isStandalone: true,
            canPrompt: true,
            platform: PwaPlatform.android,
          ),
        );

        await tester.pumpWidget(_wrap(container, const AccountScreen()));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('account-install-button')),
          findsNothing,
        );
        expect(find.byKey(const Key('account-install-hint')), findsNothing);
      },
    );

    testWidgets(
      'tapping the iOS hint opens a dialog explaining the manual Share -> '
      "'Add to Home Screen' steps",
      (tester) async {
        final container = makeContainer(
          const PwaInstallStatus(
            isStandalone: false,
            canPrompt: false,
            platform: PwaPlatform.ios,
          ),
        );

        await tester.pumpWidget(_wrap(container, const AccountScreen()));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('account-install-hint')));
        await tester.pumpAndSettle();

        // A `CupertinoAlertDialog` since the popup unification — every modal
        // in the app is now a Cupertino surface (see `masi_dialogs.dart`).
        expect(find.byType(CupertinoAlertDialog), findsOneWidget);
        expect(find.textContaining('Add to Home Screen'), findsWidgets);
      },
    );
  });

  group('#18: editable, synced display name', () {
    testWidgets(
      'entering a name and tapping Save persists it via ProfileRepository '
      'and shows a confirmation SnackBar',
      (tester) async {
        final fakeRepo = FakeAuthRepository(
          const AuthSessionState.signedIn(
            'climber@example.com',
            uid: 'uid-1',
          ),
        );
        addTearDown(fakeRepo.dispose);
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [
            authRepositoryProvider.overrideWithValue(fakeRepo),
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 1000),
            // A real `appDatabaseProvider` override means the REAL
            // `SyncOrchestrator` would otherwise see this test's own
            // `ProfileRepository` write via its `db.tableUpdates()`
            // subscription and schedule a real 2s debounced push `Timer`
            // that outlives the test (flutter_test's "Timer still pending"
            // failure) — swap in the fixed, listener-free fake used by the
            // `E1d` group above; this group only cares about the
            // display-name read/write path, not sync.
            syncOrchestratorProvider.overrideWith(
              () => _FixedSyncOrchestrator(const SyncOrchestratorState()),
            ),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(_wrap(container, const AccountScreen()));
        await _drain(tester);

        expect(
          find.byKey(const Key('account-display-name-field')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('account-display-name-save')),
          findsOneWidget,
        );

        await tester.enterText(
          find.byKey(const Key('account-display-name-field')),
          'Alex Boulder',
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('account-display-name-save')));
        await _drain(tester);

        expect(find.text('Display name saved.'), findsOneWidget);

        await tester.runAsync(() async {
          final row = await (db.select(
            db.profiles,
          )..where((t) => t.id.equals('uid-1'))).getSingleOrNull();
          expect(row?.displayName, 'Alex Boulder');
          expect(row?.dirty, isTrue);
        });
      },
    );

    testWidgets(
      'a previously-saved display name prefills the field on load',
      (tester) async {
        final fakeRepo = FakeAuthRepository(
          const AuthSessionState.signedIn(
            'climber@example.com',
            uid: 'uid-2',
          ),
        );
        addTearDown(fakeRepo.dispose);
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        await tester.runAsync(() async {
          await db
              .into(db.profiles)
              .insert(
                ProfilesCompanion.insert(
                  id: 'uid-2',
                  createdAt: 1000,
                  updatedAt: 1000,
                  displayName: const Value('Existing Name'),
                ),
              );
        });
        final container = ProviderContainer(
          overrides: [
            authRepositoryProvider.overrideWithValue(fakeRepo),
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 1000),
            // A real `appDatabaseProvider` override means the REAL
            // `SyncOrchestrator` would otherwise see this test's own
            // `ProfileRepository` write via its `db.tableUpdates()`
            // subscription and schedule a real 2s debounced push `Timer`
            // that outlives the test (flutter_test's "Timer still pending"
            // failure) — swap in the fixed, listener-free fake used by the
            // `E1d` group above; this group only cares about the
            // display-name read/write path, not sync.
            syncOrchestratorProvider.overrideWith(
              () => _FixedSyncOrchestrator(const SyncOrchestratorState()),
            ),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(_wrap(container, const AccountScreen()));
        await _drain(tester);

        expect(find.text('Existing Name'), findsOneWidget);
      },
    );

    testWidgets(
      'with no display name set yet, the field is empty and hints the '
      "email's local part",
      (tester) async {
        final fakeRepo = FakeAuthRepository(
          const AuthSessionState.signedIn(
            'climber@example.com',
            uid: 'uid-3',
          ),
        );
        addTearDown(fakeRepo.dispose);
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [
            authRepositoryProvider.overrideWithValue(fakeRepo),
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 1000),
            // A real `appDatabaseProvider` override means the REAL
            // `SyncOrchestrator` would otherwise see this test's own
            // `ProfileRepository` write via its `db.tableUpdates()`
            // subscription and schedule a real 2s debounced push `Timer`
            // that outlives the test (flutter_test's "Timer still pending"
            // failure) — swap in the fixed, listener-free fake used by the
            // `E1d` group above; this group only cares about the
            // display-name read/write path, not sync.
            syncOrchestratorProvider.overrideWith(
              () => _FixedSyncOrchestrator(const SyncOrchestratorState()),
            ),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(_wrap(container, const AccountScreen()));
        await _drain(tester);

        final field = tester.widget<TextField>(
          find.byKey(const Key('account-display-name-field')),
        );
        expect(field.controller?.text, isEmpty);
        expect(field.decoration?.hintText, 'climber');
      },
    );
  });

  group('isNotApprovedAuthError: pure classification', () {
    test(
      'the literal GoTrue message for create_user:false against a '
      'nonexistent user ("Signups not allowed for otp") -> true',
      () {
        expect(
          isNotApprovedAuthError(
            const AuthException('Signups not allowed for otp'),
          ),
          isTrue,
        );
      },
    );

    test('AuthException with code "otp_disabled" -> true', () {
      expect(
        isNotApprovedAuthError(
          const AuthException('otp is disabled', code: 'otp_disabled'),
        ),
        isTrue,
      );
    });

    test('AuthException with code "signup_disabled" -> true', () {
      expect(
        isNotApprovedAuthError(
          const AuthException('signups disabled', code: 'signup_disabled'),
        ),
        isTrue,
      );
    });

    test('a "user not found"-worded AuthException -> true', () {
      expect(
        isNotApprovedAuthError(const AuthException('User not found')),
        isTrue,
      );
    });

    test(
      'an unrelated AuthException (e.g. OTP rate-limited) -> false, falling '
      'through to the generic error path',
      () {
        expect(
          isNotApprovedAuthError(
            const AuthException('email rate limit exceeded'),
          ),
          isFalse,
        );
      },
    );

    test('a non-AuthException error (e.g. a network failure) -> false', () {
      expect(isNotApprovedAuthError(Exception('network error')), isFalse);
    });
  });

  group(
    'googleSignInErrorMessage: STAGE 1 diagnostic rendering — pure '
    'classification',
    () {
      test(
        'an AuthException with a message renders that message verbatim '
        '(the STAGE-1 diagnostic path — which step, which host)',
        () {
          expect(
            googleSignInErrorMessage(
              const AuthException(
                'Could not open the Google sign-in page. '
                '(redirect to test.supabase.co did not leave the page)',
              ),
            ),
            'Could not open the Google sign-in page. '
            '(redirect to test.supabase.co did not leave the page)',
          );
        },
      );

      test(
        'an AuthException with an empty message falls back to the generic '
        'message rather than rendering nothing',
        () {
          expect(
            googleSignInErrorMessage(const AuthException('')),
            'Google sign-in failed. Please try again.',
          );
        },
      );

      test(
        'a non-AuthException error (e.g. a plain network failure) falls '
        'back to the generic message, unchanged from before STAGE 1',
        () {
          expect(
            googleSignInErrorMessage(Exception('boom')),
            'Google sign-in failed. Please try again.',
          );
        },
      );
    },
  );

  group('#54 (approved-login UX): the not-approved OTP error message', () {
    testWidgets(
      'sendMagicLink throwing the disabled-signup AuthException shows the '
      "'account-not-approved' message, and NOT the generic sent "
      'confirmation',
      (tester) async {
        final fakeRepo = FakeAuthRepository(
          const AuthSessionState.signedOut(),
        );
        addTearDown(fakeRepo.dispose);
        fakeRepo.sendMagicLinkError = const AuthException(
          'Signups not allowed for otp',
        );
        final container = ProviderContainer(
          overrides: [authRepositoryProvider.overrideWithValue(fakeRepo)],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(_wrap(container, const AccountScreen()));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('account-email-field')),
          'notapproved@example.com',
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('account-send-link')));
        await tester.pumpAndSettle();

        expect(fakeRepo.sendMagicLinkCalls, ['notapproved@example.com']);
        expect(
          find.byKey(const Key('account-not-approved')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('account-link-sent')), findsNothing);
      },
    );

    testWidgets(
      'a genuine successful send still shows the generic "check your '
      'email" confirmation, not the not-approved message',
      (tester) async {
        final fakeRepo = FakeAuthRepository(
          const AuthSessionState.signedOut(),
        );
        addTearDown(fakeRepo.dispose);
        final container = ProviderContainer(
          overrides: [authRepositoryProvider.overrideWithValue(fakeRepo)],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(_wrap(container, const AccountScreen()));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('account-email-field')),
          'climber@example.com',
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('account-send-link')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('account-link-sent')), findsOneWidget);
        expect(find.byKey(const Key('account-not-approved')), findsNothing);
      },
    );
  });

  group('#ios-web sign-in gating', () {
    // Signed-out screen only — no DB/sync overrides needed. The one variable
    // is the sniffed platform: `PwaPlatform.ios` is TRUE only on iOS web (the
    // stub used natively/in-test reports `.other`), which is the gate that
    // swaps the magic-LINK flow for an emailed sign-in CODE.
    ProviderContainer makeContainer(
      FakeAuthRepository fakeRepo,
      PwaPlatform platform,
    ) {
      final container = ProviderContainer(
        overrides: [
          authRepositoryProvider.overrideWithValue(fakeRepo),
          pwaInstallStatusProvider.overrideWithValue(
            PwaInstallStatus(
              platform: platform,
              isStandalone: false,
              canPrompt: false,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    testWidgets(
      'iOS web: sign-in is Google-only — email/send/OTP hidden',
      (tester) async {
        final fakeRepo = FakeAuthRepository(
          const AuthSessionState.signedOut(),
        );
        addTearDown(fakeRepo.dispose);
        final container = makeContainer(fakeRepo, PwaPlatform.ios);

        await tester.pumpWidget(_wrap(container, const AccountScreen()));
        await tester.pump();

        expect(
          find.byKey(const Key('account-google-signin')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('account-email-field')), findsNothing);
        expect(find.byKey(const Key('account-send-link')), findsNothing);
        expect(find.byKey(const Key('account-otp-field')), findsNothing);
        expect(find.text('Email me a sign-in code'), findsNothing);
        expect(
          find.text('Sign in with Google to continue.'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'non-iOS (platform other): email field, "Send magic link" button, and '
      'Google are all present — the magic-link flow is NOT removed off iOS, '
      'and sending still reveals the link-sent confirmation',
      (tester) async {
        final fakeRepo = FakeAuthRepository(
          const AuthSessionState.signedOut(),
        );
        addTearDown(fakeRepo.dispose);
        final container = makeContainer(fakeRepo, PwaPlatform.other);

        await tester.pumpWidget(_wrap(container, const AccountScreen()));
        await tester.pump();

        expect(find.byKey(const Key('account-email-field')), findsOneWidget);
        expect(find.text('Send magic link'), findsOneWidget);
        expect(
          find.byKey(const Key('account-google-signin')),
          findsOneWidget,
        );
        expect(find.text('Email me a sign-in code'), findsNothing);

        await tester.enterText(
          find.byKey(const Key('account-email-field')),
          'climber@example.com',
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('account-send-link')));
        await tester.pump();

        expect(find.byKey(const Key('account-link-sent')), findsOneWidget);
      },
    );

    testWidgets(
      'iOS web: the OTP field is unreachable — there is no send button to '
      'reveal it and no stray "check your email" confirmation either',
      (tester) async {
        // The OTP-code flow's code is still in place for a future one-line
        // re-enable (see `showEmailSignIn` in `_SignedOutBody.build`), but on
        // iOS web there's no `account-send-link` button to tap to reach it
        // any more — Google is the only path. `FakeAuthRepository`'s
        // `verifyEmailOtpCalls`/`verifyEmailOtpArgs`/`verifyEmailOtpError`
        // and `googleSignInCalls` spies are kept defined (unused here) for
        // when that re-enable happens.
        final fakeRepo = FakeAuthRepository(
          const AuthSessionState.signedOut(),
        );
        addTearDown(fakeRepo.dispose);
        final container = makeContainer(fakeRepo, PwaPlatform.ios);

        await tester.pumpWidget(_wrap(container, const AccountScreen()));
        await tester.pump();

        expect(find.byKey(const Key('account-otp-field')), findsNothing);
        expect(find.byKey(const Key('account-link-sent')), findsNothing);
      },
    );
  });

  group('shared loading system', () {
    testWidgets(
      'while the auth state is still resolving the screen paints nothing, '
      'then the card skeleton — never a bare spinner',
      (tester) async {
        final fakeRepo = FakeAuthRepository(
          const AuthSessionState.signedOut(),
          seedImmediately: false,
        );
        addTearDown(fakeRepo.dispose);
        final container = ProviderContainer(
          overrides: [authRepositoryProvider.overrideWithValue(fakeRepo)],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(_wrap(container, const AccountScreen()));
        await tester.pump();

        expect(
          find.byKey(const Key('account-skeleton')),
          findsNothing,
          reason: 'the anti-flash window',
        );
        expect(find.byType(CircularProgressIndicator), findsNothing);

        await tester.pump(const Duration(milliseconds: 250));
        expect(find.byKey(const Key('account-skeleton')), findsOneWidget);
        expect(find.byKey(const Key('account-send-link')), findsNothing);

        // Resolving swaps in the real body.
        fakeRepo.emit(const AuthSessionState.signedOut());
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(find.byKey(const Key('account-skeleton')), findsNothing);
        expect(find.byKey(const Key('account-send-link')), findsOneWidget);
      },
    );

    testWidgets(
      'the errored auth state still shows the sign-in FORM, not an error '
      'state with a Retry — the web auth wall redirects errored visitors '
      'here and they must be able to sign in',
      (tester) async {
        final fakeRepo = FakeAuthRepository(
          const AuthSessionState.signedOut(),
          seedImmediately: false,
        );
        addTearDown(fakeRepo.dispose);
        final container = ProviderContainer(
          overrides: [authRepositoryProvider.overrideWithValue(fakeRepo)],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(_wrap(container, const AccountScreen()));
        fakeRepo.failStream(Exception('Supabase.initialize failed'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(find.byKey(const Key('account-send-link')), findsOneWidget);
        expect(find.byKey(const Key('account-skeleton')), findsNothing);
        expect(find.byKey(MasiAsyncView.retryKey), findsNothing);
      },
    );

    testWidgets(
      'sign-out is single-shot and shows a pending cue: a second tap while '
      'the first is in flight does not call signOut again',
      (tester) async {
        final fakeRepo = FakeAuthRepository(
          const AuthSessionState.signedIn('climber@example.com'),
        );
        addTearDown(fakeRepo.dispose);
        fakeRepo.signOutGate = Completer<void>();
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [
            authRepositoryProvider.overrideWithValue(fakeRepo),
            appDatabaseProvider.overrideWithValue(db),
            syncOrchestratorProvider.overrideWith(
              () => _FixedSyncOrchestrator(const SyncOrchestratorState()),
            ),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(_wrap(container, const AccountScreen()));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('account-sign-out')));
        await tester.pump();
        expect(fakeRepo.signOutCalls, 1);

        // Past the reveal delay the button carries the cue.
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.byKey(MasiLoadingIndicator.spinnerKey), findsOneWidget);

        await tester.tap(find.byKey(const Key('account-sign-out')));
        await tester.pump();
        expect(
          fakeRepo.signOutCalls,
          1,
          reason:
              'the sign-out button used to be a bare VoidCallback with no '
              'guard, so it was freely double-tappable',
        );

        fakeRepo.signOutGate!.complete();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
      },
    );
  });

  group('#54 B5: storage-diagnostics row', () {
    /// Signed-in container wired with the fixed [durability]/[persistence]
    /// notifiers above, plus the same `appDatabaseProvider`/
    /// `syncOrchestratorProvider` scaffolding the other signed-in groups
    /// use (a real in-memory db is required by `myDisplayNameProvider`, and
    /// the fixed sync orchestrator avoids a real debounced-push `Timer`
    /// outliving the test). Returns the container AND the persistence
    /// controller (for asserting on its recorded calls).
    (
      ProviderContainer container,
      _RecordingStoragePersistenceController persistenceController,
    )
    makeContainer({
      StorageDurability durability = const StorageDurability.probing(),
      StoragePersistenceStatus persistence = const StoragePersistenceStatus(),
    }) {
      final fakeRepo = FakeAuthRepository(
        const AuthSessionState.signedIn('climber@example.com'),
      );
      addTearDown(fakeRepo.dispose);
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final persistenceController = _RecordingStoragePersistenceController(
        persistence,
      );
      final container = ProviderContainer(
        overrides: [
          authRepositoryProvider.overrideWithValue(fakeRepo),
          appDatabaseProvider.overrideWithValue(db),
          syncOrchestratorProvider.overrideWith(
            () => _FixedSyncOrchestrator(const SyncOrchestratorState()),
          ),
          storageDurabilityProvider.overrideWith(
            () => _FixedStorageDurabilityNotifier(durability),
          ),
          storagePersistenceProvider.overrideWith(() => persistenceController),
        ],
      );
      addTearDown(container.dispose);
      return (container, persistenceController);
    }

    testWidgets(
      'assertion 1: a measured opfsLocks backend with a missing '
      'dedicatedWorkersInSharedWorkers feature renders both literal names',
      (tester) async {
        final (container, _) = makeContainer(
          durability: const StorageDurability(
            backend: StorageBackend.opfsLocks,
            missingFeatures: {
              StorageMissingFeature.dedicatedWorkersInSharedWorkers,
            },
          ),
        );

        await tester.pumpWidget(_wrap(container, const AccountScreen()));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('account-storage-diagnostics')),
          findsOneWidget,
        );
        expect(find.textContaining('opfsLocks'), findsWidgets);
        expect(
          find.textContaining('dedicatedWorkersInSharedWorkers'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'assertion 2: an unavailableOver verdict STILL renders the measured '
      'opfsLocks backend plus the stall reason — reading measuredBackend, '
      'never backend (340ba7b regression guard)',
      (tester) async {
        final measured = const StorageDurability(
          backend: StorageBackend.opfsLocks,
          missingFeatures: {
            StorageMissingFeature.dedicatedWorkersInSharedWorkers,
          },
        );
        final durability = StorageDurability.unavailableOver(
          measured,
          'reason text',
        );
        final (container, _) = makeContainer(durability: durability);

        await tester.pumpWidget(_wrap(container, const AccountScreen()));
        await tester.pumpAndSettle();

        expect(find.textContaining('opfsLocks'), findsWidgets);
        expect(find.textContaining('reason text'), findsOneWidget);
      },
    );

    testWidgets(
      'assertion 3: a clean verdict (no missing features, no error) hides '
      'BOTH the missing-features row and the error row entirely — no empty '
      'rows of noise on a healthy install',
      (tester) async {
        final (container, _) = makeContainer(
          durability: const StorageDurability(
            backend: StorageBackend.opfsShared,
          ),
        );

        await tester.pumpWidget(_wrap(container, const AccountScreen()));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('account-storage-missing-features')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('account-storage-error')),
          findsNothing,
        );
      },
    );

    testWidgets(
      'assertion 4: a 40,000,000 / 100,000,000 byte estimate renders the '
      'literal "40%" (the test hard-codes the expected string rather than '
      'recomputing usage/quota, per this repo\'s own arithmetic-vs-behaviour '
      'trap)',
      (tester) async {
        final (container, _) = makeContainer(
          persistence: const StoragePersistenceStatus(
            estimate: StorageEstimateSnapshot(
              usageBytes: 40000000,
              quotaBytes: 100000000,
            ),
          ),
        );

        await tester.pumpWidget(_wrap(container, const AccountScreen()));
        await tester.pumpAndSettle();

        expect(find.textContaining('40%'), findsOneWidget);
      },
    );

    testWidgets(
      'assertion 5: a null estimate renders "not reported", specifically '
      'NOT "0%" or "0 B" — unknown usage must never render as zero usage',
      (tester) async {
        final (container, _) = makeContainer(
          persistence: const StoragePersistenceStatus(),
        );

        await tester.pumpWidget(_wrap(container, const AccountScreen()));
        await tester.pumpAndSettle();

        expect(find.textContaining('not reported'), findsOneWidget);
        expect(find.textContaining('0%'), findsNothing);
        expect(find.textContaining('0 B'), findsNothing);
      },
    );

    testWidgets(
      'assertion 6: tapping Refresh calls StoragePersistenceController.'
      'refresh() exactly once and never requestPersistenceOnce() — looking '
      'at the row must not re-trigger the browser persistence prompt',
      (tester) async {
        final (container, persistenceController) = makeContainer();

        await tester.pumpWidget(_wrap(container, const AccountScreen()));
        await tester.pumpAndSettle();

        // The signed-in card grew when the initials chip became an editable
        // profile picture, so on this viewport the diagnostics row sits below
        // the fold — scroll it in rather than tapping empty space.
        await tester.ensureVisible(
          find.byKey(const Key('account-storage-refresh')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('account-storage-refresh')));
        await tester.pump();

        expect(persistenceController.refreshCalls, 1);
        expect(persistenceController.requestPersistenceOnceCalls, 0);
      },
    );

    testWidgets(
      'assertion 7: Copy diagnostics places a single line containing the '
      'backend, the missing feature and the persist outcome on the '
      'clipboard',
      (tester) async {
        String? clipboardText;
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(SystemChannels.platform, (
          call,
        ) async {
          if (call.method == 'Clipboard.setData') {
            final args = call.arguments as Map<Object?, Object?>;
            clipboardText = args['text'] as String?;
          }
          return null;
        });
        addTearDown(
          () => messenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );

        final (container, _) = makeContainer(
          durability: const StorageDurability(
            backend: StorageBackend.opfsLocks,
            missingFeatures: {
              StorageMissingFeature.dedicatedWorkersInSharedWorkers,
            },
          ),
          persistence: const StoragePersistenceStatus(
            outcome: StoragePersistOutcome.denied,
          ),
        );

        await tester.pumpWidget(_wrap(container, const AccountScreen()));
        await tester.pumpAndSettle();

        // The extra missing-features row pushes the Copy button below the
        // 600px test viewport fold, inside the card's SingleChildScrollView
        // — scroll it into view before tapping.
        await tester.ensureVisible(
          find.byKey(const Key('account-storage-copy')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('account-storage-copy')));
        await tester.pump();

        expect(clipboardText, isNotNull);
        expect(clipboardText, contains('opfsLocks'));
        expect(clipboardText, contains('dedicatedWorkersInSharedWorkers'));
        expect(clipboardText, contains('denied'));
      },
    );

    testWidgets(
      'assertion 8: a rejected Clipboard.setData surfaces a user-visible '
      'error message, never the success confirmation, and produces no '
      'unhandled async error (the review finding: a bare await + a '
      "discarded Future meant the button's only failure mode was silence)",
      (tester) async {
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(SystemChannels.platform, (
          call,
        ) async {
          if (call.method == 'Clipboard.setData') {
            throw PlatformException(
              code: 'unavailable',
              message: 'clipboard-write denied',
            );
          }
          return null;
        });
        addTearDown(
          () => messenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );

        final (container, _) = makeContainer();

        await tester.pumpWidget(_wrap(container, const AccountScreen()));
        await tester.pumpAndSettle();

        await tester.ensureVisible(
          find.byKey(const Key('account-storage-copy')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('account-storage-copy')));
        await tester.pump();

        // No unhandled async error: reaching this line at all (rather than
        // the test framework failing on an uncaught exception thrown into
        // the zone) is itself part of what this assertion is checking.
        expect(find.textContaining("Couldn't copy diagnostics"), findsOneWidget);
        expect(find.text('Diagnostics copied.'), findsNothing);
      },
    );

    testWidgets(
      'assertion 9: a notApplicable persistence outcome renders truthful '
      'native wording, never the literal "persisted: false" — the type '
      "doc's own words forbid reading that as \"native storage is fragile\"",
      (tester) async {
        final (container, _) = makeContainer(
          persistence: const StoragePersistenceStatus(
            outcome: StoragePersistOutcome.notApplicable,
          ),
        );

        await tester.pumpWidget(_wrap(container, const AccountScreen()));
        await tester.pumpAndSettle();

        expect(find.textContaining('persisted: false'), findsNothing);
        expect(find.textContaining('notApplicable'), findsNothing);
        expect(
          find.textContaining('this platform has no evictable storage'),
          findsOneWidget,
        );
      },
    );

    for (final outcome in [
      StoragePersistOutcome.denied,
      StoragePersistOutcome.granted,
      StoragePersistOutcome.failed,
      StoragePersistOutcome.unsupported,
    ]) {
      testWidgets(
        'assertion 10: web outcome $outcome still renders the pre-existing '
        '"<outcome> (persisted: <bool>)" row unchanged',
        (tester) async {
          final (container, _) = makeContainer(
            persistence: StoragePersistenceStatus(outcome: outcome),
          );

          await tester.pumpWidget(_wrap(container, const AccountScreen()));
          await tester.pumpAndSettle();

          expect(
            find.textContaining('${outcome.name} (persisted: false)'),
            findsOneWidget,
          );
        },
      );
    }
  });

  group('shortUserIdHash: stable across compilers', () {
    // The expected digests below are the canonical 32-bit FNV-1a values,
    // computed OUTSIDE Dart (a reference implementation in Python over the
    // same input) rather than by running this function and writing down what
    // it said — a self-recorded value would pin whatever the implementation
    // happens to do, including the very drift these tests exist to catch.
    // 'a' -> 0xe40c292c is FNV's own published test vector.
    const vectors = <String, String>{
      'a': 'e40c292c',
      '00000000-0000-4000-8000-000000000e2e': '427b60b3',
      'climber-uid-42': '23654a2b',
      'e2e-owner@masi.test': '74fbe00f',
    };

    for (final entry in vectors.entries) {
      test(
        'uid "${entry.key}" hashes to the reference FNV-1a value '
        '${entry.value} — the pre-fix `hash * prime & 0xFFFFFFFF` produced '
        'this only where an int is 64-bit, and something else under dart2js, '
        'where the >2^53 product loses its low bits BEFORE the mask',
        () {
          expect(shortUserIdHash(entry.key), entry.value);
        },
      );
    }

    test('a null or empty uid is the literal "none", never a digest', () {
      expect(shortUserIdHash(null), 'none');
      expect(shortUserIdHash(''), 'none');
      // Specifically not FNV-1a's offset basis rendered as a digest, which
      // is what hashing the empty string would produce — "nobody is signed
      // in" must not look like a real account.
      expect(shortUserIdHash(''), isNot('811c9dc5'));
    });

    test('every digest is exactly 8 lowercase hex characters', () {
      for (final uid in [
        'a',
        'A',
        '00000000-0000-4000-8000-000000000e2e',
        'áé漢字🧗',
        'x' * 200,
      ]) {
        expect(shortUserIdHash(uid), matches(RegExp(r'^[0-9a-f]{8}$')));
      }
    });

    test('different uids do not collide, and the digest is stable', () {
      const a = '11111111-2222-4333-8444-555555555555';
      const b = '11111111-2222-4333-8444-555555555556';
      expect(shortUserIdHash(a), isNot(shortUserIdHash(b)));
      expect(shortUserIdHash(a), shortUserIdHash(a));
    });
  });

  group('diagnosticsClipboardLine: the pasted support payload', () {
    const fullDurability = StorageDurability(
      backend: StorageBackend.opfsLocks,
      missingFeatures: {StorageMissingFeature.dedicatedWorkersInSharedWorkers},
    );
    const fullPersistence = StoragePersistenceStatus(
      outcome: StoragePersistOutcome.denied,
      estimate: StorageEstimateSnapshot(
        usageBytes: 40000000,
        quotaBytes: 100000000,
      ),
    );

    test('carries every enrichment token with the value it was given', () {
      final line = diagnosticsClipboardLine(
        fullDurability,
        fullPersistence,
        sync: SyncOrchestratorState(
          status: SyncStatus.error,
          lastSyncedAt: DateTime.utc(2026, 8, 8, 12, 34, 56),
          lastPullError: 'pull blew up',
          lastPushError: 'push blew up',
        ),
        schemaVersion: 42,
        userId: '00000000-0000-4000-8000-000000000e2e',
        appVersion: '9.9.9+9',
      );

      expect(line, contains('usageBytes=40000000'));
      expect(line, contains('quotaBytes=100000000'));
      expect(line, contains('usedPct=40'));
      expect(line, contains('schemaVersion=42'));
      expect(line, contains('appVersion=9.9.9+9'));
      expect(line, contains('user=427b60b3'));
      expect(line, contains('syncStatus=error'));
      expect(line, contains('lastSyncedAt=2026-08-08T12:34:56.000Z'));
      expect(line, contains('pullError="pull blew up"'));
      expect(line, contains('pushError="push blew up"'));
    });

    test(
      'the RAW uid never appears — only its digest. This is a privacy '
      'guarantee, not a nicety: the raw value is what auth.uid() resolves to '
      'server-side and what every RLS policy is written against, and this '
      'blob is written to be pasted into a possibly-public bug report',
      () {
        const uid = '11111111-2222-4333-8444-555555555555';
        final line = diagnosticsClipboardLine(
          fullDurability,
          fullPersistence,
          userId: uid,
        );

        expect(line, isNot(contains(uid)));
        // Not even a recognisable fragment of it.
        expect(line, isNot(contains('11111111')));
        expect(line, isNot(contains('555555555555')));
        expect(line, contains('user=${shortUserIdHash(uid)}'));
        expect(line, matches(RegExp(r'user=[0-9a-f]{8}(\s|$)')));
      },
    );

    test('a signed-out payload says user=none, never an empty token', () {
      final line = diagnosticsClipboardLine(fullDurability, fullPersistence);
      expect(line, contains('user=none'));
    });

    test(
      'absent values render the honest "unknown", never a plausible default',
      () {
        final line = diagnosticsClipboardLine(
          const StorageDurability.probing(),
          const StoragePersistenceStatus(),
        );

        expect(line, contains('usageBytes=unknown'));
        expect(line, contains('quotaBytes=unknown'));
        expect(line, contains('usedPct=unknown'));
        expect(line, contains('schemaVersion=unknown'));
        expect(line, contains('syncStatus=unknown'));
        expect(line, contains('lastSyncedAt=unknown'));
        // A caller with no sync state has nothing to say about errors —
        // the tokens are absent rather than rendered empty.
        expect(line, isNot(contains('pullError')));
        expect(line, isNot(contains('pushError')));
        expect(line, contains('appVersion=$kMasiAppVersion'));
      },
    );

    test(
      'a sync that has never run says lastSyncedAt=never, distinct from the '
      '"no state supplied at all" unknown',
      () {
        final line = diagnosticsClipboardLine(
          fullDurability,
          fullPersistence,
          sync: const SyncOrchestratorState(),
        );

        expect(line, contains('syncStatus=idle'));
        expect(line, contains('lastSyncedAt=never'));
      },
    );

    test('a local lastSyncedAt is normalised to UTC before it is stamped', () {
      final local = DateTime.utc(2026, 8, 8, 12).toLocal();
      final line = diagnosticsClipboardLine(
        fullDurability,
        fullPersistence,
        sync: SyncOrchestratorState(lastSyncedAt: local),
      );

      expect(line, contains('lastSyncedAt=2026-08-08T12:00:00.000Z'));
    });

    test(
      'the unavailable reason is flattened and quoted like every other '
      'free-form value — a multi-line probe error must not break the '
      'one-line clipboard guarantee',
      () {
        final line = diagnosticsClipboardLine(
          StorageDurability.unavailable(
            'probe threw\nSomeException: no "workers"\n  at frame\ttwo',
          ),
          const StoragePersistenceStatus(),
        );

        expect(line.contains('\n'), isFalse);
        expect(line.contains('\r'), isFalse);
        expect(
          line,
          contains(
            'reason="probe threw SomeException: no \'workers\' at frame two"',
          ),
        );
        expect(line, contains('backend=unavailable'));
      },
    );

    test(
      'a multi-line sync error is flattened too, and the whole payload stays '
      'exactly one line',
      () {
        final line = diagnosticsClipboardLine(
          StorageDurability.unavailable('reason\nwith a newline'),
          fullPersistence,
          sync: const SyncOrchestratorState(
            status: SyncStatus.error,
            lastPullError: 'PostgrestException:\n  message: bad row\n',
            lastPushError: 'SocketException:\r\n  failed host lookup',
          ),
          schemaVersion: 7,
          userId: 'climber-uid-42',
        );

        expect(const LineSplitter().convert(line).length, 1);
        expect(
          line,
          contains('pullError="PostgrestException: message: bad row"'),
        );
        expect(
          line,
          contains('pushError="SocketException: failed host lookup"'),
        );
      },
    );

    test('an overlong error is truncated so the paste stays greppable', () {
      final line = diagnosticsClipboardLine(
        fullDurability,
        fullPersistence,
        sync: SyncOrchestratorState(
          status: SyncStatus.error,
          lastPullError: 'x' * 500,
        ),
      );

      expect(line, contains('pullError="${'x' * 240}…"'));
      expect(line, isNot(contains('x' * 241)));
    });

    test(
      'usedPct is absent (not zero) when the browser reports no quota, so an '
      'unknown fraction can never read as an empty origin',
      () {
        final line = diagnosticsClipboardLine(
          fullDurability,
          const StoragePersistenceStatus(
            estimate: StorageEstimateSnapshot(usageBytes: 123),
          ),
        );

        expect(line, contains('usageBytes=123'));
        expect(line, contains('quotaBytes=unknown'));
        expect(line, contains('usedPct=unknown'));
      },
    );
  });
}
