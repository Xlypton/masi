import 'dart:async' show Timer, unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart'
    show Geolocator, LocationPermission, LocationSettings, Position;
import 'package:http/http.dart' show Client;
import 'package:latlong2/latlong.dart';

import '../../../app/theme.dart';
import '../../../core/location/geocoding_service.dart';
import '../../../core/location/location_service.dart';
import '../../../shared/presentation/masi_icon.dart';
import '../../community/presentation/community_screen.dart'
    show buildResilientTileHttpClient, buildResilientTileProvider;

/// Pushes a full-screen "Set location" map picker and resolves to the
/// [LatLng] the user chose via the Save action, or `null` if they cancelled
/// (mirrors `move_target_picker.dart`'s `showMoveTargetPicker` value-
/// returning-picker shape — `topos_screen.dart`'s `_handleSetLocation`
/// awaits this exactly the way `_handleMove` awaits that one).
///
/// The picker itself is a plain pan-to-position-the-crosshair map (see
/// [_SetLocationPicker]): rather than a tappable map with a marker dropped
/// at the tapped point, a symmetric crosshair is fixed to the screen center
/// and the user pans the MAP underneath it, so "where the crosshair points"
/// is always unambiguous regardless of pinch/zoom in flight.
///
/// [initial] centers the map on an existing wall's coordinates (editing a
/// location that's already set) at zoom 14; `null` (no location yet) starts
/// on a neutral continental view while [_SetLocationPickerState] makes ONE
/// silent, best-effort attempt to recenter on the device's position instead
/// (see [_SetLocationPickerState._trySilentInitialRecenter]) — silent
/// meaning it only ever uses ALREADY-granted permission and never prompts;
/// the "use my location" button remains the explicit way in when that
/// permission hasn't been granted yet.
///
/// [tileProvider]/[controller]/[locationService]/[geocodingService] are
/// test-injectable seams mirroring `community_screen.dart`'s `_MapView`
/// (`tileProvider`/`controller`) and its "find me" button
/// (`locationService`, via `_onFindMePressed`'s
/// `ref.read(locationServiceProvider)`) — production (every real call site)
/// leaves them all null. [geocodingService] backs the place-search field
/// (see [_SetLocationPickerState._runSearch]) exactly the same way.
Future<LatLng?> showSetLocationPicker(
  BuildContext context, {
  LatLng? initial,
  TileProvider? tileProvider,
  MapController? controller,
  LocationService? locationService,
  GeocodingService? geocodingService,
}) {
  return Navigator.of(context).push<LatLng>(
    MaterialPageRoute<LatLng>(
      fullscreenDialog: true,
      builder: (context) => _SetLocationPicker(
        initial: initial,
        tileProvider: tileProvider,
        controller: controller,
        locationService: locationService,
        geocodingService: geocodingService,
      ),
    ),
  );
}

/// The full-screen picker body pushed by [showSetLocationPicker]: a
/// [FlutterMap] filling the body, a fixed center crosshair overlay (the
/// crosshair never moves — the user pans the map underneath it), an AppBar
/// with Cancel/Save actions, and a "use my location" button that recenters
/// the map on a fresh device fix.
class _SetLocationPicker extends ConsumerStatefulWidget {
  const _SetLocationPicker({
    this.initial,
    this.tileProvider,
    this.controller,
    this.locationService,
    this.geocodingService,
  });

  final LatLng? initial;
  final TileProvider? tileProvider;
  final MapController? controller;
  final LocationService? locationService;
  final GeocodingService? geocodingService;

  @override
  ConsumerState<_SetLocationPicker> createState() =>
      _SetLocationPickerState();
}

class _SetLocationPickerState extends ConsumerState<_SetLocationPicker> {
  /// Hard cap on the results dropdown's height (see its `ConstrainedBox` in
  /// `build()`) -- a fixed pixel value rather than a fraction of screen
  /// height so it stays predictable across devices; comfortably fits ~4
  /// dense two-line `ListTile`s before it clamps and starts scrolling. The
  /// fix for the dropdown having no height cap at all, which let a large
  /// `textScaler` or several long `displayName`s push it low enough to
  /// overlap the crosshair or clip off the bottom of small screens.
  static const double _searchResultsMaxHeight = 260;

  late final MapController _mapController;
  late final bool _ownsController;

  /// Whether the user has ACTIVELY chosen a location yet -- the single gate
  /// on whether `Save` is allowed to pop `_mapController.camera.center` (see
  /// its `onPressed` in [build]).
  ///
  /// Starts `true` when [widget.initial] is non-null (editing an existing,
  /// already-valid coordinate -- see C2 in the picker's doc) and `false`
  /// otherwise (a brand-new/unlocated topo has nothing meaningful to save
  /// yet). It flips to `true` only via [_handlePositionChanged] (a REAL
  /// gesture-driven pan/pinch, `hasGesture == true`) or [_useMyLocation]
  /// (the explicit "use my location" button) -- never via
  /// [_trySilentInitialRecenter]'s programmatic `_mapController.move`, which
  /// flutter_map itself reports as `hasGesture: false`. This is the fix for
  /// the data-integrity bug where a silent recenter onto the device's GPS,
  /// followed by an un-panned tap on Save, used to persist a location the
  /// user never actually chose.
  bool _locationChosen = false;

  /// The resilient tile HTTP client THIS state created (see [_tileProvider]),
  /// held so [dispose] can close exactly it — never an injected
  /// `widget.tileProvider` (e.g. a test's noop provider), which this widget
  /// never owns and must never touch. Mirrors `community_screen.dart`'s
  /// `_MapViewState` create-once/dispose-closes-client fix, avoiding the
  /// same "a new `http.Client` leaked on every rebuild" bug.
  Client? _tileHttpClient;
  NetworkTileProvider? _resilientTileProvider;

  /// Backing state for the place-search field (see `build()`'s search
  /// `Positioned`): [_searchController] holds the typed query,
  /// [_searchFocusNode] lets [_selectSearchResult] unfocus the field after a
  /// tap, [_debounce] is the in-flight "wait for the user to stop typing"
  /// timer (see [_onSearchChanged]), and [_searchResults] is the current
  /// candidate list rendered directly under the field (empty hides it).
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  Timer? _debounce;
  List<PlaceResult> _searchResults = const [];

  /// Monotonically increasing "which search is current" generation counter
  /// — the fix for the out-of-order-results race: a slow lookup for an
  /// earlier query must never clobber a faster, more recent one's results
  /// (or repopulate a since-cleared field) just because it happens to
  /// resolve later. Bumped by every [_onSearchChanged] call (both the
  /// immediate-clear path and the debounced-search path), which captures
  /// the post-bump value and threads it through to [_runSearch]; that
  /// method only applies its result if the captured value still matches
  /// [_searchSeq] by the time its `await` returns. Also bumped by
  /// [_selectSearchResult]'s programmatic `_searchController.text =`
  /// write, so the change listener it fires can recognize -- and no-op --
  /// that self-inflicted "change" instead of kicking off a fresh search
  /// (see [_lastProgrammaticQuery]).
  int _searchSeq = 0;

  /// The exact (trimmed) query [_selectSearchResult] last wrote into
  /// [_searchController] programmatically, or `null` when the field's
  /// current text was typed by the user. [_onSearchChanged] compares
  /// against this to distinguish "the user is typing" from "selecting a
  /// result just set the controller's text, which fired this same
  /// listener" -- the latter must no-op rather than re-searching for the
  /// place the user just picked. Cleared back to `null` the moment the
  /// user types anything themselves (in [_onSearchChanged]'s non-matching
  /// branch), so it only ever suppresses exactly the one synthetic change
  /// it was set up for.
  String? _lastProgrammaticQuery;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _mapController = widget.controller ?? MapController();
    _locationChosen = widget.initial != null;
    // Only when there's no existing coordinate to center on already -- an
    // editing flow (widget.initial != null) has a real location to show and
    // must never have it silently swapped for wherever the device happens
    // to be right now.
    if (widget.initial == null) {
      unawaited(_trySilentInitialRecenter());
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
    if (_ownsController) {
      _mapController.dispose();
    }
    final tileHttpClient = _tileHttpClient;
    if (tileHttpClient != null) {
      tileHttpClient.close();
    }
    super.dispose();
  }

  /// `set-location-search-field`'s `onChanged` handler: debounces (~350ms)
  /// before calling [GeocodingService.search], the standard "wait for the
  /// user to stop typing" pattern -- cancelling any in-flight timer on
  /// every keystroke (and in [dispose]) so a fast typist never fires one
  /// network lookup per character. An empty (or whitespace-only) query
  /// clears the results immediately without ever calling the service, so
  /// deleting all the typed text collapses the dropdown right away.
  ///
  /// Every call -- the immediate-clear branch AND the debounced-search
  /// branch -- bumps [_searchSeq] first, so any search already in flight
  /// (from an earlier, now-superseded query) is invalidated up front: even
  /// if it resolves later, [_runSearch]'s post-`await` generation check
  /// will see a stale value and discard it instead of repopulating (or
  /// clobbering) the results shown for THIS query.
  ///
  /// [_selectSearchResult] writes the picked place's name into
  /// [_searchController] programmatically, which fires this same
  /// `onChanged` listener; when the incoming [value] exactly matches
  /// [_lastProgrammaticQuery] this is recognized as that synthetic change
  /// (not the user typing) and no-ops instead of re-searching for the
  /// place just selected. Any OTHER value clears that flag, so it can only
  /// ever suppress the one change it was set up for.
  void _onSearchChanged(String value) {
    if (value == _lastProgrammaticQuery) {
      _lastProgrammaticQuery = null;
      return;
    }
    _lastProgrammaticQuery = null;
    _debounce?.cancel();
    final query = value.trim();
    _searchSeq++;
    final seq = _searchSeq;
    if (query.isEmpty) {
      setState(() => _searchResults = const []);
      return;
    }
    _debounce = Timer(
      const Duration(milliseconds: 350),
      () => _runSearch(query, seq),
    );
  }

  /// Runs the actual lookup once [_onSearchChanged]'s debounce timer fires.
  /// [GeocodingService.search] never throws (see its doc), so no try/catch
  /// is needed here. [seq] is the generation captured by [_onSearchChanged]
  /// at the moment THIS search was scheduled; after the `await`, the result
  /// is only applied when both the widget is still `mounted` (the timer can
  /// fire after this state is disposed, e.g. the user backs out of the
  /// picker mid-debounce) AND [seq] still matches the current [_searchSeq]
  /// -- i.e. no newer query (or a clear) has superseded this one in the
  /// meantime. This is what makes a slow lookup for an old query unable to
  /// overwrite a faster, more recent query's results. Caps the rendered
  /// list at 5 defensively, mirroring the real service's own `limit=5`
  /// query param.
  Future<void> _runSearch(String query, int seq) async {
    final GeocodingService service =
        widget.geocodingService ?? ref.read(geocodingServiceProvider);
    final results = await service.search(query);
    if (!mounted || seq != _searchSeq) return;
    setState(() => _searchResults = results.take(5).toList());
  }

  /// A search-result row's `onTap`: moves the map to the chosen place
  /// (mirrors [_useMyLocation]'s `_mapController.move` call), counts as an
  /// active choice exactly like that button does -- a searched place IS a
  /// deliberate pick, and this same `MapController.move` reports
  /// `hasGesture: false` to [_handlePositionChanged] just like
  /// [_useMyLocation]'s move does, so it can't rely on that hook either --
  /// then collapses the dropdown and unfocuses the field so the keyboard
  /// and result list don't linger over the newly-centered map.
  ///
  /// Also writes [result.displayName] into [_searchController] so the
  /// field visibly reflects what was picked instead of being left showing
  /// the raw typed query. That write fires [TextEditingController]'s
  /// change notification straight into [_onSearchChanged] (the same
  /// listener the `TextField`'s `onChanged` uses), which would otherwise
  /// kick off a brand-new debounced search for the place's own name -- so
  /// [_lastProgrammaticQuery] is set to the exact string being written
  /// FIRST, letting [_onSearchChanged] recognize and no-op that one
  /// synthetic change. [_searchSeq] is bumped too (invalidating any search
  /// still in flight for whatever the user had typed), independent of
  /// [_onSearchChanged]'s no-op path, so a stale in-flight lookup can never
  /// resurrect the dropdown after this selection.
  void _selectSearchResult(PlaceResult result) {
    _mapController.move(LatLng(result.latitude, result.longitude), 15);
    _debounce?.cancel();
    _searchSeq++;
    _lastProgrammaticQuery = result.displayName;
    _searchController.text = result.displayName;
    setState(() {
      _locationChosen = true;
      _searchResults = const [];
    });
    _searchFocusNode.unfocus();
  }

  /// This picker's [TileLayer.tileProvider]: [widget.tileProvider] when
  /// injected (every widget test), else a resilient [NetworkTileProvider]
  /// built ONCE for this state's entire lifetime and reused on every
  /// subsequent `build()` — see [_tileHttpClient]'s doc.
  TileProvider _tileProvider() {
    final injected = widget.tileProvider;
    if (injected != null) return injected;
    final existing = _resilientTileProvider;
    if (existing != null) return existing;
    final client = buildResilientTileHttpClient();
    _tileHttpClient = client;
    final provider = buildResilientTileProvider(httpClient: client);
    _resilientTileProvider = provider;
    return provider;
  }

  /// `set-location-my-location`'s handler: fetches one fresh device fix and
  /// recenters the map on it, mirroring `community_screen.dart`'s
  /// `_MapViewState._onFindMePressed`. [LocationService.currentLocation]
  /// never throws — a `null` result (denied/disabled/unavailable) surfaces
  /// as a brief SnackBar instead of moving the map.
  Future<void> _useMyLocation() async {
    final LocationService service =
        widget.locationService ?? ref.read(locationServiceProvider);
    final location = await service.currentLocation();
    if (!mounted) return;
    if (location == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Location unavailable')),
      );
      return;
    }
    _mapController.move(LatLng(location.latitude, location.longitude), 15);
    // An explicit tap on "use my location" IS an active choice (unlike
    // `_trySilentInitialRecenter`'s unrequested move) even though
    // flutter_map reports this same `MapController.move` call as
    // `hasGesture: false` too -- so `_handlePositionChanged` alone can't
    // distinguish the two and this flag is set directly here instead.
    setState(() => _locationChosen = true);
  }

  /// Fired once from [initState] (fire-and-forget, never awaited by
  /// [build]) when [widget.initial] is `null`: a SILENT best-effort attempt
  /// to recenter the still-neutral map on the device's position, so a
  /// first-time "set location" doesn't dead-end on the blank (0,0)
  /// mid-Atlantic view.
  ///
  /// Deliberately does NOT go through [LocationService.currentLocation] (the
  /// "use my location" button's helper, [_useMyLocation]) -- that helper
  /// calls `Geolocator.requestPermission()` whenever permission comes back
  /// `denied`, which would surprise-prompt the user just for opening this
  /// screen. Here, [Geolocator.checkPermission] is read-only: this is a
  /// no-op unless permission is ALREADY `whileInUse`/`always`, leaving the
  /// neutral continental fallback view from [build] to stand (the "use my
  /// location" button is still the explicit, prompting way in for a user
  /// who hasn't granted permission yet).
  ///
  /// This only ever moves the CAMERA via [_mapController] -- it never pops
  /// this route and never persists anything itself. `Save`'s handler reads
  /// `_mapController.camera.center` fresh at tap time regardless of how the
  /// camera got there (an existing manual pan, the "use my location"
  /// button, or this), so it naturally picks up a resolved position the
  /// same way it already picks up a manual pan; `Cancel` pops with no value
  /// regardless, so a "no-interaction" close (or one where this attempt
  /// never resolves/never finds a position) persists nothing, exactly as
  /// before this method existed.
  Future<void> _trySilentInitialRecenter() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return;

      final permission = await Geolocator.checkPermission();
      final alreadyGranted =
          permission == LocationPermission.whileInUse ||
          permission == LocationPermission.always;
      if (!alreadyGranted) return;

      Position? position = await Geolocator.getLastKnownPosition();
      position ??= await _currentPositionOrNull();
      if (position == null) return;

      if (!mounted) return;
      _mapController.move(LatLng(position.latitude, position.longitude), 13);
    } catch (_) {
      // Best-effort, mirroring GeolocatorLocationService.currentLocation:
      // never let a platform-channel error/timeout -- or, under
      // `flutter_test`, a missing plugin -- propagate. Worst case, the
      // neutral fallback view from `build` just stands.
    }
  }

  /// [MapOptions.onPositionChanged] hook -- the other half of [_useMyLocation]
  /// in keeping [_locationChosen] accurate: flutter_map calls this on every
  /// camera move and tells us via [hasGesture] whether a real user
  /// pan/pinch/fling caused it (`true`) or a programmatic
  /// `MapController.move`/`.moveAndRotate` did (`false`). Only a real
  /// gesture counts as the user actively choosing a location here --
  /// [_trySilentInitialRecenter]'s silent GPS recenter is exactly the
  /// `hasGesture: false` case this must ignore.
  void _handlePositionChanged(MapCamera camera, bool hasGesture) {
    if (hasGesture && !_locationChosen) {
      setState(() => _locationChosen = true);
    }
  }

  /// [Geolocator.getCurrentPosition] wrapped to resolve to `null` instead of
  /// throwing/timing out, used only as a fallback from
  /// [_trySilentInitialRecenter] when [Geolocator.getLastKnownPosition] has
  /// no cached fix yet.
  Future<Position?> _currentPositionOrNull() async {
    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          timeLimit: Duration(seconds: 5),
        ),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final initial = widget.initial;
    final center = initial ?? const LatLng(0, 0);
    // `MapOptions.initialCenter`/`initialZoom` are honored ONCE, at first
    // mount (flutter_map semantics -- see `community_screen.dart`'s
    // `_MapViewState` doc for the same fact) -- so with no `initial` this is
    // always the view on first paint, even though
    // `_trySilentInitialRecenter` may move the camera a moment later. A
    // gentle continental zoom (landmasses visible) reads as "still loading
    // your position" rather than the blank mid-Atlantic ocean zoom 2 used to
    // dead-end on.
    final zoom = initial != null ? 14.0 : 3.5;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Set location'),
        leadingWidth: 96,
        leading: TextButton(
          key: const Key('set-location-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        actions: [
          TextButton(
            key: const Key('set-location-save'),
            // Disabled until `_locationChosen` flips true (see its doc) --
            // this is the fix itself: an un-panned Save can no longer
            // silently persist wherever `_trySilentInitialRecenter` (or the
            // neutral fallback view) happened to leave the camera.
            onPressed: _locationChosen
                ? () => Navigator.of(context).pop(_mapController.camera.center)
                : null,
            child: const Text('Save'),
          ),
        ],
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: center,
              initialZoom: zoom,
              onPositionChanged: _handlePositionChanged,
              // Rotation is disabled outright — an accidental two-finger
              // twist must never spin the map. Every other usual pan/zoom
              // gesture stays enabled; only `InteractiveFlag.rotate` is
              // omitted from the flags that would otherwise default to
              // `InteractiveFlag.all`.
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.drag |
                    InteractiveFlag.flingAnimation |
                    InteractiveFlag.pinchMove |
                    InteractiveFlag.pinchZoom |
                    InteractiveFlag.doubleTapZoom |
                    InteractiveFlag.doubleTapDragZoom |
                    InteractiveFlag.scrollWheelZoom,
              ),
            ),
            children: [
              TileLayer(
                urlTemplate:
                    'https://basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png',
                userAgentPackageName: 'com.climbtopo.climbtopo',
                tileProvider: _tileProvider(),
                retinaMode: RetinaMode.isHighDensity(context),
                evictErrorTileStrategy:
                    EvictErrorTileStrategy.notVisibleRespectMargin,
                maxNativeZoom: 20,
                keepBuffer: 3,
              ),
            ],
          ),
          // Fixed center crosshair: pinned to the screen center (NOT a map
          // marker layer, which would pan/zoom with the map) — the user
          // positions the location by panning the map underneath this fixed
          // crosshair. It MUST be symmetric about its own center, because
          // Save reads `mapController.camera.center` (the screen center,
          // i.e. this widget's geometric center) as the coordinate to
          // persist — an asymmetric glyph like a teardrop pin would save a
          // point offset from where the user visually aligned it.
          // `IgnorePointer` keeps it from stealing the map's own pan/zoom
          // gestures.
          IgnorePointer(
            child: Center(
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // White halo behind the crosshair so it stays legible
                  // over the light CartoDB basemap tiles.
                  MasiIcon('my_location', size: 34, color: Colors.white),
                  MasiIcon(
                    'my_location',
                    key: const Key('set-location-crosshair'),
                    size: 28,
                    color: colors.accent,
                  ),
                ],
              ),
            ),
          ),
          // Place-search field + its result dropdown + (when still
          // relevant) the "pan to place the pin" hint, top to bottom in one
          // `Positioned` `Column` -- deliberately NOT wrapped in
          // `IgnorePointer` (unlike the crosshair above and the hint's own
          // inner wrapper below) since the field needs real keyboard/tap
          // input. Placed AFTER the crosshair in this `Stack`'s children so
          // it paints on top and is hit-tested first, even though visually
          // it sits near the top of the screen rather than centered.
          Positioned(
            top: MasiSpacing.md,
            left: MasiSpacing.lg,
            right: MasiSpacing.lg,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Material(
                  color: Colors.transparent,
                  child: TextField(
                    key: const Key('set-location-search-field'),
                    controller: _searchController,
                    focusNode: _searchFocusNode,
                    onChanged: _onSearchChanged,
                    decoration: InputDecoration(
                      hintText: 'Search for a place',
                      prefixIcon: MasiIcon('search', size: 16, color: colors.ink3),
                      prefixIconConstraints: const BoxConstraints.tightFor(
                        width: 16,
                        height: 16,
                      ),
                      filled: true,
                      fillColor: colors.surface2,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide(color: colors.separator),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide(color: colors.separator),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide(color: colors.accent, width: 1.5),
                      ),
                    ),
                  ),
                ),
                // The candidate dropdown: hidden entirely when there's no
                // query (see `_onSearchChanged`, which resets this to
                // empty) or when the query matched nothing -- never a
                // separate "loading"/error state, since
                // `GeocodingService.search` never throws (see its doc).
                if (_searchResults.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(top: MasiSpacing.xs),
                    // `Material` (not a plain `Container` + `BoxDecoration`)
                    // so its background/rounding AND every `ListTile`
                    // below paint correctly -- a `ListTile` always paints
                    // its own background/ink splashes on the nearest
                    // `Material` ancestor, so a `DecoratedBox` in between
                    // (what a `Container.decoration` would insert) makes
                    // Flutter raise "ListTile background color or ink
                    // splashes may be invisible" at runtime.
                    child: Material(
                      color: colors.surface,
                      borderRadius: BorderRadius.circular(MasiRadii.control),
                      clipBehavior: Clip.antiAlias,
                      elevation: 4,
                      // Caps how tall the dropdown can grow: with `shrinkWrap`
                      // still `true`, a short result list still sizes to its
                      // own content (no wasted empty space) exactly as
                      // before, but a list that WOULD exceed
                      // `_searchResultsMaxHeight` -- many rows, a large
                      // `textScaler`, long `displayName`s wrapping to their
                      // full 2 `maxLines` -- is clamped to that height
                      // instead of growing without bound. Scrolling (the
                      // default physics below, replacing the old
                      // `NeverScrollableScrollPhysics`) is what makes the
                      // clamped remainder reachable rather than clipped: a
                      // `ListView` whose content exceeds its own bounded
                      // height still reports a nonzero `maxScrollExtent`
                      // even while `shrinkWrap: true`, so it scrolls rather
                      // than either overflowing the render box or silently
                      // truncating. Bounding it also keeps it from ever
                      // growing tall enough to cover the centered crosshair
                      // or the "Use my location" FAB in the common case.
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxHeight: _searchResultsMaxHeight,
                        ),
                        child: ListView.separated(
                          shrinkWrap: true,
                          padding: EdgeInsets.zero,
                          itemCount: _searchResults.length,
                          separatorBuilder: (_, _) =>
                              Divider(height: 1, color: colors.separator),
                          itemBuilder: (context, i) {
                            final result = _searchResults[i];
                            return ListTile(
                              key: Key('set-location-search-result-$i'),
                              dense: true,
                              leading: MasiIcon(
                                'search',
                                size: 18,
                                color: colors.ink3,
                              ),
                              title: Text(
                                result.displayName,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onTap: () => _selectSearchResult(result),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                // Subtle affordance explaining WHY Save is greyed out (see
                // its `onPressed` above) rather than leaving a disabled
                // button unexplained -- shown only until `_locationChosen`
                // flips true, then never again for this screen instance.
                // Now flows directly below the search field/results (see
                // this `Positioned`'s doc) instead of its own fixed
                // top-of-screen slot, so it never overlaps either.
                if (!_locationChosen)
                  Padding(
                    padding: const EdgeInsets.only(top: MasiSpacing.sm),
                    child: IgnorePointer(
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: Container(
                          key: const Key('set-location-hint'),
                          padding: const EdgeInsets.symmetric(
                            horizontal: MasiSpacing.md,
                            vertical: MasiSpacing.sm,
                          ),
                          decoration: BoxDecoration(
                            color: colors.surface.withValues(alpha: 0.92),
                            borderRadius: BorderRadius.circular(
                              MasiRadii.control,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              MasiIcon('info', size: 16, color: colors.ink2),
                              const SizedBox(width: MasiSpacing.xs),
                              Flexible(
                                child: Text(
                                  'Pan the map to place the pin',
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(color: colors.ink2),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('set-location-my-location'),
        onPressed: _useMyLocation,
        icon: MasiIcon('my_location'),
        label: const Text('Use my location'),
      ),
    );
  }
}
