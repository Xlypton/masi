import 'dart:typed_data';
import 'dart:ui';

/// A 3x3 projective transform (homography) used to warp points between
/// coordinate spaces (e.g. an original reference photo and a live camera
/// frame during AR alignment).
///
/// Pure Dart only: this file must not depend on `package:flutter/material.dart`
/// or `package:flutter/widgets.dart` so it can be used from non-UI code and
/// tested without the full Flutter widget stack.
///
/// The matrix [m] holds 9 elements in ROW-MAJOR order:
/// ```
/// [ m00, m01, m02,
///   m10, m11, m12,
///   m20, m21, m22 ]
/// ```
/// A point `(x, y)` is warped via the homogeneous transform:
/// ```
/// x' = m00*x + m01*y + m02
/// y' = m10*x + m11*y + m12
/// w' = m20*x + m21*y + m22
/// result = (x'/w', y'/w')
/// ```
class Homography {
  /// The 9 matrix elements, row-major: [m00,m01,m02, m10,m11,m12, m20,m21,m22].
  final Float64List m;

  /// Creates a homography backed directly by [m].
  ///
  /// This constructor TAKES OWNERSHIP of [m] and does NOT defensively copy
  /// it: the [Float64List] instance passed in becomes this homography's
  /// backing storage. Callers must not mutate the list after passing it in,
  /// since [Homography] is intended to be immutable. If you cannot guarantee
  /// that the source list won't be mutated afterward, use
  /// [Homography.fromRowMajor] instead, which copies the values.
  const Homography(this.m);

  /// The identity homography: warp is a no-op.
  factory Homography.identity() {
    return Homography(
      Float64List.fromList(<double>[
        1, 0, 0, //
        0, 1, 0, //
        0, 0, 1, //
      ]),
    );
  }

  /// Builds a homography from a flat row-major list of 9 doubles.
  factory Homography.fromRowMajor(List<double> v) {
    assert(v.length == 9, 'Homography.fromRowMajor requires exactly 9 values');
    return Homography(Float64List.fromList(v));
  }

  /// A pure translation homography by ([tx], [ty]).
  factory Homography.translation(double tx, double ty) {
    return Homography(
      Float64List.fromList(<double>[
        1, 0, tx, //
        0, 1, ty, //
        0, 0, 1, //
      ]),
    );
  }

  /// Returns the 9 matrix elements as a row-major list.
  List<double> toRowMajor() => List<double>.unmodifiable(m);

  /// Warps a point [p] through this homography using homogeneous coordinates.
  ///
  /// Guard: if the homogeneous denominator `w'` is (near) zero
  /// (`w'.abs() < 1e-12`), or the resulting point would be non-finite
  /// (NaN/Infinity), this returns [p] unchanged rather than propagating a
  /// degenerate result. This is a documented sentinel behavior, not a "best
  /// effort" warp.
  Offset warp(Offset p) {
    final double x = p.dx;
    final double y = p.dy;

    final double xPrime = m[0] * x + m[1] * y + m[2];
    final double yPrime = m[3] * x + m[4] * y + m[5];
    final double wPrime = m[6] * x + m[7] * y + m[8];

    if (wPrime.abs() < 1e-12) {
      return p;
    }

    final double resultX = xPrime / wPrime;
    final double resultY = yPrime / wPrime;

    if (!resultX.isFinite || !resultY.isFinite) {
      return p;
    }

    return Offset(resultX, resultY);
  }

  /// Warps a point given as a fraction (0..1) of [refSize] (e.g. a point
  /// expressed as a percentage of the original reference photo's dimensions)
  /// into the target coordinate space defined by this homography.
  Offset warpOriginalPercent(Offset percent, Size refSize) {
    return warp(Offset(percent.dx * refSize.width, percent.dy * refSize.height));
  }

  /// Composes this homography with [other], producing a new homography
  /// equivalent to applying [other] first, then `this` (i.e. `this * other`
  /// in matrix form).
  Homography multiply(Homography other) {
    final Float64List a = m;
    final Float64List b = other.m;
    final Float64List result = Float64List(9);

    for (int row = 0; row < 3; row++) {
      for (int col = 0; col < 3; col++) {
        double sum = 0;
        for (int k = 0; k < 3; k++) {
          sum += a[row * 3 + k] * b[k * 3 + col];
        }
        result[row * 3 + col] = sum;
      }
    }

    return Homography(result);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! Homography) return false;
    if (other.m.length != m.length) return false;
    for (int i = 0; i < m.length; i++) {
      if (m[i] != other.m[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(m);

  @override
  String toString() => 'Homography(${m.join(', ')})';
}
