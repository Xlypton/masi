/// Web-only byte key-value store backing photo persistence.
///
/// On the web build, photo/thumbnail bytes are NOT stored in the drift
/// SQLite DB (drift-web has no filesystem to point at, and stuffing large
/// blobs into SQLite rows is wasteful). Instead they live in the browser's
/// IndexedDB, addressed by the same logical path strings used elsewhere
/// (e.g. `photos/<id>.jpg`, `thumbs/<id>.jpg`).
///
/// Backend: `package:idb_shim`. Its native-web implementation
/// (`package:idb_shim/idb_client_native.dart`) is built on `package:web` +
/// `dart:js_interop` — NOT `dart:html`/`dart:indexed_db` — so it is
/// dart2wasm-clean, which matters because wasm is the default web build
/// target for this app. idb_shim also ships an in-memory factory
/// (`newIdbFactoryMemory()`) backed by `sembast`, which runs on the plain
/// Dart VM, so the store's logic is exercised by real unit tests instead of
/// being browser-only and untestable. The `IdbFactory` is an injectable
/// constructor parameter for exactly this reason.
library;

import 'dart:typed_data';

import 'package:idb_shim/idb_client_native.dart' as idb;

/// Logical-path-keyed byte store. One implementation per platform; the web
/// build wires up [createPhotoByteStore] to the IndexedDB-backed impl.
abstract class PhotoByteStore {
  /// Writes [bytes] under [key], creating or overwriting the record.
  Future<void> writeBytes(String key, Uint8List bytes);

  /// Reads the bytes stored under [key], or `null` if there is no record.
  Future<Uint8List?> readBytes(String key);

  /// Deletes the record at [key]. A no-op if [key] is absent.
  Future<void> delete(String key);

  /// Whether a record exists at [key].
  Future<bool> exists(String key);
}

/// Returns the real, browser-backed [PhotoByteStore].
PhotoByteStore createPhotoByteStore() => IdbPhotoByteStore();

/// The name of the IndexedDB database and its single object store.
const String kPhotoByteStoreDbName = 'climbtopo-photos';
const String kPhotoByteStoreName = 'photos';
const int _dbVersion = 1;

/// [PhotoByteStore] backed by a single IndexedDB object store, keyed
/// directly by the logical path string (out-of-line keys, no `keyPath`).
///
/// The [idb.IdbFactory] is injectable so tests can pass
/// `idb_shim`'s `newIdbFactoryMemory()` and exercise this class's real
/// logic on the Dart VM. Defaults to the real browser factory
/// (`idb.idbFactoryWeb`) in production, which is only ever evaluated when no
/// factory is supplied.
class IdbPhotoByteStore implements PhotoByteStore {
  IdbPhotoByteStore({idb.IdbFactory? factory})
    : _factory = factory ?? idb.idbFactoryWeb;

  final idb.IdbFactory _factory;
  Future<idb.Database>? _dbFuture;

  Future<idb.Database> _openDb() {
    return _dbFuture ??= _factory.open(
      kPhotoByteStoreDbName,
      version: _dbVersion,
      onUpgradeNeeded: (idb.VersionChangeEvent event) {
        final db = event.database;
        if (!db.objectStoreNames.contains(kPhotoByteStoreName)) {
          db.createObjectStore(kPhotoByteStoreName);
        }
      },
    );
  }

  @override
  Future<void> writeBytes(String key, Uint8List bytes) async {
    final db = await _openDb();
    final txn = db.transaction(kPhotoByteStoreName, idb.idbModeReadWrite);
    final store = txn.objectStore(kPhotoByteStoreName);
    await store.put(bytes, key);
    await txn.completed;
  }

  @override
  Future<Uint8List?> readBytes(String key) async {
    final db = await _openDb();
    final txn = db.transaction(kPhotoByteStoreName, idb.idbModeReadOnly);
    final store = txn.objectStore(kPhotoByteStoreName);
    final value = await store.getObject(key);
    await txn.completed;
    return _asBytes(value);
  }

  @override
  Future<void> delete(String key) async {
    final db = await _openDb();
    final txn = db.transaction(kPhotoByteStoreName, idb.idbModeReadWrite);
    final store = txn.objectStore(kPhotoByteStoreName);
    // idb's ObjectStore.delete() is idempotent: deleting an absent key
    // simply does nothing (no exception).
    await store.delete(key);
    await txn.completed;
  }

  @override
  Future<bool> exists(String key) async {
    final db = await _openDb();
    final txn = db.transaction(kPhotoByteStoreName, idb.idbModeReadOnly);
    final store = txn.objectStore(kPhotoByteStoreName);
    // Use getKey rather than getObject so a presence check never has to load
    // the (potentially multi-MB) photo blob into memory.
    final foundKey = await store.getKey(key);
    await txn.completed;
    return foundKey != null;
  }

  Uint8List? _asBytes(Object? value) {
    if (value == null) return null;
    if (value is Uint8List) return value;
    if (value is List<int>) return Uint8List.fromList(value);
    return null;
  }
}
