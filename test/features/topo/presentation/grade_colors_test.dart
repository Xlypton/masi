// Pure-function tests for grade_colors.dart's `colorForGradeBand` /
// `colorForRoute` — the CANONICAL grade-band color mapping this feature
// collapsed `logbook_screen.dart`'s and `community_feed_screen.dart`'s
// private `_colorForGradeBand` copies onto (both now delegate here instead
// of hand-maintaining their own copy of this switch). These assertions are
// the "did the dedup change any color value" guard: the five literals here
// are exactly what shipped before the collapse.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/core/grades/grade_system.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
import 'package:masi/features/topo/presentation/grade_colors.dart';
import 'package:masi/features/topo/presentation/route_palette.dart';

void main() {
  group('colorForGradeBand', () {
    test('returns the five documented band literals, unchanged by the dedup', () {
      expect(colorForGradeBand(GradeBand.beginner), const Color(0xFF2F9E6B));
      expect(colorForGradeBand(GradeBand.intermediate), const Color(0xFF3B82C4));
      expect(colorForGradeBand(GradeBand.advanced), const Color(0xFFE08A2B));
      expect(colorForGradeBand(GradeBand.hard), const Color(0xFFD6483B));
      expect(colorForGradeBand(GradeBand.elite), const Color(0xFF8A5CD1));
    });

    test('every band maps to a distinct color', () {
      final colors = GradeBand.values.map(colorForGradeBand).toSet();
      expect(colors, hasLength(GradeBand.values.length));
    });
  });

  group('colorForRoute', () {
    const points = [Offset(0.1, 0.1), Offset(0.2, 0.2)];

    test('a graded route gets its grade band color, not a palette color', () {
      // French '7a' -> sort key 13.0 -> GradeBand.hard (index 13 is the
      // first "hard" rung — see grade_system.dart's `_hardMax` doc).
      const route = TopoRoute(
        id: 1,
        number: 1,
        points: points,
        colorIndex: 0,
        gradeSortKey: 13.0,
      );
      expect(colorForRoute(route, kRoutePalette), colorForGradeBand(GradeBand.hard));
      // And NOT the palette color its colorIndex would otherwise pick.
      expect(colorForRoute(route, kRoutePalette), isNot(kRoutePalette[0]));
    });

    test('two routes in different grade bands render different colors', () {
      const beginnerRoute = TopoRoute(
        id: 1,
        number: 1,
        points: points,
        gradeSortKey: 0.0, // French '3' -> beginner
      );
      const eliteRoute = TopoRoute(
        id: 2,
        number: 2,
        points: points,
        gradeSortKey: 25.0, // French '9a' -> elite
      );
      expect(
        colorForRoute(beginnerRoute, kRoutePalette),
        isNot(colorForRoute(eliteRoute, kRoutePalette)),
      );
    });

    test('an ungraded route falls back to its palette colorIndex color, and does not crash', () {
      const route = TopoRoute(
        id: 1,
        number: 1,
        points: points,
        colorIndex: 2,
      );
      expect(colorForRoute(route, kRoutePalette), kRoutePalette[2]);
    });

    test('an ungraded route wraps colorIndex via % against the palette length', () {
      final route = TopoRoute(
        id: 1,
        number: 1,
        points: points,
        colorIndex: kRoutePalette.length + 3,
      );
      expect(
        colorForRoute(route, kRoutePalette),
        kRoutePalette[3 % kRoutePalette.length],
      );
    });

    test('an ungraded route against an empty palette falls back to the default color, and does not crash', () {
      const route = TopoRoute(id: 1, number: 1, points: points, colorIndex: 0);
      expect(colorForRoute(route, const []), const Color(0xFF2E7D32));
    });
  });

  group('GradeBandDot', () {
    testWidgets('paints a CircleAvatar with the given color', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: GradeBandDot(color: Color(0xFFD6483B), radius: 6),
          ),
        ),
      );

      final avatar = tester.widget<CircleAvatar>(find.byType(CircleAvatar));
      expect(avatar.backgroundColor, const Color(0xFFD6483B));
      expect(avatar.radius, 6);
    });
  });
}
