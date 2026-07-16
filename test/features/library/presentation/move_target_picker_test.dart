import 'package:climbtopo/app/theme.dart';
import 'package:climbtopo/features/library/presentation/move_target_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Wraps a trigger button that opens [showMoveTargetPicker] on tap, keyed
/// 'open', and records the returned selection into [onResult].
Widget _harness({
  required List<MoveTargetOption> options,
  required void Function(String? result) onResult,
  String emptyMessage = 'No candidates',
}) {
  return MaterialApp(
    theme: MasiTheme.light,
    home: Scaffold(
      body: Builder(
        builder: (context) => ElevatedButton(
          key: const Key('open'),
          onPressed: () async {
            final result = await showMoveTargetPicker(
              context,
              title: 'Move to…',
              options: options,
              keyPrefix: 'move-target-test',
              emptyMessage: emptyMessage,
            );
            onResult(result);
          },
          child: const Text('Open'),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
    'renders one tappable row per option, keyed <keyPrefix>-<id>; tapping '
    'one resolves showMoveTargetPicker with that id and dismisses the sheet',
    (tester) async {
      String? result;
      await tester.pumpWidget(
        _harness(
          options: const [
            MoveTargetOption(id: 'a', label: 'Area A › Sector A'),
            MoveTargetOption(id: 'b', label: 'Area B › Sector B'),
          ],
          onResult: (r) => result = r,
        ),
      );

      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();

      expect(find.text('Area A › Sector A'), findsOneWidget);
      expect(find.text('Area B › Sector B'), findsOneWidget);
      expect(find.byKey(const Key('move-target-test-a')), findsOneWidget);
      expect(find.byKey(const Key('move-target-test-b')), findsOneWidget);

      await tester.tap(find.byKey(const Key('move-target-test-b')));
      await tester.pumpAndSettle();

      expect(result, 'b');
      expect(find.byKey(const Key('move-target-test-b')), findsNothing);
    },
  );

  testWidgets(
    'an empty options list shows emptyMessage instead of any row',
    (tester) async {
      String? result = 'unset';
      await tester.pumpWidget(
        _harness(
          options: const [],
          emptyMessage: 'No other sectors available',
          onResult: (r) => result = r,
        ),
      );

      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();

      expect(find.text('No other sectors available'), findsOneWidget);
      expect(find.byType(ListView), findsNothing);
      expect(result, 'unset');
    },
  );

  testWidgets(
    'dismissing without a selection (tap outside) resolves to null',
    (tester) async {
      String? result = 'unset';
      await tester.pumpWidget(
        _harness(
          options: const [MoveTargetOption(id: 'a', label: 'Only Option')],
          onResult: (r) => result = r,
        ),
      );

      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();

      // Tap the barrier above the sheet to dismiss without selecting.
      await tester.tapAt(const Offset(200, 50));
      await tester.pumpAndSettle();

      expect(result, isNull);
    },
  );
}
