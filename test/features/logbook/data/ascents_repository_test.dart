import 'package:masi/core/db/app_database.dart' as db;
import 'package:masi/features/logbook/data/ascents_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// A seeded (wallId, routeId) pair satisfying the FK constraints on
/// `Ascents.wallId`/`Ascents.routeId` (this DB enforces
/// `PRAGMA foreign_keys = ON` — see `AppDatabase.beforeOpen`), via a minimal
/// Area -> Sector -> Wall -> Photo -> Route chain.
class _Seed {
  const _Seed(this.wallId, this.routeId);
  final String wallId;
  final String routeId;
}

void main() {
  late db.AppDatabase database;
  late AscentsRepository repo;

  /// Seeds a distinct Area/Sector/Wall/Photo/Route chain (ids suffixed with
  /// [n], which must be unique per call within a test) and returns the new
  /// wall/route ids for use as `logAscent(wallId:, routeId:)` arguments.
  Future<_Seed> seed(String n) async {
    final areaId = 'area-$n';
    final sectorId = 'sector-$n';
    final wallId = 'wall-$n';
    final photoId = 'photo-$n';
    final routeId = 'route-$n';
    await database
        .into(database.areas)
        .insert(
          db.AreasCompanion.insert(
            id: areaId,
            createdAt: 0,
            updatedAt: 0,
            name: 'Area $n',
          ),
        );
    await database
        .into(database.sectors)
        .insert(
          db.SectorsCompanion.insert(
            id: sectorId,
            createdAt: 0,
            updatedAt: 0,
            areaId: areaId,
            name: 'Sector $n',
            sortOrder: 0,
          ),
        );
    await database
        .into(database.walls)
        .insert(
          db.WallsCompanion.insert(
            id: wallId,
            createdAt: 0,
            updatedAt: 0,
            sectorId: sectorId,
            name: 'Wall $n',
            sortOrder: 0,
          ),
        );
    await database
        .into(database.photos)
        .insert(
          db.PhotosCompanion.insert(
            id: photoId,
            createdAt: 0,
            updatedAt: 0,
            wallId: wallId,
            localPath: '/tmp/$n.jpg',
            kind: 'original',
            width: 1,
            height: 1,
          ),
        );
    await database
        .into(database.routes)
        .insert(
          db.RoutesCompanion.insert(
            id: routeId,
            createdAt: 0,
            updatedAt: 0,
            wallId: wallId,
            photoId: photoId,
            number: 1,
            colorIndex: 0,
            pointsJson: '[]',
            symbolsJson: '[]',
            sortOrder: 0,
          ),
        );
    return _Seed(wallId, routeId);
  }

  setUp(() {
    database = db.AppDatabase(NativeDatabase.memory());
    repo = AscentsRepository(database, nowMs: () => 1000);
  });

  tearDown(() async {
    await database.close();
  });

  group('AscentStyle db round-trip', () {
    test('toDbString/fromDbString round-trips every value', () {
      for (final style in AscentStyle.values) {
        expect(AscentStyle.fromDbString(style.toDbString()), style);
      }
    });

    test('fromDbString throws on an unknown value', () {
      expect(() => AscentStyle.fromDbString('nonsense'), throwsArgumentError);
    });
  });

  group('B3a: logAscent', () {
    test(
      'persists a row with routeId/wallId/style (round-tripped)/climbedAt '
      'and ownerId stamped from the injected currentUid seam',
      () async {
        final s = await seed('1');
        final owned = AscentsRepository(
          database,
          nowMs: () => 1000,
          currentUid: () => 'u1',
        );
        final climbedAt = DateTime.utc(2026, 7, 1, 10, 30);

        final ascent = await owned.logAscent(
          routeId: s.routeId,
          wallId: s.wallId,
          climbedAt: climbedAt,
          style: AscentStyle.redpoint,
          notes: 'felt great',
          gradeOpinion: '7a soft',
        );

        expect(ascent.routeId, s.routeId);
        expect(ascent.wallId, s.wallId);
        expect(ascent.style, AscentStyle.redpoint);
        expect(ascent.climbedAt, climbedAt);
        expect(ascent.ownerId, 'u1');
        expect(ascent.notes, 'felt great');
        expect(ascent.gradeOpinion, '7a soft');
        expect(ascent.createdAt, 1000);
        expect(ascent.updatedAt, 1000);

        final row = await (database.select(
          database.ascents,
        )..where((t) => t.id.equals(ascent.id))).getSingle();
        expect(row.routeId, s.routeId);
        expect(row.wallId, s.wallId);
        expect(row.style, 'redpoint');
        expect(AscentStyle.fromDbString(row.style), AscentStyle.redpoint);
        expect(row.climbedAt, climbedAt.millisecondsSinceEpoch);
        expect(row.ownerId, 'u1');
        expect(row.notes, 'felt great');
        expect(row.gradeOpinion, '7a soft');
        expect(row.dirty, isTrue, reason: 'every write must mark dirty:true');
        expect(row.createdAt, 1000);
        expect(row.updatedAt, 1000);
        expect(row.deletedAt, isNull);
      },
    );

    test('default currentUid (signed-out) leaves ownerId null', () async {
      final s = await seed('1');

      final ascent = await repo.logAscent(
        routeId: s.routeId,
        wallId: s.wallId,
        climbedAt: DateTime.utc(2026, 1, 1),
        style: AscentStyle.onsight,
      );

      expect(ascent.ownerId, isNull);
      final row = await (database.select(
        database.ascents,
      )..where((t) => t.id.equals(ascent.id))).getSingle();
      expect(row.ownerId, isNull);
    });

    test(
      'defaults to visibility "private" and null authorName when omitted',
      () async {
        final s = await seed('1');

        final ascent = await repo.logAscent(
          routeId: s.routeId,
          wallId: s.wallId,
          climbedAt: DateTime.utc(2026, 1, 1),
          style: AscentStyle.onsight,
        );

        expect(ascent.visibility, 'private');
        expect(ascent.isShared, isFalse);
        expect(ascent.authorName, isNull);

        final row = await (database.select(
          database.ascents,
        )..where((t) => t.id.equals(ascent.id))).getSingle();
        expect(row.visibility, 'private');
        expect(row.authorName, isNull);
      },
    );

    test(
      'Feature #12: shared:true + authorName persist visibility="shared" '
      'and the given authorName',
      () async {
        final s = await seed('1');

        final ascent = await repo.logAscent(
          routeId: s.routeId,
          wallId: s.wallId,
          climbedAt: DateTime.utc(2026, 1, 1),
          style: AscentStyle.redpoint,
          shared: true,
          authorName: 'Alex Honnold',
        );

        expect(ascent.visibility, 'shared');
        expect(ascent.isShared, isTrue);
        expect(ascent.authorName, 'Alex Honnold');

        final row = await (database.select(
          database.ascents,
        )..where((t) => t.id.equals(ascent.id))).getSingle();
        expect(row.visibility, 'shared');
        expect(row.authorName, 'Alex Honnold');
      },
    );
  });

  group('B3b: logbook scoping + ordering', () {
    test(
      'returns own non-deleted ascents newest-climbedAt-first, excluding '
      'soft-deleted ones',
      () async {
        final s = await seed('1');
        final owned = AscentsRepository(
          database,
          nowMs: () => 1000,
          currentUid: () => 'u1',
        );

        final older = await owned.logAscent(
          routeId: s.routeId,
          wallId: s.wallId,
          climbedAt: DateTime.utc(2026, 1, 1),
          style: AscentStyle.onsight,
        );
        final newest = await owned.logAscent(
          routeId: s.routeId,
          wallId: s.wallId,
          climbedAt: DateTime.utc(2026, 6, 1),
          style: AscentStyle.flash,
        );
        final middle = await owned.logAscent(
          routeId: s.routeId,
          wallId: s.wallId,
          climbedAt: DateTime.utc(2026, 3, 1),
          style: AscentStyle.attempt,
        );
        final toDelete = await owned.logAscent(
          routeId: s.routeId,
          wallId: s.wallId,
          climbedAt: DateTime.utc(2026, 12, 1),
          style: AscentStyle.repeat,
        );
        await owned.softDeleteAscent(toDelete.id);

        final logbook = await owned.logbook();

        expect(logbook.map((a) => a.id).toList(), [
          newest.id,
          middle.id,
          older.id,
        ]);
      },
    );

    test(
      'excludes another user\'s ascents; a null currentUid seam scopes to '
      'the local unowned rows only',
      () async {
        final s = await seed('1');
        final userA = AscentsRepository(
          database,
          nowMs: () => 1000,
          currentUid: () => 'u1',
        );
        final userB = AscentsRepository(
          database,
          nowMs: () => 1000,
          currentUid: () => 'u2',
        );
        final signedOut = AscentsRepository(database, nowMs: () => 1000);

        final aAscent = await userA.logAscent(
          routeId: s.routeId,
          wallId: s.wallId,
          climbedAt: DateTime.utc(2026, 1, 1),
          style: AscentStyle.onsight,
        );
        final bAscent = await userB.logAscent(
          routeId: s.routeId,
          wallId: s.wallId,
          climbedAt: DateTime.utc(2026, 1, 2),
          style: AscentStyle.flash,
        );
        final unownedAscent = await signedOut.logAscent(
          routeId: s.routeId,
          wallId: s.wallId,
          climbedAt: DateTime.utc(2026, 1, 3),
          style: AscentStyle.attempt,
        );

        expect((await userA.logbook()).map((a) => a.id), [aAscent.id]);
        expect((await userB.logbook()).map((a) => a.id), [bAscent.id]);
        expect((await signedOut.logbook()).map((a) => a.id), [
          unownedAscent.id,
        ]);
      },
    );

    test('watchLogbook reacts to logAscent and softDeleteAscent', () async {
      final s = await seed('1');
      final owned = AscentsRepository(
        database,
        nowMs: () => 1000,
        currentUid: () => 'u1',
      );

      final emissions = <List<Ascent>>[];
      final sub = owned.watchLogbook().listen(emissions.add);
      await Future<void>.delayed(Duration.zero);
      expect(emissions.last, isEmpty);

      final ascent = await owned.logAscent(
        routeId: s.routeId,
        wallId: s.wallId,
        climbedAt: DateTime.utc(2026, 1, 1),
        style: AscentStyle.attempt,
      );
      await Future<void>.delayed(Duration.zero);
      expect(emissions.last.map((a) => a.id), [ascent.id]);

      await owned.softDeleteAscent(ascent.id);
      await Future<void>.delayed(Duration.zero);
      expect(emissions.last, isEmpty);

      await sub.cancel();
    });
  });

  group('B3c: updateAscent', () {
    test(
      'changes the targeted fields in place (same id) without creating a '
      'new row and without altering ownerId/createdAt',
      () async {
        final s = await seed('1');
        final owned = AscentsRepository(
          database,
          nowMs: () => 1000,
          currentUid: () => 'u1',
        );
        final ascent = await owned.logAscent(
          routeId: s.routeId,
          wallId: s.wallId,
          climbedAt: DateTime.utc(2026, 1, 1),
          style: AscentStyle.attempt,
          notes: 'first try',
        );

        final laterRepo = AscentsRepository(
          database,
          nowMs: () => 2000,
          currentUid: () => 'u1',
        );
        final updated = await laterRepo.updateAscent(
          id: ascent.id,
          style: AscentStyle.redpoint,
          notes: 'sent it clean',
        );

        expect(updated.id, ascent.id);
        expect(updated.style, AscentStyle.redpoint);
        expect(updated.notes, 'sent it clean');
        expect(updated.ownerId, 'u1');
        expect(updated.createdAt, 1000);
        expect(updated.updatedAt, 2000);

        final allRows = await database.select(database.ascents).get();
        expect(
          allRows,
          hasLength(1),
          reason: 'updateAscent must not create a new row',
        );

        final row = allRows.single;
        expect(row.id, ascent.id);
        expect(row.style, 'redpoint');
        expect(row.notes, 'sent it clean');
        expect(row.ownerId, 'u1', reason: 'ownerId must never change');
        expect(row.createdAt, 1000, reason: 'createdAt must never change');
        expect(row.dirty, isTrue);
      },
    );

    test('fields omitted (null) are left unchanged', () async {
      final s = await seed('1');
      final owned = AscentsRepository(
        database,
        nowMs: () => 1000,
        currentUid: () => 'u1',
      );
      final ascent = await owned.logAscent(
        routeId: s.routeId,
        wallId: s.wallId,
        climbedAt: DateTime.utc(2026, 1, 1),
        style: AscentStyle.attempt,
        notes: 'first try',
        gradeOpinion: '6a',
      );

      final updated = await owned.updateAscent(
        id: ascent.id,
        notes: 'updated note',
      );

      expect(updated.style, AscentStyle.attempt);
      expect(updated.gradeOpinion, '6a');
      expect(updated.climbedAt, ascent.climbedAt);
      expect(updated.notes, 'updated note');
    });

    test(
      'Feature #12: shared/authorName follow the same omit-to-leave-'
      'unchanged convention as the other optional fields',
      () async {
        final s = await seed('1');
        final owned = AscentsRepository(
          database,
          nowMs: () => 1000,
          currentUid: () => 'u1',
        );
        final ascent = await owned.logAscent(
          routeId: s.routeId,
          wallId: s.wallId,
          climbedAt: DateTime.utc(2026, 1, 1),
          style: AscentStyle.attempt,
        );
        expect(ascent.visibility, 'private');

        final laterRepo = AscentsRepository(
          database,
          nowMs: () => 2000,
          currentUid: () => 'u1',
        );
        final updated = await laterRepo.updateAscent(
          id: ascent.id,
          shared: true,
          authorName: 'Lynn Hill',
        );

        expect(updated.visibility, 'shared');
        expect(updated.isShared, isTrue);
        expect(updated.authorName, 'Lynn Hill');

        // Omitting both on a later update leaves them unchanged.
        final unchanged = await laterRepo.updateAscent(
          id: ascent.id,
          notes: 'unrelated edit',
        );
        expect(unchanged.visibility, 'shared');
        expect(unchanged.authorName, 'Lynn Hill');
      },
    );
  });

  group('setAscentVisibility', () {
    test(
      'flips private -> shared -> private, bumping updatedAt and marking '
      'dirty each time, without touching ownerId/createdAt',
      () async {
        final s = await seed('1');
        final owned = AscentsRepository(
          database,
          nowMs: () => 1000,
          currentUid: () => 'u1',
        );
        final ascent = await owned.logAscent(
          routeId: s.routeId,
          wallId: s.wallId,
          climbedAt: DateTime.utc(2026, 1, 1),
          style: AscentStyle.onsight,
        );
        expect(ascent.visibility, 'private');

        final laterRepo = AscentsRepository(
          database,
          nowMs: () => 2000,
          currentUid: () => 'u1',
        );
        await laterRepo.setAscentVisibility(id: ascent.id, shared: true);

        var row = await (database.select(
          database.ascents,
        )..where((t) => t.id.equals(ascent.id))).getSingle();
        expect(row.visibility, 'shared');
        expect(row.updatedAt, 2000);
        expect(row.dirty, isTrue);
        expect(row.ownerId, 'u1');
        expect(row.createdAt, 1000);

        final evenLaterRepo = AscentsRepository(
          database,
          nowMs: () => 3000,
          currentUid: () => 'u1',
        );
        await evenLaterRepo.setAscentVisibility(id: ascent.id, shared: false);

        row = await (database.select(
          database.ascents,
        )..where((t) => t.id.equals(ascent.id))).getSingle();
        expect(row.visibility, 'private');
        expect(row.updatedAt, 3000);
      },
    );

    test('is a no-op on a soft-deleted ascent (matches updateAscent)', () async {
      final s = await seed('1');
      final owned = AscentsRepository(
        database,
        nowMs: () => 1000,
        currentUid: () => 'u1',
      );
      final ascent = await owned.logAscent(
        routeId: s.routeId,
        wallId: s.wallId,
        climbedAt: DateTime.utc(2026, 1, 1),
        style: AscentStyle.onsight,
      );
      await owned.softDeleteAscent(ascent.id);

      await owned.setAscentVisibility(id: ascent.id, shared: true);

      final row = await (database.select(
        database.ascents,
      )..where((t) => t.id.equals(ascent.id))).getSingle();
      expect(row.visibility, 'private', reason: 'deleted rows are not mutated');
    });
  });

  group('Feature #12: watchSharedAscents / sharedAscents (cross-owner feed)', () {
    test(
      'returns ONLY shared ascents, across every owner, excluding private '
      'and soft-deleted rows',
      () async {
        final s = await seed('1');
        final userA = AscentsRepository(
          database,
          nowMs: () => 1000,
          currentUid: () => 'user-a',
        );
        final userB = AscentsRepository(
          database,
          nowMs: () => 1000,
          currentUid: () => 'user-b',
        );

        // A: private — must NOT appear in the feed.
        final aPrivate = await userA.logAscent(
          routeId: s.routeId,
          wallId: s.wallId,
          climbedAt: DateTime.utc(2026, 1, 1),
          style: AscentStyle.onsight,
        );
        // B: shared — MUST appear.
        final bShared = await userB.logAscent(
          routeId: s.routeId,
          wallId: s.wallId,
          climbedAt: DateTime.utc(2026, 2, 1),
          style: AscentStyle.redpoint,
          shared: true,
          authorName: 'User B',
        );
        // A: shared but later soft-deleted — must NOT appear.
        final aSharedDeleted = await userA.logAscent(
          routeId: s.routeId,
          wallId: s.wallId,
          climbedAt: DateTime.utc(2026, 3, 1),
          style: AscentStyle.flash,
          shared: true,
        );
        await userA.softDeleteAscent(aSharedDeleted.id);

        final feed = await userA.sharedAscents();

        expect(feed.map((e) => e.ascentId).toList(), [bShared.id]);
        expect(feed.single.ownerId, 'user-b');
        expect(feed.single.authorName, 'User B');
        expect(feed.single.wallId, s.wallId);
        expect(feed.single.wallName, 'Wall 1');
        expect(feed.single.style, AscentStyle.redpoint);
        expect(feed.single.routeNumber, 1);

        // Sanity: neither excluded ascent leaked through.
        expect(
          feed.map((e) => e.ascentId),
          isNot(contains(aPrivate.id)),
        );
        expect(
          feed.map((e) => e.ascentId),
          isNot(contains(aSharedDeleted.id)),
        );
      },
    );

    test(
      'newest climbedAt first across owners, and watchSharedAscents reacts '
      'to a later setAscentVisibility flip',
      () async {
        final s = await seed('1');
        final userA = AscentsRepository(
          database,
          nowMs: () => 1000,
          currentUid: () => 'user-a',
        );
        final userB = AscentsRepository(
          database,
          nowMs: () => 1000,
          currentUid: () => 'user-b',
        );

        final older = await userA.logAscent(
          routeId: s.routeId,
          wallId: s.wallId,
          climbedAt: DateTime.utc(2026, 1, 1),
          style: AscentStyle.onsight,
          shared: true,
        );
        final newer = await userB.logAscent(
          routeId: s.routeId,
          wallId: s.wallId,
          climbedAt: DateTime.utc(2026, 6, 1),
          style: AscentStyle.flash,
          shared: true,
        );
        // Starts private; not yet in the feed.
        final flipped = await userA.logAscent(
          routeId: s.routeId,
          wallId: s.wallId,
          climbedAt: DateTime.utc(2026, 3, 1),
          style: AscentStyle.attempt,
        );

        final emissions = <List<SharedAscentEntry>>[];
        final sub = userA.watchSharedAscents().listen(emissions.add);
        await Future<void>.delayed(Duration.zero);
        expect(emissions.last.map((e) => e.ascentId).toList(), [
          newer.id,
          older.id,
        ]);

        await userA.setAscentVisibility(id: flipped.id, shared: true);
        await Future<void>.delayed(Duration.zero);
        expect(emissions.last.map((e) => e.ascentId).toList(), [
          newer.id,
          flipped.id,
          older.id,
        ]);

        await sub.cancel();
      },
    );
  });

  group('ascentsForRoute', () {
    test(
      'scopes to routeId + own + non-deleted, newest climbedAt first',
      () async {
        final s1 = await seed('1');
        final s2 = await seed('2');
        final owned = AscentsRepository(
          database,
          nowMs: () => 1000,
          currentUid: () => 'u1',
        );
        final other = AscentsRepository(
          database,
          nowMs: () => 1000,
          currentUid: () => 'u2',
        );

        final r1Older = await owned.logAscent(
          routeId: s1.routeId,
          wallId: s1.wallId,
          climbedAt: DateTime.utc(2026, 1, 1),
          style: AscentStyle.attempt,
        );
        final r1Newer = await owned.logAscent(
          routeId: s1.routeId,
          wallId: s1.wallId,
          climbedAt: DateTime.utc(2026, 2, 1),
          style: AscentStyle.redpoint,
        );
        await owned.logAscent(
          routeId: s2.routeId,
          wallId: s2.wallId,
          climbedAt: DateTime.utc(2026, 3, 1),
          style: AscentStyle.flash,
        );
        await other.logAscent(
          routeId: s1.routeId,
          wallId: s1.wallId,
          climbedAt: DateTime.utc(2026, 4, 1),
          style: AscentStyle.onsight,
        );
        final r1Deleted = await owned.logAscent(
          routeId: s1.routeId,
          wallId: s1.wallId,
          climbedAt: DateTime.utc(2026, 5, 1),
          style: AscentStyle.repeat,
        );
        await owned.softDeleteAscent(r1Deleted.id);

        final ascents = await owned.ascentsForRoute(s1.routeId);

        expect(ascents.map((a) => a.id).toList(), [r1Newer.id, r1Older.id]);
      },
    );
  });

  group('softDeleteAscent', () {
    test(
      'sets deletedAt/updatedAt and marks dirty; row remains physically '
      'present (tombstone, not a hard delete)',
      () async {
        final s = await seed('1');
        final owned = AscentsRepository(
          database,
          nowMs: () => 1000,
          currentUid: () => 'u1',
        );
        final ascent = await owned.logAscent(
          routeId: s.routeId,
          wallId: s.wallId,
          climbedAt: DateTime.utc(2026, 1, 1),
          style: AscentStyle.attempt,
        );

        final laterRepo = AscentsRepository(
          database,
          nowMs: () => 2000,
          currentUid: () => 'u1',
        );
        await laterRepo.softDeleteAscent(ascent.id);

        final row = await (database.select(
          database.ascents,
        )..where((t) => t.id.equals(ascent.id))).getSingle();
        expect(row.deletedAt, 2000);
        expect(row.updatedAt, 2000);
        expect(row.dirty, isTrue);

        final allRows = await database.select(database.ascents).get();
        expect(
          allRows,
          hasLength(1),
          reason: 'soft delete must not physically remove the row',
        );
      },
    );
  });
}
