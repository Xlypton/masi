import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/topo/application/draw_controller.dart';
import 'package:masi/features/topo/data/route_repository.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
import 'package:masi/features/topo/presentation/canvas_chrome.dart';
import 'package:masi/features/topo/presentation/route_metadata_sheet.dart';
import 'package:masi/features/topo/presentation/topo_canvas.dart';
import 'package:masi/features/topo/presentation/topo_canvas_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

/// Intended-behavior tests for the canvas's View/Draw modes, the
/// draw-toolbar's scoping to Draw mode, and the commit->metadata-sheet
/// draw-flow lifecycle.
///
/// These assertions are derived ONLY from the spec (MASI.md modes
/// A1-A3, plus BUG-1's toolbar-scoping report) — never from the current,
/// known-buggy implementation. A failing test here is a bug signal to be
/// fixed in lib/, never a reason to weaken the assertion.

/// FIX #6 (family-keyed `drawControllerProvider`): stand-in wallId for the
/// tests below that don't seed a real wall (the seeded-wall tests use
/// `seeded.wallId` instead, consistently).
const _testWallId = 'test-wall';

void main() {
  /// Creates a real in-memory DB + ProviderContainer + a persisted
  /// Area/Sector/Wall, mirroring the harness pattern used throughout
  /// test/widget_test.dart's 'TopoCanvasScreen draw-mode controls' group.
  Future<({AppDatabase db, ProviderContainer container, String wallId})>
  seedWall() async {
    final db = AppDatabase(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        nowMsProvider.overrideWithValue(() => 1000),
      ],
    );
    final crud = container.read(libraryCrudRepositoryProvider);
    final area = await crud.createArea('Area');
    final sector = await crud.createSector(area.id, 'Sector');
    final wall = await crud.createWall(sector.id, 'Wall');
    return (db: db, container: container, wallId: wall.id);
  }

  /// Inserts a placeholder Photos row (kind: 'other', NOT 'original') so a
  /// photo row "exists" for the wall in the DB without being discoverable
  /// via photoRepository.loadOriginal, then seeds
  /// drawControllerProvider.activePhotoId directly via loadForWall — exactly
  /// as a real attached-original load would, but without ever triggering
  /// the real, undriveable-under-fake-time image decode (see
  /// test/widget_test.dart's M3 NOTE and its 'TopoCanvasScreen AR entry'
  /// group, which this mirrors).
  Future<String> seedPhoto(
    AppDatabase db,
    ProviderContainer container,
    String wallId,
  ) async {
    const photoId = 'placeholder-photo';
    await db
        .into(db.photos)
        .insert(
          PhotosCompanion.insert(
            id: photoId,
            createdAt: 1000,
            updatedAt: 1000,
            wallId: wallId,
            localPath: '/tmp/placeholder.jpg',
            kind: 'other',
            width: 100,
            height: 100,
          ),
        );
    await container
        .read(drawControllerProvider(wallId).notifier)
        .loadForWall(wallId, photoId);
    return photoId;
  }

  void expectClusterAbsent() {
    expect(find.byKey(const Key('topo-undo-button')), findsNothing);
    expect(find.byKey(const Key('topo-redo-button')), findsNothing);
    expect(find.byKey(const Key('topo-clear-button')), findsNothing);
    expect(find.byKey(const Key('topo-commit-button')), findsNothing);
  }

  void expectClusterPresent() {
    expect(find.byKey(const Key('topo-undo-button')), findsOneWidget);
    expect(find.byKey(const Key('topo-redo-button')), findsOneWidget);
    expect(find.byKey(const Key('topo-clear-button')), findsOneWidget);
    expect(find.byKey(const Key('topo-commit-button')), findsOneWidget);
  }

  testWidgets(
    'A1a: fresh mount (incl. once a photo is seeded) starts in View mode '
    'with the draw-toolbar cluster absent (BUG-1a, BUG-1c)',
    (tester) async {
      final seeded = await seedWall();
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: seeded.container,
          child: MaterialApp(
            theme: MasiTheme.light,
            home: TopoCanvasScreen(wallId: seeded.wallId),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(seeded.container.read(drawControllerProvider(seeded.wallId)).mode, DrawMode.view);
      expectClusterAbsent();

      // Simulate the wall's photo finishing its load ("a seeded photo"):
      // this must never itself flip the canvas into Draw mode or reveal
      // the cluster.
      await seedPhoto(seeded.db, seeded.container, seeded.wallId);
      await tester.pump();

      expect(
        seeded.container.read(drawControllerProvider(seeded.wallId)).mode,
        DrawMode.view,
        reason:
            'loading a photo must never itself switch the canvas into '
            'draw mode',
      );
      expectClusterAbsent();
    },
  );

  testWidgets(
    'A1b: tapping topo-mode-toggle switches to Draw mode and reveals all '
    'four toolbar-cluster buttons (A1, BUG-1a)',
    (tester) async {
      final seeded = await seedWall();
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: seeded.container,
          child: MaterialApp(
            theme: MasiTheme.light,
            home: TopoCanvasScreen(wallId: seeded.wallId),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('topo-mode-toggle')));
      await tester.pump();

      expect(seeded.container.read(drawControllerProvider(seeded.wallId)).mode, DrawMode.draw);
      expectClusterPresent();
    },
  );

  testWidgets(
    'A1c: committing a >=2-point route returns to View mode, hides the '
    'cluster again, and opens RouteMetadataSheet (BUG-1b, B1)',
    (tester) async {
      final seeded = await seedWall();
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: seeded.container,
          child: MaterialApp(
            theme: MasiTheme.light,
            home: TopoCanvasScreen(wallId: seeded.wallId),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('topo-mode-toggle')));
      await tester.pump();

      final notifier = seeded.container.read(drawControllerProvider(seeded.wallId).notifier);
      notifier.addPoint(const Offset(0.1, 0.1));
      notifier.addPoint(const Offset(0.2, 0.2));
      await tester.pump();

      final routesBefore = seeded.container
          .read(drawControllerProvider(seeded.wallId))
          .routes
          .length;

      await tester.tap(find.byKey(const Key('topo-commit-button')));
      await tester.pumpAndSettle();

      final state = seeded.container.read(drawControllerProvider(seeded.wallId));
      expect(state.routes.length, routesBefore + 1);
      expect(state.currentPoints, isEmpty);
      expect(state.mode, DrawMode.view);
      expectClusterAbsent();
      expect(find.byType(RouteMetadataSheet), findsOneWidget);
    },
  );

  testWidgets(
    'A1d: after committing and dismissing the metadata sheet, re-mounting '
    'a fresh TopoCanvasScreen for the same wall starts in View mode with '
    'the cluster absent (BUG-1c)',
    (tester) async {
      final seeded = await seedWall();
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: seeded.container,
          child: MaterialApp(
            theme: MasiTheme.light,
            home: TopoCanvasScreen(wallId: seeded.wallId),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('topo-mode-toggle')));
      await tester.pump();
      final notifier = seeded.container.read(drawControllerProvider(seeded.wallId).notifier);
      notifier.addPoint(const Offset(0.1, 0.1));
      notifier.addPoint(const Offset(0.2, 0.2));
      await tester.pump();
      await tester.tap(find.byKey(const Key('topo-commit-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('topo-meta-cancel')), findsOneWidget);
      await tester.tap(find.byKey(const Key('topo-meta-cancel')));
      await tester.pumpAndSettle();

      // Unmount before re-mounting a fresh screen instance for the same
      // wall, exactly as a user closing and reopening the canvas would.
      await tester.pumpWidget(const SizedBox());
      await tester.pump();

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: seeded.container,
          child: MaterialApp(
            theme: MasiTheme.light,
            home: TopoCanvasScreen(wallId: seeded.wallId),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(seeded.container.read(drawControllerProvider(seeded.wallId)).mode, DrawMode.view);
      expectClusterAbsent();
    },
  );

  testWidgets('A1e: with >=1 route present and Draw mode active, the bottom '
      'toolbar cluster does not overlap the route legend (BUG-1d)', (
    tester,
  ) async {
    final seeded = await seedWall();
    addTearDown(seeded.db.close);
    addTearDown(seeded.container.dispose);

    // RouteLegend only ever mounts inside TopoCanvasBody, which itself
    // only mounts once TopoCanvasScreen has a non-null imagePath AND a
    // resolved _imageSize (see _TopoCanvasScreenState._buildCanvasArea) —
    // so, unlike A1a-A1d, this assertion needs a wall with an attached
    // photo. Attaching one via attachPhotoToWall (exactly as
    // topo_canvas_wall_binding_test.dart's A1 does) makes
    // loadWallOriginalPhoto find it on mount and select its path, but the
    // real FileImage decode that would normally resolve _imageSize from
    // that path can't be driven under testWidgets' fake-async clock (see
    // the project CLAUDE.md's widget-test note) — so this passes
    // TopoCanvasScreen.debugInitialImageSize to bypass that decode
    // entirely, a test-only seam that is a no-op in production (defaults
    // to null).
    final crud = seeded.container.read(libraryCrudRepositoryProvider);
    late String photoId;
    await tester.runAsync(() async {
      photoId = await crud.attachPhotoToWall(
        seeded.wallId,
        XFile('/tmp/a1e-photo.jpg'),
        1000,
        2000,
      );

      // Seed one persisted route directly against RouteRepository (as
      // topo_canvas_wall_binding_test.dart's A1 does) so "a route exists"
      // is already true the moment the screen restores this wall's photo,
      // without needing a real draw/commit round-trip through the UI.
      final routeRepo = RouteRepository(seeded.db, nowMs: () => 1000);
      await routeRepo.upsertRoute(
        seeded.wallId,
        photoId,
        const TopoRoute(
          id: 1,
          number: 1,
          points: [Offset(0.1, 0.1), Offset(0.2, 0.2)],
        ),
      );
    });

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: seeded.container,
        child: MaterialApp(
          theme: MasiTheme.light,
          home: TopoCanvasScreen(
            wallId: seeded.wallId,
            debugInitialImageSize: const Size(1000, 2000),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(seeded.container.read(drawControllerProvider(seeded.wallId)).routes, isNotEmpty);

    await tester.tap(find.byKey(const Key('topo-mode-toggle')));
    await tester.pumpAndSettle();
    expect(seeded.container.read(drawControllerProvider(seeded.wallId)).mode, DrawMode.draw);
    expectClusterPresent();

    // Fix 1/3 (legend expand/collapse) supersedes this assertion's
    // original target: entering Draw mode now collapses RouteLegend's
    // fully-expanded card down to the compact `topo-route-legend-chip`
    // pill (see route_legend.dart's `legendExpandedProvider`/
    // `LegendExpandedController.setForMode`, wired up by
    // `_TopoCanvasScreenState.build`'s `ref.listen<DrawMode>` mode-change
    // listener) — the full `topo-route-legend` ListView is deliberately
    // NOT mounted while drawing (see `TopoCanvasBody.build`'s mutually
    // exclusive overlay-card/chip branches, gated on
    // `legendExpandedProvider`), so BUG-1d's "never occluded" contract is
    // now checked against the collapsed chip instead of the full card.
    final legendFinder = find.byKey(const Key('topo-route-legend-chip'));
    expect(
      legendFinder,
      findsOneWidget,
      reason:
          'a route exists and Draw mode is active, so the collapsed '
          'legend chip (Fix 1/3) must be mounted',
    );
    expect(
      find.byKey(const Key('topo-route-legend-overlay')),
      findsNothing,
      reason: 'the expanded overlay card must not coexist with the chip',
    );

    // The bottom draw-mode cluster's actual GlassChrome container (its
    // painted rect, including its own padding — not just the bounding
    // box of the buttons inside it). `_buildTopChrome` also uses a
    // GlassChrome for the top title pill, so `.last` is the bottom
    // cluster's: the Stack in TopoCanvasScreen.build lays out the top
    // chrome's Positioned before the bottom chrome's, so it appears
    // earlier in the widget tree.
    final clusterRect = tester.getRect(find.byType(GlassChrome).last);
    final legendRect = tester.getRect(legendFinder);

    expect(
      clusterRect.overlaps(legendRect),
      isFalse,
      reason:
          'the draw-mode toolbar cluster must never occlude the '
          '(collapsed) route legend\ncluster=$clusterRect legend=$legendRect',
    );
  });

  testWidgets(
    'A1f: InteractiveViewer pan/scale are both enabled in View mode; in '
    'Draw mode pan is locked but scale STAYS enabled, so a two-finger '
    'pinch still pans/zooms while single-finger gestures draw (A2, A3)',
    (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = TransformationController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: MasiTheme.light,
            home: Scaffold(
              body: TopoCanvas(
                wallId: _testWallId,
                imagePath: '/nonexistent/test-topo.jpg',
                imageSize: const Size(400, 300),
                transformationController: controller,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      InteractiveViewer viewer() => tester.widget<InteractiveViewer>(
        find.byKey(const Key('topo-interactive-viewer')),
      );

      expect(container.read(drawControllerProvider(_testWallId)).mode, DrawMode.view);
      expect(viewer().panEnabled, isTrue);
      expect(viewer().scaleEnabled, isTrue);

      container.read(drawControllerProvider(_testWallId).notifier).setMode(DrawMode.draw);
      await tester.pump();

      expect(
        viewer().panEnabled,
        isFalse,
        reason:
            'Draw mode must lock single-finger panning so single-finger '
            'gestures are unambiguously interpreted as placing/dragging '
            'points',
      );
      expect(
        viewer().scaleEnabled,
        isTrue,
        reason:
            'Draw mode must still allow a two-finger pinch to pan/zoom — '
            'only single-finger pan is reserved for drawing, per the '
            'gesture model (two-finger pan/zoom while drawing)',
      );
    },
  );
}
