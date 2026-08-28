import 'dart:math' as math;

import 'package:masi/features/topo/domain/face_layout/baseline.dart';
import 'package:masi/features/topo/domain/face_layout/face_layout_input.dart';

/// Where a baseline came from — which decides how loudly the UI hedges about
/// it.
///
/// Design 4b draws an accepted line solid and a guessed one dashed, and shows
/// the "we assembled this from your photos, drag anything wrong" banner only
/// for a guess. That is this enum's only job; nothing about positioning reads
/// it.
enum BaselineOrigin {
  /// Drawn or accepted by a human. Solid line, no banner.
  authored,

  /// Traced through the photos' own GPS fixes — the good case, and what
  /// design 4b's "From 7 GPS points" caption is counting.
  gpsTrack,

  /// No usable GPS, but headings that sweep far enough round to be a lap of
  /// something. A ring of nominal size.
  bearingRing,

  /// No usable GPS, headings clustered in one arc — one side of a long rock.
  /// A straight strip of nominal size.
  bearingStrip,

  /// Nothing usable at all. A straight strip in capture order, which is §3's
  /// minimum viable contribution and explicitly NOT a degraded state.
  captureOrderStrip,
}

extension BaselineOriginX on BaselineOrigin {
  /// True when a human has not confirmed this line, so it renders dashed and
  /// earns the confidence banner.
  bool get isProvisional => this != BaselineOrigin.authored;
}

/// A synthesised line plus the story of where it came from.
typedef SynthesizedBaseline = ({Baseline baseline, BaselineOrigin origin});

/// Minimum spread, in metres, before a cloud of GPS fixes is traced as a
/// track rather than treated as one blob.
///
/// Lower than [kMinGpsSpreadMeters] (which guards the much stronger claim
/// that projections should OVERRIDE capture-order spacing) because here the
/// points are only ever visited in capture order — a slightly noisy track
/// still draws the right shape, it just wobbles.
const double kMinTrackSpreadMeters = 10.0;

/// Radius of a synthesised ring, in metres. A boulder you can walk round in a
/// few paces; the number only sets the drawing's scale, never any ordering.
const double kNominalRingRadiusMeters = 6.0;

/// Spacing between faces on a synthesised strip, in metres, and the shortest
/// strip worth drawing.
const double kNominalStripSpacingMeters = 4.0;
const double kMinNominalStripLengthMeters = 10.0;

/// How far apart the two ends of a GPS track may be, as a multiple of the
/// track's own MEDIAN segment length, before it stops being a ring.
///
/// Measured against segment length rather than overall extent, which is the
/// only version that actually works on the shape this feature exists for. A
/// boulder shot from four sides is a square: the gap from the fourth camera
/// back to the first is one more side, i.e. exactly the length of every
/// segment already in it, so any fraction-of-extent test (the gap is 0.7 of
/// the extent there) calls a textbook boulder open. Against the median
/// segment the same square scores 1.0 and closes, while a wall walked in one
/// direction scores about `n - 1` and stays open however long or short it is.
///
/// 1.2 rather than anything looser because the case that must stay OPEN is a
/// boulder with one side still missing — three of its four cameras, which
/// leaves a gap of 1.41 median segments. Admitting that would close a ring
/// the contributor has not finished walking, and §7's acceptance test 6 wants
/// the opposite: the strip becomes a loop when the fourth photo ARRIVES, not
/// before. A genuine ring of any vertex count scores 1.0.
const double kTrackClosureSegmentFactor = 1.2;

/// Builds a provisional baseline for [faces] from whatever signals they
/// carry — §5 step 1's synthesis, and the thing that makes a contributor's
/// zero-tap upload produce a layout at all.
///
/// [originLatitude]/[originLongitude] anchor the plane (see [LayoutPoint]);
/// pass the wall's own coordinates so a stored baseline and a re-synthesised
/// one land in the same space. When they are null the faces' own mean fix is
/// used, and when there is no GPS at all the plane is arbitrary — which is
/// harmless, because nothing metric is then compared against it.
///
/// Never returns null and never throws: every branch ends at a line, because
/// "no baseline" is not a state any reader screen should have to render.
SynthesizedBaseline synthesizeBaseline(
  List<FaceInput> faces, {
  double? originLatitude,
  double? originLongitude,
}) {
  final ordered = [...faces]
    ..sort((a, b) => a.captureOrder.compareTo(b.captureOrder));
  if (ordered.isEmpty) {
    return (baseline: Baseline.empty, origin: BaselineOrigin.captureOrderStrip);
  }

  final sweep = _bearingSweepDegrees(ordered);

  final track = _gpsTrack(ordered, originLatitude, originLongitude, sweep);
  if (track != null) return track;

  if (sweep != null && sweep.abs() >= kLoopSweepDegrees) {
    return (
      baseline: _ring(ordered),
      origin: BaselineOrigin.bearingRing,
    );
  }

  return (
    baseline: _strip(ordered.length),
    origin: sweep != null
        ? BaselineOrigin.bearingStrip
        : BaselineOrigin.captureOrderStrip,
  );
}

/// Traces the line through the faces' own GPS fixes, or `null` when they
/// cannot carry it.
SynthesizedBaseline? _gpsTrack(
  List<FaceInput> ordered,
  double? originLatitude,
  double? originLongitude,
  double? bearingSweepDegrees,
) {
  final located = ordered.where((f) => f.hasUsableGps()).toList();
  if (located.length < 2) return null;

  final originLat =
      originLatitude ??
      located.map((f) => f.latitude!).reduce((a, b) => a + b) / located.length;
  final originLon =
      originLongitude ??
      located.map((f) => f.longitude!).reduce((a, b) => a + b) / located.length;

  final points = [
    for (final f in located)
      projectToPlane(
        latitude: f.latitude!,
        longitude: f.longitude!,
        originLatitude: originLat,
        originLongitude: originLon,
      ),
  ];

  final candidate = Baseline(points);
  if (candidate.isDegenerate || candidate.extent < kMinTrackSpreadMeters) {
    // Every photo taken from one standing spot. A "track" through it would be
    // a scribble the size of the GPS error, so fall through to the shapes
    // that at least order the faces honestly.
    return null;
  }

  // Two independent ways to be a ring, because either sensor alone is
  // routinely the one that is missing: the walk came back to where it
  // started, or the headings swept all the way round. Neither is asked of the
  // contributor.
  final closes =
      points.length >= 3 &&
      (points.first.distanceTo(points.last) <=
              _medianSegmentLength(candidate) * kTrackClosureSegmentFactor ||
          (bearingSweepDegrees != null &&
              bearingSweepDegrees.abs() >= kLoopSweepDegrees));

  return (
    baseline: Baseline(points, closed: closes),
    origin: BaselineOrigin.gpsTrack,
  );
}

/// Median segment length of [line] — the typical stride between two
/// consecutive camera positions.
///
/// Median rather than mean: one photo taken from far off (a wide shot from
/// across the valley) is a single long segment that drags a mean well past
/// every real stride, and the closure test built on it would then call
/// everything a ring.
double _medianSegmentLength(Baseline line) {
  final lengths = line.segmentLengths..sort();
  if (lengths.isEmpty) return 0;
  final mid = lengths.length ~/ 2;
  return lengths.length.isOdd
      ? lengths[mid]
      : (lengths[mid - 1] + lengths[mid]) / 2;
}

/// Net signed heading sweep across [ordered], in degrees, or `null` when
/// fewer than three faces carry a bearing.
///
/// Signed and cumulative — summing the SHORTEST turn between consecutive
/// headings — so walking once round a boulder totals about ±360 while pointing
/// a camera back and forth along a wall totals nearly zero. Summing absolute
/// turns instead would make that same back-and-forth look like a lap.
double? _bearingSweepDegrees(List<FaceInput> ordered) {
  final bearings = [
    for (final f in ordered)
      if (f.bearingDegrees != null && f.bearingDegrees!.isFinite)
        f.bearingDegrees!,
  ];
  if (bearings.length < 3) return null;
  var sweep = 0.0;
  for (var i = 1; i < bearings.length; i++) {
    sweep += _shortestTurnDegrees(bearings[i - 1], bearings[i]);
  }
  return sweep;
}

/// The shortest way round from [from] to [to], in degrees, in (-180, 180].
double _shortestTurnDegrees(double from, double to) {
  var delta = (to - from) % 360.0;
  if (delta > 180.0) delta -= 360.0;
  if (delta <= -180.0) delta += 360.0;
  return delta;
}

/// A closed ring of nominal size, one vertex per face, at the position a
/// camera would stand in to shoot that face.
///
/// The camera stands OPPOSITE where it looks, so a face shot on bearing θ
/// puts its photographer at `centre - r·(sin θ, cos θ)`. Getting that sign
/// wrong builds a ring that is correct in shape and mirrored in order, which
/// is the kind of bug that survives every test that only counts faces.
Baseline _ring(List<FaceInput> ordered) {
  final points = <LayoutPoint>[];
  for (var i = 0; i < ordered.length; i++) {
    final bearing = ordered[i].bearingVector;
    final direction =
        bearing ??
        // A face with no heading in an otherwise-swept set still needs a
        // place on the ring; spacing it evenly by index is the capture-order
        // fallback §5 step 3a applies everywhere else.
        _unitAtDegrees(360.0 * i / ordered.length);
    points.add(direction * -kNominalRingRadiusMeters);
  }
  return Baseline(points, closed: true);
}

LayoutPoint _unitAtDegrees(double degrees) {
  final radians = degrees * math.pi / 180.0;
  return LayoutPoint(math.sin(radians), math.cos(radians));
}

/// A straight west-to-east strip long enough to hold [faceCount] faces.
///
/// §5 step 1's stated safe default: "a loop rendered as a strip is readable,
/// the reverse is confusing".
Baseline _strip(int faceCount) {
  final length = math.max(
    kMinNominalStripLengthMeters,
    kNominalStripSpacingMeters * math.max(faceCount - 1, 1),
  );
  return Baseline(const [LayoutPoint(0, 0)] + [LayoutPoint(length, 0)]);
}
