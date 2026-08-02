// RUN 1 of the WRITE-ORDER durability matrix. Run 2 is
// `web_write_order_verify_test.dart`; the pair is driven by
//
//     tool/drive_web_write_order.sh
//
// See `web_write_order_fixture.dart` for what this measures and why the
// photo pair could not measure it. In one sentence: the photo pair proved a
// row written LAST does not survive a browser restart, and could not say
// whether "last" or "photo" was the operative word. This writes a numbered
// sequence — wall, photo, then N routes — so run 2 can report the SHAPE of
// the loss instead of a single bit.
//
// The offline severance, the two-process restart and the shared Chrome
// profile all work exactly as in the photo pair; that machinery is described
// in `web_photo_offline_seed_test.dart`'s header and is not repeated here.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// XFile is re-exported here; `cross_file` itself is not a direct dependency.
import 'package:image_picker/image_picker.dart' show XFile;
import 'package:integration_test/integration_test.dart';
import 'package:masi/app/app.dart' show MasiApp;
import 'package:masi/core/db/app_database.dart' show AppDatabase;
import 'package:masi/core/db/connection/connection.dart' show openConnection;
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/core/db/storage_durability_provider.dart';
import 'package:masi/features/account/application/auth_providers.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/main.dart' show bootApp;
import 'package:web/web.dart' as web;

import 'web_photo_offline_fixture.dart'
    show
        NetworkProbe,
        buildPhotoBytes,
        kExternalProbeUrls,
        probeExternal,
        pumpUntil;
import 'web_write_order_fixture.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final observed = <String, Object?>{};
  void record(Map<String, Object?> entries) {
    observed.addAll(entries);
    binding.reportData = Map<String, Object?>.from(observed);
  }

  testWidgets('seeds wall -> photo -> N routes offline, in a known order', (
    tester,
  ) async {
    expect(
      kOrderRunStamp,
      isNot('unstamped'),
      reason: 'run this through tool/drive_web_write_order.sh',
    );
    record({
      'run_stamp': kOrderRunStamp,
      'wall_name': orderWallName,
      'route_count': kOrderRouteCount,
    });
    await binding.takeScreenshot('order-00-seed-start');

    // 1. The network really is gone, asserted before anything is written.
    final probes = <NetworkProbe>[];
    for (final url in kExternalProbeUrls) {
      probes.add(await probeExternal(url));
    }
    record({'network_probes': probes.map((p) => p.toJson()).toList()});
    for (final probe in probes) {
      expect(
        probe.reachable,
        isFalse,
        reason: 'the browser reached ${probe.url} (${probe.detail}) — with a '
            'live network nothing below is evidence about local durability',
      );
    }

    // 2. Boot.
    //
    //    `kOrderDisableCommitFlush` rebuilds `appDatabaseProvider` exactly as
    //    `database_provider.dart:39-47` does, with the single difference that
    //    matters: `flushAfterCommit: false`, i.e. the pre-fix behaviour. It
    //    is the only way to keep measuring the ORIGINAL loss on a tree that
    //    has already fixed it.
    unawaited(
      bootApp(
        overrides: [
          webAuthGateEnabledProvider.overrideWithValue(false),
          if (kOrderDisableCommitFlush)
            appDatabaseProvider.overrideWith((ref) {
              final storage = ref.read(storageDurabilityProvider.notifier);
              final db = AppDatabase(
                openConnection(
                  onStorageReport: (verdict) =>
                      Future<void>.microtask(() => storage.report(verdict)),
                ),
                flushAfterCommit: false,
              );
              ref.onDispose(() => db.close());
              return db;
            }),
        ],
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 2));
    final booted = await pumpUntil(
      tester,
      () => tester.any(find.byKey(const Key('topos-organize'))),
      timeout: const Duration(seconds: 90),
    );
    expect(booted, isTrue, reason: 'the app never reached Topos home');

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MasiApp)),
      listen: false,
    );

    // 3. Storage must be durable, or nothing below means anything:
    //    `WasmDatabase.open` degrades silently to `inMemory`, which stores
    //    nothing and would still satisfy every in-process read.
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
    expect(verdict.backend, isNot(StorageBackend.inMemory));
    expect(verdict.isDurable, isTrue, reason: 'verdict was $verdict');

    final signedIn =
        container.read(authStateProvider).asData?.value.isSignedIn ?? false;
    record({'signed_in': signedIn});
    expect(signedIn, isFalse, reason: 'no cloud may explain any of this');

    // ---------------------------------------------------------------
    // 4. THE SEQUENCE. Each step is a separate repository call — i.e. a
    //    separate drift transaction — and each is recorded as it completes,
    //    so a crash mid-sequence still tells run 2 how far run 1 got.
    // ---------------------------------------------------------------
    final crud = container.read(libraryCrudRepositoryProvider);
    final routeRepo = container.read(routeRepositoryProvider);
    final photoRepo = container.read(photoRepositoryProvider);

    // step 0: the wall.
    final wallId = await crud.createTopo(orderWallName);
    record({'wall_id': wallId});

    // step 1: the photo. Deliberately NOT last — see the fixture header.
    final photoId = await crud.attachPhotoToWall(
      wallId,
      XFile.fromData(
        buildPhotoBytes(),
        name: orderPhotoFileName,
        mimeType: 'image/jpeg',
      ),
      900,
      600,
    );
    record({'photo_id': photoId});

    // steps 2..N+1: the routes, one call each, exactly as the drawing UI
    // saves them.
    final written = <int>[];
    for (var number = 1; number <= kOrderRouteCount; number++) {
      await routeRepo.upsertRoute(wallId, photoId, buildOrderRoute(number));
      written.add(number);
      record({'routes_written': List<int>.from(written)});
      // A frame between writes, so this is a sequence of separate turns of
      // the event loop rather than one uninterrupted microtask burst.
      await tester.pump(const Duration(milliseconds: 50));
    }

    // step N+2: THE TAIL — one more topo, i.e. one more drift
    // `transaction(...)`, written after every auto-commit route insert. See
    // `orderTailWallName` for why this specific shape is the discriminator.
    final tailWallId = await crud.createTopo(orderTailWallName);
    record({'tail_wall_id': tailWallId});

    // 5. Everything is readable IN THIS PAGE. This is the weak half — same
    //    process, possibly the same cache — but if it fails there is no
    //    point running run 2 at all, and its failure means a bug in this
    //    test rather than a durability finding.
    final ref = await photoRepo.loadOriginal(wallId);
    expect(ref, isNotNull, reason: 'no Photos row right after the attach');
    final routesNow = await routeRepo.loadRoutes(wallId, photoId);
    expect(
      routesNow.map((r) => r.name).toSet(),
      {for (var n = 1; n <= kOrderRouteCount; n++) orderRouteName(n)},
      reason: 'the routes are not all readable in the page that wrote them',
    );
    record({'routes_readable_in_page': routesNow.length});

    await tester.pumpAndSettle(const Duration(seconds: 2));
    await binding.takeScreenshot('order-01-seed-written');

    // 6. Hold the page open before `flutter drive` kills the browser. Same
    //    knob and same rationale as the photo pair's `kSettleSeconds`: it
    //    makes the flush window an axis of the experiment rather than a
    //    hidden constant.
    final deadline = DateTime.now().add(
      Duration(seconds: kOrderSettleSeconds),
    );
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    record({
      'settle_seconds': kOrderSettleSeconds,
      'teardown': kOrderTeardown,
      'commit_flush_disabled': kOrderDisableCommitFlush,
      'seed_complete': true,
    });

    // ---------------------------------------------------------------
    // 7. THE TEARDOWN. See `kOrderTeardown`.
    //
    //    In `unload` mode this is the last line that ever runs in this
    //    isolate: `location.replace` destroys the document — firing
    //    `pagehide` and `unload`, exactly as closing the tab does — and the
    //    Dart isolate goes with it. The pump loop below never completes and
    //    `flutter drive` reports a failure; that is the intended shape, and
    //    `tool/drive_web_write_order.sh` ignores run 1's exit code in this
    //    mode. The browser process itself stays up and idle for a while
    //    afterwards, so nothing here truncates a flush that the close was
    //    going to perform — if the row is still missing in run 2, it is
    //    missing because NOTHING flushed it, not because we did not wait.
    // ---------------------------------------------------------------
    if (kOrderTeardown == 'unload') {
      await binding.takeScreenshot('order-01b-seed-before-unload');
      web.window.location.replace('about:blank');
      // Keep pumping so the isolate stays live right up until the document
      // takes it down; returning here would let `flutter drive` kill Chrome
      // first and turn this back into the `kill` case.
      final unloadDeadline = DateTime.now().add(const Duration(seconds: 120));
      while (DateTime.now().isBefore(unloadDeadline)) {
        await tester.pump(const Duration(milliseconds: 200));
      }
    }
  });
}
