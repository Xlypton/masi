import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' show Client;
import 'package:latlong2/latlong.dart';

import '../../../app/theme.dart';
import '../../../core/location/location_service.dart';
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
/// on a neutral, zoomed-out world view — the "use my location" button is
/// the way in for a user with no existing coordinates, rather than this
/// picker guessing at an unrequested device fix on open.
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
  }

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final initial = widget.initial;
    final center = initial ?? const LatLng(0, 0);
    final zoom = initial != null ? 14.0 : 2.0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Set location'),
        leadingWidth: 72,
        leading: TextButton(
          key: const Key('set-location-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        actions: [
          TextButton(
            key: const Key('set-location-save'),
            onPressed: () =>
                Navigator.of(context).pop(_mapController.camera.center),
            child: const Text('Save'),
          ),
        ],
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(initialCenter: center, initialZoom: zoom),
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
                  Icon(Icons.gps_fixed, size: 34, color: Colors.white),
                  Icon(
                    Icons.gps_fixed,
                    key: const Key('set-location-crosshair'),
                    size: 28,
                    color: colors.accent,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('set-location-my-location'),
        onPressed: _useMyLocation,
        icon: const Icon(Icons.my_location),
        label: const Text('Use my location'),
      ),
    );
  }
}
