// Signed-in E2E regression flow, driven headless in Chrome.
//
// FAKE mode (no dart-defines) — what this file has always been:
//   flutter drive --driver=test_driver/integration_test.dart \
//     --target=integration_test/e2e_signed_in_test.dart \
//     -d web-server --browser-name=chrome --driver-port=4444 \
//     --headless --no-web-resources-cdn --timeout=600
//
// REAL mode — a genuine Supabase session, RLS enforced, sync live:
//   tool/e2e_accounts.sh ensure && tool/e2e_seed.sh
//   flutter drive … $(tool/e2e_accounts.sh env owner)
// or just `tool/drive_e2e.sh owner`.
//
// Boots through `e2eBoot()` from `lib/main_e2e.dart` — the SAME entry the
// interactive browser build uses — so a bug found by hand in Chrome and a bug
// found here cannot be artifacts of two different harnesses.
//
// DELIBERATELY ASSERTION-HEAVY. `web_smoke_test.dart` guards every interaction
// behind `if (tester.any(...))` and contains zero `expect()` calls, so it
// passes whether or not the app did anything — it proves "did not throw", not
// "worked" (CLAUDE.md says as much). This file instead FAILS when a step is
// unreachable, which is the only way an autonomous run can catch a regression
// rather than silently skipping past it.
//
// WHAT EACH MODE PROVES, so nothing here is over-claimed:
//   FAKE — the app's own behavior for a signed-in user: routing, layout, local
//   drift/OPFS reads and writes. `auth.uid()` is null, so nothing server-gated
//   is exercised and 401s in the console are expected.
//   REAL — all of that, plus that the production auth wall admits a real
//   session, that the sync PULL brings the seeded fixture down through live
//   RLS, and that the community surfaces render server data.
//
// WHAT NEITHER MODE CAN DRIVE: the photo picker (`image_picker`) is a native
// OS dialog outside Flutter, so "New topo" is unreachable from any
// integration_test on any platform. Every flow below that needs a photo
// reaches it through the SEEDED fixture instead (`tool/e2e_seed.sh`), never by
// pretending the picker worked.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:masi/app/router.dart' show appRouter;
import 'package:masi/main_e2e.dart'
    show e2eActiveEmail, e2eBoot, e2eRealSessionRequested;

import 'e2e_support.dart';

/// The seeded fixture's ids. Must match `tool/e2e_common.sh` — they are
/// deterministic precisely so this file can name them.
const String kE2eSeededWallName = 'E2E Published Wall';
const String kE2eSeededAreaName = 'E2E Test Area';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('signed-in: boots past the auth wall and round-trips '
      'Area -> Sector -> Wall', (tester) async {
    // Unique per run so the assertions below cannot be satisfied by a row
    // left behind in OPFS by an EARLIER run — the e2e uid is deliberately
    // stable, so the local library genuinely persists between runs.
    final stamp = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    final areaName = 'E2E Area $stamp';
    final sectorName = 'E2E Sector $stamp';
    final wallName = 'E2E Wall $stamp';

    await e2eBoot();
    await settleNetwork(tester, budget: const Duration(seconds: 8));
    await binding.takeScreenshot('01-signed-in-home');

    // The auth wall must NOT have bounced us to the sign-in view. In FAKE mode
    // that would mean the gate override regressed; in REAL mode it would mean
    // the password sign-in failed and `e2eBoot` booted signed out. Either way
    // every later step would fail with a confusing "can't find the FAB" —
    // assert the real cause here instead.
    expect(
      find.byKey(const Key('account-send-link')),
      findsNothing,
      reason: 'the auth wall redirected to the sign-in view — in REAL mode '
          'that means signInWithPassword failed (check the console for '
          '"masi/e2e: REAL sign-in FAILED"); in FAKE mode it means the '
          'webAuthGateEnabledProvider override broke',
    );

    // --- Areas ---
    await tapOrFail(
      tester,
      find.byKey(const Key('topos-organize')),
      'the Topos "organize" (Areas) entry point',
    );
    await binding.takeScreenshot('02-areas');

    await tapOrFail(
      tester,
      find.byKey(const Key('area-add-fab')),
      'the add-Area FAB',
    );
    await tester.enterText(find.byKey(const Key('crud-name-field')), areaName);
    await settle(tester, frames: 10);
    await tapOrFail(
      tester,
      find.byKey(const Key('crud-name-submit')),
      'the Area name submit button',
    );
    expect(
      find.text(areaName),
      findsWidgets,
      reason: 'the new Area did not appear in the Areas list after create',
    );
    await binding.takeScreenshot('03-area-created');

    // --- Sectors ---
    await tapOrFail(tester, find.text(areaName), 'the new Area row');
    await tapOrFail(
      tester,
      find.byKey(const Key('sector-add-fab')),
      'the add-Sector FAB',
    );
    await tester.enterText(
      find.byKey(const Key('crud-name-field')),
      sectorName,
    );
    await settle(tester, frames: 10);
    await tapOrFail(
      tester,
      find.byKey(const Key('crud-name-submit')),
      'the Sector name submit button',
    );
    expect(
      find.text(sectorName),
      findsWidgets,
      reason: 'the new Sector did not appear under its Area after create',
    );
    await binding.takeScreenshot('04-sector-created');

    // --- Walls ---
    await tapOrFail(tester, find.text(sectorName), 'the new Sector row');
    await tapOrFail(
      tester,
      find.byKey(const Key('wall-add-fab')),
      'the add-Wall FAB',
    );
    await tester.enterText(find.byKey(const Key('crud-name-field')), wallName);
    await settle(tester, frames: 10);
    await tapOrFail(
      tester,
      find.byKey(const Key('crud-name-submit')),
      'the Wall name submit button',
    );
    expect(
      find.text(wallName),
      findsWidgets,
      reason: 'the new Wall did not appear under its Sector after create',
    );
    await binding.takeScreenshot('05-wall-created');

    // --- Persistence round-trip ---
    // Navigate back up to Areas and confirm the Area is still listed. This
    // is a re-read through the drift/OPFS query path, not a widget-tree
    // leftover: the Areas screen rebuilt from `watchAreas` after the
    // Sector/Wall writes committed.
    await tester.pageBack();
    await settle(tester);
    await tester.pageBack();
    await settle(tester);
    expect(
      find.text(areaName),
      findsWidgets,
      reason: 'the Area vanished from the list after navigating back — the '
          'write did not survive a re-read from drift',
    );
    await binding.takeScreenshot('06-round-trip');
  });

  testWidgets('signed-in: the Account screen reports the session', (
    tester,
  ) async {
    await e2eBoot();
    await settleNetwork(tester, budget: const Duration(seconds: 8));

    // `/account` is a top-level sibling of the bottom-nav shell (see
    // `webAuthGateSignInPath`), not one of its tabs, so drive the module-level
    // router directly rather than hunting for a nav affordance.
    appRouter.go('/account');
    await settle(tester, frames: 40);
    await binding.takeScreenshot('07-account-signed-in');

    // Reaching /account signed-in must show the signed-IN body (the session's
    // email), never the magic-link form.
    expect(
      find.byKey(const Key('account-email-label')),
      findsWidgets,
      reason: 'Account screen did not render the signed-in body',
    );
    expect(
      find.textContaining(e2eActiveEmail),
      findsWidgets,
      reason: 'Account screen did not report the signed-in session email',
    );
    expect(
      find.byKey(const Key('account-send-link')),
      findsNothing,
      reason: 'Account screen showed the magic-link form for a signed-in user',
    );
  });

  testWidgets('signed-in: the community feed renders and its refresh runs', (
    tester,
  ) async {
    await e2eBoot();
    await settleNetwork(tester, budget: const Duration(seconds: 8));

    appRouter.go('/feed');
    await settle(tester, frames: 40);
    await waitFor(
      tester,
      find.byKey(const Key('community-feed-screen')),
      'the community feed screen',
    );
    await binding.takeScreenshot('08-community-feed');

    // Pull-to-refresh IS the pull trigger (`SyncOrchestrator.pullNow`).
    // Firing it is what makes this test meaningful in REAL mode: nothing else
    // on a cold boot with an ALREADY-signed-in session fires a pull, because
    // the orchestrator's automatic pull is on the signed-out -> signed-in EDGE
    // and `e2eBoot` signs in before the app starts.
    //
    // [pullToRefresh], never `tapOrFail` — the key is on the `RefreshIndicator`
    // wrapping the whole feed, so a tap lands mid-list and opens a row. Until
    // 2026-08-08 that is exactly what happened and no pull ran at all; this
    // test still reported green, because the sync-error key it asserts is
    // absent is equally absent on the ascent screen it had navigated to.
    await pullToRefresh(
      tester,
      find.byKey(const Key('community-feed-refresh')),
      'the community feed refresh button',
    );
    await settleNetwork(tester, budget: const Duration(seconds: 10));
    await binding.takeScreenshot('09-community-feed-refreshed');

    // The feed must not be sitting on an error state after a live pull.
    expect(
      find.byKey(const Key('community-sync-error-empty')),
      findsNothing,
      reason: 'the feed reported a sync error after pullNow — check the '
          'console for the SyncOrchestrator message',
    );
  });

  // ---------------------------------------------------------------------
  // REAL-mode only. These assert on data the SERVER has to hand back, so
  // they are meaningless without a JWT — and a skip that says why is more
  // honest than an `if (…) return` that reports a pass.
  // ---------------------------------------------------------------------
  testWidgets(
    'real session: the seeded fixture arrives through a live sync pull',
    (tester) async {
      await e2eBoot();
      await settleNetwork(tester, budget: const Duration(seconds: 8));

      // Force the pull through the feed's own refresh affordance.
      appRouter.go('/feed');
      await settle(tester, frames: 30);
      await pullToRefresh(
        tester,
        find.byKey(const Key('community-feed-refresh')),
        'the community feed refresh button',
      );
      await settleNetwork(tester, budget: const Duration(seconds: 12));

      // The published fixture is OWNED by this account, so it must come down
      // through `fetchOwnRows` — this is the assertion that the JWT is real
      // and that RLS let the row through.
      await waitFor(
        tester,
        find.text(kE2eSeededWallName),
        'the seeded published wall in the community feed — the live pull did '
        'not return it (fixture missing? run tool/e2e_seed.sh)',
        // 60s is comfortably above the real pull time. TIMING IS NOT WHY THIS
        // FAILS — that was checked, at 150s, and it fails identically. What is
        // known as of 2026-08-07:
        //   * the session is REAL and the app knows it (the Account test above
        //     passes: it renders the signed-in body and the E2E email),
        //   * the server hands the fixture to THIS account's JWT — verified by
        //     curl against PostgREST with a real password-grant token,
        //     `is_wall_public` true, both fixture walls returned,
        //   * the ancestors are owned by the same uid, so `fetchOwnRows` sees
        //     them too (the feed INNER-JOINs sectors/areas, so a missing
        //     ancestor would hide an imported wall — ruled out),
        //   * `pullNow()` reports no sync error (the feed test above asserts
        //     `community-sync-error-empty` is absent).
        // So the break is between "the pull ran" and "the row is in the local
        // walls table", and it is invisible from here: `flutter drive
        // -d web-server` swallows the app's own console. The next step is the
        // interactive loop (build main_e2e REAL, serve with COOP/COEP, read
        // the browser console) — see the task filed for it.
        timeout: const Duration(seconds: 60),
      );
      await binding.takeScreenshot('10-seeded-topo-in-feed');

      // …and it must also have landed in the LOCAL library, which is the half
      // that proves the pull imported rather than merely fetched.
      appRouter.go('/areas');
      await settle(tester, frames: 30);
      await waitFor(
        tester,
        find.text(kE2eSeededAreaName),
        'the seeded Area in the local library after the pull',
        timeout: const Duration(seconds: 60),
      );
      await binding.takeScreenshot('11-seeded-area-local');
    },
    skip: !e2eRealSessionRequested,
  );

  testWidgets(
    'real session: version history renders server-side versions',
    (tester) async {
      await e2eBoot();
      await settleNetwork(tester, budget: const Duration(seconds: 8));

      appRouter.go('/feed');
      await settle(tester, frames: 30);
      await pullToRefresh(
        tester,
        find.byKey(const Key('community-feed-refresh')),
        'the community feed refresh button',
      );
      await settleNetwork(tester, budget: const Duration(seconds: 12));
      await tapOrFail(
        tester,
        find.text(kE2eSeededWallName),
        'the seeded published wall row in the feed',
        // See the sibling test above for why this is not a timing problem.
        timeout: const Duration(seconds: 60),
      );
      await tapOrFail(
        tester,
        find.byKey(const Key('community-detail-more-button')),
        'the topo detail overflow button',
      );
      await tapOrFail(
        tester,
        find.byKey(const Key('community-detail-history')),
        'the History entry in the overflow sheet',
      );
      await waitFor(
        tester,
        find.byKey(const Key('topo-history-sheet')),
        'the version-history sheet',
      );
      await settleNetwork(tester, budget: const Duration(seconds: 8));
      await binding.takeScreenshot('12-topo-history');

      // `topo_version_list` is a SECURITY DEFINER RPC. An error state here is
      // a real finding (RLS, a missing grant, a schema drift) — an empty list
      // is not, since a freshly seeded topo may have no snapshot yet.
      expect(
        find.byKey(const Key('topo-history-error')),
        findsNothing,
        reason: 'topo_version_list errored for a real session — the history '
            'RPC is not answering under live RLS',
      );
    },
    skip: !e2eRealSessionRequested,
  );
}
