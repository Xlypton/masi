// Tests for the unified map search's data layer additions to
// `LibraryCrudRepository`: `watchLocatedRoutes` (A2 — routes joined to their
// wall's GPS coordinates) and `watchLocatedSectors`/`watchLocatedAreas` (A3 —
// derived centroids over located descendant walls, with zero-located-walls
// exclusion). See `lib/features/community/data/map_search.dart`'s
// `mapContentSearch`, which consumes these three streams alongside the
// pre-existing `toposProvider`.
import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/features/library/data/library_crud_repository.dart';
import 'package:drift/drift.dart' show Value;
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

  /// Inserts a route row directly (bypassing `RouteRepository`, which is
  /// scoped to a single wall's domain model) — mirrors the `insertRoute`
  /// helper in `library_crud_repository_test.dart`'s `A7: watchTopos` group.
  Future<String> insertRoute(
    String wallId,
    String photoId,
    String id, {
    int number = 1,
    String? name,
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
            name: Value(name),
            colorIndex: 0,
            pointsJson: '[]',
            symbolsJson: '[]',
            sortOrder: number,
          ),
        )
        .then((_) => id);
  }

  group('A2: watchLocatedRoutes', () {
    test(
      'returns a named route paired with its wall name + coordinates',
      () async {
        final area = await repo.createArea('Area');
        final sector = await repo.createSector(area.id, 'Sector');
        final wall = await repo.createWall(sector.id, 'Topo Wall');
        final photoId = await repo.attachPhotoToWall(
          wall.id,
          '/tmp/p.jpg',
          100,
          200,
        );
        await repo.setWallCoordinates(wall.id, 10.0, 20.0);
        await insertRoute(wall.id, photoId, 'r1', name: 'Great Arete');

        final located = await repo.watchLocatedRoutes().first;

        expect(located, hasLength(1));
        final route = located.single;
        expect(route.title, 'Great Arete');
        expect(route.wallId, wall.id);
        expect(route.wallName, 'Topo Wall');
        expect(route.latitude, 10.0);
        expect(route.longitude, 20.0);
      },
    );

    test("an unnamed route's title falls back to 'Route <number>'", () async {
      final area = await repo.createArea('Area');
      final sector = await repo.createSector(area.id, 'Sector');
      final wall = await repo.createWall(sector.id, 'Wall');
      final photoId = await repo.attachPhotoToWall(
        wall.id,
        '/tmp/p.jpg',
        100,
        200,
      );
      await repo.setWallCoordinates(wall.id, 1.0, 2.0);
      await insertRoute(wall.id, photoId, 'r1', number: 3);
      // Name explicitly blank (whitespace-only), not just absent.
      await insertRoute(wall.id, photoId, 'r2', number: 4, name: '   ');

      final located = await repo.watchLocatedRoutes().first;

      final titles = located.map((r) => r.title).toSet();
      expect(titles, {'Route 3', 'Route 4'});
    });

    test('excludes a route whose wall has no coordinates', () async {
      final area = await repo.createArea('Area');
      final sector = await repo.createSector(area.id, 'Sector');
      final wall = await repo.createWall(sector.id, 'Wall');
      final photoId = await repo.attachPhotoToWall(
        wall.id,
        '/tmp/p.jpg',
        100,
        200,
      );
      // Deliberately never calls setWallCoordinates.
      await insertRoute(wall.id, photoId, 'r1', name: 'Unlocated Route');

      final located = await repo.watchLocatedRoutes().first;

      expect(located, isEmpty);
    });

    test(
      'excludes a soft-deleted route on an otherwise-located wall',
      () async {
        final area = await repo.createArea('Area');
        final sector = await repo.createSector(area.id, 'Sector');
        final wall = await repo.createWall(sector.id, 'Wall');
        final photoId = await repo.attachPhotoToWall(
          wall.id,
          '/tmp/p.jpg',
          100,
          200,
        );
        await repo.setWallCoordinates(wall.id, 5.0, 6.0);
        final routeId = await insertRoute(
          wall.id,
          photoId,
          'r1',
          name: 'Deleted Route',
        );
        await (db.update(db.routes)..where((t) => t.id.equals(routeId))).write(
          const RoutesCompanion(deletedAt: Value(2000)),
        );

        final located = await repo.watchLocatedRoutes().first;

        expect(located, isEmpty);
      },
    );

    test('excludes a route on a soft-deleted wall', () async {
      final area = await repo.createArea('Area');
      final sector = await repo.createSector(area.id, 'Sector');
      final wall = await repo.createWall(sector.id, 'Wall');
      final photoId = await repo.attachPhotoToWall(
        wall.id,
        '/tmp/p.jpg',
        100,
        200,
      );
      await repo.setWallCoordinates(wall.id, 5.0, 6.0);
      await insertRoute(wall.id, photoId, 'r1', name: 'Route On Deleted Wall');
      await repo.softDeleteWall(wall.id);

      final located = await repo.watchLocatedRoutes().first;

      expect(located, isEmpty);
    });
  });

  group('A3: watchLocatedSectors (centroid over located child walls)', () {
    test('centroid is the mean lat/long over exactly the located walls, '
        'ignoring an unlocated sibling wall', () async {
      final area = await repo.createArea('Area');
      final sector = await repo.createSector(area.id, 'Boulder Field');
      final wallA = await repo.createWall(sector.id, 'Wall A');
      final wallB = await repo.createWall(sector.id, 'Wall B');
      // A third wall left deliberately without coordinates -- it must not
      // pull the centroid.
      await repo.createWall(sector.id, 'Wall C (no coords)');
      await repo.setWallCoordinates(wallA.id, 10.0, 20.0);
      await repo.setWallCoordinates(wallB.id, 12.0, 24.0);

      final located = await repo.watchLocatedSectors().first;

      expect(located, hasLength(1));
      final result = located.single;
      expect(result.id, sector.id);
      expect(result.name, 'Boulder Field');
      expect(result.latitude, closeTo(11.0, 1e-9));
      expect(result.longitude, closeTo(22.0, 1e-9));
    });

    test(
      'a sector with zero located walls (none at all) is excluded',
      () async {
        final area = await repo.createArea('Area');
        await repo.createSector(area.id, 'Empty Sector');

        final located = await repo.watchLocatedSectors().first;

        expect(located, isEmpty);
      },
    );

    test(
      'a sector whose walls exist but none have coordinates is excluded',
      () async {
        final area = await repo.createArea('Area');
        final sector = await repo.createSector(area.id, 'Sector');
        await repo.createWall(sector.id, 'Wall (no coords)');

        final located = await repo.watchLocatedSectors().first;

        expect(located, isEmpty);
      },
    );

    test('excludes the hidden __default__ sentinel sector', () async {
      // createTopo files a photo-first wall under the hidden default
      // area/sector (see LibraryCrudRepository.createTopo).
      final wallId = await repo.createTopo('Photo-first topo');
      await repo.setWallCoordinates(wallId, 1.0, 2.0);

      final located = await repo.watchLocatedSectors().first;

      expect(located, isEmpty);
    });
  });

  group('A3: watchLocatedAreas (centroid over ALL located walls under ALL '
      'its sectors)', () {
    test('centroid averages every located wall across every sector, NOT '
        'the mean of each sector centroid', () async {
      final area = await repo.createArea('Area');
      final sectorA = await repo.createSector(area.id, 'Sector A');
      final sectorB = await repo.createSector(area.id, 'Sector B');

      // Sector A: a single located wall at (0, 0).
      final wallA = await repo.createWall(sectorA.id, 'Wall A');
      await repo.setWallCoordinates(wallA.id, 0.0, 0.0);

      // Sector B: three located walls, all at (10, 0).
      final wallB1 = await repo.createWall(sectorB.id, 'Wall B1');
      final wallB2 = await repo.createWall(sectorB.id, 'Wall B2');
      final wallB3 = await repo.createWall(sectorB.id, 'Wall B3');
      await repo.setWallCoordinates(wallB1.id, 10.0, 0.0);
      await repo.setWallCoordinates(wallB2.id, 10.0, 0.0);
      await repo.setWallCoordinates(wallB3.id, 10.0, 0.0);

      final located = await repo.watchLocatedAreas().first;

      expect(located, hasLength(1));
      final result = located.single;
      expect(result.id, area.id);
      // Mean over all 4 located walls: (0+10+10+10)/4 = 7.5 — NOT the
      // mean of the two sector centroids ((0 + 10) / 2 = 5).
      expect(result.latitude, closeTo(7.5, 1e-9));
      expect(result.longitude, closeTo(0.0, 1e-9));
    });

    test(
      'an area with zero located walls anywhere under it is excluded',
      () async {
        final area = await repo.createArea('Area');
        final sector = await repo.createSector(area.id, 'Sector');
        await repo.createWall(sector.id, 'Wall (no coords)');

        final located = await repo.watchLocatedAreas().first;

        expect(located, isEmpty);
      },
    );

    test('excludes the hidden __default__ sentinel area', () async {
      final wallId = await repo.createTopo('Photo-first topo');
      await repo.setWallCoordinates(wallId, 1.0, 2.0);

      final located = await repo.watchLocatedAreas().first;

      expect(located, isEmpty);
    });
  });
}
