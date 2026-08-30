import 'dart:math' as math;

import 'package:flutter/material.dart' hide Baseline;

import 'package:masi/app/theme.dart';
import 'package:masi/features/topo/data/photo_repository.dart';
import 'package:masi/features/topo/domain/face_layout/layout_resolver.dart';
import 'package:masi/features/topo/presentation/layout_baseline_painter.dart';
import 'package:masi/features/topo/presentation/layout_plane_fit.dart';
import 'package:masi/features/topo/presentation/photo_image.dart';
import 'package:masi/features/topo/presentation/thumbnail_arrangement.dart';
import 'package:masi/shared/presentation/masi_icon.dart';

/// The reader's way round a rock with several photos: **the photos
/// themselves**, in a rail across the top of the dock.
///
/// This replaced a row of 7px dots plus a compass button plus a permanently
/// mounted plan view. The dots said how many faces there were and which one
/// you were on, and nothing else — a reader could not tell the north face
/// from the right-hand half of the south face without opening each in turn,
/// which is the exact question the screen exists to answer. A thumbnail is
/// already a picture of a side, so four of them say "there is a back and a
/// left side" better than any diagram, and the badge says which of them has
/// the climbing on it.
///
/// The abstract plan is not gone, it has moved to where it is worth its
/// space: the leading tile opens the full-screen map ([FaceMapScreen]), and
/// the layout editor is where it is manipulated. It used to sit permanently
/// above the route list at 153pt — most of what made this screen's bottom
/// half unusable on a phone — for a glance most readers take once.
///
/// A **dumb widget**: it takes its data and hands back taps, and reads no
/// provider. That is what lets `TopoDock` compose it into one surface with
/// the route list, with no clearance arithmetic between them.
///
/// Everything sensor-derived degrades silently. With no GPS and no headings
/// the rail is an ordered filmstrip in capture order, which is the product
/// rather than a fallback.
///
/// **Not built:** the design's "probably this one" chip, which highlights the
/// face a reader is standing in front of by comparing a LIVE compass heading
/// against each face's stored bearing. Everything on the stored side of that
/// comparison exists — `Photos.captureBearingDegrees`, the resolved position,
/// the orientation classifier — but the live side needs a magnetometer feed,
/// and this app has no compass dependency (`geolocator` gives position, not
/// heading). Adding one is a real decision, not an oversight to fill in
/// quietly: it is a new runtime permission surface on both platforms.
class FaceRail extends StatelessWidget {
  const FaceRail({
    super.key,
    required this.photos,
    required this.layout,
    required this.activePhotoId,
    required this.routeCounts,
    required this.onSelect,
    required this.onManage,
    required this.onOpenMap,
    required this.onAddPhoto,
    required this.colors,
  });

  final List<PhotoRef> photos;
  final LayoutResult? layout;
  final String? activePhotoId;

  /// How many climbs each photo shows, keyed by photo id. A photo missing
  /// from the map has none and gets no badge — see `wallRouteCountsProvider`.
  final Map<String, int> routeCounts;

  final void Function(PhotoRef photo) onSelect;
  final void Function(PhotoRef photo)? onManage;

  /// Opens the plan view. Null when there is no usable baseline to draw —
  /// a tile that opens an empty box is worse than no tile.
  final VoidCallback? onOpenMap;

  /// Adds another photo of this rock. Null when read-only.
  final VoidCallback? onAddPhoto;

  final MasiColors colors;

  /// The tile a reader is on. Wider than the rest, so the rail says which one
  /// it is by shape as well as by ring — a ring alone is one thin line of
  /// colour to find on a photo that may itself be purple rock.
  static const Size activeTile = Size(62, 44);
  static const Size tile = Size(48, 44);

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

    final dpr = MediaQuery.devicePixelRatioOf(context);

    return SingleChildScrollView(
      key: const Key('face-rail'),
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: MasiSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (onOpenMap case final open?) ...[
            _RailTile(
              key: const Key('face-rail-map'),
              caption: 'Map',
              size: tile,
              onTap: open,
              colors: colors,
              child: CustomPaint(
                painter: _PlanTilePainter(
                  layout: layout!,
                  stroke: colors.amethyst400,
                  dot: colors.accent,
                  activePhotoId: activePhotoId,
                ),
              ),
            ),
            // Hairline, thumb-height: the map is a different kind of thing
            // from the photos beside it, and without the rule it reads as a
            // fifth face nobody can place.
            Container(
              width: 1,
              height: tile.height,
              margin: const EdgeInsets.fromLTRB(
                MasiSpacing.xs,
                0,
                MasiSpacing.xs,
                0,
              ),
              color: colors.separator,
            ),
          ],
          for (var i = 0; i < ordered.length; i++)
            _faceTile(ordered[i], i, dpr),
          if (onAddPhoto case final add?)
            _RailTile(
              key: const Key('face-rail-add'),
              caption: 'Add',
              size: tile,
              onTap: add,
              colors: colors,
              accentOutline: true,
              child: Center(
                child: MasiIcon('add', size: 20, color: colors.accent),
              ),
            ),
        ],
      ),
    );
  }

  Widget _faceTile(PhotoRef photo, int index, double dpr) {
    final active = photo.id == activePhotoId;
    final size = active ? activeTile : tile;
    final count = routeCounts[photo.id] ?? 0;

    return _RailTile(
      key: Key('face-rail-tile-${photo.id}'),
      caption: '${index + 1}',
      captionStrong: active,
      size: size,
      selected: active,
      onTap: () => onSelect(photo),
      onLongPress: onManage == null ? null : () => onManage!(photo),
      colors: colors,
      child: Stack(
        fit: StackFit.expand,
        children: [
          PhotoImage(
            photo.localPath,
            fit: BoxFit.cover,
            // Width alone, never both: `ResizeImage`'s exact policy would
            // squash a portrait photo into the tile in the decoder, where
            // `BoxFit.cover` can no longer undo it. See [PhotoImage]'s doc.
            cacheWidth: (size.width * dpr).round(),
          ),
          if (count > 0)
            Positioned(
              right: 2,
              bottom: 2,
              child: Container(
                key: Key('face-rail-count-${photo.id}'),
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                // Black-on-white regardless of theme: this rides on a
                // photograph, not on a surface, so a themed colour pair would
                // be legible in the editor and invisible on a snowy slab.
                decoration: BoxDecoration(
                  color: const Color(0xB3000000),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '$count',
                  style: const TextStyle(
                    fontSize: 9,
                    height: 1.4,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFFFFFFFF),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One tile of the rail: a picture, a caption under it, and one tap target
/// covering both.
class _RailTile extends StatelessWidget {
  const _RailTile({
    super.key,
    required this.caption,
    required this.size,
    required this.onTap,
    required this.colors,
    required this.child,
    this.onLongPress,
    this.selected = false,
    this.captionStrong = false,
    this.accentOutline = false,
  });

  final String caption;
  final Size size;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final MasiColors colors;
  final Widget child;
  final bool selected;
  final bool captionStrong;
  final bool accentOutline;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        // Padding rather than margin: the whole column including the caption
        // is the tap target, and a 44px tile with a 5px gap beside it is a
        // control people miss on a cold morning with gloves on.
        padding: const EdgeInsets.symmetric(
          horizontal: MasiSpacing.xs,
          vertical: MasiSpacing.xs,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: size.width,
              height: size.height,
              decoration: BoxDecoration(
                color: colors.surface2,
                borderRadius: BorderRadius.circular(MasiRadii.control),
                border: Border.all(
                  color: selected
                      ? colors.accent
                      : (accentOutline
                            ? colors.accent.withValues(alpha: 0.5)
                            : colors.separator),
                  width: selected ? 2 : 1,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: child,
            ),
            const SizedBox(height: 5),
            SizedBox(
              width: size.width + 8,
              child: Text(
                caption,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.1,
                  fontWeight: captionStrong
                      ? FontWeight.w600
                      : FontWeight.w500,
                  color: captionStrong ? colors.ink : colors.ink2,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The rail's leading tile: this rock seen from above, small enough to read as
/// an icon and true enough to be the same shape as the full-screen map it
/// opens.
class _PlanTilePainter extends CustomPainter {
  const _PlanTilePainter({
    required this.layout,
    required this.stroke,
    required this.dot,
    required this.activePhotoId,
  });

  final LayoutResult layout;
  final Color stroke;
  final Color dot;
  final String? activePhotoId;

  @override
  void paint(Canvas canvas, Size size) {
    final line = layout.baseline;
    if (line.points.length < 2) return;
    final fit = LayoutPlaneFit.forBaseline(line, size, padding: 8);

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
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = stroke,
    );

    for (final face in layout.faces) {
      final at = fit.toCanvas(line.pointAt(face.t));
      final active = face.id == activePhotoId;
      canvas.drawCircle(
        at,
        active ? 3 : 1.8,
        Paint()..color = active ? dot : dot.withValues(alpha: 0.5),
      );
    }
  }

  @override
  bool shouldRepaint(_PlanTilePainter old) =>
      old.layout != layout || old.activePhotoId != activePhotoId;
}

/// The plan view, full screen: where every photo of this rock was taken from.
///
/// Two things a 48px tile in the rail cannot do, and the reason this is a
/// screen rather than a lane inside the dock: every camera is a real
/// thumbnail big enough to recognise the side from the picture alone, and the
/// outline is drawn at a size where the shape of the rock is legible. It used
/// to be a 153pt card mounted permanently above the route list, which was too
/// small to answer the question and too big to keep on screen.
///
/// Read-only by design. Every correction is a drag, and dragging happens in
/// the layout editor, one tap away behind `Edit`.
class FaceMapPlan extends StatelessWidget {
  const FaceMapPlan({
    super.key,
    required this.layout,
    required this.photos,
    required this.activePhotoId,
    required this.routeCounts,
    required this.onSelect,
    required this.colors,
  });

  final LayoutResult layout;
  final List<PhotoRef> photos;
  final String? activePhotoId;
  final Map<String, int> routeCounts;
  final void Function(PhotoRef photo) onSelect;
  final MasiColors colors;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = Size(
        constraints.maxWidth,
        math.max(240, constraints.maxHeight),
      );
      final fit = LayoutPlaneFit.forBaseline(
        layout.baseline,
        size,
        padding: 76,
      );
      final slots = arrangeThumbnails(
        anchors: LayoutBaselinePainter.anchorsFor(layout, fit),
        canvas: size,
        thumbnail: const Size(76, 58),
        stem: 58,
      );
      final dpr = MediaQuery.devicePixelRatioOf(context);
      final byId = {for (final photo in photos) photo.id: photo};

      return SizedBox(
        width: size.width,
        height: size.height,
        child: Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(
                key: const Key('face-map-plan'),
                painter: LayoutBaselinePainter(
                  layout: layout,
                  fit: fit,
                  stroke: colors.amethyst400,
                  provisionalStroke: colors.amethyst300,
                  dotColor: colors.accent,
                  pinnedColor: colors.accent,
                  handleColor: colors.amethyst400,
                  selectedFaceId: activePhotoId,
                  slots: slots,
                ),
              ),
            ),
            for (final slot in slots)
              if (byId[slot.id] case final photo?)
                Positioned(
                  left: slot.topLeft.dx,
                  top: slot.topLeft.dy,
                  child: _MapThumbnail(
                    photo: photo,
                    size: slot.size,
                    active: photo.id == activePhotoId,
                    routeCount: routeCounts[photo.id] ?? 0,
                    dpr: dpr,
                    colors: colors,
                    onTap: () => onSelect(photo),
                  ),
                ),
          ],
        ),
      );
    },
  );
}

class _MapThumbnail extends StatelessWidget {
  const _MapThumbnail({
    required this.photo,
    required this.size,
    required this.active,
    required this.routeCount,
    required this.dpr,
    required this.colors,
    required this.onTap,
  });

  final PhotoRef photo;
  final Size size;
  final bool active;
  final int routeCount;
  final double dpr;
  final MasiColors colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    key: Key('face-map-face-${photo.id}'),
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    child: Container(
      width: size.width,
      height: size.height,
      decoration: BoxDecoration(
        color: colors.surface2,
        borderRadius: BorderRadius.circular(MasiRadii.card),
        border: Border.all(
          color: active ? colors.accent : colors.separator,
          width: active ? 2.5 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          PhotoImage(
            photo.localPath,
            fit: BoxFit.cover,
            cacheWidth: (size.width * dpr).round(),
          ),
          if (routeCount > 0)
            Positioned(
              right: 3,
              bottom: 3,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xB3000000),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '$routeCount',
                  style: const TextStyle(
                    fontSize: 10,
                    height: 1.3,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFFFFFFFF),
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
