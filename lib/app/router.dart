import 'package:go_router/go_router.dart';

import '../features/account/presentation/account_screen.dart';
import '../features/ar/presentation/ar_screen.dart';
import '../features/community/presentation/community_screen.dart';
import '../features/community/presentation/community_topo_detail_screen.dart';
import '../features/library/presentation/areas_screen.dart';
import '../features/library/presentation/sectors_screen.dart';
import '../features/library/presentation/topos_screen.dart';
import '../features/library/presentation/walls_screen.dart';
import '../features/logbook/presentation/logbook_screen.dart';
import '../features/topo/presentation/topo_canvas_screen.dart';

/// Parses `/community`'s optional `?tab=`/`?focus=` query params (see
/// [CommunityScreen.initialTab]/[CommunityScreen.focusWallId]) into typed
/// values. Kept as a standalone pure function (rather than inlined in the
/// `GoRoute.builder` below) so the parsing itself is unit-testable against a
/// plain query-parameter map, without needing a real [GoRouterState] or
/// widget tree.
///
/// `tab=map` selects the Map tab; any other value (including absent, which
/// is every existing `/community` link/push in the app today) leaves `tab`
/// `null`, matching [CommunityScreen]'s previous unconditional Feed-tab
/// default exactly.
({CommunityTab? tab, String? focusWallId}) parseCommunityRouteParams(
  Map<String, String> queryParameters,
) {
  final tab = queryParameters['tab'] == 'map' ? CommunityTab.map : null;
  return (tab: tab, focusWallId: queryParameters['focus']);
}

final appRouter = GoRouter(
  routes: [
    GoRoute(path: '/', builder: (context, state) => const ToposScreen()),
    GoRoute(
      path: '/account',
      builder: (context, state) => const AccountScreen(),
    ),
    // The Community discovery feed/map (see CommunityScreen's class doc)
    // and its per-topo read-only detail, reached by `context.push`ing this
    // exact path from CommunityScreen's feed rows and map markers.
    GoRoute(
      path: '/community',
      builder: (context, state) {
        final params = parseCommunityRouteParams(state.uri.queryParameters);
        return CommunityScreen(
          initialTab: params.tab,
          focusWallId: params.focusWallId,
        );
      },
    ),
    GoRoute(
      path: '/community/topo/:wallId',
      builder: (context, state) =>
          CommunityTopoDetailScreen(wallId: state.pathParameters['wallId']!),
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
