// Ship-blocker coverage for §1b's pre-first-frame `Future.wait`.
//
// §1b moved the FIRST REAL QUERY against the local database onto the
// pre-`runApp` path (`LastKnownUid.hydrate()` reads the `AppSettings` table,
// which forces drift to actually open the database). drift 2.34.2 has no
// timeout ANYWHERE on that path — `grep -rE 'timeout|Future.any'` over
// `drift-2.34.2/lib/src/web/` and `lib/wasm.dart` returns nothing — and it has
// at least four unbounded awaits that can never complete:
//
//   * `src/web/wasm_setup.dart:123`  `_probeDedicated`  -> `nextNoError`
//   * `src/web/wasm_setup.dart:155`  `_probeShared`     -> `nextNoError`
//   * `src/web/wasm_setup.dart:329`  `connectToRemoteAndInitialize`
//   * `src/web/wasm_setup/shared.dart:390`  `_loadLockedWasmVfs` ->
//     `messageEvent.forTarget(worker).first`, which has no error listener at
//     all. This one sits on the `opfsLocks` backend a cross-origin-isolated
//     Chrome actually selects, and it runs INSIDE the worker's own
//     `LazyDatabase` (`shared.dart:284`) — i.e. on the first query, AFTER
//     `WasmDatabase.open` has already reported a green verdict.
//
// If any of those hangs, `Future.wait` never completes, `runApp` is never
// reached, and the user stares at a blank page with no error and no way in.
// For a PWA whose whole selling point is working offline, an unbootable app
// is the worst possible outcome.
//
// `awaitBootWork` is the bound. Like `requestPersistentStorageAtBoot` (see
// `test/main_boot_storage_persistence_test.dart`) it is a named top-level
// function purely so the wiring can be driven against a test container
// instead of calling `bootApp()`, which performs real side effects.
//
// Timing is driven by `testWidgets`' FakeAsync clock (`tester.pump(d)`), so
// these run against the REAL production deadlines without ever sleeping.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/core/db/storage_durability_provider.dart';
import 'package:masi/main.dart'
    show awaitBootWork, kBootFirstFrameDeadline, kBootStorageDeadline;

/// A little past a deadline, so `tester.pump` lands strictly after the timer.
const _tick = Duration(seconds: 1);

ProviderContainer _container() {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  return container;
}

void main() {
  testWidgets(
    'work that completes normally returns immediately and leaves the storage '
    'verdict untouched',
    (tester) async {
      final container = _container();
      container
          .read(storageDurabilityProvider.notifier)
          .report(const StorageDurability(backend: StorageBackend.nativeFile));

      var returned = false;
      unawaited(
        awaitBootWork(container, Future<void>.value())
            .then((_) => returned = true),
      );
      await tester.pump();

      expect(returned, isTrue, reason: 'boot must not be delayed at all');
      expect(
        container.read(storageDurabilityProvider).backend,
        StorageBackend.nativeFile,
      );
    },
  );

  testWidgets(
    'THE ship-blocker assertion: pre-frame work that NEVER completes still '
    'releases the first frame, so runApp is always reached',
    (tester) async {
      final container = _container();
      final hung = Completer<void>();

      var returned = false;
      unawaited(
        awaitBootWork(container, hung.future).then((_) => returned = true),
      );

      await tester.pump(kBootFirstFrameDeadline - _tick);
      expect(
        returned,
        isFalse,
        reason: 'boot should still be waiting before the deadline',
      );

      await tester.pump(_tick * 2);
      expect(
        returned,
        isTrue,
        reason: 'a database that never answers must not cost the user the app',
      );

      // Release the still-pending second-stage timer so the FakeAsync clock
      // is clean at teardown.
      hung.complete();
      await tester.pump();
    },
  );

  testWidgets(
    'a database that never answers is EXPLAINED: past the storage deadline '
    'the verdict becomes unavailable, which the existing storage-warning UI '
    'already renders',
    (tester) async {
      final container = _container();
      final hung = Completer<void>();
      // Nothing left to drain by the end of this one: both deadlines have
      // fired, and the gate's remaining `await work` is a plain future, not a
      // timer. Completing it anyway keeps the hang from outliving the test.
      addTearDown(hung.complete);

      unawaited(awaitBootWork(container, hung.future));

      await tester.pump(kBootStorageDeadline - _tick);
      expect(
        container.read(storageDurabilityProvider).unavailable,
        isFalse,
        reason: 'nothing may be declared dead before the storage deadline',
      );

      await tester.pump(_tick * 2);
      final verdict = container.read(storageDurabilityProvider);
      expect(verdict.unavailable, isTrue);
      expect(verdict.isProbing, isFalse, reason: 'this IS a verdict');
      expect(
        verdict.isEphemeral,
        isTrue,
        reason: 'topos_screen renders _StorageWarningBanner and disables both '
            'create affordances on exactly this flag',
      );
      expect(verdict.unavailableReason, contains('did not answer'));
      expect(
        verdict.unavailableReason,
        contains('${kBootStorageDeadline.inSeconds}s'),
      );
    },
  );

  testWidgets(
    'B2: the stall verdict PRESERVES whatever the connection layer already '
    'measured — a field report must not lose the backend and the '
    'missing-feature set',
    (tester) async {
      final container = _container();
      // What the deployed site really reports, measured three times in
      // `tool/drive_web_write_order.sh` (see `connection_web.dart`).
      container.read(storageDurabilityProvider.notifier).report(
            const StorageDurability(
              backend: StorageBackend.opfsLocks,
              missingFeatures: {
                StorageMissingFeature.dedicatedWorkersInSharedWorkers,
              },
            ),
          );
      final hung = Completer<void>();
      addTearDown(hung.complete);

      unawaited(awaitBootWork(container, hung.future));
      await tester.pump(kBootStorageDeadline + _tick);

      final verdict = container.read(storageDurabilityProvider);
      expect(verdict.unavailable, isTrue, reason: 'still a stall verdict');
      expect(
        verdict.measuredBackend,
        StorageBackend.opfsLocks,
        reason: 'the stall verdict used to zero this, so the UI could no longer '
            'say which backend the browser had actually reached',
      );
      expect(
        verdict.missingFeatures,
        {StorageMissingFeature.dedicatedWorkersInSharedWorkers},
        reason: 'THE field-report assertion: this set is the `· missing: …` '
            'segment both storage banners render, and it came back absent from '
            'a real report because the overlay zeroed it',
      );
      expect(
        verdict.backend,
        isNull,
        reason: 'nothing is in effect; the banners must still say "unavailable"',
      );
    },
  );

  testWidgets(
    'SLOW is not HUNG: work that lands after the first frame but before the '
    'storage deadline is never declared unavailable',
    (tester) async {
      final container = _container();
      container
          .read(storageDurabilityProvider.notifier)
          .report(const StorageDurability(backend: StorageBackend.nativeFile));
      final slow = Completer<void>();

      var returned = false;
      unawaited(
        awaitBootWork(container, slow.future).then((_) => returned = true),
      );

      await tester.pump(kBootFirstFrameDeadline + _tick);
      expect(returned, isTrue);

      slow.complete();
      await tester.pump(kBootStorageDeadline);

      final verdict = container.read(storageDurabilityProvider);
      expect(
        verdict.unavailable,
        isFalse,
        reason: 'a merely-slow first migration must never be reported as dead '
            'storage — that would disable topo creation for the whole session',
      );
      expect(verdict.backend, StorageBackend.nativeFile);
    },
  );

  testWidgets(
    'the timeout stops blocking the frame but does NOT abandon the open: an '
    'open that lands after the storage deadline reverts the pessimistic '
    'verdict to the connection layer\'s real one',
    (tester) async {
      final container = _container();
      container
          .read(storageDurabilityProvider.notifier)
          .report(const StorageDurability(backend: StorageBackend.opfsLocks));
      final verySlow = Completer<void>();

      unawaited(awaitBootWork(container, verySlow.future));

      await tester.pump(kBootStorageDeadline + _tick);
      expect(container.read(storageDurabilityProvider).unavailable, isTrue);

      verySlow.complete();
      await tester.pump();

      final verdict = container.read(storageDurabilityProvider);
      expect(
        verdict.unavailable,
        isFalse,
        reason: 'the database proved itself; the timeout was wrong and must '
            'be undone rather than left blocking creation forever',
      );
      expect(verdict.backend, StorageBackend.opfsLocks);
      expect(verdict.isEphemeral, isFalse);
    },
  );

  testWidgets(
    'a verdict that arrives AFTER the timeout wins — the revert never '
    'resurrects a stale snapshot',
    (tester) async {
      final container = _container();
      container
          .read(storageDurabilityProvider.notifier)
          .report(const StorageDurability(backend: StorageBackend.opfsLocks));
      final verySlow = Completer<void>();

      unawaited(awaitBootWork(container, verySlow.future));

      await tester.pump(kBootStorageDeadline + _tick);
      expect(container.read(storageDurabilityProvider).unavailable, isTrue);

      // The connection layer finally reports for real — this is newer than
      // anything the boot gate snapshotted.
      container.read(storageDurabilityProvider.notifier).report(
            const StorageDurability(backend: StorageBackend.inMemory),
          );
      verySlow.complete();
      await tester.pump();

      expect(
        container.read(storageDurabilityProvider).backend,
        StorageBackend.inMemory,
        reason: 'the freshest verdict must survive the revert',
      );
    },
  );

  testWidgets(
    'pre-frame work that THROWS is swallowed, so runApp is reached instead of '
    'main() rejecting into a blank page',
    (tester) async {
      final container = _container();

      var returned = false;
      unawaited(
        awaitBootWork(
          container,
          Future<void>.error(StateError('boot-boom')),
        ).then((_) => returned = true),
      );
      await tester.pump();

      expect(returned, isTrue);
      expect(
        container.read(storageDurabilityProvider).isProbing,
        isTrue,
        reason: 'a throw is already handled by the individual boot futures; '
            'the gate only has to stop it reaching main()',
      );
    },
  );

  test('the two deadlines are ordered and generous enough for a cold start', () {
    expect(kBootFirstFrameDeadline < kBootStorageDeadline, isTrue);
    expect(
      kBootFirstFrameDeadline >= const Duration(seconds: 5),
      isTrue,
      reason: 'must comfortably outlast a real cold open + one-time migration',
    );
  });
}
