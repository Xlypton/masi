// The Account card's navigation entry points, and where they sit.
//
// Two of them — "Suggested edits" (`account-open-suggestions`) and "Review
// queue" (`account-open-admin-queue`) — used to be appended BELOW the sign-out
// button, i.e. past the one control that ends the session, which is the last
// place anybody looks for a way further into the app. A third, the personal
// Logbook (`account-open-logbook`), did not exist here at all: `/logbook` had
// exactly one entry point in the whole app, an unlabelled icon in the
// Community Feed's app bar.
//
// So this file pins three things that are easy to break by appending the next
// row to the bottom of the same `children` list:
//  - the Logbook row exists on Account and reaches `/logbook`;
//  - all three rows render ABOVE "Sign out" (asserted by real laid-out Y
//    position, not mere presence), and "Sign out" is the last of them;
//  - the two MOVED rows still do exactly what they did before the move.

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/account/application/auth_providers.dart';
import 'package:masi/features/account/data/auth_repository.dart';
import 'package:masi/features/account/presentation/account_screen.dart';
import 'package:masi/features/backup/application/sync_orchestrator.dart';
import 'package:masi/features/moderation/application/moderation_providers.dart';
import 'package:masi/features/moderation/application/suggestion_providers.dart';
import 'package:masi/features/moderation/domain/edit_suggestion.dart';

/// Minimal signed-in [AuthRepository] double — this file only needs the
/// signed-in body to render, never an auth transition.
class _FakeAuth implements AuthRepository {
  _FakeAuth(this._state) {
    _controller.add(_state);
  }

  final AuthSessionState _state;
  final _controller = StreamController<AuthSessionState>();

  Future<void> dispose() => _controller.close();

  @override
  Stream<AuthSessionState> authStateChanges() => _controller.stream;

  @override
  AuthSessionState get currentSession => _state;

  @override
  Future<void> sendMagicLink(String email) async {}

  @override
  Future<void> signInWithGoogle() async {}

  @override
  Future<void> verifyEmailOtp(String email, String code) async {}

  @override
  Future<void> signOut() async {}
}

/// A [SyncOrchestrator] that never watches the database or schedules a
/// debounced push — the real one, given this file's in-memory
/// `appDatabaseProvider` override, would leave a pending 2 s `Timer` behind
/// and fail the test (same rationale as `account_screen_test.dart`'s own
/// `_FixedSyncOrchestrator`).
class _InertSyncOrchestrator extends SyncOrchestrator {
  @override
  SyncOrchestratorState build() => const SyncOrchestratorState();
}

const _suggestion = EditSuggestion(
  id: 's1',
  wallId: 'w1',
  wallName: 'Roof Wall',
  kind: SuggestionKind.topoMetadata,
  patch: {'name': 'Roof Wall (left)'},
  createdAt: 1000,
  isStale: false,
);

void main() {
  const logbookKey = Key('account-open-logbook');
  const suggestionsKey = Key('account-open-suggestions');
  const adminKey = Key('account-open-admin-queue');
  const signOutKey = Key('account-sign-out');

  /// Pumps the real signed-in [AccountScreen] under a real [GoRouter] whose
  /// `/logbook`, `/suggestions` and `/admin` routes are marker widgets — so a
  /// tap is proved to reach the ROUTE without dragging those screens' own
  /// providers into this test.
  ///
  /// Both the admin check and the suggestion inbox are answered positively:
  /// `AccountAdminEntryPoint` hides itself for non-admins and
  /// `AccountSuggestionsEntryPoint` hides itself on an empty inbox, so without
  /// this the ordering assertion would pass vacuously on two absent widgets.
  Future<void> pumpAccount(WidgetTester tester) async {
    // A tall, wide surface so every row of the card is laid out on-screen and
    // therefore tappable — the card scrolls, and `tester.tap` refuses a target
    // whose centre is outside the viewport.
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final auth = _FakeAuth(
      const AuthSessionState.signedIn('climber@example.com'),
    );
    addTearDown(auth.dispose);
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    final container = ProviderContainer(
      overrides: [
        authRepositoryProvider.overrideWithValue(auth),
        appDatabaseProvider.overrideWithValue(db),
        syncOrchestratorProvider.overrideWith(_InertSyncOrchestrator.new),
        effectiveUidProvider.overrideWithValue('me'),
        isAdminProvider.overrideWith((ref) async => true),
        moderationQueueProvider.overrideWith((ref) async => const []),
        mySuggestionsProvider.overrideWith((ref) async => const [_suggestion]),
      ],
    );
    addTearDown(container.dispose);

    final router = GoRouter(
      initialLocation: '/account',
      routes: [
        GoRoute(
          path: '/account',
          builder: (context, state) => const AccountScreen(),
        ),
        GoRoute(
          path: '/logbook',
          builder: (context, state) =>
              const Scaffold(key: Key('stub-logbook'), body: Text('Logbook')),
        ),
        GoRoute(
          path: '/suggestions',
          builder: (context, state) => const Scaffold(
            key: Key('stub-suggestions'),
            body: Text('Suggestions'),
          ),
        ),
        GoRoute(
          path: '/admin',
          builder: (context, state) =>
              const Scaffold(key: Key('stub-admin'), body: Text('Admin')),
        ),
      ],
    );
    addTearDown(router.dispose);

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
  }

  double topOf(WidgetTester tester, Key key) =>
      tester.getTopLeft(find.byKey(key)).dy;

  testWidgets(
    'A3: the Account card carries a labelled Logbook row, and tapping it '
    'reaches /logbook — Settings is where people hunt for "my stuff", and '
    'before this the Logbook had exactly one entry point in the whole app',
    (tester) async {
      await pumpAccount(tester);

      expect(find.byKey(logbookKey), findsOneWidget);
      expect(
        find.text('My logbook'),
        findsOneWidget,
        reason: 'labelled, not a bare icon — that was the original complaint',
      );

      await tester.tap(find.byKey(logbookKey));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('stub-logbook')), findsOneWidget);
      expect(find.byType(AccountScreen), findsNothing);
    },
  );

  testWidgets(
    'A4: all three navigation rows render ABOVE "Sign out", and "Sign out" is '
    'the last of them — they used to be appended below it, past the control '
    'that ends the session',
    (tester) async {
      await pumpAccount(tester);

      // Presence first, so a position assertion can never pass vacuously.
      for (final key in [logbookKey, suggestionsKey, adminKey, signOutKey]) {
        expect(find.byKey(key), findsOneWidget, reason: '$key must render');
      }

      final signOutY = topOf(tester, signOutKey);
      for (final key in [logbookKey, suggestionsKey, adminKey]) {
        expect(
          topOf(tester, key),
          lessThan(signOutY),
          reason:
              '$key must be laid out ABOVE account-sign-out '
              '(its y must be smaller), not appended under it',
        );
      }

      // And the intended reading order among the three themselves: the
      // Logbook — the one every user has — comes first, then the two
      // conditional inboxes.
      expect(topOf(tester, logbookKey), lessThan(topOf(tester, suggestionsKey)));
      expect(topOf(tester, suggestionsKey), lessThan(topOf(tester, adminKey)));
    },
  );

  testWidgets(
    'A5: the moved "Suggested edits" row still reaches /suggestions — the '
    'reorder must change position only, never behaviour',
    (tester) async {
      await pumpAccount(tester);

      expect(find.textContaining('Suggested edits'), findsOneWidget);

      await tester.tap(find.byKey(suggestionsKey));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('stub-suggestions')), findsOneWidget);
      expect(find.byType(AccountScreen), findsNothing);
    },
  );

  testWidgets(
    'A5: the moved "Review queue" row still reaches /admin',
    (tester) async {
      await pumpAccount(tester);

      expect(find.textContaining('Review queue'), findsOneWidget);

      await tester.tap(find.byKey(adminKey));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('stub-admin')), findsOneWidget);
      expect(find.byType(AccountScreen), findsNothing);
    },
  );
}
