import 'dart:ui';

import 'topo_route.dart';

/// Returns the shortest distance from [p] to the segment `a`-`b`.
///
/// The projection parameter is clamped to `[0, 1]` so that a perpendicular
/// foot falling outside the segment resolves to the nearer endpoint instead
/// of an extrapolated point on the infinite line. A zero-length segment
/// (i.e. `a == b`) is handled as a point-to-point distance to avoid a
/// divide-by-zero.
double _distancePointToSegment(Offset p, Offset a, Offset b) {
  final double abx = b.dx - a.dx;
  final double aby = b.dy - a.dy;
  final double lengthSquared = abx * abx + aby * aby;

  if (lengthSquared == 0) {
    return (p - a).distance;
  }

  final double apx = p.dx - a.dx;
  final double apy = p.dy - a.dy;
  double t = (apx * abx + apy * aby) / lengthSquared;
  t = t.clamp(0.0, 1.0);

  final Offset closest = Offset(a.dx + t * abx, a.dy + t * aby);
  return (p - closest).distance;
}

/// Returns the minimum distance from [tapPercent] to any part of [route].
///
/// Routes with a single point are treated as a point; routes with two or
/// more points are treated as a polyline, taking the minimum distance over
/// all consecutive segments.
double _minDistanceToRoute(Offset tapPercent, TopoRoute route) {
  final List<Offset> points = route.points;

  if (points.length == 1) {
    return (tapPercent - points[0]).distance;
  }

  double minDistance = double.infinity;
  for (int i = 0; i < points.length - 1; i++) {
    final double d = _distancePointToSegment(tapPercent, points[i], points[i + 1]);
    if (d < minDistance) {
      minDistance = d;
    }
  }
  return minDistance;
}

/// Finds the id of the route nearest to [tapPercent], within
/// [thresholdPercent], among [routes].
///
/// Only routes with `visible == true` and a non-empty `points` list are
/// considered. Distance is computed as the minimum distance from
/// [tapPercent] to the route's polyline (or to its single point, for a
/// one-point route). The route with the smallest qualifying distance wins;
/// if multiple routes tie exactly, the route with the lowest `id` wins.
/// Returns `null` if no visible route has a point within
/// [thresholdPercent] of [tapPercent].
int? hitTestRoute(
  Offset tapPercent,
  List<TopoRoute> routes,
  double thresholdPercent,
) {
  int? bestId;
  double bestDistance = double.infinity;

  for (final TopoRoute route in routes) {
    if (!route.visible || route.points.isEmpty) {
      continue;
    }

    final double distance = _minDistanceToRoute(tapPercent, route);
    if (distance > thresholdPercent) {
      continue;
    }

    final bool isNewBest = distance < bestDistance ||
        (distance == bestDistance && bestId != null && route.id < bestId);
    if (isNewBest) {
      bestDistance = distance;
      bestId = route.id;
    }
  }

  return bestId;
}
