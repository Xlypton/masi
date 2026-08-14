// ROUTE_EDITING_PLAN.md §3.3: an eraser tool joins the symbol palette beside
// Route / Anchor / Bolt / Top / Crux / Off (keyed `symbol-tool-eraser`,
// mirroring the Route tool's `symbol-tool-route` naming since neither is a
// placeable `SymbolType` -- see symbol_palette_bar.dart's class doc).
//
// "Exactly one control is ever lit" used to be expressed entirely as
// `activeSymbol == null` meaning Route (draw_controller.dart's `DrawTool`
// doc), which can't distinguish Route from a third tool. This pins the fix
// directly: activating the eraser must (a) leave `activeSymbol` null, (b)
// visibly deselect every other palette control -- not just Route -- and (c)
// itself get deselected the moment Route or a symbol is chosen instead.
//
// Harness mirrors symbol_palette_off_glyph_test.dart's lightweight
// `ProviderScope`-wrapped `SymbolPaletteBar` (no photo/DB seeding needed:
// `DrawController.build()` is `const DrawState()`, no dependency on a real
// wall), swapped for an explicit `ProviderContainer` +
// `UncontrolledProviderScope` (symbol_palette_route_tool_test.dart's
// pattern) so the test can read `DrawState` back out after each tap. Never
// drives a real image-codec decode -- this widget tree contains no photo at
// all.

import 'package:masi/app/theme.dart';
import 'package:masi/features/topo/application/draw_controller.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
import 'package:masi/features/topo/presentation/symbol_palette_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _testWallId = 'test-wall';

const _routeKey = Key('symbol-tool-route');
const _boltKey = Key('topo-symbol-bolt');
const _eraserKey = Key('symbol-tool-eraser');

/// Every palette control's key, in the order they render -- Route first,
/// then one per [SymbolType], then the eraser last -- used by
/// [_expectOnlySelected] to sweep the whole row.
const _allPaletteKeys = [
  _routeKey,
  Key('topo-symbol-anchor'),
  _boltKey,
  Key('topo-symbol-top'),
  Key('topo-symbol-crux'),
  Key('topo-symbol-disabledHold'),
  _eraserKey,
];

Future<ProviderContainer> _pumpPalette(WidgetTester tester) async {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        // Required: SymbolPaletteBar reads MasiColors.of(context) for its
        // label color, which null-checks the theme extension.
        theme: MasiTheme.light,
        home: const Scaffold(body: SymbolPaletteBar(wallId: _testWallId)),
      ),
    ),
  );
  await tester.pump();
  return container;
}

/// Reads the `BoxDecoration.color` of the `Container` inside the
/// `_SymbolButton` keyed [key] -- non-null (`colorScheme.primaryContainer`)
/// exactly when that control renders SELECTED, null otherwise. Mirrors
/// symbol_palette_bar.dart's `_SymbolButton.build`, which paints exactly
/// this `Container` with `isActive ? colorScheme.primaryContainer : null`.
Color? _decorationColorFor(WidgetTester tester, Key key) {
  final containerWidget = tester.widget<Container>(
    find.descendant(of: find.byKey(key), matching: find.byType(Container)),
  );
  return (containerWidget.decoration as BoxDecoration?)?.color;
}

/// Asserts that, of all seven palette controls, ONLY [expected] renders with
/// a non-null (selected) decoration color -- the "exactly one palette tool
/// is visibly selected at a time" invariant, now spanning three KINDS of
/// control (Route / a SymbolType / the eraser).
void _expectOnlySelected(WidgetTester tester, Key expected) {
  for (final key in _allPaletteKeys) {
    final color = _decorationColorFor(tester, key);
    if (key == expected) {
      expect(
        color,
        isNotNull,
        reason: '$key must render selected (non-null decoration color)',
      );
    } else {
      expect(
        color,
        isNull,
        reason:
            '$key must NOT render selected while $expected is the active '
            'palette tool',
      );
    }
  }
}

void main() {
  testWidgets('the eraser control renders and is tappable', (tester) async {
    await _pumpPalette(tester);

    expect(find.byKey(_eraserKey), findsOneWidget);

    // Must not throw -- proves the control is a real tappable target, not
    // just present in the tree.
    await tester.tap(find.byKey(_eraserKey));
    await tester.pump();
  });

  testWidgets(
    'activating the eraser clears activeSymbol and deselects every other '
    'control',
    (tester) async {
      final container = await _pumpPalette(tester);

      await tester.tap(find.byKey(_eraserKey));
      await tester.pump();

      final state = container.read(drawControllerProvider(_testWallId));
      expect(state.activeTool, DrawTool.eraser);
      expect(
        state.activeSymbol,
        isNull,
        reason:
            'a symbol left active underneath would silently return when '
            'the eraser is switched off (ROUTE_EDITING_PLAN.md §3.3)',
      );
      _expectOnlySelected(tester, _eraserKey);
    },
  );

  testWidgets(
    'activating the eraser while a symbol is active clears that symbol too',
    (tester) async {
      final container = await _pumpPalette(tester);

      await tester.tap(find.byKey(_boltKey));
      await tester.pump();
      expect(
        container.read(drawControllerProvider(_testWallId)).activeSymbol,
        SymbolType.bolt,
      );

      await tester.tap(find.byKey(_eraserKey));
      await tester.pump();

      final state = container.read(drawControllerProvider(_testWallId));
      expect(state.activeTool, DrawTool.eraser);
      expect(state.activeSymbol, isNull);
      _expectOnlySelected(tester, _eraserKey);
    },
  );

  testWidgets('switching to Route turns the eraser back off', (
    tester,
  ) async {
    final container = await _pumpPalette(tester);

    await tester.tap(find.byKey(_eraserKey));
    await tester.pump();
    expect(
      container.read(drawControllerProvider(_testWallId)).activeTool,
      DrawTool.eraser,
    );

    await tester.tap(find.byKey(_routeKey));
    await tester.pump();

    final state = container.read(drawControllerProvider(_testWallId));
    expect(state.activeTool, DrawTool.route);
    expect(state.activeSymbol, isNull);
    _expectOnlySelected(tester, _routeKey);
  });

  testWidgets('switching to a symbol turns the eraser back off', (
    tester,
  ) async {
    final container = await _pumpPalette(tester);

    await tester.tap(find.byKey(_eraserKey));
    await tester.pump();
    expect(
      container.read(drawControllerProvider(_testWallId)).activeTool,
      DrawTool.eraser,
    );

    await tester.tap(find.byKey(_boltKey));
    await tester.pump();

    final state = container.read(drawControllerProvider(_testWallId));
    expect(state.activeTool, DrawTool.symbol);
    expect(state.activeSymbol, SymbolType.bolt);
    _expectOnlySelected(tester, _boltKey);
  });

  testWidgets('tapping the eraser again toggles it back off', (
    tester,
  ) async {
    final container = await _pumpPalette(tester);

    await tester.tap(find.byKey(_eraserKey));
    await tester.pump();
    expect(
      container.read(drawControllerProvider(_testWallId)).activeTool,
      DrawTool.eraser,
    );

    await tester.tap(find.byKey(_eraserKey));
    await tester.pump();

    final state = container.read(drawControllerProvider(_testWallId));
    expect(
      state.activeTool,
      DrawTool.route,
      reason:
          'the eraser toggles the same way SymbolType controls do: tapping '
          'the already-active control returns to Route',
    );
    _expectOnlySelected(tester, _routeKey);
  });
}
