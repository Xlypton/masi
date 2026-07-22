// Visual review capture for the enlarged (size-20, left-padded) magnifier
// prefix icon on the app's search fields — headless-Chrome web capture via
// `tool/drive_web.sh`, screenshots read as images (not judged here).
//
// Modeled on `integration_test/web_smoke_test.dart` (boots the real app,
// drives via Key, calls `binding.takeScreenshot`). Covers:
//   1. Topos home search field (`topos-search-field`, always present on
//      first frame — see `topos_screen.dart`'s `_ToposFilterBar`).
//   2. Community Feed search field (`community-search-field`, on the
//      `/feed` bottom-nav branch — `community_screen.dart`'s
//      `_FeedView`), reached via the `nav-tab-feed` bottom-nav tab.
//   3. The Topos search field again, focused + with text entered, for a
//      one-more state shot of the field's focused border alongside the
//      magnifier.
//
// Run: tool/drive_web.sh integration_test/magnifier_review_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:masi/main.dart' as app;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('search-field magnifier visual review', (tester) async {
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // --- 1. Topos home search field ---
    final toposSearchFinder = find.byKey(const Key('topos-search-field'));
    expect(
      toposSearchFinder,
      findsOneWidget,
      reason: 'Topos home should show the search field on first frame',
    );
    await binding.takeScreenshot('01-topos-search');

    // --- 2. Community Feed search field (best-effort; skip gracefully) ---
    final feedTabFinder = find.byKey(const Key('nav-tab-feed'));
    if (tester.any(feedTabFinder)) {
      await tester.tap(feedTabFinder);
      await tester.pumpAndSettle(const Duration(seconds: 2));

      final communitySearchFinder = find.byKey(
        const Key('community-search-field'),
      );
      if (tester.any(communitySearchFinder)) {
        await binding.takeScreenshot('02-community-search');
      }

      // Back to Topos for the focused-state shot.
      final toposTabFinder = find.byKey(const Key('nav-tab-topos'));
      if (tester.any(toposTabFinder)) {
        await tester.tap(toposTabFinder);
        await tester.pumpAndSettle(const Duration(seconds: 2));
      }
    }

    // --- 3. Topos search field, focused + text entered ---
    final toposSearchFinderAgain = find.byKey(
      const Key('topos-search-field'),
    );
    if (tester.any(toposSearchFinderAgain)) {
      await tester.tap(toposSearchFinderAgain);
      await tester.enterText(toposSearchFinderAgain, 'crimp');
      await tester.pumpAndSettle(const Duration(seconds: 1));
      await binding.takeScreenshot('03-topos-search-focused');
    }
  });
}
