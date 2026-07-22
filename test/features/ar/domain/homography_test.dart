import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:masi/features/ar/domain/homography.dart';

/// Test-only mirror of the area/span^2 ratio `isDegenerateQuadSolve` computes
/// internally (bounding-box span via [max], shoelace area) -- duplicated
/// here purely so the boundary-pinning fixtures below can assert their own
/// numbers rather than relying on hand arithmetic in a comment alone. Not a
/// call into production code: `_quadArea`/the span calc are library-private
/// to `homography.dart`.
double _quadAreaOverSpanSquared(List<Offset> q) {
  double minX = q[0].dx, maxX = q[0].dx;
  double minY = q[0].dy, maxY = q[0].dy;
  for (final p in q) {
    if (p.dx < minX) minX = p.dx;
    if (p.dx > maxX) maxX = p.dx;
    if (p.dy < minY) minY = p.dy;
    if (p.dy > maxY) maxY = p.dy;
  }
  final double span = max(maxX - minX, maxY - minY);

  double sum = 0;
  for (int i = 0; i < 4; i++) {
    final Offset a = q[i];
    final Offset b = q[(i + 1) % 4];
    sum += a.dx * b.dy - b.dx * a.dy;
  }
  final double area = sum.abs() / 2.0;

  return area / (span * span);
}

void main() {
  group('Homography.identity', () {
    test('A1: warp is a no-op', () {
      final h = Homography.identity();
      final result = h.warp(const Offset(3, 7));
      expect(result.dx, closeTo(3, 1e-9));
      expect(result.dy, closeTo(7, 1e-9));
    });

    test('toRowMajor round-trips', () {
      final h = Homography.identity();
      expect(h.toRowMajor(), [1, 0, 0, 0, 1, 0, 0, 0, 1]);
    });

    test('toMatrix4ColumnMajor produces the 16-elt identity, column-major', () {
      final h = Homography.identity();
      expect(
        h.toMatrix4ColumnMajor(),
        [
          1, 0, 0, 0, //
          0, 1, 0, 0, //
          0, 0, 1, 0, //
          0, 0, 0, 1, //
        ],
      );
    });
  });

  group('Homography.translation', () {
    test('A2: translates a point', () {
      final h = Homography.translation(10, -5);
      final result = h.warp(const Offset(2, 2));
      expect(result.dx, closeTo(12, 1e-9));
      expect(result.dy, closeTo(-3, 1e-9));
    });

    test('toMatrix4ColumnMajor: tx/ty land at indices 12/13, otherwise identity', () {
      final h = Homography.translation(5, 7);
      final m4 = h.toMatrix4ColumnMajor();

      expect(m4.length, 16);
      expect(m4[12], 5);
      expect(m4[13], 7);

      final expected = [
        1, 0, 0, 0, //
        0, 1, 0, 0, //
        0, 0, 1, 0, //
        5, 7, 0, 1, //
      ];
      for (var i = 0; i < 16; i++) {
        expect(m4[i], closeTo(expected[i], 1e-9), reason: 'index $i');
      }
    });
  });

  group('Homography.scale', () {
    test('scales x and y independently', () {
      final h = Homography.scale(2, 3);
      final result = h.warp(const Offset(4, 5));
      expect(result.dx, closeTo(8, 1e-9));
      expect(result.dy, closeTo(15, 1e-9));
    });

    test('toMatrix4ColumnMajor: sx/sy land at indices 0/5', () {
      final h = Homography.scale(2, 3);
      final m4 = h.toMatrix4ColumnMajor();

      expect(m4[0], 2);
      expect(m4[5], 3);
    });
  });

  group('Homography.fitInto', () {
    test('uniform aspect: center maps to center, corners map to corners', () {
      final h = Homography.fitInto(const Size(1000, 2000), const Size(400, 800));

      final center = h.warp(const Offset(500, 1000));
      expect(center.dx, closeTo(200, 1e-9));
      expect(center.dy, closeTo(400, 1e-9));

      final topLeft = h.warp(const Offset(0, 0));
      expect(topLeft.dx, closeTo(0, 1e-9));
      expect(topLeft.dy, closeTo(0, 1e-9));

      final bottomRight = h.warp(const Offset(1000, 2000));
      expect(bottomRight.dx, closeTo(400, 1e-9));
      expect(bottomRight.dy, closeTo(800, 1e-9));
    });

    test('non-uniform aspect: letterboxes vertically, centers content', () {
      // content is square, view is taller/narrower -> s = min(400/1000, 800/1000) = 0.4
      final h = Homography.fitInto(const Size(1000, 1000), const Size(400, 800));

      final center = h.warp(const Offset(500, 500));
      expect(center.dx, closeTo(200, 1e-9));
      expect(center.dy, closeTo(400, 1e-9));

      final topLeft = h.warp(const Offset(0, 0));
      expect(topLeft.dx, closeTo(0, 1e-9));
      expect(topLeft.dy, closeTo(200, 1e-9));
    });

    test('zero-guard: degenerate content size returns identity', () {
      final h = Homography.fitInto(const Size(0, 0), const Size(400, 800));
      final result = h.warp(const Offset(3, 7));
      expect(result.dx, closeTo(3, 1e-9));
      expect(result.dy, closeTo(7, 1e-9));
    });
  });

  group('Homography.fillInto', () {
    test('non-uniform aspect: crops, centers content, center maps to center', () {
      // s = max(400/720, 800/1280) = max(0.5556, 0.625) = 0.625
      final h = Homography.fillInto(const Size(720, 1280), const Size(400, 800));

      final center = h.warp(const Offset(360, 640));
      expect(center.dx, closeTo(200, 1e-9));
      expect(center.dy, closeTo(400, 1e-9));

      final topLeft = h.warp(const Offset(0, 0));
      expect(topLeft.dx, closeTo(-25, 1e-9));
      expect(topLeft.dy, closeTo(0, 1e-9));
    });
  });

  group('warp', () {
    test('A3: scale homography warps correctly', () {
      final h = Homography.fromRowMajor([2, 0, 0, 0, 3, 0, 0, 0, 1]);
      final result = h.warp(const Offset(4, 5));
      expect(result.dx, closeTo(8, 1e-9));
      expect(result.dy, closeTo(15, 1e-9));
    });

    test('A3: projective homography with non-zero bottom row', () {
      final h = Homography.fromRowMajor([1, 0, 0, 0, 1, 0, 0.001, 0, 1]);
      const p = Offset(10, 20);
      final wPrime = 0.001 * p.dx + 1;
      final expectedX = p.dx / wPrime;
      final expectedY = p.dy / wPrime;

      final result = h.warp(p);
      expect(result.dx, closeTo(expectedX, 1e-9));
      expect(result.dy, closeTo(expectedY, 1e-9));
    });

    test('A4: near-degenerate w\' returns input unchanged, no NaN/Infinity', () {
      // Bottom row chosen so that w' = m20*x + m21*y + m22 ≈ 0 at p.
      // m20*10 + m21*0 + m22 = 0  =>  pick m20=-0.1, m22=1 => w' = -0.1*10+1=0
      final h = Homography.fromRowMajor([1, 0, 0, 0, 1, 0, -0.1, 0, 1]);
      const p = Offset(10, 5);
      final result = h.warp(p);

      expect(result.dx.isFinite, isTrue);
      expect(result.dy.isFinite, isTrue);
      expect(result.dx, closeTo(p.dx, 1e-9));
      expect(result.dy, closeTo(p.dy, 1e-9));
    });
  });

  group('warpOriginalPercent', () {
    test('A5: identity maps percent to absolute pixels', () {
      final h = Homography.identity();
      final result =
          h.warpOriginalPercent(const Offset(0.5, 0.5), const Size(1000, 800));
      expect(result.dx, closeTo(500, 1e-9));
      expect(result.dy, closeTo(400, 1e-9));
    });

    test('A5: translation composes with percent-to-pixel conversion', () {
      final h = Homography.translation(100, 50);
      final result =
          h.warpOriginalPercent(const Offset(0.5, 0.5), const Size(1000, 800));
      expect(result.dx, closeTo(600, 1e-9));
      expect(result.dy, closeTo(450, 1e-9));
    });
  });

  group('multiply', () {
    test('A6: composition of two translations', () {
      final h = Homography.translation(10, 0).multiply(Homography.translation(0, 5));
      final result = h.warp(const Offset(1, 1));
      expect(result.dx, closeTo(11, 1e-9));
      expect(result.dy, closeTo(6, 1e-9));
    });

    test('A6: identity.multiply(H) warps equally to H', () {
      final hOther = Homography.fromRowMajor([2, 0, 3, 0, 2, 4, 0, 0, 1]);
      final composed = Homography.identity().multiply(hOther);

      for (final p in [
        const Offset(0, 0),
        const Offset(5, -3),
        const Offset(100, 200),
      ]) {
        final expected = hOther.warp(p);
        final actual = composed.warp(p);
        expect(actual.dx, closeTo(expected.dx, 1e-9));
        expect(actual.dy, closeTo(expected.dy, 1e-9));
      }
    });

    test('A6: non-commutative pair proves operand order is respected', () {
      // T and S do not commute: applying S then T differs from applying T
      // then S. This guards against an operand-order/transpose bug that the
      // earlier commutative-only tests (translation-with-translation,
      // identity-with-H) cannot detect.
      final t = Homography.translation(10, 0);
      final s = Homography.fromRowMajor([2, 0, 0, 0, 3, 0, 0, 0, 1]);
      const p = Offset(1, 1);

      // T.multiply(S): S applied first -> (2, 3), then T -> (12, 3).
      final tThenS = t.multiply(s).warp(p);
      expect(tThenS.dx, closeTo(12, 1e-9));
      expect(tThenS.dy, closeTo(3, 1e-9));

      // S.multiply(T): T applied first -> (11, 1), then S -> (22, 3).
      final sThenT = s.multiply(t).warp(p);
      expect(sThenT.dx, closeTo(22, 1e-9));
      expect(sThenT.dy, closeTo(3, 1e-9));

      // Order matters: the two compositions must differ.
      expect(tThenS, isNot(equals(sThenT)));
    });
  });

  group('equality, hashCode, toString', () {
    test('equal matrices are equal and share hashCode', () {
      final a = Homography.fromRowMajor([1, 2, 3, 4, 5, 6, 7, 8, 9]);
      final b = Homography.fromRowMajor([1, 2, 3, 4, 5, 6, 7, 8, 9]);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('different matrices are not equal', () {
      final a = Homography.identity();
      final b = Homography.translation(1, 0);
      expect(a == b, isFalse);
    });

    test('toString does not throw and contains values', () {
      final a = Homography.identity();
      expect(a.toString(), isA<String>());
      expect(a.toString().isNotEmpty, isTrue);
    });
  });

  group('constructors', () {
    test('const Homography constructor works with a raw Float64List', () {
      final m = Float64List.fromList([1, 0, 0, 0, 1, 0, 0, 0, 1]);
      final h = Homography(m);
      expect(h.warp(const Offset(2, 2)), const Offset(2, 2));
    });

    test('fromRowMajor asserts length 9', () {
      expect(() => Homography.fromRowMajor([1, 2, 3]), throwsA(anything));
    });
  });

  group('Homography.fromQuad', () {
    test('B1: pure translation+scale maps all 4 corners and an interior point', () {
      const src = [
        Offset(0, 0),
        Offset(100, 0),
        Offset(100, 200),
        Offset(0, 200),
      ];
      // dst is src scaled by 0.5 then offset by (10, 20).
      const dst = [
        Offset(10, 20),
        Offset(60, 20),
        Offset(60, 120),
        Offset(10, 120),
      ];

      final h = Homography.fromQuad(src, dst);

      for (var i = 0; i < 4; i++) {
        final result = h.warp(src[i]);
        expect(result.dx, closeTo(dst[i].dx, 1e-6), reason: 'corner $i dx');
        expect(result.dy, closeTo(dst[i].dy, 1e-6), reason: 'corner $i dy');
      }

      // Interior point: src center (50, 100) -> dst center (35, 70).
      final center = h.warp(const Offset(50, 100));
      expect(center.dx, closeTo(35, 1e-6));
      expect(center.dy, closeTo(70, 1e-6));
    });

    test('B2: src == dst leaves an interior point unchanged', () {
      const quad = [
        Offset(10, 10),
        Offset(110, 10),
        Offset(110, 210),
        Offset(10, 210),
      ];

      final h = Homography.fromQuad(quad, quad);

      final result = h.warp(const Offset(60, 110));
      expect(result.dx, closeTo(60, 1e-6));
      expect(result.dy, closeTo(110, 1e-6));

      for (final corner in quad) {
        final warped = h.warp(corner);
        expect(warped.dx, closeTo(corner.dx, 1e-6));
        expect(warped.dy, closeTo(corner.dy, 1e-6));
      }
    });

    test(
      'B3: genuinely projective (non-affine) trapezoid dst solves perspective terms',
      () {
        // src is a square; dst is a trapezoid (the two non-parallel sides are
        // not parallel to one another), which is NOT the affine image of a
        // square -- affine maps always send parallelograms to parallelograms.
        // Getting every corner right therefore proves h20/h21 (the
        // perspective terms) were actually solved, not just the affine part.
        const src = [
          Offset(0, 0),
          Offset(100, 0),
          Offset(100, 100),
          Offset(0, 100),
        ];
        const dst = [
          Offset(0, 0),
          Offset(100, 0),
          Offset(80, 100),
          Offset(20, 100),
        ];

        final h = Homography.fromQuad(src, dst);

        for (var i = 0; i < 4; i++) {
          final result = h.warp(src[i]);
          expect(result.dx, closeTo(dst[i].dx, 1e-6), reason: 'corner $i dx');
          expect(result.dy, closeTo(dst[i].dy, 1e-6), reason: 'corner $i dy');
        }
      },
    );

    test('B4: degenerate collinear src returns identity, no NaN/Infinity', () {
      const src = [
        Offset(0, 0),
        Offset(1, 1),
        Offset(2, 2),
        Offset(3, 3),
      ];
      const dst = [
        Offset(0, 0),
        Offset(100, 0),
        Offset(100, 100),
        Offset(0, 100),
      ];

      final h = Homography.fromQuad(src, dst);
      expect(h, equals(Homography.identity()));

      final result = h.warp(const Offset(5, 5));
      expect(result.dx.isFinite, isTrue);
      expect(result.dy.isFinite, isTrue);
      expect(result.dx, closeTo(5, 1e-9));
      expect(result.dy, closeTo(5, 1e-9));
    });

    test(
      'A1(i): Hartley-normalized DLT round-trips a KNOWN strong-perspective '
      'homography on a realistic large-photo-pixel src / screen-pixel dst '
      'scale mismatch, within a tight tolerance -- both at the 4 defining '
      'corners AND at an interior point never given to fromQuad, proving '
      'the WHOLE matrix (not just the 4 trivially-satisfied constraints) '
      'was recovered correctly',
      () {
        // src mimics a real reference-photo pixel rect (iPhone-photo-sized:
        // thousands of px) -- the exact "photo-pixel coordinates (hundreds
        // -thousands)" scale this whole defect is about.
        const src = [
          Offset(0, 0),
          Offset(3024, 0),
          Offset(3024, 4032),
          Offset(0, 4032),
        ];

        // A genuine (non-affine) projective transform: modest rotation/
        // scale/translation PLUS non-zero perspective terms (h20/h21),
        // chosen so applying it to photo-pixel-scale src coordinates lands
        // in a plausible on-screen pixel range -- reproducing the exact
        // scale-mismatch this defect describes.
        final trueHomography = Homography.fromRowMajor(const [
          0.18, 0.04, 60, //
          -0.03, 0.16, 90, //
          0.00004, 0.00015, 1, //
        ]);

        final dst = [for (final p in src) trueHomography.warp(p)];

        final solved = Homography.fromQuad(src, dst);

        for (var i = 0; i < 4; i++) {
          final result = solved.warp(src[i]);
          expect(
            result.dx,
            closeTo(dst[i].dx, 1e-3),
            reason: 'corner $i dx',
          );
          expect(
            result.dy,
            closeTo(dst[i].dy, 1e-3),
            reason: 'corner $i dy',
          );
        }

        // An interior point NOT among the 4 correspondences given to
        // fromQuad -- only correct if the full matrix (incl. the
        // perspective terms) was recovered, not merely a fit that happens
        // to satisfy the 4 corners.
        const interior = Offset(1500, 2200);
        final expected = trueHomography.warp(interior);
        final actual = solved.warp(interior);
        expect(actual.dx, closeTo(expected.dx, 1e-3));
        expect(actual.dy, closeTo(expected.dy, 1e-3));
      },
    );

    test(
      'A1(ii): a near-collinear dst quad combined with a large-photo-pixel '
      'src (the exact scale-mismatch that made the un-normalized DLT '
      'ill-conditioned) still returns a finite, bounded homography -- no '
      'NaN/Infinity anywhere, including when warping points well outside '
      'the 4 given correspondences',
      () {
        const src = [
          Offset(0, 0),
          Offset(3024, 0),
          Offset(3024, 4032),
          Offset(0, 4032),
        ];
        // Near-collinear (not exactly): all 4 points sit almost exactly on
        // the line y=400, with only a sub-pixel perpendicular perturbation
        // -- a sliver quad that is NOT exactly singular (so the internal
        // `_solve8x8` epsilon-pivot check alone would not catch it), which
        // is precisely the "wild-but-non-singular solve" failure mode.
        const dst = [
          Offset(50, 400.0),
          Offset(250, 400.02),
          Offset(450, 399.97),
          Offset(650, 400.01),
        ];

        final solved = Homography.fromQuad(src, dst);

        for (final v in solved.m) {
          expect(v.isFinite, isTrue, reason: 'matrix entry $v must be finite');
          expect(
            v.abs(),
            lessThan(1e12),
            reason: 'matrix entry $v must be boundedly finite',
          );
        }

        // Warp a handful of points spanning (and slightly outside) the src
        // rect, incl. ones never given to fromQuad -- every result must
        // still be finite/bounded, never NaN/Infinity.
        for (final p in const [
          Offset(0, 0),
          Offset(3024, 4032),
          Offset(1512, 2016),
          Offset(-500, -500),
          Offset(4000, 5000),
        ]) {
          final result = solved.warp(p);
          expect(result.dx.isFinite, isTrue);
          expect(result.dy.isFinite, isTrue);
          expect(result.dx.abs(), lessThan(1e12));
          expect(result.dy.abs(), lessThan(1e12));
        }
      },
    );
  });

  group('Homography.isDegenerateQuadSolve', () {
    const src = [
      Offset(0, 0),
      Offset(1000, 0),
      Offset(1000, 2000),
      Offset(0, 2000),
    ];
    const goodDst = [
      Offset(50, 50),
      Offset(350, 50),
      Offset(350, 750),
      Offset(50, 750),
    ];
    // Exactly collinear -- fromQuad's internal singular-system check
    // catches this and returns identity() directly.
    const collinearDst = [
      Offset(50, 50),
      Offset(150, 50),
      Offset(250, 50),
      Offset(350, 50),
    ];
    // A sliver quad: real (tiny) perpendicular deviation from the line
    // y=50, so it is NOT exactly singular -- fromQuad returns some
    // finite, non-identity matrix for this (thanks to A1's normalization),
    // yet the quad itself is still not a trustworthy tracked corner set.
    // This is exactly the "wild-but-non-singular solve" defect #2 (A2)
    // describes: passes the old `solved == identity()` check, but must be
    // caught by the new geometric validity test.
    const sliverDst = [
      Offset(50, 50.0),
      Offset(150, 50.2),
      Offset(250, 49.85),
      Offset(350, 50.1),
    ];

    test('A2: a well-conditioned solve is NOT flagged degenerate', () {
      final solved = Homography.fromQuad(src, goodDst);
      expect(
        Homography.isDegenerateQuadSolve(solved, src, goodDst),
        isFalse,
      );
    });

    test(
      'A2: fromQuad\'s own identity sentinel (exactly-singular collinear '
      'dst) IS flagged degenerate',
      () {
        final solved = Homography.fromQuad(src, collinearDst);
        expect(solved, equals(Homography.identity()));
        expect(
          Homography.isDegenerateQuadSolve(solved, src, collinearDst),
          isTrue,
        );
      },
    );

    test(
      'A2: a wild-but-technically-non-singular sliver solve is NOT '
      'identity, yet IS flagged degenerate -- proving the new check '
      'catches what exact identity-equality alone would miss',
      () {
        final solved = Homography.fromQuad(src, sliverDst);
        expect(
          solved,
          isNot(equals(Homography.identity())),
          reason:
              'the old exact-equality check would have let this solve '
              'through uncaught',
        );
        expect(
          Homography.isDegenerateQuadSolve(solved, src, sliverDst),
          isTrue,
        );
      },
    );

    test('A2: any non-finite matrix entry is flagged degenerate', () {
      final bogus = Homography.fromRowMajor(const [
        double.nan, 0, 0, //
        0, 1, 0, //
        0, 0, 1, //
      ]);
      expect(
        Homography.isDegenerateQuadSolve(bogus, src, goodDst),
        isTrue,
      );
    });

    // --- HIGH-severity fix: convexity/consistent-winding check -------------
    //
    // The old check set's 4th check ("residual": warp(src[i]) ≈ dst[i]
    // within a span-proportional tolerance) was a TAUTOLOGY --
    // Homography.fromQuad solves the 8-DOF system EXACTLY through the 4
    // given correspondences, so warp(src[i]) == dst[i] always holds for any
    // successful solve, regardless of whether the correspondences describe a
    // geometrically sane transform. It caught nothing the non-finite check
    // didn't already catch. Meanwhile a CONCAVE (reflex-vertex) or bowtie
    // (self-intersecting) dst quad passed every one of the old checks --
    // real central projections of a planar rectangle are ALWAYS convex, so
    // either shape is an unambiguous tracking-glitch signature. F1-F3 below
    // discriminate the fix: they fail against the pre-fix check set (F1/F2
    // wrongly return false; F3 must keep returning false post-fix, i.e. the
    // fix must not over-reject genuinely convex, steeply-foreshortened
    // quads).
    group('convexity / consistent-winding (HIGH fix)', () {
      const foreshortenSrc = [
        Offset(0, 0),
        Offset(1000, 0),
        Offset(1000, 1500),
        Offset(0, 1500),
      ];

      test(
        'F1: a concave dst quad (one corner glitched inward into a reflex '
        'vertex) IS flagged degenerate -- pre-fix this returned FALSE '
        '(accepted): fromQuad solves through the 4 points exactly (the old '
        'residual check is a tautology), the span/area checks don\'t catch '
        'it either, so a real tracking glitch like this rendered at full '
        'confidence and poisoned _lastGoodHomography',
        () {
          const src = foreshortenSrc;
          // TL, TR, BR (glitched inward), BL -- see this file's module doc
          // for the exact worked example (warp(Offset(0,750)) lands 200px
          // above the whole quad under the pre-fix check set).
          const concaveDst = [
            Offset(100, 100),
            Offset(300, 100),
            Offset(150, 150),
            Offset(100, 300),
          ];

          final solved = Homography.fromQuad(src, concaveDst);
          // Confirm this is a genuine non-identity, finite solve (not caught
          // by fromQuad's own singular-system sentinel) -- otherwise F1
          // would trivially pass via the non-finite/identity path rather
          // than exercising the convexity check this test targets.
          expect(solved, isNot(equals(Homography.identity())));
          for (final v in solved.m) {
            expect(v.isFinite, isTrue);
          }

          expect(
            Homography.isDegenerateQuadSolve(solved, src, concaveDst),
            isTrue,
            reason:
                'a concave (reflex-vertex) dst quad must be rejected -- a '
                'real planar-rectangle projection is always convex',
          );
        },
      );

      test(
        'F2: a bowtie (self-intersecting) dst quad -- adjacent corners '
        'swapped -- IS flagged degenerate',
        () {
          const src = foreshortenSrc;
          // An asymmetric convex quad with TR and BR swapped: connecting
          // TL->BR'->TR'->BL now crosses itself in the middle (the
          // TL-BR' and TR'-BL edges intersect), the textbook "bowtie" quad
          // shape. Deliberately asymmetric (unlike a simple rectangle swap)
          // so the shoelace-sum area is non-negligible relative to span^2 --
          // a symmetric swap can shoelace-cancel to exactly 0 and get caught
          // by the pre-existing area/span check alone, which would NOT
          // discriminate this fix.
          const bowtieDst = [
            Offset(50, 50), // TL
            Offset(280, 700), // was BR
            Offset(300, 60), // was TR
            Offset(60, 680), // BL
          ];

          final solved = Homography.fromQuad(src, bowtieDst);
          for (final v in solved.m) {
            expect(v.isFinite, isTrue);
          }

          expect(
            Homography.isDegenerateQuadSolve(solved, src, bowtieDst),
            isTrue,
            reason: 'a self-intersecting (bowtie) dst quad must be rejected',
          );
        },
      );

      test(
        'F3: genuinely CONVEX quads are NOT over-rejected -- a near-square '
        'and a strongly-foreshortened-but-convex trapezoid (short top edge, '
        'long bottom edge, simulating an oblique ~80° view) both return '
        'FALSE',
        () {
          const src = foreshortenSrc;

          const nearSquareDst = [
            Offset(100, 100),
            Offset(400, 100),
            Offset(400, 400),
            Offset(100, 400),
          ];
          final solvedSquare = Homography.fromQuad(src, nearSquareDst);
          expect(
            Homography.isDegenerateQuadSolve(solvedSquare, src, nearSquareDst),
            isFalse,
            reason: 'a plain convex square must never be flagged degenerate',
          );

          // Steeply-foreshortened but still convex: the far (top) edge is
          // much shorter than the near (bottom) edge, exactly what a real
          // rectangle viewed at a steep oblique angle projects to -- still
          // convex (all 4 winding cross-products share the same sign).
          const trapezoidDst = [
            Offset(300, 100), // TL -- short top edge
            Offset(500, 100), // TR
            Offset(700, 600), // BR -- long bottom edge
            Offset(100, 600), // BL
          ];
          final solvedTrapezoid = Homography.fromQuad(src, trapezoidDst);
          expect(
            Homography.isDegenerateQuadSolve(
              solvedTrapezoid,
              src,
              trapezoidDst,
            ),
            isFalse,
            reason:
                'a steeply-foreshortened but still-convex trapezoid must '
                'not be over-rejected -- this is exactly what a real '
                'oblique-angle wall view looks like',
          );
        },
      );

      test(
        'F4: the pre-existing collinear / sliver / non-finite degenerate '
        'cases still return TRUE post-fix (regression guard: the '
        'convexity check must not have loosened these)',
        () {
          expect(
            Homography.isDegenerateQuadSolve(
              Homography.fromQuad(src, collinearDst),
              src,
              collinearDst,
            ),
            isTrue,
          );
          expect(
            Homography.isDegenerateQuadSolve(
              Homography.fromQuad(src, sliverDst),
              src,
              sliverDst,
            ),
            isTrue,
          );
          final bogus = Homography.fromRowMajor(const [
            double.nan, 0, 0, //
            0, 1, 0, //
            0, 0, 1, //
          ]);
          expect(
            Homography.isDegenerateQuadSolve(bogus, src, goodDst),
            isTrue,
          );
        },
      );

      test(
        'F5 (boundary-pinning): a genuinely convex, strongly-foreshortened '
        'quad whose area/span^2 ratio sits just above (not deep past) the '
        '1e-4 area gate is NOT over-rejected -- pins that the convexity/'
        'winding epsilon (1e-6, scaled by span^2) never becomes the binding '
        'constraint ahead of the area gate for a realistic steep view',
        () {
          const src = foreshortenSrc;
          // A thin, near-edge-on trapezoid: top edge flat (TL->TR at
          // y=500), bottom edge only slightly tilted (BL at y=500.7, BR at
          // y=500.9) -- exactly what a real planar rectangle viewed at a
          // razor-steep oblique angle projects to. All 4 winding
          // cross-products are comfortably large here (700-900, versus a
          // span^2*1e-6 threshold of ~1) -- there is no near-straight
          // vertex in this fixture; that invariant is isolated separately
          // in F6, so this test exercises only the area-gate boundary.
          const steepDst = [
            Offset(0, 500), // TL
            Offset(1000, 500), // TR
            Offset(1000, 500.9), // BR
            Offset(0, 500.7), // BL
          ];

          // area/span^2 = 800 / 1000^2 = 8e-4 -- comfortably (8x) above the
          // 1e-4 area gate, landing inside the requested ~5e-4..1e-3
          // boundary-pinning band. Asserted rather than trusted from hand
          // arithmetic alone.
          expect(
            _quadAreaOverSpanSquared(steepDst),
            closeTo(8e-4, 1e-6),
            reason: 'fixture must actually sit in the intended boundary band',
          );

          final solved = Homography.fromQuad(src, steepDst);
          for (final v in solved.m) {
            expect(v.isFinite, isTrue);
          }

          expect(
            Homography.isDegenerateQuadSolve(solved, src, steepDst),
            isFalse,
            reason:
                'a realistic steep view sitting just above the area gate '
                'must not be over-rejected -- pins that a valid steeply '
                'foreshortened quad stays accepted',
          );
        },
      );

      test(
        'F6 (winding-vs-area isolation): a convex quad with ONE '
        'near-straight (~178.6 degree) vertex is accepted even though its '
        'winding cross-product there is far smaller than its neighbors -- '
        'proving the 1e-6 winding epsilon is looser than the 1e-4 area gate '
        'and does not reject a genuinely convex near-straight corner',
        () {
          const src = foreshortenSrc;
          // TL, BR, and BL form a large, unambiguously convex triangle; TR
          // sits barely off the TL-BR line (offset by 6 in y against a
          // 1000-wide span), giving it an interior angle of ~178.6 degrees
          // -- convex (all 4 winding cross-products positive: 503000 at
          // TL, 6000 at TR, 503000 at BR, 1000000 at BL) but only just so
          // at TR. The overall shape is nowhere near degenerate: its own
          // area/span^2 (asserted below) clears the 1e-4 area gate by
          // ~5000x, so the area check is trivially satisfied and cannot be
          // what's discriminating here -- only the winding epsilon at TR
          // is actually exercised, isolating that invariant from F5's
          // area-boundary case.
          const nearStraightDst = [
            Offset(0, 0), // TL
            Offset(500, -6), // TR -- near-straight vs TL/BR
            Offset(1000, 0), // BR
            Offset(500, 1000), // BL
          ];

          expect(
            _quadAreaOverSpanSquared(nearStraightDst),
            greaterThan(1e-2),
            reason:
                'overall area/span^2 must clear the area gate by orders of '
                'magnitude, isolating the winding check as the only thing '
                'that could reject this quad',
          );

          final solved = Homography.fromQuad(src, nearStraightDst);
          for (final v in solved.m) {
            expect(v.isFinite, isTrue);
          }

          expect(
            Homography.isDegenerateQuadSolve(solved, src, nearStraightDst),
            isFalse,
            reason:
                'a near-straight-but-still-convex vertex must not be '
                'rejected -- the winding epsilon is deliberately looser '
                'than the area gate for exactly this reason',
          );
        },
      );
    });
  });

  test('sqrt sanity check for pure-dart math import availability', () {
    expect(sqrt(4), closeTo(2, 1e-9));
  });
}
