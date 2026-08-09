import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../../topo/domain/topo_route.dart';
import '../../topo/presentation/grade_colors.dart';
import '../../topo/presentation/photo_image.dart';
import '../../topo/presentation/route_palette.dart';
import '../../topo/presentation/topo_painter.dart';
import '../application/ascent_route_art_providers.dart';
import '../domain/route_crop.dart';

/// The square frame of [art]'s photo that puts its one route in the middle, or
/// `null` when there is nothing to frame.
///
/// A one-line wrapper over [routeCropRect], but a shared one on purpose: the
/// two surfaces that show a logged ascent's route — the feed's tile and the
/// ascent detail screen's header — must agree on WHAT is being framed, or the
/// picture the user taps and the picture they land on are different pictures.
Rect? routeArtCrop(AscentRouteArt art) => routeCropRect(
  points: art.route.points,
  imageWidth: art.imageWidth,
  imageHeight: art.imageHeight,
);

/// One climbed route, drawn over the rock it was climbed on, in a [side]-square
/// box.
///
/// This is the picture itself and nothing else — no provider, no loading state,
/// no fallback chain. Those differ per surface (a feed row degrades to its
/// grade swatch; the detail header degrades to showing nothing at all), but the
/// crop arithmetic and the [TopoPainter] wiring below must not: two copies of
/// this would drift, and a drifted copy draws the wrong line on the wrong rock.
///
/// **Only the climbed route is drawn.** The photo behind it usually carries a
/// dozen lines, and rendering them all would put the viewer back where they
/// started — hunting for which one this ascent was about. So the painter is
/// handed a single-element route list, not the wall's routes.
///
/// **It fills the box.** [crop] is square in PIXEL space (see [routeCropRect])
/// and the photo is then scaled so that square maps exactly onto this box,
/// which is what makes `BoxFit.fill` safe here: the box and the source region
/// have the same aspect ratio by construction, so nothing is stretched. Using
/// `BoxFit.cover` on the whole photo instead would be the obvious-looking
/// approach and would silently crop away the route.
class RouteArtPicture extends StatelessWidget {
  const RouteArtPicture({
    super.key,
    required this.storedPath,
    required this.route,
    required this.crop,
    required this.side,
    this.borderRadius = 10,
    this.loadingPlaceholder,
  });

  /// The stored photo to draw, already resolved for this platform — see
  /// [PhotoImage].
  final String storedPath;

  /// The one route to draw over it.
  final TopoRoute route;

  /// Which square of the photo to show, in normalized coordinates — from
  /// [routeArtCrop].
  final Rect crop;

  /// The box's side. Square, because [crop] is.
  final double side;

  final double borderRadius;

  /// What to show while the photo's bytes are still being read, distinct from
  /// the "these bytes are not on this device" gradient which is always shown.
  ///
  /// `null` (the default) means the gradient covers both states. That is not
  /// laziness: an unbounded shimmer over a bitmap slot whose load a widget test
  /// cannot complete turns every `pumpAndSettle` in the file into a timeout
  /// (see `MasiSkeleton`'s class doc, which was written after that happened to
  /// 46 tests). The feed's small tile opts in because its own suite pumps
  /// bounded frames; a screen full of ordinary `pumpAndSettle` callers should
  /// not.
  final Widget Function()? loadingPlaceholder;

  @override
  Widget build(BuildContext context) {
    // The photo is drawn at the size that makes `crop` land exactly on this
    // box: scaled = side / crop-fraction on each axis, then translated so the
    // crop's top-left sits at the box's origin.
    //
    // Because `crop` is square in pixels, scaled.width / scaled.height equals
    // the photo's own aspect ratio — which is precisely why `BoxFit.fill`
    // below distorts nothing.
    final scaled = Size(side / crop.width, side / crop.height);
    final dx = -crop.left * scaled.width;
    final dy = -crop.top * scaled.height;

    // Decode at what is actually painted, not at the photo's full resolution —
    // the box is `side` logical px but the photo is drawn `1/crop` times
    // larger than that, so the decode target is the SCALED size. Asking for
    // more pixels than the file holds costs nothing: `cacheWidth`/`cacheHeight`
    // reach `ResizeImage` with `allowUpscaling: false`, which clamps the target
    // down to the source's own dimensions.
    final ratio = MediaQuery.of(context).devicePixelRatio;

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: SizedBox(
        width: side,
        height: side,
        child: Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            Positioned(
              left: dx,
              top: dy,
              width: scaled.width,
              height: scaled.height,
              child: PhotoImage(
                storedPath,
                width: scaled.width,
                height: scaled.height,
                fit: BoxFit.fill,
                cacheWidth: (scaled.width * ratio).round(),
                cacheHeight: (scaled.height * ratio).round(),
                placeholder: () => RockFallback(colors: MasiColors.of(context)),
                loadingPlaceholder: loadingPlaceholder,
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
                  // entirely, so without this the picture would silently fall
                  // back for every ascent on a route its author had hidden.
                  routes: [route.copyWith(visible: true)],
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

/// What a route picture shows when the photo bytes themselves will not render.
/// Kept deliberately plain — a broken-image glyph reads as the app being
/// broken, which it is not: the photo simply is not on this device.
class RockFallback extends StatelessWidget {
  const RockFallback({super.key, required this.colors});

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
