// The one way a widget test says "don't draw a real basemap".
//
// ## Why this replaces the tile-provider seams
//
// Until the vector migration, every screen that rendered a map carried a
// `tileProvider` (or `setLocationTileProvider`) constructor parameter whose
// only purpose was to let a test hand in a no-op provider, so `flutter_test`
// never opened a socket toward a tile host. Those seams are gone: there is no
// `TileLayer` anymore. `BasemapLayer` reads `basemapStyleProvider`, and THAT
// is now the single place a test has to intercept -- one `ProviderScope`
// override instead of a parameter threaded through four widgets.
//
// The override resolves to a future that never completes, so the provider
// stays in its loading state for the life of the test. `BasemapLayer` renders
// `SizedBox.shrink()` for loading (see its doc: a map that fails is blank,
// never an error surface), which is exactly what the old no-op tile provider
// produced -- an empty ground under real markers and real chrome. Nothing
// throws, nothing is logged, and no request is ever made.
//
// A test that needs to prove the basemap ITSELF works does not use this: the
// vector cache has its own unit tests (`test/core/map/vector_tile_cache_test`)
// and the rendered map is verified in a real browser by the `e2e-verify`
// skill. This helper exists so the OTHER 200 tests can mount a map screen
// without caring.
import 'dart:async';

import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:masi/core/map/basemap_style.dart';

/// Overrides for a `ProviderScope`/`ProviderContainer` that mounts any map
/// surface. Spread it into an existing `overrides:` list.
List<Override> fakeBasemapOverrides() => [
  basemapStyleProvider.overrideWith((ref) => Completer<Style>().future),
];
