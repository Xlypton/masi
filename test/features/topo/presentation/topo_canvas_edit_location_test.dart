// Tests for the canvas screen's own "Edit location"/"Set location" button
// (`topo-edit-location-button`) — the canvas-screen counterpart to
// `topos_screen.dart`'s overflow-menu "Set location" item, which used to be
// the ONLY way to reach this flow. Mirrors that file's own "S-L" test group
// (see `topos_screen_test.dart`) for the picker-interaction pattern: a
// `_NoopTileProvider` (never touches the network) plus an injected
// `MapController` (directly inspectable, via `TopoCanvasScreen`'s own
// `setLocationTileProvider`/`setLocationMapController` test seams — mirroring
// `ToposScreen`'s identically-named/-shaped fields).

import 'dart:convert';

import 'package:climbtopo/app/theme.dart';
import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/core/db/database_provider.dart';
import 'package:climbtopo/features/library/application/library_providers.dart';
import 'package:climbtopo/features/topo/presentation/topo_canvas_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A tiny valid PNG's bytes, used by [_NoopTileProvider] below. Copied from
/// `topos_screen_test.dart`'s identical fixture (itself copied from
/// `community_screen_test.dart`) — each of this trio of test files keeps its
/// own private copy rather than sharing one, matching the existing pattern.
final _tinyPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY'
  '42YAAAAASUVORK5CYII=',
);

/// A tile provider that never performs any network/file I/O: every tile
/// request resolves synchronously to the same tiny in-memory image. Copied
/// from `topos_screen_test.dart`'s identical (library-private) class — wired
/// into the "Set location" picker this file opens, so its `FlutterMap`'s
/// `TileLayer` can never attempt a real network fetch under `flutter_test`
/// (see CLAUDE.md: "never hit the network in a widget test").
class _NoopTileProvider extends TileProvider {
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    return MemoryImage(_tinyPngBytes);
  }
}

/// Creates a real in-memory DB + [ProviderContainer] + a persisted
/// Area/Sector/Wall, mirroring the harness pattern used throughout this
/// directory (e.g. `canvas_chrome_gating_test.dart`'s `_seedWall`).
Future<({AppDatabase db, ProviderContainer container, String wallId})>
_seedWall() async {
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
  return (db: db, container: container, wallId: wall.id);
}

/// Runs [body] inside [WidgetTester.runAsync] and returns its result —
/// needed for real async DB reads (e.g. `watchTopos().first`) that a plain
/// `await` under `flutter_test`'s fake async zone can't resolve. Mirrors
/// `topos_screen_test.dart`'s identically-shaped `_dbWork` helper.
Future<T> _dbWork<T>(WidgetTester tester, Future<T> Function() body) async {
  late T result;
  await tester.runAsync(() async {
    result = await body();
  });
  return result;
}

void main() {
  group('topo-edit-location-button', () {
    testWidgets('absent when readOnly', (tester) async {
      final seeded = await _seedWall();
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: seeded.container,
          child: MaterialApp(
            theme: MasiTheme.light,
            home: TopoCanvasScreen(wallId: seeded.wallId, readOnly: true),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('topo-edit-location-button')),
        findsNothing,
        reason:
            'readOnly hides every editing affordance on this screen — see '
            'TopoCanvasScreen.readOnly\'s doc — including this one, since it '
            'mutates the wall the same way every other gated control does',
      );
    });

    testWidgets(
      'present in view mode, absent in draw mode — mirrors the AR button\'s '
      'own mode gating',
      (tester) async {
        final seeded = await _seedWall();
        addTearDown(seeded.db.close);
        addTearDown(seeded.container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: seeded.container,
            child: MaterialApp(
              theme: MasiTheme.light,
              home: TopoCanvasScreen(wallId: seeded.wallId),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('topo-edit-location-button')),
          findsOneWidget,
          reason: 'view mode (the default) must show the button',
        );

        await tester.tap(find.byKey(const Key('topo-mode-toggle')));
        await tester.pump();

        expect(
          find.byKey(const Key('topo-edit-location-button')),
          findsNothing,
          reason:
              'draw mode must hide it too, exactly like topo-ar-button — '
              'neither should clutter the draw toolbar',
        );
      },
    );

    testWidgets(
      'tooltip is "Set location" for a wall with no coordinates, and flips '
      'to "Edit location" once coordinates are set',
      (tester) async {
        final seeded = await _seedWall();
        addTearDown(seeded.db.close);
        addTearDown(seeded.container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: seeded.container,
            child: MaterialApp(
              theme: MasiTheme.light,
              home: TopoCanvasScreen(wallId: seeded.wallId),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          tester
              .widget<IconButton>(
                find.byKey(const Key('topo-edit-location-button')),
              )
              .tooltip,
          'Set location',
          reason: 'a wall with no recorded coordinates yet reads as "Set"',
        );

        // Write coordinates directly through the repository (bypassing the
        // picker entirely) to prove E4: toposProvider is a live
        // StreamProvider backed by a Drift `.watch()` query that reads from
        // the walls table (see LibraryCrudRepository.watchTopos'
        // `readsFrom`), so this write alone -- no manual invalidation --
        // must be enough for the screen to notice the wall now has
        // coordinates.
        await _dbWork(
          tester,
          () => seeded.container
              .read(libraryCrudRepositoryProvider)
              .setWallCoordinates(seeded.wallId, 45.0, 6.0),
        );
        await tester.pumpAndSettle();

        expect(
          tester
              .widget<IconButton>(
                find.byKey(const Key('topo-edit-location-button')),
              )
              .tooltip,
          'Edit location',
          reason:
              'once the wall has coordinates, the tooltip must flip to '
              '"Edit" -- the live toposProvider read updating on its own, '
              'with no invalidation call anywhere in this screen',
        );
      },
    );

    testWidgets(
      'S-L: tapping the button opens the real "Set location" picker; '
      'panning it via a REAL drag gesture then tapping Save writes the '
      'post-drag camera center via setWallCoordinates and shows a '
      '"Location saved" confirmation SnackBar',
      (tester) async {
        final controller = MapController();
        addTearDown(controller.dispose);
        final seeded = await _seedWall();
        addTearDown(seeded.db.close);
        addTearDown(seeded.container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: seeded.container,
            child: MaterialApp(
              theme: MasiTheme.light,
              home: TopoCanvasScreen(
                wallId: seeded.wallId,
                setLocationTileProvider: _NoopTileProvider(),
                setLocationMapController: controller,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('topo-edit-location-button')));
        await tester.pumpAndSettle();

        expect(
          find.byType(FlutterMap),
          findsOneWidget,
          reason: 'the button must open the real map picker',
        );
        // The freshly-created wall has no coordinates yet, so the picker
        // opens on the neutral (0, 0) world view and Save starts disabled
        // (mirrors topos_screen_test.dart's own S-L2/S-L3).
        expect(
          tester
              .widget<TextButton>(find.byKey(const Key('set-location-save')))
              .onPressed,
          isNull,
        );

        await tester.drag(find.byType(FlutterMap), const Offset(-120, -80));
        await tester.pump();

        final centerAfterDrag = controller.camera.center;
        expect(centerAfterDrag.latitude.abs(), greaterThan(0.01));
        expect(centerAfterDrag.longitude.abs(), greaterThan(0.01));

        expect(
          tester
              .widget<TextButton>(find.byKey(const Key('set-location-save')))
              .onPressed,
          isNotNull,
        );

        await tester.tap(find.byKey(const Key('set-location-save')));
        await tester.pumpAndSettle();

        expect(find.text('Location saved'), findsOneWidget);

        final topos = await _dbWork(
          tester,
          () => seeded.container
              .read(libraryCrudRepositoryProvider)
              .watchTopos()
              .first,
        );
        final saved = topos.firstWhere((t) => t.wallId == seeded.wallId);
        expect(saved.latitude, isNotNull);
        expect(saved.longitude, isNotNull);
        expect(saved.latitude!, closeTo(centerAfterDrag.latitude, 0.0001));
        expect(saved.longitude!, closeTo(centerAfterDrag.longitude, 0.0001));
      },
    );
  });
}
