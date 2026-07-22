import 'dart:async';

import 'package:climbtopo/app/router.dart';
import 'package:climbtopo/app/theme.dart';
import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/core/db/database_provider.dart';
import 'package:climbtopo/features/account/application/auth_providers.dart';
import 'package:climbtopo/features/account/data/auth_repository.dart';
import 'package:climbtopo/features/account/presentation/account_screen.dart';
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

/// Minimal in-memory [AuthRepository] double for the web-auth-wall tests
/// below — mirrors `account_screen_test.dart`'s own `FakeAuthRepository`
/// (a single-subscription, seed-buffered [StreamController], so the
/// constructor-seeded [initial] state reliably reaches
/// `authStateProvider`'s listener on its first `listen()`) but trimmed to
/// just what `_webAuthGateRedirect` actually reads (`authStateChanges`) —
/// `sendMagicLink`/`signOut` are never exercised by these routing tests.
class _FakeAuthRepository implements AuthRepository {
  _FakeAuthRepository(AuthSessionState initial) : _current = initial {
    _controller.add(initial);
  }

  /// Never emits on [authStateChanges] at all — models `authStateProvider`
  /// stuck in its initial `AsyncLoading`, with no value yet, for the
  /// fail-closed regression test: [_webAuthGateRedirect] must NOT bounce a
  /// visitor while auth is genuinely still resolving (e.g. first boot / a
  /// magic-link `?code=` exchange in flight).
  _FakeAuthRepository.loadingForever()
    : _current = const AuthSessionState.signedOut();

  /// Immediately errors on [authStateChanges] instead of ever emitting a
  /// value — models `authStateProvider` becoming a *permanent* value-less
  /// `AsyncError`, which is exactly what happens in production when
  /// `main()`'s documented `Supabase.initialize()` catch-and-continue
  /// fallback fires (see `currentUidProvider`'s doc in `auth_providers.dart`)
  /// and the app is left with no working auth backend. This is the case the
  /// fail-OPEN bug let slip through as "unknown, allow" — this fake exists
  /// so the regression test can force exactly that state.
  _FakeAuthRepository.erroring(Object error)
    : _current = const AuthSessionState.signedOut() {
    _controller.addError(error);
  }

  final _controller = StreamController<AuthSessionState>();
  final AuthSessionState _current;

  @override
  AuthSessionState get currentSession => _current;

  @override
  Stream<AuthSessionState> authStateChanges() => _controller.stream;

  @override
  Future<void> sendMagicLink(String email) async {}

  @override
  Future<void> signInWithGoogle() async {}

  @override
  Future<void> signOut() async {}

  Future<void> dispose() => _controller.close();
}

/// Like [_makeContainer], plus the auth seams the web-auth-wall tests need:
/// a [_FakeAuthRepository] seeded with [authState] and
/// [webAuthGateEnabledProvider] forced to [gateEnabled] — the CRITICAL
/// testability seam `router.dart`'s `_webAuthGateRedirect` reads instead of
/// a bare `kIsWeb`, so these tests can force the gate on/off without a real
/// web build.
ProviderContainer _makeGateContainer({
  required AuthSessionState authState,
  required bool gateEnabled,
}) => _makeGateContainerFromRepo(
  _FakeAuthRepository(authState),
  gateEnabled: gateEnabled,
);

/// Shared by [_makeGateContainer] and the fail-closed regression tests that
/// need a [_FakeAuthRepository] variant other than a resolved
/// [AuthSessionState] — [_FakeAuthRepository.loadingForever] and
/// [_FakeAuthRepository.erroring] — so every web-auth-wall test wires the
/// same DB/gate overrides.
ProviderContainer _makeGateContainerFromRepo(
  _FakeAuthRepository repo, {
  required bool gateEnabled,
}) {
  addTearDown(repo.dispose);
  final db = AppDatabase(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      nowMsProvider.overrideWithValue(() => 1000),
      authRepositoryProvider.overrideWithValue(repo),
      webAuthGateEnabledProvider.overrideWithValue(gateEnabled),
    ],
  );
  addTearDown(db.close);
  addTearDown(container.dispose);
  return container;
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

  group('web auth wall: _webAuthGateRedirect gates every route behind '
      'sign-in on web, and is a total no-op on native', () {
    setUp(() => appRouter.go('/'));

    testWidgets(
      'gate enabled + signed-out: lands on the sign-in view (/account) — '
      'Topos and the bottom-nav tabs are not reachable',
      (tester) async {
        final container = _makeGateContainer(
          authState: const AuthSessionState.signedOut(),
          gateEnabled: true,
        );

        await tester.pumpWidget(_wrapRouter(container));
        await _drain(tester);

        expect(find.byType(AccountScreen), findsOneWidget);
        expect(find.byKey(const Key('account-email-field')), findsOneWidget);
        expect(find.byType(ToposScreen), findsNothing);
        expect(find.byKey(const Key('nav-tab-topos')), findsNothing);
      },
    );

    testWidgets(
      'gate enabled + signed-out: a direct deep link to a wall (not just '
      'the Topos home) also redirects to the sign-in view',
      (tester) async {
        final container = _makeGateContainer(
          authState: const AuthSessionState.signedOut(),
          gateEnabled: true,
        );

        await tester.pumpWidget(_wrapRouter(container));
        await _drain(tester);
        appRouter.go('/walls/nonexistent-wall-id');
        await _drain(tester);

        expect(find.byType(AccountScreen), findsOneWidget);
        expect(find.byType(TopoCanvasScreen), findsNothing);
      },
    );

    testWidgets(
      'gate enabled + signed-in: no redirect — the normal app renders, '
      'Topos and its nav tab are reachable',
      (tester) async {
        final container = _makeGateContainer(
          authState: const AuthSessionState.signedIn('climber@example.com'),
          gateEnabled: true,
        );

        await tester.pumpWidget(_wrapRouter(container));
        await _drain(tester);

        expect(find.byType(ToposScreen), findsOneWidget);
        expect(find.byKey(const Key('nav-tab-topos')), findsOneWidget);
        expect(find.byType(AccountScreen), findsNothing);
      },
    );

    testWidgets(
      'gate enabled + auth state genuinely still loading (no value yet, e.g. '
      'first boot / a magic-link `?code=` exchange in flight): does NOT '
      'redirect — the pending resolution must be allowed to complete',
      (tester) async {
        final container = _makeGateContainerFromRepo(
          _FakeAuthRepository.loadingForever(),
          gateEnabled: true,
        );

        await tester.pumpWidget(_wrapRouter(container));
        await _drain(tester);

        expect(find.byType(ToposScreen), findsOneWidget);
        expect(find.byType(AccountScreen), findsNothing);
      },
    );

    testWidgets(
      'gate enabled + auth state errored (e.g. Supabase.initialize() failed '
      "per main()'s documented catch-and-continue fallback, leaving "
      'authStateProvider a permanent value-less AsyncError): redirects to '
      'the sign-in view — the wall fails CLOSED, never open',
      (tester) async {
        final container = _makeGateContainerFromRepo(
          _FakeAuthRepository.erroring(
            StateError('auth backend unavailable'),
          ),
          gateEnabled: true,
        );

        await tester.pumpWidget(_wrapRouter(container));
        await _drain(tester);

        expect(find.byType(AccountScreen), findsOneWidget);
        expect(find.byKey(const Key('account-email-field')), findsOneWidget);
        expect(find.byType(ToposScreen), findsNothing);
        expect(find.byKey(const Key('nav-tab-topos')), findsNothing);
      },
    );

    testWidgets(
      'gate DISABLED (the native default) + signed-out: NO redirect — the '
      'local-first app stays fully usable signed out, unchanged (regression '
      'guard for iOS/Android)',
      (tester) async {
        final container = _makeGateContainer(
          authState: const AuthSessionState.signedOut(),
          gateEnabled: false,
        );

        await tester.pumpWidget(_wrapRouter(container));
        await _drain(tester);

        expect(find.byType(ToposScreen), findsOneWidget);
        expect(find.byKey(const Key('nav-tab-topos')), findsOneWidget);
        expect(find.byType(AccountScreen), findsNothing);
      },
    );

    testWidgets(
      'gate enabled + signed-out, already on /account: stays there — no '
      'redirect loop out of the sign-in view itself',
      (tester) async {
        final container = _makeGateContainer(
          authState: const AuthSessionState.signedOut(),
          gateEnabled: true,
        );

        await tester.pumpWidget(_wrapRouter(container));
        await _drain(tester);
        appRouter.go('/account');
        await _drain(tester);

        expect(find.byType(AccountScreen), findsOneWidget);
        expect(find.byKey(const Key('account-email-field')), findsOneWidget);
      },
    );
  });
}
