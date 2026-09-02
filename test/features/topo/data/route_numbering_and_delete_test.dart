// Two rules a topo has to obey that it did not, both reported on 2026-09-02.
//
//  1. "Deleting a route should only delete it from that picture. If it was the
//     last picture it was shown on, then and only then delete it altogether."
//     Deleting from a climb's HOME photo used to tombstone the climb outright
//     — its name, its grade, its stars and every ascent logged against it —
//     even when the same climb was still drawn on two other faces of the rock.
//  2. "Renumber routes if needed, always show the route number from left to
//     right." Numbers were handed out in the order lines were DRAWN, which is
//     the one order a guidebook never uses.
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

  group('renumbering', () {
    test('orders climbs left to right by where each line STARTS, and reports '
        'what moved', () async {
      // Drawn right, left, middle — the order that produced the complaint.
      await repository.upsertRoute(
        wallId,
        photoOne,
        TopoRoute(id: 1, number: 1, points: lineAt(0.8), name: 'Right'),
      );
      await repository.upsertRoute(
        wallId,
        photoOne,
        TopoRoute(id: 2, number: 2, points: lineAt(0.1), name: 'Left'),
      );
      await repository.upsertRoute(
        wallId,
        photoOne,
        TopoRoute(id: 3, number: 3, points: lineAt(0.5), name: 'Middle'),
      );

      final moved = await repository.renumberByPosition(wallId);
      expect(moved, {1: 3, 3: 2, 2: 1});

      final ordered = await repository.loadRoutes(wallId, photoOne);
      expect(ordered.map((r) => '${r.number} ${r.name}'), [
        '1 Left',
        '2 Middle',
        '3 Right',
      ]);
    });

    test('keeps the colour in step with the number, because every other '
        'writer derives it that way', () async {
      await repository.upsertRoute(
        wallId,
        photoOne,
        TopoRoute(id: 1, number: 1, points: lineAt(0.9)),
      );
      await repository.upsertRoute(
        wallId,
        photoOne,
        TopoRoute(id: 2, number: 2, points: lineAt(0.1)),
      );

      await repository.renumberByPosition(wallId);

      for (final route in await repository.loadRoutes(wallId, photoOne)) {
        expect(route.colorIndex, routeColorIndexFor(route.number));
      }
    });

    test(
      'a straight SWAP survives the unique index on (wall, number)',
      () async {
        // The case a one-pass renumber cannot do: 1 becomes 2 while 2 still
        // holds it. Without the parking pass this throws, or silently collapses
        // both onto one number.
        await repository.upsertRoute(
          wallId,
          photoOne,
          TopoRoute(id: 1, number: 1, points: lineAt(0.9), name: 'A'),
        );
        await repository.upsertRoute(
          wallId,
          photoOne,
          TopoRoute(id: 2, number: 2, points: lineAt(0.1), name: 'B'),
        );

        await repository.renumberByPosition(wallId);

        final ordered = await repository.loadRoutes(wallId, photoOne);
        expect(ordered.map((r) => '${r.number} ${r.name}'), ['1 B', '2 A']);
      },
    );

    test(
      'numbers photo by photo, in rail order, then left to right within '
      'each — a wall-wide number that still reads as a walk along the base',
      () async {
        await repository.upsertRoute(
          wallId,
          photoTwo,
          TopoRoute(id: 1, number: 1, points: lineAt(0.6), name: 'Two-right'),
        );
        await repository.upsertRoute(
          wallId,
          photoTwo,
          TopoRoute(id: 2, number: 2, points: lineAt(0.2), name: 'Two-left'),
        );
        await repository.upsertRoute(
          wallId,
          photoOne,
          TopoRoute(id: 3, number: 3, points: lineAt(0.4), name: 'One'),
        );

        await repository.renumberByPosition(wallId);

        final onOne = await repository.loadRoutes(wallId, photoOne);
        final onTwo = await repository.loadRoutes(wallId, photoTwo);
        expect(onOne.single.number, 1, reason: 'the first photo comes first');
        expect(onTwo.map((r) => '${r.number} ${r.name}'), [
          '2 Two-left',
          '3 Two-right',
        ]);
      },
    );

    test('a climb drawn on two photos is placed by its HOME line only, and '
        'keeps one number', () async {
      await repository.upsertRoute(
        wallId,
        photoOne,
        TopoRoute(id: 1, number: 1, points: lineAt(0.9), name: 'Home right'),
      );
      // Its second drawing sits far LEFT on the other photo. If that line were
      // consulted, this climb would sort first and the numbering would depend
      // on which photo you happened to be looking at.
      await repository.upsertRoute(
        wallId,
        photoTwo,
        TopoRoute(id: 1, number: 1, points: lineAt(0.05), name: 'Home right'),
      );
      await repository.upsertRoute(
        wallId,
        photoOne,
        TopoRoute(id: 2, number: 2, points: lineAt(0.2), name: 'Home left'),
      );

      await repository.renumberByPosition(wallId);

      final onOne = await repository.loadRoutes(wallId, photoOne);
      expect(onOne.map((r) => '${r.number} ${r.name}'), [
        '1 Home left',
        '2 Home right',
      ]);
      final onTwo = await repository.loadRoutes(wallId, photoTwo);
      expect(
        onTwo.single.number,
        2,
        reason: 'the same climb, the same number, seen from the other side',
      );
    });

    test('is a no-op on a wall already in order — it reports nothing moved '
        'and leaves the rows untouched', () async {
      await repository.upsertRoute(
        wallId,
        photoOne,
        TopoRoute(id: 1, number: 1, points: lineAt(0.1)),
      );
      await repository.upsertRoute(
        wallId,
        photoOne,
        TopoRoute(id: 2, number: 2, points: lineAt(0.8)),
      );
      final before = await db.select(db.routes).get();

      expect(await repository.renumberByPosition(wallId), isEmpty);

      expect(await db.select(db.routes).get(), before);
    });

    test('leaves an UNPLACED climb after the drawn ones, keeping the order it '
        'had — a guidebook import is a whole wall of climbs nobody has drawn '
        'yet, and x = 0 would put every one of them leftmost', () async {
      await repository.upsertRoute(
        wallId,
        photoOne,
        const TopoRoute(id: 1, number: 1, points: [], name: 'Unplaced first'),
      );
      await repository.upsertRoute(
        wallId,
        photoOne,
        const TopoRoute(id: 2, number: 2, points: [], name: 'Unplaced second'),
      );
      await repository.upsertRoute(
        wallId,
        photoOne,
        TopoRoute(id: 3, number: 3, points: lineAt(0.5), name: 'Drawn'),
      );

      await repository.renumberByPosition(wallId);

      expect(
        (await repository.loadRoutes(
          wallId,
          photoOne,
        )).map((r) => '${r.number} ${r.name}'),
        ['1 Drawn', '2 Unplaced first', '3 Unplaced second'],
      );
    });

    test('ignores deleted climbs, so a tombstone leaves no gap', () async {
      for (var i = 1; i <= 3; i++) {
        await repository.upsertRoute(
          wallId,
          photoOne,
          TopoRoute(id: i, number: i, points: lineAt(i / 10)),
        );
      }
      await repository.softDeleteRoute(wallId, photoOne, 2);

      await repository.renumberByPosition(wallId);

      final live = await repository.loadRoutes(wallId, photoOne);
      expect(live.map((r) => r.number), [1, 2]);
    });
  });
}
