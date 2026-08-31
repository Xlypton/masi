import 'dart:math' as math;

import 'package:masi/features/topo/domain/face_layout/baseline.dart';

/// Everything the layout engine is allowed to know about one face.
///
/// Deliberately NOT a Drift row and deliberately not a widget-facing model:
/// the engine is pure (workstream B, "no UI deps"), so the whole of it can be
/// property-tested headlessly with hand-built inputs, and the same resolver
/// can later be pointed at a different pairing — a sector's walls instead of
/// a wall's photos — without touching a line of it.
class FaceInput {
  const FaceInput({
    required this.id,
    required this.captureOrder,
    this.latitude,
    this.longitude,
    this.gpsAccuracyMeters,
    this.bearingDegrees,
    this.pinnedT,
  });

  /// The face's stable identity — a `photos.id` at the only call site today.
  final String id;

  /// Position in the sequence the photos were taken in — §5's signal 2, and
  /// the only one that is always present.
  ///
  /// Backed by `Photos.sortOrder`, which starts as the upload sequence and is
  /// changed only by a human reordering the rail. That is exactly §5.4's rule
  /// ("order is only ever changed by the human dragging a thumbnail"), so
  /// there is no separate capture-order column to drift out of sync with what
  /// the user sees.
  final int captureOrder;

  /// EXIF GPS, or `null` when the photo carries none.
  final double? latitude;
  final double? longitude;

  /// Reported horizontal accuracy in metres, or `null` when unknown.
  ///
  /// `null` is treated as *unusable* rather than *perfect* by
  /// [hasUsableGps] — an unlabelled fix under a cliff is exactly the 5–15 m
  /// multipath case §5 says never to trust for intra-object positioning.
  final double? gpsAccuracyMeters;

  /// Camera heading in degrees clockwise from true north, or `null`.
  final double? bearingDegrees;

  /// Where a human dragged this face to, or `null` if nobody has.
  ///
  /// One nullable column rather than the spec's `t` + `t_pinned` pair. The
  /// pair has a state the resolver would have to arbitrate — a `t` with
  /// `t_pinned` false is a stale computed value, and full-row last-writer-wins
  /// sync (decision D-4) can land the two halves from different edits. A
  /// single nullable value cannot disagree with itself, and "unpinned" is
  /// then not a stored fact at all but the absence of one.
  final double? pinnedT;

  bool get isPinned => pinnedT != null;

  /// A copy with a different pin.
  ///
  /// Used where a wall holds several rocks: the pin stored on the row names
  /// a rock AND a place on it (see `BaselineSet.pack`), and the engine is
  /// handed one rock at a time — so the place has to be re-expressed in that
  /// rock's own coordinates before it goes in.
  FaceInput withPinnedT(double? t) => FaceInput(
    id: id,
    captureOrder: captureOrder,
    latitude: latitude,
    longitude: longitude,
    gpsAccuracyMeters: gpsAccuracyMeters,
    bearingDegrees: bearingDegrees,
    pinnedT: t,
  );

  /// Whether this face's GPS is good enough to position it ALONG the rock.
  ///
  /// Note the asymmetry with the wall's own map pin: a fix far too coarse to
  /// say which side of a 4 m boulder you are on is perfectly fine for saying
  /// which valley the boulder is in. That is §5's whole "GPS is object-level
  /// only" rule, and it lives here so no caller can accidentally reuse one
  /// answer for the other question.
  bool hasUsableGps({double maxAccuracyMeters = kMaxUsableGpsAccuracyMeters}) {
    final lat = latitude;
    final lon = longitude;
    final accuracy = gpsAccuracyMeters;
    if (lat == null || lon == null || accuracy == null) return false;
    if (!lat.isFinite || !lon.isFinite || !accuracy.isFinite) return false;
    if (lat.abs() > 90 || lon.abs() > 180) return false;
    return accuracy > 0 && accuracy <= maxAccuracyMeters;
  }

  /// This face's heading as a unit vector on the layout plane, or `null`.
  LayoutPoint? get bearingVector {
    final b = bearingDegrees;
    if (b == null || !b.isFinite) return null;
    final radians = b * math.pi / 180.0;
    // x is east, y is north, and a compass bearing turns clockwise FROM
    // north — so north is (0,1) and east is (1,0), which is sin/cos rather
    // than the cos/sin of an ordinary maths angle.
    return LayoutPoint(math.sin(radians), math.cos(radians));
  }

  FaceInput copyWith({double? pinnedT, bool clearPin = false}) => FaceInput(
    id: id,
    captureOrder: captureOrder,
    latitude: latitude,
    longitude: longitude,
    gpsAccuracyMeters: gpsAccuracyMeters,
    bearingDegrees: bearingDegrees,
    pinnedT: clearPin ? null : (pinnedT ?? this.pinnedT),
  );

  @override
  String toString() =>
      'FaceInput($id, order: $captureOrder, '
      'gps: ${latitude != null}, bearing: $bearingDegrees, pin: $pinnedT)';
}

/// Worst horizontal accuracy, in metres, at which a fix may still be used to
/// position a face along the baseline.
///
/// 12 m is a deliberate compromise and one of §8's open questions: phone GPS
/// in the open reports 3–5 m, under a cliff or in trees 5–15 m. Anything
/// looser than this cannot distinguish two sides of a boulder, so it is
/// dropped and capture order carries the face instead — the outcome §5's
/// hierarchy wants anyway.
const double kMaxUsableGpsAccuracyMeters = 12.0;

/// How far apart, in metres, a span's GPS points must spread before the
/// engine believes the spread is signal rather than noise.
///
/// Below this, projecting the points onto the line just scatters faces by the
/// error in their own fixes. 25 m is roughly twice the accuracy ceiling
/// above: the spread has to beat the noise by a clear factor, not squeak past
/// it.
const double kMinGpsSpreadMeters = 25.0;

/// Minimum faces in a span carrying usable GPS before their projections are
/// trusted (§5 step 3b). Two points can always be fitted to a line and say
/// nothing; three is the first count that can disagree with itself.
const int kMinGpsFacesForProjection = 3;

/// Total bearing sweep, in degrees, above which the faces are taken to walk
/// all the way round an object rather than along one side of it.
const double kLoopSweepDegrees = 270.0;

/// Metres per degree of latitude — the sphere approximation the plane
/// projection below is built on.
const double _metersPerDegreeLatitude = 111320.0;

/// Projects WGS84 degrees onto the flat layout plane centred on
/// ([originLatitude], [originLongitude]).
///
/// An equirectangular projection, not a real geodesic one, and that is
/// correct here rather than merely cheap: an object in this model spans tens
/// of metres, over which the error is millimetres, and the alternative pulls
/// in a projection dependency for a number that is then compared against a
/// finger-drawn line.
LayoutPoint projectToPlane({
  required double latitude,
  required double longitude,
  required double originLatitude,
  required double originLongitude,
}) {
  final metersPerDegreeLongitude =
      _metersPerDegreeLatitude * math.cos(originLatitude * math.pi / 180.0);
  return LayoutPoint(
    (longitude - originLongitude) * metersPerDegreeLongitude,
    (latitude - originLatitude) * _metersPerDegreeLatitude,
  );
}

/// The inverse of [projectToPlane] — plane metres back to WGS84 degrees.
({double latitude, double longitude}) unprojectFromPlane({
  required LayoutPoint point,
  required double originLatitude,
  required double originLongitude,
}) {
  final metersPerDegreeLongitude =
      _metersPerDegreeLatitude * math.cos(originLatitude * math.pi / 180.0);
  return (
    latitude: originLatitude + point.y / _metersPerDegreeLatitude,
    longitude: metersPerDegreeLongitude == 0
        ? originLongitude
        : originLongitude + point.x / metersPerDegreeLongitude,
  );
}
