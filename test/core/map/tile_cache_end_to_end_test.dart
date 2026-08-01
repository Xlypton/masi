// Drives the REAL flutter_map network-tile pipeline
// (`NetworkTileProvider` -> `NetworkTileImageProvider`) over our caching
// provider, with a `MockClient` transport. This is the only test that proves
// the offline claim end to end: after one successful fetch, a client that
// throws on EVERY request must still yield a decoded tile.
//
// Deliberately NOT built by mocking the cache — the cache is the thing under
// test. The network is what gets faked, at flutter_map's own `httpClient`
// seam, with the exact exception type (`ClientException`) that a browser
// `fetch` failure produces and that flutter_map branches on.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' show ClientException, Response;
import 'package:http/testing.dart' show MockClient;
import 'package:idb_shim/idb_client_memory.dart';
import 'package:masi/core/map/masi_tile_caching_provider.dart';
import 'package:masi/core/map/tile_cache_store.dart';

/// The smallest valid PNG: 1x1, fully transparent. Decodes for real, costs
/// nothing — this is NOT the prohibited `TopoCanvas` codec drive.
final Uint8List _onePixelPng = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

/// A tile-server response whose own caching headers say the tile went stale
/// long ago. Only our freshness override can keep it usable.
Response _tileResponse() => Response.bytes(
  _onePixelPng,
  200,
  headers: const {
    'cache-control': 'max-age=1',
    'date': 'Wed, 01 Jan 2025 00:00:00 GMT',
  },
);

/// `NetworkTileProvider` only implements the cancellable variant
/// (`supportsCancelLoading` is `true`), so the plain `getImage` throws
/// `UnimplementedError`. A never-completing trigger means "never abort".
ImageProvider _tileImage(NetworkTileProvider provider, TileCoordinates coords) =>
    provider.getImageWithCancelLoadingSupport(
      coords,
      TileLayer(urlTemplate: 'https://tiles.example/{z}/{x}/{y}.png'),
      Completer<void>().future,
    );

/// Resolves [provider] and RETURNS the image-stream error, or `null` if a
/// frame decoded successfully.
///
/// Returned rather than rethrown on purpose: an error that escapes
/// `tester.runAsync` is additionally reported to the test framework as an
/// unexpected exception, which turns the intended failure of the second test
/// into a confusing "Multiple exceptions (2)" instead of a clean assertion.
Future<Object?> _resolveTile(WidgetTester tester, ImageProvider provider) async {
  Object? caught;
  await tester.runAsync(() async {
    final completer = Completer<void>();
    final stream = provider.resolve(ImageConfiguration.empty);
    late ImageStreamListener listener;
    listener = ImageStreamListener(
      (_, _) {
        stream.removeListener(listener);
        if (!completer.isCompleted) completer.complete();
      },
      onError: (error, _) {
        caught = error;
        stream.removeListener(listener);
        if (!completer.isCompleted) completer.complete();
      },
    );
    stream.addListener(listener);
    await completer.future;
  });
  return caught;
}

void main() {
  testWidgets(
    'a tile fetched once renders again with a transport that throws on every '
    'request — the offline claim, end to end through flutter_map',
    (tester) async {
      var requests = 0;
      var offline = false;
      final client = MockClient((request) async {
        requests++;
        if (offline) throw ClientException('Failed to fetch', request.url);
        return _tileResponse();
      });

      final cache = MasiTileCachingProvider(
        store: IdbTileCacheStore(factory: newIdbFactoryMemory()),
      );
      final tileProvider = NetworkTileProvider(
        httpClient: client,
        cachingProvider: cache,
      );
      const coords = TileCoordinates(1, 1, 1);

      // Online: one real fetch.
      expect(await _resolveTile(tester, _tileImage(tileProvider, coords)), isNull);
      expect(requests, 1);

      // Offline, fresh image provider (a real remount, not a memory-cache
      // hit): the transport now throws, so anything that renders came from
      // IndexedDB.
      offline = true;
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      final offlineProvider = NetworkTileProvider(
        httpClient: client,
        cachingProvider: cache,
      );
      expect(
        await _resolveTile(tester, _tileImage(offlineProvider, coords)),
        isNull,
        reason: 'the map must still DRAW with a dead transport — a decoded '
            'frame, not a ClientException and not a blank grey tile',
      );

      expect(
        requests,
        1,
        reason: 'the cached tile must be served with ZERO network requests — '
            'flutter_map only skips the fetch while the tile is not stale, '
            'which is exactly what the 30-day freshness override buys',
      );
      expect(cache.isSupported, isTrue);
    },
  );

  testWidgets(
    'a tile that was never fetched still fails offline (we cache, we do not '
    'invent) — and the failure is the ordinary one, not a crash',
    (tester) async {
      final client = MockClient(
        (request) async => throw ClientException('Failed to fetch', request.url),
      );
      final cache = MasiTileCachingProvider(
        store: IdbTileCacheStore(factory: newIdbFactoryMemory()),
      );
      final tileProvider = NetworkTileProvider(
        httpClient: client,
        cachingProvider: cache,
      );

      expect(
        await _resolveTile(
          tester,
          _tileImage(tileProvider, const TileCoordinates(9, 9, 9)),
        ),
        isA<ClientException>(),
      );
    },
  );
}
