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

  Rect get rect => Rect.fromCenter(
    center: centre,
    width: size.width,
    height: size.height,
  );

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
List<ThumbnailSlot> arrangeThumbnails({
  required List<ThumbnailAnchor> anchors,
  required Size canvas,
  Size thumbnail = const Size(64, 48),
  double stem = 52,
  double gap = 8,
  double margin = 6,
  int iterations = 90,
}) {
  if (anchors.isEmpty) return const <ThumbnailSlot>[];

  final n = anchors.length;
  final ideal = <Offset>[];
  for (var i = 0; i < n; i++) {
    final d = anchors[i].direction;
    final length = d.distance;
    final unit = length > 0
        ? d / length
        // No usable normal (a degenerate segment). Up is the one direction
        // that never reads as "attached to the wrong part of the line".
        : const Offset(0, -1);
    ideal.add(anchors[i].base + unit * stem);
  }

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

  final pos = [for (final p in ideal) clamp(p)];

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

    for (var i = 0; i < n; i++) {
      pos[i] = clamp(pos[i]);
    }

    if (!overlapped && pass >= springUntil) break;
  }

  _repackRemainingOverlaps(
    pos: pos,
    needX: needX,
    needY: needY,
    clamp: clamp,
  );

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
      (a.dx - b.dx).abs() < needX - 0.001 && (a.dy - b.dy).abs() < needY - 0.001;

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
