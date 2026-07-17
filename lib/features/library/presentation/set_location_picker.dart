import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart'
    show Geolocator, LocationPermission, LocationSettings, Position;
import 'package:http/http.dart' show Client;
import 'package:latlong2/latlong.dart';

import '../../../app/theme.dart';
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
/// [tileProvider]/[controller]/[locationService] are test-injectable seams
/// mirroring `community_screen.dart`'s `_MapView` (`tileProvider`/
/// `controller`) and its "find me" button (`locationService`, via
/// `_onFindMePressed`'s `ref.read(locationServiceProvider)`) — production
/// (every real call site) leaves them all null.
Future<LatLng?> showSetLocationPicker(
  BuildContext context, {
  LatLng? initial,
  TileProvider? tileProvider,
  MapController? controller,
  LocationService? locationService,
}) {
  return Navigator.of(context).push<LatLng>(
    MaterialPageRoute<LatLng>(
      fullscreenDialog: true,
      builder: (context) => _SetLocationPicker(
        initial: initial,
        tileProvider: tileProvider,
        controller: controller,
        locationService: locationService,
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
  });

  final LatLng? initial;
  final TileProvider? tileProvider;
  final MapController? controller;
  final LocationService? locationService;

  @override
  ConsumerState<_SetLocationPicker> createState() =>
      _SetLocationPickerState();
}

class _SetLocationPickerState extends ConsumerState<_SetLocationPicker> {
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
    if (_ownsController) {
      _mapController.dispose();
    }
    final tileHttpClient = _tileHttpClient;
    if (tileHttpClient != null) {
      tileHttpClient.close();
    }
    super.dispose();
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
          // Subtle affordance explaining WHY Save is greyed out (see its
          // `onPressed` above) rather than leaving a disabled button
          // unexplained -- shown only until `_locationChosen` flips true,
          // then never again for this screen instance.
          if (!_locationChosen)
            Positioned(
              top: MasiSpacing.md,
              left: MasiSpacing.lg,
              right: MasiSpacing.lg,
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
                      borderRadius: BorderRadius.circular(MasiRadii.control),
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
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('set-location-my-location'),
        onPressed: _useMyLocation,
        icon: MasiIcon('my_location'),
        label: const Text('Use my location'),
      ),
    );
  }
}
