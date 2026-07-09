import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:climbtopo/features/ar/domain/homography.dart';

/// Drives user-hand alignment of the ghost overlay: pan/scale/rotate
/// gestures compose into a single [Homography] that the overlay painter
/// applies to warp the reference photo's points into the live screen space.
///
/// The overlay painter only ever consumes a [Homography] — it is mode-
/// agnostic about *how* that homography was produced (solved from markers,
/// or hand-adjusted here), which keeps manual alignment a drop-in
/// alternative to automatic alignment.
///
/// ## Composition convention
///
/// The transform this controller holds is a 2D affine (translate/scale/
/// rotate) encoded in the bottom row `[0, 0, 1]` of the 3x3 homography — no
/// projective (perspective) component is ever introduced here.
///
/// Every gesture is interpreted as happening in the *current* screen space,
/// i.e. it is applied ON TOP of whatever adjustment the user has already
/// made. Concretely, for a gesture matrix `G` and current state `S`, the new
/// state is:
///
/// ```
/// S' = G.multiply(S)
/// ```
///
/// Since [Homography.multiply] documents `a.multiply(b)` as "`b` applied
/// first, then `a`", this means: warp a point through the old state `S`
/// first (i.e. through every adjustment made so far), then apply the new
/// gesture `G` — matching how a user expects "drag the overlay 10px right"
/// to move the overlay from wherever it currently sits, not from its
/// original identity position.
///
/// - **pan(delta)**: `G = Homography.translation(delta.dx, delta.dy)`.
/// - **scale(factor, focal)**: `G = T(focal) * S(factor) * T(-focal)` (scale
///   about a fixed focal point). Built by composing three homographies with
///   [Homography.multiply], right-to-left: `T(-focal)` applied first, then
///   the raw scale, then `T(focal)` to shift the fixed point back.
/// - **rotate(radians, focal)**: `G = T(focal) * R(radians) * T(-focal)`
///   (rotate about a fixed focal point), built the same way.
///
/// The rotation matrix `R(theta)` used is the standard counter-clockwise
/// (in a y-down screen space, this reads as clockwise-on-screen) convention:
/// ```
/// [ cos(theta), -sin(theta), 0,
///   sin(theta),  cos(theta), 0,
///   0,           0,          1 ]
/// ```
/// which maps `(1, 0) -> (cos(theta), sin(theta))`; for `theta = pi/2` this
/// sends `(1, 0) -> (0, 1)`.
class ManualAlignController extends Notifier<Homography> {
  @override
  Homography build() => Homography.identity();

  /// Pans (translates) the overlay by [delta], in the same coordinate space
  /// the overlay warps into (screen points). Composed on top of the current
  /// state: `Homography.translation(delta.dx, delta.dy).multiply(state)`.
  void pan(Offset delta) {
    state = Homography.translation(delta.dx, delta.dy).multiply(state);
  }

  /// Scales the overlay by [factor] about the fixed point [focal]: distances
  /// from [focal] are scaled by [factor], and [focal] itself stays put.
  /// Composed on top of the current state.
  void scale(double factor, Offset focal) {
    final Homography gesture = Homography.translation(focal.dx, focal.dy)
        .multiply(_scaleMatrix(factor))
        .multiply(Homography.translation(-focal.dx, -focal.dy));
    state = gesture.multiply(state);
  }

  /// Rotates the overlay by [radians] about the fixed point [focal]: the
  /// overlay is rotated around [focal], which itself stays put. Composed on
  /// top of the current state.
  void rotate(double radians, Offset focal) {
    final Homography gesture = Homography.translation(focal.dx, focal.dy)
        .multiply(_rotationMatrix(radians))
        .multiply(Homography.translation(-focal.dx, -focal.dy));
    state = gesture.multiply(state);
  }

  /// Discards every pan/scale/rotate adjustment made so far, returning the
  /// overlay to its identity (un-adjusted) alignment.
  void reset() {
    state = Homography.identity();
  }

  /// A pure uniform-scale homography (no translation): `diag(factor, factor, 1)`.
  static Homography _scaleMatrix(double factor) {
    return Homography.fromRowMajor(<double>[
      factor, 0, 0, //
      0, factor, 0, //
      0, 0, 1, //
    ]);
  }

  /// A pure rotation homography by [radians] (see class doc for sign
  /// convention): `(1, 0) -> (cos(radians), sin(radians))`.
  static Homography _rotationMatrix(double radians) {
    final double c = math.cos(radians);
    final double s = math.sin(radians);
    return Homography.fromRowMajor(<double>[
      c, -s, 0, //
      s, c, 0, //
      0, 0, 1, //
    ]);
  }
}

/// Exposes the current manual-alignment [Homography], starting at identity.
final manualAlignProvider =
    NotifierProvider<ManualAlignController, Homography>(
      ManualAlignController.new,
    );
