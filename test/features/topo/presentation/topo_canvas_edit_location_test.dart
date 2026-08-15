// Tests for the canvas screen's location controls, split by mode per user
// feedback ("only show the location edit button in edit mode, on normal
// mode use the button to locate the topo on the map"):
//  - DRAW mode shows the "Edit location"/"Set location" button
//    (`topo-edit-location-button`) -- the canvas-screen counterpart to
//    `topos_screen.dart`'s overflow-menu "Set location" item, which used to
//    be the ONLY way to reach this flow. Mirrors that file's own "S-L" test
//    group for the picker-interaction pattern: a `_NoopTileProvider` (never
//    touches the network) plus an injected `MapController` (directly
//    inspectable, via `TopoCanvasScreen`'s own
//    `setLocationTileProvider`/`setLocationMapController` test seams --
//    mirroring `ToposScreen`'s identically-named/-shaped fields).
//  - VIEW mode shows a DISTINCT "Show on map" locate button
//    (`topo-locate-on-map-button`) that jumps into `/community`'s Map tab,
//    focused on this wall -- the EXACT SAME navigation
//    `topos_screen.dart`'s `_handleShowOnMap` uses for its home-list "Show
//    on map" menu item, reused verbatim. Mirrors that file's own "Q1" test
//    group for both the disabled-without-coordinates behavior and the
//    navigation-assertion pattern: a real minimal `GoRouter` with a keyed
//    `/community` placeholder route carrying the pushed `tab`/`focus` query
//    params in its text.

import 'dart:convert';

import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/topo/application/draw_controller.dart';
import 'package:masi/features/topo/data/route_repository.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
import 'package:masi/features/topo/presentation/topo_canvas_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

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

/// Like [_seedWall], but also attaches a photo and persists a single
/// 2-point route, so the top chrome's `selectedRouteId != null`-gated
/// edit-metadata glyph can join the row too -- needed by the "no overflow
/// at 375px" group below to exercise each mode's worst-case trailing-action
/// count. Mirrors `canvas_bottom_reclaim_test.dart`'s identically-shaped
/// `seedWallWithPhotoAndRoute`.
Future<({AppDatabase db, ProviderContainer container, String wallId})>
_seedWallWithPhotoAndRoute(WidgetTester tester) async {
  final seeded = await _seedWall();
  final crud = seeded.container.read(libraryCrudRepositoryProvider);
  await tester.runAsync(() async {
    final photoId = await crud.attachPhotoToWall(
      seeded.wallId,
      XFile('/tmp/edit-location-photo.jpg'),
      1000,
      2000,
    );
    final routeRepo = RouteRepository(seeded.db, nowMs: () => 1000);
    await routeRepo.upsertRoute(
      seeded.wallId,
      photoId,
      const TopoRoute(
        id: 1,
        number: 1,
        points: [Offset(0.1, 0.1), Offset(0.2, 0.2)],
      ),
    );
  });
  return seeded;
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

/// Wraps [screen] in a real (minimal) [GoRouter] so the locate-on-map
/// button's `context.push` call resolves against a real router instead of
/// throwing for lack of one — mirrors `topos_screen_test.dart`'s own `_wrap`
/// exactly, including its keyed `/community` placeholder that carries the
/// pushed `tab`/`focus` query params in its text, so a test can confirm
/// both that navigation happened AND that it carried the right values,
/// without needing the real `CommunityScreen`/`FlutterMap`.
Widget _wrap(ProviderContainer container, Widget screen) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (context, state) => screen),
      GoRoute(
        path: '/community',
        builder: (context, state) => Text(
          'community-'
          '${state.uri.queryParameters['tab']}-'
          '${state.uri.queryParameters['focus']}',
          key: const Key('community-placeholder'),
        ),
      ),
    ],
  );
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(theme: MasiTheme.light, routerConfig: router),
  );
}

void main() {
  group('topo-edit-location-button (draw mode)', () {
    testWidgets('absent when readOnly, even forced into draw mode', (
      tester,
    ) async {
      final seeded = await _seedWall();
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);

      await tester.pumpWidget(
        _wrap(
          seeded.container,
          TopoCanvasScreen(wallId: seeded.wallId, readOnly: true),
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

      // readOnly has no UI path to draw mode (the mode-toggle itself is
      // readOnly-gated — see `_topTrailingActions`'s doc), but `DrawState`
      // is an app-lifetime-global provider, so force it directly to prove
      // the readOnly gate holds regardless of mode, not just at the
      // default view-mode this screen always opens in.
      seeded.container
          .read(drawControllerProvider(seeded.wallId).notifier)
          .setMode(DrawMode.draw);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('topo-edit-location-button')),
        findsNothing,
        reason: 'readOnly must hide the edit button in draw mode too',
      );
    });

    testWidgets(
      'present in draw mode, absent in view mode — moved here from view '
      'mode per user feedback',
      (tester) async {
        final seeded = await _seedWall();
        addTearDown(seeded.db.close);
        addTearDown(seeded.container.dispose);

        await tester.pumpWidget(
          _wrap(seeded.container, TopoCanvasScreen(wallId: seeded.wallId)),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('topo-edit-location-button')),
          findsNothing,
          reason: 'view mode (the default) must NOT show the edit button',
        );

        await tester.tap(find.byKey(const Key('topo-mode-toggle')));
        await tester.pump();

        expect(
          find.byKey(const Key('topo-edit-location-button')),
          findsOneWidget,
          reason: 'draw mode must show the edit button',
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
          _wrap(seeded.container, TopoCanvasScreen(wallId: seeded.wallId)),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('topo-mode-toggle')));
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
        // picker entirely): toposProvider is a live StreamProvider backed
        // by a Drift `.watch()` query that reads from the walls table (see
        // LibraryCrudRepository.watchTopos' `readsFrom`), so this write
        // alone -- no manual invalidation -- must be enough for the screen
        // to notice the wall now has coordinates.
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
      'S-L: tapping the button (in draw mode) opens the real "Set location" '
      'picker; panning it via a REAL drag gesture then tapping Save writes '
      'the post-drag camera center via setWallCoordinates and shows a '
      '"Location saved" confirmation SnackBar',
      (tester) async {
        final controller = MapController();
        addTearDown(controller.dispose);
        final seeded = await _seedWall();
        addTearDown(seeded.db.close);
        addTearDown(seeded.container.dispose);

        await tester.pumpWidget(
          _wrap(
            seeded.container,
            TopoCanvasScreen(
              wallId: seeded.wallId,
              setLocationTileProvider: _NoopTileProvider(),
              setLocationMapController: controller,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('topo-mode-toggle')));
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

  group('topo-locate-on-map-button (view mode)', () {
    testWidgets('absent when readOnly', (tester) async {
      final seeded = await _seedWall();
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);
      await _dbWork(
        tester,
        () => seeded.container
            .read(libraryCrudRepositoryProvider)
            .setWallCoordinates(seeded.wallId, 45.0, 6.0),
      );

      await tester.pumpWidget(
        _wrap(
          seeded.container,
          TopoCanvasScreen(wallId: seeded.wallId, readOnly: true),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('topo-locate-on-map-button')),
        findsNothing,
        reason:
            'readOnly hides every editing/navigation affordance this screen '
            'adds on top of the shared community embed',
      );
    });

    testWidgets('present in view mode, absent in draw mode', (tester) async {
      final seeded = await _seedWall();
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);

      await tester.pumpWidget(
        _wrap(seeded.container, TopoCanvasScreen(wallId: seeded.wallId)),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('topo-locate-on-map-button')),
        findsOneWidget,
        reason: 'view mode (the default) must show the locate button',
      );

      await tester.tap(find.byKey(const Key('topo-mode-toggle')));
      await tester.pump();

      expect(
        find.byKey(const Key('topo-locate-on-map-button')),
        findsNothing,
        reason: 'draw mode must hide the locate button',
      );
    });

    testWidgets('disabled with a "No location set" tooltip for a wall with no '
        'coordinates, and flips to enabled with "Show on map" once '
        'coordinates are set', (tester) async {
      final seeded = await _seedWall();
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);

      await tester.pumpWidget(
        _wrap(seeded.container, TopoCanvasScreen(wallId: seeded.wallId)),
      );
      await tester.pumpAndSettle();

      final buttonFinder = find.byKey(const Key('topo-locate-on-map-button'));
      expect(
        tester.widget<IconButton>(buttonFinder).onPressed,
        isNull,
        reason: 'nothing to locate on the map without coordinates',
      );
      expect(
        tester.widget<IconButton>(buttonFinder).tooltip,
        'No location set',
      );

      await _dbWork(
        tester,
        () => seeded.container
            .read(libraryCrudRepositoryProvider)
            .setWallCoordinates(seeded.wallId, 45.0, 6.0),
      );
      await tester.pumpAndSettle();

      expect(
        tester.widget<IconButton>(buttonFinder).onPressed,
        isNotNull,
        reason:
            'the live toposProvider read updating on its own must enable '
            'the button once the wall has coordinates',
      );
      expect(tester.widget<IconButton>(buttonFinder).tooltip, 'Show on map');
    });

    testWidgets('Q1: tapping the button (with coordinates set) navigates to '
        '/community?tab=map&focus=<wallId> — the same destination '
        'topos_screen.dart\'s "Show on map" menu item uses', (tester) async {
      final seeded = await _seedWall();
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);
      await _dbWork(
        tester,
        () => seeded.container
            .read(libraryCrudRepositoryProvider)
            .setWallCoordinates(seeded.wallId, 47.4979, 19.0402),
      );

      await tester.pumpWidget(
        _wrap(seeded.container, TopoCanvasScreen(wallId: seeded.wallId)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('topo-locate-on-map-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('community-placeholder')), findsOneWidget);
      expect(
        find.text('community-map-${seeded.wallId}'),
        findsOneWidget,
        reason:
            'must push the SAME tab=map&focus=<wallId> destination as '
            'topos_screen.dart\'s _handleShowOnMap',
      );
    });
  });

  group('no RenderFlex overflow at 375px width in either mode', () {
    // 375px is this project's supported minimum width (see CLAUDE.md /
    // DESIGN.md). Mirrors `canvas_bottom_reclaim_test.dart`'s own 375px
    // overflow regression tests, but exercises each mode's location-control
    // slot separately, since the button moved out of view mode and a new
    // one was added to draw mode's row by this change.
    void setViewportSize(WidgetTester tester, Size size) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    testWidgets('view mode: worst-case trailing row (AR + mode-toggle + '
        'locate-on-map) does not overflow', (tester) async {
      setViewportSize(tester, const Size(375, 812));
      final seeded = await _seedWallWithPhotoAndRoute(tester);
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);
      await _dbWork(
        tester,
        () => seeded.container
            .read(libraryCrudRepositoryProvider)
            .setWallCoordinates(seeded.wallId, 45.0, 6.0),
      );

      await tester.pumpWidget(
        _wrap(
          seeded.container,
          TopoCanvasScreen(
            wallId: seeded.wallId,
            debugInitialImageSize: const Size(1000, 2000),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(seeded.container.read(drawControllerProvider(seeded.wallId)).mode, DrawMode.view);
      seeded.container.read(drawControllerProvider(seeded.wallId).notifier).selectRoute(1);
      await tester.pumpAndSettle();

      for (final key in const [
        'topo-ar-button',
        'topo-mode-toggle',
        'topo-locate-on-map-button',
      ]) {
        expect(
          find.byKey(Key(key)),
          findsOneWidget,
          reason: '$key must be present for this worst-case row',
        );
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'draw mode: the trailing row is down to the edit-location glyph alone '
      'and does not overflow — the Cancel/Save text pair that briefly made '
      'this the wider of the two modes moved into the bottom cluster, and '
      'the edit-metadata pencil moved onto the route itself (2026-08-12)',
      (tester) async {
        setViewportSize(tester, const Size(375, 812));
        final seeded = await _seedWallWithPhotoAndRoute(tester);
        addTearDown(seeded.db.close);
        addTearDown(seeded.container.dispose);

        await tester.pumpWidget(
          _wrap(
            seeded.container,
            TopoCanvasScreen(
              wallId: seeded.wallId,
              debugInitialImageSize: const Size(1000, 2000),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('topo-mode-toggle')));
        await tester.pumpAndSettle();
        seeded.container.read(drawControllerProvider(seeded.wallId).notifier).selectRoute(1);
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('topo-edit-location-button')),
          findsOneWidget,
          reason: 'setting the wall location is a draw-mode action',
        );
        // Draw mode shows neither the AR glyph nor the locate-on-map glyph
        // (view-mode-only — see `_topTrailingActions`), carries no mode
        // control at all (the bottom ✗/✓ is the way out), and no longer
        // carries the route-metadata pencil (it lives on the route's own
        // legend row now).
        expect(find.byKey(const Key('topo-ar-button')), findsNothing);
        expect(
          find.byKey(const Key('topo-locate-on-map-button')),
          findsNothing,
        );
        expect(find.byKey(const Key('topo-mode-toggle')), findsNothing);
        expect(
          find.byKey(const Key('topo-edit-metadata-button')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);

        // Every control in the row is laid out inside the 375px viewport —
        // the real claim, since `takeException` alone would miss a button
        // pushed off-screen by an unbounded Row that happened not to assert.
        for (final key in const [
          'topo-back-button',
          'topo-edit-location-button',
        ]) {
          final rect = tester.getRect(find.byKey(Key(key)));
          expect(rect.left, greaterThanOrEqualTo(0), reason: '$key off-screen left');
          expect(
            rect.right,
            lessThanOrEqualTo(375.0),
            reason: '$key (rect=$rect) must not overflow a 375px viewport',
          );
        }
      },
    );
  });
}
