import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// The translucent tint the rock mask is painted with. The decoded mask image
/// (see `decodeRockMaskAlpha`) is a per-texel alpha stencil (0 or 255 alpha)
/// with a constant baked RGB; this [ColorFilter] recolors it to this tint via
/// [BlendMode.srcIn] (output = tint.rgb, alpha = tint.alpha * maskAlpha), so
/// the highlight reads as a semi-transparent wash over the rock rather than an
/// opaque fill that would hide the photo underneath. Cyan reads well over most
/// rock/foliage.
const Color _kRockHighlightTint = Color(0x6600E5FF);

/// A standalone [CustomPainter] that draws a rock-segmentation [mask] stretched
/// to cover [imageSize], tinted via a [BlendMode.srcIn] [ColorFilter] so only
/// the masked (rock) region is washed in [_kRockHighlightTint].
///
/// Deliberately self-contained — it takes ONLY a decoded [ui.Image] and a
/// target [Size], with no provider/channel/IO dependency — so it is directly
/// widget-testable with a fake image and needs no device or real segmentation.
///
/// Coordinate frame: the mask lives in the same 0..1 frame as the full upright
/// reference photo (its pixel dims are the DOWNSAMPLED mask dims, not the
/// photo's — see `ArSegmentationResult.mask`), so it is drawn with an
/// independent-x/y `drawImageRect` from the full mask rect onto the full
/// [imageSize] rect; that stretch self-corrects any aspect mismatch. It shares
/// the enclosing `InteractiveViewer` transform automatically (same as the
/// photo and route painter it's layered between), so no homography is applied
/// here.
class RockMaskPainter extends CustomPainter {
  const RockMaskPainter({required this.mask, required this.imageSize});

  /// The paint-ready RGBA segmentation image (per-texel alpha stencil).
  final ui.Image mask;

  /// The natural (decoded) size of the photo the mask is stretched over — the
  /// same `imageSize` the photo and `TopoPainter` use, so all three layers
  /// register pixel-for-pixel under the shared view transform.
  final Size imageSize;

  @override
  void paint(Canvas canvas, Size size) {
    final src = Rect.fromLTWH(
      0,
      0,
      mask.width.toDouble(),
      mask.height.toDouble(),
    );
    final dst = Rect.fromLTWH(0, 0, imageSize.width, imageSize.height);
    final paint = Paint()
      ..colorFilter = const ColorFilter.mode(
        _kRockHighlightTint,
        BlendMode.srcIn,
      )
      ..filterQuality = FilterQuality.low
      ..isAntiAlias = true;
    canvas.drawImageRect(mask, src, dst, paint);
  }

  @override
  bool shouldRepaint(RockMaskPainter oldDelegate) =>
      !identical(oldDelegate.mask, mask) || oldDelegate.imageSize != imageSize;
}
