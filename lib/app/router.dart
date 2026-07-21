import 'package:go_router/go_router.dart';

import 'nav_shell.dart';
import '../features/account/presentation/account_screen.dart';
import '../features/ar/presentation/ar_screen.dart';
import '../features/community/presentation/ascent_detail_screen.dart';
import '../features/community/presentation/community_screen.dart';
import '../features/community/presentation/community_topo_detail_screen.dart';
import '../features/library/presentation/areas_screen.dart';
import '../features/library/presentation/sectors_screen.dart';
import '../features/library/presentation/topos_screen.dart';
import '../features/library/presentation/walls_screen.dart';
import '../features/logbook/presentation/logbook_screen.dart';
import '../features/topo/presentation/topo_canvas_screen.dart';

/// Where the legacy `/community` deep link (`?tab=`/`?focus=` query params —
/// see `CommunityScreen`'s old `initialTab`/`focusWallId`, since replaced by
/// the persistent bottom-nav's separate Map (`/map`) and Feed (`/feed`)
/// branches — this app's real `home-community-button`/"Show on map" actions
/// still build this exact path) should redirect to.
///
/// Factored out as a pure function (rather than inlined in the `GoRoute`'s
/// `redirect` below) so the target-path logic is unit-testable directly
/// against a plain query-parameter map, without a real [GoRouterState].
///
/// `tab=feed` sends the legacy link to the Feed branch (`/feed`); anything
/// else (including no `tab` at all — `CommunityScreen` used to default to
/// Map) sends it to the Map branch (`/map`), carrying an optional
/// `focus=<wallId>` along as `/map`'s own `focus` query param, exactly as
/// `CommunityScreen.focusWallId` used to.
String communityRedirectTarget(Map<String, String> queryParameters) {
  if (queryParameters['tab'] == 'feed') return '/feed';
  final focus = queryParameters['focus'];
  return focus != null ? '/map?focus=$focus' : '/map';
}

final appRouter = GoRouter(
  routes: [
    // The persistent bottom-nav shell (see `nav_shell.dart`'s `NavShell`):
    // three `IndexedStack` branches — Topos (home, index 0) / Map (index 1)
    // / Feed (index 2) — each preserving its own navigator/scroll state
    // across tab switches. Every route BELOW this one is a top-level
    // sibling instead, so it builds on the ROOT navigator and appears
    // full-screen, above the bottom bar (see `NavShell`'s doc).
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) =>
          NavShell(navigationShell: navigationShell),
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/',
              builder: (context, state) => const ToposScreen(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/map',
              builder: (context, state) => CommunityMapScreen(
                focusWallId: state.uri.queryParameters['focus'],
              ),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/feed',
              builder: (context, state) => const CommunityFeedScreen(),
            ),
          ],
        ),
      ],
    ),
    // The legacy Community discovery path — see [communityRedirectTarget]'s
    // doc. Kept alive (rather than removed) since it's still built by
    // `topos_screen.dart`'s "Show on map" action and any old bookmark/deep
    // link.
    GoRoute(
      path: '/community',
      redirect: (context, state) =>
          communityRedirectTarget(state.uri.queryParameters),
    ),
    GoRoute(
      path: '/account',
      builder: (context, state) => const AccountScreen(),
    ),
    // A shared topo's read-only detail — reached by `context.push`ing this
    // exact path from the Feed/Map screens' rows/markers. Full-screen, above
    // the bottom nav (see `NavShell`'s doc) — a focused, single-topo view is
    // not one of the three persistent tabs.
    GoRoute(
      path: '/community/topo/:wallId',
      builder: (context, state) =>
          CommunityTopoDetailScreen(wallId: state.pathParameters['wallId']!),
    ),
    // A shared ascent log's read-only detail (Feature #12, public opt-in
    // ascent logs) — see AscentDetailScreen's class doc.
    GoRoute(
      path: '/community/ascent/:id',
      builder: (context, state) =>
          AscentDetailScreen(ascentId: state.pathParameters['id']!),
    ),
    // The personal ascent Logbook (see LogbookScreen's class doc).
    GoRoute(
      path: '/logbook',
      builder: (context, state) => const LogbookScreen(),
    ),
    GoRoute(path: '/areas', builder: (context, state) => const AreasScreen()),
    GoRoute(
      path: '/areas/:areaId/sectors',
      builder: (context, state) => SectorsScreen(
        areaId: state.pathParameters['areaId']!,
        areaName: state.extra as String?,
      ),
    ),
    GoRoute(
      path: '/sectors/:sectorId/walls',
      builder: (context, state) => WallsScreen(
        sectorId: state.pathParameters['sectorId']!,
        sectorName: state.extra as String?,
      ),
    ),
    // The wall-detail route hosts the real topo canvas, bound to the
    // navigated wall (see TopoCanvasScreen.wallId).
    GoRoute(
      path: '/walls/:wallId',
      builder: (context, state) =>
          TopoCanvasScreen(wallId: state.pathParameters['wallId']!),
    ),
    // The AR alignment view for a wall — see ArScreen's class doc for the
    // native-camera-vs-overlay platform split.
    GoRoute(
      path: '/walls/:wallId/ar',
      builder: (context, state) =>
          ArScreen(wallId: state.pathParameters['wallId']!),
    ),
  ],
);
