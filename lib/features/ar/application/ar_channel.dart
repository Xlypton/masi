import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';

/// The AR alignment mode: whether the native side continuously re-solves the
/// homography from tracked features ([auto]), or holds the last-solved (or
/// manually nudged) homography fixed ([manual]).
///
/// `name` (e.g. `ArMode.manual.name == 'manual'`) is the wire value sent to
/// the native side via [ArChannel.setMode] — the native implementation MUST
/// match these exact strings.
enum ArMode { auto, manual }

/// A single AR alignment update pushed from the native side: a confidence
/// score, whether tracking is currently healthy, and (the primary ARKit
/// image-tracking signal) the 4 on-screen corners the tracked anchor
/// currently projects to.
///
/// Constructed from the wire map delivered over
/// [ArChannel.alignments]/`climbtopo/ar/alignment`. The native (ARKit)
/// side's current payload shape is:
/// ```
/// {
///   'tracking': <bool>,
///   'corners': [x0,y0,x1,y1,x2,y2,x3,y3],  // TL,TR,BR,BL screen points in
///                                          // logical px; present only when
///                                          // tracked
/// }
/// ```
/// `confidence` is never sent by native at all (it's a Dart-only field that
/// always defaults to `0.0` via [fromMap]); `homography`/`frameWidth`/
/// `frameHeight` used to be sent but are no longer read anywhere and have
/// been removed from this model entirely. [fromMap] parses each remaining
/// field independently and defaults just that field on malformed/missing
/// input rather than bailing out entirely: a missing/non-numeric
/// `confidence` falls back to `0.0`, a missing/non-bool `tracking` falls
/// back to `false`, and malformed `corners` falls back to `null` — none of
/// this throws.
class ArAlignment {
  const ArAlignment({
    required this.confidence,
    required this.tracking,
    this.screenCorners,
  });

  final double confidence;
  final bool tracking;

  /// The 4 on-screen corners (TL, TR, BR, BL, in logical px) the tracked
  /// ARKit image anchor currently projects to, or `null` when not tracking
  /// (or the native payload's `corners` was absent/malformed). This is the
  /// primary signal `ArAlignmentStage` uses in auto mode: it feeds directly
  /// into `Homography.fromQuad` to build the reference-photo → screen
  /// homography each frame, rather than relying on a native-solved
  /// homography.
  final List<Offset>? screenCorners;

  /// Parses [map] into an [ArAlignment].
  ///
  /// Never throws: each field is parsed independently and falls back to its
  /// documented default (see the class doc) on missing/malformed input,
  /// rather than the whole result bailing out to a single all-default value.
  factory ArAlignment.fromMap(Map<Object?, Object?> map) {
    final Object? confidenceRaw = map['confidence'];
    final Object? trackingRaw = map['tracking'];

    final double confidence = confidenceRaw is num
        ? confidenceRaw.toDouble()
        : 0.0;
    final bool tracking = trackingRaw is bool ? trackingRaw : false;

    final List<Offset>? screenCorners = _parseCorners(map['corners']);

    return ArAlignment(
      confidence: confidence,
      tracking: tracking,
      screenCorners: screenCorners,
    );
  }

  /// Parses the wire `corners` field (a flat `[x0,y0,x1,y1,x2,y2,x3,y3]`
  /// list, TL/TR/BR/BL) into 4 [Offset]s, or `null` if [raw] isn't a `List`
  /// of exactly 8 numeric entries.
  static List<Offset>? _parseCorners(Object? raw) {
    if (raw is! List || raw.length != 8) {
      return null;
    }
    final List<double> values = <double>[];
    for (final Object? entry in raw) {
      if (entry is! num) {
        return null;
      }
      values.add(entry.toDouble());
    }
    return <Offset>[
      Offset(values[0], values[1]),
      Offset(values[2], values[3]),
      Offset(values[4], values[5]),
      Offset(values[6], values[7]),
    ];
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ArAlignment &&
        other.confidence == confidence &&
        other.tracking == tracking &&
        _cornersEqual(other.screenCorners, screenCorners);
  }

  static bool _cornersEqual(List<Offset>? a, List<Offset>? b) {
    if (a == null || b == null) return a == b;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    confidence,
    tracking,
    screenCorners == null ? null : Object.hashAll(screenCorners!),
  );

  @override
  String toString() =>
      'ArAlignment(confidence: $confidence, '
      'tracking: $tracking, screenCorners: $screenCorners)';
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
  }) async {
    debugPrint(
      'AR_DBG ar_channel.start invoking (refPath=$referenceImagePath '
      '${refWidth}x$refHeight)',
    );
    try {
      await _method.invokeMethod<void>('start', <String, Object?>{
        'referenceImagePath': referenceImagePath,
        'refWidth': refWidth,
        'refHeight': refHeight,
        'routesJson': routesJson,
      });
      debugPrint('AR_DBG ar_channel.start returned OK');
    } catch (e) {
      debugPrint('AR_DBG ar_channel.start ERROR $e');
      rethrow;
    }
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

  /// Re-triggers native ARKit detection (clears the pinned world anchor so
  /// the user can redo a bad first lock). No args.
  Future<void> rescan() => _method.invokeMethod<void>('rescan');

  /// Locks the manual alignment on the native side, handing it the 4 screen
  /// corners (TL, TR, BR, BL, in Flutter view/logical points) the manually
  /// composited homography currently warps the reference photo's corners to.
  ///
  /// Invokes the native `lockManual` method with `{'corners': [x0,y0, x1,y1,
  /// x2,y2, x3,y3]}` — [corners] must have exactly 4 entries (asserted, and
  /// guarded in release with an early `false` return if that invariant is
  /// ever violated).
  ///
  /// Returns whether native actually pinned the alignment: `true` means the
  /// world anchor was successfully created (e.g. tracking was good enough at
  /// that moment); `false` means it couldn't (e.g. poor tracking) — a
  /// missing/non-bool result from the platform channel is treated as `false`
  /// rather than throwing.
  Future<bool> lockManual(List<Offset> corners) async {
    assert(corners.length == 4);
    if (corners.length != 4) return false;
    final flat = <double>[];
    for (final c in corners) {
      flat
        ..add(c.dx)
        ..add(c.dy);
    }
    final ok = await _method.invokeMethod<bool>('lockManual', {
      'corners': flat,
    });
    return ok ?? false;
  }

  /// Unlocks a previously-locked manual alignment on the native side. No
  /// args.
  Future<void> unlockManual() => _method.invokeMethod<void>('unlockManual');

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
