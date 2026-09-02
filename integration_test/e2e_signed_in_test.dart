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

/// The never-submitted, never-published fixture wall. Used by the
/// draw-into-a-selected-route test below because its routes may change freely
/// without disturbing anything else in the suite (nothing may ever submit or
/// publish this wall — see the skill's §6).
const String kE2eDraftWallId = 'e2e-wall-draft-0001';

/// The seeded route with a name, a grade, a number and NO line — what a
/// guidebook import leaves when it cannot read a polyline.
const String kE2eUnplacedRouteName = 'E2E Unplaced Line';

/// The four-photo fixture wall, and its first two faces. The only wall in the
/// fixture with more than one photo, so the only one on which "the same climb,
/// seen from over here" is a thing that can be said at all.
const String kE2eFacesWallId = 'e2e-wall-faces-0001';
const String kE2eFaceOnePhotoId = 'e2e-photo-face-0001';
const String kE2eFaceTwoPhotoId = 'e2e-photo-face-0002';
const String kE2eFaceThreePhotoId = 'e2e-photo-face-0003';

/// The one climb the fixture puts on that wall, on its FIRST face only.
const String kE2eFaceOneRouteName = 'E2E Face One Line';

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
      reason:
          'the auth wall redirected to the sign-in view — in REAL mode '
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
      reason:
          'the Area vanished from the list after navigating back — the '
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
      reason:
          'the feed reported a sync error after pullNow — check the '
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
        reason:
            'topo_version_list errored for a real session — the history '
            'RPC is not answering under live RLS',
      );
    },
    skip: !e2eRealSessionRequested,
  );

  testWidgets(
    'real session: a selected UNPLACED route takes the line that is drawn, '
    'instead of a new route appearing beside it',
    (tester) async {
      // The bug this guards: a guidebook import creates routes it could not
      // place (name, grade, number, empty points — "this route is yours to
      // draw"). Selecting one and drawing used to produce a SECOND,
      // separately-numbered route beside it, leaving the imported one empty
      // forever with no way at all to draw it.
      await e2eBoot();
      await settleNetwork(tester, budget: const Duration(seconds: 8));

      // The fixture is server-side until a pull imports it, and the canvas
      // reads its routes from the LOCAL database. Force the pull first.
      appRouter.go('/feed');
      await settle(tester, frames: 30);
      await pullToRefresh(
        tester,
        find.byKey(const Key('community-feed-refresh')),
        'the community feed refresh button',
      );
      await settleNetwork(tester, budget: const Duration(seconds: 12));

      // Straight to the wall by id rather than tapping down
      // Areas -> Sectors -> Walls: this test is about the canvas, and should
      // not be able to fail for a reason that belongs to those lists.
      appRouter.go('/walls/$kE2eDraftWallId');
      await settle(tester, frames: 30);
      await settleNetwork(tester, budget: const Duration(seconds: 12));
      await binding.takeScreenshot('13-draft-wall-canvas');

      // The unplaced route announces itself in the legend — it has no line on
      // the photo, so this row is the ONLY way to reach it.
      await waitFor(
        tester,
        find.textContaining(kE2eUnplacedRouteName),
        'the seeded unplaced route in the topo legend — the canvas did not '
        'render its routes (did the pull import the draft wall and photo?)',
        timeout: const Duration(seconds: 60),
      );
      expect(
        find.textContaining('No line yet'),
        findsWidgets,
        reason:
            'the legend must say which routes still need drawing, or an '
            'imported route cannot be found at all',
      );

      await tapOrFail(
        tester,
        find.textContaining(kE2eUnplacedRouteName),
        'the unplaced route row in the legend',
      );
      await binding.takeScreenshot('14-unplaced-route-selected');

      await tapOrFail(
        tester,
        find.byKey(const Key('topo-mode-toggle')),
        'the draw-mode toggle',
      );

      await settle(tester, frames: 10);

      // Two taps on the photo make a line. The draw-mode gesture surface is
      // the thing that actually receives them, so its own box is what the
      // coordinates come from — no viewport size is assumed — and both points
      // sit well inside it, clear of the floating chrome.
      await waitFor(
        tester,
        find.byKey(const Key('topo-draw-gesture-detector')),
        'the draw-mode gesture surface — the mode toggle did not enter draw '
        'mode',
      );
      final canvas = tester.getRect(
        find.byKey(const Key('topo-draw-gesture-detector')),
      );
      await tester.tapAt(
        Offset(canvas.center.dx, canvas.top + canvas.height * 0.35),
      );
      await settle(tester, frames: 5);
      await tester.tapAt(
        Offset(canvas.center.dx, canvas.top + canvas.height * 0.55),
      );
      await settle(tester, frames: 5);
      await binding.takeScreenshot('15-line-drawn-for-selected-route');

      await tapOrFail(
        tester,
        find.byKey(const Key('topo-commit-button')),
        'the commit (save) button',
      );
      await settleNetwork(tester, budget: const Duration(seconds: 10));
      await binding.takeScreenshot('16-line-saved-to-selected-route');

      // The whole claim, in three assertions:
      expect(
        find.textContaining('Route 3'),
        findsNothing,
        reason:
            'a third, separately-numbered route appeared — the line was '
            'committed as a NEW route instead of onto the selected one, '
            'which is exactly the reported bug',
      );
      expect(
        find.textContaining(kE2eUnplacedRouteName),
        findsWidgets,
        reason:
            'the imported route lost its name — drawing its line must '
            'keep its identity, not replace it',
      );
      expect(
        find.textContaining('No line yet'),
        findsNothing,
        reason:
            'the route still reports no line, so the draft never landed '
            'on it',
      );
    },
    skip: !e2eRealSessionRequested,
  );

  testWidgets(
    'real session: a line drawn on a second face can be given to the climb '
    'that already lives on the first',
    (tester) async {
      // Two bugs in one flow, and they were each other's mirror image.
      //
      // A new line on a second face used to take the number of a climb on the
      // first — the next-number seed read the climbs visible on THIS photo —
      // so an unrelated climb silently became a second drawing of climb 1,
      // and the blank draft's null name and grade were folded onto it.
      //
      // And the thing that collision imitated could not be asked for. A climb
      // drawn on another face is not in this face's legend, so nothing here
      // could select it, and there was no way to say "that is climb 1, seen
      // from over here" at all.
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

      appRouter.go('/walls/$kE2eFacesWallId');
      await settle(tester, frames: 30);
      await settleNetwork(tester, budget: const Duration(seconds: 12));

      /// Opens the dock's route list, which is closed by default — the names
      /// this test asserts on live in there.
      Future<void> openDockBody() async {
        if (find.byKey(const Key('topo-dock-body')).evaluate().isNotEmpty) {
          return;
        }
        final toggle = find.byKey(const Key('topo-dock-routes-toggle'));
        if (toggle.evaluate().isEmpty) return;
        await tapOrFail(tester, toggle, 'the dock route-list toggle');
        await settle(tester, frames: 8);
      }

      await waitFor(
        tester,
        find.byKey(const Key('face-rail-tile-$kE2eFaceOnePhotoId')),
        'the four-photo wall\'s face rail — did the pull import it?',
        timeout: const Duration(seconds: 60),
      );
      await openDockBody();
      await waitFor(
        tester,
        find.textContaining(kE2eFaceOneRouteName),
        'the seeded climb on the first face',
        timeout: const Duration(seconds: 30),
      );
      await binding.takeScreenshot('17-climb-on-first-face');

      // ── Over to a face that has nothing on it.
      await tapOrFail(
        tester,
        find.byKey(const Key('face-rail-tile-$kE2eFaceTwoPhotoId')),
        'the second face in the dock rail',
      );
      await settleNetwork(tester, budget: const Duration(seconds: 10));
      expect(
        find.textContaining(kE2eFaceOneRouteName),
        findsNothing,
        reason:
            'the climb is drawn on the OTHER face — a legend listing it '
            'here would mean this test cannot tell the two faces apart',
      );

      // ── A line, drawn here.
      await tapOrFail(
        tester,
        find.byKey(const Key('topo-mode-toggle')),
        'the draw-mode toggle',
      );
      await settle(tester, frames: 10);
      await waitFor(
        tester,
        find.byKey(const Key('topo-draw-gesture-detector')),
        'the draw-mode gesture surface',
      );
      final canvas = tester.getRect(
        find.byKey(const Key('topo-draw-gesture-detector')),
      );
      await tester.tapAt(
        Offset(canvas.center.dx, canvas.top + canvas.height * 0.35),
      );
      await settle(tester, frames: 5);
      await tester.tapAt(
        Offset(canvas.center.dx, canvas.top + canvas.height * 0.6),
      );
      await settle(tester, frames: 5);
      await binding.takeScreenshot('18-line-on-second-face');

      // ── And it is that climb, seen from here.
      await tapOrFail(
        tester,
        find.byKey(const Key('topo-link-climb-button')),
        'the "this line is a climb I already have" control — it appears only '
        'while there is a line AND the wall has a climb that is not on this '
        'face, which is exactly this state',
      );
      await settle(tester, frames: 10);
      await tapOrFail(
        tester,
        find.byKey(const Key('topo-link-climb-1')),
        'climb 1 in the picker',
      );
      await settleNetwork(tester, budget: const Duration(seconds: 12));
      await openDockBody();
      await binding.takeScreenshot('19-second-face-linked');

      expect(
        find.textContaining(kE2eFaceOneRouteName),
        findsWidgets,
        reason:
            'the line landed as some other climb — the whole point is '
            'that this face now lists the SAME climb, with its own drawing',
      );
      expect(
        find.textContaining('Route 2'),
        findsNothing,
        reason: 'a second climb was invented — linking must spend no number',
      );

      // ── And the way BACK, for a line already saved as its own climb.
      //
      // The fixture's third face carries exactly that: an unnamed climb of
      // its own, which is what a contributor is left with when they answer
      // the save wrong. Every way of saying 'that is really climb 1' used to
      // happen BEFORE the save, so the row was simply stuck.
      await tapOrFail(
        tester,
        find.byKey(const Key('face-rail-tile-$kE2eFaceThreePhotoId')),
        'the third face in the dock rail',
      );
      await settleNetwork(tester, budget: const Duration(seconds: 10));
      await openDockBody();
      await waitFor(
        tester,
        find.textContaining('Route 2'),
        'the unnamed climb the fixture leaves on the third face',
        timeout: const Duration(seconds: 30),
      );
      await binding.takeScreenshot('20-stuck-climb-on-third-face');

      // Its row's menu is where somebody who has just READ the wrong name
      // already is.
      await tapOrFail(
        tester,
        find.byKey(const Key('topo-route-menu-1')),
        "the unnamed climb's row menu",
      );
      await settle(tester, frames: 10);
      await tapOrFail(
        tester,
        find.byKey(const Key('topo-route-same-climb-1')),
        'the "Same climb as…" action',
      );
      await settle(tester, frames: 10);
      await tapOrFail(
        tester,
        find.byKey(const Key('topo-same-climb-1')),
        'climb 1 in the picker',
      );
      await settle(tester, frames: 10);
      await tapOrFail(
        tester,
        find.byKey(const Key('topo-same-climb-confirm')),
        'the merge confirmation',
      );
      await settleNetwork(tester, budget: const Duration(seconds: 12));
      await openDockBody();
      await binding.takeScreenshot('21-stuck-climb-merged');

      expect(
        find.textContaining(kE2eFaceOneRouteName),
        findsWidgets,
        reason:
            'the third face has to show the climb it was merged into, '
            'under its real name',
      );
      expect(
        find.textContaining('Route 2'),
        findsNothing,
        reason: 'and the climb that was never its own stops being one',
      );
    },
    skip: !e2eRealSessionRequested,
  );
}
