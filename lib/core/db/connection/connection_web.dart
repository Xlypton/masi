import 'package:drift/drift.dart';
import 'package:drift/wasm.dart';

import 'storage_durability.dart';

/// Web connection — drift on WASM (OPFS-via-worker where available, IndexedDB
/// fallback). Assets `sqlite3.wasm` + `drift_worker.js` are pinned in web/.
///
/// [onStorageReport] receives drift's verdict — which storage implementation
/// was actually chosen, and which browser features were missing — exactly
/// once, as soon as `WasmDatabase.open`'s feature probe resolves. That
/// verdict used to be thrown away behind a debug-only conditional wrapping a
/// `debugPrint(...)` call, which is L1 in
/// `docs/superpowers/specs/2026-07-30-web-offline-reliability-design.md`:
/// `WasmDatabase.open` NEVER throws, it silently degrades to
/// `WasmStorageImplementation.inMemory` ("doesn't store anything"), so every
/// write succeeds, every list populates, and the whole library is gone on the
/// next page load with zero production signal.
QueryExecutor openConnection({
  void Function(StorageDurability verdict)? onStorageReport,
}) {
  // Wrapping `result.resolvedExecutor` (a `DatabaseConnection`) in a bare
  // `LazyDatabase` would discard its `BroadcastStreamQueryStore`, silently
  // breaking cross-tab watch() invalidation. `DatabaseConnection.delayed`
  // preserves `streamQueries` (via a `DelayedStreamQueryStore`) while still
  // deferring the async WASM setup.
  return DatabaseConnection.delayed(Future(() async {
    final result = await WasmDatabase.open(
      databaseName: 'climbtopo',
      sqlite3Uri: Uri.parse('sqlite3.wasm'),
      driftWorkerUri: Uri.parse('drift_worker.js'),
      // L8 lock-in mitigation. Without this, `WasmDatabase.open`'s
      // `_selectExistingDatabase` downgrades the chosen implementation back
      // to whatever storage API an EXISTING `climbtopo` database already
      // lives in, on EVERY open — so any install that first landed on
      // IndexedDB (i.e. every visitor served before the COOP/COEP headers in
      // `web/_headers` shipped) stays on IndexedDB forever, even once the
      // browser would happily give us OPFS.
      //
      // Safe by drift's own construction: `moveFromIndexedDBToOpfs` COPIES
      // the IndexedDB files into OPFS and only then deletes the IndexedDB
      // originals, and drift wraps the whole move in a try/catch that falls
      // back to "keep using the old IndexedDB database" on any throw
      // (drift-2.34.2/lib/wasm.dart:184-199). The worst case is therefore
      // "no upgrade", never "no data". The browser assertion that seeded
      // rows actually survive it lives in
      // `integration_test/web_storage_backend_test.dart`; the OPFS half of
      // that (which needs cross-origin isolation, and so cannot happen under
      // `flutter drive -d web-server`) is proven on real Chrome via
      // `tool/serve_web_isolated.py`.
      moveExistingIndexedDbToOpfs: true,
    );
    onStorageReport?.call(
      StorageDurability(
        backend: _backendOf(result.chosenImplementation),
        missingFeatures: {
          for (final feature in result.missingFeatures) _featureOf(feature),
        },
      ),
    );
    return result.resolvedExecutor;
  }));
}

/// Maps drift's web-only `WasmStorageImplementation` onto the
/// platform-agnostic [StorageBackend] the rest of the app — and every
/// `flutter test` unit test — speaks.
///
/// Exhaustive by construction: a drift upgrade that adds a storage
/// implementation makes this `switch` non-exhaustive, which `flutter analyze`
/// reports as an error. That matters more than convenience here — a mapping
/// that quietly resolved a new value to "durable" would re-open L1.
StorageBackend _backendOf(WasmStorageImplementation implementation) {
  return switch (implementation) {
    WasmStorageImplementation.opfsShared => StorageBackend.opfsShared,
    WasmStorageImplementation.opfsLocks => StorageBackend.opfsLocks,
    WasmStorageImplementation.sharedIndexedDb => StorageBackend.sharedIndexedDb,
    WasmStorageImplementation.unsafeIndexedDb => StorageBackend.unsafeIndexedDb,
    WasmStorageImplementation.inMemory => StorageBackend.inMemory,
  };
}

/// Same idea as [_backendOf], for drift's `MissingBrowserFeature`. These are
/// what a support report needs to explain WHY a browser ended up on a weaker
/// backend (e.g. `sharedArrayBuffers` missing means the COOP/COEP headers in
/// `web/_headers` did not arrive, so OPFS was never on the table).
StorageMissingFeature _featureOf(MissingBrowserFeature feature) {
  return switch (feature) {
    MissingBrowserFeature.sharedWorkers => StorageMissingFeature.sharedWorkers,
    MissingBrowserFeature.dedicatedWorkers =>
      StorageMissingFeature.dedicatedWorkers,
    MissingBrowserFeature.dedicatedWorkersInSharedWorkers =>
      StorageMissingFeature.dedicatedWorkersInSharedWorkers,
    MissingBrowserFeature.fileSystemAccess =>
      StorageMissingFeature.fileSystemAccess,
    MissingBrowserFeature.indexedDb => StorageMissingFeature.indexedDb,
    MissingBrowserFeature.sharedArrayBuffers =>
      StorageMissingFeature.sharedArrayBuffers,
    MissingBrowserFeature.workerError => StorageMissingFeature.workerError,
  };
}
