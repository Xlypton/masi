import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/topo/application/draw_controller.dart';
import 'package:masi/features/topo/data/route_repository.dart';
import 'package:masi/features/topo/domain/topo_route.dart';

/// Pins `DrawState.proposalOnlyGeometryEdits` and its supporting machinery in
/// `draw_controller.dart` -- the non-owner half of `ROUTE_EDITING_PLAN.md`
/// §3.2: editing someone else's committed route must mutate the canvas in
/// memory (so a suggester can see and refine what they're proposing) while
/// performing ZERO repository writes. That is a security-shaped property --
/// someone else's topo must not change on disk because a visitor dragged a
/// point -- so several tests below assert directly against the double's
/// write-attempt counter, not just against in-memory state.
///
/// Harness copied verbatim from
/// `draw_controller_route_geometry_test.dart` (same subsystem, written the
/// same day): a real in-memory [AppDatabase] + a real [DrawController] + a
/// counting repository double, against a seeded Area→Sector→Wall→Photo.
class _FlakyRouteRepository extends RouteRepository {
  _FlakyRouteRepository(super.db, {required super.nowMs});

  /// When non-null, every [upsertRoute] throws this instead of touching the
  /// database. Unused in this file but kept for harness parity.
  Object? writeError;

  /// Counts every [upsertRoute] attempt (successful or not) -- the
  /// zero-writes assertions below read this directly.
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

  /// Loads the wall and commits one route with [points] (and no symbols).
  /// The first route committed against a freshly-loaded, empty wall always
  /// gets id 1 / number 1.
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

  TopoRoute routeById(int id) =>
      stateFor().routes.firstWhere((r) => r.id == id);

  const p0 = Offset(0.1, 0.1);
  const p1 = Offset(0.2, 0.2);
  const p2 = Offset(0.3, 0.3);

  group('proposal-only mode: in-memory edit, zero writes', () {
    test(
      'a geometry edit + endRouteGeometryEdit mutates DrawState.routes, '
      'records exactly ONE undo entry, and performs ZERO repository writes',
      () async {
        await loadedWithRoute([p0, p1, p2]);
        final c = controllerFor();
        const routeId = 1;
        c.setProposalOnlyGeometryEdits(true);
        final baseline = repo.upsertAttempts;

        const moved = Offset(0.9, 0.9);
        c.moveRoutePoint(routeId, 0, moved);
        await c.endRouteGeometryEdit(routeId);

        expect(
          routeById(routeId).points[0],
          moved,
          reason: 'the canvas must show the edit so the suggester can see '
              'and refine what they are proposing',
        );
        expect(
          stateFor().undoStack,
          hasLength(1),
          reason: 'the gesture still records one undo entry, exactly like '
              "an owner's edit",
        );
        expect(stateFor().undoStack.single, isA<EditRouteGeometryOp>());
        expect(
          repo.upsertAttempts - baseline,
          0,
          reason: "someone else's topo must not change on disk because a "
              'visitor dragged a point',
        );
      },
    );
  });

  group('pendingProposalBaselines', () {
    test(
      "gains the route's ORIGINAL geometry, and a SECOND gesture on the "
      'same route does not overwrite that entry with the intermediate '
      'state',
      () async {
        await loadedWithRoute([p0, p1, p2]);
        final c = controllerFor();
        const routeId = 1;
        c.setProposalOnlyGeometryEdits(true);

        const firstMove = Offset(0.7, 0.7);
        const secondMove = Offset(0.8, 0.8);

        c.moveRoutePoint(routeId, 0, firstMove);
        await c.endRouteGeometryEdit(routeId);

        final baselineAfterFirst = c.pendingProposalBaselineFor(routeId);
        expect(baselineAfterFirst, isNotNull);
        expect(
          baselineAfterFirst!.points[0],
          p0,
          reason: 'the baseline is the geometry BEFORE any edit this visit '
              'made',
        );

        c.moveRoutePoint(routeId, 0, secondMove);
        await c.endRouteGeometryEdit(routeId);

        expect(
          routeById(routeId).points[0],
          secondMove,
          reason: 'the route itself keeps moving with each gesture',
        );
        final baselineAfterSecond = c.pendingProposalBaselineFor(routeId);
        expect(
          baselineAfterSecond!.points[0],
          p0,
          reason: 'the SECOND gesture must not overwrite the baseline with '
              'the first gesture\'s (intermediate) result -- it must still '
              'be the geometry from before the first edit',
        );
        expect(
          identical(baselineAfterFirst, baselineAfterSecond) ||
              baselineAfterFirst.points[0] == baselineAfterSecond.points[0],
          isTrue,
        );
      },
    );

    test('editing two different routes records a baseline for each', () async {
      final c = controllerFor();
      await c.loadForWall(wallId, photoId);

      c.setMode(DrawMode.draw);
      c.addPoint(p0);
      c.addPoint(p1);
      await c.commitRoute();
      final routeAId = stateFor().routes.single.id;

      c.addPoint(const Offset(0.5, 0.5));
      c.addPoint(const Offset(0.6, 0.6));
      await c.commitRoute();
      final routeBId = stateFor().routes.firstWhere((r) => r.id != routeAId).id;

      c.setProposalOnlyGeometryEdits(true);

      c.moveRoutePoint(routeAId, 0, const Offset(0.11, 0.11));
      await c.endRouteGeometryEdit(routeAId);
      c.moveRoutePoint(routeBId, 0, const Offset(0.51, 0.51));
      await c.endRouteGeometryEdit(routeBId);

      final baselineA = c.pendingProposalBaselineFor(routeAId);
      final baselineB = c.pendingProposalBaselineFor(routeBId);
      expect(baselineA, isNotNull);
      expect(baselineB, isNotNull);
      expect(baselineA!.points[0], p0);
      expect(baselineB!.points[0], const Offset(0.5, 0.5));
    });
  });

  group('discardPendingGeometryProposals', () {
    test(
      'restores the edited route exactly, empties the pending map, and '
      "drops the route's own EditRouteGeometryOp from the undo stack -- an "
      'unrelated AddCommittedSymbolOp on another route survives',
      () async {
        final c = controllerFor();
        await c.loadForWall(wallId, photoId);

        // Route A: will be geometry-edited under proposal-only mode.
        c.setMode(DrawMode.draw);
        c.addPoint(p0);
        c.addPoint(p1);
        await c.commitRoute();
        final routeAId = stateFor().routes.single.id;

        // Route B: unrelated. Gets a symbol placed on it BEFORE proposal-only
        // mode turns on, so its AddCommittedSymbolOp is an ordinary,
        // already-persisted op that discard must leave alone.
        c.addPoint(const Offset(0.5, 0.5));
        c.addPoint(const Offset(0.6, 0.6));
        await c.commitRoute();
        final routeBId = stateFor().routes
            .firstWhere((r) => r.id != routeAId)
            .id;
        c.selectRoute(routeBId);
        c.setActiveSymbol(SymbolType.bolt);
        await c.placeSymbol(const Offset(0.55, 0.55));
        expect(
          stateFor().undoStack.whereType<AddCommittedSymbolOp>(),
          hasLength(1),
          reason: 'precondition: the unrelated op is really on the stack',
        );

        c.setProposalOnlyGeometryEdits(true);
        c.moveRoutePoint(routeAId, 0, const Offset(0.9, 0.9));
        await c.endRouteGeometryEdit(routeAId);

        expect(
          stateFor().pendingProposalBaselines,
          contains(routeAId),
          reason: 'precondition: the edit is pending',
        );
        expect(
          stateFor().undoStack.whereType<EditRouteGeometryOp>(),
          hasLength(1),
          reason: "precondition: route A's op is on the undo stack",
        );

        c.discardPendingGeometryProposals();

        expect(
          routeById(routeAId).points[0],
          p0,
          reason: 'route A is put back exactly as the owner has it',
        );
        expect(
          stateFor().pendingProposalBaselines,
          isEmpty,
          reason: 'the pending set is forgotten once discarded',
        );
        expect(
          stateFor().undoStack.whereType<EditRouteGeometryOp>(),
          isEmpty,
          reason:
              "route A's EditRouteGeometryOp must be gone, or pressing undo "
              'afterwards could re-apply a change to a route that was just '
              'put back',
        );
        expect(
          stateFor().undoStack.whereType<AddCommittedSymbolOp>(),
          hasLength(1),
          reason: "the unrelated op on route B must survive discard -- it "
              "has nothing to do with route A's reverted proposal",
        );
      },
    );

    test(
      'an EditRouteGeometryOp already moved onto the redo stack (via undo) '
      'is also dropped by discard',
      () async {
        await loadedWithRoute([p0, p1]);
        final c = controllerFor();
        const routeId = 1;

        c.setProposalOnlyGeometryEdits(true);
        c.moveRoutePoint(routeId, 0, const Offset(0.9, 0.9));
        await c.endRouteGeometryEdit(routeId);

        expect(
          stateFor().pendingProposalBaselines,
          contains(routeId),
          reason: 'precondition',
        );

        // Move the op from undo to redo without a further edit, so it's
        // sitting in redoStack (not undoStack) when discard runs.
        await c.undo();
        expect(
          stateFor().redoStack.whereType<EditRouteGeometryOp>(),
          hasLength(1),
          reason: 'precondition: the op is now on the redo stack',
        );
        expect(
          stateFor().undoStack.whereType<EditRouteGeometryOp>(),
          isEmpty,
          reason: 'precondition: and no longer on the undo stack',
        );

        c.discardPendingGeometryProposals();

        expect(
          stateFor().redoStack.whereType<EditRouteGeometryOp>(),
          isEmpty,
          reason: 'discard must clear a reverted route\'s op out of BOTH '
              'stacks, not just the undo stack -- otherwise pressing redo '
              'could re-apply a change to a route that was just put back',
        );
      },
    );
  });

  group('setProposalOnlyGeometryEdits', () {
    test(
      'setting it to false clears pending baselines; calling it with the '
      'value it already has is a no-op that does not clear them',
      () async {
        await loadedWithRoute([p0, p1]);
        final c = controllerFor();
        const routeId = 1;

        c.setProposalOnlyGeometryEdits(true);
        c.moveRoutePoint(routeId, 0, const Offset(0.9, 0.9));
        await c.endRouteGeometryEdit(routeId);
        expect(stateFor().pendingProposalBaselines, contains(routeId));

        // Same value again: must be a no-op, baselines survive.
        c.setProposalOnlyGeometryEdits(true);
        expect(
          stateFor().pendingProposalBaselines,
          contains(routeId),
          reason: 'setting the flag to the value it already has must not '
              'clear pending baselines',
        );

        c.setProposalOnlyGeometryEdits(false);
        expect(stateFor().proposalOnlyGeometryEdits, isFalse);
        expect(
          stateFor().pendingProposalBaselines,
          isEmpty,
          reason: 'turning proposal-only mode off discards baselines for '
              'edits that were never written and now have no submit path',
        );
      },
    );
  });

  group('sanity contrast: proposal-only OFF', () {
    test(
      'with the flag FALSE, the same edit DOES write to the repository '
      '(count 1) and leaves pendingProposalBaselines empty',
      () async {
        await loadedWithRoute([p0, p1]);
        final c = controllerFor();
        const routeId = 1;
        expect(
          stateFor().proposalOnlyGeometryEdits,
          isFalse,
          reason: 'precondition: default is off',
        );
        final baseline = repo.upsertAttempts;

        c.moveRoutePoint(routeId, 0, const Offset(0.9, 0.9));
        await c.endRouteGeometryEdit(routeId);

        expect(
          repo.upsertAttempts - baseline,
          1,
          reason: 'without this contrast, the whole proposal-only suite '
              'could pass against a controller that never writes at all',
        );
        expect(stateFor().pendingProposalBaselines, isEmpty);
      },
    );
  });
}
