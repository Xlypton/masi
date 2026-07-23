import 'dart:ui' show Offset, Rect;

import 'package:masi/features/topo/domain/topo_route.dart';

/// Ship 1 of the route-derived rock box (see #68's plan): rather than trust
/// Vision-based foreground segmentation (which selected PEOPLE instead of the
/// rock — see the AR overhaul doc), the "rock" AR highlights/tracks is
/// derived directly from the geometry the user actually drew: the drawn
/// routes are always on the rock, so a padded bounding box around all route
/// points/symbols is a robust (if coarse) stand-in for "where the rock is".
///
/// Padding each side by [kRockBoxPadFraction] of the box's longer extent
/// gives the box some margin beyond the drawn geometry itself (routes rarely
/// touch the rock's true edges), and the [kRockBoxMinAspect] floor keeps a
/// single near-vertical (or near-horizontal) route from producing a
/// pathologically thin sliver box.
const double kRockBoxPadFraction = 0.18;

/// Neither side of the padded box may be thinner than this fraction of the
/// other side — see [rockBoxFromRoutes]'s doc.
const double kRockBoxMinAspect = 0.55;

/// Half-size (in each direction) of the box built around a degenerate
/// (single-point, or all-coincident-points) route — see [rockBoxFromRoutes]'s
/// doc.
const double kRockBoxPointHalf = 0.12;

/// Computes the bounding box of all drawn route geometry in [routes] —
/// every [TopoRoute.points] entry plus every [TopoRoute.symbols]' position —
/// padded to plausibly cover the rock face the routes are drawn on, in 0..1
/// fractions of the upright photo (top-left origin, same percent space
/// [TopoRoute.points] is already stored in).
///
/// Returns `null` if [routes] contains no points/symbols at all (nothing to
/// derive a box from).
///
/// Padding: the box is grown on every side by [kRockBoxPadFraction] times
/// its longer raw extent (width or height, whichever is bigger), then
/// widened/heightened (about its own center) if needed so neither side is
/// thinner than [kRockBoxMinAspect] times the other — this keeps a single
/// near-vertical or near-horizontal route from producing an unusably thin
/// sliver box.
///
/// Degenerate case: if every point/symbol coincides (a single-point route,
/// or several points at the exact same position), there is no meaningful
/// width/height to pad proportionally, so the box is instead a fixed
/// [kRockBoxPointHalf]-radius square centered on that point.
///
/// The result is always clamped into `[0, 1]` on every side (photo bounds),
/// and `null` is returned instead of a degenerate/empty clamped rect (e.g.
/// every point sitting exactly on one edge, with padding clamped away).
Rect? rockBoxFromRoutes(List<TopoRoute> routes) {
  final pts = <Offset>[];
  for (final r in routes) {
    pts.addAll(r.points);
    for (final s in r.symbols) {
      pts.add(s.position);
    }
  }
  if (pts.isEmpty) return null;

  var minX = pts.first.dx, maxX = pts.first.dx;
  var minY = pts.first.dy, maxY = pts.first.dy;
  for (final p in pts) {
    if (p.dx < minX) minX = p.dx;
    if (p.dx > maxX) maxX = p.dx;
    if (p.dy < minY) minY = p.dy;
    if (p.dy > maxY) maxY = p.dy;
  }

  final w = maxX - minX, h = maxY - minY;
  final ext = w > h ? w : h;

  double l, t, rr, b;
  if (ext <= 1e-6) {
    // Degenerate: all points coincident (or within floating-point noise) --
    // nothing to pad proportionally, so fall back to a fixed-size box
    // centered on the shared point.
    final cx = (minX + maxX) / 2, cy = (minY + maxY) / 2;
    l = cx - kRockBoxPointHalf;
    t = cy - kRockBoxPointHalf;
    rr = cx + kRockBoxPointHalf;
    b = cy + kRockBoxPointHalf;
  } else {
    final pad = kRockBoxPadFraction * ext;
    l = minX - pad;
    t = minY - pad;
    rr = maxX + pad;
    b = maxY + pad;

    var w2 = rr - l, h2 = b - t;
    final cx = (l + rr) / 2, cy = (t + b) / 2;
    if (w2 < kRockBoxMinAspect * h2) {
      w2 = kRockBoxMinAspect * h2;
      l = cx - w2 / 2;
      rr = cx + w2 / 2;
    }
    if (h2 < kRockBoxMinAspect * w2) {
      h2 = kRockBoxMinAspect * w2;
      t = cy - h2 / 2;
      b = cy + h2 / 2;
    }
  }

  double c(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);
  l = c(l);
  t = c(t);
  rr = c(rr);
  b = c(b);
  if (rr <= l || b <= t) return null;
  return Rect.fromLTRB(l, t, rr, b);
}

/// The 4 corners of [box] in TL, TR, BR, BL order — the same corner
/// convention every other AR quad (e.g. `ArAlignment.screenCorners`,
/// `Homography.fromQuad`'s `dst`) uses.
List<Offset> rockBoxCornersNorm(Rect box) {
  return [box.topLeft, box.topRight, box.bottomRight, box.bottomLeft];
}
