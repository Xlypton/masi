import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

/// WGS84 coordinates for the device's current position, as resolved by
/// [LocationService.currentLocation]. Shares its `({double latitude, double
/// longitude})` shape with `core/location/photo_gps.dart`'s `PhotoGps` (they
/// are deliberately NOT unified into one typedef: one is EXIF-derived, the
/// other device-GPS-derived, and callers that care about the distinction —
/// e.g. B-ii's "EXIF wins, device location is only a fallback" — read more
/// clearly with two named types than one shared one).
typedef DeviceLocation = ({double latitude, double longitude});

/// Abstraction over "where is this device right now", so callers (the
/// Community map's "you are here" marker, and the photo-import GPS fallback)
/// never talk to `package:geolocator` directly and so are trivially fakeable
/// in widget/unit tests.
///
/// [currentLocation] is deliberately best-effort and NEVER throws: any
/// denied/permanently-denied permission, disabled location service, timeout,
/// or platform-channel error resolves to `null` rather than propagating an
/// exception, exactly like `photo_gps.dart`'s [extractGpsFromImageBytes] —
/// neither the map nor the photo-import flow should ever crash or stall
/// because location wasn't available.
abstract class LocationService {
  Future<DeviceLocation?> currentLocation();
}

/// Thin seam over the handful of static `Geolocator` calls
/// [GeolocatorLocationService] needs, so that class can be unit-tested
/// without a real platform channel: tests inject a fake [GeolocatorBoundary]
/// that simulates a denied/disabled/throwing device instead of the real one.
abstract class GeolocatorBoundary {
  Future<bool> isLocationServiceEnabled();
  Future<LocationPermission> checkPermission();
  Future<LocationPermission> requestPermission();
  Future<Position> getCurrentPosition();
}

/// The real [GeolocatorBoundary], delegating to `package:geolocator`'s
/// static `Geolocator` methods.
class _RealGeolocatorBoundary implements GeolocatorBoundary {
  @override
  Future<bool> isLocationServiceEnabled() =>
      Geolocator.isLocationServiceEnabled();

  @override
  Future<LocationPermission> checkPermission() => Geolocator.checkPermission();

  @override
  Future<LocationPermission> requestPermission() =>
      Geolocator.requestPermission();

  @override
  Future<Position> getCurrentPosition() => Geolocator.getCurrentPosition(
    locationSettings: const LocationSettings(timeLimit: Duration(seconds: 10)),
  );
}

/// The real [LocationService], backed by `package:geolocator` (via
/// [boundary], defaulting to [_RealGeolocatorBoundary]).
///
/// Never throws (see [LocationService.currentLocation]'s doc): checks
/// [GeolocatorBoundary.isLocationServiceEnabled] first (device location
/// switched off entirely), then [GeolocatorBoundary.checkPermission] —
/// requesting it via [GeolocatorBoundary.requestPermission] only when it
/// comes back [LocationPermission.denied] (i.e. never re-prompts a user who
/// already permanently denied it) — and finally reads a position via
/// [GeolocatorBoundary.getCurrentPosition]. Any `false`/denied/
/// deniedForever/exception at any step short-circuits to `null`.
class GeolocatorLocationService implements LocationService {
  GeolocatorLocationService({GeolocatorBoundary? boundary})
    : _boundary = boundary ?? _RealGeolocatorBoundary();

  final GeolocatorBoundary _boundary;

  @override
  Future<DeviceLocation?> currentLocation() async {
    try {
      final serviceEnabled = await _boundary.isLocationServiceEnabled();
      if (!serviceEnabled) return null;

      var permission = await _boundary.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await _boundary.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }

      final position = await _boundary.getCurrentPosition();
      return (latitude: position.latitude, longitude: position.longitude);
    } catch (_) {
      // Best-effort: a timeout, a disabled-service exception raised instead
      // of surfacing through isLocationServiceEnabled, or any other
      // platform-channel error must never propagate to callers.
      return null;
    }
  }
}

/// The app-wide [LocationService] seam. Overridden in tests with a fake that
/// returns a fixed [DeviceLocation] or `null` — never the real
/// [GeolocatorLocationService], which would touch a real platform channel.
final locationServiceProvider = Provider<LocationService>(
  (ref) => GeolocatorLocationService(),
);
