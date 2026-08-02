import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/topo/application/draw_controller.dart';
import 'package:masi/features/topo/data/photo_write_exception.dart';
import 'package:masi/features/topo/data/route_repository.dart';
import 'package:masi/features/topo/domain/topo_route.dart';

/// UF-2 (a route LOAD that fails is indistinguishable from "this topo has no
/// routes").
///
/// The write side of this problem is already covered by
/// `draw_controller_persist_failure_test.dart` (UF-1). This file locks the READ
/// side, which fails in two distinct ways — the second one is the reason this
/// matters more than a missing try/catch:
///
///  1. **The switch is never settled.** [DrawController.beginPhotoSwitch] sets
///     `isSwitchingPhoto = true` and only [DrawController.loadForWall] or
///     [DrawController.cancelPhotoSwitch] can clear it. When `loadRoutes`
///     threw, `loadForWall` propagated and cleared nothing, so the flag stayed
///     stuck `true` — violating the invariant `_attachPhotoAndLoad`'s FIX #4
///     doc states outright: EVERY exit path must settle the switch it opened.
///
///  2. **The stuck flag then corrupts an unrelated, LATER photo switch.** With
///     `isSwitchingPhoto` stuck `true`, the next `beginPhotoSwitch` misreads it
///     as "a real switch is still in flight" and CARRIES FORWARD
///     [DrawState.routes] instead of clearing them — and the next successful
///     `loadForWall` then merges those carried-forward routes in and PERSISTS
///     them (`RouteWriteOperation.preserveRouteAcrossPhotoSwitch`). So a route
///     the climber drew on photo 1's blank-looking canvas silently lands in
///     photo 2's database rows. That is the redraw/duplicate harm: the canvas
///     rendered "no routes" when the truth was "routes unknown", the climber
///     redrew, and the redraw was filed against the wrong photo.
///
/// The fix is that a failed load settles its own switch, records
/// [DrawState.lastLoadFailure] (the "routes are UNKNOWN, not empty" marker the
/// canvas needs to stop implying an empty topo), and leaves
/// [DrawState.activeWallId]/[DrawState.activePhotoId] null so nothing can be
/// persisted against a photo whose real route set was never read.
class _LoadFailingRouteRepository extends RouteRepository {
  _LoadFailingRouteRepository(super.db, {required super.nowMs});

  /// Photo ids whose [loadRoutes] must throw [loadError] instead of reading.
  /// Anything not listed delegates to the real implementation, so one test can
  /// fail photo 1's load and still let photo 2's succeed.
  final Set<String> failingPhotoIds = <String>{};

  /// Thrown by a failing [loadRoutes]. Defaults to the browser out-of-room
  /// signal so the real `classifyPhotoWriteFailure` path is exercised.
  Object loadError = _QuotaExceededError();

  int loadAttempts = 0;

  @override
  Future<List<TopoRoute>> loadRoutes(String wallId, String photoId) async {
    loadAttempts++;
    if (!failingPhotoIds.contains(photoId)) {
      return super.loadRoutes(wallId, photoId);
    }
    throw loadError;
  }
}

/// Stands in for the browser's out-of-room signal. `classifyPhotoWriteFailure`
/// is deliberately STRING-based (see its doc), so reproducing the marker text
/// is enough to exercise the real classification path on the plain Dart VM.
/// Mirrors `draw_controller_persist_failure_test.dart`'s identical class
/// (file-private there).
class _QuotaExceededError {
  @override
  String toString() => 'QuotaExceededError: The quota has been exceeded.';
}

void main() {
  const wallId = 'wall-1';
  const photoId = 'photo-1';
  const otherPhotoId = 'photo-2';
  const now = 1000;

  late AppDatabase db;
  late _LoadFailingRouteRepository repo;
  late ProviderContainer container;

  Future<void> seedHierarchy() async {
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
    for (final id in const [photoId, otherPhotoId]) {
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

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await seedHierarchy();
    repo = _LoadFailingRouteRepository(db, nowMs: () => now);
    container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        nowMsProvider.overrideWithValue(() => now),
        routeRepositoryProvider.overrideWithValue(repo),
      ],
    );
    // LIFO: the container is disposed first, then the database it read from.
    addTearDown(db.close);
    addTearDown(container.dispose);
  });

  /// `drawControllerProvider` is autoDispose: a bare `.notifier` read would be
  /// torn down across an `await` by the real zero-duration teardown timer.
  void keepControllerAlive() {
    final sub = container.listen(drawControllerProvider(wallId), (_, _) {});
    addTearDown(sub.close);
  }

  DrawController controllerFor() =>
      container.read(drawControllerProvider(wallId).notifier);
  DrawState stateFor() => container.read(drawControllerProvider(wallId));

  /// Reads what is ACTUALLY on disk, bypassing the failing double entirely.
  Future<List<TopoRoute>> persistedRoutes([String photo = photoId]) =>
      RouteRepository(db, nowMs: () => now).loadRoutes(wallId, photo);

  /// Draws and commits a two-point line.
  Future<void> commitTwoPointRoute(DrawController c) async {
    c.setMode(DrawMode.draw);
    c.addPoint(const Offset(0.1, 0.1));
    c.addPoint(const Offset(0.2, 0.2));
    await c.commitRoute();
  }

  group('UF-2: loadForWall when the routes cannot be read at all', () {
    test(
      'settles the switch it was supposed to close, instead of leaving '
      'isSwitchingPhoto stuck true',
      () async {
        keepControllerAlive();
        final c = controllerFor();
        repo.failingPhotoIds.add(photoId);

        final generation = c.beginPhotoSwitch();
        expect(
          stateFor().isSwitchingPhoto,
          isTrue,
          reason: 'precondition: beginPhotoSwitch opened a switch',
        );

        await c.loadForWall(wallId, photoId);

        expect(
          stateFor().isSwitchingPhoto,
          isFalse,
          reason:
              'A failed load is still an EXIT PATH out of the switch '
              'beginPhotoSwitch opened. Leaving it true is what corrupts the '
              'next, unrelated beginPhotoSwitch (see this file header).',
        );
        expect(
          stateFor().switchTargetPhotoId,
          isNull,
          reason:
              'the in-flight destination is settled along with the flag, '
              'exactly as cancelPhotoSwitch does it',
        );
        expect(
          stateFor().switchGeneration,
          generation,
          reason: 'a failed load must not invent a new switch',
        );
      },
    );

    test('does not rethrow — it reports through DrawState instead', () async {
      keepControllerAlive();
      final c = controllerFor();
      repo.failingPhotoIds.add(photoId);
      c.beginPhotoSwitch();

      await expectLater(c.loadForWall(wallId, photoId), completes);
    });

    test(
      'records lastLoadFailure so the canvas can tell UNKNOWN from EMPTY, '
      'with the shared quota wording',
      () async {
        keepControllerAlive();
        final c = controllerFor();
        repo.failingPhotoIds.add(photoId);
        c.beginPhotoSwitch();

        await c.loadForWall(wallId, photoId);

        final failure = stateFor().lastLoadFailure;
        expect(
          failure,
          isNotNull,
          reason:
              'routes == [] after a FAILED read is indistinguishable from a '
              'topo that genuinely has none. This field is the difference, '
              'and it is what stops the canvas implying the work is gone.',
        );
        expect(
          failure!.failure,
          PhotoWriteFailure.quotaExceeded,
          reason:
              'reuses the shared string-based classifier rather than a fourth '
              'private one',
        );
        expect(failure.wallId, wallId);
        expect(failure.photoId, photoId);
        expect(
          failure.userMessage,
          contains('Out of storage space'),
          reason:
              'same frame as photoWriteFailureSnackBar/routeWriteFailure'
              'SnackBar — one device problem must not read as three faults',
        );
        expect(
          failure.userMessage,
          contains('still saved'),
          reason:
              'THE point of the message: the routes are on disk, they just '
              'could not be read. A climber told otherwise redraws them.',
        );
      },
    );

    test(
      'leaves activeWallId/activePhotoId null, so nothing can be written '
      'against a photo whose real routes were never read',
      () async {
        keepControllerAlive();
        final c = controllerFor();
        repo.failingPhotoIds.add(photoId);
        c.beginPhotoSwitch();

        await c.loadForWall(wallId, photoId);

        expect(stateFor().activeWallId, isNull);
        expect(stateFor().activePhotoId, isNull);

        // A route drawn on the blank-looking canvas stays in memory only.
        await commitTwoPointRoute(c);
        expect(
          await persistedRoutes(),
          isEmpty,
          reason:
              'ids/numbers are derived from the loaded set; persisting against '
              'an unknown set is exactly how duplicates and collisions happen',
        );
      },
    );

    test('a successful load clears a previous lastLoadFailure', () async {
      keepControllerAlive();
      final c = controllerFor();
      repo.failingPhotoIds.add(photoId);
      c.beginPhotoSwitch();
      await c.loadForWall(wallId, photoId);
      expect(stateFor().lastLoadFailure, isNotNull, reason: 'precondition');

      repo.failingPhotoIds.clear();
      c.beginPhotoSwitch();
      await c.loadForWall(wallId, photoId);

      expect(
        stateFor().lastLoadFailure,
        isNull,
        reason: 'the routes are known again; the canvas must stop warning',
      );
      expect(stateFor().activePhotoId, photoId);
    });

    test('beginPhotoSwitch clears a stale lastLoadFailure', () async {
      keepControllerAlive();
      final c = controllerFor();
      repo.failingPhotoIds.add(photoId);
      c.beginPhotoSwitch();
      await c.loadForWall(wallId, photoId);
      expect(stateFor().lastLoadFailure, isNotNull, reason: 'precondition');

      c.beginPhotoSwitch();

      expect(
        stateFor().lastLoadFailure,
        isNull,
        reason:
            'a new switch is a new attempt — the previous photo\'s failure '
            'must not keep warning over the new one',
      );
    });

    test(
      'a superseded failed load does not clobber the newer switch that '
      'overtook it',
      () async {
        keepControllerAlive();
        final c = controllerFor();
        repo.failingPhotoIds.add(photoId);

        c.beginPhotoSwitch();
        final stale = c.loadForWall(wallId, photoId);
        // The climber moves on to another photo while the failing read is
        // still in flight.
        final newGeneration = c.beginPhotoSwitch();
        await stale;

        expect(
          stateFor().isSwitchingPhoto,
          isTrue,
          reason:
              'the NEWER switch is still genuinely in flight — a stale failure '
              'must not mark it settled (same hazard cancelPhotoSwitch guards)',
        );
        expect(
          stateFor().lastLoadFailure,
          isNull,
          reason:
              'the stale failure belongs to a photo the climber already left',
        );
        expect(stateFor().switchGeneration, newGeneration);
      },
    );
  });

  group('UF-2 second-order: the delayed corruption of a LATER switch', () {
    test(
      'REGRESSION: a route drawn after a failed load is NOT persisted onto '
      'the next photo the climber opens',
      () async {
        keepControllerAlive();
        final c = controllerFor();

        // Photo 1's routes cannot be read. The canvas goes blank.
        //
        // The `try`/`catch` reproduces production EXACTLY: both screen-side
        // callers of loadForWall swallow into a debugPrint —
        // `_loadInitialPhotoForWall` (topo_canvas_screen.dart:580) and
        // `_switchToPhoto` (:806). Neither settles the switch. Without
        // mirroring that swallow here the test would abort at the throw and
        // never reach the assertion that matters, hiding the real harm behind
        // the symptom.
        repo.failingPhotoIds.add(photoId);
        c.beginPhotoSwitch();
        try {
          await c.loadForWall(wallId, photoId);
        } catch (_) {
          // exactly what the screen does today
        }

        // The climber, seeing an empty topo, redraws a route.
        await commitTwoPointRoute(c);
        expect(
          stateFor().routes,
          hasLength(1),
          reason: 'precondition: the redrawn route is on the canvas',
        );

        // They then open a DIFFERENT photo of the same wall, which loads fine.
        repo.failingPhotoIds.clear();
        c.beginPhotoSwitch();
        await c.loadForWall(wallId, otherPhotoId);

        expect(
          await persistedRoutes(otherPhotoId),
          isEmpty,
          reason:
              'THE headline bug. With isSwitchingPhoto stuck true, '
              'beginPhotoSwitch carries the redrawn route forward and '
              'loadForWall persists it as preserveRouteAcrossPhotoSwitch — '
              'filing a route drawn for photo 1 into photo 2 rows.',
        );
        expect(
          stateFor().routes,
          isEmpty,
          reason:
              'photo 2 genuinely has no routes; the stray must not be shown '
              'on it either',
        );
        expect(
          await persistedRoutes(photoId),
          isEmpty,
          reason: 'photo 1 was never writable — nothing should have landed',
        );
      },
    );

    test(
      'the NEXT switch after a failed load clears routes normally, exactly '
      'like any settled switch',
      () async {
        keepControllerAlive();
        final c = controllerFor();

        repo.failingPhotoIds.add(photoId);
        c.beginPhotoSwitch();
        try {
          await c.loadForWall(wallId, photoId);
        } catch (_) {
          // mirrors the screen's swallow — see the regression test above
        }
        await commitTwoPointRoute(c);
        expect(stateFor().routes, hasLength(1), reason: 'precondition');

        c.beginPhotoSwitch();

        expect(
          stateFor().routes,
          isEmpty,
          reason:
              'isSwitchingPhoto was settled by the failed load, so this switch '
              'takes the ordinary "previous photo is fully settled" branch and '
              'discards rather than carrying forward',
        );
      },
    );

    test(
      'a route genuinely pending across a switch is still preserved when the '
      'NEXT load succeeds — the failure path must not break the rescue',
      () async {
        keepControllerAlive();
        final c = controllerFor();

        // A normal, successful first load so persistence is on.
        c.beginPhotoSwitch();
        await c.loadForWall(wallId, photoId);

        // Switch away; commit DURING the switch (activeWallId is null, so this
        // route lives only in memory until loadForWall rescues it).
        c.beginPhotoSwitch();
        await commitTwoPointRoute(c);
        await c.loadForWall(wallId, otherPhotoId);

        expect(
          await persistedRoutes(otherPhotoId),
          hasLength(1),
          reason:
              'FIX #4\'s mid-switch rescue must keep working — this test fails '
              'if the load-failure fix over-eagerly settles or wipes routes',
        );
      },
    );
  });
}
