import 'dart:async';

import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/account/application/auth_providers.dart';
import 'package:masi/features/account/application/pwa_install_providers.dart';
import 'package:masi/features/account/application/pwa_install_types.dart';
import 'package:masi/features/account/data/auth_repository.dart';
import 'package:masi/features/account/presentation/account_screen.dart';
import 'package:masi/features/backup/application/sync_orchestrator.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/library/data/library_crud_repository.dart';
import 'package:masi/features/library/presentation/topos_screen.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;

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
  FakeAuthRepository(AuthSessionState initial) : _current = initial {
    _controller.add(initial);
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

  @override
  Future<void> signOut() async {
    signOutCalls++;
  }

  @override
  Future<void> signInWithGoogle() async {
    googleSignInCalls++;
    if (googleSignInError != null) throw googleSignInError!;
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
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 30));
  }
  await tester.pumpAndSettle();
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

        expect(find.byType(AlertDialog), findsOneWidget);
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
}
