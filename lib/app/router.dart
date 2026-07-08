import 'package:go_router/go_router.dart';

import '../features/topo/presentation/topo_canvas_screen.dart';

final appRouter = GoRouter(
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => const TopoCanvasScreen(),
    ),
  ],
);
