// Regression test for the view-mode route-legend "empty gap" defect: with no
// `padding:` on the `RouteLegend` `ListView.builder`, Flutter's BoxScrollView
// auto-applies the ambient device safe-area `MediaQuery.padding` (the top
// notch inset) as leading scroll padding, pushing the first route row down
// by ~40-47px — a gap roughly 2-2.5x a compact row's height. The fix is
// `padding: EdgeInsets.zero` on that ListView.
//
// Seeding follows the same real Area -> Sector -> Wall -> Photo -> Route
// repository chain as `route_legend_intent_test.dart` (`_seedRoutes` there),
// duplicated here per that file's own doc comment guidance to copy the
// pattern rather than import test-only helpers across files.
import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/topo/application/draw_controller.dart';
import 'package:masi/features/topo/data/route_repository.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
import 'package:masi/features/topo/presentation/route_legend.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

/// FIX #6 (family-keyed `drawControllerProvider(_testWallId)`): stand-in wallId, paired
/// consistently everywhere this file constructs `RouteLegend` or reads the
/// provider directly.
const _testWallId = 'test-wall';

/// Seeds [count] routes (number 1..count, ids assigned 1..count in the same
/// order by [RouteRepository.loadRoutes]) through the real Area -> Sector ->
/// Wall -> Photo -> Route repository chain, then loads them into
/// [drawControllerProvider(_testWallId)] exactly as [TopoCanvasScreen] does on open. Copy
/// of `_seedRoutes` in `route_legend_intent_test.dart`.
Future<ProviderContainer> _seedRoutes(WidgetTester tester, int count) async {
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
  // alive for the whole test via a permanent listener, mirroring what a
  // mounted RouteLegend's `ref.watch` does -- otherwise every bare
  // `container.read(...)` below (before any widget is pumped) schedules an
  // autoDispose teardown `Timer(Duration.zero, ...)` that only fires on a
  // duration-based `tester.pump`/`pumpAndSettle`; one scheduled AFTER the
  // test's last such pump is still "pending" when the test ends, tripping
  // flutter_test's `!timersPending` invariant.
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
    await routeRepo.upsertRoute(
      wall.id,
      photoId,
      TopoRoute(
        id: number,
        number: number,
        points: const [Offset(0.1, 0.1), Offset(0.2, 0.2)],
      ),
    );
  }

  await container
      .read(drawControllerProvider(_testWallId).notifier)
      .loadForWall(wall.id, photoId);

  return container;
}

/// Same shape as `_pumpLegend` in `route_legend_intent_test.dart`, but pumps
/// `RouteLegend` inside a plain `Scaffold`/`MaterialApp` — the ambient
/// `MediaQuery.padding` used to simulate the device notch/safe-area comes
/// from `tester.view.padding` (set by the caller before this runs), which
/// `MaterialApp`'s own `MediaQuery.fromView` picks up automatically.
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

void main() {
  testWidgets(
    'A1.2: with a simulated top/bottom safe-area inset, the first route row '
    'sits at the top of the legend — no ~40px safe-area gap is inserted '
    'before it',
    (tester) async {
      // Simulate a device notch (~47px top inset, matching an iPhone's
      // status bar/Dynamic Island) plus a home-indicator bottom inset
      // (~34px) as MediaQuery.padding, the same ambient padding a real
      // device supplies outside of any test.
      tester.view.devicePixelRatio = 1.0;
      tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetDevicePixelRatio);

      final container = await _seedRoutes(tester, 2);
      final routes = container.read(drawControllerProvider(_testWallId)).routes;
      expect(routes, hasLength(2));

      await _pumpLegend(tester, container);
      await tester.pump();

      final legendTop = tester
          .getTopLeft(find.byKey(const Key('topo-route-legend')))
          .dy;
      final firstRowTop = tester
          .getTopLeft(
            find.byKey(Key('topo-route-legend-item-${routes.first.id}')),
          )
          .dy;

      expect(
        (firstRowTop - legendTop).abs(),
        lessThanOrEqualTo(8.0),
        reason:
            'legend top=$legendTop, first row top=$firstRowTop — the first '
            'route row must sit right at the top of the legend list, not '
            '~40px+ below it (the safe-area gap this test guards against)',
      );
    },
  );

  testWidgets(
    'A1.3: keys, MainAxisSize.min sizing, and the maxHeight cap all still '
    'hold with the padding fix applied',
    (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPadding);

      final container = await _seedRoutes(tester, 12);
      final routes = container.read(drawControllerProvider(_testWallId)).routes;
      expect(routes, hasLength(12));

      await _pumpLegend(tester, container);
      await tester.pump();

      expect(find.byKey(const Key('topo-route-legend')), findsOneWidget);
      // `ListView.builder` is lazily virtualized, so only rows within the
      // capped viewport are actually built (same as A2c/A2h in
      // route_legend_intent_test.dart) — check the first route's key
      // directly rather than every route at once.
      expect(
        find.byKey(Key('topo-route-legend-item-${routes.first.id}')),
        findsOneWidget,
      );

      const expectedMaxHeight = 800.0 * kLegendMaxHeightFraction;
      final legendSize = tester.getSize(
        find.byKey(const Key('topo-route-legend')),
      );
      expect(
        legendSize.height,
        lessThanOrEqualTo(expectedMaxHeight + 0.5),
        reason:
            'the legend must stay capped at <= 40% of the screen height '
            'even with the padding fix',
      );
    },
  );
}
