import 'dart:convert';

/// The reconstruction manifest: everything about a finished scan EXCEPT the
/// points themselves, which live in a separate binary PLY.
///
/// ## This class is a wire contract
///
/// It is written by the reconstruction worker (`tool/rock_scan_worker/`,
/// Python) and read here. The two must agree, so treat the field names below
/// as fixed and add rather than rename. [version] exists to make that
/// enforceable: a manifest from a newer worker than this build understands
/// parses as far as it can and reports [isFutureVersion], instead of throwing
/// on the library screen.
///
/// ## Everything is optional except [version]
///
/// A worker that cannot compute a quality figure, or that registered no
/// cameras at all, still produces a valid manifest — the UI's job is then to
/// say "we do not know", which it can only do if "we do not know" is
/// representable. [fromJson] therefore never throws on a missing or
/// wrong-typed field; it drops it.
///
/// Pure Dart, no Flutter import: usable from the data layer and testable
/// without a widget binding.
class RockScanManifest {
  const RockScanManifest({
    required this.version,
    this.engine,
    this.engineVersion,
    this.framesExtracted,
    this.framesRegistered,
    this.pointCount,
    this.boundsMin,
    this.boundsMax,
    this.cameras = const [],
    this.registeredRatio,
    this.meanReprojectionError,
    this.metresPerUnit,
    this.scaleSource,
  });

  /// The manifest schema version this document claims to be. The only
  /// genuinely required field.
  final int version;

  /// The schema version this build was written against. A manifest above this
  /// is readable but may carry fields not surfaced here.
  static const int currentVersion = 1;

  /// Reconstruction engine name, e.g. `colmap`.
  final String? engine;

  /// Engine version string, verbatim from the worker.
  final String? engineVersion;

  /// Frames pulled out of the source video.
  final int? framesExtracted;

  /// Frames the reconstruction actually placed. The gap between this and
  /// [framesExtracted] is the single most diagnostic number here: a large one
  /// means the video moved too fast, or the rock is too smooth to match.
  final int? framesRegistered;

  /// Points in the accompanying cloud.
  final int? pointCount;

  /// Axis-aligned bounds, `[x, y, z]` each, in the cloud's own units. Both
  /// are null together or set together.
  final List<double>? boundsMin;
  final List<double>? boundsMax;

  /// Camera positions in the cloud's own coordinate frame, `[x, y, z]` each.
  ///
  /// Positions only, deliberately — no orientation. The viewer draws where
  /// the climber walked, which is a genuinely useful sanity check on a scan
  /// ("did I actually cover the whole face?"), and orientation would triple
  /// the manifest for something nothing currently reads.
  final List<List<double>> cameras;

  /// [framesRegistered] / [framesExtracted], when both are known.
  final double? registeredRatio;

  /// Mean reprojection error in pixels, as the engine reports it.
  final double? meanReprojectionError;

  /// How many metres one cloud unit represents, or `null` when the
  /// reconstruction is at arbitrary scale — which is the DEFAULT and the
  /// common case.
  ///
  /// Structure-from-motion recovers geometry only up to a similarity
  /// transform, so a bare reconstruction has no idea how big the rock is.
  /// Nothing may present a measurement to a climber while this is null.
  final double? metresPerUnit;

  /// Where [metresPerUnit] came from — e.g. `baseline`, `gps`, `manual`.
  /// `null` whenever [metresPerUnit] is.
  final String? scaleSource;

  /// True when this manifest was written by a newer worker than this build
  /// knows about. Not an error: the fields below are still whatever this
  /// build could parse.
  bool get isFutureVersion => version > currentVersion;

  /// Whether the cloud carries a real-world scale. See [metresPerUnit].
  bool get hasMetricScale => metresPerUnit != null && metresPerUnit! > 0;

  /// The longest side of the bounding box in cloud units, or `null` when
  /// bounds are unknown. The viewer uses it to frame the initial camera.
  double? get extent {
    final min = boundsMin;
    final max = boundsMax;
    if (min == null || max == null || min.length < 3 || max.length < 3) {
      return null;
    }
    var largest = 0.0;
    for (var i = 0; i < 3; i++) {
      final side = (max[i] - min[i]).abs();
      if (side > largest) largest = side;
    }
    return largest > 0 ? largest : null;
  }

  /// Parses [source], which may be a JSON string or an already-decoded map.
  ///
  /// Returns `null` for anything unparseable — malformed JSON, a non-map
  /// document, or a missing/non-numeric `version`. A scan whose manifest
  /// cannot be read is presentable as "ready, details unknown"; one that
  /// threw here would take the screen down with it.
  static RockScanManifest? tryParse(Object? source) {
    Object? decoded = source;
    if (source is String) {
      if (source.trim().isEmpty) return null;
      try {
        decoded = jsonDecode(source);
      } on FormatException {
        return null;
      }
    }
    if (decoded is! Map) return null;
    final version = _int(decoded['version']);
    if (version == null) return null;

    final extracted = _int(decoded['framesExtracted']);
    final registered = _int(decoded['framesRegistered']);
    return RockScanManifest(
      version: version,
      engine: _string(decoded['engine']),
      engineVersion: _string(decoded['engineVersion']),
      framesExtracted: extracted,
      framesRegistered: registered,
      pointCount: _int(decoded['pointCount']),
      boundsMin: _vec3(decoded['boundsMin']),
      boundsMax: _vec3(decoded['boundsMax']),
      cameras: _vec3List(decoded['cameras']),
      // Recomputed from the counts when the worker did not send it, rather
      // than trusting a figure two other fields already determine.
      registeredRatio:
          _double(decoded['registeredRatio']) ??
          ((extracted != null && registered != null && extracted > 0)
              ? registered / extracted
              : null),
      meanReprojectionError: _double(decoded['meanReprojectionError']),
      metresPerUnit: _double(decoded['metresPerUnit']),
      scaleSource: _string(decoded['scaleSource']),
    );
  }

  static int? _int(Object? raw) => raw is num ? raw.toInt() : null;

  static double? _double(Object? raw) => raw is num ? raw.toDouble() : null;

  static String? _string(Object? raw) =>
      raw is String && raw.isNotEmpty ? raw : null;

  /// A `[x, y, z]` triple, or `null` if [raw] is not one. A longer list is
  /// truncated to three; a shorter one is rejected outright, because a
  /// partial coordinate is not a usable position and silently zero-filling it
  /// would put a camera at the origin.
  static List<double>? _vec3(Object? raw) {
    if (raw is! List || raw.length < 3) return null;
    final out = <double>[];
    for (var i = 0; i < 3; i++) {
      final value = raw[i];
      if (value is! num || !value.isFinite) return null;
      out.add(value.toDouble());
    }
    return out;
  }

  static List<List<double>> _vec3List(Object? raw) {
    if (raw is! List) return const [];
    final out = <List<double>>[];
    for (final entry in raw) {
      final vec = _vec3(entry);
      if (vec != null) out.add(vec);
    }
    return out;
  }
}
