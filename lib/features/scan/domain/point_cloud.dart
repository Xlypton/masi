import 'dart:math' as math;
import 'dart:typed_data';

/// A decimated, colour-carrying point cloud, plus the binary-PLY reader that
/// produces one.
///
/// ## Failure model — NEVER throws, always returns `null`
///
/// Every entry point on this class ([tryParseBinaryPly], [fromXyzRgb]) reports
/// failure by returning `null`. Nothing here throws, for any input. That is a
/// deliberate contract and it matches `RockScanManifest.tryParse`
/// (`rock_scan_manifest.dart`), which is read on the same screens: a scan whose
/// cloud will not parse is presentable as "we cannot show this reconstruction",
/// and one that threw would take the whole screen down with it. The file this
/// reads is produced by a worker on someone else's machine and moved through
/// storage, so "malformed" is a routine state, not a bug — a climber's phone
/// halfway up an approach must not be the thing that discovers it.
///
/// The body of the parser is additionally wrapped in a blanket `catch`, so even
/// a bug in the bounds arithmetic below degrades to `null` rather than an
/// exception. That is belt-and-braces on top of the explicit checks, not a
/// substitute for them.
///
/// ## Storage layout — flat buffers, not a `List<Point>`
///
/// [positions] and [colors] are flat, interleaved, primitive-typed buffers
/// rather than a list of point objects. At the default 150k budget a
/// `List<Vector3>` is 150k heap allocations plus 150k pointer dereferences per
/// frame; the flat form is two allocations total and lets the painter walk it
/// linearly. This is the difference between the viewer being usable on a phone
/// and not, so it is not an implementation detail to be tidied away.
class PointCloud {
  const PointCloud._({
    required this.positions,
    required this.colors,
    required this.pointCount,
    required this.sourcePointCount,
    required this.minX,
    required this.minY,
    required this.minZ,
    required this.maxX,
    required this.maxY,
    required this.maxZ,
    required this.centroidX,
    required this.centroidY,
    required this.centroidZ,
  });

  /// The number of points a phone is asked to hold by default.
  ///
  /// A COLMAP dense cloud of a rock face routinely runs to several million
  /// points; 150k is roughly what stays smooth on a mid-range phone and is
  /// still far more than the screen has pixels to show it on.
  static const int kDefaultPointBudget = 150000;

  /// Bytes per binary vertex record: `float x,y,z` + `uchar r,g,b`.
  static const int _vertexStride = 3 * 4 + 3;

  /// The most header bytes we will scan before giving up looking for
  /// `end_header`. A real PLY header is a few hundred bytes; without a cap, a
  /// large binary blob that merely *starts* with `ply` would be scanned in
  /// full, byte by byte, before failing.
  static const int _maxHeaderBytes = 64 * 1024;

  /// Interleaved `x, y, z` for every kept point. Length is `3 * pointCount`.
  final Float32List positions;

  /// Interleaved `r, g, b` (0-255) for every kept point, in the same order as
  /// [positions]. Length is `3 * pointCount`.
  final Uint8List colors;

  /// Points actually held here — after decimation.
  final int pointCount;

  /// Points the source file declared, before decimation. Equal to
  /// [pointCount] when nothing was dropped.
  final int sourcePointCount;

  /// Axis-aligned bounds over the points KEPT, not over the source file.
  /// Framing the camera on bounds that include dropped points would open the
  /// viewer slightly zoomed out from the geometry it can actually draw.
  final double minX;
  final double minY;
  final double minZ;
  final double maxX;
  final double maxY;
  final double maxZ;

  /// Mean position of the points kept. Distinct from the bounding-box centre
  /// ([centerX] and friends): a cloud with one far outlier has a box centre
  /// pulled toward the outlier and a centroid that stays with the bulk.
  final double centroidX;
  final double centroidY;
  final double centroidZ;

  /// Whether points were dropped to meet the budget.
  bool get isDecimated => pointCount < sourcePointCount;

  double get centerX => (minX + maxX) / 2;
  double get centerY => (minY + maxY) / 2;
  double get centerZ => (minZ + maxZ) / 2;

  double get sizeX => maxX - minX;
  double get sizeY => maxY - minY;
  double get sizeZ => maxZ - minZ;

  /// Longest side of the bounding box, in the cloud's own (arbitrary) units.
  double get extent {
    var largest = sizeX;
    if (sizeY > largest) largest = sizeY;
    if (sizeZ > largest) largest = sizeZ;
    return largest;
  }

  /// Radius of the sphere that encloses the bounding box. What the viewer
  /// frames against, because it is orientation-independent — framing on
  /// [extent] alone would clip the corners of the box at some yaw angles.
  double get boundingRadius {
    final dx = sizeX / 2;
    final dy = sizeY / 2;
    final dz = sizeZ / 2;
    return math.sqrt(dx * dx + dy * dy + dz * dz);
  }

  /// Builds a cloud from already-unpacked buffers, computing bounds and
  /// centroid. Returns `null` when the buffers disagree on length, are empty,
  /// or contain no finite point.
  ///
  /// Exists so the viewer (and its tests) can be exercised without going
  /// through a byte encoder, and so a future non-PLY source has a way in.
  static PointCloud? fromXyzRgb(
    Float32List positions,
    Uint8List colors, {
    int? sourcePointCount,
  }) {
    try {
      if (positions.length % 3 != 0) return null;
      final count = positions.length ~/ 3;
      if (count == 0) return null;
      if (colors.length != count * 3) return null;
      for (var i = 0; i < positions.length; i++) {
        if (!positions[i].isFinite) return null;
      }
      return _finish(
        positions: positions,
        colors: colors,
        pointCount: count,
        sourcePointCount: sourcePointCount ?? count,
      );
    } catch (_) {
      return null;
    }
  }

  /// Parses a **binary little-endian** PLY as written by COLMAP: one `vertex`
  /// element whose properties are exactly `float x, float y, float z,
  /// uchar red, uchar green, uchar blue`, in that order.
  ///
  /// Returns `null` — never throws — for anything else, including: bytes that
  /// are not a PLY, `format ascii 1.0`, `format binary_big_endian 1.0`, a
  /// header with no `end_header`, a vertex block shorter than the declared
  /// vertex count, a vertex count that would run past the end of [bytes], a
  /// vertex element carrying properties beyond the six above, and a file
  /// declaring zero vertices.
  ///
  /// Zero vertices is a failure rather than an empty cloud on purpose: a cloud
  /// with nothing in it has no bounds to frame a camera on, and every caller
  /// would have to special-case it anyway. "Nothing to show" and "cannot be
  /// read" are the same outcome on screen.
  ///
  /// At most [maxPoints] points are kept; see the decimation comment inside.
  static PointCloud? tryParseBinaryPly(
    Uint8List bytes, {
    int maxPoints = kDefaultPointBudget,
  }) {
    try {
      return _parse(bytes, maxPoints);
    } catch (_) {
      // Unreachable by design — every failure below is an explicit `null`.
      // Kept because the promise this class makes to its callers is "never
      // throws", and that promise should not depend on this file staying
      // bug-free.
      return null;
    }
  }

  static PointCloud? _parse(Uint8List bytes, int maxPoints) {
    // A budget below one point is nonsense rather than a request for an empty
    // cloud; clamp instead of throwing on a bad argument.
    final budget = maxPoints < 1 ? 1 : maxPoints;

    final header = _readHeader(bytes);
    if (header == null) return null;

    final sourceCount = header.vertexCount;
    if (sourceCount <= 0) return null;

    // Overflow-safe capacity check: divide the available bytes rather than
    // multiplying the declared count. On web an `int` is a double, so a header
    // claiming 10^20 vertices would lose precision under multiplication and
    // could pass a naive `count * stride <= available` test.
    final available = bytes.length - header.dataStart;
    if (available < 0) return null;
    if (sourceCount > available ~/ _vertexStride) return null;

    final keep = sourceCount < budget ? sourceCount : budget;

    final positions = Float32List(keep * 3);
    final colors = Uint8List(keep * 3);
    final data = ByteData.sublistView(bytes);

    var kept = 0;
    for (var i = 0; i < keep; i++) {
      // DECIMATE UNIFORMLY ACROSS THE WHOLE FILE, never `bytes.take(N)`.
      //
      // COLMAP emits points in reconstruction order, which is spatially
      // clustered: the first N points of a cloud are one corner of the rock,
      // usually whichever patch got dense first. A prefix therefore renders a
      // recognisable fragment of the face and reads to the climber as a FAILED
      // RECONSTRUCTION rather than as a downsample — the single most expensive
      // way this could be wrong, because the user's response is to reshoot a
      // scan that was fine. Striding across the full index range costs the same
      // and cannot produce that.
      //
      // If you are here to "optimise" this into a sequential read: don't. The
      // buffer is already in memory; the reads are not the cost.
      final src = (i * sourceCount) ~/ keep;
      final offset = header.dataStart + src * _vertexStride;
      final x = data.getFloat32(offset, Endian.little);
      final y = data.getFloat32(offset + 4, Endian.little);
      final z = data.getFloat32(offset + 8, Endian.little);
      // A single NaN/Inf coordinate would poison the bounds for the whole
      // cloud and frame the camera on infinity, so drop the point instead.
      if (!x.isFinite || !y.isFinite || !z.isFinite) continue;
      final p = kept * 3;
      positions[p] = x;
      positions[p + 1] = y;
      positions[p + 2] = z;
      colors[p] = data.getUint8(offset + 12);
      colors[p + 1] = data.getUint8(offset + 13);
      colors[p + 2] = data.getUint8(offset + 14);
      kept++;
    }

    if (kept == 0) return null;

    final trimmedPositions = kept == keep
        ? positions
        : Float32List.sublistView(positions, 0, kept * 3);
    final trimmedColors =
        kept == keep ? colors : Uint8List.sublistView(colors, 0, kept * 3);

    return _finish(
      positions: trimmedPositions,
      colors: trimmedColors,
      pointCount: kept,
      sourcePointCount: sourceCount,
    );
  }

  static PointCloud _finish({
    required Float32List positions,
    required Uint8List colors,
    required int pointCount,
    required int sourcePointCount,
  }) {
    var minX = positions[0];
    var minY = positions[1];
    var minZ = positions[2];
    var maxX = minX;
    var maxY = minY;
    var maxZ = minZ;
    // Accumulate in double regardless of the Float32 storage: 150k float32
    // additions lose enough low bits to move a centroid visibly.
    var sumX = 0.0;
    var sumY = 0.0;
    var sumZ = 0.0;
    for (var i = 0; i < pointCount; i++) {
      final p = i * 3;
      final x = positions[p];
      final y = positions[p + 1];
      final z = positions[p + 2];
      if (x < minX) minX = x;
      if (y < minY) minY = y;
      if (z < minZ) minZ = z;
      if (x > maxX) maxX = x;
      if (y > maxY) maxY = y;
      if (z > maxZ) maxZ = z;
      sumX += x;
      sumY += y;
      sumZ += z;
    }
    return PointCloud._(
      positions: positions,
      colors: colors,
      pointCount: pointCount,
      sourcePointCount: sourcePointCount,
      minX: minX,
      minY: minY,
      minZ: minZ,
      maxX: maxX,
      maxY: maxY,
      maxZ: maxZ,
      centroidX: sumX / pointCount,
      centroidY: sumY / pointCount,
      centroidZ: sumZ / pointCount,
    );
  }

  // ---------------------------------------------------------------- header

  static _PlyHeader? _readHeader(Uint8List bytes) {
    if (bytes.length < 4) return null;

    final limit =
        bytes.length < _maxHeaderBytes ? bytes.length : _maxHeaderBytes;
    final lines = <String>[];
    var lineStart = 0;
    var dataStart = -1;
    for (var i = 0; i < limit; i++) {
      if (bytes[i] != 0x0A) continue;
      var end = i;
      if (end > lineStart && bytes[end - 1] == 0x0D) end--;
      final line = String.fromCharCodes(bytes, lineStart, end).trim();
      lineStart = i + 1;
      if (line == 'end_header') {
        dataStart = lineStart;
        break;
      }
      lines.add(line);
      // A header this long is not a header we wrote; stop rather than
      // accumulating unbounded strings out of a hostile file.
      if (lines.length > 512) return null;
    }
    if (dataStart < 0) return null;
    if (lines.isEmpty || lines.first != 'ply') return null;

    var sawFormat = false;
    var elementIndex = 0;
    var vertexElementIndex = -1;
    var vertexCount = -1;
    String? currentElement;
    final vertexProperties = <List<String>>[];

    for (var i = 1; i < lines.length; i++) {
      final tokens = lines[i].split(RegExp(r'\s+'))
        ..removeWhere((t) => t.isEmpty);
      if (tokens.isEmpty) continue;
      switch (tokens.first) {
        case 'format':
          // Anything but binary little-endian is rejected outright rather than
          // read as if it were: an ASCII PLY reinterpreted as packed floats
          // produces a plausible-looking cloud of garbage, which is far worse
          // than a clean failure.
          if (tokens.length < 2) return null;
          if (tokens[1] != 'binary_little_endian') return null;
          sawFormat = true;
        case 'element':
          if (tokens.length < 3) return null;
          currentElement = tokens[1];
          if (tokens[1] == 'vertex') {
            if (vertexElementIndex >= 0) return null; // declared twice
            vertexElementIndex = elementIndex;
            final n = int.tryParse(tokens[2]);
            if (n == null || n < 0) return null;
            vertexCount = n;
          }
          elementIndex++;
        case 'property':
          if (currentElement == 'vertex') {
            vertexProperties.add(tokens.sublist(1));
          }
        default:
          // comment / obj_info / anything unknown: ignored.
          break;
      }
    }

    if (!sawFormat) return null;
    // The vertex block must be the FIRST element, because that is what makes
    // `end_header` the offset of vertex zero. A file with, say, a `face`
    // element ahead of `vertex` would parse its face data as coordinates.
    if (vertexElementIndex != 0) return null;
    if (vertexCount < 0) return null;
    if (!_propertiesMatch(vertexProperties)) return null;

    return _PlyHeader(vertexCount: vertexCount, dataStart: dataStart);
  }

  /// The exact six properties, in order. A vertex element with a seventh
  /// property (normals, alpha, a COLMAP `nx/ny/nz`) has a different stride, so
  /// reading it with ours would walk off alignment after the first point —
  /// hence reject rather than skip.
  static const List<List<String>> _expectedProperties = [
    ['float', 'x'],
    ['float', 'y'],
    ['float', 'z'],
    ['uchar', 'red'],
    ['uchar', 'green'],
    ['uchar', 'blue'],
  ];

  static bool _propertiesMatch(List<List<String>> actual) {
    if (actual.length != _expectedProperties.length) return false;
    for (var i = 0; i < actual.length; i++) {
      final got = actual[i];
      final want = _expectedProperties[i];
      // `property list ...` lands here with four tokens and is rejected by
      // the length check, which is what we want.
      if (got.length != 2) return false;
      if (!_typeMatches(got[0], want[0])) return false;
      if (got[1] != want[1]) return false;
    }
    return true;
  }

  static bool _typeMatches(String actual, String want) {
    if (actual == want) return true;
    // PLY's newer spelling of the same widths; COLMAP writes the old one but
    // other tooling in the pipeline may not.
    if (want == 'float') return actual == 'float32';
    if (want == 'uchar') return actual == 'uint8';
    return false;
  }
}

class _PlyHeader {
  const _PlyHeader({required this.vertexCount, required this.dataStart});

  final int vertexCount;
  final int dataStart;
}
