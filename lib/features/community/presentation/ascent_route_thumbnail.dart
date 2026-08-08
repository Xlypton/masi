import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../shared/presentation/masi_shimmer.dart';
import '../../topo/presentation/grade_colors.dart';
import '../../topo/presentation/photo_image.dart';
import '../../topo/presentation/route_palette.dart';
import '../../topo/presentation/topo_painter.dart';
import '../application/ascent_route_art_providers.dart';
import '../domain/route_crop.dart';

/// The rock a logged ascent was climbed on, cropped to the one route the
/// climber did and drawn with that route's line over it.
///
/// This replaces a flat colour swatch keyed on grade band. A grade tells you
/// how hard; it tells you nothing about which line, and a feed of shared
/// ascents is mostly people you follow doing routes you might recognise. The
/// picture is the recognisable part.
///
/// **Only the climbed route is drawn.** The photo behind it usually carries a
/// dozen lines, and rendering them all would put the viewer back where they
/// started — hunting for which one this ascent was about. So the painter is
/// handed a single-element route list, not the wall's routes.
///
/// **It fills the box.** The crop is square in PIXEL space (see
/// [routeCropRect]) and the photo is then scaled so that square maps exactly
/// onto this tile, which is what makes `BoxFit.fill` safe here: the box and the
/// source region have the same aspect ratio by construction, so nothing is
/// stretched. Using `BoxFit.cover` on the whole photo instead would be the
/// obvious-looking approach and would silently crop away the route.
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

    final crop = routeCropRect(
      points: resolved.route.points,
      imageWidth: resolved.imageWidth,
      imageHeight: resolved.imageHeight,
    );
    if (crop == null) return fallback();

    // The photo is drawn at the size that makes `crop` land exactly on this
    // tile: scaled = size / crop-fraction on each axis, then translated so the
    // crop's top-left sits at the tile's origin.
    //
    // Because `crop` is square in pixels, scaled.width / scaled.height equals
    // the photo's own aspect ratio — which is precisely why `BoxFit.fill`
    // below distorts nothing.
    final scaled = Size(size / crop.width, size / crop.height);
    final dx = -crop.left * scaled.width;
    final dy = -crop.top * scaled.height;

    // Decode at what is actually painted, not at the photo's full resolution —
    // the tile is `size` logical px but the photo is drawn `1/crop` times
    // larger than that, so the decode target is the SCALED size.
    final ratio = MediaQuery.of(context).devicePixelRatio;

    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            Positioned(
              left: dx,
              top: dy,
              width: scaled.width,
              height: scaled.height,
              child: PhotoImage(
                resolved.thumbnailPath,
                width: scaled.width,
                height: scaled.height,
                fit: BoxFit.fill,
                cacheWidth: (scaled.width * ratio).round(),
                cacheHeight: (scaled.height * ratio).round(),
                placeholder: () => _RockFallback(colors: MasiColors.of(context)),
                loadingPlaceholder: () => const MasiShimmer(),
              ),
            ),
            Positioned(
              left: dx,
              top: dy,
              width: scaled.width,
              height: scaled.height,
              child: CustomPaint(
                size: scaled,
                painter: TopoPainter(
                  // Percent x display is the same transform at any scale, so
                  // handing the painter the DISPLAY size is all it takes to
                  // draw the line correctly over a magnified crop —
                  // `TopoLineView` relies on the same property.
                  imageSize: scaled,
                  // `visible: true` forced: that flag is the OWNER's editor
                  // toggle for decluttering their own canvas, and it has no
                  // business deciding whether somebody else's logged ascent
                  // gets a picture. TopoPainter skips an invisible route
                  // entirely, so without this the tile would silently fall
                  // back for every ascent on a route its author had hidden.
                  routes: [resolved.route.copyWith(visible: true)],
                  // Nothing is being drawn here, so there is no in-progress
                  // line and no handles to mark where a tap landed.
                  currentPoints: const [],
                  showHandles: false,
                  palette: kRoutePalette,
                  routeColorResolver: topoRouteColor,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// What a tile shows when the photo bytes themselves will not render. Kept
/// deliberately plain — a broken-image glyph in a feed reads as the app being
/// broken, which it is not: the photo simply is not on this device.
class _RockFallback extends StatelessWidget {
  const _RockFallback({required this.colors});

  final MasiColors colors;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [colors.amethyst300, colors.amethyst500],
        ),
      ),
      child: const SizedBox.expand(),
    );
  }
}
