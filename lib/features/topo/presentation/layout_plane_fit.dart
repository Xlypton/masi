import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

import 'package:masi/features/topo/domain/face_layout/baseline.dart';

/// Maps between the baseline's plane (metres east/north — see [LayoutPoint])
/// and canvas pixels, fitting the whole stroke into a box with room to spare.
///
/// Pure and separate from the widget so the mapping — the part that silently
/// mirrors a topo when it is wrong — is testable without pumping anything.
///
/// The y axis FLIPS: the plane's +y is north and a canvas's +y is down. A fit
/// that forgets it draws a layout that is correct in shape, mirrored in
/// arrangement, and completely convincing — the worst kind of wrong for a
/// document someone navigates by at the rock.
class LayoutPlaneFit {
  const LayoutPlaneFit._(this._scale, this._planeCentre, this._canvasCentre);

  /// Fits [baseline] into [size], keeping [padding] px clear on every edge
  /// for the thumbnails that float off the line.
  ///
  /// Aspect ratio is preserved: a single scale for both axes. Stretching to
  /// fill would make a boulder's ring an ellipse whose long side is whichever
  /// way the canvas happens to be shaped.
  ///
  /// The four per-edge overrides exist because the band the thumbnails need
  /// is **not** the same on every edge. Thumbnails leave a ring in every
  /// direction, so a ring needs the band all round; they leave a strip on one
  /// side only, so reserving the band on the other three shrinks the line for
  /// nothing — a wall drawn at 60% of the width it could have had, with its
  /// photos crammed together above it and half the canvas empty below. The
  /// line is centred in what is left after the padding, so an uneven padding
  /// also moves the drawing off the geometric centre, which is what balances
  /// a one-sided composition.
  factory LayoutPlaneFit.forBaseline(
    Baseline baseline,
    Size size, {
    double padding = 56,
    double? padLeft,
    double? padTop,
    double? padRight,
    double? padBottom,
  }) {
    final left = padLeft ?? padding;
    final top = padTop ?? padding;
    final right = padRight ?? padding;
    final bottom = padBottom ?? padding;
    final rawWidth = size.width - left - right;
    final rawHeight = size.height - top - bottom;
    final usableWidth = math.max(rawWidth, 1.0);
    final usableHeight = math.max(rawHeight, 1.0);
    // Off-centre only while the padding actually FITS. A box too small to
    // hold its own padding has no usable rect to be off-centre in, and
    // biasing towards one edge there would push the drawing out of a canvas
    // that is already too small for it.
    final canvasCentre = Offset(
      rawWidth > 0 ? left + rawWidth / 2 : size.width / 2,
      rawHeight > 0 ? top + rawHeight / 2 : size.height / 2,
    );

    if (baseline.isDegenerate) {
      return LayoutPlaneFit._(1, const LayoutPoint(0, 0), canvasCentre);
    }

    final bounds = baseline.bounds;
    final planeWidth = bounds.maxX - bounds.minX;
    final planeHeight = bounds.maxY - bounds.minY;
    // A perfectly straight strip has zero height. Dividing by it gives
    // infinity, and every point then lands at NaN — a blank canvas with no
    // error anywhere to explain it.
    final scale = math.min(
      planeWidth <= 0 ? double.infinity : usableWidth / planeWidth,
      planeHeight <= 0 ? double.infinity : usableHeight / planeHeight,
    );

    return LayoutPlaneFit._(
      scale.isFinite && scale > 0 ? scale : 1,
      LayoutPoint(
        (bounds.minX + bounds.maxX) / 2,
        (bounds.minY + bounds.maxY) / 2,
      ),
      canvasCentre,
    );
  }

  /// A fixed-scale fit for drawing a line when there is no line yet.
  ///
  /// [forBaseline] derives its scale from the stroke it is shown, which is
  /// exactly wrong while one is being DRAWN: the draft grows with every
  /// pointer move, so the scale would change under the finger and the same
  /// screen position would mean a different place in the plane from one
  /// frame to the next. A redraw therefore pins a scale up front — either
  /// the outgoing line's, or this one when there is no outgoing line — and
  /// keeps it for the whole stroke.
  ///
  /// [planeSpanMetres] is what the canvas's WIDTH represents, so the drawn
  /// shape is the shape the finger made at a believable size for a crag.
  factory LayoutPlaneFit.forSpan(
    Size size,
    double planeSpanMetres, {
    double padding = 56,
  }) {
    final usableWidth = math.max(size.width - padding * 2, 1.0);
    final span = planeSpanMetres > 0 ? planeSpanMetres : 1.0;
    return LayoutPlaneFit._(
      usableWidth / span,
      const LayoutPoint(0, 0),
      Offset(size.width / 2, size.height / 2),
    );
  }

  final double _scale;
  final LayoutPoint _planeCentre;
  final Offset _canvasCentre;

  /// Pixels per plane unit — what a metre is worth on screen.
  double get scale => _scale;

  Offset toCanvas(LayoutPoint point) => Offset(
    _canvasCentre.dx + (point.x - _planeCentre.x) * _scale,
    // Negated: plane north is canvas up.
    _canvasCentre.dy - (point.y - _planeCentre.y) * _scale,
  );

  LayoutPoint toPlane(Offset point) => LayoutPoint(
    _planeCentre.x + (point.dx - _canvasCentre.dx) / _scale,
    _planeCentre.y - (point.dy - _canvasCentre.dy) / _scale,
  );

  /// A plane direction as a canvas direction — the same y flip, without the
  /// translation, so normals and tangents point the right way.
  Offset directionToCanvas(LayoutPoint direction) =>
      Offset(direction.x, -direction.y);
}
