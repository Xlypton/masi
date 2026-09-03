/// Persistent, byte-accounted store for map tiles on web.
///
/// Backend: `package:idb_shim`, exactly like `PhotoByteStore` — its native-web
/// implementation is `package:web` + `dart:js_interop` (dart2wasm-clean, which
/// matters because wasm is this app's default web build), and it ships an
/// in-memory factory (`newIdbFactoryMemory()`) that runs on the plain Dart VM,
/// so every line below is covered by real unit tests instead of being
/// browser-only.
///
/// A SEPARATE IndexedDB database from `climbtopo-photos` on purpose: tiles are
/// derivable and disposable, photos are not, and keeping them apart means a
/// wholesale tile-cache drop (the quota-pressure response — see
/// `CachingVectorTileProvider`) can never touch a single photo byte.
library;

import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:idb_shim/idb_client_native.dart' as idb;

/// One cached tile: its bytes plus everything needed to decide freshness and
/// LRU order without loading the bytes again.
class CachedTileRecord {
  const CachedTileRecord({
    required this.bytes,
    required this.staleAtMs,
    required this.lastModifiedMs,
    required this.etag,
    required this.sizeBytes,
    required this.lastUsedMs,
  });

  final Uint8List bytes;

  /// Epoch millis at which this tile should be revalidated. Written by
  /// `CachingVectorTileProvider`, which deliberately overrides what the tile
  /// server asked for — see its doc for why.
  final int staleAtMs;

  final int? lastModifiedMs;
  final String? etag;
  final int sizeBytes;
  final int lastUsedMs;
}

/// Seam over the tile byte store so the caching provider is testable without
/// a browser and so a test can inject a store that throws.
abstract class TileCacheStore {
  /// Returns the record at [url] and marks it most-recently-used, or `null`.
  Future<CachedTileRecord?> read(String url);

  /// Inserts or replaces [url]'s bytes and metadata, marking it
  /// most-recently-used.
  Future<void> write(
    String url, {
    required Uint8List bytes,
    required int staleAtMs,
    int? lastModifiedMs,
    String? etag,
  });

  /// Marks [url] most-recently-used and optionally refreshes its freshness
  /// window, without rewriting its bytes. This is the HTTP-304 path: the
  /// server confirmed the tile is unchanged, so only the metadata moves.
  Future<void> touch(String url, {int? staleAtMs, String? etag});

  /// Total bytes currently stored.
  Future<int> totalBytes();

  /// Deletes least-recently-used tiles until [maxBytes] is not exceeded.
  Future<void> evictLruUntilUnder(int maxBytes);

  /// Removes everything.
  Future<void> clear();
}

const String kTileCacheDbName = 'masi-map-tiles';
const String kTileBytesStoreName = 'tiles';
const String kTileMetaStoreName = 'tile_meta';
const int _dbVersion = 1;

const String _kStaleAt = 'staleAt';
const String _kLastModified = 'lastModified';
const String _kEtag = 'etag';
const String _kSize = 'size';
const String _kLastUsed = 'lastUsed';

/// [TileCacheStore] over two IndexedDB object stores.
///
/// TWO stores rather than one indexed store, deliberately:
///  * `tiles` holds the raw [Uint8List] under an out-of-line key (the tile
///    URL) — the same shape `IdbPhotoByteStore` uses, which is the shape
///    proven to round-trip through BOTH the browser factory and sembast's
///    in-memory one. A typed array nested inside a map value is not.
///  * `tile_meta` holds a plain `Map<String, Object?>` of ints and strings.
///    Every LRU scan and freshness check reads only this store, so recency
///    bookkeeping never pulls kilobytes of PNG into memory — the same
///    reasoning behind `photo_byte_store.dart`'s `getKey`-over-`getObject`.
///
/// No IndexedDB index on `lastUsed`: the meta store holds a few thousand tiny
/// records, a cursor scan over it is cheap, and skipping the index keeps the
/// schema at a single `onUpgradeNeeded` with no future index migration.
class IdbTileCacheStore implements TileCacheStore {
  IdbTileCacheStore({idb.IdbFactory? factory, int Function()? nowMs})
    : _factoryOverride = factory,
      _nowMs = nowMs ?? _wallClockMs;

  static int _wallClockMs() => DateTime.now().millisecondsSinceEpoch;

  final idb.IdbFactory? _factoryOverride;

  /// Resolved LAZILY, on the first database open — never in the constructor.
  ///
  /// `idb.idbFactoryWeb` is a getter that `throw`s `UnimplementedError` off
  /// the web (`idb_shim/src/native_web/idb_native_stub.dart`), so reading it
  /// eagerly would make the production wiring un-constructible on the Dart
  /// VM, and with it every unit test that merely builds an
  /// `IdbTileCacheStore` to hand to a `CachingVectorTileProvider`. Deferring
  /// it to [_openDb] means those tests construct the real object graph and
  /// only a genuine I/O attempt would need a browser.
  idb.IdbFactory get _factory => _factoryOverride ?? idb.idbFactoryWeb;

  final int Function() _nowMs;
  Future<idb.Database>? _dbFuture;

  /// Running byte total. `null` until the first [totalBytes]/[write] forces a
  /// one-time scan — a fresh instance after a page reload must recompute it
  /// from what is actually on disk rather than starting from zero.
  int? _cachedTotal;

  /// Test-only: lets a test open a SECOND store over the same backing factory
  /// to model a page reload.
  @visibleForTesting
  idb.IdbFactory get debugFactory => _factory;

  /// Test-only: deletes a tile's BYTES while leaving its metadata behind, so a
  /// test can construct the torn-write state that [read] has to reap.
  @visibleForTesting
  Future<void> debugDeleteBytesOnly(String url) async {
    final db = await _openDb();
    final txn = db.transaction(kTileBytesStoreName, idb.idbModeReadWrite);
    await txn.objectStore(kTileBytesStoreName).delete(url);
    await txn.completed;
  }

  Future<idb.Database> _openDb() {
    return _dbFuture ??= _factory.open(
      kTileCacheDbName,
      version: _dbVersion,
      onUpgradeNeeded: (idb.VersionChangeEvent event) {
        final db = event.database;
        if (!db.objectStoreNames.contains(kTileBytesStoreName)) {
          db.createObjectStore(kTileBytesStoreName);
        }
        if (!db.objectStoreNames.contains(kTileMetaStoreName)) {
          db.createObjectStore(kTileMetaStoreName);
        }
      },
    );
  }

  @override
  Future<CachedTileRecord?> read(String url) async {
    final db = await _openDb();
    final txn = db.transaction([
      kTileBytesStoreName,
      kTileMetaStoreName,
    ], idb.idbModeReadWrite);
    final metaStore = txn.objectStore(kTileMetaStoreName);
    final meta = _asMeta(await metaStore.getObject(url));
    if (meta == null) {
      await txn.completed;
      return null;
    }
    final bytes = _asBytes(
      await txn.objectStore(kTileBytesStoreName).getObject(url),
    );
    if (bytes == null) {
      // Metadata without bytes is a torn write (an interrupted put, or a
      // partial eviction). Treat it as a miss and drop the orphan so the
      // total stays honest.
      await metaStore.delete(url);
      await txn.completed;
      _cachedTotal = null;
      return null;
    }
    final now = _nowMs();
    await metaStore.put({...meta, _kLastUsed: now}, url);
    await txn.completed;

    return CachedTileRecord(
      bytes: bytes,
      staleAtMs: meta[_kStaleAt] as int? ?? 0,
      lastModifiedMs: meta[_kLastModified] as int?,
      etag: meta[_kEtag] as String?,
      sizeBytes: meta[_kSize] as int? ?? bytes.length,
      lastUsedMs: now,
    );
  }

  @override
  Future<void> write(
    String url, {
    required Uint8List bytes,
    required int staleAtMs,
    int? lastModifiedMs,
    String? etag,
  }) async {
    final total = await totalBytes();
    final db = await _openDb();
    final txn = db.transaction([
      kTileBytesStoreName,
      kTileMetaStoreName,
    ], idb.idbModeReadWrite);
    final metaStore = txn.objectStore(kTileMetaStoreName);
    final previous = _asMeta(await metaStore.getObject(url));
    final previousSize = previous?[_kSize] as int? ?? 0;

    await txn.objectStore(kTileBytesStoreName).put(bytes, url);
    // Absent keys rather than explicit nulls: this is a full replacement of
    // the record, so omitting a field IS setting it to null on read, and it
    // keeps the map free of nulls that a JSON-shaped backend need not accept.
    await metaStore.put({
      _kStaleAt: staleAtMs,
      _kLastModified: ?lastModifiedMs,
      _kEtag: ?etag,
      _kSize: bytes.length,
      _kLastUsed: _nowMs(),
    }, url);
    await txn.completed;

    _cachedTotal = total - previousSize + bytes.length;
  }

  @override
  Future<void> touch(String url, {int? staleAtMs, String? etag}) async {
    final db = await _openDb();
    final txn = db.transaction(kTileMetaStoreName, idb.idbModeReadWrite);
    final store = txn.objectStore(kTileMetaStoreName);
    final meta = _asMeta(await store.getObject(url));
    if (meta != null) {
      await store.put({
        ...meta,
        _kStaleAt: ?staleAtMs,
        _kEtag: ?etag,
        _kLastUsed: _nowMs(),
      }, url);
    }
    await txn.completed;
  }

  @override
  Future<int> totalBytes() async {
    final cached = _cachedTotal;
    if (cached != null) return cached;
    var sum = 0;
    await _forEachMeta((key, meta) {
      sum += meta[_kSize] as int? ?? 0;
    });
    return _cachedTotal = sum;
  }

  @override
  Future<void> evictLruUntilUnder(int maxBytes) async {
    var total = await totalBytes();
    if (total <= maxBytes) return;

    // Scan in its OWN read-only transaction and materialise the order before
    // deleting anything: an idb transaction auto-closes once its microtask
    // queue drains, so interleaving a cursor stream with later writes inside
    // one transaction is a latent flake, not a saving.
    final entries = <({String url, int lastUsed, int size})>[];
    await _forEachMeta((key, meta) {
      entries.add((
        url: key,
        lastUsed: meta[_kLastUsed] as int? ?? 0,
        size: meta[_kSize] as int? ?? 0,
      ));
    });
    entries.sort((a, b) => a.lastUsed.compareTo(b.lastUsed));

    final doomed = <String>[];
    for (final entry in entries) {
      if (total <= maxBytes) break;
      doomed.add(entry.url);
      total -= entry.size;
    }
    if (doomed.isEmpty) return;

    final db = await _openDb();
    final txn = db.transaction([
      kTileBytesStoreName,
      kTileMetaStoreName,
    ], idb.idbModeReadWrite);
    final bytesStore = txn.objectStore(kTileBytesStoreName);
    final metaStore = txn.objectStore(kTileMetaStoreName);
    for (final url in doomed) {
      await bytesStore.delete(url);
      await metaStore.delete(url);
    }
    await txn.completed;
    _cachedTotal = total;
  }

  @override
  Future<void> clear() async {
    final db = await _openDb();
    final txn = db.transaction([
      kTileBytesStoreName,
      kTileMetaStoreName,
    ], idb.idbModeReadWrite);
    await txn.objectStore(kTileBytesStoreName).clear();
    await txn.objectStore(kTileMetaStoreName).clear();
    await txn.completed;
    _cachedTotal = 0;
  }

  Future<void> _forEachMeta(
    void Function(String key, Map<String, Object?> meta) visit,
  ) async {
    final db = await _openDb();
    final txn = db.transaction(kTileMetaStoreName, idb.idbModeReadOnly);
    final store = txn.objectStore(kTileMetaStoreName);
    await for (final cursor in store.openCursor(autoAdvance: true)) {
      final meta = _asMeta(cursor.value);
      if (meta != null) visit(cursor.key.toString(), meta);
    }
    await txn.completed;
  }

  Map<String, Object?>? _asMeta(Object? value) {
    if (value is Map) return value.cast<String, Object?>();
    return null;
  }

  Uint8List? _asBytes(Object? value) {
    if (value == null) return null;
    if (value is Uint8List) return value;
    if (value is List<int>) return Uint8List.fromList(value);
    return null;
  }
}
