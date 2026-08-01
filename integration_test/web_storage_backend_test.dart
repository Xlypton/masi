// Browser-executed assertions for design-doc §1a. Driven headless via
//   tool/drive_web.sh integration_test/web_storage_backend_test.dart
// (NOT run by `flutter test` — `package:drift/wasm.dart` imports
// `dart:js_interop`, so the Dart VM cannot compile any of this).
//
// Two things are proven here:
//
//  1. The REAL `openConnection()` — the same one `appDatabaseProvider` uses —
//     resolves to a durable backend in a real browser, never drift's silent
//     `inMemory` fallback (L1). Before §1a there was no way to observe this
//     at all: the verdict was discarded behind `if (kDebugMode)`.
//
//  2. An existing IndexedDB database is never silently abandoned. A drift
//     database is deliberately created on IndexedDB (the storage every
//     pre-COOP/COEP install is pinned to by `_selectExistingDatabase`),
//     seeded with a known row, closed, then reopened exactly the way
//     `connection_web.dart` does it — which, deliberately, is WITHOUT
//     `moveExistingIndexedDbToOpfs`. The seeded row must still be there, and
//     the reopen must stay on IndexedDB rather than landing on a fresh
//     database somewhere else.
//
//     This assertion used to be the opposite: it reopened with the flag ON
//     and proved the move was lossless. The flag has since been reverted —
//     drift 2.34.2's IndexedDB->OPFS move takes no Web Lock and has a crash
//     window in which it publishes a zero-byte OPFS database that a
//     subsequent boot may prefer over the intact IndexedDB one. The full
//     trace is in the comment block in `connection_web.dart`. So what this
//     test now pins is the behaviour we actually ship: pin-to-existing-
//     storage, which costs us the L8 lock-in and cannot cost us the library.
//
// HARNESS NOTE: `flutter drive` has no `--web-header` flag, so the
// `-d web-server` device cannot send COOP/COEP. Without cross-origin
// isolation there is no SharedArrayBuffer, so drift's probe never offers
// `opfsLocks` (drift wasm_setup.dart:124-131 requires
// `supportsSharedArrayBuffers`), and `opfsShared` needs nested workers which
// only Firefox implements. That limit no longer weakens assertion 2: with the
// move disabled, staying on IndexedDB is the required outcome whether or not
// OPFS is on offer, so the assertion is now unconditional.
import 'package:drift/wasm.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/connection/connection.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'the real openConnection() resolves to a DURABLE backend, never inMemory',
    (tester) async {
      final verdicts = <StorageDurability>[];
      final db = AppDatabase(openConnection(onStorageReport: verdicts.add));
      addTearDown(db.close);

      // Force the delayed connection to actually resolve (and drift to run
      // its migration) — the verdict is reported inside the same future the
      // executor awaits, so it has necessarily landed by the time this
      // returns.
      await db.customSelect('SELECT 1').get();

      expect(verdicts, hasLength(1));
      final verdict = verdicts.single;
      expect(
        verdict.backend,
        isNot(StorageBackend.inMemory),
        reason:
            'drift fell back to inMemory, which stores NOTHING — this is '
            'L1 happening for real. missingFeatures: '
            '${verdict.missingFeatures}',
      );
      expect(verdict.isDurable, isTrue);
      expect(verdict.isEphemeral, isFalse);
    },
  );

  testWidgets(
    'an existing IndexedDB database survives a reopen and stays on IndexedDB '
    '— no rows lost, and no silent hop to another storage backend',
    (tester) async {
      // A test-only database name: this must never be able to touch the real
      // `climbtopo` database.
      const name = 'masi_move_probe';
      final sqlite3Uri = Uri.parse('sqlite3.wasm');
      final driftWorkerUri = Uri.parse('drift_worker.js');

      final probe = await WasmDatabase.probe(
        sqlite3Uri: sqlite3Uri,
        driftWorkerUri: driftWorkerUri,
        databaseName: name,
      );
      final indexedDbImplementations = probe.availableStorages
          .where((i) => i.storageApi == WebStorageApi.indexedDb)
          .toList();
      expect(
        indexedDbImplementations,
        isNotEmpty,
        reason:
            'this browser cannot host the IndexedDB half of this test; '
            'available: ${probe.availableStorages}, missing: '
            '${probe.missingFeatures}',
      );

      // Seed the database ON INDEXEDDB, which is where every install served
      // before COOP/COEP shipped still lives.
      final seedConnection = await probe.open(
        indexedDbImplementations.first,
        name,
      );
      final seedDb = AppDatabase(seedConnection);
      await seedDb
          .into(seedDb.areas)
          .insert(
            AreasCompanion.insert(
              id: 'move-probe-area',
              name: 'Move probe',
              createdAt: 1,
              updatedAt: 1,
            ),
          );
      await seedDb.close();

      // Reopen exactly the way `connection_web.dart` does — no
      // `moveExistingIndexedDbToOpfs`, so drift's default `false` applies.
      final reopened = await WasmDatabase.open(
        databaseName: name,
        sqlite3Uri: sqlite3Uri,
        driftWorkerUri: driftWorkerUri,
      );
      final movedDb = AppDatabase(reopened.resolvedExecutor);
      addTearDown(movedDb.close);

      final areas = await movedDb.select(movedDb.areas).get();
      expect(
        areas.map((a) => a.id),
        contains('move-probe-area'),
        reason:
            'the row seeded in IndexedDB must survive the reopen — this '
            'is the "existing install keeps its library" assertion. '
            'chosenImplementation: ${reopened.chosenImplementation}',
      );
      expect(
        reopened.chosenImplementation,
        isNot(WasmStorageImplementation.inMemory),
      );

      expect(
        reopened.chosenImplementation.storageApi,
        WebStorageApi.indexedDb,
        reason:
            'unconditional, and deliberately so: with the move disabled, '
            "drift's `_selectExistingDatabase` must pin the reopen to the "
            'storage the data already lives in, whether or not OPFS is '
            'available here (available: ${probe.availableStorages}). This is '
            'the L8 lock-in, asserted rather than hidden — it is the price of '
            'never running drift 2.34.2\'s unlocked, non-crash-safe '
            'IndexedDB->OPFS move against a real user library.',
      );
    },
  );
}
