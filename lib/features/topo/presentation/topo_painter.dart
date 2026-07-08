import 'dart:ui';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/rendering.dart' show CustomPainter;

import 'package:climbtopo/core/coordinates/coordinate_transformer.dart';

/// Default stroke color for completed routes.
const Color _defaultRouteColor = Color(0xFF2E7D32);

/// Default stroke color for the in-progress route.
const Color _defaultCurrentColor = Color(0xFFE65100);

/// Default fill color for draggable point handles.
const Color _defaultHandleColor = Color(0xFF1565C0);

/// Radius (in scene/pixel units) of the dot drawn for a single-point route.
const double _dotRadius = 4.0;

/// Radius (in scene/pixel units) of a draggable point handle.
const double _handleRadius = 6.0;

/// Stroke width used for route polylines.
const double _strokeWidth = 3.0;

/// Paints completed routes and the in-progress route on the topo canvas.
///
/// All point lists are expressed in percent space (0.0-1.0 fractions of
/// [imageSize] on each axis) and converted to scene/pixel coordinates via
/// [CoordinateTransformer.percentToScene] before being drawn. Each polyline
/// is rendered as a Catmull-Rom spline (converted to cubic Bezier segments)
/// so routes look smooth rather than faceted.
class TopoPainter extends CustomPainter {
  const TopoPainter({
    required this.imageSize,
    required this.routes,
    required this.currentPoints,
    required this.showHandles,
    this.routeColor = _defaultRouteColor,
    this.currentColor = _defaultCurrentColor,
    this.handleColor = _defaultHandleColor,
  });

  /// The natural size of the underlying topo image, used to convert percent
  /// points into scene/pixel coordinates.
  final Size imageSize;

  /// Completed routes, each a list of points in percent space.
  final List<List<Offset>> routes;

  /// The in-progress route being drawn, in percent space.
  final List<Offset> currentPoints;

  /// Whether to draw draggable handles at each [currentPoints] position.
  final bool showHandles;

  /// Stroke color for completed routes.
  final Color routeColor;

  /// Stroke color for the in-progress route.
  final Color currentColor;

  /// Fill color for point handles.
  final Color handleColor;

  @override
  void paint(Canvas canvas, Size size) {
    for (final route in routes) {
      _paintPolyline(canvas, _toScene(route), routeColor);
    }

    final currentScene = _toScene(currentPoints);
    _paintPolyline(canvas, currentScene, currentColor);

    if (showHandles) {
      final handlePaint = Paint()
        ..color = handleColor
        ..style = PaintingStyle.fill;
      for (final p in currentScene) {
        canvas.drawCircle(p, _handleRadius, handlePaint);
      }
    }
  }

  List<Offset> _toScene(List<Offset> percentPoints) {
    return [
      for (final p in percentPoints) CoordinateTransformer.percentToScene(p, imageSize),
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

  /// Builds a smooth path through [points] using a Catmull-Rom spline
  /// converted to cubic Bezier segments. [points] must have at least 3
  /// elements. The first/last points are duplicated so the tangent formula
  /// is well-defined at the ends of the curve.
  Path _catmullRomPath(List<Offset> points) {
    final n = points.length;
    final path = Path()..moveTo(points[0].dx, points[0].dy);

    for (var i = 0; i < n - 1; i++) {
      final p0 = i == 0 ? points[0] : points[i - 1];
      final p1 = points[i];
      final p2 = points[i + 1];
      final p3 = i + 2 < n ? points[i + 2] : points[n - 1];

      final (cp1, cp2) = catmullRomControlPoints(p0, p1, p2, p3);

      path.cubicTo(cp1.dx, cp1.dy, cp2.dx, cp2.dy, p2.dx, p2.dy);
    }

    return path;
  }

  /// Computes the two cubic-Bezier control points for the Catmull-Rom
  /// segment between [p1] and [p2], given the neighboring points [p0] and
  /// [p3] used to derive the tangents at each end.
  ///
  /// Exposed as `@visibleForTesting` so the spline math can be verified
  /// numerically in tests without needing to reverse-engineer it from a
  /// rendered [Path]. [_catmullRomPath] calls this helper directly, so the
  /// tested formula is guaranteed to be the same one used at paint time.
  @visibleForTesting
  static (Offset, Offset) catmullRomControlPoints(
    Offset p0,
    Offset p1,
    Offset p2,
    Offset p3,
  ) {
    final cp1 = p1 + (p2 - p0) / 6;
    final cp2 = p2 - (p3 - p1) / 6;
    return (cp1, cp2);
  }

  @override
  bool shouldRepaint(covariant TopoPainter oldDelegate) {
    return imageSize != oldDelegate.imageSize ||
        showHandles != oldDelegate.showHandles ||
        routeColor != oldDelegate.routeColor ||
        currentColor != oldDelegate.currentColor ||
        handleColor != oldDelegate.handleColor ||
        !_pointsEqual(currentPoints, oldDelegate.currentPoints) ||
        !_routesEqual(routes, oldDelegate.routes);
  }

  // NOTE: the `identical()` fast path below assumes callers always pass a
  // *new* list instance when a route's points change (e.g. via copyWith or
  // spread-into-a-new-list), which is the convention used throughout this
  // codebase. If a caller instead mutated a list in place and passed the
  // same instance back, `identical()` would return true and shouldRepaint
  // would wrongly skip a needed repaint.
  static bool _pointsEqual(List<Offset> a, List<Offset> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // Same caveat as `_pointsEqual`: the `identical()` fast path assumes
  // callers pass a new `routes` list instance (and new inner point lists)
  // on change, rather than mutating an existing list/route in place.
  static bool _routesEqual(List<List<Offset>> a, List<List<Offset>> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_pointsEqual(a[i], b[i])) return false;
    }
    return true;
  }
}
