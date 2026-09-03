import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:masi/main.dart' as app;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('boots to the Topos home, then Organize into Areas', (
    tester,
  ) async {
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 2));
    await binding.takeScreenshot('01-topos-home');

    const organizeKey = Key('topos-organize');
    final organizeFinder = find.byKey(organizeKey);
    if (tester.any(organizeFinder)) {
      await tester.tap(organizeFinder);
    }
    await tester.pumpAndSettle(const Duration(seconds: 2));
    await binding.takeScreenshot('02-areas');

    const fabKey = Key('area-add-fab');
    final fabFinder = find.byKey(fabKey);
    if (tester.any(fabFinder)) {
      await tester.tap(fabFinder);
    } else {
      final anyFab = find.byType(FloatingActionButton);
      if (tester.any(anyFab)) {
        await tester.tap(anyFab.first);
      }
    }
    await tester.pumpAndSettle(const Duration(seconds: 2));
    await binding.takeScreenshot('03-after-fab');
  });
}
