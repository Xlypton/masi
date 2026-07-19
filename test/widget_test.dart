import 'package:climbtopo/app/app.dart';
import 'package:climbtopo/app/router.dart';
import 'package:climbtopo/app/theme.dart';
import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/core/db/database_provider.dart';
import 'package:climbtopo/core/grades/grade_system.dart';
import 'package:climbtopo/features/ar/presentation/ar_screen.dart';
import 'package:climbtopo/features/library/application/library_providers.dart';
import 'package:climbtopo/features/library/data/library_crud_repository.dart';
import 'package:climbtopo/features/topo/application/active_view_controller.dart';
import 'package:climbtopo/features/topo/application/draw_controller.dart';
import 'package:climbtopo/features/topo/application/slice_controller.dart';
import 'package:climbtopo/features/topo/data/photo_repository.dart';
import 'package:climbtopo/features/topo/data/route_repository.dart';
import 'package:climbtopo/features/topo/domain/topo_route.dart';
import 'package:climbtopo/features/topo/presentation/grade_colors.dart';
import 'package:climbtopo/features/topo/presentation/photo_selector.dart';
import 'package:climbtopo/features/topo/presentation/route_legend.dart';
import 'package:climbtopo/features/topo/presentation/route_metadata_sheet.dart';
import 'package:climbtopo/features/topo/presentation/route_palette.dart';
import 'package:climbtopo/features/topo/presentation/slice_tool.dart';
import 'package:climbtopo/features/topo/presentation/symbol_palette_bar.dart';
import 'package:climbtopo/features/topo/presentation/topo_canvas.dart';
import 'package:climbtopo/features/topo/presentation/topo_canvas_screen.dart';
import 'package:climbtopo/features/topo/presentation/topo_painter.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// Advances real asynchronous work (Drift's in-memory background executor's
/// stream re-queries) that would otherwise never make progress under
/// `testWidgets`' fake-async clock, then pumps to flush the resulting
/// Riverpod-triggered rebuilds and any in-flight route transitions.
///
/// AreasScreen (the M6 library root) watches a Drift-backed StreamProvider and
/// shows a [CircularProgressIndicator] until that watch stream's first
/// emission lands. `pumpAndSettle` would spin forever on that unbounded
/// spinner animation (the stream never emits under the fake clock) and, worse,
/// leave the Drift subscription open so teardown hangs closing the DB out from
/// under it ("Cannot add event while adding stream"). Interleaving `runAsync`
/// (real clock, lets Drift emit) with a fixed-duration `pump` (fake clock,
/// advances transitions + rebuilds) settles everything deterministically. This
/// mirrors the `_drain` helper in
/// test/features/library/presentation/areas_screen_test.dart.
Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 30));
  }
  // The Drift-backed stream has now emitted (real data on screen), so no
  // unbounded spinner remains and pumpAndSettle is safe: it flushes any
  // remaining bounded route/transition motion deterministically.
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'App boots to AreasScreen (root route) showing its empty state',
    (WidgetTester tester) async {
      // The router's default `/` route is now ToposScreen (the flat
      // photo-first home) rather than AreasScreen — navigate to `/areas`
      // explicitly before exercising the library CRUD root's empty state,
      // which is what this test actually covers. TopoCanvasScreen itself is
      // still covered directly by the draw-mode-controls group below.
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 1000),
          ],
          child: const ClimbTopoApp(),
        ),
      );
      // Let GoRouter/MaterialApp.router settle AND the Drift-backed
      // areasProvider watch stream emit its first (empty) value, so the
      // AreasScreen leaves its loading spinner and renders the empty state.
      await _drain(tester);

      appRouter.go('/areas');
      await _drain(tester);

      expect(find.text('Areas'), findsOneWidget);
      expect(find.text('No areas yet — tap + to add one'), findsOneWidget);

      // Unmount the (owning) ProviderScope inside the test so Riverpod
      // disposes the StreamProvider and cancels its live Drift watch
      // subscription now, draining Drift's stream-close cleanup timer instead
      // of leaving it pending — and so the addTearDown `db.close` later closes
      // the DB with no watch still attached (which would otherwise hang).
      await tester.pumpWidget(const SizedBox());
      await _drain(tester);
    },
  );

  group('TopoCanvasScreen draw-mode controls', () {
    // These controls (the toggle and the toolbar) live in the app bar /
    // bottom bar and operate purely on drawControllerProvider state, so they
    // are pumped via the full TopoCanvasScreen without ever selecting an
    // image — no real image file is needed for A1/A3.

    testWidgets('A1: the view/draw toggle flips the draw controller mode', (
      tester,
    ) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          nowMsProvider.overrideWithValue(() => 1000),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: MasiTheme.light,
            home: const TopoCanvasScreen(wallId: 'test-wall'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(container.read(drawControllerProvider).mode, DrawMode.view);

      await tester.tap(find.byKey(const Key('topo-mode-toggle')));
      await tester.pump();
      expect(container.read(drawControllerProvider).mode, DrawMode.draw);

      await tester.tap(find.byKey(const Key('topo-mode-toggle')));
      await tester.pump();
      expect(container.read(drawControllerProvider).mode, DrawMode.view);
    });

    testWidgets(
      'A3: undo/redo/commit toolbar buttons invoke the draw controller '
      '(bottom cluster is draw-mode-only; committing returns to view mode)',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 1000),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
            theme: MasiTheme.light,
            home: const TopoCanvasScreen(wallId: 'test-wall'),
          ),
          ),
        );
        await tester.pumpAndSettle();

        // Bug fix coverage: the undo/redo/cancel/commit cluster is now
        // gated to DrawMode.draw (previously shown unconditionally, which
        // is what let it cover RouteLegend even in view mode — see
        // TopoCanvasScreen._buildBottomChrome's doc). The screen opens in
        // view mode by default, so none of the cluster's buttons exist yet.
        expect(container.read(drawControllerProvider).mode, DrawMode.view);
        expect(find.byKey(const Key('topo-undo-button')), findsNothing);
        expect(find.byKey(const Key('topo-commit-button')), findsNothing);

        await tester.tap(find.byKey(const Key('topo-mode-toggle')));
        await tester.pumpAndSettle();
        expect(container.read(drawControllerProvider).mode, DrawMode.draw);

        final notifier = container.read(drawControllerProvider.notifier);
        notifier.addPoint(const Offset(0.1, 0.1));
        notifier.addPoint(const Offset(0.2, 0.2));
        expect(container.read(drawControllerProvider).currentPoints.length, 2);

        await tester.tap(find.byKey(const Key('topo-undo-button')));
        await tester.pump();
        expect(container.read(drawControllerProvider).currentPoints.length, 1);

        await tester.tap(find.byKey(const Key('topo-redo-button')));
        await tester.pump();
        expect(container.read(drawControllerProvider).currentPoints.length, 2);

        await tester.tap(find.byKey(const Key('topo-commit-button')));
        await tester.pumpAndSettle();
        expect(container.read(drawControllerProvider).currentPoints, isEmpty);
        expect(container.read(drawControllerProvider).routes.length, 1);
        // Bug fix: committing returns the canvas to view mode (previously
        // it stayed in draw mode, leaving the cluster on screen over
        // RouteLegend even after the user was done editing).
        expect(container.read(drawControllerProvider).mode, DrawMode.view);

        // A real commit opens the route-metadata sheet for the just
        // -committed route; dismiss it (Cancel) before continuing so the
        // clear-button interaction below isn't swallowed by the sheet's
        // modal barrier.
        expect(find.byKey(const Key('topo-meta-save')), findsOneWidget);
        // The sheet grew (beta-URL/style-tags/stars sections) and now
        // overflows the default 800x600 test surface; its body is a real
        // SingleChildScrollView (see RouteMetadataSheet.build), so Cancel
        // must be scrolled into view before tapping it -- otherwise the
        // tap misses, the modal bottom sheet never closes, and every
        // subsequent tap in this test hits its (still-present) barrier
        // instead of the intended widget.
        await tester.ensureVisible(find.byKey(const Key('topo-meta-cancel')));
        await tester.tap(find.byKey(const Key('topo-meta-cancel')));
        await tester.pumpAndSettle();

        // topo-clear-button: back in view mode post-commit, the cluster
        // (including the clear button) is hidden again until draw mode is
        // re-entered.
        expect(find.byKey(const Key('topo-clear-button')), findsNothing);
        await tester.tap(find.byKey(const Key('topo-mode-toggle')));
        await tester.pumpAndSettle();

        // Start a new current route, then discard it.
        notifier.addPoint(const Offset(0.3, 0.3));
        await tester.tap(find.byKey(const Key('topo-clear-button')));
        await tester.pump();
        expect(container.read(drawControllerProvider).currentPoints, isEmpty);
      },
    );

    testWidgets(
      'M4 cleanup coverage: with a route selected, topo-edit-metadata-button '
      'appears in the app bar and tapping it opens RouteMetadataSheet',
      (tester) async {
        // The edit-metadata button lives in the app bar (see
        // TopoCanvasScreen.build's AppBar.actions), gated only on
        // drawState.selectedRouteId — independent of the image-load path —
        // so this is exercised the same way as A1/A3 above: pumping the
        // full screen without ever selecting an image.
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 1000),
          ],
        );
        addTearDown(container.dispose);

        final notifier = container.read(drawControllerProvider.notifier);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
            theme: MasiTheme.light,
            home: const TopoCanvasScreen(wallId: 'test-wall'),
          ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('topo-edit-metadata-button')), findsNothing);

        // Drawn/committed AFTER the screen has mounted (and its microtask-
        // deferred enter-wall reset — see TopoCanvasScreen.initState's doc —
        // has already run): drawControllerProvider is an app-lifetime
        // global, and TopoCanvasScreen now unconditionally resets it for
        // the wall it's mounted for (even when, as here, 'test-wall' has no
        // persisted photo) — see loadWallOriginalPhoto's doc for the M6
        // cross-wall-leak fix this closes. A route committed BEFORE mount
        // would therefore be cleared by that reset; committing here instead
        // matches how a real user actually creates a route: after opening
        // the wall's canvas, not before.
        notifier.addPoint(const Offset(0.1, 0.1));
        notifier.addPoint(const Offset(0.2, 0.2));
        notifier.commitRoute();
        final routeId = container.read(drawControllerProvider).routes.single.id;

        notifier.selectRoute(routeId);
        await tester.pump();

        expect(
          find.byKey(const Key('topo-edit-metadata-button')),
          findsOneWidget,
        );

        await tester.tap(find.byKey(const Key('topo-edit-metadata-button')));
        await tester.pumpAndSettle();

        expect(find.byType(RouteMetadataSheet), findsOneWidget);
        expect(find.byKey(const Key('topo-meta-save')), findsOneWidget);
      },
    );
  });

  group('TopoCanvas', () {
    // TopoCanvas is pumped directly (not via the full screen) with an
    // injected, fixed imageSize and an identity TransformationController so
    // the scene<->percent coordinate math is deterministic. imagePath points
    // nowhere real: Image.file's errorBuilder swallows the decode failure,
    // so no real image file is required to exercise the draw/gesture layer.
    //
    // Fix 1 (fit-to-viewport) makes TopoCanvas initialize its
    // transformationController to a centering fit-scale transform on first
    // layout, whenever the controller is still at identity — see
    // TopoCanvas._applyFitScaleOnce. To keep these pre-existing tests'
    // identity-transform-based coordinate math (tap/drag position <->
    // expected percent, which also assumes the widget's local origin
    // coincides with the test surface's global origin) valid unchanged,
    // each test below resizes the *test surface itself* (via
    // `tester.view.physicalSize`) to exactly match `imageSize` rather than
    // wrapping the widget in a smaller box (which would offset its local
    // origin away from (0, 0) if centered). With viewport == image size,
    // fitScale is exactly 1.0 and the centering translation is (0, 0), so
    // the "fit" transform IS the identity transform and
    // _applyFitScaleOnce's write is a harmless no-op — these tests'
    // behavior is unchanged.
    Widget buildCanvas({
      required ProviderContainer container,
      required TransformationController controller,
      Size imageSize = const Size(400, 300),
    }) {
      return UncontrolledProviderScope(
        container: container,
        // Fix 2 (canvas UI fixes) needs `theme: MasiTheme.light`: TopoCanvas
        // now reads `MasiColors.of(context)` (for its viewport frame's
        // hairline border) in every build, which null-check-throws without
        // a MASI-themed ancestor — a bare `MaterialApp()` (as this used to
        // pump) has no `MasiColors` extension registered.
        child: MaterialApp(
          theme: MasiTheme.light,
          home: Scaffold(
            body: TopoCanvas(
              imagePath: '/nonexistent/test-topo.jpg',
              imageSize: imageSize,
              transformationController: controller,
            ),
          ),
        ),
      );
    }

    /// Resizes the test surface to exactly [size] (logical pixels, i.e.
    /// devicePixelRatio pinned to 1.0) for the duration of the calling
    /// test, restoring the previous size on teardown.
    void setViewportSize(WidgetTester tester, Size size) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    testWidgets(
      'A2: InteractiveViewer pan is disabled (but scale stays enabled) in '
      'draw mode; both are enabled in view mode',
      (tester) async {
        setViewportSize(tester, const Size(400, 300));
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final controller = TransformationController();
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          buildCanvas(container: container, controller: controller),
        );
        await tester.pump();

        InteractiveViewer viewer() =>
            tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));

        expect(viewer().panEnabled, isTrue);
        expect(viewer().scaleEnabled, isTrue);

        container.read(drawControllerProvider.notifier).setMode(DrawMode.draw);
        await tester.pump();

        expect(
          viewer().panEnabled,
          isFalse,
          reason:
              'draw mode locks single-finger pan so it is unambiguously a '
              'tap-to-add / handle-drag gesture instead',
        );
        expect(
          viewer().scaleEnabled,
          isTrue,
          reason:
              'draw mode still allows a two-finger pinch to pan/zoom — '
              'only single-finger pan is reserved for drawing',
        );

        container.read(drawControllerProvider.notifier).setMode(DrawMode.view);
        await tester.pump();

        expect(viewer().panEnabled, isTrue);
        expect(viewer().scaleEnabled, isTrue);
      },
    );

    testWidgets(
      'A4: tapping in draw mode adds one point with a percent value in '
      '[0,1] x [0,1]',
      (tester) async {
        setViewportSize(tester, const Size(400, 300));
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final controller = TransformationController();
        addTearDown(controller.dispose);

        container.read(drawControllerProvider.notifier).setMode(DrawMode.draw);

        await tester.pumpWidget(
          buildCanvas(container: container, controller: controller),
        );
        await tester.pump();

        // Identity transform + Size(400, 300): tapping local/global (200,
        // 150) (the widget fills the unobstructed test viewport, so local
        // == global here) maps to scene (200, 150) -> percent (0.5, 0.5).
        await tester.tapAt(const Offset(200, 150));
        await tester.pump();

        final points = container.read(drawControllerProvider).currentPoints;
        expect(points.length, 1);
        expect(points.first.dx, inInclusiveRange(0.0, 1.0));
        expect(points.first.dy, inInclusiveRange(0.0, 1.0));
        expect(points.first.dx, closeTo(0.5, 0.01));
        expect(points.first.dy, closeTo(0.5, 0.01));
      },
    );

    testWidgets(
      'A4 corner-tap regression: a draw-mode tap in the extreme CORNER of '
      'the viewport still places a point (full-bleed canvas rework: the '
      'viewport is no longer clipped/rounded at all, so this is a cheap '
      'guard against ever reintroducing a corner-clipping gesture bug)',
      (tester) async {
        // Same identity-transform harness as the tap-adds-a-point test
        // above: viewport == imageSize == Size(400, 300), so tapping
        // local/global (x, y) maps to scene (x, y) directly.
        setViewportSize(tester, const Size(400, 300));
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final controller = TransformationController();
        addTearDown(controller.dispose);

        container.read(drawControllerProvider.notifier).setMode(DrawMode.draw);

        await tester.pumpWidget(
          buildCanvas(container: container, controller: controller),
        );
        await tester.pump();

        // (2, 2) sits in the extreme top-left corner of the viewport's
        // bounding rect. Historical note: this used to sit OUTSIDE a
        // MasiRadii.large-rounded corner arc that a ClipRRect clipped hit-
        // testing to (not just painting), so a tap there silently placed no
        // point — the original regression this test guarded against. The
        // full-bleed canvas rework removed that rounding/clip entirely, so
        // this now simply guards against a future edit reintroducing any
        // clip that would swallow corner taps again.
        await tester.tapAt(const Offset(2, 2));
        await tester.pump();

        final points = container.read(drawControllerProvider).currentPoints;
        expect(
          points.length,
          1,
          reason:
              'a tap in the extreme corner must still reach the gesture '
              'layer and place a point — nothing should clip hit-testing '
              'there',
        );
      },
    );

    testWidgets(
      'dragging an existing handle moves it instead of adding a new point',
      (tester) async {
        setViewportSize(tester, const Size(400, 300));
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final controller = TransformationController();
        addTearDown(controller.dispose);

        final notifier = container.read(drawControllerProvider.notifier);
        notifier.setMode(DrawMode.draw);
        // Percent (0.5, 0.5) of a 400x300 image is scene/local (200, 150).
        notifier.addPoint(const Offset(0.5, 0.5));

        await tester.pumpWidget(
          buildCanvas(container: container, controller: controller),
        );
        await tester.pump();

        await tester.dragFrom(const Offset(200, 150), const Offset(40, 0));
        await tester.pump();

        final points = container.read(drawControllerProvider).currentPoints;
        expect(points.length, 1);
        expect(points.first.dx, closeTo(0.6, 0.01));
        expect(points.first.dy, closeTo(0.5, 0.01));
      },
    );

    testWidgets(
      'gesture model: a single-finger drag STARTING ON EMPTY SPACE in draw '
      'mode (moved past the tap slop before release) adds NO point — only '
      'a genuine tap (or a drag starting ON a handle) does',
      (tester) async {
        setViewportSize(tester, const Size(400, 300));
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final controller = TransformationController();
        addTearDown(controller.dispose);

        container.read(drawControllerProvider.notifier).setMode(DrawMode.draw);

        await tester.pumpWidget(
          buildCanvas(container: container, controller: controller),
        );
        await tester.pump();

        // (200, 150) is empty space (no existing points yet), and the drag
        // moves well past `_tapMovementSlopPx` (8.0) before release.
        await tester.dragFrom(const Offset(200, 150), const Offset(40, 0));
        await tester.pump();

        expect(
          container.read(drawControllerProvider).currentPoints,
          isEmpty,
          reason:
              'a drag that starts on empty space and moves past the tap '
              'slop must add nothing — panEnabled is false in draw mode, '
              'so this must not fall back to panning either; it is simply '
              'a no-op',
        );
      },
    );

    testWidgets(
      'gesture model: a TWO-finger gesture in draw mode pans/zooms via '
      'InteractiveViewer and adds NO point',
      (tester) async {
        setViewportSize(tester, const Size(400, 300));
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final controller = TransformationController();
        addTearDown(controller.dispose);

        container.read(drawControllerProvider.notifier).setMode(DrawMode.draw);

        await tester.pumpWidget(
          buildCanvas(container: container, controller: controller),
        );
        await tester.pump();

        final matrixBefore = controller.value.clone();

        // Two pointers going down and moving together (a pinch/pan), as in
        // the "Fix 1: draw mode ignores a second finger" test above but
        // with BOTH fingers moving rather than just the first placing a
        // symbol — mirroring how InteractiveViewer's own ScaleGestureRecognizer
        // is driven in its own tests.
        final gestureA = await tester.startGesture(
          const Offset(150, 100),
          pointer: 1,
        );
        await tester.pump();
        final gestureB = await tester.startGesture(
          const Offset(250, 200),
          pointer: 2,
        );
        await tester.pump();

        // Move both pointers apart (a pinch-out/zoom-in gesture).
        await gestureA.moveTo(const Offset(120, 70));
        await gestureB.moveTo(const Offset(280, 230));
        await tester.pump();

        await gestureA.up();
        await gestureB.up();
        await tester.pump();

        expect(
          container.read(drawControllerProvider).currentPoints,
          isEmpty,
          reason:
              'a two-finger gesture must never add a point — the raw '
              'Listener aborts the (nonexistent, here) pending tap the '
              'moment the second finger goes down, and single-finger tap-'
              'to-add never gets a chance to fire for either pointer',
        );
        expect(
          controller.value,
          isNot(equals(matrixBefore)),
          reason:
              'scaleEnabled is true in draw mode (only panEnabled is '
              "locked), so InteractiveViewer's own recognizer must still "
              'apply the two-finger pinch/pan to the transformation '
              'controller',
        );
      },
    );

    testWidgets(
      'Fix 1 (canvas look rework: default framing is CONTAIN, not COVER): '
      'a large photo fits ENTIRELY inside the viewport (minScale allows '
      'zooming out to fitScale, and the controller is initialized to '
      'fitScale itself so the whole image is visible on first layout)',
      (tester) async {
        // A real 4000x3000 photo in a narrow ~400x800 phone viewport: the
        // image is far larger than the viewport on both axes, so fitScale
        // (CONTAIN — now used for BOTH minScale and the initial/reframe
        // transform, per the canvas look rework's "whole wall visible on
        // open" default) is governed by the tighter-constraining axis
        // (width here: 400/4000 = 0.1 < 800/3000 = 0.2667).
        const imageSize = Size(4000, 3000);
        const viewportSize = Size(400, 800);
        const fitScale = 0.1; // min(400/4000, 800/3000)
        const epsilon = 0.001;

        setViewportSize(tester, viewportSize);
        final container = ProviderContainer();
        addTearDown(container.dispose);
        // Deliberately NOT pre-seeded/non-identity: this is the "real app"
        // path (TopoCanvasScreen hands TopoCanvas a fresh, identity
        // TransformationController), so the fit-init in
        // TopoCanvas._applyFitScaleOnce must fire.
        final controller = TransformationController();
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          buildCanvas(
            container: container,
            controller: controller,
            imageSize: imageSize,
          ),
        );
        await tester.pump();

        final viewer = tester.widget<InteractiveViewer>(
          find.byType(InteractiveViewer),
        );
        expect(
          viewer.minScale,
          lessThanOrEqualTo(fitScale + epsilon),
          reason:
              'minScale must allow zooming out far enough to see the '
              'entire wall photo',
        );

        expect(
          controller.value.getMaxScaleOnAxis(),
          closeTo(fitScale, epsilon),
          reason:
              'canvas look rework: the controller is now initialized to '
              'fitScale (CONTAIN) on first layout, so the WHOLE photo is '
              'visible on open rather than pre-cropped to fill the '
              'viewport (the old COVER/fillScale behavior)',
        );
      },
    );

    testWidgets(
      'A2: in view mode, a tap on a rendered route selects it; a tap far '
      'away clears the selection',
      (tester) async {
        setViewportSize(tester, const Size(400, 300));
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final controller = TransformationController();
        addTearDown(controller.dispose);

        // A vertical route straight down the middle of the image
        // (percent x=0.5): scene x=200 at any y between scene 30 and 270.
        final notifier = container.read(drawControllerProvider.notifier);
        notifier.addPoint(const Offset(0.5, 0.1));
        notifier.addPoint(const Offset(0.5, 0.9));
        notifier.commitRoute();
        final routeId = container.read(drawControllerProvider).routes.single.id;

        await tester.pumpWidget(
          buildCanvas(container: container, controller: controller),
        );
        await tester.pump();

        expect(container.read(drawControllerProvider).mode, DrawMode.view);
        expect(container.read(drawControllerProvider).selectedRouteId, isNull);

        // Scene (200, 150) -> percent (0.5, 0.5): exactly on the route.
        await tester.tapAt(const Offset(200, 150));
        await tester.pump();

        expect(container.read(drawControllerProvider).selectedRouteId, routeId);

        // Scene (390, 10) -> percent (0.975, 0.033): far from the route.
        await tester.tapAt(const Offset(390, 10));
        await tester.pump();

        expect(container.read(drawControllerProvider).selectedRouteId, isNull);
      },
    );

    testWidgets(
      'A4: multiple committed routes are all handed to the painter, along '
      'with the selected route id',
      (tester) async {
        setViewportSize(tester, const Size(400, 300));
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final controller = TransformationController();
        addTearDown(controller.dispose);

        final notifier = container.read(drawControllerProvider.notifier);
        notifier.addPoint(const Offset(0.1, 0.1));
        notifier.addPoint(const Offset(0.2, 0.2));
        notifier.commitRoute();
        notifier.addPoint(const Offset(0.3, 0.3));
        notifier.addPoint(const Offset(0.4, 0.4));
        notifier.commitRoute();
        final routes = container.read(drawControllerProvider).routes;
        expect(routes, hasLength(2));
        notifier.selectRoute(routes.first.id);

        await tester.pumpWidget(
          buildCanvas(container: container, controller: controller),
        );
        await tester.pump();

        final customPaint = tester.widget<CustomPaint>(
          find.byWidgetPredicate(
            (widget) => widget is CustomPaint && widget.painter is TopoPainter,
          ),
        );
        final painter = customPaint.painter as TopoPainter;

        expect(painter.routes.length, routes.length);
        expect(painter.selectedRouteId, routes.first.id);
      },
    );

    testWidgets(
      'Fix 1: draw mode ignores a second finger touching down before the '
      'first lifts (no extra symbol placed)',
      (tester) async {
        setViewportSize(tester, const Size(400, 300));
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final controller = TransformationController();
        addTearDown(controller.dispose);

        final notifier = container.read(drawControllerProvider.notifier);
        notifier.addPoint(const Offset(0.1, 0.1));
        notifier.addPoint(const Offset(0.9, 0.9));
        notifier.commitRoute();
        final routeId = container.read(drawControllerProvider).routes.single.id;
        notifier.selectRoute(routeId);
        notifier.setMode(DrawMode.draw);
        notifier.setActiveSymbol(SymbolType.anchor);

        await tester.pumpWidget(
          buildCanvas(container: container, controller: controller),
        );
        await tester.pump();

        // Pointer A goes down first and places a symbol (scene (200, 150)
        // -> percent (0.5, 0.5)).
        final gestureA = await tester.startGesture(
          const Offset(200, 150),
          pointer: 1,
        );
        await tester.pump();

        // Pointer B (e.g. the second contact of a pinch) goes down at a
        // different spot BEFORE A lifts: without the Fix 1 guard this would
        // re-latch `_activePointer` and place a second symbol.
        final gestureB = await tester.startGesture(
          const Offset(300, 100),
          pointer: 2,
        );
        await tester.pump();

        final route = container.read(drawControllerProvider).routes.single;
        expect(
          route.symbols,
          hasLength(1),
          reason:
              'the second finger down must be ignored while the first '
              'is still active',
        );

        await gestureA.up();
        await gestureB.up();
        await tester.pump();

        expect(
          container.read(drawControllerProvider).routes.single.symbols,
          hasLength(1),
        );
      },
    );

    testWidgets(
      'M4 cleanup Fix 1: the CANVAS itself (not just the legend) colors a '
      'graded route by its grade band, via TopoPainter.routeColorResolver',
      (tester) async {
        setViewportSize(tester, const Size(400, 300));
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final controller = TransformationController();
        addTearDown(controller.dispose);

        final notifier = container.read(drawControllerProvider.notifier);
        notifier.addPoint(const Offset(0.1, 0.1));
        notifier.addPoint(const Offset(0.2, 0.2));
        notifier.commitRoute();
        final routeId = container.read(drawControllerProvider).routes.single.id;
        // French '7a' -> shared-scale sort key 13.0 -> GradeBand.hard -> red.
        await notifier.setRouteMetadata(
          routeId,
          gradeSystem: GradeSystem.french,
          gradeRaw: '7a',
        );
        final gradedRoute = container.read(drawControllerProvider).routes.single;

        await tester.pumpWidget(
          buildCanvas(container: container, controller: controller),
        );
        await tester.pump();

        final customPaint = tester.widget<CustomPaint>(
          find.byWidgetPredicate(
            (widget) => widget is CustomPaint && widget.painter is TopoPainter,
          ),
        );
        final painter = customPaint.painter as TopoPainter;

        expect(
          painter.routeColorResolver,
          isNotNull,
          reason:
              'topo_canvas.dart must pass routeColorResolver into '
              'TopoPainter so the canvas (not just the legend) uses '
              'grade-band coloring',
        );
        expect(
          painter.routeColorResolver!(gradedRoute).toARGB32(),
          colorForGradeBand(GradeBand.hard).toARGB32(),
        );
      },
    );

    testWidgets(
      'Fix 1: view mode ignores a second finger touching down before the '
      "first lifts (selection reflects only the first finger's tap)",
      (tester) async {
        setViewportSize(tester, const Size(400, 300));
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final controller = TransformationController();
        addTearDown(controller.dispose);

        // A vertical route straight down the middle of the image, as in the
        // A2 view-mode selection test above.
        final notifier = container.read(drawControllerProvider.notifier);
        notifier.addPoint(const Offset(0.5, 0.1));
        notifier.addPoint(const Offset(0.5, 0.9));
        notifier.commitRoute();
        final routeId = container.read(drawControllerProvider).routes.single.id;

        await tester.pumpWidget(
          buildCanvas(container: container, controller: controller),
        );
        await tester.pump();

        expect(container.read(drawControllerProvider).mode, DrawMode.view);

        // Pointer A goes down on the route (scene (200, 150) -> percent
        // (0.5, 0.5)).
        final gestureA = await tester.startGesture(
          const Offset(200, 150),
          pointer: 1,
        );
        await tester.pump();

        // Pointer B goes down far from the route BEFORE A lifts: without
        // the Fix 1 guard this re-latches `_viewTapPointer` onto B, so A's
        // eventual lift-in-place would be silently dropped (never
        // registering the tap) and B's lift-in-place would instead be read
        // as a tap that misses the route, clearing the selection.
        final gestureB = await tester.startGesture(
          const Offset(390, 10),
          pointer: 2,
        );
        await tester.pump();

        // Lift A first, in place (a tap, no movement): this must register
        // as the real tap and select the route.
        await gestureA.up();
        await tester.pump();

        expect(
          container.read(drawControllerProvider).selectedRouteId,
          routeId,
          reason:
              "the first finger's tap must select the route even "
              'though a second finger was briefly down',
        );

        // Lift B second, also in place: since B was ignored on the way
        // down, this up must be a no-op rather than being read as a second
        // tap that clears the selection.
        await gestureB.up();
        await tester.pump();

        expect(
          container.read(drawControllerProvider).selectedRouteId,
          routeId,
          reason: "the second finger's lift must not flip the selection",
        );
      },
    );
  });

  // NOTE (M3): The old "picking a second, different photo resets draw state"
  // widget test was removed here. In M3 the screen resets/loads draw state by
  // resolving a newly-selected image's on-disk size (a real, non-mocked
  // ImageStreamListener) and then calling ensureDefaultForImage + loadForWall
  // from that success callback. That whole chain is genuinely asynchronous on
  // the real event loop (FileImage decode + in-memory drift reads) and cannot
  // be driven under testWidgets' fake-async clock: the decode/DB work never
  // completes between pumps, the `_imageSize == null` CircularProgressIndicator
  // is an unbounded animation that never settles, and any real async that does
  // resolve does so after the test body, crashing teardown ("Cannot add event
  // while adding stream"). The reset/load/persist SEMANTICS are instead
  // asserted deterministically at the controller level in
  // test/features/topo/application/draw_controller_persistence_test.dart
  // (A1/A2/A6/A8 — plain `test()`s, where real async awaits work). The screen
  // itself is still pumped (without an image) by the passing A1/A3 draw-mode
  // control tests above, which confirm the DB-overridden providers wire up.

  // NOTE (canvas look rework, Subtask A): the "TopoCanvasBody: symbol bar
  // mode visibility (Fix 2)" group that used to live here tested
  // `SymbolPaletteBar` as an ALWAYS-MOUNTED, `Visibility(maintainSize:
  // true)`-wrapped, in-flow child of `TopoCanvasBody`'s own Column — that
  // reserved-slot approach is gone. `SymbolPaletteBar` no longer lives in
  // `TopoCanvasBody`/`TopoCanvasScreen`'s in-flow layout at all: it now
  // floats as a Stack overlay in `TopoCanvasScreen`'s own `build` (on
  // `GlassChrome`, directly below the title pill), shown only in draw mode,
  // with NO reserved slot — see `TopoCanvasScreen.build`'s
  // `showSymbolPalette` and `symbol_palette_bar.dart`'s class doc. Removed
  // rather than kept passing-but-meaningless (it asserted a `Visibility`
  // ancestor around `SymbolPaletteBar` inside `TopoCanvasBody` that no
  // longer exists). The NEW floating/mode-gating/no-collision behavior is
  // covered by `test/features/topo/presentation/canvas_viewport_intent_test
  // .dart`'s "A-f" group, and the reclaimed canvas-region height (no more
  // permanently-reserved band) by that same file's "A-f: canvas region is
  // taller in view mode" test.

  group('TopoCanvasBody: slice mode overlay (M5)', () {
    // Mirrors the "symbol bar mode visibility" harness above: TopoCanvasBody
    // is pumped directly with an injected fixed imageSize and the sliceMode
    // flag driven explicitly (rather than through TopoCanvasScreen's own
    // _sliceMode state, which is gated behind a real async image decode —
    // see the big NOTE (M3) comment above), so this covers SliceTool's
    // actual mount/unmount + tap-to-add-cut behavior without needing a real,
    // decodable image file on disk.
    Widget buildBody({
      required ProviderContainer container,
      required TransformationController controller,
      required bool sliceMode,
      Size imageSize = const Size(400, 300),
    }) {
      return UncontrolledProviderScope(
        container: container,
        // Fix 2 (canvas UI fixes) needs `theme: MasiTheme.light`: this
        // renders a real `TopoCanvas` (via `TopoCanvasBody`), which now
        // reads `MasiColors.of(context)` for its viewport frame's hairline
        // border in every build — see the top-level 'TopoCanvas' group's
        // buildCanvas for the full rationale.
        child: MaterialApp(
          theme: MasiTheme.light,
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) {
                final drawState = ref.watch(drawControllerProvider);
                return TopoCanvasBody(
                  imagePath: '/nonexistent/test-topo.jpg',
                  imageSize: imageSize,
                  drawState: drawState,
                  transformationController: controller,
                  sliceMode: sliceMode,
                );
              },
            ),
          ),
        ),
      );
    }

    void setViewportSize(WidgetTester tester, Size size) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    testWidgets(
      'A2: slice mode shows the SliceTool overlay (absent in normal mode); '
      'adding 2 cuts renders 2 keyed cut markers',
      (tester) async {
        setViewportSize(tester, const Size(400, 356));
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final controller = TransformationController();
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          buildBody(
            container: container,
            controller: controller,
            sliceMode: false,
          ),
        );
        await tester.pump();

        expect(find.byType(SliceTool), findsNothing);

        await tester.pumpWidget(
          buildBody(
            container: container,
            controller: controller,
            sliceMode: true,
          ),
        );
        await tester.pump();

        expect(find.byType(SliceTool), findsOneWidget);
        expect(find.byKey(const Key('slice-cut-0')), findsNothing);

        container.read(sliceControllerProvider.notifier)
          ..addCut(0.3)
          ..addCut(0.6);
        await tester.pump();

        expect(find.byKey(const Key('slice-cut-0')), findsOneWidget);
        expect(find.byKey(const Key('slice-cut-1')), findsOneWidget);
        expect(find.byKey(const Key('slice-cut-2')), findsNothing);
      },
    );

    testWidgets(
      'tapping the overlay adds a cut at the tapped fraction; tapping near '
      'an existing cut removes it instead',
      (tester) async {
        setViewportSize(tester, const Size(400, 356));
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final controller = TransformationController();
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          buildBody(
            container: container,
            controller: controller,
            sliceMode: true,
          ),
        );
        await tester.pump();

        // Column children (the top clearance spacer, the invisible-but-
        // still-SIZED symbol bar slot — Fix 3 of the canvas UI fixes
        // reserves both unconditionally now, see TopoCanvasBody.build's
        // doc — the Expanded canvas area, RouteLegend) all stretch to the
        // Column's full WIDTH regardless of their individual heights, so
        // the Expanded canvas area — and the SliceTool stacked inside it —
        // spans the full 400px viewport width. SliceTool's cut fraction is
        // `dx / viewportWidth` (purely horizontal), so it's unaffected by
        // the Expanded region's now-shifted-down vertical origin: a tap at
        // GLOBAL (200, 150) still lands at fraction 200/400 = 0.5, whatever
        // its (irrelevant here) local y ends up being.
        await tester.tapAt(const Offset(200, 150));
        await tester.pump();

        expect(container.read(sliceControllerProvider), [closeTo(0.5, 0.01)]);

        // Tapping again at the same spot is within the hit radius of the
        // existing cut, so it removes it instead of adding a second one.
        await tester.tapAt(const Offset(200, 150));
        await tester.pump();

        expect(container.read(sliceControllerProvider), isEmpty);
      },
    );
  });

  group(
    'TopoCanvasBody: stable canvas viewport across bar toggles (Fix 3 of '
    'the canvas UI fixes)',
    () {
      // Bug fix ("not always centered" / "the photo jumps"): PhotoSelector's
      // and SymbolPaletteBar's slots used to be conditionally INCLUDED in
      // this Column (`if (showSymbolBar) SymbolPaletteBar()`), so the
      // Expanded canvas region below them resized every time `showSymbolBar`
      // flipped — most commonly on every single draw<->view mode toggle
      // (which `_handleCommitRoute` itself triggers after every committed
      // route). A resized Expanded region gives TopoCanvas a different
      // LayoutBuilder viewport, which makes `_reframeIfNeeded` recompute a
      // fresh fit and visibly re-center/rescale the photo. TopoCanvasBody
      // now reserves those slots' sizes UNCONDITIONALLY (via
      // `Visibility(maintainSize: true, ...)`), toggling only their
      // visibility — so the Expanded region, and therefore TopoCanvas's fit,
      // must stay pixel-identical across the toggle. See
      // TopoCanvasBody.build's doc for the full rationale (and the accepted
      // trade-off: a no-slices wall in view mode no longer extends fully
      // edge-to-edge behind the top pill).
      void setViewportSize(WidgetTester tester, Size size) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
      }

      Widget buildBody({
        required ProviderContainer container,
        required TransformationController controller,
        Size imageSize = const Size(1600, 1200),
        String? originalPhotoId,
        List<PhotoRef> slices = const [],
      }) {
        return UncontrolledProviderScope(
          container: container,
          // Needs `theme: MasiTheme.light`: this renders a real TopoCanvas
          // (via TopoCanvasBody), which reads MasiColors.of(context) (e.g.
          // the Scaffold's own `ground` fill showing through any letterbox
          // margins) on every build.
          child: MaterialApp(
            theme: MasiTheme.light,
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) {
                  final drawState = ref.watch(drawControllerProvider);
                  return TopoCanvasBody(
                    imagePath: '/nonexistent/test-topo.jpg',
                    imageSize: imageSize,
                    drawState: drawState,
                    transformationController: controller,
                    originalPhotoId: originalPhotoId,
                    slices: slices,
                  );
                },
              ),
            ),
          ),
        );
      }

      testWidgets(
        'toggling draw/view mode does not resize the canvas viewport frame '
        '(a wall with no slices — only the symbol bar toggles)',
        (tester) async {
          setViewportSize(tester, const Size(400, 800));
          final container = ProviderContainer();
          addTearDown(container.dispose);
          final controller = TransformationController();
          addTearDown(controller.dispose);
          final notifier = container.read(drawControllerProvider.notifier);

          await tester.pumpWidget(
            buildBody(container: container, controller: controller),
          );
          await tester.pump();

          final frameFinder = find.byKey(
            const Key('topo-interactive-viewer'),
          );
          final sizeBefore = tester.getSize(frameFinder);

          notifier.setMode(DrawMode.draw);
          await tester.pump();

          expect(
            tester.getSize(frameFinder),
            sizeBefore,
            reason:
                'entering draw mode (which shows the symbol bar) must not '
                'change the canvas viewport size — its slot is always '
                'reserved now, only its visibility toggles',
          );

          notifier.setMode(DrawMode.view);
          await tester.pump();

          expect(tester.getSize(frameFinder), sizeBefore);
        },
      );

      testWidgets(
        "the image's fit transform (scale + translation) is byte-identical "
        'across a draw/view toggle, proving the photo does not visibly '
        'jump or re-center',
        (tester) async {
          setViewportSize(tester, const Size(400, 800));
          final container = ProviderContainer();
          addTearDown(container.dispose);
          final controller = TransformationController();
          addTearDown(controller.dispose);
          final notifier = container.read(drawControllerProvider.notifier);

          await tester.pumpWidget(
            buildBody(container: container, controller: controller),
          );
          await tester.pump();

          final matrixBefore = controller.value.clone();

          notifier.setMode(DrawMode.draw);
          await tester.pump();
          expect(controller.value, matrixBefore);

          notifier.setMode(DrawMode.view);
          await tester.pump();
          expect(controller.value, matrixBefore);
        },
      );

      testWidgets(
        'a wall WITH slices (PhotoSelector always eligible to show) also '
        'keeps the canvas viewport stable across draw/view toggles',
        (tester) async {
          setViewportSize(tester, const Size(400, 800));
          final container = ProviderContainer();
          addTearDown(container.dispose);
          final controller = TransformationController();
          addTearDown(controller.dispose);
          final notifier = container.read(drawControllerProvider.notifier);

          const slice = PhotoRef(
            id: 'slice-1',
            wallId: 'wall-1',
            kind: 'slice',
            localPath: '/tmp/original.jpg',
            width: 1000,
            height: 2000,
            parentPhotoId: 'orig-1',
            cropXpct: 0.25,
            cropWidthPct: 0.5,
          );

          await tester.pumpWidget(
            buildBody(
              container: container,
              controller: controller,
              originalPhotoId: 'orig-1',
              slices: const [slice],
            ),
          );
          await tester.pump();

          final frameFinder = find.byKey(
            const Key('topo-interactive-viewer'),
          );
          final sizeBefore = tester.getSize(frameFinder);

          notifier.setMode(DrawMode.draw);
          await tester.pump();
          expect(tester.getSize(frameFinder), sizeBefore);

          notifier.setMode(DrawMode.view);
          await tester.pump();
          expect(tester.getSize(frameFinder), sizeBefore);
        },
      );
    },
  );

  group('TopoCanvasScreen slice-mode controls', () {
    // These operate purely on sliceControllerProvider + the screen's local
    // _sliceMode UI state via the app bar, so — like the draw-mode toggle
    // and toolbar tests above — they're pumped via the full TopoCanvasScreen
    // without ever selecting an image: the app bar renders regardless of
    // imagePath/imageSize (see TopoCanvasScreen.build's AppBar.actions).
    //
    // Bug 8 fix (canvas look rework): `topo-slice-mode-button` is now gated
    // on `drawState.activePhotoId != null` (previously it showed regardless
    // — the slice tool over an empty canvas). Each test below seeds
    // `activePhotoId` directly via `drawControllerProvider.notifier
    // .loadForWall(...)` (a plain SELECT against an unknown wallId is safe —
    // see `loadForWall`'s doc, and the same seam the "AR entry"/"slice mode
    // forces Original view" groups elsewhere in this file already use) so
    // the button exists to tap, without ever touching `selectedImageProvider`
    // or triggering the real, undriveable-under-fake-time image decode this
    // file's M3 NOTE describes.
    Future<void> seedActivePhoto(ProviderContainer container) =>
        container
            .read(drawControllerProvider.notifier)
            .loadForWall('test-wall', 'test-original-photo');

    testWidgets(
      'the slice-mode toggle shows/hides the Commit and Clear actions',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 1000),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
            theme: MasiTheme.light,
            home: const TopoCanvasScreen(wallId: 'test-wall'),
          ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('topo-slice-commit')), findsNothing);
        expect(find.byKey(const Key('topo-slice-clear')), findsNothing);

        await seedActivePhoto(container);
        await tester.pump();

        await tester.tap(find.byKey(const Key('topo-slice-mode-button')));
        await tester.pump();

        expect(find.byKey(const Key('topo-slice-commit')), findsOneWidget);
        expect(find.byKey(const Key('topo-slice-clear')), findsOneWidget);

        await tester.tap(find.byKey(const Key('topo-slice-mode-button')));
        await tester.pump();

        expect(find.byKey(const Key('topo-slice-commit')), findsNothing);
        expect(find.byKey(const Key('topo-slice-clear')), findsNothing);
      },
    );

    testWidgets(
      'the Clear action empties the pending cut list',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 1000),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
            theme: MasiTheme.light,
            home: const TopoCanvasScreen(wallId: 'test-wall'),
          ),
          ),
        );
        await tester.pumpAndSettle();

        await seedActivePhoto(container);
        await tester.pump();

        await tester.tap(find.byKey(const Key('topo-slice-mode-button')));
        await tester.pump();

        container.read(sliceControllerProvider.notifier).addCut(0.5);
        expect(container.read(sliceControllerProvider), isNotEmpty);

        await tester.tap(find.byKey(const Key('topo-slice-clear')));
        await tester.pump();

        expect(container.read(sliceControllerProvider), isEmpty);
      },
    );

    testWidgets(
      'A4: committing with no pending cuts is a no-op — a hint is shown and '
      'slice mode stays active',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 1000),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
            theme: MasiTheme.light,
            home: const TopoCanvasScreen(wallId: 'test-wall'),
          ),
          ),
        );
        await tester.pumpAndSettle();

        await seedActivePhoto(container);
        await tester.pump();

        await tester.tap(find.byKey(const Key('topo-slice-mode-button')));
        await tester.pump();

        await tester.tap(find.byKey(const Key('topo-slice-commit')));
        await tester.pump();

        expect(
          find.text('Add at least one cut before committing.'),
          findsOneWidget,
        );
        // Still in slice mode: Commit/Clear remain visible.
        expect(find.byKey(const Key('topo-slice-commit')), findsOneWidget);
      },
    );
  });

  group('TopoCanvasScreen AR entry (v2-ar-viewer)', () {
    // topo-ar-button is gated purely on drawControllerProvider state
    // (activePhotoId != null && routes.isNotEmpty) — never on
    // selectedImageProvider/imagePath — so, like the draw-mode-controls
    // group at the top of this file, it's exercised without ever selecting
    // a real image. Seeding is done two ways on purpose:
    //  - a placeholder `Photos` row (kind: 'slice', NOT 'original') is
    //    inserted directly so `Routes.photoId`'s FK is satisfiable, WITHOUT
    //    being discoverable via `photoRepository.loadOriginal` — so the
    //    screen's own initial-load microtask never selects an image path
    //    and never triggers the real, undriveable-under-fake-time image
    //    decode this file's M3 NOTE (above) describes.
    //  - `drawControllerProvider.notifier.loadForWall(...)` is then called
    //    directly (exactly like TopoCanvasScreen._loadInitialPhotoForWall
    //    would for a wall with a real attached original) to seed
    //    `activePhotoId` + `routes` for the gating check.
    testWidgets(
      'A4: topo-ar-button appears only once the wall has a photo + >=1 '
      'route, and navigates to /walls/:wallId/ar',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 1000),
          ],
        );
        addTearDown(container.dispose);

        final crud = container.read(libraryCrudRepositoryProvider);
        final area = await crud.createArea('Area');
        final sector = await crud.createSector(area.id, 'Sector');
        final wall = await crud.createWall(sector.id, 'Wall');

        const placeholderPhotoId = 'placeholder-photo';
        await db.into(db.photos).insert(
              PhotosCompanion.insert(
                id: placeholderPhotoId,
                createdAt: 1000,
                updatedAt: 1000,
                wallId: wall.id,
                localPath: '/tmp/placeholder.jpg',
                kind: 'slice',
                width: 100,
                height: 100,
              ),
            );
        final routeRepo = RouteRepository(db, nowMs: () => 1000);
        await routeRepo.upsertRoute(
          wall.id,
          placeholderPhotoId,
          const TopoRoute(
            id: 1,
            number: 1,
            points: [Offset(0.1, 0.1), Offset(0.2, 0.2)],
          ),
        );

        final router = GoRouter(
          initialLocation: '/walls/${wall.id}',
          routes: [
            GoRoute(
              path: '/walls/:wallId',
              builder: (context, state) => TopoCanvasScreen(
                wallId: state.pathParameters['wallId']!,
              ),
            ),
            GoRoute(
              path: '/walls/:wallId/ar',
              builder: (context, state) =>
                  ArScreen(wallId: state.pathParameters['wallId']!),
            ),
          ],
        );
        addTearDown(router.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp.router(
              routerConfig: router,
              theme: MasiTheme.light,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // No photo/route wired into drawControllerProvider yet (the
        // placeholder Photos row above is deliberately NOT the wall's
        // 'original', so the screen's own load found nothing): the button
        // must be absent.
        expect(find.byKey(const Key('topo-ar-button')), findsNothing);

        // Seed activePhotoId + routes exactly as a real attached-original
        // load would, without ever touching selectedImageProvider.
        await container
            .read(drawControllerProvider.notifier)
            .loadForWall(wall.id, placeholderPhotoId);
        await tester.pump();

        expect(find.byKey(const Key('topo-ar-button')), findsOneWidget);

        await tester.tap(find.byKey(const Key('topo-ar-button')));
        await tester.pumpAndSettle();

        expect(find.byType(ArScreen), findsOneWidget);
        expect(
          find.byKey(const Key('ar-unsupported-placeholder')),
          findsOneWidget,
          reason:
              'the AR route was reached (this test host is non-iOS, so '
              "ArScreen's own platform gate renders its placeholder)",
        );
      },
    );

    testWidgets(
      'Fix 3: topo-ar-button stays hidden when the wall has a photo but its '
      'only route is invisible, and appears once toggled visible',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 1000),
          ],
        );
        addTearDown(container.dispose);

        final crud = container.read(libraryCrudRepositoryProvider);
        final area = await crud.createArea('Area');
        final sector = await crud.createSector(area.id, 'Sector');
        final wall = await crud.createWall(sector.id, 'Wall');

        const placeholderPhotoId = 'placeholder-photo';
        await db.into(db.photos).insert(
              PhotosCompanion.insert(
                id: placeholderPhotoId,
                createdAt: 1000,
                updatedAt: 1000,
                wallId: wall.id,
                localPath: '/tmp/placeholder.jpg',
                kind: 'slice',
                width: 100,
                height: 100,
              ),
            );
        final routeRepo = RouteRepository(db, nowMs: () => 1000);
        await routeRepo.upsertRoute(
          wall.id,
          placeholderPhotoId,
          const TopoRoute(
            id: 1,
            number: 1,
            visible: false,
            points: [Offset(0.1, 0.1), Offset(0.2, 0.2)],
          ),
        );

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: MasiTheme.light,
              home: TopoCanvasScreen(wallId: wall.id),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await container
            .read(drawControllerProvider.notifier)
            .loadForWall(wall.id, placeholderPhotoId);
        await tester.pump();

        final routeId =
            container.read(drawControllerProvider).routes.single.id;
        expect(
          container.read(drawControllerProvider).routes.single.visible,
          isFalse,
        );
        expect(
          find.byKey(const Key('topo-ar-button')),
          findsNothing,
          reason:
              'a wall whose only route is invisible has nothing for AR to '
              'show, so the button must stay hidden',
        );

        await container
            .read(drawControllerProvider.notifier)
            .toggleRouteVisibility(routeId);
        await tester.pump();

        expect(
          container.read(drawControllerProvider).routes.single.visible,
          isTrue,
        );
        expect(find.byKey(const Key('topo-ar-button')), findsOneWidget);
      },
    );
  });

  group('RouteLegend', () {
    testWidgets('A1: with >=1 committed route, the legend lists it (number + '
        'visibility toggle), and tapping the toggle flips routes[i].visible', (
      tester,
    ) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(drawControllerProvider.notifier);
      notifier.addPoint(const Offset(0.1, 0.1));
      notifier.addPoint(const Offset(0.2, 0.2));
      notifier.commitRoute();
      final route = container.read(drawControllerProvider).routes.single;

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: MasiTheme.light,
            home: const Scaffold(body: RouteLegend()),
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(Key('topo-route-legend-item-${route.id}')),
        findsOneWidget,
      );
      expect(find.text('Route ${route.number}'), findsOneWidget);
      expect(
        container.read(drawControllerProvider).routes.single.visible,
        isTrue,
      );

      await tester.tap(find.byKey(Key('topo-route-visibility-${route.id}')));
      await tester.pump();

      expect(
        container.read(drawControllerProvider).routes.single.visible,
        isFalse,
      );

      // Delete control removes the route entirely.
      await tester.tap(find.byKey(Key('topo-route-delete-${route.id}')));
      await tester.pump();

      expect(container.read(drawControllerProvider).routes, isEmpty);
    });

    testWidgets('renders nothing when there are no routes', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: RouteLegend())),
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key('topo-route-legend')), findsNothing);
    });

    testWidgets(
      'A4: a graded route shows its grade in the title and its swatch uses '
      'the grade-band color (colorForRoute), not the palette color',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);

        final notifier = container.read(drawControllerProvider.notifier);
        notifier.addPoint(const Offset(0.1, 0.1));
        notifier.addPoint(const Offset(0.2, 0.2));
        notifier.commitRoute();
        final route = container.read(drawControllerProvider).routes.single;

        // French '7a' -> shared-scale sort key 13.0 -> GradeBand.hard.
        await notifier.setRouteMetadata(
          route.id,
          gradeSystem: GradeSystem.french,
          gradeRaw: '7a',
        );

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: MasiTheme.light,
              home: const Scaffold(body: RouteLegend()),
            ),
          ),
        );
        await tester.pump();

        expect(find.text('Route ${route.number} • 7a'), findsOneWidget);

        final gradedRoute = container.read(drawControllerProvider).routes.single;
        final avatar = tester.widget<CircleAvatar>(
          find.descendant(
            of: find.byKey(Key('topo-route-legend-item-${route.id}')),
            matching: find.byType(CircleAvatar),
          ),
        );
        expect(
          avatar.backgroundColor!.toARGB32(),
          colorForRoute(gradedRoute, kRoutePalette).toARGB32(),
        );
        expect(
          avatar.backgroundColor!.toARGB32(),
          colorForGradeBand(GradeBand.hard).toARGB32(),
        );
      },
    );

    void setViewportSize(WidgetTester tester, Size size) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    testWidgets(
      'Fix 1: a single route wraps to its own content height instead of '
      'the old hard-coded 140px box (which left a tall, mostly-empty gap '
      'for just one row)',
      (tester) async {
        setViewportSize(tester, const Size(400, 800));

        final container = ProviderContainer();
        addTearDown(container.dispose);
        final notifier = container.read(drawControllerProvider.notifier);
        notifier.addPoint(const Offset(0.1, 0.1));
        notifier.addPoint(const Offset(0.2, 0.2));
        notifier.commitRoute();

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: MasiTheme.light,
              home: const Scaffold(body: RouteLegend()),
            ),
          ),
        );
        await tester.pump();

        final size = tester.getSize(find.byKey(const Key('topo-route-legend')));
        expect(
          size.height,
          lessThan(100),
          reason:
              'one route must render as ~one row of content — a single '
              "ListTile — not the old fixed 140px SizedBox that left a "
              'tall, mostly-empty box for just one route',
        );
      },
    );

    testWidgets(
      'Fix 1: >=8 routes cap the legend at <=~40% of the screen height and '
      'scroll internally, with every row still reachable (none clipped)',
      (tester) async {
        setViewportSize(tester, const Size(400, 800));

        final container = ProviderContainer();
        addTearDown(container.dispose);
        final notifier = container.read(drawControllerProvider.notifier);
        for (var i = 0; i < 10; i++) {
          notifier.addPoint(const Offset(0.1, 0.1));
          notifier.addPoint(const Offset(0.2, 0.2));
          notifier.commitRoute();
        }
        final routes = container.read(drawControllerProvider).routes;
        expect(routes, hasLength(10));

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: MasiTheme.light,
              home: const Scaffold(body: RouteLegend()),
            ),
          ),
        );
        await tester.pump();

        // 800 (screen height) * 0.4 (the cap fraction) = 320.
        const expectedMaxHeight = 320.0;
        final size = tester.getSize(find.byKey(const Key('topo-route-legend')));
        expect(
          size.height,
          lessThanOrEqualTo(expectedMaxHeight + 0.5),
          reason:
              '10 routes must cap at <=40% of the 800px-tall screen '
              '(${expectedMaxHeight}px) rather than growing to fit every '
              'row, which would push (or overflow past) the canvas above '
              'it',
        );
        expect(
          size.height,
          greaterThan(100),
          reason:
              '10 routes should fill the cap, not shrink-wrap down to a '
              'single row — sanity check that this scenario actually '
              'exercises the capped/scrolling path, not the content-sized '
              'path from the single-route test above',
        );

        // The first route is visible without scrolling...
        expect(
          find.byKey(Key('topo-route-legend-item-${routes.first.id}')),
          findsOneWidget,
        );
        // ...and the LAST route, even though off-screen initially, is
        // still reachable by scrolling — proving nothing is permanently
        // clipped, just capped-and-scrollable.
        await tester.scrollUntilVisible(
          find.byKey(Key('topo-route-legend-item-${routes.last.id}')),
          200.0,
          scrollable: find.byType(Scrollable),
        );
        expect(
          find.byKey(Key('topo-route-legend-item-${routes.last.id}')),
          findsOneWidget,
        );
      },
    );
  });

  group('RouteMetadataSheet', () {
    // Pumped directly with a seeded drawControllerProvider (a single
    // committed route) inside a ProviderScope + MaterialApp, per the class
    // doc's testability contract: no image decode, no real canvas/photo
    // path, so these run as plain (non-fake-async) widget tests.
    Widget buildSheet({
      required ProviderContainer container,
      required int routeId,
      TopoRoute? initial,
    }) {
      return UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: MasiTheme.light,
          home: Scaffold(
            body: RouteMetadataSheet(routeId: routeId, initial: initial),
          ),
        ),
      );
    }

    testWidgets(
      'A1: shows the name field, grade-system toggle, grade picker, style '
      'selector, description field, and save/cancel controls',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final notifier = container.read(drawControllerProvider.notifier);
        notifier.addPoint(const Offset(0.1, 0.1));
        notifier.addPoint(const Offset(0.2, 0.2));
        notifier.commitRoute();
        final routeId = container.read(drawControllerProvider).routes.single.id;

        await tester.pumpWidget(buildSheet(container: container, routeId: routeId));
        await tester.pump();

        expect(find.byKey(const Key('topo-meta-name')), findsOneWidget);
        expect(
          find.byKey(const Key('topo-meta-gradesystem-french')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('topo-meta-gradesystem-uiaa')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('topo-meta-grade')), findsOneWidget);
        expect(find.byKey(const Key('topo-meta-style-sport')), findsOneWidget);
        expect(find.byKey(const Key('topo-meta-style-trad')), findsOneWidget);
        expect(
          find.byKey(const Key('topo-meta-style-boulder')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('topo-meta-description')), findsOneWidget);
        expect(find.byKey(const Key('topo-meta-save')), findsOneWidget);
        expect(find.byKey(const Key('topo-meta-cancel')), findsOneWidget);
      },
    );

    testWidgets(
      'A2: filling name + French + a valid grade + style and tapping save '
      "updates the controller's route with that metadata and a non-null "
      'gradeSortKey',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final notifier = container.read(drawControllerProvider.notifier);
        notifier.addPoint(const Offset(0.1, 0.1));
        notifier.addPoint(const Offset(0.2, 0.2));
        notifier.commitRoute();
        final routeId = container.read(drawControllerProvider).routes.single.id;

        await tester.pumpWidget(buildSheet(container: container, routeId: routeId));
        await tester.pump();

        await tester.enterText(
          find.byKey(const Key('topo-meta-name')),
          'Le Toit',
        );
        await tester.tap(find.byKey(const Key('topo-meta-gradesystem-french')));
        await tester.pump();

        await tester.tap(find.byKey(const Key('topo-meta-grade')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('6a+'));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('topo-meta-style-sport')));
        await tester.pump();

        // The sheet grew (beta-URL/style-tags/stars sections) and now
        // overflows the default 800x600 test surface; its body is a real
        // SingleChildScrollView (see RouteMetadataSheet.build), so Save
        // must be scrolled into view before tapping it.
        await tester.ensureVisible(find.byKey(const Key('topo-meta-save')));
        await tester.tap(find.byKey(const Key('topo-meta-save')));
        await tester.pump();

        final route = container.read(drawControllerProvider).routes.single;
        expect(route.name, 'Le Toit');
        expect(route.gradeSystem, GradeSystem.french);
        expect(route.gradeRaw, '6a+');
        expect(route.style, 'sport');
        expect(route.gradeSortKey, isNotNull);
      },
    );

    testWidgets(
      'A3: toggling French<->UIAA repopulates the grade dropdown with that '
      "system's options",
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final notifier = container.read(drawControllerProvider.notifier);
        notifier.addPoint(const Offset(0.1, 0.1));
        notifier.addPoint(const Offset(0.2, 0.2));
        notifier.commitRoute();
        final routeId = container.read(drawControllerProvider).routes.single.id;

        await tester.pumpWidget(buildSheet(container: container, routeId: routeId));
        await tester.pump();

        // Default system is French: opening the dropdown should offer '6a'.
        await tester.tap(find.byKey(const Key('topo-meta-grade')));
        await tester.pumpAndSettle();
        expect(find.text('6a'), findsOneWidget);
        // Close the dropdown without selecting.
        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('topo-meta-gradesystem-uiaa')));
        await tester.pump();

        await tester.tap(find.byKey(const Key('topo-meta-grade')));
        await tester.pumpAndSettle();
        expect(find.text('VI+'), findsOneWidget);
        expect(find.text('6a'), findsNothing);
      },
    );

    testWidgets(
      'pre-fills fields from initial when editing an already-graded route',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final notifier = container.read(drawControllerProvider.notifier);
        notifier.addPoint(const Offset(0.1, 0.1));
        notifier.addPoint(const Offset(0.2, 0.2));
        notifier.commitRoute();
        final routeId = container.read(drawControllerProvider).routes.single.id;
        await notifier.setRouteMetadata(
          routeId,
          name: 'Existing Route',
          gradeSystem: GradeSystem.uiaa,
          gradeRaw: 'VII-',
          style: 'trad',
          description: 'Crimpy start',
        );
        final initial = container.read(drawControllerProvider).routes.single;

        await tester.pumpWidget(
          buildSheet(container: container, routeId: routeId, initial: initial),
        );
        await tester.pump();

        expect(find.text('Existing Route'), findsOneWidget);
        expect(find.text('VII-'), findsOneWidget);
        expect(find.text('Crimpy start'), findsOneWidget);
      },
    );
  });

  group('SymbolPaletteBar + TopoCanvas symbol placement', () {
    // Pumps the symbol palette bar directly above a fixed-size TopoCanvas
    // (mirroring how TopoCanvasScreen lays them out via a Column), with the
    // same identity-transform + fixed-imageSize harness used by the
    // 'TopoCanvas' group above, so canvas taps map to deterministic percent
    // coordinates.
    Widget buildPaletteAndCanvas({
      required ProviderContainer container,
      required TransformationController controller,
      Size imageSize = const Size(400, 300),
    }) {
      return UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          // SymbolPaletteBar reads MasiColors off the ambient Theme — see
          // the "TopoCanvasBody: symbol bar mode visibility" buildBody's
          // identical fix above.
          theme: MasiTheme.light,
          home: Scaffold(
            body: Column(
              children: [
                const SymbolPaletteBar(),
                Expanded(
                  child: TopoCanvas(
                    imagePath: '/nonexistent/test-topo.jpg',
                    imageSize: imageSize,
                    transformationController: controller,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    void setViewportSize(WidgetTester tester, Size size) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    testWidgets(
      'A3: tapping a symbol control sets activeSymbol (and tapping it '
      'again clears it); with a route selected, a canvas tap appends a '
      'symbol of that type to the route',
      (tester) async {
        // 300 (imageSize height) + a generous placeholder for the bar's
        // height: measured for real just below, since SymbolPaletteBar's
        // ACTUAL rendered height (canvas look rework: now GlassChrome-
        // wrapped, adding that widget's own vertical padding on top of
        // kSymbolPaletteBarHeight) is no longer exactly
        // kSymbolPaletteBarHeight — see symbol_palette_bar.dart's class doc.
        setViewportSize(
          tester,
          const Size(400, 300 + kSymbolPaletteBarHeight + 32),
        );
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final controller = TransformationController();
        addTearDown(controller.dispose);

        final notifier = container.read(drawControllerProvider.notifier);
        notifier.addPoint(const Offset(0.1, 0.1));
        notifier.addPoint(const Offset(0.9, 0.9));
        notifier.commitRoute();
        final routeId = container.read(drawControllerProvider).routes.single.id;
        notifier.selectRoute(routeId);
        notifier.setMode(DrawMode.draw);

        await tester.pumpWidget(
          buildPaletteAndCanvas(container: container, controller: controller),
        );
        await tester.pump();

        // Measure the bar's REAL rendered height (rather than assuming
        // kSymbolPaletteBarHeight exactly — see the setViewportSize comment
        // above), then resize the viewport so the Expanded TopoCanvas below
        // it gets EXACTLY `imageSize` as its viewport, keeping the
        // identity-transform coordinate math below valid.
        final barHeight = tester.getSize(find.byType(SymbolPaletteBar)).height;
        setViewportSize(tester, Size(400, 300 + barHeight));
        await tester.pump();

        expect(container.read(drawControllerProvider).activeSymbol, isNull);

        await tester.tap(find.byKey(const Key('topo-symbol-anchor')));
        await tester.pump();

        expect(
          container.read(drawControllerProvider).activeSymbol,
          SymbolType.anchor,
        );

        // TopoCanvas sits below the `barHeight`-tall SymbolPaletteBar in the
        // Column, so a global tap's localPosition *within TopoCanvas* is
        // offset by that height: tapping global (200, 150 + barHeight)
        // lands at local (200, 150) -> scene (200, 150) -> percent
        // (0.5, 0.5).
        await tester.tapAt(Offset(200, 150 + barHeight));
        await tester.pump();

        final route = container.read(drawControllerProvider).routes.single;
        expect(route.symbols, hasLength(1));
        expect(route.symbols.single.type, SymbolType.anchor);
        expect(route.symbols.single.position.dx, closeTo(0.5, 0.01));
        expect(route.symbols.single.position.dy, closeTo(0.5, 0.01));

        // Tapping the already-active control clears it.
        await tester.tap(find.byKey(const Key('topo-symbol-anchor')));
        await tester.pump();

        expect(container.read(drawControllerProvider).activeSymbol, isNull);

        // With no active symbol, a further canvas tap goes back to normal
        // draw behavior (adds a route point) rather than placing another
        // symbol.
        await tester.tapAt(const Offset(300, 100));
        await tester.pump();

        expect(
          container.read(drawControllerProvider).currentPoints,
          hasLength(1),
        );
        expect(
          container.read(drawControllerProvider).routes.single.symbols,
          hasLength(1),
        );
      },
    );

    testWidgets(
      'U1/U6 (canvas render): placing a symbol on the in-progress '
      '(uncommitted) route is handed to TopoPainter via currentSymbols, so '
      'it renders before the route is ever committed',
      (tester) async {
        setViewportSize(
          tester,
          const Size(400, 300 + kSymbolPaletteBarHeight + 32),
        );
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final controller = TransformationController();
        addTearDown(controller.dispose);

        final notifier = container.read(drawControllerProvider.notifier);
        notifier.setMode(DrawMode.draw);
        // Two points drawn but NOT committed: routes stays empty, so
        // placeSymbol below must land on currentSymbols (see draw_controller
        // .dart's placeSymbol doc), not a committed route.
        notifier.addPoint(const Offset(0.1, 0.1));
        notifier.addPoint(const Offset(0.9, 0.9));
        expect(container.read(drawControllerProvider).routes, isEmpty);

        await tester.pumpWidget(
          buildPaletteAndCanvas(container: container, controller: controller),
        );
        await tester.pump();

        final barHeight = tester.getSize(find.byType(SymbolPaletteBar)).height;
        setViewportSize(tester, Size(400, 300 + barHeight));
        await tester.pump();

        await tester.tap(find.byKey(const Key('topo-symbol-crux')));
        await tester.pump();
        expect(
          container.read(drawControllerProvider).activeSymbol,
          SymbolType.crux,
        );

        // Global (200, 150 + barHeight) -> local (200, 150) -> scene
        // (200, 150) -> percent (0.5, 0.5), same mapping as A3 above.
        await tester.tapAt(Offset(200, 150 + barHeight));
        await tester.pump();

        final state = container.read(drawControllerProvider);
        expect(state.routes, isEmpty); // still uncommitted
        expect(state.currentSymbols, hasLength(1));
        expect(state.currentSymbols.single.type, SymbolType.crux);

        final customPaint = tester.widget<CustomPaint>(
          find.byWidgetPredicate(
            (widget) => widget is CustomPaint && widget.painter is TopoPainter,
          ),
        );
        final painter = customPaint.painter as TopoPainter;

        // The painter must be handed the SAME in-progress symbols the
        // controller holds, so TopoPainter.paint's currentSymbols loop
        // actually renders it -- this is what makes the symbol visible on
        // screen before commitRoute is ever called.
        expect(painter.currentSymbols, state.currentSymbols);
        expect(painter.currentSymbols.single.position.dx, closeTo(0.5, 0.01));
        expect(painter.currentSymbols.single.position.dy, closeTo(0.5, 0.01));
      },
    );

    testWidgets(
      'switching between symbol controls only activates one at a time',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            // SymbolPaletteBar reads MasiColors off the ambient Theme — see
            // buildPaletteAndCanvas's identical fix above.
            child: MaterialApp(
              theme: MasiTheme.light,
              home: const Scaffold(body: SymbolPaletteBar()),
            ),
          ),
        );
        await tester.pump();

        await tester.tap(find.byKey(const Key('topo-symbol-bolt')));
        await tester.pump();
        expect(
          container.read(drawControllerProvider).activeSymbol,
          SymbolType.bolt,
        );

        await tester.tap(find.byKey(const Key('topo-symbol-crux')));
        await tester.pump();
        expect(
          container.read(drawControllerProvider).activeSymbol,
          SymbolType.crux,
        );
      },
    );
  });

  group('PhotoSelector (M5)', () {
    // PhotoSelector is pumped directly (mirroring the other presentation
    // widgets in this file) with a plain ProviderContainer — it only reads
    // activeViewProvider, no database/photoRepository access — and a fixed
    // list of PhotoRefs standing in for a wall's persisted slices.
    const slice0 = PhotoRef(
      id: 'slice-0',
      wallId: 'wall-1',
      kind: 'slice',
      localPath: '/tmp/original.jpg',
      width: 1000,
      height: 2000,
      parentPhotoId: 'orig-1',
      cropXpct: 0.0,
      cropWidthPct: 0.5,
    );
    const slice1 = PhotoRef(
      id: 'slice-1',
      wallId: 'wall-1',
      kind: 'slice',
      localPath: '/tmp/original.jpg',
      width: 1000,
      height: 2000,
      parentPhotoId: 'orig-1',
      cropXpct: 0.5,
      cropWidthPct: 0.5,
    );

    Widget buildSelector(ProviderContainer container) {
      return UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: PhotoSelector(
              originalPhotoId: 'orig-1',
              slices: [slice0, slice1],
            ),
          ),
        ),
      );
    }

    testWidgets(
      'A1: lists Original + one chip per persisted slice; tapping a slice '
      "chip sets activeViewProvider to that slice's crop; tapping Original "
      'clears it (isOriginal true)',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);

        await tester.pumpWidget(buildSelector(container));
        await tester.pump();

        expect(find.byKey(const Key('photo-sel-original')), findsOneWidget);
        expect(find.byKey(const Key('photo-sel-slice-0')), findsOneWidget);
        expect(find.byKey(const Key('photo-sel-slice-1')), findsOneWidget);
        expect(find.byKey(const Key('photo-sel-slice-2')), findsNothing);

        // Nothing selected yet (null) reads the same as Original.
        expect(container.read(activeViewProvider), isNull);

        await tester.tap(find.byKey(const Key('photo-sel-slice-1')));
        await tester.pump();

        final afterSlice = container.read(activeViewProvider);
        expect(afterSlice, isNotNull);
        expect(afterSlice!.isOriginal, isFalse);
        expect(afterSlice.photoId, 'slice-1');
        expect(afterSlice.cropXpct, 0.5);
        expect(afterSlice.cropWidthPct, 0.5);

        await tester.tap(find.byKey(const Key('photo-sel-original')));
        await tester.pump();

        final afterOriginal = container.read(activeViewProvider);
        expect(afterOriginal, isNotNull);
        expect(afterOriginal!.isOriginal, isTrue);
        expect(afterOriginal.photoId, 'orig-1');
      },
    );
  });

  group('TopoCanvas.computeCropTransform (M5, A2)', () {
    test(
      'scale == min(viewportWidth/(cropWidthPct*W), viewportHeight/H) '
      '(Fix 3 contain-fit); with this image/viewport/crop the two '
      'candidate scales happen to be equal, so the band still maps to '
      'exactly [0, viewportWidth] on screen',
      () {
        const viewportSize = Size(400, 400);
        const imageSize = Size(2000, 1000);
        const cropXpct = 0.25;
        const cropWidthPct = 0.5;

        final matrix = TopoCanvas.computeCropTransform(
          viewportSize: viewportSize,
          imageSize: imageSize,
          cropXpct: cropXpct,
          cropWidthPct: cropWidthPct,
        );

        final widthScale = viewportSize.width / (cropWidthPct * imageSize.width);
        final heightScale = viewportSize.height / imageSize.height;
        final expectedScale = widthScale < heightScale ? widthScale : heightScale;
        expect(matrix.getMaxScaleOnAxis(), closeTo(expectedScale, 1e-9));

        final bandLeftScreen = MatrixUtils.transformPoint(
          matrix,
          Offset(cropXpct * imageSize.width, 0),
        );
        expect(bandLeftScreen.dx, closeTo(0.0, 1e-6));

        final bandRightScreen = MatrixUtils.transformPoint(
          matrix,
          Offset((cropXpct + cropWidthPct) * imageSize.width, 0),
        );
        expect(bandRightScreen.dx, closeTo(viewportSize.width, 1e-6));
      },
    );

    test(
      'Fix 3: a thin band whose width-only scale would overflow the '
      'viewport vertically is instead height-bound (contain-fit) and '
      'centered horizontally, so the whole band fits with no clipping',
      () {
        // A 1000x1000 image, a thin 10%-wide band, framed into a 400x400
        // viewport: width-only scale would be 400/(0.1*1000) = 4.0, which
        // would scale the full 1000px-tall image to 4000px — massively
        // overflowing a 400-tall viewport. The height-bound scale
        // (400/1000 = 0.4) is smaller and must win instead.
        const viewportSize = Size(400, 400);
        const imageSize = Size(1000, 1000);
        const cropXpct = 0.45;
        const cropWidthPct = 0.1;

        final matrix = TopoCanvas.computeCropTransform(
          viewportSize: viewportSize,
          imageSize: imageSize,
          cropXpct: cropXpct,
          cropWidthPct: cropWidthPct,
        );

        const expectedScale = 0.4; // height-bound: 400/1000
        expect(matrix.getMaxScaleOnAxis(), closeTo(expectedScale, 1e-9));

        // The scaled band (100px wide * 0.4 = 40px) no longer fills the
        // viewport's width, so it must be centered horizontally rather
        // than left-aligned to screen x=0.
        final bandLeftScreen = MatrixUtils.transformPoint(
          matrix,
          Offset(cropXpct * imageSize.width, 0),
        );
        final bandRightScreen = MatrixUtils.transformPoint(
          matrix,
          Offset((cropXpct + cropWidthPct) * imageSize.width, 0),
        );
        final expectedBandWidthScreen = cropWidthPct * imageSize.width * expectedScale;
        expect(
          bandRightScreen.dx - bandLeftScreen.dx,
          closeTo(expectedBandWidthScreen, 1e-6),
        );
        final expectedLeft =
            (viewportSize.width - expectedBandWidthScreen) / 2;
        expect(bandLeftScreen.dx, closeTo(expectedLeft, 1e-6));

        // The full image height, scaled, exactly fills the viewport height
        // here (1000*0.4 == 400), so the top/bottom edges land exactly on
        // the viewport bounds with no vertical overflow.
        final topScreen = MatrixUtils.transformPoint(matrix, const Offset(0, 0));
        final bottomScreen = MatrixUtils.transformPoint(
          matrix,
          Offset(0, imageSize.height),
        );
        expect(topScreen.dy, closeTo(0.0, 1e-6));
        expect(bottomScreen.dy, closeTo(viewportSize.height, 1e-6));
      },
    );
  });

  group('TopoCanvas crop framing (M5)', () {
    // Mirrors the identity-controller + injected-imageSize harness used by
    // the 'TopoCanvas' group above: the test surface is resized to exactly
    // `viewportSize` so LayoutBuilder's constraints are deterministic.
    void setViewportSize(WidgetTester tester, Size size) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    Widget buildCanvas({
      required ProviderContainer container,
      required TransformationController controller,
      required Size imageSize,
      double? activeCropXpct,
      double? activeCropWidthPct,
    }) {
      return UncontrolledProviderScope(
        container: container,
        // Fix 2 (canvas UI fixes) needs `theme: MasiTheme.light` — see the
        // 'TopoCanvas' group's buildCanvas above for why.
        child: MaterialApp(
          theme: MasiTheme.light,
          home: Scaffold(
            body: TopoCanvas(
              imagePath: '/nonexistent/test-topo.jpg',
              imageSize: imageSize,
              transformationController: controller,
              activeCropXpct: activeCropXpct,
              activeCropWidthPct: activeCropWidthPct,
            ),
          ),
        ),
      );
    }

    // A 2000x1000 image cropped to cropWidthPct=0.5 (band width 1000px)
    // framed into a 400x400 viewport: scale = 400/1000 = 0.4, and the
    // scaled image height (1000*0.4 = 400) exactly matches the viewport
    // height, so the vertical centering translate is exactly 0 — chosen so
    // the expected screen<->scene mapping below has no extra letterboxing
    // term to account for.
    const imageSize = Size(2000, 1000);
    const viewportSize = Size(400, 400);
    const cropXpct = 0.25;
    const cropWidthPct = 0.5;

    testWidgets(
      'A2: with a slice active, the controller is framed to exactly '
      'TopoCanvas.computeCropTransform for the current viewport/image size',
      (tester) async {
        setViewportSize(tester, viewportSize);
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final controller = TransformationController();
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          buildCanvas(
            container: container,
            controller: controller,
            imageSize: imageSize,
            activeCropXpct: cropXpct,
            activeCropWidthPct: cropWidthPct,
          ),
        );
        await tester.pump();

        final expected = TopoCanvas.computeCropTransform(
          viewportSize: viewportSize,
          imageSize: imageSize,
          cropXpct: cropXpct,
          cropWidthPct: cropWidthPct,
        );

        expect(controller.value, expected);
      },
    );

    testWidgets(
      'A3: tapping in draw mode while a slice is active stores the point '
      "as ORIGINAL % — the framed band's LEFT edge maps to dx≈cropXpct, "
      'the band CENTER maps to dx≈cropXpct+cropWidthPct/2 (proving '
      'drawing on a slice needs no reprojection)',
      (tester) async {
        setViewportSize(tester, viewportSize);
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final controller = TransformationController();
        addTearDown(controller.dispose);

        container.read(drawControllerProvider.notifier).setMode(DrawMode.draw);

        await tester.pumpWidget(
          buildCanvas(
            container: container,
            controller: controller,
            imageSize: imageSize,
            activeCropXpct: cropXpct,
            activeCropWidthPct: cropWidthPct,
          ),
        );
        await tester.pump();

        // The band's LEFT edge is framed at screen x≈0 (tap slightly
        // inside, at x=2, to stay clear of the exact widget boundary).
        await tester.tapAt(const Offset(2, 200));
        await tester.pump();

        var points = container.read(drawControllerProvider).currentPoints;
        expect(points.length, 1);
        expect(points.last.dx, closeTo(cropXpct, 0.01));

        // The band CENTER is framed at screen x = viewportWidth/2 = 200.
        await tester.tapAt(const Offset(200, 200));
        await tester.pump();

        points = container.read(drawControllerProvider).currentPoints;
        expect(points.length, 2);
        expect(points.last.dx, closeTo(cropXpct + cropWidthPct / 2, 0.01));
      },
    );
  });

  group('TopoCanvas reframe on imageSize change (M5 Fix 1 hardening)', () {
    // Regression coverage for Fix 1's second half: TopoCanvasScreen shares
    // ONE long-lived TransformationController/TopoCanvas position across
    // photo switches (see the group below for the screen-level half of
    // Fix 1), so _TopoCanvasState itself must not treat "same crop value
    // (null->null), different imageSize" as "nothing changed" — that was
    // exactly how a fresh photo could keep rendering through the previous
    // photo's stale fit matrix forever.
    void setViewportSize(WidgetTester tester, Size size) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    Widget buildCanvas({
      required ProviderContainer container,
      required TransformationController controller,
      required Size imageSize,
    }) {
      return UncontrolledProviderScope(
        container: container,
        // Fix 2 (canvas UI fixes) needs `theme: MasiTheme.light` — see the
        // 'TopoCanvas' group's buildCanvas above for why.
        child: MaterialApp(
          theme: MasiTheme.light,
          home: Scaffold(
            body: TopoCanvas(
              imagePath: '/nonexistent/test-topo.jpg',
              imageSize: imageSize,
              transformationController: controller,
            ),
          ),
        ),
      );
    }

    testWidgets(
      'rebuilding the SAME TopoCanvas position with a different imageSize '
      '(no crop; crop value unchanged at null->null) re-fits to the NEW '
      "size instead of keeping the previous imageSize's stale transform",
      (tester) async {
        const viewportSize = Size(400, 800);
        setViewportSize(tester, viewportSize);
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final controller = TransformationController();
        addTearDown(controller.dispose);

        // fitScale (CONTAIN — canvas look rework's default open-framing) =
        // min(400/4000, 800/2000) = min(0.1, 0.4) = 0.1
        const imageSizeA = Size(4000, 2000);
        await tester.pumpWidget(
          buildCanvas(
            container: container,
            controller: controller,
            imageSize: imageSizeA,
          ),
        );
        await tester.pump();

        expect(
          controller.value.getMaxScaleOnAxis(),
          closeTo(0.1, 0.001),
          reason: 'first layout must fit imageSize A',
        );

        // fitScale = min(400/2000, 800/4000) = min(0.2, 0.2) = 0.2 — this
        // image's aspect ratio matches the viewport's exactly (no letterbox
        // either way), so CONTAIN and COVER coincide here regardless. A
        // different image, at the SAME widget position/State, still with
        // no crop active (null->null, i.e. an "unchanged" crop value).
        const imageSizeB = Size(2000, 4000);
        await tester.pumpWidget(
          buildCanvas(
            container: container,
            controller: controller,
            imageSize: imageSizeB,
          ),
        );
        await tester.pump();

        expect(
          controller.value.getMaxScaleOnAxis(),
          closeTo(0.2, 0.001),
          reason:
              'must reframe to fit the NEW image size rather than staying '
              "stuck on imageSize A's fit matrix",
        );
      },
    );
  });

  group('TopoCanvas scale range with a crop active (M5 Fix 4)', () {
    void setViewportSize(WidgetTester tester, Size size) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    testWidgets(
      'a thin slice whose applied crop scale exceeds the full-image-'
      "derived maxScale gets minScale/maxScale WIDENED so it's never "
      'clamped back out of the crop on the first pinch',
      (tester) async {
        // A very wide, short image: the full-image fit is width-bound
        // (fitScale = min(400/4000, 300/50) = 0.1), so the OLD
        // fitScale-derived maxScale (max(0.1*20, 5.0) = 5.0) undershoots
        // what a thin crop band actually needs.
        const viewportSize = Size(400, 300);
        const imageSize = Size(4000, 50);
        const cropXpct = 0.5;
        const cropWidthPct = 0.01; // a 40px-wide band

        setViewportSize(tester, viewportSize);
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final controller = TransformationController();
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            // Fix 2 (canvas UI fixes) needs `theme: MasiTheme.light` — see
            // the 'TopoCanvas' group's buildCanvas for why.
            child: MaterialApp(
              theme: MasiTheme.light,
              home: Scaffold(
                body: TopoCanvas(
                  imagePath: '/nonexistent/test-topo.jpg',
                  imageSize: imageSize,
                  transformationController: controller,
                  activeCropXpct: cropXpct,
                  activeCropWidthPct: cropWidthPct,
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        final appliedCropScale = TopoCanvas.computeCropTransform(
          viewportSize: viewportSize,
          imageSize: imageSize,
          cropXpct: cropXpct,
          cropWidthPct: cropWidthPct,
        ).getMaxScaleOnAxis();

        // Sanity: this scenario is only meaningful if the crop's applied
        // scale actually exceeds the OLD hardcoded default of 5.0 —
        // otherwise the pre-fix maxScale would already have been
        // permissive enough and this test would prove nothing.
        expect(appliedCropScale, greaterThan(5.0));

        final viewer = tester.widget<InteractiveViewer>(
          find.byType(InteractiveViewer),
        );

        expect(
          viewer.maxScale,
          greaterThanOrEqualTo(appliedCropScale),
          reason:
              'maxScale must not be smaller than the scale the crop is '
              'actually framed at, or the first pinch snaps back out',
        );
        expect(viewer.minScale, lessThanOrEqualTo(appliedCropScale));
      },
    );
  });

  group('TopoCanvasScreen photo switch resets stale view state (M5 Fix 1)', () {
    testWidgets(
      'selecting a NEW image path synchronously resets activeViewProvider '
      "back to null, mirroring beginPhotoSwitch's synchronous reset",
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 1000),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
            theme: MasiTheme.light,
            home: const TopoCanvasScreen(wallId: 'test-wall'),
          ),
          ),
        );
        await tester.pumpAndSettle();

        // Simulate the previous photo having left activeView pointing
        // somewhere non-null — the Fix 1 symptom: a stale view left over
        // from a prior photo that a fresh photo could otherwise render
        // through.
        container
            .read(activeViewProvider.notifier)
            .showOriginal('stale-photo-id');
        expect(container.read(activeViewProvider), isNotNull);

        // Select a new path directly on the provider (rather than tapping
        // the "pick a photo" FAB, which would invoke the real image_picker
        // plugin) and assert BEFORE ever calling `tester.pump()`:
        // TopoCanvasScreen's `ref.listen` callback fires synchronously as
        // part of Riverpod's own state-change notification, not gated
        // behind a Flutter frame, so this catches exactly the synchronous
        // reset Fix 1 adds without ever triggering a rebuild — and thus
        // without ever scheduling the real FileImage decode that
        // `_resolveImageSize` would kick off, which (per the M3 NOTE
        // above) cannot be reliably driven to completion under
        // testWidgets.
        container
            .read(selectedImageProvider.notifier)
            .select('/nonexistent/new-photo.jpg');

        expect(
          container.read(activeViewProvider),
          isNull,
          reason:
              'the moment a new photo path is selected, activeView must '
              'reset via ActiveViewController.clear() rather than keep '
              "showing through the PREVIOUS photo's view",
        );
      },
    );
  });

  group('TopoCanvasScreen slice mode forces Original view (M5 Fix 2)', () {
    testWidgets(
      'entering slice mode while a slice is the active view resets '
      'activeViewProvider back to Original (isOriginal true), so '
      "SliceTool's dx/viewportWidth cut math is always a true "
      'original-image fraction',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 1000),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
            theme: MasiTheme.light,
            home: const TopoCanvasScreen(wallId: 'test-wall'),
          ),
          ),
        );
        await tester.pumpAndSettle();

        // Establish an active photo (mirroring what loadForWall does once
        // a real photo resolves — a plain SELECT against an unknown
        // wallId is safe, see loadForWall's doc) and switch the active
        // view to a slice, as if the user had picked a slice chip via
        // PhotoSelector before entering slice mode.
        await container
            .read(drawControllerProvider.notifier)
            .loadForWall('test-wall', 'test-original-photo');
        const slice = PhotoRef(
          id: 'test-slice',
          wallId: 'test-wall',
          kind: 'slice',
          localPath: '/tmp/original.jpg',
          width: 1000,
          height: 2000,
          parentPhotoId: 'test-original-photo',
          cropXpct: 0.25,
          cropWidthPct: 0.5,
        );
        container.read(activeViewProvider.notifier).showSlice(slice);
        expect(container.read(activeViewProvider)!.isOriginal, isFalse);

        // Bug 8 fix (canvas look rework): `topo-slice-mode-button` is now
        // gated on `drawState.activePhotoId != null` (see that fix's doc),
        // so — unlike before this gate existed — the widget tree must
        // actually REBUILD to pick up the `loadForWall` call above before
        // the button exists to tap.
        await tester.pump();

        await tester.tap(find.byKey(const Key('topo-slice-mode-button')));
        await tester.pump();

        final activeView = container.read(activeViewProvider);
        expect(activeView, isNotNull);
        expect(
          activeView!.isOriginal,
          isTrue,
          reason: 'entering slice mode must force the view back to Original',
        );
        expect(activeView.photoId, 'test-original-photo');
      },
    );
  });

  group(
    'M6 subtask 4: /walls/:wallId hosts TopoCanvasScreen bound to the '
    'navigated wall',
    () {
      testWidgets(
        'A3/A4: the full Areas -> Sectors -> Walls -> /walls/:wallId nav '
        'chain is intact, and the wall-detail route renders '
        "TopoCanvasScreen(wallId: <the tapped wall's id>), showing its "
        'empty state since no photo is attached yet (decode-free, '
        'deterministic)',
        (tester) async {
          // Owns the container directly (see the "A2: tapping an area
          // navigates..." test in areas_screen_test.dart for why: disposal
          // must happen in addTearDown/real-async, not inside the widget
          // tree's fake-async finalizeTree).
          final db = AppDatabase(NativeDatabase.memory());
          final container = ProviderContainer(
            overrides: [
              appDatabaseProvider.overrideWithValue(db),
              nowMsProvider.overrideWithValue(() => 1000),
            ],
          );
          addTearDown(db.close);
          addTearDown(container.dispose);
          final repo = container.read(libraryCrudRepositoryProvider);
          late AreaRef area;
          late SectorRef sector;
          late WallRef wall;
          await tester.runAsync(() async {
            area = await repo.createArea('Test Area');
            sector = await repo.createSector(area.id, 'Test Sector');
            wall = await repo.createWall(sector.id, 'Test Wall');
          });

          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: const ClimbTopoApp(),
            ),
          );
          await _drain(tester);

          // `/` now renders ToposScreen, not AreasScreen — navigate to the
          // Areas hierarchy explicitly before driving the nav chain below.
          appRouter.go('/areas');
          await _drain(tester);

          expect(find.text('Test Area'), findsOneWidget);

          await tester.tap(find.byKey(Key('area-item-${area.id}')));
          await _drain(tester);
          expect(find.text('Test Sector'), findsOneWidget);

          await tester.tap(find.byKey(Key('sector-item-${sector.id}')));
          await _drain(tester);
          expect(find.text('Test Wall'), findsOneWidget);

          await tester.tap(find.byKey(Key('wall-item-${wall.id}')));
          await _drain(tester);

          expect(find.byType(TopoCanvasScreen), findsOneWidget);
          final screen = tester.widget<TopoCanvasScreen>(
            find.byType(TopoCanvasScreen),
          );
          expect(screen.wallId, wall.id);
          // No photo has been attached to this wall, so the empty state
          // (decode-free — no FileImage/image codec involved) is shown
          // rather than the canvas.
          expect(find.byKey(const Key('topo-empty-state')), findsOneWidget);
          expect(
            find.text('No photo yet — pick one to start'),
            findsOneWidget,
          );

          // Unmount so Riverpod cancels the live Drift watch subscriptions
          // this real (owning) ProviderScope holds before db.close runs in
          // addTearDown — see the "App boots to AreasScreen" test's teardown
          // doc above for why this ordering matters.
          await tester.pumpWidget(const SizedBox());
          await _drain(tester);
        },
      );
    },
  );
}
