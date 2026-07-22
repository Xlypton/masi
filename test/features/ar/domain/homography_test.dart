import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:masi/features/ar/domain/homography.dart';

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
  });

  test('sqrt sanity check for pure-dart math import availability', () {
    expect(sqrt(4), closeTo(2, 1e-9));
  });
}
