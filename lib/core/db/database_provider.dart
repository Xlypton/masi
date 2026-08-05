import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_database.dart';
import 'connection/connection.dart';
import 'connection/query_timeout.dart';
import 'schema_downgrade.dart';
import 'settings_store.dart';
import 'storage_durability_provider.dart';
import '../../features/account/application/auth_providers.dart';
import '../../features/topo/data/photo_files.dart';
import '../../features/topo/data/photo_repository.dart';
import '../../features/topo/data/route_repository.dart';

/// The per-operation database bound in effect, or `null` for "unbounded".
///
/// WEB-ONLY, and deliberately so. Both wedge modes [bindQueryTimeout] exists
/// for are web-only: the sqlite3 OPFS VFS's
/// `Atomics.wait(int32View, _responseIndex, -1)` inside a worker, and drift's
/// worker-side `LazyDatabase` (`wasm_setup/shared.dart:284`). On native a stall
/// is a file lock or a corrupt database, which a Dart timeout neither fixes nor
/// diagnoses — so bounding there would trade an executor-identity change across
/// ~160 call sites on the primary shipped platform, against 1930+ green tests,
/// for zero known benefit.
///
/// `kIsWeb` rather than a conditional import, per CLAUDE.md's convention: this
/// is a BEHAVIOURAL gate on a platform-capable code path with no `dart:io`
/// anywhere near it, and a conditional import would require editing
/// `connection_native.dart`, which must stay bit-identical.
///
/// Exposed as an overridable provider because `kIsWeb` is permanently FALSE
/// under `flutter test`: without this seam the gate would be entirely
/// unobservable, and every property of the wiring below untestable. The
/// negative (native -> `null`) is asserted in
/// `test/core/db/database_provider_test.dart`; that the gate actually engages
/// on web can only be shown in a real browser
/// (`integration_test/web_query_timeout_test.dart`).
final databaseQueryTimeoutProvider = Provider<Duration?>(
  (ref) => kIsWeb ? kDatabaseQueryTimeout : null,
);

/// Turns [QueryTimeoutInterceptor]'s stall/recovery signals into storage
/// verdicts, REVERSIBLY.
///
/// Lifted out of [appDatabaseProvider]'s body for the same reason
/// [probeDatabaseUsable] was lifted out of [verifyDatabaseUsable]: the policy
/// is the part worth testing, and it cannot be tested through the provider
/// because `flutter test` always resolves the native connection seam, where a
/// real `NativeDatabase` never stalls.
///
/// Both callbacks are SYNCHRONOUS. The microtask deferral belongs at the wiring
/// site (see [appDatabaseProvider]), matching how `onStorageReport` is already
/// deferred there.
class StorageStallReporter {
  StorageStallReporter({
    required this.current,
    required this.report,
    required this.timeout,
  });

  /// Reads the verdict currently in effect. May THROW if the container behind
  /// it is gone — see [onStall].
  final StorageDurability Function() current;

  final void Function(StorageDurability) report;

  /// Only used to word the reason. The bound itself is applied by
  /// [bindQueryTimeout].
  final Duration timeout;

  /// The verdict this reporter published, kept so [onRecovered] can tell "the
  /// stall verdict is still in effect" from "something newer has landed since".
  StorageDurability? _published;

  /// The verdict [onStall] displaced, kept so [onRecovered] can put it back.
  StorageDurability? _replaced;

  /// Publishes the stall.
  ///
  /// [StorageDurability.unavailableOver], NEVER plain
  /// `StorageDurability.unavailable`: the plain constructor hard-zeroes
  /// `measuredBackend` and `missingFeatures`, which is exactly the bug commit
  /// `340ba7b` fixed. Production measures
  /// `backend: opfsLocks, missingFeatures: {dedicatedWorkersInSharedWorkers}`
  /// seconds before any stall verdict can exist, and those two fields are the
  /// ONLY field-diagnosable facts this app ever learns about a browser's
  /// storage — a real field report came back with no `· missing: …` segment for
  /// precisely this reason.
  ///
  /// One report per stall. `QueryTimeoutInterceptor` already de-duplicates
  /// `onStall`, and that de-duplication is load-bearing here: a second call
  /// during the same stall would snapshot the stall verdict into [_replaced]
  /// and make [onRecovered] "restore" the failure.
  void onStall() {
    final StorageDurability replaced;
    try {
      replaced = current();
    } catch (error) {
      // The container is gone (a hot restart tearing down mid-flight). Logged
      // unconditionally, like `logStorageDurability`: on a release web build
      // this line is the only record. Same shape as `main.dart`'s
      // `_reportStalledStorageAtBoot`.
      debugPrint('masi/storage: a stalled query had nowhere to report: $error');
      return;
    }
    final verdict = StorageDurability.unavailableOver(
      replaced,
      'a database query did not answer within ${describeQueryBound(timeout)}',
    );
    _replaced = replaced;
    _published = verdict;
    report(verdict);
  }

  /// Restores the displaced verdict — but ONLY if the verdict published by
  /// [onStall] is still the one in effect.
  ///
  /// A verdict reported after ours is a NEWER FACT and must survive; blindly
  /// restoring the snapshot would resurrect a stale verdict over it. Same
  /// discipline as `main.dart`'s `_reportStalledStorageAtBoot`.
  ///
  /// A no-op when nothing was ever published, so the healthy path costs one
  /// null check.
  void onRecovered() {
    final published = _published;
    final replaced = _replaced;
    if (published == null || replaced == null) return;
    _published = null;
    _replaced = null;
    try {
      if (current() != published) return;
    } catch (error) {
      debugPrint('masi/storage: a recovered query had nowhere to report: '
          '$error');
      return;
    }
    report(replaced);
  }
}

/// Opens the on-device [AppDatabase], deferring the actual file-system/SQLite
/// work until first use via [LazyDatabase] so constructing this provider
/// never blocks.
///
/// Intended to be OVERRIDDEN in tests with an in-memory
/// `AppDatabase(NativeDatabase.memory())`.
final appDatabaseProvider = Provider<AppDatabase>((ref) {
  // The connection layer's storage verdict (native: "a real sqlite file, so
  // durable"; web: whatever `WasmDatabase.open`'s browser-feature probe
  // resolved to) is published on `storageDurabilityProvider` instead of being
  // discarded — that discard is L1 in
  // `docs/superpowers/specs/2026-07-30-web-offline-reliability-design.md`.
  //
  // The notifier is captured HERE, at build time, rather than `ref.read` from
  // inside the callback: on web that callback fires long after this build
  // returns, and reaching through a possibly-disposed `ref` then would throw.
  //
  // The report is deferred by one microtask because `connection_native.dart`
  // calls `onStorageReport` SYNCHRONOUSLY, i.e. while this provider is still
  // initializing — and Riverpod asserts "Providers are not allowed to modify
  // other providers during their initialization."
  // (riverpod/src/core/element.dart). One microtask puts the state write
  // safely outside both this build and any widget build that triggered it; on
  // web it changes nothing, since the callback is already asynchronous.
  // `report()` is itself `ref.mounted`-guarded, so a verdict that lands after
  // teardown is logged and dropped rather than crashing.
  final storage = ref.read(storageDurabilityProvider.notifier);
  // `null` off web — see `databaseQueryTimeoutProvider`, where the whole
  // platform decision and the reason it is a provider at all are recorded.
  final timeout = ref.watch(databaseQueryTimeoutProvider);
  // `ref.mounted`-guarded rather than captured: unlike `storage.report`, which
  // has its own guard, reading a provider off a disposed container throws, and
  // this callback can fire tens of seconds after the read that built it.
  final reporter = timeout == null
      ? null
      : StorageStallReporter(
          current: () => ref.mounted
              ? ref.read(storageDurabilityProvider)
              : throw StateError('the provider container is gone'),
          report: storage.report,
          timeout: timeout,
        );
  final db = AppDatabase(
    // Turns a database that never answers into a NAMED error, so the 17
    // `watch()`-backed providers surface an error state instead of hanging
    // silently — and so `storageRetryNotice`/`storageBlockedNotice` and the
    // create-topo interlock, all of which already exist, light up. It does NOT
    // unwedge anything; see `bindQueryTimeout`.
    //
    // Both callbacks are deferred by one microtask for the same reason
    // `onStorageReport` below is: Riverpod forbids one provider modifying
    // another during initialization, and putting the state write on a later
    // turn of the event loop keeps it outside both this build and any widget
    // build that triggered it.
    bindQueryTimeout(
      openConnection(
        onStorageReport: (verdict) =>
            Future<void>.microtask(() => storage.report(verdict)),
      ),
      timeout: timeout,
      onStall: reporter == null
          ? null
          : () => Future<void>.microtask(reporter.onStall),
      onRecovered: reporter == null
          ? null
          : () => Future<void>.microtask(reporter.onRecovered),
    ),
  );
  ref.onDispose(() => db.close());
  return db;
});

/// Proves the local database can actually ANSWER, and publishes
/// [StorageDurability.unavailable] if it cannot.
///
/// The connection layer's verdict is reported before the database has done
/// any real work, on both platforms:
///  - native's `openConnection` reports `nativeFile` SYNCHRONOUSLY around an
///    unopened `LazyDatabase` (`connection_native.dart`);
///  - on web, `WasmDatabase.open`'s `resolvedExecutor` is a connection to a
///    worker whose own sqlite open is itself deferred behind a `LazyDatabase`
///    (`drift-2.34.2/lib/src/web/wasm_setup/shared.dart:284`), so the whole
///    `WasmSqlite3.loadFromUrl` + VFS setup happens on the FIRST QUERY, well
///    after `connection_web.dart` reported which backend was chosen.
///
/// A green `opfsShared`/`opfsLocks`/`nativeFile` verdict is therefore not
/// evidence that storage works — only a completed query is. Without this, a
/// worker that reports green and then fails on its first statement leaves
/// `topos_screen` with creation ENABLED and no warning banner: the L1
/// silent-data-loss shape the verdict exists to end.
///
/// Called from `main.dart`'s pre-first-frame `Future.wait`, where it shares
/// `hydrate()`'s `ensureOpen` (so it costs one trivial statement, not a
/// second open) and is bounded by the same `awaitBootWork` deadlines. Never
/// throws: boot must not be taken down by its own probe.
Future<void> verifyDatabaseUsable(ProviderContainer container) =>
    probeDatabaseUsable(
      openDatabase: () => container.read(appDatabaseProvider),
      report: container.read(storageDurabilityProvider.notifier).report,
    );

/// [verifyDatabaseUsable]'s body, with the two provider reads lifted into
/// parameters.
///
/// Exists because the probe now has TWO callers that reach it through
/// different Riverpod handles: boot holds a [ProviderContainer], while
/// `StorageRetryController` (`storage_retry_provider.dart`) holds a `Ref`, and
/// the two share no common `read` interface. Keeping one probe rather than two
/// matters for correctness, not tidiness: the retry must publish its verdict
/// through exactly the same statement and the same classification as boot, or
/// "retry" would come to mean something subtly different from "boot".
///
/// [openDatabase] is a CALLBACK, not an [AppDatabase], so that a synchronously
/// throwing `openConnection` (native's shape) is caught here too — this
/// function's contract is that it never throws.
Future<void> probeDatabaseUsable({
  required AppDatabase Function() openDatabase,
  required void Function(StorageDurability) report,
}) async {
  try {
    await openDatabase().customSelect('SELECT 1').get();
  } catch (error) {
    // The CAUSE is classified here rather than left for the UI to infer from
    // the reason string: an L7 refusal and a dead storage backend both land on
    // `unavailable`, but they are opposite news for the user — a downgrade
    // means the library is provably intact and needs a newer app, a failure
    // means storage itself is unusable. See `StorageUnavailableCause`.
    report(
      StorageDurability.unavailable(
        '$error',
        cause: error is SchemaDowngradeException
            ? StorageUnavailableCause.schemaDowngrade
            : StorageUnavailableCause.failed,
      ),
    );
  }
}

/// The only place `DateTime.now()` is read for persistence timestamps, so
/// tests can override it with a deterministic clock.
final nowMsProvider = Provider<int Function()>(
  (ref) =>
      () => DateTime.now().millisecondsSinceEpoch,
);

/// The shared [SettingsStore] over the local-only `AppSettings` table, wired
/// to the same [appDatabaseProvider]/[nowMsProvider] seams every repository
/// provider here uses. Override `appDatabaseProvider` in tests, as usual.
final settingsStoreProvider = Provider<SettingsStore>(
  (ref) => SettingsStore(
    ref.watch(appDatabaseProvider),
    nowMs: ref.watch(nowMsProvider),
  ),
);

final routeRepositoryProvider = Provider<RouteRepository>(
  (ref) => RouteRepository(
    ref.watch(appDatabaseProvider),
    nowMs: ref.watch(nowMsProvider),
    currentUid: ref.watch(currentUidProvider),
  ),
);

/// Single [PhotoFiles] instance shared by every repository that resolves
/// `Photos.localPath` values (`photoRepositoryProvider`,
/// `libraryCrudRepositoryProvider`), so its memoized docs-path cache
/// (`_cachedDocsPath`) is warmed exactly ONCE and visible everywhere.
///
/// Deliberately does NOT depend on [currentUidProvider] (or any other
/// auth-driven provider): the docs-path cache has nothing to do with who is
/// signed in, and depending on auth would tear down and rebuild a fresh,
/// cold `PhotoFiles` on every sign-in/out — defeating the whole point of
/// pre-warming it once at startup (see `main.dart`).
final photoFilesProvider = Provider<PhotoFiles>((ref) => PhotoFiles());

final photoRepositoryProvider = Provider<PhotoRepository>(
  (ref) => PhotoRepository(
    ref.watch(appDatabaseProvider),
    nowMs: ref.watch(nowMsProvider),
    currentUid: ref.watch(currentUidProvider),
    photoFiles: ref.watch(photoFilesProvider),
  ),
);

/// Live list of a wall's `kind:'original'` photos (the multi-photo strip),
/// ordered by [PhotoRef.sortOrder] then `createdAt` — a thin
/// `StreamProvider.autoDispose.family` wrapper around
/// [PhotoRepository.watchWallOriginals]. `autoDispose` so leaving the
/// wall/topo whose strip this backs drops the cached subscription rather
/// than keeping it alive app-lifetime for every wall ever opened.
final wallOriginalsProvider =
    StreamProvider.autoDispose.family<List<PhotoRef>, String>(
  (ref, wallId) => ref.watch(photoRepositoryProvider).watchWallOriginals(wallId),
);
