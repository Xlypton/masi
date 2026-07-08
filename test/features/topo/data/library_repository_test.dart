import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/features/topo/data/library_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late LibraryRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = LibraryRepository(db, nowMs: () => 1000);
  });

  tearDown(() async {
    await db.close();
  });

  test(
    'A3: ensureDefaultForImage is idempotent for the same localPath',
    () async {
      final first = await repo.ensureDefaultForImage(
        '/tmp/photo.jpg',
        100,
        200,
      );
      final second = await repo.ensureDefaultForImage(
        '/tmp/photo.jpg',
        100,
        200,
      );

      expect(second, first);

      final areas = await db.select(db.areas).get();
      final sectors = await db.select(db.sectors).get();
      final walls = await db.select(db.walls).get();
      final photos = await db.select(db.photos).get();

      expect(areas, hasLength(1));
      expect(sectors, hasLength(1));
      expect(walls, hasLength(1));
      expect(photos, hasLength(1));

      expect(areas.single.id, first.areaId);
      expect(sectors.single.id, first.sectorId);
      expect(walls.single.id, first.wallId);
      expect(photos.single.id, first.photoId);
      expect(areas.single.name, 'Default');
      expect(sectors.single.name, 'Default');
      expect(walls.single.name, 'Default');
    },
  );

  test(
    'a different localPath creates its own new Area/Sector/Wall/Photo chain',
    () async {
      final first = await repo.ensureDefaultForImage(
        '/tmp/photo-a.jpg',
        100,
        200,
      );
      final second = await repo.ensureDefaultForImage(
        '/tmp/photo-b.jpg',
        50,
        60,
      );

      expect(second.photoId, isNot(first.photoId));
      expect(second.wallId, isNot(first.wallId));
      expect(second.sectorId, isNot(first.sectorId));
      expect(second.areaId, isNot(first.areaId));

      final areas = await db.select(db.areas).get();
      final sectors = await db.select(db.sectors).get();
      final walls = await db.select(db.walls).get();
      final photos = await db.select(db.photos).get();

      expect(areas, hasLength(2));
      expect(sectors, hasLength(2));
      expect(walls, hasLength(2));
      expect(photos, hasLength(2));
    },
  );

  test('returns the ids as a record with the documented shape', () async {
    final result = await repo.ensureDefaultForImage('/tmp/x.jpg', 1, 1);

    expect(result.areaId, isNotEmpty);
    expect(result.sectorId, isNotEmpty);
    expect(result.wallId, isNotEmpty);
    expect(result.photoId, isNotEmpty);
  });

  test(
    'fix (f): concurrent ensureDefaultForImage calls for the same localPath '
    'create exactly one chain, not one each',
    () async {
      const path = '/tmp/concurrent.jpg';

      final results = await Future.wait([
        repo.ensureDefaultForImage(path, 100, 200),
        repo.ensureDefaultForImage(path, 100, 200),
        repo.ensureDefaultForImage(path, 100, 200),
      ]);

      final first = results[0];
      for (final result in results) {
        expect(result.photoId, first.photoId);
        expect(result.wallId, first.wallId);
        expect(result.sectorId, first.sectorId);
        expect(result.areaId, first.areaId);
      }

      final photos = await db.select(db.photos).get();
      expect(
        photos,
        hasLength(1),
        reason:
            'concurrent calls for the same localPath must not create '
            'duplicate Photo (and Area/Sector/Wall) chains',
      );

      final areas = await db.select(db.areas).get();
      final sectors = await db.select(db.sectors).get();
      final walls = await db.select(db.walls).get();
      expect(areas, hasLength(1));
      expect(sectors, hasLength(1));
      expect(walls, hasLength(1));
    },
  );
}
