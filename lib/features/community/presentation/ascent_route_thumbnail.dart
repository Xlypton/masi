import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/presentation/masi_shimmer.dart';
import '../application/ascent_route_art_providers.dart';
import 'route_art_picture.dart';

/// The rock a logged ascent was climbed on, cropped to the one route the
/// climber did and drawn with that route's line over it.
///
/// This replaces a flat colour swatch keyed on grade band. A grade tells you
/// how hard; it tells you nothing about which line, and a feed of shared
/// ascents is mostly people you follow doing routes you might recognise. The
/// picture is the recognisable part.
///
/// The picture itself — the crop arithmetic and the topo painter — lives in
/// [RouteArtPicture], shared with the ascent detail screen's larger header so
/// the row you tap and the screen you land on frame the same thing.
///
/// Every unresolvable case falls back to [fallback] — the grade swatch this
/// replaced. A photo that has not synced, a deleted route, a photo with no
/// recorded dimensions: all of them mean "show what the row used to show",
/// never a broken-image glyph and never an error.
class AscentRouteThumbnail extends ConsumerWidget {
  const AscentRouteThumbnail({
    super.key,
    required this.wallId,
    required this.routeNumber,
    required this.size,
    required this.fallback,
  });

  final String wallId;

  /// The [TopoRoute.number] this ascent was logged against. `null` when the
  /// ascent's route can no longer be joined, which goes straight to [fallback].
  final int? routeNumber;

  /// The tile's side. Square, matching the feed's other leading tiles.
  final double size;

  /// Drawn whenever there is no picture to show. Built lazily so the common
  /// case does not construct a widget it will not use.
  final Widget Function() fallback;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final number = routeNumber;
    if (number == null) return fallback();

    final art = ref.watch(
      ascentRouteArtProvider((wallId: wallId, routeNumber: number)),
    );

    // `asData?.value` rather than `.when`: a first load must not flash an
    // error or a spinner into a scrolling list. While it resolves, and forever
    // after if it resolves to null, the row shows exactly what it always did.
    final resolved = art.asData?.value;
    if (resolved == null) {
      return art.isLoading
          ? SizedBox(
              width: size,
              height: size,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: const MasiShimmer(),
              ),
            )
          : fallback();
    }

    final crop = routeArtCrop(resolved);
    if (crop == null) return fallback();

    return RouteArtPicture(
      storedPath: resolved.thumbnailPath,
      route: resolved.route,
      crop: crop,
      side: size,
      // The tile's own suite pumps bounded frames, so an unbounded shimmer is
      // safe here — see [RouteArtPicture.loadingPlaceholder] for why it is not
      // the default.
      loadingPlaceholder: () => const MasiShimmer(),
    );
  }
}
