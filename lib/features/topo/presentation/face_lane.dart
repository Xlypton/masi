import 'dart:math' as math;

import 'package:flutter/material.dart' hide Baseline;

import 'package:masi/app/theme.dart';
import 'package:masi/features/topo/data/photo_repository.dart';
import 'package:masi/features/topo/domain/face_layout/layout_resolver.dart';
import 'package:masi/features/topo/presentation/layout_plane_fit.dart';
import 'package:masi/shared/presentation/masi_icon.dart';

/// The two parts of the reader's way round a rock with several photos: a dot
/// per face ([FaceDots]), and a plan saying where each shot was taken from
/// ([FaceMinimap]).
///
/// Replaces the 52px thumbnail strip that used to sit in the top chrome. Six
/// thumbnails in upload order carried no spatial meaning — a reader could not
/// tell the north face from the right-hand half of the south face — and the
/// answer is not a better thumbnail, it is putting the photos somewhere. The
/// dots say how many and which one; the minimap says where.
///
/// Both are **dumb widgets**: they take their data and hand back taps, and
/// they read no provider. That is what lets `TopoDock` compose them into one
/// surface with the route list. The `FacePager` that used to own them was a
/// third floating panel in the bottom band, and every panel down there had to
/// reserve pixels for the next one by hand-maintained constant — a scheme that
/// drifted out of true three times (the draw hint, the dot row, and finally
/// the minimap, which ended up drawn ON TOP of the route legend). There is no
/// clearance arithmetic left to get wrong because there is nothing left to
/// clear.
///
/// Everything sensor-derived degrades silently. With no GPS and no headings
/// no view cone is drawn and the dots remain an ordered filmstrip, which is
/// the product rather than a fallback.
///
/// **Not built:** the design's "probably this one" chip, which highlights the
/// face a reader is standing in front of by comparing a LIVE compass heading
/// against each face's stored bearing. Everything on the stored side of that
/// comparison exists — `Photos.captureBearingDegrees`, the resolved position,
/// the orientation classifier — but the live side needs a magnetometer feed,
/// and this app has no compass dependency (`geolocator` gives position, not
/// heading). Adding one is a real decision, not an oversight to fill in
/// quietly: it is a new runtime permission surface on both platforms. The
/// screen is complete without it, which is the point of the hint being a hint.
/// The dot row: one tap target per face, in the order you walk past the rock.
class FaceDots extends StatelessWidget {
  const FaceDots({
    this.framed = true,
    super.key,
    required this.photos,
    required this.layout,
    required this.activePhotoId,
    required this.onSelect,
    required this.onManage,
    required this.colors,
  });

  /// Whether to draw the pill around the dots.
  ///
  /// False inside `TopoDock`, where the dock itself is the surface and a
  /// second bordered pill on top of it reads as a control that came loose.
  final bool framed;

  final List<PhotoRef> photos;
  final LayoutResult? layout;
  final String? activePhotoId;
  final void Function(PhotoRef photo) onSelect;
  final void Function(PhotoRef photo)? onManage;
  final MasiColors colors;

  @override
  Widget build(BuildContext context) {
    // Ordered by the layout when there is one — that is capture order, the
    // order you walk past the rock — and by the strip's own order otherwise.
    final ordered = <PhotoRef>[];
    final byId = {for (final photo in photos) photo.id: photo};
    for (final face in layout?.faces ?? const <FacePosition>[]) {
      final photo = byId.remove(face.id);
      if (photo != null) ordered.add(photo);
    }
    ordered.addAll(byId.values);

    return Container(
      key: const Key('face-pager-dots'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: framed
          ? BoxDecoration(
              color: colors.chrome,
              borderRadius: BorderRadius.circular(MasiRadii.large),
              border: Border.all(color: colors.separator),
            )
          : null,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final photo in ordered)
            GestureDetector(
              key: Key('face-dot-${photo.id}'),
              onTap: () => onSelect(photo),
              onLongPress:
                  onManage == null ? null : () => onManage!(photo),
              behavior: HitTestBehavior.opaque,
              child: Padding(
                // Padding, not margin: it is the tap target, and a 6px dot
                // with a 6px margin is a control nobody can hit.
                padding: const EdgeInsets.symmetric(
                  horizontal: 5,
                  vertical: 8,
                ),
                child: Container(
                  width: photo.id == activePhotoId ? 22 : 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: photo.id == activePhotoId
                        ? colors.accent
                        : colors.ink3,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The plan view: the baseline seen from above, with a dot per face.
class FaceMinimap extends StatelessWidget {
  const FaceMinimap({
    this.planSize = const Size(184, 100),
    this.framed = true,
    super.key,
    required this.layout,
    required this.photos,
    required this.activePhotoId,
    required this.onSelect,
    required this.onEditLayout,
    required this.colors,
  });

  final LayoutResult layout;
  final List<PhotoRef> photos;
  final String? activePhotoId;
  final void Function(PhotoRef photo) onSelect;
  final VoidCallback? onEditLayout;
  final MasiColors colors;

  /// How big to draw the plan itself, excluding the caption row below it.
  ///
  /// A parameter rather than a constant because the dock gives it the full
  /// width of the sheet, while a standalone use (tests, and any future
  /// caller) wants the compact card.
  final Size planSize;

  /// Whether to draw the card around the plan — false inside `TopoDock`, for
  /// the same reason as [FaceDots.framed].
  final bool framed;

  @override
  Widget build(BuildContext context) {
    final fit = LayoutPlaneFit.forBaseline(layout.baseline, planSize, padding: 12);

    return Container(
      key: const Key('face-pager-minimap'),
      padding: const EdgeInsets.all(8),
      decoration: framed
          ? BoxDecoration(
              color: colors.chrome,
              borderRadius: BorderRadius.circular(MasiRadii.large),
              border: Border.all(color: colors.separator),
            )
          : null,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: planSize.width,
            height: planSize.height,
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _MinimapPainter(
                      layout: layout,
                      fit: fit,
                      stroke: colors.amethyst400,
                      cone: colors.accent,
                      activePhotoId: activePhotoId,
                    ),
                  ),
                ),
                for (final face in layout.faces)
                  _hitTarget(face, fit),
              ],
            ),
          ),
          const SizedBox(height: 4),
          // A caption and a real button, not a caption that is secretly a
          // button. The whole line used to be tappable at 10px with the word
          // 'edit' appended — no affordance, no hit area worth the name, and
          // the only discoverable way into the editor.
          //
          // Width-limited to the plan box: an unbounded `spaceBetween` row
          // takes every pixel offered, and this card sits in a `Column` with
          // the whole screen to offer — which stretched a 184px minimap into
          // a full-bleed band across the topo.
          SizedBox(
            width: planSize.width,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
              Flexible(
                child: Text(
                  'where each photo was taken',
                  // One line, always. Wrapped to two it pushed the Edit
                  // button into a corner and made the card look broken.
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    letterSpacing: 0.4,
                    color: colors.ink2,
                  ),
                ),
              ),
              if (onEditLayout != null)
                GestureDetector(
                  key: const Key('face-pager-edit-layout'),
                  behavior: HitTestBehavior.opaque,
                  onTap: onEditLayout,
                  child: Container(
                    // 32px tall with the padding: small for a control, but
                    // this rides above the canvas and a 44px pill here eats
                    // the topo. The label carries the affordance.
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: colors.accent.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(MasiRadii.control),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        MasiIcon('edit', size: 12, color: colors.accent),
                        const SizedBox(width: 5),
                        Text(
                          'Edit',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: colors.accent,
                          ),
                        ),
                      ],
                    ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _hitTarget(FacePosition face, LayoutPlaneFit fit) {
    final at = fit.toCanvas(layout.baseline.pointAt(face.t));
    return Positioned(
      left: at.dx - 14,
      top: at.dy - 14,
      width: 28,
      height: 28,
      child: GestureDetector(
        key: Key('minimap-face-${face.id}'),
        behavior: HitTestBehavior.opaque,
        onTap: () {
          for (final photo in photos) {
            if (photo.id == face.id) {
              onSelect(photo);
              return;
            }
          }
        },
      ),
    );
  }
}

class _MinimapPainter extends CustomPainter {
  const _MinimapPainter({
    required this.layout,
    required this.fit,
    required this.stroke,
    required this.cone,
    required this.activePhotoId,
  });

  final LayoutResult layout;
  final LayoutPlaneFit fit;
  final Color stroke;
  final Color cone;
  final String? activePhotoId;

  @override
  void paint(Canvas canvas, Size size) {
    final line = layout.baseline;
    if (line.points.length < 2) return;

    final path = Path()
      ..moveTo(fit.toCanvas(line.points.first).dx,
          fit.toCanvas(line.points.first).dy);
    for (final point in line.points.skip(1)) {
      final at = fit.toCanvas(point);
      path.lineTo(at.dx, at.dy);
    }
    if (line.closed) path.close();

    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = stroke,
    );

    for (final face in layout.faces) {
      final at = fit.toCanvas(line.pointAt(face.t));
      final active = face.id == activePhotoId;

      // The cone is what each photo COVERS, drawn only where a real heading
      // put the face there. Drawing one from a capture-order guess would
      // invent a direction the data never claimed.
      if (face.placement == FacePlacement.bearingRefined ||
          face.placement == FacePlacement.gpsProjected) {
        final normal = line.normalAt(face.t);
        if (normal != null) {
          final direction =
              fit.directionToCanvas(normal * layout.thumbnailNormalSign);
          final length = math.sqrt(
            direction.dx * direction.dx + direction.dy * direction.dy,
          );
          if (length > 0) {
            final unit = direction / length;
            final tip = at + unit * 18;
            final side = Offset(-unit.dy, unit.dx) * 7;
            canvas.drawPath(
              Path()
                ..moveTo(at.dx, at.dy)
                ..lineTo(tip.dx + side.dx, tip.dy + side.dy)
                ..lineTo(tip.dx - side.dx, tip.dy - side.dy)
                ..close(),
              Paint()..color = cone.withValues(alpha: active ? 0.35 : 0.16),
            );
          }
        }
      }

      canvas.drawCircle(
        at,
        active ? 5 : 3.5,
        Paint()..color = active ? cone : cone.withValues(alpha: 0.55),
      );
    }
  }

  @override
  bool shouldRepaint(_MinimapPainter old) =>
      old.layout != layout || old.activePhotoId != activePhotoId;
}
