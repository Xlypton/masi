// Display tests for RouteLegend's #41 (beta-video button), #42 (style-tag
// chips), and #44 (star rating) per-route rendering. Seeding mirrors
// route_legend_intent_test.dart's `_seedRoutes` (real Area -> Sector ->
// Wall -> Photo -> Route chain, loaded into drawControllerProvider via
// DrawController.loadForWall — exactly the path TopoCanvasScreen drives).

import 'package:climbtopo/app/theme.dart';
import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/core/db/database_provider.dart';
import 'package:climbtopo/features/library/application/library_providers.dart';
import 'package:climbtopo/features/topo/application/draw_controller.dart';
import 'package:climbtopo/features/topo/data/route_repository.dart';
import 'package:climbtopo/features/topo/domain/topo_route.dart';
import 'package:climbtopo/features/topo/presentation/route_legend.dart';
import 'package:climbtopo/shared/presentation/masi_icon.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Future<ProviderContainer> _seedOneRoute(
  WidgetTester tester,
  TopoRoute route,
) async {
  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      nowMsProvider.overrideWithValue(() => 1000),
    ],
  );
  addTearDown(container.dispose);

  final crud = container.read(libraryCrudRepositoryProvider);
  final area = await crud.createArea('Area');
  final sector = await crud.createSector(area.id, 'Sector');
  final wall = await crud.createWall(sector.id, 'Wall');
  late String photoId;
  await tester.runAsync(() async {
    photoId = await crud.attachPhotoToWall(
      wall.id,
      '/tmp/route-legend-perroute-test-photo.jpg',
      1000,
      2000,
    );
  });

  final routeRepo = RouteRepository(db, nowMs: () => 1000);
  await routeRepo.upsertRoute(wall.id, photoId, route);

  await container
      .read(drawControllerProvider.notifier)
      .loadForWall(wall.id, photoId);

  return container;
}

Future<void> _pumpLegend(WidgetTester tester, ProviderContainer container) {
  return tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: MasiTheme.light,
        home: const Scaffold(body: RouteLegend()),
      ),
    ),
  );
}

void main() {
  group('RouteLegend beta-video button (#41)', () {
    testWidgets('a route with betaVideoUrl shows route-beta-<id>', (
      tester,
    ) async {
      final container = await _seedOneRoute(
        tester,
        const TopoRoute(
          id: 1,
          number: 1,
          points: [Offset(0.1, 0.1), Offset(0.2, 0.2)],
          betaVideoUrl: 'https://example.com/beta',
        ),
      );
      await _pumpLegend(tester, container);
      await tester.pump();

      final routeId = container.read(drawControllerProvider).routes.single.id;
      expect(find.byKey(Key('route-beta-$routeId')), findsOneWidget);
    });

    testWidgets('a route without betaVideoUrl has no route-beta-<id>', (
      tester,
    ) async {
      final container = await _seedOneRoute(
        tester,
        const TopoRoute(
          id: 1,
          number: 1,
          points: [Offset(0.1, 0.1), Offset(0.2, 0.2)],
        ),
      );
      await _pumpLegend(tester, container);
      await tester.pump();

      final routeId = container.read(drawControllerProvider).routes.single.id;
      expect(find.byKey(Key('route-beta-$routeId')), findsNothing);
    });
  });

  group('RouteLegend style-tag chips (#42)', () {
    testWidgets(
      'renders one route-styletag-<id>-<key> chip per tag, curated and '
      'custom alike',
      (tester) async {
        final container = await _seedOneRoute(
          tester,
          const TopoRoute(
            id: 1,
            number: 1,
            points: [Offset(0.1, 0.1), Offset(0.2, 0.2)],
            styleTags: ['dyno', 'my-custom-tag'],
          ),
        );
        await _pumpLegend(tester, container);
        await tester.pump();

        final routeId = container.read(drawControllerProvider).routes.single.id;
        expect(
          find.byKey(Key('route-styletag-$routeId-dyno')),
          findsOneWidget,
        );
        expect(
          find.byKey(Key('route-styletag-$routeId-my-custom-tag')),
          findsOneWidget,
        );
        // Curated tag shows its curated label; custom tag shows itself raw.
        expect(find.text('Dyno'), findsOneWidget);
        expect(find.text('my-custom-tag'), findsOneWidget);
      },
    );

    testWidgets('a route with no style tags renders no tag chips', (
      tester,
    ) async {
      final container = await _seedOneRoute(
        tester,
        const TopoRoute(
          id: 1,
          number: 1,
          points: [Offset(0.1, 0.1), Offset(0.2, 0.2)],
        ),
      );
      await _pumpLegend(tester, container);
      await tester.pump();

      final routeId = container.read(drawControllerProvider).routes.single.id;
      expect(
        find.byKey(Key('route-styletag-$routeId-dyno')),
        findsNothing,
      );
    });
  });

  group('RouteLegend star rating (#44)', () {
    testWidgets('stars=2 shows the route-stars-<id> row with 2 filled stars', (
      tester,
    ) async {
      final container = await _seedOneRoute(
        tester,
        const TopoRoute(
          id: 1,
          number: 1,
          points: [Offset(0.1, 0.1), Offset(0.2, 0.2)],
          stars: 2,
        ),
      );
      await _pumpLegend(tester, container);
      await tester.pump();

      final routeId = container.read(drawControllerProvider).routes.single.id;
      final starsRow = find.byKey(Key('route-stars-$routeId'));
      expect(starsRow, findsOneWidget);
      expect(
        find.descendant(of: starsRow, matching: find.byType(MasiIcon)),
        findsNWidgets(2),
      );
    });

    testWidgets('an unrated route (stars null) renders no stars row', (
      tester,
    ) async {
      final container = await _seedOneRoute(
        tester,
        const TopoRoute(
          id: 1,
          number: 1,
          points: [Offset(0.1, 0.1), Offset(0.2, 0.2)],
        ),
      );
      await _pumpLegend(tester, container);
      await tester.pump();

      final routeId = container.read(drawControllerProvider).routes.single.id;
      expect(find.byKey(Key('route-stars-$routeId')), findsNothing);
    });

    testWidgets('stars=0 (explicit) renders no stars row', (tester) async {
      final container = await _seedOneRoute(
        tester,
        const TopoRoute(
          id: 1,
          number: 1,
          points: [Offset(0.1, 0.1), Offset(0.2, 0.2)],
          stars: 0,
        ),
      );
      await _pumpLegend(tester, container);
      await tester.pump();

      final routeId = container.read(drawControllerProvider).routes.single.id;
      expect(find.byKey(Key('route-stars-$routeId')), findsNothing);
    });
  });
}
