import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/features/community/data/likes_repository.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late LikesRepository repo;
  const wallId = 'wall-1';

  Future<void> seedWall(String id) async {
    const now = 1000;
    await db
        .into(db.areas)
        .insert(
          AreasCompanion.insert(
            id: 'area-$id',
            createdAt: now,
            updatedAt: now,
            name: 'Area for $id',
          ),
        );
    await db
        .into(db.sectors)
        .insert(
          SectorsCompanion.insert(
            id: 'sector-$id',
            createdAt: now,
            updatedAt: now,
            areaId: 'area-$id',
            name: 'Sector for $id',
            sortOrder: 0,
          ),
        );
    await db
        .into(db.walls)
        .insert(
          WallsCompanion.insert(
            id: id,
            createdAt: now,
            updatedAt: now,
            sectorId: 'sector-$id',
            name: 'Wall $id',
            sortOrder: 0,
          ),
        );
  }

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    repo = LikesRepository(db, nowMs: () => 1000);
    await seedWall(wallId);
  });

  tearDown(() async {
    await db.close();
  });

  group('B2a: toggleLike idempotence per (owner, wall)', () {
    test(
      'like -> unlike -> like leaves exactly ONE active like (never two)',
      () async {
        final owned = LikesRepository(
          db,
          nowMs: () => 1000,
          currentUid: () => 'u1',
        );

        final liked1 = await owned.toggleLike(wallId);
        final unliked = await owned.toggleLike(wallId);
        final liked2 = await owned.toggleLike(wallId);

        expect(liked1, isTrue);
        expect(unliked, isFalse);
        expect(liked2, isTrue);

        final allRows = await db.select(db.likes).get();
        final activeRows = allRows.where((r) => r.deletedAt == null).toList();
        expect(
          allRows,
          hasLength(1),
          reason:
              'revive-in-place, not a second insert, for the same '
              '(owner, wall) pair',
        );
        expect(activeRows, hasLength(1));
        expect(activeRows.single.ownerId, 'u1');
        expect(activeRows.single.wallId, wallId);
        expect(activeRows.single.dirty, isTrue);
      },
    );

    test('toggling to unlike leaves zero active likes', () async {
      final owned = LikesRepository(
        db,
        nowMs: () => 1000,
        currentUid: () => 'u1',
      );

      await owned.toggleLike(wallId);
      final unliked = await owned.toggleLike(wallId);

      expect(unliked, isFalse);
      final activeRows = await (db.select(
        db.likes,
      )..where((t) => t.deletedAt.isNull())).get();
      expect(activeRows, isEmpty);

      final allRows = await db.select(db.likes).get();
      expect(allRows, hasLength(1), reason: 'the tombstone remains, not gone');
      expect(allRows.single.deletedAt, isNotNull);
    });

    test(
      'a signed-out uid (null) is treated as its own single local owner: '
      'like -> unlike -> like also converges to exactly one active row',
      () async {
        // repo (from setUp) uses the default currentUid (signed-out/null).
        final liked1 = await repo.toggleLike(wallId);
        final unliked = await repo.toggleLike(wallId);
        final liked2 = await repo.toggleLike(wallId);

        expect(liked1, isTrue);
        expect(unliked, isFalse);
        expect(liked2, isTrue);

        final allRows = await db.select(db.likes).get();
        final activeRows = allRows.where((r) => r.deletedAt == null).toList();
        expect(allRows, hasLength(1));
        expect(activeRows, hasLength(1));
        expect(activeRows.single.ownerId, isNull);
      },
    );
  });

  group(
    'B2a-race: concurrent toggleLike calls on the same pair are atomic',
    () {
      Expression<bool> ownerMatch($LikesTable t, String? ownerId) {
        return ownerId == null
            ? t.ownerId.isNull()
            : t.ownerId.equals(ownerId);
      }

      Future<List<Like>> rowsForPair(String? ownerId, String forWallId) {
        return (db.select(db.likes)..where(
              (t) => ownerMatch(t, ownerId) & t.wallId.equals(forWallId),
            ))
            .get();
      }

      /// After N concurrent toggles settle, the class invariant (at most
      /// one ACTIVE like per pair) must hold, and the read-side helpers
      /// must agree with whichever state (liked or unliked) it settled to.
      Future<void> expectConsistentSettledState({
        required String? ownerId,
        required String forWallId,
        required LikesRepository ownerRepo,
      }) async {
        final rows = await rowsForPair(ownerId, forWallId);
        final activeRows = rows.where((r) => r.deletedAt == null).toList();
        expect(
          activeRows.length,
          lessThanOrEqualTo(1),
          reason:
              'race must never produce more than one ACTIVE like for the '
              'same (ownerId, wallId) pair',
        );

        final count = await ownerRepo.likeCountForWall(forWallId);
        final liked = await ownerRepo.hasLiked(forWallId);
        if (activeRows.isEmpty) {
          expect(count, 0);
          expect(liked, isFalse);
        } else {
          expect(count, 1);
          expect(liked, isTrue);
        }
      }

      test(
        '2 concurrent toggleLike calls on a fresh signed-in pair settle '
        'to a consistent (>=0, <=1 active) state',
        () async {
          final owned = LikesRepository(
            db,
            nowMs: () => 1000,
            currentUid: () => 'racer-2',
          );

          final futures = [owned.toggleLike(wallId), owned.toggleLike(wallId)];
          await Future.wait(futures);

          await expectConsistentSettledState(
            ownerId: 'racer-2',
            forWallId: wallId,
            ownerRepo: owned,
          );
        },
      );

      test(
        '3 concurrent toggleLike calls on a fresh signed-in pair settle '
        'to a consistent (>=0, <=1 active) state',
        () async {
          final owned = LikesRepository(
            db,
            nowMs: () => 1000,
            currentUid: () => 'racer-3',
          );

          final futures = [
            owned.toggleLike(wallId),
            owned.toggleLike(wallId),
            owned.toggleLike(wallId),
          ];
          await Future.wait(futures);

          await expectConsistentSettledState(
            ownerId: 'racer-3',
            forWallId: wallId,
            ownerRepo: owned,
          );
        },
      );

      test(
        '2 concurrent toggleLike calls for the signed-out (null) owner '
        'settle to a consistent (>=0, <=1 active) state',
        () async {
          // repo (from setUp) uses the default currentUid (signed-out/null).
          final futures = [repo.toggleLike(wallId), repo.toggleLike(wallId)];
          await Future.wait(futures);

          await expectConsistentSettledState(
            ownerId: null,
            forWallId: wallId,
            ownerRepo: repo,
          );
        },
      );

      test(
        '3 concurrent toggleLike calls for the signed-out (null) owner '
        'settle to a consistent (>=0, <=1 active) state',
        () async {
          final futures = [
            repo.toggleLike(wallId),
            repo.toggleLike(wallId),
            repo.toggleLike(wallId),
          ];
          await Future.wait(futures);

          await expectConsistentSettledState(
            ownerId: null,
            forWallId: wallId,
            ownerRepo: repo,
          );
        },
      );
    },
  );

  group('B2b: likeCountForWall counts distinct active likers', () {
    test(
      'counts likes from multiple distinct ownerIds on the same wall',
      () async {
        final u1 = LikesRepository(
          db,
          nowMs: () => 1000,
          currentUid: () => 'u1',
        );
        final u2 = LikesRepository(
          db,
          nowMs: () => 1000,
          currentUid: () => 'u2',
        );
        final u3 = LikesRepository(
          db,
          nowMs: () => 1000,
          currentUid: () => 'u3',
        );

        await u1.toggleLike(wallId);
        await u2.toggleLike(wallId);
        await u3.toggleLike(wallId);

        expect(await repo.likeCountForWall(wallId), 3);
      },
    );

    test('excludes a retracted (soft-deleted) like from the count', () async {
      final u1 = LikesRepository(db, nowMs: () => 1000, currentUid: () => 'u1');
      final u2 = LikesRepository(db, nowMs: () => 1000, currentUid: () => 'u2');

      await u1.toggleLike(wallId);
      await u2.toggleLike(wallId);
      expect(await repo.likeCountForWall(wallId), 2);

      await u1.toggleLike(wallId); // u1 unlikes
      expect(await repo.likeCountForWall(wallId), 1);
    });

    test('does not count likes on a different wall', () async {
      const otherWallId = 'wall-2';
      await seedWall(otherWallId);
      final u1 = LikesRepository(db, nowMs: () => 1000, currentUid: () => 'u1');
      final u2 = LikesRepository(db, nowMs: () => 1000, currentUid: () => 'u2');

      await u1.toggleLike(wallId);
      await u2.toggleLike(otherWallId);

      expect(await repo.likeCountForWall(wallId), 1);
      expect(await repo.likeCountForWall(otherWallId), 1);
    });

    test('watchLikeCountForWall emits the live active count', () async {
      final u1 = LikesRepository(db, nowMs: () => 1000, currentUid: () => 'u1');
      final u2 = LikesRepository(db, nowMs: () => 1000, currentUid: () => 'u2');

      final counts = <int>[];
      final sub = repo.watchLikeCountForWall(wallId).listen(counts.add);

      await pumpEventQueue();
      await u1.toggleLike(wallId);
      await pumpEventQueue();
      await u2.toggleLike(wallId);
      await pumpEventQueue();
      await u1.toggleLike(wallId); // u1 unlikes
      await pumpEventQueue();

      await sub.cancel();
      expect(counts, [0, 1, 2, 1]);
    });
  });

  group('B2c: hasLiked reflects the current uid\'s active-like state', () {
    test(
      'false before any like, true after toggleLike, false after unlike',
      () async {
        final owned = LikesRepository(
          db,
          nowMs: () => 1000,
          currentUid: () => 'u1',
        );

        expect(await owned.hasLiked(wallId), isFalse);

        await owned.toggleLike(wallId);
        expect(await owned.hasLiked(wallId), isTrue);

        await owned.toggleLike(wallId);
        expect(await owned.hasLiked(wallId), isFalse);
      },
    );

    test('is scoped per-owner: one uid liking a wall does not flip hasLiked '
        'for a different uid', () async {
      final u1 = LikesRepository(db, nowMs: () => 1000, currentUid: () => 'u1');
      final u2 = LikesRepository(db, nowMs: () => 1000, currentUid: () => 'u2');

      await u1.toggleLike(wallId);

      expect(await u1.hasLiked(wallId), isTrue);
      expect(await u2.hasLiked(wallId), isFalse);
    });

    test(
      'a signed-out (null) uid has its own independent hasLiked state',
      () async {
        final u1 = LikesRepository(
          db,
          nowMs: () => 1000,
          currentUid: () => 'u1',
        );

        await u1.toggleLike(wallId);

        expect(await u1.hasLiked(wallId), isTrue);
        // repo (default currentUid, signed-out/null) is a distinct owner.
        expect(await repo.hasLiked(wallId), isFalse);
      },
    );
  });
}
