// The binary-PLY reader and point-cloud value type
// (`lib/features/scan/domain/point_cloud.dart`).
//
// The bytes under test are built HERE, by `_ply` below, rather than loaded
// from a fixture: every malformed case this file covers is a one-line
// variation on a good header, and a directory of twenty broken .ply files
// would hide which byte each one is actually testing.
//
// The contract being pinned, in one line: this parser NEVER throws. Every
// failure is `null`. Half the tests below exist to keep it that way.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:masi/features/scan/domain/point_cloud.dart';

/// One vertex, as the test wants to talk about it.
class _P {
  const _P(this.x, this.y, this.z, this.r, this.g, this.b);

  final double x;
  final double y;
  final double z;
  final int r;
  final int g;
  final int b;
}

const List<String> _defaultProperties = [
  'property float x',
  'property float y',
  'property float z',
  'property uchar red',
  'property uchar green',
  'property uchar blue',
];

/// Emits a binary little-endian PLY. Every knob exists for one malformed-input
/// test; the defaults produce exactly what COLMAP writes.
Uint8List _ply(
  List<_P> points, {
  String format = 'binary_little_endian 1.0',
  bool includeFormat = true,
  int? declaredCount,
  List<String> properties = _defaultProperties,
  List<String> extraHeaderBefore = const [],
  bool includeEndHeader = true,
  int dropTrailingBytes = 0,
  String newline = '\n',
}) {
  final header = StringBuffer('ply$newline');
  if (includeFormat) header.write('format $format$newline');
  header.write('comment written by point_cloud_test$newline');
  for (final line in extraHeaderBefore) {
    header.write('$line$newline');
  }
  header.write('element vertex ${declaredCount ?? points.length}$newline');
  for (final property in properties) {
    header.write('$property$newline');
  }
  if (includeEndHeader) header.write('end_header$newline');

  final headerBytes = Uint8List.fromList(header.toString().codeUnits);
  final body = Uint8List(points.length * 15);
  final view = ByteData.sublistView(body);
  for (var i = 0; i < points.length; i++) {
    final p = points[i];
    final o = i * 15;
    view.setFloat32(o, p.x, Endian.little);
    view.setFloat32(o + 4, p.y, Endian.little);
    view.setFloat32(o + 8, p.z, Endian.little);
    view.setUint8(o + 12, p.r);
    view.setUint8(o + 13, p.g);
    view.setUint8(o + 14, p.b);
  }

  final out = Uint8List(headerBytes.length + body.length)
    ..setRange(0, headerBytes.length, headerBytes)
    ..setRange(headerBytes.length, headerBytes.length + body.length, body);
  if (dropTrailingBytes <= 0) return out;
  return Uint8List.sublistView(out, 0, out.length - dropTrailingBytes);
}

/// A cloud of [count] points whose x coordinate IS the point index, so a
/// decimation bug is visible in the kept values.
List<_P> _indexedPoints(int count) => [
  for (var i = 0; i < count; i++) _P(i.toDouble(), 0, 0, i % 256, 0, 0),
];

void main() {
  group('tryParseBinaryPly — happy path', () {
    test('round-trips positions and colours', () {
      // Values chosen to be exactly representable in float32, so the
      // assertions can be exact rather than approximate.
      final bytes = _ply(const [
        _P(1.5, -2.25, 0.5, 10, 20, 30),
        _P(-4, 8, 16.5, 200, 100, 50),
        _P(0, 0, -1, 255, 0, 128),
      ]);

      final cloud = PointCloud.tryParseBinaryPly(bytes);

      expect(cloud, isNotNull);
      expect(cloud!.pointCount, 3);
      expect(cloud.sourcePointCount, 3);
      expect(cloud.isDecimated, isFalse);
      expect(cloud.positions, [1.5, -2.25, 0.5, -4, 8, 16.5, 0, 0, -1]);
      expect(cloud.colors, [10, 20, 30, 200, 100, 50, 255, 0, 128]);
    });

    test('computes bounds and centroid over the kept points', () {
      final bytes = _ply(const [
        _P(0, 0, 0, 0, 0, 0),
        _P(2, 4, 8, 0, 0, 0),
        _P(-2, 8, 4, 0, 0, 0),
      ]);

      final cloud = PointCloud.tryParseBinaryPly(bytes)!;

      expect(cloud.minX, -2);
      expect(cloud.maxX, 2);
      expect(cloud.minY, 0);
      expect(cloud.maxY, 8);
      expect(cloud.minZ, 0);
      expect(cloud.maxZ, 8);
      expect(cloud.centroidX, closeTo(0, 1e-6));
      expect(cloud.centroidY, closeTo(4, 1e-6));
      expect(cloud.centroidZ, closeTo(4, 1e-6));
      expect(cloud.centerX, 0);
      expect(cloud.centerY, 4);
      expect(cloud.extent, 8);
      expect(cloud.boundingRadius, closeTo(6, 1e-6));
    });

    test('accepts the float32/uint8 spellings of the same widths', () {
      final bytes = _ply(
        const [_P(1, 2, 3, 4, 5, 6)],
        properties: const [
          'property float32 x',
          'property float32 y',
          'property float32 z',
          'property uint8 red',
          'property uint8 green',
          'property uint8 blue',
        ],
      );

      expect(PointCloud.tryParseBinaryPly(bytes), isNotNull);
    });

    test('accepts a CRLF header', () {
      final bytes = _ply(const [_P(1, 2, 3, 4, 5, 6)], newline: '\r\n');

      final cloud = PointCloud.tryParseBinaryPly(bytes);

      expect(cloud, isNotNull);
      expect(cloud!.positions, [1, 2, 3]);
    });

    test('tolerates trailing bytes after the vertex block', () {
      final good = _ply(const [_P(1, 2, 3, 4, 5, 6)]);
      final padded = Uint8List(good.length + 9)..setRange(0, good.length, good);

      expect(PointCloud.tryParseBinaryPly(padded)?.pointCount, 1);
    });
  });

  group('decimation', () {
    test('keeps everything when the budget is not exceeded', () {
      final bytes = _ply(_indexedPoints(10));

      final cloud = PointCloud.tryParseBinaryPly(bytes, maxPoints: 10)!;

      expect(cloud.pointCount, 10);
      expect(cloud.sourcePointCount, 10);
      expect(cloud.isDecimated, isFalse);
    });

    test('strides uniformly across the index range', () {
      final bytes = _ply(_indexedPoints(10));

      final cloud = PointCloud.tryParseBinaryPly(bytes, maxPoints: 5)!;

      expect(cloud.pointCount, 5);
      expect(cloud.sourcePointCount, 10);
      expect(cloud.isDecimated, isTrue);
      // (i * 10) ~/ 5 — 0, 2, 4, 6, 8. NOT 0, 1, 2, 3, 4.
      expect(
        [for (var i = 0; i < 5; i++) cloud.positions[i * 3]],
        [0, 2, 4, 6, 8],
      );
    });

    test('samples the WHOLE cloud, not a spatially clustered prefix', () {
      // COLMAP emits points in reconstruction order, which is spatially
      // clustered — so a `take(N)` decimation would return one corner of the
      // rock and read on screen as a failed reconstruction. This cloud makes
      // that failure detectable: the first half sits near the origin, the
      // second half a hundred units away.
      final points = <_P>[
        for (var i = 0; i < 500; i++) _P(i / 500, 0, 0, 255, 0, 0),
        for (var i = 0; i < 500; i++) _P(100 + i / 500, 0, 0, 0, 0, 255),
      ];
      final bytes = _ply(points);

      final cloud = PointCloud.tryParseBinaryPly(bytes, maxPoints: 20)!;

      expect(cloud.pointCount, 20);
      expect(cloud.maxX, greaterThan(100), reason: 'far cluster was dropped');
      expect(cloud.minX, lessThan(1), reason: 'near cluster was dropped');
      // Both clusters should be represented roughly evenly.
      var far = 0;
      for (var i = 0; i < cloud.pointCount; i++) {
        if (cloud.positions[i * 3] >= 100) far++;
      }
      expect(far, 10);
    });

    test('a budget below one point is clamped, not thrown on', () {
      final bytes = _ply(_indexedPoints(10));

      final cloud = PointCloud.tryParseBinaryPly(bytes, maxPoints: 0);

      expect(cloud, isNotNull);
      expect(cloud!.pointCount, 1);
    });

    test('the default budget is the documented 150k', () {
      expect(PointCloud.kDefaultPointBudget, 150000);
    });
  });

  group('malformed input returns null and never throws', () {
    test('empty bytes', () {
      expect(PointCloud.tryParseBinaryPly(Uint8List(0)), isNull);
    });

    test('not a PLY at all', () {
      final bytes = Uint8List.fromList(
        List<int>.generate(4096, (i) => (i * 37) % 256),
      );

      expect(PointCloud.tryParseBinaryPly(bytes), isNull);
    });

    test('a text file that is not a PLY', () {
      final bytes = Uint8List.fromList(
        'hello\nthis is not a ply\nend_header\n'.codeUnits,
      );

      expect(PointCloud.tryParseBinaryPly(bytes), isNull);
    });

    test('ASCII-format PLY is refused rather than misparsed', () {
      final bytes = _ply(const [_P(1, 2, 3, 4, 5, 6)], format: 'ascii 1.0');

      expect(PointCloud.tryParseBinaryPly(bytes), isNull);
    });

    test('big-endian PLY', () {
      final bytes = _ply(
        const [_P(1, 2, 3, 4, 5, 6)],
        format: 'binary_big_endian 1.0',
      );

      expect(PointCloud.tryParseBinaryPly(bytes), isNull);
    });

    test('missing format line', () {
      final bytes = _ply(const [_P(1, 2, 3, 4, 5, 6)], includeFormat: false);

      expect(PointCloud.tryParseBinaryPly(bytes), isNull);
    });

    test('truncated header — no end_header', () {
      final bytes = _ply(
        const [_P(1, 2, 3, 4, 5, 6)],
        includeEndHeader: false,
      );

      expect(PointCloud.tryParseBinaryPly(bytes), isNull);
    });

    test('header cut off mid-way', () {
      final full = _ply(const [_P(1, 2, 3, 4, 5, 6)]);
      final cut = Uint8List.sublistView(full, 0, 20);

      expect(PointCloud.tryParseBinaryPly(cut), isNull);
    });

    test('truncated vertex block', () {
      final bytes = _ply(
        const [
          _P(1, 2, 3, 4, 5, 6),
          _P(7, 8, 9, 10, 11, 12),
        ],
        dropTrailingBytes: 4,
      );

      expect(PointCloud.tryParseBinaryPly(bytes), isNull);
    });

    test('vertex count that would overflow the buffer', () {
      final bytes = _ply(const [_P(1, 2, 3, 4, 5, 6)], declaredCount: 100000);

      expect(PointCloud.tryParseBinaryPly(bytes), isNull);
    });

    test('an absurd vertex count does not overflow the capacity check', () {
      final bytes = _ply(
        const [_P(1, 2, 3, 4, 5, 6)],
        declaredCount: 9007199254740991,
      );

      expect(PointCloud.tryParseBinaryPly(bytes), isNull);
    });

    test('a non-numeric vertex count', () {
      final good = _ply(const [_P(1, 2, 3, 4, 5, 6)]);
      final broken = Uint8List.fromList(
        String.fromCharCodes(good)
            .replaceFirst('element vertex 1', 'element vertex lots')
            .codeUnits,
      );

      expect(PointCloud.tryParseBinaryPly(broken), isNull);
    });

    test('zero vertices', () {
      final bytes = _ply(const []);

      expect(PointCloud.tryParseBinaryPly(bytes), isNull);
    });

    test('a seventh property we do not know about', () {
      final bytes = _ply(
        const [_P(1, 2, 3, 4, 5, 6)],
        properties: const [
          ..._defaultProperties,
          'property uchar alpha',
        ],
      );

      expect(PointCloud.tryParseBinaryPly(bytes), isNull);
    });

    test('normals ahead of the colours', () {
      final bytes = _ply(
        const [_P(1, 2, 3, 4, 5, 6)],
        properties: const [
          'property float x',
          'property float y',
          'property float z',
          'property float nx',
          'property float ny',
          'property float nz',
        ],
      );

      expect(PointCloud.tryParseBinaryPly(bytes), isNull);
    });

    test('a list property', () {
      final bytes = _ply(
        const [_P(1, 2, 3, 4, 5, 6)],
        properties: const [
          'property float x',
          'property float y',
          'property float z',
          'property list uchar int vertex_index',
        ],
      );

      expect(PointCloud.tryParseBinaryPly(bytes), isNull);
    });

    test('fewer properties than we need', () {
      final bytes = _ply(
        const [_P(1, 2, 3, 4, 5, 6)],
        properties: const [
          'property float x',
          'property float y',
          'property float z',
        ],
      );

      expect(PointCloud.tryParseBinaryPly(bytes), isNull);
    });

    test('another element declared ahead of vertex', () {
      // The vertex block only starts at `end_header` when vertex is the FIRST
      // element; otherwise this would read someone else's data as coordinates.
      final bytes = _ply(
        const [_P(1, 2, 3, 4, 5, 6)],
        extraHeaderBefore: const [
          'element camera 1',
          'property float view_px',
        ],
      );

      expect(PointCloud.tryParseBinaryPly(bytes), isNull);
    });

    test('vertex declared twice', () {
      final bytes = _ply(
        const [_P(1, 2, 3, 4, 5, 6)],
        extraHeaderBefore: const ['element vertex 1'],
      );

      expect(PointCloud.tryParseBinaryPly(bytes), isNull);
    });

    test('every prefix of a good file either parses or returns null', () {
      // The blunt-instrument check on "never throws": walk the truncation
      // space rather than reasoning about which byte matters.
      final good = _ply(_indexedPoints(6));
      for (var length = 0; length <= good.length; length++) {
        final prefix = Uint8List.sublistView(good, 0, length);
        expect(
          () => PointCloud.tryParseBinaryPly(prefix),
          returnsNormally,
          reason: 'threw at length $length',
        );
      }
    });
  });

  group('non-finite coordinates', () {
    test('a NaN point is dropped, the rest survive', () {
      final bytes = _ply(const [
        _P(1, 2, 3, 4, 5, 6),
        _P(double.nan, 0, 0, 1, 1, 1),
        _P(4, 5, 6, 7, 8, 9),
      ]);

      final cloud = PointCloud.tryParseBinaryPly(bytes)!;

      expect(cloud.pointCount, 2);
      expect(cloud.sourcePointCount, 3);
      expect(cloud.positions, [1, 2, 3, 4, 5, 6]);
      expect(cloud.colors, [4, 5, 6, 7, 8, 9]);
      expect(cloud.maxX, 4);
    });

    test('an infinity is dropped too', () {
      final bytes = _ply(const [
        _P(1, 2, 3, 4, 5, 6),
        _P(0, double.infinity, 0, 1, 1, 1),
      ]);

      expect(PointCloud.tryParseBinaryPly(bytes)!.pointCount, 1);
    });

    test('a cloud of nothing but NaN is a failure, not an empty cloud', () {
      final bytes = _ply(const [
        _P(double.nan, 0, 0, 1, 1, 1),
        _P(0, double.nan, 0, 1, 1, 1),
      ]);

      expect(PointCloud.tryParseBinaryPly(bytes), isNull);
    });
  });

  group('fromXyzRgb', () {
    test('builds a cloud and computes bounds', () {
      final cloud = PointCloud.fromXyzRgb(
        Float32List.fromList([0, 0, 0, 2, 2, 2]),
        Uint8List.fromList([1, 2, 3, 4, 5, 6]),
      );

      expect(cloud, isNotNull);
      expect(cloud!.pointCount, 2);
      expect(cloud.sourcePointCount, 2);
      expect(cloud.maxX, 2);
      expect(cloud.centroidZ, 1);
    });

    test('rejects mismatched buffers, an empty cloud and non-finite data', () {
      expect(
        PointCloud.fromXyzRgb(
          Float32List.fromList([0, 0, 0]),
          Uint8List.fromList([1, 2, 3, 4]),
        ),
        isNull,
      );
      expect(
        PointCloud.fromXyzRgb(
          Float32List.fromList([0, 0]),
          Uint8List.fromList([1, 2]),
        ),
        isNull,
      );
      expect(PointCloud.fromXyzRgb(Float32List(0), Uint8List(0)), isNull);
      expect(
        PointCloud.fromXyzRgb(
          Float32List.fromList([0, 0, double.nan]),
          Uint8List.fromList([1, 2, 3]),
        ),
        isNull,
      );
    });

    test('reports decimation when told the source was larger', () {
      final cloud = PointCloud.fromXyzRgb(
        Float32List.fromList([0, 0, 0]),
        Uint8List.fromList([1, 2, 3]),
        sourcePointCount: 900,
      )!;

      expect(cloud.isDecimated, isTrue);
      expect(cloud.sourcePointCount, 900);
    });
  });
}
