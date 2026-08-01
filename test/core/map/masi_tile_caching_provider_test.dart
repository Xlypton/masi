// Unit tests for the flutter_map `MapCachingProvider` adapter, on the plain
// Dart VM against idb_shim's in-memory factory.
//
// TIMEBASE WARNING, and the reason `now` is anchored to the real wall clock
// below: `CachedMapTileMetadata.isStale` is hardcoded to
// `DateTime.timestamp().isAfter(staleAt)` (flutter_map
// `caching/tile_metadata.dart`). flutter_map exposes no clock seam there, so
// the ONLY way to test "a tile written N days ago" is to write it with a
// BACKDATED clock and then ask the real one. An epoch-zero fake clock would
// make every tile permanently stale and the freshness assertions vacuous.
import 'dart:typed_data';

import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idb_shim/idb_client_memory.dart';
import 'package:masi/core/map/masi_tile_caching_provider.dart';
import 'package:masi/core/map/tile_cache_store.dart';
import 'package:masi/features/topo/data/photo_byte_store.dart'
    show kPhotoByteStoreDbName;

Uint8List _bytes(int n) => Uint8List.fromList(List<int>.filled(n, 3));

CachedMapTileMetadata _serverMeta(int staleAtMs, {String? etag}) =>
    CachedMapTileMetadata(
      staleAt: DateTime.fromMillisecondsSinceEpoch(staleAtMs, isUtc: true),
      lastModified: null,
      etag: etag,
    );

/// A store that throws the browser's quota error on every write, and counts
/// how many writes and clears it saw.
class _QuotaExceededStore implements TileCacheStore {
  int clearCount = 0;
  int writeCount = 0;

  @override
  Future<CachedTileRecord?> read(String url) async => null;

  @override
  Future<void> write(
    String url, {
    required Uint8List bytes,
    required int staleAtMs,
    int? lastModifiedMs,
    String? etag,
  }) async {
    writeCount++;
    throw StateError('QuotaExceededError: quota has been exceeded');
  }

  @override
  Future<void> touch(String url, {int? staleAtMs, String? etag}) async {}

  @override
  Future<int> totalBytes() async => 0;

  @override
  Future<void> evictLruUntilUnder(int maxBytes) async {}

  @override
  Future<void> clear() async => clearCount++;
}

/// A store whose writes fail for a reason that is NOT quota — a transient
/// IndexedDB blip, which must not cost us the whole cache.
class _FlakyStore extends _QuotaExceededStore {
  @override
  Future<void> write(
    String url, {
    required Uint8List bytes,
    required int staleAtMs,
    int? lastModifiedMs,
    String? etag,
  }) async {
    writeCount++;
    throw StateError('transient');
  }
}

/// A store whose reads always blow up with something flutter_map does NOT
/// special-case — proving `getTile` swallows it instead of escaping.
class _ExplodingStore extends _QuotaExceededStore {
  @override
  Future<CachedTileRecord?> read(String url) async =>
      throw StateError('indexeddb is having a bad day');
}

void main() {
  late IdbTileCacheStore store;
  late MasiTileCachingProvider provider;
  late int now;

  setUp(() {
    now = DateTime.now().millisecondsSinceEpoch;
    store = IdbTileCacheStore(factory: newIdbFactoryMemory(), nowMs: () => now);
    provider = MasiTileCachingProvider(store: store, nowMs: () => now);
  });

  test('isSupported is true for a healthy store', () {
    expect(provider.isSupported, isTrue);
  });

  test('a put then a get round-trips the bytes', () async {
    await provider.putTile(
      url: 'https://tiles/1.png',
      metadata: _serverMeta(now + 2000),
      bytes: _bytes(32),
    );

    final tile = await provider.getTile('https://tiles/1.png');

    expect(tile, isNotNull);
    expect(tile!.bytes, equals(_bytes(32)));
  });

  test(
    "the freshness window OVERRIDES the server's staleAt — this is what lets "
    'a cached tile render offline, because flutter_map only skips the network '
    'for a tile that is not stale',
    () async {
      // Write the tile as though it were fetched SEVEN DAYS AGO, and let the
      // server claim it went stale one second after that fetch.
      now = DateTime.now().millisecondsSinceEpoch -
          const Duration(days: 7).inMilliseconds;
      final serverMetadata = _serverMeta(now + 1000);
      expect(
        serverMetadata.isStale,
        isTrue,
        reason: 'control: honouring the server verbatim would make this tile '
            'stale, so flutter_map would go to the network and — offline — '
            'render a transparent tile instead of what we already hold',
      );

      await provider.putTile(
        url: 'https://tiles/1.png',
        metadata: serverMetadata,
        bytes: _bytes(32),
      );

      // Now ask for it at the real present moment.
      now = DateTime.now().millisecondsSinceEpoch;
      final tile = await provider.getTile('https://tiles/1.png');

      expect(tile, isNotNull);
      expect(
        tile!.metadata.isStale,
        isFalse,
        reason: 'a 7-day-old tile inside the 30-day window must not be stale, '
            'or flutter_map goes to the network and shows a blank tile offline',
      );
    },
  );

  test('past the freshness window a tile IS stale again', () async {
    // Fetched 31 days ago: outside the window, so it wants revalidating.
    now = DateTime.now().millisecondsSinceEpoch -
        const Duration(days: 31).inMilliseconds;
    await provider.putTile(
      url: 'https://tiles/1.png',
      metadata: _serverMeta(now),
      bytes: _bytes(32),
    );

    now = DateTime.now().millisecondsSinceEpoch;
    final tile = await provider.getTile('https://tiles/1.png');

    expect(tile, isNotNull, reason: 'the bytes are still there…');
    expect(
      tile!.metadata.isStale,
      isTrue,
      reason: '…but they want revalidating — the window is a window, not '
          '"never expire"',
    );
  });

  test('the freshness override only ever EXTENDS, never shortens', () async {
    // A server generous enough to promise a year keeps its promise.
    final aYear = now + const Duration(days: 365).inMilliseconds;
    await provider.putTile(
      url: 'https://tiles/1.png',
      metadata: _serverMeta(aYear),
      bytes: _bytes(32),
    );

    final tile = await provider.getTile('https://tiles/1.png');
    expect(tile!.metadata.staleAt.millisecondsSinceEpoch, aYear);
  });

  test(
    'putTile with null bytes (the HTTP 304 path) refreshes metadata only',
    () async {
      await provider.putTile(
        url: 'https://tiles/1.png',
        metadata: _serverMeta(now, etag: 'v1'),
        bytes: _bytes(32),
      );

      now += 5000;
      await provider.putTile(
        url: 'https://tiles/1.png',
        metadata: _serverMeta(now, etag: 'v2'),
        bytes: null,
      );

      final tile = await provider.getTile('https://tiles/1.png');
      expect(tile!.bytes, equals(_bytes(32)), reason: 'bytes untouched');
      expect(tile.metadata.etag, 'v2');
      expect(await store.totalBytes(), 32, reason: 'no double counting');
    },
  );

  test('the cache stays under its byte budget, evicting LRU', () async {
    final small = MasiTileCachingProvider(
      store: store,
      nowMs: () => now,
      maxBytes: 100,
    );
    final base = now;
    for (var i = 0; i < 5; i++) {
      now = base + i;
      await small.putTile(
        url: 'https://tiles/$i.png',
        metadata: _serverMeta(now),
        bytes: _bytes(40),
      );
    }

    expect(await store.totalBytes(), lessThanOrEqualTo(100));
    expect(await small.getTile('https://tiles/0.png'), isNull);
    expect(await small.getTile('https://tiles/4.png'), isNotNull);
  });

  test(
    'a quota failure drops the whole cache and disables it for the session — '
    'tiles must never compete with photos for the origin quota',
    () async {
      final quotaStore = _QuotaExceededStore();
      final p = MasiTileCachingProvider(store: quotaStore, nowMs: () => now);

      expect(p.isSupported, isTrue);
      await p.putTile(
        url: 'https://tiles/1.png',
        metadata: _serverMeta(now),
        bytes: _bytes(32),
      );

      expect(quotaStore.clearCount, 1, reason: 'the space is handed back');
      expect(p.isSupported, isFalse, reason: 'and we stop asking for more');

      // And it really does stop asking: no further byte is claimed from the
      // origin quota for the rest of the session, so the next `importPhoto`
      // keeps every byte the tile cache just released.
      await p.putTile(
        url: 'https://tiles/2.png',
        metadata: _serverMeta(now),
        bytes: _bytes(32),
      );
      expect(quotaStore.writeCount, 1, reason: 'no second write attempted');
      expect(await p.getTile('https://tiles/1.png'), isNull);
    },
  );

  test(
    'tiles live in their OWN IndexedDB database, so dropping them under quota '
    'pressure cannot touch a single photo byte',
    () {
      expect(kTileCacheDbName, isNot(kPhotoByteStoreDbName));
    },
  );

  test(
    'a non-quota write failure is swallowed and does NOT disable the cache',
    () async {
      final flaky = _FlakyStore();
      final p = MasiTileCachingProvider(store: flaky, nowMs: () => now);

      await p.putTile(
        url: 'https://tiles/1.png',
        metadata: _serverMeta(now),
        bytes: _bytes(32),
      );

      expect(p.isSupported, isTrue, reason: 'a transient blip is not fatal');
      expect(flaky.clearCount, 0, reason: 'and we do not throw the cache away');
    },
  );

  test('getTile never propagates a store exception', () async {
    final p = MasiTileCachingProvider(
      store: _ExplodingStore(),
      nowMs: () => now,
    );

    // Anything other than `null` here — including a throw — breaks
    // flutter_map's image pipeline (its `_loadImage` only catches
    // `CachedMapTileReadFailure`).
    await expectLater(p.getTile('https://tiles/1.png'), completion(isNull));
  });

  test(
    'constructing the real browser-backed store does not evaluate '
    '`idbFactoryWeb`, which throws UnimplementedError off-web',
    () {
      // If the factory were resolved eagerly in the constructor, every VM test
      // that merely BUILDS the production wiring — including the singleton
      // below and `buildResilientTileProvider(isWeb: true)` — would blow up.
      expect(IdbTileCacheStore.new, returnsNormally);
    },
  );

  test('the process-wide singleton is stable across calls', () {
    expect(
      identical(webTileCachingProvider(), webTileCachingProvider()),
      isTrue,
    );
  });

  test('the tunable defaults are the agreed ones', () {
    expect(kTileCacheMaxBytes, 40 * 1024 * 1024);
    expect(kTileFreshnessWindow, const Duration(days: 30));
  });
}
