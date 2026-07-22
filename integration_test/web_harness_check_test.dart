// Trivial, dependency-free web E2E harness smoke test.
//
// Purpose: prove the headless-Chrome `flutter drive` + chromedriver pipeline
// (see `tool/drive_web.sh`) actually works, independent of whether the real
// Masi app compiles for web yet. This file deliberately does NOT import
// `package:masi/main.dart` (or anything else that pulls in `dart:io`),
// so it compiles for `-d web-server` today even while the real app doesn't.
//
// Run it with:
//   tool/drive_web.sh integration_test/web_harness_check_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('web harness pipeline renders and screenshots a trivial widget', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: Text('web-harness-ok', key: Key('web-harness-ok')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('web-harness-ok')), findsOneWidget);

    await binding.takeScreenshot('web-harness-ok');
  });
}
