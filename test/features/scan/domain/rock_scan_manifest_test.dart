import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:masi/features/scan/domain/rock_scan_manifest.dart';

void main() {
  group('RockScanManifest.tryParse', () {
    test('parses a full worker document', () {
      final json = jsonEncode({
        'version': 1,
        'engine': 'colmap',
        'engineVersion': '3.9.1',
        'framesExtracted': 150,
        'framesRegistered': 132,
        'pointCount': 84213,
        'boundsMin': [-2.0, -1.0, -3.0],
        'boundsMax': [4.0, 1.5, 1.0],
        'cameras': [
          [0.0, 0.0, 0.0],
          [1.0, 0.1, 0.2],
        ],
        'registeredRatio': 0.88,
        'meanReprojectionError': 0.78,
      });

      final m = RockScanManifest.tryParse(json)!;
      expect(m.version, 1);
      expect(m.engine, 'colmap');
      expect(m.framesRegistered, 132);
      expect(m.pointCount, 84213);
      expect(m.cameras, hasLength(2));
      expect(m.meanReprojectionError, closeTo(0.78, 1e-9));
      expect(m.isFutureVersion, isFalse);
      // Longest side is x: 4.0 - (-2.0).
      expect(m.extent, closeTo(6.0, 1e-9));
    });

    test('accepts an already-decoded map as well as a string', () {
      final map = {'version': 1, 'engine': 'colmap'};
      expect(RockScanManifest.tryParse(map)?.engine, 'colmap');
      expect(RockScanManifest.tryParse(jsonEncode(map))?.engine, 'colmap');
    });

    test('returns null rather than throwing on unusable input', () {
      // A scan whose manifest cannot be read is still presentable as "ready,
      // details unknown". One that threw would take the screen down with it.
      expect(RockScanManifest.tryParse('not json at all'), isNull);
      expect(RockScanManifest.tryParse('[1,2,3]'), isNull);
      expect(RockScanManifest.tryParse('{"engine":"colmap"}'), isNull);
      expect(RockScanManifest.tryParse('{"version":"one"}'), isNull);
      expect(RockScanManifest.tryParse(''), isNull);
      expect(RockScanManifest.tryParse('   '), isNull);
      expect(RockScanManifest.tryParse(null), isNull);
    });

    test('a version-only manifest is valid and reports nothing else', () {
      final m = RockScanManifest.tryParse('{"version":1}')!;
      expect(m.engine, isNull);
      expect(m.pointCount, isNull);
      expect(m.cameras, isEmpty);
      expect(m.extent, isNull);
      expect(m.hasMetricScale, isFalse);
    });

    test('a newer manifest parses and flags itself', () {
      final m = RockScanManifest.tryParse('{"version":99,"engine":"glomap"}')!;
      expect(m.isFutureVersion, isTrue);
      expect(m.engine, 'glomap');
    });

    test('derives registeredRatio when the worker omits it', () {
      final m = RockScanManifest.tryParse(
        '{"version":1,"framesExtracted":200,"framesRegistered":150}',
      )!;
      expect(m.registeredRatio, closeTo(0.75, 1e-9));
    });

    test('does not divide by zero deriving registeredRatio', () {
      final m = RockScanManifest.tryParse(
        '{"version":1,"framesExtracted":0,"framesRegistered":0}',
      )!;
      expect(m.registeredRatio, isNull);
    });

    test('an explicit registeredRatio is preferred over the derived one', () {
      final m = RockScanManifest.tryParse(
        '{"version":1,"framesExtracted":200,"framesRegistered":150,'
        '"registeredRatio":0.5}',
      )!;
      expect(m.registeredRatio, closeTo(0.5, 1e-9));
    });

    test('drops malformed vectors instead of zero-filling them', () {
      // A partial coordinate is not a usable position, and silently filling
      // the missing axis with 0 would put a camera at the origin — which
      // reads on screen as a real observation the climber never made.
      final m = RockScanManifest.tryParse(
        '{"version":1,"boundsMin":[1,2],"cameras":[[1,2],[1,2,3],'
        '["a","b","c"],[4,5,6,7]]}',
      )!;
      expect(m.boundsMin, isNull);
      expect(m.cameras, [
        [1.0, 2.0, 3.0],
        [4.0, 5.0, 6.0],
      ]);
    });

    test('rejects a non-finite coordinate', () {
      final m = RockScanManifest.tryParse({
        'version': 1,
        'cameras': [
          [double.nan, 0, 0],
          [double.infinity, 0, 0],
          [1, 2, 3],
        ],
      })!;
      expect(m.cameras, [
        [1.0, 2.0, 3.0],
      ]);
    });

    test('extent needs both bounds', () {
      final m = RockScanManifest.tryParse(
        '{"version":1,"boundsMin":[0,0,0]}',
      )!;
      expect(m.extent, isNull);
    });

    test('a degenerate bounding box has no extent', () {
      final m = RockScanManifest.tryParse(
        '{"version":1,"boundsMin":[1,1,1],"boundsMax":[1,1,1]}',
      )!;
      expect(m.extent, isNull);
    });
  });

  group('metric scale', () {
    test('absent scale is not metric — the default and the common case', () {
      // Structure-from-motion recovers geometry only up to a similarity
      // transform. Nothing may present a measurement to a climber while this
      // is null, so the null must survive parsing rather than becoming 1.0.
      final m = RockScanManifest.tryParse('{"version":1}')!;
      expect(m.metresPerUnit, isNull);
      expect(m.scaleSource, isNull);
      expect(m.hasMetricScale, isFalse);
    });

    test('a real scale is reported with its source', () {
      final m = RockScanManifest.tryParse(
        '{"version":1,"metresPerUnit":2.5,"scaleSource":"baseline"}',
      )!;
      expect(m.hasMetricScale, isTrue);
      expect(m.metresPerUnit, closeTo(2.5, 1e-9));
      expect(m.scaleSource, 'baseline');
    });

    test('a zero or negative scale is not metric', () {
      expect(
        RockScanManifest.tryParse('{"version":1,"metresPerUnit":0}')!
            .hasMetricScale,
        isFalse,
      );
      expect(
        RockScanManifest.tryParse('{"version":1,"metresPerUnit":-3}')!
            .hasMetricScale,
        isFalse,
      );
    });
  });
}
