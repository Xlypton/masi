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
import 'package:climbtopo/shared/presentation/masi_icon.dart';
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

/// Like [_drain], but WITHOUT the trailing `pumpAndSettle()` — used whenever
/// the destination builds a REAL (production) `CommunityMapScreen`, whose
/// `FlutterMap` is backed by the real network `NetworkTileProvider`
/// (`CommunityMapScreen`/the `/map` route have no injectable `tileProvider`
/// seam). `pumpAndSettle` would wait on that tile fetch forever under
/// `flutter_test` — a handful of bounded pumps is enough to let GoRouter
/// resolve the route and build the widget tree.
Future<void> _pumpBounded(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
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
    'D1a: community/logbook routes register and build their screens',
    () {
      setUp(() => appRouter.go('/'));

      testWidgets(
        '/community redirects to the Map branch, building CommunityMapScreen',
        (tester) async {
          final container = _makeContainer();

          await tester.pumpWidget(_wrapRouter(container));
          await _drain(tester);

          appRouter.go('/community');
          await _pumpBounded(tester);

          expect(find.byType(CommunityMapScreen), findsOneWidget);
        },
      );

      testWidgets('/map renders CommunityMapScreen directly', (tester) async {
        final container = _makeContainer();

        await tester.pumpWidget(_wrapRouter(container));
        await _drain(tester);

        appRouter.go('/map');
        await _pumpBounded(tester);

        expect(find.byType(CommunityMapScreen), findsOneWidget);
      });

      testWidgets('/feed renders CommunityFeedScreen', (tester) async {
        final container = _makeContainer();

        await tester.pumpWidget(_wrapRouter(container));
        await _drain(tester);

        appRouter.go('/feed');
        await _drain(tester);

        expect(find.byType(CommunityFeedScreen), findsOneWidget);
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

  group('communityRedirectTarget: pure redirect-target logic', () {
    test('no query params -> /map (matches the old Map-default behavior)', () {
      expect(communityRedirectTarget(const {}), '/map');
    });

    test('tab=feed -> /feed', () {
      expect(communityRedirectTarget(const {'tab': 'feed'}), '/feed');
    });

    test('any non-"feed" tab value -> /map', () {
      expect(communityRedirectTarget(const {'tab': 'map'}), '/map');
    });

    test('focus=<id> is carried onto /map as its own focus query param', () {
      expect(
        communityRedirectTarget(const {'focus': 'wall-x'}),
        '/map?focus=wall-x',
      );
    });

    test(
      'tab=feed wins over an accompanying focus -- Feed has no focus concept',
      () {
        expect(
          communityRedirectTarget(const {'tab': 'feed', 'focus': 'wall-x'}),
          '/feed',
        );
      },
    );
  });

  group('Q4: /community?focus=X redirects to /map with focusWallId applied', () {
    setUp(() => appRouter.go('/'));

    testWidgets(
      'navigating to /community?focus=wall-x builds a CommunityMapScreen '
      'with focusWallId=wall-x',
      (tester) async {
        final container = _makeContainer();

        await tester.pumpWidget(_wrapRouter(container));
        await _drain(tester);

        appRouter.go('/community?focus=wall-x');
        await _pumpBounded(tester);

        expect(find.byType(CommunityMapScreen), findsOneWidget);
        final screen = tester.widget<CommunityMapScreen>(
          find.byType(CommunityMapScreen),
        );
        expect(screen.focusWallId, 'wall-x');
      },
    );

    testWidgets(
      'the legacy full query shape /community?tab=map&focus=wall-x still '
      'redirects to /map with focusWallId applied',
      (tester) async {
        final container = _makeContainer();

        await tester.pumpWidget(_wrapRouter(container));
        await _drain(tester);

        appRouter.go('/community?tab=map&focus=wall-x');
        await _pumpBounded(tester);

        expect(find.byType(CommunityMapScreen), findsOneWidget);
        final screen = tester.widget<CommunityMapScreen>(
          find.byType(CommunityMapScreen),
        );
        expect(screen.focusWallId, 'wall-x');
      },
    );
  });

  group('N1/N4: persistent bottom-nav shell (NavShell)', () {
    setUp(() => appRouter.go('/'));

    testWidgets(
      'shows exactly 3 nav tabs (Topos/Map/Feed); Topos is selected by '
      'default and the old segmented _TabToggle is gone',
      (tester) async {
        final container = _makeContainer();

        await tester.pumpWidget(_wrapRouter(container));
        await _drain(tester);

        expect(find.byKey(const Key('nav-tab-topos')), findsOneWidget);
        expect(find.byKey(const Key('nav-tab-map')), findsOneWidget);
        expect(find.byKey(const Key('nav-tab-feed')), findsOneWidget);

        expect(find.byType(ToposScreen), findsOneWidget);
        expect(find.byType(CommunityMapScreen), findsNothing);
        expect(find.byType(CommunityFeedScreen), findsNothing);

        // The old in-screen segmented Feed/Map toggle no longer exists
        // anywhere in the tree.
        expect(find.byKey(const Key('community-feed-toggle')), findsNothing);
        expect(find.byKey(const Key('community-map-toggle')), findsNothing);
      },
    );

    testWidgets(
      'tapping nav-tab-map switches the visible body to CommunityMapScreen '
      '(IndexedStack: Topos is preserved offstage, not disposed)',
      (tester) async {
        final container = _makeContainer();

        await tester.pumpWidget(_wrapRouter(container));
        await _drain(tester);

        await tester.tap(find.byKey(const Key('nav-tab-map')));
        await _pumpBounded(tester);

        expect(find.byType(CommunityMapScreen), findsOneWidget);
        // `StatefulShellRoute.indexedStack`'s default container wraps every
        // INACTIVE branch in a real `Offstage(offstage: true)` (see
        // go_router's `_buildRouteBranchContainer`), which `find.byType`'s
        // default `skipOffstage: true` excludes -- ToposScreen is still
        // mounted (its state survives the tab switch), just not "onstage".
        expect(find.byType(ToposScreen), findsNothing);
      },
    );

    testWidgets(
      'tapping nav-tab-feed switches the visible body to CommunityFeedScreen',
      (tester) async {
        final container = _makeContainer();

        await tester.pumpWidget(_wrapRouter(container));
        await _drain(tester);

        await tester.tap(find.byKey(const Key('nav-tab-feed')));
        await _drain(tester);

        expect(find.byType(CommunityFeedScreen), findsOneWidget);
        expect(find.byType(ToposScreen), findsNothing);
      },
    );

    testWidgets(
      'switching Map -> Topos -> Map preserves the map branch instead of '
      'rebuilding it from scratch (IndexedStack state preservation)',
      (tester) async {
        final container = _makeContainer();

        await tester.pumpWidget(_wrapRouter(container));
        await _drain(tester);

        await tester.tap(find.byKey(const Key('nav-tab-map')));
        await _pumpBounded(tester);
        expect(find.byType(CommunityMapScreen), findsOneWidget);
        final firstState = tester.state(find.byType(CommunityMapScreen));

        await tester.tap(find.byKey(const Key('nav-tab-topos')));
        await _drain(tester);
        expect(find.byType(ToposScreen), findsOneWidget);
        expect(find.byType(CommunityMapScreen), findsNothing);

        await tester.tap(find.byKey(const Key('nav-tab-map')));
        await _pumpBounded(tester);
        expect(find.byType(CommunityMapScreen), findsOneWidget);
        final secondState = tester.state(find.byType(CommunityMapScreen));

        expect(
          identical(firstState, secondState),
          isTrue,
          reason:
              'the Map branch\'s State must be preserved across a round '
              'trip through another tab, not rebuilt from scratch',
        );
      },
    );

    testWidgets(
      '#51: the NavShell Scaffold sets extendBody unconditionally, so '
      'every branch (Topos/Map/Feed) draws full-bleed behind the floating '
      'translucent bar',
      (tester) async {
        final container = _makeContainer();

        await tester.pumpWidget(_wrapRouter(container));
        await _drain(tester);

        // The NavShell's OWN Scaffold is the one holding the bottom-nav
        // bar -- distinct from ToposScreen's/CommunityMapScreen's own
        // per-branch Scaffolds, neither of which sets a
        // `bottomNavigationBar`.
        Scaffold navShellScaffold() => tester.widget<Scaffold>(
          find.byWidgetPredicate(
            (widget) => widget is Scaffold && widget.bottomNavigationBar != null,
          ),
        );

        expect(
          navShellScaffold().extendBody,
          isTrue,
          reason: 'Topos (default tab) must draw full-bleed behind the bar',
        );

        await tester.tap(find.byKey(const Key('nav-tab-map')));
        await _pumpBounded(tester);
        expect(
          navShellScaffold().extendBody,
          isTrue,
          reason: 'Map must draw full-bleed behind the translucent bar',
        );

        await tester.tap(find.byKey(const Key('nav-tab-feed')));
        await _drain(tester);
        expect(
          navShellScaffold().extendBody,
          isTrue,
          reason: 'Feed must also draw full-bleed behind the bar',
        );

        await tester.tap(find.byKey(const Key('nav-tab-topos')));
        await _drain(tester);
        expect(navShellScaffold().extendBody, isTrue);
      },
    );

    testWidgets(
      '#50: the Topos tab icon is the routes glyph (not the wall glyph), '
      'while Map/Feed keep their existing glyphs',
      (tester) async {
        final container = _makeContainer();

        await tester.pumpWidget(_wrapRouter(container));
        await _drain(tester);

        MasiIcon iconInTab(Key tabKey) => tester.widget<MasiIcon>(
          find.descendant(
            of: find.byKey(tabKey),
            matching: find.byType(MasiIcon),
          ),
        );

        expect(iconInTab(const Key('nav-tab-topos')).name, 'route');
        expect(iconInTab(const Key('nav-tab-map')).name, 'topo_map');
        expect(iconInTab(const Key('nav-tab-feed')).name, 'comment');
      },
    );
  });
}
