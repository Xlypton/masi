import 'package:flutter/foundation.dart';

/// Where the local database actually ended up living, as reported by the
/// platform connection layer (`connection_native.dart` on iOS/Android,
/// `connection_web.dart` in the browser).
///
/// Deliberately a masi-owned enum rather than drift's own
/// `WasmStorageImplementation`: that type lives behind
/// `package:drift/wasm.dart`, which imports `dart:js_interop` and therefore
/// cannot be compiled by the Dart VM — so nothing `flutter test` runs, and
/// nothing in a native build, may reference it. Keeping the vocabulary here
/// is what lets the provider, the release logging and the create-topo
/// interlock all be unit-tested under `flutter test`, while
/// `connection_web.dart` stays the ONLY file in the repo that knows drift's
/// web types exist. `connection_web.dart` maps drift's enum onto this one
/// with an exhaustive `switch`, so a drift upgrade that adds a storage
/// implementation is a `flutter analyze` error rather than a silent
/// mis-report.
enum StorageBackend {
  /// iOS/Android/desktop: a real sqlite file in the app documents directory.
  /// Always durable; there is nothing to probe.
  nativeFile,

  /// drift `WasmStorageImplementation.opfsShared` — OPFS hosted in a shared
  /// worker. drift's preferred web backend.
  opfsShared,

  /// drift `WasmStorageImplementation.opfsLocks` — OPFS behind two dedicated
  /// workers using `Atomics.wait`. Requires cross-origin isolation, i.e. the
  /// COOP/COEP headers in `web/_headers`.
  opfsLocks,

  /// drift `WasmStorageImplementation.sharedIndexedDb` — IndexedDB hosted in
  /// a shared worker.
  sharedIndexedDb,

  /// drift `WasmStorageImplementation.unsafeIndexedDb` — IndexedDB from the
  /// main browsing context. Persistent, but drift documents it as unable to
  /// prevent cross-tab data races (L8; the race half is out of scope here).
  unsafeIndexedDb,

  /// drift `WasmStorageImplementation.inMemory`, which drift documents as
  /// "doesn't store anything".
  ///
  /// This is L1. `WasmDatabase.open` NEVER throws: when none of the browser
  /// features it needs are available it silently returns this. Every write
  /// succeeds, every list populates, and the entire library is gone on the
  /// next page load.
  inMemory;

  /// Whether data written to this backend survives a page reload / app
  /// restart. Note [unsafeIndexedDb] counts as durable — it is race-prone
  /// across tabs, but it does persist.
  bool get isDurable => this != StorageBackend.inMemory;
}

/// Browser features drift probed for and did not find. Mirrors drift's
/// `MissingBrowserFeature` name-for-name without importing it — see
/// [StorageBackend] for why.
enum StorageMissingFeature {
  sharedWorkers,
  dedicatedWorkers,
  dedicatedWorkersInSharedWorkers,
  fileSystemAccess,
  indexedDb,
  sharedArrayBuffers,
  workerError,
}

/// The platform connection layer's verdict on local persistence.
@immutable
class StorageDurability {
  const StorageDurability({
    required this.backend,
    this.missingFeatures = const {},
  });

  /// The state before any verdict has arrived.
  ///
  /// Only ever observed on web, and only for as long as
  /// `WasmDatabase.open`'s browser-feature probe takes — it starts the moment
  /// `appDatabaseProvider` is first read (during boot), well before a user
  /// gesture can reach the "New topo" flow. Native reports synchronously and
  /// is never in this state after its first `appDatabaseProvider` read.
  ///
  /// Deliberately counts as "allow creation": [isEphemeral] is false here, so
  /// the interlock blocks only on a KNOWN-bad backend, never on a
  /// not-yet-known one. Blocking on `probing` would also disable creation in
  /// every widget test (which overrides `appDatabaseProvider` and so never
  /// runs `openConnection`).
  const StorageDurability.probing()
      : backend = null,
        missingFeatures = const {};

  /// `null` while [isProbing].
  final StorageBackend? backend;

  /// Empty on native and whenever drift found everything it looked for.
  final Set<StorageMissingFeature> missingFeatures;

  /// No verdict yet.
  bool get isProbing => backend == null;

  /// The backend is KNOWN to keep data across a reload.
  bool get isDurable => backend?.isDurable ?? false;

  /// The backend is KNOWN to lose data across a reload. This is the single
  /// condition the create-topo interlock blocks on.
  bool get isEphemeral => backend != null && !backend!.isDurable;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StorageDurability &&
          other.backend == backend &&
          setEquals(other.missingFeatures, missingFeatures));

  @override
  int get hashCode =>
      Object.hash(backend, Object.hashAllUnordered(missingFeatures));

  @override
  String toString() =>
      'StorageDurability(backend: $backend, durable: $isDurable, '
      'missingFeatures: $missingFeatures)';
}

/// Logs [durability] — deliberately not gated behind a debug-only build flag.
///
/// This line is the only thing that can answer a "my data vanished" web
/// report (design doc §1a / L1), and a RELEASE web build is exactly where it
/// matters, so it must not be compiled out. `debugPrint` is the repo's
/// standard log call (38 other sites) and is a plain mutable top-level
/// function that still forwards to `print` in release builds — on web that
/// reaches the browser console, where `masi/storage:` is greppable.
/// `test/core/db/storage_durability_test.dart` swaps `debugPrint` out to
/// assert this fires; `test/core/db/connection_seam_source_test.dart`
/// asserts no debug-only logging gate has crept back into `lib/`.
void logStorageDurability(StorageDurability durability) {
  final missing = durability.missingFeatures.map((f) => f.name).toList()
    ..sort();
  debugPrint(
    'masi/storage: backend=${durability.backend?.name ?? 'probing'} '
    'durable=${durability.isDurable} '
    'missingFeatures=${missing.join(',')}',
  );
}
