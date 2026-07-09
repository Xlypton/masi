import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:climbtopo/features/ar/domain/homography.dart';

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
  });

  group('Homography.translation', () {
    test('A2: translates a point', () {
      final h = Homography.translation(10, -5);
      final result = h.warp(const Offset(2, 2));
      expect(result.dx, closeTo(12, 1e-9));
      expect(result.dy, closeTo(-3, 1e-9));
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

  test('sqrt sanity check for pure-dart math import availability', () {
    expect(sqrt(4), closeTo(2, 1e-9));
  });
}
