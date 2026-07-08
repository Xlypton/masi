import 'package:climbtopo/app/app.dart';
import 'package:climbtopo/features/topo/application/draw_controller.dart';
import 'package:climbtopo/features/topo/presentation/topo_canvas.dart';
import 'package:climbtopo/features/topo/presentation/topo_canvas_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('App renders ClimbTopo title', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: ClimbTopoApp()),
    );
    // Allow GoRouter and MaterialApp.router to settle.
    await tester.pumpAndSettle();

    expect(find.text('ClimbTopo'), findsOneWidget);
  });

  group('TopoCanvasScreen draw-mode controls', () {
    // These controls (the toggle and the toolbar) live in the app bar /
    // bottom bar and operate purely on drawControllerProvider state, so they
    // are pumped via the full TopoCanvasScreen without ever selecting an
    // image — no real image file is needed for A1/A3.

    testWidgets(
      'A1: the view/draw toggle flips the draw controller mode',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: TopoCanvasScreen()),
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
      },
    );

    testWidgets(
      'A3: undo/redo/commit toolbar buttons invoke the draw controller',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: TopoCanvasScreen()),
          ),
        );
        await tester.pumpAndSettle();

        final notifier = container.read(drawControllerProvider.notifier);
        notifier.addPoint(const Offset(0.1, 0.1));
        notifier.addPoint(const Offset(0.2, 0.2));
        expect(
          container.read(drawControllerProvider).currentPoints.length,
          2,
        );

        await tester.tap(find.byKey(const Key('topo-undo-button')));
        await tester.pump();
        expect(
          container.read(drawControllerProvider).currentPoints.length,
          1,
        );

        await tester.tap(find.byKey(const Key('topo-redo-button')));
        await tester.pump();
        expect(
          container.read(drawControllerProvider).currentPoints.length,
          2,
        );

        await tester.tap(find.byKey(const Key('topo-commit-button')));
        await tester.pump();
        expect(container.read(drawControllerProvider).currentPoints, isEmpty);
        expect(
          container.read(drawControllerProvider).completedRoutes.length,
          1,
        );

        // topo-clear-button: start a new current route, then discard it.
        notifier.addPoint(const Offset(0.3, 0.3));
        await tester.tap(find.byKey(const Key('topo-clear-button')));
        await tester.pump();
        expect(container.read(drawControllerProvider).currentPoints, isEmpty);
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
        child: MaterialApp(
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
      'A2: InteractiveViewer pan/scale are disabled in draw mode, enabled '
      'in view mode',
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

        container.read(drawControllerProvider.notifier).setMode(
          DrawMode.draw,
        );
        await tester.pump();

        expect(viewer().panEnabled, isFalse);
        expect(viewer().scaleEnabled, isFalse);

        container.read(drawControllerProvider.notifier).setMode(
          DrawMode.view,
        );
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

        container.read(drawControllerProvider.notifier).setMode(
          DrawMode.draw,
        );

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

        await tester.dragFrom(
          const Offset(200, 150),
          const Offset(40, 0),
        );
        await tester.pump();

        final points = container.read(drawControllerProvider).currentPoints;
        expect(points.length, 1);
        expect(points.first.dx, closeTo(0.6, 0.01));
        expect(points.first.dy, closeTo(0.5, 0.01));
      },
    );

    testWidgets(
      'Fix 1: a large photo fits the viewport (minScale allows zooming out '
      'to fitScale, and the controller is initialized to fitScale so the '
      'whole image is visible on first layout)',
      (tester) async {
        // A real 4000x3000 photo in a narrow ~400x800 phone viewport: the
        // image is far larger than the viewport on both axes, so fitScale
        // is governed by the tighter-constraining axis (width here:
        // 400/4000 = 0.1 < 800/3000 = 0.2667).
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
          reason: 'minScale must allow zooming out far enough to see the '
              'entire wall photo',
        );

        expect(
          controller.value.getMaxScaleOnAxis(),
          closeTo(fitScale, epsilon),
          reason: 'the controller should be initialized to fitScale on '
              'first layout so the whole image is visible without any '
              'manual zoom',
        );
      },
    );
  });

  group('TopoCanvasScreen: new photo resets draw state (Fix 2)', () {
    // _pickImage can't be driven in a widget test without mocking the
    // image_picker platform channel. TopoCanvasScreen instead wires the
    // reset via `ref.listen(selectedImageProvider, ...)` inside build (see
    // _TopoCanvasScreenState._onSelectedImageChanged): whenever the
    // selected path changes to a *different* non-null path, it invalidates
    // drawControllerProvider. That listener fires regardless of how
    // selectedImageProvider's value changes, so "picking a photo" can be
    // simulated here simply by calling the (already-public)
    // selectedImageProvider's notifier directly — this exercises exactly
    // the same code path _pickImage uses internally.
    testWidgets(
      'picking a second, different photo clears currentPoints and '
      'completedRoutes from the first',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: TopoCanvasScreen()),
          ),
        );
        await tester.pumpAndSettle();

        // Simulate picking photo A.
        container.read(selectedImageProvider.notifier).select('/photo-a.jpg');
        await tester.pump();

        final drawNotifier = container.read(drawControllerProvider.notifier);
        drawNotifier.addPoint(const Offset(0.1, 0.1));
        drawNotifier.addPoint(const Offset(0.2, 0.2));
        drawNotifier.commitRoute();
        drawNotifier.addPoint(const Offset(0.3, 0.3));

        expect(
          container.read(drawControllerProvider).currentPoints,
          isNotEmpty,
        );
        expect(
          container.read(drawControllerProvider).completedRoutes,
          isNotEmpty,
        );

        // Simulate picking a different photo B.
        container.read(selectedImageProvider.notifier).select('/photo-b.jpg');
        await tester.pump();

        expect(container.read(drawControllerProvider).currentPoints, isEmpty);
        expect(
          container.read(drawControllerProvider).completedRoutes,
          isEmpty,
        );
      },
    );
  });
}
