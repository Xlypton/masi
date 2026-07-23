import 'package:masi/features/ar/domain/rock_box.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('rockBoxFromRoutes', () {
    test('(a) empty routes -> null', () {
      expect(rockBoxFromRoutes(const []), isNull);
    });

    test(
      '(a) routes with no points and no symbols at all -> null',
      () {
        const route = TopoRoute(id: 1, number: 1, points: []);
        expect(rockBoxFromRoutes(const [route]), isNull);
      },
    );

    test(
      '(b) a single near-vertical route produces a box whose WIDTH is at '
      'least kRockBoxMinAspect * HEIGHT (not a thin sliver), centered on '
      'the route\'s x',
      () {
        const route = TopoRoute(
          id: 1,
          number: 1,
          points: [Offset(0.5, 0.2), Offset(0.5, 0.7)],
        );

        final box = rockBoxFromRoutes(const [route]);

        expect(box, isNotNull);
        expect(
          box!.width,
          greaterThanOrEqualTo(kRockBoxMinAspect * box.height - 1e-9),
          reason:
              'a near-vertical route must not collapse into an unusably '
              'thin sliver box',
        );
        expect(box.center.dx, closeTo(0.5, 1e-9));
        // Sanity: the route's own vertical extent is still (at least)
        // covered, with padding beyond it.
        expect(box.top, lessThan(0.2));
        expect(box.bottom, greaterThan(0.7));
      },
    );

    test(
      '(b) symmetric case: a single near-horizontal route produces a box '
      'whose HEIGHT is at least kRockBoxMinAspect * WIDTH, centered on the '
      "route's y",
      () {
        const route = TopoRoute(
          id: 1,
          number: 1,
          points: [Offset(0.2, 0.5), Offset(0.7, 0.5)],
        );

        final box = rockBoxFromRoutes(const [route]);

        expect(box, isNotNull);
        expect(
          box!.height,
          greaterThanOrEqualTo(kRockBoxMinAspect * box.width - 1e-9),
        );
        expect(box.center.dy, closeTo(0.5, 1e-9));
      },
    );

    test(
      '(c) multiple routes (incl. symbols) -> the padded bounding box '
      'contains every point/symbol across all routes',
      () {
        const routeA = TopoRoute(
          id: 1,
          number: 1,
          points: [Offset(0.3, 0.4), Offset(0.35, 0.42)],
        );
        const routeB = TopoRoute(
          id: 2,
          number: 2,
          points: [Offset(0.6, 0.5)],
          symbols: [
            TopoSymbol(type: SymbolType.anchor, position: Offset(0.65, 0.55)),
          ],
        );

        final box = rockBoxFromRoutes(const [routeA, routeB]);

        expect(box, isNotNull);
        // Contains every point/symbol across both routes -- padding only
        // ever grows the box outward from the raw bounding box, never
        // shrinks it.
        expect(box!.left, lessThanOrEqualTo(0.3));
        expect(box.top, lessThanOrEqualTo(0.4));
        expect(box.right, greaterThanOrEqualTo(0.65));
        expect(box.bottom, greaterThanOrEqualTo(0.55));
        // And it's a real pad, not just the exact bbox.
        expect(box.left, lessThan(0.3));
        expect(box.top, lessThan(0.4));
        expect(box.right, greaterThan(0.65));
        expect(box.bottom, greaterThan(0.55));
      },
    );

    test(
      '(d) a degenerate single-point route produces a fixed ~0.24-wide box '
      '(2 * kRockBoxPointHalf) centered on that point',
      () {
        const route = TopoRoute(
          id: 1,
          number: 1,
          points: [Offset(0.5, 0.5)],
        );

        final box = rockBoxFromRoutes(const [route]);

        expect(box, isNotNull);
        expect(box!.width, closeTo(2 * kRockBoxPointHalf, 1e-9));
        expect(box.height, closeTo(2 * kRockBoxPointHalf, 1e-9));
        expect(box.center.dx, closeTo(0.5, 1e-9));
        expect(box.center.dy, closeTo(0.5, 1e-9));
      },
    );

    test(
      '(d) several coincident points across routes are ALSO degenerate '
      '(zero extent), not just a literal single point',
      () {
        const routeA = TopoRoute(
          id: 1,
          number: 1,
          points: [Offset(0.3, 0.3)],
        );
        const routeB = TopoRoute(
          id: 2,
          number: 2,
          points: [Offset(0.3, 0.3), Offset(0.3, 0.3)],
        );

        final box = rockBoxFromRoutes(const [routeA, routeB]);

        expect(box, isNotNull);
        expect(box!.width, closeTo(2 * kRockBoxPointHalf, 1e-9));
        expect(box.center.dx, closeTo(0.3, 1e-9));
      },
    );

    test(
      '(e) points near the (0,0) corner: the padded box is clamped, never '
      'negative',
      () {
        const route = TopoRoute(
          id: 1,
          number: 1,
          points: [Offset(0.0, 0.0), Offset(0.05, 0.02)],
        );

        final box = rockBoxFromRoutes(const [route]);

        expect(box, isNotNull);
        expect(box!.left, greaterThanOrEqualTo(0));
        expect(box.top, greaterThanOrEqualTo(0));
        expect(box.left, 0);
        expect(box.top, 0);
      },
    );

    test(
      '(e) points near the (1,1) corner: the padded box is clamped, never '
      'past 1',
      () {
        const route = TopoRoute(
          id: 1,
          number: 1,
          points: [Offset(0.95, 0.98), Offset(1.0, 1.0)],
        );

        final box = rockBoxFromRoutes(const [route]);

        expect(box, isNotNull);
        expect(box!.right, lessThanOrEqualTo(1));
        expect(box.bottom, lessThanOrEqualTo(1));
        expect(box.right, 1);
        expect(box.bottom, 1);
      },
    );
  });

  group('rockBoxCornersNorm', () {
    test('returns the 4 corners in TL, TR, BR, BL order', () {
      const box = Rect.fromLTRB(0.1, 0.2, 0.8, 0.9);

      final corners = rockBoxCornersNorm(box);

      expect(corners, const <Offset>[
        Offset(0.1, 0.2),
        Offset(0.8, 0.2),
        Offset(0.8, 0.9),
        Offset(0.1, 0.9),
      ]);
    });
  });
}
