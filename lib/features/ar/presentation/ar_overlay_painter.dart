import 'dart:ui';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/rendering.dart' show CustomPainter;

import 'package:masi/features/ar/domain/homography.dart';
import 'package:masi/features/ar/domain/rock_box.dart';
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

/// The flat tint the rock-box highlight ([ArOverlayPainter.rockBox]) is
/// drawn with. Cyan reads as a glowing highlight over most rock/foliage
/// photos.
const Color _rockHighlightTint = Color(0xFF00E5FF);

/// Alpha (0-255) applied to [_rockHighlightTint] for the rock box's
/// STROKE (its outline).
const int _rockHighlightAlpha = 160;

/// Alpha (0-255) applied to [_rockHighlightTint] for the rock box's faint
/// FILL (~18% opacity) — translucent enough that the live camera feed still
/// clearly shows through the highlighted area.
const int _rockBoxFillAlpha = 46;

/// Stroke width (canvas px) for the rock box's outline.
const double _rockBoxStrokeWidth = 3.0;

/// Layer opacity (ARGB, RGB ignored -- see the `saveLayer`-opacity idiom
/// already used by the [ArOverlayPainter.outline] block's `Color(0x73000000)`)
/// applied when compositing the [ArOverlayPainter.rockMask] silhouette, so the
/// recognized-rock highlight reads as a translucent tint (~40% opacity) over
/// the live camera feed rather than an opaque cyan cutout.
const int _rockSilhouetteLayerAlpha = 0x66000000;

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
    this.rockBox,
    this.rockMask,
    this.cropBox,
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

  /// Optional route-derived rock box (see `rock_box.dart`'s
  /// `rockBoxFromRoutes`), normalized 0..1 fractions of [refSize], painted
  /// as a highlight — its 4 corners warped through [homography] the same
  /// way route points are — over the tracked wall: a faint tinted fill plus
  /// a tinted stroke outline, both in [_rockHighlightTint]. `null` (the
  /// default) draws no highlight at all — the screen passes the box only
  /// while the "highlight rock" toggle is on (see `ar_screen.dart`).
  final Rect? rockBox;

  /// Optional per-pixel rock silhouette in the same 0..1 fractions of
  /// [refSize] as [rockBox]/[cropBox] (native, via Core ML segmentation —
  /// see `ar_controller.dart`'s `ArState.rockMask`). When non-null, the
  /// [outline] ghost is clipped to this silhouette (via `BlendMode.dstIn`)
  /// instead of the full photo rect, so it only drapes over the rock, not
  /// forest/sky/terrain. `null` (the default) falls back to [cropBox] (or, if
  /// that's also `null`, no crop at all).
  final ui.Image? rockMask;

  /// Optional route-hull rectangle (0..1 fractions of [refSize], typically
  /// `rockBoxFromRoutes`'s result) used to crop the [outline] ghost when
  /// [rockMask] is `null` — the fallback tier for web, before the native
  /// mask resolves, or on the simulator. `null` (the default) draws the
  /// ghost over the full photo rect (unchanged legacy behavior).
  final Rect? cropBox;

  bool get _isLowConfidence => confidence < kLowConfidenceThreshold;

  @override
  void paint(Canvas canvas, Size size) {
    final outlineImage = outline;
    if (outlineImage != null) {
      canvas.save();
      canvas.transform(homography.toMatrix4ColumnMajor());
      final dst = Rect.fromLTWH(0, 0, refSize.width, refSize.height);
      final mask = rockMask;
      final box = cropBox;
      // Fallback rectangular crop (web / before the per-pixel mask resolves).
      if (mask == null && box != null) {
        canvas.clipRect(Rect.fromLTRB(
          box.left * refSize.width,
          box.top * refSize.height,
          box.right * refSize.width,
          box.bottom * refSize.height,
        ));
      }
      final src = Rect.fromLTWH(0, 0, outlineImage.width.toDouble(), outlineImage.height.toDouble());
      canvas.saveLayer(dst, Paint()..color = const Color(0x73000000)); // ~45% opacity layer
      // High-quality (bilinear) filtering smooths the upscaled binary edge
      // image instead of leaving it jagged/aliased on-device.
      final outlinePaint = Paint()
        ..filterQuality = FilterQuality.high
        ..isAntiAlias = true;
      canvas.drawImageRect(outlineImage, src, dst, outlinePaint);
      // Per-pixel silhouette crop: keep the ghost only where the rock mask is
      // opaque.
      if (mask != null) {
        final maskSrc = Rect.fromLTWH(0, 0, mask.width.toDouble(), mask.height.toDouble());
        canvas.drawImageRect(mask, maskSrc, dst, Paint()..blendMode = BlendMode.dstIn..filterQuality = FilterQuality.high);
      }
      canvas.restore(); // ends saveLayer
      canvas.restore(); // ends transform save (+ clip)
    }

    final box = rockBox;
    if (box != null) {
      final mask = rockMask;
      if (mask != null) {
        // Recognized-rock silhouette: the mask is already cyan-tinted with
        // binary alpha, so draw it translucently, warped onto the wall -- it
        // follows the real rock shape instead of a bounding rectangle.
        // Visible in auto mode (where a mask is available but no [outline]
        // ghost is drawn).
        canvas.save();
        canvas.transform(homography.toMatrix4ColumnMajor());
        final dst = Rect.fromLTWH(0, 0, refSize.width, refSize.height);
        final maskSrc = Rect.fromLTWH(0, 0, mask.width.toDouble(), mask.height.toDouble());
        canvas.saveLayer(dst, Paint()..color = const Color(_rockSilhouetteLayerAlpha));
        canvas.drawImageRect(
          mask,
          maskSrc,
          dst,
          Paint()
            ..filterQuality = FilterQuality.high
            ..isAntiAlias = true,
        );
        canvas.restore(); // saveLayer
        canvas.restore(); // transform
      } else {
        // Fallback (no mask yet / seg unavailable): the previous route-bbox
        // rectangle. Corners warped exactly the way route points are
        // (homography.warpOriginalPercent on a 0..1 fraction of refSize) --
        // consistent with the rest of this painter's coordinate handling,
        // and simpler than the outline block's
        // canvas.transform+drawImageRect recipe since there's no image to
        // stretch, just 4 points to draw a path through.
        final corners = [
          for (final p in rockBoxCornersNorm(box))
            homography.warpOriginalPercent(p, refSize),
        ];
        final path = Path()..moveTo(corners[0].dx, corners[0].dy);
        for (final c in corners.skip(1)) {
          path.lineTo(c.dx, c.dy);
        }
        path.close();

        final fillPaint = Paint()
          ..color = _rockHighlightTint.withAlpha(_rockBoxFillAlpha)
          ..style = PaintingStyle.fill;
        canvas.drawPath(path, fillPaint);

        final strokePaint = Paint()
          ..color = _rockHighlightTint.withAlpha(_rockHighlightAlpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = _rockBoxStrokeWidth
          ..isAntiAlias = true;
        canvas.drawPath(path, strokePaint);
      }
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
        rockBox != oldDelegate.rockBox ||
        rockMask != oldDelegate.rockMask ||
        cropBox != oldDelegate.cropBox ||
        !listEquals(palette, oldDelegate.palette) ||
        !listEquals(routes, oldDelegate.routes);
  }
}
