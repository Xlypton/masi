// Regression test for the canvas-backdrop UX defect: the topo photo is
// fill-width, so on a tall/short-photo combination a slack strip is painted
// straight through by the Scaffold's own `backgroundColor`. This used to be
// hardcoded to a near-black `_kCanvasBackdrop = Color(0xFF121316)`
// regardless of the app's theme, so the canvas stayed dark even in light
// mode.
//
// `topo_canvas_screen.dart` now sets `Scaffold(backgroundColor:
// colors.ground)` — the SAME theme-derived token the empty-state/
// image-error-state placeholders have always used (`ColoredBox(color:
// colors.ground)`) — so the canvas backdrop follows the theme like every
// other screen: light-theme ground (0xFFF3F1F9) in light mode, dark-theme
// ground (0xFF100D17) in dark mode.
import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/topo/presentation/topo_canvas_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  ProviderContainer buildContainer() {
    final db = AppDatabase(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        nowMsProvider.overrideWithValue(() => 1000),
      ],
    );
    addTearDown(db.close);
    return container;
  }

  testWidgets(
    "TopoCanvasScreen's Scaffold backgroundColor follows the LIGHT theme's "
    'colors.ground (0xFFF3F1F9), not a hardcoded dark backdrop',
    (tester) async {
      final container = buildContainer();
      addTearDown(container.dispose);

      final crud = container.read(libraryCrudRepositoryProvider);
      final area = await crud.createArea('Area');
      final sector = await crud.createSector(area.id, 'Sector');
      final wall = await crud.createWall(sector.id, 'Wall');

      // No photo attached: the real TopoCanvasScreen renders its
      // empty-state placeholder, but the Scaffold itself (and its
      // backgroundColor, which is what this test is about) is present
      // regardless of whether a photo is loaded.
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: MasiTheme.light,
            home: TopoCanvasScreen(wallId: wall.id),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
      expect(scaffold.backgroundColor, MasiColors.light.ground);
      expect(scaffold.backgroundColor, isNot(const Color(0xFF121316)));
    },
  );

  testWidgets(
    "TopoCanvasScreen's Scaffold backgroundColor follows the DARK theme's "
    'colors.ground (0xFF100D17)',
    (tester) async {
      final container = buildContainer();
      addTearDown(container.dispose);

      final crud = container.read(libraryCrudRepositoryProvider);
      final area = await crud.createArea('Area');
      final sector = await crud.createSector(area.id, 'Sector');
      final wall = await crud.createWall(sector.id, 'Wall');

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: MasiTheme.dark,
            home: TopoCanvasScreen(wallId: wall.id),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
      expect(scaffold.backgroundColor, MasiColors.dark.ground);
    },
  );
}
