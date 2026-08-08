import 'dart:math' as math;
import 'dart:ui';

/// How much breathing room to leave around a route's bounding box, as a
/// fraction of the box's longer side.
///
/// A line cropped exactly to its own extent reads as a scribble on an
/// unidentifiable texture: the whole point of showing the rock is the context
/// — the arete it follows, the roof it pulls through — and none of that is
/// inside the bounding box.
const double kRouteCropPadFraction = 0.22;

/// The smallest fraction of the image's SHORTER side a crop may take.
///
/// This is a resolution floor, not an aesthetic one. The feed draws from the
/// 512 px thumbnail (`thumbs/<id>.jpg`), so a crop of 0.22 leaves ~113 px of
/// source for a 52 pt tile — still over 2x on a 2x screen. Cropping tighter
/// would magnify a short boulder problem into mush.
const double kRouteCropMinFraction = 0.22;

/// The sub-rectangle of a topo photo to show so that ONE route fills the
/// frame, in normalized (0..1) image coordinates.
///
/// [points] are percent-space, the same coordinates [TopoRoute.points] uses.
/// [imageWidth]/[imageHeight] are the photo's PIXEL dimensions, and they
/// matter: the returned rectangle is square **in pixels**, not in normalized
/// space, so a tall photo does not come back stretched. Normalized coordinates
/// are relative to each axis independently, so a 0.3 x 0.3 normalized crop of a
/// 1000x2000 photo is 300x600 pixels — drawing that into a square tile is how
/// you get a squashed climber.
///
/// Returns `null` when there is nothing to frame — no points, or a photo with
/// no dimensions recorded. Callers treat that as "fall back to the plain
/// thumbnail", never as an error.
///
/// The result is always fully inside the image: the square is clamped to the
/// shorter side and then slid (not shrunk) to fit, so a route running along the
/// very edge of the photo still yields a full, in-bounds frame rather than one
/// that hangs off and renders as a band of blank.
Rect? routeCropRect({
  required List<Offset> points,
  required int imageWidth,
  required int imageHeight,
  double padFraction = kRouteCropPadFraction,
  double minFraction = kRouteCropMinFraction,
}) {
  if (points.isEmpty) return null;
  if (imageWidth <= 0 || imageHeight <= 0) return null;

  final width = imageWidth.toDouble();
  final height = imageHeight.toDouble();

  // Everything below is in PIXEL space. Doing the squaring in normalized space
  // is the trap this function exists to avoid.
  var minX = double.infinity;
  var maxX = double.negativeInfinity;
  var minY = double.infinity;
  var maxY = double.negativeInfinity;
  for (final point in points) {
    final x = point.dx.clamp(0.0, 1.0) * width;
    final y = point.dy.clamp(0.0, 1.0) * height;
    minX = math.min(minX, x);
    maxX = math.max(maxX, x);
    minY = math.min(minY, y);
    maxY = math.max(maxY, y);
  }

  final centerX = (minX + maxX) / 2;
  final centerY = (minY + maxY) / 2;

  // A square whose side covers the longer extent plus padding. A single-point
  // route (a bouldering topo marked with one tap) has a zero-extent box, and
  // the floor below is what stops it collapsing to nothing.
  final extent = math.max(maxX - minX, maxY - minY);
  final shorterSide = math.min(width, height);
  var side = extent * (1 + 2 * padFraction);
  side = math.max(side, shorterSide * minFraction);
  // Cannot be larger than the image itself, or no in-bounds square exists.
  side = math.min(side, shorterSide);

  // Slide into bounds rather than shrinking: the frame stays the size the
  // resolution floor asked for, and only its position gives.
  final left = (centerX - side / 2).clamp(0.0, width - side);
  final top = (centerY - side / 2).clamp(0.0, height - side);

  return Rect.fromLTWH(
    left / width,
    top / height,
    side / width,
    side / height,
  );
}
