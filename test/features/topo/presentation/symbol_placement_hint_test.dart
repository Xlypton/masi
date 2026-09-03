import 'package:masi/app/theme.dart';
import 'package:masi/features/topo/application/draw_controller.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
import 'package:masi/features/topo/presentation/symbol_palette_bar.dart';
import 'package:masi/features/topo/presentation/topo_canvas.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// FIX #6 (family-keyed `drawControllerProvider(_testWallId)`): stand-in wallId, paired
/// consistently everywhere this file constructs `TopoCanvas`/
/// `SymbolPaletteBar` or reads the provider directly.
const _testWallId = 'test-wall';

/// Widget-level regression test for the "silent no-op when placing a topo
/// symbol with no route selected" bug (see
/// lib/features/topo/application/draw_controller.dart's `placeSymbol` doc
/// and lib/features/topo/presentation/topo_canvas.dart's `_beginInteraction`).
///
/// Pumps a bare [TopoCanvas] + [SymbolPaletteBar] directly under a
/// [Scaffold] (mirroring the proven "SymbolPaletteBar + TopoCanvas symbol
/// placement" group in test/widget_test.dart) rather than the full
/// [TopoCanvasScreen] + seeded wall/photo/DB: the SnackBar wiring this test
/// asserts lives entirely in `_beginInteraction`, which only needs a real
/// [TopoCanvas] under a [Scaffold] (for [ScaffoldMessenger]) to exercise --
/// no wall/photo/DB seeding changes that codepath, and this avoids the
/// undriveable-under-fake-time real image decode entirely (imagePath here
/// never resolves; TopoCanvas's `errorBuilder` swallows that).
void main() {
  testWidgets(
    'S5: activating a symbol and tapping the canvas with zero routes shows '
    'a "draw a route first" SnackBar hint instead of silently no-oping',
    (tester) async {
      const imageSize = Size(400, 300);
      tester.view.physicalSize = const Size(
        400,
        300 + kSymbolPaletteBarHeight,
      );
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = TransformationController();
      addTearDown(controller.dispose);

      // Draw mode, zero routes -- exactly the "user activates a symbol
      // before ever drawing a route" scenario the bug report describes.
      container.read(drawControllerProvider(_testWallId).notifier).setMode(DrawMode.draw);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: MasiTheme.light,
            home: Scaffold(
              body: Column(
                children: [
                  const SymbolPaletteBar(wallId: _testWallId),
                  Expanded(
                    child: TopoCanvas(
                      wallId: _testWallId,
                      imagePath: '/nonexistent/test-topo.jpg',
                      imageSize: imageSize,
                      transformationController: controller,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(container.read(drawControllerProvider(_testWallId)).routes, isEmpty);
      expect(find.byType(SnackBar), findsNothing);

      await tester.tap(find.byKey(const Key('topo-symbol-bolt')));
      await tester.pump();
      expect(
        container.read(drawControllerProvider(_testWallId)).activeSymbol,
        SymbolType.bolt,
      );

      // Tap the canvas surface via the real gesture layer
      // (topo-draw-gesture-detector, wrapped by tapping inside TopoCanvas's
      // bounds): with zero routes, placeSymbol must return
      // noRouteAvailable and _beginInteraction must surface a SnackBar hint
      // instead of silently doing nothing.
      await tester.tapAt(const Offset(200, 150 + kSymbolPaletteBarHeight));
      await tester.pumpAndSettle();

      expect(find.byType(SnackBar), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.textContaining('Draw a route first'),
        ),
        findsOneWidget,
      );

      // No route existed to place onto, so state must be unchanged: no
      // route gained a symbol (there are none), and nothing got selected.
      expect(container.read(drawControllerProvider(_testWallId)).routes, isEmpty);
      expect(container.read(drawControllerProvider(_testWallId)).selectedRouteId, isNull);
    },
  );

  testWidgets(
    'U5: with zero committed routes but an in-progress route present '
    '(currentPoints non-empty), placing a symbol succeeds onto '
    'currentSymbols and shows NO "draw a route first" SnackBar -- the hint '
    'precondition is routes.isEmpty && currentPoints.isEmpty, not just '
    'routes.isEmpty',
    (tester) async {
      const imageSize = Size(400, 300);
      tester.view.physicalSize = const Size(
        400,
        300 + kSymbolPaletteBarHeight,
      );
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = TransformationController();
      addTearDown(controller.dispose);

      final notifier = container.read(drawControllerProvider(_testWallId).notifier);
      notifier.setMode(DrawMode.draw);
      // An in-progress (uncommitted) route: routes stays empty, but
      // currentPoints is not.
      notifier.addPoint(const Offset(0.2, 0.2));
      notifier.addPoint(const Offset(0.3, 0.3));

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: MasiTheme.light,
            home: Scaffold(
              body: Column(
                children: [
                  const SymbolPaletteBar(wallId: _testWallId),
                  Expanded(
                    child: TopoCanvas(
                      wallId: _testWallId,
                      imagePath: '/nonexistent/test-topo.jpg',
                      imageSize: imageSize,
                      transformationController: controller,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(container.read(drawControllerProvider(_testWallId)).routes, isEmpty);
      expect(container.read(drawControllerProvider(_testWallId)).currentPoints, isNotEmpty);
      expect(find.byType(SnackBar), findsNothing);

      await tester.tap(find.byKey(const Key('topo-symbol-bolt')));
      await tester.pump();
      expect(
        container.read(drawControllerProvider(_testWallId)).activeSymbol,
        SymbolType.bolt,
      );

      await tester.tapAt(const Offset(200, 150 + kSymbolPaletteBarHeight));
      await tester.pumpAndSettle();

      expect(find.byType(SnackBar), findsNothing);
      expect(
        container.read(drawControllerProvider(_testWallId)).currentSymbols,
        hasLength(1),
      );
      expect(container.read(drawControllerProvider(_testWallId)).routes, isEmpty);
    },
  );
}
