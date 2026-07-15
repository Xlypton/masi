// Regression test for the "blue smear" chrome-pill defect: GlassChrome's
// DEFAULT (non-strong) path used to render ONLY a semi-transparent
// `colors.chrome`-tinted card over a blur — no opaque scrim — so a
// strongly-saturated region of photo behind a floating pill (top nav pill,
// bottom undo/redo/commit cluster, symbol-palette bar) bled through as a
// hard, saturated color smear. `strong: true` (used by RouteLegend) already
// added a near-opaque `colors.surface` scrim UNDER the tinted card and looks
// clean — that's the quality bar this fix brings the default path up to.
//
// Assertions (A3.1-A3.4 from the fix brief):
//  - non-strong (default) GlassChrome now ALSO renders a `DecoratedBox`
//    scrim of `colors.surface`, at alpha ~0.78 (enough to kill saturated
//    smears, still visibly translucent/glassy) — where before there was
//    none.
//  - strong GlassChrome's scrim alpha stays 0.92, unchanged.
//  - in both cases the child content still renders (legibility intact).

import 'package:climbtopo/app/theme.dart';
import 'package:climbtopo/features/topo/presentation/canvas_chrome.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Finds the (single) [DecoratedBox] inside [glassChromeFinder] whose
/// [BoxDecoration.color] matches [surface]'s RGB channels (ignoring alpha —
/// that's exactly the axis under test). Distinguishing from the OTHER
/// `DecoratedBox`/`Container` in the tree (the `colors.chrome`-tinted card,
/// a visibly different RGB in both themes) this way means the test finds
/// the scrim specifically, not just any decorated box.
Finder _surfaceScrimFinder(WidgetTester tester, Finder glassChromeFinder, Color surface) {
  final candidates = find.descendant(
    of: glassChromeFinder,
    matching: find.byType(DecoratedBox),
  );
  final matches = <Element>[];
  for (final element in candidates.evaluate()) {
    final widget = element.widget as DecoratedBox;
    final decoration = widget.decoration;
    if (decoration is BoxDecoration) {
      final color = decoration.color;
      if (color != null &&
          color.r == surface.r &&
          color.g == surface.g &&
          color.b == surface.b) {
        matches.add(element);
      }
    }
  }
  expect(
    matches.length,
    1,
    reason:
        'expected exactly one DecoratedBox scrim tinted with colors.surface '
        '(ignoring alpha) inside GlassChrome; found ${matches.length}',
  );
  return find.byWidgetPredicate(
    (w) => identical(w, matches.single.widget),
  );
}

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: MasiTheme.light,
    home: Scaffold(body: Center(child: child)),
  );
}

void main() {
  group('GlassChrome content-invariant surface scrim', () {
    testWidgets(
      'A3.2/A3.4: non-strong (default) GlassChrome now renders a '
      'colors.surface scrim at alpha ~0.78, and the child still renders',
      (tester) async {
        await tester.pumpWidget(
          _wrap(const GlassChrome(child: Text('x'))),
        );
        await tester.pump();

        final context = tester.element(find.byType(GlassChrome));
        final colors = MasiColors.of(context);

        final scrimFinder = _surfaceScrimFinder(
          tester,
          find.byType(GlassChrome),
          colors.surface,
        );
        final decoratedBox = tester.widget<DecoratedBox>(scrimFinder);
        final decoration = decoratedBox.decoration as BoxDecoration;
        final alpha = decoration.color!.a;

        expect(
          alpha,
          allOf(greaterThanOrEqualTo(0.75), lessThanOrEqualTo(0.82)),
          reason:
              'non-strong GlassChrome must now carry a surface scrim strong '
              'enough (~0.78) to kill saturated photo-color smears, but '
              'still short of the strong path\'s near-opaque 0.92',
        );

        expect(
          find.text('x'),
          findsOneWidget,
          reason: 'A3.4: the child content must still render through the scrim',
        );
      },
    );

    testWidgets(
      'A3.3/A3.4: strong GlassChrome keeps its scrim alpha at 0.92 '
      '(unchanged), and the child still renders',
      (tester) async {
        await tester.pumpWidget(
          _wrap(const GlassChrome(strong: true, child: Text('x'))),
        );
        await tester.pump();

        final context = tester.element(find.byType(GlassChrome));
        final colors = MasiColors.of(context);

        final scrimFinder = _surfaceScrimFinder(
          tester,
          find.byType(GlassChrome),
          colors.surface,
        );
        final decoratedBox = tester.widget<DecoratedBox>(scrimFinder);
        final decoration = decoratedBox.decoration as BoxDecoration;
        final alpha = decoration.color!.a;

        expect(
          alpha,
          closeTo(0.92, 0.01),
          reason: 'strong GlassChrome\'s look must stay unchanged at alpha 0.92',
        );

        expect(
          find.text('x'),
          findsOneWidget,
          reason: 'A3.4: the child content must still render through the scrim',
        );
      },
    );
  });
}
