import 'dart:math';
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

  /// A pure (anisotropic) scale homography by ([sx], [sy]).
  factory Homography.scale(double sx, double sy) {
    return Homography(
      Float64List.fromList(<double>[
        sx, 0, 0, //
        0, sy, 0, //
        0, 0, 1, //
      ]),
    );
  }

  /// Maps points in [content]'s pixel space into [view]'s point space using
  /// aspect-FIT (a.k.a. "contain") scaling: [content] is scaled uniformly so
  /// it fits entirely within [view], centered, with letterboxing on
  /// whichever axis has leftover space.
  ///
  /// Useful for placing a reference photo (content space) inside a
  /// differently-proportioned view/screen (view space) without cropping.
  ///
  /// If [content] has a non-positive width or height (degenerate/unknown
  /// size), returns [Homography.identity] to avoid dividing by zero.
  factory Homography.fitInto(Size content, Size view) {
    if (content.width <= 0 || content.height <= 0) {
      return Homography.identity();
    }
    final double s = min(view.width / content.width, view.height / content.height);
    final double tx = (view.width - content.width * s) / 2;
    final double ty = (view.height - content.height * s) / 2;
    return Homography.translation(tx, ty).multiply(Homography.scale(s, s));
  }

  /// Maps points in [content]'s pixel space into [view]'s point space using
  /// aspect-FILL (a.k.a. "cover") scaling: [content] is scaled uniformly so
  /// it completely covers [view], centered, cropping whichever axis has
  /// overflow.
  ///
  /// If [content] has a non-positive width or height (degenerate/unknown
  /// size), returns [Homography.identity] to avoid dividing by zero.
  factory Homography.fillInto(Size content, Size view) {
    if (content.width <= 0 || content.height <= 0) {
      return Homography.identity();
    }
    final double s = max(view.width / content.width, view.height / content.height);
    final double tx = (view.width - content.width * s) / 2;
    final double ty = (view.height - content.height * s) / 2;
    return Homography.translation(tx, ty).multiply(Homography.scale(s, s));
  }

  /// Solves the 4-point projective homography (DLT, i.e. Direct Linear
  /// Transform) that maps the quad [src] onto the quad [dst], such that
  /// `warp(src[i])` is approximately `dst[i]` for each `i` in 0..3.
  ///
  /// Used to map the 4 corners of a reference topo photo onto the 4 screen
  /// corners ARKit reports for the tracked anchor each frame, producing the
  /// per-frame transform that projects the route overlay onto the live
  /// camera image.
  ///
  /// Both [src] and [dst] must have exactly 4 points (asserted).
  ///
  /// Internally this assembles the 8x8 linear system for the 8 unknowns
  /// `[h00, h01, h02, h10, h11, h12, h20, h21]` (with `h22` fixed to `1`)
  /// implied by the 2 equations each correspondence contributes, then solves
  /// it via Gaussian elimination with partial pivoting -- pure Dart, no
  /// external packages.
  ///
  /// If the system is singular (e.g. [src] or [dst] points are collinear or
  /// otherwise degenerate), this returns [Homography.identity] rather than
  /// throwing or producing NaN/Infinity.
  factory Homography.fromQuad(List<Offset> src, List<Offset> dst) {
    assert(src.length == 4, 'Homography.fromQuad requires exactly 4 src points');
    assert(dst.length == 4, 'Homography.fromQuad requires exactly 4 dst points');

    // Each correspondence (x,y) -> (u,v) contributes two rows to an 8x8
    // augmented matrix (8 unknown coefficients + 1 RHS column):
    //   h00*x + h01*y + h02 - h20*x*u - h21*y*u = u
    //   h10*x + h11*y + h12 - h20*x*v - h21*y*v = v
    final List<Float64List> a = List<Float64List>.generate(8, (_) => Float64List(9));

    for (int i = 0; i < 4; i++) {
      final double x = src[i].dx;
      final double y = src[i].dy;
      final double u = dst[i].dx;
      final double v = dst[i].dy;

      final Float64List rowU = a[2 * i];
      rowU[0] = x;
      rowU[1] = y;
      rowU[2] = 1;
      rowU[3] = 0;
      rowU[4] = 0;
      rowU[5] = 0;
      rowU[6] = -x * u;
      rowU[7] = -y * u;
      rowU[8] = u;

      final Float64List rowV = a[2 * i + 1];
      rowV[0] = 0;
      rowV[1] = 0;
      rowV[2] = 0;
      rowV[3] = x;
      rowV[4] = y;
      rowV[5] = 1;
      rowV[6] = -x * v;
      rowV[7] = -y * v;
      rowV[8] = v;
    }

    final List<double>? h = _solve8x8(a);
    if (h == null) {
      return Homography.identity();
    }

    return Homography.fromRowMajor(<double>[
      h[0], h[1], h[2], //
      h[3], h[4], h[5], //
      h[6], h[7], 1.0, //
    ]);
  }

  /// Solves the 8x8 linear system encoded as an augmented matrix (8 rows,
  /// 9 columns each: 8 coefficients followed by the RHS value) via
  /// Gauss-Jordan elimination with partial pivoting.
  ///
  /// Returns the 8-element solution vector, or `null` if the system is
  /// singular -- i.e. the largest-magnitude pivot candidate found in a
  /// column is (near) zero (`< 1e-10`), which happens for degenerate
  /// (e.g. collinear) point configurations.
  static List<double>? _solve8x8(List<Float64List> a) {
    const int n = 8;
    const double epsilon = 1e-10;

    for (int col = 0; col < n; col++) {
      // Partial pivoting: swap in the row (at or below this one) with the
      // largest-magnitude entry in this column, for numerical stability.
      int pivotRow = col;
      double maxAbs = a[col][col].abs();
      for (int row = col + 1; row < n; row++) {
        final double candidate = a[row][col].abs();
        if (candidate > maxAbs) {
          maxAbs = candidate;
          pivotRow = row;
        }
      }

      if (maxAbs < epsilon) {
        return null;
      }

      if (pivotRow != col) {
        final Float64List tmp = a[col];
        a[col] = a[pivotRow];
        a[pivotRow] = tmp;
      }

      // Eliminate this column from every other row.
      final Float64List pivot = a[col];
      final double pivotVal = pivot[col];
      for (int row = 0; row < n; row++) {
        if (row == col) continue;
        final Float64List r = a[row];
        final double factor = r[col] / pivotVal;
        if (factor == 0) continue;
        for (int k = col; k <= n; k++) {
          r[k] -= factor * pivot[k];
        }
      }
    }

    // Every row now has only its diagonal entry non-zero among the
    // coefficient columns, so the solution is just RHS / diagonal.
    final List<double> result = List<double>.filled(n, 0);
    for (int row = 0; row < n; row++) {
      result[row] = a[row][n] / a[row][row];
    }
    return result;
  }

  /// Returns the 9 matrix elements as a row-major list.
  List<double> toRowMajor() => List<double>.unmodifiable(m);

  /// Embeds this 2D projective 3x3 transform into a 4x4 matrix suitable for
  /// [Canvas.transform] (and `Matrix4`), with an identity z-axis so z passes
  /// through unchanged.
  ///
  /// The 4x4 (row-major, for reference) is:
  /// ```
  /// [ m00, m01, 0, m02,
  ///   m10, m11, 0, m12,
  ///   0,   0,   1, 0,
  ///   m20, m21, 0, m22 ]
  /// ```
  /// but this returns it flattened COLUMN-MAJOR (storage index = col*4 +
  /// row), which is the layout `Canvas.transform`/`Matrix4` expect.
  Float64List toMatrix4ColumnMajor() {
    return Float64List.fromList(<double>[
      m[0], m[3], 0, m[6], //
      m[1], m[4], 0, m[7], //
      0, 0, 1, 0, //
      m[2], m[5], 0, m[8], //
    ]);
  }

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
