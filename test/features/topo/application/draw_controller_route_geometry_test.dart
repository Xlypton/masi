import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/topo/application/draw_controller.dart';
import 'package:masi/features/topo/data/route_repository.dart';
import 'package:masi/features/topo/domain/topo_route.dart';

/// Pins the "editing a COMMITTED route's geometry" feature in
/// `draw_controller.dart` (`ROUTE_EDITING_PLAN.md` §3.1/§3.3/§4.1/§4.5): the
/// five in-memory-only mutators (`moveRoutePoint`, `insertRoutePointAfter`,
/// `removeRoutePoint`, `moveRouteSymbol`, `removeRouteSymbol`) plus the single
/// commit point `endRouteGeometryEdit`, and the `activeTool`/eraser mutual
/// exclusion from §3.3.
///
/// §3.1's whole reason for existing is a performance/UX trap: a drag emits a
/// move event per FRAME (~120 for a two-second drag), and persisting or
/// recording undo on every one of those would mean ~120 database writes and
/// an undo stack whose first press only rewinds the last frame instead of the
/// whole gesture. `endRouteGeometryEdit` is the drag boundary that fixes
/// that, and the first test below ("one undo per gesture") is the test that
/// actually pins it -- everything else here is per-mutator correctness.
///
/// Mirrors `draw_controller_persist_failure_test.dart`'s harness: a real
/// in-memory [AppDatabase] + a real [DrawController] + a
/// [_FlakyRouteRepository] double that can be told to fail (and counts its
/// own write attempts) so tests can assert against what is ACTUALLY on disk,
/// not just in-memory state.
class _FlakyRouteRepository extends RouteRepository {
  _FlakyRouteRepository(super.db, {required super.nowMs});

  /// When non-null, every [upsertRoute] throws this instead of touching the
  /// database. Null (the default) delegates to the real implementation.
  Object? writeError;

  /// Counts every [upsertRoute] attempt (successful or not) -- the "the
  /// mutators persist nothing on their own" test asserts against this
  /// directly.
  int upsertAttempts = 0;

  @override
  Future<void> upsertRoute(
    String wallId,
    String photoId,
    TopoRoute route,
  ) async {
    upsertAttempts++;
    final error = writeError;
    if (error == null) return super.upsertRoute(wallId, photoId, route);
    throw error;
  }
}

/// Stands in for the browser's out-of-room signal. `classifyPhotoWriteFailure`
/// is deliberately STRING-based (see its doc), so reproducing the marker text
/// is enough to exercise the real classification path on the plain Dart VM.
/// Mirrors the identical file-private class in the sibling
/// `draw_controller_*_failure_test.dart` files.
class _QuotaExceededError {
  @override
  String toString() => 'QuotaExceededError: The quota has been exceeded.';
}

void main() {
  const wallId = 'wall-1';
  const photoId = 'photo-1';
  const now = 1000;

  late AppDatabase db;
  late _FlakyRouteRepository repo;
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
    await db
        .into(db.photos)
        .insert(
          PhotosCompanion.insert(
            id: photoId,
            createdAt: now,
            updatedAt: now,
            wallId: wallId,
            localPath: '/tmp/$photoId.jpg',
            kind: 'original',
            width: 100,
            height: 200,
          ),
        );
  }

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await seedHierarchy();
    repo = _FlakyRouteRepository(db, nowMs: () => now);
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

  DrawController controllerFor() =>
      container.read(drawControllerProvider(wallId).notifier);
  DrawState stateFor() => container.read(drawControllerProvider(wallId));

  /// Reads what is ACTUALLY on disk, bypassing the flaky double entirely.
  Future<List<TopoRoute>> persistedRoutes() =>
      RouteRepository(db, nowMs: () => now).loadRoutes(wallId, photoId);

  /// Loads the wall and commits one route with [points] (and no symbols).
  /// The first route committed against a freshly-loaded, empty wall always
  /// gets id 1 / number 1, which every test below relies on.
  Future<DrawController> loadedWithRoute(List<Offset> points) async {
    final c = controllerFor();
    await c.loadForWall(wallId, photoId);
    c.setMode(DrawMode.draw);
    for (final p in points) {
      c.addPoint(p);
    }
    await c.commitRoute();
    return c;
  }

  /// Loads the wall and commits one route with [points] and, in order,
  /// [symbols] placed on it (via the same currentSymbols path a real draw
  /// uses, so the resulting route's `symbols` order matches [symbols]
  /// exactly).
  Future<DrawController> loadedWithRouteAndSymbols(
    List<Offset> points,
    List<TopoSymbol> symbols,
  ) async {
    final c = controllerFor();
    await c.loadForWall(wallId, photoId);
    c.setMode(DrawMode.draw);
    for (final p in points) {
      c.addPoint(p);
    }
    for (final symbol in symbols) {
      c.setActiveSymbol(symbol.type);
      await c.placeSymbol(symbol.position);
    }
    await c.commitRoute();
    return c;
  }

  TopoRoute routeById(int id) =>
      stateFor().routes.firstWhere((r) => r.id == id);

  const p0 = Offset(0.1, 0.1);
  const p1 = Offset(0.2, 0.2);
  const p2 = Offset(0.3, 0.3);

  group('§3.1: one undo per gesture, not per frame', () {
    test(
      'a ~20-move drag ends with exactly ONE undo entry, and a single undo '
      'restores the point to its PRE-DRAG position, not an intermediate '
      'frame',
      () async {
        await loadedWithRoute([p0, p1, p2]);
        final c = controllerFor();
        const routeId = 1;

        expect(
          stateFor().undoStack,
          isEmpty,
          reason: 'precondition: committing filtered the draft ops away',
        );

        // Simulate a drag: ~20 per-frame calls on the same point, none of
        // them ended by endRouteGeometryEdit yet.
        var lastFrame = p0;
        for (var i = 1; i <= 20; i++) {
          lastFrame = Offset(0.1 + i * 0.01, 0.1 + i * 0.01);
          c.moveRoutePoint(routeId, 0, lastFrame);
        }
        expect(
          stateFor().undoStack,
          isEmpty,
          reason:
              'the per-frame mutator must not push an undo entry per frame -- '
              'that is exactly the trap §3.1 exists to avoid',
        );

        await c.endRouteGeometryEdit(routeId);

        expect(
          stateFor().undoStack,
          hasLength(1),
          reason: 'the WHOLE 20-frame drag collapses into ONE undo entry',
        );
        expect(
          routeById(routeId).points[0],
          lastFrame,
          reason: 'the last frame of the drag is what stuck',
        );

        await c.undo();

        expect(
          routeById(routeId).points[0],
          p0,
          reason:
              'a single undo must land back on the PRE-DRAG position, not on '
              'frame 19 or any other intermediate value -- that is the whole '
              'point of collapsing the gesture into one op',
        );
        expect(stateFor().undoStack, isEmpty);
        expect(stateFor().redoStack, hasLength(1));
      },
    );
  });

  group('the five mutators persist nothing on their own', () {
    test(
      'upsertRoute is called zero times across several mutators, and '
      'exactly once when endRouteGeometryEdit finally runs',
      () async {
        await loadedWithRouteAndSymbols(
          [p0, p1, p2],
          const [TopoSymbol(type: SymbolType.bolt, position: Offset(0.15, 0.15))],
        );
        final c = controllerFor();
        const routeId = 1;
        final baseline = repo.upsertAttempts;

        c.moveRoutePoint(routeId, 0, const Offset(0.11, 0.11));
        c.insertRoutePointAfter(routeId, 0, const Offset(0.12, 0.12));
        c.moveRouteSymbol(routeId, 0, const Offset(0.16, 0.16));
        c.moveRoutePoint(routeId, 2, const Offset(0.31, 0.31));

        expect(
          repo.upsertAttempts - baseline,
          0,
          reason:
              'not one of the five mutators may touch the repository -- only '
              'endRouteGeometryEdit is allowed to',
        );

        await c.endRouteGeometryEdit(routeId);

        expect(
          repo.upsertAttempts - baseline,
          1,
          reason:
              'the whole gesture -- point move, insert, symbol move, another '
              'point move -- persists in exactly ONE write',
        );
      },
    );
  });

  group('the 2-point floor', () {
    test(
      'removeRoutePoint on a 2-point route is a total no-op: still 2 points, '
      'no undo entry, nothing persisted',
      () async {
        await loadedWithRoute([p0, p1]);
        final c = controllerFor();
        const routeId = 1;
        final baseline = repo.upsertAttempts;

        c.removeRoutePoint(routeId, 0);
        await c.endRouteGeometryEdit(routeId);

        expect(
          routeById(routeId).points,
          [p0, p1],
          reason: 'a one-point route has no line to draw -- see the doc on '
              'removeRoutePoint',
        );
        expect(
          stateFor().undoStack,
          isEmpty,
          reason:
              'the gesture changed nothing (the floor refused it), so it must '
              'not be recorded -- same rule as any other no-op gesture',
        );
        expect(repo.upsertAttempts - baseline, 0);
      },
    );

    test(
      'removeRoutePoint on a 3-point route removes one and stops at the '
      'floor',
      () async {
        await loadedWithRoute([p0, p1, p2]);
        final c = controllerFor();
        const routeId = 1;

        c.removeRoutePoint(routeId, 1);
        expect(routeById(routeId).points, [p0, p2]);

        // A second removal on the now-2-point route must refuse.
        c.removeRoutePoint(routeId, 0);
        expect(
          routeById(routeId).points,
          [p0, p2],
          reason: 'stops exactly at the 2-point floor, does not go to 1 or 0',
        );
      },
    );
  });

  group('insertRoutePointAfter', () {
    test(
      'the new point lands immediately AFTER the given index, not appended '
      'to the end of the line',
      () async {
        await loadedWithRoute([p0, p1, p2]);
        final c = controllerFor();
        const routeId = 1;
        const inserted = Offset(0.99, 0.99);

        c.insertRoutePointAfter(routeId, 0, inserted);

        expect(
          routeById(routeId).points,
          [p0, inserted, p1, p2],
          reason:
              'a route is an ORDERED path -- appending at the end would draw '
              'a spur back across the whole line instead of bending the '
              'segment the climber actually touched',
        );
      },
    );
  });

  group('symbol mutators', () {
    const bolt = TopoSymbol(type: SymbolType.bolt, position: Offset(0.4, 0.4));
    const anchor = TopoSymbol(
      type: SymbolType.anchor,
      position: Offset(0.5, 0.5),
    );

    test(
      'moveRouteSymbol moves the right one and leaves its type alone',
      () async {
        await loadedWithRouteAndSymbols([p0, p1], [bolt, anchor]);
        final c = controllerFor();
        const routeId = 1;
        const moved = Offset(0.6, 0.6);

        c.moveRouteSymbol(routeId, 1, moved);

        final symbols = routeById(routeId).symbols;
        expect(
          symbols[0],
          bolt,
          reason: 'symbol 0 (the bolt) is untouched',
        );
        expect(symbols[1].position, moved);
        expect(
          symbols[1].type,
          SymbolType.anchor,
          reason: 'moving a marker must not change what kind of marker it is',
        );
      },
    );

    test('removeRouteSymbol removes the right one', () async {
      await loadedWithRouteAndSymbols([p0, p1], [bolt, anchor]);
      final c = controllerFor();
      const routeId = 1;

      c.removeRouteSymbol(routeId, 0);

      expect(
        routeById(routeId).symbols,
        [anchor],
        reason: 'the bolt (index 0) is gone; the anchor survives',
      );
    });

    test(
      'removing symbols has no floor -- a route can end up with zero '
      'markers',
      () async {
        await loadedWithRouteAndSymbols([p0, p1], [bolt]);
        final c = controllerFor();
        const routeId = 1;

        c.removeRouteSymbol(routeId, 0);

        expect(
          routeById(routeId).symbols,
          isEmpty,
          reason:
              'unlike removeRoutePoint there is no floor: an ordinary route '
              'can have no markers at all',
        );
      },
    );
  });

  group('undo/redo inversion', () {
    test(
      'a MIXED gesture -- insert then move the newly-inserted point, one '
      'endRouteGeometryEdit -- undoes to exactly the pre-gesture geometry '
      'and redoes to exactly the post-gesture geometry',
      () async {
        await loadedWithRoute([p0, p1]);
        final c = controllerFor();
        const routeId = 1;
        const movedInserted = Offset(0.77, 0.77);

        c.insertRoutePointAfter(routeId, 0, const Offset(0.5, 0.5));
        c.moveRoutePoint(routeId, 1, movedInserted);
        await c.endRouteGeometryEdit(routeId);

        final postGesture = routeById(routeId).points;
        expect(
          postGesture,
          [p0, movedInserted, p1],
          reason: 'precondition: the mixed gesture landed as expected',
        );

        await c.undo();
        expect(
          routeById(routeId).points,
          [p0, p1],
          reason:
              'one undo returns EXACTLY to the pre-gesture geometry -- no '
              'stray inserted point left behind',
        );

        await c.redo();
        expect(
          routeById(routeId).points,
          postGesture,
          reason: 'one redo returns EXACTLY to the post-gesture geometry',
        );
      },
    );
  });

  group('a gesture that changed nothing is not recorded', () {
    test(
      'moving a point and moving it back to its exact original position '
      'ends with no undo entry and no write',
      () async {
        await loadedWithRoute([p0, p1]);
        final c = controllerFor();
        const routeId = 1;
        final baseline = repo.upsertAttempts;

        c.moveRoutePoint(routeId, 0, const Offset(0.9, 0.9));
        c.moveRoutePoint(routeId, 0, p0);
        await c.endRouteGeometryEdit(routeId);

        expect(
          stateFor().undoStack,
          isEmpty,
          reason:
              'undo must never contain an entry that does nothing when '
              'inverted -- the climber would press it and watch nothing '
              'happen',
        );
        expect(repo.upsertAttempts - baseline, 0);
      },
    );
  });

  group('write failure rolls back and reports', () {
    test(
      'a failed endRouteGeometryEdit write reverts the geometry, drops the '
      'op from the undo stack, and records a RouteWriteException',
      () async {
        await loadedWithRoute([p0, p1]);
        final c = controllerFor();
        const routeId = 1;

        c.moveRoutePoint(routeId, 0, const Offset(0.9, 0.9));
        repo.writeError = _QuotaExceededError();
        await c.endRouteGeometryEdit(routeId);

        expect(
          routeById(routeId).points[0],
          p0,
          reason:
              'the canvas must snap back to what the database actually holds '
              '-- the moved point never reached disk',
        );
        expect(
          stateFor().undoStack.whereType<EditRouteGeometryOp>(),
          isEmpty,
          reason:
              'a refused write must not leave an undo entry describing an '
              'edit that was never actually saved',
        );
        final failure = stateFor().lastWriteFailure;
        expect(failure, isNotNull);
        expect(failure!.operation, RouteWriteOperation.editRouteGeometry);
        expect(
          failure.rolledBack,
          isTrue,
          reason: 'nothing else touched the controller during the write, so '
              'the revert was safe',
        );
      },
    );
  });

  group('§4.1/§4.5: identity is preserved', () {
    test(
      "a geometry edit changes only geometry: the route's id/number/"
      'colorIndex, and the persisted row\'s database id, are unchanged',
      () async {
        await loadedWithRoute([p0, p1]);
        final c = controllerFor();
        const routeId = 1;
        final before = routeById(routeId);

        final dbIdsBefore = await RouteRepository(
          db,
          nowMs: () => now,
        ).routeDbIdsByNumber(wallId, photoId);
        final dbIdBefore = dbIdsBefore[before.number];
        expect(
          dbIdBefore,
          isNotNull,
          reason: 'precondition: the route is really on disk',
        );

        c.moveRoutePoint(routeId, 0, const Offset(0.9, 0.9));
        await c.endRouteGeometryEdit(routeId);

        final after = routeById(routeId);
        expect(after.id, before.id);
        expect(after.number, before.number);
        expect(after.colorIndex, before.colorIndex);

        final dbIdsAfter = await RouteRepository(
          db,
          nowMs: () => now,
        ).routeDbIdsByNumber(wallId, photoId);
        expect(
          dbIdsAfter[after.number],
          dbIdBefore,
          reason:
              'RouteRepository.upsertRoute keys on (photoId, number), so an '
              'edit must UPDATE the existing row rather than replace it -- '
              'this is the property the rejected "re-open into the draft" '
              'design would have broken, and it is why an ascent logged '
              'against this route still resolves to it afterwards',
        );

        // And the edit really landed, rather than merely being counted. Every
        // other assertion here reads in-memory state or a row id; this one
        // reads the stored geometry back off disk, which is the only thing
        // that survives closing the app.
        final stored = await persistedRoutes();
        expect(stored.single.points.first, const Offset(0.9, 0.9));
        expect(stored.single.number, before.number);
      },
    );
  });

  group('§3.3: eraser mutual exclusion', () {
    test(
      'activating the eraser clears activeSymbol (not merely shadows it), '
      'and placeSymbol while it is active places nothing',
      () async {
        final c = controllerFor();

        c.setActiveSymbol(SymbolType.bolt);
        expect(stateFor().activeSymbol, SymbolType.bolt);
        expect(stateFor().activeTool, DrawTool.symbol);

        c.setEraserActive(true);
        expect(
          stateFor().activeSymbol,
          isNull,
          reason:
              'clearing (not shadowing) is the whole point: a symbol left '
              'active underneath would silently come back the moment the '
              'eraser switched off',
        );
        expect(stateFor().activeTool, DrawTool.eraser);

        final outcome = await c.placeSymbol(const Offset(0.5, 0.5));
        expect(
          outcome,
          SymbolPlacementOutcome.noActiveSymbol,
          reason:
              'placeSymbol\'s existing activeSymbol == null guard already '
              'makes placement impossible while erasing -- no second gate '
              'needed',
        );
        expect(
          stateFor().currentSymbols,
          isEmpty,
          reason: 'nothing was placed',
        );

        c.setActiveSymbol(null);
        expect(
          stateFor().activeTool,
          DrawTool.route,
          reason: 'selecting Route (or a symbol) turns the eraser back off',
        );
      },
    );
  });

  group('§3.3: a geometry edit does not clear the route selection', () {
    test(
      'the selected route stays selected across a moveRoutePoint + '
      'endRouteGeometryEdit gesture',
      () async {
        await loadedWithRoute([p0, p1]);
        final c = controllerFor();
        const routeId = 1;
        c.selectRoute(routeId);
        expect(stateFor().selectedRouteId, routeId, reason: 'precondition');

        c.moveRoutePoint(routeId, 0, const Offset(0.9, 0.9));
        await c.endRouteGeometryEdit(routeId);

        expect(
          stateFor().selectedRouteId,
          routeId,
          reason:
              'the eraser needs the route to STAY selected: markers and '
              'point handles only render for the selected route (§3.3), so a '
              'geometry edit clearing the selection would leave the eraser '
              'with nothing visible to act on next',
        );
      },
    );
  });

  group(
    'FIX #9-style: deleting a route drops its own pending geometry ops but '
    'leaves unrelated ones',
    () {
      test(
        'removeRoute filters out only the removed route\'s '
        'EditRouteGeometryOp, leaving another route\'s own op intact',
        () async {
          final c = controllerFor();
          await c.loadForWall(wallId, photoId);

          // Route A: committed, then geometry-edited (pushes an
          // EditRouteGeometryOp for A).
          c.setMode(DrawMode.draw);
          c.addPoint(p0);
          c.addPoint(p1);
          await c.commitRoute();
          final routeAId = stateFor().routes.single.id;
          c.moveRoutePoint(routeAId, 0, const Offset(0.15, 0.15));
          await c.endRouteGeometryEdit(routeAId);

          // Route B: committed, then its OWN geometry edit (pushes an
          // EditRouteGeometryOp for B) -- unrelated to A.
          c.addPoint(const Offset(0.5, 0.5));
          c.addPoint(const Offset(0.6, 0.6));
          await c.commitRoute();
          final routeBId = stateFor().routes
              .firstWhere((r) => r.id != routeAId)
              .id;
          c.moveRoutePoint(routeBId, 0, const Offset(0.55, 0.55));
          await c.endRouteGeometryEdit(routeBId);

          expect(
            stateFor().undoStack,
            hasLength(2),
            reason: "precondition: both routes' EditRouteGeometryOp are on "
                'the stack',
          );

          await c.removeRoute(routeAId);

          final undoStack = stateFor().undoStack;
          expect(
            undoStack,
            hasLength(1),
            reason:
                "route A's op is gone (it would dangle against a route that "
                'no longer exists); route B\'s survives untouched',
          );
          expect(
            (undoStack.single as EditRouteGeometryOp).routeId,
            routeBId,
          );
        },
      );
    },
  );
}
