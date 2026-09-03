/// The app's basemap, as a single widget both map surfaces drop into their
/// `FlutterMap.children`.
///
/// It exists because a vector basemap is asynchronous in a way a raster one
/// never was: [basemapStyleProvider] has to fetch and parse a style document
/// before any tile can be drawn, so every map has to say what it shows while
/// that is in flight, and what it shows if it fails. Answering that once, here,
/// is what keeps the two screens from answering it differently.
library;

import 'package:flutter/material.dart';
import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'basemap_style.dart';
import 'vector_tile_cache.dart';

/// Memory budget for decoded tile data, per source.
///
/// Decoded geometry is several times its encoded size, and this is RAM rather
/// than storage — a phone browser reclaims a backgrounded tab far more
/// eagerly than it reclaims IndexedDB. Small on purpose: the persistent cache
/// ([kVectorTileCacheMaxBytes]) is what makes a revisit cheap, so there is
/// nothing to gain from also holding a large decoded set in memory.
const int kVectorTileMemoryCacheMaxBytes = 8 * 1024 * 1024;

class BasemapLayer extends ConsumerWidget {
  const BasemapLayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final style = ref.watch(basemapStyleProvider);
    return switch (style) {
      AsyncData(:final value) => VectorTileLayer(
        key: const Key('basemap-vector-layer'),
        theme: value.theme,
        tileProviders: value.providers,
        rasterSources: value.rasterSources,
        sprites: value.sprites,
        memoryCacheMaxBytes: kVectorTileMemoryCacheMaxBytes,
        // Native only — on web this is documented as having no effect, and
        // `CachingVectorTileProvider` is what caches there instead. Set to the
        // same budget so a phone and a browser occupy the same space.
        diskCacheMaximumSizeInBytes: kVectorTileCacheMaxBytes,
      ),
      // Loading, or a style that could not be read at all (offline on the very
      // first run, before anything is cached). Nothing is DRAWN rather than an
      // error: the markers, the crosshair and the app's own chrome are still
      // useful over an empty ground, and a map that says "failed" where the
      // rock is would be worse than one that is simply blank.
      //
      // `expand`, not `shrink`, and that distinction is load-bearing.
      // `FlutterMap` sizes itself from its children when its own constraints
      // are loose — which they are in both call sites, each a non-positioned
      // child of a `Stack`. A zero-sized placeholder therefore collapses the
      // WHOLE MAP to 0x0 for as long as the style is in flight: no camera, no
      // gestures, no markers, and a crosshair pointing at nothing. Offline
      // with no cached style, that is permanent. Filling the constraints
      // keeps the map a map while the ground is still missing.
      _ => const SizedBox.expand(),
    };
  }
}
