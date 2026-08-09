import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../../topo/data/photo_path_resolution.dart';
import '../../topo/data/photo_repository.dart';
import '../../topo/domain/topo_route.dart';
import '../../topo/presentation/grade_colors.dart';
import '../../topo/presentation/photo_image.dart';
import '../../topo/presentation/route_palette.dart';
import '../../topo/presentation/topo_painter.dart';

/// The colour a PROPOSED line is drawn in, in both the propose canvas and the
/// owner's diff.
///
/// One colour for both, deliberately: the person drawing and the person
/// deciding are looking at the same picture, and a proposal that changed
/// colour between being made and being reviewed would read as two different
/// things. It is deliberately not on [kRoutePalette] — a proposal must never
/// be mistakable for a line that is already on the topo.
const Color kProposedLineColor = Color(0xFF00E5FF);

/// A photo with the lines already on it, plus at most one proposed line drawn
/// over the top (community editing phase 7b / C-5b, requirement 3).
///
/// This is the visual diff, and it is the whole reason geometry got its own
/// phase: nobody can review a line by reading coordinates. The existing routes
/// render in their normal colours and the proposal in [kProposedLineColor], so
/// "is this better than what is there" is one glance rather than an act of
/// imagination.
///
/// Deliberately NOT built on `TopoCanvas`. That widget is the owner's editor —
/// it writes through `DrawController` to the repository, and pointing it at
/// somebody else's topo would put a stranger's drawing one code path away from
/// the routes table. Nothing here can write anything.
///
/// Points are percent-space fractions of [photo], so the painter is handed the
/// DISPLAY size rather than the image's natural size: percent × display is the
/// same transform at any scale, and it means this renders correctly in a
/// thumbnail-sized inbox row and full-screen without a second code path.
class TopoLineView extends StatelessWidget {
  const TopoLineView({
    super.key,
    required this.photo,
    required this.routes,
    this.proposedPoints = const [],
    this.proposedSymbols = const [],
    this.replacedRouteNumber,
    this.onTapPercent,
    this.useThumbnail = false,
  });

  final PhotoRef photo;

  /// The lines already on this photo.
  final List<TopoRoute> routes;

  /// The line being proposed, in percent space. Empty renders the topo as it
  /// stands, which is what the propose canvas shows before the first tap.
  final List<Offset> proposedPoints;

  final List<TopoSymbol> proposedSymbols;

  /// When a proposal REPLACES an existing line, that line's number.
  ///
  /// It is dropped from the underlay rather than drawn: showing both would ask
  /// the owner to tell two lines apart by colour at the exact moment the
  /// answer matters most, and the old one is still one tap away in the topo
  /// itself. What is on screen is what accepting would produce.
  final int? replacedRouteNumber;

  /// Tapping the photo, in percent space. Null makes this read-only, which is
  /// how the owner's diff uses it.
  final void Function(Offset percent)? onTapPercent;

  /// Render [photo]'s downscaled `thumbs/<id>.jpg` derivative instead of the
  /// full-resolution original.
  ///
  /// For the suggestions inbox, and only for it. That screen puts EVERY
  /// unanswered suggestion on screen at once, each one a photo in a 180px-tall
  /// row: at full resolution a single 24.5 MP original is ~98 MB of decoded
  /// RGBA, so a handful of pending suggestions was several hundred megabytes of
  /// bitmap behind boxes the size of a stamp. Mobile Safari — the primary
  /// target — answers that by silently discarding the page and reloading it,
  /// which is why this is a crash risk and not a slowness complaint.
  ///
  /// DEFAULTS TO FALSE AND MUST STAY THAT WAY. `propose_line_screen` renders
  /// this same widget inside a 6x-zoom `InteractiveViewer` so a stranger can
  /// place a line on an individual hold; a 512px-max-edge thumbnail blown up
  /// 6x is precisely the mush that makes that impossible. The two uses want
  /// opposite things from the same widget, so the caller says which.
  ///
  /// [thumbKeyFor] only rewrites the basename, so it composes with every path
  /// shape [PhotoImage] re-resolves (a relative storage key, a legacy absolute
  /// path, a stale absolute one pending self-heal) — same derivation
  /// `photo_strip.dart`'s 52px tile and `LibraryCrudRepository
  /// ._resolveThumbnail` already use. A photo that predates thumbnail
  /// generation has no bytes behind that key and degrades to the same
  /// `placeholder` any unreadable photo gets, never a broken-image glyph.
  final bool useThumbnail;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final display = _fit(constraints);
        if (display.isEmpty) return const SizedBox.shrink();

        final underlay = replacedRouteNumber == null
            ? routes
            : [for (final r in routes) if (r.number != replacedRouteNumber) r];

        final content = Stack(
          children: [
            SizedBox(
              width: display.width,
              height: display.height,
              child: PhotoImage(
                // See [useThumbnail] — the inbox row gets the small
                // derivative, the propose canvas the full-resolution
                // original.
                useThumbnail ? thumbKeyFor(photo.localPath) : photo.localPath,
                fit: BoxFit.fill,
                placeholder: () => ColoredBox(
                  color: MasiColors.of(context).surface2,
                  child: const SizedBox.expand(),
                ),
              ),
            ),
            CustomPaint(
              size: display,
              painter: TopoPainter(
                imageSize: display,
                routes: underlay,
                currentPoints: proposedPoints,
                currentSymbols: proposedSymbols,
                // Handles mark where a tap landed, so they belong to the
                // person drawing and are noise to the person reviewing.
                showHandles: onTapPercent != null,
                palette: kRoutePalette,
                currentColor: kProposedLineColor,
                handleColor: kProposedLineColor,
                routeColorResolver: topoRouteColor,
              ),
            ),
          ],
        );

        return SizedBox(
          width: display.width,
          height: display.height,
          child: onTapPercent == null
              ? content
              : GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  // `localPosition` is already in this box's coordinates, and
                  // this box is exactly `display` — so the percent conversion
                  // is a plain divide, with no transform to invert. It stays
                  // true inside an InteractiveViewer too: a gesture detector
                  // BELOW the transform receives untransformed local
                  // coordinates, which is why the zoom wrapper lives outside
                  // this widget rather than in it.
                  onTapUp: (details) {
                    final local = details.localPosition;
                    onTapPercent!(
                      Offset(
                        (local.dx / display.width).clamp(0.0, 1.0),
                        (local.dy / display.height).clamp(0.0, 1.0),
                      ),
                    );
                  },
                  child: content,
                ),
        );
      },
    );
  }

  /// CONTAIN-fits the photo's aspect ratio into [constraints].
  ///
  /// Contain, not cover: a cropped photo would hide part of the wall, and a
  /// line proposed against the part that is off-screen cannot be judged — or,
  /// worse, cannot be drawn at all.
  Size _fit(BoxConstraints constraints) {
    if (photo.width <= 0 || photo.height <= 0) return Size.zero;
    final aspect = photo.width / photo.height;
    final maxWidth = constraints.maxWidth.isFinite
        ? constraints.maxWidth
        : photo.width.toDouble();
    final maxHeight = constraints.maxHeight.isFinite
        ? constraints.maxHeight
        : maxWidth / aspect;
    if (maxWidth <= 0 || maxHeight <= 0) return Size.zero;

    final byWidth = Size(maxWidth, maxWidth / aspect);
    return byWidth.height <= maxHeight
        ? byWidth
        : Size(maxHeight * aspect, maxHeight);
  }
}
