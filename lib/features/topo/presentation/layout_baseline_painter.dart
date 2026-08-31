import 'dart:math' as math;

// `Baseline` collides with Flutter's text-baseline enum, which this file
// never uses; the layout one is the subject here.
import 'package:flutter/material.dart' hide Baseline;

import 'package:masi/features/topo/domain/face_layout/baseline.dart';
import 'package:masi/features/topo/domain/face_layout/layout_resolver.dart';
import 'package:masi/features/topo/presentation/layout_plane_fit.dart';
import 'package:masi/features/topo/presentation/topo_painter.dart';
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
    required this.handleRingColor,
    required this.selectedFaceId,
    this.slots = const <ThumbnailSlot>[],
    this.showHandles = false,
    this.draft,
    this.selectedStroke,
  });

  final LayoutResult layout;
  final LayoutPlaneFit fit;
  final Color stroke;
  final Color provisionalStroke;
  final Color dotColor;
  final Color pinnedColor;
  final Color handleColor;

  /// The pale ring drawn around each handle's core — a surface colour, so the
  /// handle is legible on the stroke, on a thumbnail, and on the empty canvas
  /// alike.
  final Color handleRingColor;

  final String? selectedFaceId;

  /// Where each face's thumbnail actually sits, from `arrangeThumbnails`.
  ///
  /// Passed in rather than recomputed here because the widget layer positions
  /// the real thumbnails from the same list: a leader drawn to a box the
  /// widget put somewhere else reads as a rendering bug.
  final List<ThumbnailSlot> slots;

  /// Whether to draw the diamond reshape handles at each vertex.
  final bool showHandles;

  /// A stroke being drawn right now, in plane coordinates. Drawn ALONGSIDE
  /// the rocks that already exist when it is a new one being added, and
  /// instead of them when it replaces the drawing.
  final Baseline? draft;

  /// The rock the contributor has picked out, drawn heavier so "remove this
  /// one" can name something they can see.
  final int? selectedStroke;

  static const double _dotRadius = 5;

  /// Handles are drawn as a filled core inside a light ring, and both radii
  /// are bigger than the 5px diamond they replace. A corner of a traced rock
  /// is the thing a contributor reaches for to fix the shape, and a small
  /// accent-coloured diamond sitting on an accent-coloured line is nearly
  /// invisible — which is most of what made reshaping feel unavailable.
  static const double _handleRadius = 6.5;
  static const double _handleRingWidth = 2.5;

  /// How far a thumbnail floats off the line, in pixels.
  ///
  /// Short on purpose. This is the whole distance between a photo and the dot
  /// it belongs to, and every pixel of it is a pixel the reader has to trace.
  static const double stemLength = 42;

  /// Radius of the close-the-ring target drawn on a draft's first point.
  /// Deliberately larger than a handle: it is a place to aim at, not a thing
  /// to grab.
  static const double _closeTargetRadius = 12;

  /// Every rock this painter is being asked to draw.
  ///
  /// A wall can hold more than one stroke now, and a draft is one MORE rock
  /// being added — not a replacement for the ones already there. Drawing only
  /// the draft while a second boulder is being traced would blank the first,
  /// which reads as having destroyed it.
  List<Baseline> get _lines => [
    if (layout.strokes.isEmpty) layout.baseline else ...layout.strokes,
    ?draft,
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final lines = _lines;
    final drafting = draft != null;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      // Not `< 2`: a line being TAPPED out starts as one point, and a first
      // point that paints nothing reads as a tap that did not register.
      if (line.points.isEmpty) continue;

      final isDraft = drafting && i == lines.length - 1;
      final provisional = isDraft || layout.isProvisional;
      final selected = !drafting && i == selectedStroke;

      if (line.points.length >= 2) {
        final path = _smoothPath([
          for (final point in line.points) fit.toCanvas(point),
        ], closed: line.closed);

        final base = provisional ? provisionalStroke : stroke;
        final paint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = selected ? 10 : 7
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          // The rocks already standing fade back while a new one is being
          // traced. They stay on screen because a boulder drawn without its
          // neighbour in view lands in the wrong place, but nothing on them
          // is grabbable at that moment — see the handles below — and a line
          // that looks live while ignoring every touch reads as broken.
          ..color = drafting && !isDraft ? base.withValues(alpha: 0.3) : base;

        canvas.drawPath(provisional ? _dashed(path) : path, paint);
      }

      // While a new rock is being drawn, only ITS points are grabbable, so
      // only its points wear handles — handles on the settled rocks would
      // offer an edit the canvas is not listening for.
      if (showHandles && (!drafting || isDraft)) {
        for (final point in line.points) {
          _handle(canvas, fit.toCanvas(point));
        }
      }
    }

    if (drafting) {
      _closeTarget(canvas, draft!);
      return;
    }

    for (final face in layout.faces) {
      final line = layout.strokeFor(face);
      if (line.points.length < 2) continue;
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

  /// The ring on the FIRST point of a stroke being tapped out: the target
  /// that closes it into a boulder.
  ///
  /// Closure is the one thing this editor cannot infer and the one thing it
  /// cannot ask in words — the whole design turns on "it is a boulder because
  /// the line closes" — so the gesture has to be visible at the moment it
  /// becomes available. Drawn from three points on, which is when a closed
  /// stroke first encloses anything.
  void _closeTarget(Canvas canvas, Baseline line) {
    if (line.points.length < 3 || line.closed) return;
    final at = fit.toCanvas(line.points.first);
    canvas.drawCircle(
      at,
      _closeTargetRadius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = pinnedColor,
    );
  }

  ThumbnailSlot? _slotFor(String id) {
    for (final slot in slots) {
      if (slot.id == id) return slot;
    }
    return null;
  }

  /// The room a plan needs on each edge for the photos that float off the
  /// line, given the tile size and stem the caller is going to draw with.
  ///
  /// Not a constant, and not the same on all four sides. A ring's thumbnails
  /// leave in every direction, so a ring needs the whole band all round or
  /// the photos land on the rock they are pictures of. A strip's leave on ONE
  /// side, so reserving the band on the other three costs the line 40% of its
  /// width and buys nothing — and it is the line's length that the photos are
  /// spread along.
  ///
  /// Feed the result to [LayoutPlaneFit.forBaseline]'s per-edge padding.
  static ({double left, double top, double right, double bottom}) planInsets({
    required LayoutResult layout,
    required Size thumbnail,
    required double stem,
    double margin = 10,
  }) {
    final halfX = thumbnail.width / 2 + margin;
    final halfY = thumbnail.height / 2 + margin;
    // ANY ring means the band is needed all round: a wall holding a boulder
    // and a slab has photos leaving in every direction somewhere.
    final anyClosed = layout.strokes.isEmpty
        ? layout.baseline.closed
        : layout.strokes.any((stroke) => stroke.closed);
    if (anyClosed) {
      return (
        left: halfX + stem,
        top: halfY + stem,
        right: halfX + stem,
        bottom: halfY + stem,
      );
    }

    // Which way an open line's thumbnails go, in canvas terms. Averaged over
    // the faces because a wiggly strip's normals differ face to face while
    // the SIDE they are on does not.
    var bias = Offset.zero;
    for (final face in layout.faces) {
      final normal = layout.strokeFor(face).normalAt(face.t);
      if (normal == null) continue;
      final unit = (normal * layout.normalSignFor(face)).normalized;
      if (unit != null) bias += Offset(unit.x, -unit.y);
    }
    if (bias.distance > 0) bias = bias / bias.distance;

    return (
      left: halfX + stem * math.max(0, -bias.dx),
      top: halfY + stem * math.max(0, -bias.dy),
      right: halfX + stem * math.max(0, bias.dx),
      bottom: halfY + stem * math.max(0, bias.dy),
    );
  }

  /// Where each face WANTS its thumbnail, before collision resolution.
  ///
  /// Shared with the widget layer rather than duplicated there: a thumbnail
  /// drawn anywhere but at the end of its own leader reads as a bug in the
  /// data.
  ///
  /// On a RING the direction is **radial from the stroke's own centre**, not
  /// the segment normal. Two things go wrong with the normal here and both
  /// shipped. It depends on the winding — `normalAt` is the tangent turned
  /// left, so which side of the line it names is decided by which way round
  /// the contributor happened to trace the boulder — and
  /// [LayoutResult.thumbnailNormalSign] can only correct that for the stroke
  /// as a whole, so the correction is a coin flip that sends every photo of a
  /// rock into the middle of its own outline. And it is LOCAL: at a concave
  /// vertex of a hand-traced rock the left normal points back into the rock
  /// even when the sign is right for every other face. The radius from
  /// [Baseline.centroid] has neither problem, and it fans the photos evenly
  /// around the rock, which is the arrangement that reads.
  ///
  /// The normal still decides an OPEN line, where there is no inside to be
  /// on: a strip's two sides are genuinely symmetric and the sign is the only
  /// thing that knows which one the cameras were standing on.
  static List<ThumbnailAnchor> anchorsFor(
    LayoutResult layout,
    LayoutPlaneFit fit,
  ) {
    // An amphitheatre is a ring photographed from the INSIDE, so its
    // thumbnails belong inside it. Everything else — including the ordinary
    // case of not knowing — is a boulder you walk around.
    final inside = layout.orientation == LayoutOrientation.outward;

    final out = <ThumbnailAnchor>[];
    for (final face in layout.faces) {
      // Each face floats off ITS OWN rock. A wall with two boulders has two
      // centres, and measuring every photo's direction from one of them
      // would send the second boulder's photos across the drawing.
      final line = layout.strokeFor(face);
      if (line.points.length < 2) continue;
      final at = fit.toCanvas(line.pointAt(face.t));

      var direction = Offset.zero;
      if (line.closed) {
        final radial = at - fit.toCanvas(line.centroid);
        // A face sitting on the centre has no radius to speak of — one point
        // in a thousand, and dividing by it would be a NaN thumbnail. The
        // normal below is the fallback.
        if (radial.distance > 0.5) {
          direction = inside ? -radial : radial;
        }
      }
      if (direction == Offset.zero) {
        final normal = line.normalAt(face.t);
        direction = normal == null
            ? Offset.zero
            : fit.directionToCanvas(normal * layout.normalSignFor(face));
      }

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

  /// A corner you can see and aim at: a pale ring around a solid core, so it
  /// stands off the stroke it sits on whichever colour that stroke is.
  void _handle(Canvas canvas, Offset centre) {
    canvas.drawCircle(centre, _handleRadius, Paint()..color = handleRingColor);
    canvas.drawCircle(
      centre,
      _handleRadius - _handleRingWidth,
      Paint()..color = handleColor,
    );
  }

  /// The stroke as a rounded curve rather than a chain of straight segments.
  ///
  /// A rock traced in a dozen taps comes out as a polygon, and a polygon
  /// reads as a diagram of a box rather than as the outline of a rock — the
  /// user's word for it was "boxy". Catmull-Rom (converted to cubics) passes
  /// exactly THROUGH every point that was placed, so the smoothing is purely
  /// cosmetic: the handles still sit on the curve, the stored geometry is
  /// untouched, and nothing that hit-tests against the polyline moves.
  ///
  /// The control points come from [TopoPainter.catmullRomControlPoints] — the
  /// same function that curves every route line on every topo — rather than
  /// from a second copy of the formula here. A rock's outline and a climb's
  /// line are now drawn by one piece of maths, which is the point: they are
  /// tapped out with the same gesture and should come out the same shape.
  static Path _smoothPath(List<Offset> points, {required bool closed}) {
    final path = Path();
    if (points.isEmpty) return path;
    path.moveTo(points.first.dx, points.first.dy);
    if (points.length == 2) {
      path.lineTo(points[1].dx, points[1].dy);
      return path;
    }

    final n = points.length;
    Offset at(int i) {
      if (closed) return points[(i % n + n) % n];
      return points[i.clamp(0, n - 1)];
    }

    final last = closed ? n : n - 1;
    for (var i = 0; i < last; i++) {
      final p0 = at(i - 1);
      final p1 = at(i);
      final p2 = at(i + 1);
      final p3 = at(i + 2);
      final (c1, c2) = TopoPainter.catmullRomControlPoints(p0, p1, p2, p3);
      path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p2.dx, p2.dy);
    }
    if (closed) path.close();
    return path;
  }

  @override
  bool shouldRepaint(LayoutBaselinePainter old) =>
      old.layout != layout ||
      old.draft != draft ||
      old.selectedFaceId != selectedFaceId ||
      old.showHandles != showHandles ||
      old.handleRingColor != handleRingColor ||
      old.selectedStroke != selectedStroke ||
      old.slots != slots ||
      old.stroke != stroke;
}
