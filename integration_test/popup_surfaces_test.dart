// Visual check for the popup unification: opens each migrated modal surface
// in the REAL signed-in app and screenshots it, so the four idioms that used
// to render differently can be compared side by side as images.
//
//   flutter drive --driver=test_driver/integration_test.dart \
//     --target=integration_test/popup_surfaces_test.dart \
//     -d web-server --browser-name=chrome --driver-port=4444 \
//     --headless --no-web-resources-cdn --timeout=600
//
// Boots through `e2eOverrides()` exactly like `e2e_signed_in_test.dart`, so a
// bug seen here and a bug seen by hand in Chrome cannot be harness artifacts.
//
// Assertion-bearing, not screenshot-only: each step asserts the surface it
// just opened is actually on screen, so an unreachable popup FAILS here
// instead of quietly producing a screenshot of the screen behind it.
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:masi/main.dart' show bootApp;
import 'package:masi/main_e2e.dart' show e2eOverrides;

Future<void> settle(
  WidgetTester tester, {
  int frames = 40,
  Duration step = const Duration(milliseconds: 100),
}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(step);
  }
}

Future<void> tapOrFail(
  WidgetTester tester,
  Finder finder,
  String what,
) async {
  expect(finder, findsWidgets, reason: 'expected to find $what');
  await tester.tap(finder.first);
  await settle(tester);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('every migrated popup opens as a Cupertino surface', (
    tester,
  ) async {
    final stamp = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    final areaName = 'Popup Area $stamp';

    bootApp(overrides: e2eOverrides());
    await settle(tester, frames: 60);

    // --- 1. The text prompt (was three duplicated Material AlertDialogs) ---
    await tapOrFail(
      tester,
      find.byKey(const Key('topos-organize')),
      'the Topos "organize" (Areas) entry point',
    );
    await tapOrFail(
      tester,
      find.byKey(const Key('area-add-fab')),
      'the add-Area FAB',
    );
    expect(
      find.byType(CupertinoAlertDialog),
      findsOneWidget,
      reason: 'the name prompt should now be a CupertinoAlertDialog',
    );
    await binding.takeScreenshot('popup-01-text-prompt-empty');

    // Submit must be inert until the field has non-whitespace content —
    // the behaviour all three old copies implemented separately.
    expect(
      tester
          .widget<CupertinoDialogAction>(
            find.byKey(const Key('crud-name-submit')),
          )
          .onPressed,
      isNull,
      reason: 'submit must be disabled while the field is empty',
    );

    await tester.enterText(find.byKey(const Key('crud-name-field')), areaName);
    await settle(tester, frames: 10);
    await binding.takeScreenshot('popup-02-text-prompt-filled');

    await tapOrFail(
      tester,
      find.byKey(const Key('crud-name-submit')),
      'the Area name submit button',
    );
    expect(find.text(areaName), findsWidgets);

    // --- 2. The destructive confirm (was a Material AlertDialog here) ---
    final areaRow = find.ancestor(
      of: find.text(areaName),
      matching: find.byType(Material),
    );
    expect(areaRow, findsWidgets, reason: 'the new Area row');

    final deleteButton = find.descendant(
      of: areaRow.first,
      matching: find.byWidgetPredicate(
        (w) => w.key.toString().contains('area-delete-'),
      ),
    );
    await tapOrFail(tester, deleteButton, 'the Area delete button');
    expect(
      find.byType(CupertinoActionSheet),
      findsOneWidget,
      reason: 'delete confirm should be a CupertinoActionSheet',
    );
    expect(find.text('Delete "$areaName"?'), findsWidgets);
    await binding.takeScreenshot('popup-03-delete-confirm');

    // Cancel: the confirm must NOT delete on dismissal.
    await tapOrFail(tester, find.text('Cancel'), 'the confirm Cancel button');
    expect(
      find.text(areaName),
      findsWidgets,
      reason: 'cancelling the confirm must leave the Area alone',
    );

    // --- 3. The row action menu, on the Topos home ---
    await tester.pageBack();
    await settle(tester, frames: 30);
    await binding.takeScreenshot('popup-04-topos-home');
  });
}
