import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_database.dart';
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
  final db = AppDatabase(_openConnection());
  ref.onDispose(() => db.close());
  return db;
});

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'climbtopo.sqlite'));
    return NativeDatabase(file);
  });
}

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
