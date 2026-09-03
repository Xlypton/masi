// RUN 1 of the chained photo-durability proof. Run 2 is
// `web_photo_offline_verify_test.dart`; the pair is driven by
//
//     tool/drive_web_photo_offline.sh
//
// Do not run this file on its own and read anything into a green tick — on
// its own it proves only that bytes went in, which is the easy half.
//
// -----------------------------------------------------------------------
// WHAT THIS PAIR EXISTS TO PROVE
// -----------------------------------------------------------------------
// "A topo without its photo is not a topo." Every other piece of the
// web-offline workstream has unit or widget coverage; the claim that a photo
// attached while offline is STILL THERE, as pixels, after the browser has
// been shut down and reopened, had none. `web_offline_persistence_test.dart`
// covers the drift rows and says so explicitly in its own header: a true
// reload-and-resume "needs a driver-level harness (CDP, or two chained
// `flutter drive` runs sharing one Chrome profile) that does not exist yet".
// This is that harness, and photo BYTES are what it carries.
//
// -----------------------------------------------------------------------
// WHY TWO PROCESSES INSTEAD OF A SECOND bootApp()
// -----------------------------------------------------------------------
// `integration_test` cannot press F5: the test isolate dies with the page.
// The in-page substitute — call `bootApp()` again, get a fresh
// `ProviderContainer` — leaves a great deal alive that a real restart would
// not: the wasm module, the JS heap, drift's SharedWorker hosting the sqlite
// image, and (decisive here) `PhotoImageCache.instance`, a process-wide map
// of key -> blob: URL. A photo could render after an in-page reboot purely
// from that cache, having never been read back from storage at all.
//
// So the restart is a real one: run 2 is a separate `flutter drive`, i.e. a
// separate Chrome PROCESS with a separate Dart isolate. The two runs share
// exactly two things, both on disk:
//
//   * `--web-port` is pinned, so both pages are the same ORIGIN and
//     therefore see the same IndexedDB databases; and
//   * `--user-data-dir` is pinned, so Chrome writes that origin's storage
//     into one profile directory that outlives the first browser.
//
// That is strictly stronger than F5: cold JS heap, cold wasm, cold worker,
// cold image cache. Nothing but bytes on disk crosses the gap.
//
// -----------------------------------------------------------------------
// WHAT "OFFLINE" MEANS HERE — AND HOW IT IS ENFORCED, NOT ASSUMED
// -----------------------------------------------------------------------
// Chrome is launched with `--proxy-server=127.0.0.1:1` — a proxy that does
// not exist. Chrome bypasses the proxy for loopback, so the app's own origin
// keeps working while every other request fails at connect, before a name is
// even resolved. This is a real severance at the network stack, not a
// `connectivityServiceProvider` override that merely tells the app it is
// offline. The test then PROVES it by issuing real GETs — including one at
// this app's actual Supabase host — and asserting they fail. Drop the flag
// and these assertions fail, rather than silently passing on a machine that
// happens to have wifi.
//
// (The obvious `--host-resolver-rules=MAP * ~NOTFOUND,EXCLUDE localhost`
// cannot be used: `flutter drive --web-browser-flag` splits its value on
// commas. See `tool/drive_web_photo_offline.sh` for the full measurement.)
//
// -----------------------------------------------------------------------
// THE PICKER
// -----------------------------------------------------------------------
// The photo is attached through `LibraryCrudRepository.attachPhotoToWall`,
// the exact call both UI paths make (`ToposScreen._handleNewTopo:569`,
// `TopoCanvasScreen._attachPhotoAndLoad:676`). What is skipped is only
// `image_picker`'s OS dialog, which `integration_test` cannot tap and which
// the router-built screens do not expose an injection seam for (their
// `photoSourcePicker`/`photoPicker` params are widget fields, and
// `router.dart:328` passes neither). Everything downstream of the picker —
// `PhotoFiles.importPhoto`, the browser thumbnail via `OffscreenCanvas`,
// `IdbPhotoByteStore`, the `Photos` row, the canvas render — is the real
// production path, unmocked. `web_photo_write_failure_test.dart` covers the
// UI half by pumping the screens directly.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
// XFile is re-exported here; `cross_file` itself is not a direct dependency.
import 'package:image_picker/image_picker.dart' show XFile;
import 'package:integration_test/integration_test.dart';
import 'package:masi/app/app.dart' show MasiApp;
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/core/db/storage_durability_provider.dart';
import 'package:masi/features/account/application/auth_providers.dart';
import 'package:masi/features/library/application/library_providers.dart';
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

  testWidgets('seeds a photo into browser storage with the network severed', (
    tester,
  ) async {
    expect(
      kRunStamp,
      isNot('unstamped'),
      reason: 'run this through tool/drive_web_photo_offline.sh — without '
          '--dart-define=MASI_PHOTO_RUN the two halves cannot agree on which '
          'rows they are talking about, and run 2 could pass on leftovers',
    );
    record({'run_stamp': kRunStamp, 'wall_name': wallName});

    // A progress marker before anything can block. `reportData` is only
    // written when the run ENDS, so a hang leaves no report at all — the
    // screenshots are the only externally visible trace of how far this got,
    // and which of them exist localises a stall to a specific step.
    await binding.takeScreenshot('photo-00-seed-start');

    // ---------------------------------------------------------------
    // 1. The network really is gone. Asserted before anything is written,
    //    so nothing below can be explained by a server round trip.
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
        reason: 'THE OFFLINE PRECONDITION FAILED: the browser reached '
            '${probe.url} (${probe.detail}). Chrome was supposed to be '
            'launched with --proxy-server=127.0.0.1:1. Everything this file '
            'asserts about local durability would be unfalsifiable with a '
            'live network.',
      );
    }

    // ---------------------------------------------------------------
    // 2. Boot. `bootApp` is bounded at kBootFirstFrameDeadline (8s) even
    //    when Supabase.initialize cannot resolve its host, so a severed
    //    network delays the first frame but cannot prevent it.
    // ---------------------------------------------------------------
    unawaited(
      bootApp(overrides: [webAuthGateEnabledProvider.overrideWithValue(false)]),
    );
    await tester.pumpAndSettle(const Duration(seconds: 2));
    final booted = await pumpUntil(
      tester,
      () => tester.any(find.byKey(const Key('topos-organize'))),
      timeout: const Duration(seconds: 90),
    );
    expect(booted, isTrue, reason: 'the app never reached Topos home');
    await binding.takeScreenshot('photo-01-seed-booted-offline');

    final container = currentContainer(tester);

    // ---------------------------------------------------------------
    // 3. Storage must be durable, or "the bytes came back" means nothing.
    //    `WasmDatabase.open` never throws — it silently returns `inMemory`,
    //    which stores nothing and would still satisfy every read below
    //    inside a single process.
    // ---------------------------------------------------------------
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
    expect(verdictArrived, isTrue, reason: 'storage verdict never arrived');
    expect(
      verdict.backend,
      isNot(StorageBackend.inMemory),
      reason: 'drift fell back to a backend that stores NOTHING; '
          'missingFeatures: ${verdict.missingFeatures}',
    );
    expect(verdict.isDurable, isTrue, reason: 'verdict was $verdict');

    final signedIn =
        container.read(authStateProvider).asData?.value.isSignedIn ?? false;
    record({'signed_in': signedIn});
    expect(
      signedIn,
      isFalse,
      reason: 'a live session would let the cloud, not browser storage, '
          'explain anything that survives',
    );

    // ---------------------------------------------------------------
    // 4. Attach the photo. Real bytes, real repository, real web
    //    PhotoFiles -> real IdbPhotoByteStore -> real IndexedDB.
    // ---------------------------------------------------------------
    final bytes = buildPhotoBytes();
    final expectedHash = fnv1a64(bytes);
    record({'photo_len': bytes.length, 'photo_hash': expectedHash});
    expect(
      bytes.length,
      greaterThan(4096),
      reason: 'the fixture must be a real JPEG of real size, not a stub — '
          'a few hundred bytes would not exercise the thumbnail path or '
          'prove anything about storing a photo',
    );

    final repo = container.read(libraryCrudRepositoryProvider);
    final wallId = await repo.createTopo(wallName);
    final photoId = await repo.attachPhotoToWall(
      wallId,
      XFile.fromData(bytes, name: photoFileName, mimeType: 'image/jpeg'),
      900,
      600,
    );
    record({'wall_id': wallId, 'photo_id': photoId});

    // The `Photos` row, and the key its bytes live under.
    final photoRepo = container.read(photoRepositoryProvider);
    final ref = await photoRepo.loadOriginal(wallId);
    expect(ref, isNotNull, reason: 'no Photos row after attachPhotoToWall');
    record({'photo_key': ref!.localPath});

    // Read the bytes straight back out of IndexedDB, in-process. This is
    // the weak half — it is the same page that wrote them — but if it fails
    // there is no point continuing to run 2.
    final readBack = await container
        .read(photoFilesProvider)
        .readPhotoBytes(ref.localPath);
    expect(readBack, isNotNull, reason: 'bytes were not readable at all');
    expect(readBack!.length, bytes.length);
    expect(
      fnv1a64(readBack),
      expectedHash,
      reason: 'the bytes that came back differ from the bytes written, '
          'in the very same page',
    );

    // ---------------------------------------------------------------
    // 5. Pixels. Two shots, because these are the two places a user sees
    //    their photo, and run 2 takes the identical pair for comparison.
    // ---------------------------------------------------------------
    final onHome = await pumpUntil(tester, () => tester.any(find.text(wallName)));
    expect(onHome, isTrue, reason: '"$wallName" never appeared on Topos home');
    await tester.pumpAndSettle(const Duration(seconds: 2));
    await binding.takeScreenshot('photo-02-seed-home-thumbnail');

    GoRouter.of(
      tester.element(find.byType(Scaffold).first),
    ).go('/walls/$wallId');
    await tester.pumpAndSettle(const Duration(seconds: 2));
    // Wait out `topo-image-loading` — the canvas shows a spinner until the
    // `Photos` row resolves the persisted width/height.
    await pumpUntil(
      tester,
      () => !tester.any(find.byKey(const Key('topo-image-loading'))),
      timeout: const Duration(seconds: 30),
    );
    await tester.pumpAndSettle(const Duration(seconds: 2));
    expect(
      find.byKey(const Key('topo-empty-state')),
      findsNothing,
      reason: 'the canvas is showing "No photo yet" for a wall that has one',
    );
    await binding.takeScreenshot('photo-03-seed-canvas');

    // ---------------------------------------------------------------
    // 6. Let the writes actually reach disk before this browser dies.
    //
    //    The two halves of a photo persist on very different schedules. The
    //    PIXELS go straight into the `climbtopo-photos` IndexedDB through
    //    `IdbPhotoByteStore`, committed by the time `writeBytes` returns.
    //    The `Photos` ROW goes into drift's sqlite image, which the
    //    `sharedIndexedDb` backend hosts in a SharedWorker and persists to
    //    IndexedDB LAZILY — so a row is readable in-process long before it
    //    is durable.
    //
    //    `flutter drive` kills Chrome the instant this test returns, which
    //    is harsher than anything a user does: even closing a tab fires
    //    pagehide first. Without this pause the run measured exactly that
    //    artefact — the Wall row (written seconds earlier) survived while the
    //    Photos row (written last) did not, and the topo came back on the
    //    home screen with a blank canvas.
    //
    //    So: hold the page open, pumping real frames, long enough for the
    //    flush. This models "the climber took the photo, then some seconds
    //    passed, then the browser went away", which is the realistic case.
    //    It is NOT a way of making the assertion easier — run 2 still has to
    //    find both the pixels and the row, and the window is deliberately
    //    stated here rather than hidden in a sleep.
    final settleDeadline = DateTime.now().add(
      const Duration(seconds: kSettleSeconds),
    );
    while (DateTime.now().isBefore(settleDeadline)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    record({'settle_seconds': kSettleSeconds, 'seed_complete': true});
  });
}
