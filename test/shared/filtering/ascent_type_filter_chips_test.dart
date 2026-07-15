// Widget tests for AscentTypeFilterChips (Subtask A2 of the filtering plan,
// ~/.claude/plans/masi-filtering.md): render + emit onChanged with the
// right Set<AscentStyle> on interaction.

import 'package:climbtopo/app/theme.dart';
import 'package:climbtopo/features/logbook/data/ascents_repository.dart';
import 'package:climbtopo/shared/filtering/ascent_type_filter_chips.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _buildChips({
  required Set<AscentStyle> selected,
  required ValueChanged<Set<AscentStyle>> onChanged,
}) {
  return MaterialApp(
    theme: MasiTheme.light,
    home: Scaffold(
      body: AscentTypeFilterChips(selected: selected, onChanged: onChanged),
    ),
  );
}

void main() {
  group('AscentTypeFilterChips', () {
    testWidgets('renders a chip key for every AscentStyle value', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildChips(selected: const {}, onChanged: (_) {}),
      );
      await tester.pump();

      for (final style in AscentStyle.values) {
        expect(
          find.byKey(Key('filter-ascent-${style.name}')),
          findsOneWidget,
          reason: 'missing chip for $style',
        );
      }
    });

    testWidgets('labels are the capitalized enum name', (tester) async {
      await tester.pumpWidget(
        _buildChips(selected: const {}, onChanged: (_) {}),
      );
      await tester.pump();

      expect(find.text('Onsight'), findsOneWidget);
      expect(find.text('Flash'), findsOneWidget);
      expect(find.text('Redpoint'), findsOneWidget);
      expect(find.text('Repeat'), findsOneWidget);
      expect(find.text('Attempt'), findsOneWidget);
    });

    testWidgets('tapping an unselected chip emits it added to the set', (
      tester,
    ) async {
      Set<AscentStyle>? emitted;
      await tester.pumpWidget(
        _buildChips(selected: const {}, onChanged: (v) => emitted = v),
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key('filter-ascent-flash')));
      await tester.pump();

      expect(emitted, {AscentStyle.flash});
    });

    testWidgets('tapping an already-selected chip emits it removed from the set', (
      tester,
    ) async {
      Set<AscentStyle>? emitted;
      await tester.pumpWidget(
        _buildChips(
          selected: const {AscentStyle.onsight, AscentStyle.redpoint},
          onChanged: (v) => emitted = v,
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key('filter-ascent-onsight')));
      await tester.pump();

      expect(emitted, {AscentStyle.redpoint});
    });
  });
}
