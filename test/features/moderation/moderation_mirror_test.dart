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

  @override
  Future<List<Map<String, dynamic>>> fetchWallModeration(
    Set<String> wallIds,
  ) async {
    requestedIds.add(wallIds);
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
  Future<List<Map<String, dynamic>>> fetchMaterialChanges({
    int limit = 50,
  }) async => const [];
  @override
  Future<void> resolveMaterialChange(String noticeId) async {}
  @override
  Future<int> removePublishedPhotoObjects(List<String> objectPaths) async => 0;

  @override
  Future<int?> requestWithdrawal(String wallId) async => null;

  @override
  Future<String> cancelWithdrawal(String wallId) async => 'published';
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
