// Browser-level proof that Masi's web basemap cache
// (`lib/core/map/vector_tile_cache.dart`) works against a REAL browser
// IndexedDB.
//
// Run:
//   tool/drive_web.sh integration_test/web_tile_cache_test.dart
//
// -----------------------------------------------------------------------
// WHY THIS FILE EXISTS
// -----------------------------------------------------------------------
// `test/core/map/vector_tile_cache_test.dart` is thorough — but it builds
// `IdbTileCacheStore(factory: newIdbFactoryMemory())`: idb_shim's in-memory
// fake, on the plain Dart VM under `flutter test`. Nothing in that suite ever
// opens `IdbTileCacheStore()` with its REAL default factory
// (`idb.idbFactoryWeb`, resolved lazily — see that class's doc) in an actual
// browser. This file runs the same scenarios against the real thing, headless
// in Chrome via `tool/drive_web.sh`, exactly like `web_smoke_test.dart`.
//
// The offline map needs BOTH halves to survive that round trip, so both are
// here: `CachingVectorTileProvider` for the `.mvt` tiles, and
// `CachingStyleClient` for the style/TileJSON/sprite/glyph bytes. Cached
// tiles with no glyphs is a map with no labels; a cached style with no tiles
// is an empty one.
//
// -----------------------------------------------------------------------
// WHAT IT PROVES, AND WHAT IT DOES NOT
// -----------------------------------------------------------------------
//  1. Bytes written by one object graph are read back by a SECOND, entirely
//     independent one (new store, new decorator) over the same real
//     IndexedDB database — so nothing here can be explained by a Dart field
//     surviving between phases.
//  2. With the network severed (an inner provider / transport that fails on
//     every call), the cached bytes are still served, and the inner is not
//     called at all while the entry is fresh.
//  3. NEGATIVE CONTROL: the same severed network against a key that was
//     never written fails. Without this, phases 1-2 could be green for some
//     reason that has nothing to do with the cache.
//
// It does NOT prove the rendered map: turning cached MVT bytes into pixels is
// `integration_test/e2e_map_test.dart`'s job, in the same real browser. Nor
// does it prove survival across a genuine page reload (fresh wasm module,
// fresh JS heap) — that is what the `web_photo_offline_*` PAIR exists for,
// and this claim is narrower: does our storage layer round-trip through the
// browser's actual IndexedDB.
import 'dart:typed_data';

import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' show MockClient;
import 'package:integration_test/integration_test.dart';
import 'package:masi/core/map/tile_cache_store.dart';
import 'package:masi/core/map/vector_tile_cache.dart';

/// Stand-in for the package's `NetworkVectorTileProvider`: scripted, counted,
/// and never opening a socket — so "severed network" is unambiguous and this
/// file has no live-internet dependency.
class _ScriptedProvider implements VectorTileProvider {
  _ScriptedProvider({required this.cacheKey, this.bytes, this.failure});

  @override
  final String cacheKey;
  final Uint8List? bytes;
  final Object? failure;
  int loads = 0;

  @override
  int get maximumZoom => 14;
  @override
  int get minimumZoom => 0;
  @override
  bool get cacheBytesToDisk => true;

  @override
  Future<TileResponse> load(
    TileKey tile, {
    CancellationToken? cancellation,
  }) async {
    loads++;
    final f = failure;
    if (f != null) return TileResponseError(f);
    return TileResponseData(bytes!);
  }

  @override
  void dispose() {}
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'tile bytes cached via the REAL browser IndexedDB are served again '
    'through a provider that fails on every request — and a key that was '
    'never cached still fails',
    (tester) async {
      // Unique per run, so re-running against a browser profile that happens
      // to persist can never be satisfied by a previous run's leftovers.
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final source = 'https://tile-cache-proof.example/$stamp/{z}/{x}/{y}.mvt';
      final payload = Uint8List.fromList(
        List<int>.generate(2048, (i) => (i * 7 + stamp) & 0xFF),
      );
      const tile = TileKey(14, 8723, 5860);

      // PHASE 1 — online: one real load, written through the real
      // `idb.idbFactoryWeb` store.
      final onlineInner = _ScriptedProvider(cacheKey: source, bytes: payload);
      final online = CachingVectorTileProvider(
        inner: onlineInner,
        // No `factory:` — the REAL browser IndexedDB, resolved lazily.
        store: IdbTileCacheStore(),
      );
      final first = await online.load(tile);
      expect(first, isA<TileResponseData>());
      expect(onlineInner.loads, 1);
      // Production never waits on the cache write; this test has to.
      await online.settled();

      // PHASE 2 — network severed, over a SECOND, independent object graph.
      // Nothing from phase 1 is reachable except the browser's database.
      final deadInner = _ScriptedProvider(
        cacheKey: source,
        failure: 'network severed',
      );
      final offline = CachingVectorTileProvider(
        inner: deadInner,
        store: IdbTileCacheStore(),
      );
      final second = await offline.load(tile);

      expect(
        second,
        isA<TileResponseData>(),
        reason: 'THE CLAIM: a tile fetched once must be served again with a '
            'dead network. It came back as ${second.runtimeType} instead.',
      );
      expect((second as TileResponseData).bytes, payload);
      expect(
        deadInner.loads,
        0,
        reason: 'a FRESH cached tile must be served without consulting the '
            'network at all — the 30-day freshness window is what buys that',
      );

      // PHASE 3 — NEGATIVE CONTROL. Same dead network, a key nobody ever
      // wrote. If this also "succeeded", phases 1-2 would be evidence of
      // nothing: we cache, we do not invent.
      final controlInner = _ScriptedProvider(
        cacheKey: 'https://tile-cache-proof.example/$stamp/never/{z}/{x}/{y}',
        failure: 'network severed',
      );
      final control = CachingVectorTileProvider(
        inner: controlInner,
        store: IdbTileCacheStore(),
      );
      expect(
        await control.load(tile),
        isA<TileResponseError>(),
        reason: 'MUTATION CHECK FAILED: an uncached tile succeeded offline, '
            "so phase 2's success cannot be attributed to the cache",
      );
      expect(controlInner.loads, 1);

      // ignore: avoid_print
      print(
        'web_tile_cache_test: tiles — phase1 loads=${onlineInner.loads} '
        '| phase2(cache hit) loads=${deadInner.loads} '
        '| phase3(control) loads=${controlInner.loads}',
      );
    },
  );

  testWidgets(
    'style, sprite and glyph bytes round-trip through the REAL browser '
    'IndexedDB too — cached tiles with no glyphs is a map with no labels',
    (tester) async {
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final styleUrl = Uri.parse('https://style-proof.example/$stamp/style.json');
      final missingUrl = Uri.parse('https://style-proof.example/$stamp/gone.json');
      const body = '{"version":8,"sources":{},"layers":[]}';

      var onlineRequests = 0;
      final online = CachingStyleClient(
        store: IdbTileCacheStore(),
        inner: MockClient((_) async {
          onlineRequests++;
          return http.Response(body, 200);
        }),
      );
      expect((await online.get(styleUrl)).body, body);
      expect(onlineRequests, 1);
      await online.settled();

      var deadRequests = 0;
      final offline = CachingStyleClient(
        store: IdbTileCacheStore(),
        inner: MockClient((r) async {
          deadRequests++;
          throw http.ClientException('network severed', r.url);
        }),
      );
      expect(
        (await offline.get(styleUrl)).body,
        body,
        reason: 'a cached style document must survive a dead transport — '
            'without it there is nothing to draw the cached tiles with',
      );
      expect(deadRequests, 0);

      // NEGATIVE CONTROL: never cached, still fails.
      await expectLater(
        offline.get(missingUrl),
        throwsA(isA<http.ClientException>()),
      );

      // ignore: avoid_print
      print(
        'web_tile_cache_test: style — online=$onlineRequests '
        'offline-network-calls=$deadRequests',
      );
    },
  );
}
