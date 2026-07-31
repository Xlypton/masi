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
//  2. `moveExistingIndexedDbToOpfs: true` is SAFE. A drift database is
//     deliberately created on IndexedDB (the storage every pre-COOP/COEP
//     install is pinned to by `_selectExistingDatabase`), seeded with a known
//     row, closed, then reopened with the flag on. The row must still be
//     there — moved to OPFS where OPFS is available, left in IndexedDB where
//     it is not. Either way: nothing lost.
//
// IMPORTANT HARNESS LIMIT: `flutter drive` has no `--web-header` flag, so the
// `-d web-server` device cannot send COOP/COEP. Without cross-origin
// isolation there is no SharedArrayBuffer, so drift's probe never offers
// `opfsLocks` (drift wasm_setup.dart:124-131 requires
// `supportsSharedArrayBuffers`), and `opfsShared` needs nested workers which
// only Firefox implements. In THIS harness the test therefore exercises the
// "no OPFS available -> flag is a no-op, data intact" branch, which is
// exactly the regression that would silently drop a user's library. The OPFS
// branch is proven on real Chrome via `tool/serve_web_isolated.py` (see that
// file's header) before this ships.
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
        reason: 'drift fell back to inMemory, which stores NOTHING — this is '
            'L1 happening for real. missingFeatures: '
            '${verdict.missingFeatures}',
      );
      expect(verdict.isDurable, isTrue);
      expect(verdict.isEphemeral, isFalse);
    },
  );

  testWidgets(
    'moveExistingIndexedDbToOpfs: an existing IndexedDB database survives a '
    'reopen with the flag on — no rows lost, whether or not OPFS is available',
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
        reason: 'this browser cannot host the IndexedDB half of this test; '
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
      await seedDb.into(seedDb.areas).insert(
            AreasCompanion.insert(
              id: 'move-probe-area',
              name: 'Move probe',
              createdAt: 1,
              updatedAt: 1,
            ),
          );
      await seedDb.close();

      // Reopen exactly the way `connection_web.dart` does.
      final reopened = await WasmDatabase.open(
        databaseName: name,
        sqlite3Uri: sqlite3Uri,
        driftWorkerUri: driftWorkerUri,
        moveExistingIndexedDbToOpfs: true,
      );
      final movedDb = AppDatabase(reopened.resolvedExecutor);
      addTearDown(movedDb.close);

      final areas = await movedDb.select(movedDb.areas).get();
      expect(
        areas.map((a) => a.id),
        contains('move-probe-area'),
        reason: 'THE assertion that makes moveExistingIndexedDbToOpfs safe to '
            'ship: the row seeded in IndexedDB must survive the reopen. '
            'chosenImplementation: ${reopened.chosenImplementation}',
      );
      expect(
        reopened.chosenImplementation,
        isNot(WasmStorageImplementation.inMemory),
      );

      final opfsAvailable = probe.availableStorages.any(
        (i) => i.storageApi == WebStorageApi.opfs,
      );
      if (opfsAvailable) {
        expect(
          reopened.chosenImplementation.storageApi,
          WebStorageApi.opfs,
          reason: 'with OPFS available, the flag must actually migrate the '
              'database up instead of staying pinned to IndexedDB (L8)',
        );
      } else {
        expect(
          reopened.chosenImplementation.storageApi,
          WebStorageApi.indexedDb,
          reason: 'with no OPFS available the flag must be a pure no-op that '
              'leaves the existing IndexedDB database exactly where it is',
        );
      }
    },
  );
}
