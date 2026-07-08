import 'dart:ui';

import 'package:flutter/widgets.dart' show Matrix4, MatrixUtils;

/// Pure, stateless coordinate transforms used by the topo canvas.
///
/// Every method here is a plain mathematical transform with no side
/// effects and no dependency on widget/render state beyond the values
/// explicitly passed in. This file intentionally avoids importing
/// `package:flutter/material.dart`; it only needs `dart:ui` primitives
/// (`Offset`, `Size`) plus `Matrix4`/`MatrixUtils`, both of which are
/// available from `package:flutter/widgets.dart`.
class CoordinateTransformer {
  const CoordinateTransformer._();

  /// Converts a point expressed as a fraction of [imageSize] (0.0-1.0 on
  /// each axis) into scene/pixel coordinates.
  static Offset percentToScene(Offset percent, Size imageSize) {
    return Offset(
      percent.dx * imageSize.width,
      percent.dy * imageSize.height,
    );
  }

  /// Inverse of [percentToScene]: converts a scene/pixel point back into a
  /// fraction of [imageSize].
  ///
  /// Each axis is guarded independently: if [imageSize.width] is zero the
  /// resulting `dx` is `0.0` (instead of the `Infinity`/`NaN` that dividing
  /// by zero would produce), and likewise for `dy` and [imageSize.height].
  /// This can happen transiently while an image is still loading/laying out
  /// and has not yet been assigned a real size.
  static Offset sceneToPercent(Offset scene, Size imageSize) {
    return Offset(
      imageSize.width == 0 ? 0.0 : scene.dx / imageSize.width,
      imageSize.height == 0 ? 0.0 : scene.dy / imageSize.height,
    );
  }

  /// Maps a point in screen space into scene space by applying the inverse
  /// of [transform].
  ///
  /// If [transform] is singular (not invertible), this method returns
  /// [screenPoint] unchanged rather than throwing or propagating
  /// NaN/Infinity — a degenerate transform has no meaningful inverse
  /// mapping, and returning the input is the safest fallback for
  /// interactive gesture handling. Invertibility is checked robustly via
  /// [Matrix4.tryInvert] rather than an exact `determinant() == 0`
  /// comparison, since near-singular matrices can have a tiny non-zero
  /// determinant yet still fail to invert meaningfully.
  static Offset screenToScene(Offset screenPoint, Matrix4 transform) {
    final inverse = Matrix4.tryInvert(transform);
    if (inverse == null) {
      return screenPoint;
    }
    return MatrixUtils.transformPoint(inverse, screenPoint);
  }

  /// Reprojects a point expressed as a percentage of the *original* image
  /// into a percentage of a cropped slice of that image.
  ///
  /// [cropXpct] is the left edge of the crop region and [cropWidthPct] is
  /// its width, both expressed as a fraction (0.0-1.0) of the original
  /// image width. The Y axis is unaffected, since cropping is horizontal
  /// only.
  ///
  /// If [cropWidthPct] is zero (or not finite), the crop slice has no
  /// width and there is no meaningful mapping onto it, so `dx` collapses
  /// to `0.0` instead of propagating the `NaN`/`Infinity` that dividing by
  /// zero would otherwise produce into stored route coordinates. `dy` is
  /// returned untouched.
  static Offset originalPercentToSlicePercent(
    Offset p,
    double cropXpct,
    double cropWidthPct,
  ) {
    if (cropWidthPct == 0 || !cropWidthPct.isFinite) {
      return Offset(0.0, p.dy);
    }
    return Offset((p.dx - cropXpct) / cropWidthPct, p.dy);
  }

  /// Inverse of [originalPercentToSlicePercent]: maps a point expressed as
  /// a percentage of the cropped slice back to a percentage of the
  /// original image.
  static Offset slicePercentToOriginalPercent(
    Offset p,
    double cropXpct,
    double cropWidthPct,
  ) {
    return Offset(p.dx * cropWidthPct + cropXpct, p.dy);
  }
}
