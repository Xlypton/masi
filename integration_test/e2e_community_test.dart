// Cross-role community/moderation E2E — REAL Supabase session only.
//
//   tool/e2e_accounts.sh ensure && tool/e2e_seed.sh
//   tool/drive_e2e.sh community
//
// WHY THIS FILE EXISTS. Everything below is gated on `auth.uid()`: filing a
// report, filing a suggestion, the owner's inbox (`suggestions_for_me`),
// applying a suggestion (`resolve_suggestion`), the admin queue
// (`moderation_queue`), approving (`review_topo`), resolving a report
// (`resolve_report`). Under the fake identity every one of them answers 403 or
// 401, so none of it had ever been exercised outside unit tests with fake
// remotes. This is the file that runs them against the live policies.
//
// IT CROSSES OWNERSHIP BOUNDARIES IN ONE BUILD, via `e2eSignInAs` — a real
// gotrue sign-out/sign-in, so `effectiveUidProvider` genuinely changes and the
// local library re-scopes underneath the app exactly as it would for a user
// switching accounts. That is the only way a single run can be reader, owner
// and admin in turn; `--dart-define` is compile-time and would otherwise need
// three builds that could not share state.
//
// THE ONE DESTRUCTIVE-SAFETY RULE, and it is not optional:
//   The live admin queue contains THE USER'S REAL PENDING TOPOS. Every action
//   in the admin section below targets a key that names the seeded fixture's
//   wall id explicitly (`admin-queue-approve-<kE2ePendingWallId>`). Never tap
//   "the first row". Approving or rejecting a real row would be an
//   irreversible edit to somebody's actual data.
//
// WHAT IT CANNOT DRIVE, stated rather than faked: the photo picker is a native
// OS dialog, so no topo is ever CREATED here — the topo, its photo and its
// routes all come from `tool/e2e_seed.sh`, which inserts them server-side and
// approves one through the real `review_topo` RPC. The propose-line canvas is
// driven by tapping the rendered `TopoLineView`, which needs that seeded photo
// to exist.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:masi/app/router.dart' show appRouter;
import 'package:masi/main_e2e.dart'
    show
        e2eAdminEmail,
        e2eBoot,
        e2eOwnerEmail,
        e2eReaderEmail,
        e2eRealSessionRequested,
        e2eSignInAs;

import 'e2e_support.dart';

/// Fixture ids — must match `tool/e2e_common.sh`. Deterministic on purpose:
/// the admin-queue keys are per-wall, and naming the wall is what keeps this
/// suite from ever acting on a real pending topo.
const String kE2ePendingWallId = 'e2e-wall-pending-0001';
const String kE2ePublishedWallName = 'E2E Published Wall';

/// The name the reader suggests. Unique per run so the final assertion cannot
/// be satisfied by a leftover from an earlier run.
final String kSuggestedName =
    'E2E Renamed ${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';

/// Opens the seeded published topo's detail screen from the community feed,
/// forcing a live pull first. Shared by every role below, because all three
/// start from "see the owner's published topo".
Future<void> openSeededTopo(WidgetTester tester) async {
  appRouter.go('/feed');
  await settle(tester, frames: 30);
  await tapOrFail(
    tester,
    find.byKey(const Key('community-feed-refresh')),
    'the community feed refresh button',
  );
  await settleNetwork(tester, budget: const Duration(seconds: 12));
  await tapOrFail(
    tester,
    find.text(kE2ePublishedWallName),
    'the seeded published wall in the feed (run tool/e2e_seed.sh)',
    timeout: const Duration(seconds: 45),
  );
  await waitFor(
    tester,
    find.byKey(const Key('community-detail-header')),
    'the community topo detail screen',
  );
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Every test below carries `skip: !e2eRealSessionRequested` — a SKIP, not a
  // silent pass. `flutter_test`'s `skip` is a bool, so the reason lives here
  // and in each test's name: without `--dart-define=E2E_PASSWORD=…`
  // (`tool/e2e_accounts.sh env`) there is no JWT, every RPC below answers
  // 401/403, and a run that reported green would be reporting a lie.

  testWidgets(
    'reader: files a report, a metadata suggestion and a geometry suggestion',
    (tester) async {
      await e2eBoot();
      await settleNetwork(tester, budget: const Duration(seconds: 8));
      await e2eSignInAs(e2eReaderEmail);
      await settleNetwork(tester, budget: const Duration(seconds: 6));

      await openSeededTopo(tester);
      await binding.takeScreenshot('20-reader-topo-detail');

      // --- report (phase 6b) -------------------------------------------
      await tapOrFail(
        tester,
        find.byKey(const Key('community-detail-more-button')),
        'the topo detail overflow button',
      );
      await tapOrFail(
        tester,
        find.byKey(const Key('community-detail-report')),
        'the "Report this topo" overflow entry',
      );
      await waitFor(
        tester,
        find.byKey(const Key('report-reporter-sheet')),
        'the report sheet',
      );
      await tapOrFail(
        tester,
        find.byKey(const Key('report-reason-inaccurate')),
        'the "inaccurate" report reason',
      );
      await tester.enterText(
        find.byKey(const Key('report-body-field')),
        'E2E harness report — safe to dismiss.',
      );
      await settle(tester, frames: 10);
      await tapOrFail(
        tester,
        find.byKey(const Key('report-body-submit')),
        'the report submit button',
      );
      await settleNetwork(tester, budget: const Duration(seconds: 8));
      await binding.takeScreenshot('21-reader-reported');

      // --- metadata suggestion (phase 7a) ------------------------------
      await tapOrFail(
        tester,
        find.byKey(const Key('community-detail-more-button')),
        'the topo detail overflow button (2nd open)',
      );
      await tapOrFail(
        tester,
        find.byKey(const Key('community-detail-suggest')),
        'the "Suggest a fix" overflow entry',
      );
      await waitFor(
        tester,
        find.byKey(const Key('suggestion-field-sheet')),
        'the suggestion field sheet',
      );
      await tapOrFail(
        tester,
        find.byKey(const Key('suggestion-field-name')),
        'the "Topo name" suggestable field',
      );
      await tester.enterText(
        find.byKey(const Key('suggestion-value-field')),
        kSuggestedName,
      );
      await settle(tester, frames: 10);
      await tapOrFail(
        tester,
        find.byKey(const Key('suggestion-value-submit')),
        'the suggestion value submit button',
      );
      await tester.enterText(
        find.byKey(const Key('suggestion-note-field')),
        'E2E harness suggestion.',
      );
      await settle(tester, frames: 10);
      await tapOrFail(
        tester,
        find.byKey(const Key('suggestion-note-submit')),
        'the suggestion note submit button',
      );
      await settleNetwork(tester, budget: const Duration(seconds: 8));
      await binding.takeScreenshot('22-reader-suggested-name');

      // --- geometry suggestion (phase 7b) ------------------------------
      await tapOrFail(
        tester,
        find.byKey(const Key('community-detail-more-button')),
        'the topo detail overflow button (3rd open)',
      );
      await tapOrFail(
        tester,
        find.byKey(const Key('community-detail-suggest-line')),
        'the "Suggest a line" overflow entry',
      );
      // The canvas resolves from the LOCAL database (`topoGeometryProvider`
      // reads photos + routes), so this is also the assertion that the pull
      // imported the seeded photo — a missing photo renders
      // `propose-line-no-photo` instead.
      await waitFor(
        tester,
        find.byKey(const Key('propose-line-canvas')),
        'the propose-line canvas — if `propose-line-no-photo` is showing '
        'instead, the seeded photo did not reach the local database',
        timeout: const Duration(seconds: 40),
      );
      await tapOrFail(
        tester,
        find.byKey(const Key('propose-line-target-1')),
        'the "Fix line 1" target chip',
      );

      // Two taps is the server-enforced minimum for a line
      // (`geometry_patch_error`: "a line needs at least two points"), and the
      // Send button stays disabled until there are two.
      final canvas = tester.getRect(
        find.byKey(const Key('propose-line-canvas')),
      );
      await tester.tapAt(
        Offset(canvas.center.dx, canvas.top + canvas.height * 0.75),
      );
      await settle(tester, frames: 10);
      await tester.tapAt(
        Offset(canvas.center.dx, canvas.top + canvas.height * 0.25),
      );
      await settle(tester, frames: 10);
      await tester.enterText(
        find.byKey(const Key('propose-line-note-field')),
        'E2E harness line.',
      );
      await settle(tester, frames: 10);
      await binding.takeScreenshot('23-reader-proposed-line');
      await tapOrFail(
        tester,
        find.byKey(const Key('propose-line-send')),
        'the propose-line send button — still disabled means the two canvas '
        'taps did not register as points',
      );
      await settleNetwork(tester, budget: const Duration(seconds: 8));
      await binding.takeScreenshot('24-reader-line-sent');
    },
    skip: !e2eRealSessionRequested,
    timeout: const Timeout(Duration(minutes: 6)),
  );

  testWidgets(
    'owner: the inbox renders both suggestions, and applying the metadata one '
    'renames the topo',
    (tester) async {
      await e2eBoot();
      await settleNetwork(tester, budget: const Duration(seconds: 8));
      await e2eSignInAs(e2eOwnerEmail);
      await settleNetwork(tester, budget: const Duration(seconds: 6));

      appRouter.go('/suggestions');
      await settle(tester, frames: 30);
      await waitFor(
        tester,
        find.byKey(const Key('suggestions-inbox-screen')),
        'the suggestions inbox',
      );
      await settleNetwork(tester, budget: const Duration(seconds: 10));
      await binding.takeScreenshot('25-owner-suggestions-inbox');

      // `suggestions_for_me` is owner-scoped SERVER-side. Anything here at all
      // proves the reader's writes landed and the RPC returned them to the
      // right person.
      final rows = keysWithPrefix(tester, 'suggestion-row-');
      expect(
        rows.length,
        greaterThanOrEqualTo(2),
        reason: 'expected the reader\'s metadata AND geometry suggestions in '
            'the owner\'s inbox, found ${rows.length}: $rows',
      );

      // The phase-7b visual diff. Rendered only for a geometry suggestion, and
      // only when the local geometry it diffs against resolved.
      expect(
        keysWithPrefix(tester, 'suggestion-diff-'),
        isNotEmpty,
        reason: 'the geometry suggestion rendered no visual diff — check for '
            'suggestion-diff-missing-* / suggestion-diff-error-*',
      );
      expect(
        keysWithPrefix(tester, 'suggestion-geometry-summary-'),
        isNotEmpty,
        reason: 'no geometry summary line on the geometry suggestion',
      );

      // --- accept the GEOMETRY one -------------------------------------
      final geometryId = firstIdWithPrefix(
        tester,
        'suggestion-geometry-summary-',
      )!;
      await tapOrFail(
        tester,
        find.byKey(Key('suggestion-accept-$geometryId')),
        'the accept button on the geometry suggestion',
      );
      await settleNetwork(tester, budget: const Duration(seconds: 10));
      await binding.takeScreenshot('26-owner-accepted-geometry');
      expect(
        keysWithPrefix(tester, 'suggestion-row-'),
        isNot(contains('suggestion-row-$geometryId')),
        reason: 'the geometry suggestion is still in the inbox after Apply — '
            'resolve_suggestion did not accept it',
      );

      // --- accept the METADATA one, and prove the topo actually changed ---
      // This is the end-to-end claim: a value typed by ANOTHER account, stored
      // server-side, applied by the owner, is then visible on the topo. An
      // inbox row disappearing would only prove the RPC returned 200.
      final remaining = keysWithPrefix(tester, 'suggestion-accept-');
      expect(
        remaining,
        isNotEmpty,
        reason: 'the metadata suggestion vanished along with the geometry one',
      );
      await tapOrFail(
        tester,
        find.byKey(Key(remaining.first)),
        'the accept button on the metadata suggestion',
      );
      await settleNetwork(tester, budget: const Duration(seconds: 10));
      await binding.takeScreenshot('27-owner-accepted-metadata');

      appRouter.go('/feed');
      await settle(tester, frames: 30);
      await tapOrFail(
        tester,
        find.byKey(const Key('community-feed-refresh')),
        'the community feed refresh button',
      );
      await waitFor(
        tester,
        find.text(kSuggestedName),
        'the topo renamed to "$kSuggestedName" — the accepted metadata patch '
        'did not reach the wall row (or the pull did not bring it back)',
        timeout: const Duration(seconds: 45),
      );
      await binding.takeScreenshot('28-owner-topo-renamed');
    },
    skip: !e2eRealSessionRequested,
    timeout: const Timeout(Duration(minutes: 6)),
  );

  testWidgets(
    'admin: the review queue and the reports tab answer, and the seeded '
    'pending topo can be approved',
    (tester) async {
      await e2eBoot();
      await settleNetwork(tester, budget: const Duration(seconds: 8));
      await e2eSignInAs(e2eAdminEmail);
      await settleNetwork(tester, budget: const Duration(seconds: 6));

      appRouter.go('/admin');
      await settle(tester, frames: 30);
      await waitFor(
        tester,
        find.byKey(const Key('admin-queue-screen')),
        'the admin queue screen',
      );
      await settleNetwork(tester, budget: const Duration(seconds: 10));
      await binding.takeScreenshot('30-admin-queue');

      // `is_admin()` is evaluated SERVER-side against `public.admins`. A
      // forbidden state here means the admin row is missing or the JWT is not
      // what the RPC sees.
      expect(
        find.byKey(const Key('admin-queue-forbidden')),
        findsNothing,
        reason: 'the admin queue reported forbidden for the E2E admin account '
            '— is_admin() is false server-side',
      );

      // ⚠ THE SEEDED WALL, BY ID. The queue also lists the user's REAL pending
      // topos; approving one of those would be an irreversible edit to their
      // data. Never relax this to "the first row".
      await waitFor(
        tester,
        find.byKey(const Key('admin-queue-row-$kE2ePendingWallId')),
        'the seeded pending wall in the review queue',
        timeout: const Duration(seconds: 30),
      );
      await tapOrFail(
        tester,
        find.byKey(const Key('admin-queue-approve-$kE2ePendingWallId')),
        'the approve button on the SEEDED pending wall',
      );
      await settleNetwork(tester, budget: const Duration(seconds: 10));
      await binding.takeScreenshot('31-admin-approved');
      expect(
        find.byKey(const Key('admin-queue-row-$kE2ePendingWallId')),
        findsNothing,
        reason: 'the seeded wall is still queued after approve — review_topo '
            'did not publish it',
      );

      // --- reports tab (phase 6b) --------------------------------------
      await tapOrFail(
        tester,
        find.byKey(const Key('admin-tab-reports')),
        'the Reports tab',
      );
      await settleNetwork(tester, budget: const Duration(seconds: 10));
      await binding.takeScreenshot('32-admin-reports');

      final reports = keysWithPrefix(tester, 'admin-report-row-');
      expect(
        reports,
        isNotEmpty,
        reason: "the reader's report is not in the admin reports tab — "
            'report_content wrote nothing, or moderation_reports did not '
            'return it',
      );

      // Dismiss it, so the harness leaves the queue as it found it. Dismiss
      // rather than uphold: upholding takes the topo down, which is a
      // moderation action the teardown would then have to undo.
      final reportId = reports.first.substring('admin-report-row-'.length);
      await tapOrFail(
        tester,
        find.byKey(Key('admin-report-dismiss-$reportId')),
        'the dismiss button on the E2E report',
      );
      await settleNetwork(tester, budget: const Duration(seconds: 10));
      await binding.takeScreenshot('33-admin-report-dismissed');
      expect(
        find.byKey(Key('admin-report-row-$reportId')),
        findsNothing,
        reason: 'the report is still open after Dismiss — resolve_report did '
            'not accept it',
      );
    },
    skip: !e2eRealSessionRequested,
    timeout: const Timeout(Duration(minutes: 6)),
  );

  // --- the admin-only read RPCs (C-5d, C-11) ------------------------------
  //
  // Its OWN test, depending on no fixture state, and that is the point. Every
  // other test in this file needs the seeded wall to have reached the client
  // feed first, so when that link is broken they all fail together and nothing
  // downstream of it is exercised at all — which is exactly what happened to an
  // earlier version of this check, buried at the end of the admin test behind
  // an assertion about the reader's report.
  //
  // What it proves that a widget test cannot: `material_changes` and
  // `abandoned_topos` are SECURITY DEFINER RPCs gated on `is_admin()` and newly
  // granted to `authenticated`. A missing GRANT, a wrong parameter name, or a
  // return shape the client cannot decode all look identical offline, and all
  // of them surface HERE as the tab's error state, because both providers are
  // deliberately not best-effort.
  //
  // It asserts the ABSENCE of the error rather than the presence of a row, and
  // that is the honest assertion: whether any topo has changed shape or gone
  // stale depends on the user's real data, so demanding a row would make this
  // pass or fail for reasons that have nothing to do with the code.
  testWidgets(
    'admin: the Changes and Stalled tabs answer from a real admin JWT',
    (tester) async {
      await e2eBoot();
      await settleNetwork(tester, budget: const Duration(seconds: 8));
      await e2eSignInAs(e2eAdminEmail);
      await settleNetwork(tester, budget: const Duration(seconds: 6));

      appRouter.go('/admin');
      await settle(tester, frames: 30);
      await waitFor(
        tester,
        find.byKey(const Key('admin-queue-screen')),
        'the admin queue screen',
      );
      expect(find.byKey(const Key('admin-queue-forbidden')), findsNothing);

      await tapOrFail(
        tester,
        find.byKey(const Key('admin-tab-changes')),
        'the Changes tab',
      );
      await settleNetwork(tester, budget: const Duration(seconds: 10));
      await binding.takeScreenshot('36-admin-changes');
      expect(
        find.textContaining("Couldn't load recent changes"),
        findsNothing,
        reason: 'material_changes() failed for a real admin JWT — the RPC is '
            'missing, not granted to authenticated, or is_admin() is false',
      );

      await tapOrFail(
        tester,
        find.byKey(const Key('admin-tab-abandoned')),
        'the Stalled tab',
      );
      await settleNetwork(tester, budget: const Duration(seconds: 10));
      await binding.takeScreenshot('37-admin-stalled');
      expect(
        find.textContaining("Couldn't load stalled topos"),
        findsNothing,
        reason: 'abandoned_topos() failed for a real admin JWT',
      );
    },
    skip: !e2eRealSessionRequested,
    timeout: const Timeout(Duration(minutes: 4)),
  );

  testWidgets(
    'owner: the trust standing is readable from a real session',
    (tester) async {
      await e2eBoot();
      await settleNetwork(tester, budget: const Duration(seconds: 8));
      await e2eSignInAs(e2eOwnerEmail);
      await settleNetwork(tester, budget: const Duration(seconds: 6));

      // NOTE — there is no trust READOUT on the Account screen. `myTrustProvider`
      // has exactly one consumer in the app (`topos_row.dart`), where it
      // switches the publish-confirm sheet between "Submit to Community?"
      // (untrusted, goes to the queue) and "Publish to Community?" (trusted,
      // goes straight live). So the observable surface for trust IS that sheet,
      // and that is what this asserts — going through the Account screen would
      // be asserting on something that does not exist.
      appRouter.go('/');
      await settle(tester, frames: 30);
      await settleNetwork(tester, budget: const Duration(seconds: 10));
      await binding.takeScreenshot('34-owner-library');

      final menus = keysWithPrefix(tester, 'topo-menu-');
      expect(
        menus,
        isNotEmpty,
        reason: 'the owner has no topos in the local library after a pull — '
            'the seeded fixture did not import',
      );
      await tapOrFail(
        tester,
        find.byKey(Key(menus.first)),
        'a topo overflow menu',
      );
      final wallId = menus.first.substring('topo-menu-'.length);
      await tapOrFail(
        tester,
        find.byKey(Key('topo-publish-$wallId')),
        'the publish/submit entry in the topo overflow menu',
      );
      await waitFor(
        tester,
        find.byKey(Key('topo-publish-confirm-$wallId')),
        'the publish confirmation sheet — this is where myTrustProvider '
        '(the `my_trust` RPC) is actually read',
      );
      await binding.takeScreenshot('35-owner-publish-confirm-trust');

      // A brand-new account is trust level 0, so the sheet must use the
      // "submit for review" wording. If this ever reads "Publish", the account
      // crossed the 3-approval threshold and the fixture needs rethinking.
      expect(
        find.textContaining('Submit'),
        findsWidgets,
        reason: 'the publish sheet did not use the untrusted wording — either '
            'my_trust answered a level >= 1, or it failed and the UI fell back',
      );
    },
    skip: !e2eRealSessionRequested,
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
