import 'dart:async';

import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/core/db/database_provider.dart';
import 'package:climbtopo/core/grades/grade_system.dart';
import 'package:climbtopo/features/topo/application/draw_controller.dart';
import 'package:climbtopo/features/topo/data/route_repository.dart';
import 'package:climbtopo/features/topo/domain/topo_route.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Test double for [RouteRepository] that lets a test hold
/// [RouteRepository.loadRoutes] open for a chosen `photoId` until it
/// explicitly releases it, so out-of-order `loadForWall` resolution can be
/// forced deterministically instead of relying on incidental timing.
class _GatedRouteRepository extends RouteRepository {
  _GatedRouteRepository(
    super.db, {
    required super.nowMs,
    this.gates = const {},
  });

  /// photoId -> a future this repository awaits before delegating to the
  /// real query for that photo. Photos with no entry proceed immediately.
  final Map<String, Future<void>> gates;

  @override
  Future<List<TopoRoute>> loadRoutes(String wallId, String photoId) async {
    final gate = gates[photoId];
    if (gate != null) await gate;
    return super.loadRoutes(wallId, photoId);
  }
}

/// M3 integration tests: verify [DrawController] write-through persistence
/// via [RouteRepository]/[LibraryRepository] wiring in
/// `lib/core/db/database_provider.dart`.
///
/// Every test shares a single in-memory [AppDatabase] instance across one or
/// more [ProviderContainer]s (each overriding [appDatabaseProvider] with the
/// SAME instance), simulating separate "app launches"/screens reading from
/// the same on-device database.
void main() {
  const wallId = 'wall-1';
  const photoId = 'photo-1';
  const now = 1000;

  late AppDatabase db;

  /// Seeds the minimal Area/Sector/Wall/Photo hierarchy [RouteRepository]
  /// requires (its Routes table has real FK references, enforced via
  /// `PRAGMA foreign_keys = ON`).
  Future<void> seedWallAndPhoto() async {
    await db
        .into(db.areas)
        .insert(
          AreasCompanion.insert(
            id: 'area-1',
            createdAt: now,
            updatedAt: now,
            name: 'Test Area',
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
            name: 'Test Sector',
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
            name: 'Test Wall',
            sortOrder: 0,
          ),
        );
    await db
        .into(db.photos)
        .insert(
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

  /// A fresh [ProviderContainer] wired to the shared [db], simulating a new
  /// screen/app-launch reading from the same on-device database.
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

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await seedWallAndPhoto();
  });

  tearDown(() async {
    await db.close();
  });

  test('A1: loadForWall on an empty DB yields empty routes, sets activeWallId, '
      'and nextNumber stays 1', () async {
    final container = makeContainer();
    final notifier = container.read(drawControllerProvider(wallId).notifier);

    await notifier.loadForWall(wallId, photoId);

    final state = container.read(drawControllerProvider(wallId));
    expect(state.routes, isEmpty);
    expect(state.activeWallId, wallId);
    expect(state.activePhotoId, photoId);
    expect(state.nextNumber, 1);
    expect(state.nextId, 1);
  });

  test('A2: commitRoute with an active wall persists the route; a fresh '
      'controller loading the same wall sees it', () async {
    final containerA = makeContainer();
    final notifierA = containerA.read(drawControllerProvider(wallId).notifier);
    await notifierA.loadForWall(wallId, photoId);

    notifierA.addPoint(const Offset(0.1, 0.1));
    notifierA.addPoint(const Offset(0.2, 0.2));
    await notifierA.commitRoute();

    final containerB = makeContainer();
    final notifierB = containerB.read(drawControllerProvider(wallId).notifier);
    await notifierB.loadForWall(wallId, photoId);

    final loaded = containerB.read(drawControllerProvider(wallId)).routes;
    expect(loaded, hasLength(1));
    expect(loaded.single.number, 1);
    expect(loaded.single.points, [
      const Offset(0.1, 0.1),
      const Offset(0.2, 0.2),
    ]);
    expect(loaded.single.symbols, isEmpty);
  });

  test(
    'A3: removeRoute soft-deletes; a reload no longer returns the route',
    () async {
      final containerA = makeContainer();
      final notifierA = containerA.read(drawControllerProvider(wallId).notifier);
      await notifierA.loadForWall(wallId, photoId);

      notifierA.addPoint(const Offset(0.1, 0.1));
      notifierA.addPoint(const Offset(0.2, 0.2));
      await notifierA.commitRoute();
      final routeId = containerA.read(drawControllerProvider(wallId)).routes.single.id;

      await notifierA.removeRoute(routeId);
      expect(containerA.read(drawControllerProvider(wallId)).routes, isEmpty);

      final containerB = makeContainer();
      final notifierB = containerB.read(drawControllerProvider(wallId).notifier);
      await notifierB.loadForWall(wallId, photoId);
      expect(containerB.read(drawControllerProvider(wallId)).routes, isEmpty);
    },
  );

  test('A4: placeSymbol with a selected route and active symbol persists the '
      'symbol; a reload sees it', () async {
    final containerA = makeContainer();
    final notifierA = containerA.read(drawControllerProvider(wallId).notifier);
    await notifierA.loadForWall(wallId, photoId);

    notifierA.addPoint(const Offset(0.1, 0.1));
    notifierA.addPoint(const Offset(0.2, 0.2));
    await notifierA.commitRoute();
    final routeId = containerA.read(drawControllerProvider(wallId)).routes.single.id;

    notifierA.selectRoute(routeId);
    notifierA.setActiveSymbol(SymbolType.bolt);
    const symbolAt = Offset(0.15, 0.15);
    await notifierA.placeSymbol(symbolAt);

    expect(containerA.read(drawControllerProvider(wallId)).routes.single.symbols, [
      const TopoSymbol(type: SymbolType.bolt, position: symbolAt),
    ]);

    final containerB = makeContainer();
    final notifierB = containerB.read(drawControllerProvider(wallId).notifier);
    await notifierB.loadForWall(wallId, photoId);
    expect(containerB.read(drawControllerProvider(wallId)).routes.single.symbols, [
      const TopoSymbol(type: SymbolType.bolt, position: symbolAt),
    ]);
  });

  test(
    'U3: undo removes a symbol placed on an already-committed route AND '
    're-persists that removal (the reported bug: previously undo only ever '
    'popped points, and had no way to write the removal through to disk); '
    'redo restores the symbol and re-persists it too',
    () async {
      final containerA = makeContainer();
      final notifierA = containerA.read(drawControllerProvider(wallId).notifier);
      await notifierA.loadForWall(wallId, photoId);

      notifierA.addPoint(const Offset(0.1, 0.1));
      notifierA.addPoint(const Offset(0.2, 0.2));
      await notifierA.commitRoute();
      final routeId = containerA.read(drawControllerProvider(wallId)).routes.single.id;

      notifierA.selectRoute(routeId);
      notifierA.setActiveSymbol(SymbolType.bolt);
      const symbolAt = Offset(0.15, 0.15);
      await notifierA.placeSymbol(symbolAt);
      expect(containerA.read(drawControllerProvider(wallId)).routes.single.symbols, [
        const TopoSymbol(type: SymbolType.bolt, position: symbolAt),
      ]);

      await notifierA.undo();
      expect(
        containerA.read(drawControllerProvider(wallId)).routes.single.symbols,
        isEmpty,
      );

      // A fresh controller loading the same wall must see the symbol GONE
      // -- i.e. undo's removal was written through to the DB, not just
      // held in memory.
      final containerB = makeContainer();
      final notifierB = containerB.read(drawControllerProvider(wallId).notifier);
      await notifierB.loadForWall(wallId, photoId);
      expect(containerB.read(drawControllerProvider(wallId)).routes.single.symbols, isEmpty);

      await notifierA.redo();
      expect(containerA.read(drawControllerProvider(wallId)).routes.single.symbols, [
        const TopoSymbol(type: SymbolType.bolt, position: symbolAt),
      ]);

      // And a third fresh controller must see it RESTORED post-redo.
      final containerC = makeContainer();
      final notifierC = containerC.read(drawControllerProvider(wallId).notifier);
      await notifierC.loadForWall(wallId, photoId);
      expect(containerC.read(drawControllerProvider(wallId)).routes.single.symbols, [
        const TopoSymbol(type: SymbolType.bolt, position: symbolAt),
      ]);
    },
  );

  test(
    'U8: placeSymbol while drawing a NEW route (after a route is already '
    'committed) does not persist the symbol onto the pre-existing '
    'committed route ON DISK -- a fresh controller reload must see it '
    'still symbol-less until the new route is itself committed',
    () async {
      final containerA = makeContainer();
      final notifierA = containerA.read(drawControllerProvider(wallId).notifier);
      await notifierA.loadForWall(wallId, photoId);
      notifierA.setMode(DrawMode.draw);

      notifierA.addPoint(const Offset(0.1, 0.1));
      notifierA.addPoint(const Offset(0.2, 0.2));
      await notifierA.commitRoute();

      // Start a NEW in-progress route with no explicit selection.
      notifierA.addPoint(const Offset(0.5, 0.1));
      notifierA.addPoint(const Offset(0.6, 0.1));

      notifierA.setActiveSymbol(SymbolType.bolt);
      const placedAt = Offset(0.5, 0.5);
      final outcome = await notifierA.placeSymbol(placedAt);
      expect(outcome, SymbolPlacementOutcome.placed);

      // A fresh controller loading the same wall must see the committed
      // route UNMODIFIED on disk -- the symbol must not have been written
      // through to it.
      final containerB = makeContainer();
      final notifierB = containerB.read(drawControllerProvider(wallId).notifier);
      await notifierB.loadForWall(wallId, photoId);
      final loadedBeforeNewCommit = containerB
          .read(drawControllerProvider(wallId))
          .routes;
      expect(loadedBeforeNewCommit, hasLength(1));
      expect(loadedBeforeNewCommit.single.symbols, isEmpty);

      // Committing the new in-progress route persists it WITH the bolt,
      // while the original committed route still has none.
      await notifierA.commitRoute();

      final containerC = makeContainer();
      final notifierC = containerC.read(drawControllerProvider(wallId).notifier);
      await notifierC.loadForWall(wallId, photoId);
      final loaded = containerC.read(drawControllerProvider(wallId)).routes;
      expect(loaded, hasLength(2));

      final original = loaded.firstWhere((r) => r.number == 1);
      final newRoute = loaded.firstWhere((r) => r.number == 2);
      expect(original.symbols, isEmpty);
      expect(newRoute.symbols, [
        const TopoSymbol(type: SymbolType.bolt, position: placedAt),
      ]);
    },
  );

  test('A5: toggleRouteVisibility persists the flipped flag; a reload reflects '
      'it', () async {
    final containerA = makeContainer();
    final notifierA = containerA.read(drawControllerProvider(wallId).notifier);
    await notifierA.loadForWall(wallId, photoId);

    notifierA.addPoint(const Offset(0.1, 0.1));
    notifierA.addPoint(const Offset(0.2, 0.2));
    await notifierA.commitRoute();
    final routeId = containerA.read(drawControllerProvider(wallId)).routes.single.id;
    expect(
      containerA.read(drawControllerProvider(wallId)).routes.single.visible,
      isTrue,
    );

    await notifierA.toggleRouteVisibility(routeId);
    expect(
      containerA.read(drawControllerProvider(wallId)).routes.single.visible,
      isFalse,
    );

    final containerB = makeContainer();
    final notifierB = containerB.read(drawControllerProvider(wallId).notifier);
    await notifierB.loadForWall(wallId, photoId);
    expect(
      containerB.read(drawControllerProvider(wallId)).routes.single.visible,
      isFalse,
    );
  });

  test('A6: relaunch simulation - controller A commits two routes (one with a '
      'symbol, one hidden), controller B loads both with matching data and '
      'nextNumber == 3', () async {
    final containerA = makeContainer();
    final notifierA = containerA.read(drawControllerProvider(wallId).notifier);
    await notifierA.loadForWall(wallId, photoId);

    // Route 1: gets a symbol.
    notifierA.addPoint(const Offset(0.1, 0.1));
    notifierA.addPoint(const Offset(0.2, 0.2));
    await notifierA.commitRoute();
    final firstId = containerA.read(drawControllerProvider(wallId)).routes[0].id;
    notifierA.selectRoute(firstId);
    notifierA.setActiveSymbol(SymbolType.anchor);
    const symbolAt = Offset(0.15, 0.15);
    await notifierA.placeSymbol(symbolAt);

    // Route 2: hidden via toggle.
    notifierA.addPoint(const Offset(0.3, 0.3));
    notifierA.addPoint(const Offset(0.4, 0.4));
    await notifierA.commitRoute();
    final secondId = containerA.read(drawControllerProvider(wallId)).routes[1].id;
    await notifierA.toggleRouteVisibility(secondId);

    final containerB = makeContainer();
    final notifierB = containerB.read(drawControllerProvider(wallId).notifier);
    await notifierB.loadForWall(wallId, photoId);

    final stateB = containerB.read(drawControllerProvider(wallId));
    final loaded = stateB.routes;
    expect(loaded, hasLength(2));

    final route1 = loaded.firstWhere((r) => r.number == 1);
    expect(route1.points, [const Offset(0.1, 0.1), const Offset(0.2, 0.2)]);
    expect(route1.symbols, [
      const TopoSymbol(type: SymbolType.anchor, position: symbolAt),
    ]);
    expect(route1.visible, isTrue);

    final route2 = loaded.firstWhere((r) => r.number == 2);
    expect(route2.points, [const Offset(0.3, 0.3), const Offset(0.4, 0.4)]);
    expect(route2.symbols, isEmpty);
    expect(route2.visible, isFalse);

    expect(stateB.nextNumber, 3);
    expect(stateB.nextId, 3);
  });

  test('A7: without ever calling loadForWall, activeWallId stays null and '
      'commitRoute/placeSymbol/toggleRouteVisibility/removeRoute all work '
      'with no DB and no error (pre-M3 behavior preserved)', () async {
    // Deliberately no provider overrides: appDatabaseProvider must never
    // be constructed/read since activeWallId stays null throughout.
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(drawControllerProvider(wallId).notifier);

    expect(container.read(drawControllerProvider(wallId)).activeWallId, isNull);

    notifier.addPoint(const Offset(0.1, 0.1));
    notifier.addPoint(const Offset(0.2, 0.2));
    await notifier.commitRoute();
    final routeId = container.read(drawControllerProvider(wallId)).routes.single.id;
    expect(container.read(drawControllerProvider(wallId)).routes, hasLength(1));

    notifier.selectRoute(routeId);
    notifier.setActiveSymbol(SymbolType.top);
    await notifier.placeSymbol(const Offset(0.15, 0.15));
    expect(
      container.read(drawControllerProvider(wallId)).routes.single.symbols,
      hasLength(1),
    );

    await notifier.toggleRouteVisibility(routeId);
    expect(
      container.read(drawControllerProvider(wallId)).routes.single.visible,
      isFalse,
    );

    await notifier.removeRoute(routeId);
    expect(container.read(drawControllerProvider(wallId)).routes, isEmpty);

    expect(container.read(drawControllerProvider(wallId)).activeWallId, isNull);
  });

  test(
    'A8: switching walls (as TopoCanvasScreen does on a new photo) resets '
    'in-progress drawing state and loads the target wall\'s own routes',
    () async {
      // A second wall/photo under the same DB, standing in for a second
      // imported image.
      const wall2 = 'wall-2';
      const photo2 = 'photo-2';
      await db
          .into(db.walls)
          .insert(
            WallsCompanion.insert(
              id: wall2,
              createdAt: now,
              updatedAt: now,
              sectorId: 'sector-1',
              name: 'Test Wall 2',
              sortOrder: 1,
            ),
          );
      await db
          .into(db.photos)
          .insert(
            PhotosCompanion.insert(
              id: photo2,
              createdAt: now,
              updatedAt: now,
              wallId: wall2,
              localPath: '/tmp/photo2.jpg',
              kind: 'original',
              width: 100,
              height: 200,
            ),
          );

      final container = makeContainer();
      final notifier = container.read(drawControllerProvider(wallId).notifier);

      // Wall 1: commit a route, then start an in-progress route + selection.
      await notifier.loadForWall(wallId, photoId);
      notifier.addPoint(const Offset(0.1, 0.1));
      notifier.addPoint(const Offset(0.2, 0.2));
      await notifier.commitRoute();
      final wall1RouteId = container
          .read(drawControllerProvider(wallId))
          .routes
          .single
          .id;
      notifier.selectRoute(wall1RouteId);
      notifier.addPoint(const Offset(0.3, 0.3));
      expect(container.read(drawControllerProvider(wallId)).currentPoints, isNotEmpty);
      expect(container.read(drawControllerProvider(wallId)).routes, isNotEmpty);
      expect(container.read(drawControllerProvider(wallId)).selectedRouteId, isNotNull);

      // Switch to wall 2 (empty): resets in-progress drawing state AND
      // swaps in wall 2's (empty) routes.
      await notifier.loadForWall(wall2, photo2);
      var state = container.read(drawControllerProvider(wallId));
      expect(state.activeWallId, wall2);
      expect(state.currentPoints, isEmpty);
      expect(state.routes, isEmpty);
      expect(state.selectedRouteId, isNull);
      expect(state.nextNumber, 1);

      // Switch back to wall 1: its persisted route reappears.
      await notifier.loadForWall(wallId, photoId);
      state = container.read(drawControllerProvider(wallId));
      expect(state.activeWallId, wallId);
      expect(state.routes, hasLength(1));
      expect(state.routes.single.points, [
        const Offset(0.1, 0.1),
        const Offset(0.2, 0.2),
      ]);
      expect(state.currentPoints, isEmpty);
      expect(state.selectedRouteId, isNull);
      expect(state.nextNumber, 2);
    },
  );

  test(
    'T1: beginPhotoSwitch synchronously clears routes/points/selection and '
    'nulls activeWallId/activePhotoId',
    () async {
      final container = makeContainer();
      final notifier = container.read(drawControllerProvider(wallId).notifier);
      await notifier.loadForWall(wallId, photoId);

      notifier.addPoint(const Offset(0.1, 0.1));
      notifier.addPoint(const Offset(0.2, 0.2));
      await notifier.commitRoute();
      final routeId = container.read(drawControllerProvider(wallId)).routes.single.id;
      notifier.selectRoute(routeId);
      notifier.addPoint(const Offset(0.3, 0.3));

      var state = container.read(drawControllerProvider(wallId));
      expect(state.activeWallId, wallId);
      expect(state.routes, isNotEmpty);
      expect(state.currentPoints, isNotEmpty);
      expect(state.selectedRouteId, isNotNull);

      notifier.beginPhotoSwitch();

      state = container.read(drawControllerProvider(wallId));
      expect(state.routes, isEmpty);
      expect(state.currentPoints, isEmpty);
      expect(state.redoStack, isEmpty);
      expect(state.selectedRouteId, isNull);
      expect(state.activeWallId, isNull);
      expect(state.activePhotoId, isNull);
    },
  );

  test(
    'T2: THE RACE - a commitRoute in the beginPhotoSwitch window does NOT '
    'persist to the previous wall',
    () async {
      final container = makeContainer();
      final notifier = container.read(drawControllerProvider(wallId).notifier);
      await notifier.loadForWall(wallId, photoId);

      // Original content committed to wall A before the switch.
      notifier.addPoint(const Offset(0.1, 0.1));
      notifier.addPoint(const Offset(0.2, 0.2));
      await notifier.commitRoute();

      // Simulate a new photo being selected: the screen calls
      // beginPhotoSwitch() synchronously, well before the async
      // ensureDefaultForImage/loadForWall chain for the new photo
      // resolves.
      notifier.beginPhotoSwitch();
      expect(container.read(drawControllerProvider(wallId)).activeWallId, isNull);

      // A commit that lands in this window (e.g. the user manages to tap
      // commit before the new photo's wall finishes loading) must only
      // mutate in-memory state, never write through to wall A.
      notifier.addPoint(const Offset(0.9, 0.9));
      notifier.addPoint(const Offset(0.8, 0.8));
      await notifier.commitRoute();
      expect(container.read(drawControllerProvider(wallId)).routes, hasLength(1));

      // A fresh controller loading wall A on the SAME in-memory DB must see
      // only the route committed before the switch.
      final containerB = makeContainer();
      final notifierB = containerB.read(drawControllerProvider(wallId).notifier);
      await notifierB.loadForWall(wallId, photoId);

      final loaded = containerB.read(drawControllerProvider(wallId)).routes;
      expect(loaded, hasLength(1));
      expect(loaded.single.points, [
        const Offset(0.1, 0.1),
        const Offset(0.2, 0.2),
      ]);
    },
  );

  test(
    'T3: after beginPhotoSwitch + loadForWall(B), commitRoute persists to B',
    () async {
      const wall2 = 'wall-2';
      const photo2 = 'photo-2';
      await db
          .into(db.walls)
          .insert(
            WallsCompanion.insert(
              id: wall2,
              createdAt: now,
              updatedAt: now,
              sectorId: 'sector-1',
              name: 'Test Wall 2',
              sortOrder: 1,
            ),
          );
      await db
          .into(db.photos)
          .insert(
            PhotosCompanion.insert(
              id: photo2,
              createdAt: now,
              updatedAt: now,
              wallId: wall2,
              localPath: '/tmp/photo2.jpg',
              kind: 'original',
              width: 100,
              height: 200,
            ),
          );

      final container = makeContainer();
      final notifier = container.read(drawControllerProvider(wallId).notifier);
      await notifier.loadForWall(wallId, photoId);

      notifier.beginPhotoSwitch();
      await notifier.loadForWall(wall2, photo2);
      expect(container.read(drawControllerProvider(wallId)).activeWallId, wall2);

      notifier.addPoint(const Offset(0.5, 0.5));
      notifier.addPoint(const Offset(0.6, 0.6));
      await notifier.commitRoute();

      final containerB = makeContainer();
      final notifierB = containerB.read(drawControllerProvider(wallId).notifier);
      await notifierB.loadForWall(wall2, photo2);
      final loaded = containerB.read(drawControllerProvider(wallId)).routes;
      expect(loaded, hasLength(1));
      expect(loaded.single.points, [
        const Offset(0.5, 0.5),
        const Offset(0.6, 0.6),
      ]);
    },
  );

  test(
    'A9: setRouteMetadata with an active wall persists name/grade; a fresh '
    'controller loading the same wall sees the metadata',
    () async {
      final containerA = makeContainer();
      final notifierA = containerA.read(drawControllerProvider(wallId).notifier);
      await notifierA.loadForWall(wallId, photoId);

      notifierA.addPoint(const Offset(0.1, 0.1));
      notifierA.addPoint(const Offset(0.2, 0.2));
      await notifierA.commitRoute();
      final routeId = containerA.read(drawControllerProvider(wallId)).routes.single.id;

      await notifierA.setRouteMetadata(
        routeId,
        name: 'Crux',
        gradeSystem: GradeSystem.french,
        gradeRaw: '6a+',
        style: 'sport',
        description: 'Crimpy start, big move at the top.',
      );

      final containerB = makeContainer();
      final notifierB = containerB.read(drawControllerProvider(wallId).notifier);
      await notifierB.loadForWall(wallId, photoId);

      final loaded = containerB.read(drawControllerProvider(wallId)).routes.single;
      expect(loaded.name, 'Crux');
      expect(loaded.gradeSystem, GradeSystem.french);
      expect(loaded.gradeRaw, '6a+');
      expect(loaded.gradeSortKey, gradeSortKey(GradeSystem.french, '6a+'));
      expect(loaded.style, 'sport');
      expect(loaded.description, 'Crimpy start, big move at the top.');
    },
  );

  test(
    'FIX #4: a route committed in the async gap between beginPhotoSwitch and '
    'the paired loadForWall(wall2) resolving is preserved AND persisted to '
    "wall2, instead of being silently wiped by loadForWall's own state "
    'overwrite',
    () async {
      const wall2 = 'wall-2';
      const photo2 = 'photo-2';
      await db
          .into(db.walls)
          .insert(
            WallsCompanion.insert(
              id: wall2,
              createdAt: now,
              updatedAt: now,
              sectorId: 'sector-1',
              name: 'Test Wall 2',
              sortOrder: 1,
            ),
          );
      await db
          .into(db.photos)
          .insert(
            PhotosCompanion.insert(
              id: photo2,
              createdAt: now,
              updatedAt: now,
              wallId: wall2,
              localPath: '/tmp/photo2.jpg',
              kind: 'original',
              width: 100,
              height: 200,
            ),
          );

      final container = makeContainer();
      final notifier = container.read(drawControllerProvider(wallId).notifier);
      await notifier.loadForWall(wallId, photoId);

      // Mirrors the real race (TopoCanvasScreen._switchToPhoto): beginPhotoSwitch
      // runs synchronously (clearing routes to empty and setting
      // isSwitchingPhoto), then loadForWall(wall2, photo2) is called but
      // deliberately NOT awaited yet -- its body runs synchronously up to
      // its own internal `await loadRoutes(...)` and then suspends, handing
      // control back here (an `await` always defers at least one microtask
      // in Dart, even for an already-resolved Future) -- exactly the window
      // FIX #4 closes.
      notifier.beginPhotoSwitch();
      final switchFuture = notifier.loadForWall(wall2, photo2);

      // A commit lands in that window (e.g. the user manages to draw +
      // release before wall2's routes finish loading). activeWallId is null
      // right now (beginPhotoSwitch just cleared it), so this only mutates
      // in-memory state, exactly like T2's contract -- but unlike before
      // this fix, it must not evaporate once `switchFuture` applies below.
      notifier.addPoint(const Offset(0.9, 0.9));
      notifier.addPoint(const Offset(0.8, 0.8));
      await notifier.commitRoute();
      expect(
        container.read(drawControllerProvider(wallId)).routes,
        hasLength(1),
      );

      await switchFuture;

      final state = container.read(drawControllerProvider(wallId));
      expect(state.activeWallId, wall2);
      expect(state.isSwitchingPhoto, isFalse);
      expect(
        state.routes,
        hasLength(1),
        reason: 'the mid-switch commit must survive loadForWall applying '
            "wall2's own (empty) loaded list, not be wiped by it",
      );
      expect(state.routes.single.points, [
        const Offset(0.9, 0.9),
        const Offset(0.8, 0.8),
      ]);

      // And it must be persisted for REAL, not just preserved in memory:
      // its original commitRoute() call could only mutate in-memory state
      // (activeWallId was null at the time), so a totally fresh controller
      // loading wall2 from scratch must also see it.
      final containerB = makeContainer();
      final notifierB = containerB.read(drawControllerProvider(wallId).notifier);
      await notifierB.loadForWall(wall2, photo2);
      final loaded = containerB.read(drawControllerProvider(wallId)).routes;
      expect(loaded, hasLength(1));
      expect(loaded.single.points, [
        const Offset(0.9, 0.9),
        const Offset(0.8, 0.8),
      ]);
    },
  );

  test(
    'FIX #4 (control): loadForWall called directly WITHOUT a preceding '
    'beginPhotoSwitch still unconditionally replaces routes (does not merge '
    "leftover state) -- preserves the pre-existing \"switching walls\" "
    'contract',
    () async {
      const wall2 = 'wall-2';
      const photo2 = 'photo-2';
      await db
          .into(db.walls)
          .insert(
            WallsCompanion.insert(
              id: wall2,
              createdAt: now,
              updatedAt: now,
              sectorId: 'sector-1',
              name: 'Test Wall 2',
              sortOrder: 1,
            ),
          );
      await db
          .into(db.photos)
          .insert(
            PhotosCompanion.insert(
              id: photo2,
              createdAt: now,
              updatedAt: now,
              wallId: wall2,
              localPath: '/tmp/photo2.jpg',
              kind: 'original',
              width: 100,
              height: 200,
            ),
          );

      final container = makeContainer();
      final notifier = container.read(drawControllerProvider(wallId).notifier);
      await notifier.loadForWall(wallId, photoId);

      notifier.addPoint(const Offset(0.1, 0.1));
      notifier.addPoint(const Offset(0.2, 0.2));
      await notifier.commitRoute();
      expect(
        container.read(drawControllerProvider(wallId)).routes,
        hasLength(1),
        reason: 'sanity: wall A has a committed route before switching',
      );

      // Direct call, no beginPhotoSwitch: isSwitchingPhoto is still false,
      // so this must fully REPLACE routes with wall2's (empty) list, not
      // merge wall A's leftover route into it.
      await notifier.loadForWall(wall2, photo2);

      final state = container.read(drawControllerProvider(wallId));
      expect(state.activeWallId, wall2);
      expect(
        state.routes,
        isEmpty,
        reason:
            "wall A's route must be fully discarded, not merged into wall2",
      );
    },
  );

  test(
    'FIX #4 (race #2): a SECOND beginPhotoSwitch firing before the FIRST '
    "switch's loadForWall resolves does not lose a route committed in the "
    'first switch\'s window (rapid double-switch)',
    () async {
      const wall2 = 'wall-2';
      const photo2 = 'photo-2';
      const wall3 = 'wall-3';
      const photo3 = 'photo-3';
      for (final w in [
        (wall2, photo2, 'Test Wall 2', 1),
        (wall3, photo3, 'Test Wall 3', 2),
      ]) {
        await db
            .into(db.walls)
            .insert(
              WallsCompanion.insert(
                id: w.$1,
                createdAt: now,
                updatedAt: now,
                sectorId: 'sector-1',
                name: w.$3,
                sortOrder: w.$4,
              ),
            );
        await db
            .into(db.photos)
            .insert(
              PhotosCompanion.insert(
                id: w.$2,
                createdAt: now,
                updatedAt: now,
                wallId: w.$1,
                localPath: '/tmp/${w.$2}.jpg',
                kind: 'original',
                width: 100,
                height: 200,
              ),
            );
      }

      final container = makeContainer();
      final notifier = container.read(drawControllerProvider(wallId).notifier);
      await notifier.loadForWall(wallId, photoId);

      // Switch 1 starts (wall1 -> wall2), deliberately not awaited yet --
      // same "hand control back after its own internal await" trick the
      // FIX #4 test above relies on.
      notifier.beginPhotoSwitch();
      final switchFuture1 = notifier.loadForWall(wall2, photo2);

      // A route gets committed in switch 1's window (activeWallId is null,
      // so this only mutates in-memory state).
      notifier.addPoint(const Offset(0.9, 0.9));
      notifier.addPoint(const Offset(0.8, 0.8));
      await notifier.commitRoute();
      expect(
        container.read(drawControllerProvider(wallId)).routes,
        hasLength(1),
        reason: 'sanity: the route committed mid-switch-1 is in memory',
      );

      // Before switch 1 resolves, a SECOND switch fires (wall2 -> wall3).
      // beginPhotoSwitch must NOT wipe the pending route committed above --
      // it must carry it forward into switch 2.
      notifier.beginPhotoSwitch();
      expect(
        container.read(drawControllerProvider(wallId)).routes,
        hasLength(1),
        reason: 'a route committed during switch 1 must survive a second '
            'beginPhotoSwitch firing before switch 1 resolves',
      );
      final switchFuture2 = notifier.loadForWall(wall3, photo3);

      await switchFuture1;
      await switchFuture2;

      final state = container.read(drawControllerProvider(wallId));
      expect(state.activeWallId, wall3);
      expect(state.activePhotoId, photo3);
      expect(state.isSwitchingPhoto, isFalse);
      expect(
        state.routes,
        hasLength(1),
        reason: 'the route committed during switch 1 must be forwarded '
            "into switch 2's result, not discarded",
      );
      expect(state.routes.single.points, [
        const Offset(0.9, 0.9),
        const Offset(0.8, 0.8),
      ]);

      // And persisted for real against wall3 (not wall2, and not just held
      // in memory): a totally fresh controller loading wall3 must see it.
      final containerB = makeContainer();
      final notifierB = containerB.read(drawControllerProvider(wallId).notifier);
      await notifierB.loadForWall(wall3, photo3);
      final loaded = containerB.read(drawControllerProvider(wallId)).routes;
      expect(loaded, hasLength(1));
      expect(loaded.single.points, [
        const Offset(0.9, 0.9),
        const Offset(0.8, 0.8),
      ]);

      // wall2 itself must have received nothing (the pending route was
      // always destined for "whichever photo the user actually landed
      // on", i.e. wall3, never wall2).
      final containerC = makeContainer();
      final notifierC = containerC.read(drawControllerProvider(wallId).notifier);
      await notifierC.loadForWall(wall2, photo2);
      expect(containerC.read(drawControllerProvider(wallId)).routes, isEmpty);
    },
  );

  test(
    'FIX #4 (race #3): an out-of-order loadForWall resolution (older switch '
    'resolves AFTER a newer one) is discarded instead of clobbering the '
    "newer photo's state",
    () async {
      const wall2 = 'wall-2';
      const photo2 = 'photo-2';
      const wall3 = 'wall-3';
      const photo3 = 'photo-3';
      await db
          .into(db.walls)
          .insert(
            WallsCompanion.insert(
              id: wall2,
              createdAt: now,
              updatedAt: now,
              sectorId: 'sector-1',
              name: 'Test Wall 2',
              sortOrder: 1,
            ),
          );
      await db
          .into(db.walls)
          .insert(
            WallsCompanion.insert(
              id: wall3,
              createdAt: now,
              updatedAt: now,
              sectorId: 'sector-1',
              name: 'Test Wall 3',
              sortOrder: 2,
            ),
          );
      await db
          .into(db.photos)
          .insert(
            PhotosCompanion.insert(
              id: photo2,
              createdAt: now,
              updatedAt: now,
              wallId: wall2,
              localPath: '/tmp/photo2.jpg',
              kind: 'original',
              width: 100,
              height: 200,
            ),
          );
      await db
          .into(db.photos)
          .insert(
            PhotosCompanion.insert(
              id: photo3,
              createdAt: now,
              updatedAt: now,
              wallId: wall3,
              localPath: '/tmp/photo3.jpg',
              kind: 'original',
              width: 100,
              height: 200,
            ),
          );
      // Seed wall2 with a persisted route, so that if the out-of-order
      // resolution guard failed, wall2's load would visibly (and wrongly)
      // clobber the final state below with THIS route.
      await db
          .into(db.routes)
          .insert(
            RoutesCompanion.insert(
              id: 'route-wall2-1',
              createdAt: now,
              updatedAt: now,
              wallId: wall2,
              photoId: photo2,
              number: 1,
              pointsJson: '[{"x":0.05,"y":0.05},{"x":0.06,"y":0.06}]',
              symbolsJson: '[]',
              colorIndex: 0,
              sortOrder: 1,
            ),
          );

      // wall2's loadRoutes is gated open until the test explicitly
      // completes it -- this deterministically forces switch 1 (targeting
      // wall2) to resolve AFTER switch 2 (targeting wall3, ungated).
      final wall2Gate = Completer<void>();
      final repo = _GatedRouteRepository(
        db,
        nowMs: () => now,
        gates: {photo2: wall2Gate.future},
      );
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          nowMsProvider.overrideWithValue(() => now),
          routeRepositoryProvider.overrideWithValue(repo),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(drawControllerProvider(wallId).notifier);
      await notifier.loadForWall(wallId, photoId);

      // Switch 1: wall1 -> wall2. Its loadRoutes is gated and will not
      // resolve until wall2Gate completes.
      notifier.beginPhotoSwitch();
      final switchFuture1 = notifier.loadForWall(wall2, photo2);

      // Switch 2 fires before switch 1 resolves: wall2 -> wall3. wall3's
      // loadRoutes is NOT gated, so this resolves normally.
      notifier.beginPhotoSwitch();
      final switchFuture2 = notifier.loadForWall(wall3, photo3);
      await switchFuture2;

      var state = container.read(drawControllerProvider(wallId));
      expect(state.activeWallId, wall3);
      expect(state.activePhotoId, photo3);
      expect(state.isSwitchingPhoto, isFalse);
      expect(state.routes, isEmpty);

      // Now let switch 1 (the OLDER, superseded switch) finally resolve.
      wall2Gate.complete();
      await switchFuture1;

      // Its stale result must have been discarded outright: state must
      // still reflect wall3, not have been clobbered back to wall2's
      // activeWallId/routes.
      state = container.read(drawControllerProvider(wallId));
      expect(
        state.activeWallId,
        wall3,
        reason: 'the older switch (wall2) resolving late must not reclaim '
            'activeWallId from the newer switch (wall3)',
      );
      expect(state.activePhotoId, photo3);
      expect(state.isSwitchingPhoto, isFalse);
      expect(
        state.routes,
        isEmpty,
        reason: "wall3's (empty) routes must not be replaced by wall2's "
            'seeded route via the stale resolution',
      );
    },
  );

  test(
    'FIX #4 (race #4): cancelPhotoSwitch settles a switch that never gets a '
    'loadForWall (photo-less wall), so a stray route committed there does '
    'NOT leak into -- or get persisted against -- the NEXT wall entered',
    () async {
      final container = makeContainer();
      final notifier = container.read(drawControllerProvider(wallId).notifier);
      await notifier.loadForWall(wallId, photoId);
      notifier.addPoint(const Offset(0.1, 0.1));
      notifier.addPoint(const Offset(0.2, 0.2));
      await notifier.commitRoute();
      expect(
        container.read(drawControllerProvider(wallId)).routes,
        hasLength(1),
        reason: 'sanity: wall A has one persisted route before the '
            'photo-less detour',
      );

      // Enter a photo-less wall (mirrors TopoCanvasScreen.loadWallOriginalPhoto's
      // no-photo branch): beginPhotoSwitch opens the switch, but there is
      // nothing to load, so cancelPhotoSwitch settles it instead of
      // loadForWall.
      final generation = notifier.beginPhotoSwitch();
      expect(
        container.read(drawControllerProvider(wallId)).routes,
        isEmpty,
        reason: 'entering the photo-less wall clears wall A\'s routes off '
            'the canvas',
      );
      notifier.cancelPhotoSwitch(generation);

      // A stray route gets committed on the photo-less wall's empty canvas
      // (activeWallId is null, so this only mutates in-memory state).
      notifier.addPoint(const Offset(0.9, 0.9));
      notifier.addPoint(const Offset(0.8, 0.8));
      await notifier.commitRoute();
      expect(container.read(drawControllerProvider(wallId)).routes, hasLength(1));

      // Re-enter wall A. Because cancelPhotoSwitch settled the previous
      // switch, beginPhotoSwitch here must see isSwitchingPhoto == false
      // and clear the stray route, not carry it forward.
      notifier.beginPhotoSwitch();
      expect(
        container.read(drawControllerProvider(wallId)).routes,
        isEmpty,
        reason: 'the stray route from the photo-less detour must NOT '
            'survive into wall A -- cancelPhotoSwitch settled that switch, '
            'so this beginPhotoSwitch must treat it as the ordinary '
            '(not-already-switching) case',
      );
      await notifier.loadForWall(wallId, photoId);

      final state = container.read(drawControllerProvider(wallId));
      expect(
        state.routes,
        hasLength(1),
        reason: "wall A must show exactly its ORIGINAL persisted route, "
            'with no phantom 2nd route from the photo-less detour\'s stray '
            'commit',
      );
      expect(state.routes.single.points, [
        const Offset(0.1, 0.1),
        const Offset(0.2, 0.2),
      ]);

      // And nothing was ever persisted for the stray route: a totally
      // fresh controller loading wall A must also see exactly one route.
      final containerB = makeContainer();
      final notifierB = containerB.read(drawControllerProvider(wallId).notifier);
      await notifierB.loadForWall(wallId, photoId);
      expect(containerB.read(drawControllerProvider(wallId)).routes, hasLength(1));
    },
  );

  test(
    'FIX #4 (continued): switchTargetPhotoId tracks the destination photoId '
    'for the WHOLE duration of an in-flight loadForWall (not just once it '
    'settles), closing the window where activePhotoId being null mid-switch '
    'made "switching to this photo" and "no photo relevant right now" '
    "indistinguishable -- see TopoCanvasScreen._handleDeletePhoto's doc for "
    'the bug this closes',
    () async {
      const photo2 = 'photo-2';
      await db
          .into(db.photos)
          .insert(
            PhotosCompanion.insert(
              id: photo2,
              createdAt: now,
              updatedAt: now,
              wallId: wallId,
              localPath: '/tmp/photo2.jpg',
              kind: 'original',
              width: 100,
              height: 200,
            ),
          );

      final gate = Completer<void>();
      final repo = _GatedRouteRepository(
        db,
        nowMs: () => now,
        gates: {photo2: gate.future},
      );
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          nowMsProvider.overrideWithValue(() => now),
          routeRepositoryProvider.overrideWithValue(repo),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(drawControllerProvider(wallId).notifier);
      await notifier.loadForWall(wallId, photoId);
      expect(
        container.read(drawControllerProvider(wallId)).switchTargetPhotoId,
        isNull,
      );

      notifier.beginPhotoSwitch();
      expect(
        container.read(drawControllerProvider(wallId)).switchTargetPhotoId,
        isNull,
        reason: 'beginPhotoSwitch itself does not know the destination yet '
            '-- only the loadForWall call that follows it does',
      );

      // Deliberately not awaited yet -- loadForWall runs synchronously up
      // to its own internal `await loadRoutes(...)`, which is gated and
      // suspends, handing control back here (same trick used throughout
      // this file).
      final switchFuture = notifier.loadForWall(wallId, photo2);
      expect(
        container.read(drawControllerProvider(wallId)).switchTargetPhotoId,
        photo2,
        reason: 'set synchronously, before the gated repository read even '
            'starts',
      );
      expect(
        container.read(drawControllerProvider(wallId)).activePhotoId,
        isNull,
        reason: 'sanity: activePhotoId alone cannot distinguish "switching '
            'to photo2" from "no photo relevant" -- that is exactly what '
            'switchTargetPhotoId is for',
      );

      gate.complete();
      await switchFuture;

      final state = container.read(drawControllerProvider(wallId));
      expect(state.activePhotoId, photo2);
      expect(
        state.switchTargetPhotoId,
        isNull,
        reason: 'once the switch settles, the destination IS activePhotoId; '
            'there is no separate in-flight target left to track',
      );
    },
  );

  test(
    'FIX #4 (continued): deleting the switch-target photo mid-switch, with '
    'a route committed in that window, is redirected + preserved -- mirrors '
    "TopoCanvasScreen._handleDeletePhoto's fixed sequence: detecting the "
    'delete via switchTargetPhotoId (since activePhotoId is null throughout '
    'the switch), then settling+redirecting via a second beginPhotoSwitch + '
    "loadForWall to the wall's remaining photo, without discarding the "
    'pending commit or leaving isSwitchingPhoto/switchTargetPhotoId stuck '
    'for the next switch',
    () async {
      const photo2 = 'photo-2'; // the switch target, "deleted" mid-flight
      const photo3 = 'photo-3'; // the wall's remaining photo, redirected onto
      for (final id in [photo2, photo3]) {
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

      // photo2's loadRoutes is gated open so its (deleted-out-from-under-
      // it) load stays in flight until explicitly released, forcing the
      // out-of-order resolution deterministically -- same technique as the
      // race #3 test above.
      final photo2Gate = Completer<void>();
      final repo = _GatedRouteRepository(
        db,
        nowMs: () => now,
        gates: {photo2: photo2Gate.future},
      );
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          nowMsProvider.overrideWithValue(() => now),
          routeRepositoryProvider.overrideWithValue(repo),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(drawControllerProvider(wallId).notifier);
      await notifier.loadForWall(wallId, photoId);

      // User taps photo2 in the strip: beginPhotoSwitch + loadForWall(photo2),
      // deliberately not awaited yet.
      notifier.beginPhotoSwitch();
      final staleSwitch = notifier.loadForWall(wallId, photo2);
      expect(
        container.read(drawControllerProvider(wallId)).switchTargetPhotoId,
        photo2,
      );

      // A route gets committed in that window (activeWallId is null, so
      // this only mutates in-memory state) -- the pending commit this fix
      // must preserve.
      notifier.addPoint(const Offset(0.9, 0.9));
      notifier.addPoint(const Offset(0.8, 0.8));
      await notifier.commitRoute();
      expect(
        container.read(drawControllerProvider(wallId)).routes,
        hasLength(1),
        reason: 'sanity: the route committed mid-switch is in memory',
      );

      // photo2 gets deleted (its row + routes -- not modeled here since
      // DrawController never touches PhotoRepository; what matters is what
      // the FIXED _handleDeletePhoto does next). Because
      // switchTargetPhotoId == photo2, it now correctly treats this like
      // the ordinary "delete the active photo" case: settle + redirect to
      // the wall's remaining photo (photo3) via a SECOND beginPhotoSwitch
      // (bumping switchGeneration, which invalidates the stale in-flight
      // `staleSwitch` above) followed by loadForWall(photo3) -- exactly
      // what _switchToPhoto does.
      notifier.beginPhotoSwitch();
      expect(
        container.read(drawControllerProvider(wallId)).routes,
        hasLength(1),
        reason: "the pending route must survive the redirect's own "
            'beginPhotoSwitch call, not be wiped by it',
      );
      final redirectSwitch = notifier.loadForWall(wallId, photo3);
      await redirectSwitch;

      var state = container.read(drawControllerProvider(wallId));
      expect(
        state.activePhotoId,
        photo3,
        reason: 'the canvas must land on the redirected photo, not the '
            'deleted switch target',
      );
      expect(state.isSwitchingPhoto, isFalse);
      expect(state.switchTargetPhotoId, isNull);
      expect(
        state.routes,
        hasLength(1),
        reason: 'the mid-switch commit must survive the redirect, not be '
            'discarded just because its original destination was deleted',
      );
      expect(state.routes.single.points, [
        const Offset(0.9, 0.9),
        const Offset(0.8, 0.8),
      ]);

      // Now let the stale, superseded photo2 load finally resolve -- it
      // must be discarded outright, not clobber the redirect above.
      photo2Gate.complete();
      await staleSwitch;
      state = container.read(drawControllerProvider(wallId));
      expect(
        state.activePhotoId,
        photo3,
        reason: 'the deleted photo2 resolving late must not reclaim '
            'activePhotoId from the redirect',
      );
      expect(state.routes, hasLength(1));

      // And persisted for real against photo3 (not the deleted photo2, and
      // not just held in memory): a totally fresh controller loading
      // photo3 must also see it.
      final containerB = makeContainer();
      final notifierB = containerB.read(drawControllerProvider(wallId).notifier);
      await notifierB.loadForWall(wallId, photo3);
      final loaded = containerB.read(drawControllerProvider(wallId)).routes;
      expect(loaded, hasLength(1));
      expect(loaded.single.points, [
        const Offset(0.9, 0.9),
        const Offset(0.8, 0.8),
      ]);

      // The next switch (e.g. the user taps back to the wall's original
      // photo) must be clean -- no stale isSwitchingPhoto/
      // switchTargetPhotoId, and photo3's already-persisted route must not
      // be misread as a still-pending mid-switch commit.
      notifier.beginPhotoSwitch();
      final nextState = container.read(drawControllerProvider(wallId));
      expect(nextState.isSwitchingPhoto, isTrue);
      expect(nextState.switchTargetPhotoId, isNull);
      expect(
        nextState.routes,
        isEmpty,
        reason: 'a fresh switch straight after the redirect must not carry '
            "forward photo3's already-persisted route as if it were still "
            'a pending mid-switch commit',
      );
      await notifier.loadForWall(wallId, photoId);
      expect(
        container.read(drawControllerProvider(wallId)).routes,
        isEmpty,
        reason: "the wall's original photo has no routes of its own",
      );
    },
  );

  test(
    'FIX #4 (continued): a switch whose attach/load path THROWS mid-flight '
    "(mirrors TopoCanvasScreen._attachPhotoAndLoad's catch-all) is settled "
    'via cancelPhotoSwitch instead of leaving isSwitchingPhoto stuck true, '
    'so the NEXT switch is unaffected',
    () async {
      final container = makeContainer();
      final notifier = container.read(drawControllerProvider(wallId).notifier);
      await notifier.loadForWall(wallId, photoId);
      notifier.addPoint(const Offset(0.1, 0.1));
      notifier.addPoint(const Offset(0.2, 0.2));
      await notifier.commitRoute();
      expect(
        container.read(drawControllerProvider(wallId)).routes,
        hasLength(1),
        reason: 'sanity: wall has one persisted route before the failed '
            'attach attempt',
      );

      // Mirrors the ref.listen callback firing the moment a freshly-picked
      // photo's path is selected: beginPhotoSwitch opens the switch, well
      // before _attachPhotoAndLoad's own attachPhotoToWall call even
      // starts.
      final generation = notifier.beginPhotoSwitch();
      expect(
        container.read(drawControllerProvider(wallId)).isSwitchingPhoto,
        isTrue,
      );

      // A stray route gets committed while the (about-to-fail) attach is
      // in flight -- activeWallId is null, so only in-memory.
      notifier.addPoint(const Offset(0.9, 0.9));
      notifier.addPoint(const Offset(0.8, 0.8));
      await notifier.commitRoute();

      // attachPhotoToWall (or loadForWall's own repository read) throws --
      // _attachPhotoAndLoad's catch-all settles the switch via
      // cancelPhotoSwitch(generation) instead of ever reaching
      // loadForWall.
      notifier.cancelPhotoSwitch(generation);

      final settled = container.read(drawControllerProvider(wallId));
      expect(
        settled.isSwitchingPhoto,
        isFalse,
        reason: 'the fix: an exception mid-attach must not leave '
            'isSwitchingPhoto stuck true forever',
      );
      expect(settled.switchTargetPhotoId, isNull);

      // The NEXT switch (e.g. the user retries picking a photo) must
      // behave like an ORDINARY switch, not one that thinks it is still
      // mid-flight from the failed attempt -- the stray route above must
      // not leak into it.
      notifier.beginPhotoSwitch();
      expect(
        container.read(drawControllerProvider(wallId)).routes,
        isEmpty,
        reason: 'the stray route from the failed attach must not survive '
            'into the next switch -- cancelPhotoSwitch settled the failed '
            'one, so this beginPhotoSwitch sees isSwitchingPhoto == false '
            'and clears routes normally',
      );
      await notifier.loadForWall(wallId, photoId);
      expect(
        container.read(drawControllerProvider(wallId)).routes,
        hasLength(1),
        reason: 'wall must show exactly its original persisted route, no '
            'phantom 2nd route from the failed attach attempt',
      );
    },
  );

  // Note: the screen-level latest-path guard added to
  // TopoCanvasScreen._loadWallForImage (`if (!mounted ||
  // ref.read(selectedImageProvider) != path) return;`) is verified by code
  // inspection rather than a test here, per the constraint that a real
  // image-decode widget test hangs under fake-async. The on-device manual
  // test exercises that guard against the real decode path.
}
