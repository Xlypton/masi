import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'storage_durability.dart';

/// Native (iOS/Android/desktop) connection — opens climbtopo.sqlite in the
/// app documents directory. Byte-identical to the pre-split implementation.
///
/// [onStorageReport] is invoked exactly once, SYNCHRONOUSLY, before the
/// executor is returned. A real sqlite file on the device filesystem is
/// unconditionally durable — there is nothing to probe and nothing that can
/// degrade — so reporting up front means the create-topo interlock
/// (`topos_screen.dart`) is already in its final `durable` state on the very
/// first frame, and `StorageDurability.probing` is a web-only state in
/// practice. Nothing about HOW the database is opened changed: same documents
/// directory, same filename, same `NativeDatabase`, still lazy.
QueryExecutor openConnection({
  void Function(StorageDurability verdict)? onStorageReport,
}) {
  onStorageReport?.call(
    const StorageDurability(backend: StorageBackend.nativeFile),
  );
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'climbtopo.sqlite'));
    return NativeDatabase(file);
  });
}
