import 'package:masi/core/db/app_database.dart';
import 'package:masi/features/backup/data/backup_repository.dart';
// `hide isNotNull, isNull`: drift's query-builder helpers of the same names
// collide with `package:matcher`'s (via flutter_test) `isNotNull`/`isNull`
// MATCHERS used throughout this file's `expect(...)` calls — this file only
// needs the latter.
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late BackupRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = BackupRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  /// Seeds one Area/Sector/Wall, an original Photo + a slice Photo (self-FK
  /// via parentPhotoId), a Route, AND a soft-deleted second Area (tombstone)
  /// so exports/imports are exercised against a non-trivial, realistic
  /// hierarchy.
  Future<void> seed(AppDatabase db) async {
    await db.into(db.areas).insert(
      AreasCompanion.insert(
        id: 'area-1',
        createdAt: 100,
        updatedAt: 100,
        name: 'Area One',
      ),
    );
    await db.into(db.areas).insert(
      AreasCompanion.insert(
        id: 'area-2-deleted',
        createdAt: 100,
        updatedAt: 150,
        deletedAt: const Value(200),
        name: 'Deleted Area',
      ),
    );
    await db.into(db.sectors).insert(
      SectorsCompanion.insert(
        id: 'sector-1',
        createdAt: 100,
        updatedAt: 100,
        areaId: 'area-1',
        name: 'Sector One',
        sortOrder: 0,
      ),
    );
    await db.into(db.walls).insert(
      WallsCompanion.insert(
        id: 'wall-1',
        createdAt: 100,
        updatedAt: 100,
        sectorId: 'sector-1',
        name: 'Wall One',
        sortOrder: 0,
      ),
    );
    await db.into(db.photos).insert(
      PhotosCompanion.insert(
        id: 'photo-original',
        createdAt: 100,
        updatedAt: 100,
        wallId: 'wall-1',
        localPath: '/tmp/original.jpg',
        kind: 'original',
        width: 800,
        height: 600,
      ),
    );
    await db.into(db.photos).insert(
      PhotosCompanion.insert(
        id: 'photo-slice',
        createdAt: 100,
        updatedAt: 100,
        wallId: 'wall-1',
        localPath: '/tmp/original.jpg',
        kind: 'slice',
        width: 400,
        height: 300,
        parentPhotoId: const Value('photo-original'),
      ),
    );
    await db.into(db.routes).insert(
      RoutesCompanion.insert(
        id: 'route-1',
        createdAt: 100,
        updatedAt: 100,
        wallId: 'wall-1',
        photoId: 'photo-original',
        number: 1,
        colorIndex: 0,
        pointsJson: '[]',
        symbolsJson: '[]',
        sortOrder: 0,
      ),
    );
  }

  /// Deletes every row from every table, in reverse-FK order, so the DB is
  /// empty but the (open) connection + FK pragma survive.
  Future<void> wipe(AppDatabase db) async {
    await db.delete(db.routes).go();
    await db.delete(db.photos).go();
    await db.delete(db.walls).go();
    await db.delete(db.sectors).go();
    await db.delete(db.areas).go();
  }

  test(
    'S3-a: export -> wipe -> replace-import reproduces every row '
    'byte-for-byte, including the soft-deleted tombstone',
    () async {
      await seed(db);

      final originalAreas = await db.select(db.areas).get();
      final originalSectors = await db.select(db.sectors).get();
      final originalWalls = await db.select(db.walls).get();
      final originalPhotos = await db.select(db.photos).get();
      final originalRoutes = await db.select(db.routes).get();

      final snapshot = await repo.exportSnapshot();

      await wipe(db);
      expect(await db.select(db.areas).get(), isEmpty);

      await repo.importSnapshot(snapshot, mode: ConflictMode.replace);

      final restoredAreas = await db.select(db.areas).get();
      final restoredSectors = await db.select(db.sectors).get();
      final restoredWalls = await db.select(db.walls).get();
      final restoredPhotos = await db.select(db.photos).get();
      final restoredRoutes = await db.select(db.routes).get();

      expect(
        {for (final a in restoredAreas) a.id: a},
        {for (final a in originalAreas) a.id: a},
      );
      expect(
        {for (final s in restoredSectors) s.id: s},
        {for (final s in originalSectors) s.id: s},
      );
      expect(
        {for (final w in restoredWalls) w.id: w},
        {for (final w in originalWalls) w.id: w},
      );
      expect(
        {for (final p in restoredPhotos) p.id: p},
        {for (final p in originalPhotos) p.id: p},
      );
      expect(
        {for (final r in restoredRoutes) r.id: r},
        {for (final r in originalRoutes) r.id: r},
      );

      // Explicitly assert the tombstone survived the round trip.
      final restoredDeletedArea = restoredAreas.firstWhere(
        (a) => a.id == 'area-2-deleted',
      );
      expect(restoredDeletedArea.deletedAt, 200);
    },
  );

  test('S3-b: importing the same snapshot twice is idempotent', () async {
    await seed(db);
    final snapshot = await repo.exportSnapshot();

    await wipe(db);
    await repo.importSnapshot(snapshot, mode: ConflictMode.replace);
    final afterFirst = await repo.exportSnapshot();

    await repo.importSnapshot(snapshot, mode: ConflictMode.replace);
    final afterSecond = await repo.exportSnapshot();

    expect(afterSecond, afterFirst);

    final areas = await db.select(db.areas).get();
    final photos = await db.select(db.photos).get();
    expect(areas, hasLength(2));
    expect(photos, hasLength(2));
  });

  test(
    'S3-c: import succeeds under FK enforcement even when a slice Photo '
    'appears BEFORE its original in the snapshot array',
    () async {
      final snapshot = {
        'schemaVersion': 1,
        'tables': {
          'areas': [
            {
              'id': 'area-1',
              'createdAt': 100,
              'updatedAt': 100,
              'deletedAt': null,
              'remoteId': null,
              'dirty': false,
              'name': 'Area One',
              'description': null,
              'latitude': null,
              'longitude': null,
            },
          ],
          'sectors': [
            {
              'id': 'sector-1',
              'createdAt': 100,
              'updatedAt': 100,
              'deletedAt': null,
              'remoteId': null,
              'dirty': false,
              'areaId': 'area-1',
              'name': 'Sector One',
              'sortOrder': 0,
            },
          ],
          'walls': [
            {
              'id': 'wall-1',
              'createdAt': 100,
              'updatedAt': 100,
              'deletedAt': null,
              'remoteId': null,
              'dirty': false,
              'sectorId': 'sector-1',
              'name': 'Wall One',
              'sortOrder': 0,
            },
          ],
          // Deliberately reversed: slice (has parentPhotoId) listed first,
          // original second. A naive in-order import would violate the
          // Photos self-FK under `PRAGMA foreign_keys = ON`.
          'photos': [
            {
              'id': 'photo-slice',
              'createdAt': 100,
              'updatedAt': 100,
              'deletedAt': null,
              'remoteId': null,
              'dirty': false,
              'wallId': 'wall-1',
              'localPath': '/tmp/original.jpg',
              'kind': 'slice',
              'width': 400,
              'height': 300,
              'parentPhotoId': 'photo-original',
              'cropXpct': null,
              'cropWidthPct': null,
            },
            {
              'id': 'photo-original',
              'createdAt': 100,
              'updatedAt': 100,
              'deletedAt': null,
              'remoteId': null,
              'dirty': false,
              'wallId': 'wall-1',
              'localPath': '/tmp/original.jpg',
              'kind': 'original',
              'width': 800,
              'height': 600,
              'parentPhotoId': null,
              'cropXpct': null,
              'cropWidthPct': null,
            },
          ],
          'routes': <Map<String, dynamic>>[],
        },
      };

      // Must not throw an SqliteException (FK violation).
      await repo.importSnapshot(snapshot, mode: ConflictMode.replace);

      final photos = await db.select(db.photos).get();
      expect(photos, hasLength(2));
      final slice = photos.firstWhere((p) => p.id == 'photo-slice');
      expect(slice.parentPhotoId, 'photo-original');
    },
  );

  group('S5: profiles (#18, editable synced display name)', () {
    test(
      'export -> wipe -> replace-import round-trips a profiles row '
      'byte-for-byte, alongside the rest of the hierarchy',
      () async {
        await seed(db);
        await db.into(db.profiles).insert(
          ProfilesCompanion.insert(
            id: 'user-1',
            createdAt: 100,
            updatedAt: 100,
            ownerId: const Value('user-1'),
            displayName: const Value('Alex'),
          ),
        );

        final snapshot = await repo.exportSnapshot();
        expect(
          (snapshot['tables'] as Map)['profiles'],
          isNotNull,
          reason: 'exportSnapshot must include a profiles key',
        );

        await wipe(db);
        await db.delete(db.profiles).go();
        expect(await db.select(db.profiles).get(), isEmpty);

        await repo.importSnapshot(snapshot, mode: ConflictMode.replace);

        final profile = await (db.select(
          db.profiles,
        )..where((t) => t.id.equals('user-1'))).getSingle();
        expect(profile.displayName, 'Alex');
        expect(profile.ownerId, 'user-1');
      },
    );

    test(
      'lww: a local profile row with a NEWER updatedAt survives an older '
      'incoming import; an incoming row with no local counterpart is '
      'inserted',
      () async {
        await db.into(db.profiles).insert(
          ProfilesCompanion.insert(
            id: 'user-1',
            createdAt: 100,
            updatedAt: 500,
            displayName: const Value('Local (newer)'),
          ),
        );

        final incoming = {
          'schemaVersion': 1,
          'tables': {
            'profiles': [
              {
                'id': 'user-1',
                'createdAt': 100,
                'updatedAt': 100, // older than local's 500
                'deletedAt': null,
                'remoteId': null,
                'dirty': false,
                'ownerId': 'user-1',
                'displayName': 'Incoming (older)',
              },
              {
                'id': 'user-2',
                'createdAt': 100,
                'updatedAt': 100,
                'deletedAt': null,
                'remoteId': null,
                'dirty': false,
                'ownerId': 'user-2',
                'displayName': 'Brand new',
              },
            ],
            'areas': <Map<String, dynamic>>[],
            'sectors': <Map<String, dynamic>>[],
            'walls': <Map<String, dynamic>>[],
            'photos': <Map<String, dynamic>>[],
            'routes': <Map<String, dynamic>>[],
          },
        };

        await repo.importSnapshot(incoming, mode: ConflictMode.lww);

        final user1 = await (db.select(
          db.profiles,
        )..where((t) => t.id.equals('user-1'))).getSingle();
        expect(user1.displayName, 'Local (newer)');

        final user2 = await (db.select(
          db.profiles,
        )..where((t) => t.id.equals('user-2'))).getSingle();
        expect(user2.displayName, 'Brand new');
      },
    );
  });

  group('S3-d: lww conflict mode', () {
    test('a local row with a NEWER updatedAt is preserved', () async {
      await db.into(db.areas).insert(
        AreasCompanion.insert(
          id: 'area-1',
          createdAt: 100,
          updatedAt: 500,
          name: 'Local (newer)',
        ),
      );

      final incoming = {
        'schemaVersion': 1,
        'tables': {
          'areas': [
            {
              'id': 'area-1',
              'createdAt': 100,
              'updatedAt': 100, // older than local's 500
              'deletedAt': null,
              'remoteId': null,
              'dirty': false,
              'name': 'Incoming (older)',
              'description': null,
              'latitude': null,
              'longitude': null,
            },
          ],
          'sectors': <Map<String, dynamic>>[],
          'walls': <Map<String, dynamic>>[],
          'photos': <Map<String, dynamic>>[],
          'routes': <Map<String, dynamic>>[],
        },
      };

      await repo.importSnapshot(incoming, mode: ConflictMode.lww);

      final area = await (db.select(
        db.areas,
      )..where((t) => t.id.equals('area-1'))).getSingle();
      expect(area.name, 'Local (newer)');
      expect(area.updatedAt, 500);
    });

    test('a local row with an OLDER updatedAt is overwritten', () async {
      await db.into(db.areas).insert(
        AreasCompanion.insert(
          id: 'area-1',
          createdAt: 100,
          updatedAt: 100,
          name: 'Local (older)',
        ),
      );

      final incoming = {
        'schemaVersion': 1,
        'tables': {
          'areas': [
            {
              'id': 'area-1',
              'createdAt': 100,
              'updatedAt': 500, // newer than local's 100
              'deletedAt': null,
              'remoteId': null,
              'dirty': false,
              'name': 'Incoming (newer)',
              'description': null,
              'latitude': null,
              'longitude': null,
            },
          ],
          'sectors': <Map<String, dynamic>>[],
          'walls': <Map<String, dynamic>>[],
          'photos': <Map<String, dynamic>>[],
          'routes': <Map<String, dynamic>>[],
        },
      };

      await repo.importSnapshot(incoming, mode: ConflictMode.lww);

      final area = await (db.select(
        db.areas,
      )..where((t) => t.id.equals('area-1'))).getSingle();
      expect(area.name, 'Incoming (newer)');
      expect(area.updatedAt, 500);
    });

    test(
      'a row with no local counterpart yet is inserted (new locally)',
      () async {
        final incoming = {
          'schemaVersion': 1,
          'tables': {
            'areas': [
              {
                'id': 'area-brand-new',
                'createdAt': 100,
                'updatedAt': 100,
                'deletedAt': null,
                'remoteId': null,
                'dirty': false,
                'name': 'Brand new',
                'description': null,
                'latitude': null,
                'longitude': null,
              },
            ],
            'sectors': <Map<String, dynamic>>[],
            'walls': <Map<String, dynamic>>[],
            'photos': <Map<String, dynamic>>[],
            'routes': <Map<String, dynamic>>[],
          },
        };

        await repo.importSnapshot(incoming, mode: ConflictMode.lww);

        final area = await (db.select(
          db.areas,
        )..where((t) => t.id.equals('area-brand-new'))).getSingle();
        expect(area.name, 'Brand new');
      },
    );
  });

  group('sync bookkeeping: imported rows are never locally dirty (S9)', () {
    test(
      'a row whose incoming payload says dirty:true is imported dirty:false '
      '-- a pulled row is by definition NOT a local change awaiting push',
      () async {
        await repo.importSnapshot({
          'tables': {
            'areas': [
              {
                'id': 'area-cloud',
                'createdAt': 100,
                'updatedAt': 100,
                'name': 'Cloud Area',
                'dirty': true,
                'ownerId': 'u1',
              },
            ],
          },
        });

        final row = await (db.select(
          db.areas,
        )..where((t) => t.id.equals('area-cloud'))).getSingle();
        expect(row.dirty, isFalse);
      },
    );

    test(
      'a row payload with NO dirty key at all still decodes (this is the '
      'shape a cloud row comes back in once the push strips dirty/remoteId)',
      () async {
        await repo.importSnapshot({
          'tables': {
            'areas': [
              {
                'id': 'area-stripped',
                'createdAt': 100,
                'updatedAt': 100,
                'name': 'Stripped Area',
                'ownerId': 'u1',
              },
            ],
          },
        });

        final row = await (db.select(
          db.areas,
        )..where((t) => t.id.equals('area-stripped'))).getSingle();
        expect(row.dirty, isFalse);
        expect(row.remoteId, isNull);
      },
    );
  });

  /// The live sync failure this group exists for, verbatim off a device:
  ///
  ///     Couldn't sync — Sync failed: own rows import failed: Bad state:
  ///     importSnapshot: 3 table(s) failed: ascents: SqliteException(787):
  ///     FOREIGN KEY constraint failed
  ///
  /// Root cause: `SyncRemote.fetchOwnRows` is scoped `ownerId = uid`, so the
  /// signed-in user's own batch contains their Ascents/Comments/Likes made on
  /// ANOTHER owner's shared topo but CANNOT contain the parent Wall/Route,
  /// which belongs to that other owner and arrives with the shared batch (which
  /// imports afterwards). Inserting the child unconditionally violated
  /// `PRAGMA foreign_keys = ON` and — because each table imports in its own
  /// transaction — took the WHOLE table down, so the user also lost their
  /// ascents/comments/likes on their OWN topos. Three tables, every time:
  /// ascents, comments, likes.
  ///
  /// Confirmed against the live (dev) Supabase: `ascents`, `comments` and
  /// `likes` rows all exist whose owner differs from their parent wall/route's
  /// owner, including two whose parents are additionally soft-deleted.
  group('FK orphans: a child whose parent is absent is DEFERRED, not a 787 '
      'that loses its whole table', () {
    /// A second Area→Sector→Wall→Photo→Route hierarchy standing in for ANOTHER
    /// owner's shared topo — the rows `fetchOwnRows` structurally cannot
    /// return.
    Future<void> seedForeign(AppDatabase db) async {
      await db.into(db.areas).insert(
        AreasCompanion.insert(
          id: 'area-f',
          createdAt: 100,
          updatedAt: 100,
          ownerId: const Value('other-owner'),
          name: 'Foreign Area',
        ),
      );
      await db.into(db.sectors).insert(
        SectorsCompanion.insert(
          id: 'sector-f',
          createdAt: 100,
          updatedAt: 100,
          ownerId: const Value('other-owner'),
          areaId: 'area-f',
          name: 'Foreign Sector',
          sortOrder: 0,
        ),
      );
      await db.into(db.walls).insert(
        WallsCompanion.insert(
          id: 'wall-f',
          createdAt: 100,
          updatedAt: 100,
          ownerId: const Value('other-owner'),
          sectorId: 'sector-f',
          name: 'Foreign Wall',
          sortOrder: 0,
          visibility: const Value('shared'),
        ),
      );
      await db.into(db.photos).insert(
        PhotosCompanion.insert(
          id: 'photo-f',
          createdAt: 100,
          updatedAt: 100,
          ownerId: const Value('other-owner'),
          wallId: 'wall-f',
          localPath: '/tmp/foreign.jpg',
          kind: 'original',
          width: 800,
          height: 600,
        ),
      );
      await db.into(db.routes).insert(
        RoutesCompanion.insert(
          id: 'route-f',
          createdAt: 100,
          updatedAt: 100,
          ownerId: const Value('other-owner'),
          wallId: 'wall-f',
          photoId: 'photo-f',
          number: 1,
          colorIndex: 0,
          pointsJson: '[]',
          symbolsJson: '[]',
          sortOrder: 0,
        ),
      );
    }

    /// The signed-in user's own community rows: one of each on their OWN topo
    /// (must always come back) and one of each on the FOREIGN topo (the rows
    /// that used to detonate the table).
    Future<void> seedOwnChildren(AppDatabase db) async {
      Future<void> ascent(String id, String routeId, String wallId) =>
          db.into(db.ascents).insert(
            AscentsCompanion.insert(
              id: id,
              createdAt: 100,
              updatedAt: 100,
              ownerId: const Value('me'),
              routeId: routeId,
              wallId: wallId,
              climbedAt: 100,
              style: 'redpoint',
            ),
          );
      await ascent('ascent-own', 'route-1', 'wall-1');
      await ascent('ascent-foreign', 'route-f', 'wall-f');

      Future<void> comment(String id, {String? wallId, String? ascentId}) =>
          db.into(db.comments).insert(
            CommentsCompanion.insert(
              id: id,
              createdAt: 100,
              updatedAt: 100,
              ownerId: const Value('me'),
              wallId: Value(wallId),
              ascentId: Value(ascentId),
              body: 'nice line',
            ),
          );
      await comment('comment-own', wallId: 'wall-1');
      await comment('comment-on-own-ascent', ascentId: 'ascent-own');
      await comment('comment-foreign', wallId: 'wall-f');

      Future<void> like(String id, {String? wallId, String? ascentId}) =>
          db.into(db.likes).insert(
            LikesCompanion.insert(
              id: id,
              createdAt: 100,
              updatedAt: 100,
              ownerId: const Value('me'),
              wallId: Value(wallId),
              ascentId: Value(ascentId),
            ),
          );
      await like('like-own', wallId: 'wall-1');
      await like('like-foreign', wallId: 'wall-f');
    }

    /// Every table, reverse-FK order — so the DB is genuinely empty (the fresh
    /// install / logged-back-in case) but the connection + FK pragma survive.
    Future<void> wipeAll(AppDatabase db) async {
      await db.delete(db.likes).go();
      await db.delete(db.comments).go();
      await db.delete(db.ascents).go();
      await db.delete(db.routes).go();
      await db.delete(db.photos).go();
      await db.delete(db.walls).go();
      await db.delete(db.sectors).go();
      await db.delete(db.areas).go();
    }

    /// Drops every `-f` (foreign-owner) row from [snapshot]'s parent tables,
    /// leaving exactly the shape `fetchOwnRows(uid)` returns: the user's own
    /// rows, INCLUDING their children on the foreign topo, but none of that
    /// topo's parent rows.
    Map<String, dynamic> ownOnly(Map<String, dynamic> snapshot) {
      final tables = (snapshot['tables'] as Map).cast<String, dynamic>();
      for (final table in const ['areas', 'sectors', 'walls', 'photos', 'routes']) {
        tables[table] = [
          for (final row in (tables[table] as List).cast<Map<String, dynamic>>())
            if (!(row['id'] as String).endsWith('-f')) row,
        ];
      }
      return {'tables': tables};
    }

    /// export → strip the foreign parents → wipe → import, i.e. exactly one
    /// own-rows pull into an empty database.
    Future<ImportReport> pullOwnOnly() async {
      await seed(db);
      await seedForeign(db);
      await seedOwnChildren(db);
      final snapshot = ownOnly(await repo.exportSnapshot());
      await wipeAll(db);
      return repo.importSnapshot(snapshot, mode: ConflictMode.lww);
    }

    test(
      'the own-rows pull no longer throws, and every own-topo ascent/comment/'
      'like still lands — the three orphans are reported, not dropped',
      () async {
        final report = await pullOwnOnly();

        // Pre-fix this line threw:
        //   Bad state: importSnapshot: 3 table(s) failed: ascents: ... 787
        expect(report.hasDeferrals, isTrue);
        expect(
          report.deferred.map((d) => '${d.table}/${d.id}/${d.column}'),
          unorderedEquals(const [
            'ascents/ascent-foreign/routeId',
            'comments/comment-foreign/wallId',
            'likes/like-foreign/wallId',
          ]),
          reason: 'all THREE live-failing tables must be covered',
        );
        expect(
          report.deferred.singleWhere((d) => d.table == 'ascents').missingParentId,
          'route-f',
        );

        // The whole point: the rows on the user's OWN topo survived.
        expect(
          (await db.select(db.ascents).get()).map((a) => a.id),
          ['ascent-own'],
        );
        expect(
          (await db.select(db.comments).get()).map((c) => c.id),
          unorderedEquals(['comment-own', 'comment-on-own-ascent']),
        );
        expect((await db.select(db.likes).get()).map((l) => l.id), ['like-own']);
      },
    );

    test(
      'the deferred rows are handed back verbatim and import cleanly once the '
      "other owner's parents arrive (the shared batch) — nothing is lost",
      () async {
        final report = await pullOwnOnly();

        // The shared batch lands the other owner's topo...
        await seedForeign(db);

        // ...and the SAME rows, re-imported through the same door, land.
        final retry = await repo.importSnapshot(
          {'tables': report.deferredRows},
          mode: ConflictMode.lww,
        );

        expect(retry.hasDeferrals, isFalse, reason: retry.summary);
        expect(
          (await db.select(db.ascents).get()).map((a) => a.id),
          unorderedEquals(['ascent-own', 'ascent-foreign']),
        );
        expect(
          (await db.select(db.comments).get()).map((c) => c.id),
          unorderedEquals([
            'comment-own',
            'comment-on-own-ascent',
            'comment-foreign',
          ]),
        );
        expect(
          (await db.select(db.likes).get()).map((l) => l.id),
          unorderedEquals(['like-own', 'like-foreign']),
        );
      },
    );

    test(
      'a comment/like pointing at a missing ASCENT (not wall) is deferred too '
      '-- Feature #12 added that second FK',
      () async {
        await seed(db);

        final report = await repo.importSnapshot({
          'tables': {
            'comments': [
              {
                'id': 'comment-orphan-ascent',
                'createdAt': 100,
                'updatedAt': 100,
                'deletedAt': null,
                'remoteId': null,
                'dirty': false,
                'ownerId': 'me',
                'wallId': null,
                'ascentId': 'ascent-gone',
                'body': 'orphan',
                'authorName': null,
              },
            ],
            'likes': [
              {
                'id': 'like-orphan-ascent',
                'createdAt': 100,
                'updatedAt': 100,
                'deletedAt': null,
                'remoteId': null,
                'dirty': false,
                'ownerId': 'me',
                'wallId': null,
                'ascentId': 'ascent-gone',
              },
            ],
          },
        }, mode: ConflictMode.lww);

        expect(
          report.deferred.map((d) => '${d.table}/${d.column}'),
          unorderedEquals(const ['comments/ascentId', 'likes/ascentId']),
        );
        expect(await db.select(db.comments).get(), isEmpty);
        expect(await db.select(db.likes).get(), isEmpty);
      },
    );

    test(
      'a TOMBSTONED parent is still a parent: a child of a soft-deleted wall '
      'imports normally and is NOT deferred',
      () async {
        await seed(db);
        // Soft-delete the wall the way the app does (tombstone, row stays).
        await (db.update(db.walls)..where((t) => t.id.equals('wall-1'))).write(
          WallsCompanion(deletedAt: const Value(999), updatedAt: const Value(999)),
        );

        final report = await repo.importSnapshot({
          'tables': {
            'likes': [
              {
                'id': 'like-on-tombstoned-wall',
                'createdAt': 100,
                'updatedAt': 100,
                'deletedAt': null,
                'remoteId': null,
                'dirty': false,
                'ownerId': 'me',
                'wallId': 'wall-1',
                'ascentId': null,
              },
            ],
          },
        }, mode: ConflictMode.lww);

        expect(report.hasDeferrals, isFalse, reason: report.summary);
        expect((await db.select(db.likes).get()).single.wallId, 'wall-1');
      },
    );

    test(
      'the guard is not ascents-only: a sector whose area is missing is '
      'deferred while every other sector in the same batch still imports',
      () async {
        await seed(db);

        Map<String, dynamic> sectorRow(String id, String areaId) => {
          'id': id,
          'createdAt': 100,
          'updatedAt': 100,
          'deletedAt': null,
          'remoteId': null,
          'dirty': false,
          'ownerId': 'me',
          'areaId': areaId,
          'name': 'Sector $id',
          'sortOrder': 0,
        };

        final report = await repo.importSnapshot({
          'tables': {
            'sectors': [
              sectorRow('sector-good', 'area-1'),
              sectorRow('sector-orphan', 'area-gone'),
            ],
          },
        }, mode: ConflictMode.lww);

        expect(
          report.deferred.map((d) => d.id),
          ['sector-orphan'],
          reason: 'one orphan must not roll back the whole sectors table',
        );
        expect(
          (await db.select(db.sectors).get()).map((s) => s.id),
          unorderedEquals(['sector-1', 'sector-good']),
        );
      },
    );
  });

  /// The restore-path half of the schema-downgrade hazard already closed for
  /// the local database by `SchemaDowngradeException`
  /// (`lib/core/db/schema_downgrade.dart`): there, an older shell opened a
  /// newer database; here, an older shell imports a snapshot exported by a
  /// newer one. [importSnapshot] is the choke point every restore funnels
  /// through, so the guard lives here and covers any caller — present or
  /// future — that hands it a version-stamped snapshot.
  group('schema downgrade: importSnapshot refuses a too-new snapshot', () {
    /// One Area row, in whatever shape the test's snapshot claims. Its
    /// presence (or absence) in the DB afterwards is the real assertion:
    /// a refusal that still wrote rows would make the exception message's
    /// "Nothing has been changed or deleted" a lie.
    Map<String, dynamic> areaRow(String id) => {
      'id': id,
      'createdAt': 100,
      'updatedAt': 100,
      'name': 'Area $id',
      'ownerId': 'u1',
    };

    test(
      'a snapshot stamped NEWER than AppDatabase.schemaVersion throws '
      'SnapshotSchemaDowngradeException and imports no rows at all',
      () async {
        final tooNew = db.schemaVersion + 1;

        await expectLater(
          repo.importSnapshot({
            'schemaVersion': tooNew,
            'tables': {
              'areas': [areaRow('area-from-the-future')],
            },
          }, mode: ConflictMode.replace),
          throwsA(isA<SnapshotSchemaDowngradeException>()),
        );

        // Total refusal: the guard must run BEFORE the first transaction,
        // not table-by-table. Without it this row imports cleanly (drift's
        // generated fromJson ignores keys it does not know), which is
        // exactly the silent lossy restore being prevented.
        expect(
          await db.select(db.areas).get(),
          isEmpty,
          reason: 'a refused restore must leave the local database untouched',
        );
      },
    );

    test(
      'the exception reports both versions and keeps the local-database '
      "guard's wording, so one hazard has one explanation",
      () async {
        final tooNew = db.schemaVersion + 3;

        Object? thrown;
        try {
          await repo.importSnapshot({
            'schemaVersion': tooNew,
            'tables': <String, dynamic>{},
          });
        } catch (e) {
          thrown = e;
        }

        expect(thrown, isA<SnapshotSchemaDowngradeException>());
        final e = thrown! as SnapshotSchemaDowngradeException;
        expect(e.snapshotVersion, tooNew);
        expect(e.appVersion, db.schemaVersion);

        final message = e.toString();
        expect(
          message,
          contains('older than'),
          reason: 'same framing as SchemaDowngradeException: the APP is '
              'behind the DATA, not the other way round',
        );
        expect(
          message,
          contains('Nothing has been changed or deleted'),
          reason: 'the refusal is non-destructive and must say so, in the '
              'same words the local-database guard uses',
        );
        expect(message, contains('$tooNew'));
        expect(message, contains('${db.schemaVersion}'));
      },
    );

    test(
      'a snapshot stamped OLDER than this build imports normally -- forward '
      'migration is the safe, ordinary case and must not be blocked',
      () async {
        await repo.importSnapshot({
          'schemaVersion': 1,
          'tables': {
            'areas': [areaRow('area-legacy')],
          },
        }, mode: ConflictMode.replace);

        final row = await (db.select(
          db.areas,
        )..where((t) => t.id.equals('area-legacy'))).getSingle();
        expect(row.name, 'Area area-legacy');
      },
    );

    test(
      'a snapshot stamped at EXACTLY this build\'s version imports normally',
      () async {
        await repo.importSnapshot({
          'schemaVersion': db.schemaVersion,
          'tables': {
            'areas': [areaRow('area-current')],
          },
        }, mode: ConflictMode.replace);

        expect(await db.select(db.areas).get(), hasLength(1));
      },
    );

    test(
      'a snapshot with NO schemaVersion key imports normally -- absent is '
      'not incompatible, and SyncService hands importSnapshot exactly this '
      "shape ({'tables': ...}) on every pull",
      () async {
        await repo.importSnapshot({
          'tables': {
            'areas': [areaRow('area-unversioned')],
          },
        }, mode: ConflictMode.replace);

        expect(await db.select(db.areas).get(), hasLength(1));
      },
    );

    test(
      'a snapshot whose schemaVersion is not an int is treated as absent, '
      'not as fatal -- an unreadable stamp must not lock a user out of an '
      'otherwise importable backup',
      () async {
        await repo.importSnapshot({
          'schemaVersion': 'nine',
          'tables': {
            'areas': [areaRow('area-garbled-stamp')],
          },
        }, mode: ConflictMode.replace);

        expect(await db.select(db.areas).get(), hasLength(1));
      },
    );
  });
}
