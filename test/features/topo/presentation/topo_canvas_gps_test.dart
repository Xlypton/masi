// Tests for `captureWallGpsFromPhoto` (topo_canvas_screen.dart), the
// standalone function `_attachPhotoAndLoad` calls after every fresh photo
// attach on the OWN (non-community) topo canvas's add/replace-photo flow.
//
// Extracted as a standalone function (mirroring `loadWallOriginalPhoto`/
// `resolveAttachedPhotoPath` — see topo_canvas_screen.dart) precisely so
// this is testable directly against a real LibraryCrudRepository and a real
// file on disk: no widget pump, no `FileImage`/`ui.instantiateImageCodec`
// decode (which CLAUDE.md flags as hanging under fake-async in this repo),
// and no `image_picker` dependency at all — "injecting known bytes without
// a native picker" here just means writing them to a temp file and pointing
// this function at its path.
import 'dart:io';
import 'dart:typed_data';

import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/core/location/location_service.dart';
import 'package:climbtopo/features/library/data/library_crud_repository.dart';
import 'package:climbtopo/features/topo/presentation/topo_canvas_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
// See photo_gps_test.dart's identical import for why this reaches into
// package:image's src/ directly (Rational isn't exported from the barrel).
import 'package:image/src/util/rational.dart';
import 'package:image_picker/image_picker.dart';

/// A [LocationService] double that resolves to whatever fixed [result] it
/// was constructed with — no real geolocator call, ever, under
/// `flutter_test`. Mirrors `community_screen_test.dart`'s
/// `_FakeLocationService`.
class _FakeLocationService implements LocationService {
  const _FakeLocationService(this.result);

  final DeviceLocation? result;

  @override
  Future<DeviceLocation?> currentLocation() async => result;
}

List<int> _buildJpegBytes({double? latitude, double? longitude}) {
  final image = img.Image(width: 4, height: 4);

  if (latitude != null && longitude != null) {
    final gps = image.exif.gpsIfd;
    _setDms(gps, 'GPSLatitude', latitude, positiveRef: 'N', negativeRef: 'S');
    _setDms(gps, 'GPSLongitude', longitude, positiveRef: 'E', negativeRef: 'W');
  }

  return img.encodeJpg(image);
}

void _setDms(
  img.IfdDirectory gps,
  String tagPrefix,
  double decimal, {
  required String positiveRef,
  required String negativeRef,
}) {
  final ref = decimal < 0 ? negativeRef : positiveRef;
  final absolute = decimal.abs();
  final degrees = absolute.floor();
  final minutesFull = (absolute - degrees) * 60;
  final minutes = minutesFull.floor();
  final secondsFull = (minutesFull - minutes) * 60;
  final secondsNumerator = (secondsFull * 10000).round();

  gps['${tagPrefix}Ref'] = img.IfdValueAscii(ref);
  gps[tagPrefix] = img.IfdValueRational.list([
    Rational(degrees, 1),
    Rational(minutes, 1),
    Rational(secondsNumerator, 10000),
  ]);
}

void main() {
  late AppDatabase db;
  late Directory tempDir;
  late LibraryCrudRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = LibraryCrudRepository(db, nowMs: () => 1000);
    tempDir = Directory.systemTemp.createTempSync('topo_canvas_gps_test_');
  });

  tearDown(() async {
    await db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<String> seedWall() async {
    final area = await repo.createArea('Area');
    final sector = await repo.createSector(area.id, 'Sector');
    final wall = await repo.createWall(sector.id, 'Wall');
    return wall.id;
  }

  group('captureWallGpsFromPhoto', () {
    test('a picked photo with EXIF GPS sets the wall\'s coordinates', () async {
      final wallId = await seedWall();
      final file = File('${tempDir.path}/geotagged.jpg');
      file.writeAsBytesSync(
        _buildJpegBytes(latitude: 47.4979, longitude: 19.0402),
      );

      final result = await captureWallGpsFromPhoto(
        repo,
        wallId,
        XFile(file.path),
      );

      expect(
        result,
        GpsCaptureResult.exif,
        reason: 'G1: EXIF GPS found must report GpsCaptureResult.exif',
      );
      final wall = await (db.select(
        db.walls,
      )..where((t) => t.id.equals(wallId))).getSingle();
      expect(wall.latitude, closeTo(47.4979, 1e-4));
      expect(wall.longitude, closeTo(19.0402, 1e-4));
      expect(
        wall.dirty,
        isTrue,
        reason: 'setWallCoordinates must mark the wall dirty for sync',
      );
    });

    test('a picked photo with NO EXIF GPS leaves the wall\'s coordinates null, '
        'no crash', () async {
      final wallId = await seedWall();
      final file = File('${tempDir.path}/no-gps.jpg');
      file.writeAsBytesSync(_buildJpegBytes());

      final result = await captureWallGpsFromPhoto(
        repo,
        wallId,
        XFile(file.path),
      );

      expect(
        result,
        GpsCaptureResult.none,
        reason:
            'G3: no EXIF GPS and no locationService given at all must '
            'report GpsCaptureResult.none',
      );
      final wall = await (db.select(
        db.walls,
      )..where((t) => t.id.equals(wallId))).getSingle();
      expect(wall.latitude, isNull);
      expect(wall.longitude, isNull);
      expect(wall.dirty, isFalse);
    });

    test('G2/B-ii-1: NO EXIF GPS + a device location available + the wall has '
        'NO coordinates yet falls back to the device location, reporting '
        'GpsCaptureResult.deviceFallback', () async {
      final wallId = await seedWall();
      final file = File('${tempDir.path}/no-gps-device-fallback.jpg');
      file.writeAsBytesSync(_buildJpegBytes());

      final result = await captureWallGpsFromPhoto(
        repo,
        wallId,
        XFile(file.path),
        locationService: const _FakeLocationService((
          latitude: 47.4979,
          longitude: 19.0402,
        )),
      );

      expect(result, GpsCaptureResult.deviceFallback);
      final wall = await (db.select(
        db.walls,
      )..where((t) => t.id.equals(wallId))).getSingle();
      expect(wall.latitude, closeTo(47.4979, 1e-9));
      expect(wall.longitude, closeTo(19.0402, 1e-9));
      expect(wall.dirty, isTrue);
    });

    test(
      'G3/B-ii-2: NO EXIF GPS + device location denied/unavailable (null) '
      'leaves coordinates null, no crash, reports GpsCaptureResult.none',
      () async {
        final wallId = await seedWall();
        final file = File('${tempDir.path}/no-gps-no-device.jpg');
        file.writeAsBytesSync(_buildJpegBytes());

        final result = await captureWallGpsFromPhoto(
          repo,
          wallId,
          XFile(file.path),
          locationService: const _FakeLocationService(null),
        );

        expect(result, GpsCaptureResult.none);
        final wall = await (db.select(
          db.walls,
        )..where((t) => t.id.equals(wallId))).getSingle();
        expect(wall.latitude, isNull);
        expect(wall.longitude, isNull);
        expect(wall.dirty, isFalse);
      },
    );

    test('EXIF GPS wins over an available device location fallback, reporting '
        'GpsCaptureResult.exif', () async {
      final wallId = await seedWall();
      final file = File('${tempDir.path}/exif-wins.jpg');
      file.writeAsBytesSync(
        _buildJpegBytes(latitude: 47.4979, longitude: 19.0402),
      );

      final result = await captureWallGpsFromPhoto(
        repo,
        wallId,
        XFile(file.path),
        // A deliberately different device location -- if this "won" the
        // wall would end up with THESE coordinates instead of the EXIF
        // ones asserted below.
        locationService: const _FakeLocationService((
          latitude: 10,
          longitude: 10,
        )),
      );

      expect(result, GpsCaptureResult.exif);
      final wall = await (db.select(
        db.walls,
      )..where((t) => t.id.equals(wallId))).getSingle();
      expect(wall.latitude, closeTo(47.4979, 1e-4));
      expect(wall.longitude, closeTo(19.0402, 1e-4));
    });

    test('data-corruption regression: replacing a wall\'s photo with a '
        'NO-EXIF photo does NOT overwrite its EXISTING coordinates with the '
        'device\'s current location', () async {
      final wallId = await seedWall();
      // The wall is already correctly geotagged -- e.g. from a first
      // photo's real EXIF GPS at the actual crag.
      await repo.setWallCoordinates(wallId, 47.4979, 19.0402);

      final file = File('${tempDir.path}/replacement-no-gps.jpg');
      file.writeAsBytesSync(_buildJpegBytes());

      final result = await captureWallGpsFromPhoto(
        repo,
        wallId,
        XFile(file.path),
        // A deliberately different "home" location -- if the bug is
        // present, this ends up overwriting the crag coords above.
        locationService: const _FakeLocationService((
          latitude: 40.7128,
          longitude: -74.0060,
        )),
      );

      expect(
        result,
        GpsCaptureResult.none,
        reason:
            'G3: no EXIF GPS + the wall already has coordinates must '
            'report GpsCaptureResult.none -- no fallback was applied, '
            'even though a device location WAS available',
      );
      final wall = await (db.select(
        db.walls,
      )..where((t) => t.id.equals(wallId))).getSingle();
      expect(
        wall.latitude,
        closeTo(47.4979, 1e-4),
        reason:
            'the device\'s current location must never overwrite '
            'coordinates the wall already has',
      );
      expect(wall.longitude, closeTo(19.0402, 1e-4));
    });

    test('EXIF GPS on a replacement photo UPDATES a wall\'s existing '
        'coordinates -- EXIF is authoritative even on replace', () async {
      final wallId = await seedWall();
      await repo.setWallCoordinates(wallId, 47.4979, 19.0402);

      final file = File('${tempDir.path}/replacement-exif.jpg');
      file.writeAsBytesSync(
        _buildJpegBytes(latitude: 48.1372, longitude: 11.5755),
      );

      final result = await captureWallGpsFromPhoto(
        repo,
        wallId,
        XFile(file.path),
      );

      expect(result, GpsCaptureResult.exif);
      final wall = await (db.select(
        db.walls,
      )..where((t) => t.id.equals(wallId))).getSingle();
      expect(wall.latitude, closeTo(48.1372, 1e-4));
      expect(wall.longitude, closeTo(11.5755, 1e-4));
    });

    test('a missing file is a silent no-op: no crash, coordinates stay null, '
        'reports GpsCaptureResult.none', () async {
      final wallId = await seedWall();

      final result = await captureWallGpsFromPhoto(
        repo,
        wallId,
        XFile('${tempDir.path}/does-not-exist.jpg'),
      );

      expect(result, GpsCaptureResult.none);
      final wall = await (db.select(
        db.walls,
      )..where((t) => t.id.equals(wallId))).getSingle();
      expect(wall.latitude, isNull);
      expect(wall.longitude, isNull);
    });

    test('garbage (non-image) bytes at the path are a silent no-op: no crash, '
        'coordinates stay null, reports GpsCaptureResult.none', () async {
      final wallId = await seedWall();
      final file = File('${tempDir.path}/garbage.jpg');
      file.writeAsBytesSync(Uint8List.fromList(List<int>.filled(32, 0xFF)));

      final result = await captureWallGpsFromPhoto(
        repo,
        wallId,
        XFile(file.path),
      );

      expect(result, GpsCaptureResult.none);
      final wall = await (db.select(
        db.walls,
      )..where((t) => t.id.equals(wallId))).getSingle();
      expect(wall.latitude, isNull);
      expect(wall.longitude, isNull);
    });
  });
}
