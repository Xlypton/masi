import 'package:go_router/go_router.dart';

import '../features/ar/presentation/ar_screen.dart';
import '../features/library/presentation/areas_screen.dart';
import '../features/library/presentation/sectors_screen.dart';
import '../features/library/presentation/walls_screen.dart';
import '../features/topo/presentation/topo_canvas_screen.dart';

final appRouter = GoRouter(
  routes: [
    GoRoute(path: '/', builder: (context, state) => const AreasScreen()),
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
      builder: (context, state) => TopoCanvasScreen(
        wallId: state.pathParameters['wallId']!,
      ),
    ),
    // The AR alignment view for a wall — see ArScreen's class doc for the
    // native-camera-vs-overlay platform split.
    GoRoute(
      path: '/walls/:wallId/ar',
      builder: (context, state) => ArScreen(
        wallId: state.pathParameters['wallId']!,
      ),
    ),
  ],
);
