import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/database_provider.dart';
import '../../topo/data/photo_repository.dart';
import '../../topo/domain/topo_route.dart';

/// Everything needed to draw a line on somebody else's topo, or to render a
/// proposed one back to its owner (community editing phase 7b / C-5b).
///
/// All of it comes from the LOCAL database. A published topo's photos and
/// routes are pulled into the same `photos`/`routes` tables as the reader's
/// own, so a proposer and an owner are looking at the same rows — which is
/// what makes the diff a diff rather than two different pictures.
class TopoGeometry {
  const TopoGeometry({
    required this.photo,
    required this.routes,
    required this.routeIdsByNumber,
  });

  final PhotoRef photo;

  /// The lines already on [photo], as the canvas draws them.
  final List<TopoRoute> routes;

  /// `TopoRoute.number` → the route table's own text uuid.
  ///
  /// The reason this map exists at all is §C-5b's second requirement:
  /// [TopoRoute.id] is an int reassigned 1..n on every load, so it cannot
  /// cross the wire. Anything naming a route to the server names it from here.
  final Map<int, String> routeIdsByNumber;

  String? dbIdFor(TopoRoute route) => routeIdsByNumber[route.number];
}

/// Which photo of a topo to resolve geometry for.
///
/// A null [photoId] means the primary one, which is what the propose canvas
/// opens on. An explicit id is what the owner's inbox passes: a proposal is
/// pinned to the photo it was DRAWN on, and a topo can carry several, each
/// with its own independent set of routes. Resolving the primary there would
/// draw a line proposed on the second photo over the first — a diff that is
/// not merely unhelpful but actively misleading.
typedef TopoGeometryKey = ({String wallId, String? photoId});

/// Resolves [TopoGeometry], or null when the requested photo is not there —
/// which is not an error but a real state: a topo with no photo has nothing
/// to draw on, and a suggestion pinned to a deleted one cannot be shown.
final topoGeometryProvider = FutureProvider.autoDispose
    .family<TopoGeometry?, TopoGeometryKey>((ref, key) async {
      final photos = ref.watch(photoRepositoryProvider);
      final PhotoRef? photo;
      if (key.photoId case final id?) {
        final all = await photos.loadOriginals(key.wallId);
        photo = all.where((p) => p.id == id).firstOrNull;
      } else {
        photo = await photos.loadOriginal(key.wallId);
      }
      if (photo == null) return null;

      final routes = ref.watch(routeRepositoryProvider);
      return TopoGeometry(
        photo: photo,
        routes: await routes.loadRoutes(key.wallId, photo.id),
        routeIdsByNumber: await routes.routeDbIdsByNumber(key.wallId, photo.id),
      );
    });
