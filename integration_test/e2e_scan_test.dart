// The cross-machine half of the rock-scan feature, driven headless in Chrome.
//
// Every other test of this feature verifies ONE side of a seam. The unit tests
// prove the Dart parser reads a PLY; the Python suite proves the worker writes
// one; `colmap_contract_test.dart` proves the two agree about a file captured
// from a real COLMAP run. None of them prove the thing the user actually has:
// a video uploaded from a phone, reconstructed on a machine in another
// country, and drawn on the screen — with the row travelling back through live
// RLS and the sync pull to get there.
//
// That is what this file is for, and it is why it lives apart from
// `e2e_signed_in_test.dart`:
//
//   * it depends on EXTERNAL state that the harness cannot create — a worker
//     that actually ran — so folding it into the standard suite would turn
//     "the Windows box is switched off" into a red regression run for changes
//     that have nothing to do with scans;
//   * and it must still ASSERT rather than skip when it does run, so it cannot
//     be an `if (tester.any(...))` branch bolted onto an existing test. The
//     skill's §6 is explicit about that failure mode: an assertion parked at
//     the end of a long test is never reached once anything earlier breaks,
//     and silently proves nothing.
//
// Run it on its own, AFTER a job has come back `ready`, and without re-seeding
// (`tool/e2e_seed.sh` resets first, which deletes the very row under test):
//
//   flutter drive --driver=test_driver/integration_test.dart \
//     --target=integration_test/e2e_scan_test.dart \
//     -d web-server --browser-name=chrome --driver-port=4444 --headless \
//     --no-web-resources-cdn --timeout=900 $(tool/e2e_accounts.sh env owner)
//
// WHAT IT CANNOT COVER, stated here so a green run is never over-read: the
// video that produced the cloud was enqueued by `tool/rock_scan_e2e.sh`, not
// recorded through the app, because `image_picker` opens a native OS dialog
// that no integration test can drive on any platform. So the capture BUTTON's
// upload path is exercised by unit tests only; everything downstream of the
// uploaded bytes — the queue, the worker, the write-back, the pull, the
// download, the parse and the render — is exercised here for real.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:masi/app/router.dart' show appRouter;
import 'package:masi/main_e2e.dart' show e2eBoot, e2eRealSessionRequested;

import 'e2e_support.dart';

/// The fixture wall the scan hangs off.
///
/// Deliberately NOT `e2e-wall-draft-0001`: the standard signed-in suite
/// asserts that wall shows "No scans yet", so parking a scan there would make
/// the two suites contradict each other — and the one that broke would be the
/// one whose failure looks like a product bug.
const String kE2eScanWallId = 'e2e-wall-faces-0001';

/// The scan id `tool/rock_scan_e2e.sh` enqueues. Deterministic for the same
/// reason every other fixture id is: so this file can name the widget key.
const String kE2eScanId = 'e2e-scan-0001';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'signed-in: a scan a real worker reconstructed pulls down and renders',
    (tester) async {
      await e2eBoot();
      await settleNetwork(tester, budget: const Duration(seconds: 10));

      appRouter.go('/walls/$kE2eScanWallId/scans');
      await settle(tester, frames: 40);
      await waitFor(
        tester,
        find.byKey(const Key('scan-capture-button')),
        'the 3D scans screen (deferred library never finished loading?)',
      );

      // Nothing on this device created this row. It exists because a worker
      // claimed a job and wrote to Postgres, so the ONLY way it can appear
      // here is a real pull through RLS — which is most of what this test is
      // for. The budget is generous because a cold sign-in pulls every table.
      await waitFor(
        tester,
        find.byKey(const Key('scan-tile-$kE2eScanId')),
        'the reconstructed scan to arrive through the sync pull',
        timeout: const Duration(seconds: 90),
      );
      await binding.takeScreenshot('30-wall-scans-ready');

      expect(
        find.text('3D model ready'),
        findsOneWidget,
        reason:
            'the worker set status=ready, so the tile must say so — a scan '
            'stuck on "Building the 3D model" here means the pull brought '
            'the row but the client is reading the wrong column',
      );

      await tapOrFail(
        tester,
        find.byKey(const Key('scan-tile-$kE2eScanId')),
        'the ready scan tile',
      );

      // `scan-point-cloud` is mounted only when the bytes were downloaded from
      // Storage AND parsed into a cloud. Every other outcome — a 404, a
      // transport error, a PLY the parser cannot read — renders a _Message
      // instead, so this single key standing in for all of it is exactly the
      // assertion worth making.
      await waitFor(
        tester,
        find.byKey(const Key('scan-point-cloud')),
        'the reconstructed point cloud to download and parse',
        timeout: const Duration(seconds: 60),
      );
      await settleNetwork(tester, budget: const Duration(seconds: 3));
      await binding.takeScreenshot('31-scan-point-cloud');

      expect(
        find.textContaining('points'),
        findsWidgets,
        reason:
            'the header subtitle reports the manifest point count, so its '
            'absence means the worker wrote a cloud but no readable manifest',
      );
      expect(
        find.textContaining('Could not'),
        findsNothing,
        reason: 'no failure message may be on screen in the ready state',
      );
    },
    skip: !e2eRealSessionRequested,
  );
}
