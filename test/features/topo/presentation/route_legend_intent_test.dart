// Intended-behavior tests for [RouteLegend], derived from the SPEC (see
// `/Users/kerip/.claude/plans/masi-intended-behavior-ui-tests.md`, Subtask
// A2 / BUG-2 / F1 / E1 / G1), NOT from current code. A failing assertion
// here means the CODE is wrong relative to the spec — never weaken the
// assertion to match buggy behavior.
//
// Seeding follows `test/features/topo/application/topo_canvas_wall_binding_
// test.dart:30-77`: a real in-memory [AppDatabase] + [ProviderContainer],
// Area -> Sector -> Wall -> attachPhotoToWall via the real
// [libraryCrudRepositoryProvider], routes written with a real
// [RouteRepository.upsertRoute], then loaded into [drawControllerProvider(_testWallId)]
// via [DrawController.loadForWall] — exactly the path
// `TopoCanvasScreen._loadInitialPhotoForWall` drives in production. No
// image is ever decoded (RouteLegend never touches the photo), so plain
// `await`s inside `testWidgets` (before `pumpWidget`) are safe here, same as
// the "A4: topo-ar-button" group in `test/widget_test.dart`.
//
// [RouteLegend] is pumped in isolation (`MaterialApp(theme: MasiTheme.light,
// home: Scaffold(body: RouteLegend()))`), mirroring the existing
// `group('RouteLegend', ...)` in `test/widget_test.dart`. `theme:
// MasiTheme.light` IS required here (unlike when this doc was first
// written): `RouteLegend.build` now reads `MasiColors.of(context).accent`
// for its selected-row tint (the #15 compact-rows refinement), which throws
// a null-check failure without a `MasiColors` theme extension registered —
// every real call site (`TopoCanvasScreen`'s own `MaterialApp`) always
// supplies one, so this is purely a test-harness requirement, not a
// production concern. Toolbar-vs-legend overlap (BUG-1d) is covered by
// Subtask A1's canvas_mode_intent_test.dart, not here.
import 'package:climbtopo/app/theme.dart';
import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/core/db/database_provider.dart';
import 'package:climbtopo/core/grades/grade_system.dart';
import 'package:climbtopo/features/library/application/library_providers.dart';
import 'package:climbtopo/features/topo/application/draw_controller.dart';
import 'package:climbtopo/features/topo/data/route_repository.dart';
import 'package:climbtopo/features/topo/domain/topo_route.dart';
import 'package:climbtopo/features/topo/presentation/route_legend.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

/// FIX #6 (family-keyed `drawControllerProvider(_testWallId)`): stand-in wallId, paired
/// consistently everywhere this file constructs `RouteLegend` or reads the
/// provider directly (the real seeded wall's own id is never returned out of
/// `_seedRoutes`, so this fixed key is used for provider identity instead —
/// it doesn't need to match the real wall id, only be consistent within a
/// given test's container).
const _testWallId = 'test-wall';

/// SPEC grade-band -> color map (H6), independent of wherever
/// `grade_colors.dart` currently reads its literals from — this is the
/// contract the test asserts against, not a mirror of the implementation.
const Map<GradeBand, Color> _specBandColor = {
  GradeBand.beginner: Color(0xFF2F9E6B), // green, French <= 4 (<= '4c')
  GradeBand.intermediate: Color(0xFF3B82C4), // blue, French 5 - 6a
  GradeBand.advanced: Color(0xFFE08A2B), // orange, French 6a+ - 6c+
  GradeBand.hard: Color(0xFFD6483B), // red, French 7a - 7c+
  GradeBand.elite: Color(0xFF8A5CD1), // purple, French >= 8a
};

/// One representative French token per band, spanning the whole ladder.
const List<({String grade, GradeBand band})> _representativeGrades = [
  (grade: '4c', band: GradeBand.beginner),
  (grade: '5c', band: GradeBand.intermediate),
  (grade: '6b', band: GradeBand.advanced),
  (grade: '7a', band: GradeBand.hard),
  (grade: '8a', band: GradeBand.elite),
];

/// Seeds [count] routes (number 1..count, ids assigned 1..count in the same
/// order by [RouteRepository.loadRoutes]) through the real Area -> Sector ->
/// Wall -> Photo -> Route repository chain, then loads them into
/// [drawControllerProvider(_testWallId)] exactly as [TopoCanvasScreen] does on open.
/// [gradesByNumber] optionally assigns a French grade token to route
/// `number` (1-based); routes without an entry stay ungraded.
Future<ProviderContainer> _seedRoutes(
  WidgetTester tester,
  int count, {
  Map<int, String> gradesByNumber = const {},
}) async {
  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      nowMsProvider.overrideWithValue(() => 1000),
    ],
  );
  addTearDown(container.dispose);
  // FIX #6 (autoDispose pending-timer gotcha): keep this family member
  // alive for the whole test -- see route_legend_gap_test.dart's
  // `_seedRoutes` for the full explanation.
  container.listen(drawControllerProvider(_testWallId), (_, _) {});

  final crud = container.read(libraryCrudRepositoryProvider);
  final area = await crud.createArea('Area');
  final sector = await crud.createSector(area.id, 'Sector');
  final wall = await crud.createWall(sector.id, 'Wall');
  late String photoId;
  await tester.runAsync(() async {
    photoId = await crud.attachPhotoToWall(
      wall.id,
      XFile('/tmp/wall-photo.jpg'),
      1000,
      2000,
    );
  });

  final routeRepo = RouteRepository(db, nowMs: () => 1000);
  for (var number = 1; number <= count; number++) {
    final grade = gradesByNumber[number];
    await routeRepo.upsertRoute(
      wall.id,
      photoId,
      TopoRoute(
        id: number,
        number: number,
        points: const [Offset(0.1, 0.1), Offset(0.2, 0.2)],
        gradeSystem: grade != null ? GradeSystem.french : null,
        gradeRaw: grade,
        gradeSortKey: grade != null
            ? gradeSortKey(GradeSystem.french, grade)
            : null,
      ),
    );
  }

  await container
      .read(drawControllerProvider(_testWallId).notifier)
      .loadForWall(wall.id, photoId);

  return container;
}

Future<void> _pumpLegend(WidgetTester tester, ProviderContainer container) {
  return tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: MasiTheme.light,
        home: const Scaffold(body: RouteLegend(wallId: _testWallId)),
      ),
    ),
  );
}

void _setViewportSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Logical on-screen bounds, computed directly from the test view rather
/// than `getRect(find.byType(MaterialApp))` (which is not guaranteed to
/// correspond to a single RenderObject) — this is what "on-screen" /
/// "not clipped" means for BUG-2a.
Rect _screenRect(WidgetTester tester) {
  final size = tester.view.physicalSize / tester.view.devicePixelRatio;
  return Rect.fromLTWH(0, 0, size.width, size.height);
}

void main() {
  testWidgets(
    'A2a: with 1 route, topo-route-legend is fully within screen bounds '
    '(not clipped top or bottom) (BUG-2a)',
    (tester) async {
      final container = await _seedRoutes(tester, 1);
      await _pumpLegend(tester, container);
      await tester.pump();

      final legendRect = tester.getRect(
        find.byKey(const Key('topo-route-legend')),
      );
      final screenRect = _screenRect(tester);

      expect(
        legendRect.top,
        greaterThanOrEqualTo(screenRect.top - 0.5),
        reason: 'the legend must not be clipped above the top of the screen',
      );
      expect(
        legendRect.bottom,
        lessThanOrEqualTo(screenRect.bottom + 0.5),
        reason: 'the legend must not be clipped below the bottom of the screen',
      );
      expect(legendRect.left, greaterThanOrEqualTo(screenRect.left - 0.5));
      expect(legendRect.right, lessThanOrEqualTo(screenRect.right + 0.5));
    },
  );

  testWidgets(
    'A2b: with 12 routes, topo-route-legend height is capped at <= ~40% of '
    'the screen height (BUG-2c)',
    (tester) async {
      _setViewportSize(tester, const Size(400, 800));

      final container = await _seedRoutes(tester, 12);
      await _pumpLegend(tester, container);
      await tester.pump();

      const expectedMaxHeight = 800.0 * 0.4; // 320.0
      final legendSize = tester.getSize(
        find.byKey(const Key('topo-route-legend')),
      );

      expect(
        legendSize.height,
        lessThanOrEqualTo(expectedMaxHeight + 0.5),
        reason:
            '12 routes must cap the legend at <= 40% of the 800px screen '
            '($expectedMaxHeight px), never grow to fit every row',
      );
    },
  );

  testWidgets(
    'A2c: with 12 routes, the legend list scrolls internally and every '
    'route stays reachable (none permanently clipped) (BUG-2b)',
    (tester) async {
      _setViewportSize(tester, const Size(400, 800));

      final container = await _seedRoutes(tester, 12);
      final routes = container.read(drawControllerProvider(_testWallId)).routes;
      expect(routes, hasLength(12));

      await _pumpLegend(tester, container);
      await tester.pump();

      // The first route is visible without any scrolling.
      expect(
        find.byKey(Key('topo-route-legend-item-${routes.first.id}')),
        findsOneWidget,
      );

      // The legend's inner list is actually scrollable (this is what makes
      // "capped height" safe rather than lossy).
      expect(
        find.descendant(
          of: find.byKey(const Key('topo-route-legend')),
          matching: find.byType(Scrollable),
        ),
        findsWidgets,
      );

      // The LAST route, though off-screen initially (capped + scrolled),
      // must still be reachable by scrolling — nothing is permanently
      // clipped, just capped-and-scrollable.
      await tester.scrollUntilVisible(
        find.byKey(Key('topo-route-legend-item-${routes.last.id}')),
        200.0,
        scrollable: find.descendant(
          of: find.byKey(const Key('topo-route-legend')),
          matching: find.byType(Scrollable),
        ),
      );
      expect(
        find.byKey(Key('topo-route-legend-item-${routes.last.id}')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'A2d: tapping topo-route-visibility-<id> flips only that route\'s '
    'visibility, leaving other routes unchanged (F1)',
    (tester) async {
      final container = await _seedRoutes(tester, 3);
      final routes = container.read(drawControllerProvider(_testWallId)).routes;
      expect(routes, hasLength(3));
      final target = routes[1];

      await _pumpLegend(tester, container);
      await tester.pump();

      expect(
        container.read(drawControllerProvider(_testWallId)).routes.every((r) => r.visible),
        isTrue,
        reason: 'sanity check: every seeded route starts visible',
      );

      await tester.tap(find.byKey(Key('topo-route-visibility-${target.id}')));
      await tester.pump();

      final after = container.read(drawControllerProvider(_testWallId)).routes;
      for (final r in after) {
        if (r.id == target.id) {
          expect(r.visible, isFalse, reason: 'the tapped route must toggle');
        } else {
          expect(
            r.visible,
            isTrue,
            reason: "route ${r.id} was not tapped and must keep its visibility",
          );
        }
      }
    },
  );

  testWidgets(
    'A2e: tapping topo-route-legend-item-<id> selects that route (E1)',
    (tester) async {
      final container = await _seedRoutes(tester, 2);
      final routes = container.read(drawControllerProvider(_testWallId)).routes;
      final target = routes[0];
      final other = routes[1];

      await _pumpLegend(tester, container);
      await tester.pump();

      expect(container.read(drawControllerProvider(_testWallId)).selectedRouteId, isNull);

      await tester.tap(find.byKey(Key('topo-route-legend-item-${target.id}')));
      await tester.pump();

      expect(container.read(drawControllerProvider(_testWallId)).selectedRouteId, target.id);

      await tester.tap(find.byKey(Key('topo-route-legend-item-${other.id}')));
      await tester.pump();

      expect(
        container.read(drawControllerProvider(_testWallId)).selectedRouteId,
        other.id,
        reason: 'selecting a different item must move the selection to it',
      );
    },
  );

  testWidgets('A2f: a graded route shows its grade in the label, and the leading '
      'swatch color equals the SPEC grade-band color (H6/G1)', (tester) async {
    final gradesByNumber = <int, String>{
      for (var i = 0; i < _representativeGrades.length; i++)
        i + 1: _representativeGrades[i].grade,
    };
    final container = await _seedRoutes(
      tester,
      _representativeGrades.length,
      gradesByNumber: gradesByNumber,
    );
    final routes = container.read(drawControllerProvider(_testWallId)).routes;
    expect(routes, hasLength(_representativeGrades.length));

    await _pumpLegend(tester, container);
    await tester.pump();

    for (var i = 0; i < routes.length; i++) {
      final route = routes[i];
      final expected = _representativeGrades[i];
      expect(route.gradeRaw, expected.grade);

      expect(
        find.text('Route ${route.number} • ${expected.grade}'),
        findsOneWidget,
        reason:
            'the label for route ${route.number} must contain its grade '
            'text (${expected.grade})',
      );

      final avatar = tester.widget<CircleAvatar>(
        find.descendant(
          of: find.byKey(Key('topo-route-legend-item-${route.id}')),
          matching: find.byType(CircleAvatar),
        ),
      );
      final expectedColor = _specBandColor[expected.band]!;
      expect(
        avatar.backgroundColor?.toARGB32(),
        expectedColor.toARGB32(),
        reason:
            'grade ${expected.grade} (band ${expected.band}) must render '
            'the SPEC band color 0x${expectedColor.toARGB32().toRadixString(16)}',
      );
    }
  });

  testWidgets(
    'A2g: tapping topo-route-delete-<id> removes exactly that route',
    (tester) async {
      final container = await _seedRoutes(tester, 3);
      final routes = container.read(drawControllerProvider(_testWallId)).routes;
      final target = routes[1];
      final survivorIds = routes
          .where((r) => r.id != target.id)
          .map((r) => r.id)
          .toSet();

      await _pumpLegend(tester, container);
      await tester.pump();

      await tester.tap(find.byKey(Key('topo-route-delete-${target.id}')));
      await tester.pump();

      final after = container.read(drawControllerProvider(_testWallId)).routes;
      expect(after, hasLength(2));
      expect(
        after.map((r) => r.id).toSet(),
        survivorIds,
        reason:
            'only the tapped route should be removed; the other two '
            'routes must survive untouched',
      );
      expect(after.any((r) => r.id == target.id), isFalse);
    },
  );

  testWidgets(
    'A2h (#15): rows are compact — dense ListTile + VisualDensity.compact, '
    'small trailing IconButtons with their default 48px tap-target '
    'constraint removed — so the capped legend height comfortably fits '
    'MORE than ~2 rows, keys unchanged',
    (tester) async {
      _setViewportSize(tester, const Size(400, 800));
      final container = await _seedRoutes(tester, 6);
      await _pumpLegend(tester, container);
      await tester.pump();

      final routes = container.read(drawControllerProvider(_testWallId)).routes;
      final firstId = routes.first.id;

      final tile = tester.widget<ListTile>(
        find.byKey(Key('topo-route-legend-item-$firstId')),
      );
      expect(
        tile.dense,
        isTrue,
        reason: 'rows must be dense to reduce vertical rhythm',
      );
      expect(
        tile.visualDensity,
        VisualDensity.compact,
        reason: 'rows must use VisualDensity.compact',
      );

      final visibilityButton = tester.widget<IconButton>(
        find.byKey(Key('topo-route-visibility-$firstId')),
      );
      expect(
        visibilityButton.constraints,
        const BoxConstraints(),
        reason:
            'the visibility toggle must drop the default 48px '
            'kMinInteractiveDimension tap-target constraint to shrink to '
            'its padded icon size',
      );
      final deleteButton = tester.widget<IconButton>(
        find.byKey(Key('topo-route-delete-$firstId')),
      );
      expect(
        deleteButton.constraints,
        const BoxConstraints(),
        reason: 'the delete button must drop the same default constraint',
      );

      // Keys must be unchanged (still findable, still functional — see the
      // A2d/A2e/A2g groups above for the functional behavior itself).
      expect(find.byKey(const Key('topo-route-legend')), findsOneWidget);
      for (final route in routes) {
        expect(
          find.byKey(Key('topo-route-legend-item-${route.id}')),
          findsOneWidget,
        );
      }

      // The actual "fits more than ~2 rows" claim: a single row's rendered
      // height must be small enough that the legend's own capped height
      // (still ~40% of the 800px screen, per A2b above) fits more than 2 of
      // them — this is what "the route list looks squished" was fixed
      // against: the previous default-ListTile row was tall enough that
      // the ~320px cap barely fit two.
      final rowHeight = tester
          .getSize(find.byKey(Key('topo-route-legend-item-$firstId')))
          .height;
      final legendHeight = tester
          .getSize(find.byKey(const Key('topo-route-legend')))
          .height;
      expect(
        legendHeight / rowHeight,
        greaterThan(2),
        reason:
            'row height=$rowHeight, legend height=$legendHeight — the '
            'capped legend must comfortably fit more than 2 compact rows',
      );
    },
  );
}
