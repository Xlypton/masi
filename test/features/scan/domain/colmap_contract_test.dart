import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:masi/features/scan/domain/point_cloud.dart';
import 'package:masi/features/scan/domain/rock_scan_manifest.dart';

/// The cross-language contract test.
///
/// Both halves of this feature were built against a written spec rather than
/// against each other: the Python worker in `tool/rock_scan_worker/` writes
/// the PLY and the manifest, and the Dart in `lib/features/scan/` reads them.
/// Every other test on either side uses fixtures that side built itself,
/// which proves each is self-consistent and proves nothing about the seam.
///
/// These two files are REAL worker output — produced by running the worker's
/// own end-to-end integration test against COLMAP 3.9.1 and ffmpeg 6.1.1 on
/// a synthetic scene, then copied here verbatim. If the worker's output shape
/// drifts, this is the test that fails.
void main() {
  late Uint8List ply;
  late String manifestJson;

  setUpAll(() {
    ply = File('test/features/scan/fixtures/colmap_sample.ply')
        .readAsBytesSync();
    manifestJson = File(
      'test/features/scan/fixtures/colmap_manifest.json',
    ).readAsStringSync();
  });

  group('a real COLMAP point cloud', () {
    test('parses, with the vertex count the header declares', () {
      final cloud = PointCloud.tryParseBinaryPly(ply);
      expect(
        cloud,
        isNotNull,
        reason: 'this is literal worker output — if it does not parse, the '
            'two halves of the feature do not agree',
      );
      // The header of this fixture says 2812.
      expect(cloud!.pointCount, 2812);
    });

    test('its bounds match what the worker independently computed', () {
      // The worker measured these in Python, over the same points, before
      // writing the file. Agreement here means the byte layout is being read
      // the way it was written — not merely that SOME numbers came out.
      final cloud = PointCloud.tryParseBinaryPly(ply)!;
      final manifest = RockScanManifest.tryParse(manifestJson)!;

      expect(cloud.minX, closeTo(manifest.boundsMin![0], 1e-3));
      expect(cloud.minY, closeTo(manifest.boundsMin![1], 1e-3));
      expect(cloud.minZ, closeTo(manifest.boundsMin![2], 1e-3));
      expect(cloud.maxX, closeTo(manifest.boundsMax![0], 1e-3));
      expect(cloud.maxY, closeTo(manifest.boundsMax![1], 1e-3));
      expect(cloud.maxZ, closeTo(manifest.boundsMax![2], 1e-3));
    });

    test('the manifest agrees with the cloud on how many points there are',
        () {
      final cloud = PointCloud.tryParseBinaryPly(ply)!;
      final manifest = RockScanManifest.tryParse(manifestJson)!;
      expect(cloud.pointCount, manifest.pointCount);
    });
  });

  group('a real worker manifest', () {
    test('parses and carries the fields the UI actually reads', () {
      final manifest = RockScanManifest.tryParse(manifestJson)!;
      expect(manifest.version, RockScanManifest.currentVersion);
      expect(manifest.isFutureVersion, isFalse);
      expect(manifest.engine, 'colmap');
      expect(manifest.engineVersion, isNotNull);
      expect(manifest.framesExtracted, greaterThan(0));
      expect(manifest.framesRegistered, greaterThan(0));
      expect(manifest.pointCount, greaterThan(0));
      expect(manifest.registeredRatio, isNotNull);
      expect(manifest.cameras, isNotEmpty);
      expect(manifest.extent, isNotNull);
    });

    test('reports NO metric scale, which is the correct answer here', () {
      // Structure-from-motion recovers geometry only up to a similarity
      // transform. This reconstruction had no scale reference, so the worker
      // must report null rather than a plausible-looking 1.0 — and the app
      // must therefore show no measurement. A regression on either side turns
      // an unknown into a wrong number on a climber's screen.
      final manifest = RockScanManifest.tryParse(manifestJson)!;
      expect(manifest.metresPerUnit, isNull);
      expect(manifest.scaleSource, isNull);
      expect(manifest.hasMetricScale, isFalse);
    });

    test('every camera position is a well-formed 3-vector', () {
      final manifest = RockScanManifest.tryParse(manifestJson)!;
      final decoded = jsonDecode(manifestJson) as Map<String, dynamic>;
      expect(
        manifest.cameras.length,
        (decoded['cameras'] as List).length,
        reason: 'a dropped camera means the parser rejected a real one',
      );
      for (final camera in manifest.cameras) {
        expect(camera, hasLength(3));
        for (final value in camera) {
          expect(value.isFinite, isTrue);
        }
      }
    });
  });
}
