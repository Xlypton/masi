// ACCEPTANCE TEST for the headline promise of the web-offline workstream:
//
//   "Make the masi PWA web app work offline as reliable as possible — most
//    important is to not lose topos recorded offline."
//
// Everything else in the web suite tests a piece:
// `web_storage_backend_test.dart` calls `openConnection()` directly (no app,
// no UI, no restart), `web_storage_persistence_test.dart` drives the
// `navigator.storage` seam, `web_smoke_test.dart` walks Area→Sector→Wall with
// **zero `expect()` calls** (design doc "Testing strategy": that green tick is
// screenshot-only). This file is the end-to-end one: real app boot, real UI
// gestures, real drift-on-WASM browser storage, an in-page app RESTART, and
// hard assertions that every row created before the restart is still there
// after it.
//
// Run it (headless Chrome via chromedriver; NOT part of `flutter test`, which
// runs on the Dart VM and can compile none of the web storage stack):
//
//   tool/drive_web.sh integration_test/web_offline_persistence_test.dart
//
// -----------------------------------------------------------------------
// WHAT "restart" MEANS HERE, AND WHAT IT DOES NOT
// -----------------------------------------------------------------------
// `integration_test` cannot reload the browser page and resume — the test
// isolate dies with the page. So the restart is the strongest thing that IS
// reachable in-page: `bootApp()` is called a second time, which builds a
// brand-new `ProviderContainer`, a brand-new `AppDatabase`, and a brand-new
// `openConnection()` against the browser's `climbtopo` database, then
// `runApp`s a fresh widget tree over it. Nothing the first run held in Dart
// memory — no provider cache, no `StreamProvider` value, no widget state — is
// visible to the second one; the only channel between them is the browser's
// own storage.
//
// That is NOT identical to an F5. drift's `sharedIndexedDb` backend hosts the
// sqlite image inside a SharedWorker, and that worker survives a second client
// connecting, so this proves "a cold Dart-side app re-reads the persisted
// database" rather than "the bytes were flushed all the way to disk". The
// missing half is covered from the other side, in the same run: the test
// asserts the connection layer resolved to a backend whose whole definition is
// "survives a page load" (`StorageDurability.isDurable`) and, independently,
// probes the browser for an EXISTING persistent `climbtopo` database — a
// question only real IndexedDB/OPFS storage can answer yes to. A true
// reload-and-resume needs a driver-level harness (CDP, or two chained
// `flutter drive` runs sharing one Chrome profile) that does not exist yet.
//
// -----------------------------------------------------------------------
// WHAT "OFFLINE" MEANS HERE
// -----------------------------------------------------------------------
// The network is NOT severed. `flutter drive` exposes no CDP hook, and the
// obvious Riverpod seam (`connectivityServiceProvider`, in
// `lib/features/backup/`) is being rewritten concurrently, so an override
// against it would assert on a moving target. What this run does establish is
// the load-bearing property: the app is SIGNED OUT for the whole flow (see
// `signed_in` in the reported data), so not one row here can have been written
// by, echoed through, or recovered from Supabase. Every row asserted after the
// restart came out of local browser storage and nowhere else. Sync status,
// `lastSyncedAt` and the outbox are deliberately untouched — that is §1d/§1e's
// surface, not this file's.
//
// -----------------------------------------------------------------------
// GETTING VALUES OUT
// -----------------------------------------------------------------------
// `flutter drive -d web-server` does not relay the browser's `debugPrint`, so
// every number this test looked at is pushed through `binding.reportData`,
// which the driver persists to `build/integration_response_data.json`. Read
// that file to see which storage backend Chrome actually resolved to and how
// many rows survived — a green tick alone would not tell you.
import 'dart:async';

import 'package:drift/wasm.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:masi/app/app.dart' show MasiApp;
import 'package:masi/core/db/storage_durability_provider.dart';
import 'package:masi/features/account/application/auth_providers.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/main.dart' show bootApp;

/// The database name `connection_web.dart` opens. Kept as a literal (rather
/// than exported from `lib/`) so a rename there is caught here as a failing
/// existence probe rather than silently following along.
const _databaseName = 'climbtopo';

/// Pumps real frames until [condition] holds, or [timeout] elapses.
///
/// `pumpAndSettle` is unusable for the waits in this file: the app keeps live
/// `StreamProvider` subscriptions and (during boot) an indeterminate progress
/// indicator, so "no more frames scheduled" may never arrive. This is the same
/// reason `web_boot_stability_test.dart` hand-rolls `_pumpForStability`.
Future<bool> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 45),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return true;
    await tester.pump(const Duration(milliseconds: 100));
  }
  return condition();
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// Everything the browser actually reported, merged into `reportData` as it
  /// is observed (the driver writes the map once, at the end of the run).
  final observed = <String, Object?>{};
  void record(Map<String, Object?> entries) {
    observed.addAll(entries);
    binding.reportData = Map<String, Object?>.from(observed);
  }

  /// The container behind the CURRENTLY mounted app. Re-read after the
  /// restart, where it must be a different object.
  ProviderContainer currentContainer(WidgetTester tester) =>
      ProviderScope.containerOf(
        tester.element(find.byType(MasiApp)),
        listen: false,
      );

  /// Boots the real app with the web auth wall disabled.
  ///
  /// The wall (`webAuthGateEnabledProvider`, defaulting to `kIsWeb`) would
  /// redirect a signed-out user straight to `/account` and none of the library
  /// flow below would be reachable — same override, same reason, as
  /// `web_smoke_test.dart`. Note this disables the ROUTING gate only: the
  /// session really is signed out, which is what makes the "nothing could have
  /// come from the cloud" argument in this file's header hold.
  ///
  /// Deliberately not awaited, matching `web_smoke_test.dart`: `bootApp`
  /// finishes with `runApp`, and the frames that attach that tree only happen
  /// once the test starts pumping.
  void boot() {
    unawaited(
      bootApp(overrides: [webAuthGateEnabledProvider.overrideWithValue(false)]),
    );
  }

  /// Types [name] into the shared CRUD add/rename dialog and submits it.
  /// Keys come from `crud_list_scaffold.dart` (`crud-name-field` /
  /// `crud-name-submit`), shared by Areas, Sectors and Walls.
  Future<void> submitCrudName(WidgetTester tester, String name) async {
    expect(
      find.byKey(const Key('crud-name-field')),
      findsOneWidget,
      reason: 'the add dialog must be open before a name can be entered',
    );
    await tester.enterText(find.byKey(const Key('crud-name-field')), name);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('crud-name-submit')));
    await tester.pumpAndSettle(const Duration(seconds: 1));
  }

  /// Taps `<entityKey>-add-fab` and creates a child named [name], asserting it
  /// is on screen afterwards.
  Future<void> createEntity(
    WidgetTester tester,
    String entityKey,
    String name,
  ) async {
    final fab = find.byKey(Key('$entityKey-add-fab'));
    expect(fab, findsOneWidget, reason: 'no $entityKey-add-fab on screen');
    await tester.tap(fab);
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await submitCrudName(tester, name);
    expect(
      find.text(name),
      findsOneWidget,
      reason: '$entityKey "$name" was not listed after creation',
    );
  }

  /// Taps the row labelled [name] and waits for the child screen's add-FAB.
  Future<void> drillInto(
    WidgetTester tester,
    String name,
    String childEntityKey,
  ) async {
    expect(find.text(name), findsOneWidget, reason: 'no row named "$name"');
    await tester.tap(find.text(name).first);
    await tester.pumpAndSettle(const Duration(seconds: 1));
    final reached = await _pumpUntil(
      tester,
      () => tester.any(find.byKey(Key('$childEntityKey-add-fab'))),
    );
    expect(
      reached,
      isTrue,
      reason: 'tapping "$name" never reached the $childEntityKey screen',
    );
  }

  testWidgets(
    'a topo recorded with no cloud session survives an app restart: '
    'Area -> Sector -> Wall are still in durable browser storage, and still '
    'on screen, after a fresh ProviderContainer re-opens the database',
    (tester) async {
      // Run-unique names: a re-run against a warm Chrome profile must not be
      // able to pass on rows a previous run left behind.
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final areaName = 'Offline Area $stamp';
      final sectorName = 'Offline Sector $stamp';
      final wallName = 'Offline Wall $stamp';
      record({
        'area_name': areaName,
        'sector_name': sectorName,
        'wall_name': wallName,
      });

      // ---------------------------------------------------------------
      // 1. Boot, and reach a usable state.
      // ---------------------------------------------------------------
      boot();
      await tester.pumpAndSettle(const Duration(seconds: 2));
      final booted = await _pumpUntil(
        tester,
        () => tester.any(find.byKey(const Key('topos-organize'))),
      );
      await binding.takeScreenshot('01-booted-topos-home');
      expect(
        booted,
        isTrue,
        reason: 'the app never reached Topos home (no topos-organize action)',
      );

      final container = currentContainer(tester);

      // ---------------------------------------------------------------
      // 2. The storage verdict — the whole point of §1a.
      //
      // `WasmDatabase.open` NEVER throws; when the browser cannot give it a
      // real backend it silently returns `inMemory`, which "doesn't store
      // anything". Every write below would still succeed and every list would
      // still populate — and the entire library would be gone on reload. So
      // asserting the rows come back is only meaningful once the backend they
      // came back FROM is known to be durable.
      // ---------------------------------------------------------------
      final verdictArrived = await _pumpUntil(
        tester,
        () => !container.read(storageDurabilityProvider).isProbing,
        timeout: const Duration(seconds: 60),
      );
      final verdict = container.read(storageDurabilityProvider);
      record({
        'storage_verdict_arrived': verdictArrived,
        'storage_backend': verdict.backend?.name,
        'storage_is_durable': verdict.isDurable,
        'storage_is_ephemeral': verdict.isEphemeral,
        'storage_unavailable': verdict.unavailable,
        'storage_unavailable_reason': verdict.unavailableReason,
        'storage_missing_features': (verdict.missingFeatures
            .map((f) => f.name)
            .toList()
          ..sort()),
      });
      expect(
        verdictArrived,
        isTrue,
        reason: 'storageDurabilityProvider never left `probing`, so the app '
            'ran the whole session without knowing whether it could keep '
            'anything — the create-topo interlock reads that as "allow"',
      );
      expect(
        verdict.backend,
        isNot(StorageBackend.inMemory),
        reason: 'L1 happening for real: drift fell back to a backend that '
            'stores NOTHING. missingFeatures: ${verdict.missingFeatures}',
      );
      expect(verdict.isDurable, isTrue, reason: 'verdict was $verdict');
      expect(verdict.isEphemeral, isFalse);
      expect(
        find.byKey(const Key('topos-storage-warning')),
        findsNothing,
        reason: 'the ephemeral-storage banner is up, so the app itself does '
            'not believe this browser can keep data',
      );

      // Nothing below can have reached, or come back from, Supabase.
      final signedIn =
          container.read(authStateProvider).asData?.value.isSignedIn ?? false;
      record({'signed_in': signedIn});
      expect(
        signedIn,
        isFalse,
        reason: 'this flow must prove LOCAL durability; a live session would '
            'let the cloud, not browser storage, explain the survivors',
      );
      await binding.takeScreenshot('02-storage-verdict-durable');

      // ---------------------------------------------------------------
      // 3. Record a topo through the UI only (keys, never coordinates).
      // ---------------------------------------------------------------
      await tester.tap(find.byKey(const Key('topos-organize')));
      await tester.pumpAndSettle(const Duration(seconds: 2));

      await createEntity(tester, 'area', areaName);
      await binding.takeScreenshot('03-area-created');

      await drillInto(tester, areaName, 'sector');
      await createEntity(tester, 'sector', sectorName);
      await binding.takeScreenshot('04-sector-created');

      await drillInto(tester, sectorName, 'wall');
      await createEntity(tester, 'wall', wallName);
      await binding.takeScreenshot('05-wall-created');

      // Capture the ids so the post-restart assertion can prove these are the
      // SAME rows, not same-named rows re-created by some replay path.
      final repo = container.read(libraryCrudRepositoryProvider);
      final areaBefore = (await repo.watchAreas().first).singleWhere(
        (a) => a.name == areaName,
      );
      final sectorBefore = (await repo.watchSectors(areaBefore.id).first)
          .singleWhere((s) => s.name == sectorName);
      final wallBefore = (await repo.watchWalls(sectorBefore.id).first)
          .singleWhere((w) => w.name == wallName);
      record({
        'area_id': areaBefore.id,
        'sector_id': sectorBefore.id,
        'wall_id': wallBefore.id,
      });

      // An independent, browser-level answer to "is there really a persistent
      // database out there?". `existingDatabases` only ever lists databases
      // found in OPFS or IndexedDB — an in-memory backend has nothing to list.
      final probe = await WasmDatabase.probe(
        sqlite3Uri: Uri.parse('sqlite3.wasm'),
        driftWorkerUri: Uri.parse('drift_worker.js'),
        databaseName: _databaseName,
      );
      record({
        'existing_databases': probe.existingDatabases
            .map((e) => '${e.$1.name}:${e.$2}')
            .toList(),
        'available_storages': probe.availableStorages
            .map((s) => s.name)
            .toList(),
        'probe_missing_features': probe.missingFeatures
            .map((f) => f.name)
            .toList(),
      });
      expect(
        probe.existingDatabases.map((e) => e.$2),
        contains(_databaseName),
        reason: 'no persistent "$_databaseName" database exists in this '
            "browser's storage, so whatever the UI just listed is living in "
            'memory only. existingDatabases: ${probe.existingDatabases}',
      );

      // ---------------------------------------------------------------
      // 4. Restart, in-page.
      //
      // `appRouter` is a module-level singleton whose navigation state
      // survives a re-boot (see `web_boot_stability_test.dart`'s header), so
      // park it at Topos home first — otherwise the second boot resumes on
      // the walls screen and "the data is still there" would be indisting-
      // uishable from "the old tree is still there".
      // ---------------------------------------------------------------
      GoRouter.of(tester.element(find.byType(Scaffold).first)).go('/');
      await tester.pumpAndSettle(const Duration(seconds: 2));

      boot();
      await tester.pumpAndSettle(const Duration(seconds: 2));
      final rebooted = await _pumpUntil(
        tester,
        () => tester.any(find.byKey(const Key('topos-organize'))),
      );
      expect(rebooted, isTrue, reason: 'the app did not come back up');

      final container2 = currentContainer(tester);
      expect(
        identical(container2, container),
        isFalse,
        reason: 'the second boot reused the first ProviderContainer, so this '
            'proves nothing about re-reading storage — every provider value '
            'below would just be the first run\'s cache',
      );
      final verdict2Arrived = await _pumpUntil(
        tester,
        () => !container2.read(storageDurabilityProvider).isProbing,
        timeout: const Duration(seconds: 60),
      );
      final verdict2 = container2.read(storageDurabilityProvider);
      record({
        'restart_storage_verdict_arrived': verdict2Arrived,
        'restart_storage_backend': verdict2.backend?.name,
        'restart_storage_is_durable': verdict2.isDurable,
      });
      expect(verdict2Arrived, isTrue);
      expect(verdict2.isDurable, isTrue, reason: 'verdict was $verdict2');

      // The promise, stated the way a user would state it: reopen the app and
      // the topo you recorded is on the home screen. Nothing has been tapped
      // since the reboot — this is the first thing the rebooted app renders.
      final topoOnHome = await _pumpUntil(
        tester,
        () => tester.any(find.text(wallName)),
      );
      await binding.takeScreenshot('06-after-restart-topos-home');
      expect(
        topoOnHome,
        isTrue,
        reason: 'the rebooted Topos home does not list "$wallName", the topo '
            'recorded before the restart — this IS the headline promise '
            'failing, whatever the database says below',
      );

      // ---------------------------------------------------------------
      // 5. THE data-loss assertion — at the database, then on screen.
      // ---------------------------------------------------------------
      final repo2 = container2.read(libraryCrudRepositoryProvider);
      final areasAfter = await repo2.watchAreas().first;
      record({
        'areas_after_restart': areasAfter.length,
        'area_names_after_restart': areasAfter.map((a) => a.name).toList(),
      });
      expect(
        areasAfter.map((a) => a.name),
        contains(areaName),
        reason: 'THE regression this file exists for: an area created before '
            'the restart is gone after it. Backend was '
            '${verdict2.backend?.name}',
      );
      final areaAfter = areasAfter.singleWhere((a) => a.name == areaName);
      expect(
        areaAfter.id,
        areaBefore.id,
        reason: 'same name, different id — this is a re-created row, not a '
            'survived one',
      );

      final sectorsAfter = await repo2.watchSectors(areaAfter.id).first;
      record({'sectors_after_restart': sectorsAfter.length});
      expect(sectorsAfter.map((s) => s.id), contains(sectorBefore.id));
      expect(sectorsAfter.map((s) => s.name), contains(sectorName));

      final wallsAfter = await repo2.watchWalls(sectorBefore.id).first;
      record({'walls_after_restart': wallsAfter.length});
      expect(
        wallsAfter.map((w) => w.id),
        contains(wallBefore.id),
        reason: 'the wall — the "topo" itself — did not survive the restart',
      );
      expect(wallsAfter.map((w) => w.name), contains(wallName));

      // Same three rows, but read the way a user reads them: through the UI
      // of the freshly booted app. A repository that returns rows the screens
      // never render is not "not losing topos".
      await tester.tap(find.byKey(const Key('topos-organize')));
      await tester.pumpAndSettle(const Duration(seconds: 2));
      final areaVisible = await _pumpUntil(
        tester,
        () => tester.any(find.text(areaName)),
      );
      await binding.takeScreenshot('07-areas-after-restart');
      expect(
        areaVisible,
        isTrue,
        reason: '"$areaName" is in the database but the rebooted Areas screen '
            'does not show it',
      );

      await drillInto(tester, areaName, 'sector');
      await binding.takeScreenshot('08-sectors-after-restart');
      expect(find.text(sectorName), findsOneWidget);

      await drillInto(tester, sectorName, 'wall');
      await binding.takeScreenshot('09-walls-after-restart');
      expect(find.text(wallName), findsOneWidget);
    },
  );
}
