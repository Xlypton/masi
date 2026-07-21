// Widget tests for RouteLegend.onLogAscent (masi-log-ascent-own-routes
// plan, Subtask 1 / assertions A3, A4, A7): the per-route "log ascent"
// icon button that makes ascent-logging discoverable from the user's own
// topo canvas legend, not just the community detail screen.
//
// Seeding duplicates the real Area -> Sector -> Wall -> Photo -> Route
// repository chain used by `route_legend_intent_test.dart`'s `_seedRoutes`
// (per that file's own doc comment guidance to copy the pattern rather than
// import test-only helpers across files).
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
/// provider directly.
const _testWallId = 'test-wall';

Future<ProviderContainer> _seedRoutes(
  WidgetTester tester,
  int count, {
  Map<int, String> gradesByNumber = const {},
  GradeSystem gradeSystem = GradeSystem.french,
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
      XFile('/tmp/route-legend-log-ascent-test-photo.jpg'),
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
        gradeSystem: grade != null ? gradeSystem : null,
        gradeRaw: grade,
        gradeSortKey: grade != null ? gradeSortKey(gradeSystem, grade) : null,
      ),
    );
  }

  await container
      .read(drawControllerProvider(_testWallId).notifier)
      .loadForWall(wall.id, photoId);

  return container;
}

Future<void> _pumpLegend(
  WidgetTester tester,
  ProviderContainer container, {
  bool readOnly = false,
  void Function(int routeId)? onLogAscent,
}) {
  return tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: MasiTheme.light,
        home: Scaffold(
          body: RouteLegend(
            wallId: _testWallId,
            readOnly: readOnly,
            onLogAscent: onLogAscent,
          ),
        ),
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

void main() {
  testWidgets('A3: with onLogAscent set and !readOnly, each row shows '
      'topo-log-ascent-<routeId>, and tapping it invokes the callback with '
      "that route's real (persisted) TopoRoute.id", (tester) async {
    final container = await _seedRoutes(tester, 3);
    final routes = container.read(drawControllerProvider(_testWallId)).routes;
    expect(routes, hasLength(3));

    final tapped = <int>[];
    await _pumpLegend(
      tester,
      container,
      onLogAscent: (routeId) => tapped.add(routeId),
    );
    await tester.pump();

    for (final route in routes) {
      expect(
        find.byKey(Key('topo-log-ascent-${route.id}')),
        findsOneWidget,
        reason: 'route ${route.id} must show its own log-ascent button',
      );
    }

    final target = routes[1];
    await tester.tap(find.byKey(Key('topo-log-ascent-${target.id}')));
    await tester.pump();

    expect(
      tapped,
      [target.id],
      reason:
          'tapping row ${target.id}\'s log-ascent button must invoke the '
          'callback with exactly that id, not an index or a different '
          "route's id",
    );

    // Tapping a different row's button passes THAT row's id.
    final other = routes[0];
    await tester.tap(find.byKey(Key('topo-log-ascent-${other.id}')));
    await tester.pump();
    expect(tapped, [target.id, other.id]);
  });

  testWidgets('A4: when readOnly == true, no log-ascent button renders even if '
      'onLogAscent is provided', (tester) async {
    final container = await _seedRoutes(tester, 2);
    final routes = container.read(drawControllerProvider(_testWallId)).routes;

    await _pumpLegend(tester, container, readOnly: true, onLogAscent: (_) {});
    await tester.pump();

    for (final route in routes) {
      expect(find.byKey(Key('topo-log-ascent-${route.id}')), findsNothing);
    }
    // The other two editing affordances stay hidden too (existing
    // readOnly contract, unaffected by this change).
    expect(
      find.byKey(Key('topo-route-visibility-${routes.first.id}')),
      findsNothing,
    );
    expect(
      find.byKey(Key('topo-route-delete-${routes.first.id}')),
      findsNothing,
    );
  });

  testWidgets(
    'A4b: with onLogAscent == null (existing call sites unchanged), no '
    'log-ascent button renders, even with readOnly == false',
    (tester) async {
      final container = await _seedRoutes(tester, 1);
      final routes = container.read(drawControllerProvider(_testWallId)).routes;

      await _pumpLegend(tester, container);
      await tester.pump();

      expect(
        find.byKey(Key('topo-log-ascent-${routes.single.id}')),
        findsNothing,
      );
      // The pre-existing controls are untouched.
      expect(
        find.byKey(Key('topo-route-visibility-${routes.single.id}')),
        findsOneWidget,
      );
      expect(
        find.byKey(Key('topo-route-delete-${routes.single.id}')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'A7: with a graded route using the WIDEST realistic grade token (UIAA '
    "'VIII+', 5 chars vs. French's max 3) and all three trailing icons "
    '(log-ascent + visibility + delete) at a realistic 375px-wide '
    "viewport, the title stays single-line (elided, not wrapped) — proof "
    "the overflow guard actually engages for this row rather than merely "
    'fitting with slack.\n'
    '\n'
    'Note on what "overflow" means here: `ListTile` computes its own '
    'height as `max(target, titleHeight + padding)` (see Flutter SDK '
    '`list_tile.dart`), so it silently GROWS to fit a wrapped title rather '
    'than throwing a catchable `RenderFlex` exception — and it is hosted '
    'in a scrollable `ListView`, which structurally never overflow-'
    "asserts either. So `tester.takeException()` alone can't distinguish "
    "with/without the fix (confirmed empirically: it stays null even with "
    "the fix disabled, for grade strings up to 40 chars and textScale up "
    "to 3.0x). The real, measurable effect of `maxLines:1` + ellipsis is "
    "row HEIGHT: this test's own teeth-check (temporarily commenting out "
    "the fix in route_legend.dart, see PR notes) showed this exact "
    'row — same 375px width, same \'VIII+\' grade, same 3 icons — at '
    '40px tall WITH the fix vs. 64px (a wrapped 2nd line) WITHOUT it. '
    'That 40-vs-64 split is what the height assertion below pins down.',
    (tester) async {
      _setViewportSize(tester, const Size(375, 812));

      final container = await _seedRoutes(
        tester,
        1,
        gradesByNumber: {1: 'VIII+'},
        gradeSystem: GradeSystem.uiaa,
      );

      await _pumpLegend(tester, container, onLogAscent: (_) {});
      await tester.pump();

      expect(tester.takeException(), isNull);

      final routes = container.read(drawControllerProvider(_testWallId)).routes;
      expect(
        find.byKey(Key('topo-log-ascent-${routes.single.id}')),
        findsOneWidget,
      );
      expect(
        find.byKey(Key('topo-route-visibility-${routes.single.id}')),
        findsOneWidget,
      );
      expect(
        find.byKey(Key('topo-route-delete-${routes.single.id}')),
        findsOneWidget,
      );

      // The row itself must fit within the 375px viewport width (no
      // horizontal RenderFlex overflow smuggled past takeException by
      // clipping).
      final rowSize = tester.getSize(
        find.byKey(Key('topo-route-legend-item-${routes.single.id}')),
      );
      expect(rowSize.width, lessThanOrEqualTo(375.0 + 0.5));

      // The teeth: without `maxLines: 1` + ellipsis, this exact row (375px,
      // 'VIII+', 3 trailing icons) wraps to a 2nd line and grows to ~64px
      // (measured directly against this test's own fixture — see doc
      // above). 50px sits strictly between the observed 40px (single-line,
      // fix present) and 64px (wrapped, fix removed), so this assertion
      // fails without the fix and passes with it.
      expect(
        rowSize.height,
        lessThan(50.0),
        reason:
            "the title must stay single-line (elided) for this row's "
            'widest realistic grade token — a wrapped 2nd line would push '
            'the row height to ~64px, well past this threshold',
      );
    },
  );
}
