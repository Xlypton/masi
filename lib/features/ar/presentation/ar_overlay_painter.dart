import 'dart:ui';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/rendering.dart' show CustomPainter;

import 'package:masi/features/ar/domain/homography.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
import 'package:masi/features/topo/presentation/topo_painter.dart';

/// Radius (in canvas pixel units) of the dot drawn for a single-point route.
const double _dotRadius = 4.0;

/// Stroke width used for route polylines.
const double _strokeWidth = 3.0;

/// Confidence threshold below which routes are rendered with a distinct
/// "low confidence" treatment (reduced opacity) instead of the normal solid
/// stroke. Chosen to match the "e.g. < 0.4" guidance in this painter's
/// contract: below this, the camera-to-photo alignment is considered too
/// uncertain to present the overlay as trustworthy, so it's rendered more
/// faintly (searching-for-alignment look) rather than hidden outright.
const double kLowConfidenceThreshold = 0.4;

/// Alpha (0-255) applied to route strokes when [ArOverlayPainter.confidence]
/// is below [kLowConfidenceThreshold], in place of the normal fully-opaque
/// stroke. This is the "low-confidence treatment" referenced above.
const int kLowConfidenceAlpha = 89; // ~0.35 * 255, rounded.

/// Fallback stroke color used when [ArOverlayPainter.palette] is empty, so a
/// route can still be painted (rather than throwing from indexing an empty
/// palette) even if the caller passes an empty palette list.
const Color _fallbackRouteColor = Color(0xFF2E7D32);

/// Paints topo routes warped through a [Homography] on top of a live camera
/// feed, for the AR alignment view.
///
/// Route points are stored as percentages (0.0-1.0) of the *original*
/// reference photo's dimensions ([refSize]). Each point is first converted
/// to reference-photo pixel coordinates (`percent * refSize`) and then
/// warped into camera/screen space via
/// [Homography.warpOriginalPercent]/[Homography.warp]. The resulting screen
/// points are connected into a polyline using the exact same shape logic as
/// [TopoPainter] (1 point -> dot, 2 points -> straight line, 3+ points ->
/// Catmull-Rom spline via [TopoPainter.catmullRomControlPoints]) so the AR
/// overlay and the flat topo editor always agree on route shape.
///
/// ## Low-confidence treatment
///
/// When [confidence] is below [kLowConfidenceThreshold] (0.4), every route is
/// stroked with a reduced-alpha paint ([kLowConfidenceAlpha], ~0.35 opacity)
/// instead of the normal fully-opaque stroke, so a shaky/uncertain camera
/// alignment reads visually as "searching" rather than presenting a
/// misleadingly confident overlay.
class ArOverlayPainter extends CustomPainter {
  const ArOverlayPainter({
    required this.routes,
    required this.refSize,
    required this.homography,
    required this.palette,
    this.confidence = 1.0,
    this.routeColorResolver,
    this.outline,
  });

  /// Routes to render, in percent-of-[refSize] space. Routes with
  /// `visible == false` are skipped entirely.
  final List<TopoRoute> routes;

  /// The pixel dimensions of the original reference photo that
  /// [TopoRoute.points] percentages are relative to.
  final Size refSize;

  /// Maps points from the reference photo's coordinate space into the
  /// current camera/screen space.
  final Homography homography;

  /// Maps a route's `colorIndex` to a stroke [Color]. Indices wrap via `%`
  /// so any non-negative `colorIndex` is safe to use.
  final List<Color> palette;

  /// A 0.0-1.0 estimate of how well [homography] currently reflects reality
  /// (e.g. tracking/pose confidence). Values below [kLowConfidenceThreshold]
  /// trigger the low-confidence paint treatment; see the class doc.
  final double confidence;

  /// Optional override for a route's stroke color, taking precedence over
  /// [palette]-based coloring when provided. When null, colors fall back to
  /// `palette[route.colorIndex % palette.length]` (or
  /// [_fallbackRouteColor] if [palette] is empty).
  final Color Function(TopoRoute route)? routeColorResolver;

  /// Optional "ghost" outline image of the reference photo, drawn faintly
  /// (behind the route polylines) warped through [homography] so it lines
  /// up with the live camera feed the same way the routes do. `null` (the
  /// default) draws no outline at all.
  final ui.Image? outline;

  bool get _isLowConfidence => confidence < kLowConfidenceThreshold;

  @override
  void paint(Canvas canvas, Size size) {
    final outlineImage = outline;
    if (outlineImage != null) {
      canvas.save();
      canvas.transform(homography.toMatrix4ColumnMajor());
      final dst = Rect.fromLTWH(0, 0, refSize.width, refSize.height);
      final src = Rect.fromLTWH(0, 0, outlineImage.width.toDouble(), outlineImage.height.toDouble());
      canvas.saveLayer(dst, Paint()..color = const Color(0x73000000)); // ~45% opacity layer
      // High-quality (bilinear) filtering smooths the upscaled binary edge
      // image instead of leaving it jagged/aliased on-device.
      final outlinePaint = Paint()
        ..filterQuality = FilterQuality.high
        ..isAntiAlias = true;
      canvas.drawImageRect(outlineImage, src, dst, outlinePaint);
      canvas.restore(); // ends saveLayer
      canvas.restore(); // ends transform save
    }

    for (final route in routes) {
      if (!route.visible) continue;

      final screenPoints = _warpPoints(route.points);
      final resolver = routeColorResolver;
      final baseColor = resolver != null
          ? resolver(route)
          : (palette.isEmpty ? _fallbackRouteColor : palette[route.colorIndex % palette.length]);
      final color = _isLowConfidence ? baseColor.withAlpha(kLowConfidenceAlpha) : baseColor;

      _paintPolyline(canvas, screenPoints, color);
    }
  }

  List<Offset> _warpPoints(List<Offset> percentPoints) {
    return [
      for (final p in percentPoints) homography.warpOriginalPercent(p, refSize),
    ];
  }

  void _paintPolyline(Canvas canvas, List<Offset> points, Color color) {
    if (points.isEmpty) return;

    if (points.length == 1) {
      final dotPaint = Paint()
        ..color = color
        ..style = PaintingStyle.fill;
      canvas.drawCircle(points.first, _dotRadius, dotPaint);
      return;
    }

    final linePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = _strokeWidth
      ..strokeCap = StrokeCap.round;

    if (points.length == 2) {
      canvas.drawLine(points[0], points[1], linePaint);
      return;
    }

    canvas.drawPath(_catmullRomPath(points), linePaint);
  }

  /// Builds a smooth path through [points] using the same Catmull-Rom ->
  /// cubic-Bezier construction as [TopoPainter], reusing
  /// [TopoPainter.catmullRomControlPoints] so the two painters can never
  /// drift apart on spline shape.
  Path _catmullRomPath(List<Offset> points) {
    final n = points.length;
    final path = Path()..moveTo(points[0].dx, points[0].dy);

    for (var i = 0; i < n - 1; i++) {
      final p0 = i == 0 ? points[0] : points[i - 1];
      final p1 = points[i];
      final p2 = points[i + 1];
      final p3 = i + 2 < n ? points[i + 2] : points[n - 1];

      // `catmullRomControlPoints` is annotated `@visibleForTesting` because
      // TopoPainter's own author only anticipated test callers, but this
      // painter's contract explicitly requires reusing that exact helper
      // (rather than re-deriving/duplicating the Catmull-Rom formula) so AR
      // and flat-topo splines can never drift apart. Silencing the lint here
      // is a deliberate, narrow exception to that annotation's intent, not
      // an accident.
      // ignore: invalid_use_of_visible_for_testing_member
      final (cp1, cp2) = TopoPainter.catmullRomControlPoints(p0, p1, p2, p3);

      path.cubicTo(cp1.dx, cp1.dy, cp2.dx, cp2.dy, p2.dx, p2.dy);
    }

    return path;
  }

  @override
  bool shouldRepaint(covariant ArOverlayPainter oldDelegate) {
    return refSize != oldDelegate.refSize ||
        homography != oldDelegate.homography ||
        confidence != oldDelegate.confidence ||
        routeColorResolver != oldDelegate.routeColorResolver ||
        outline != oldDelegate.outline ||
        !listEquals(palette, oldDelegate.palette) ||
        !listEquals(routes, oldDelegate.routes);
  }
}
