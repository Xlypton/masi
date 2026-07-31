import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_database.dart';
import 'connection/connection.dart';
import 'storage_durability_provider.dart';
import '../../features/account/application/auth_providers.dart';
import '../../features/topo/data/photo_files.dart';
import '../../features/topo/data/photo_repository.dart';
import '../../features/topo/data/route_repository.dart';

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
  final db = AppDatabase(
    openConnection(
      onStorageReport: (verdict) =>
          Future<void>.microtask(() => storage.report(verdict)),
    ),
  );
  ref.onDispose(() => db.close());
  return db;
});

/// The only place `DateTime.now()` is read for persistence timestamps, so
/// tests can override it with a deterministic clock.
final nowMsProvider = Provider<int Function()>(
  (ref) =>
      () => DateTime.now().millisecondsSinceEpoch,
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
