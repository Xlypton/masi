// "In edit mode, if I select a route and draw a line, I want to draw the line
// FOR that route."
//
// The case that produced the request: a guidebook import (over MCP) added the
// routes of a wall but could not read a polyline for them, so each was created
// with an empty `points` list — `ImportWarningKind.unplacedGeometry`, "this
// route is yours to draw". Selecting one and drawing produced a SECOND,
// separately-numbered route beside it, and the imported one stayed empty
// forever; there was no way to draw it at all.
//
// So the rule under test is asymmetric on purpose, and the asymmetry is the
// interesting part:
//
//  * An UNPLACED selected route claims the draft silently — it destroys
//    nothing, and there is no second reading of the gesture.
//  * A selected route that already HAS a line does NOT, unless the caller
//    explicitly passes `replaceSelectedLine`. A selection lingers (it is also
//    how markers, the eraser and handle-dragging pick their target), so
//    quietly overwriting a drawn line on the strength of one would destroy
//    work nobody asked to touch.

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/topo/application/draw_controller.dart';
import 'package:masi/features/topo/domain/topo_route.dart';

void main() {
  const wallId = 'wall-1';
  const photoId = 'photo-1';
  const now = 1000;

  late AppDatabase db;

  Future<void> seedWallAndPhoto() async {
    await db.into(db.areas).insert(
          AreasCompanion.insert(
            id: 'area-1',
            createdAt: now,
            updatedAt: now,
            name: 'Test Area',
          ),
        );
    await db.into(db.sectors).insert(
          SectorsCompanion.insert(
            id: 'sector-1',
            createdAt: now,
            updatedAt: now,
            areaId: 'area-1',
            name: 'Test Sector',
            sortOrder: 0,
          ),
        );
    await db.into(db.walls).insert(
          WallsCompanion.insert(
            id: wallId,
            createdAt: now,
            updatedAt: now,
            sectorId: 'sector-1',
            name: 'Test Wall',
            sortOrder: 0,
          ),
        );
    await db.into(db.photos).insert(
          PhotosCompanion.insert(
            id: photoId,
            createdAt: now,
            updatedAt: now,
            wallId: wallId,
            localPath: '/tmp/photo.jpg',
            kind: 'original',
            width: 100,
            height: 200,
          ),
        );
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

  /// What a guidebook import leaves on the wall: name, grade and number, no
  /// line. Written straight through the repository so `loadForWall` sees
  /// exactly what a real import would have left behind.
  Future<void> seedUnplacedRoute(
    ProviderContainer container, {
    int number = 1,
    String name = 'Berán',
    String grade = '6a',
  }) async {
    await container.read(routeRepositoryProvider).upsertRoute(
          wallId,
          photoId,
          TopoRoute(
            id: number,
            number: number,
            points: const [],
            name: name,
            gradeRaw: grade,
          ),
        );
  }

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await seedWallAndPhoto();
  });

  tearDown(() async {
    await db.close();
  });

  group('an UNPLACED selected route claims the draft', () {
    test('the line lands on that route instead of creating a new one, and its '
        'number, name and grade all survive', () async {
      final container = makeContainer();
      final notifier = container.read(drawControllerProvider(wallId).notifier);
      await seedUnplacedRoute(container);
      await notifier.loadForWall(wallId, photoId);

      final imported = container.read(drawControllerProvider(wallId)).routes.single;
      expect(imported.points, isEmpty, reason: 'the fixture is the import case');

      notifier.selectRoute(imported.id);
      notifier.addPoint(const Offset(0.1, 0.2));
      notifier.addPoint(const Offset(0.3, 0.4));
      await notifier.commitRoute();

      final state = container.read(drawControllerProvider(wallId));
      expect(state.routes, hasLength(1), reason: 'no second route was made');
      final drawn = state.routes.single;
      expect(drawn.id, imported.id);
      expect(drawn.number, imported.number);
      expect(drawn.name, 'Berán');
      expect(drawn.gradeRaw, '6a');
      expect(drawn.points, [const Offset(0.1, 0.2), const Offset(0.3, 0.4)]);
      expect(state.currentPoints, isEmpty, reason: 'the draft was consumed');
    });

    test('the line is PERSISTED onto that route — a relaunch still has it, '
        'still on the same numbered route', () async {
      final containerA = makeContainer();
      final notifierA = containerA.read(drawControllerProvider(wallId).notifier);
      await seedUnplacedRoute(containerA);
      await notifierA.loadForWall(wallId, photoId);

      final id = containerA.read(drawControllerProvider(wallId)).routes.single.id;
      notifierA.selectRoute(id);
      notifierA.addPoint(const Offset(0.1, 0.2));
      notifierA.addPoint(const Offset(0.3, 0.4));
      await notifierA.commitRoute();

      final containerB = makeContainer();
      final notifierB = containerB.read(drawControllerProvider(wallId).notifier);
      await notifierB.loadForWall(wallId, photoId);

      final reloaded = containerB.read(drawControllerProvider(wallId)).routes.single;
      expect(reloaded.number, 1);
      expect(reloaded.name, 'Berán');
      expect(reloaded.points, [const Offset(0.1, 0.2), const Offset(0.3, 0.4)]);
      expect(
        containerB.read(drawControllerProvider(wallId)).nextNumber,
        2,
        reason: 'drawing an existing route must not consume a second number',
      );
    });

    test('one undo puts the route back to unplaced — not half-drawn, and not '
        'deleted', () async {
      final container = makeContainer();
      final notifier = container.read(drawControllerProvider(wallId).notifier);
      await seedUnplacedRoute(container);
      await notifier.loadForWall(wallId, photoId);

      final id = container.read(drawControllerProvider(wallId)).routes.single.id;
      notifier.selectRoute(id);
      notifier.addPoint(const Offset(0.1, 0.2));
      notifier.addPoint(const Offset(0.3, 0.4));
      await notifier.commitRoute();

      notifier.undo();

      final state = container.read(drawControllerProvider(wallId));
      expect(state.routes, hasLength(1), reason: 'the route itself survives');
      expect(state.routes.single.points, isEmpty);
      expect(state.routes.single.name, 'Berán');
    });

    test('the NEXT line drawn after it makes a new route, because the commit '
        'left nothing unplaced to claim it', () async {
      final container = makeContainer();
      final notifier = container.read(drawControllerProvider(wallId).notifier);
      await seedUnplacedRoute(container);
      await notifier.loadForWall(wallId, photoId);

      final id = container.read(drawControllerProvider(wallId)).routes.single.id;
      notifier.selectRoute(id);
      notifier.addPoint(const Offset(0.1, 0.2));
      notifier.addPoint(const Offset(0.3, 0.4));
      await notifier.commitRoute();

      // Selection deliberately left alone — this is the lingering-selection
      // trap, and the second line must NOT overwrite the first.
      notifier.addPoint(const Offset(0.6, 0.6));
      notifier.addPoint(const Offset(0.7, 0.8));
      await notifier.commitRoute();

      final state = container.read(drawControllerProvider(wallId));
      expect(state.routes, hasLength(2));
      expect(state.routes.first.points, [
        const Offset(0.1, 0.2),
        const Offset(0.3, 0.4),
      ]);
      expect(state.routes.last.number, 2);
    });
  });

  group('a selected route that ALREADY has a line', () {
    Future<(ProviderContainer, DrawController, int)> withDrawnRoute() async {
      final container = makeContainer();
      final notifier = container.read(drawControllerProvider(wallId).notifier);
      await notifier.loadForWall(wallId, photoId);
      notifier.addPoint(const Offset(0.1, 0.1));
      notifier.addPoint(const Offset(0.2, 0.2));
      await notifier.commitRoute();
      final id = container.read(drawControllerProvider(wallId)).routes.single.id;
      notifier.selectRoute(id);
      return (container, notifier, id);
    }

    test('is NOT overwritten by default — the draft becomes a new route, as it '
        'always did', () async {
      final (container, notifier, id) = await withDrawnRoute();

      notifier.addPoint(const Offset(0.8, 0.8));
      notifier.addPoint(const Offset(0.9, 0.9));
      await notifier.commitRoute();

      final state = container.read(drawControllerProvider(wallId));
      expect(state.routes, hasLength(2));
      expect(
        state.routes.firstWhere((r) => r.id == id).points,
        [const Offset(0.1, 0.1), const Offset(0.2, 0.2)],
        reason: 'the selected route is untouched',
      );
    });

    test('IS overwritten when the caller says so, keeping its identity and its '
        'existing markers', () async {
      final (container, notifier, id) = await withDrawnRoute();
      notifier.setActiveSymbol(SymbolType.anchor);
      await notifier.placeSymbol(const Offset(0.15, 0.15));
      notifier.setActiveSymbol(null);

      notifier.addPoint(const Offset(0.8, 0.8));
      notifier.addPoint(const Offset(0.9, 0.9));
      await notifier.commitRoute(replaceSelectedLine: true);

      final state = container.read(drawControllerProvider(wallId));
      expect(state.routes, hasLength(1));
      final route = state.routes.single;
      expect(route.id, id);
      expect(route.number, 1);
      expect(route.points, [const Offset(0.8, 0.8), const Offset(0.9, 0.9)]);
      expect(
        route.symbols,
        hasLength(1),
        reason: 'a marker is anchored to the photo, not to the line it was '
            'placed near, so a redraw does not silently delete it',
      );
    });

    test('undo after a replace restores the line that was there', () async {
      final (container, notifier, _) = await withDrawnRoute();

      notifier.addPoint(const Offset(0.8, 0.8));
      notifier.addPoint(const Offset(0.9, 0.9));
      await notifier.commitRoute(replaceSelectedLine: true);
      notifier.undo();

      expect(
        container.read(drawControllerProvider(wallId)).routes.single.points,
        [const Offset(0.1, 0.1), const Offset(0.2, 0.2)],
      );
    });
  });

  group('pendingDraftTarget tells the canvas which case it is in', () {
    test('null with nothing selected, and null with no drawable draft',
        () async {
      final container = makeContainer();
      final notifier = container.read(drawControllerProvider(wallId).notifier);
      await seedUnplacedRoute(container);
      await notifier.loadForWall(wallId, photoId);

      notifier.addPoint(const Offset(0.1, 0.2));
      notifier.addPoint(const Offset(0.3, 0.4));
      expect(notifier.pendingDraftTarget, isNull, reason: 'nothing selected');

      notifier.selectRoute(
        container.read(drawControllerProvider(wallId)).routes.single.id,
      );
      notifier.clearCurrent();
      expect(notifier.pendingDraftTarget, isNull, reason: 'no draft to place');
    });

    test('overwritesLine is false for an unplaced route and true for a drawn '
        'one', () async {
      final container = makeContainer();
      final notifier = container.read(drawControllerProvider(wallId).notifier);
      await seedUnplacedRoute(container);
      await notifier.loadForWall(wallId, photoId);
      final unplacedId =
          container.read(drawControllerProvider(wallId)).routes.single.id;

      notifier.selectRoute(unplacedId);
      notifier.addPoint(const Offset(0.1, 0.2));
      notifier.addPoint(const Offset(0.3, 0.4));
      expect(notifier.pendingDraftTarget?.route.id, unplacedId);
      expect(notifier.pendingDraftTarget?.overwritesLine, isFalse);

      await notifier.commitRoute();
      notifier.addPoint(const Offset(0.6, 0.6));
      notifier.addPoint(const Offset(0.7, 0.8));
      expect(notifier.pendingDraftTarget?.route.id, unplacedId);
      expect(
        notifier.pendingDraftTarget?.overwritesLine,
        isTrue,
        reason: 'the same route now has a line, so the canvas must ask',
      );
    });
  });

  group("on somebody else's wall", () {
    test('drawing an unplaced route is a PROPOSAL: applied in memory, never '
        'written, and revertible', () async {
      final container = makeContainer();
      final notifier = container.read(drawControllerProvider(wallId).notifier);
      await seedUnplacedRoute(container);
      await notifier.loadForWall(wallId, photoId);
      notifier.setProposalOnlyGeometryEdits(true);

      final id = container.read(drawControllerProvider(wallId)).routes.single.id;
      notifier.selectRoute(id);
      notifier.addPoint(const Offset(0.1, 0.2));
      notifier.addPoint(const Offset(0.3, 0.4));
      await notifier.commitRoute();

      final state = container.read(drawControllerProvider(wallId));
      expect(state.routes.single.points, hasLength(2), reason: 'visible to the suggester');
      expect(state.pendingProposalBaselines.containsKey(id), isTrue);

      // Nothing reached disk: a fresh container reading the same database
      // still sees the owner's unplaced route.
      final containerB = makeContainer();
      await containerB
          .read(drawControllerProvider(wallId).notifier)
          .loadForWall(wallId, photoId);
      expect(
        containerB.read(drawControllerProvider(wallId)).routes.single.points,
        isEmpty,
      );
    });
  });
}
