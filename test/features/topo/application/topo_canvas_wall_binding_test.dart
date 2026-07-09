import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/core/db/database_provider.dart';
import 'package:climbtopo/features/library/application/library_providers.dart';
import 'package:climbtopo/features/topo/application/draw_controller.dart';
import 'package:climbtopo/features/topo/data/route_repository.dart';
import 'package:climbtopo/features/topo/domain/topo_route.dart';
import 'package:climbtopo/features/topo/presentation/topo_canvas_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// M6 subtask 4 (wall-bound canvas + attach-to-wall) tests, at the
/// controller/repository level: no widget is ever pumped and no image is
/// ever decoded, per the constraint documented at length in
/// `test/widget_test.dart`'s M3 NOTE (real `FileImage` decode cannot be
/// driven to completion under `testWidgets`' fake-async clock). Both
/// [loadWallOriginalPhoto] (the "restore a wall's persisted photo/routes on
/// open" path) and [LibraryCrudRepository.attachPhotoToWall] (the "pick a
/// photo, attach it to WALL, don't touch the library hierarchy" path) are
/// pure async functions/methods over a real in-memory [AppDatabase] and a
/// [ProviderContainer], so they're exercised directly here exactly as
/// [_TopoCanvasScreenState] would call them, without needing
/// [TopoCanvasScreen] itself on screen — [loadWallOriginalPhoto] takes its
/// dependencies directly (a [PhotoRepository], a [DrawController]) rather
/// than a `WidgetRef`, since `WidgetRef` is `sealed` in riverpod 3 and so
/// cannot be faked in a plain `test()`.
void main() {
  late AppDatabase db;

  ProviderContainer makeContainer() {
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        nowMsProvider.overrideWithValue(() => 1000),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  test(
    'A1: loadWallOriginalPhoto(ref, wallId) loads a persisted original '
    "photo's routes into drawControllerProvider (activeWallId == wallId, "
    'both seeded routes present) — no widget, no image decode',
    () async {
      final container = makeContainer();
      final crud = container.read(libraryCrudRepositoryProvider);

      final area = await crud.createArea('Area');
      final sector = await crud.createSector(area.id, 'Sector');
      final wall = await crud.createWall(sector.id, 'Wall');
      final photoId = await crud.attachPhotoToWall(
        wall.id,
        '/tmp/wall-photo.jpg',
        1000,
        2000,
      );

      final routeRepo = RouteRepository(db, nowMs: () => 1000);
      await routeRepo.upsertRoute(
        wall.id,
        photoId,
        const TopoRoute(id: 1, number: 1, points: [Offset(0.1, 0.1), Offset(0.2, 0.2)]),
      );
      await routeRepo.upsertRoute(
        wall.id,
        photoId,
        const TopoRoute(id: 2, number: 2, points: [Offset(0.3, 0.3), Offset(0.4, 0.4)]),
      );

      // Exercise the screen's actual load path for this wallId — the same
      // function TopoCanvasScreen._loadInitialPhotoForWall calls on init.
      final photo = await loadWallOriginalPhoto(
        container.read(photoRepositoryProvider),
        container.read(drawControllerProvider.notifier),
        wall.id,
      );

      expect(photo, isNotNull);
      expect(photo!.id, photoId);
      expect(photo.wallId, wall.id);
      expect(photo.localPath, '/tmp/wall-photo.jpg');

      final state = container.read(drawControllerProvider);
      expect(state.activeWallId, wall.id);
      expect(state.activePhotoId, photoId);
      expect(state.routes, hasLength(2));
      expect(state.routes.map((r) => r.number), containsAll([1, 2]));
    },
  );

  test(
    'A1b: loadWallOriginalPhoto returns null and leaves drawControllerProvider '
    'untouched when the wall has no original photo yet',
    () async {
      final container = makeContainer();
      final crud = container.read(libraryCrudRepositoryProvider);
      final area = await crud.createArea('Area');
      final sector = await crud.createSector(area.id, 'Sector');
      final wall = await crud.createWall(sector.id, 'Wall');

      final photo = await loadWallOriginalPhoto(
        container.read(photoRepositoryProvider),
        container.read(drawControllerProvider.notifier),
        wall.id,
      );

      expect(photo, isNull);
      expect(container.read(drawControllerProvider).activeWallId, isNull);
    },
  );

  test(
    'A2: attaching a photo to a wall goes through '
    'LibraryCrudRepository.attachPhotoToWall (NOT the old '
    'ensureDefaultForImage default-hierarchy path) — a fresh loadOriginal '
    'for that wallId returns exactly the attached photo, and no new '
    'Area/Sector/Wall is created as a side effect',
    () async {
      final container = makeContainer();
      final crud = container.read(libraryCrudRepositoryProvider);

      final area = await crud.createArea('Area');
      final sector = await crud.createSector(area.id, 'Sector');
      final wall = await crud.createWall(sector.id, 'Wall');

      final areasBefore = await crud.listAreas();
      final sectorsBefore = await crud.listSectors(area.id);
      final wallsBefore = await crud.listWalls(sector.id);

      // This is exactly what TopoCanvasScreen._attachPhotoAndLoad calls on
      // a photo pick — attachPhotoToWall, not the topo feature's OLD
      // LibraryRepository.ensureDefaultForImage.
      final photoId = await crud.attachPhotoToWall(
        wall.id,
        '/tmp/picked.jpg',
        640,
        480,
      );

      final reloaded = await container
          .read(photoRepositoryProvider)
          .loadOriginal(wall.id);

      expect(reloaded, isNotNull);
      expect(reloaded!.id, photoId);
      expect(reloaded.wallId, wall.id, reason: 'must belong to the navigated wall');
      expect(reloaded.kind, 'original');
      expect(reloaded.localPath, '/tmp/picked.jpg');
      expect(reloaded.width, 640);
      expect(reloaded.height, 480);

      // No new Area/Sector/Wall was created as a side effect of attaching —
      // unlike the retired ensureDefaultForImage hierarchy, attaching a
      // photo never touches the library CRUD tables.
      expect(await crud.listAreas(), hasLength(areasBefore.length));
      expect(await crud.listSectors(area.id), hasLength(sectorsBefore.length));
      expect(await crud.listWalls(sector.id), hasLength(wallsBefore.length));
      expect(
        (await crud.listWalls(sector.id)).map((w) => w.id),
        contains(wall.id),
      );
    },
  );

  // T1/T2 (HIGH data-corruption fix regression): `selectedImageProvider` and
  // `drawControllerProvider` are app-lifetime globals — a single
  // ProviderContainer/DrawController instance is reused across BOTH wall
  // loads below, exactly like the real app reuses one screen's/app's
  // provider container across wall navigations. A1/A1b/A2 above each make
  // their OWN fresh container per test, so none of them ever exercised two
  // sequential `loadWallOriginalPhoto` calls sharing state — which is
  // exactly the scenario that hid the bug: entering a photo-less wall B
  // right after a has-photo wall A left B showing A's routes/activeWallId,
  // since the old code only reset state inside the `beforeLoadForWall`
  // hook, which never ran when `loadOriginal` returned null.
  test(
    'T1: entering a photo-less wall B right after a has-photo wall A '
    "does NOT leak wall A's routes/activeWallId into B — the "
    'unconditional pre-load reset in loadWallOriginalPhoto clears '
    'drawControllerProvider (and, via onReset, selectedImageProvider) even '
    'when the new wall has no photo',
    () async {
      final container = makeContainer();
      final crud = container.read(libraryCrudRepositoryProvider);
      final photoRepo = container.read(photoRepositoryProvider);
      final drawNotifier = container.read(drawControllerProvider.notifier);

      final area = await crud.createArea('Area');
      final sector = await crud.createSector(area.id, 'Sector');

      // Wall A: has a photo + 2 routes.
      final wallA = await crud.createWall(sector.id, 'Wall A');
      final photoIdA = await crud.attachPhotoToWall(
        wallA.id,
        '/tmp/wall-a.jpg',
        1000,
        2000,
      );
      final routeRepo = RouteRepository(db, nowMs: () => 1000);
      await routeRepo.upsertRoute(
        wallA.id,
        photoIdA,
        const TopoRoute(id: 1, number: 1, points: [Offset(0.1, 0.1), Offset(0.2, 0.2)]),
      );
      await routeRepo.upsertRoute(
        wallA.id,
        photoIdA,
        const TopoRoute(id: 2, number: 2, points: [Offset(0.3, 0.3), Offset(0.4, 0.4)]),
      );

      // Wall B: no photo attached at all.
      final wallB = await crud.createWall(sector.id, 'Wall B');

      // Screen-side bookkeeping the real _loadInitialPhotoForWall performs,
      // reproduced here directly against the (fake, non-sealed) state we can
      // observe without a WidgetRef: track "selected image path" the same
      // way SelectedImageNotifier does.
      String? selectedImagePath;

      // Enter wall A (the has-photo case) — same call the screen makes on
      // open.
      final photoA = await loadWallOriginalPhoto(
        photoRepo,
        drawNotifier,
        wallA.id,
        onReset: () => selectedImagePath = null,
        beforeLoadForWall: (p) => selectedImagePath = p.localPath,
      );

      expect(photoA, isNotNull);
      final stateA = container.read(drawControllerProvider);
      expect(stateA.activeWallId, wallA.id);
      expect(stateA.routes, hasLength(2));
      expect(selectedImagePath, '/tmp/wall-a.jpg');

      // Now enter wall B (the photo-less case) on the SAME container/
      // notifier — this is the real-app scenario: navigating from A to B
      // never gets a fresh drawControllerProvider/selectedImageProvider.
      final photoB = await loadWallOriginalPhoto(
        photoRepo,
        drawNotifier,
        wallB.id,
        onReset: () => selectedImagePath = null,
        beforeLoadForWall: (p) => selectedImagePath = p.localPath,
      );

      expect(photoB, isNull, reason: 'wall B has no original photo');

      final stateB = container.read(drawControllerProvider);
      // The bug: without the unconditional reset, stateB here would still
      // be wall A's state (activeWallId == wallA.id, 2 routes).
      expect(
        stateB.routes,
        isEmpty,
        reason: "wall A's routes must not leak into photo-less wall B",
      );
      expect(
        stateB.activeWallId,
        isNot(wallA.id),
        reason: 'activeWallId must not still point at wall A',
      );
      expect(
        stateB.activeWallId,
        isNull,
        reason: 'wall B has no photo, so there is nothing to be active for',
      );
      expect(
        selectedImagePath,
        isNull,
        reason:
            'selectedImageProvider must be cleared, not left showing '
            "wall A's photo",
      );
    },
  );

  test(
    'T2: after entering photo-less wall B (activeWallId null), '
    'committing a route does NOT persist to wall A — a fresh '
    "loadForWall(A) still returns exactly A's original 2 routes",
    () async {
      final container = makeContainer();
      final crud = container.read(libraryCrudRepositoryProvider);
      final photoRepo = container.read(photoRepositoryProvider);
      final drawNotifier = container.read(drawControllerProvider.notifier);

      final area = await crud.createArea('Area');
      final sector = await crud.createSector(area.id, 'Sector');

      final wallA = await crud.createWall(sector.id, 'Wall A');
      final photoIdA = await crud.attachPhotoToWall(
        wallA.id,
        '/tmp/wall-a.jpg',
        1000,
        2000,
      );
      final routeRepo = RouteRepository(db, nowMs: () => 1000);
      await routeRepo.upsertRoute(
        wallA.id,
        photoIdA,
        const TopoRoute(id: 1, number: 1, points: [Offset(0.1, 0.1), Offset(0.2, 0.2)]),
      );
      await routeRepo.upsertRoute(
        wallA.id,
        photoIdA,
        const TopoRoute(id: 2, number: 2, points: [Offset(0.3, 0.3), Offset(0.4, 0.4)]),
      );

      final wallB = await crud.createWall(sector.id, 'Wall B');

      // Enter A, then B — same sequence as T1, sharing one container.
      await loadWallOriginalPhoto(photoRepo, drawNotifier, wallA.id);
      final photoB = await loadWallOriginalPhoto(
        photoRepo,
        drawNotifier,
        wallB.id,
      );
      expect(photoB, isNull);
      expect(container.read(drawControllerProvider).activeWallId, isNull);

      // Simulate a stray in-flight draw + commit landing on wall B's (clean,
      // wall-less) screen state.
      drawNotifier.addPoint(const Offset(0.5, 0.5));
      drawNotifier.addPoint(const Offset(0.6, 0.6));
      await drawNotifier.commitRoute();

      // The commit only mutated in-memory state (activeWallId was null, so
      // commitRoute's persistence write-through no-oped — see its doc) and
      // never reached the database. Re-loading wall A from scratch must
      // still show exactly its original 2 routes: no phantom 3rd route from
      // B's stray commit.
      final freshDrawNotifier = container.read(drawControllerProvider.notifier);
      final reloadedA = await loadWallOriginalPhoto(
        photoRepo,
        freshDrawNotifier,
        wallA.id,
      );

      expect(reloadedA, isNotNull);
      final finalStateA = container.read(drawControllerProvider);
      expect(finalStateA.activeWallId, wallA.id);
      expect(finalStateA.routes, hasLength(2));
      expect(finalStateA.routes.map((r) => r.number), containsAll([1, 2]));
    },
  );
}
