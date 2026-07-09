import 'package:flutter/services.dart';

import 'package:climbtopo/features/ar/domain/homography.dart';

/// The AR alignment mode: whether the native side continuously re-solves the
/// homography from tracked features ([auto]), or holds the last-solved (or
/// manually nudged) homography fixed ([manual]).
///
/// `name` (e.g. `ArMode.manual.name == 'manual'`) is the wire value sent to
/// the native side via [ArChannel.setMode] — the native implementation MUST
/// match these exact strings.
enum ArMode { auto, manual }

/// A single AR alignment update pushed from the native side: the current
/// homography mapping the reference photo into the live camera frame, a
/// confidence score, and whether tracking is currently healthy.
///
/// Constructed from the wire map delivered over
/// [ArChannel.alignments]/`climbtopo/ar/alignment`:
/// ```
/// {
///   'homography': <9 doubles, row-major>,
///   'confidence': <double>,
///   'tracking': <bool>,
/// }
/// ```
/// [fromMap] never throws: any missing, short, or non-numeric `homography`
/// falls back to [Homography.identity] with `confidence: 0.0` and
/// `tracking: false`.
class ArAlignment {
  const ArAlignment({
    required this.homography,
    required this.confidence,
    required this.tracking,
  });

  /// The default alignment: identity homography, zero confidence, not
  /// tracking. Used whenever [fromMap] receives malformed input.
  static ArAlignment _defaultAlignment() => ArAlignment(
    homography: Homography.identity(),
    confidence: 0.0,
    tracking: false,
  );

  final Homography homography;
  final double confidence;
  final bool tracking;

  /// Parses [map] into an [ArAlignment].
  ///
  /// On any malformed input — missing `homography`, a homography list that
  /// isn't exactly 9 numeric entries, or a non-map input — returns the
  /// documented default (identity homography, confidence 0.0, tracking
  /// false) rather than throwing.
  factory ArAlignment.fromMap(Map<Object?, Object?> map) {
    final Homography? homography = _parseHomography(map['homography']);
    if (homography == null) {
      return _defaultAlignment();
    }

    final Object? confidenceRaw = map['confidence'];
    final Object? trackingRaw = map['tracking'];

    final double confidence = confidenceRaw is num
        ? confidenceRaw.toDouble()
        : 0.0;
    final bool tracking = trackingRaw is bool ? trackingRaw : false;

    return ArAlignment(
      homography: homography,
      confidence: confidence,
      tracking: tracking,
    );
  }

  static Homography? _parseHomography(Object? raw) {
    if (raw is! List || raw.length != 9) {
      return null;
    }
    final List<double> values = <double>[];
    for (final Object? entry in raw) {
      if (entry is! num) {
        return null;
      }
      values.add(entry.toDouble());
    }
    return Homography.fromRowMajor(values);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ArAlignment &&
        other.homography == homography &&
        other.confidence == confidence &&
        other.tracking == tracking;
  }

  @override
  int get hashCode => Object.hash(homography, confidence, tracking);

  @override
  String toString() =>
      'ArAlignment(homography: $homography, confidence: $confidence, '
      'tracking: $tracking)';
}

/// Dart-side handle to the native AR platform channel pair:
///  - `climbtopo/ar` ([MethodChannel]): start/stop/setMode calls.
///  - `climbtopo/ar/alignment` ([EventChannel]): a broadcast stream of
///    alignment updates (see [ArAlignment]).
///
/// Both channels default to those names but accept injected instances so
/// tests can supply mocks.
class ArChannel {
  ArChannel({MethodChannel? method, EventChannel? event})
    : _method = method ?? const MethodChannel('climbtopo/ar'),
      _event = event ?? const EventChannel('climbtopo/ar/alignment');

  final MethodChannel _method;
  final EventChannel _event;

  /// Starts native AR tracking/alignment against the reference photo at
  /// [referenceImagePath] (with pixel dimensions [refWidth]x[refHeight]),
  /// seeded with the route geometry in [routesJson].
  ///
  /// Invokes the native `start` method with exactly:
  /// `{'referenceImagePath': ..., 'refWidth': ..., 'refHeight': ...,
  /// 'routesJson': ...}`.
  Future<void> start({
    required String referenceImagePath,
    required int refWidth,
    required int refHeight,
    required String routesJson,
  }) {
    return _method.invokeMethod<void>('start', <String, Object?>{
      'referenceImagePath': referenceImagePath,
      'refWidth': refWidth,
      'refHeight': refHeight,
      'routesJson': routesJson,
    });
  }

  /// Stops native AR tracking. Invokes the native `stop` method (no args).
  Future<void> stop() {
    return _method.invokeMethod<void>('stop');
  }

  /// Switches the native alignment mode. Invokes the native `setMode`
  /// method with `{'mode': mode.name}` (`'auto'` or `'manual'`).
  Future<void> setMode(ArMode mode) {
    return _method.invokeMethod<void>('setMode', <String, Object?>{
      'mode': mode.name,
    });
  }

  /// A broadcast stream of [ArAlignment] updates from the native side.
  ///
  /// Non-map events are guarded (mapped to the [ArAlignment.fromMap]
  /// default) rather than propagated as-is or thrown.
  Stream<ArAlignment> alignments() {
    return _event.receiveBroadcastStream().map((Object? event) {
      if (event is! Map) {
        return ArAlignment.fromMap(const <Object?, Object?>{});
      }
      return ArAlignment.fromMap(event.cast<Object?, Object?>());
    });
  }
}
