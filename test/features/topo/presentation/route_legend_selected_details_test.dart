// Selecting a route in [RouteLegend] expands its row to the details that do
// not fit on one line — its description, and its freeform style note (user
// request, 2026-08-11: "when a route is selected show the details like
// description etc").
//
// The two halves of the claim are equally load-bearing:
//   * a SELECTED route with a description shows it, so the legend is a place
//     you can actually read a topo from rather than a list of numbers;
//   * an UNSELECTED route does NOT, because the legend has a hard height cap
//     (`kLegendMaxHeightFraction`) and every route's description at once
//     would fill it with the second route, hiding the rest.
//
// Seeding mirrors `route_legend_intent_test.dart`'s `_seedRoutes` — a real
// in-memory DB through the real Area -> Sector -> Wall -> Photo -> Route
// repository chain, then `loadForWall`, exactly the path
// `TopoCanvasScreen._loadInitialPhotoForWall` drives in production. No image
// is ever decoded (RouteLegend never touches the photo).

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

const _testWallId = 'test-wall';

const _description =
    'Start matched on the low jug, then a long move to the sloper rail.';
const _style = 'Sit start';

Future<ProviderContainer> _seedTwoDescribedRoutes(WidgetTester tester) async {
  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      nowMsProvider.overrideWithValue(() => 1000),
    ],
  );
  addTearDown(container.dispose);
  // FIX #6 (autoDispose pending-timer gotcha) — see route_legend_gap_test.dart.
  container.listen(drawControllerProvider(_testWallId), (_, _) {});

  final crud = container.read(libraryCrudRepositoryProvider);
  final area = await crud.createArea('Area');
  final sector = await crud.createSector(area.id, 'Sector');
  final wall = await crud.createWall(sector.id, 'Wall');
  late String photoId;
  await tester.runAsync(() async {
    photoId = await crud.attachPhotoToWall(
      wall.id,
      XFile('/tmp/selected-details-photo.jpg'),
      1000,
      2000,
    );
  });

  final routeRepo = RouteRepository(db, nowMs: () => 1000);
  for (var number = 1; number <= 2; number++) {
    await routeRepo.upsertRoute(
      wall.id,
      photoId,
      TopoRoute(
        id: number,
        number: number,
        points: const [Offset(0.1, 0.1), Offset(0.2, 0.2)],
        description: _description,
        style: _style,
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
}) {
  return tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: MasiTheme.light,
        home: Scaffold(
          body: RouteLegend(wallId: _testWallId, readOnly: readOnly),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
    'with nothing selected, no route shows its description or style note',
    (tester) async {
      final container = await _seedTwoDescribedRoutes(tester);
      await _pumpLegend(tester, container);
      await tester.pumpAndSettle();

      expect(
        container.read(drawControllerProvider(_testWallId)).selectedRouteId,
        isNull,
      );
      expect(find.byKey(const Key('route-description-1')), findsNothing);
      expect(find.byKey(const Key('route-description-2')), findsNothing);
      expect(find.byKey(const Key('route-style-1')), findsNothing);
    },
  );

  testWidgets(
    'selecting a route reveals ITS description and style note, and only its '
    'own — the other route stays a one-line row',
    (tester) async {
      final container = await _seedTwoDescribedRoutes(tester);
      await _pumpLegend(tester, container);
      await tester.pumpAndSettle();

      container.read(drawControllerProvider(_testWallId).notifier).selectRoute(1);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('route-description-1')), findsOneWidget);
      expect(find.byKey(const Key('route-style-1')), findsOneWidget);
      expect(find.text(_description), findsOneWidget);
      expect(find.text(_style), findsOneWidget);

      expect(
        find.byKey(const Key('route-description-2')),
        findsNothing,
        reason:
            'only the selected row expands — every row expanded would fill '
            'the legend\'s height cap and hide the routes either side',
      );
    },
  );

  testWidgets(
    'tapping a legend row is enough to reveal its details — selection is the '
    'gesture a climber actually performs',
    (tester) async {
      final container = await _seedTwoDescribedRoutes(tester);
      await _pumpLegend(tester, container);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('topo-route-legend-item-2')));
      await tester.pumpAndSettle();

      expect(
        container.read(drawControllerProvider(_testWallId)).selectedRouteId,
        2,
      );
      expect(find.byKey(const Key('route-description-2')), findsOneWidget);
    },
  );

  testWidgets(
    'details show in readOnly mode too — they are what a topo is READ from, '
    'not an editing affordance',
    (tester) async {
      final container = await _seedTwoDescribedRoutes(tester);
      await _pumpLegend(tester, container, readOnly: true);
      await tester.pumpAndSettle();

      container.read(drawControllerProvider(_testWallId).notifier).selectRoute(1);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('route-description-1')), findsOneWidget);
      // The editing controls stay hidden, which is what readOnly governs.
      expect(find.byKey(const Key('topo-route-delete-1')), findsNothing);
    },
  );

  testWidgets(
    'a selected route with no description adds no empty detail line',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          nowMsProvider.overrideWithValue(() => 1000),
        ],
      );
      addTearDown(container.dispose);
      container.listen(drawControllerProvider(_testWallId), (_, _) {});

      final crud = container.read(libraryCrudRepositoryProvider);
      final area = await crud.createArea('Area');
      final sector = await crud.createSector(area.id, 'Sector');
      final wall = await crud.createWall(sector.id, 'Wall');
      late String photoId;
      await tester.runAsync(() async {
        photoId = await crud.attachPhotoToWall(
          wall.id,
          XFile('/tmp/selected-details-bare.jpg'),
          1000,
          2000,
        );
      });
      await RouteRepository(db, nowMs: () => 1000).upsertRoute(
        wall.id,
        photoId,
        const TopoRoute(
          id: 1,
          number: 1,
          points: [Offset(0.1, 0.1), Offset(0.2, 0.2)],
        ),
      );
      await container
          .read(drawControllerProvider(_testWallId).notifier)
          .loadForWall(wall.id, photoId);

      await _pumpLegend(tester, container);
      await tester.pumpAndSettle();
      container.read(drawControllerProvider(_testWallId).notifier).selectRoute(1);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('route-description-1')), findsNothing);
      expect(find.byKey(const Key('route-style-1')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
