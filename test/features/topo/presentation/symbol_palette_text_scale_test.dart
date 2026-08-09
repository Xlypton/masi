// Regression tests for the symbol palette's ACCESSIBILITY INVERSION: the
// canvas tool glyphs used to get SMALLER as the user turned the system text
// size UP.
//
// Cause (see symbol_palette_bar.dart's `_kSymbolLabelMaxTextScale`): the
// icon+label group was wrapped as a unit in `FittedBox(fit: scaleDown)` to
// keep it inside the bar's deliberately fixed `kSymbolPaletteBarHeight`
// slot; six controls share the bar's width, so a scaled-up label is a WIDER
// label, and `scaleDown` shrank the glyph along with it. Measured against
// the pre-fix widget (this file's own harness, 800px-wide surface): the
// 22px glyph rendered at 21.2px at 2.0x text scale and 14.3px at 3.0x.
//
// The fix drops the LABEL past a text-scale threshold and leaves the glyph
// alone at a fixed size, letting the `Tooltip` every control already carries
// supply the meaning (and the accessibility label). These tests pin all
// three halves of that: the glyph never shrinks, the labels do drop, and
// 1.0x renders byte-for-byte the same geometry it did before the change.
//
// Deliberately NOT changed and NOT retested here: `kSymbolPaletteBarHeight`
// itself, which four other test files convert into literal tap coordinates.

import 'package:masi/app/theme.dart';
import 'package:masi/features/topo/application/draw_controller.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
import 'package:masi/features/topo/presentation/symbol_palette_bar.dart';
import 'package:masi/shared/presentation/masi_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// FIX #6 (family-keyed `drawControllerProvider(_testWallId)`): stand-in
/// wallId, paired consistently everywhere this file constructs
/// `SymbolPaletteBar` or reads the provider directly.
const _testWallId = 'test-wall';

/// Every visible control label, in row order (Route tool first — see
/// `SymbolPaletteBar`'s class doc for why it isn't a `SymbolType`).
const _allLabels = ['Route', 'Anchor', 'Bolt', 'Top', 'Crux', 'Off'];

Widget _buildBar(ProviderContainer container, double textScale) {
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

/// A fresh container per pump, with a permanent listener so unmounting the
/// tree can't leave an autoDispose teardown Timer pending with no remaining
/// duration-based pump to flush it (the gotcha documented at length in
/// `route_legend_gap_test.dart`'s `_seedRoutes`).
ProviderContainer _container(WidgetTester tester) {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  container.listen(drawControllerProvider(_testWallId), (_, _) {});
  return container;
}

/// On-SCREEN size of a control's glyph. `getRect` resolves through
/// `localToGlobal`, so any ancestor `FittedBox` scale is applied — which is
/// the entire point: the pre-fix widget's `MasiIcon` render box still
/// *reported* 22px while painting at 14.3px.
Size _glyphSize(WidgetTester tester, String buttonKey) {
  return tester
      .getRect(
        find.descendant(
          of: find.byKey(Key(buttonKey)),
          matching: find.byType(MasiIcon),
        ),
      )
      .size;
}

/// Asserts a control's glyph is painting at its full, unscaled 22px.
///
/// Compared with a tolerance rather than against `const Size(22, 22)`: on a
/// surface whose width doesn't divide evenly by the six controls the glyph's
/// global rect lands on a fractional offset and `Size ==` fails on a
/// sub-ulp difference that prints, unhelpfully, as `22.0` vs `22.0`.
void _expectFullSizeGlyph(
  WidgetTester tester,
  String buttonKey, {
  required String reason,
}) {
  final size = _glyphSize(tester, buttonKey);
  expect(size.width, moreOrLessEquals(22.0, epsilon: 0.01), reason: reason);
  expect(size.height, moreOrLessEquals(22.0, epsilon: 0.01), reason: reason);
}

void main() {
  group('SymbolPaletteBar at large text scales', () {
    testWidgets(
      'T1: the glyph never shrinks as text scale grows (pre-fix: 22 → 21.2 '
      '→ 14.3px)',
      (tester) async {
        for (final scale in [1.0, 1.3, 1.5, 2.0, 3.0]) {
          await tester.pumpWidget(_buildBar(_container(tester), scale));
          await tester.pumpAndSettle();

          expect(
            tester.takeException(),
            isNull,
            reason: 'unexpected overflow/exception at textScale=$scale',
          );
          for (final key in ['symbol-tool-route', 'topo-symbol-anchor']) {
            _expectFullSizeGlyph(
              tester,
              key,
              reason:
                  '$key glyph must stay 22px on screen at textScale=$scale — '
                  'a LARGER accessibility text size must never shrink the '
                  'canvas tools',
            );
          }
        }
      },
    );

    testWidgets(
      'T2: labels show up to the threshold and drop above it, with the '
      'Tooltip still carrying the meaning',
      (tester) async {
        // At and below `_kSymbolLabelMaxTextScale` (1.3) every label shows.
        for (final scale in [1.0, 1.3]) {
          await tester.pumpWidget(_buildBar(_container(tester), scale));
          await tester.pumpAndSettle();
          for (final label in _allLabels) {
            expect(
              find.text(label),
              findsOneWidget,
              reason: 'label "$label" must still show at textScale=$scale',
            );
          }
        }

        // Above it the visible labels give way — but every control keeps its
        // Tooltip, which is both the meaning and the accessibility label.
        for (final scale in [1.4, 2.0, 3.0]) {
          await tester.pumpWidget(_buildBar(_container(tester), scale));
          await tester.pumpAndSettle();
          for (final label in _allLabels) {
            expect(
              find.text(label),
              findsNothing,
              reason: 'label "$label" must drop at textScale=$scale',
            );
            expect(
              find.byTooltip(label),
              findsOneWidget,
              reason:
                  'the Tooltip for "$label" must survive the label drop — it '
                  'is what carries the meaning once the text is gone',
            );
          }
        }
      },
    );

    testWidgets(
      'T3: at 1.0x the bar renders exactly as it did before the fix',
      (tester) async {
        await tester.pumpWidget(_buildBar(_container(tester), 1.0));
        await tester.pumpAndSettle();

        // Measured on the PRE-fix widget on this same 800x600 default
        // surface: glyph 22.0x22.0, control 130.3x51.0, label 69.0x15.0.
        // Widths are font-metric dependent, so only the heights and the
        // glyph (which is asset-sized, not font-sized) are pinned tightly.
        _expectFullSizeGlyph(
          tester,
          'topo-symbol-anchor',
          reason: 'the glyph is unscaled at 1.0x, before and after the fix',
        );
        expect(
          tester.getRect(find.byKey(const Key('topo-symbol-anchor'))).height,
          moreOrLessEquals(51.0, epsilon: 0.01),
          reason:
              'the control height at 1.0x must be unchanged from the pre-fix '
              'measurement — the min-height floor and the label drop are '
              'both meant to be inert here',
        );
        expect(
          tester.getRect(find.text('Anchor')).height,
          moreOrLessEquals(15.0, epsilon: 0.01),
          reason: 'the label must not be scaled at all at 1.0x',
        );
      },
    );

    testWidgets(
      'T4: the tap target never falls below 44pt, and the control still '
      'works once its label is gone',
      (tester) async {
        for (final scale in [1.0, 3.0]) {
          final container = _container(tester);
          await tester.pumpWidget(_buildBar(container, scale));
          await tester.pumpAndSettle();

          expect(
            tester.getRect(find.byKey(const Key('topo-symbol-anchor'))).height,
            greaterThanOrEqualTo(44.0),
            reason: 'tap target below 44pt at textScale=$scale',
          );

          await tester.tap(find.byKey(const Key('topo-symbol-anchor')));
          await tester.pumpAndSettle();
          expect(
            container.read(drawControllerProvider(_testWallId)).activeSymbol,
            SymbolType.anchor,
            reason:
                'tapping a label-less control must still select its symbol '
                '(textScale=$scale)',
          );
        }
      },
    );

    testWidgets(
      'T5: a narrow (320pt) phone-width surface does not overflow at any '
      'scale, and still does not shrink the glyphs',
      (tester) async {
        tester.view.physicalSize = const Size(320, 600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        for (final scale in [1.0, 1.3, 3.0]) {
          await tester.pumpWidget(_buildBar(_container(tester), scale));
          await tester.pumpAndSettle();

          expect(
            tester.takeException(),
            isNull,
            reason: 'unexpected overflow at 320pt wide, textScale=$scale',
          );
          _expectFullSizeGlyph(
            tester,
            'topo-symbol-anchor',
            reason: 'glyph shrank on a narrow surface at textScale=$scale',
          );
        }
      },
    );
  });
}
