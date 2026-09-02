// "This is climb 3, drawn here."
//
// Since v16 a climb is one row numbered across the whole WALL, and the same
// climb drawn on another photo of the rock is a `route_lines` row — the same
// rock from 90 degrees round is a different shape, and it is still the same
// climb. Two things were wrong with how that state could be reached.
//
//  * It fired BY ACCIDENT. `loadForWall` seeded the next climb number from
//    the climbs visible on THIS photo, so the first line drawn on a second,
//    empty face took number 1 — which already belonged to a climb on the
//    first face. `upsertRoute` keys on (wallId, number), read that as "the
//    same climb, from over here", and folded the blank draft's null name and
//    grade onto the climb it collided with.
//  * It could not be reached ON PURPOSE. Only a route already visible on this
//    photo could claim a draft, and a climb drawn on another face is by
//    definition not visible here.

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/topo/application/draw_controller.dart';
import 'package:masi/features/topo/domain/topo_route.dart';

void main() {
  const wallId = 'wall-1';
  const photoOne = 'photo-1';
  const photoTwo = 'photo-2';
  const now = 1000;

  late AppDatabase db;

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
            ),
          );
    }
  }

  ProviderContainer makeContainer() {
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        nowMsProvider.overrideWithValue(() => now),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// Climb 1: named, graded, drawn on the first photo.
  Future<void> seedClimbOne(ProviderContainer container) => container
      .read(routeRepositoryProvider)
      .upsertRoute(
        wallId,
        photoOne,
        const TopoRoute(
          id: 1,
          number: 1,
          points: [Offset(0.1, 0.1), Offset(0.2, 0.9)],
          name: 'Arete',
          gradeRaw: '6a',
        ),
      );

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await seedWall();
  });

  tearDown(() async => db.close());

  test('a new line on a second face is a NEW climb, and the first keeps its '
      'name and grade', () async {
    final container = makeContainer();
    await seedClimbOne(container);

    final notifier = container.read(drawControllerProvider(wallId).notifier);
    await notifier.loadForWall(wallId, photoTwo);

    expect(
      container.read(drawControllerProvider(wallId)).routes,
      isEmpty,
      reason: 'the second face has nothing on it yet',
    );
    expect(
      container.read(drawControllerProvider(wallId)).nextNumber,
      2,
      reason:
          'the number seed is the whole rock, not this photo — seeding it '
          'from an empty face is what handed the next line climb 1',
    );

    notifier.addPoint(const Offset(0.5, 0.1));
    notifier.addPoint(const Offset(0.6, 0.9));
    await notifier.commitRoute();

    final climbs =
        await (db.select(db.routes)..where((t) => t.deletedAt.isNull())).get()
          ..sort((a, b) => a.number.compareTo(b.number));
    expect(climbs, hasLength(2), reason: 'two climbs, not one drawn twice');
    expect(climbs.first.number, 1);
    expect(
      climbs.first.name,
      'Arete',
      reason: 'the climb on the other face was never part of this drawing',
    );
    expect(climbs.first.gradeRaw, '6a');
    expect(climbs.first.photoId, photoOne);
    expect(climbs[1].number, 2);
    expect(climbs[1].photoId, photoTwo);

    final lines = await db.select(db.routeLines).get();
    expect(lines, isEmpty, reason: 'nothing here was another face of anything');
  });

  test('and the climb it did not touch is still offered as one this line '
      'COULD be', () async {
    final container = makeContainer();
    await seedClimbOne(container);

    final candidates = await container
        .read(routeRepositoryProvider)
        .loadClimbsElsewhere(wallId, photoTwo);
    expect(candidates, hasLength(1));
    expect(candidates.single.number, 1);
    expect(candidates.single.name, 'Arete');

    expect(
      await container
          .read(routeRepositoryProvider)
          .loadClimbsElsewhere(wallId, photoOne),
      isEmpty,
      reason:
          'a climb already on this photo cannot be drawn on it again — '
          'the partial unique index forbids a second line for one photo',
    );
  });

  test('saying so on purpose puts the line on that climb, spends no number, '
      'and leaves its first drawing alone', () async {
    final container = makeContainer();
    await seedClimbOne(container);

    final notifier = container.read(drawControllerProvider(wallId).notifier);
    await notifier.loadForWall(wallId, photoTwo);

    final candidates = await container
        .read(routeRepositoryProvider)
        .loadClimbsElsewhere(wallId, photoTwo);

    notifier.addPoint(const Offset(0.5, 0.1));
    notifier.addPoint(const Offset(0.6, 0.9));
    await notifier.commitDraftAsClimb(candidates.single);

    final state = container.read(drawControllerProvider(wallId));
    expect(state.currentPoints, isEmpty, reason: 'the draft was consumed');
    expect(state.routes, hasLength(1));
    expect(state.routes.single.number, 1);
    expect(state.routes.single.name, 'Arete');
    expect(
      state.nextNumber,
      2,
      reason: 'no new number was spent — this climb already had one',
    );

    final climbs = await (db.select(
      db.routes,
    )..where((t) => t.deletedAt.isNull())).get();
    expect(climbs, hasLength(1), reason: 'no second climb was invented');
    expect(climbs.single.name, 'Arete', reason: 'and nothing was overwritten');
    expect(climbs.single.gradeRaw, '6a');
    expect(
      climbs.single.photoId,
      photoOne,
      reason: 'its home is still the face it was drawn on first',
    );
    expect(
      climbs.single.pointsJson,
      contains('0.1'),
      reason:
          'the first drawing is untouched — that is the whole difference '
          'between this and the overwrite it replaces',
    );

    final lines = await db.select(db.routeLines).get();
    expect(lines, hasLength(1));
    expect(lines.single.photoId, photoTwo);
    expect(lines.single.routeId, climbs.single.id);

    // And reading the second face back shows the climb with ITS geometry.
    final onTwo = await container
        .read(routeRepositoryProvider)
        .loadRoutes(wallId, photoTwo);
    expect(onTwo, hasLength(1));
    expect(onTwo.single.number, 1);
    expect(onTwo.single.name, 'Arete');
    expect(onTwo.single.points, [
      const Offset(0.5, 0.1),
      const Offset(0.6, 0.9),
    ]);

    expect(
      await container
          .read(routeRepositoryProvider)
          .loadClimbsElsewhere(wallId, photoTwo),
      isEmpty,
      reason:
          'it is on this photo now, so it is no longer a candidate for '
          'the next line drawn here',
    );
  });

  test(
    'the wall-wide seed also covers a route committed mid photo-switch',
    () async {
      final container = makeContainer();
      await seedClimbOne(container);

      final notifier = container.read(drawControllerProvider(wallId).notifier);
      await notifier.loadForWall(wallId, photoOne);

      // A line finished in the gap between leaving one face and the next
      // face's routes arriving. It is renumbered on arrival, and the number it
      // gets has to clear the whole wall, not the photo it lands on.
      notifier.beginPhotoSwitch();
      notifier.addPoint(const Offset(0.5, 0.1));
      notifier.addPoint(const Offset(0.6, 0.9));
      await notifier.commitRoute();
      await notifier.loadForWall(wallId, photoTwo);

      final climbs = await (db.select(
        db.routes,
      )..where((t) => t.deletedAt.isNull())).get();
      expect(climbs, hasLength(2));
      expect(
        climbs.map((c) => c.number).toSet(),
        {1, 2},
        reason:
            'the preserved route may not reuse a number the wall already '
            'gave out',
      );
      expect(
        climbs.firstWhere((c) => c.number == 1).name,
        'Arete',
        reason: 'and may not fold itself onto the climb holding that number',
      );
    },
  );

  test('a climb saved as its own can be merged into one from another face, '
      'and takes that climb\'s number, name and grade', () async {
    final container = makeContainer();
    await seedClimbOne(container);

    final notifier = container.read(drawControllerProvider(wallId).notifier);
    await notifier.loadForWall(wallId, photoTwo);

    // What the save produces when nobody says otherwise: a second climb, on
    // this face, with no name. The row the contributor is then stuck with.
    notifier.addPoint(const Offset(0.5, 0.1));
    notifier.addPoint(const Offset(0.6, 0.9));
    await notifier.commitRoute();

    var state = container.read(drawControllerProvider(wallId));
    expect(state.routes, hasLength(1));
    expect(state.routes.single.number, 2);
    expect(state.routes.single.name, isNull);

    final candidates = await container
        .read(routeRepositoryProvider)
        .loadClimbsElsewhere(wallId, photoTwo);
    expect(candidates.single.number, 1);

    await notifier.mergeRouteIntoClimb(
      state.routes.single.id,
      candidates.single,
    );

    state = container.read(drawControllerProvider(wallId));
    expect(state.routes, hasLength(1));
    expect(state.routes.single.number, 1);
    expect(state.routes.single.name, 'Arete');
    expect(state.routes.single.gradeRaw, '6a');

    final live = await (db.select(
      db.routes,
    )..where((t) => t.deletedAt.isNull())).get();
    expect(
      live,
      hasLength(1),
      reason: 'the climb that was never its own stops being one',
    );
    expect(live.single.number, 1);
    expect(live.single.name, 'Arete', reason: 'and nothing was overwritten');
    expect(
      live.single.photoId,
      photoOne,
      reason: 'its home is still the face it was drawn on first',
    );

    final lines = await (db.select(
      db.routeLines,
    )..where((t) => t.deletedAt.isNull())).get();
    expect(lines, hasLength(1));
    expect(lines.single.photoId, photoTwo);
    expect(lines.single.routeId, live.single.id);

    final onTwo = await container
        .read(routeRepositoryProvider)
        .loadRoutes(wallId, photoTwo);
    expect(onTwo.single.name, 'Arete');
    expect(onTwo.single.points, [
      const Offset(0.5, 0.1),
      const Offset(0.6, 0.9),
    ]);
  });
}
