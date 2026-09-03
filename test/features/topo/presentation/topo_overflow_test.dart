import 'package:masi/app/theme.dart';
import 'package:masi/features/topo/application/draw_controller.dart';
import 'package:masi/features/topo/presentation/route_legend.dart';
import 'package:masi/features/topo/presentation/symbol_palette_bar.dart';
import 'package:masi/features/topo/presentation/topo_canvas.dart';
import 'package:masi/features/topo/presentation/topo_canvas_screen.dart';
import 'package:masi/shared/presentation/masi_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// FIX #6 (family-keyed `drawControllerProvider(_testWallId)`): stand-in wallId, paired
/// consistently everywhere this file constructs `TopoCanvasBody`/
/// `SymbolPaletteBar` or reads the provider directly.
const _testWallId = 'test-wall';

/// Regression tests for two layout-overflow bugs (see
/// `~/.claude/plans/topo-overflow-bugs.md`):
///
/// Bug A: `SymbolPaletteBar`'s fixed-height (`kSymbolPaletteBarHeight`) bar
/// overflowed at large `textScaler` values because its icon+label `Column`
/// grew past the bar's fixed slot. The bar must still not overflow at any
/// text scale — that is what this group guards — but the WAY it stays inside
/// its slot has since changed, and so has what "correct" looks like above
/// ~1.3x. The original fix wrapped the whole icon+label group in
/// `FittedBox(fit: scaleDown)`, which kept the bar inside its slot by
/// shrinking the CANVAS TOOL GLYPHS as the system text size grew — an
/// accessibility inversion (measured: 22px at 1.0x → 14.3px at 3.0x). The
/// bar now keeps the glyph at a fixed size and DROPS the text label past
/// `_kSymbolLabelMaxTextScale` (1.3), leaving the `Tooltip` each control
/// already carried to supply both the meaning and the accessibility label —
/// so above that threshold "no label rendered" is the correct outcome, not a
/// failure. See `symbol_palette_bar.dart`'s `_kSymbolLabelMaxTextScale`, and
/// `symbol_palette_text_scale_test.dart` for the full threshold/tap-target
/// matrix; the cases below pin only the no-overflow guarantee plus the
/// contract at 3.0x.
///
/// Bug B: `TopoCanvasBody`'s Column wasn't scrollable, and `RouteLegend`
/// capped its height at 40% of the FULL SCREEN (not the height actually
/// still available below the fixed top-clearance/PhotoSelector/SymbolBar
/// slots) — on a short viewport this could overflow the bottom.
void main() {
  group('Bug A: SymbolPaletteBar overflow at large text scale', () {
    Widget buildPaletteBar(ProviderContainer container, double textScale) {
      return UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: MasiTheme.light,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: const Scaffold(body: SymbolPaletteBar(wallId: _testWallId)),
        ),
      );
    }

    testWidgets(
      'B-A1: no overflow at 3.0x text scale; the labels give way and the '
      'Tooltip carries each symbol instead, with the glyph left full size',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        // See B-A2's note: keep this family member alive so the unmount at
        // teardown can't leave an autoDispose Timer pending.
        container.listen(drawControllerProvider(_testWallId), (_, _) {});

        await tester.pumpWidget(buildPaletteBar(container, 3.0));
        await tester.pumpAndSettle();

        // The original point of this case, unchanged: whatever the bar does
        // about labels, it must not overflow its fixed-height slot.
        expect(tester.takeException(), isNull);

        for (final (label, buttonKey) in const [
          ('Anchor', 'topo-symbol-anchor'),
          ('Bolt', 'topo-symbol-bolt'),
          ('Top', 'topo-symbol-top'),
          ('Crux', 'topo-symbol-crux'),
        ]) {
          expect(
            find.text(label),
            findsNothing,
            reason:
                'past _kSymbolLabelMaxTextScale (1.3) the visible label "$label" '
                'is what gives way — at 3.0x it must not be rendered',
          );
          expect(
            find.byTooltip(label),
            findsOneWidget,
            reason:
                'the Tooltip for "$label" must survive the label drop — it is '
                'what carries the meaning, and the accessibility label, once '
                'the text is gone',
          );

          // The actual regression the label drop exists to prevent: a LARGER
          // accessibility text scale must never shrink the canvas tools.
          // `getRect` resolves through `localToGlobal`, so any ancestor
          // FittedBox scale shows up here — the pre-fix widget's MasiIcon
          // still *reported* 22px while painting at 14.3px.
          final glyph = tester
              .getRect(
                find.descendant(
                  of: find.byKey(Key(buttonKey)),
                  matching: find.byType(MasiIcon),
                ),
              )
              .size;
          expect(
            glyph.width,
            moreOrLessEquals(22.0, epsilon: 0.01),
            reason: '"$label" glyph shrank at 3.0x text scale',
          );
          expect(
            glyph.height,
            moreOrLessEquals(22.0, epsilon: 0.01),
            reason: '"$label" glyph shrank at 3.0x text scale',
          );
        }
      },
    );

    testWidgets(
      'B-A2: no overflow at 1.0x and 2.0x text scale (regression guard '
      'across scales)',
      (tester) async {
        for (final scale in [1.0, 2.0]) {
          final container = ProviderContainer();
          addTearDown(container.dispose);
          // FIX #6 (autoDispose pending-timer gotcha): keep this family
          // member alive via a permanent listener -- both the mid-loop
          // unmount (when the next iteration's `pumpWidget` replaces this
          // tree) and the final-teardown unmount (for the last iteration)
          // would otherwise schedule an autoDispose teardown Timer with no
          // remaining duration-based pump to flush it. See
          // route_legend_gap_test.dart's `_seedRoutes` for the fuller
          // explanation.
          container.listen(drawControllerProvider(_testWallId), (_, _) {});

          await tester.pumpWidget(buildPaletteBar(container, scale));
          await tester.pumpAndSettle();

          expect(
            tester.takeException(),
            isNull,
            reason: 'unexpected overflow/exception at textScale=$scale',
          );
        }
      },
    );
  });

  group('Bug B: TopoCanvasBody short-viewport overflow', () {
    Widget buildBody({
      required ProviderContainer container,
      required TransformationController controller,
      Size imageSize = const Size(400, 300),
    }) {
      return UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: MasiTheme.light,
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) {
                final drawState = ref.watch(drawControllerProvider(_testWallId));
                return TopoCanvasBody(
                  wallId: _testWallId,
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

    void setViewportSize(WidgetTester tester, Size size) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    /// Commits [count] >=2-point routes in-memory (no DB/wall attached, so
    /// `commitRoute`'s persistence write-through is skipped — see
    /// `DrawController.commitRoute`'s doc) and switches to Draw mode, so
    /// both `SymbolPaletteBar` and a multi-row `RouteLegend` are showing.
    void seedRoutesAndDrawMode(ProviderContainer container, int count) {
      final notifier = container.read(drawControllerProvider(_testWallId).notifier);
      for (var i = 0; i < count; i++) {
        final y = 0.1 + i * 0.05;
        notifier.addPoint(Offset(0.1, y));
        notifier.addPoint(Offset(0.2, y + 0.02));
        notifier.commitRoute();
      }
      notifier.setMode(DrawMode.draw);
    }

    testWidgets(
      'B-B1: short viewport (700x320) with >=3 routes and draw mode does '
      'not overflow',
      (tester) async {
        setViewportSize(tester, const Size(700, 320));
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final controller = TransformationController();
        addTearDown(controller.dispose);
        seedRoutesAndDrawMode(container, 3);

        await tester.pumpWidget(
          buildBody(container: container, controller: controller),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'B-B2: even shorter viewport (640x300) with >=3 routes and draw mode '
      'does not overflow',
      (tester) async {
        setViewportSize(tester, const Size(640, 300));
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final controller = TransformationController();
        addTearDown(controller.dispose);
        seedRoutesAndDrawMode(container, 3);

        await tester.pumpWidget(
          buildBody(container: container, controller: controller),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'B-B3: on a normal 800x600 surface the canvas still occupies the '
      'majority of the body (no empty gap, no canvas shrink regression)',
      (tester) async {
        setViewportSize(tester, const Size(800, 600));
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final controller = TransformationController();
        addTearDown(controller.dispose);
        seedRoutesAndDrawMode(container, 3);

        await tester.pumpWidget(
          buildBody(container: container, controller: controller),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);

        final canvasRect = tester.getRect(find.byType(TopoCanvas));
        final legendRect = tester.getRect(
          find.byKey(const Key('topo-route-legend')),
        );

        expect(
          canvasRect.height,
          greaterThan(legendRect.height),
          reason:
              'canvas=$canvasRect legend=$legendRect — the canvas must stay '
              'the majority of the body height on a normal/tall screen',
        );
      },
    );

    testWidgets(
      'B-B5: extreme short viewport (640x200 and 640x180) with >=3 routes '
      'and draw mode does not overflow',
      (tester) async {
        for (final size in [const Size(640, 200), const Size(640, 180)]) {
          setViewportSize(tester, size);
          final container = ProviderContainer();
          addTearDown(container.dispose);
          // FIX #6 (autoDispose pending-timer gotcha): keep both family
          // members alive via permanent listeners -- see
          // route_legend_gap_test.dart's `_seedRoutes` for the fuller
          // explanation.
          container.listen(drawControllerProvider(_testWallId), (_, _) {});
          container.listen(legendExpandedProvider(_testWallId), (_, _) {});
          final controller = TransformationController();
          addTearDown(controller.dispose);
          seedRoutesAndDrawMode(container, 3);

          await tester.pumpWidget(
            buildBody(container: container, controller: controller),
          );
          await tester.pumpAndSettle();

          expect(
            tester.takeException(),
            isNull,
            reason: 'unexpected overflow at viewport size $size',
          );
        }
      },
    );

    testWidgets(
      'B-B6: combined stress — short viewport (700x300) AND 3.0x text '
      'scale together, with >=3 routes and draw mode, does not overflow',
      (tester) async {
        setViewportSize(tester, const Size(700, 300));
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final controller = TransformationController();
        addTearDown(controller.dispose);
        seedRoutesAndDrawMode(container, 3);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: MasiTheme.light,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(3.0)),
                child: child!,
              ),
              home: Scaffold(
                body: Consumer(
                  builder: (context, ref, _) {
                    final drawState = ref.watch(drawControllerProvider(_testWallId));
                    return TopoCanvasBody(
                      wallId: _testWallId,
                      imagePath: '/nonexistent/test-topo.jpg',
                      imageSize: const Size(400, 300),
                      drawState: drawState,
                      transformationController: controller,
                    );
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          tester.takeException(),
          isNull,
          reason:
              'unexpected overflow at 700x300 combined with 3.0x text scale',
        );
      },
    );
  });
}
