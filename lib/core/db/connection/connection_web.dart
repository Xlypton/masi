import 'package:drift/drift.dart';
import 'package:drift/wasm.dart';
import 'package:flutter/foundation.dart';

/// Web connection — drift on WASM (OPFS-via-worker where available, IndexedDB
/// fallback). Assets `sqlite3.wasm` + `drift_worker.js` are pinned in web/.
QueryExecutor openConnection() {
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
    );
    if (kDebugMode) {
      // First thing to check in any "my data vanished" web report.
      debugPrint(
        'drift/web storage backend: ${result.chosenImplementation} '
        '(missing features: ${result.missingFeatures})',
      );
    }
    return result.resolvedExecutor;
  }));
}
