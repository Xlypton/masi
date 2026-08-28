import 'dart:math' as math;

// `Baseline` collides with Flutter's text-baseline enum, which this file
// never uses; the layout one is the subject here.
import 'package:flutter/material.dart' hide Baseline;

import 'package:masi/features/topo/domain/face_layout/baseline.dart';
import 'package:masi/features/topo/domain/face_layout/layout_resolver.dart';
import 'package:masi/features/topo/presentation/layout_plane_fit.dart';
import 'package:masi/features/topo/presentation/thumbnail_arrangement.dart';

/// Draws the semantic baseline and the faces riding it.
///
/// The only thing the stroke's appearance encodes is whether a human has
/// accepted it: solid once authored, dashed while it is still the app's guess
/// (design 4b). There is deliberately no visual difference between a ring and
/// a strip beyond the shape itself — a boulder is not labelled a boulder
/// anywhere, it simply closes.
class LayoutBaselinePainter extends CustomPainter {
  const LayoutBaselinePainter({
    required this.layout,
    required this.fit,
    required this.stroke,
    required this.provisionalStroke,
    required this.dotColor,
    required this.pinnedColor,
    required this.handleColor,
    required this.selectedFaceId,
    this.slots = const <ThumbnailSlot>[],
    this.showHandles = false,
    this.draft,
  });

  final LayoutResult layout;
  final LayoutPlaneFit fit;
  final Color stroke;
  final Color provisionalStroke;
  final Color dotColor;
  final Color pinnedColor;
  final Color handleColor;
  final String? selectedFaceId;

  /// Where each face's thumbnail actually sits, from `arrangeThumbnails`.
  ///
  /// Passed in rather than recomputed here because the widget layer positions
  /// the real thumbnails from the same list: a leader drawn to a box the
  /// widget put somewhere else reads as a rendering bug.
  final List<ThumbnailSlot> slots;

  /// Whether to draw the diamond reshape handles at each vertex.
  final bool showHandles;

  /// A stroke being drawn right now, in plane coordinates. Drawn instead of
  /// [layout]'s baseline so the contributor sees their own line rather than
  /// the one they are replacing.
  final Baseline? draft;

  static const double _dotRadius = 5;
  static const double _handleRadius = 5;

  /// How far a thumbnail floats off the line, in pixels.
  static const double stemLength = 52;

  @override
  void paint(Canvas canvas, Size size) {
    final line = draft ?? layout.baseline;
    if (line.points.length < 2) return;

    final provisional = draft != null || layout.isProvisional;
    final path = Path()..moveTo(
      fit.toCanvas(line.points.first).dx,
      fit.toCanvas(line.points.first).dy,
    );
    for (final point in line.points.skip(1)) {
      final at = fit.toCanvas(point);
      path.lineTo(at.dx, at.dy);
    }
    if (line.closed) path.close();

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = provisional ? provisionalStroke : stroke;

    canvas.drawPath(provisional ? _dashed(path) : path, paint);

    if (showHandles) {
      for (final point in line.points) {
        _diamond(canvas, fit.toCanvas(point), _handleRadius, handleColor);
      }
    }

    if (draft != null) return;

    for (final face in layout.faces) {
      final at = fit.toCanvas(line.pointAt(face.t));
      // A leader to wherever the arrangement pass ACTUALLY put this
      // thumbnail, which is not in general the end of its own normal — see
      // `arrangeThumbnails`. Without it a thumbnail that moved to avoid a
      // collision would belong to no dot in particular.
      final slot = _slotFor(face.id);
      if (slot != null) {
        final end = leaderEnd(at, slot.rect);
        if (end != null) {
          canvas.drawLine(
            at,
            end,
            Paint()
              ..color = (face.isPinned ? pinnedColor : dotColor).withValues(
                alpha: 0.45,
              )
              ..strokeWidth = 1.5,
          );
        }
      }

      final selected = face.id == selectedFaceId;
      canvas.drawCircle(
        at,
        selected ? _dotRadius + 2.5 : _dotRadius,
        Paint()..color = face.isPinned ? pinnedColor : dotColor,
      );
      if (selected) {
        canvas.drawCircle(
          at,
          _dotRadius + 6,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = pinnedColor,
        );
      }
    }
  }

  ThumbnailSlot? _slotFor(String id) {
    for (final slot in slots) {
      if (slot.id == id) return slot;
    }
    return null;
  }

  /// Where each face WANTS its thumbnail, before collision resolution.
  ///
  /// Shared with the widget layer rather than duplicated there: a thumbnail
  /// drawn anywhere but at the end of its own leader reads as a bug in the
  /// data.
  static List<ThumbnailAnchor> anchorsFor(
    LayoutResult layout,
    LayoutPlaneFit fit,
  ) {
    if (layout.baseline.points.length < 2) return const <ThumbnailAnchor>[];
    final out = <ThumbnailAnchor>[];
    for (final face in layout.faces) {
      final at = fit.toCanvas(layout.baseline.pointAt(face.t));
      final normal = layout.baseline.normalAt(face.t);
      final direction = normal == null
          ? Offset.zero
          : fit.directionToCanvas(normal * layout.thumbnailNormalSign);
      out.add(ThumbnailAnchor(id: face.id, base: at, direction: direction));
    }
    return out;
  }

  Path _dashed(Path source) {
    const dash = 10.0;
    const gap = 9.0;
    final out = Path();
    for (final metric in source.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final end = math.min(distance + dash, metric.length);
        out.addPath(metric.extractPath(distance, end), Offset.zero);
        distance = end + gap;
      }
    }
    return out;
  }

  void _diamond(Canvas canvas, Offset centre, double radius, Color color) {
    final path = Path()
      ..moveTo(centre.dx, centre.dy - radius)
      ..lineTo(centre.dx + radius, centre.dy)
      ..lineTo(centre.dx, centre.dy + radius)
      ..lineTo(centre.dx - radius, centre.dy)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(LayoutBaselinePainter old) =>
      old.layout != layout ||
      old.draft != draft ||
      old.selectedFaceId != selectedFaceId ||
      old.showHandles != showHandles ||
      old.slots != slots ||
      old.stroke != stroke;
}
