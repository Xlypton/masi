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
