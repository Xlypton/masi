import 'package:drift/drift.dart';
import 'package:drift/wasm.dart';

import 'storage_durability.dart';

/// On drift's **IndexedDB** backends, a drift `COMMIT` does NOT reach browser
/// storage. Something else has to make it, and [AppDatabase.transaction] does
/// — see its override for the workaround. This flag is the platform half of
/// that seam.
///
/// Read the scope in that first sentence literally. It is NOT true of drift's
/// OPFS backends, and this flag is deliberately `true` for both anyway; the
/// measurements and the reasoning are in "PER-BACKEND, MEASURED" at the bottom
/// of this comment. An earlier version of this sentence said "on the web" with
/// no qualifier, which is how the harness gap below went unnoticed.
///
/// MEASURED, then traced to source. `tool/drive_web_write_order.sh` wrote
/// `wall -> photo -> 10 routes -> one more topo` into a real headless Chrome
/// with the network severed, killed the browser, and reopened the same
/// profile in a new process. Everything came back EXCEPT the last topo. Ten
/// route rows written seconds earlier survived; the topo written after them
/// did not. The difference is not recency and not the table — it is that
/// `RouteRepository.upsertRoute` is a bare auto-commit `INSERT` while
/// `LibraryCrudRepository.createTopo` is a `transaction(...)`.
///
/// Why, in drift 2.34.2 + sqlite3 3.5.0:
///
///  1. `sharedIndexedDb` is backed by sqlite3's `IndexedDbFileSystem`, opened
///     by drift with `writeAutomatically: false`
///     (`drift/src/web/wasm_setup/shared.dart:341-345`, comment: "We call
///     flush() in _WasmDelegate"). The authoritative database image is an
///     `InMemoryFileSystem`; IndexedDB is a write-behind mirror.
///  2. Because `writeAutomatically` is false, `_startWorkingIfNeeded`
///     (`sqlite3/src/wasm/vfs/indexed_db.dart:533-534`) returns immediately
///     for every implicit trigger. There is NO timer, NO debounce and NO
///     size threshold. The mirror is updated ONLY by an explicit `flush()`
///     or `close()`. Waiting does not help — measured at 15s and at 60s.
///  3. sqlite's own durability points are wired to nothing: `xSync` is "a
///     noop" (`indexed_db.dart:685-688`), `xClose` is empty, `xWrite`
///     queues a work item whose completion future is discarded
///     (`indexed_db.dart:712-737`).
///  4. Drift calls that `flush()` in `_WasmDelegate._runWithArgs` — but only
///     `if (!isInTransaction)` (`drift/lib/wasm.dart:362-368`).
///  5. And `isInTransaction` is still `true` while `COMMIT` runs:
///     `_StatementBasedTransactionExecutor.send()` is
///     `await runCustom(_commitCommand); _release();`
///     (`drift/src/runtime/executor/helpers/engines.dart:274-281`), and
///     `_release()` is what clears the flag (`:300-307`).
///
/// So a committed transaction is flushed only by whatever write happens to
/// come NEXT — including the `BEGIN` of the next transaction, which runs
/// before `isInTransaction` is set (`engines.dart:239-240`). That is exactly
/// why the original photo measurement looked photo-specific: the `Wall` row
/// survived because `attachPhotoToWall`'s own `BEGIN` flushed it, and the
/// `Photos` row died because nothing came after it.
///
/// The last transaction a user performs is therefore ALWAYS at risk, forever,
/// with no time limit — which for this app means the topo they just made, the
/// photo they just attached, or the delete they just performed, whenever it is
/// the last thing they do before the tab goes away.
///
/// -------------------------------------------------------------------------
/// PER-BACKEND, MEASURED — and why this flag is still unconditional
/// -------------------------------------------------------------------------
/// Everything above was measured on `sharedIndexedDb`, because
/// `tool/drive_web_write_order.sh` drives `flutter drive -d web-server`, whose
/// origin sent no COOP/COEP — so `crossOriginIsolated` was false and drift's
/// probe never offered OPFS. PRODUCTION sets both headers (`web/_headers`) and
/// runs OPFS. The fix was therefore validated on a backend production may not
/// even use. Closing that gap needed no new harness: `flutter drive` DOES
/// accept `--web-header` (hidden from its non-verbose help; `DriveCommand
/// extends RunCommandBase`, which calls `usesWebOptions`), which is now
/// `COI=1` on that script.
///
/// Three runs, 2026-08-04, same script, same headless Chrome 150, each
/// reporting the backend it actually opened (`storage_backend` in its JSON):
///
///   COI  flush  backend            verdict
///   off  OFF    sharedIndexedDb    ONLY_TRAILING_TRANSACTION_LOST
///   on   OFF    opfsLocks          ALL_SURVIVED
///   on   ON     opfsLocks          ALL_SURVIVED
///
/// Row 1 is the control: the SAME harness, with the fix disabled via
/// `NO_FLUSH=1`, still reproduces the loss — so rows 2 and 3 are a real
/// difference in the backend, not a harness that stopped measuring. The
/// cross-origin-isolated runs reported `opfsLocks` with
/// `missingFeatures: {dedicatedWorkersInSharedWorkers}`, which is exactly what
/// the deployed site reports.
///
/// So on OPFS the trailing-transaction loss DOES NOT HAPPEN, and the flush is
/// not what saves it. Both facts follow from source:
///
///  * drift's `_WasmDelegate._flush()` is `await _fileSystem?.flush()`
///    (`drift/lib/wasm.dart:358-360`) and `_fileSystem` is an
///    `IndexedDbFileSystem?` that `_openDatabase` populates ONLY on the
///    `sharedIndexedDb`/`unsafeIndexedDb` branches
///    (`wasm_setup/shared.dart:330-347`). On `opfsShared`/`opfsLocks` it is
///    `null`, so the post-commit statement's flush is a no-op there.
///  * OPFS does not need it. Its `xSync` really syncs —
///    `syncHandle.flush()` (`sqlite3/src/wasm/vfs/simple_opfs.dart:340-342`,
///    and via the worker for `WasmVfs`, `vfs/async_opfs/worker.dart:262-270`)
///    — whereas the IndexedDB VFS's `xSync` is "a noop"
///    (`vfs/indexed_db.dart:685-688`). sqlite calls `xSync` as part of
///    `COMMIT`, so on OPFS the commit is already durable when it returns.
///
/// This flag stays `true` for the whole web platform regardless, on purpose:
///
///  * The cost on OPFS is one `SELECT 1` per top-level transaction, whose
///    flush does nothing. Row 3 above is that configuration, measured green.
///  * Both IndexedDB variants take the same `writeAutomatically: false`
///    branch, so both need it — and BOTH remain live in production. Any
///    install first served before the COOP/COEP headers shipped is pinned to
///    IndexedDB forever by `_selectExistingDatabase` (the L8 lock-in
///    documented in `openConnection` below), and a browser without
///    `SharedWorker` (Safari) cannot be offered `sharedIndexedDb` at all —
///    its only options are `opfsLocks` or `unsafeIndexedDb`
///    (`wasm_setup.dart:114-137`, `:142+`).
///  * The failure directions are not symmetric. Keying this on the runtime
///    verdict would buy one skipped no-op statement per transaction, and risk
///    silent permanent data loss if the verdict were ever wrong, late, or
///    missing. Unconditionally-on is the safe default; the wasted statement is
///    the price, and it is a rounding error next to what it insures against.
///
/// NOT measured: iOS Safari, which is the app's primary target and is neither
/// of the two rows above. Which backend it picks is a real open question (see
/// the `SharedWorker` note), and if it lands on `unsafeIndexedDb` then the
/// original loss applies to it in full and this flag is what prevents it.
const bool commitNeedsExplicitFlush = true;

/// Web connection — drift on WASM (OPFS-via-worker where available, IndexedDB
/// fallback). Assets `sqlite3.wasm` + `drift_worker.js` are pinned in web/.
///
/// [onStorageReport] receives drift's verdict — which storage implementation
/// was actually chosen, and which browser features were missing — exactly
/// once, as soon as `WasmDatabase.open`'s feature probe resolves. That
/// verdict used to be thrown away behind an `if (kDebugMode) debugPrint(...)`,
/// which is L1 in
/// `docs/superpowers/specs/2026-07-30-web-offline-reliability-design.md`:
/// `WasmDatabase.open` NEVER throws, it silently degrades to
/// `WasmStorageImplementation.inMemory` ("doesn't store anything"), so every
/// write succeeds, every list populates, and the whole library is gone on the
/// next page load with zero production signal.
///
/// If `WasmDatabase.open` itself THROWS instead of degrading, there is no
/// result to report and no executor to return — every query on this database
/// will fail loudly regardless of what happens here. What this `catch` adds
/// is observability: without it, `storageDurabilityProvider` would never see
/// a success-path report and would stay `probing` forever, which the
/// create-topo interlock reads as "allow creation" — exactly the gap §1a
/// exists to close. So it reports [StorageDurability.unavailable] (which
/// counts as `isEphemeral`, blocking creation) and then rethrows unchanged —
/// this does not swallow the error or attempt to fabricate a working
/// database.
QueryExecutor openConnection({
  void Function(StorageDurability verdict)? onStorageReport,
}) {
  // Wrapping `result.resolvedExecutor` (a `DatabaseConnection`) in a bare
  // `LazyDatabase` would discard its `BroadcastStreamQueryStore`, silently
  // breaking cross-tab watch() invalidation. `DatabaseConnection.delayed`
  // preserves `streamQueries` (via a `DelayedStreamQueryStore`) while still
  // deferring the async WASM setup.
  return DatabaseConnection.delayed(Future(() async {
    try {
      // `moveExistingIndexedDbToOpfs` is deliberately left at drift's default
      // of `false` (drift-2.34.2/lib/wasm.dart:163).
      //
      // The cost of that default is real, and is accepted here. On every open,
      // `_selectExistingDatabase` (wasm.dart:183-210) pins the chosen
      // implementation back to whatever storage API an existing `climbtopo`
      // database already lives in — so any install that first landed on
      // IndexedDB (every visitor served before the COOP/COEP headers in
      // `web/_headers` shipped) stays on `sharedIndexedDb` forever, even once
      // the browser would happily give us OPFS. That is the L8 lock-in, and it
      // is NOT fixed here; it is knowingly traded away. `sharedIndexedDb` does
      // persist — it is drift's third-ranked implementation and is explicitly
      // not the one drift flags unsafe (that warning is reserved for
      // `unsafeIndexedDb`, wasm_setup/types.dart:78-83). OPFS is a performance
      // upgrade, not a durability requirement.
      //
      // Passing `true` was tried and reverted, and an earlier version of this
      // comment claimed it was "safe by drift's own construction… worst case
      // 'no upgrade', never 'no data'". That claim was FALSE. Verified against
      // drift 2.34.2's source:
      //
      //  - No lock. `moveIndexedDBDatabaseToOpfs`
      //    (drift/src/web/wasm_setup/indexeddb_to_opfs.dart:13-79) runs in the
      //    calling TAB, not in the worker, and takes no Web Lock — there is no
      //    `navigator.locks` call anywhere in drift 2.34.2 or sqlite3 3.5.0.
      //    Two tabs opening at once both run it, against the same files.
      //  - A crash window, with no recovery. `copyFile` calls
      //    `getFileHandle(file, create: true)` (:42) BEFORE writing a byte,
      //    and `opfsDatabases()` (wasm_setup/shared.dart:204-230) decides an
      //    OPFS database "exists" purely by whether that handle resolves — it
      //    never reads `meta`, never checks the size. So from :42 until the
      //    move completes, a killed tab leaves a zero-byte OPFS `database`
      //    advertised as real. Drift has no in-progress marker and nothing
      //    repairs it on the next boot. This is not a remote risk: the move
      //    buffers the WHOLE database into one `Uint8List` on the main thread
      //    during boot, which is exactly when iOS Safari reclaims a tab.
      //  - Which copy then wins is a coin flip. With both an IndexedDB and an
      //    OPFS `climbtopo` present, `_selectExistingDatabase`
      //    (wasm.dart:227-252) returns the FIRST match in probe-insertion
      //    order — not the one holding data. If it picks OPFS, sqlite sees a
      //    zero-length file, creates a fresh database, drift runs `onCreate`,
      //    and the library is empty. The real rows are still sitting in
      //    IndexedDB, but nothing in the app will ever look there again.
      //  - And it would report GREEN. `chosenImplementation` would be
      //    `opfsShared`, which `_backendOf` maps to our most durable verdict,
      //    for a database that just lost everything. `resolvedExecutor` is
      //    lazy, so `WasmDatabase.open` returning successfully says nothing
      //    about the data behind it. The interlock cannot catch this one.
      //
      // Drift's try/catch around the move (wasm.dart:197-202) does not rescue
      // any of that: it catches thrown exceptions inside a live JS context,
      // never process death, and the fallback it guards (:205-208,
      // `firstWhere((e) => e.storageApi == currentDb)`) never re-checks that
      // the fallback target still exists. Hence the two-tab race: tab A
      // finishes the move and deletes the IndexedDB source
      // (indexeddb_to_opfs.dart:72-79), tab B's concurrent attempt throws on
      // the OPFS write conflict, is swallowed, and tab B reopens the
      // just-deleted IndexedDB database — which IndexedDB silently re-creates
      // EMPTY, and tab B starts writing into it.
      //
      // A `navigator.locks` guard of our own would fix only the two-tab race;
      // locks are released when a tab dies, so the crash window would survive
      // untouched, and the unguarded `getFileHandle` sits inside drift's own
      // function where we cannot interpose. Re-enable this only behind a
      // genuinely crash-safe migration (own in-progress marker, partial-OPFS
      // cleanup before open), proven on a real cross-origin-isolated browser.
      final result = await WasmDatabase.open(
        databaseName: 'climbtopo',
        sqlite3Uri: Uri.parse('sqlite3.wasm'),
        driftWorkerUri: Uri.parse('drift_worker.js'),
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
    } catch (error) {
      onStorageReport?.call(StorageDurability.unavailable('$error'));
      rethrow;
    }
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
