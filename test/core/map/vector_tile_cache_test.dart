// The offline claim for the vector basemap, proved against a real store.
//
// The cache is the thing under test, so nothing about it is mocked: an
// in-memory `idb` factory backs a REAL `IdbTileCacheStore`, and it is the
// network — the wrapped `VectorTileProvider` and `http.Client` — that gets
// faked. That is the only arrangement in which "a tile fetched once still
// renders with a dead transport" means anything.
//
// Two halves, because a map needs two kinds of bytes and losing either draws
// nothing: `CachingVectorTileProvider` for the `.mvt` tiles, and
// `CachingStyleClient` for the style document, TileJSON, sprites and glyphs
// the renderer needs to turn those tiles into a picture.
//
// The behaviour these pin that the raster cache did NOT have: a tile past its
// freshness window is still SERVED when the network fails, rather than
// evicted. flutter_map's own contract turned a failed revalidation into a
// blank tile — bytes in hand, thrown away — which at a crag with no signal is
// the difference between a month-old basemap and no map.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' show MockClient;
import 'package:idb_shim/idb_client_memory.dart';
import 'package:masi/core/map/tile_cache_store.dart';
import 'package:masi/core/map/vector_tile_cache.dart';

/// Stand-in for the package's `NetworkVectorTileProvider`: scripted, counted,
/// and never touching a socket.
class _FakeProvider implements VectorTileProvider {
  _FakeProvider({this.bytes, this.failure, this.throwInstead = false});

  Uint8List? bytes;
  Object? failure;
  bool throwInstead;
  int loads = 0;

  @override
  int get maximumZoom => 14;
  @override
  int get minimumZoom => 0;
  @override
  String get cacheKey => 'https://tiles.example/{z}/{x}/{y}.mvt';
  @override
  bool get cacheBytesToDisk => true;

  @override
  Future<TileResponse> load(TileKey tile, {CancellationToken? cancellation}) async {
    loads++;
    final f = failure;
    if (f != null) {
      if (throwInstead) throw f;
      return TileResponseError(f);
    }
    return TileResponseData(bytes!);
  }

  @override
  void dispose() {}
}

TileCacheStore _store() => IdbTileCacheStore(factory: newIdbFactoryMemory());

Uint8List _mvt(String marker) => Uint8List.fromList(marker.codeUnits);

void main() {
  group('CachingVectorTileProvider', () {
    test('a tile fetched once is served again with a transport that fails on '
        'every request — the offline claim, with zero further loads', () async {
      final inner = _FakeProvider(bytes: _mvt('tile-bytes'));
      final cache = CachingVectorTileProvider(inner: inner, store: _store());
      const tile = TileKey(14, 8000, 5000);

      final first = await cache.load(tile);
      expect(first, isA<TileResponseData>());
      expect(inner.loads, 1);
      await cache.settled();

      // A brand-new decorator over the SAME store: a genuine cold start, not
      // an in-memory hit surviving inside one object.
      final offlineInner = _FakeProvider(failure: 'offline');
      // ignore: unused_local_variable
      final second = await CachingVectorTileProvider(
        inner: offlineInner,
        store: cache.store,
      ).load(tile);
      expect((second as TileResponseData).bytes, _mvt('tile-bytes'));
      expect(
        offlineInner.loads,
        0,
        reason: 'a fresh cached tile must be served without asking the '
            'network at all — that is where the offline map comes from',
      );
    });

    test('a STALE tile is still served when the network fails, rather than '
        'evicted — the raster cache dropped these and drew nothing', () async {
      var now = 1000;
      final inner = _FakeProvider(bytes: _mvt('old'));
      final store = _store();
      final warm = CachingVectorTileProvider(
        inner: inner,
        store: store,
        freshnessWindow: const Duration(days: 30),
        nowMs: () => now,
      );
      const tile = TileKey(14, 1, 1);
      await warm.load(tile);
      await warm.settled();

      // Two months later, offline.
      now += const Duration(days: 60).inMilliseconds;
      final offlineInner = _FakeProvider(failure: 'offline');
      final cold = CachingVectorTileProvider(
        inner: offlineInner,
        store: store,
        nowMs: () => now,
      );

      final response = await cold.load(tile);
      expect(response, isA<TileResponseData>());
      expect((response as TileResponseData).bytes, _mvt('old'));
      expect(
        offlineInner.loads,
        1,
        reason: 'stale means REVALIDATE, not ignore — it must try the network '
            'first and only fall back to the old bytes when that fails',
      );
    });

    test('a stale tile that revalidates successfully serves the NEW bytes',
        () async {
      var now = 1000;
      final store = _store();
      final warm = CachingVectorTileProvider(
        inner: _FakeProvider(bytes: _mvt('old')),
        store: store,
        nowMs: () => now,
      );
      await warm.load(const TileKey(14, 2, 2));
      await warm.settled();

      now += const Duration(days: 60).inMilliseconds;
      final response = await CachingVectorTileProvider(
        inner: _FakeProvider(bytes: _mvt('new')),
        store: store,
        nowMs: () => now,
      ).load(const TileKey(14, 2, 2));

      expect((response as TileResponseData).bytes, _mvt('new'));
    });

    test('a provider that THROWS instead of returning an error is survivable '
        'too — a decorator that trusts the contract and is wrong takes the '
        'whole map down', () async {
      final store = _store();
      const tile = TileKey(14, 3, 3);
      final warm = CachingVectorTileProvider(
        inner: _FakeProvider(bytes: _mvt('held')),
        store: store,
      );
      await warm.load(tile);
      await warm.settled();

      final response = await CachingVectorTileProvider(
        inner: _FakeProvider(failure: StateError('boom'), throwInstead: true),
        store: store,
      ).load(tile);
      expect((response as TileResponseData).bytes, _mvt('held'));
    });

    test('a tile that was never fetched still fails offline — we cache, we do '
        'not invent', () async {
      final cache = CachingVectorTileProvider(
        inner: _FakeProvider(failure: 'offline'),
        store: _store(),
      );
      expect(await cache.load(const TileKey(9, 9, 9)), isA<TileResponseError>());
    });

    test('a failure never overwrites good bytes with an error record',
        () async {
      final store = _store();
      const tile = TileKey(14, 4, 4);
      final warm = CachingVectorTileProvider(
        inner: _FakeProvider(bytes: _mvt('good')),
        store: store,
      );
      await warm.load(tile);
      await warm.settled();

      final failing = CachingVectorTileProvider(
        inner: _FakeProvider(failure: 'offline'),
        store: store,
      );
      await failing.load(tile);
      await failing.settled();

      final still = await CachingVectorTileProvider(
        inner: _FakeProvider(failure: 'offline'),
        store: store,
      ).load(tile);
      expect((still as TileResponseData).bytes, _mvt('good'));
    });

    test('two sources sharing one store cannot serve each other\'s bytes',
        () async {
      final store = _store();
      const tile = TileKey(14, 5, 5);
      final a = _FakeProvider(bytes: _mvt('source-a'));
      final warm = CachingVectorTileProvider(inner: a, store: store);
      await warm.load(tile);
      await warm.settled();

      final b = _OtherKeyProvider(_mvt('source-b'));
      final response =
          await CachingVectorTileProvider(inner: b, store: store).load(tile);
      expect((response as TileResponseData).bytes, _mvt('source-b'));
      expect(b.loads, 1, reason: 'the key is scoped by source, so this is a '
          'miss rather than a cross-source hit');
    });

    test('it never double-writes: the package\'s own disk cache is native, '
        'this decorator is web, and cacheBytesToDisk says so', () {
      final cache = CachingVectorTileProvider(
        inner: _FakeProvider(bytes: _mvt('x')),
        store: _store(),
      );
      expect(cache.cacheBytesToDisk, isFalse);
      expect(cache.maximumZoom, 14);
      expect(cache.cacheKey, 'https://tiles.example/{z}/{x}/{y}.mvt');
    });

    test('the budget is enforced: writing past maxBytes evicts, and the store '
        'stays under the cap', () async {
      final store = _store();
      final big = Uint8List(4000);
      final cache = CachingVectorTileProvider(
        inner: _FakeProvider(bytes: big),
        store: store,
        maxBytes: 10000,
      );
      for (var i = 0; i < 6; i++) {
        await cache.load(TileKey(14, i, 0));
      }
      await cache.settled();
      expect(await store.totalBytes(), greaterThan(0));
      expect(await store.totalBytes(), lessThanOrEqualTo(10000));
    });
  });

  group('CachingStyleClient', () {
    test('a style document fetched once is served again from a dead '
        'transport — without the glyphs and the style there are no labels '
        'and no map, cached tiles or not', () async {
      final store = _store();
      final url = Uri.parse('https://basemaps.example/style.json');

      final online = CachingStyleClient(
        store: store,
        inner: MockClient((_) async => http.Response('{"version":8}', 200)),
      );
      expect((await online.get(url)).body, '{"version":8}');
      await online.settled();

      final offline = CachingStyleClient(
        store: store,
        inner: MockClient((r) async => throw http.ClientException('dead', r.url)),
      );
      expect((await offline.get(url)).body, '{"version":8}');
    });

    test('a non-200 falls back to the cached body rather than handing the '
        'renderer an error page', () async {
      final store = _store();
      final url = Uri.parse('https://basemaps.example/sprite.json');
      final warm = CachingStyleClient(
        store: store,
        inner: MockClient((_) async => http.Response('sprites', 200)),
      );
      await warm.get(url);
      await warm.settled();

      final degraded = CachingStyleClient(
        store: store,
        inner: MockClient((_) async => http.Response('nope', 503)),
      );
      final response = await degraded.get(url);
      expect(response.statusCode, 200);
      expect(response.body, 'sprites');
    });

    test('with nothing cached, a failure is still a failure', () async {
      final client = CachingStyleClient(
        store: _store(),
        inner: MockClient((r) async => throw http.ClientException('dead', r.url)),
      );
      expect(
        () => client.get(Uri.parse('https://basemaps.example/glyphs.pbf')),
        throwsA(isA<http.ClientException>()),
      );
    });

    test('only GETs are cached — a POST goes straight through', () async {
      var posts = 0;
      final client = CachingStyleClient(
        store: _store(),
        inner: MockClient((r) async {
          if (r.method == 'POST') posts++;
          return http.Response('ok', 200);
        }),
      );
      await client.post(Uri.parse('https://basemaps.example/x'));
      await client.post(Uri.parse('https://basemaps.example/x'));
      expect(posts, 2);
    });

    test('close() does NOT close the inner client — StyleReader documents '
        'that a passed client stays the caller\'s, and this one is shared by '
        'every style load in the process', () {
      var closed = false;
      final inner = _ClosableClient(() => closed = true);
      CachingStyleClient(store: _store(), inner: inner).close();
      expect(closed, isFalse);
    });
  });
}

/// Same tiles, different source identity — the cross-source key check.
class _OtherKeyProvider extends _FakeProvider {
  _OtherKeyProvider(Uint8List bytes) : super(bytes: bytes);
  @override
  String get cacheKey => 'https://other.example/{z}/{x}/{y}.mvt';
}

class _ClosableClient extends http.BaseClient {
  _ClosableClient(this.onClose);
  final void Function() onClose;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(const Stream.empty(), 200);
  @override
  void close() => onClose();
}
