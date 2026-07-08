import 'package:flutter_test/flutter_test.dart';

import 'package:climbtopo/core/grades/grade_system.dart';

// Contract under test (see lib/core/grades/grade_system.dart doc comment
// for the full derivation of the shared scale, anchors, and thresholds):
//
// A1: within EACH system, the ladder in order yields strictly increasing
//     gradeSortKey values (no duplicates).
// A2: cross-system anchors: french '6a' ~= uiaa 'VI+'; french '8a' >
//     uiaa 'V'; uiaa 'XI' > french '4a'.
// A3: isValidGrade true for every ladder token in both systems; false for
//     invalid tokens; case-normalization is honored.
// A4: bandForSortKey at the documented boundaries.
// A5: gradeOptions non-empty & ascending, matching the documented ladder
//     length.
// A6: no material.dart/widgets.dart import (structural, checked by not
//     importing it below + `flutter analyze`).

const List<String> kFrenchLadder = [
  '3',
  '4a', '4b', '4c',
  '5a', '5b', '5c',
  '6a', '6a+', '6b', '6b+', '6c', '6c+',
  '7a', '7a+', '7b', '7b+', '7c', '7c+',
  '8a', '8a+', '8b', '8b+', '8c', '8c+',
  '9a', '9a+', '9b', '9b+', '9c',
];

const List<String> kUiaaLadder = [
  'III',
  'IV-', 'IV', 'IV+',
  'V-', 'V', 'V+',
  'VI-', 'VI', 'VI+',
  'VII-', 'VII', 'VII+',
  'VIII-', 'VIII', 'VIII+',
  'IX-', 'IX', 'IX+',
  'X-', 'X', 'X+',
  'XI-', 'XI', 'XI+',
];

void main() {
  group('A1: ladder ordering yields strictly increasing sortKey', () {
    test('French ladder sort keys are strictly increasing, no dupes', () {
      final keys =
          kFrenchLadder.map((g) => gradeSortKey(GradeSystem.french, g)).toList();
      final sorted = [...keys]..sort();
      expect(keys, equals(sorted));
      expect(keys.toSet().length, keys.length);
      for (var i = 1; i < keys.length; i++) {
        expect(keys[i], greaterThan(keys[i - 1]));
      }
    });

    test('UIAA ladder sort keys are strictly increasing, no dupes', () {
      final keys =
          kUiaaLadder.map((g) => gradeSortKey(GradeSystem.uiaa, g)).toList();
      final sorted = [...keys]..sort();
      expect(keys, equals(sorted));
      expect(keys.toSet().length, keys.length);
      for (var i = 1; i < keys.length; i++) {
        expect(keys[i], greaterThan(keys[i - 1]));
      }
    });
  });

  group('A2: cross-system anchors are mutually comparable', () {
    test('french 6a is close to uiaa VI+ (documented anchor)', () {
      final frenchKey = gradeSortKey(GradeSystem.french, '6a');
      final uiaaKey = gradeSortKey(GradeSystem.uiaa, 'VI+');
      expect(frenchKey, closeTo(uiaaKey, 1e-9));
    });

    test('french 7a is close to uiaa VIII- (documented anchor)', () {
      final frenchKey = gradeSortKey(GradeSystem.french, '7a');
      final uiaaKey = gradeSortKey(GradeSystem.uiaa, 'VIII-');
      expect(frenchKey, closeTo(uiaaKey, 1e-9));
    });

    test('french 8a is clearly harder than uiaa V', () {
      expect(
        gradeSortKey(GradeSystem.french, '8a'),
        greaterThan(gradeSortKey(GradeSystem.uiaa, 'V')),
      );
    });

    test('uiaa XI is clearly harder than french 4a (vice-versa case)', () {
      expect(
        gradeSortKey(GradeSystem.uiaa, 'XI'),
        greaterThan(gradeSortKey(GradeSystem.french, '4a')),
      );
    });

    test('gradeSortKey throws ArgumentError for an invalid grade', () {
      expect(
        () => gradeSortKey(GradeSystem.french, 'banana'),
        throwsArgumentError,
      );
      expect(
        () => gradeSortKey(GradeSystem.uiaa, 'banana'),
        throwsArgumentError,
      );
    });
  });

  group('A3: isValidGrade + normalizeGrade', () {
    test('every French ladder token is valid', () {
      for (final g in kFrenchLadder) {
        expect(isValidGrade(GradeSystem.french, g), isTrue, reason: g);
      }
    });

    test('every UIAA ladder token is valid', () {
      for (final g in kUiaaLadder) {
        expect(isValidGrade(GradeSystem.uiaa, g), isTrue, reason: g);
      }
    });

    test('invalid tokens are rejected in both systems', () {
      for (final bad in ['banana', '', '6z', ' ']) {
        expect(isValidGrade(GradeSystem.french, bad), isFalse, reason: bad);
        expect(isValidGrade(GradeSystem.uiaa, bad), isFalse, reason: bad);
      }
    });

    test('French normalization lowercases letters: 6A -> 6a', () {
      expect(normalizeGrade(GradeSystem.french, '6A'), '6a');
      expect(isValidGrade(GradeSystem.french, '6A'), isTrue);
    });

    test('French normalization trims whitespace', () {
      expect(normalizeGrade(GradeSystem.french, ' 6a+ '), '6a+');
      expect(isValidGrade(GradeSystem.french, ' 6a+ '), isTrue);
    });

    test('UIAA normalization uppercases: vi+ -> VI+', () {
      expect(normalizeGrade(GradeSystem.uiaa, 'vi+'), 'VI+');
      expect(isValidGrade(GradeSystem.uiaa, 'vi+'), isTrue);
    });

    test('UIAA normalization trims whitespace', () {
      expect(normalizeGrade(GradeSystem.uiaa, ' viii- '), 'VIII-');
      expect(isValidGrade(GradeSystem.uiaa, ' viii- '), isTrue);
    });
  });

  group('A4: bandForSortKey boundaries (French-token derived)', () {
    // Beginner tops out at French '4c' (the spec's "French 4" tier
    // includes 4a/4b/4c since the ladder has no bare '4' token; see
    // grade_system.dart doc comment for this documented choice).
    test('french 4c -> beginner', () {
      expect(
        bandForSortKey(gradeSortKey(GradeSystem.french, '4c')),
        GradeBand.beginner,
      );
    });

    test('french 5c -> intermediate', () {
      expect(
        bandForSortKey(gradeSortKey(GradeSystem.french, '5c')),
        GradeBand.intermediate,
      );
    });

    test('french 6a -> intermediate', () {
      expect(
        bandForSortKey(gradeSortKey(GradeSystem.french, '6a')),
        GradeBand.intermediate,
      );
    });

    test('french 6a+ -> advanced', () {
      expect(
        bandForSortKey(gradeSortKey(GradeSystem.french, '6a+')),
        GradeBand.advanced,
      );
    });

    test('french 6c+ -> advanced', () {
      expect(
        bandForSortKey(gradeSortKey(GradeSystem.french, '6c+')),
        GradeBand.advanced,
      );
    });

    test('french 7a -> hard', () {
      expect(
        bandForSortKey(gradeSortKey(GradeSystem.french, '7a')),
        GradeBand.hard,
      );
    });

    test('french 7c+ -> hard', () {
      expect(
        bandForSortKey(gradeSortKey(GradeSystem.french, '7c+')),
        GradeBand.hard,
      );
    });

    test('french 8a -> elite', () {
      expect(
        bandForSortKey(gradeSortKey(GradeSystem.french, '8a')),
        GradeBand.elite,
      );
    });

    test('french 9a -> elite', () {
      expect(
        bandForSortKey(gradeSortKey(GradeSystem.french, '9a')),
        GradeBand.elite,
      );
    });
  });

  group('A5: gradeOptions', () {
    test('French options are non-empty, ascending, match documented ladder',
        () {
      final options = gradeOptions(GradeSystem.french);
      expect(options, isNotEmpty);
      expect(options, equals(kFrenchLadder));
      final keys =
          options.map((g) => gradeSortKey(GradeSystem.french, g)).toList();
      expect(keys, equals([...keys]..sort()));
    });

    test('UIAA options are non-empty, ascending, match documented ladder',
        () {
      final options = gradeOptions(GradeSystem.uiaa);
      expect(options, isNotEmpty);
      expect(options, equals(kUiaaLadder));
      final keys =
          options.map((g) => gradeSortKey(GradeSystem.uiaa, g)).toList();
      expect(keys, equals([...keys]..sort()));
    });
  });
}
