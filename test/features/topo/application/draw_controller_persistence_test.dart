import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/core/db/database_provider.dart';
import 'package:climbtopo/features/topo/application/draw_controller.dart';
import 'package:climbtopo/features/topo/domain/topo_route.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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
    final notifier = container.read(drawControllerProvider.notifier);

    await notifier.loadForWall(wallId, photoId);

    final state = container.read(drawControllerProvider);
    expect(state.routes, isEmpty);
    expect(state.activeWallId, wallId);
    expect(state.activePhotoId, photoId);
    expect(state.nextNumber, 1);
    expect(state.nextId, 1);
  });

  test('A2: commitRoute with an active wall persists the route; a fresh '
      'controller loading the same wall sees it', () async {
    final containerA = makeContainer();
    final notifierA = containerA.read(drawControllerProvider.notifier);
    await notifierA.loadForWall(wallId, photoId);

    notifierA.addPoint(const Offset(0.1, 0.1));
    notifierA.addPoint(const Offset(0.2, 0.2));
    await notifierA.commitRoute();

    final containerB = makeContainer();
    final notifierB = containerB.read(drawControllerProvider.notifier);
    await notifierB.loadForWall(wallId, photoId);

    final loaded = containerB.read(drawControllerProvider).routes;
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
      final notifierA = containerA.read(drawControllerProvider.notifier);
      await notifierA.loadForWall(wallId, photoId);

      notifierA.addPoint(const Offset(0.1, 0.1));
      notifierA.addPoint(const Offset(0.2, 0.2));
      await notifierA.commitRoute();
      final routeId = containerA.read(drawControllerProvider).routes.single.id;

      await notifierA.removeRoute(routeId);
      expect(containerA.read(drawControllerProvider).routes, isEmpty);

      final containerB = makeContainer();
      final notifierB = containerB.read(drawControllerProvider.notifier);
      await notifierB.loadForWall(wallId, photoId);
      expect(containerB.read(drawControllerProvider).routes, isEmpty);
    },
  );

  test('A4: placeSymbol with a selected route and active symbol persists the '
      'symbol; a reload sees it', () async {
    final containerA = makeContainer();
    final notifierA = containerA.read(drawControllerProvider.notifier);
    await notifierA.loadForWall(wallId, photoId);

    notifierA.addPoint(const Offset(0.1, 0.1));
    notifierA.addPoint(const Offset(0.2, 0.2));
    await notifierA.commitRoute();
    final routeId = containerA.read(drawControllerProvider).routes.single.id;

    notifierA.selectRoute(routeId);
    notifierA.setActiveSymbol(SymbolType.bolt);
    const symbolAt = Offset(0.15, 0.15);
    await notifierA.placeSymbol(symbolAt);

    expect(containerA.read(drawControllerProvider).routes.single.symbols, [
      const TopoSymbol(type: SymbolType.bolt, position: symbolAt),
    ]);

    final containerB = makeContainer();
    final notifierB = containerB.read(drawControllerProvider.notifier);
    await notifierB.loadForWall(wallId, photoId);
    expect(containerB.read(drawControllerProvider).routes.single.symbols, [
      const TopoSymbol(type: SymbolType.bolt, position: symbolAt),
    ]);
  });

  test('A5: toggleRouteVisibility persists the flipped flag; a reload reflects '
      'it', () async {
    final containerA = makeContainer();
    final notifierA = containerA.read(drawControllerProvider.notifier);
    await notifierA.loadForWall(wallId, photoId);

    notifierA.addPoint(const Offset(0.1, 0.1));
    notifierA.addPoint(const Offset(0.2, 0.2));
    await notifierA.commitRoute();
    final routeId = containerA.read(drawControllerProvider).routes.single.id;
    expect(
      containerA.read(drawControllerProvider).routes.single.visible,
      isTrue,
    );

    await notifierA.toggleRouteVisibility(routeId);
    expect(
      containerA.read(drawControllerProvider).routes.single.visible,
      isFalse,
    );

    final containerB = makeContainer();
    final notifierB = containerB.read(drawControllerProvider.notifier);
    await notifierB.loadForWall(wallId, photoId);
    expect(
      containerB.read(drawControllerProvider).routes.single.visible,
      isFalse,
    );
  });

  test('A6: relaunch simulation - controller A commits two routes (one with a '
      'symbol, one hidden), controller B loads both with matching data and '
      'nextNumber == 3', () async {
    final containerA = makeContainer();
    final notifierA = containerA.read(drawControllerProvider.notifier);
    await notifierA.loadForWall(wallId, photoId);

    // Route 1: gets a symbol.
    notifierA.addPoint(const Offset(0.1, 0.1));
    notifierA.addPoint(const Offset(0.2, 0.2));
    await notifierA.commitRoute();
    final firstId = containerA.read(drawControllerProvider).routes[0].id;
    notifierA.selectRoute(firstId);
    notifierA.setActiveSymbol(SymbolType.anchor);
    const symbolAt = Offset(0.15, 0.15);
    await notifierA.placeSymbol(symbolAt);

    // Route 2: hidden via toggle.
    notifierA.addPoint(const Offset(0.3, 0.3));
    notifierA.addPoint(const Offset(0.4, 0.4));
    await notifierA.commitRoute();
    final secondId = containerA.read(drawControllerProvider).routes[1].id;
    await notifierA.toggleRouteVisibility(secondId);

    final containerB = makeContainer();
    final notifierB = containerB.read(drawControllerProvider.notifier);
    await notifierB.loadForWall(wallId, photoId);

    final stateB = containerB.read(drawControllerProvider);
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
    final notifier = container.read(drawControllerProvider.notifier);

    expect(container.read(drawControllerProvider).activeWallId, isNull);

    notifier.addPoint(const Offset(0.1, 0.1));
    notifier.addPoint(const Offset(0.2, 0.2));
    await notifier.commitRoute();
    final routeId = container.read(drawControllerProvider).routes.single.id;
    expect(container.read(drawControllerProvider).routes, hasLength(1));

    notifier.selectRoute(routeId);
    notifier.setActiveSymbol(SymbolType.top);
    await notifier.placeSymbol(const Offset(0.15, 0.15));
    expect(
      container.read(drawControllerProvider).routes.single.symbols,
      hasLength(1),
    );

    await notifier.toggleRouteVisibility(routeId);
    expect(
      container.read(drawControllerProvider).routes.single.visible,
      isFalse,
    );

    await notifier.removeRoute(routeId);
    expect(container.read(drawControllerProvider).routes, isEmpty);

    expect(container.read(drawControllerProvider).activeWallId, isNull);
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
      final notifier = container.read(drawControllerProvider.notifier);

      // Wall 1: commit a route, then start an in-progress route + selection.
      await notifier.loadForWall(wallId, photoId);
      notifier.addPoint(const Offset(0.1, 0.1));
      notifier.addPoint(const Offset(0.2, 0.2));
      await notifier.commitRoute();
      final wall1RouteId = container
          .read(drawControllerProvider)
          .routes
          .single
          .id;
      notifier.selectRoute(wall1RouteId);
      notifier.addPoint(const Offset(0.3, 0.3));
      expect(container.read(drawControllerProvider).currentPoints, isNotEmpty);
      expect(container.read(drawControllerProvider).routes, isNotEmpty);
      expect(container.read(drawControllerProvider).selectedRouteId, isNotNull);

      // Switch to wall 2 (empty): resets in-progress drawing state AND
      // swaps in wall 2's (empty) routes.
      await notifier.loadForWall(wall2, photo2);
      var state = container.read(drawControllerProvider);
      expect(state.activeWallId, wall2);
      expect(state.currentPoints, isEmpty);
      expect(state.routes, isEmpty);
      expect(state.selectedRouteId, isNull);
      expect(state.nextNumber, 1);

      // Switch back to wall 1: its persisted route reappears.
      await notifier.loadForWall(wallId, photoId);
      state = container.read(drawControllerProvider);
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
      final notifier = container.read(drawControllerProvider.notifier);
      await notifier.loadForWall(wallId, photoId);

      notifier.addPoint(const Offset(0.1, 0.1));
      notifier.addPoint(const Offset(0.2, 0.2));
      await notifier.commitRoute();
      final routeId = container.read(drawControllerProvider).routes.single.id;
      notifier.selectRoute(routeId);
      notifier.addPoint(const Offset(0.3, 0.3));

      var state = container.read(drawControllerProvider);
      expect(state.activeWallId, wallId);
      expect(state.routes, isNotEmpty);
      expect(state.currentPoints, isNotEmpty);
      expect(state.selectedRouteId, isNotNull);

      notifier.beginPhotoSwitch();

      state = container.read(drawControllerProvider);
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
      final notifier = container.read(drawControllerProvider.notifier);
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
      expect(container.read(drawControllerProvider).activeWallId, isNull);

      // A commit that lands in this window (e.g. the user manages to tap
      // commit before the new photo's wall finishes loading) must only
      // mutate in-memory state, never write through to wall A.
      notifier.addPoint(const Offset(0.9, 0.9));
      notifier.addPoint(const Offset(0.8, 0.8));
      await notifier.commitRoute();
      expect(container.read(drawControllerProvider).routes, hasLength(1));

      // A fresh controller loading wall A on the SAME in-memory DB must see
      // only the route committed before the switch.
      final containerB = makeContainer();
      final notifierB = containerB.read(drawControllerProvider.notifier);
      await notifierB.loadForWall(wallId, photoId);

      final loaded = containerB.read(drawControllerProvider).routes;
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
      final notifier = container.read(drawControllerProvider.notifier);
      await notifier.loadForWall(wallId, photoId);

      notifier.beginPhotoSwitch();
      await notifier.loadForWall(wall2, photo2);
      expect(container.read(drawControllerProvider).activeWallId, wall2);

      notifier.addPoint(const Offset(0.5, 0.5));
      notifier.addPoint(const Offset(0.6, 0.6));
      await notifier.commitRoute();

      final containerB = makeContainer();
      final notifierB = containerB.read(drawControllerProvider.notifier);
      await notifierB.loadForWall(wall2, photo2);
      final loaded = containerB.read(drawControllerProvider).routes;
      expect(loaded, hasLength(1));
      expect(loaded.single.points, [
        const Offset(0.5, 0.5),
        const Offset(0.6, 0.6),
      ]);
    },
  );

  // Note: the screen-level latest-path guard added to
  // TopoCanvasScreen._loadWallForImage (`if (!mounted ||
  // ref.read(selectedImageProvider) != path) return;`) is verified by code
  // inspection rather than a test here, per the constraint that a real
  // image-decode widget test hangs under fake-async. The on-device manual
  // test exercises that guard against the real decode path.
}
