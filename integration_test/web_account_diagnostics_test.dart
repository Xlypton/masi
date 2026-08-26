// Visual + structural check of the Account screen's BUILD diagnostics section
// and the Feed tab's account button, driven headless in Chrome.
//
//   tool/drive_web.sh integration_test/web_account_diagnostics_test.dart
//
// Boots through `e2eBoot()` from `lib/main_e2e.dart` — the same entry the
// signed-in E2E suite uses — because both surfaces under test live BEHIND the
// web auth wall (`webAuthGateEnabledProvider` bounces every route to
// `/account`), and none of the three sign-in routes the app offers can be
// driven by an agent.
//
// FAKE mode is deliberate and sufficient HERE, unlike anywhere server-gated:
// every value this exercises is client-side — a compile-time build stamp, a
// `navigator.serviceWorker`/`caches` read, and an app-bar button. Nothing on
// this path needs `auth.uid()`, so the 401s the fake session produces are
// expected and irrelevant. **Nothing about RLS, sync or moderation may be
// claimed from this file.**
//
// What this covers that `flutter test` cannot: that the section renders inside
// the REAL scrolling Account card without overflowing, that the "Offline
// shell" row resolves against a REAL service worker rather than the inert
// stub, and that the Feed's new action actually reaches `/account` through the
// production router.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:masi/app/router.dart' show appRouter;
import 'package:masi/main_e2e.dart' show e2eBoot;

import 'e2e_support.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the Account screen renders the build diagnostics, and the '
      'Feed reaches /account', (tester) async {
    await e2eBoot();
    await settleNetwork(tester, budget: const Duration(seconds: 8));

    // The auth wall must not have bounced us to the sign-in view — otherwise
    // every assertion below would fail with a confusing "can't find the row".
    expect(
      find.byKey(const Key('account-send-link')),
      findsNothing,
      reason: 'the auth wall redirected to the sign-in view; the '
          'webAuthGateEnabledProvider override broke',
    );

    // ---- 1. The Feed's new account button --------------------------------
    appRouter.go('/feed');
    await settle(tester);
    await binding.takeScreenshot('acct-01-feed-with-account-button');

    final feedAccountButton = find.byKey(const Key('feed-account-button'));
    expect(
      feedAccountButton,
      findsOneWidget,
      reason: 'the Feed tab must carry its own way into /account',
    );

    await tapOrFail(tester, feedAccountButton, 'the Feed account button');
    await settle(tester);

    // Through the REAL router, not a test double: reaching the signed-in body
    // is what proves the push actually landed on `/account`.
    expect(
      find.byKey(const Key('account-email-label')),
      findsOneWidget,
      reason: 'tapping the Feed account button did not reach /account',
    );

    // ---- 2. The build diagnostics section --------------------------------
    // The section sits well below the fold of the Account card, so it has to
    // be scrolled to — which is also the point: this proves it lays out inside
    // the real scroll view rather than overflowing it.
    final buildSection = find.byKey(const Key('account-build-diagnostics'));
    await tester.scrollUntilVisible(
      buildSection,
      300,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 30,
    );
    await settle(tester);
    await binding.takeScreenshot('acct-02-build-diagnostics');

    for (final key in [
      'account-build-version',
      'account-build-time',
      'account-build-commit',
      'account-build-channel',
      'account-build-shell',
      'account-build-backend',
    ]) {
      expect(find.byKey(Key(key)), findsOneWidget, reason: key);
    }

    // The "Offline shell" row must have RESOLVED, not still be probing: in a
    // browser the seam answers from `navigator.serviceWorker` + `caches`, and
    // a row stuck on "checking…" would mean the js_interop read never
    // completed. It must also never render the stub's native answer.
    expect(
      find.textContaining('checking…'),
      findsNothing,
      reason: 'the shell probe never resolved in a real browser',
    );
    expect(
      find.textContaining('not applicable'),
      findsNothing,
      reason: 'the inert stub was compiled into the web bundle',
    );

    // ---- 3. The storage section's two newly-visible rows ------------------
    final storageSection = find.byKey(const Key('account-storage-diagnostics'));
    await tester.scrollUntilVisible(
      storageSection,
      300,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 30,
    );
    await settle(tester);
    await binding.takeScreenshot('acct-03-storage-diagnostics');

    expect(find.byKey(const Key('account-storage-schema')), findsOneWidget);
    expect(find.byKey(const Key('account-storage-user')), findsOneWidget);
  });
}
