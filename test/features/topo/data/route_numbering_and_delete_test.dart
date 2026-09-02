// Two rules a topo has to obey that it did not, both reported on 2026-09-02.
//
//  1. "Deleting a route should only delete it from that picture. If it was the
//     last picture it was shown on, then and only then delete it altogether."
//     Deleting from a climb's HOME photo used to tombstone the climb outright
//     — its name, its grade, its stars and every ascent logged against it —
//     even when the same climb was still drawn on two other faces of the rock.
//  2. "Renumber routes if needed, always show the route number from left to
//     right." Numbers were handed out in the order lines were DRAWN, which is
//     the one order a guidebook never uses. (Added in the commit after this
//     one; its tests join this file there.)
//
// Both live in `RouteRepository`, and both are tested here against a real
// in-memory drift database rather than a fake, because the parts that can go
// wrong are the parts a fake would not have: the partial unique index on
// `(wallId, number)` that a naive renumber trips halfway through, and the
// `route_lines` promotion that has to leave exactly one drawing per photo.

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:masi/core/db/app_database.dart';
import 'package:masi/features/topo/data/route_repository.dart';
import 'package:masi/features/topo/domain/topo_route.dart';

void main() {
  const wallId = 'wall-1';
  const photoOne = 'photo-1';
  const photoTwo = 'photo-2';
  const now = 1000;

  late AppDatabase db;
  late RouteRepository repository;

  Future<void> seedWall() async {
    await db
        .into(db.areas)
        .insert(
          AreasCompanion.insert(
            id: 'area-1',
            createdAt: now,
            updatedAt: now,
            name: 'Area',
          ),
        );
    await db
        .into(db.sectors)
        .insert(
          SectorsCompanion.insert(
            id: 'sector-1',
            createdAt: now,
            updatedAt: now,
            areaId: 'area-1',
            name: 'Sector',
            sortOrder: 0,
          ),
        );
    await db
        .into(db.walls)
        .insert(
          WallsCompanion.insert(
            id: wallId,
            createdAt: now,
            updatedAt: now,
            sectorId: 'sector-1',
            name: 'Wall',
            sortOrder: 0,
          ),
        );
    var order = 0;
    for (final id in const [photoOne, photoTwo]) {
      await db
          .into(db.photos)
          .insert(
            PhotosCompanion.insert(
              id: id,
              createdAt: now,
              updatedAt: now,
              wallId: wallId,
              localPath: '/tmp/$id.jpg',
              kind: 'original',
              width: 100,
              height: 200,
              sortOrder: Value(order++),
            ),
          );
    }
  }

  /// A line whose BASE (its bottom-most point, where a climber starts) sits at
  /// [baseX], and whose top wanders elsewhere — so a test that passes by
  /// reading the first point rather than the base would fail.
  List<Offset> lineAt(double baseX) => [
    Offset(1 - baseX, 0.1),
    Offset(baseX, 0.9),
  ];

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    repository = RouteRepository(db, nowMs: () => now);
    await seedWall();
  });

  tearDown(() async => db.close());

  group('deleting a line', () {
    test('on the climb\'s HOME photo keeps the climb when another photo still '
        'shows it — the other line is promoted to home, with the name, grade '
        'and stars intact', () async {
      await repository.upsertRoute(
        wallId,
        photoOne,
        TopoRoute(
          id: 1,
          number: 1,
          points: lineAt(0.2),
          name: 'Wedding tour',
          gradeRaw: '6a',
          stars: 3,
        ),
      );
      // The same climb, seen from the second photo. The whole climb is
      // passed, not a bare line: `upsertRoute`'s third case folds the shared
      // fields onto the climb, so handing it a nameless route would blank the
      // name — which is what every caller of this path already does (see
      // `DrawController.commitDraftAsClimb`).
      await repository.upsertRoute(
        wallId,
        photoTwo,
        TopoRoute(
          id: 1,
          number: 1,
          points: lineAt(0.7),
          name: 'Wedding tour',
          gradeRaw: '6a',
          stars: 3,
        ),
      );
      expect(await db.select(db.routeLines).get(), hasLength(1));

      await repository.softDeleteRoute(wallId, photoOne, 1);

      final climbs = await (db.select(
        db.routes,
      )..where((t) => t.deletedAt.isNull())).get();
      expect(
        climbs,
        hasLength(1),
        reason: 'the climb is still drawn somewhere, so it still exists',
      );
      expect(climbs.single.name, 'Wedding tour');
      expect(climbs.single.gradeRaw, '6a');
      expect(climbs.single.stars, 3);
      expect(
        climbs.single.photoId,
        photoTwo,
        reason: 'the surviving line was promoted to be the home drawing',
      );

      expect(
        await repository.loadRoutes(wallId, photoOne),
        isEmpty,
        reason: 'the photo it was deleted from shows nothing',
      );
      final onTwo = await repository.loadRoutes(wallId, photoTwo);
      expect(onTwo, hasLength(1), reason: 'and exactly once on the other');
      expect(onTwo.single.name, 'Wedding tour');

      final liveLines = await (db.select(
        db.routeLines,
      )..where((t) => t.deletedAt.isNull())).get();
      expect(
        liveLines,
        isEmpty,
        reason:
            'the promoted line must not survive as a route_lines row as well '
            '— that is the same drawing twice, and the partial unique index '
            'forbids a line on the home photo',
      );
    });

    test('on the LAST photo showing it deletes the climb altogether', () async {
      await repository.upsertRoute(
        wallId,
        photoOne,
        TopoRoute(id: 1, number: 1, points: lineAt(0.2), name: 'Solo'),
      );

      await repository.softDeleteRoute(wallId, photoOne, 1);

      final live = await (db.select(
        db.routes,
      )..where((t) => t.deletedAt.isNull())).get();
      expect(live, isEmpty);
      final all = await db.select(db.routes).get();
      expect(
        all.single.deletedAt,
        now,
        reason: 'tombstoned, not physically removed — sync needs the row',
      );
      expect(all.single.dirty, isTrue);
    });

    test(
      'on a photo that is NOT its home still only removes that line',
      () async {
        await repository.upsertRoute(
          wallId,
          photoOne,
          TopoRoute(id: 1, number: 1, points: lineAt(0.2), name: 'Arete'),
        );
        await repository.upsertRoute(
          wallId,
          photoTwo,
          TopoRoute(id: 1, number: 1, points: lineAt(0.7), name: 'Arete'),
        );

        await repository.softDeleteRoute(wallId, photoTwo, 1);

        final climbs = await (db.select(
          db.routes,
        )..where((t) => t.deletedAt.isNull())).get();
        expect(climbs.single.photoId, photoOne);
        expect(climbs.single.name, 'Arete');
        expect(await repository.loadRoutes(wallId, photoTwo), isEmpty);
      },
    );
  });
}
