/// How much of the shared world a single pull is allowed to fetch (W-1).
///
/// ## The problem this exists for
///
/// `fetchSharedTopos` issued `.eq('visibility','shared')` with no limit, no geo
/// scope and no pagination, then imported every row into local SQLite. At a
/// hundred published topos that is fine. At ten thousand it downloads the world
/// onto a phone at a crag, over the connection least able to carry it.
///
/// ## Why a bounding box and not a radius query
///
/// The filter has to be expressible in PostgREST — `.gte`/`.lte` on the two
/// coordinate columns — because the alternative is a server-side RPC and the
/// whole shared fetch is still a client-side join today. A box is a superset of
/// the circle it encloses, so this over-fetches slightly rather than under-
/// fetching: the corners bring in topos up to ~41% further away than
/// [radiusKm]. That is the right direction to be wrong in. Nothing here is a
/// privacy boundary — RLS decides what is visible, this decides how much of it
/// to carry — so a loose box costs bandwidth, never correctness.
library;

import 'dart:math' as math;

/// A point to scope the fetch around.
typedef GeoAnchor = ({double latitude, double longitude});

/// A latitude/longitude window, in degrees.
typedef GeoBox = ({
  double minLatitude,
  double maxLatitude,
  double minLongitude,
  double maxLongitude,
});

/// Default reach around the anchor. Deliberately generous: climbers drive, and
/// a feed that only knows about the valley you are standing in is useless for
/// planning next weekend. 250 km covers a normal trip radius while still
/// excluding another continent.
const double kSharedTopoRadiusKm = 250;

/// Hard ceiling on published topos per pull, applied whether or not there is an
/// anchor. This is the actual W-1 backstop: geography narrows the common case,
/// but a dense region must still not be able to hand a phone an unbounded set.
const int kSharedTopoLimit = 500;

/// Separate, much smaller ceiling for published topos that have NO coordinates.
///
/// They cannot be geo-filtered, so without their own budget they would either
/// be dropped entirely — invisible forever, which is a worse bug than the one
/// being fixed — or be allowed to consume the whole limit. On the live project
/// 1 published wall in 10 has no coordinates, so this is not a hypothetical
/// case to wave away.
const int kSharedTopoUncoordinatedLimit = 50;

/// Mean Earth degrees-to-km at the equator. One degree of latitude is very
/// nearly constant; longitude shrinks with the cosine of latitude.
const double _kKmPerDegreeLatitude = 111.32;

/// Floor for `cos(latitude)`, matching the `nearby_published_topos` RPC.
/// Without it the longitude window explodes to the whole planet near the poles
/// — mathematically correct and operationally useless.
const double _kMinCosLatitude = 0.01;

/// The scope of one shared-topo fetch.
class SharedTopoScope {
  const SharedTopoScope({
    this.anchor,
    this.radiusKm = kSharedTopoRadiusKm,
    this.limit = kSharedTopoLimit,
    this.uncoordinatedLimit = kSharedTopoUncoordinatedLimit,
  });

  /// Everything, no geography, no cap — the pre-W-1 behaviour.
  ///
  /// Kept as a named constructor rather than deleted because tests and any
  /// future full-resync path want it, and because naming it makes each use a
  /// visible decision instead of an omitted argument.
  const SharedTopoScope.unbounded()
    : anchor = null,
      radiusKm = double.infinity,
      limit = 0,
      uncoordinatedLimit = 0;

  /// Where to fetch around, or null for "no geographic preference".
  ///
  /// Null is not a failure state: a brand-new account with no topos of its own
  /// has nowhere to anchor to, and showing it the most recent published topos
  /// is better than showing it nothing. [limit] still applies.
  final GeoAnchor? anchor;

  final double radiusKm;

  /// `0` means unlimited.
  final int limit;

  /// `0` means unlimited.
  final int uncoordinatedLimit;

  bool get isUnbounded => limit == 0 && anchor == null;

  /// The latitude/longitude window to filter on, or null when there is no
  /// anchor or the window would wrap the antimeridian.
  ///
  /// Wrapping returns null on purpose. A wrapped box cannot be expressed as one
  /// `min <= x <= max` pair, and the choices are to split it into two queries or
  /// to skip the longitude filter. Skipping is chosen because it degrades to
  /// "fetch a latitude band, still capped by [limit]" — correct, merely less
  /// selective — whereas an unsplit wrapped box would silently return NOTHING
  /// for anyone near the dateline.
  GeoBox? get boundingBox {
    final at = anchor;
    if (at == null || !radiusKm.isFinite || radiusKm <= 0) return null;

    final latDelta = radiusKm / _kKmPerDegreeLatitude;
    final cosLat = math.max(
      _kMinCosLatitude,
      math.cos(at.latitude * math.pi / 180).abs(),
    );
    final lngDelta = radiusKm / (_kKmPerDegreeLatitude * cosLat);

    // Latitude clamps rather than wraps: there is no "beyond the pole".
    final minLat = math.max(-90.0, at.latitude - latDelta);
    final maxLat = math.min(90.0, at.latitude + latDelta);

    final minLng = at.longitude - lngDelta;
    final maxLng = at.longitude + lngDelta;
    if (minLng < -180 || maxLng > 180) return null; // wraps — see doc.

    return (
      minLatitude: minLat,
      maxLatitude: maxLat,
      minLongitude: minLng,
      maxLongitude: maxLng,
    );
  }
}

/// Picks the anchor for the next pull from the signed-in user's OWN walls.
///
/// **The most recently updated one wins — not the centroid.** A centroid is the
/// obvious choice and the wrong one: a climber with crags in Italy and in
/// Norway has a centroid somewhere in Germany, and a radius around it reaches
/// neither of the places they actually climb. "Where I was working most
/// recently" is both a better predictor and degrades sensibly — it simply
/// follows them as they travel.
///
/// Returns null when no own wall has coordinates, which [SharedTopoScope]
/// treats as "no geographic preference" rather than as an error.
///
/// [candidates] is expected to be the user's own walls as
/// `(updatedAt, latitude, longitude)` triples; rows without both coordinates
/// are ignored. Pure and import-free so it can be tested without a database.
GeoAnchor? anchorFromOwnWalls(
  Iterable<({int updatedAt, double? latitude, double? longitude})> candidates,
) {
  int? bestAt;
  GeoAnchor? best;
  for (final row in candidates) {
    final lat = row.latitude;
    final lng = row.longitude;
    if (lat == null || lng == null) continue;
    if (lat.isNaN || lng.isNaN || lat.abs() > 90 || lng.abs() > 180) continue;
    if (bestAt == null || row.updatedAt > bestAt) {
      bestAt = row.updatedAt;
      best = (latitude: lat, longitude: lng);
    }
  }
  return best;
}
