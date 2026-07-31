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
///
/// Comes in three shapes: not-yet-known ([probing]), a chosen backend (the
/// default constructor, [backend] non-null), or a failed open where no
/// backend was ever chosen at all ([unavailable] — e.g. `WasmDatabase.open`
/// itself throwing in `connection_web.dart`).
@immutable
class StorageDurability {
  const StorageDurability({
    required this.backend,
    this.missingFeatures = const {},
  })  : unavailable = false,
        unavailableReason = null;

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
        missingFeatures = const {},
        unavailable = false,
        unavailableReason = null;

  /// The connection layer's open call itself threw, so no [backend] was ever
  /// chosen. [unavailableReason] is a short description (typically the
  /// caught exception's `toString()`) so a "my data vanished" report is
  /// answerable from the log line alone.
  ///
  /// Unlike [probing] this IS a verdict — [isProbing] is false. It counts as
  /// [isEphemeral], so the create-topo interlock blocks creation exactly as
  /// it does for [StorageBackend.inMemory]: a database that could not even be
  /// opened cannot be trusted with new data either. This does not attempt to
  /// recover or fabricate a working database — see `connection_web.dart`'s
  /// `catch` around `WasmDatabase.open` for the only production caller.
  const StorageDurability.unavailable(this.unavailableReason)
      : backend = null,
        missingFeatures = const {},
        unavailable = true;

  /// `null` while [isProbing] or [unavailable] — nothing was ever chosen.
  final StorageBackend? backend;

  /// Empty on native and whenever drift found everything it looked for.
  final Set<StorageMissingFeature> missingFeatures;

  /// True when the connection layer's open call itself threw before any
  /// backend could be chosen. See [StorageDurability.unavailable].
  final bool unavailable;

  /// Short description of why [unavailable] is true. `null` unless
  /// [unavailable].
  final String? unavailableReason;

  /// No verdict yet. False once ANY verdict has landed — [unavailable] is
  /// itself a (bad) verdict, not an absence of one.
  bool get isProbing => backend == null && !unavailable;

  /// The backend is KNOWN to keep data across a reload. Always false when
  /// [unavailable]: there is no backend to be durable.
  bool get isDurable => !unavailable && (backend?.isDurable ?? false);

  /// The backend is KNOWN to lose data across a reload, or the database could
  /// not even be opened ([unavailable]). This is the single condition the
  /// create-topo interlock blocks on.
  bool get isEphemeral =>
      unavailable || (backend != null && !backend!.isDurable);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StorageDurability &&
          other.backend == backend &&
          setEquals(other.missingFeatures, missingFeatures) &&
          other.unavailable == unavailable &&
          other.unavailableReason == unavailableReason);

  @override
  int get hashCode => Object.hash(
        backend,
        Object.hashAllUnordered(missingFeatures),
        unavailable,
        unavailableReason,
      );

  @override
  String toString() =>
      'StorageDurability(backend: $backend, durable: $isDurable, '
      'missingFeatures: $missingFeatures, unavailable: $unavailable'
      '${unavailableReason == null ? '' : ', unavailableReason: $unavailableReason'})';
}

/// Logs [durability] — deliberately NOT behind `kDebugMode`.
///
/// This line is the only thing that can answer a "my data vanished" web
/// report (design doc §1a / L1), and a RELEASE web build is exactly where it
/// matters, so it must not be compiled out. `debugPrint` is the repo's
/// standard log call (38 other sites) and is a plain mutable top-level
/// function that still forwards to `print` in release builds — on web that
/// reaches the browser console, where `masi/storage:` is greppable.
/// `test/core/db/storage_durability_test.dart` swaps `debugPrint` out to
/// assert this fires; `test/core/db/connection_seam_source_test.dart`
/// asserts no `kDebugMode` gate has crept back into `lib/`.
void logStorageDurability(StorageDurability durability) {
  final missing = durability.missingFeatures.map((f) => f.name).toList()
    ..sort();
  final backendLabel = durability.unavailable
      ? 'unavailable'
      : durability.backend?.name ?? 'probing';
  final reasonSuffix = durability.unavailable
      ? ' reason=${durability.unavailableReason}'
      : '';
  debugPrint(
    'masi/storage: backend=$backendLabel '
    'durable=${durability.isDurable} '
    'missingFeatures=${missing.join(',')}'
    '$reasonSuffix',
  );
}
