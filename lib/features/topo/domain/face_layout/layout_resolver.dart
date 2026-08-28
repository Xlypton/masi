import 'dart:math' as math;

import 'package:masi/features/topo/domain/face_layout/baseline.dart';
import 'package:masi/features/topo/domain/face_layout/baseline_synthesis.dart';
import 'package:masi/features/topo/domain/face_layout/face_layout_input.dart';

/// Which signal actually decided a face's position — §5's hierarchy, recorded
/// per face so the UI can say *why* and a test can assert the hierarchy held
/// rather than merely that some number came out.
enum FacePlacement {
  /// A human dragged it here. Never overridden by anything below.
  pinned,

  /// Its own GPS fix, projected onto the line.
  gpsProjected,

  /// Its heading, mapped to an angle around a closed line.
  bearingRefined,

  /// Spread evenly in capture order — the always-available answer.
  captureOrder,
}

/// Which way the cameras face relative to the line, on a closed baseline.
///
/// Rendering only, exactly as §5 requires: it picks which side of the stroke
/// thumbnails and labels sit on and never moves a face along it.
enum LayoutOrientation {
  /// Cameras stand outside and look in — a boulder. Thumbnails render
  /// outside the ring.
  inward,

  /// Cameras stand inside and look out — an amphitheatre or a mine.
  /// Thumbnails render inside the ring.
  outward,

  /// Not enough headings to tell. Callers pick a default and say nothing.
  unknown,
}

/// One face's resolved place on the line.
class FacePosition {
  const FacePosition({
    required this.id,
    required this.captureOrder,
    required this.t,
    required this.placement,
  });

  final String id;
  final int captureOrder;

  /// Arc-length fraction along the baseline. Cyclic when the baseline is
  /// closed.
  final double t;

  final FacePlacement placement;

  bool get isPinned => placement == FacePlacement.pinned;

  @override
  String toString() => 'FacePosition($id, t: ${t.toStringAsFixed(3)}, '
      '$placement)';
}

/// The whole computed layout for one rock object.
///
/// Every field is derived from the current rows — §5 step 5's "topology is a
/// computed property of current data, not a stored decision". Nothing here is
/// persisted except the two things a human authored: the baseline stroke and
/// any pins.
class LayoutResult {
  const LayoutResult({
    required this.baseline,
    required this.origin,
    required this.faces,
    required this.orientation,
    required this.thumbnailNormalSign,
  });

  final Baseline baseline;
  final BaselineOrigin origin;

  /// Faces in capture order — the order the reader pages through.
  final List<FacePosition> faces;

  final LayoutOrientation orientation;

  /// Multiply `baseline.normalAt(t)` by this to get the direction a
  /// thumbnail should float away from the line.
  ///
  /// A single sign for the whole object rather than one per face: thumbnails
  /// that individually chose a side would flip back and forth wherever the
  /// stroke wiggles, which reads as noise rather than as geometry.
  final double thumbnailNormalSign;

  /// True when the line closes — the only thing separating a boulder from a
  /// wall in this model.
  bool get isLoop => baseline.closed;

  /// True while the line is still a guess: it earns a dashed stroke and
  /// design 4b's "drag anything that looks wrong" banner.
  bool get isProvisional => origin.isProvisional;

  FacePosition? positionOf(String id) {
    for (final f in faces) {
      if (f.id == id) return f;
    }
    return null;
  }

  static const LayoutResult empty = LayoutResult(
    baseline: Baseline.empty,
    origin: BaselineOrigin.captureOrderStrip,
    faces: <FacePosition>[],
    orientation: LayoutOrientation.unknown,
    thumbnailNormalSign: 1,
  );
}

/// Resolves a `t` for every face, blending all available signals under §5's
/// strict priority.
///
/// Pure and total: same inputs, same output, no I/O, no throw. That is what
/// lets it be re-run on literally every edit (§5 step 5) instead of being
/// something the app has to remember to invalidate.
///
/// Pass [baseline] when the wall has an authored or previously accepted one;
/// leave it null to have one synthesised from the faces themselves.
LayoutResult resolveLayout({
  required List<FaceInput> faces,
  Baseline? baseline,
  BaselineOrigin origin = BaselineOrigin.authored,
  double? originLatitude,
  double? originLongitude,
}) {
  if (faces.isEmpty) return LayoutResult.empty;

  // Sorted by capture order, tie-broken by id purely so the result is
  // reproducible when two rows share a sortOrder — which the multi-photo
  // strip's append-at-end writer can produce under a concurrent attach.
  final ordered = [...faces]..sort((a, b) {
    final byOrder = a.captureOrder.compareTo(b.captureOrder);
    return byOrder != 0 ? byOrder : a.id.compareTo(b.id);
  });

  var line = baseline;
  var lineOrigin = origin;
  if (line == null || line.isDegenerate) {
    final synthesized = synthesizeBaseline(
      ordered,
      originLatitude: originLatitude,
      originLongitude: originLongitude,
    );
    line = synthesized.baseline;
    lineOrigin = synthesized.origin;
  }

  final resolvedOrigin = _planeOrigin(ordered, originLatitude, originLongitude);
  // Orientation is settled BEFORE anything is placed, and only from the
  // cameras' own fixes. Deriving it from resolved positions instead would be
  // circular — bearing placement needs to know which side the rock is on, and
  // would then be graded by a classifier reading its own output. That circle
  // is exactly what put an amphitheatre's faces 180 degrees out and then
  // reported it as a boulder.
  final orientation = _classifyOrientation(ordered, resolvedOrigin);
  final positions = _resolvePositions(ordered, line, resolvedOrigin, orientation);

  return LayoutResult(
    baseline: line,
    origin: lineOrigin,
    faces: [
      for (var i = 0; i < ordered.length; i++)
        FacePosition(
          id: ordered[i].id,
          captureOrder: ordered[i].captureOrder,
          t: line.normalizeT(positions[i].t),
          placement: positions[i].placement,
        ),
    ],
    orientation: orientation,
    thumbnailNormalSign: _thumbnailSign(ordered, line, positions),
  );
}

typedef _Placed = ({double t, FacePlacement placement});

({double lat, double lon})? _planeOrigin(
  List<FaceInput> ordered,
  double? originLatitude,
  double? originLongitude,
) {
  if (originLatitude != null && originLongitude != null) {
    return (lat: originLatitude, lon: originLongitude);
  }
  final located = ordered.where((f) => f.hasUsableGps()).toList();
  if (located.isEmpty) return null;
  return (
    lat: located.map((f) => f.latitude!).reduce((a, b) => a + b) /
        located.length,
    lon: located.map((f) => f.longitude!).reduce((a, b) => a + b) /
        located.length,
  );
}

/// §5 steps 2–4: pins are fixed, then each span between them is filled.
List<_Placed> _resolvePositions(
  List<FaceInput> ordered,
  Baseline line,
  ({double lat, double lon})? planeOrigin,
  LayoutOrientation orientation,
) {
  final n = ordered.length;
  final out = List<_Placed?>.filled(n, null);
  final pinIndices = <int>[];
  for (var i = 0; i < n; i++) {
    final pin = ordered[i].pinnedT;
    if (pin != null && pin.isFinite) {
      out[i] = (t: line.normalizeT(pin), placement: FacePlacement.pinned);
      pinIndices.add(i);
    }
  }

  if (pinIndices.isEmpty) {
    _fillWholeLine(ordered, line, planeOrigin, orientation, out);
  } else if (line.closed) {
    _fillClosedSpans(ordered, line, planeOrigin, orientation, out, pinIndices);
  } else {
    _fillOpenSpans(ordered, line, planeOrigin, orientation, out, pinIndices);
  }

  return [
    for (var i = 0; i < n; i++)
      out[i] ?? (t: 0.0, placement: FacePlacement.captureOrder),
  ];
}

void _fillWholeLine(
  List<FaceInput> ordered,
  Baseline line,
  ({double lat, double lon})? planeOrigin,
  LayoutOrientation orientation,
  List<_Placed?> out,
) {
  final indices = [for (var i = 0; i < ordered.length; i++) i];
  if (line.closed) {
    _assign(
      ordered,
      line,
      planeOrigin,
      orientation,
      out,
      indices,
      startT: 0,
      forward: 1.0,
      anchorStart: true,
      anchorEnd: false,
    );
    return;
  }
  if (indices.length == 1) {
    // A lone photo has no position to express. Mid-line rather than at the
    // very start, because a single thumbnail parked on the left end of a
    // strip reads as "the rest failed to load".
    out[indices.first] = (t: 0.5, placement: FacePlacement.captureOrder);
    return;
  }
  _assign(
    ordered,
    line,
    planeOrigin,
    orientation,
    out,
    indices,
    startT: 0,
    forward: 1.0,
    anchorStart: true,
    anchorEnd: true,
  );
}

void _fillOpenSpans(
  List<FaceInput> ordered,
  Baseline line,
  ({double lat, double lon})? planeOrigin,
  LayoutOrientation orientation,
  List<_Placed?> out,
  List<int> pinIndices,
) {
  final first = pinIndices.first;
  if (first > 0) {
    _assign(
      ordered,
      line,
      planeOrigin,
      orientation,
      out,
      [for (var i = 0; i < first; i++) i],
      startT: 0,
      forward: out[first]!.t,
      anchorStart: true,
      anchorEnd: false,
    );
  }
  for (var p = 0; p + 1 < pinIndices.length; p++) {
    final a = pinIndices[p];
    final b = pinIndices[p + 1];
    if (b - a <= 1) continue;
    _assign(
      ordered,
      line,
      planeOrigin,
      orientation,
      out,
      [for (var i = a + 1; i < b; i++) i],
      startT: out[a]!.t,
      // A later pin dragged BEFORE an earlier one leaves no room between
      // them. Zero forward length collapses the span onto the first pin
      // rather than producing negative spacing that would reverse order.
      forward: math.max(0.0, out[b]!.t - out[a]!.t),
      anchorStart: false,
      anchorEnd: false,
    );
  }
  final last = pinIndices.last;
  if (last < ordered.length - 1) {
    _assign(
      ordered,
      line,
      planeOrigin,
      orientation,
      out,
      [for (var i = last + 1; i < ordered.length; i++) i],
      startT: out[last]!.t,
      forward: math.max(0.0, 1.0 - out[last]!.t),
      anchorStart: false,
      anchorEnd: true,
    );
  }
}

void _fillClosedSpans(
  List<FaceInput> ordered,
  Baseline line,
  ({double lat, double lon})? planeOrigin,
  LayoutOrientation orientation,
  List<_Placed?> out,
  List<int> pinIndices,
) {
  final n = ordered.length;
  for (var p = 0; p < pinIndices.length; p++) {
    final a = pinIndices[p];
    final b = pinIndices[(p + 1) % pinIndices.length];
    final between = <int>[];
    for (var step = 1; step < n; step++) {
      final i = (a + step) % n;
      if (i == b) break;
      between.add(i);
    }
    if (between.isEmpty) continue;
    final startT = out[a]!.t;
    var forward = (out[b]!.t - startT) % 1.0;
    if (forward < 0) forward += 1.0;
    // One pin, or several stacked on the same spot: the span is the whole
    // way round rather than nothing.
    if (pinIndices.length == 1 || forward <= 1e-9) forward = 1.0;
    _assign(
      ordered,
      line,
      planeOrigin,
      orientation,
      out,
      between,
      startT: startT,
      forward: forward,
      anchorStart: false,
      anchorEnd: false,
    );
  }
}

/// Places every face in one span, trying GPS, then bearing, then plain even
/// spacing — §5 step 3's (b), (c), (a) in priority order.
void _assign(
  List<FaceInput> ordered,
  Baseline line,
  ({double lat, double lon})? planeOrigin,
  LayoutOrientation orientation,
  List<_Placed?> out,
  List<int> indices, {
  required double startT,
  required double forward,
  required bool anchorStart,
  required bool anchorEnd,
}) {
  if (indices.isEmpty) return;

  final offsets = _evenOffsets(
    indices.length,
    forward,
    anchorStart: anchorStart,
    anchorEnd: anchorEnd,
  );
  final placements = List<FacePlacement>.filled(
    indices.length,
    FacePlacement.captureOrder,
  );

  var source = FacePlacement.gpsProjected;
  var refined = _gpsOffsets(
    ordered,
    line,
    planeOrigin,
    indices,
    startT,
    forward,
  );
  if (refined == null) {
    source = FacePlacement.bearingRefined;
    refined = _bearingOffsets(
      ordered,
      line,
      orientation,
      indices,
      startT,
      forward,
    );
  }

  if (refined != null) {
    _blendRefined(offsets, placements, refined, forward, source);
  }

  for (var k = 0; k < indices.length; k++) {
    out[indices[k]] = (
      t: line.normalizeT(startT + offsets[k]),
      placement: placements[k],
    );
  }
}

/// Even spacing across a span (§5 step 3a).
///
/// [anchorStart]/[anchorEnd] say whether a face may sit exactly ON the
/// boundary. Span boundaries that are pins must stay exclusive — two faces at
/// identical `t` render as one thumbnail and read as a lost photo — while the
/// ends of an open line are real positions a face should be able to occupy.
List<double> _evenOffsets(
  int count,
  double forward, {
  required bool anchorStart,
  required bool anchorEnd,
}) {
  if (count == 1 && anchorStart && !anchorEnd) return [0.0];
  if (anchorStart && anchorEnd) {
    if (count == 1) return [forward / 2];
    return [for (var k = 0; k < count; k++) forward * k / (count - 1)];
  }
  if (anchorStart) {
    return [for (var k = 0; k < count; k++) forward * k / count];
  }
  if (anchorEnd) {
    return [for (var k = 0; k < count; k++) forward * (k + 1) / count];
  }
  return [for (var k = 0; k < count; k++) forward * (k + 1) / (count + 1)];
}

/// Span offsets from GPS projection, or `null` when the span's fixes do not
/// clear §5 step 3b's bar.
List<double?>? _gpsOffsets(
  List<FaceInput> ordered,
  Baseline line,
  ({double lat, double lon})? planeOrigin,
  List<int> indices,
  double startT,
  double forward,
) {
  if (planeOrigin == null || forward <= 0) return null;
  final located = <int, LayoutPoint>{};
  for (var k = 0; k < indices.length; k++) {
    final face = ordered[indices[k]];
    if (!face.hasUsableGps()) continue;
    located[k] = projectToPlane(
      latitude: face.latitude!,
      longitude: face.longitude!,
      originLatitude: planeOrigin.lat,
      originLongitude: planeOrigin.lon,
    );
  }
  if (located.length < kMinGpsFacesForProjection) return null;

  var spread = 0.0;
  final points = located.values.toList();
  for (var i = 0; i < points.length; i++) {
    for (var j = i + 1; j < points.length; j++) {
      spread = math.max(spread, points[i].distanceTo(points[j]));
    }
  }
  // A cloud no wider than the noise that produced it. Projecting it would
  // scatter faces by their own error and call the result data.
  if (spread < kMinGpsSpreadMeters) return null;

  final offsets = List<double?>.filled(indices.length, null);
  for (final entry in located.entries) {
    final t = line.project(entry.value).t;
    var offset = t - startT;
    if (line.closed) {
      offset %= 1.0;
      if (offset < 0) offset += 1.0;
    }
    // A fix that lands outside this span contradicts the pins bracketing it,
    // and §5 step 4 is explicit that a sensor never reorders anything — so it
    // is dropped, not honoured.
    if (offset < 0 || offset > forward) continue;
    offsets[entry.key] = offset;
  }
  return offsets.any((o) => o != null) ? offsets : null;
}

/// Span offsets from heading, for a closed line only (§5 step 3c).
///
/// A heading is an angle, and an angle only maps to a position when the line
/// wraps round something. On a strip the same heading describes every photo
/// shot from the path, which is precisely why §5 makes bearing a sort key
/// rather than ground truth.
List<double?>? _bearingOffsets(
  List<FaceInput> ordered,
  Baseline line,
  LayoutOrientation orientation,
  List<int> indices,
  double startT,
  double forward,
) {
  if (!line.closed || forward <= 0) return null;
  final centroid = line.centroid;
  final radius = math.max(line.extent / 2, 1e-6);
  // Which way a heading points relative to the line depends on which side of
  // it the rock is. Round a boulder the photographer stands opposite what
  // they shoot; inside an amphitheatre they stand on the same side as it.
  // `unknown` takes the boulder sign because that is the overwhelmingly
  // common object, and because bearings alone genuinely cannot tell the two
  // apart — a full sweep looks identical from inside and out.
  final standSign = orientation == LayoutOrientation.outward ? 1.0 : -1.0;
  final offsets = List<double?>.filled(indices.length, null);
  var found = 0;
  for (var k = 0; k < indices.length; k++) {
    final bearing = ordered[indices[k]].bearingVector;
    if (bearing == null) continue;
    // The photographer stands opposite the direction they shoot, so the
    // camera sits at centre - r·bearing. Projecting THAT (rather than the
    // bearing itself) means an irregular hand-drawn ring works exactly like a
    // circle, with no special case for shape.
    final t = line.project(centroid + bearing * (standSign * radius)).t;
    var offset = t - startT;
    offset %= 1.0;
    if (offset < 0) offset += 1.0;
    if (offset > forward) continue;
    offsets[k] = offset;
    found++;
  }
  return found >= 2 ? offsets : null;
}

/// Folds sensor-derived offsets into the evenly-spaced ones, dropping any
/// that would reorder the span.
///
/// §5 step 4 in code: a value that contradicts capture order is an outlier —
/// magnetic rock, a bad fix — and outliers are dropped, never used to
/// reorder. The running maximum is what enforces it: an offset that does not
/// advance on its predecessor is simply not taken.
void _blendRefined(
  List<double> offsets,
  List<FacePlacement> placements,
  List<double?> refined,
  double forward,
  FacePlacement source,
) {
  final accepted = <int, double>{};
  var high = double.negativeInfinity;
  for (var k = 0; k < refined.length; k++) {
    final value = refined[k];
    if (value == null) continue;
    if (value <= high) continue;
    accepted[k] = value;
    high = value;
  }
  if (accepted.length < 2) return;

  final keys = accepted.keys.toList()..sort();
  for (final k in keys) {
    offsets[k] = accepted[k]!;
    placements[k] = source;
  }
  // Faces the sensors could not place sit evenly between the ones they
  // could, so a single missing heading does not drag a whole span back to
  // uniform spacing.
  for (var k = 0; k < offsets.length; k++) {
    if (accepted.containsKey(k)) continue;
    final before = keys.where((i) => i < k).fold<int?>(null, (a, b) => b);
    final after = keys.where((i) => i > k).fold<int?>(null, (a, b) => a ?? b);
    final lowIndex = before ?? -1;
    final highIndex = after ?? offsets.length;
    final lowValue = before == null ? 0.0 : accepted[before]!;
    final highValue = after == null ? forward : accepted[after]!;
    final steps = highIndex - lowIndex;
    offsets[k] =
        lowValue + (highValue - lowValue) * (k - lowIndex) / math.max(steps, 1);
  }
}

/// Boulder or amphitheatre, from the sign of the average dot product between
/// each camera's heading and its direction to the centre of the camera cloud
/// (§5).
///
/// Cameras that look INWARD stand outside the rock — a boulder. Cameras that
/// look outward stand inside one — an amphitheatre or a mine. No contributor
/// is ever asked which they are standing in.
///
/// Read from the fixes themselves rather than from resolved positions, and
/// therefore `unknown` whenever GPS is absent. That is the honest answer, not
/// a gap: with headings alone the two shapes are indistinguishable — walking
/// round the outside of a block and turning on the spot inside a mine both
/// sweep 360 degrees — so anything derived from bearings would only be
/// restating the assumption it started from.
LayoutOrientation _classifyOrientation(
  List<FaceInput> ordered,
  ({double lat, double lon})? planeOrigin,
) {
  if (planeOrigin == null) return LayoutOrientation.unknown;

  final located = <LayoutPoint, LayoutPoint>{};
  for (final face in ordered) {
    final bearing = face.bearingVector;
    if (bearing == null || !face.hasUsableGps()) continue;
    located[projectToPlane(
      latitude: face.latitude!,
      longitude: face.longitude!,
      originLatitude: planeOrigin.lat,
      originLongitude: planeOrigin.lon,
    )] = bearing;
  }
  if (located.length < 2) return LayoutOrientation.unknown;

  var centre = const LayoutPoint(0, 0);
  for (final position in located.keys) {
    centre = centre + position;
  }
  centre = centre * (1 / located.length);

  var sum = 0.0;
  var count = 0;
  for (final entry in located.entries) {
    final toCentre = (centre - entry.key).normalized;
    if (toCentre == null) continue;
    sum += entry.value.dot(toCentre);
    count++;
  }
  if (count < 2) return LayoutOrientation.unknown;

  final mean = sum / count;
  // A deliberate dead band. Cameras that neither clearly look in nor clearly
  // look out are a mixed or badly-calibrated set, and guessing from a mean of
  // 0.05 would flip every thumbnail to the wrong side on the next photo.
  if (mean > 0.2) return LayoutOrientation.inward;
  if (mean < -0.2) return LayoutOrientation.outward;
  return LayoutOrientation.unknown;
}

/// Which side of the line thumbnails float on.
///
/// Follows the cameras' own gaze: the rock is what they are pointed at, so
/// putting the picture on that side makes the stroke read as "the rock is
/// over there" rather than as an arbitrary ribbon.
double _thumbnailSign(
  List<FaceInput> ordered,
  Baseline line,
  List<_Placed> positions,
) {
  var sum = 0.0;
  for (var i = 0; i < ordered.length; i++) {
    final bearing = ordered[i].bearingVector;
    if (bearing == null) continue;
    final normal = line.normalAt(positions[i].t);
    if (normal == null) continue;
    sum += bearing.dot(normal);
  }
  if (sum > 0) return 1;
  if (sum < 0) return -1;
  return 1;
}
