import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/database_provider.dart';
import '../../topo/data/photo_path_resolution.dart';
import '../../topo/domain/topo_route.dart';

/// Which route on which wall a feed row wants a picture of.
typedef AscentRouteKey = ({String wallId, int routeNumber});

/// Everything needed to draw one route on its rock: the photo to crop, its
/// pixel dimensions (see [routeCropRect] for why those are not optional), and
/// the single route to draw.
typedef AscentRouteArt = ({
  String thumbnailPath,
  int imageWidth,
  int imageHeight,
  TopoRoute route,
});

/// Resolves the photo + geometry behind a shared ascent, so the feed can show
/// the line the climber actually did rather than a coloured square.
///
/// Returns `null` for every "cannot draw this" case, and there are several
/// legitimate ones: a wall whose photo has not synced down yet, a route number
/// that no longer resolves (the ascent's route was deleted), or a photo with no
/// recorded dimensions. Each falls back to the grade swatch, which is what the
/// row showed before — a missing picture must never be an error state in a
/// scrolling list.
///
/// Reads the wall's PRIMARY photo the same way `routeEntriesForWallProvider`
/// does, and scopes `loadRoutes` to that same photo id. Routes are numbered
/// independently per photo (see `RouteRepository`'s class doc), so an unscoped
/// lookup would happily return a DIFFERENT photo's route with the same number
/// and draw the wrong line on the wrong rock.
///
/// `autoDispose` because this is keyed per feed row: a family member for every
/// ascent ever scrolled past would otherwise hold its photo metadata for the
/// life of the app.
final ascentRouteArtProvider = FutureProvider.autoDispose
    .family<AscentRouteArt?, AscentRouteKey>((ref, key) async {
      final photo = await ref
          .watch(photoRepositoryProvider)
          .loadOriginal(key.wallId);
      if (photo == null) return null;
      if (photo.width <= 0 || photo.height <= 0) return null;

      final routes = await ref
          .watch(routeRepositoryProvider)
          .loadRoutes(key.wallId, photo.id);

      TopoRoute? match;
      for (final route in routes) {
        if (route.number == key.routeNumber) {
          match = route;
          break;
        }
      }
      if (match == null || match.points.isEmpty) return null;

      // The 512 px thumbnail, not the original — this renders in a scrolling
      // list, and #56 exists because decoding originals there is what made the
      // feed stutter. `routeCropRect`'s resolution floor is set against exactly
      // this source size.
      final thumbnailPath = ref
          .watch(photoFilesProvider)
          .resolvePhotoPathSync(thumbKeyFor(photo.localPath))
          .path;

      return (
        thumbnailPath: thumbnailPath,
        imageWidth: photo.width,
        imageHeight: photo.height,
        route: match,
      );
    });
