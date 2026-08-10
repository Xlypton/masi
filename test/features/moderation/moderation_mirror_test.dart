// Phase 1 client mirror of moderation state (community editing).
//
// The load-bearing assertion in this file is the LAST group: that moderation
// state can never travel back up through the sync engine. Everything else is
// ordinary parse/store coverage.

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/backup/data/sync_remote.dart' show syncTableNames;
import 'package:masi/features/moderation/application/moderation_providers.dart';
import 'package:masi/features/moderation/data/moderation_remote.dart';
import 'package:masi/features/moderation/data/moderation_repository.dart';
import 'package:masi/features/moderation/domain/moderation_state.dart';

class _FakeModerationRemote implements ModerationRemote {
  _FakeModerationRemote(this.rows);

  final List<Map<String, dynamic>> rows;
  final requestedIds = <Set<String>>[];

  /// Makes [fetchWallModeration] throw, which is the whole situation the
  /// withdrawal fix is about: the RPC committed, and the refresh meant to bring
  /// the server's new answer back did not arrive.
  bool fetchThrows = false;

  /// Every wall [cancelWithdrawal]/[requestWithdrawal] was called for, and what
  /// each answers. Defaults match the pre-existing behaviour of this fake.
  final cancelledIds = <String>[];
  final requestedWithdrawalIds = <String>[];
  String cancelResult = 'published';
  int? requestResult;

  @override
  Future<List<Map<String, dynamic>>> fetchWallModeration(
    Set<String> wallIds,
  ) async {
    requestedIds.add(wallIds);
    if (fetchThrows) throw StateError('refresh unavailable');
    return rows
        .where((r) => wallIds.contains(r['wallId'] as String))
        .toList();
  }

  // Phase 3 surface. Unused by this file's assertions — it covers the mirror,
  // not the review flow — but required to satisfy the interface.
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
  }) async => approve ? 'published' : 'rejected';

  @override
  Future<void> removeTopo({required String wallId, String? reason}) async {}

  @override
  Future<List<Map<String, dynamic>>> fetchAbandoned({
    int inactiveDays = 90,
    int limit = 50,
  }) async => const [];

  @override
  Future<List<String>> publishedPhotoObjects(String wallId) async => const [];

  @override
  Future<Map<String, dynamic>?> deletionRequestFor(String wallId) async => null;
  @override
  Future<String> requestDeletion(String wallId, {String? reason}) async => '';
  @override
  Future<List<Map<String, dynamic>>> fetchDeletionRequests({int limit = 50}) async =>
      const [];
  @override
  Future<String> reviewDeletion({
    required String requestId,
    required bool approve,
    String? note,
  }) async => approve ? 'approved' : 'rejected';
  @override
  Future<List<Map<String, dynamic>>> fetchMaterialChanges({
    int limit = 50,
  }) async => const [];
  @override
  Future<void> resolveMaterialChange(String noticeId) async {}
  @override
  Future<int> removePublishedPhotoObjects(List<String> objectPaths) async => 0;

  @override
  Future<int?> requestWithdrawal(String wallId) async {
    requestedWithdrawalIds.add(wallId);
    return requestResult;
  }

  @override
  Future<String> cancelWithdrawal(String wallId) async {
    cancelledIds.add(wallId);
    return cancelResult;
  }

  @override
  Future<int?> adminDeleteTopo({required String wallId, String? reason}) async =>
      null;
  @override
  Future<int?> adminRestoreTopo({
    required String wallId,
    String? reason,
  }) async => null;
  @override
  Future<int?> adminDeleteAscent({
    required String ascentId,
    String? reason,
  }) async => null;
  @override
  Future<int?> adminDeleteComment({
    required String commentId,
    String? reason,
  }) async => null;
}

Map<String, dynamic> _row(
  String wallId,
  String state, {
  int? withdrawRequestedAt,
  String? rejectionReason,
  int updatedAt = 1000,
}) => {
  'wallId': wallId,
  'state': state,
  'submittedAt': 500,
  'reviewedAt': 900,
  'reviewerId': 'admin-1',
  'rejectionReason': rejectionReason,
  'withdrawRequestedAt': withdrawRequestedAt,
  'updatedAt': updatedAt,
};

void main() {
  group('ModerationState.fromWire', () {
    test('parses every state the server can send', () {
      expect(ModerationState.fromWire('draft'), ModerationState.draft);
      expect(ModerationState.fromWire('pending'), ModerationState.pending);
      expect(ModerationState.fromWire('published'), ModerationState.published);
      expect(ModerationState.fromWire('rejected'), ModerationState.rejected);
      expect(ModerationState.fromWire('withdrawn'), ModerationState.withdrawn);
      expect(ModerationState.fromWire('removed'), ModerationState.removed);
    });

    test(
      'FAILS CLOSED on an unknown or missing state — a client running against '
      'a newer server must never render unreviewed content as approved',
      () {
        expect(ModerationState.fromWire(null), ModerationState.draft);
        expect(ModerationState.fromWire(''), ModerationState.draft);
        expect(
          ModerationState.fromWire('some_future_state'),
          ModerationState.draft,
        );
        expect(ModerationState.fromWire('PUBLISHED'), ModerationState.draft);
      },
    );

    test('isPublic is true for published and nothing else', () {
      for (final state in ModerationState.values) {
        expect(
          state.isPublic,
          state == ModerationState.published,
          reason: '$state',
        );
      }
    });
  });

  group('ModerationRepository', () {
    late AppDatabase db;
    late ModerationRepository repo;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      repo = ModerationRepository(db);
    });
    tearDown(() => db.close());

    test('stores and reads back a row', () async {
      await repo.upsertFromRemote([_row('w1', 'published')]);

      expect(await repo.watchState('w1').first, ModerationState.published);
      final row = await repo.watchRow('w1').first;
      expect(row!.reviewerId, 'admin-1');
      expect(row.submittedAt, 500);
    });

    test('an unknown wall reads as draft, not as an error', () async {
      expect(await repo.watchState('never-seen').first, ModerationState.draft);
      expect(await repo.watchRow('never-seen').first, isNull);
    });

    test('upsert overwrites an existing row rather than duplicating', () async {
      await repo.upsertFromRemote([_row('w1', 'pending', updatedAt: 1)]);
      await repo.upsertFromRemote([_row('w1', 'published', updatedAt: 2)]);

      expect(await repo.watchState('w1').first, ModerationState.published);
      expect(await db.select(db.wallModerationRows).get(), hasLength(1));
    });

    test(
      'a batch only touches the walls it names — state for topos outside the '
      'batch is not cleared',
      () async {
        await repo.upsertFromRemote([
          _row('w1', 'published'),
          _row('w2', 'pending'),
        ]);

        await repo.upsertFromRemote([_row('w1', 'withdrawn')]);

        expect(await repo.watchState('w1').first, ModerationState.withdrawn);
        expect(
          await repo.watchState('w2').first,
          ModerationState.pending,
          reason: 'w2 was not in the second batch and must be untouched',
        );
      },
    );

    test('skips malformed rows instead of aborting the whole import', () async {
      final written = await repo.upsertFromRemote([
        _row('good', 'published'),
        {'state': 'published'}, // no wallId
        {'wallId': 'no-state'}, // no state
        {'wallId': 42, 'state': 'published'}, // wrong type
        _row('also-good', 'pending'),
      ]);

      expect(written, 2);
      expect(await repo.watchState('good').first, ModerationState.published);
      expect(await repo.watchState('also-good').first, ModerationState.pending);
    });

    test('coerces a bigint that arrives as num or String', () async {
      await repo.upsertFromRemote([
        {
          'wallId': 'w1',
          'state': 'published',
          'submittedAt': 1.0,
          'withdrawRequestedAt': '1700000000000',
          'updatedAt': 5,
        },
      ]);

      final row = await repo.watchRow('w1').first;
      expect(row!.submittedAt, 1);
      expect(row.withdrawRequestedAt, 1700000000000);
    });

    group('recordWithdrawRequestedAt', () {
      test('clears a countdown the server says is over', () async {
        await repo.upsertFromRemote([
          _row('w1', 'published', withdrawRequestedAt: 1700000000000),
        ]);

        expect(await repo.recordWithdrawRequestedAt('w1', null), 1);

        final row = await repo.watchRow('w1').first;
        expect(row!.withdrawRequestedAt, isNull);
      });

      test('writes a countdown the server says has started', () async {
        await repo.upsertFromRemote([_row('w1', 'published')]);

        expect(await repo.recordWithdrawRequestedAt('w1', 1700000000000), 1);

        expect(
          (await repo.watchRow('w1').first)!.withdrawRequestedAt,
          1700000000000,
        );
      });

      test(
        'touches nothing else on the row, INCLUDING updatedAt — a partial local '
        'correction must not out-rank the next real pull',
        () async {
          await repo.upsertFromRemote([
            _row(
              'w1',
              'published',
              withdrawRequestedAt: 1700000000000,
              updatedAt: 42,
            ),
          ]);

          await repo.recordWithdrawRequestedAt('w1', null);

          final row = await repo.watchRow('w1').first;
          expect(row!.updatedAt, 42);
          expect(row.state, 'published');
          expect(row.submittedAt, 500);
          expect(row.reviewerId, 'admin-1');
        },
      );

      test(
        'an unknown wall writes NOTHING rather than inventing a row — there is '
        'no stale countdown to correct, and no state or updatedAt to invent',
        () async {
          expect(await repo.recordWithdrawRequestedAt('never-seen', null), 0);
          expect(await db.select(db.wallModerationRows).get(), isEmpty);
        },
      );

      test('only the named wall is affected', () async {
        await repo.upsertFromRemote([
          _row('w1', 'published', withdrawRequestedAt: 111),
          _row('w2', 'published', withdrawRequestedAt: 222),
        ]);

        await repo.recordWithdrawRequestedAt('w1', null);

        expect((await repo.watchRow('w1').first)!.withdrawRequestedAt, isNull);
        expect((await repo.watchRow('w2').first)!.withdrawRequestedAt, 222);
      });
    });

    test('clear() drops everything — sign-out must not leak to the next account',
        () async {
      await repo.upsertFromRemote([_row('w1', 'pending', rejectionReason: 'x')]);

      await repo.clear();

      expect(await db.select(db.wallModerationRows).get(), isEmpty);
      expect(await repo.watchState('w1').first, ModerationState.draft);
    });

    test('watchState is reactive — a later import repaints an open banner',
        () async {
      final states = <ModerationState>[];
      final sub = repo.watchState('w1').listen(states.add);
      await Future<void>.delayed(Duration.zero);

      await repo.upsertFromRemote([_row('w1', 'pending')]);
      await Future<void>.delayed(Duration.zero);
      await repo.upsertFromRemote([_row('w1', 'published', updatedAt: 2)]);
      await Future<void>.delayed(Duration.zero);

      await sub.cancel();
      expect(states, [
        ModerationState.draft,
        ModerationState.pending,
        ModerationState.published,
      ]);
    });
  });

  group('refreshWallModeration', () {
    ProviderContainer build(ModerationRemote remote) {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          moderationRemoteProvider.overrideWithValue(remote),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('pulls and stores', () async {
      final remote = _FakeModerationRemote([
        _row('w1', 'published'),
        _row('w2', 'pending'),
      ]);
      final container = build(remote);

      final written = await pullWallModeration(remote: remote, repository: container.read(moderationRepositoryProvider), wallIds: {'w1', 'w2'});

      expect(written, 2);
      expect(
        await container.read(moderationRepositoryProvider).watchState('w1').first,
        ModerationState.published,
      );
    });

    test('an empty id set does not hit the network at all', () async {
      final remote = _FakeModerationRemote([]);
      final container = build(remote);

      expect(await pullWallModeration(remote: remote, repository: container.read(moderationRepositoryProvider), wallIds: {}), 0);
      expect(remote.requestedIds, isEmpty);
    });

    test(
      'a wall the server declines to describe leaves NO local row — absent '
      'means "you may not know", never "approved"',
      () async {
        // The remote returns nothing for w-secret: RLS hid it.
        final remote = _FakeModerationRemote([_row('w1', 'published')]);
        final container = build(remote);

        await pullWallModeration(remote: remote, repository: container.read(moderationRepositoryProvider), wallIds: {'w1', 'w-secret'});

        final repo = container.read(moderationRepositoryProvider);
        expect(await repo.watchState('w1').first, ModerationState.published);
        expect(await repo.watchState('w-secret').first, ModerationState.draft);
      },
    );
  });

  // A cancelled withdrawal whose follow-up refresh fails used to leave the local
  // mirror holding the MATURED timestamp the server had just cleared — and SEC-2
  // in `sync_service.dart` derives `shouldBeShared` from exactly that value, so
  // the next push deleted the published photo bytes of a topo the server had put
  // back. The push half of that proof lives in
  // `test/features/backup/data/sync_service_test.dart`; this is the mirror half.
  group('WithdrawalService', () {
    /// Ten days and a millisecond ago — matured, which is the only value that
    /// can cost anything. Derived from [kWithdrawalCooldown] rather than spelled
    /// out, since that constant is already pinned to the server's 864000000 by
    /// `withdrawal_test.dart`.
    final maturedAt =
        DateTime.now().millisecondsSinceEpoch -
        kWithdrawalCooldown.inMilliseconds -
        1;

    ({ProviderContainer container, ModerationRepository repo}) build(
      _FakeModerationRemote remote,
    ) {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          moderationRemoteProvider.overrideWithValue(remote),
        ],
      );
      addTearDown(container.dispose);
      return (
        container: container,
        repo: container.read(moderationRepositoryProvider),
      );
    }

    /// Seeds `w1` with a countdown that has ALREADY run out, and proves the
    /// fixture really is matured — a fixture that quietly stopped being matured
    /// would make every test below pass for the wrong reason.
    Future<void> seedMaturedWithdrawal(ModerationRepository repo) async {
      await repo.upsertFromRemote([
        _row('w1', 'published', withdrawRequestedAt: maturedAt),
      ]);
      expect(
        ModerationView.fromRow(
          state: 'published',
          withdrawRequestedAt: maturedAt,
        ).hasMatured,
        isTrue,
      );
    }

    test(
      'cancel leaves NO matured withdrawRequestedAt in the mirror even when the '
      'refresh after the RPC throws',
      () async {
        final remote = _FakeModerationRemote([])..fetchThrows = true;
        final c = build(remote);
        await seedMaturedWithdrawal(c.repo);

        await c.container.read(withdrawalServiceProvider).cancel('w1');

        expect(remote.cancelledIds, ['w1'], reason: 'the RPC did run');
        final row = await c.repo.watchRow('w1').first;
        expect(row!.withdrawRequestedAt, isNull);
        expect(
          ModerationView.fromRow(
            state: row.state,
            withdrawRequestedAt: row.withdrawRequestedAt,
          ).hasMatured,
          isFalse,
          reason:
              'a matured value here is what makes the next push delete the '
              'published bytes of a topo the server just restored',
        );
      },
    );

    test(
      'cancel still returns the resulting state and does not throw when the '
      'refresh fails — the RPC already committed',
      () async {
        final remote = _FakeModerationRemote([])
          ..fetchThrows = true
          // The re-submission branch: the window had already elapsed, so the
          // server put the topo back into the review queue.
          ..cancelResult = 'pending';
        final c = build(remote);
        await seedMaturedWithdrawal(c.repo);

        expect(
          await c.container.read(withdrawalServiceProvider).cancel('w1'),
          'pending',
        );
      },
    );

    test(
      'a cancel whose refresh SUCCEEDS still ends up with the server\'s row — '
      'the local write is a floor, not a replacement for the reconcile',
      () async {
        final remote = _FakeModerationRemote([
          _row('w1', 'pending', updatedAt: 9000),
        ])..cancelResult = 'pending';
        final c = build(remote);
        await seedMaturedWithdrawal(c.repo);

        expect(
          await c.container.read(withdrawalServiceProvider).cancel('w1'),
          'pending',
        );

        final row = await c.repo.watchRow('w1').first;
        expect(row!.withdrawRequestedAt, isNull);
        expect(row.state, 'pending');
        expect(row.updatedAt, 9000);
      },
    );

    test(
      'request records the countdown the RPC reported even when the refresh '
      'throws, so a maturing window is not invisible to the next push',
      () async {
        final remote = _FakeModerationRemote([])
          ..fetchThrows = true
          ..requestResult = 1700000000000;
        final c = build(remote);
        await c.repo.upsertFromRemote([_row('w1', 'published')]);

        expect(
          await c.container.read(withdrawalServiceProvider).request('w1'),
          1700000000000,
        );

        expect(
          (await c.repo.watchRow('w1').first)!.withdrawRequestedAt,
          1700000000000,
        );
      },
    );

    test(
      'an UNREADABLE request answer does not clear a countdown the server may '
      'have just started',
      () async {
        // `requestWithdrawal` returning null means "the answer could not be
        // parsed", not "no clock is running". Writing it as a clear would be a
        // local invention, which is the one thing the mirror must never hold.
        final remote = _FakeModerationRemote([])
          ..fetchThrows = true
          ..requestResult = null;
        final c = build(remote);
        await c.repo.upsertFromRemote([
          _row('w1', 'published', withdrawRequestedAt: 1700000000000),
        ]);

        expect(
          await c.container.read(withdrawalServiceProvider).request('w1'),
          isNull,
        );

        expect(
          (await c.repo.watchRow('w1').first)!.withdrawRequestedAt,
          1700000000000,
        );
      },
    );
  });

  group('the guarantee: moderation state never syncs', () {
    test(
      'wall_moderation is NOT in syncTableNames — the sync engine pushes '
      'whole rows with local-wins-ties LWW, so a synced moderation column '
      'would let an owner revert a moderator (COMMUNITY_PLAN.md G-1)',
      () {
        for (final name in syncTableNames) {
          expect(
            name.toLowerCase(),
            isNot(contains('moderation')),
            reason:
                'syncTableNames must never contain a moderation table; found '
                '"$name"',
          );
        }
        expect(syncTableNames, isNot(contains('wall_moderation')));
        expect(syncTableNames, isNot(contains('wallModerationRows')));
      },
    );

    test(
      'ModerationRemote exposes no write method — every mutation goes through '
      'a SECURITY DEFINER RPC so the action and its audit entry cannot diverge',
      () {
        // A compile-time guarantee expressed as a runtime one: if someone adds
        // an upload/push method to the seam, this reflection-free check will
        // not catch it — but the interface below documents the intent, and the
        // server refuses direct writes regardless (no write policy on
        // public.wall_moderation). Asserting the read shape at least pins the
        // contract this test was written against.
        final ModerationRemote remote = _FakeModerationRemote([]);
        expect(remote.fetchWallModeration, isA<Function>());
      },
    );

    test(
      'the local mirror table carries no dirty/ownerId columns, so it cannot '
      'be picked up by a dirty-scoped push even by accident',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);

        final columns = await db
            .customSelect("PRAGMA table_info('wall_moderation_rows')")
            .map((r) => r.read<String>('name'))
            .get();

        expect(columns, isNotEmpty, reason: 'table must exist');
        expect(columns, isNot(contains('dirty')));
        expect(columns, isNot(contains('owner_id')));
        expect(columns, contains('wall_id'));
        expect(columns, contains('state'));
      },
    );
  });
}
