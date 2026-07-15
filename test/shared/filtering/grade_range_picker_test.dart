// Widget tests for GradeRangePicker (Subtask A2 of the filtering plan,
// ~/.claude/plans/masi-filtering.md): render + emit onChanged with the
// right GradeRange on interaction. No image decode / real canvas involved
// -- this is a plain controlled widget pumped directly under MaterialApp.

import 'package:climbtopo/app/theme.dart';
import 'package:climbtopo/core/grades/grade_system.dart';
import 'package:climbtopo/shared/filtering/grade_range.dart';
import 'package:climbtopo/shared/filtering/grade_range_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _buildPicker({
  required GradeRange value,
  required ValueChanged<GradeRange> onChanged,
}) {
  return MaterialApp(
    theme: MasiTheme.light,
    home: Scaffold(
      body: GradeRangePicker(value: value, onChanged: onChanged),
    ),
  );
}

/// Opens the dropdown at [dropdownKey], scrolls its popup menu as needed to
/// bring [token] into view, taps it, then settles.
///
/// DropdownButton's popup menu only mounts items near the currently
/// selected one (confirmed empirically: opening a fresh/null selection
/// mounts roughly the first ~10 ladder tokens; opening with a mid-ladder
/// token selected mounts roughly the 12 tokens surrounding it) -- so a
/// direct `tester.tap(find.text(token))` can throw "Bad state: No
/// element" for a token far from the current selection. [scrollOffset]'s
/// sign picks the scroll direction: negative dy reveals LATER (harder)
/// tokens, positive dy reveals EARLIER (easier) tokens/`Any`.
/// [WidgetTester.dragUntilVisible] is a no-op drag-wise if [token] is
/// already visible, so this is safe to use unconditionally.
Future<void> _selectGrade(
  WidgetTester tester, {
  required Key dropdownKey,
  required String token,
  required Offset scrollOffset,
}) async {
  await tester.tap(find.byKey(dropdownKey));
  await tester.pumpAndSettle();
  // NOTE: the finder passed to dragUntilVisible must NOT be `.last`-wrapped
  // -- dragUntilVisible evaluates it on every scroll step to check
  // visibility, and a `.last` finder throws ("Bad state: No element")
  // rather than evaluating empty when the target isn't mounted yet, which
  // breaks dragUntilVisible's own empty-check before it can scroll.
  final baseFinder = find.text(token);
  await tester.dragUntilVisible(baseFinder, find.byType(Scrollable).last, scrollOffset);
  // dragUntilVisible's internal Scrollable.ensureVisible() kicks off a
  // scroll-settling animation but doesn't itself pump frames to
  // completion -- without this, the item can still be mid-animation
  // (clipped at the viewport edge) and fail hit-testing on tap.
  await tester.pumpAndSettle();
  await tester.tap(baseFinder.last);
  await tester.pumpAndSettle();
}

void main() {
  group('GradeRangePicker', () {
    testWidgets('renders the grade-system toggle and both dropdown keys', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildPicker(value: const GradeRange(), onChanged: (_) {}),
      );
      await tester.pump();

      expect(find.byKey(const Key('filter-grade-system')), findsOneWidget);
      expect(find.byKey(const Key('filter-grade-min')), findsOneWidget);
      expect(find.byKey(const Key('filter-grade-max')), findsOneWidget);
    });

    testWidgets('grade-system toggle offers exactly French and UIAA', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildPicker(value: const GradeRange(), onChanged: (_) {}),
      );
      await tester.pump();

      final keys = tester.allWidgets
          .map((w) => w.key)
          .whereType<ValueKey<String>>()
          .map((k) => k.value)
          .where((v) => v.startsWith('filter-grade-system-'))
          .toSet();

      expect(keys, {'filter-grade-system-french', 'filter-grade-system-uiaa'});
    });

    testWidgets('switching grade system emits a GradeRange with reset bounds', (
      tester,
    ) async {
      GradeRange? emitted;
      await tester.pumpWidget(
        _buildPicker(
          value: const GradeRange(minToken: '6a', maxToken: '7a'),
          onChanged: (v) => emitted = v,
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key('filter-grade-system-uiaa')));
      await tester.pumpAndSettle();

      expect(emitted, isNotNull);
      expect(emitted!.system, GradeSystem.uiaa);
      expect(emitted!.minToken, isNull);
      expect(emitted!.maxToken, isNull);
    });

    testWidgets('tapping the same (already-selected) system does not fire onChanged', (
      tester,
    ) async {
      var callCount = 0;
      await tester.pumpWidget(
        _buildPicker(
          value: const GradeRange(),
          onChanged: (_) => callCount++,
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key('filter-grade-system-french')));
      await tester.pumpAndSettle();

      expect(callCount, 0);
    });

    testWidgets('picking a min grade emits a GradeRange with that minToken', (
      tester,
    ) async {
      GradeRange? emitted;
      await tester.pumpWidget(
        _buildPicker(value: const GradeRange(), onChanged: (v) => emitted = v),
      );
      await tester.pump();

      await _selectGrade(
        tester,
        dropdownKey: const Key('filter-grade-min'),
        token: '6a',
        scrollOffset: const Offset(0, -50),
      );

      expect(emitted, isNotNull);
      expect(emitted!.minToken, '6a');
      expect(emitted!.maxToken, isNull);
    });

    testWidgets('picking a max grade emits a GradeRange with that maxToken', (
      tester,
    ) async {
      GradeRange? emitted;
      await tester.pumpWidget(
        _buildPicker(value: const GradeRange(), onChanged: (v) => emitted = v),
      );
      await tester.pump();

      await _selectGrade(
        tester,
        dropdownKey: const Key('filter-grade-max'),
        token: '6a',
        scrollOffset: const Offset(0, -50),
      );

      expect(emitted, isNotNull);
      expect(emitted!.maxToken, '6a');
      expect(emitted!.minToken, isNull);
    });

    testWidgets(
      'picking a min grade harder than the current max bumps the max up to match',
      (tester) async {
        GradeRange? emitted;
        await tester.pumpWidget(
          _buildPicker(
            value: const GradeRange(minToken: '5a', maxToken: '6a'),
            onChanged: (v) => emitted = v,
          ),
        );
        await tester.pump();

        // '7a' is harder than the current max ('6a').
        await _selectGrade(
          tester,
          dropdownKey: const Key('filter-grade-min'),
          token: '7a',
          scrollOffset: const Offset(0, -50),
        );

        expect(emitted, isNotNull);
        expect(emitted!.minToken, '7a');
        expect(emitted!.maxToken, '7a');
      },
    );

    testWidgets(
      'picking a max grade easier than the current min bumps the min down to match',
      (tester) async {
        GradeRange? emitted;
        await tester.pumpWidget(
          _buildPicker(
            value: const GradeRange(minToken: '6a', maxToken: '7a'),
            onChanged: (v) => emitted = v,
          ),
        );
        await tester.pump();

        // '5a' is easier than the current min ('6a').
        await _selectGrade(
          tester,
          dropdownKey: const Key('filter-grade-max'),
          token: '5a',
          scrollOffset: const Offset(0, 50),
        );

        expect(emitted, isNotNull);
        expect(emitted!.maxToken, '5a');
        expect(emitted!.minToken, '5a');
      },
    );

    testWidgets('picking "Any" for min clears minToken', (tester) async {
      GradeRange? emitted;
      await tester.pumpWidget(
        _buildPicker(
          value: const GradeRange(minToken: '6a', maxToken: '7a'),
          onChanged: (v) => emitted = v,
        ),
      );
      await tester.pump();

      await _selectGrade(
        tester,
        dropdownKey: const Key('filter-grade-min'),
        token: 'Any',
        scrollOffset: const Offset(0, 50),
      );

      expect(emitted, isNotNull);
      expect(emitted!.minToken, isNull);
      expect(emitted!.maxToken, '7a');
    });
  });
}
