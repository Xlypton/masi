// A5 (Lane A, dump-batch #25-30 plan, item #27): the symbol palette's
// leading "Route" tool (`Key('symbol-tool-route')`) represents the
// route-LINE draw action -- `DrawState.activeSymbol == null` -- rather than
// a new `SymbolType` member (see symbol_palette_bar.dart's class doc for why
// adding one was deliberately avoided). This test drives the REAL
// `TopoCanvasScreen` into draw mode via the mode toggle (rather than poking
// `DrawController` directly) and asserts:
//  - Route renders SELECTED by default on entering draw mode --
//    `DrawState.activeSymbol` defaults to null (draw_controller.dart), so no
//    explicit reset-on-mode-change wiring is needed for this to hold.
//  - Tapping a `SymbolType` control (bolt) selects it and visibly deselects
//    Route.
//  - Tapping Route re-selects it and clears `activeSymbol` back to null.
// "Visibly selected" is checked two ways at every step: the controller's
// `activeSymbol` (the source of truth) AND the actual rendered
// `BoxDecoration.color` of every one of the seven palette controls, to prove
// the "exactly one control is ever visibly selected" invariant holds across
// the whole row, not just for the two controls under test.
//
// Harness mirrors legend_expand_collapse_test.dart's
// `_seedWallWithPhotoAndRoute` (real in-memory DB + a photo attached via
// `LibraryCrudRepository.attachPhotoToWall`, inside `tester.runAsync` so the
// attach's own async work never touches fake time) and
// `TopoCanvasScreen(debugInitialImageSize: ...)`, the documented seam that
// lets the real screen reach draw mode with a photo "loaded" without ever
// driving a real image-codec decode under fake-async (see this repo's
// CLAUDE.md "Never drive a real image-codec decode in widget tests").

import 'package:climbtopo/app/theme.dart';
import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/core/db/database_provider.dart';
import 'package:climbtopo/features/library/application/library_providers.dart';
import 'package:climbtopo/features/topo/application/draw_controller.dart';
import 'package:climbtopo/features/topo/domain/topo_route.dart';
import 'package:climbtopo/features/topo/presentation/topo_canvas_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

/// Creates a real in-memory DB + ProviderContainer + a persisted
/// Area/Sector/Wall with a photo attached and loaded into
/// [DrawController] -- mirrors
/// `legend_expand_collapse_test.dart:_seedWallWithPhotoAndRoute`, minus the
/// committed route (this test never needs one: the palette's selection
/// state is orthogonal to whether any route exists yet).
Future<({AppDatabase db, ProviderContainer container, String wallId})>
_seedWallWithPhoto(WidgetTester tester) async {
  final db = AppDatabase(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      nowMsProvider.overrideWithValue(() => 1000),
    ],
  );
  final crud = container.read(libraryCrudRepositoryProvider);
  final area = await crud.createArea('Area');
  final sector = await crud.createSector(area.id, 'Sector');
  final wall = await crud.createWall(sector.id, 'Wall');

  late String photoId;
  await tester.runAsync(() async {
    photoId = await crud.attachPhotoToWall(
      wall.id,
      XFile('/tmp/symbol-palette-route-tool-photo.jpg'),
      400,
      300,
    );
  });
  await container
      .read(drawControllerProvider(wall.id).notifier)
      .loadForWall(wall.id, photoId);

  return (db: db, container: container, wallId: wall.id);
}

const _routeKey = Key('symbol-tool-route');
const _boltKey = Key('topo-symbol-bolt');

/// Every palette control's key, in the order they render -- Route first,
/// then one per [SymbolType] -- used by [_expectOnlySelected] to sweep the
/// whole row.
const _allPaletteKeys = [
  _routeKey,
  Key('topo-symbol-anchor'),
  _boltKey,
  Key('topo-symbol-top'),
  Key('topo-symbol-crux'),
  Key('topo-symbol-rest'),
  // Feature #43: the per-route disabled/excluded-hold marker tool.
  Key('topo-symbol-disabledHold'),
];

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
/// is visibly selected at a time" invariant (A3).
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
  testWidgets(
    'A5: entering draw mode selects Route by default; tapping bolt selects '
    'bolt & deselects Route; tapping Route re-selects it & clears '
    'activeSymbol',
    (tester) async {
      final seeded = await _seedWallWithPhoto(tester);
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: seeded.container,
          child: MaterialApp(
            theme: MasiTheme.light,
            home: TopoCanvasScreen(
              wallId: seeded.wallId,
              debugInitialImageSize: const Size(400, 300),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Sanity: the real screen opens in view mode, where the (draw-mode
      // only) palette -- and so the Route tool -- isn't mounted at all.
      expect(find.byKey(_routeKey), findsNothing);

      await tester.tap(find.byKey(const Key('topo-mode-toggle')));
      await tester.pumpAndSettle();

      // Entering draw mode: Route selected by default. DrawState
      // .activeSymbol defaults to null (draw_controller.dart) and nothing
      // about toggling modes touches it, so this holds with no dedicated
      // reset-on-enter-draw-mode wiring.
      expect(
        seeded.container.read(drawControllerProvider(seeded.wallId)).activeSymbol,
        isNull,
      );
      _expectOnlySelected(tester, _routeKey);

      // Tapping bolt selects it and visibly deselects Route.
      await tester.tap(find.byKey(_boltKey));
      await tester.pump();

      expect(
        seeded.container.read(drawControllerProvider(seeded.wallId)).activeSymbol,
        SymbolType.bolt,
      );
      _expectOnlySelected(tester, _boltKey);

      // Tapping Route re-selects it and clears activeSymbol back to null.
      await tester.tap(find.byKey(_routeKey));
      await tester.pump();

      expect(
        seeded.container.read(drawControllerProvider(seeded.wallId)).activeSymbol,
        isNull,
      );
      _expectOnlySelected(tester, _routeKey);
    },
  );
}
