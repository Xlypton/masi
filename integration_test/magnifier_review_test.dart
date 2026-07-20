import 'dart:developer' as developer;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:climbtopo/main.dart' as app;

/// binding.takeScreenshot() was found to return a blank white capture in
/// this environment (VMServiceFlutterDriver request_data stalls / returns
/// empty). As a fallback, this flow holds each state for several real
/// seconds and prints a distinctive marker line so an external `simctl io
/// booted screenshot` can be triggered from outside the Dart VM at the
/// right moment.
Future<void> _holdAndMark(WidgetTester tester, String marker) async {
  // ignore: avoid_print
  print('MAGNIFIER_STATE_READY: $marker');
  developer.log('MAGNIFIER_STATE_READY: $marker');
  for (var i = 0; i < 60; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('search-field magnifier visual review', (tester) async {
    app.main();

    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await _holdAndMark(tester, '01-topos-home');

    final searchFinder = find.byKey(const Key('topos-search-field'));
    if (tester.any(searchFinder)) {
      await tester.tap(searchFinder);
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }
    await _holdAndMark(tester, '02-topos-search-focused');

    final feedTabFinder = find.byKey(const Key('nav-tab-feed'));
    if (tester.any(feedTabFinder)) {
      await tester.tap(feedTabFinder);
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }
    await _holdAndMark(tester, '03-feed-search');
  });
}
