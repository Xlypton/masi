/// Loads the app's vector basemap style, once, for every map surface.
///
/// A vector basemap is not a URL the way a raster one was: the style document
/// has to be fetched and parsed into a theme, its sprite sheet downloaded and
/// its sources resolved into tile providers, before a single tile can be
/// drawn. That is an async, moderately expensive step shared by the Map tab
/// and the set-location picker, so it lives behind one provider rather than
/// being repeated per screen.
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'basemap.dart';
import 'tile_cache_store.dart';
import 'vector_tile_cache.dart';

/// The loaded style: theme, tile providers, sprites.
///
/// NOT `autoDispose`. `Style.dispose()` disposes the tile providers it owns,
/// so letting this drop while a map is open would pull the providers out from
/// under a live layer; and re-reading it on every visit to the Map tab would
/// re-fetch the sprite sheet each time. One per app run is the right lifetime
/// — the same call `canEditWallRoutesProvider` documents for the same reason.
final basemapStyleProvider = FutureProvider<Style>((ref) async {
  final client = ref.watch(basemapHttpClientProvider);
  final style = await StyleReader(
    uri: basemapStyleUri,
    apiKey: cartoBasemapKey,
    httpClient: client,
    // Native keeps the package's own on-disk style cache. On web the flag is
    // documented as a no-op, and [CachingStyleClient] is what stands in for
    // it — see `vector_tile_cache.dart`.
    cache: !kIsWeb,
  ).read();

  if (!kIsWeb) return style;

  // WEB ONLY: wrap every tile provider so its bytes go through IndexedDB.
  // Without this the Map tab has no persistent cache at all and draws nothing
  // offline, which is the regression that made this migration conditional on
  // building a cache first.
  final store = basemapCacheStore(ref);
  final cached = TileProviders({
    for (final entry in style.providers.providers.entries)
      entry.key: CachingVectorTileProvider(inner: entry.value, store: store),
  });
  return Style(
    theme: style.theme,
    providers: cached,
    rasterSources: style.rasterSources,
    sprites: style.sprites,
    center: style.center,
    zoom: style.zoom,
    name: style.name,
    attributions: style.attributions,
  );
});

/// The HTTP client the style, TileJSON, sprite and glyph requests go through.
///
/// On web that is [CachingStyleClient], so a cold start with no signal still
/// has a style and its fonts to draw the cached tiles with. On native the
/// package's own disk cache already covers them, so this is a plain client.
///
/// Overridable in tests, which must never touch the network.
final basemapHttpClientProvider = Provider<http.Client>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  if (!kIsWeb) return client;
  return CachingStyleClient(store: basemapCacheStore(ref), inner: client);
});

/// The byte store shared by the tile and style caches, so they share one
/// budget. Overridable in tests with an in-memory IndexedDB factory.
final basemapCacheStoreProvider = Provider<TileCacheStore>(
  (ref) => IdbTileCacheStore(),
);

TileCacheStore basemapCacheStore(Ref ref) =>
    ref.watch(basemapCacheStoreProvider);
