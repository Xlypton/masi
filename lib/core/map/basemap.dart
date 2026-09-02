import 'dart:ui' show ColorFilter;

/// The raster basemap every map surface in the app draws on.
///
/// This lives in one place because the choice is not a style preference — it
/// is a licensing constraint, and getting it wrong is *visible to the user as
/// text printed across the map*. CARTO (`basemaps.cartocdn.com/light_all`,
/// what this app used until 2026-09-02) stopped serving its basemaps
/// anonymously: the endpoint still answers `200` with a valid PNG, so nothing
/// in the retry/eviction machinery notices anything is wrong, but every tile
/// now carries a diagonal `API KEY REQUIRED / carto.com/basemaps/apikey`
/// watermark baked into the image. A tile server can start doing that at any
/// time; a single constant is what makes the swap a one-line change instead of
/// a hunt through every screen that happens to render a map.
///
/// OpenStreetMap's standard tiles need no key and no account. In exchange
/// their [tile usage policy](https://operations.osmfoundation.org/policies/tiles/)
/// asks for three things, all of which this app does:
///
///  * an identifying User-Agent — `userAgentPackageName: 'com.xlypton.masi'`
///    on every [TileLayer] (on web the browser sends its own UA plus the
///    origin as `Referer`, which serves the same purpose);
///  * visible attribution — [basemapAttribution], rendered as an
///    always-visible credit pill, never behind a tap-to-expand info icon;
///  * no bulk downloading and modest volume — the app only ever fetches the
///    tiles it is about to draw, and on web `MasiTileCachingProvider` keeps
///    them so a revisit costs nothing.
const String basemapUrlTemplate =
    'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

/// The deepest zoom OSM renders real tiles for. Past this flutter_map upscales
/// the last real tile rather than requesting one that would come back `404`
/// (CARTO went to 20; OSM stops at 19, so this dropped by one with the swap).
const int basemapMaxNativeZoom = 19;

/// The credit line. Must be visible without interaction — see the policy note
/// above. OSM's standard tiles are rendered by the OSM Foundation itself, so
/// the contributors line is the whole requirement; there is no second party to
/// credit the way `· CARTO` used to be.
const String basemapAttribution = '© OpenStreetMap contributors';

/// Paints OSM's standard tiles in Masi's colours.
///
/// The swap away from CARTO was a licensing fix that cost the app its look:
/// Positron is a near-white cartography designed to sit under data, and OSM's
/// standard style is the opposite — saturated greens, yellow roads, orange
/// POIs, drawn to be read on its own. Dropped into this app it reads as
/// somebody else's map with Masi's markers scattered on top ("the map is ugly
/// and missing the Masi style", 2026-09-02).
///
/// So the tiles are restyled on the client instead of shopping for another
/// server. Three moves, in this order, and the matrix below is the three of
/// them multiplied together:
///
///  1. **Desaturate to 12%.** Kills the forest greens and route-number
///     lozenges that fight the purple markers, while leaving just enough
///     colour that water still reads as water.
///  2. **Lift toward white** (scale 0.78, offset 64). Compresses the whole
///     image into the top of the range, which is what makes a basemap recede.
///     White stays white; black lands at a mid grey, so labels and paths stay
///     legible instead of vanishing.
///  3. **Blend 20% toward [MasiColors.amethyst100]**, the app's own lightest
///     lavender. This is the step that makes it Masi's map rather than a grey
///     one: the ground takes the same cool cast as every surface around it.
///
/// Applied as ONE [ColorFiltered] around the whole [TileLayer] rather than
/// through `TileLayer.tileBuilder`, which would be a `saveLayer` per tile
/// instead of per layer.
///
/// It is deliberately the same in dark mode, exactly as the CARTO basemap was:
/// a dark basemap is a different cartography, not a filtered one, and inverting
/// this one turns labels into holes.
const ColorFilter basemapTint = ColorFilter.matrix(<double>[
  0.19184, 0.39262, 0.03954, 0, 99.0, //
  0.11696, 0.46750, 0.03954, 0, 97.8, //
  0.11696, 0.39262, 0.11442, 0, 101.2, //
  0, 0, 0, 1, 0, //
]);
