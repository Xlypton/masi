import 'dart:ui' show Size, Offset;

import 'package:flutter_test/flutter_test.dart';
import 'package:masi/features/topo/domain/face_layout/baseline.dart';
import 'package:masi/features/topo/presentation/layout_plane_fit.dart';

/// The plane-to-canvas mapping, which is the one piece of this feature that
/// can be wrong in a way that looks completely right.
void main() {
  test('north is up: the y axis flips between plane and canvas', () {
    final line = Baseline(const [LayoutPoint(0, 0), LayoutPoint(0, 100)]);
    final fit = LayoutPlaneFit.forBaseline(line, const Size(200, 200));

    final south = fit.toCanvas(const LayoutPoint(0, 0));
    final north = fit.toCanvas(const LayoutPoint(0, 100));

    expect(
      north.dy,
      lessThan(south.dy),
      reason: 'a mirrored topo is convincing and wrong — the worst kind',
    );
  });

  test('round-trips a point through canvas space', () {
    final line = Baseline(const [
      LayoutPoint(-30, -10),
      LayoutPoint(40, 25),
    ]);
    final fit = LayoutPlaneFit.forBaseline(line, const Size(300, 200));

    const original = LayoutPoint(12, 3);
    final back = fit.toPlane(fit.toCanvas(original));
    expect(back.x, closeTo(original.x, 1e-9));
    expect(back.y, closeTo(original.y, 1e-9));
  });

  test('a perfectly straight strip has zero height and still fits', () {
    // Dividing by a zero span gives infinity, and every point then lands at
    // NaN — a blank canvas with no error anywhere to explain it.
    final line = Baseline(const [LayoutPoint(0, 0), LayoutPoint(80, 0)]);
    final fit = LayoutPlaneFit.forBaseline(line, const Size(300, 200));

    final at = fit.toCanvas(const LayoutPoint(40, 0));
    expect(at.dx.isFinite, isTrue);
    expect(at.dy.isFinite, isTrue);
    expect(fit.scale.isFinite, isTrue);
    expect(fit.scale, greaterThan(0));
  });

  test('a degenerate baseline maps to the middle rather than to NaN', () {
    final fit = LayoutPlaneFit.forBaseline(
      Baseline.empty,
      const Size(200, 100),
    );
    final at = fit.toCanvas(const LayoutPoint(0, 0));
    expect(at, const Offset(100, 50));
  });

  test('the whole stroke lands inside the box, padding included', () {
    final ring = Baseline(const [
      LayoutPoint(-20, -20),
      LayoutPoint(20, -20),
      LayoutPoint(20, 20),
      LayoutPoint(-20, 20),
    ], closed: true);
    const size = Size(300, 220);
    const padding = 40.0;
    final fit = LayoutPlaneFit.forBaseline(ring, size, padding: padding);

    for (final point in ring.points) {
      final at = fit.toCanvas(point);
      expect(at.dx, inInclusiveRange(padding - 0.001, size.width - padding + 0.001));
      expect(at.dy, inInclusiveRange(padding - 0.001, size.height - padding + 0.001));
    }
  });

  test('aspect ratio is preserved — a ring never becomes an ellipse', () {
    final ring = Baseline(const [
      LayoutPoint(0, 0),
      LayoutPoint(10, 0),
      LayoutPoint(10, 10),
      LayoutPoint(0, 10),
    ], closed: true);
    final fit = LayoutPlaneFit.forBaseline(ring, const Size(400, 150));

    final horizontal =
        (fit.toCanvas(const LayoutPoint(10, 0)) -
                fit.toCanvas(const LayoutPoint(0, 0)))
            .distance;
    final vertical =
        (fit.toCanvas(const LayoutPoint(0, 10)) -
                fit.toCanvas(const LayoutPoint(0, 0)))
            .distance;
    expect(horizontal, closeTo(vertical, 1e-9));
  });
}
