import 'dart:ui';

import 'package:flutter/widgets.dart' show Matrix4;
import 'package:flutter_test/flutter_test.dart';

import 'package:climbtopo/core/coordinates/coordinate_transformer.dart';

void main() {
  group('percentToScene', () {
    test('A1: maps center percent to center scene point', () {
      final result = CoordinateTransformer.percentToScene(
        const Offset(0.5, 0.5),
        const Size(1000, 800),
      );
      expect(result.dx, closeTo(500, 1e-9));
      expect(result.dy, closeTo(400, 1e-9));
    });

    test('maps origin and far corner correctly', () {
      const size = Size(1000, 800);
      expect(
        CoordinateTransformer.percentToScene(Offset.zero, size),
        Offset.zero,
      );
      final farCorner = CoordinateTransformer.percentToScene(
        const Offset(1, 1),
        size,
      );
      expect(farCorner.dx, closeTo(1000, 1e-9));
      expect(farCorner.dy, closeTo(800, 1e-9));
    });
  });

  group('sceneToPercent', () {
    test('A2: round-trips through percentToScene within 1e-9', () {
      const size = Size(1234.5, 987.6);
      const points = [
        Offset(0.0, 0.0),
        Offset(1.0, 1.0),
        Offset(0.5, 0.5),
        Offset(0.1, 0.9),
        Offset(0.3333333, 0.6666667),
        Offset(0.999999, 0.000001),
      ];
      for (final p in points) {
        final scene = CoordinateTransformer.percentToScene(p, size);
        final back = CoordinateTransformer.sceneToPercent(scene, size);
        expect(back.dx, closeTo(p.dx, 1e-9), reason: 'dx for $p');
        expect(back.dy, closeTo(p.dy, 1e-9), reason: 'dy for $p');
      }
    });

    test('a zero-area imageSize does not produce Infinity/NaN', () {
      final result = CoordinateTransformer.sceneToPercent(
        const Offset(10, 10),
        Size.zero,
      );
      expect(result.dx.isFinite, isTrue, reason: 'dx for Size.zero');
      expect(result.dy.isFinite, isTrue, reason: 'dy for Size.zero');
      expect(result, const Offset(0.0, 0.0));
    });

    test('guards only the zero axis when a single dimension is zero', () {
      final zeroWidth = CoordinateTransformer.sceneToPercent(
        const Offset(10, 20),
        const Size(0, 100),
      );
      expect(zeroWidth.dx, 0.0);
      expect(zeroWidth.dy, closeTo(0.2, 1e-9));

      final zeroHeight = CoordinateTransformer.sceneToPercent(
        const Offset(10, 20),
        const Size(100, 0),
      );
      expect(zeroHeight.dx, closeTo(0.1, 1e-9));
      expect(zeroHeight.dy, 0.0);
    });
  });

  group('screenToScene', () {
    test(
        'A3: inverts a scale(2) then translate(100,50) transform '
        'for a known screen point', () {
      // Transform built as: identity -> scale(2.0) -> translate(100, 50).
      //
      // vector_math's Matrix4.scale/translate post-multiply the *current*
      // matrix (M := M * S, then M := M * T), so the resulting matrix is:
      //   M = I * S(2,2,2,1) * T(100,50,0)
      //     = [ 2 0 0 200 ]
      //       [ 0 2 0 100 ]
      //       [ 0 0 2   0 ]
      //       [ 0 0 0   1 ]
      // which maps a scene point (x, y) to screen (2x + 200, 2y + 100).
      // This was verified by hand-expanding scaleByDouble/translateByDouble
      // in package:vector_math's Matrix4 implementation.
      final transform = Matrix4.identity()
        ..scaleByDouble(2.0, 2.0, 2.0, 1.0)
        ..translateByDouble(100.0, 50.0, 0.0, 1.0);

      const scenePoint = Offset(30, 20);
      // Hand-computed forward point using the matrix derived above.
      const screenPoint = Offset(2 * 30 + 200, 2 * 20 + 100); // (260, 140)

      final recovered = CoordinateTransformer.screenToScene(
        screenPoint,
        transform,
      );

      expect(recovered.dx, closeTo(scenePoint.dx, 1e-9));
      expect(recovered.dy, closeTo(scenePoint.dy, 1e-9));
    });

    test('handles a non-invertible (singular) transform gracefully', () {
      // A matrix that collapses everything to zero scale is singular.
      final singular = Matrix4.identity()..scaleByDouble(0.0, 0.0, 0.0, 1.0);
      const screenPoint = Offset(42, 24);

      // Documented behavior: return the input point unchanged rather than
      // throwing or returning NaN/Infinity.
      final result = CoordinateTransformer.screenToScene(
        screenPoint,
        singular,
      );

      expect(result, screenPoint);
    });

    test('handles a transform that collapses a single axis gracefully', () {
      // Scaling the y axis to zero collapses the matrix onto a plane,
      // which is also non-invertible (determinant 0) even though the
      // other axes are untouched.
      final collapsed = Matrix4.identity()
        ..scaleByDouble(1.0, 0.0, 1.0, 1.0);
      const screenPoint = Offset(42, 24);

      final result = CoordinateTransformer.screenToScene(
        screenPoint,
        collapsed,
      );

      expect(result, screenPoint);
    });
  });
}
