// Web review test for feature #12: confirms the Topos home app bar has had
// its dedicated Logbook/compass icons removed (only `topos-organize` +
// `topos-account-button` remain), and that the Feed screen's app bar now
// carries the `feed-logbook-button` (MasiIcon 'logbook') as the new entry
// point back to the personal Logbook (see `community_screen.dart` around
// the `feed-logbook-button` IconButton, and `nav_shell.dart`'s
// `nav-tab-feed` bottom-nav tab).
//
// Driven headless in Chrome via `tool/drive_web.sh
// integration_test/home_feed_icons_review_test.dart` (see
// `integration_test/web_smoke_test.dart` for the harness pattern and
// `CLAUDE.md`'s "Web verification loop"). This test does NOT judge the
// screenshots — it only needs to reliably produce them; a human/reviewer
// reads the PNGs from `build/screenshots/` afterward.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:climbtopo/main.dart' as app;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Topos home icons + Feed logbook button (feature #12)', (
    tester,
  ) async {
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // --- h1: Topos home app bar — should show ONLY folder (Organize) +
    // account icons; the compass + logbook icons were removed in #12.
    await binding.takeScreenshot('h1-topos-home-appbar');

    final organizeFinder = find.byKey(const Key('topos-organize'));
    final accountFinder = find.byKey(const Key('topos-account-button'));
    if (!tester.any(organizeFinder)) {
      // ignore: avoid_print
      print(
        'REVIEW WARNING: key "topos-organize" not found on Topos home '
        '— cannot confirm the folder/Organize icon is present.',
      );
    }
    if (!tester.any(accountFinder)) {
      // ignore: avoid_print
      print(
        'REVIEW WARNING: key "topos-account-button" not found on Topos '
        'home — cannot confirm the account icon is present.',
      );
    }

    // --- Navigate to the Feed tab via the bottom nav ---
    final feedTabFinder = find.byKey(const Key('nav-tab-feed'));
    if (tester.any(feedTabFinder)) {
      await tester.tap(feedTabFinder);
      await tester.pumpAndSettle(const Duration(seconds: 2));
    } else {
      // ignore: avoid_print
      print(
        'REVIEW WARNING: key "nav-tab-feed" not found — could not tap into '
        'the Feed tab. Screenshot h2 will show whatever screen is current.',
      );
    }

    // --- h2: Feed screen app bar — should show the new
    // `feed-logbook-button` (MasiIcon 'logbook').
    await binding.takeScreenshot('h2-feed-with-logbook-button');

    final logbookButtonFinder = find.byKey(const Key('feed-logbook-button'));
    if (tester.any(logbookButtonFinder)) {
      // --- Optional: tap it and confirm it opens the logbook ---
      await tester.tap(logbookButtonFinder);
      await tester.pumpAndSettle(const Duration(seconds: 2));
      await binding.takeScreenshot('h3-logbook');
    } else {
      // ignore: avoid_print
      print(
        'REVIEW WARNING: key "feed-logbook-button" not found on the Feed '
        'screen — cannot confirm the new logbook entry point is present. '
        'Skipping h3-logbook screenshot.',
      );
    }
  });
}
