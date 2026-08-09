// THROWAWAY UX-AUDIT CAPTURE FLOW — PASS 2. Not a regression suite.
//
// Pass 1 captured 40 surfaces but lost four of them: the Topos filter sheet
// would not close (no Close/Done button, and a barrier tap at the top of the
// screen did not dismiss it), so every capture after it in that test recorded
// the stuck sheet instead. This pass re-takes those, and additionally probes
// the dismissal behaviour itself, since "the sheet has no way out" is a
// finding rather than a harness problem.
//
//   chromedriver --port=4444 &
//   flutter drive --driver=test_driver/integration_test.dart \
//     --target=integration_test/ux_capture_test.dart \
//     -d web-server --browser-name=chrome --driver-port=4444 --headless \
//     --no-web-resources-cdn --browser-dimension=390x844@2 --timeout=2400 \
//     $(tool/e2e_accounts.sh env owner)
//
// READ-ONLY TOWARD REAL USER DATA: every write-capable control touched below
// is on an E2E-owned row, and confirmation sheets are screenshotted and then
// cancelled, never confirmed.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:masi/app/router.dart' show appRouter;
import 'package:masi/main_e2e.dart' show e2eBoot;

import 'e2e_support.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> shot(WidgetTester tester, String name) async {
    await settle(tester, frames: 12);
    await binding.takeScreenshot(name);
  }

  Future<bool> tapIfPresent(
    WidgetTester tester,
    Finder finder,
    String what, {
    Duration wait = const Duration(seconds: 4),
  }) async {
    final deadline = DateTime.now().add(wait);
    while (DateTime.now().isBefore(deadline)) {
      if (finder.evaluate().isNotEmpty) break;
      await tester.pump(const Duration(milliseconds: 150));
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    if (finder.evaluate().isEmpty) {
      debugPrint('masi/ux-capture: MISSING $what');
      return false;
    }
    await tester.tap(finder.first, warnIfMissed: false);
    await settle(tester);
    return true;
  }

  Future<void> cancelSheet(WidgetTester tester) async {
    if (find.text('Cancel').evaluate().isNotEmpty) {
      await tester.tap(find.text('Cancel').last, warnIfMissed: false);
      await settle(tester);
      return;
    }
    // No labelled dismiss. Try the barrier, then a downward fling on the sheet.
    await tester.tapAt(const Offset(195, 6));
    await settle(tester);
    await tester.dragFrom(const Offset(195, 60), const Offset(0, 600));
    await settle(tester, frames: 25);
  }

  /// The first own-topo row's wall id (own rows are the only ones with a
  /// `topo-menu-` overflow; community rows have none).
  String? firstOwnWallId(WidgetTester tester) =>
      firstIdWithPrefix(tester, 'topo-menu-');

  // ------------------------------------------------------------------
  // 1. The row overflow menu and the New-topo flow (lost in pass 1).
  // ------------------------------------------------------------------
  testWidgets('ux2: topo row overflow menu and the New topo flow', (
    tester,
  ) async {
    await e2eBoot();
    await settleNetwork(tester, budget: const Duration(seconds: 14));
    appRouter.go('/');
    await settleNetwork(tester, budget: const Duration(seconds: 10));

    final wallId = firstOwnWallId(tester);
    debugPrint('masi/ux-capture: own wall = $wallId');
    if (wallId != null) {
      await tapIfPresent(
        tester,
        find.byKey(Key('topo-menu-$wallId')),
        'topo-menu-$wallId',
      );
      await shot(tester, '51-topo-row-overflow-menu');
      await cancelSheet(tester);
    }

    await tapIfPresent(
      tester,
      find.byKey(const Key('topos-new-topo')),
      'topos-new-topo FAB',
    );
    await shot(tester, '52-new-topo-name-dialog');
    if (find.byKey(const Key('topo-name-field')).evaluate().isNotEmpty) {
      await tester.enterText(
        find.byKey(const Key('topo-name-field')),
        'Sit start project',
      );
      await settle(tester, frames: 10);
      await tapIfPresent(
        tester,
        find.byKey(const Key('topo-name-submit')),
        'topo-name-submit',
      );
      await shot(tester, '53-photo-source-sheet');
      await tapIfPresent(
        tester,
        find.byKey(const Key('photo-source-cancel')),
        'photo-source-cancel',
      );
      await settleNetwork(tester, budget: const Duration(seconds: 6));
      await shot(tester, '54-topos-home-after-cancelled-new-topo');
    }
  }, timeout: const Timeout(Duration(minutes: 6)));

  // ------------------------------------------------------------------
  // 2. Can the filter sheet actually be closed?
  // ------------------------------------------------------------------
  testWidgets('ux2: the filter sheet has no visible way out', (tester) async {
    await e2eBoot();
    await settleNetwork(tester, budget: const Duration(seconds: 12));
    appRouter.go('/');
    await settleNetwork(tester, budget: const Duration(seconds: 8));

    await tapIfPresent(
      tester,
      find.byKey(const Key('topos-filter-button')),
      'topos-filter-button',
    );
    await shot(tester, '82-filter-sheet-open');

    // Attempt 1: tap the sliver of page visible above the sheet (the barrier).
    await tester.tapAt(const Offset(195, 6));
    await settle(tester, frames: 25);
    await shot(tester, '83-filter-after-barrier-tap');
    debugPrint(
      'masi/ux-capture: after barrier tap, Filters present = '
      '${find.text('Filters').evaluate().isNotEmpty}',
    );

    // Attempt 2: drag the sheet down by its handle.
    await tester.dragFrom(const Offset(195, 45), const Offset(0, 600));
    await settle(tester, frames: 30);
    await shot(tester, '84-filter-after-drag-down');
    debugPrint(
      'masi/ux-capture: after drag down, Filters present = '
      '${find.text('Filters').evaluate().isNotEmpty}',
    );
  }, timeout: const Timeout(Duration(minutes: 5)));

  // ------------------------------------------------------------------
  // 3. Owner-side moderation surfaces off the row menu.
  // ------------------------------------------------------------------
  testWidgets('ux2: access editor, owner history, publish confirm', (
    tester,
  ) async {
    await e2eBoot();
    await settleNetwork(tester, budget: const Duration(seconds: 12));
    appRouter.go('/');
    await settleNetwork(tester, budget: const Duration(seconds: 10));

    // Prefer the PUBLISHED fixture: it is the only row that offers History.
    String? wallId;
    for (final id in keysWithPrefix(tester, 'topo-menu-')) {
      wallId = id.substring('topo-menu-'.length);
      if (wallId == 'e2e-wall-published-0001') break;
    }
    debugPrint('masi/ux-capture: acting on wall $wallId');
    if (wallId == null) return;

    Future<bool> openMenuThen(String entryKey) async {
      final opened = await tapIfPresent(
        tester,
        find.byKey(Key('topo-menu-$wallId')),
        'topo-menu-$wallId',
      );
      if (!opened) return false;
      return tapIfPresent(tester, find.byKey(Key(entryKey)), entryKey);
    }

    if (await openMenuThen('topo-access-$wallId')) {
      await settleNetwork(tester, budget: const Duration(seconds: 6));
      await shot(tester, '85-access-editor');
      await cancelSheet(tester);
    }

    if (await openMenuThen('topo-history-$wallId')) {
      await settleNetwork(tester, budget: const Duration(seconds: 10));
      await shot(tester, '86-owner-topo-history');
      await cancelSheet(tester);
    }

    // The publish/withdraw confirmation. SCREENSHOT ONLY — never confirmed.
    if (await openMenuThen('topo-publish-$wallId')) {
      await settleNetwork(tester, budget: const Duration(seconds: 8));
      await shot(tester, '87-publish-or-withdraw-confirm');
      await cancelSheet(tester);
    }

    if (await openMenuThen('topo-delete-$wallId')) {
      await settle(tester, frames: 20);
      await shot(tester, '88-delete-confirm');
      await cancelSheet(tester);
    }
  }, timeout: const Timeout(Duration(minutes: 8)));

  // ------------------------------------------------------------------
  // 4. Account at 1.8x, scrolled — pass 1 only saw the top of it.
  // ------------------------------------------------------------------
  testWidgets('ux2: account scrolled at 1.8x text scale', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.8;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await e2eBoot();
    await settleNetwork(tester, budget: const Duration(seconds: 12));
    appRouter.go('/account');
    await settleNetwork(tester, budget: const Duration(seconds: 10));
    await shot(tester, '89-account-1_8-top');
    for (var i = 0; i < 4; i++) {
      await tester.dragFrom(const Offset(195, 640), const Offset(0, -400));
      await settle(tester, frames: 20);
    }
    await settleNetwork(tester, budget: const Duration(seconds: 6));
    await shot(tester, '90-account-1_8-bottom');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
