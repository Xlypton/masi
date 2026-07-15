import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/features/community/data/community_repository.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// Covers Subtask B's B1 assertion: `watchSharedTopos` enriches `SharedTopo`
/// with `routeGradeKeys`/`routeStyles`, parsed correctly from the query's
/// `group_concat` columns, while every pre-existing field/behavior is
/// unchanged.
void main() {
  late AppDatabase db;
  late CommunityRepository repo;

  Future<void> seedArea(
    String id, {
    String name = 'Area',
    double? latitude,
    double? longitude,
  }) {
    return db
        .into(db.areas)
        .insert(
          AreasCompanion.insert(
            id: id,
            createdAt: 1000,
            updatedAt: 1000,
            name: name,
            latitude: Value(latitude),
            longitude: Value(longitude),
          ),
        );
  }

  Future<void> seedSector(String id, {required String areaId}) {
    return db
        .into(db.sectors)
        .insert(
          SectorsCompanion.insert(
            id: id,
            createdAt: 1000,
            updatedAt: 1000,
            areaId: areaId,
            name: 'Sector',
            sortOrder: 0,
          ),
        );
  }

  Future<void> seedWall(
    String id, {
    required String sectorId,
    String name = 'Wall',
    String visibility = 'shared',
    double? latitude,
    double? longitude,
  }) {
    return db
        .into(db.walls)
        .insert(
          WallsCompanion.insert(
            id: id,
            createdAt: 1000,
            updatedAt: 1000,
            sectorId: sectorId,
            name: name,
            sortOrder: 0,
            visibility: Value(visibility),
            latitude: Value(latitude),
            longitude: Value(longitude),
          ),
        );
  }

  Future<String> seedPhoto(String id, {required String wallId}) {
    return db
        .into(db.photos)
        .insert(
          PhotosCompanion.insert(
            id: id,
            createdAt: 1000,
            updatedAt: 1000,
            wallId: wallId,
            localPath: '/tmp/$id.jpg',
            kind: 'original',
            width: 100,
            height: 100,
          ),
        )
        .then((_) => id);
  }

  /// Seeds a single non-deleted route on [wallId]/[photoId]. [number] must
  /// be distinct per wall (unique index on live routes).
  Future<void> seedRoute(
    String id, {
    required String wallId,
    required String photoId,
    required int number,
    String? gradeRaw,
    double? gradeSortKey,
    String? style,
    int? deletedAt,
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
            gradeSortKey: Value(gradeSortKey),
            style: Value(style),
            deletedAt: Value(deletedAt),
          ),
        );
  }

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = CommunityRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('B1: routeGradeKeys + routeStyles on SharedTopo', () {
    test(
      'a wall with graded, styled routes exposes their sort keys and '
      'lowercased styles, deduplicated',
      () async {
        await seedArea('area-1');
        await seedSector('sector-1', areaId: 'area-1');
        await seedWall('wall-1', sectorId: 'sector-1');
        final photoId = await seedPhoto('photo-1', wallId: 'wall-1');

        await seedRoute(
          'route-1',
          wallId: 'wall-1',
          photoId: photoId,
          number: 1,
          gradeRaw: '6a',
          gradeSortKey: 7.0,
          style: 'Sport',
        );
        await seedRoute(
          'route-2',
          wallId: 'wall-1',
          photoId: photoId,
          number: 2,
          gradeRaw: '7a',
          gradeSortKey: 13.0,
          style: 'TRAD',
        );
        // A duplicate grade/style pair -- must be deduplicated.
        await seedRoute(
          'route-3',
          wallId: 'wall-1',
          photoId: photoId,
          number: 3,
          gradeRaw: '6a',
          gradeSortKey: 7.0,
          style: ' sport ',
        );

        final topos = await repo.watchSharedTopos().first;
        final topo = topos.singleWhere((t) => t.wallId == 'wall-1');

        expect(topo.routeGradeKeys, [7.0, 13.0]);
        expect(topo.routeStyles, {'sport', 'trad'});
        // Existing fields still correct.
        expect(topo.routeCount, 3);
        expect(topo.topGradeLabel, '7a');
      },
    );

    test(
      'a wall with no routes at all exposes empty routeGradeKeys/'
      'routeStyles (not null, not a crash)',
      () async {
        await seedArea('area-2');
        await seedSector('sector-2', areaId: 'area-2');
        await seedWall('wall-2', sectorId: 'sector-2');

        final topos = await repo.watchSharedTopos().first;
        final topo = topos.singleWhere((t) => t.wallId == 'wall-2');

        expect(topo.routeGradeKeys, isEmpty);
        expect(topo.routeStyles, isEmpty);
        expect(topo.routeCount, 0);
      },
    );

    test(
      'ungraded routes contribute no grade key; unstyled (null/empty) '
      'routes contribute no style, but both are still counted in '
      'routeCount',
      () async {
        await seedArea('area-3');
        await seedSector('sector-3', areaId: 'area-3');
        await seedWall('wall-3', sectorId: 'sector-3');
        final photoId = await seedPhoto('photo-3', wallId: 'wall-3');

        await seedRoute(
          'route-ungraded',
          wallId: 'wall-3',
          photoId: photoId,
          number: 1,
        );
        await seedRoute(
          'route-empty-style',
          wallId: 'wall-3',
          photoId: photoId,
          number: 2,
          gradeRaw: '6b',
          gradeSortKey: 9.0,
          style: '',
        );

        final topos = await repo.watchSharedTopos().first;
        final topo = topos.singleWhere((t) => t.wallId == 'wall-3');

        expect(topo.routeGradeKeys, [9.0]);
        expect(topo.routeStyles, isEmpty);
        expect(topo.routeCount, 2);
      },
    );

    test(
      'a soft-deleted route is excluded from both routeGradeKeys and '
      'routeStyles (and from routeCount)',
      () async {
        await seedArea('area-4');
        await seedSector('sector-4', areaId: 'area-4');
        await seedWall('wall-4', sectorId: 'sector-4');
        final photoId = await seedPhoto('photo-4', wallId: 'wall-4');

        await seedRoute(
          'route-live',
          wallId: 'wall-4',
          photoId: photoId,
          number: 1,
          gradeRaw: '6a',
          gradeSortKey: 7.0,
          style: 'sport',
        );
        await seedRoute(
          'route-deleted',
          wallId: 'wall-4',
          photoId: photoId,
          number: 2,
          gradeRaw: '9a',
          gradeSortKey: 25.0,
          style: 'boulder',
          deletedAt: 2000,
        );

        final topos = await repo.watchSharedTopos().first;
        final topo = topos.singleWhere((t) => t.wallId == 'wall-4');

        expect(topo.routeGradeKeys, [7.0]);
        expect(topo.routeStyles, {'sport'});
        expect(topo.routeCount, 1);
      },
    );

    test(
      'a private (non-shared) wall never appears in watchSharedTopos at '
      'all, regardless of its routes',
      () async {
        await seedArea('area-5');
        await seedSector('sector-5', areaId: 'area-5');
        await seedWall(
          'wall-private',
          sectorId: 'sector-5',
          visibility: 'private',
        );
        final photoId = await seedPhoto('photo-5', wallId: 'wall-private');
        await seedRoute(
          'route-private',
          wallId: 'wall-private',
          photoId: photoId,
          number: 1,
          gradeRaw: '6a',
          gradeSortKey: 7.0,
          style: 'sport',
        );

        final topos = await repo.watchSharedTopos().first;
        expect(topos.any((t) => t.wallId == 'wall-private'), isFalse);
      },
    );
  });

  group('B2: SharedTopo coordinates come from the WALL, not the Area', () {
    test(
      'a shared wall with its own coordinates exposes those exact '
      'coordinates, even when its ancestor Area has DIFFERENT coordinates '
      'set (regression: coordinates must no longer be read off the Area)',
      () async {
        await seedArea('area-6', latitude: 1.0, longitude: 2.0);
        await seedSector('sector-6', areaId: 'area-6');
        await seedWall(
          'wall-6',
          sectorId: 'sector-6',
          latitude: 47.4979,
          longitude: 19.0402,
        );

        final topos = await repo.watchSharedTopos().first;
        final topo = topos.singleWhere((t) => t.wallId == 'wall-6');

        expect(topo.latitude, 47.4979);
        expect(topo.longitude, 19.0402);
        expect(topo.hasCoordinates, isTrue);
      },
    );

    test(
      'a shared wall with no coordinates of its own reports null/null '
      '(NOT falling back to its ancestor Area\'s coordinates), and '
      'hasCoordinates is false so the map view can omit it',
      () async {
        await seedArea('area-7', latitude: 1.0, longitude: 2.0);
        await seedSector('sector-7', areaId: 'area-7');
        await seedWall('wall-7', sectorId: 'sector-7');

        final topos = await repo.watchSharedTopos().first;
        final topo = topos.singleWhere((t) => t.wallId == 'wall-7');

        expect(topo.latitude, isNull);
        expect(topo.longitude, isNull);
        expect(topo.hasCoordinates, isFalse);
      },
    );
  });
}
