// The client-side half of the withdrawal cooldown (community editing phase 5
// / C-3), where the owner actually meets it: the topo row's action menu.
//
// The server is the enforcement layer and it works by REVERTING, not by
// raising — it has to, because `upsertOwnRows` batches per table with one
// try/catch around each, so a trigger that raised on one wall row would fail
// the whole `walls` push and the client would retry the same poisoned batch
// forever (COMMUNITY_IMPL.md §0.1).
//
// That design choice is exactly what makes these tests load-bearing. Without a
// client-side guard the owner taps Delete, watches it disappear from the list,
// and finds it back tomorrow with no error ever shown — the worst possible way
// to discover a rule exists. So what is asserted here is not "the topo
// survives" (Postgres guarantees that); it is that the app never offers an
// action it knows the server will undo, and offers the one that works instead.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/backup/application/sync_orchestrator.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/library/data/library_crud_repository.dart';
import 'package:masi/features/library/presentation/topos_screen.dart';
import 'package:masi/features/moderation/application/moderation_providers.dart';
import 'package:masi/features/moderation/data/moderation_remote.dart';

import '../../../support/async_drain.dart';

/// Answers the moderation reads and records the withdrawal calls, so a test
/// can assert which RPC the menu actually reached for.
class _FakeRemote implements ModerationRemote {
  _FakeRemote({this.state = 'published', this.withdrawRequestedAt});

  final String state;
  final int? withdrawRequestedAt;

  final withdrawn = <String>[];
  final cancelled = <String>[];

  /// What `cancel_withdrawal` should answer. The server decides between
  /// `published` (cancelled in time) and `pending` (the window had elapsed, so
  /// this was a re-submission); the client must report whichever it is told.
  String cancelResult = 'published';

  @override
  Future<List<Map<String, dynamic>>> fetchWallModeration(
    Set<String> wallIds,
  ) async => [
    for (final id in wallIds)
      {
        'wallId': id,
        'state': state,
        'withdrawRequestedAt': withdrawRequestedAt,
        'updatedAt': 1,
      },
  ];

  @override
  Future<int?> requestWithdrawal(String wallId) async {
    withdrawn.add(wallId);
    return DateTime.now().millisecondsSinceEpoch;
  }

  @override
  Future<String> cancelWithdrawal(String wallId) async {
    cancelled.add(wallId);
    return cancelResult;
  }

  @override
  Future<bool> isAdmin() async => false;

  @override
  Future<List<Map<String, dynamic>>> fetchQueue({int limit = 50}) async =>
      const [];

  @override
  Future<String> reviewTopo({
    required String wallId,
    required bool approve,
    String? reason,
  }) async => 'published';

  @override
  Future<void> removeTopo({required String wallId, String? reason}) async {}
}

class _FakeSyncOrchestrator extends SyncOrchestrator {
  @override
  SyncOrchestratorState build() => const SyncOrchestratorState();

  @override
  Future<void> pullNow({bool throttled = false}) async {}
}

Widget _wrap(ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp.router(
    theme: MasiTheme.light,
    routerConfig: GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (context, state) => const ToposScreen()),
        GoRoute(
          path: '/walls/:wallId',
          builder: (context, state) => const SizedBox(),
        ),
      ],
    ),
  ),
);

/// Builds a published, shared topo and opens its action menu.
Future<({String wallId, _FakeRemote remote, ProviderContainer container})>
_openMenu(
  WidgetTester tester, {
  String state = 'published',
  int? withdrawRequestedAt,
}) async {
  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final repo = LibraryCrudRepository(db, nowMs: () => 1000);
  final remote = _FakeRemote(
    state: state,
    withdrawRequestedAt: withdrawRequestedAt,
  );
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      nowMsProvider.overrideWithValue(() => 1000),
      libraryCrudRepositoryProvider.overrideWithValue(repo),
      moderationRemoteProvider.overrideWithValue(remote),
      syncOrchestratorProvider.overrideWith(_FakeSyncOrchestrator.new),
      // `storageDurabilityProvider` is deliberately NOT overridden: its
      // default `probing()` verdict counts as "allow creation" precisely so
      // widget tests, which never run `openConnection`, are not blocked by the
      // storage interlock.
    ],
  );
  addTearDown(container.dispose);

  late String wallId;
  await tester.runAsync(() async {
    wallId = await repo.createTopo('Dolomitici');
    // The topo has to be SHARED for any of this to apply — the guard is about
    // content other people can see.
    await repo.publishTopo(wallId);
  });

  await tester.pumpWidget(_wrap(container));
  await drainAsync(tester, rounds: 6, settle: false);
  await tester.pumpAndSettle();

  await tester.tap(find.byKey(Key('topo-menu-$wallId')));
  await tester.pumpAndSettle();

  return (wallId: wallId, remote: remote, container: container);
}

void main() {
  const tenDays = 864000000;

  group('a PUBLISHED topo', () {
    testWidgets(
      'offers Withdraw, never a bare Unpublish — the server would silently '
      'revert the latter and the owner would never learn why',
      (tester) async {
        final ctx = await _openMenu(tester);

        expect(find.text('Withdraw from Community…'), findsOne);
        expect(find.text('Unpublish'), findsNothing);
        expect(find.text('Stays visible for 10 days'), findsOne);

        expect(find.byKey(Key('topo-publish-${ctx.wallId}')), findsOne);
      },
    );

    testWidgets('Withdraw asks first, and says the topo stays visible', (
      tester,
    ) async {
      final ctx = await _openMenu(tester);

      await tester.tap(find.byKey(Key('topo-publish-${ctx.wallId}')));
      await tester.pumpAndSettle();

      expect(find.textContaining('stays visible for 10 more days'), findsOne);
      // The notice to everyone else is the reason the cooldown exists at all,
      // so the owner is told about it before they commit, not after.
      expect(find.textContaining('notice telling people'), findsOne);

      await tester.tap(find.byKey(Key('topo-withdraw-confirm-${ctx.wallId}')));
      await tester.pumpAndSettle();

      expect(ctx.remote.withdrawn, [ctx.wallId]);
    });

    testWidgets(
      'backing out of the confirm withdraws nothing — a mis-tap on a menu '
      'must not start a ten-day clock',
      (tester) async {
        final ctx = await _openMenu(tester);

        await tester.tap(find.byKey(Key('topo-publish-${ctx.wallId}')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel').last);
        await tester.pumpAndSettle();

        expect(ctx.remote.withdrawn, isEmpty);
      },
    );

    testWidgets(
      'DELETE is intercepted. Otherwise the cooldown is theatre: `deletedAt = '
      'now` achieves in one tap exactly what the ten days exist to slow down',
      (tester) async {
        final ctx = await _openMenu(tester);

        await tester.tap(find.byKey(Key('topo-delete-${ctx.wallId}')));
        await tester.pumpAndSettle();

        expect(find.text('Withdraw "Dolomitici" first'), findsOne);
        expect(
          find.byKey(Key('topo-delete-confirm-${ctx.wallId}')),
          findsNothing,
          reason: 'the ordinary delete confirm must not be reachable',
        );
      },
    );

    testWidgets(
      'the intercepted delete leads INTO the withdrawal, rather than being a '
      'dead end that just says no',
      (tester) async {
        final ctx = await _openMenu(tester);

        await tester.tap(find.byKey(Key('topo-delete-${ctx.wallId}')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('topo-delete-blocked-${ctx.wallId}')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('topo-withdraw-confirm-${ctx.wallId}')));
        await tester.pumpAndSettle();

        expect(ctx.remote.withdrawn, [ctx.wallId]);
      },
    );

    testWidgets('the badge reads Published', (tester) async {
      await _openMenu(tester);
      expect(find.text('Published'), findsOne);
    });
  });

  group('a topo already being withdrawn', () {
    Future<({String wallId, _FakeRemote remote, ProviderContainer container})>
    open(WidgetTester tester) => _openMenu(
      tester,
      withdrawRequestedAt:
          DateTime.now().millisecondsSinceEpoch - const Duration(days: 3).inMilliseconds,
    );

    testWidgets('offers Cancel, with the days left', (tester) async {
      final ctx = await open(tester);

      expect(find.text('Cancel withdrawal'), findsOne);
      expect(find.textContaining('Stops being public in 7 days'), findsOne);
      expect(find.text('Withdraw from Community…'), findsNothing);
      expect(ctx.remote.withdrawn, isEmpty);
    });

    testWidgets('Cancel calls the RPC and says the topo stayed public', (
      tester,
    ) async {
      final ctx = await open(tester);

      await tester.tap(find.byKey(Key('topo-cancel-withdraw-${ctx.wallId}')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(Key('topo-cancel-withdraw-confirm-${ctx.wallId}')),
      );
      await tester.pumpAndSettle();

      expect(ctx.remote.cancelled, [ctx.wallId]);
      expect(find.text('Still public — withdrawal cancelled'), findsOne);
    });

    testWidgets('the badge warns rather than claiming Published', (
      tester,
    ) async {
      await open(tester);
      expect(find.text('Withdrawing'), findsOne);
      expect(find.text('Published'), findsNothing);
    });

    testWidgets('delete is still intercepted while the window runs', (
      tester,
    ) async {
      final ctx = await open(tester);

      await tester.tap(find.byKey(Key('topo-delete-${ctx.wallId}')));
      await tester.pumpAndSettle();

      expect(find.text('Withdraw "Dolomitici" first'), findsOne);
    });
  });

  group('a topo whose window has closed', () {
    Future<({String wallId, _FakeRemote remote, ProviderContainer container})>
    open(WidgetTester tester) => _openMenu(
      tester,
      withdrawRequestedAt:
          DateTime.now().millisecondsSinceEpoch - tenDays - 60000,
    );

    testWidgets(
      'offers a way BACK. Without this the owner is stranded: the topo is '
      'still `shared` and still stored `published`, so nothing in the UI can '
      'express re-sharing something already shared',
      (tester) async {
        final ctx = await open(tester);

        expect(find.text('Submit for review again'), findsOne);
        expect(find.byKey(Key('topo-resubmit-${ctx.wallId}')), findsOne);
        expect(find.text('Withdrawn — not public'), findsOne);
      },
    );

    testWidgets(
      'coming back is honestly described as going through review again, not '
      'as flipping a switch',
      (tester) async {
        final ctx = await open(tester);
        ctx.remote.cancelResult = 'pending';

        await tester.tap(find.byKey(Key('topo-resubmit-${ctx.wallId}')));
        await tester.pumpAndSettle();
        expect(find.textContaining('goes back to a moderator'), findsOne);

        await tester.tap(
          find.byKey(Key('topo-cancel-withdraw-confirm-${ctx.wallId}')),
        );
        await tester.pumpAndSettle();

        expect(ctx.remote.cancelled, [ctx.wallId]);
        expect(find.text('Sent back for review'), findsOne);
      },
    );

    testWidgets(
      'delete is NO LONGER intercepted — the cooldown is a delay, not a '
      'permanent lock on the owner\'s own content',
      (tester) async {
        final ctx = await open(tester);

        await tester.tap(find.byKey(Key('topo-delete-${ctx.wallId}')));
        await tester.pumpAndSettle();

        expect(find.byKey(Key('topo-delete-confirm-${ctx.wallId}')), findsOne);
        expect(find.text('Withdraw "Dolomitici" first'), findsNothing);
      },
    );

    testWidgets('the badge reads Withdrawn', (tester) async {
      await open(tester);
      expect(find.text('Withdrawn'), findsOne);
    });
  });

  group('states with nothing to protect', () {
    testWidgets(
      'a PENDING topo unpublishes freely — nobody else can see it, so there '
      'is no one to warn',
      (tester) async {
        final ctx = await _openMenu(tester, state: 'pending');

        expect(find.text('Unpublish'), findsOne);
        expect(find.text('Withdraw from Community…'), findsNothing);

        await tester.tap(find.byKey(Key('topo-delete-${ctx.wallId}')));
        await tester.pumpAndSettle();
        expect(find.byKey(Key('topo-delete-confirm-${ctx.wallId}')), findsOne);
      },
    );

    testWidgets('a pending topo badges as In review, not Published', (
      tester,
    ) async {
      await _openMenu(tester, state: 'pending');
      expect(find.text('In review'), findsOne);
      expect(find.text('Published'), findsNothing);
    });

    testWidgets(
      'an UNKNOWN moderation state degrades to the pre-phase-5 menu rather '
      'than locking the owner out of their own topo on missing information',
      (tester) async {
        final ctx = await _openMenu(tester, state: 'wat');

        expect(find.text('Unpublish'), findsOne);
        await tester.tap(find.byKey(Key('topo-delete-${ctx.wallId}')));
        await tester.pumpAndSettle();
        expect(find.byKey(Key('topo-delete-confirm-${ctx.wallId}')), findsOne);
      },
    );
  });
}
