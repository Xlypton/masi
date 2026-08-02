// RUN 2 of the WRITE-ORDER durability matrix — the half that measures.
//
// Driven by `tool/drive_web_write_order.sh`, in a SEPARATE `flutter drive`
// invocation from the seed: a new Chrome process, a new Dart isolate, a cold
// wasm module and a cold drift SharedWorker, sharing only the pinned
// `--web-port` (one origin) and `--user-data-dir` (one profile on disk).
//
// This file's job is to REPORT A SHAPE, not merely to fail. Every step of
// run 1's sequence is looked up independently and written into `reportData`
// as a survivor list, so the run's JSON says which members came back even
// when the assertion at the bottom fails. That matrix is the finding; the
// assertion only decides the exit code.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:masi/app/app.dart' show MasiApp;
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/core/db/storage_durability_provider.dart';
import 'package:masi/features/account/application/auth_providers.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/main.dart' show bootApp;

import 'web_photo_offline_fixture.dart'
    show NetworkProbe, kExternalProbeUrls, probeExternal, pumpUntil;
import 'web_write_order_fixture.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final observed = <String, Object?>{};
  void record(Map<String, Object?> entries) {
    observed.addAll(entries);
    binding.reportData = Map<String, Object?>.from(observed);
  }

  testWidgets(
    'THE MATRIX: which members of wall -> photo -> route 1..N survived a '
    'real browser restart',
    (tester) async {
      expect(
        kOrderRunStamp,
        isNot('unstamped'),
        reason: 'run this through tool/drive_web_write_order.sh',
      );
      record({
        'run_stamp': kOrderRunStamp,
        'expected_wall_id': kOrderExpectedWallId,
        'expected_photo_id': kOrderExpectedPhotoId,
        'expected_route_count': kOrderRouteCount,
      });
      await binding.takeScreenshot('order-02-verify-start');

      // Still offline, re-asserted in THIS browser.
      final probes = <NetworkProbe>[];
      for (final url in kExternalProbeUrls) {
        probes.add(await probeExternal(url));
      }
      record({'network_probes': probes.map((p) => p.toJson()).toList()});
      for (final probe in probes) {
        expect(probe.reachable, isFalse, reason: 'reached ${probe.url}');
      }

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

      final container = ProviderScope.containerOf(
        tester.element(find.byType(MasiApp)),
        listen: false,
      );
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
      expect(signedIn, isFalse);

      // ---------------------------------------------------------------
      // THE MATRIX.
      //
      // Polled, not read once. `web_photo_offline_verify_test.dart` learned
      // this the hard way: a single null is always dismissable as "the query
      // ran before the database finished opening". Here the whole matrix is
      // re-read until it stops changing or the deadline passes, and BOTH the
      // first observation and the final one are reported — if they differ,
      // the difference is itself the finding.
      // ---------------------------------------------------------------
      final photoRepo = container.read(photoRepositoryProvider);
      final routeRepo = container.read(routeRepositoryProvider);
      final crud = container.read(libraryCrudRepositoryProvider);

      // Identity is resolved BY NAME, from the database itself, and only
      // falls back to whatever run 1's report threaded through. That is not a
      // convenience: in `MASI_ORDER_TEARDOWN=unload` mode run 1 navigates its
      // own page away and never returns a report at all, so a run 2 that
      // depended on those defines could not measure the graceful close — the
      // single most valuable thing this harness does.
      var wallId = kOrderExpectedWallId;
      if (wallId.isEmpty) {
        final topos = await crud.watchTopos().first;
        final match = topos.where((t) => t.name == orderWallName);
        wallId = match.isEmpty ? '' : match.first.wallId;
      }
      record({'resolved_wall_id': wallId});

      Future<Map<String, Object?>> sample() async {
        final wallPresent = tester.any(find.text(orderWallName));
        final tailWallPresent = tester.any(find.text(orderTailWallName));
        final ref = wallId.isEmpty
            ? null
            : await photoRepo.loadOriginal(wallId);
        // The photo's own row id, not a threaded define: routes hang off the
        // PHOTO, and a photo row that came back has the id its routes point
        // at.
        final photoId = ref?.id ?? kOrderExpectedPhotoId;
        var routeNames = <String>[];
        if (wallId.isNotEmpty && photoId.isNotEmpty) {
          final routes = await routeRepo.loadRoutes(wallId, photoId);
          routeNames = [
            for (final route in routes)
              if (route.name != null) route.name!,
          ];
        }
        final survivors = <int>[
          for (var n = 1; n <= kOrderRouteCount; n++)
            if (routeNames.contains(orderRouteName(n))) n,
        ];
        final missing = <int>[
          for (var n = 1; n <= kOrderRouteCount; n++)
            if (!routeNames.contains(orderRouteName(n))) n,
        ];
        return <String, Object?>{
          'wall_on_home': wallPresent,
          'tail_wall_on_home': tailWallPresent,
          'photo_row': ref?.localPath,
          'routes_survived': survivors,
          'routes_missing': missing,
        };
      }

      // Give the app a beat to paint the home list before the first sample,
      // so `wall_on_home` measures the rendered UI rather than a race.
      await pumpUntil(
        tester,
        () => tester.any(find.text(orderWallName)),
        timeout: const Duration(seconds: 30),
      );
      await tester.pumpAndSettle(const Duration(seconds: 2));

      final first = await sample();
      record({'first_sample': first});

      var last = first;
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 500));
        last = await sample();
        final routesMissing = last['routes_missing'] as List<int>;
        if (last['photo_row'] != null && routesMissing.isEmpty) break;
      }
      record({'final_sample': last});

      // Everything the app knows about this wall, independent of the
      // wall/photo ids threaded through — so a wall that came back under a
      // different identity, or a photo hanging off nothing, still shows up.
      final topos = await crud.watchTopos().first;
      final named = topos.where((t) => t.name == orderWallName).toList();
      final tailNamed = topos.where((t) => t.name == orderTailWallName).length;
      record({
        'topos_named_match': named.length,
        'tail_topos_named_match': tailNamed,
        'topos_total': topos.length,
        // The app's OWN aggregate over the Routes table, computed by a
        // different query than `loadRoutes` above. If the two disagree the
        // problem is a query, not durability.
        'topo_route_count': named.isEmpty ? null : named.first.routeCount,
        'topo_thumbnail': named.isEmpty ? null : named.first.thumbnailPath,
      });

      await binding.takeScreenshot('order-03-verify-home');

      // ---------------------------------------------------------------
      // The verdict. Reported first, asserted second, so the exit code
      // never costs us the measurement.
      // ---------------------------------------------------------------
      final missing = last['routes_missing'] as List<int>;
      final photoLost = last['photo_row'] == null;
      final tailLost = last['tail_wall_on_home'] != true;
      record({
        'verdict': switch ((photoLost, missing.isEmpty, tailLost)) {
          (false, true, false) => 'ALL_SURVIVED',
          // The signature the flush-on-commit hypothesis predicts: the two
          // transaction-wrapped writes bracket the auto-commit ones, and only
          // the trailing transaction is lost.
          (false, true, true) => 'ONLY_TRAILING_TRANSACTION_LOST',
          (true, true, _) => 'PHOTO_LOST_ROUTES_KEPT',
          (false, false, _) => 'ROUTES_LOST_PHOTO_KEPT',
          (true, false, _) => 'PHOTO_AND_ROUTES_LOST',
        },
      });

      expect(
        last['wall_on_home'],
        isTrue,
        reason: 'even the first Wall row is gone — a stronger failure than '
            'the photo pair measured',
      );
      expect(
        missing,
        isEmpty,
        reason: 'ROUTES WERE LOST across the restart. Missing route numbers: '
            '$missing out of 1..$kOrderRouteCount. Routes are what a climber '
            'draws last, offline, at the crag — this is the failure the '
            'whole web-offline effort exists to prevent.',
      );
      expect(
        last['photo_row'],
        isNotNull,
        reason: 'the Photos row did not survive (the photo pair already '
            'measures this; repeated here so one run reports both)',
      );
      expect(
        last['tail_wall_on_home'],
        isTrue,
        reason: 'THE TRAILING TRANSACTION WAS LOST: "$orderTailWallName" was '
            'created through LibraryCrudRepository.createTopo — a drift '
            'transaction — after every route insert, and did not come back '
            'while the routes did. That is the whole finding: it is not '
            'photos and it is not "the last write", it is the last write '
            'made inside a TRANSACTION.',
      );
    },
  );
}
