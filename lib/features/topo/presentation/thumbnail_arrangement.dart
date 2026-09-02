import 'dart:math' as math;

import 'package:flutter/painting.dart';

/// Where one face wants its thumbnail, before anyone else gets a say.
///
/// [base] is the dot on the baseline; [direction] is the way the thumbnail
/// should float off it (already in canvas pixels, any length — a zero vector
/// means "no opinion" and is treated as straight up).
class ThumbnailAnchor {
  const ThumbnailAnchor({
    required this.id,
    required this.base,
    required this.direction,
  });

  final String id;
  final Offset base;
  final Offset direction;
}

/// Where one face's thumbnail actually ends up.
class ThumbnailSlot {
  const ThumbnailSlot({
    required this.id,
    required this.base,
    required this.centre,
    required this.size,
  });

  final String id;

  /// The dot on the line this thumbnail belongs to. The leader is drawn from
  /// here, so a thumbnail that had to move is still visibly *this* face's.
  final Offset base;

  final Offset centre;
  final Size size;

  Rect get rect =>
      Rect.fromCenter(center: centre, width: size.width, height: size.height);

  Offset get topLeft => rect.topLeft;
}

/// Lays thumbnails out along a baseline so that **no two of them overlap**.
///
/// The naive placement — every thumbnail parked a fixed distance down its own
/// normal — collapses in the two cases that actually occur. On a closed ring
/// the normals converge, so four photos of a boulder land in a heap at the
/// centre. On a straight strip the normals are parallel, so photos spaced
/// closer than a thumbnail's width along the line simply stack on each other.
/// Both look like a rendering bug rather than like geometry, and both hide the
/// one thing the screen exists to show: which photo is which face.
///
/// So this is leader-line label placement, not stem placement. Each thumbnail
/// starts at its ideal spot, then a deterministic relaxation pass pushes
/// overlapping pairs apart along their axis of least penetration while a weak
/// spring keeps pulling each back toward where it wanted to be. The result is
/// stable (no randomness, fixed iteration count, order-independent within a
/// pass) and the caller draws a leader from [ThumbnailSlot.base] to the
/// resolved centre, so moving a thumbnail never orphans it.
///
/// Best-effort by design: when the canvas is genuinely too small to hold the
/// thumbnails without overlap, it returns the least-bad arrangement rather
/// than throwing or dropping any. A drawing that is slightly crowded is
/// recoverable; a face that silently vanished is not.
///
/// [stem] is how far a thumbnail floats off its dot, and it is deliberately
/// the ONLY distance in play. A version of this pushed each thumbnail out to
/// the far edge of the box it was allowed to occupy, to spend the empty
/// canvas on the gaps between them — which maximised separation and lost the
/// thing separation was for. A photo at the end of a 120px leader belongs to
/// no dot you can point at: the reader has to trace a line to find out which
/// side of the rock they are looking at, and four of those lines cross. Near
/// its own dot and displaced only as far as a collision demands is what reads
/// as "this photo is that side".
///
/// [obstacles] are the rock outlines themselves, as polylines in canvas
/// pixels. A thumbnail that sits ON the line hides the very shape the drawing
/// exists to show, and reads as a photo pinned to a place on the rock rather
/// than as a view of one side of it — so they are pushed clear of the line as
/// well as of each other. Best-effort, like everything else here: a line that
/// crosses the whole canvas leaves nowhere to go, and a crowded drawing beats
/// a missing face.
List<ThumbnailSlot> arrangeThumbnails({
  required List<ThumbnailAnchor> anchors,
  required Size canvas,
  Size thumbnail = const Size(64, 48),
  double stem = 52,
  double gap = 8,
  double margin = 6,
  int iterations = 90,
  List<List<Offset>> obstacles = const <List<Offset>>[],
  double lineClearance = 8,
}) {
  if (anchors.isEmpty) return const <ThumbnailSlot>[];

  final n = anchors.length;

  // Half-extents including the gap: two thumbnails are clear of each other
  // exactly when their centres differ by more than this on either axis.
  final needX = thumbnail.width + gap;
  final needY = thumbnail.height + gap;

  final minX = margin + thumbnail.width / 2;
  final maxX = math.max(minX, canvas.width - margin - thumbnail.width / 2);
  final minY = margin + thumbnail.height / 2;
  final maxY = math.max(minY, canvas.height - margin - thumbnail.height / 2);

  Offset clamp(Offset p) => Offset(
    p.dx.clamp(minX, maxX).toDouble(),
    p.dy.clamp(minY, maxY).toDouble(),
  );

  final halfW = thumbnail.width / 2 + lineClearance;
  final halfH = thumbnail.height / 2 + lineClearance;

  /// The rock outline that cuts deepest through a thumbnail centred at [c],
  /// or `null` when none of them touches it.
  ({Offset mid, double span})? deepestCrossing(Offset c) {
    ({Offset mid, double span})? worst;
    Offset? along;
    for (final line in obstacles) {
      for (var s = 0; s + 1 < line.length; s++) {
        final hit = _segmentThroughBox(line[s], line[s + 1], c, halfW, halfH);
        if (hit == null || (worst != null && hit.span < worst.span)) continue;
        worst = hit;
        along = line[s + 1] - line[s];
      }
    }
    if (worst == null) return null;
    // A crossing dead through the centre has no direction to push away from;
    // hand back the segment's normal instead, which is the shortest way off.
    if ((c - worst.mid).distance >= 0.001) return worst;
    final length = along?.distance ?? 0;
    final normal = length > 0
        ? Offset(-along!.dy / length, along.dx / length)
        : const Offset(0, -1);
    return (mid: c - normal, span: worst.span);
  }

  final ideal = <Offset>[];
  for (var i = 0; i < n; i++) {
    final d = anchors[i].direction;
    final length = d.distance;
    final unit = length > 0
        ? d / length
        // No usable normal (a degenerate segment). Up is the one direction
        // that never reads as "attached to the wrong part of the line".
        : const Offset(0, -1);
    final want = clamp(anchors[i].base + unit * stem);
    // A photo whose own normal points INTO the rock goes to the other side of
    // its dot instead. Relaxation can push a thumbnail off a line it has
    // landed on, but it cannot win an argument with the spring that put it
    // there: the ideal is what the spring pulls toward for two thirds of the
    // passes, so an ideal sitting on the outline is a thumbnail that spends
    // the whole arrangement being dragged back onto it.
    if (deepestCrossing(want) == null) {
      ideal.add(want);
      continue;
    }
    final flipped = clamp(anchors[i].base - unit * stem);
    ideal.add(deepestCrossing(flipped) == null ? flipped : want);
  }

  final pos = [for (final p in ideal) clamp(p)];

  /// Nudges [i] off any rock outline it is sitting on, one step per pass.
  ///
  /// A step rather than a solve: the exact escape distance depends on which
  /// other thumbnail is in the way, so this cooperates with the pair
  /// separation above instead of fighting it, and the spring decides how far
  /// out it is worth going. The last third of the passes runs without the
  /// spring, so the arrangement ENDS clear rather than being pulled back onto
  /// the line after the last push.
  bool pushOffLines(int i) {
    // One direction per pass, from the DEEPEST crossing, never all of them at
    // once: a thumbnail parked inside a ring is crossed by every side of it,
    // and pushing away from each in turn cancels out to nothing — it sits in
    // the middle of the boulder for ninety passes, perfectly balanced.
    final hit = deepestCrossing(pos[i]);
    if (hit == null) return false;
    final away = pos[i] - hit.mid;
    pos[i] = clamp(pos[i] + away / away.distance * 4.0);
    return true;
  }

  // The spring is switched off for the last third so the pass ENDS on
  // separation. With it running to the final iteration a pair could be pulled
  // back into contact after the last push apart, which is precisely the
  // failure the caller cannot see in a static screenshot.
  final springUntil = (iterations * 2) ~/ 3;

  for (var pass = 0; pass < iterations; pass++) {
    if (pass < springUntil) {
      for (var i = 0; i < n; i++) {
        pos[i] = pos[i] + (ideal[i] - pos[i]) * 0.12;
      }
    }

    var overlapped = false;
    for (var i = 0; i < n; i++) {
      for (var j = i + 1; j < n; j++) {
        final delta = pos[j] - pos[i];
        final overlapX = needX - delta.dx.abs();
        final overlapY = needY - delta.dy.abs();
        if (overlapX <= 0 || overlapY <= 0) continue;
        overlapped = true;

        Offset push;
        if (delta.dx == 0 && delta.dy == 0) {
          // Exactly coincident — every separation axis is equally valid, so
          // pick one from the index rather than from the geometry. Anything
          // read off the (zero) delta here is a division by zero.
          push = i.isEven ? Offset(needX / 2, 0) : Offset(0, needY / 2);
        } else if (overlapX <= overlapY) {
          push = Offset((delta.dx >= 0 ? 1 : -1) * overlapX / 2, 0);
        } else {
          push = Offset(0, (delta.dy >= 0 ? 1 : -1) * overlapY / 2);
        }

        // Half each, so neither face is privileged by its capture order.
        pos[i] = pos[i] - push * 0.55;
        pos[j] = pos[j] + push * 0.55;
      }
    }

    var onLine = false;
    for (var i = 0; i < n; i++) {
      if (pushOffLines(i)) onLine = true;
      pos[i] = clamp(pos[i]);
    }

    if (!overlapped && !onLine && pass >= springUntil) break;
  }

  _repackRemainingOverlaps(pos: pos, needX: needX, needY: needY, clamp: clamp);

  // The repack works on a lattice and knows nothing about the rock, so it
  // can drop a thumbnail straight back onto the line. A short settling pass
  // with no spring puts it right; it is a no-op when the repack did nothing.
  if (obstacles.isNotEmpty) {
    for (var pass = 0; pass < 40; pass++) {
      var moved = false;
      for (var i = 0; i < n; i++) {
        for (var j = i + 1; j < n; j++) {
          final delta = pos[j] - pos[i];
          final overlapX = needX - delta.dx.abs();
          final overlapY = needY - delta.dy.abs();
          if (overlapX <= 0 || overlapY <= 0) continue;
          moved = true;
          final push = overlapX <= overlapY
              ? Offset((delta.dx >= 0 ? 1 : -1) * overlapX / 2, 0)
              : Offset(0, (delta.dy >= 0 ? 1 : -1) * overlapY / 2);
          pos[i] = clamp(pos[i] - push * 0.55);
          pos[j] = clamp(pos[j] + push * 0.55);
        }
      }
      for (var i = 0; i < n; i++) {
        if (pushOffLines(i)) moved = true;
      }
      if (!moved) break;
    }
  }

  _assignToNearestBase([for (final a in anchors) a.base], pos);

  return [
    for (var i = 0; i < n; i++)
      ThumbnailSlot(
        id: anchors[i].id,
        base: anchors[i].base,
        centre: pos[i],
        size: thumbnail,
      ),
  ];
}

/// Hands the resolved positions back to the faces that are CLOSEST to them.
///
/// Everything above decides where thumbnails may sit; this decides which
/// thumbnail sits in which of those places. They are separate problems, and
/// only doing the first leaves the second to whatever order the spring
/// happened to settle in — which on a stroke whose dots are close together
/// puts a photo two dots away from its own, with a long leader crossing
/// somebody else's to prove it. A reader then cannot tell which side of the
/// rock they are looking at without tracing lines, which is the one job the
/// drawing has.
///
/// A swap is free: the positions are already non-overlapping and swapping two
/// of them cannot create an overlap, so this can only improve the pairing.
/// Total leader LENGTH is the thing minimised (not the square), because that
/// is what makes the guarantee geometric: two crossing segments always get
/// shorter when their ends are exchanged, so a settled arrangement has no
/// crossings left. Each pass strictly decreases a bounded sum, so it
/// terminates; the fixed iteration order keeps it deterministic.
void _assignToNearestBase(List<Offset> bases, List<Offset> pos) {
  final n = pos.length;
  if (n < 2) return;

  for (var pass = 0; pass < n; pass++) {
    var swapped = false;
    for (var i = 0; i < n; i++) {
      for (var j = i + 1; j < n; j++) {
        final now = (pos[i] - bases[i]).distance + (pos[j] - bases[j]).distance;
        final then =
            (pos[j] - bases[i]).distance + (pos[i] - bases[j]).distance;
        if (then < now - 0.001) {
          final hold = pos[i];
          pos[i] = pos[j];
          pos[j] = hold;
          swapped = true;
        }
      }
    }
    if (!swapped) break;
  }
}

/// Where the leader line from [base] should stop: the point where it meets
/// the thumbnail's edge, or `null` when the base is already inside it.
///
/// Drawing the full segment instead would put a line across the photo.
Offset? leaderEnd(Offset base, Rect rect) {
  if (rect.contains(base)) return null;
  final centre = rect.center;
  final delta = centre - base;
  if (delta.dx == 0 && delta.dy == 0) return null;

  // Slab clip. The centre is inside the rect by construction, so t = 1 is
  // inside both slabs and the ENTRY parameter is the later of the two
  // per-axis crossings — taking the earlier one would stop the leader short
  // of the box on the axis that has not been entered yet.
  var t = 0.0;
  if (delta.dx != 0) {
    final edge = delta.dx > 0 ? rect.left : rect.right;
    t = math.max(t, (edge - base.dx) / delta.dx);
  }
  if (delta.dy != 0) {
    final edge = delta.dy > 0 ? rect.top : rect.bottom;
    t = math.max(t, (edge - base.dy) / delta.dy);
  }
  if (!t.isFinite || t <= 0 || t >= 1) return null;
  return base + delta * t;
}

/// Last resort for the case relaxation cannot solve: a row of thumbnails
/// wider than the canvas.
///
/// Pushing apart along the axis of least penetration is the right move
/// almost always, but it deadlocks when the crowded axis is also the one
/// pinned by the canvas edge — six photos on a 360px-wide strip need 432px of
/// row and there is nowhere left to push sideways. The escape is to use the
/// other axis, which relaxation will not do on its own because the sideways
/// penetration stays the smaller of the two.
///
/// So: walk the thumbnails in capture order and give each the nearest free
/// cell on a lattice of its own pitch, preferring to move DOWN a row over
/// sliding along one. That turns an impossible row into a legible zigzag, and
/// it is a no-op whenever relaxation already succeeded. If even this finds
/// nothing free (a canvas too small to hold them at all) the relaxed position
/// stands — crowded beats vanished.
void _repackRemainingOverlaps({
  required List<Offset> pos,
  required double needX,
  required double needY,
  required Offset Function(Offset) clamp,
}) {
  bool clash(Offset a, Offset b) =>
      (a.dx - b.dx).abs() < needX - 0.001 &&
      (a.dy - b.dy).abs() < needY - 0.001;

  var anyOverlap = false;
  for (var i = 0; i < pos.length && !anyOverlap; i++) {
    for (var j = i + 1; j < pos.length; j++) {
      if (clash(pos[i], pos[j])) {
        anyOverlap = true;
        break;
      }
    }
  }
  if (!anyOverlap) return;

  // Nearest-first, and vertical before horizontal at equal distance: a
  // thumbnail that dropped a row still sits above its own dot, while one that
  // slid sideways sits above someone else's.
  final cells = <(int, int)>[];
  for (var cx = -3; cx <= 3; cx++) {
    for (var cy = -3; cy <= 3; cy++) {
      cells.add((cx, cy));
    }
  }
  cells.sort((a, b) {
    final byRing = (a.$1.abs() + a.$2.abs()).compareTo(b.$1.abs() + b.$2.abs());
    if (byRing != 0) return byRing;
    final bySlide = a.$1.abs().compareTo(b.$1.abs());
    if (bySlide != 0) return bySlide;
    final byX = a.$1.compareTo(b.$1);
    return byX != 0 ? byX : a.$2.compareTo(b.$2);
  });

  final ideal = [...pos];
  final placed = <Offset>[];
  for (var i = 0; i < pos.length; i++) {
    Offset? chosen;
    for (final cell in cells) {
      final candidate = clamp(
        ideal[i] + Offset(cell.$1 * needX, cell.$2 * needY),
      );
      if (placed.every((other) => !clash(candidate, other))) {
        chosen = candidate;
        break;
      }
    }
    final resolved = chosen ?? pos[i];
    pos[i] = resolved;
    placed.add(resolved);
  }
}

/// Where the segment [a]-[b] passes through the box of half-extents
/// [halfW]/[halfH] centred on [centre], or `null` when it misses.
///
/// Liang–Barsky rather than "is the closest point on the segment inside the
/// box": a box is not a ball, so on a wide thumbnail the nearest point of a
/// segment that genuinely crosses it can lie outside, and the naive test
/// then reports no collision on exactly the case it exists to catch.
///
/// Returns the MIDPOINT of the part inside the box — the point to push away
/// from, since pushing away from an endpoint would slide the thumbnail along
/// the line rather than off it — and how long that part is, which is how the
/// caller tells a graze from a line straight through the middle.
({Offset mid, double span})? _segmentThroughBox(
  Offset a,
  Offset b,
  Offset centre,
  double halfW,
  double halfH,
) {
  final left = centre.dx - halfW;
  final right = centre.dx + halfW;
  final top = centre.dy - halfH;
  final bottom = centre.dy + halfH;
  final dx = b.dx - a.dx;
  final dy = b.dy - a.dy;

  var t0 = 0.0;
  var t1 = 1.0;
  for (final (p, q) in <(double, double)>[
    (-dx, a.dx - left),
    (dx, right - a.dx),
    (-dy, a.dy - top),
    (dy, bottom - a.dy),
  ]) {
    if (p == 0) {
      // Parallel to this pair of edges: outside it means outside the box, and
      // no value of t can bring it back.
      if (q < 0) return null;
      continue;
    }
    final r = q / p;
    if (p < 0) {
      if (r > t1) return null;
      if (r > t0) t0 = r;
    } else {
      if (r < t0) return null;
      if (r < t1) t1 = r;
    }
  }
  if (t1 < t0) return null;
  final mid = (t0 + t1) / 2;
  return (
    mid: Offset(a.dx + dx * mid, a.dy + dy * mid),
    span: (t1 - t0) * math.sqrt(dx * dx + dy * dy),
  );
}
