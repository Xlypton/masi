import 'package:flutter_test/flutter_test.dart';
import 'package:climbtopo/features/topo/domain/slice_geometry.dart';

void main() {
  group('SliceSpec', () {
    test('equality, hashCode, toString', () {
      const a = SliceSpec(0.25, 0.5);
      const b = SliceSpec(0.25, 0.5);
      const c = SliceSpec(0.0, 0.5);

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
      expect(a.toString(), contains('0.25'));
      expect(a.toString(), contains('0.5'));
    });
  });

  group('slicesFromCuts', () {
    test('A1: no cuts -> single full-width slice', () {
      expect(slicesFromCuts([]), [const SliceSpec(0.0, 1.0)]);
    });

    test('A2: single cut at 0.5', () {
      expect(slicesFromCuts([0.5]), [
        const SliceSpec(0.0, 0.5),
        const SliceSpec(0.5, 0.5),
      ]);
    });

    test('A3: two cuts produce three slices summing to 1.0', () {
      final slices = slicesFromCuts([0.25, 0.75]);
      expect(slices, [
        const SliceSpec(0.0, 0.25),
        const SliceSpec(0.25, 0.5),
        const SliceSpec(0.75, 0.25),
      ]);
      final widthSum = slices.fold<double>(0.0, (sum, s) => sum + s.cropWidthPct);
      expect(widthSum, closeTo(1.0, 1e-9));
    });

    test('A4: unsorted, duplicate, and out-of-range cuts are cleaned', () {
      final slices = slicesFromCuts([0.75, 0.25, 0.25, 1.2, -0.1]);
      expect(slices, [
        const SliceSpec(0.0, 0.25),
        const SliceSpec(0.25, 0.5),
        const SliceSpec(0.75, 0.25),
      ]);
      for (final s in slices) {
        expect(s.cropWidthPct, greaterThan(kSliceEpsilon));
      }
      final widthSum = slices.fold<double>(0.0, (sum, s) => sum + s.cropWidthPct);
      expect(widthSum, closeTo(1.0, 1e-9));
    });

    test('A5: invariants hold for every produced slice', () {
      for (final cuts in [
        <double>[],
        [0.5],
        [0.25, 0.75],
        [0.75, 0.25, 0.25, 1.2, -0.1],
        [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9],
      ]) {
        final slices = slicesFromCuts(cuts);
        expect(slices, isNotEmpty);
        for (final s in slices) {
          expect(s.cropWidthPct, greaterThan(0.0));
          expect(s.cropXpct + s.cropWidthPct, lessThanOrEqualTo(1.0 + 1e-9));
        }
        expect(slices.first.cropXpct, equals(0.0));
        final last = slices.last;
        expect(last.cropXpct + last.cropWidthPct, closeTo(1.0, 1e-9));
      }
    });

    test('cuts within epsilon of each other are deduped', () {
      final slices = slicesFromCuts([0.5, 0.5 + kSliceEpsilon / 2]);
      expect(slices, [
        const SliceSpec(0.0, 0.5),
        const SliceSpec(0.5, 0.5),
      ]);
    });

    test('cuts at or beyond boundaries are dropped', () {
      expect(slicesFromCuts([0.0, 1.0, 2.0, -1.0]), [
        const SliceSpec(0.0, 1.0),
      ]);
    });

    test('B1: cut within epsilon of 0.0 is treated as non-interior', () {
      expect(slicesFromCuts([5e-7]), [const SliceSpec(0.0, 1.0)]);
    });

    test('B2: cut within epsilon of 1.0 is treated as non-interior', () {
      expect(slicesFromCuts([1 - 5e-7]), [const SliceSpec(0.0, 1.0)]);
    });

    test(
      'B3: near-boundary cuts dropped, interior cut kept',
      () {
        final slices = slicesFromCuts([
          kSliceEpsilon / 2,
          0.5,
          1 - kSliceEpsilon / 2,
        ]);
        expect(slices, [
          const SliceSpec(0.0, 0.5),
          const SliceSpec(0.5, 0.5),
        ]);
      },
    );

    test('B4: coverage invariants hold with near-boundary cuts', () {
      for (final cuts in [
        [5e-7],
        [1 - 5e-7],
        [kSliceEpsilon / 2, 0.5, 1 - kSliceEpsilon / 2],
        [kSliceEpsilon / 2, 1 - kSliceEpsilon / 2],
        [0.3, kSliceEpsilon / 3, 1 - kSliceEpsilon / 3, 0.6],
      ]) {
        final slices = slicesFromCuts(cuts);
        expect(slices, isNotEmpty);
        expect(slices.first.cropXpct, equals(0.0));
        final last = slices.last;
        expect(last.cropXpct + last.cropWidthPct, closeTo(1.0, 1e-9));
        final widthSum = slices.fold<double>(
          0.0,
          (sum, s) => sum + s.cropWidthPct,
        );
        expect(widthSum, closeTo(1.0, 1e-9));
      }
    });
  });
}
