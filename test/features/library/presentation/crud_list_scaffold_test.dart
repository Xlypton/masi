import 'package:masi/app/theme.dart';
import 'package:masi/features/library/presentation/crud_list_scaffold.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Wraps [CrudListScaffold] with a single fake item ("Test Area") and the
/// app's real light theme — `MasiColors.of(context)` null-check-crashes
/// without a registered `MasiTheme`. `T` is plain `String` here since the
/// scaffold only ever calls [idOf]/[nameOf] on it.
Widget _harness({
  required Future<void> Function(String item) onDelete,
  Future<void> Function(BuildContext context, String item)? onMove,
  Future<void> Function(String item, String newName)? onRename,
}) {
  return MaterialApp(
    theme: MasiTheme.light,
    home: CrudListScaffold<String>(
      title: 'Areas',
      entityKey: 'area',
      asyncItems: const AsyncValue.data(['Test Area']),
      idOf: (item) => item,
      nameOf: (item) => item,
      emptyMessage: 'No areas yet',
      addDialogTitle: 'New Area',
      renameDialogTitle: 'Rename Area',
      onRetry: () {},
      onTap: (_) {},
      onCreate: (_) async {},
      onRename: onRename ?? (item, name) async {},
      onDelete: onDelete,
      onMove: onMove,
    ),
  );
}

Future<void> _openDeleteSheet(WidgetTester tester) async {
  await tester.pumpWidget(_harness(onDelete: (_) async {}));
  await tester.tap(find.byKey(const Key('area-delete-Test Area')));
  await tester.pumpAndSettle();
}

void main() {
  group('CrudListScaffold delete confirm sheet', () {
    testWidgets(
      'C-a: barrier is materially darker than the ~20% Cupertino default '
      '(>= 45% black), so the bottom-pinned accent button cannot bleed '
      'through the actions/cancel gap',
      (tester) async {
        await _openDeleteSheet(tester);

        final barrier = tester.widget<ModalBarrier>(
          find.byType(ModalBarrier).last,
        );
        expect(barrier.color, isNotNull);
        // Default kCupertinoModalBarrierColor (light) is 0x33000000, i.e.
        // alpha ~0.2 — assert materially higher than that.
        expect(barrier.color!.a, greaterThanOrEqualTo(0.45));
      },
    );

    testWidgets(
      'C-b: tapping the destructive confirm action calls onDelete for that '
      'item (and only after the confirm tap, never on the initial delete '
      'icon tap)',
      (tester) async {
        final deleted = <String>[];
        await tester.pumpWidget(
          _harness(
            onDelete: (item) async {
              deleted.add(item);
            },
          ),
        );

        await tester.tap(find.byKey(const Key('area-delete-Test Area')));
        await tester.pumpAndSettle();
        expect(deleted, isEmpty); // opening the sheet must not delete.

        await tester.tap(
          find.byKey(const Key('area-delete-confirm-Test Area')),
        );
        await tester.pumpAndSettle();

        expect(deleted, ['Test Area']);
      },
    );

    testWidgets(
      'C-b: tapping Cancel is a no-op — onDelete never fires',
      (tester) async {
        final deleted = <String>[];
        await tester.pumpWidget(
          _harness(
            onDelete: (item) async {
              deleted.add(item);
            },
          ),
        );

        await tester.tap(find.byKey(const Key('area-delete-Test Area')));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        expect(deleted, isEmpty);
        // The sheet is dismissed.
        expect(find.byType(CupertinoActionSheet), findsNothing);
      },
    );
  });

  group('#20: name dialog keyboard dismissal', () {
    testWidgets(
      'submitting the name dialog (add flow) drops focus/keyboard, not '
      'just the dialog',
      (tester) async {
        await tester.pumpWidget(_harness(onDelete: (_) async {}));

        await tester.tap(find.byKey(const Key('area-add-fab')));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('crud-name-field')),
          'New Area',
        );
        await tester.pump();
        expect(tester.testTextInput.hasAnyClients, isTrue);

        await tester.tap(find.byKey(const Key('crud-name-submit')));
        await tester.pumpAndSettle();

        expect(
          tester.testTextInput.hasAnyClients,
          isFalse,
          reason: 'submitting the name dialog must dismiss the keyboard',
        );
      },
    );

    testWidgets(
      'cancelling the name dialog (rename flow) drops focus/keyboard, not '
      'just the dialog',
      (tester) async {
        await tester.pumpWidget(_harness(onDelete: (_) async {}));

        await tester.tap(find.byKey(const Key('area-rename-Test Area')));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('crud-name-field')));
        await tester.pump();
        expect(tester.testTextInput.hasAnyClients, isTrue);

        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        expect(
          tester.testTextInput.hasAnyClients,
          isFalse,
          reason: 'cancelling the name dialog must dismiss the keyboard',
        );
      },
    );
  });

  group('D8: optional onMove button', () {
    testWidgets(
      'V5 (no regression): omitting onMove (the AreasScreen/WallsScreen '
      'default) renders no move button at all, existing rename/delete '
      'buttons unaffected',
      (tester) async {
        await tester.pumpWidget(_harness(onDelete: (_) async {}));

        expect(find.byKey(const Key('area-move-Test Area')), findsNothing);
        expect(find.byKey(const Key('area-rename-Test Area')), findsOneWidget);
        expect(find.byKey(const Key('area-delete-Test Area')), findsOneWidget);
      },
    );

    testWidgets(
      'supplying onMove renders area-move-<id>; tapping it calls onMove '
      'with the row\'s own item AND a live BuildContext',
      (tester) async {
        final moved = <String>[];
        BuildContext? capturedContext;
        await tester.pumpWidget(
          _harness(
            onDelete: (_) async {},
            onMove: (context, item) async {
              capturedContext = context;
              moved.add(item);
            },
          ),
        );

        expect(find.byKey(const Key('area-move-Test Area')), findsOneWidget);

        await tester.tap(find.byKey(const Key('area-move-Test Area')));
        await tester.pump();

        expect(moved, ['Test Area']);
        expect(capturedContext, isNotNull);
        expect(capturedContext!.mounted, isTrue);
      },
    );
  });

  group('CrudListScaffold surfaces a failed write instead of swallowing it', () {
    testWidgets(
      'a throwing onDelete shows a "Couldn\'t delete" SnackBar (audit L4: a '
      'guarded delete that matches 0 rows must never look like success)',
      (tester) async {
        await tester.pumpWidget(
          _harness(
            onDelete: (_) async => throw Exception('0 rows affected (test)'),
          ),
        );

        await tester.tap(find.byKey(const Key('area-delete-Test Area')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('area-delete-confirm-Test Area')),
        );
        await tester.pumpAndSettle();

        expect(
          find.text("Couldn't delete — please try again"),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'a throwing onRename shows a "Couldn\'t rename" SnackBar',
      (tester) async {
        await tester.pumpWidget(
          _harness(
            onDelete: (_) async {},
            onRename: (_, _) async => throw Exception('0 rows affected (test)'),
          ),
        );

        await tester.tap(find.byKey(const Key('area-rename-Test Area')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('crud-name-submit')));
        await tester.pumpAndSettle();

        expect(
          find.text("Couldn't rename — please try again"),
          findsOneWidget,
        );
      },
    );
  });
}
