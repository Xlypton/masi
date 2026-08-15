// The "Off" tool in [SymbolPaletteBar] must show the SAME prohibition sign
// the marker it places is drawn as (user report, 2026-08-11: "the off drawing
// too should have the same banned sign as on the drawing").
//
// It used to borrow `masi_close.svg` — an X — because the brand set had no
// "off/no/ban" glyph, while `TopoPainter._paintSymbol` hand-drew a circle
// with a diagonal slash for the marker itself. So the palette advertised one
// symbol and the canvas drew another, and the X additionally read as
// "close/cancel" sitting in a row of drawing tools. `masi_ban.svg` was added
// for this, with the painter's own geometry: a circle of radius 8 in a 24x24
// box, slashed NW->SE at 0.707r.
//
// The assertion is on the asset NAME rather than on rendered pixels: MasiIcon
// resolves `assets/icons/masi/masi_<name>.svg`, so the name IS the identity of
// the glyph, and an SVG's rasterization is not something a widget test can
// meaningfully compare without a golden (which this project's goldens do not
// currently cover on every platform).

import 'package:masi/app/theme.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
import 'package:masi/features/topo/presentation/symbol_palette_bar.dart';
import 'package:masi/shared/presentation/masi_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _testWallId = 'test-wall';

Future<void> _pumpPalette(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        // Required: SymbolPaletteBar reads MasiColors.of(context) for its
        // label color, which null-checks the theme extension.
        theme: MasiTheme.light,
        home: const Scaffold(body: SymbolPaletteBar(wallId: _testWallId)),
      ),
    ),
  );
  await tester.pump();
}

String _iconNameIn(WidgetTester tester, Key buttonKey) {
  final icon = tester.widget<MasiIcon>(
    find.descendant(of: find.byKey(buttonKey), matching: find.byType(MasiIcon)),
  );
  return icon.name;
}

void main() {
  testWidgets(
    'the Off tool renders the ban glyph, not the close/X glyph',
    (tester) async {
      await _pumpPalette(tester);

      expect(
        _iconNameIn(tester, const Key('topo-symbol-disabledHold')),
        'ban',
        reason:
            'the palette glyph must be the prohibition sign the marker is '
            'drawn as — an X reads as "cancel" in a row of drawing tools',
      );
    },
  );

  testWidgets(
    'no other palette tool borrows the ban glyph — it means exactly one '
    'thing on this bar',
    (tester) async {
      await _pumpPalette(tester);

      for (final type in SymbolType.values) {
        if (type == SymbolType.disabledHold) continue;
        expect(
          _iconNameIn(tester, Key('topo-symbol-${type.name}')),
          isNot('ban'),
          reason: '${type.name} must not share the Off tool\'s glyph',
        );
      }
      expect(_iconNameIn(tester, const Key('symbol-tool-route')), isNot('ban'));
    },
  );
}
