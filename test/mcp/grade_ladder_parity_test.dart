import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:masi/core/grades/grade_system.dart';

/// Guards the one duplicated piece of domain logic in this repo.
///
/// `mcp-server/src/grades.ts` mirrors the grade ladders so the MCP server's
/// `update_route` can write a `gradeSortKey`. That key is what every
/// difficulty sort, filter and grade band reads, and a wrong one is invisible
/// on screen — the grade still displays correctly — so a silent divergence
/// would corrupt sorting everywhere with nothing to reveal it.
///
/// This test is the thing that makes the duplication safe: change the Dart
/// ladder without changing the TypeScript one and it goes red here, in the
/// suite that actually runs on every commit.
void main() {
  final file = File('mcp-server/src/grades.ts');

  late String source;

  setUpAll(() {
    expect(
      file.existsSync(),
      isTrue,
      reason: 'mcp-server/src/grades.ts is missing. If the MCP server was '
          'removed, delete this test too; otherwise the ladders are now '
          'unguarded.',
    );
    source = file.readAsStringSync();
  });

  /// Pulls the string entries out of `export const <name>: string[] = [ ... ];`
  List<String> tsArray(String name) {
    final match = RegExp(
      'export const $name: string\\[\\] = \\[(.*?)\\];',
      dotAll: true,
    ).firstMatch(source);
    expect(match, isNotNull, reason: 'could not find $name in grades.ts');
    return RegExp('"([^"]*)"')
        .allMatches(match!.group(1)!)
        .map((m) => m.group(1)!)
        .toList();
  }

  int tsConst(String name) {
    final match =
        RegExp('export const $name = (-?\\d+);').firstMatch(source);
    expect(match, isNotNull, reason: 'could not find $name in grades.ts');
    return int.parse(match!.group(1)!);
  }

  test('the French ladder matches, entry for entry and in order', () {
    expect(tsArray('FRENCH_LADDER'), gradeOptions(GradeSystem.french));
  });

  test('the UIAA ladder matches, entry for entry and in order', () {
    expect(tsArray('UIAA_LADDER'), gradeOptions(GradeSystem.uiaa));
  });

  test('the UIAA-to-shared-scale anchors match', () {
    // Order matters as much as membership: these four indices define the
    // slope, so an off-by-one silently skews every UIAA sort key.
    expect(tsConst('ANCHOR_FRENCH_LOW'), 7,
        reason: "must be the index of '6a' in the French ladder");
    expect(gradeOptions(GradeSystem.french)[7], '6a');

    expect(tsConst('ANCHOR_UIAA_LOW'), 9,
        reason: "must be the index of 'VI+' in the UIAA ladder");
    expect(gradeOptions(GradeSystem.uiaa)[9], 'VI+');

    expect(tsConst('ANCHOR_FRENCH_HIGH'), 13,
        reason: "must be the index of '7a' in the French ladder");
    expect(gradeOptions(GradeSystem.french)[13], '7a');

    expect(tsConst('ANCHOR_UIAA_HIGH'), 13,
        reason: "must be the index of 'VIII-' in the UIAA ladder");
    expect(gradeOptions(GradeSystem.uiaa)[13], 'VIII-');
  });

  test('every French grade would get the same sort key from either side', () {
    // The TypeScript computes `index` for French, so reproducing that here is
    // the whole contract: if Dart ever stops returning the bare index, the
    // duplicate silently disagrees and this catches it.
    final ladder = gradeOptions(GradeSystem.french);
    for (var i = 0; i < ladder.length; i++) {
      expect(
        gradeSortKey(GradeSystem.french, ladder[i]),
        i.toDouble(),
        reason: '${ladder[i]} should sort at its ladder index',
      );
    }
  });

  test('every UIAA grade would get the same sort key from either side', () {
    final ladder = gradeOptions(GradeSystem.uiaa);
    final slope = (tsConst('ANCHOR_FRENCH_HIGH') - tsConst('ANCHOR_FRENCH_LOW')) /
        (tsConst('ANCHOR_UIAA_HIGH') - tsConst('ANCHOR_UIAA_LOW'));

    for (var i = 0; i < ladder.length; i++) {
      final fromTs =
          tsConst('ANCHOR_FRENCH_LOW') + slope * (i - tsConst('ANCHOR_UIAA_LOW'));
      expect(
        gradeSortKey(GradeSystem.uiaa, ladder[i]),
        closeTo(fromTs, 1e-9),
        reason: '${ladder[i]} disagrees between Dart and grades.ts',
      );
    }
  });

  test('normalization agrees on case and whitespace', () {
    // grades.ts lowercases French and uppercases UIAA. If Dart ever changes
    // that, a grade the app accepts would stop resolving on the server.
    expect(source, contains('toLowerCase()'));
    expect(source, contains('toUpperCase()'));
    expect(normalizeGrade(GradeSystem.french, ' 6A+ '), '6a+');
    expect(normalizeGrade(GradeSystem.uiaa, ' viii- '), 'VIII-');
  });
}
