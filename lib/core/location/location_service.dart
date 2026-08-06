import 'package:flutter/foundation.dart' show kIsWeb;
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

/// How long a single position fix is given before [LocationService.
/// currentLocation] gives up and reports "unavailable". A cold GPS fix on a
/// real phone is genuinely slow (the previous 10s cut off legitimate fixes
/// outdoors), and on web this clock also covers the browser's own permission
/// prompt, which the user may take several seconds to answer.
const Duration _fixTimeout = Duration(seconds: 15);

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

  /// Asks for the most precise fix the platform can give.
  ///
  /// [LocationAccuracy.best] is stated EXPLICITLY rather than relying on
  /// `LocationSettings`' default, because on web it is the only thing that
  /// sets `PositionOptions.enableHighAccuracy` — `geolocator_web` maps
  /// `lowest`/`low`/`medium`/`reduced` (and a null accuracy) to `false`, and
  /// a low-accuracy browser fix is Wi-Fi/IP-derived, i.e. the middle of your
  /// city rather than the crag you are standing at.
  ///
  /// [WebSettings] (rather than a plain [LocationSettings]) on web for one
  /// reason: `geolocator_web` only forwards `maximumAge` to
  /// `navigator.geolocation.getCurrentPosition` when the settings object is
  /// literally a `WebSettings`. `Duration.zero` forbids the browser from
  /// handing back a cached position — which matters because the permission
  /// prompt itself can leave a coarse one sitting in that cache.
  @override
  Future<Position> getCurrentPosition() => Geolocator.getCurrentPosition(
    locationSettings: kIsWeb
        ? WebSettings(
            accuracy: LocationAccuracy.best,
            maximumAge: Duration.zero,
            timeLimit: _fixTimeout,
          )
        : const LocationSettings(
            accuracy: LocationAccuracy.best,
            timeLimit: _fixTimeout,
          ),
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
  GeolocatorLocationService({
    GeolocatorBoundary? boundary,
    bool? requestsPermissionUpFront,
  }) : _boundary = boundary ?? _RealGeolocatorBoundary(),
       // Defaults to "native yes, web no" — see the field's doc. Injectable
       // so both branches are unit-testable off their real platform.
       _requestsPermissionUpFront = requestsPermissionUpFront ?? !kIsWeb;

  final GeolocatorBoundary _boundary;

  /// Whether a [LocationPermission.denied] verdict from
  /// [GeolocatorBoundary.checkPermission] should be answered with an
  /// explicit [GeolocatorBoundary.requestPermission] call before reading a
  /// position. True on native, false on web — and the difference is not
  /// cosmetic.
  ///
  /// On web, `denied` does not mean denied. `geolocator_web` maps the
  /// Permissions API's `'prompt'` state (i.e. "the user has not been asked
  /// yet", the normal first-run state) onto `LocationPermission.denied`, and
  /// implements `requestPermission()` as a bare
  /// `navigator.geolocation.getCurrentPosition()` with NO `PositionOptions`
  /// — so `enableHighAccuracy` defaults to `false`. That call is what
  /// actually raises the browser's permission prompt, and the fix it
  /// resolves with is a coarse, Wi-Fi/IP-derived one, thrown away for its
  /// permission verdict alone. It is also, on iOS Safari, what made both
  /// the map's auto-center and the find-me button land in the middle of the
  /// user's city instead of on the user.
  ///
  /// Skipping it on web loses nothing: [getCurrentPosition] raises the same
  /// prompt itself, at high accuracy, and a refusal surfaces as a
  /// `PermissionDeniedException` that [currentLocation]'s `catch` already
  /// turns into the same `null`. A genuinely blocked site still
  /// short-circuits earlier, since the browser reports that as
  /// [LocationPermission.deniedForever].
  final bool _requestsPermissionUpFront;

  @override
  Future<DeviceLocation?> currentLocation() async {
    try {
      final serviceEnabled = await _boundary.isLocationServiceEnabled();
      if (!serviceEnabled) return null;

      var permission = await _boundary.checkPermission();
      if (permission == LocationPermission.denied &&
          _requestsPermissionUpFront) {
        permission = await _boundary.requestPermission();
      }
      if (permission == LocationPermission.deniedForever ||
          (permission == LocationPermission.denied &&
              _requestsPermissionUpFront)) {
        return null;
      }

      // A SECOND, outer deadline on top of the `timeLimit` handed to the
      // platform, because on web that one does not work: `geolocator_web`
      // passes `timeLimit.inMicroseconds` into `PositionOptions.timeout`,
      // which is a MILLISECONDS field — so a 15s limit reaches the browser
      // as ~4 hours and an unanswered permission prompt would hang this
      // future (and the find-me button's spinner) indefinitely.
      final position = await _boundary.getCurrentPosition().timeout(
        _fixTimeout + const Duration(seconds: 5),
      );
      return (latitude: position.latitude, longitude: position.longitude);
    } catch (_) {
      // Best-effort: a timeout, a refused browser permission prompt, a
      // disabled-service exception raised instead of surfacing through
      // isLocationServiceEnabled, or any other platform-channel error must
      // never propagate to callers.
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
