import 'package:flutter_test/flutter_test.dart';
import 'package:masi/features/topo/domain/face_layout/baseline.dart';
import 'package:masi/features/topo/domain/face_layout/face_layout_input.dart';
import 'package:masi/features/topo/domain/face_layout/layout_resolver.dart';

/// Which SIDE of a closed line thumbnails float off.
///
/// With no compass tag anywhere — the ordinary case, since most phones write
/// none — the sign used to fall back to a flat `1`, which is inward for a
/// counter-clockwise ring. Half of all boulders therefore sent every
/// thumbnail to the centre of their own ring, where they stacked into one
/// unreadable pile. The tie is decidable from the winding alone, and these
/// tests hold it: whichever way the contributor traced the rock, the
/// thumbnails end up outside it.
void main() {
  List<FaceInput> facesWithoutMetadata(int n) => [
    for (var i = 0; i < n; i++) FaceInput(id: 'f$i', captureOrder: i),
  ];

  /// How far outward each thumbnail's direction points, measured from the
  /// ring's centroid. Positive is away from the middle.
  List<double> outwardness(LayoutResult layout) {
    final points = layout.baseline.points;
    final centroid = LayoutPoint(
      points.map((p) => p.x).reduce((a, b) => a + b) / points.length,
      points.map((p) => p.y).reduce((a, b) => a + b) / points.length,
    );
    return [
      for (final face in layout.faces)
        layout.baseline.normalAt(face.t)!.dot(
          layout.baseline.pointAt(face.t) - centroid,
        ) *
            layout.thumbnailNormalSign,
    ];
  }

  test('thumbnails sit outside a counter-clockwise ring', () {
    final layout = resolveLayout(
      faces: facesWithoutMetadata(4),
      baseline: Baseline(const [
        LayoutPoint(-5, -5),
        LayoutPoint(5, -5),
        LayoutPoint(5, 5),
        LayoutPoint(-5, 5),
      ], closed: true),
    );

    expect(layout.isLoop, isTrue);
    for (final value in outwardness(layout)) {
      expect(value, greaterThan(0));
    }
  });

  test('thumbnails sit outside a clockwise ring too', () {
    final layout = resolveLayout(
      faces: facesWithoutMetadata(4),
      baseline: Baseline(const [
        LayoutPoint(-5, 5),
        LayoutPoint(5, 5),
        LayoutPoint(5, -5),
        LayoutPoint(-5, -5),
      ], closed: true),
    );

    for (final value in outwardness(layout)) {
      expect(value, greaterThan(0));
    }
  });

  test('an open strip keeps one consistent side', () {
    final layout = resolveLayout(
      faces: facesWithoutMetadata(3),
      baseline: Baseline(const [
        LayoutPoint(0, 0),
        LayoutPoint(10, 0),
        LayoutPoint(20, 0),
      ]),
    );

    expect(layout.isLoop, isFalse);
    expect(layout.thumbnailNormalSign, 1);
  });
}
