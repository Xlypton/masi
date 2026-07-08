import 'dart:ui';

import 'package:flutter/foundation.dart' show listEquals, visibleForTesting;
import 'package:flutter/rendering.dart' show CustomPainter, TextPainter, TextSpan, TextStyle;

import 'package:climbtopo/core/coordinates/coordinate_transformer.dart';
import 'package:climbtopo/features/topo/domain/topo_route.dart';

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

/// Multiplier applied to [_strokeWidth] for the selected route's emphasis
/// pass.
const double _selectedStrokeMultiplier = 2.0;

/// Radius (in scene/pixel units) of symbol glyphs.
const double _symbolRadius = 7.0;

/// Font size used for route number labels.
const double _labelFontSize = 14.0;

/// Fallback stroke color used when [TopoPainter.palette] is empty, so a
/// route can still be painted (rather than throwing
/// `IntegerDivisionByZeroException` from `palette[i % palette.length]`)
/// even if the caller passes an empty palette list.
const Color _fallbackRouteColor = Color(0xFF2E7D32);

/// Paints completed routes (with symbols) and the in-progress route on the
/// topo canvas.
///
/// All point lists are expressed in percent space (0.0-1.0 fractions of
/// [imageSize] on each axis) and converted to scene/pixel coordinates via
/// [CoordinateTransformer.percentToScene] before being drawn. Each polyline
/// is rendered as a Catmull-Rom spline (converted to cubic Bezier segments)
/// so routes look smooth rather than faceted.
///
/// ## Symbol glyph mapping
///
/// Each [TopoSymbol] is rendered as a glyph distinct per [SymbolType], drawn
/// with plain canvas primitives (no images/fonts):
///  - [SymbolType.anchor]: a filled circle.
///  - [SymbolType.bolt]: an "X" made of two crossed lines.
///  - [SymbolType.top]: a closed, filled/stroked triangle (3-point path).
///  - [SymbolType.crux]: a star/asterisk made of several crossing lines
///    (a "+" plus an "X", four spokes total).
///  - [SymbolType.rest]: a stroked circle outline with a small filled dot at
///    its center.
class TopoPainter extends CustomPainter {
  const TopoPainter({
    required this.imageSize,
    required this.routes,
    required this.currentPoints,
    required this.showHandles,
    this.selectedRouteId,
    required this.palette,
    this.currentColor = _defaultCurrentColor,
    this.handleColor = _defaultHandleColor,
    this.routeColorResolver,
  });

  /// The natural size of the underlying topo image, used to convert percent
  /// points into scene/pixel coordinates.
  final Size imageSize;

  /// Completed routes to render. Routes with `visible == false` are skipped
  /// entirely (no spline, label, or symbols).
  final List<TopoRoute> routes;

  /// The in-progress route being drawn, in percent space.
  final List<Offset> currentPoints;

  /// Whether to draw draggable handles at each [currentPoints] position.
  final bool showHandles;

  /// The id of the currently-selected route, if any. When set, the matching
  /// route (if visible) is rendered with emphasis (thicker stroke plus an
  /// extra highlight outline).
  final int? selectedRouteId;

  /// Maps a route's `colorIndex` to a stroke [Color]. Indices wrap via `%`
  /// so any non-negative `colorIndex` is safe to use.
  final List<Color> palette;

  /// Stroke color for the in-progress route.
  final Color currentColor;

  /// Fill color for point handles.
  final Color handleColor;

  /// Optional override for a route's stroke/label/symbol color. When
  /// provided, it takes precedence over [palette]-based coloring for every
  /// route (e.g. so grade-band coloring, see
  /// `presentation/grade_colors.dart`'s `colorForRoute`, can be plugged in
  /// without this painter needing to know anything about grades). When
  /// null, colors fall back to `palette[route.colorIndex % palette.length]`
  /// (or [_fallbackRouteColor] if [palette] is empty), preserving this
  /// painter's pre-existing behavior.
  final Color Function(TopoRoute route)? routeColorResolver;

  @override
  void paint(Canvas canvas, Size size) {
    for (final route in routes) {
      if (!route.visible) continue;

      final scenePoints = _toScene(route.points);
      final resolver = routeColorResolver;
      final color = resolver != null
          ? resolver(route)
          : (palette.isEmpty
              ? _fallbackRouteColor
              : palette[route.colorIndex % palette.length]);
      final isSelected = route.id == selectedRouteId;

      if (isSelected) {
        // Extra highlight outline pass: a wider, translucent stroke drawn
        // underneath the normal-color spline so the selected route is
        // unambiguously distinguishable (both by an extra draw call and by
        // a larger strokeWidth) from unselected routes.
        _paintPolyline(
          canvas,
          scenePoints,
          color.withAlpha(120),
          strokeWidth: _strokeWidth * _selectedStrokeMultiplier,
        );
      }

      _paintPolyline(
        canvas,
        scenePoints,
        color,
        strokeWidth: isSelected ? _strokeWidth * _selectedStrokeMultiplier : _strokeWidth,
      );

      if (scenePoints.isNotEmpty) {
        _paintLabel(canvas, scenePoints.first, route.number, color);
      }

      for (final symbol in route.symbols) {
        _paintSymbol(canvas, CoordinateTransformer.percentToScene(symbol.position, imageSize), symbol.type, color);
      }
    }

    final currentScene = _toScene(currentPoints);
    _paintPolyline(canvas, currentScene, currentColor, strokeWidth: _strokeWidth);

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

  void _paintLabel(Canvas canvas, Offset anchor, int number, Color color) {
    final textPainter = TextPainter(
      text: TextSpan(
        text: '$number',
        style: TextStyle(
          color: color,
          fontSize: _labelFontSize,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    // Offset the label up-and-left of the anchor point so it doesn't
    // obscure the route's starting point.
    textPainter.paint(canvas, anchor + const Offset(-6, -20));
  }

  void _paintSymbol(Canvas canvas, Offset center, SymbolType type, Color color) {
    final strokePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;
    final fillPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    switch (type) {
      case SymbolType.anchor:
        // Filled circle.
        canvas.drawCircle(center, _symbolRadius, fillPaint);
        break;
      case SymbolType.bolt:
        // An "X": two crossed lines.
        canvas.drawLine(
          center + const Offset(-_symbolRadius, -_symbolRadius),
          center + const Offset(_symbolRadius, _symbolRadius),
          strokePaint,
        );
        canvas.drawLine(
          center + const Offset(_symbolRadius, -_symbolRadius),
          center + const Offset(-_symbolRadius, _symbolRadius),
          strokePaint,
        );
        break;
      case SymbolType.top:
        // A closed triangle (3-point path).
        final path = Path()
          ..moveTo(center.dx, center.dy - _symbolRadius)
          ..lineTo(center.dx + _symbolRadius, center.dy + _symbolRadius)
          ..lineTo(center.dx - _symbolRadius, center.dy + _symbolRadius)
          ..close();
        canvas.drawPath(path, fillPaint);
        break;
      case SymbolType.crux:
        // A star/asterisk: a "+" plus an "X" (four crossing spokes).
        canvas.drawLine(
          center + const Offset(0, -_symbolRadius),
          center + const Offset(0, _symbolRadius),
          strokePaint,
        );
        canvas.drawLine(
          center + const Offset(-_symbolRadius, 0),
          center + const Offset(_symbolRadius, 0),
          strokePaint,
        );
        canvas.drawLine(
          center + const Offset(-_symbolRadius, -_symbolRadius),
          center + const Offset(_symbolRadius, _symbolRadius),
          strokePaint,
        );
        canvas.drawLine(
          center + const Offset(_symbolRadius, -_symbolRadius),
          center + const Offset(-_symbolRadius, _symbolRadius),
          strokePaint,
        );
        break;
      case SymbolType.rest:
        // A stroked circle outline with a small filled center dot.
        canvas.drawCircle(center, _symbolRadius, strokePaint);
        canvas.drawCircle(center, _symbolRadius / 3, fillPaint);
        break;
    }
  }

  void _paintPolyline(
    Canvas canvas,
    List<Offset> points,
    Color color, {
    required double strokeWidth,
  }) {
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
      ..strokeWidth = strokeWidth
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
        selectedRouteId != oldDelegate.selectedRouteId ||
        currentColor != oldDelegate.currentColor ||
        handleColor != oldDelegate.handleColor ||
        routeColorResolver != oldDelegate.routeColorResolver ||
        !_pointsEqual(currentPoints, oldDelegate.currentPoints) ||
        !listEquals(palette, oldDelegate.palette) ||
        !listEquals(routes, oldDelegate.routes);
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
}
