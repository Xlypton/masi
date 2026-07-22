// Widget tests for StyleFilterChips (Subtask A2 of the filtering plan,
// ~/.claude/plans/masi-filtering.md): render + emit onChanged with the
// right Set<String> on interaction.

import 'package:masi/app/theme.dart';
import 'package:masi/shared/filtering/style_filter_chips.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _buildChips({
  required Set<String> selected,
  required ValueChanged<Set<String>> onChanged,
}) {
  return MaterialApp(
    theme: MasiTheme.light,
    home: Scaffold(
      body: StyleFilterChips(selected: selected, onChanged: onChanged),
    ),
  );
}

void main() {
  group('StyleFilterChips', () {
    testWidgets('renders exactly the sport/trad/boulder chip keys', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildChips(selected: const {}, onChanged: (_) {}),
      );
      await tester.pump();

      expect(find.byKey(const Key('filter-style-sport')), findsOneWidget);
      expect(find.byKey(const Key('filter-style-trad')), findsOneWidget);
      expect(find.byKey(const Key('filter-style-boulder')), findsOneWidget);
    });

    testWidgets('tapping an unselected chip emits it added to the set', (
      tester,
    ) async {
      Set<String>? emitted;
      await tester.pumpWidget(
        _buildChips(selected: const {}, onChanged: (v) => emitted = v),
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key('filter-style-trad')));
      await tester.pump();

      expect(emitted, {'trad'});
    });

    testWidgets('tapping an already-selected chip emits it removed from the set', (
      tester,
    ) async {
      Set<String>? emitted;
      await tester.pumpWidget(
        _buildChips(
          selected: const {'sport', 'trad'},
          onChanged: (v) => emitted = v,
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key('filter-style-sport')));
      await tester.pump();

      expect(emitted, {'trad'});
    });

    testWidgets('selecting one chip does not disturb the others already selected', (
      tester,
    ) async {
      Set<String>? emitted;
      await tester.pumpWidget(
        _buildChips(
          selected: const {'boulder'},
          onChanged: (v) => emitted = v,
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key('filter-style-sport')));
      await tester.pump();

      expect(emitted, {'boulder', 'sport'});
    });
  });
}
