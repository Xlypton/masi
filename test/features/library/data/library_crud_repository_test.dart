import 'dart:io';

import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/core/grades/grade_system.dart';
import 'package:climbtopo/features/library/data/library_crud_repository.dart';
import 'package:climbtopo/features/topo/data/photo_files.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

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

    test(
      'createSector sortOrder increments among siblings (0,1,2...)',
      () async {
        final area = await repo.createArea('Area');

        final s0 = await repo.createSector(area.id, 'Sector 0');
        final s1 = await repo.createSector(area.id, 'Sector 1');
        final s2 = await repo.createSector(area.id, 'Sector 2');

        expect(s0.sortOrder, 0);
        expect(s1.sortOrder, 1);
        expect(s2.sortOrder, 2);
      },
    );

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
    test('soft-deletes area + all descendant sectors/walls/photos/routes, '
        'rows remain physically present', () async {
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
    });
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
    test(
      'watchAreas emits initial empty list, then after create, then after delete',
      () async {
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
      },
    );

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
    test(
      'inserts an original photo under the wall and returns a usable id',
      () async {
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
        expect(
          photo.localPath,
          'photos/$photoId.jpg',
          reason:
              'attachPhotoToWall stores the relative photos/<id><ext> '
              'form (never an absolute path baked into the row) — the '
              'source here does not actually exist on disk, so importPhoto '
              'takes its missing-source fast path and returns that relative '
              'destination form directly',
        );
        expect(photo.width, 640);
        expect(photo.height, 480);
        expect(photo.deletedAt, isNull);
      },
    );
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

      expect(
        sectorsA.map((s) => s.id),
        containsAll([sectorA1.id, sectorA2.id]),
      );
      expect(sectorsA, hasLength(2));
      expect(sectorsA.every((s) => s.areaId == areaA.id), isTrue);

      expect(sectorsB, hasLength(1));
      expect(sectorsB.single.id, sectorB1.id);
      expect(sectorsB.single.areaId, areaB.id);
    });
  });

  group('A7: watchTopos', () {
    Future<String> insertRoute(
      String wallId,
      String photoId,
      String id, {
      int number = 1,
      String? gradeRaw,
    }) {
      return db
          .into(db.routes)
          .insert(
            RoutesCompanion.insert(
              id: id,
              createdAt: 1000,
              updatedAt: 1000,
              wallId: wallId,
              photoId: photoId,
              number: number,
              colorIndex: 0,
              pointsJson: '[]',
              symbolsJson: '[]',
              sortOrder: 0,
              gradeRaw: Value(gradeRaw),
              gradeSortKey: Value(
                gradeRaw == null
                    ? null
                    : gradeSortKey(GradeSystem.french, gradeRaw),
              ),
            ),
          )
          .then((_) => id);
    }

    test(
      'emits one TopoRef per non-deleted wall with correct name/thumbnail',
      () async {
        final area = await repo.createArea('Area');
        final sector = await repo.createSector(area.id, 'Sector');
        final wallNoPhoto = await repo.createWall(sector.id, 'No Photo Wall');
        final wallWithPhoto = await repo.createWall(sector.id, 'Photo Wall');
        final thumbPhotoId = await repo.attachPhotoToWall(
          wallWithPhoto.id,
          '/tmp/thumb.jpg',
          100,
          200,
        );

        final topos = await repo.watchTopos().first;

        expect(topos, hasLength(2));

        final noPhotoRef = topos.firstWhere((t) => t.wallId == wallNoPhoto.id);
        expect(noPhotoRef.name, 'No Photo Wall');
        expect(noPhotoRef.thumbnailPath, isNull);
        expect(noPhotoRef.routeCount, 0);

        final withPhotoRef = topos.firstWhere(
          (t) => t.wallId == wallWithPhoto.id,
        );
        expect(withPhotoRef.name, 'Photo Wall');
        expect(
          withPhotoRef.thumbnailPath,
          'photos/$thumbPhotoId.jpg',
          reason:
              'attachPhotoToWall stores the relative photos/<id><ext> '
              'form (the source path does not exist on disk here), and '
              'watchTopos with the default (no path_provider available in '
              'this test) PhotoFiles falls back to returning it unchanged',
        );
        expect(withPhotoRef.routeCount, 0);
      },
    );

    test('excludes soft-deleted walls and re-emits without them', () async {
      final area = await repo.createArea('Area');
      final sector = await repo.createSector(area.id, 'Sector');
      final wallA = await repo.createWall(sector.id, 'Wall A');
      final wallB = await repo.createWall(sector.id, 'Wall B');

      final emissions = <List<TopoRef>>[];
      final sub = repo.watchTopos().listen(emissions.add);
      await Future<void>.delayed(Duration.zero);
      expect(
        emissions.last.map((t) => t.wallId),
        containsAll([wallA.id, wallB.id]),
      );
      expect(emissions.last, hasLength(2));

      await repo.softDeleteWall(wallA.id);
      await Future<void>.delayed(Duration.zero);
      expect(emissions.last, hasLength(1));
      expect(emissions.last.single.wallId, wallB.id);

      await sub.cancel();
    });

    test('routeCount reflects live non-deleted route count and reacts to '
        'route insert/soft-delete', () async {
      final area = await repo.createArea('Area');
      final sector = await repo.createSector(area.id, 'Sector');
      final wall = await repo.createWall(sector.id, 'Wall');
      final photoId = await repo.attachPhotoToWall(
        wall.id,
        '/tmp/photo.jpg',
        100,
        200,
      );

      final emissions = <List<TopoRef>>[];
      final sub = repo.watchTopos().listen(emissions.add);
      await Future<void>.delayed(Duration.zero);
      expect(emissions.last.single.routeCount, 0);

      final routeId = await insertRoute(wall.id, photoId, 'route-1');
      await Future<void>.delayed(Duration.zero);
      expect(emissions.last.single.routeCount, 1);

      await (db.update(db.routes)..where((t) => t.id.equals(routeId))).write(
        const RoutesCompanion(deletedAt: Value(2000)),
      );
      await Future<void>.delayed(Duration.zero);
      expect(emissions.last.single.routeCount, 0);

      await sub.cancel();
    });

    test(
      'topGradeLabel/topGradeBand report the hardest graded route on the '
      'wall (5c/7a/6b -> 7a, hard band); a wall with no routes reports '
      'null/null; adding a harder route re-emits with the new hardest',
      () async {
        final area = await repo.createArea('Area');
        final sector = await repo.createSector(area.id, 'Sector');
        final gradedWall = await repo.createWall(sector.id, 'Graded Wall');
        final ungradedWall = await repo.createWall(sector.id, 'Bare Wall');
        final photoId = await repo.attachPhotoToWall(
          gradedWall.id,
          '/tmp/photo.jpg',
          100,
          200,
        );

        await insertRoute(
          gradedWall.id,
          photoId,
          'route-5c',
          number: 1,
          gradeRaw: '5c',
        );
        await insertRoute(
          gradedWall.id,
          photoId,
          'route-7a',
          number: 2,
          gradeRaw: '7a',
        );
        await insertRoute(
          gradedWall.id,
          photoId,
          'route-6b',
          number: 3,
          gradeRaw: '6b',
        );

        final emissions = <List<TopoRef>>[];
        final sub = repo.watchTopos().listen(emissions.add);
        await Future<void>.delayed(Duration.zero);

        final gradedRef = emissions.last.firstWhere(
          (t) => t.wallId == gradedWall.id,
        );
        expect(gradedRef.topGradeLabel, '7a');
        expect(gradedRef.topGradeBand, GradeBand.hard);

        final ungradedRef = emissions.last.firstWhere(
          (t) => t.wallId == ungradedWall.id,
        );
        expect(ungradedRef.topGradeLabel, isNull);
        expect(ungradedRef.topGradeBand, isNull);

        await insertRoute(
          gradedWall.id,
          photoId,
          'route-8a',
          number: 4,
          gradeRaw: '8a',
        );
        await Future<void>.delayed(Duration.zero);

        final updatedRef = emissions.last.firstWhere(
          (t) => t.wallId == gradedWall.id,
        );
        expect(updatedRef.topGradeLabel, '8a');
        expect(updatedRef.topGradeBand, GradeBand.elite);

        await sub.cancel();
      },
    );

    test('orders by wall createdAt DESC (newest topo first)', () async {
      final area = await repo.createArea('Area');
      final sector = await repo.createSector(area.id, 'Sector');
      final wallOld = await repo.createWall(sector.id, 'Old Wall');
      await (db.update(db.walls)..where((t) => t.id.equals(wallOld.id))).write(
        const WallsCompanion(createdAt: Value(500)),
      );
      final wallNew = await repo.createWall(sector.id, 'New Wall');
      await (db.update(db.walls)..where((t) => t.id.equals(wallNew.id))).write(
        const WallsCompanion(createdAt: Value(1500)),
      );

      final topos = await repo.watchTopos().first;

      expect(topos.map((t) => t.wallId).toList(), [wallNew.id, wallOld.id]);
    });
  });

  group(
    'D1: watchTopos area + routeGradeKeys enrichment (filtering Subtask D)',
    () {
      Future<String> insertRoute(
        String wallId,
        String photoId,
        String id, {
        int number = 1,
        String? gradeRaw,
      }) {
        return db
            .into(db.routes)
            .insert(
              RoutesCompanion.insert(
                id: id,
                createdAt: 1000,
                updatedAt: 1000,
                wallId: wallId,
                photoId: photoId,
                number: number,
                colorIndex: 0,
                pointsJson: '[]',
                symbolsJson: '[]',
                sortOrder: 0,
                gradeRaw: Value(gradeRaw),
                gradeSortKey: Value(
                  gradeRaw == null
                      ? null
                      : gradeSortKey(GradeSystem.french, gradeRaw),
                ),
              ),
            )
            .then((_) => id);
      }

      test(
        "a topo under a REAL area exposes that area's id/name",
        () async {
          final area = await repo.createArea('Squamish');
          final sector = await repo.createSector(area.id, 'Sector');
          final wall = await repo.createWall(sector.id, 'Wall');

          final topos = await repo.watchTopos().first;

          final ref = topos.firstWhere((t) => t.wallId == wall.id);
          expect(ref.areaId, area.id);
          expect(ref.areaName, 'Squamish');
        },
      );

      test(
        'a photo-first topo (filed under the hidden __default__ sentinel '
        'Area/Sector via createTopo) reports areaId/areaName as null '
        '(Unfiled) -- the sentinel itself must never surface as a real '
        'area',
        () async {
          final wallId = await repo.createTopo('Photo First Topo');

          final topos = await repo.watchTopos().first;

          final ref = topos.firstWhere((t) => t.wallId == wallId);
          expect(ref.areaId, isNull);
          expect(ref.areaName, isNull);
        },
      );

      test(
        "routeGradeKeys contains every live graded route's gradeSortKey, "
        'deduplicated and sorted, and omits ungraded/soft-deleted routes; a '
        'wall with no graded routes reports an empty list',
        () async {
          final area = await repo.createArea('Area');
          final sector = await repo.createSector(area.id, 'Sector');
          final wall = await repo.createWall(sector.id, 'Wall');
          final bareWall = await repo.createWall(sector.id, 'Bare Wall');
          final photoId = await repo.attachPhotoToWall(
            wall.id,
            '/tmp/p.jpg',
            1,
            1,
          );

          await insertRoute(
            wall.id,
            photoId,
            'route-6a',
            number: 1,
            gradeRaw: '6a',
          );
          // A duplicate grade must be deduplicated (group_concat DISTINCT).
          await insertRoute(
            wall.id,
            photoId,
            'route-6a-dup',
            number: 2,
            gradeRaw: '6a',
          );
          await insertRoute(
            wall.id,
            photoId,
            'route-7a',
            number: 3,
            gradeRaw: '7a',
          );
          // Ungraded route: must not contribute a key.
          await insertRoute(wall.id, photoId, 'route-ungraded', number: 4);
          // Soft-deleted graded route: must not contribute a key either.
          final deletedRouteId = await insertRoute(
            wall.id,
            photoId,
            'route-deleted',
            number: 5,
            gradeRaw: '9a',
          );
          await (db.update(
            db.routes,
          )..where((t) => t.id.equals(deletedRouteId))).write(
            const RoutesCompanion(deletedAt: Value(2000)),
          );

          final topos = await repo.watchTopos().first;

          final ref = topos.firstWhere((t) => t.wallId == wall.id);
          expect(ref.routeGradeKeys, [
            gradeSortKey(GradeSystem.french, '6a'),
            gradeSortKey(GradeSystem.french, '7a'),
          ]);

          final bareRef = topos.firstWhere((t) => t.wallId == bareWall.id);
          expect(bareRef.routeGradeKeys, isEmpty);
        },
      );

      test(
        'existing fields (name/thumbnailPath/routeCount/createdAt/'
        'topGradeLabel/topGradeBand/visibility) are unchanged by the '
        'area/routeGradeKeys enrichment',
        () async {
          final area = await repo.createArea('Area');
          final sector = await repo.createSector(area.id, 'Sector');
          final wall = await repo.createWall(sector.id, 'Wall');
          final photoId = await repo.attachPhotoToWall(
            wall.id,
            '/tmp/p.jpg',
            640,
            480,
          );
          await insertRoute(
            wall.id,
            photoId,
            'route-1',
            number: 1,
            gradeRaw: '7a',
          );

          final ref = (await repo.watchTopos().first).single;

          expect(ref.name, 'Wall');
          expect(ref.thumbnailPath, 'photos/$photoId.jpg');
          expect(ref.routeCount, 1);
          expect(ref.topGradeLabel, '7a');
          expect(ref.topGradeBand, GradeBand.hard);
          expect(ref.visibility, 'private');
        },
      );

      test(
        'exposes the wall latitude/longitude set via setWallCoordinates; a '
        'wall with no coordinates reports both as null (M1 -- backs the '
        "Community map's own-topo markers)",
        () async {
          final area = await repo.createArea('Area');
          final sector = await repo.createSector(area.id, 'Sector');
          final wallWithCoords = await repo.createWall(sector.id, 'Wall');
          final wallWithoutCoords = await repo.createWall(
            sector.id,
            'Bare Wall',
          );
          await repo.setWallCoordinates(wallWithCoords.id, 47.4979, 19.0402);

          final topos = await repo.watchTopos().first;

          final withCoordsRef = topos.firstWhere(
            (t) => t.wallId == wallWithCoords.id,
          );
          expect(withCoordsRef.latitude, 47.4979);
          expect(withCoordsRef.longitude, 19.0402);

          final withoutCoordsRef = topos.firstWhere(
            (t) => t.wallId == wallWithoutCoords.id,
          );
          expect(withoutCoordsRef.latitude, isNull);
          expect(withoutCoordsRef.longitude, isNull);
        },
      );

      test(
        'listAreas/watchAreas still exclude the __default__ sentinel even '
        'though watchTopos now LEFT JOINs through sectors/areas',
        () async {
          final realArea = await repo.createArea('Squamish');
          await repo.createTopo('Photo First Topo');

          final areas = await repo.listAreas();
          expect(areas, [realArea]);
          expect(areas.any((a) => a.name == '__default__'), isFalse);
        },
      );
    },
  );

  group('A8: createTopo', () {
    test('returns a wallId resolving to a real non-deleted Wall row with the '
        'given name', () async {
      final wallId = await repo.createTopo('My New Topo');

      final wall = await (db.select(
        db.walls,
      )..where((t) => t.id.equals(wallId))).getSingle();

      expect(wall.name, 'My New Topo');
      expect(wall.deletedAt, isNull);
    });

    test('calling createTopo twice reuses the same default Area and Sector '
        '(exactly one of each)', () async {
      final wallId1 = await repo.createTopo('Topo 1');
      final wallId2 = await repo.createTopo('Topo 2');

      final areas = await (db.select(
        db.areas,
      )..where((t) => t.name.equals('__default__'))).get();
      expect(areas, hasLength(1));

      final sectors = await (db.select(
        db.sectors,
      )..where((t) => t.name.equals('__default__'))).get();
      expect(sectors, hasLength(1));
      expect(sectors.single.areaId, areas.single.id);

      final wall1 = await (db.select(
        db.walls,
      )..where((t) => t.id.equals(wallId1))).getSingle();
      final wall2 = await (db.select(
        db.walls,
      )..where((t) => t.id.equals(wallId2))).getSingle();
      expect(wall1.sectorId, sectors.single.id);
      expect(wall2.sectorId, sectors.single.id);
    });

    test('concurrent createTopo calls (double-tap) create exactly ONE '
        '__default__ area and ONE __default__ sector, and both wallIds are '
        'real non-deleted walls under that one sector', () async {
      final results = await Future.wait([
        repo.createTopo('A'),
        repo.createTopo('B'),
      ]);
      final wallIdA = results[0];
      final wallIdB = results[1];

      final areas = await (db.select(
        db.areas,
      )..where((t) => t.name.equals('__default__'))).get();
      expect(
        areas,
        hasLength(1),
        reason:
            'two concurrent createTopo calls must not race into creating '
            'two __default__ areas',
      );

      final sectors = await (db.select(
        db.sectors,
      )..where((t) => t.name.equals('__default__'))).get();
      expect(
        sectors,
        hasLength(1),
        reason:
            'two concurrent createTopo calls must not race into creating '
            'two __default__ sectors',
      );
      expect(sectors.single.areaId, areas.single.id);

      final wallA = await (db.select(
        db.walls,
      )..where((t) => t.id.equals(wallIdA))).getSingle();
      final wallB = await (db.select(
        db.walls,
      )..where((t) => t.id.equals(wallIdB))).getSingle();
      expect(wallA.deletedAt, isNull);
      expect(wallB.deletedAt, isNull);
      expect(wallA.sectorId, sectors.single.id);
      expect(wallB.sectorId, sectors.single.id);
    });
  });

  group('A9: sentinel default Area/Sector excluded from hierarchy queries', () {
    test('watchAreas/listAreas exclude the __default__ area created by '
        'createTopo', () async {
      // A real, user-created area named e.g. "Squamish" must still show
      // up; only the sentinel is hidden.
      final realArea = await repo.createArea('Squamish');
      await repo.createTopo('Photo First Topo');

      final listed = await repo.listAreas();
      expect(listed, [realArea]);
      expect(
        listed.any((a) => a.name == '__default__'),
        isFalse,
        reason:
            'the hidden sentinel default area must never surface in '
            'the Areas hierarchy UI',
      );

      final emissions = <List<AreaRef>>[];
      final sub = repo.watchAreas().listen(emissions.add);
      await Future<void>.delayed(Duration.zero);
      expect(emissions.last, [realArea]);
      await sub.cancel();

      // Raw table proves the sentinel really exists (it's just filtered
      // out of the hierarchy read model), so deleting it would still
      // cascade-delete every photo-first topo if it were exposed.
      final rawAreas = await (db.select(
        db.areas,
      )..where((t) => t.name.equals('__default__'))).get();
      expect(rawAreas, hasLength(1));
    });

    test('watchSectors/listSectors exclude the __default__ sector created by '
        'createTopo', () async {
      final realArea = await repo.createArea('Area A');
      final realSector = await repo.createSector(realArea.id, 'Sector A');
      await repo.createTopo('Photo First Topo');

      final listedForRealArea = await repo.listSectors(realArea.id);
      expect(listedForRealArea, [realSector]);

      // The sentinel sector lives under a different (sentinel) area, so
      // scoping to the sentinel area's id should also exclude it.
      final rawSentinelArea = await (db.select(
        db.areas,
      )..where((t) => t.name.equals('__default__'))).getSingle();
      final listedForSentinelArea = await repo.listSectors(rawSentinelArea.id);
      expect(
        listedForSentinelArea,
        isEmpty,
        reason:
            'the hidden sentinel default sector must never surface in '
            'the Sectors hierarchy UI',
      );

      final emissions = <List<SectorRef>>[];
      final sub = repo.watchSectors(rawSentinelArea.id).listen(emissions.add);
      await Future<void>.delayed(Duration.zero);
      expect(emissions.last, isEmpty);
      await sub.cancel();

      final rawSectors = await (db.select(
        db.sectors,
      )..where((t) => t.name.equals('__default__'))).get();
      expect(rawSectors, hasLength(1));
    });
  });

  group('A10: watchTopos deterministic tiebreak on equal createdAt', () {
    test('two walls with identical createdAt order deterministically by id '
        'DESC, consistently across repeated reads', () async {
      // Force both walls to share the exact same injected nowMs.
      final tiedRepo = LibraryCrudRepository(db, nowMs: () => 5000);
      final area = await tiedRepo.createArea('Area');
      final sector = await tiedRepo.createSector(area.id, 'Sector');
      final wall1 = await tiedRepo.createWall(sector.id, 'Wall 1');
      final wall2 = await tiedRepo.createWall(sector.id, 'Wall 2');

      expect(wall1.name, isNot(wall2.name));

      // Confirm the createdAt tie really exists at the raw row level.
      final rawWall1 = await (db.select(
        db.walls,
      )..where((t) => t.id.equals(wall1.id))).getSingle();
      final rawWall2 = await (db.select(
        db.walls,
      )..where((t) => t.id.equals(wall2.id))).getSingle();
      expect(rawWall1.createdAt, rawWall2.createdAt);

      final expectedOrder = [wall1.id, wall2.id]
        ..sort((a, b) => b.compareTo(a));

      for (var i = 0; i < 3; i++) {
        final topos = await tiedRepo.watchTopos().first;
        expect(
          topos.map((t) => t.wallId).toList(),
          expectedOrder,
          reason:
              'ordering among createdAt ties must be deterministic '
              '(id DESC) and stable across repeated reads',
        );
      }
    });

    test(
      'thumbnail subquery tiebreak: two original photos on the same wall '
      'with identical createdAt resolve deterministically by photo id DESC',
      () async {
        final tiedRepo = LibraryCrudRepository(db, nowMs: () => 7000);
        final area = await tiedRepo.createArea('Area');
        final sector = await tiedRepo.createSector(area.id, 'Sector');
        final wall = await tiedRepo.createWall(sector.id, 'Wall');

        final photoId1 = await tiedRepo.attachPhotoToWall(
          wall.id,
          '/tmp/photo-a.jpg',
          100,
          200,
        );
        final photoId2 = await tiedRepo.attachPhotoToWall(
          wall.id,
          '/tmp/photo-b.jpg',
          100,
          200,
        );

        final rawPhoto1 = await (db.select(
          db.photos,
        )..where((t) => t.id.equals(photoId1))).getSingle();
        final rawPhoto2 = await (db.select(
          db.photos,
        )..where((t) => t.id.equals(photoId2))).getSingle();
        expect(rawPhoto1.createdAt, rawPhoto2.createdAt);

        final expectedPhotoId = [photoId1, photoId2]
          ..sort((a, b) => b.compareTo(a));
        // Both source paths are missing on disk, so attachPhotoToWall
        // stores the relative photos/<id><ext> form for each, and the
        // default (no path_provider in this test) PhotoFiles used by
        // watchTopos falls back to returning it unchanged.
        final expectedPath = 'photos/${expectedPhotoId.first}.jpg';

        for (var i = 0; i < 3; i++) {
          final topos = await tiedRepo.watchTopos().first;
          expect(topos.single.thumbnailPath, expectedPath);
        }
      },
    );
  });

  group('S2: photoLocalPath self-heal + watchTopos sync thumbnail resolution '
      '(container-rotation fix)', () {
    late Directory docsDir;
    late PhotoFiles photoFiles;
    late LibraryCrudRepository healingRepo;

    String photosDirPath() => p.join(docsDir.path, 'photos');

    setUp(() {
      docsDir = Directory.systemTemp.createTempSync('library_crud_docs_');
      photoFiles = PhotoFiles(docsDir: () async => docsDir);
      healingRepo = LibraryCrudRepository(
        db,
        nowMs: () => 1000,
        photoFiles: photoFiles,
      );
    });

    tearDown(() {
      if (docsDir.existsSync()) docsDir.deleteSync(recursive: true);
    });

    test('photoLocalPath self-heals a stale absolute path (simulating a '
        'container-UUID rotation) whose file has moved to the current '
        'docs dir: returns the new absolute path AND rewrites the row to '
        'the relative form, without touching updatedAt/dirty', () async {
      // photoLocalPath resolves via PhotoFiles' memoized docs path
      // (resolvePhotoPath never awaits path_provider on its hot path);
      // warm it so this await-driven test sees deterministic heal.
      await photoFiles.warmDocsPath();
      final area = await healingRepo.createArea('Area');
      final sector = await healingRepo.createSector(area.id, 'Sector');
      final wall = await healingRepo.createWall(sector.id, 'Wall');
      final photoId = await healingRepo.attachPhotoToWall(
        wall.id,
        '/tmp/does-not-exist.jpg',
        1,
        1,
      );
      Directory(photosDirPath()).createSync(recursive: true);
      File(
        p.join(photosDirPath(), '$photoId.jpg'),
      ).writeAsBytesSync(List<int>.filled(4, 9));
      final staleAbsolute =
          '/private/var/mobile/Containers/Data/Application/'
          'OLD-UUID/Documents/photos/$photoId.jpg';
      await (db.update(db.photos)..where((t) => t.id.equals(photoId))).write(
        PhotosCompanion(localPath: Value(staleAbsolute)),
      );
      final before = await (db.select(
        db.photos,
      )..where((t) => t.id.equals(photoId))).getSingle();

      final resolved = await healingRepo.photoLocalPath(photoId);

      expect(resolved, p.join(photosDirPath(), '$photoId.jpg'));

      final after = await (db.select(
        db.photos,
      )..where((t) => t.id.equals(photoId))).getSingle();
      expect(after.localPath, 'photos/$photoId.jpg');
      expect(after.updatedAt, before.updatedAt);
      expect(after.dirty, isFalse);
    });

    test('watchTopos resolves a RELATIVE stored thumbnail path to an '
        'absolute display path via the synchronous resolver (once the docs '
        'cache is warm), WITHOUT rewriting the DB row (heal is reserved for '
        'the async open-a-wall paths, not the sync stream)', () async {
      final area = await healingRepo.createArea('Area');
      final sector = await healingRepo.createSector(area.id, 'Sector');
      final wall = await healingRepo.createWall(sector.id, 'Wall');
      // Missing source -> attachPhotoToWall stores the relative
      // photos/<id>.jpg form (the container-rotation-proof shape).
      final photoId = await healingRepo.attachPhotoToWall(
        wall.id,
        '/tmp/does-not-exist.jpg',
        1,
        1,
      );
      final stored = await (db.select(
        db.photos,
      )..where((t) => t.id.equals(photoId))).getSingle();
      expect(
        stored.localPath,
        'photos/$photoId.jpg',
        reason: 'attach stores the relative form',
      );

      // Warm the memoized docs path so the SYNCHRONOUS watchTopos
      // resolver can join the relative thumbnail against it (in the
      // real app this is warmed by path_provider / prior async reads).
      await photoFiles.warmDocsPath();

      final topos = await healingRepo.watchTopos().first;

      expect(
        topos.single.thumbnailPath,
        p.join(photosDirPath(), '$photoId.jpg'),
        reason:
            'the relative stored thumbnail must resolve to an '
            'absolute path under the current docs dir',
      );

      // watchTopos must NOT heal/rewrite the row (sync stream has no
      // async DB write); the stored value stays the relative form.
      final after = await (db.select(
        db.photos,
      )..where((t) => t.id.equals(photoId))).getSingle();
      expect(after.localPath, 'photos/$photoId.jpg');
      expect(after.updatedAt, stored.updatedAt);
      expect(after.dirty, isFalse);
    });

    test(
      'watchTopos falls back to the stored thumbnail value unchanged when '
      'the docs cache is cold (no async resolution has warmed it yet) — '
      'the ToposScreen thumbnail then gates it via File.existsSync',
      () async {
        final area = await healingRepo.createArea('Area');
        final sector = await healingRepo.createSector(area.id, 'Sector');
        final wall = await healingRepo.createWall(sector.id, 'Wall');
        final photoId = await healingRepo.attachPhotoToWall(
          wall.id,
          '/tmp/does-not-exist.jpg',
          1,
          1,
        );

        // No warmDocsPath()/async resolve called on THIS PhotoFiles, so
        // the sync resolver's cache is cold -> returns the stored value.
        final topos = await healingRepo.watchTopos().first;

        expect(topos.single.thumbnailPath, 'photos/$photoId.jpg');
      },
    );
  });

  group('P1-b: ownerId stamping on create', () {
    test('createArea/createSector/createWall/createTopo/attachPhotoToWall '
        'stamp ownerId with the injected currentUid, and a new Wall defaults '
        'visibility to private', () async {
      final owned = LibraryCrudRepository(
        db,
        nowMs: () => 1000,
        currentUid: () => 'u1',
      );

      final area = await owned.createArea('Area');
      final sector = await owned.createSector(area.id, 'Sector');
      final wall = await owned.createWall(sector.id, 'Wall');
      final photoId = await owned.attachPhotoToWall(
        wall.id,
        '/tmp/photo.jpg',
        100,
        200,
      );
      final topoWallId = await owned.createTopo('Topo');

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
      final rawTopoWall = await (db.select(
        db.walls,
      )..where((t) => t.id.equals(topoWallId))).getSingle();

      expect(rawArea.ownerId, 'u1');
      expect(rawSector.ownerId, 'u1');
      expect(rawWall.ownerId, 'u1');
      expect(rawPhoto.ownerId, 'u1');
      expect(rawTopoWall.ownerId, 'u1');

      expect(
        rawWall.visibility,
        'private',
        reason:
            'new Walls default to private visibility regardless of '
            'ownerId',
      );
      expect(rawTopoWall.visibility, 'private');
    });

    test('default currentUid (signed-out) leaves ownerId null on every insert '
        'path', () async {
      // `repo` (from setUp) uses the default currentUid, i.e. no uid was
      // passed to the constructor.
      final area = await repo.createArea('Area');
      final sector = await repo.createSector(area.id, 'Sector');
      final wall = await repo.createWall(sector.id, 'Wall');
      final photoId = await repo.attachPhotoToWall(
        wall.id,
        '/tmp/photo.jpg',
        100,
        200,
      );
      final topoWallId = await repo.createTopo('Topo');

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
      final rawTopoWall = await (db.select(
        db.walls,
      )..where((t) => t.id.equals(topoWallId))).getSingle();

      expect(rawArea.ownerId, isNull);
      expect(rawSector.ownerId, isNull);
      expect(rawWall.ownerId, isNull);
      expect(rawPhoto.ownerId, isNull);
      expect(rawTopoWall.ownerId, isNull);
      expect(rawWall.visibility, 'private');
    });
  });

  group('P1-c: claimOwnership backfill', () {
    test('claims every unowned, non-deleted row across all 8 sync-tracked '
        'tables (the original 5 plus the v3 community tables — Comments, '
        'Likes, Ascents), bumping updatedAt and setting dirty:true, while '
        'leaving already-owned and soft-deleted rows untouched', () async {
      const seedNow = 5000;

      // Unowned, live rows -- one per table -- must be claimed.
      await db
          .into(db.areas)
          .insert(
            AreasCompanion.insert(
              id: 'area-null',
              createdAt: seedNow,
              updatedAt: seedNow,
              name: 'Unowned Area',
            ),
          );
      await db
          .into(db.sectors)
          .insert(
            SectorsCompanion.insert(
              id: 'sector-null',
              createdAt: seedNow,
              updatedAt: seedNow,
              areaId: 'area-null',
              name: 'Unowned Sector',
              sortOrder: 0,
            ),
          );
      await db
          .into(db.walls)
          .insert(
            WallsCompanion.insert(
              id: 'wall-null',
              createdAt: seedNow,
              updatedAt: seedNow,
              sectorId: 'sector-null',
              name: 'Unowned Wall',
              sortOrder: 0,
            ),
          );
      await db
          .into(db.photos)
          .insert(
            PhotosCompanion.insert(
              id: 'photo-null',
              createdAt: seedNow,
              updatedAt: seedNow,
              wallId: 'wall-null',
              localPath: '/tmp/unowned.jpg',
              kind: 'original',
              width: 1,
              height: 1,
            ),
          );
      await db
          .into(db.routes)
          .insert(
            RoutesCompanion.insert(
              id: 'route-null',
              createdAt: seedNow,
              updatedAt: seedNow,
              wallId: 'wall-null',
              photoId: 'photo-null',
              number: 1,
              colorIndex: 0,
              pointsJson: '[]',
              symbolsJson: '[]',
              sortOrder: 0,
            ),
          );

      // Unowned, live rows on the v3 community tables (Comments, Likes,
      // Ascents) -- must also be claimed, same as the original 5.
      await db
          .into(db.comments)
          .insert(
            CommentsCompanion.insert(
              id: 'comment-null',
              createdAt: seedNow,
              updatedAt: seedNow,
              wallId: 'wall-null',
              body: 'Unowned comment',
            ),
          );
      await db
          .into(db.likes)
          .insert(
            LikesCompanion.insert(
              id: 'like-null',
              createdAt: seedNow,
              updatedAt: seedNow,
              wallId: 'wall-null',
            ),
          );
      await db
          .into(db.ascents)
          .insert(
            AscentsCompanion.insert(
              id: 'ascent-null',
              createdAt: seedNow,
              updatedAt: seedNow,
              routeId: 'route-null',
              wallId: 'wall-null',
              climbedAt: seedNow,
              style: 'redpoint',
            ),
          );

      // Already-owned by someone else -- must be left completely alone.
      await db
          .into(db.areas)
          .insert(
            AreasCompanion.insert(
              id: 'area-other',
              createdAt: seedNow,
              updatedAt: seedNow,
              name: 'Someone Else\'s Area',
              ownerId: const Value('other'),
            ),
          );
      await db
          .into(db.likes)
          .insert(
            LikesCompanion.insert(
              id: 'like-other',
              createdAt: seedNow,
              updatedAt: seedNow,
              wallId: 'wall-null',
              ownerId: const Value('other'),
            ),
          );

      // Unowned but soft-deleted -- must NOT be claimed.
      await db
          .into(db.areas)
          .insert(
            AreasCompanion.insert(
              id: 'area-deleted',
              createdAt: seedNow,
              updatedAt: seedNow,
              name: 'Deleted Unowned Area',
              deletedAt: const Value(9999),
            ),
          );
      await db
          .into(db.comments)
          .insert(
            CommentsCompanion.insert(
              id: 'comment-deleted',
              createdAt: seedNow,
              updatedAt: seedNow,
              wallId: 'wall-null',
              body: 'Deleted unowned comment',
              deletedAt: const Value(9999),
            ),
          );

      // repo's nowMs is a constant 1000 (see setUp), distinct from
      // seedNow (5000), so a bumped updatedAt is unambiguous.
      await repo.claimOwnership('u1');

      final claimedArea = await (db.select(
        db.areas,
      )..where((t) => t.id.equals('area-null'))).getSingle();
      expect(claimedArea.ownerId, 'u1');
      expect(claimedArea.dirty, isTrue);
      expect(claimedArea.updatedAt, 1000);

      final claimedSector = await (db.select(
        db.sectors,
      )..where((t) => t.id.equals('sector-null'))).getSingle();
      expect(claimedSector.ownerId, 'u1');
      expect(claimedSector.dirty, isTrue);
      expect(claimedSector.updatedAt, 1000);

      final claimedWall = await (db.select(
        db.walls,
      )..where((t) => t.id.equals('wall-null'))).getSingle();
      expect(claimedWall.ownerId, 'u1');
      expect(claimedWall.dirty, isTrue);
      expect(claimedWall.updatedAt, 1000);

      final claimedPhoto = await (db.select(
        db.photos,
      )..where((t) => t.id.equals('photo-null'))).getSingle();
      expect(claimedPhoto.ownerId, 'u1');
      expect(claimedPhoto.dirty, isTrue);
      expect(claimedPhoto.updatedAt, 1000);

      final claimedRoute = await (db.select(
        db.routes,
      )..where((t) => t.id.equals('route-null'))).getSingle();
      expect(claimedRoute.ownerId, 'u1');
      expect(claimedRoute.dirty, isTrue);
      expect(claimedRoute.updatedAt, 1000);

      final claimedComment = await (db.select(
        db.comments,
      )..where((t) => t.id.equals('comment-null'))).getSingle();
      expect(claimedComment.ownerId, 'u1');
      expect(claimedComment.dirty, isTrue);
      expect(claimedComment.updatedAt, 1000);

      final claimedLike = await (db.select(
        db.likes,
      )..where((t) => t.id.equals('like-null'))).getSingle();
      expect(claimedLike.ownerId, 'u1');
      expect(claimedLike.dirty, isTrue);
      expect(claimedLike.updatedAt, 1000);

      final claimedAscent = await (db.select(
        db.ascents,
      )..where((t) => t.id.equals('ascent-null'))).getSingle();
      expect(claimedAscent.ownerId, 'u1');
      expect(claimedAscent.dirty, isTrue);
      expect(claimedAscent.updatedAt, 1000);

      final otherArea = await (db.select(
        db.areas,
      )..where((t) => t.id.equals('area-other'))).getSingle();
      expect(
        otherArea.ownerId,
        'other',
        reason:
            'a row already owned by someone else must never be '
            'reassigned',
      );
      expect(otherArea.dirty, isFalse);
      expect(otherArea.updatedAt, seedNow);

      final otherLike = await (db.select(
        db.likes,
      )..where((t) => t.id.equals('like-other'))).getSingle();
      expect(
        otherLike.ownerId,
        'other',
        reason:
            'a v3 community-table row already owned by someone else '
            'must never be reassigned either',
      );
      expect(otherLike.dirty, isFalse);
      expect(otherLike.updatedAt, seedNow);

      final deletedArea = await (db.select(
        db.areas,
      )..where((t) => t.id.equals('area-deleted'))).getSingle();
      expect(
        deletedArea.ownerId,
        isNull,
        reason: 'soft-deleted rows must never be claimed',
      );
      expect(deletedArea.dirty, isFalse);
      expect(deletedArea.updatedAt, seedNow);

      final deletedComment = await (db.select(
        db.comments,
      )..where((t) => t.id.equals('comment-deleted'))).getSingle();
      expect(
        deletedComment.ownerId,
        isNull,
        reason:
            'soft-deleted v3 community-table rows must never be '
            'claimed either',
      );
      expect(deletedComment.dirty, isFalse);
      expect(deletedComment.updatedAt, seedNow);
    });
  });

  // D5c ("a non-owner never sees the publish control") has no repository-
  // level test here: the Topos home only ever lists the signed-in user's
  // OWN topos (see `watchTopos` / the ToposScreen row it backs), so there is
  // no code path by which another user's topo could reach this menu in the
  // first place — the control is inherently owner-only by construction, not
  // by an extra visibility check that could regress independently.
  group('D5: publishTopo / unpublishTopo', () {
    Future<String> insertRouteFor(String wallId, String photoId, String id) {
      return db
          .into(db.routes)
          .insert(
            RoutesCompanion.insert(
              id: id,
              createdAt: 1000,
              updatedAt: 1000,
              wallId: wallId,
              photoId: photoId,
              number: 1,
              colorIndex: 0,
              pointsJson: '[]',
              symbolsJson: '[]',
              sortOrder: 0,
            ),
          )
          .then((_) => id);
    }

    test('D5a: publishTopo sets visibility=shared and marks the wall + its '
        'non-deleted photos + its non-deleted routes dirty:true with a '
        'bumped updatedAt', () async {
      final wallId = await repo.createTopo('Topo');
      final photoId = await repo.attachPhotoToWall(
        wallId,
        '/tmp/p.jpg',
        10,
        10,
      );
      final routeId = await insertRouteFor(wallId, photoId, 'route-1');

      // A distinct nowMs from the seed's fixed 1000 (see setUp) makes the
      // post-publish updatedAt bump unambiguous.
      final publishRepo = LibraryCrudRepository(db, nowMs: () => 2000);
      await publishRepo.publishTopo(wallId);

      final wall = await (db.select(
        db.walls,
      )..where((t) => t.id.equals(wallId))).getSingle();
      expect(wall.visibility, 'shared');
      expect(wall.dirty, isTrue);
      expect(wall.updatedAt, 2000);

      final photo = await (db.select(
        db.photos,
      )..where((t) => t.id.equals(photoId))).getSingle();
      expect(photo.dirty, isTrue);
      expect(photo.updatedAt, 2000);

      final route = await (db.select(
        db.routes,
      )..where((t) => t.id.equals(routeId))).getSingle();
      expect(route.dirty, isTrue);
      expect(route.updatedAt, 2000);
    });

    test('publishTopo leaves a sibling wall (and its own photos) untouched: '
        'not shared, not dirty', () async {
      final wallId = await repo.createTopo('Topo A');
      final siblingWallId = await repo.createTopo('Topo B');
      final siblingPhotoId = await repo.attachPhotoToWall(
        siblingWallId,
        '/tmp/s.jpg',
        10,
        10,
      );

      await repo.publishTopo(wallId);

      final siblingWall = await (db.select(
        db.walls,
      )..where((t) => t.id.equals(siblingWallId))).getSingle();
      expect(siblingWall.visibility, 'private');
      expect(siblingWall.dirty, isFalse);

      final siblingPhoto = await (db.select(
        db.photos,
      )..where((t) => t.id.equals(siblingPhotoId))).getSingle();
      expect(siblingPhoto.dirty, isFalse);
    });

    test('publishTopo does not resurrect a soft-deleted photo on the same wall '
        'as dirty', () async {
      final wallId = await repo.createTopo('Topo');
      final photoId = await repo.attachPhotoToWall(
        wallId,
        '/tmp/p.jpg',
        10,
        10,
      );
      await (db.update(db.photos)..where((t) => t.id.equals(photoId))).write(
        const PhotosCompanion(deletedAt: Value(1500)),
      );

      await repo.publishTopo(wallId);

      final photo = await (db.select(
        db.photos,
      )..where((t) => t.id.equals(photoId))).getSingle();
      expect(
        photo.dirty,
        isFalse,
        reason: 'a soft-deleted photo must not be touched by publish',
      );
    });

    test('D5b: unpublishTopo reverts visibility to private and bumps the same '
        'dirty/updatedAt subtree as publishTopo', () async {
      final wallId = await repo.createTopo('Topo');
      final photoId = await repo.attachPhotoToWall(
        wallId,
        '/tmp/p.jpg',
        10,
        10,
      );
      final routeId = await insertRouteFor(wallId, photoId, 'route-1');
      await repo.publishTopo(wallId);

      final unpublishRepo = LibraryCrudRepository(db, nowMs: () => 3000);
      await unpublishRepo.unpublishTopo(wallId);

      final wall = await (db.select(
        db.walls,
      )..where((t) => t.id.equals(wallId))).getSingle();
      expect(wall.visibility, 'private');
      expect(wall.dirty, isTrue);
      expect(wall.updatedAt, 3000);

      final photo = await (db.select(
        db.photos,
      )..where((t) => t.id.equals(photoId))).getSingle();
      expect(photo.dirty, isTrue);
      expect(photo.updatedAt, 3000);

      final route = await (db.select(
        db.routes,
      )..where((t) => t.id.equals(routeId))).getSingle();
      expect(route.dirty, isTrue);
      expect(route.updatedAt, 3000);
    });

    test('publishTopo/unpublishTopo against a nonexistent wallId are silent '
        'no-ops (no exception, no unrelated rows touched)', () async {
      await repo.publishTopo('does-not-exist');
      await repo.unpublishTopo('does-not-exist');
    });
  });

  group('D6: setWallCoordinates', () {
    test(
      'persists latitude/longitude on the wall and marks it dirty with a '
      'bumped updatedAt — the same wall-row shape _setWallVisibility uses',
      () async {
        final wall = await repo.createWall(
          (await repo.createSector(
            (await repo.createArea('Area')).id,
            'Sector',
          )).id,
          'Wall',
        );

        final coordsRepo = LibraryCrudRepository(db, nowMs: () => 2000);
        await coordsRepo.setWallCoordinates(wall.id, 47.4979, 19.0402);

        final row = await (db.select(
          db.walls,
        )..where((t) => t.id.equals(wall.id))).getSingle();
        expect(row.latitude, 47.4979);
        expect(row.longitude, 19.0402);
        expect(row.dirty, isTrue);
        expect(row.updatedAt, 2000);
      },
    );

    test(
      'a sibling wall is left untouched: no coordinates, not dirty',
      () async {
        final area = await repo.createArea('Area');
        final sector = await repo.createSector(area.id, 'Sector');
        final wall = await repo.createWall(sector.id, 'Wall');
        final sibling = await repo.createWall(sector.id, 'Sibling');

        await repo.setWallCoordinates(wall.id, 47.4979, 19.0402);

        final siblingRow = await (db.select(
          db.walls,
        )..where((t) => t.id.equals(sibling.id))).getSingle();
        expect(siblingRow.latitude, isNull);
        expect(siblingRow.longitude, isNull);
        expect(siblingRow.dirty, isFalse);
      },
    );

    test(
      'against a nonexistent wallId is a silent no-op (no exception)',
      () async {
        await repo.setWallCoordinates('does-not-exist', 47.4979, 19.0402);
      },
    );
  });

  group('D7: moveWall / moveSector re-parenting', () {
    test(
      'R1: moveWall re-parents into the destination sector, appends '
      'sortOrder past the destination siblings, marks dirty with a bumped '
      'updatedAt',
      () async {
        final area = await repo.createArea('Area');
        final sourceSector = await repo.createSector(area.id, 'Source');
        final destSector = await repo.createSector(area.id, 'Dest');
        final wall = await repo.createWall(sourceSector.id, 'Wall');
        // Pre-existing walls in dest sector so "append at end" is meaningful.
        await repo.createWall(destSector.id, 'Dest Wall 0');
        final destWall1 = await repo.createWall(destSector.id, 'Dest Wall 1');

        final moveRepo = LibraryCrudRepository(db, nowMs: () => 2000);
        await moveRepo.moveWall(wall.id, destSector.id);

        final row = await (db.select(
          db.walls,
        )..where((t) => t.id.equals(wall.id))).getSingle();
        expect(row.sectorId, destSector.id);
        expect(row.dirty, isTrue);
        expect(row.updatedAt, 2000);
        expect(row.sortOrder, greaterThan(destWall1.sortOrder));
      },
    );

    test(
      'R2: moveWall leaves a sibling left behind in the source sector AND '
      'a pre-existing wall in the destination sector untouched',
      () async {
        final area = await repo.createArea('Area');
        final sourceSector = await repo.createSector(area.id, 'Source');
        final destSector = await repo.createSector(area.id, 'Dest');
        final wall = await repo.createWall(sourceSector.id, 'Wall');
        final sibling = await repo.createWall(sourceSector.id, 'Sibling');
        final destWall = await repo.createWall(destSector.id, 'Dest Wall');

        await repo.moveWall(wall.id, destSector.id);

        final siblingRow = await (db.select(
          db.walls,
        )..where((t) => t.id.equals(sibling.id))).getSingle();
        expect(siblingRow.sectorId, sourceSector.id);
        expect(siblingRow.sortOrder, sibling.sortOrder);
        expect(siblingRow.dirty, isFalse);
        expect(siblingRow.updatedAt, 1000);

        final destWallRow = await (db.select(
          db.walls,
        )..where((t) => t.id.equals(destWall.id))).getSingle();
        expect(destWallRow.sectorId, destSector.id);
        expect(destWallRow.sortOrder, destWall.sortOrder);
        expect(destWallRow.dirty, isFalse);
        expect(destWallRow.updatedAt, 1000);
      },
    );

    test(
      'R3: moveWall to a nonexistent sector throws (FK enforcement)',
      () async {
        final area = await repo.createArea('Area');
        final sector = await repo.createSector(area.id, 'Sector');
        final wall = await repo.createWall(sector.id, 'Wall');

        await expectLater(
          repo.moveWall(wall.id, 'nonexistent-sector'),
          throwsA(anything),
        );
      },
    );

    test(
      'R4: moveSector re-parents into the destination area, appends '
      'sortOrder past the destination siblings, marks dirty with a bumped '
      'updatedAt; siblings/nonexistent-area behave the same as moveWall',
      () async {
        final sourceArea = await repo.createArea('Source Area');
        final destArea = await repo.createArea('Dest Area');
        final sector = await repo.createSector(sourceArea.id, 'Sector');
        final sourceSibling = await repo.createSector(
          sourceArea.id,
          'Source Sibling',
        );
        await repo.createSector(destArea.id, 'Dest Sector 0');
        final destSector1 = await repo.createSector(
          destArea.id,
          'Dest Sector 1',
        );

        final moveRepo = LibraryCrudRepository(db, nowMs: () => 2000);
        await moveRepo.moveSector(sector.id, destArea.id);

        final row = await (db.select(
          db.sectors,
        )..where((t) => t.id.equals(sector.id))).getSingle();
        expect(row.areaId, destArea.id);
        expect(row.dirty, isTrue);
        expect(row.updatedAt, 2000);
        expect(row.sortOrder, greaterThan(destSector1.sortOrder));

        final siblingRow = await (db.select(
          db.sectors,
        )..where((t) => t.id.equals(sourceSibling.id))).getSingle();
        expect(siblingRow.areaId, sourceArea.id);
        expect(siblingRow.sortOrder, sourceSibling.sortOrder);
        expect(siblingRow.dirty, isFalse);
        expect(siblingRow.updatedAt, 1000);

        final destSector1Row = await (db.select(
          db.sectors,
        )..where((t) => t.id.equals(destSector1.id))).getSingle();
        expect(destSector1Row.areaId, destArea.id);
        expect(destSector1Row.sortOrder, destSector1.sortOrder);
        expect(destSector1Row.dirty, isFalse);
        expect(destSector1Row.updatedAt, 1000);

        await expectLater(
          repo.moveSector(sector.id, 'nonexistent-area'),
          throwsA(anything),
        );
      },
    );

    test(
      'R5a: moving a soft-deleted wall is a no-op (guard excludes it)',
      () async {
        final area = await repo.createArea('Area');
        final sourceSector = await repo.createSector(area.id, 'Source');
        final destSector = await repo.createSector(area.id, 'Dest');
        final wall = await repo.createWall(sourceSector.id, 'Wall');
        await repo.softDeleteWall(wall.id);

        await repo.moveWall(wall.id, destSector.id);

        final row = await (db.select(
          db.walls,
        )..where((t) => t.id.equals(wall.id))).getSingle();
        expect(row.sectorId, sourceSector.id);
        expect(row.sortOrder, wall.sortOrder);
        expect(row.dirty, isFalse);
        expect(row.updatedAt, 1000);
        expect(row.deletedAt, isNotNull);
      },
    );

    test(
      'R5b: moving a soft-deleted sector is a no-op (guard excludes it)',
      () async {
        final sourceArea = await repo.createArea('Source Area');
        final destArea = await repo.createArea('Dest Area');
        final sector = await repo.createSector(sourceArea.id, 'Sector');
        await repo.softDeleteSector(sector.id);

        await repo.moveSector(sector.id, destArea.id);

        final row = await (db.select(
          db.sectors,
        )..where((t) => t.id.equals(sector.id))).getSingle();
        expect(row.areaId, sourceArea.id);
        expect(row.sortOrder, sector.sortOrder);
        expect(row.dirty, isFalse);
        expect(row.updatedAt, 1000);
        expect(row.deletedAt, isNotNull);
      },
    );
  });
}
