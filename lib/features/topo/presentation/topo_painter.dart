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

/// Stroke width (on-screen target, at `scale == 1.0`) used for route
/// polylines. Divided by [TopoPainter.scale] at paint time so the on-screen
/// width stays constant regardless of the live zoom/fit scale (see
/// [TopoPainter.scale]'s doc) — bumped from the historical `3.0` to `4.0`,
/// then to `5.5` (bug fix: on a physical Retina iPhone, `4.0` read as too
/// thin for an UNSELECTED/at-rest route over a busy photo — only the
/// SELECTED weight, `_strokeWidth * _selectedStrokeMultiplier`, looked
/// "right" to the reporting user). `5.5` keeps routes reading boldly at
/// rest while still leaving clear headroom under the selected multiplier
/// (5.5 * 1.4 = 7.7) for the emphasis pass to remain visually distinct.
const double _strokeWidth = 5.5;

/// Multiplier applied to [_strokeWidth] for the selected route's emphasis
/// pass.
const double _selectedStrokeMultiplier = 1.4;

/// Radius (in scene/pixel units) of symbol glyphs.
const double _symbolRadius = 7.0;

/// Font size used for route number labels.
const double _labelFontSize = 14.0;

/// On-screen distance (scene-space at `scale == 1.0`, divided by
/// [TopoPainter.scale] at paint time like every other on-screen-constant
/// size in this painter) the route-number label is offset from its route's
/// first point — #18 fix: clear of the (5.5px-wide) route stroke, rather
/// than the old fixed `Offset(-6, -20)` which sat on top of it.
const double _labelOffsetDistance = 22.0;

/// Fallback stroke color used when [TopoPainter.palette] is empty, so a
/// route can still be painted (rather than throwing
/// `IntegerDivisionByZeroException` from `palette[i % palette.length]`)
/// even if the caller passes an empty palette list.
const Color _fallbackRouteColor = Color(0xFF2E7D32);

/// Fixed high-contrast color used to paint route-number labels, regardless
/// of the route's own stroke color. A route-colored (e.g. orange) label
/// can be nearly invisible over a similarly colored photo region; the
/// route's color identity is already conveyed by the colored line itself
/// plus the legend swatch, so the number doesn't need to match it. White
/// paired with the dark shadow(s) baked into the label's [TextStyle] (see
/// [TopoPainter._paintLabel]) reads clearly over both light and dark photo
/// backgrounds.
const Color _labelColor = Color(0xFFFFFFFF);

/// Minimum on-screen distance (scaled by 1/[TopoPainter._safeScale], like
/// every other on-screen-constant size in this painter) a route-number
/// label's full bounding box is kept from the image edges. Without this, a
/// route whose first point sits near (or at) the frame boundary could have
/// its label placed partially or fully off-frame; [TopoPainter._paintLabel]
/// clamps the label's final on-screen origin so it never crosses this
/// margin.
const double _labelEdgeMargin = 6.0;

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
    this.scale = 1.0,
  });

  /// The natural size of the underlying topo image, used to convert percent
  /// points into scene/pixel coordinates.
  final Size imageSize;

  /// The live view transform's scale (`TransformationController.value
  /// .getMaxScaleOnAxis()`, i.e. `TopoCanvas._currentScale`) at paint time.
  ///
  /// All scene-space sizes (`_strokeWidth`, `_handleRadius`, `_dotRadius`,
  /// `_symbolRadius`, `_labelFontSize`, and the symbol outline stroke width)
  /// are divided by this value before drawing, so that once the canvas
  /// itself is scaled down/up by the same factor (the fit/zoom transform),
  /// the *on-screen* size stays constant instead of shrinking to a
  /// sub-pixel hairline at small fit scales. Defaults to `1.0` (identity),
  /// which reproduces the historical scene-pixel-constant sizing used by
  /// pre-existing tests/goldens that construct a [TopoPainter] directly
  /// without a live transform. Non-positive values are treated as `1.0` to
  /// avoid a divide-by-zero/blow-up (see [_safeScale]).
  final double scale;

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

  /// [scale] clamped to a small positive floor so dividing by it never
  /// produces a divide-by-zero (`double.infinity`) or a non-positive
  /// stroke/radius/font size.
  double get _safeScale => scale <= 0 ? 1.0 : scale;

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
          strokeWidth: (_strokeWidth * _selectedStrokeMultiplier) / _safeScale,
        );
      }

      _paintPolyline(
        canvas,
        scenePoints,
        color,
        strokeWidth: (isSelected ? _strokeWidth * _selectedStrokeMultiplier : _strokeWidth) / _safeScale,
      );

      if (scenePoints.isNotEmpty) {
        _paintLabel(canvas, size, scenePoints, route.number);
      }

      for (final symbol in route.symbols) {
        _paintSymbol(canvas, CoordinateTransformer.percentToScene(symbol.position, imageSize), symbol.type, color);
      }
    }

    final currentScene = _toScene(currentPoints);
    _paintPolyline(canvas, currentScene, currentColor, strokeWidth: _strokeWidth / _safeScale);

    if (showHandles) {
      final handlePaint = Paint()
        ..color = handleColor
        ..style = PaintingStyle.fill;
      for (final p in currentScene) {
        canvas.drawCircle(p, _handleRadius / _safeScale, handlePaint);
      }
    }
  }

  List<Offset> _toScene(List<Offset> percentPoints) {
    return [
      for (final p in percentPoints) CoordinateTransformer.percentToScene(p, imageSize),
    ];
  }

  /// Paints [number]'s label near the route's first scene point
  /// ([scenePoints.first]), offset clear of the route's own stroke (#18
  /// fix — it used to sit at a fixed `Offset(-6, -20)` from the anchor,
  /// which overlapped the 5.5px-wide stroke for many segment directions).
  ///
  /// The offset direction is PERPENDICULAR to the first segment
  /// ([scenePoints]\[0\] -> [scenePoints]\[1\]) — i.e. to the SIDE of the
  /// line the route travels along, which clears the stroke regardless of
  /// which way the route heads from its first point (an offset ALONG the
  /// segment's own direction would still ride the stroke as it travels
  /// away from the anchor). [scenePoints] with fewer than 2 points (a
  /// single-point route) has no segment to be perpendicular to, so falls
  /// back to the pre-existing up-and-left placement.
  ///
  /// The bold number is painted directly on the photo in a FIXED
  /// high-contrast color ([_labelColor], white) rather than the route's own
  /// color — a route-colored (e.g. orange) label can be nearly invisible
  /// over a similarly colored photo region, whereas white plus the dark
  /// shadows baked into its [TextStyle.shadows] reads clearly over both
  /// light and dark backgrounds. There is no background chip.
  ///
  /// [size] is the painter's on-screen/image-pixel bounds (the `size`
  /// [paint] receives). The label's final origin is clamped so its FULL
  /// laid-out bounding box stays within [size] (minus [_labelEdgeMargin]),
  /// so an anchor near — or at — the image edge nudges the label inward
  /// instead of letting it clip off-frame. Only the final origin is
  /// clamped; the perpendicular-offset DIRECTION above is unaffected.
  void _paintLabel(
    Canvas canvas,
    Size size,
    List<Offset> scenePoints,
    int number,
  ) {
    final anchor = scenePoints.first;

    final Offset offsetDirection;
    if (scenePoints.length >= 2) {
      final segment = scenePoints[1] - scenePoints[0];
      final length = segment.distance;
      final unit = length > 0 ? segment / length : const Offset(1, 0);
      // Rotate the segment's unit direction by -90° to get a perpendicular
      // (a rotation of (dx, dy) by -90° is (dy, -dx); either perpendicular
      // side clears the stroke equally well, so the specific sign here is
      // an arbitrary but fixed choice).
      offsetDirection = Offset(unit.dy, -unit.dx);
    } else {
      // Single-point route: no segment to be perpendicular to — fall back
      // to the pre-existing up-and-left placement (matches the sign of the
      // old fixed `Offset(-6, -20)`).
      offsetDirection = const Offset(-0.70710678, -0.70710678);
    }

    final textPainter = TextPainter(
      text: TextSpan(
        text: '$number',
        style: TextStyle(
          color: _labelColor,
          fontSize: _labelFontSize / _safeScale,
          fontWeight: FontWeight.bold,
          shadows: [
            // Tight, low-blur pass: strengthens the outline/halo against
            // very light or busy backgrounds where the soft shadow alone
            // could be marginal. Intentionally NOT a filled box — just a
            // subtle stacked shadow.
            Shadow(
              color: const Color(0xE6000000),
              blurRadius: 1.5 / _safeScale,
            ),
            // Soft drop shadow for depth/legibility over busy photo
            // textures.
            Shadow(
              color: const Color(0xB3000000),
              blurRadius: 3.0 / _safeScale,
              offset: Offset(0, 1.0 / _safeScale),
            ),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    // Scaled by 1/_safeScale (like every other on-screen-constant size in
    // this painter) so the label sits a constant ON-SCREEN distance from
    // the anchor, regardless of the live fit/zoom scale.
    final labelOrigin =
        anchor + offsetDirection * (_labelOffsetDistance / _safeScale);

    final margin = _labelEdgeMargin / _safeScale;
    final clampedOrigin = Offset(
      _clampToEdge(labelOrigin.dx, margin, size.width - textPainter.width - margin),
      _clampToEdge(labelOrigin.dy, margin, size.height - textPainter.height - margin),
    );

    textPainter.paint(canvas, clampedOrigin);
  }

  /// Clamps [value] into `[margin, maxEdge]` — used to keep a label's full
  /// width/height inside the image bounds. Falls back to just [margin] when
  /// `maxEdge < margin` (the label is wider/taller than the image itself
  /// minus margins, so there is no valid non-empty range) rather than
  /// letting [num.clamp] throw on an inverted range.
  static double _clampToEdge(double value, double margin, double maxEdge) {
    if (maxEdge <= margin) return margin;
    return value.clamp(margin, maxEdge);
  }

  void _paintSymbol(Canvas canvas, Offset center, SymbolType type, Color color) {
    final strokePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0 / _safeScale
      ..strokeCap = StrokeCap.round;
    final fillPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    // Scaled by 1/_safeScale (like every other on-screen-constant size in
    // this painter) so symbol glyphs keep a constant on-screen footprint
    // regardless of the live fit/zoom scale.
    final radius = _symbolRadius / _safeScale;

    switch (type) {
      case SymbolType.anchor:
        // Filled circle.
        canvas.drawCircle(center, radius, fillPaint);
        break;
      case SymbolType.bolt:
        // An "X": two crossed lines.
        canvas.drawLine(
          center + Offset(-radius, -radius),
          center + Offset(radius, radius),
          strokePaint,
        );
        canvas.drawLine(
          center + Offset(radius, -radius),
          center + Offset(-radius, radius),
          strokePaint,
        );
        break;
      case SymbolType.top:
        // A closed triangle (3-point path).
        final path = Path()
          ..moveTo(center.dx, center.dy - radius)
          ..lineTo(center.dx + radius, center.dy + radius)
          ..lineTo(center.dx - radius, center.dy + radius)
          ..close();
        canvas.drawPath(path, fillPaint);
        break;
      case SymbolType.crux:
        // A star/asterisk: a "+" plus an "X" (four crossing spokes).
        canvas.drawLine(
          center + Offset(0, -radius),
          center + Offset(0, radius),
          strokePaint,
        );
        canvas.drawLine(
          center + Offset(-radius, 0),
          center + Offset(radius, 0),
          strokePaint,
        );
        canvas.drawLine(
          center + Offset(-radius, -radius),
          center + Offset(radius, radius),
          strokePaint,
        );
        canvas.drawLine(
          center + Offset(radius, -radius),
          center + Offset(-radius, radius),
          strokePaint,
        );
        break;
      case SymbolType.rest:
        // A stroked circle outline with a small filled center dot.
        canvas.drawCircle(center, radius, strokePaint);
        canvas.drawCircle(center, radius / 3, fillPaint);
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
      canvas.drawCircle(points.first, _dotRadius / _safeScale, dotPaint);
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
        scale != oldDelegate.scale ||
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
