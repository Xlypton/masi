import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/features/library/data/library_crud_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late LibraryCrudRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = LibraryCrudRepository(db, nowMs: () => 1000);
  });

  tearDown(() async {
    await db.close();
  });

  group('A1: create/rename/sortOrder', () {
    test('createArea -> listAreas returns it', () async {
      final area = await repo.createArea('Squamish', description: 'BC');

      final areas = await repo.listAreas();

      expect(areas, hasLength(1));
      expect(areas.single, area);
      expect(areas.single.name, 'Squamish');
      expect(areas.single.description, 'BC');
    });

    test('renameArea persists the new name', () async {
      final area = await repo.createArea('Squamish');

      await repo.renameArea(area.id, 'Squamish Renamed');

      final areas = await repo.listAreas();
      expect(areas.single.name, 'Squamish Renamed');
    });

    test('createSector sortOrder increments among siblings (0,1,2...)', () async {
      final area = await repo.createArea('Area');

      final s0 = await repo.createSector(area.id, 'Sector 0');
      final s1 = await repo.createSector(area.id, 'Sector 1');
      final s2 = await repo.createSector(area.id, 'Sector 2');

      expect(s0.sortOrder, 0);
      expect(s1.sortOrder, 1);
      expect(s2.sortOrder, 2);
    });

    test('createWall sortOrder increments among siblings (0,1,2...)', () async {
      final area = await repo.createArea('Area');
      final sector = await repo.createSector(area.id, 'Sector');

      final w0 = await repo.createWall(sector.id, 'Wall 0');
      final w1 = await repo.createWall(sector.id, 'Wall 1');
      final w2 = await repo.createWall(sector.id, 'Wall 2');

      expect(w0.sortOrder, 0);
      expect(w1.sortOrder, 1);
      expect(w2.sortOrder, 2);
    });

    test('renameSector/renameWall persist new names', () async {
      final area = await repo.createArea('Area');
      final sector = await repo.createSector(area.id, 'Sector');
      final wall = await repo.createWall(sector.id, 'Wall');

      await repo.renameSector(sector.id, 'Sector Renamed');
      await repo.renameWall(wall.id, 'Wall Renamed');

      final sectors = await repo.listSectors(area.id);
      final walls = await repo.listWalls(sector.id);
      expect(sectors.single.name, 'Sector Renamed');
      expect(walls.single.name, 'Wall Renamed');
    });
  });

  group('A2: softDeleteArea cascades', () {
    test(
      'soft-deletes area + all descendant sectors/walls/photos/routes, '
      'rows remain physically present',
      () async {
        final area = await repo.createArea('Area');
        final sector = await repo.createSector(area.id, 'Sector');
        final wall = await repo.createWall(sector.id, 'Wall');
        final photoId = await repo.attachPhotoToWall(
          wall.id,
          '/tmp/photo.jpg',
          100,
          200,
        );
        final routeId = 'route-1';
        await db
            .into(db.routes)
            .insert(
              RoutesCompanion.insert(
                id: routeId,
                createdAt: 1000,
                updatedAt: 1000,
                wallId: wall.id,
                photoId: photoId,
                number: 1,
                colorIndex: 0,
                pointsJson: '[]',
                symbolsJson: '[]',
                sortOrder: 0,
              ),
            );

        await repo.softDeleteArea(area.id);

        expect(await repo.listAreas(), isEmpty);
        expect(await repo.listSectors(area.id), isEmpty);
        expect(await repo.listWalls(sector.id), isEmpty);

        final rawArea = await (db.select(
          db.areas,
        )..where((t) => t.id.equals(area.id))).getSingle();
        final rawSector = await (db.select(
          db.sectors,
        )..where((t) => t.id.equals(sector.id))).getSingle();
        final rawWall = await (db.select(
          db.walls,
        )..where((t) => t.id.equals(wall.id))).getSingle();
        final rawPhoto = await (db.select(
          db.photos,
        )..where((t) => t.id.equals(photoId))).getSingle();
        final rawRoute = await (db.select(
          db.routes,
        )..where((t) => t.id.equals(routeId))).getSingle();

        expect(rawArea.deletedAt, isNotNull);
        expect(rawSector.deletedAt, isNotNull);
        expect(rawWall.deletedAt, isNotNull);
        expect(rawPhoto.deletedAt, isNotNull, reason: 'photo must be tombstoned');
        expect(rawRoute.deletedAt, isNotNull, reason: 'route must be tombstoned');

        // Rows physically remain (not deleted from the table).
        expect((await db.select(db.areas).get()), hasLength(1));
        expect((await db.select(db.sectors).get()), hasLength(1));
        expect((await db.select(db.walls).get()), hasLength(1));
        expect((await db.select(db.photos).get()), hasLength(1));
        expect((await db.select(db.routes).get()), hasLength(1));
      },
    );
  });

  group('A3: softDeleteWall cascades only its own subtree', () {
    test('sibling wall (and its photos/routes) are untouched', () async {
      final area = await repo.createArea('Area');
      final sector = await repo.createSector(area.id, 'Sector');
      final targetWall = await repo.createWall(sector.id, 'Target Wall');
      final siblingWall = await repo.createWall(sector.id, 'Sibling Wall');

      final targetPhotoId = await repo.attachPhotoToWall(
        targetWall.id,
        '/tmp/target.jpg',
        100,
        200,
      );
      final siblingPhotoId = await repo.attachPhotoToWall(
        siblingWall.id,
        '/tmp/sibling.jpg',
        100,
        200,
      );

      await db
          .into(db.routes)
          .insert(
            RoutesCompanion.insert(
              id: 'route-target',
              createdAt: 1000,
              updatedAt: 1000,
              wallId: targetWall.id,
              photoId: targetPhotoId,
              number: 1,
              colorIndex: 0,
              pointsJson: '[]',
              symbolsJson: '[]',
              sortOrder: 0,
            ),
          );
      await db
          .into(db.routes)
          .insert(
            RoutesCompanion.insert(
              id: 'route-sibling',
              createdAt: 1000,
              updatedAt: 1000,
              wallId: siblingWall.id,
              photoId: siblingPhotoId,
              number: 1,
              colorIndex: 0,
              pointsJson: '[]',
              symbolsJson: '[]',
              sortOrder: 0,
            ),
          );

      await repo.softDeleteWall(targetWall.id);

      final walls = await repo.listWalls(sector.id);
      expect(walls, hasLength(1));
      expect(walls.single.id, siblingWall.id);

      final rawTargetWall = await (db.select(
        db.walls,
      )..where((t) => t.id.equals(targetWall.id))).getSingle();
      final rawSiblingWall = await (db.select(
        db.walls,
      )..where((t) => t.id.equals(siblingWall.id))).getSingle();
      expect(rawTargetWall.deletedAt, isNotNull);
      expect(rawSiblingWall.deletedAt, isNull);

      final rawTargetPhoto = await (db.select(
        db.photos,
      )..where((t) => t.id.equals(targetPhotoId))).getSingle();
      final rawSiblingPhoto = await (db.select(
        db.photos,
      )..where((t) => t.id.equals(siblingPhotoId))).getSingle();
      expect(rawTargetPhoto.deletedAt, isNotNull);
      expect(rawSiblingPhoto.deletedAt, isNull);

      final rawTargetRoute = await (db.select(
        db.routes,
      )..where((t) => t.id.equals('route-target'))).getSingle();
      final rawSiblingRoute = await (db.select(
        db.routes,
      )..where((t) => t.id.equals('route-sibling'))).getSingle();
      expect(rawTargetRoute.deletedAt, isNotNull);
      expect(rawSiblingRoute.deletedAt, isNull);

      // Sector itself untouched.
      final sectors = await repo.listSectors(area.id);
      expect(sectors, hasLength(1));
    });
  });

  group('A4: watch streams emit updates', () {
    test('watchAreas emits initial empty list, then after create, then after delete', () async {
      final stream = repo.watchAreas();

      final emissions = <List<AreaRef>>[];
      final sub = stream.listen(emissions.add);

      // Let the initial emission land.
      await Future<void>.delayed(Duration.zero);
      expect(emissions, hasLength(1));
      expect(emissions.last, isEmpty);

      final area = await repo.createArea('Area');
      await Future<void>.delayed(Duration.zero);
      expect(emissions.last, [area]);

      await repo.softDeleteArea(area.id);
      await Future<void>.delayed(Duration.zero);
      expect(emissions.last, isEmpty);

      await sub.cancel();
    });

    test('watchSectors scopes to its areaId and emits updates', () async {
      final areaA = await repo.createArea('Area A');
      final areaB = await repo.createArea('Area B');

      final emissions = <List<SectorRef>>[];
      final sub = repo.watchSectors(areaA.id).listen(emissions.add);
      await Future<void>.delayed(Duration.zero);
      expect(emissions.last, isEmpty);

      final sectorInB = await repo.createSector(areaB.id, 'Sector B');
      await Future<void>.delayed(Duration.zero);
      // Unrelated area's sector must not show up for areaA's watch.
      expect(emissions.last, isEmpty);

      final sectorInA = await repo.createSector(areaA.id, 'Sector A');
      await Future<void>.delayed(Duration.zero);
      expect(emissions.last, [sectorInA]);

      await repo.softDeleteSector(sectorInA.id);
      await Future<void>.delayed(Duration.zero);
      expect(emissions.last, isEmpty);

      await sub.cancel();
      // Keep sectorInB referenced so analyzer doesn't flag unused var while
      // documenting the scoping intent above.
      expect(sectorInB.areaId, areaB.id);
    });

    test('watchWalls scopes to its sectorId and emits updates', () async {
      final area = await repo.createArea('Area');
      final sectorA = await repo.createSector(area.id, 'Sector A');
      final sectorB = await repo.createSector(area.id, 'Sector B');

      final emissions = <List<WallRef>>[];
      final sub = repo.watchWalls(sectorA.id).listen(emissions.add);
      await Future<void>.delayed(Duration.zero);
      expect(emissions.last, isEmpty);

      await repo.createWall(sectorB.id, 'Wall B');
      await Future<void>.delayed(Duration.zero);
      expect(emissions.last, isEmpty);

      final wallA = await repo.createWall(sectorA.id, 'Wall A');
      await Future<void>.delayed(Duration.zero);
      expect(emissions.last, [wallA]);

      await repo.softDeleteWall(wallA.id);
      await Future<void>.delayed(Duration.zero);
      expect(emissions.last, isEmpty);

      await sub.cancel();
    });
  });

  group('A5: attachPhotoToWall', () {
    test('inserts an original photo under the wall and returns a usable id', () async {
      final area = await repo.createArea('Area');
      final sector = await repo.createSector(area.id, 'Sector');
      final wall = await repo.createWall(sector.id, 'Wall');

      final photoId = await repo.attachPhotoToWall(
        wall.id,
        '/tmp/photo.jpg',
        640,
        480,
      );

      expect(photoId, isNotEmpty);

      final photo = await (db.select(
        db.photos,
      )..where((t) => t.id.equals(photoId))).getSingle();

      expect(photo.kind, 'original');
      expect(photo.wallId, wall.id);
      expect(photo.localPath, '/tmp/photo.jpg');
      expect(photo.width, 640);
      expect(photo.height, 480);
      expect(photo.deletedAt, isNull);
    });
  });

  group('A6: listSectors scoping', () {
    test('listSectors(areaId) returns only that area\'s sectors', () async {
      final areaA = await repo.createArea('Area A');
      final areaB = await repo.createArea('Area B');

      final sectorA1 = await repo.createSector(areaA.id, 'A Sector 1');
      final sectorA2 = await repo.createSector(areaA.id, 'A Sector 2');
      final sectorB1 = await repo.createSector(areaB.id, 'B Sector 1');

      final sectorsA = await repo.listSectors(areaA.id);
      final sectorsB = await repo.listSectors(areaB.id);

      expect(sectorsA.map((s) => s.id), containsAll([sectorA1.id, sectorA2.id]));
      expect(sectorsA, hasLength(2));
      expect(sectorsA.every((s) => s.areaId == areaA.id), isTrue);

      expect(sectorsB, hasLength(1));
      expect(sectorsB.single.id, sectorB1.id);
      expect(sectorsB.single.areaId, areaB.id);
    });
  });
}
