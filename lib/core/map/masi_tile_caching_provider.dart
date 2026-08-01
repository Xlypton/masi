/// flutter_map [MapCachingProvider] backed by [TileCacheStore], so the WEB
/// build finally has a map-tile cache.
///
/// Native does not use this: `buildResilientTileProvider` leaves
/// `cachingProvider` null there, which resolves to flutter_map's on-disk
/// `BuiltInMapCachingProvider` (1 GB default). On web that same class is a
/// documented no-op — `built_in/impl/web/web.dart` is literally
/// `class BuiltInMapCachingProviderImpl with DisabledMapCachingProvider` — so
/// the Map tab has been rendering nothing but blank tiles offline.
library;

import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_map/flutter_map.dart';

import '../../features/topo/data/photo_write_exception.dart';
import 'tile_cache_store.dart';

/// Hard cap on cached tile bytes. ~40 MB is roughly 2 000 retina PNG tiles —
/// several sessions' worth of the areas a climber actually revisits — while
/// staying a rounding error against a desktop Chrome quota and about 4 % of
/// iOS Safari's ~1 GB per-origin allowance.
///
/// Deliberately small relative to the photo budget: tiles are re-downloadable,
/// photos are not. See [MasiTileCachingProvider]'s quota policy.
///
/// TUNABLE. This is the single source of truth for the tile budget — change it
/// here and nowhere else.
const int kTileCacheMaxBytes = 40 * 1024 * 1024;

/// How long a cached tile is treated as fresh, REGARDLESS of what the tile
/// server's `Cache-Control` said. See [MasiTileCachingProvider._staleAtFor].
///
/// flutter_map's own fallback is 7 days; 30 deliberately favours offline
/// usefulness over basemap freshness for a slowly-changing raster basemap.
///
/// TUNABLE. Single source of truth for the freshness window.
const Duration kTileFreshnessWindow = Duration(days: 30);

/// A [MapCachingProvider] that persists tiles in IndexedDB under a hard byte
/// budget, and that reports freshness on OUR terms rather than the tile
/// server's so a cached tile still renders with no network.
class MasiTileCachingProvider implements MapCachingProvider {
  MasiTileCachingProvider({
    required this.store,
    int Function()? nowMs,
    this.maxBytes = kTileCacheMaxBytes,
    this.freshnessWindow = kTileFreshnessWindow,
  }) : _nowMs = nowMs ?? _wallClockMs;

  static int _wallClockMs() => DateTime.now().millisecondsSinceEpoch;

  /// The backing byte store. Injected so the policy above is unit-testable
  /// against an in-memory IndexedDB, and so a test can supply one that throws.
  final TileCacheStore store;

  /// This instance's byte budget. Defaults to [kTileCacheMaxBytes].
  final int maxBytes;

  /// This instance's freshness window. Defaults to [kTileFreshnessWindow].
  final Duration freshnessWindow;

  final int Function() _nowMs;

  /// Flipped to `false` and never back for the rest of the page's life once
  /// the browser refuses a write for quota. See [_handleWriteFailure].
  bool _enabled = true;

  @override
  bool get isSupported => _enabled;

  @override
  Future<CachedMapTile?> getTile(String url) async {
    if (!_enabled) return null;
    try {
      final record = await store.read(url);
      if (record == null) return null;
      return (
        bytes: record.bytes,
        metadata: CachedMapTileMetadata(
          staleAt: DateTime.fromMillisecondsSinceEpoch(
            record.staleAtMs,
            isUtc: true,
          ),
          lastModified: record.lastModifiedMs == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(
                  record.lastModifiedMs!,
                  isUtc: true,
                ),
          etag: record.etag,
        ),
      );
    } catch (e) {
      // MUST NOT propagate. `NetworkTileImageProvider._loadImage` wraps this
      // call in `try … on CachedMapTileReadFailure` ONLY; any other exception
      // escapes the whole method and errors the image stream, turning a cache
      // hiccup into a permanently broken tile.
      debugPrint('masi/tiles: read failed for $url: $e');
      return null;
    }
  }

  @override
  Future<void> putTile({
    required String url,
    required CachedMapTileMetadata metadata,
    Uint8List? bytes,
  }) async {
    if (!_enabled) return;
    final staleAtMs = _staleAtFor(metadata);
    try {
      if (bytes == null) {
        // The HTTP-304 path: the server confirmed the tile is unchanged, so
        // only the freshness window and etag move.
        await store.touch(url, staleAtMs: staleAtMs, etag: metadata.etag);
        return;
      }
      await store.write(
        url,
        bytes: bytes,
        staleAtMs: staleAtMs,
        lastModifiedMs: metadata.lastModified?.millisecondsSinceEpoch,
        etag: metadata.etag,
      );
      await store.evictLruUntilUnder(maxBytes);
    } catch (e) {
      // MUST NOT propagate: flutter_map calls putTile UNAWAITED, so a throw
      // here is an unhandled async error with no owner.
      await _handleWriteFailure(url, e);
    }
  }

  /// The freshness this cache reports, which is deliberately NOT what the
  /// tile server asked for.
  ///
  /// flutter_map serves a cached tile without touching the network only while
  /// `!metadata.isStale`. Once stale it re-requests, and offline that request
  /// fails with a `ClientException` which flutter_map turns into an EVICTION
  /// and a transparent tile — it never falls back to the stale bytes already
  /// in hand. So a cache that honoured CartoDB's `Cache-Control` would still
  /// show a blank map the moment its tiles aged out, which is precisely the
  /// failure this class exists to fix.
  ///
  /// A 30-day window is defensible for THIS payload specifically: the
  /// `light_all` raster basemap is a slowly-changing global product where a
  /// month-old tile is visually identical. It is not a general-purpose HTTP
  /// cache and must not be reused as one. If a longer window is ever offered
  /// by the server we keep the server's — the override only ever EXTENDS
  /// freshness, never shortens it.
  int _staleAtFor(CachedMapTileMetadata metadata) {
    final ours = _nowMs() + freshnessWindow.inMilliseconds;
    final theirs = metadata.staleAt.millisecondsSinceEpoch;
    return theirs > ours ? theirs : ours;
  }

  Future<void> _handleWriteFailure(String url, Object error) async {
    if (classifyPhotoWriteFailure(error) != PhotoWriteFailure.quotaExceeded) {
      // A transient IndexedDB blip. Skip this tile, keep the cache.
      debugPrint('masi/tiles: write failed for $url: $error');
      return;
    }
    // Quota. This is the deliberate INVERSE of the photo policy: a photo
    // write fails LOUDLY because the user's photo is irreplaceable, whereas a
    // tile is a free re-download. So rather than compete for the last bytes of
    // the origin quota — and risk being the reason the next `importPhoto`
    // throws — the tile cache hands ALL of its space back immediately and
    // stops asking for more this session.
    _enabled = false;
    debugPrint(
      'masi/tiles: quota exceeded — dropping the tile cache and disabling it '
      'for this session so photo storage keeps its headroom',
    );
    try {
      await store.clear();
    } catch (e) {
      debugPrint('masi/tiles: could not clear after quota failure: $e');
    }
  }
}

MasiTileCachingProvider? _singleton;

/// The process-wide web tile cache.
///
/// A single instance for the same reason `PhotoImageCache.instance` is one:
/// both `TileLayer`s — the Community map and the Set-location picker — must
/// share one budget and one LRU ordering, not maintain competing caches over
/// the same IndexedDB database.
///
/// Safe to call off-web: [IdbTileCacheStore] resolves its browser factory
/// lazily, so nothing here touches IndexedDB until a tile is actually read or
/// written.
MasiTileCachingProvider webTileCachingProvider() =>
    _singleton ??= MasiTileCachingProvider(store: IdbTileCacheStore());
