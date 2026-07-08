import 'package:climbtopo/app/app.dart';
import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/core/db/database_provider.dart';
import 'package:climbtopo/features/topo/application/draw_controller.dart';
import 'package:climbtopo/features/topo/domain/topo_route.dart';
import 'package:climbtopo/features/topo/presentation/route_legend.dart';
import 'package:climbtopo/features/topo/presentation/symbol_palette_bar.dart';
import 'package:climbtopo/features/topo/presentation/topo_canvas.dart';
import 'package:climbtopo/features/topo/presentation/topo_canvas_screen.dart';
import 'package:climbtopo/features/topo/presentation/topo_painter.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('App renders ClimbTopo title', (WidgetTester tester) async {
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
    // Allow GoRouter and MaterialApp.router to settle.
    await tester.pumpAndSettle();

    expect(find.text('ClimbTopo'), findsOneWidget);
  });

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
    });

    testWidgets(
      'A3: undo/redo/commit toolbar buttons invoke the draw controller',
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
            child: const MaterialApp(home: TopoCanvasScreen()),
          ),
        );
        await tester.pumpAndSettle();

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
        await tester.pump();
        expect(container.read(drawControllerProvider).currentPoints, isEmpty);
        expect(container.read(drawControllerProvider).routes.length, 1);

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

        container.read(drawControllerProvider.notifier).setMode(DrawMode.draw);
        await tester.pump();

        expect(viewer().panEnabled, isFalse);
        expect(viewer().scaleEnabled, isFalse);

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
          reason:
              'minScale must allow zooming out far enough to see the '
              'entire wall photo',
        );

        expect(
          controller.value.getMaxScaleOnAxis(),
          closeTo(fitScale, epsilon),
          reason:
              'the controller should be initialized to fitScale on '
              'first layout so the whole image is visible without any '
              'manual zoom',
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

  group('TopoCanvasBody: symbol bar mode visibility (Fix 2)', () {
    // TopoCanvasBody is pumped directly (mirroring how TopoCanvas itself is
    // tested above) with a live-watched drawState via a Consumer, an
    // injected fixed imageSize, and an identity TransformationController —
    // no real, decodable image file is needed. TopoCanvasScreen's own
    // _buildCanvasArea only ever constructs this same widget once the real
    // async image decode resolves, so exercising TopoCanvasBody directly
    // covers Fix 2's actual conditional (`if (drawState.mode ==
    // DrawMode.draw) const SymbolPaletteBar()`).
    Widget buildBody({
      required ProviderContainer container,
      required TransformationController controller,
      Size imageSize = const Size(400, 300),
    }) {
      return UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) {
                final drawState = ref.watch(drawControllerProvider);
                return TopoCanvasBody(
                  imagePath: '/nonexistent/test-topo.jpg',
                  imageSize: imageSize,
                  drawState: drawState,
                  transformationController: controller,
                );
              },
            ),
          ),
        ),
      );
    }

    testWidgets(
      'the symbol bar is present in draw mode and absent in view mode',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final controller = TransformationController();
        addTearDown(controller.dispose);

        final notifier = container.read(drawControllerProvider.notifier);

        await tester.pumpWidget(
          buildBody(container: container, controller: controller),
        );
        await tester.pump();

        // Default mode is view: the symbol bar must be hidden.
        expect(container.read(drawControllerProvider).mode, DrawMode.view);
        expect(find.byType(SymbolPaletteBar), findsNothing);

        // Switching to draw mode shows it.
        notifier.setMode(DrawMode.draw);
        await tester.pump();

        expect(find.byType(SymbolPaletteBar), findsOneWidget);

        // Switching back to view mode hides it again, without clearing
        // activeSymbol.
        notifier.setActiveSymbol(SymbolType.anchor);
        await tester.pump();

        notifier.setMode(DrawMode.view);
        await tester.pump();

        expect(find.byType(SymbolPaletteBar), findsNothing);
        expect(
          container.read(drawControllerProvider).activeSymbol,
          SymbolType.anchor,
          reason: 'peeking at view mode must not clear the chosen symbol',
        );
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
          child: const MaterialApp(home: Scaffold(body: RouteLegend())),
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
        // 300 (imageSize height) + 56 (SymbolPaletteBar height) so the
        // Expanded TopoCanvas gets exactly imageSize as its viewport,
        // keeping the identity-transform coordinate math below valid.
        setViewportSize(tester, const Size(400, 356));
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

        expect(container.read(drawControllerProvider).activeSymbol, isNull);

        await tester.tap(find.byKey(const Key('topo-symbol-anchor')));
        await tester.pump();

        expect(
          container.read(drawControllerProvider).activeSymbol,
          SymbolType.anchor,
        );

        // TopoCanvas sits below the 56px-tall SymbolPaletteBar in the
        // Column, so a global tap's localPosition *within TopoCanvas* is
        // offset by that 56px: tapping global (200, 206) lands at local
        // (200, 150) -> scene (200, 150) -> percent (0.5, 0.5).
        await tester.tapAt(const Offset(200, 206));
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
      'switching between symbol controls only activates one at a time',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: Scaffold(body: SymbolPaletteBar())),
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
}
