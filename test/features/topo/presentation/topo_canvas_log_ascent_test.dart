// Widget tests for the own (non-community) topo canvas's "log ascent"
// wiring (masi-log-ascent-own-routes plan, Subtask 1 / assertions A5, A6):
// tapping a route's `topo-log-ascent-<id>` button in RouteLegend opens the
// shared LogAscentSheet, and saving persists an ascent against the
// CORRECT wallId and the route's real, persisted DB row id — NOT
// `TopoRoute.id`'s locally-reassigned sequential int (see
// `RouteRepository`'s class doc for why those two ids are unrelated).
//
// Seeding follows `canvas_mode_intent_test.dart`'s pattern: attach a real
// photo via `attachPhotoToWall` (inside `tester.runAsync`, since that copies
// a real file) and seed a persisted route directly via `RouteRepository`,
// then pump `TopoCanvasScreen` with `debugInitialImageSize` to bypass the
// real (undriveable-under-fake-time) image decode.
import 'package:climbtopo/app/theme.dart';
import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/core/db/database_provider.dart';
import 'package:climbtopo/features/library/application/library_providers.dart';
import 'package:climbtopo/features/logbook/application/ascents_providers.dart';
import 'package:climbtopo/features/logbook/data/ascents_repository.dart';
import 'package:climbtopo/features/topo/application/draw_controller.dart';
import 'package:climbtopo/features/topo/data/route_repository.dart';
import 'package:climbtopo/features/topo/domain/topo_route.dart';
import 'package:climbtopo/features/topo/presentation/topo_canvas_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A [RouteRepository] whose [upsertRoute] silently skips persisting any
/// route whose [TopoRoute.number] is [skipNumber] — simulating Fix 1's
/// target race (a `commitRoute` fire-and-forget write that hasn't landed
/// yet, or has failed) so that route's uuid stays unresolvable via
/// [RouteRepository.routeDbIdsByNumber] even though the route already
/// exists in [DrawState.routes] (see `commitRoute`'s doc: the in-memory
/// mutation happens synchronously, before the write-through `await`).
class _SkipNumberRouteRepository extends RouteRepository {
  _SkipNumberRouteRepository(
    super.db, {
    required super.nowMs,
    required this.skipNumber,
  });

  final int skipNumber;

  @override
  Future<void> upsertRoute(
    String wallId,
    String photoId,
    TopoRoute route,
  ) async {
    if (route.number == skipNumber) return;
    await super.upsertRoute(wallId, photoId, route);
  }
}

void main() {
  Future<
    ({
      AppDatabase db,
      ProviderContainer container,
      String wallId,
      String routeDbId,
    })
  >
  seedWallWithRoute(WidgetTester tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        nowMsProvider.overrideWithValue(() => 1000),
      ],
    );

    final crud = container.read(libraryCrudRepositoryProvider);
    final area = await crud.createArea('Area');
    final sector = await crud.createSector(area.id, 'Sector');
    final wall = await crud.createWall(sector.id, 'Wall');

    late String photoId;
    await tester.runAsync(() async {
      photoId = await crud.attachPhotoToWall(
        wall.id,
        '/tmp/topo-canvas-log-ascent-test-photo.jpg',
        1000,
        2000,
      );
    });

    final routeRepo = RouteRepository(db, nowMs: () => 1000);
    await routeRepo.upsertRoute(
      wall.id,
      photoId,
      const TopoRoute(
        id: 1,
        number: 1,
        points: [Offset(0.1, 0.1), Offset(0.2, 0.2)],
        gradeRaw: '6a',
      ),
    );
    final dbIds = await routeRepo.routeDbIdsByNumber(wall.id);

    return (
      db: db,
      container: container,
      wallId: wall.id,
      routeDbId: dbIds[1]!,
    );
  }

  /// Fix 1 seam: seeds a wall with ONE persisted route (number 1, as
  /// [seedWallWithRoute] does), but overrides [routeRepositoryProvider]
  /// with [_SkipNumberRouteRepository] so any SECOND route committed via
  /// the live [drawControllerProvider] (number 2) updates local
  /// [DrawState.routes] synchronously but never lands in the DB — the
  /// exact "just-drawn route whose fire-and-forget DB write hasn't landed"
  /// race the finding describes.
  Future<
    ({AppDatabase db, ProviderContainer container, String wallId})
  >
  seedWallWithUnresolvedSecondRoute(WidgetTester tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    final flakyRepo = _SkipNumberRouteRepository(
      db,
      nowMs: () => 1000,
      skipNumber: 2,
    );
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        nowMsProvider.overrideWithValue(() => 1000),
        routeRepositoryProvider.overrideWithValue(flakyRepo),
      ],
    );

    final crud = container.read(libraryCrudRepositoryProvider);
    final area = await crud.createArea('Area');
    final sector = await crud.createSector(area.id, 'Sector');
    final wall = await crud.createWall(sector.id, 'Wall');

    late String photoId;
    await tester.runAsync(() async {
      photoId = await crud.attachPhotoToWall(
        wall.id,
        '/tmp/topo-canvas-log-ascent-unresolved-test-photo.jpg',
        1000,
        2000,
      );
    });

    // Route 1 is persisted directly (bypassing the flaky override) so it
    // resolves normally — only route 2 (committed later, through the live
    // controller) must hit the skip path.
    final routeRepo = RouteRepository(db, nowMs: () => 1000);
    await routeRepo.upsertRoute(
      wall.id,
      photoId,
      const TopoRoute(
        id: 1,
        number: 1,
        points: [Offset(0.1, 0.1), Offset(0.2, 0.2)],
        gradeRaw: '6a',
      ),
    );

    return (db: db, container: container, wallId: wall.id);
  }

  /// Fix 2 seam: seeds a wall with [count] persisted routes (numbers
  /// `1..count`, each therefore a DISTINCT persisted uuid — see
  /// `RouteRepository`'s class doc), for the multi-route end-to-end
  /// disambiguation test.
  Future<
    ({
      AppDatabase db,
      ProviderContainer container,
      String wallId,
      Map<int, String> routeDbIdsByNumber,
    })
  >
  seedWallWithRoutes(WidgetTester tester, int count) async {
    final db = AppDatabase(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        nowMsProvider.overrideWithValue(() => 1000),
      ],
    );

    final crud = container.read(libraryCrudRepositoryProvider);
    final area = await crud.createArea('Area');
    final sector = await crud.createSector(area.id, 'Sector');
    final wall = await crud.createWall(sector.id, 'Wall');

    late String photoId;
    await tester.runAsync(() async {
      photoId = await crud.attachPhotoToWall(
        wall.id,
        '/tmp/topo-canvas-log-ascent-multi-test-photo.jpg',
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
          gradeRaw: '6a',
        ),
      );
    }
    final dbIds = await routeRepo.routeDbIdsByNumber(wall.id);

    return (
      db: db,
      container: container,
      wallId: wall.id,
      routeDbIdsByNumber: dbIds,
    );
  }

  testWidgets(
    'A5/A6: tapping a route\'s log-ascent button on the OWN topo canvas '
    'opens LogAscentSheet, and saving persists the ascent against the '
    "route's real DB id and the current wallId — not an index",
    (tester) async {
      final seeded = await seedWallWithRoute(tester);
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);

      // Sanity: the real DB id is a uuid, not the naive `TopoRoute.id`
      // stringified (a bug this test would otherwise silently miss).
      expect(seeded.routeDbId, isNot('1'));
      expect(seeded.routeDbId.contains('-'), isTrue);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: seeded.container,
          child: MaterialApp(
            theme: MasiTheme.light,
            home: TopoCanvasScreen(
              wallId: seeded.wallId,
              debugInitialImageSize: const Size(1000, 2000),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final routes = seeded.container.read(drawControllerProvider).routes;
      expect(routes, hasLength(1));
      final routeLocalId = routes.single.id;

      final logAscentButton = find.byKey(Key('topo-log-ascent-$routeLocalId'));
      expect(
        logAscentButton,
        findsOneWidget,
        reason: 'the own (non-readOnly) canvas must show the log-ascent '
            'button on its route legend row',
      );

      await tester.tap(logAscentButton);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('topo-log-ascent-sheet')), findsOneWidget);

      await tester.tap(find.byKey(const Key('topo-ascent-save')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('topo-log-ascent-sheet')), findsNothing);

      final ascentsRepo = seeded.container.read(ascentsRepositoryProvider);
      final ascents = await ascentsRepo.ascentsForRoute(seeded.routeDbId);
      expect(
        ascents,
        hasLength(1),
        reason:
            'the ascent must be persisted against the route\'s REAL db id '
            '(${seeded.routeDbId}), not TopoRoute.id ($routeLocalId) or '
            'any other index',
      );
      expect(ascents.single.routeId, seeded.routeDbId);
      expect(ascents.single.wallId, seeded.wallId);
      expect(ascents.single.style, AscentStyle.redpoint);
    },
  );

  testWidgets(
    'A5b: the readOnly canvas never renders a log-ascent button (that '
    "screen's own separate community affordance covers it instead)",
    (tester) async {
      final seeded = await seedWallWithRoute(tester);
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: seeded.container,
          child: MaterialApp(
            theme: MasiTheme.light,
            home: TopoCanvasScreen(
              wallId: seeded.wallId,
              readOnly: true,
              debugInitialImageSize: const Size(1000, 2000),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final routes = seeded.container.read(drawControllerProvider).routes;
      expect(routes, hasLength(1));
      expect(
        find.byKey(Key('topo-log-ascent-${routes.single.id}')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'Fix 1: tapping a route whose real DB id cannot be resolved yet (a '
    "just-committed route whose fire-and-forget write hasn't landed) shows "
    'a SnackBar instead of silently no-opping, and never opens '
    'LogAscentSheet',
    (tester) async {
      final seeded = await seedWallWithUnresolvedSecondRoute(tester);
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: seeded.container,
          child: MaterialApp(
            theme: MasiTheme.light,
            home: TopoCanvasScreen(
              wallId: seeded.wallId,
              debugInitialImageSize: const Size(1000, 2000),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Commit a SECOND route directly via the live controller — its
      // write-through goes through the flaky repo (skipNumber: 2) and
      // never lands, but the in-memory route (per `commitRoute`'s doc)
      // appears immediately.
      final notifier = seeded.container.read(drawControllerProvider.notifier);
      notifier.addPoint(const Offset(0.3, 0.3));
      notifier.addPoint(const Offset(0.4, 0.4));
      await notifier.commitRoute();
      await tester.pumpAndSettle();

      final routes = seeded.container.read(drawControllerProvider).routes;
      expect(routes, hasLength(2));
      final unresolvedRoute = routes.firstWhere((r) => r.number == 2);

      final logAscentButton = find.byKey(
        Key('topo-log-ascent-${unresolvedRoute.id}'),
      );
      expect(logAscentButton, findsOneWidget);

      await tester.tap(logAscentButton);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('topo-log-ascent-sheet')),
        findsNothing,
        reason:
            'the sheet must never open when the route cannot be resolved '
            'to a real, persisted DB id',
      );
      expect(
        find.text('Route is still saving — try again in a moment.'),
        findsOneWidget,
        reason:
            'the user must get explicit feedback instead of a silently '
            'broken-looking button',
      );
    },
  );

  testWidgets(
    'Fix 2: with 3 persisted routes on the canvas, tapping the SECOND '
    "route's real log-ascent button persists the ascent against exactly "
    "THAT route's uuid — not route 1's or route 3's",
    (tester) async {
      final seeded = await seedWallWithRoutes(tester, 3);
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);

      final route1DbId = seeded.routeDbIdsByNumber[1]!;
      final route2DbId = seeded.routeDbIdsByNumber[2]!;
      final route3DbId = seeded.routeDbIdsByNumber[3]!;
      // Sanity: three distinct persisted uuids (this is the id-correctness
      // -sensitive area the finding calls out).
      expect({route1DbId, route2DbId, route3DbId}, hasLength(3));

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: seeded.container,
          child: MaterialApp(
            theme: MasiTheme.light,
            home: TopoCanvasScreen(
              wallId: seeded.wallId,
              debugInitialImageSize: const Size(1000, 2000),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final routes = seeded.container.read(drawControllerProvider).routes;
      expect(routes, hasLength(3));
      final route2Local = routes.firstWhere((r) => r.number == 2);

      final logAscentButton = find.byKey(
        Key('topo-log-ascent-${route2Local.id}'),
      );
      expect(logAscentButton, findsOneWidget);

      await tester.tap(logAscentButton);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('topo-log-ascent-sheet')), findsOneWidget);

      await tester.tap(find.byKey(const Key('topo-ascent-save')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('topo-log-ascent-sheet')), findsNothing);

      final ascentsRepo = seeded.container.read(ascentsRepositoryProvider);
      final allAscents = [
        ...await ascentsRepo.ascentsForRoute(route1DbId),
        ...await ascentsRepo.ascentsForRoute(route2DbId),
        ...await ascentsRepo.ascentsForRoute(route3DbId),
      ];
      expect(
        allAscents,
        hasLength(1),
        reason: 'exactly one ascent must exist across all three routes',
      );
      expect(allAscents.single.routeId, route2DbId);
      expect(
        allAscents.single.routeId,
        isNot(route1DbId),
        reason: "must not land on route 1's uuid",
      );
      expect(
        allAscents.single.routeId,
        isNot(route3DbId),
        reason: "must not land on route 3's uuid",
      );
    },
  );
}
