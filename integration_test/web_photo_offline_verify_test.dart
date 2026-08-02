// RUN 2 of the chained photo-durability proof — the half that matters.
//
// Driven by `tool/drive_web_photo_offline.sh`, which runs
// `web_photo_offline_seed_test.dart` first and then this file in a SEPARATE
// `flutter drive` invocation: a new Chrome process, a new page, a new Dart
// isolate, a new wasm module, a cold `PhotoImageCache`. See run 1's header
// for why that is stronger than an F5 and why an in-page second `bootApp()`
// would not do.
//
// The only things that cross the gap:
//   * the pinned `--web-port` (same origin) and pinned `--user-data-dir`
//     (same Chrome profile on disk) — i.e. the browser's own storage; and
//   * four `--dart-define`s the script reads out of run 1's
//     `build/integration_response_data.json`: the run stamp, the wall id,
//     the photo's IndexedDB key, and its length + FNV-1a/64 digest.
//
// The digests are threaded through rather than recomputed from the fixture
// so that this file compares against WHAT RUN 1 ACTUALLY WROTE, not against
// what a re-run of the generator thinks it should have written. A truncated,
// zero-filled or re-encoded read fails.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:masi/app/app.dart' show MasiApp;
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/core/db/storage_durability_provider.dart';
import 'package:masi/features/account/application/auth_providers.dart';
import 'package:masi/features/topo/data/photo_repository.dart' show PhotoRef;
import 'package:masi/main.dart' show bootApp;

import 'web_photo_offline_fixture.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final observed = <String, Object?>{};
  void record(Map<String, Object?> entries) {
    observed.addAll(entries);
    binding.reportData = Map<String, Object?>.from(observed);
  }

  ProviderContainer currentContainer(WidgetTester tester) =>
      ProviderScope.containerOf(
        tester.element(find.byType(MasiApp)),
        listen: false,
      );

  testWidgets(
    'THE CLAIM: a photo attached offline is still there — as bytes and as '
    'pixels — in a brand-new browser process with the network still severed',
    (tester) async {
      expect(
        kRunStamp,
        isNot('unstamped'),
        reason: 'run this through tool/drive_web_photo_offline.sh',
      );
      expect(
        kExpectedWallId,
        isNotEmpty,
        reason: 'MASI_PHOTO_WALL was not threaded through from run 1, so '
            'this run has no row to look for. The script reads it from '
            'build/integration_response_data.json — if that file was missing '
            'or unparsable, run 1 did not really succeed.',
      );
      expect(kExpectedPhotoKey, isNotEmpty, reason: 'MASI_PHOTO_KEY missing');
      expect(kExpectedPhotoLen, isNotEmpty, reason: 'MASI_PHOTO_LEN missing');
      expect(kExpectedPhotoHash, isNotEmpty, reason: 'MASI_PHOTO_HASH missing');
      final expectedLen = int.parse(kExpectedPhotoLen);
      record({
        'run_stamp': kRunStamp,
        'expected_wall_id': kExpectedWallId,
        'expected_photo_key': kExpectedPhotoKey,
        'expected_photo_len': expectedLen,
        'expected_photo_hash': kExpectedPhotoHash,
      });

      // A progress marker before anything can block. `reportData` is only
      // written when the run ENDS, so a hang leaves no report at all and the
      // screenshots are the only externally visible trace of how far this
      // got. Its ABSENCE means the test body never ran — which is a browser
      // or harness problem (page never executed `main()`), not a storage one.
      await binding.takeScreenshot('photo-04a-verify-start');

      // ---------------------------------------------------------------
      // 1. Still offline. Re-asserted in THIS process — run 1's severance
      //    says nothing about this browser.
      // ---------------------------------------------------------------
      final probes = <NetworkProbe>[];
      for (final url in kExternalProbeUrls) {
        probes.add(await probeExternal(url));
      }
      record({'network_probes': probes.map((p) => p.toJson()).toList()});
      for (final probe in probes) {
        expect(
          probe.reachable,
          isFalse,
          reason: 'the browser reached ${probe.url} (${probe.detail}) — with '
              'a live network, "the photo is still here" could be explained '
              'by a download rather than by local storage',
        );
      }

      // ---------------------------------------------------------------
      // 2. Cold boot.
      // ---------------------------------------------------------------
      unawaited(
        bootApp(
          overrides: [webAuthGateEnabledProvider.overrideWithValue(false)],
        ),
      );
      await tester.pumpAndSettle(const Duration(seconds: 2));
      final booted = await pumpUntil(
        tester,
        () => tester.any(find.byKey(const Key('topos-organize'))),
        timeout: const Duration(seconds: 90),
      );
      expect(booted, isTrue, reason: 'the app did not come back up');

      final container = currentContainer(tester);
      final verdictArrived = await pumpUntil(
        tester,
        () => !container.read(storageDurabilityProvider).isProbing,
        timeout: const Duration(seconds: 60),
      );
      final verdict = container.read(storageDurabilityProvider);
      record({
        'storage_verdict_arrived': verdictArrived,
        'storage_backend': verdict.backend?.name,
        'storage_is_durable': verdict.isDurable,
      });
      expect(verdictArrived, isTrue);
      expect(verdict.backend, isNot(StorageBackend.inMemory));

      final signedIn =
          container.read(authStateProvider).asData?.value.isSignedIn ?? false;
      record({'signed_in': signedIn});
      expect(
        signedIn,
        isFalse,
        reason: 'nothing here may be explained by a cloud session',
      );

      // ---------------------------------------------------------------
      // 3. THE FIRST THING THE USER SEES. Nothing has been tapped yet;
      //    this is the rebooted app's own home screen, and the topo's row
      //    carries a thumbnail read back out of IndexedDB.
      // ---------------------------------------------------------------
      final topoOnHome = await pumpUntil(
        tester,
        () => tester.any(find.text(wallName)),
        timeout: const Duration(seconds: 60),
      );
      expect(
        topoOnHome,
        isTrue,
        reason: 'the rebooted Topos home does not list "$wallName" — the '
            'topo recorded in run 1 is gone. This is the headline promise '
            'failing.',
      );
      await tester.pumpAndSettle(const Duration(seconds: 3));
      await binding.takeScreenshot('photo-04-verify-home-thumbnail');

      // ---------------------------------------------------------------
      // 4. THE BYTES — probed FIRST, and by key, deliberately.
      //
      //    A photo lives in two independent places: the pixels in the
      //    `climbtopo-photos` IndexedDB (written directly by
      //    `IdbPhotoByteStore`), and the `Photos` row in the drift `climbtopo`
      //    database (a sqlite image that drift persists to IndexedDB lazily).
      //    Either can be lost without the other, and the two failures mean
      //    very different things — so read the pixels using the key run 1
      //    reported, WITHOUT going through the row. Going via the row first
      //    would make a lost row indistinguishable from lost pixels.
      //
      //    `PhotoImageCache` is process-wide in-memory state and this process
      //    has never run before, so this read cannot be served from a cache:
      //    it reaches IndexedDB or it fails.
      // ---------------------------------------------------------------
      final photoFiles = container.read(photoFilesProvider);
      final bytes = await photoFiles.readPhotoBytes(kExpectedPhotoKey);
      record({
        'bytes_after_restart': bytes?.length,
        'bytes_hash_after_restart': bytes == null ? null : fnv1a64(bytes),
      });
      expect(
        bytes,
        isNotNull,
        reason: 'THE PIXELS ARE GONE: nothing is stored under '
            '"$kExpectedPhotoKey" in this browser. The photo bytes did not '
            'survive the restart.',
      );
      expect(
        bytes!.length,
        expectedLen,
        reason: 'the photo came back a different size than it went in',
      );
      expect(
        fnv1a64(bytes),
        kExpectedPhotoHash,
        reason: 'the photo came back CORRUPTED — same length, different '
            'content',
      );

      // ---------------------------------------------------------------
      // 5. THE ROW. Pixels with no row are just as unreachable to a user as
      //    no pixels: the canvas renders from the row's width/height.
      // ---------------------------------------------------------------
      //    Polled rather than read once. A single null could always be
      //    dismissed as "the query ran before the database finished opening";
      //    30 seconds of retries cannot. (When this last ran for real it
      //    returned null on the first try and stayed null, and the rendered
      //    home screen agreed — its thumbnail, driven by an independent
      //    stream over the same table, was an empty placeholder.)
      final photoRepo = container.read(photoRepositoryProvider);
      PhotoRef? ref;
      final rowDeadline = DateTime.now().add(const Duration(seconds: 30));
      var rowAttempts = 0;
      while (DateTime.now().isBefore(rowDeadline)) {
        rowAttempts++;
        ref = await photoRepo.loadOriginal(kExpectedWallId);
        if (ref != null) break;
        await tester.pump(const Duration(milliseconds: 500));
      }
      record({
        'photo_row_after_restart': ref?.localPath,
        'photo_row_attempts': rowAttempts,
      });
      expect(
        ref,
        isNotNull,
        reason: 'the pixels survived but the Photos row for wall '
            '$kExpectedWallId did not — the drift database lost it while '
            'keeping the Wall row that was written moments earlier. The topo '
            'is listed on the home screen and opens to a blank canvas.',
      );
      expect(
        ref!.localPath,
        kExpectedPhotoKey,
        reason: 'the row survived but points at a different key than run 1 '
            'wrote',
      );

      // ---------------------------------------------------------------
      // 6. Pixels on the canvas.
      //
      //    Note what a failure looks like: `topo_canvas.dart:1019` passes
      //    `placeholder: () => const SizedBox.shrink()`, so a photo whose
      //    bytes are gone renders as NOTHING — a flat ground-coloured
      //    canvas under the normal chrome, with no spinner and no error.
      //    A widget-finder cannot tell that apart from success, which is
      //    exactly why this pair ends by taking a screenshot to be looked
      //    at. The fixture is built to be unmistakable when it does render:
      //    saturated corner blocks and the run stamp drawn across the
      //    middle in 48px type.
      // ---------------------------------------------------------------
      GoRouter.of(
        tester.element(find.byType(Scaffold).first),
      ).go('/walls/$kExpectedWallId');
      await tester.pumpAndSettle(const Duration(seconds: 2));
      await pumpUntil(
        tester,
        () => !tester.any(find.byKey(const Key('topo-image-loading'))),
        timeout: const Duration(seconds: 30),
      );
      await tester.pumpAndSettle(const Duration(seconds: 3));
      expect(
        find.byKey(const Key('topo-empty-state')),
        findsNothing,
        reason: 'the canvas is showing "No photo yet — pick one to start" '
            'for a wall whose photo we just read out of IndexedDB',
      );
      await binding.takeScreenshot('photo-05-verify-canvas');

      record({'verify_complete': true});
    },
  );
}
