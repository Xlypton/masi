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
import 'package:climbtopo/features/library/data/library_crud_repository.dart';
import 'package:climbtopo/features/topo/presentation/topo_canvas_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
// See photo_gps_test.dart's identical import for why this reaches into
// package:image's src/ directly (Rational isn't exported from the barrel).
import 'package:image/src/util/rational.dart';

List<int> _buildJpegBytes({double? latitude, double? longitude}) {
  final image = img.Image(width: 4, height: 4);

  if (latitude != null && longitude != null) {
    final gps = image.exif.gpsIfd;
    _setDms(gps, 'GPSLatitude', latitude, positiveRef: 'N', negativeRef: 'S');
    _setDms(
      gps,
      'GPSLongitude',
      longitude,
      positiveRef: 'E',
      negativeRef: 'W',
    );
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
    test(
      'a picked photo with EXIF GPS sets the wall\'s coordinates',
      () async {
        final wallId = await seedWall();
        final file = File('${tempDir.path}/geotagged.jpg');
        file.writeAsBytesSync(
          _buildJpegBytes(latitude: 47.4979, longitude: 19.0402),
        );

        await captureWallGpsFromPhoto(repo, wallId, file.path);

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
      },
    );

    test(
      'a picked photo with NO EXIF GPS leaves the wall\'s coordinates null, '
      'no crash',
      () async {
        final wallId = await seedWall();
        final file = File('${tempDir.path}/no-gps.jpg');
        file.writeAsBytesSync(_buildJpegBytes());

        await captureWallGpsFromPhoto(repo, wallId, file.path);

        final wall = await (db.select(
          db.walls,
        )..where((t) => t.id.equals(wallId))).getSingle();
        expect(wall.latitude, isNull);
        expect(wall.longitude, isNull);
        expect(wall.dirty, isFalse);
      },
    );

    test(
      'a missing file is a silent no-op: no crash, coordinates stay null',
      () async {
        final wallId = await seedWall();

        await captureWallGpsFromPhoto(
          repo,
          wallId,
          '${tempDir.path}/does-not-exist.jpg',
        );

        final wall = await (db.select(
          db.walls,
        )..where((t) => t.id.equals(wallId))).getSingle();
        expect(wall.latitude, isNull);
        expect(wall.longitude, isNull);
      },
    );

    test(
      'garbage (non-image) bytes at the path are a silent no-op: no crash, '
      'coordinates stay null',
      () async {
        final wallId = await seedWall();
        final file = File('${tempDir.path}/garbage.jpg');
        file.writeAsBytesSync(Uint8List.fromList(List<int>.filled(32, 0xFF)));

        await captureWallGpsFromPhoto(repo, wallId, file.path);

        final wall = await (db.select(
          db.walls,
        )..where((t) => t.id.equals(wallId))).getSingle();
        expect(wall.latitude, isNull);
        expect(wall.longitude, isNull);
      },
    );
  });
}
