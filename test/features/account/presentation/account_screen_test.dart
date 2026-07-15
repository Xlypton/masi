import 'dart:async';

import 'package:climbtopo/app/theme.dart';
import 'package:climbtopo/features/account/application/auth_providers.dart';
import 'package:climbtopo/features/account/data/auth_repository.dart';
import 'package:climbtopo/features/account/presentation/account_screen.dart';
import 'package:climbtopo/features/backup/application/sync_orchestrator.dart';
import 'package:climbtopo/features/library/application/library_providers.dart';
import 'package:climbtopo/features/library/data/library_crud_repository.dart';
import 'package:climbtopo/features/library/presentation/topos_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

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

  /// When non-null, the next call(s) to [sendMagicLink] throw this instead
  /// of succeeding — lets a test simulate a failed/rate-limited send (e.g.
  /// the MAJOR-1 stale-"link sent"-plus-error regression test below).
  Object? sendMagicLinkError;

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

  group('S2-b: signed-in state', () {
    testWidgets(
      'a signed-in session flips the screen to the signed-in body: shows '
      "the user's email and a working Sign out button",
      (tester) async {
        final fakeRepo = FakeAuthRepository(
          const AuthSessionState.signedIn('climber@example.com'),
        );
        addTearDown(fakeRepo.dispose);
        final container = ProviderContainer(
          overrides: [authRepositoryProvider.overrideWithValue(fakeRepo)],
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
      'S2-b (flip): a signed-out screen rebuilds to signed-in when the '
      'auth stream emits a session while mounted',
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
        final container = ProviderContainer(
          overrides: [authRepositoryProvider.overrideWithValue(fakeRepo)],
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
      final container = ProviderContainer(
        overrides: [
          authRepositoryProvider.overrideWithValue(fakeRepo),
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
  });
}
