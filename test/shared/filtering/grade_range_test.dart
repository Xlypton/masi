// Unit tests for GradeRange (Subtask A1 of the filtering plan,
// ~/.claude/plans/masi-filtering.md). Pure logic, no widget harness needed.
//
// Covers: matchesSortKey in-range/out-of-range with inclusive boundaries on
// both ends, the "no bounds -> matches everything (including null)" case,
// the "null key excluded only when active" case, min>max normalization, and
// value equality/copyWith.

import 'package:masi/core/grades/grade_system.dart';
import 'package:masi/shared/filtering/grade_range.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('GradeRange.isActive', () {
    test('false when neither bound is set', () {
      const range = GradeRange();
      expect(range.isActive, isFalse);
    });

    test('true when only minToken is set', () {
      const range = GradeRange(minToken: '6a');
      expect(range.isActive, isTrue);
    });

    test('true when only maxToken is set', () {
      const range = GradeRange(maxToken: '7a');
      expect(range.isActive, isTrue);
    });
  });

  group('GradeRange.minKey / maxKey', () {
    test('null when the corresponding token is unset', () {
      const range = GradeRange();
      expect(range.minKey, isNull);
      expect(range.maxKey, isNull);
    });

    test('computed via gradeSortKey for the range system', () {
      const range = GradeRange(minToken: '6a', maxToken: '7a');
      expect(range.minKey, gradeSortKey(GradeSystem.french, '6a'));
      expect(range.maxKey, gradeSortKey(GradeSystem.french, '7a'));
    });

    test('uses the UIAA ladder when system is uiaa', () {
      const range = GradeRange(system: GradeSystem.uiaa, minToken: 'VI');
      expect(range.minKey, gradeSortKey(GradeSystem.uiaa, 'VI'));
    });
  });

  group('GradeRange.matchesSortKey — no bounds', () {
    test('matches every key when inactive', () {
      const range = GradeRange();
      expect(range.matchesSortKey(0), isTrue);
      expect(range.matchesSortKey(29), isTrue);
      expect(range.matchesSortKey(-100), isTrue);
    });

    test('matches a null key too, when inactive', () {
      const range = GradeRange();
      expect(range.matchesSortKey(null), isTrue);
    });
  });

  group('GradeRange.matchesSortKey — null key handling', () {
    test('an active filter excludes a null key', () {
      const range = GradeRange(minToken: '6a');
      expect(range.matchesSortKey(null), isFalse);
    });

    test('an inactive filter still matches a null key', () {
      const range = GradeRange();
      expect(range.matchesSortKey(null), isTrue);
    });
  });

  group('GradeRange.matchesSortKey — min-only bound', () {
    final minKey = gradeSortKey(GradeSystem.french, '6a');
    const range = GradeRange(minToken: '6a');

    test('matches exactly at the min boundary (inclusive)', () {
      expect(range.matchesSortKey(minKey), isTrue);
    });

    test('matches above the min boundary', () {
      expect(range.matchesSortKey(minKey + 5), isTrue);
    });

    test('excludes just below the min boundary', () {
      expect(range.matchesSortKey(minKey - 0.001), isFalse);
    });
  });

  group('GradeRange.matchesSortKey — max-only bound', () {
    final maxKey = gradeSortKey(GradeSystem.french, '7a');
    const range = GradeRange(maxToken: '7a');

    test('matches exactly at the max boundary (inclusive)', () {
      expect(range.matchesSortKey(maxKey), isTrue);
    });

    test('matches below the max boundary', () {
      expect(range.matchesSortKey(maxKey - 5), isTrue);
    });

    test('excludes just above the max boundary', () {
      expect(range.matchesSortKey(maxKey + 0.001), isFalse);
    });
  });

  group('GradeRange.matchesSortKey — min and max bound', () {
    final minKey = gradeSortKey(GradeSystem.french, '6a');
    final maxKey = gradeSortKey(GradeSystem.french, '7a');
    const range = GradeRange(minToken: '6a', maxToken: '7a');

    test('matches exactly at the min boundary (inclusive)', () {
      expect(range.matchesSortKey(minKey), isTrue);
    });

    test('matches exactly at the max boundary (inclusive)', () {
      expect(range.matchesSortKey(maxKey), isTrue);
    });

    test('matches strictly between the bounds', () {
      expect(range.matchesSortKey((minKey + maxKey) / 2), isTrue);
    });

    test('excludes just below the min boundary', () {
      expect(range.matchesSortKey(minKey - 0.001), isFalse);
    });

    test('excludes just above the max boundary', () {
      expect(range.matchesSortKey(maxKey + 0.001), isFalse);
    });
  });

  group('GradeRange min>max normalization', () {
    // minToken harder than maxToken -- an "inverted" range. Per the class
    // doc, this is treated as swapped (the smaller sort key is always the
    // effective lower bound), rather than rejecting everything.
    final low = gradeSortKey(GradeSystem.french, '6a');
    final high = gradeSortKey(GradeSystem.french, '7a');
    const inverted = GradeRange(minToken: '7a', maxToken: '6a');

    test('still matches the (swapped) effective lower boundary', () {
      expect(inverted.matchesSortKey(low), isTrue);
    });

    test('still matches the (swapped) effective upper boundary', () {
      expect(inverted.matchesSortKey(high), isTrue);
    });

    test('still matches strictly between the effective bounds', () {
      expect(inverted.matchesSortKey((low + high) / 2), isTrue);
    });

    test('still excludes just below the effective lower boundary', () {
      expect(inverted.matchesSortKey(low - 0.001), isFalse);
    });

    test('still excludes just above the effective upper boundary', () {
      expect(inverted.matchesSortKey(high + 0.001), isFalse);
    });

    test('minKey/maxKey still expose the raw (unswapped) tokens', () {
      expect(inverted.minKey, high);
      expect(inverted.maxKey, low);
    });
  });

  group('GradeRange equality', () {
    test('equal when system/minToken/maxToken all match', () {
      const a = GradeRange(minToken: '6a', maxToken: '7a');
      const b = GradeRange(minToken: '6a', maxToken: '7a');
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('not equal when a token differs', () {
      const a = GradeRange(minToken: '6a', maxToken: '7a');
      const b = GradeRange(minToken: '6a', maxToken: '7b');
      expect(a == b, isFalse);
    });

    test('not equal when system differs', () {
      const a = GradeRange();
      const b = GradeRange(system: GradeSystem.uiaa);
      expect(a == b, isFalse);
    });
  });

  group('GradeRange.copyWith', () {
    test('preserves fields not passed', () {
      const base = GradeRange(minToken: '6a', maxToken: '7a');
      final changed = base.copyWith(maxToken: '7c');
      expect(changed.minToken, '6a');
      expect(changed.maxToken, '7c');
      expect(changed.system, GradeSystem.french);
    });

    test('can explicitly clear a bound to null (distinct from omitting it)', () {
      const base = GradeRange(minToken: '6a', maxToken: '7a');
      final cleared = base.copyWith(minToken: null);
      expect(cleared.minToken, isNull);
      expect(cleared.maxToken, '7a');
    });

    test('can change the system', () {
      const base = GradeRange();
      final changed = base.copyWith(system: GradeSystem.uiaa);
      expect(changed.system, GradeSystem.uiaa);
    });
  });
}
