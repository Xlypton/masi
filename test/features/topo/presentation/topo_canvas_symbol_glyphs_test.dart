// Subtask D (unify on-canvas markers with the masi glyphs): TopoCanvas now
// preloads 4 masi brand-glyph SVGs as ui.Pictures ONCE in
// _TopoCanvasState.initState (see topo_canvas.dart's `_loadSymbolPictures`)
// and hands them to TopoPainter via a new `symbolPictures` param, instead of
// TopoPainter drawing hand-geometry markers that didn't match the draw-mode
// symbol palette's own masi glyphs.
//
// This widget test exercises the REAL async flutter_svg asset decode (not a
// dummy Picture, unlike the plain TopoPainter unit tests in
// topo_painter_golden_test.dart, which don't have a widget-test binding to
// resolve a real asset through) across two points in the widget's lifecycle:
// the very first frame (before the async decode has necessarily completed,
// so TopoPainter must fall back to its hand-drawn geometry without
// throwing) and after `pumpAndSettle` (once the glyph has loaded and
// `setState` swapped it in, triggering one more repaint) -- both must
// complete cleanly with no exception, proving the load-once-outside-paint
// wiring (D1) and the before/after-load fallback (D4) actually work end to
// end, not just against a synthetic dummy Picture.
//
// Mirrors symbol_placement_hint_test.dart's established pattern: a bare
// TopoCanvas under a Scaffold with a nonexistent imagePath (TopoCanvas's
// Image.file errorBuilder swallows the decode failure), fed via
// DrawController's public API rather than the full TopoCanvasScreen +
// seeded wall/photo/DB.

import 'package:climbtopo/app/theme.dart';
import 'package:climbtopo/features/topo/application/draw_controller.dart';
import 'package:climbtopo/features/topo/domain/topo_route.dart';
import 'package:climbtopo/features/topo/presentation/topo_canvas.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'TopoCanvas renders a placed symbol (masi glyph marker) without '
    'throwing both before and after the async SVG glyph load settles, and '
    'disposes cleanly',
    (tester) async {
      const imageSize = Size(400, 300);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = TransformationController();
      addTearDown(controller.dispose);

      final notifier = container.read(drawControllerProvider.notifier);
      notifier.setMode(DrawMode.draw);
      // An in-progress (uncommitted) route with a placed anchor symbol --
      // exercises the exact same TopoPainter._paintSymbol codepath a
      // committed route's symbols use, without needing a real DB/repository
      // write-through (see DrawController.commitRoute's persistence
      // doc) just to get a symbol onto the canvas.
      notifier.addPoint(const Offset(0.2, 0.2));
      notifier.addPoint(const Offset(0.6, 0.6));
      notifier.setActiveSymbol(SymbolType.anchor);
      await notifier.placeSymbol(const Offset(0.5, 0.5));
      expect(
        container.read(drawControllerProvider).currentSymbols,
        hasLength(1),
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
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
        ),
      );

      // First frame: the async masi_anchor.svg decode may not have
      // completed yet -- TopoPainter must fall back to its hand-drawn
      // geometry for the anchor marker rather than throwing or leaving it
      // blank (D4).
      expect(tester.takeException(), isNull);
      expect(find.byType(TopoCanvas), findsOneWidget);

      // Let the real flutter_svg asset decode complete and the resulting
      // setState's repaint happen -- must swap in the masi_anchor glyph
      // picture and repaint without throwing (D1: loaded once outside
      // paint(), consumed as a Map).
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(TopoCanvas), findsOneWidget);

      // Unmounting must dispose the loaded picture(s) cleanly (no
      // exception from _TopoCanvasState.dispose's picture.dispose() loop).
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'TopoCanvas renders a disabledHold marker (feature #43, always '
    'hand-drawn -- no masi asset is mapped for it, so this exercises the '
    "TopoPainter fallback geometry through the real widget, not just "
    'TopoPainter unit tests) without throwing',
    (tester) async {
      const imageSize = Size(400, 300);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = TransformationController();
      addTearDown(controller.dispose);

      final notifier = container.read(drawControllerProvider.notifier);
      notifier.setMode(DrawMode.draw);
      notifier.addPoint(const Offset(0.2, 0.2));
      notifier.addPoint(const Offset(0.6, 0.6));
      notifier.setActiveSymbol(SymbolType.disabledHold);
      await notifier.placeSymbol(const Offset(0.5, 0.5));
      expect(
        container.read(drawControllerProvider).currentSymbols,
        hasLength(1),
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
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
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.byType(TopoCanvas), findsOneWidget);

      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(TopoCanvas), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );
}
