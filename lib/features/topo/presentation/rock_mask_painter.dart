import 'package:flutter/material.dart';

import 'package:masi/core/coordinates/coordinate_transformer.dart';
import 'package:masi/features/ar/domain/rock_box.dart';

/// The flat tint the rock box is drawn with. Cyan reads well as a highlight
/// over most rock/foliage photos. Mirrors `ar_overlay_painter.dart`'s
/// `_rockHighlightTint` (same hex, same fill/stroke alpha split) so the
/// topo-canvas preview and the AR overlay read as the same highlight.
const Color _kRockHighlightTint = Color(0xFF00E5FF);

/// Alpha (0-255) applied to [_kRockHighlightTint] for the box's STROKE (its
/// outline).
const int _kRockHighlightStrokeAlpha = 160;

/// Alpha (0-255) applied to [_kRockHighlightTint] for the box's faint FILL
/// (~18% opacity) -- translucent enough that the photo underneath still
/// clearly shows through the highlighted area.
const int _kRockBoxFillAlpha = 46;

/// Stroke width (canvas px) for the box's outline.
const double _kRockBoxStrokeWidth = 3.0;

/// A standalone [CustomPainter] that draws the route-derived rock [box] (see
/// `rock_box.dart`'s `rockBoxFromRoutes`) over [imageSize]: a faint tinted
/// fill plus a tinted stroke outline, both in [_kRockHighlightTint].
///
/// Deliberately self-contained -- it takes ONLY a normalized [box] and a
/// target [Size], with no provider/route-list/IO dependency -- so it is
/// directly widget-testable with a plain [Rect] and needs no device, no
/// image decode, and no drawn routes.
///
/// Coordinate frame: [box] is expressed in the same 0..1 percent space
/// [TopoRoute.points] already uses, so each corner is converted to scene
/// pixels via [CoordinateTransformer.percentToScene] before drawing. It
/// shares the enclosing `InteractiveViewer` transform automatically (same as
/// the photo and route painter it's layered between), so no homography is
/// applied here -- unlike `ArOverlayPainter.rockBox`, which warps the same
/// corners through a `Homography` instead.
class RockBoxPainter extends CustomPainter {
  const RockBoxPainter({required this.box, required this.imageSize});

  /// The route-derived rock box, in 0..1 fractions of [imageSize] (top-left
  /// origin) -- see `rockBoxFromRoutes`.
  final Rect box;

  /// The natural (decoded) size of the photo the box is drawn over -- the
  /// same `imageSize` the photo and `TopoPainter` use, so all layers
  /// register pixel-for-pixel under the shared view transform.
  final Size imageSize;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..addPolygon(
        [
          for (final corner in rockBoxCornersNorm(box))
            CoordinateTransformer.percentToScene(corner, imageSize),
        ],
        true,
      );

    final fillPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = _kRockHighlightTint.withAlpha(_kRockBoxFillAlpha);
    canvas.drawPath(path, fillPaint);

    final strokePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _kRockBoxStrokeWidth
      ..isAntiAlias = true
      ..color = _kRockHighlightTint.withAlpha(_kRockHighlightStrokeAlpha);
    canvas.drawPath(path, strokePaint);
  }

  @override
  bool shouldRepaint(RockBoxPainter oldDelegate) =>
      oldDelegate.box != box || oldDelegate.imageSize != imageSize;
}
