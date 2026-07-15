import 'package:climbtopo/core/location/location_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';

/// A [GeolocatorBoundary] double whose every call is scripted per-test —
/// never touches a real platform channel, so [GeolocatorLocationService]'s
/// permission/service-enabled logic is exercised in plain `flutter_test`.
class _FakeGeolocatorBoundary implements GeolocatorBoundary {
  _FakeGeolocatorBoundary({
    this.serviceEnabled = true,
    this.checkResult = LocationPermission.whileInUse,
    this.requestResult = LocationPermission.whileInUse,
    this.throwOn,
  });

  final bool serviceEnabled;
  final LocationPermission checkResult;
  final LocationPermission requestResult;

  /// When non-null, the named call ('serviceEnabled' | 'check' | 'request' |
  /// 'position') throws instead of returning normally, so the "never
  /// throws" contract can be exercised at each step.
  final String? throwOn;

  bool requestPermissionCalled = false;

  @override
  Future<bool> isLocationServiceEnabled() async {
    if (throwOn == 'serviceEnabled') throw Exception('boom');
    return serviceEnabled;
  }

  @override
  Future<LocationPermission> checkPermission() async {
    if (throwOn == 'check') throw Exception('boom');
    return checkResult;
  }

  @override
  Future<LocationPermission> requestPermission() async {
    requestPermissionCalled = true;
    if (throwOn == 'request') throw Exception('boom');
    return requestResult;
  }

  @override
  Future<Position> getCurrentPosition() async {
    if (throwOn == 'position') throw Exception('boom');
    return _fixedPosition;
  }
}

final _fixedPosition = Position(
  latitude: 46.0569,
  longitude: 14.5058,
  timestamp: DateTime.utc(2026, 1, 1),
  accuracy: 5,
  altitude: 0,
  altitudeAccuracy: 0,
  heading: 0,
  headingAccuracy: 0,
  speed: 0,
  speedAccuracy: 0,
);

/// A trivial [LocationService] fake used by consumer tests (the Community
/// map's "you are here" marker, the photo-import GPS fallback): returns
/// whatever [result] was constructed with, with no geolocator involved at
/// all.
class FakeLocationService implements LocationService {
  const FakeLocationService(this.result);

  final DeviceLocation? result;

  @override
  Future<DeviceLocation?> currentLocation() async => result;
}

void main() {
  group('FakeLocationService', () {
    test('returns the fixed position it was constructed with', () async {
      const service = FakeLocationService((
        latitude: 46.0569,
        longitude: 14.5058,
      ));
      final result = await service.currentLocation();
      expect(result, (latitude: 46.0569, longitude: 14.5058));
    });

    test('returns null when constructed with null', () async {
      const service = FakeLocationService(null);
      final result = await service.currentLocation();
      expect(result, isNull);
    });
  });

  group('GeolocatorLocationService', () {
    test('returns coordinates when service enabled and permission already '
        'granted', () async {
      final boundary = _FakeGeolocatorBoundary(
        checkResult: LocationPermission.whileInUse,
      );
      final service = GeolocatorLocationService(boundary: boundary);

      final result = await service.currentLocation();

      expect(result, (latitude: 46.0569, longitude: 14.5058));
      expect(
        boundary.requestPermissionCalled,
        isFalse,
        reason: 'must not re-prompt when already granted',
      );
    });

    test('requests permission and succeeds when initial check is denied but '
        'the request is granted', () async {
      final boundary = _FakeGeolocatorBoundary(
        checkResult: LocationPermission.denied,
        requestResult: LocationPermission.whileInUse,
      );
      final service = GeolocatorLocationService(boundary: boundary);

      final result = await service.currentLocation();

      expect(result, isNotNull);
      expect(boundary.requestPermissionCalled, isTrue);
    });

    test('returns null when location services are disabled', () async {
      final boundary = _FakeGeolocatorBoundary(serviceEnabled: false);
      final service = GeolocatorLocationService(boundary: boundary);

      final result = await service.currentLocation();

      expect(result, isNull);
    });

    test('returns null when permission is denied and the request is also '
        'denied', () async {
      final boundary = _FakeGeolocatorBoundary(
        checkResult: LocationPermission.denied,
        requestResult: LocationPermission.denied,
      );
      final service = GeolocatorLocationService(boundary: boundary);

      final result = await service.currentLocation();

      expect(result, isNull);
      expect(boundary.requestPermissionCalled, isTrue);
    });

    test('returns null when permission is permanently denied, without '
        'requesting', () async {
      final boundary = _FakeGeolocatorBoundary(
        checkResult: LocationPermission.deniedForever,
      );
      final service = GeolocatorLocationService(boundary: boundary);

      final result = await service.currentLocation();

      expect(result, isNull);
      expect(
        boundary.requestPermissionCalled,
        isFalse,
        reason: 'deniedForever must never trigger a re-prompt',
      );
    });

    test(
      'returns null (never throws) when isLocationServiceEnabled throws',
      () async {
        final boundary = _FakeGeolocatorBoundary(throwOn: 'serviceEnabled');
        final service = GeolocatorLocationService(boundary: boundary);

        final result = await service.currentLocation();

        expect(result, isNull);
      },
    );

    test('returns null (never throws) when checkPermission throws', () async {
      final boundary = _FakeGeolocatorBoundary(throwOn: 'check');
      final service = GeolocatorLocationService(boundary: boundary);

      final result = await service.currentLocation();

      expect(result, isNull);
    });

    test('returns null (never throws) when getCurrentPosition throws '
        '(e.g. a timeout)', () async {
      final boundary = _FakeGeolocatorBoundary(throwOn: 'position');
      final service = GeolocatorLocationService(boundary: boundary);

      final result = await service.currentLocation();

      expect(result, isNull);
    });
  });
}
