/// The raster basemap every map surface in the app draws on.
///
/// This lives in one place because the choice is not a style preference — it
/// is a licensing constraint, and getting it wrong is *visible to the user as
/// text printed across the map*. CARTO stopped serving these tiles
/// anonymously: the endpoint kept answering `200` with a valid PNG, so nothing
/// in the retry or eviction machinery noticed anything was wrong, but every
/// tile arrived carrying a diagonal `API KEY REQUIRED / carto.com/basemaps/apikey`
/// watermark baked into the image. A tile server can start doing that at any
/// time; a single constant is what makes the swap a one-line change instead of
/// a hunt through every screen that happens to render a map.
///
/// The app spent a few hours on keyless OpenStreetMap tiles in between, under a
/// colour filter that pulled them toward the app's palette. That worked and is
/// worth remembering as the no-key escape hatch (see git history for the
/// matrix), but it was not this: Positron is a cartography designed to sit
/// under data, and a filtered general-purpose map only ever approximates it.
library;

/// The CARTO basemap key.
///
/// **Public by construction, and committed on purpose** — the same call as
/// `supabaseAnonKey`. A web app cannot hide a key it puts in a tile URL, which
/// is why CARTO issues these per-domain, over email, with no account and no
/// approval step. Rotating it is another one-minute form at
/// carto.com/basemaps/apikey, so the cost of it leaking is a rotation, not an
/// incident.
///
/// Overridable with `--dart-define=MASI_CARTO_KEY=…` for anyone who would
/// rather not ship the committed one (a fork, or a separate domain), because
/// CARTO asks that a key not be shared across unrelated projects.
const String cartoBasemapKey = String.fromEnvironment(
  'MASI_CARTO_KEY',
  defaultValue: 'cb1_2tdk_1_f62f62c1d553920476bbdeeb',
);

/// CARTO Positron ("light_all"), the near-white cartography this app is drawn
/// against — pale ground, grey labels, no colour of its own to fight the
/// purple route markers.
///
/// `{r}` is flutter_map's retina placeholder: CARTO serves a real `@2x` tile,
/// so on a phone this is genuinely twice the resolution rather than an upscale.
///
/// Free up to 5 million tile requests a month, which this app will not
/// approach. The conditions are attribution ([basemapAttribution], visible
/// without interaction) and not reusing the key for unrelated projects.
///
/// **Known expiry: CARTO is retiring raster.** Their docs say the raster
/// basemaps are "being retired" and that they are considering stopping data
/// updates to them, with vector as the recommended path. No date is given. The
/// vector migration is a real piece of work rather than a URL swap — on web the
/// vector renderers have no persistent tile cache, and this app's offline map
/// (`MasiTileCachingProvider`) is raster-only — so it is a deliberate project,
/// not something to be surprised by. When it happens, this constant is again
/// the only line that has to change.
String get basemapUrlTemplate =>
    'https://basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png'
    '?key=$cartoBasemapKey';

/// The deepest zoom CARTO renders real tiles for. Past this flutter_map
/// upscales the last real tile rather than requesting one that would come back
/// `404`.
const int basemapMaxNativeZoom = 20;

/// The credit line. Must be visible without interaction — CARTO's terms are
/// explicit that "CARTO and OpenStreetMap must be credited on every map", and
/// OSM's tile policy says the same of its data. A collapsed info-icon popup
/// does not satisfy either.
const String basemapAttribution = '© OpenStreetMap contributors · CARTO';
