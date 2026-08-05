// Browser-level proof that Masi's web map-tile cache
// (`lib/core/map/masi_tile_caching_provider.dart`) actually works against a
// REAL browser IndexedDB.
//
// Run:
//   tool/drive_web.sh integration_test/web_tile_cache_test.dart
//
// -----------------------------------------------------------------------
// WHY THIS FILE EXISTS
// -----------------------------------------------------------------------
// `test/core/map/masi_tile_caching_provider_test.dart` and
// `test/core/map/tile_cache_end_to_end_test.dart` are thorough — but BOTH
// construct `IdbTileCacheStore(factory: newIdbFactoryMemory())`: idb_shim's
// in-memory fake, running on the plain Dart VM under `flutter test`. Nothing
// in the suite has ever opened `IdbTileCacheStore()` with its REAL default
// factory (`idb.idbFactoryWeb`, resolved lazily — see that class's doc) in
// an actual browser. This file ports `tile_cache_end_to_end_test.dart`'s
// scenario (a real flutter_map `NetworkTileProvider` + our caching provider,
// with the HTTP transport faked and counted) verbatim in shape, swapping the
// in-memory IndexedDB for the real thing, driven headless in Chrome via
// `tool/drive_web.sh` exactly like `web_smoke_test.dart`.
//
// -----------------------------------------------------------------------
// WHY ONE FILE / ONE PROCESS, UNLIKE THE web_photo_offline_* PAIR
// -----------------------------------------------------------------------
// `web_photo_offline_seed_test.dart` / `_verify_test.dart` chain TWO SEPARATE
// `flutter drive` processes (via `tool/drive_web_photo_offline.sh`) because
// that claim — a photo survives a real cold restart — depends on things a
// same-page "reload" cannot rule out: drift's SharedWorker, the wasm module,
// `PhotoImageCache.instance`.
//
// This claim is narrower: does OUR caching provider (`MasiTileCachingProvider`
// / `IdbTileCacheStore`) round-trip a tile through the browser's actual
// IndexedDB, such that flutter_map's real tile pipeline renders it with the
// network transport making ZERO calls? That does not need a process restart
// to rule out the same confounders the photo pair worried about:
//   * every "online" and "offline" phase below builds a BRAND NEW
//     `IdbTileCacheStore()` / `MasiTileCachingProvider` / `NetworkTileProvider`
//     object graph — nothing here is an in-memory field surviving from an
//     earlier phase;
//   * `PaintingBinding.instance.imageCache` is explicitly cleared between
//     phases (see the file-level warning in the task brief this was written
//     against — flutter's OWN image cache keys `NetworkTileImageProvider`
//     purely on URL, so a stale in-memory decode could silently explain a
//     "hit" that never touched storage at all);
//   * the network transport is a synchronous, in-process fake
//     (`http.testing.MockClient`) that never opens a socket, so there is no
//     live-internet dependency and no ambiguity about what "severed" means —
//     a transport that unconditionally throws IS the severed network.
// The one thing this design does NOT prove, which a true cross-process pair
// would: survival across an actual page reload / browser restart (a fresh
// wasm module, fresh JS heap). What it DOES prove beyond the existing unit
// tests: the whole flutter_map tile pipeline — real `TileLayer`/`FlutterMap`,
// real `NetworkTileProvider`, our real caching classes — round-trips through
// the ACTUAL browser's IndexedDB, in a real browser, which no existing test
// touches at all.
//
// -----------------------------------------------------------------------
// THE FOUR THINGS THIS PROVES (see each phase below)
// -----------------------------------------------------------------------
//  1. A tile fetched once (phase 1) is served on a later load (phase 2) with
//     ZERO network requests — counted via the injected `MockClient`, not
//     inferred from the render.
//  2. Phase 2 uses a store/provider/cache object graph that has never seen
//     phase 1's Dart objects — only real IndexedDB crosses the gap.
//  3. Phase 2's network transport throws unconditionally (a severed network)
//     and the tile still renders (no `errorTileCallback`), inside a bounded
//     pump loop rather than `pumpAndSettle` (flutter_map's tile fade-in
//     animation never fully settles).
//  4. Phase 3 is the negative control: the SAME already-cached tile, the SAME
//     dead transport, but `cachingProvider: DisabledMapCachingProvider()`
//     instead of ours — and it fails (network attempted, transport throws,
//     `errorTileCallback` fires). This is what makes phases 1-3 a real test:
//     if phase 3 also silently "passed", nothing above would be evidence of
//     anything.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' show ClientException, Request, Response;
import 'package:http/testing.dart' show MockClient;
import 'package:integration_test/integration_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:masi/core/map/masi_tile_caching_provider.dart';
import 'package:masi/core/map/tile_cache_store.dart';

/// The smallest valid PNG: 1x1, fully transparent. Decodes for real in the
/// browser's own image codec — this is NOT a `TopoCanvas`-style large decode
/// (CLAUDE.md's "never drive a real image-codec decode in widget tests" is
/// about hangs under FAKE-async; `integration_test` runs live, and a 1x1 PNG
/// is as cheap as a decode gets).
final Uint8List _onePixelPng = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

/// A tile-server response whose OWN caching headers say the tile went stale
/// almost immediately. Only `MasiTileCachingProvider`'s 30-day freshness
/// override (`kTileFreshnessWindow`) can keep phase 2 from re-hitting the
/// network — proving the override, not a lucky long-lived server header, is
/// what makes offline rendering work.
Response _tileResponse() => Response.bytes(
  _onePixelPng,
  200,
  headers: const {
    'cache-control': 'max-age=1',
    'date': 'Wed, 01 Jan 2025 00:00:00 GMT',
  },
);

/// Pumps real frames for a FIXED, bounded wall-clock window — never
/// `pumpAndSettle`. flutter_map's tile fade-in transition and this app's own
/// loading affordances are exactly the kind of repeating/never-quite-done
/// animation that `pumpAndSettle` can spin on forever; a bounded loop always
/// returns, which is itself part of what "does not hang" means here.
Future<void> pumpFor(
  WidgetTester tester,
  Duration total, {
  Duration step = const Duration(milliseconds: 100),
}) async {
  final deadline = DateTime.now().add(total);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(step);
  }
}

/// A minimal, real `FlutterMap`/`TileLayer` — the actual production widgets,
/// just not wrapped in `CommunityMapScreen` (which would need a full
/// `bootApp()` — drift, auth, sync — none of which this file's claim is
/// about). [onErrorTile] fires flutter_map's own `errorTileCallback`, i.e.
/// "this tile failed to load", the same signal `CommunityMapScreen`'s real
/// `TileLayer` would report.
Widget _harness({
  required TileProvider tileProvider,
  required String urlTemplate,
  required VoidCallback onErrorTile,
}) {
  return MaterialApp(
    home: Scaffold(
      body: FlutterMap(
        options: const MapOptions(
          initialCenter: LatLng(47.0, 11.0),
          initialZoom: 14,
        ),
        children: [
          TileLayer(
            urlTemplate: urlTemplate,
            tileProvider: tileProvider,
            errorTileCallback: (tile, error, stackTrace) => onErrorTile(),
          ),
        ],
      ),
    ),
  );
}

/// Drops everything flutter's OWN pipeline might be holding onto for the
/// tiles just rendered. `NetworkTileImageProvider.operator==` keys purely on
/// URL (see flutter_map's `image_provider.dart`), so reusing a URL across
/// phases — required so our cache keys actually match — means a stale
/// decoded frame in `PaintingBinding.imageCache` could otherwise explain a
/// "hit" that never touched `MasiTileCachingProvider` at all.
void clearFlutterImageCache() {
  PaintingBinding.instance.imageCache.clear();
  PaintingBinding.instance.imageCache.clearLiveImages();
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'a tile cached via the REAL browser IndexedDB renders again through a '
    'transport that throws on every request — and a disabled cache does not',
    (tester) async {
      // Unique per run so re-running this file against a browser profile
      // that happens to persist (e.g. a developer's own Chrome, rather than
      // the ephemeral profile `tool/drive_web.sh` normally gets) can never
      // be satisfied by a PREVIOUS run's leftovers.
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final cachedUrl = 'https://tile-cache-proof.example/$stamp/{z}/{x}/{y}.png';
      // Deliberately never fetched by anyone — used only by the negative
      // control's "never cached" framing check below.
      final neverFetchedUrl =
          'https://tile-cache-proof.example/$stamp/never/{z}/{x}/{y}.png';

      await binding.takeScreenshot('tile-00-start');

      // ---------------------------------------------------------------
      // PHASE 1 — online: one real fetch, through the REAL caching
      // provider backed by the browser's actual IndexedDB.
      // ---------------------------------------------------------------
      var requestsA = 0;
      final clientA = MockClient((Request request) async {
        requestsA++;
        return _tileResponse();
      });
      final storeA = IdbTileCacheStore(); // real `idb.idbFactoryWeb`, lazy.
      final cacheA = MasiTileCachingProvider(store: storeA);
      var errorsA = 0;
      await tester.pumpWidget(
        _harness(
          tileProvider: NetworkTileProvider(
            httpClient: clientA,
            cachingProvider: cacheA,
          ),
          urlTemplate: cachedUrl,
          onErrorTile: () => errorsA++,
        ),
      );
      await pumpFor(tester, const Duration(seconds: 5));
      await binding.takeScreenshot('tile-01-online-fetched');

      expect(
        requestsA,
        greaterThan(0),
        reason: 'the harness never fetched anything — the rest of this test '
            'would be checking nothing',
      );
      expect(
        errorsA,
        0,
        reason: 'the very first, online fetch failed to render a tile: '
            '$errorsA error callback(s) fired',
      );
      final fetchedRequests = requestsA;

      // Unmount before phase 2, and drop flutter's own image cache — see
      // `clearFlutterImageCache`'s doc. Nothing from here on may be
      // explained by Dart-object or ImageCache memory; only the browser's
      // IndexedDB is shared with phase 1.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      clearFlutterImageCache();

      // ---------------------------------------------------------------
      // PHASE 2 — "network severed": a brand-new store/cache/provider
      // object graph (never touched by phase 1) over the SAME real
      // IndexedDB database, paired with a transport that throws
      // unconditionally. Anything that renders came from storage.
      // ---------------------------------------------------------------
      var requestsB = 0;
      final deadClientB = MockClient((Request request) async {
        requestsB++;
        throw ClientException('network severed', request.url);
      });
      final storeB = IdbTileCacheStore(); // a SECOND, independent instance.
      final cacheB = MasiTileCachingProvider(store: storeB);
      var errorsB = 0;
      final severedStopwatch = Stopwatch()..start();
      await tester.pumpWidget(
        _harness(
          tileProvider: NetworkTileProvider(
            httpClient: deadClientB,
            cachingProvider: cacheB,
          ),
          urlTemplate: cachedUrl, // SAME url as phase 1 -> same cache key.
          onErrorTile: () => errorsB++,
        ),
      );
      await pumpFor(tester, const Duration(seconds: 5));
      severedStopwatch.stop();
      await binding.takeScreenshot('tile-02-severed-served-from-cache');

      // "Does not hang": the bounded loop above always returns; this is the
      // wall-clock receipt that it did, well inside the drive/timeout budget.
      expect(
        severedStopwatch.elapsed,
        lessThan(const Duration(seconds: 10)),
        reason: 'the bounded pump loop itself guarantees this, but assert it '
            'anyway as a receipt',
      );
      expect(
        requestsB,
        0,
        reason: 'THE CLAIM: a tile fetched once must render again with ZERO '
            'network requests. The transport was called $requestsB time(s) '
            'despite a real, browser-IndexedDB-backed cache holding the '
            'exact same URL — the 30-day freshness override '
            '(kTileFreshnessWindow) is what is supposed to prevent this.',
      );
      expect(
        errorsB,
        0,
        reason: 'the map must still DRAW with a dead transport — a decoded '
            'tile, not a grey error tile — but errorTileCallback fired '
            '$errorsB time(s)',
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      clearFlutterImageCache();

      // ---------------------------------------------------------------
      // PHASE 3 — NEGATIVE CONTROL. Same already-cached URL, same kind of
      // dead transport, but `cachingProvider: DisabledMapCachingProvider()`
      // instead of ours. If this ALSO rendered successfully, phases 1-2
      // would prove nothing — some OTHER mechanism (flutter's image cache,
      // a lenient error path, a harness bug) could be doing the work
      // instead of `MasiTileCachingProvider`. It must fail.
      // ---------------------------------------------------------------
      var requestsC = 0;
      final deadClientC = MockClient((Request request) async {
        requestsC++;
        throw ClientException('network severed', request.url);
      });
      var errorsC = 0;
      await tester.pumpWidget(
        _harness(
          tileProvider: NetworkTileProvider(
            httpClient: deadClientC,
            cachingProvider: const DisabledMapCachingProvider(),
          ),
          urlTemplate: cachedUrl, // the EXACT url phases 1-2 proved works.
          onErrorTile: () => errorsC++,
        ),
      );
      await pumpFor(tester, const Duration(seconds: 5));
      await binding.takeScreenshot('tile-03-negative-control-disabled-cache');

      expect(
        requestsC,
        greaterThan(0),
        reason: 'with caching DISABLED, the tile provider must still try the '
            'network (and find it dead) — if it never tried, something '
            'other than the disabled-cache flag is short-circuiting this',
      );
      expect(
        errorsC,
        greaterThan(0),
        reason: 'MUTATION CHECK FAILED: with the real cache swapped out for '
            'DisabledMapCachingProvider, the exact same severed-network '
            'scenario that passed in phase 2 must now FAIL. It did not — '
            'which means phase 2\'s success cannot be attributed to '
            'MasiTileCachingProvider at all, and this whole file would be '
            'an always-green test proving nothing.',
      );

      // Sanity companion to the negative control above: a URL nobody ever
      // fetched behaves the same way under the real (non-disabled) cache —
      // "we cache, we do not invent". Uses cacheB's real, browser-IndexedDB
      // store, which has never seen this URL.
      var requestsD = 0;
      final deadClientD = MockClient((Request request) async {
        requestsD++;
        throw ClientException('network severed', request.url);
      });
      var errorsD = 0;
      final storeD = IdbTileCacheStore();
      await tester.pumpWidget(
        _harness(
          tileProvider: NetworkTileProvider(
            httpClient: deadClientD,
            cachingProvider: MasiTileCachingProvider(store: storeD),
          ),
          urlTemplate: neverFetchedUrl,
          onErrorTile: () => errorsD++,
        ),
      );
      await pumpFor(tester, const Duration(seconds: 5));
      expect(
        errorsD,
        greaterThan(0),
        reason: 'a URL that was never fetched must still fail offline even '
            'with the real cache in play — the cache does not invent tiles',
      );

      // Final receipt, useful when reading console output rather than the
      // screenshots.
      // ignore: avoid_print
      print(
        'web_tile_cache_test: phase1 fetched=$fetchedRequests errors=$errorsA '
        '| phase2(cache-hit) requests=$requestsB errors=$errorsB '
        '| phase3(disabled-cache control) requests=$requestsC errors=$errorsC '
        '| phase3b(never-fetched control) requests=$requestsD errors=$errorsD',
      );
    },
  );
}
