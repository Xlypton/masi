import 'package:masi/features/topo/domain/route_hit_test.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('hitTestRoute basic hits (A1)', () {
    test('tap exactly on a segment midpoint returns that route id', () {
      const route = TopoRoute(
        id: 7,
        number: 1,
        points: [Offset(0.0, 0.0), Offset(1.0, 0.0)],
      );

      final result = hitTestRoute(
        const Offset(0.5, 0.0),
        [route],
        0.05,
      );

      expect(result, 7);
    });
  });

  group('hitTestRoute misses (A2)', () {
    test('tap far from all routes beyond threshold returns null', () {
      const route = TopoRoute(
        id: 1,
        number: 1,
        points: [Offset(0.0, 0.0), Offset(1.0, 0.0)],
      );

      final result = hitTestRoute(
        const Offset(0.5, 10.0),
        [route],
        0.05,
      );

      expect(result, isNull);
    });
  });

  group('hitTestRoute nearest-route selection (A3)', () {
    test('nearer route wins; moving tap closer to other route flips result', () {
      const routeA = TopoRoute(
        id: 1,
        number: 1,
        points: [Offset(0.0, 0.0), Offset(0.0, 1.0)],
      );
      const routeB = TopoRoute(
        id: 2,
        number: 2,
        points: [Offset(1.0, 0.0), Offset(1.0, 1.0)],
      );
      final routes = [routeA, routeB];

      final nearA = hitTestRoute(const Offset(0.1, 0.5), routes, 0.5);
      expect(nearA, 1);

      final nearB = hitTestRoute(const Offset(0.9, 0.5), routes, 0.5);
      expect(nearB, 2);
    });
  });

  group('hitTestRoute visibility (A4)', () {
    test('invisible route is never returned even if tap lies exactly on it', () {
      const route = TopoRoute(
        id: 3,
        number: 1,
        points: [Offset(0.0, 0.0), Offset(1.0, 0.0)],
        visible: false,
      );

      final result = hitTestRoute(
        const Offset(0.5, 0.0),
        [route],
        0.05,
      );

      expect(result, isNull);
    });
  });

  group('hitTestRoute perpendicular foot outside segment (A5)', () {
    test('foot beyond endpoint clamps to nearer endpoint distance', () {
      const route = TopoRoute(
        id: 9,
        number: 1,
        points: [Offset(0.0, 0.0), Offset(0.5, 0.0)],
      );

      // Nearest point on segment to (1.0, 0.0) is endpoint (0.5, 0.0),
      // distance 0.5. Threshold just above 0.5 should hit; just below should
      // not.
      final hit = hitTestRoute(const Offset(1.0, 0.0), [route], 0.5);
      expect(hit, 9);

      final miss = hitTestRoute(const Offset(1.0, 0.0), [route], 0.49);
      expect(miss, isNull);
    });
  });

  group('hitTestRoute zero-length segment', () {
    test('route with two identical points does not throw and hits at that point', () {
      const route = TopoRoute(
        id: 4,
        number: 1,
        points: [Offset(0.3, 0.3), Offset(0.3, 0.3)],
      );

      expect(
        () => hitTestRoute(const Offset(0.3, 0.3), [route], 0.01),
        returnsNormally,
      );

      final result = hitTestRoute(const Offset(0.3, 0.3), [route], 0.01);
      expect(result, 4);

      final miss = hitTestRoute(const Offset(0.9, 0.9), [route], 0.01);
      expect(miss, isNull);
    });
  });

  group('hitTestRoute single-point route', () {
    test('uses point-to-point distance', () {
      const route = TopoRoute(
        id: 5,
        number: 1,
        points: [Offset(0.2, 0.2)],
      );

      final hit = hitTestRoute(const Offset(0.21, 0.2), [route], 0.02);
      expect(hit, 5);

      final miss = hitTestRoute(const Offset(0.5, 0.5), [route], 0.02);
      expect(miss, isNull);
    });
  });

  group('hitTestRoute exact tie tie-break', () {
    test('on exact-equal distance, the lower id wins regardless of list order', () {
      const routeLow = TopoRoute(
        id: 1,
        number: 1,
        points: [Offset(0.0, 0.0), Offset(0.0, 1.0)],
      );
      const routeHigh = TopoRoute(
        id: 2,
        number: 2,
        points: [Offset(1.0, 0.0), Offset(1.0, 1.0)],
      );

      // Tap equidistant (0.5) from both vertical routes at x=0 and x=1.
      final tap = Offset(0.5, 0.5);

      final resultInOrder = hitTestRoute(tap, [routeLow, routeHigh], 0.5);
      expect(resultInOrder, 1);

      final resultReversed = hitTestRoute(tap, [routeHigh, routeLow], 0.5);
      expect(resultReversed, 1);
    });
  });
}
