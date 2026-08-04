import 'dart:async';

import 'package:masi/app/theme.dart';
import 'package:masi/features/library/presentation/crud_list_scaffold.dart';
import 'package:masi/shared/presentation/masi_loading_indicator.dart';
import 'package:masi/shared/presentation/masi_pending_button.dart';
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
  List<String> items = const ['Test Area'],
  Future<void> Function(
    BuildContext context,
    String item,
    MasiBusyReporter reportBusy,
  )?
  onMove,
  Future<void> Function(String item, String newName)? onRename,
  Future<void> Function(String name)? onCreate,
}) {
  return MaterialApp(
    theme: MasiTheme.light,
    home: CrudListScaffold<String>(
      title: 'Areas',
      entityKey: 'area',
      asyncItems: AsyncValue.data(items),
      idOf: (item) => item,
      nameOf: (item) => item,
      emptyMessage: 'No areas yet',
      addDialogTitle: 'New Area',
      renameDialogTitle: 'Rename Area',
      onRetry: () {},
      onTap: (_) {},
      onCreate: onCreate ?? (_) async {},
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

    testWidgets('C-b: tapping Cancel is a no-op — onDelete never fires', (
      tester,
    ) async {
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
    });
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
            onMove: (context, item, reportBusy) async {
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

  group(
    'CrudListScaffold surfaces a failed write instead of swallowing it',
    () {
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

      testWidgets('a throwing onRename shows a "Couldn\'t rename" SnackBar', (
        tester,
      ) async {
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

        expect(find.text("Couldn't rename — please try again"), findsOneWidget);
      });
    },
  );

  // The state this screen simply did not have: between "the confirm sheet
  // closed" and "the row disappeared" there was nothing on screen at all, and
  // nothing stopping a second tap from firing a second write at the same row.
  group('a row write in flight', () {
    testWidgets(
      'puts a cue on the button that was pressed, leaves the other two inert, '
      'and swallows a second tap',
      (tester) async {
        final deletes = Completer<void>();
        var deleteCalls = 0;
        await tester.pumpWidget(
          _harness(
            onDelete: (_) {
              deleteCalls++;
              return deletes.future;
            },
          ),
        );

        await tester.tap(find.byKey(const Key('area-delete-Test Area')));
        await tester.pumpAndSettle();

        // While the SHEET is up the row is idle: the user is the one working,
        // and a spinner behind a modal they are still reading is noise. (It
        // would also make the pumpAndSettle above hang forever.)
        expect(find.byKey(MasiLoadingIndicator.spinnerKey), findsNothing);

        await tester.tap(
          find.byKey(const Key('area-delete-confirm-Test Area')),
        );
        // Deliver the confirm, then cross the reveal delay: the cue is not
        // allowed on screen for the first 180 ms, so a fast delete paints
        // nothing at all.
        await tester.pump();
        expect(deleteCalls, 1);
        expect(find.byKey(MasiLoadingIndicator.spinnerKey), findsNothing);

        await tester.pump(const Duration(milliseconds: 250));
        expect(
          find.descendant(
            of: find.byKey(const Key('area-delete-Test Area')),
            matching: find.byKey(MasiLoadingIndicator.spinnerKey),
          ),
          findsOneWidget,
          reason: 'the cue belongs on the control the user actually pressed',
        );

        final rename = tester.widget<IconButton>(
          find.byKey(const Key('area-rename-Test Area')),
        );
        expect(
          rename.onPressed,
          isNull,
          reason:
              'a rename racing a delete on one row is exactly the '
              'concurrent write this guard exists to stop',
        );

        // A second delete tap while the first is still in flight must do
        // nothing — including during the 180 ms window where the button still
        // LOOKS idle (asserted above).
        await tester.tap(
          find.byKey(const Key('area-delete-Test Area')),
          warnIfMissed: false,
        );
        await tester.pump();
        expect(deleteCalls, 1);

        deletes.complete();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.byKey(MasiLoadingIndicator.spinnerKey), findsNothing);
        expect(
          tester
              .widget<IconButton>(
                find.byKey(const Key('area-rename-Test Area')),
              )
              .onPressed,
          isNotNull,
        );
      },
    );

    testWidgets('a move reports its own pre-sheet read, so the tap is never '
        'silent', (tester) async {
      final areasRead = Completer<void>();
      await tester.pumpWidget(
        _harness(
          onDelete: (_) async {},
          // Mirrors `sectors_screen.dart`'s `_handleMove`: resolve the
          // candidate destinations from the database FIRST (the sheet cannot
          // be built without them), and only then hand control back.
          onMove: (context, item, reportBusy) async {
            reportBusy(true);
            await areasRead.future;
            reportBusy(false);
          },
        ),
      );

      await tester.tap(find.byKey(const Key('area-move-Test Area')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(
        find.descendant(
          of: find.byKey(const Key('area-move-Test Area')),
          matching: find.byKey(MasiLoadingIndicator.spinnerKey),
        ),
        findsOneWidget,
        reason:
            'tapping Move used to do nothing observable until the read '
            'finished and the sheet appeared',
      );

      areasRead.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byKey(MasiLoadingIndicator.spinnerKey), findsNothing);
    });

    testWidgets('the create button waits on its own write, not on its own '
        'name dialog', (tester) async {
      final write = Completer<void>();
      await tester.pumpWidget(
        _harness(onDelete: (_) async {}, onCreate: (_) => write.future),
      );

      await tester.tap(find.byKey(const Key('area-add-fab')));
      await tester.pumpAndSettle();

      // The dialog is the user's turn. A cue here would sit on the one control
      // still visible under the barrier for as long as they type — and would
      // have hung the pumpAndSettle above.
      expect(find.byKey(MasiLoadingIndicator.spinnerKey), findsNothing);

      await tester.enterText(
        find.byKey(const Key('crud-name-field')),
        'Squamish',
      );
      // The dialog's Save enables itself via setState, so it is only tappable
      // on the following frame.
      await tester.pump();
      await tester.tap(find.byKey(const Key('crud-name-submit')));
      // `showDialog`'s future resolves only once the route has finished its
      // EXIT transition, so the write — and therefore the cue — starts a
      // couple of hundred ms after the tap. Pump past both that and the
      // reveal delay.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(
        find.descendant(
          of: find.byKey(const Key('area-add-fab')),
          matching: find.byKey(MasiLoadingIndicator.spinnerKey),
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<ElevatedButton>(find.byKey(const Key('area-add-fab')))
            .onPressed,
        isNull,
        reason: 'a second insert from a second tap is the bug this closes',
      );
      // The label keeps its box while the cue is over it, so the button cannot
      // change width mid-write.
      expect(find.text('New Area'), findsOneWidget);

      write.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byKey(MasiLoadingIndicator.spinnerKey), findsNothing);
    });
  });

  // Defect confirmed by construction, not by reading: the lock and the cue live
  // in the ROW's State, and this is a lazy `ListView.separated` with no
  // keep-alive. Scroll the row past the cache extent while its delete cascade
  // is still in flight and that State is disposed — so `reportBusy(false)` and
  // the `finally` both no-op, and scrolling back rebuilds a FRESH State with
  // both flags clear: an idle-looking glyph over a write that is still running,
  // and a second tap that starts a second concurrent write on the same row.
  group('a row scrolled out of the list mid-write', () {
    final many = [for (var i = 0; i < 60; i++) 'Area $i'];

    testWidgets(
      'keeps its in-flight lock and its cue across being recycled — a second '
      'delete on the same row must be impossible',
      (tester) async {
        // Small enough that row 0 is far outside the 250px default cache extent
        // once we scroll.
        tester.view.physicalSize = const Size(400, 600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final deletes = Completer<void>();
        var deleteCalls = 0;
        await tester.pumpWidget(
          _harness(
            items: many,
            onDelete: (_) {
              deleteCalls++;
              return deletes.future;
            },
          ),
        );

        await tester.tap(find.byKey(const Key('area-delete-Area 0')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('area-delete-confirm-Area 0')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(deleteCalls, 1);
        expect(
          find.descendant(
            of: find.byKey(const Key('area-delete-Area 0')),
            matching: find.byKey(MasiLoadingIndicator.spinnerKey),
          ),
          findsOneWidget,
        );

        // Out of the cache extent and back.
        await tester.drag(find.byType(ListView), const Offset(0, -4000));
        await tester.pump();
        await tester.drag(find.byType(ListView), const Offset(0, 4000));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        expect(
          find.descendant(
            of: find.byKey(const Key('area-delete-Area 0')),
            matching: find.byKey(MasiLoadingIndicator.spinnerKey),
          ),
          findsOneWidget,
          reason: 'the row came back looking idle over a live cascade',
        );
        expect(
          tester
              .widget<IconButton>(find.byKey(const Key('area-delete-Area 0')))
              .onPressed,
          isNull,
          reason: 'a recycled row must not offer its own write a second time',
        );

        // And prove it at the behavioural level: a second delete attempt.
        // Explicit pumps, not `pumpAndSettle` — the cue is live now, which is
        // the whole point, and a revealed spinner never settles.
        await tester.tap(
          find.byKey(const Key('area-delete-Area 0')),
          warnIfMissed: false,
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          find.byKey(const Key('area-delete-confirm-Area 0')),
          findsNothing,
          reason: 'the confirm sheet reopened on a row already being deleted',
        );
        expect(deleteCalls, 1);

        deletes.complete();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
      },
    );
  });
}
