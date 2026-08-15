import 'dart:ui';

import 'package:flutter/foundation.dart' show listEquals, visibleForTesting;
import 'package:flutter/rendering.dart' show CustomPainter, TextPainter, TextSpan, TextStyle;

import 'package:masi/core/coordinates/coordinate_transformer.dart';
import 'package:masi/features/topo/domain/topo_route.dart';

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

/// Radius (in scene/pixel units) of symbol glyphs. Bumped from the
/// historical `7.0` to `11.0` (~22px on-screen diameter, roughly matching
/// the toolbar palette glyph size) so on-photo symbols read clearly at a
/// glance without needing a contrast halo behind them.
const double _symbolRadius = 11.0;

/// Font size used for route number labels.
const double _labelFontSize = 14.0;

/// On-screen distance (scene-space at `scale == 1.0`, divided by
/// [TopoPainter.scale] at paint time like every other on-screen-constant
/// size in this painter) the route-number label is offset from its route's
/// first point — #18 fix: clear of the (5.5px-wide) route stroke, rather
/// than the old fixed `Offset(-6, -20)` which sat on top of it.
const double _labelOffsetDistance = 16.0;

/// Fallback stroke color used when [TopoPainter.palette] is empty, so a
/// route can still be painted (rather than throwing
/// `IntegerDivisionByZeroException` from `palette[i % palette.length]`)
/// even if the caller passes an empty palette list.
const Color _fallbackRouteColor = Color(0xFF2E7D32);

/// #79: route-number labels are tinted to the route's OWN resolved color
/// (the same color as its drawn line and legend swatch) rather than a fixed
/// white, so the number reads as an at-a-glance match to its route. The two
/// dark [Shadow]s baked into the label's [TextStyle] (see
/// [TopoPainter._paintLabel]) still provide the legibility outline that
/// keeps the colored glyph readable over both light and dark photo
/// backgrounds.

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
/// Each [TopoSymbol] is rendered as a glyph distinct per [SymbolType]. When
/// [symbolPictures] has a loaded masi brand-glyph [Picture] for a type
/// (see `TopoCanvas`'s `_loadSymbolPictures`, which preloads
/// `assets/icons/masi/masi_<name>.svg` once, outside [paint]), that glyph is
/// drawn instead — this is what makes the on-photo marker match the
/// draw-mode symbol palette's own `MasiIcon`/`SvgPicture` rendering of the
/// same glyph. Any type without a loaded entry in [symbolPictures] (e.g.
/// before the async load completes) falls back to the historical
/// hand-drawn geometry below, so a marker is never left blank:
///  - [SymbolType.anchor]: a filled circle.
///  - [SymbolType.bolt]: an "X" made of two crossed lines.
///  - [SymbolType.top]: a closed, filled/stroked triangle (3-point path).
///  - [SymbolType.crux]: a star/asterisk made of several crossing lines
///    (a "+" plus an "X", four spokes total).
///  - [SymbolType.disabledHold]: a prohibition/no-entry sign -- a stroked
///    circle outline with a single diagonal slash through it. Always this
///    hand-drawn geometry, never a preloaded glyph -- there is no masi
///    brand asset mapped for it (see `TopoCanvas`'s
///    `_symbolGlyphAssetNames`), so [symbolPictures] never contains an
///    entry for it in practice, and [_paintSymbol] force-excludes it from
///    the picture lookup defensively even if a caller ever mis-populated
///    one.
///
/// ## Marker visibility is gated by route selection (feature #43)
///
/// A committed route's LINE (spline) and number LABEL render whenever
/// `route.visible` -- unconditionally, regardless of selection, unchanged
/// from the pre-#43 behavior. Its SYMBOLS (both [SymbolType.disabledHold]
/// markers and every other [SymbolType]: anchor/bolt/top/crux), by
/// contrast, render ONLY when that route is ALSO the selected route
/// (`route.id == selectedRouteId`) -- see [paint]'s committed-route loop.
/// When [selectedRouteId] is null, no committed route's symbols paint at
/// all. This keeps a busy multi-route topo legible: markers no longer pile
/// up for every route at once, only for whichever one the climber is
/// currently focused on (selected via the legend row or a canvas tap in
/// view mode). The in-progress route's own symbols
/// ([currentSymbols], a separate paint path from the committed-route loop)
/// are UNAFFECTED by this gating -- they always render while being placed,
/// regardless of [selectedRouteId].
class TopoPainter extends CustomPainter {
  const TopoPainter({
    required this.imageSize,
    required this.routes,
    required this.currentPoints,
    this.currentSymbols = const [],
    required this.showHandles,
    this.selectedRouteId,
    required this.palette,
    this.currentColor = _defaultCurrentColor,
    this.handleColor = _defaultHandleColor,
    this.routeColorResolver,
    this.scale = 1.0,
    this.symbolPictures = const {},
    this.editableRouteId,
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

  /// Symbols placed on the in-progress route (via [DrawController
  /// .placeSymbol] while it's still uncommitted -- see
  /// `DrawState.currentSymbols`'s doc), in percent space. Rendered in
  /// [currentColor] like the in-progress polyline itself, since the route
  /// doesn't have a palette color assigned until it's committed.
  final List<TopoSymbol> currentSymbols;

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

  /// Preloaded masi brand glyphs (see the class doc's "Symbol glyph
  /// mapping" section), keyed by [SymbolType], drawn via
  /// [Canvas.drawPicture] in [_paintSymbol] instead of that method's
  /// hand-drawn primitives for any type present here — EXCEPT
  /// [SymbolType.disabledHold], which always keeps its hand-drawn geometry
  /// even if a caller supplied an entry for it. Defaults to empty so every
  /// pre-existing caller/test that constructs a [TopoPainter] directly
  /// (never passing this) keeps rendering the historical hand-drawn
  /// geometry unchanged, and so does any type whose glyph hasn't finished
  /// loading yet.
  final Map<SymbolType, Picture> symbolPictures;

  /// The committed route whose points should be painted with drag handles, or
  /// null for none.
  ///
  /// This is deliberately a SEPARATE field from [showHandles] rather than an
  /// overload of it: [showHandles] means "paint handles for the in-progress
  /// draft ([currentPoints])" and always has, so folding a committed route
  /// into that same flag would make it mean two different things depending
  /// on context. When [editableRouteId] matches a route in [routes] that is
  /// also `visible`, that route's points are painted with the exact same
  /// handle geometry [currentPoints] gets under [showHandles] (see
  /// [_paintHandles]) -- same radius, same [handleColor], same 1/[scale]
  /// on-screen-constant sizing. A route that doesn't exist, or exists but is
  /// invisible, paints no handles even if its id is set here. Symbols need
  /// no equivalent change: a committed route's markers already render only
  /// while it's the selected route (feature #43, see the class doc above).
  final int? editableRouteId;

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
        _paintLabel(canvas, size, scenePoints, route.number, color);
      }

      // Feature #43: a committed route's symbols (disabled-hold markers +
      // every other SymbolType) render ONLY while this route is the
      // selected one -- unlike the line/label above, which always render
      // for every visible route. This keeps a multi-route topo legible:
      // markers don't pile up for routes the climber isn't focused on.
      if (isSelected) {
        for (final symbol in route.symbols) {
          _paintSymbol(canvas, CoordinateTransformer.percentToScene(symbol.position, imageSize), symbol.type, color);
        }
      }

      // Step 2 of the route-editing plan (§4.2): paint drag handles for the
      // committed route currently marked editable, using the SAME handle
      // geometry the draft (currentPoints) already uses under showHandles
      // below -- see _paintHandles. `visible` is already guaranteed here by
      // the `continue` at the top of this loop.
      if (route.id == editableRouteId) {
        _paintHandles(canvas, scenePoints);
      }
    }

    final currentScene = _toScene(currentPoints);
    _paintPolyline(canvas, currentScene, currentColor, strokeWidth: _strokeWidth / _safeScale);

    for (final symbol in currentSymbols) {
      _paintSymbol(
        canvas,
        CoordinateTransformer.percentToScene(symbol.position, imageSize),
        symbol.type,
        currentColor,
      );
    }

    if (showHandles) {
      _paintHandles(canvas, currentScene);
    }
  }

  /// Paints one draggable-handle circle (see [_handleRadius], scaled by
  /// 1/[_safeScale] like every other on-screen-constant size in this
  /// painter) at each of [points], filled with [handleColor]. Shared by both
  /// the in-progress draft (under [showHandles]) and a committed route
  /// marked [editableRouteId] (step 2 of the route-editing plan), so the two
  /// stay visually identical by construction rather than by two hand-synced
  /// copies of the same geometry.
  void _paintHandles(Canvas canvas, List<Offset> points) {
    final handlePaint = Paint()
      ..color = handleColor
      ..style = PaintingStyle.fill;
    for (final p in points) {
      canvas.drawCircle(p, _handleRadius / _safeScale, handlePaint);
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
  /// The bold number is painted in [color] — the SAME resolved color as the
  /// route's own line and legend swatch (#79) — so the number reads as an
  /// at-a-glance match to its route, rather than the old fixed white. The
  /// dark shadows baked into its [TextStyle.shadows] still keep the
  /// colored glyph legible over both light and dark photo backgrounds.
  /// There is no background chip.
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
    Color color,
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
          color: color,
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

    // Prefer the preloaded masi brand glyph for this type, if one has
    // loaded — EXCEPT for SymbolType.disabledHold, which has no dedicated
    // brand icon and always keeps its hand-drawn geometry in the switch
    // below regardless of what symbolPictures contains for it (defensive:
    // this guarantees its geometry even if a caller ever mis-populated an
    // entry). Any other type without a loaded picture yet falls through to
    // the same switch, so a marker is never left blank while loading.
    final picture = (type == SymbolType.disabledHold) ? null : symbolPictures[type];
    if (picture != null) {
      _paintSymbolPicture(canvas, center, picture, color, radius);
      return;
    }

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
      case SymbolType.disabledHold:
        // A prohibition/no-entry sign: a stroked circle outline with a
        // single diagonal slash through it (NW->SE), distinct from every
        // other glyph above -- unlike bolt's X (two crossed lines, no
        // circle), this is exactly one circle plus one line.
        canvas.drawCircle(center, radius, strokePaint);
        final slash = Offset(radius * 0.70710678, radius * 0.70710678);
        canvas.drawLine(center - slash, center + slash, strokePaint);
        break;
    }
  }

  /// Draws a preloaded masi brand-glyph [picture] (a [Picture] recorded in
  /// the glyph SVG's 24x24 viewBox space — see `TopoCanvas`'s
  /// `_loadSymbolPictures`) centered at [center], tinted to [color], and
  /// sized so its on-screen diameter matches [radius]'s `2 * radius` — the
  /// SAME on-screen footprint the hand-drawn geometry in [_paintSymbol]'s
  /// switch uses for this marker (e.g. the old filled-circle anchor's
  /// diameter), so swapping in the brand glyph doesn't change how big the
  /// marker reads on screen.
  ///
  /// Tinting uses a `saveLayer` + `BlendMode.srcIn` [ColorFilter] — the same
  /// technique `MasiIcon`/`SvgPicture`'s own `colorFilter` uses — because
  /// the glyph SVGs are drawn in `currentColor` plus fill-opacity facet
  /// layers: `srcIn` replaces every drawn pixel's RGB with [color] while
  /// preserving each pixel's own alpha, so the facet shading survives as
  /// varying opacity of the SAME tint color rather than being flattened to
  /// a single flat blob.
  void _paintSymbolPicture(
    Canvas canvas,
    Offset center,
    Picture picture,
    Color color,
    double radius,
  ) {
    final target = 2 * radius;
    final k = target / 24.0; // The glyph SVGs use a 24x24 viewBox.

    canvas.save();
    canvas.translate(center.dx, center.dy);

    canvas.scale(k);
    canvas.saveLayer(
      const Rect.fromLTWH(-12, -12, 24, 24),
      Paint()..colorFilter = ColorFilter.mode(color, BlendMode.srcIn),
    );
    // Shift so the glyph's 0..24 viewBox is centered on `center` (already
    // the local origin after the translate above).
    canvas.translate(-12, -12);
    canvas.drawPicture(picture);
    canvas.restore(); // saveLayer

    canvas.restore(); // translate/scale
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
        editableRouteId != oldDelegate.editableRouteId ||
        currentColor != oldDelegate.currentColor ||
        handleColor != oldDelegate.handleColor ||
        routeColorResolver != oldDelegate.routeColorResolver ||
        !identical(symbolPictures, oldDelegate.symbolPictures) ||
        symbolPictures.length != oldDelegate.symbolPictures.length ||
        !_pointsEqual(currentPoints, oldDelegate.currentPoints) ||
        !listEquals(currentSymbols, oldDelegate.currentSymbols) ||
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
