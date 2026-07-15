import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/features/backup/data/backup_repository.dart';
import 'package:drift/drift.dart';
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
}
