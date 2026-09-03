/// Persistent basemap caching for the WEB build, layered onto
/// `flutter_map_vector_tiles`.
///
/// The package caches tiles on disk on every platform except the one this app
/// primarily ships to: its own docs say web "has no persistent tile cache:
/// tiles fall back to the in-memory cache and the browser's own HTTP cache".
/// An in-memory cache dies with the tab and the browser HTTP cache is not
/// something an app can size, inspect or rely on — so at a crag with no signal
/// the Map tab would draw nothing, which is the exact failure the raster
/// cache this replaced was written to fix.
///
/// This is that fix again, one level up. Two seams, because a working offline
/// map needs two different kinds of bytes:
///
///  * [CachingVectorTileProvider] decorates the package's own
///    [VectorTileProvider] interface, so every `.mvt` tile goes through the
///    byte store. It has to be a provider decorator rather than an HTTP
///    client: `StyleReader` passes its `httpClient` to the style, TileJSON,
///    sprite and glyph requests but NOT to the `NetworkVectorTileProvider` it
///    builds for a network source, which makes its own.
///  * [CachingStyleClient] is the HTTP client for everything else the style
///    references — style.json, TileJSON, the sprite sheet, the glyph ranges.
///    Without them a cold offline start has tile data and no way to draw it.
///
/// Both share one [TileCacheStore] (and therefore one byte budget), which is
/// the same IndexedDB store the raster cache used. That reuse is deliberate:
/// the raster PNGs left on existing devices are the least-recently-used rows
/// in it, so the first vector tile written under the much smaller budget below
/// evicts them. Nobody has to migrate anything, and the space comes back on
/// first use.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart';
import 'package:http/http.dart' as http;

import '../../features/topo/data/photo_write_exception.dart';
import 'tile_cache_store.dart';

/// Hard cap on cached basemap bytes — tiles, style, sprites and glyphs
/// together.
///
/// **4 MB, down from the raster cache's 40.** Not a guess: a vector source
/// tops out at zoom 14 (CARTO's `carto.streets` declares `maxzoom: 14`) and
/// every deeper zoom is rendered by overzooming that same tile. So one ~8 KB
/// tile covers a 2-3 km square at *every* zoom a climber uses at the rock,
/// where the raster cache needed a fresh PNG per zoom per tile — 341 of them,
/// about 2.7 MB, for the same ground between z14 and z18.
///
/// 4 MB is therefore several hundred z14 tiles: thousands of square
/// kilometres of crag, in a tenth of the space the old cache took to hold a
/// few valleys. Minimising what the app occupies on the device was the point
/// of the migration; this constant is where it is actually spent.
///
/// TUNABLE. Single source of truth for the basemap byte budget.
const int kVectorTileCacheMaxBytes = 4 * 1024 * 1024;

/// A [VectorTileProvider] that reads and writes tile bytes through a
/// [TileCacheStore] before falling back to [inner].
///
/// The offline behaviour is the whole point, and it is stronger than the
/// raster cache managed: a cached tile past its freshness window is still
/// SERVED when the network fails, rather than evicted. flutter_map's own
/// contract turned a failed revalidation into an eviction and a transparent
/// tile — bytes in hand, thrown away, blank map. Here a stale tile is a
/// month-old basemap, which at a crag is indistinguishable from a fresh one.
class CachingVectorTileProvider implements VectorTileProvider {
  CachingVectorTileProvider({
    required this.inner,
    required this.store,
    this.maxBytes = kVectorTileCacheMaxBytes,
    this.freshnessWindow = const Duration(days: 30),
    int Function()? nowMs,
  }) : _nowMs = nowMs ?? _wallClockMs;

  static int _wallClockMs() => DateTime.now().millisecondsSinceEpoch;

  final VectorTileProvider inner;
  final TileCacheStore store;
  final int maxBytes;
  final Duration freshnessWindow;
  final int Function() _nowMs;

  /// Flipped false and never back once the browser refuses a write for quota,
  /// carried over from the raster cache: a cache that cannot write must not
  /// spend the rest of the session throwing on every tile.
  bool _enabled = true;

  /// Cache writes, chained rather than fired in parallel.
  ///
  /// [load] must never wait on a write — a tile that is already in hand has
  /// nothing to gain from blocking on IndexedDB — so writes run off to the
  /// side. Chaining them serialises the read-modify-evict pass each one ends
  /// with, so two tiles arriving together cannot both measure the store
  /// before either has grown it and jointly overshoot [maxBytes].
  ///
  /// [settled] is the same chain, awaited: the only way a test can observe a
  /// write that production deliberately does not wait for.
  Future<void> _writes = Future<void>.value();

  /// Completes once every write issued so far has finished. Test-only — no
  /// production path waits for the cache.
  @visibleForTesting
  Future<void> settled() => _writes;

  @override
  int get maximumZoom => inner.maximumZoom;

  @override
  int get minimumZoom => inner.minimumZoom;

  @override
  String get cacheKey => inner.cacheKey;

  /// The package's own disk cache is native-only and this decorator is
  /// web-only, so the two never both run. Saying so explicitly keeps a future
  /// native use of this class from writing every tile twice.
  @override
  bool get cacheBytesToDisk => false;

  /// Keyed by the source's identity plus the tile coordinate, so two styles
  /// sharing this store cannot serve each other's bytes.
  String _keyFor(TileKey tile) =>
      '${inner.cacheKey}#${tile.z}/${tile.x}/${tile.y}';

  @override
  Future<TileResponse> load(
    TileKey tile, {
    CancellationToken? cancellation,
  }) async {
    final key = _keyFor(tile);
    final cached = await _read(key);
    if (cached != null && _nowMs() < cached.staleAtMs) {
      return TileResponseData(cached.bytes);
    }

    final TileResponse response;
    try {
      response = await inner.load(tile, cancellation: cancellation);
    } catch (error) {
      // The provider contract says failures come back as TileResponseError
      // rather than throwing, but a decorator that trusts that and is wrong
      // takes the map down. Stale bytes beat an exception either way.
      if (cached != null) return TileResponseData(cached.bytes);
      rethrow;
    }

    switch (response) {
      case TileResponseData(:final bytes):
        _writes = _writes.then((_) => _write(key, bytes));
        return response;
      case TileResponseError():
        // The offline path. Nothing is written: a failure must never
        // overwrite good bytes with an error.
        if (cached != null) return TileResponseData(cached.bytes);
        return response;
      case TileResponseNotFound():
      case TileResponseCancelled():
        return response;
    }
  }

  Future<CachedTileRecord?> _read(String key) async {
    if (!_enabled) return null;
    try {
      return await store.read(key);
    } catch (error) {
      // A read failure is a cache miss, never a map failure.
      debugPrint('masi/vector-tiles: read failed for $key: $error');
      return null;
    }
  }

  Future<void> _write(String key, Uint8List bytes) async {
    if (!_enabled) return;
    try {
      await store.write(
        key,
        bytes: bytes,
        staleAtMs: _nowMs() + freshnessWindow.inMilliseconds,
      );
      await store.evictLruUntilUnder(maxBytes);
    } catch (error) {
      await _handleWriteFailure(key, error);
    }
  }

  /// Quota pressure drops the whole store and stops caching for this page.
  ///
  /// Tiles are re-downloadable and photos are not, so handing the space back
  /// is the right response to a full origin — the same policy, and the same
  /// reasoning, the raster cache had.
  Future<void> _handleWriteFailure(String key, Object error) async {
    if (classifyPhotoWriteFailure(error) != PhotoWriteFailure.quotaExceeded) {
      debugPrint('masi/vector-tiles: write failed for $key: $error');
      return;
    }
    _enabled = false;
    debugPrint('masi/vector-tiles: quota exceeded — dropping the tile cache');
    try {
      await store.clear();
    } catch (error) {
      debugPrint('masi/vector-tiles: cache drop failed: $error');
    }
  }

  @override
  void dispose() => inner.dispose();
}

/// The HTTP client for a style's non-tile bytes: style.json, TileJSON, the
/// sprite sheet and its index, and the glyph ranges.
///
/// Small in total — a few hundred KB — and completely load-bearing: without
/// the glyphs there are no labels, and without the style there is no map at
/// all. They come through the same store and the same budget as the tiles.
///
/// Only GETs are cached, and a cached body is served when the network fails,
/// which is what lets a cold start with no signal draw a map.
class CachingStyleClient extends http.BaseClient {
  CachingStyleClient({
    required this.store,
    required this.inner,
    this.maxBytes = kVectorTileCacheMaxBytes,
    this.freshnessWindow = const Duration(days: 30),
    int Function()? nowMs,
  }) : _nowMs = nowMs ?? _wallClockMs;

  static int _wallClockMs() => DateTime.now().millisecondsSinceEpoch;

  final TileCacheStore store;

  /// The transport this wraps. Public and named like
  /// [CachingVectorTileProvider.inner] so a test can hand in a fake.
  final http.Client inner;
  final int maxBytes;
  final Duration freshnessWindow;
  final int Function() _nowMs;

  bool _enabled = true;

  /// See [CachingVectorTileProvider._writes] — same chain, same reason.
  Future<void> _writes = Future<void>.value();

  /// Completes once every write issued so far has finished. Test-only.
  @visibleForTesting
  Future<void> settled() => _writes;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.method != 'GET') return inner.send(request);
    final key = 'style:${request.url}';

    final cached = await _read(key);
    if (cached != null && _nowMs() < cached.staleAtMs) {
      return _responseFrom(cached.bytes, request);
    }

    try {
      final response = await inner.send(request);
      if (response.statusCode != 200) {
        if (cached != null) return _responseFrom(cached.bytes, request);
        return response;
      }
      // Buffered rather than streamed: the body has to be held anyway to be
      // stored, and these are small documents.
      final bytes = await response.stream.toBytes();
      _writes = _writes.then((_) => _write(key, bytes));
      return _responseFrom(bytes, request);
    } catch (error) {
      if (cached != null) return _responseFrom(cached.bytes, request);
      rethrow;
    }
  }

  http.StreamedResponse _responseFrom(Uint8List bytes, http.BaseRequest req) =>
      http.StreamedResponse(
        Stream<List<int>>.value(bytes),
        200,
        contentLength: bytes.length,
        request: req,
      );

  Future<CachedTileRecord?> _read(String key) async {
    if (!_enabled) return null;
    try {
      return await store.read(key);
    } catch (error) {
      debugPrint('masi/vector-style: read failed for $key: $error');
      return null;
    }
  }

  Future<void> _write(String key, Uint8List bytes) async {
    if (!_enabled) return;
    try {
      await store.write(
        key,
        bytes: bytes,
        staleAtMs: _nowMs() + freshnessWindow.inMilliseconds,
      );
      await store.evictLruUntilUnder(maxBytes);
    } catch (error) {
      if (classifyPhotoWriteFailure(error) == PhotoWriteFailure.quotaExceeded) {
        _enabled = false;
      }
      debugPrint('masi/vector-style: write failed for $key: $error');
    }
  }

  @override
  void close() {
    // The inner client is the caller's: `StyleReader` documents that "a passed
    // client stays yours and is never closed for you", and this one is shared
    // by every style load in the process.
  }
}
