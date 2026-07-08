import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_database.dart';
import '../../features/topo/data/library_repository.dart';
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
  ),
);

final libraryRepositoryProvider = Provider<LibraryRepository>(
  (ref) => LibraryRepository(
    ref.watch(appDatabaseProvider),
    nowMs: ref.watch(nowMsProvider),
  ),
);
