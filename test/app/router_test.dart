import 'package:climbtopo/app/router.dart';
import 'package:climbtopo/app/theme.dart';
import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/core/db/database_provider.dart';
import 'package:climbtopo/features/community/presentation/community_screen.dart';
import 'package:climbtopo/features/community/presentation/community_topo_detail_screen.dart';
import 'package:climbtopo/features/library/presentation/areas_screen.dart';
import 'package:climbtopo/features/library/presentation/topos_screen.dart';
import 'package:climbtopo/features/logbook/presentation/logbook_screen.dart';
import 'package:climbtopo/features/topo/presentation/topo_canvas_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a [ProviderContainer] wired to a fresh in-memory database, mirroring
/// the pattern in `areas_screen_test.dart`: `db.close` is registered BEFORE
/// `container.dispose` (addTearDown runs LIFO), so the container disposes
/// Riverpod's live watch subscriptions before the underlying Drift connection
/// closes.
ProviderContainer _makeContainer() {
  final db = AppDatabase(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      nowMsProvider.overrideWithValue(() => 1000),
    ],
  );
  addTearDown(db.close);
  addTearDown(container.dispose);
  return container;
}

Widget _wrapRouter(ProviderContainer container) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(routerConfig: appRouter, theme: MasiTheme.light),
  );
}

/// Advances real asynchronous Drift work interleaved with fake-clock pumps to
/// get past the initial `CircularProgressIndicator` (which a bare
/// `pumpAndSettle` would spin on forever), then settles bounded animations —
/// see the identical helper's doc comment in `areas_screen_test.dart`.
Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 30));
  }
  await tester.pumpAndSettle();
}

void main() {
  group('router: / renders the new Topos home', () {
    // `appRouter` is a module-level singleton (see `lib/app/router.dart`),
    // so its current location persists across tests within this file —
    // `MaterialApp.router` does not reset it on a fresh pump. Force it back
    // to `/` before every test so each one starts from a known location
    // regardless of where a previous test's navigation left it.
    setUp(() => appRouter.go('/'));

    testWidgets('/ renders ToposScreen', (tester) async {
      final container = _makeContainer();

      await tester.pumpWidget(_wrapRouter(container));
      await _drain(tester);

      expect(find.byType(ToposScreen), findsOneWidget);
      expect(find.byType(AreasScreen), findsNothing);
    });

    testWidgets('/areas renders AreasScreen', (tester) async {
      final container = _makeContainer();

      await tester.pumpWidget(_wrapRouter(container));
      await _drain(tester);

      appRouter.go('/areas');
      await _drain(tester);

      expect(find.byType(AreasScreen), findsOneWidget);
    });

    testWidgets('tapping topos-organize from ToposScreen navigates to '
        'AreasScreen', (tester) async {
      final container = _makeContainer();

      await tester.pumpWidget(_wrapRouter(container));
      await _drain(tester);

      expect(find.byType(ToposScreen), findsOneWidget);

      await tester.tap(find.byKey(const Key('topos-organize')));
      await _drain(tester);

      expect(find.byType(AreasScreen), findsOneWidget);
    });

    testWidgets('/walls/:wallId still renders TopoCanvasScreen', (
      tester,
    ) async {
      final container = _makeContainer();

      await tester.pumpWidget(_wrapRouter(container));
      await _drain(tester);

      // A nonexistent wall id is enough here: the assertion is about the
      // ROUTE resolving to the canvas screen TYPE, not about a loaded photo
      // — TopoCanvasScreen is expected to render an empty/error state for a
      // wall it can't find.
      appRouter.go('/walls/nonexistent-wall-id');
      await _drain(tester);

      expect(find.byType(TopoCanvasScreen), findsOneWidget);
    });
  });

  group(
    'D1a: new community/logbook routes register and build their screens',
    () {
      setUp(() => appRouter.go('/'));

      testWidgets('/community renders CommunityScreen', (tester) async {
        final container = _makeContainer();

        await tester.pumpWidget(_wrapRouter(container));
        await _drain(tester);

        appRouter.go('/community');
        // Bounded pumps only -- deliberately NOT `_drain` (whose trailing
        // `pumpAndSettle()` would wait on this route's REAL (production)
        // `NetworkTileProvider`/`BuiltInMapCachingProviderImpl`, which needs
        // a real `path_provider` cache directory never available under
        // `flutter_test` -- see Q4's identical note below). `CommunityScreen`
        // now opens on the Map tab by default, so this route builds a real
        // `FlutterMap` immediately; a handful of bounded pumps is enough to
        // let GoRouter resolve the route and build the widget tree without
        // needing that tile fetch to settle.
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 30));
        }

        expect(find.byType(CommunityScreen), findsOneWidget);
      });

      testWidgets(
        '/community/topo/:wallId renders CommunityTopoDetailScreen bound to '
        'that wallId',
        (tester) async {
          final container = _makeContainer();

          await tester.pumpWidget(_wrapRouter(container));
          await _drain(tester);

          // A nonexistent wall id is enough here (mirrors the existing
          // `/walls/:wallId` route test above): the assertion is about the
          // ROUTE resolving to the right screen TYPE bound to the right
          // path param, not about a fully loaded shared topo.
          appRouter.go('/community/topo/nonexistent-wall-id');
          await _drain(tester);

          expect(find.byType(CommunityTopoDetailScreen), findsOneWidget);
          final screen = tester.widget<CommunityTopoDetailScreen>(
            find.byType(CommunityTopoDetailScreen),
          );
          expect(screen.wallId, 'nonexistent-wall-id');
        },
      );

      testWidgets('/logbook renders LogbookScreen', (tester) async {
        final container = _makeContainer();

        await tester.pumpWidget(_wrapRouter(container));
        await _drain(tester);

        appRouter.go('/logbook');
        await _drain(tester);

        expect(find.byType(LogbookScreen), findsOneWidget);
      });

      testWidgets(
        'existing routes (/, /areas, /walls/:wallId) still resolve after the '
        'new routes were added',
        (tester) async {
          final container = _makeContainer();

          await tester.pumpWidget(_wrapRouter(container));
          await _drain(tester);
          expect(find.byType(ToposScreen), findsOneWidget);

          appRouter.go('/areas');
          await _drain(tester);
          expect(find.byType(AreasScreen), findsOneWidget);

          appRouter.go('/walls/nonexistent-wall-id');
          await _drain(tester);
          expect(find.byType(TopoCanvasScreen), findsOneWidget);
        },
      );
    },
  );

  group('D1b: Home nav entry points to Community/Logbook', () {
    setUp(() => appRouter.go('/'));

    testWidgets('tapping home-community-button navigates from ToposScreen to '
        'CommunityScreen', (tester) async {
      final container = _makeContainer();

      await tester.pumpWidget(_wrapRouter(container));
      await _drain(tester);
      expect(find.byType(ToposScreen), findsOneWidget);

      await tester.tap(find.byKey(const Key('home-community-button')));
      // Bounded pumps only -- deliberately NOT `_drain` (whose trailing
      // `pumpAndSettle()` would wait on this route's REAL (production)
      // `NetworkTileProvider`, which `CommunityScreen` now builds
      // immediately since it opens on the Map tab by default -- see the
      // identical note on the D1a `/community` test above.
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }

      expect(find.byType(CommunityScreen), findsOneWidget);
    });

    testWidgets('tapping home-logbook-button navigates from ToposScreen to '
        'LogbookScreen', (tester) async {
      final container = _makeContainer();

      await tester.pumpWidget(_wrapRouter(container));
      await _drain(tester);
      expect(find.byType(ToposScreen), findsOneWidget);

      await tester.tap(find.byKey(const Key('home-logbook-button')));
      await _drain(tester);

      expect(find.byType(LogbookScreen), findsOneWidget);
    });
  });

  group('Q4: /community query-param parsing (parseCommunityRouteParams)', () {
    test('no query params -> tab null, focusWallId null (plain /community, '
        'unchanged behavior)', () {
      final result = parseCommunityRouteParams(const {});
      expect(result.tab, isNull);
      expect(result.focusWallId, isNull);
    });

    test('tab=map -> CommunityTab.map', () {
      final result = parseCommunityRouteParams(const {'tab': 'map'});
      expect(result.tab, CommunityTab.map);
      expect(result.focusWallId, isNull);
    });

    test('any non-"map" tab value -> null (defaults to Map)', () {
      final result = parseCommunityRouteParams(const {'tab': 'feed'});
      expect(result.tab, isNull);
    });

    test('focus=<id> is parsed regardless of tab', () {
      final result = parseCommunityRouteParams(const {'focus': 'wall-x'});
      expect(result.tab, isNull);
      expect(result.focusWallId, 'wall-x');
    });

    test('tab=map&focus=<id> -> both parsed', () {
      final result = parseCommunityRouteParams(const {
        'tab': 'map',
        'focus': 'wall-x',
      });
      expect(result.tab, CommunityTab.map);
      expect(result.focusWallId, 'wall-x');
    });
  });

  group(
    'Q4: /community?tab=map&focus=X builds CommunityScreen focused on X',
    () {
      setUp(() => appRouter.go('/'));

      testWidgets('navigating to /community?tab=map&focus=wall-x builds a '
          'CommunityScreen with initialTab=CommunityTab.map and '
          'focusWallId=wall-x', (tester) async {
        final container = _makeContainer();

        await tester.pumpWidget(_wrapRouter(container));
        await _drain(tester);

        appRouter.go('/community?tab=map&focus=wall-x');
        // Bounded pumps only -- deliberately NOT `_drain`'s trailing
        // `pumpAndSettle()`. This route's real (production) builder has no
        // injectable `tileProvider` seam, so with `initialTab: map` it
        // builds a REAL `FlutterMap` backed by the real network
        // `NetworkTileProvider` -- unlike every Map-tab test in
        // `community_screen_test.dart`, which injects `_NoopTileProvider`.
        // `pumpAndSettle` would wait for that tile fetch to resolve, which
        // never happens under `flutter_test`. A handful of bounded pumps is
        // enough to let GoRouter resolve the route and build the widget
        // tree; reading `CommunityScreen`'s own constructor params below
        // doesn't require the map's tiles to have loaded.
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 30));
        }

        expect(find.byType(CommunityScreen), findsOneWidget);
        final screen = tester.widget<CommunityScreen>(
          find.byType(CommunityScreen),
        );
        expect(screen.initialTab, CommunityTab.map);
        expect(screen.focusWallId, 'wall-x');
      });
    },
  );
}
