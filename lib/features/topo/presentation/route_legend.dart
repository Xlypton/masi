import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:climbtopo/features/topo/application/draw_controller.dart';
import 'package:climbtopo/features/topo/presentation/route_palette.dart';

/// Height of the [RouteLegend] panel when it has at least one route to
/// show. Fixed so it doesn't fight the canvas above it for space as the
/// route count grows; it scrolls internally instead.
const double _legendHeight = 140.0;

/// Lists every route in [DrawState.routes]: a color swatch (from
/// [kRoutePalette]) and number, a visibility toggle
/// ([DrawController.toggleRouteVisibility]), a delete control
/// ([DrawController.removeRoute]), and select-on-tap
/// ([DrawController.selectRoute]). Renders nothing if there are no routes
/// yet.
class RouteLegend extends ConsumerWidget {
  const RouteLegend({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final drawState = ref.watch(drawControllerProvider);
    final notifier = ref.read(drawControllerProvider.notifier);

    if (drawState.routes.isEmpty) {
      return const SizedBox.shrink();
    }

    return SizedBox(
      key: const Key('topo-route-legend'),
      height: _legendHeight,
      child: ListView.builder(
        itemCount: drawState.routes.length,
        itemBuilder: (context, index) {
          final route = drawState.routes[index];
          final isSelected = route.id == drawState.selectedRouteId;
          final color = kRoutePalette.isEmpty
              ? Theme.of(context).colorScheme.primary
              : kRoutePalette[route.colorIndex % kRoutePalette.length];

          return ListTile(
            key: Key('topo-route-legend-item-${route.id}'),
            selected: isSelected,
            onTap: () => notifier.selectRoute(route.id),
            leading: CircleAvatar(backgroundColor: color, radius: 10),
            title: Text('Route ${route.number}'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  key: Key('topo-route-visibility-${route.id}'),
                  tooltip: route.visible ? 'Hide route' : 'Show route',
                  icon: Icon(
                    route.visible
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                  onPressed: () => notifier.toggleRouteVisibility(route.id),
                ),
                IconButton(
                  key: Key('topo-route-delete-${route.id}'),
                  tooltip: 'Delete route',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => notifier.removeRoute(route.id),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
