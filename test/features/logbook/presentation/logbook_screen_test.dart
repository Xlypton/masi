import 'package:climbtopo/app/theme.dart';
import 'package:climbtopo/core/db/app_database.dart' as db;
import 'package:climbtopo/core/db/database_provider.dart';
import 'package:climbtopo/core/grades/grade_system.dart';
import 'package:climbtopo/features/logbook/application/ascents_providers.dart';
import 'package:climbtopo/features/logbook/data/ascents_repository.dart';
import 'package:climbtopo/features/logbook/presentation/logbook_screen.dart';
import 'package:drift/drift.dart' hide isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A seeded (wallId, routeId) pair satisfying the FK constraints on
/// `Ascents.wallId`/`Ascents.routeId` (this DB enforces
/// `PRAGMA foreign_keys = ON` — see `AppDatabase.beforeOpen`), via a minimal
/// Area -> Sector -> Wall -> Photo -> Route chain. Mirrors
/// `test/features/logbook/data/ascents_repository_test.dart`'s `_Seed`/`seed`.
class _Seed {
  const _Seed(this.wallId, this.routeId);
  final String wallId;
  final String routeId;
}

/// Seeds a distinct Area/Sector/Wall/Photo/Route chain (ids suffixed with
/// [n], which must be unique per call within a test) and returns the new
/// wall/route ids for use as `logAscent(wallId:, routeId:)` arguments.
Future<_Seed> _seed(
  db.AppDatabase database,
  String n, {
  String wallName = 'Wall',
  int routeNumber = 1,
  String? routeName,
  String? gradeRaw,
  double? gradeSortKey,
}) async {
  final areaId = 'area-$n';
  final sectorId = 'sector-$n';
  final wallId = 'wall-$n';
  final photoId = 'photo-$n';
  final routeId = 'route-$n';
  await database
      .into(database.areas)
      .insert(
        db.AreasCompanion.insert(
          id: areaId,
          createdAt: 0,
          updatedAt: 0,
          name: 'Area $n',
        ),
      );
  await database
      .into(database.sectors)
      .insert(
        db.SectorsCompanion.insert(
          id: sectorId,
          createdAt: 0,
          updatedAt: 0,
          areaId: areaId,
          name: 'Sector $n',
          sortOrder: 0,
        ),
      );
  await database
      .into(database.walls)
      .insert(
        db.WallsCompanion.insert(
          id: wallId,
          createdAt: 0,
          updatedAt: 0,
          sectorId: sectorId,
          name: wallName,
          sortOrder: 0,
        ),
      );
  await database
      .into(database.photos)
      .insert(
        db.PhotosCompanion.insert(
          id: photoId,
          createdAt: 0,
          updatedAt: 0,
          wallId: wallId,
          localPath: '/tmp/$n.jpg',
          kind: 'original',
          width: 1,
          height: 1,
        ),
      );
  await database
      .into(database.routes)
      .insert(
        db.RoutesCompanion.insert(
          id: routeId,
          createdAt: 0,
          updatedAt: 0,
          wallId: wallId,
          photoId: photoId,
          number: routeNumber,
          name: Value(routeName),
          gradeRaw: Value(gradeRaw),
          gradeSortKey: Value(gradeSortKey),
          colorIndex: 0,
          pointsJson: '[]',
          symbolsJson: '[]',
          sortOrder: 0,
        ),
      );
  return _Seed(wallId, routeId);
}

/// Builds a [ProviderContainer] wired to a fresh in-memory database and
/// registers teardown of both the container and the database connection.
///
/// addTearDown runs LIFO, so `database.close` is registered first: the
/// container must be disposed (cancelling Riverpod's live watch
/// subscriptions) BEFORE the underlying Drift connection is closed, otherwise
/// closing the database out from under a still-active watch stream hangs
/// waiting on the background executor isolate. (Mirrors
/// `test/features/library/presentation/topos_screen_test.dart`.)
ProviderContainer _makeContainer() {
  final database = db.AppDatabase(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(database),
      nowMsProvider.overrideWithValue(() => 1000),
    ],
  );
  addTearDown(database.close);
  addTearDown(container.dispose);
  return container;
}

Widget _wrap(ProviderContainer container, Widget screen) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(theme: MasiTheme.light, home: screen),
  );
}

/// Advances real asynchronous work (Drift's in-memory background executor
/// and any other awaited futures) that would otherwise never make progress
/// under `testWidgets`' fake-async clock, then pumps to flush the resulting
/// Riverpod-triggered rebuilds. Mirrors `topos_screen_test.dart`'s `_drain`.
Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 30));
  }
  await tester.pumpAndSettle();
}

/// Runs [body] (which performs real Drift async work) under the real event
/// loop so its awaits actually complete, capturing the result.
Future<T> _dbWork<T>(WidgetTester tester, Future<T> Function() body) async {
  late T result;
  await tester.runAsync(() async {
    result = await body();
  });
  return result;
}

void main() {
  group('Empty state', () {
    testWidgets('no ascents shows logbook-empty', (tester) async {
      final container = _makeContainer();

      await tester.pumpWidget(_wrap(container, const LogbookScreen()));
      await _drain(tester);

      expect(find.byKey(const Key('logbook-empty')), findsOneWidget);
      expect(find.text('No ascents logged yet'), findsOneWidget);
    });
  });

  group('D6a: ordering', () {
    testWidgets(
      'entries render newest-climbedAt-first',
      (tester) async {
        final container = _makeContainer();
        final database = container.read(appDatabaseProvider);
        final repo = container.read(ascentsRepositoryProvider);

        final s1 = await _dbWork(
          tester,
          () => _seed(database, '1', wallName: 'Wall One', routeNumber: 1),
        );
        final s2 = await _dbWork(
          tester,
          () => _seed(database, '2', wallName: 'Wall Two', routeNumber: 2),
        );

        final older = await _dbWork(
          tester,
          () => repo.logAscent(
            routeId: s1.routeId,
            wallId: s1.wallId,
            climbedAt: DateTime.utc(2026, 1, 1),
            style: AscentStyle.onsight,
          ),
        );
        final newest = await _dbWork(
          tester,
          () => repo.logAscent(
            routeId: s2.routeId,
            wallId: s2.wallId,
            climbedAt: DateTime.utc(2026, 6, 1),
            style: AscentStyle.flash,
          ),
        );

        await tester.pumpWidget(_wrap(container, const LogbookScreen()));
        await _drain(tester);

        expect(
          find.byKey(Key('logbook-entry-${older.id}')),
          findsOneWidget,
        );
        expect(
          find.byKey(Key('logbook-entry-${newest.id}')),
          findsOneWidget,
        );

        final newestY = tester
            .getTopLeft(find.byKey(Key('logbook-entry-${newest.id}')))
            .dy;
        final olderY = tester
            .getTopLeft(find.byKey(Key('logbook-entry-${older.id}')))
            .dy;
        expect(
          newestY,
          lessThan(olderY),
          reason: 'the newest-climbedAt entry must render above the older '
              'one',
        );
      },
    );
  });

  group('D6b: entry content', () {
    testWidgets(
      'shows style, date, route name/grade and wall name',
      (tester) async {
        final container = _makeContainer();
        final database = container.read(appDatabaseProvider);
        final repo = container.read(ascentsRepositoryProvider);

        final s = await _dbWork(
          tester,
          () => _seed(
            database,
            '1',
            wallName: 'Roof Wall',
            routeNumber: 3,
            routeName: 'Sunny Arete',
            gradeRaw: '6a',
            gradeSortKey: gradeSortKey(GradeSystem.french, '6a'),
          ),
        );
        final ascent = await _dbWork(
          tester,
          () => repo.logAscent(
            routeId: s.routeId,
            wallId: s.wallId,
            climbedAt: DateTime.utc(2026, 7, 4),
            style: AscentStyle.redpoint,
          ),
        );

        await tester.pumpWidget(_wrap(container, const LogbookScreen()));
        await _drain(tester);

        expect(
          find.byKey(Key('logbook-entry-${ascent.id}')),
          findsOneWidget,
        );
        expect(find.text('Sunny Arete'), findsOneWidget);
        expect(find.text('Roof Wall'), findsOneWidget);
        expect(find.text('6a'), findsOneWidget);
        expect(find.textContaining('Redpoint'), findsOneWidget);
        expect(find.textContaining('Jul 4, 2026'), findsOneWidget);
      },
    );

    testWidgets(
      'a route with no name falls back to "Route N"',
      (tester) async {
        final container = _makeContainer();
        final database = container.read(appDatabaseProvider);
        final repo = container.read(ascentsRepositoryProvider);

        final s = await _dbWork(
          tester,
          () => _seed(database, '1', wallName: 'Slab Wall', routeNumber: 5),
        );
        await _dbWork(
          tester,
          () => repo.logAscent(
            routeId: s.routeId,
            wallId: s.wallId,
            climbedAt: DateTime.utc(2026, 2, 2),
            style: AscentStyle.attempt,
          ),
        );

        await tester.pumpWidget(_wrap(container, const LogbookScreen()));
        await _drain(tester);

        expect(find.text('Route 5'), findsOneWidget);
        expect(find.textContaining('Attempt'), findsOneWidget);
      },
    );
  });

  group('D6c: delete flow', () {
    testWidgets(
      'tapping delete then confirming removes the row and soft-deletes it '
      'in the repo (tombstone, not a hard delete)',
      (tester) async {
        final container = _makeContainer();
        final database = container.read(appDatabaseProvider);
        final repo = container.read(ascentsRepositoryProvider);

        final s = await _dbWork(
          tester,
          () => _seed(database, '1', wallName: 'Wall X', routeNumber: 1),
        );
        final ascent = await _dbWork(
          tester,
          () => repo.logAscent(
            routeId: s.routeId,
            wallId: s.wallId,
            climbedAt: DateTime.utc(2026, 1, 1),
            style: AscentStyle.attempt,
          ),
        );

        await tester.pumpWidget(_wrap(container, const LogbookScreen()));
        await _drain(tester);

        expect(
          find.byKey(Key('logbook-entry-${ascent.id}')),
          findsOneWidget,
        );

        await tester.tap(
          find.byKey(Key('logbook-entry-delete-${ascent.id}')),
        );
        await tester.pumpAndSettle();

        expect(find.text('Delete ascent?'), findsOneWidget);

        await tester.tap(
          find.byKey(Key('logbook-entry-delete-confirm-${ascent.id}')),
        );
        await _drain(tester);

        expect(
          find.byKey(Key('logbook-entry-${ascent.id}')),
          findsNothing,
        );
        expect(find.byKey(const Key('logbook-empty')), findsOneWidget);

        final remaining = await _dbWork(tester, () => repo.logbook());
        expect(remaining, isEmpty);

        final row = await _dbWork(
          tester,
          () => (database.select(
            database.ascents,
          )..where((t) => t.id.equals(ascent.id))).getSingle(),
        );
        expect(
          row.deletedAt,
          isNotNull,
          reason: 'delete must be a soft-delete tombstone, not physical',
        );
      },
    );

    testWidgets(
      'cancelling the confirm dialog leaves the entry in place',
      (tester) async {
        final container = _makeContainer();
        final database = container.read(appDatabaseProvider);
        final repo = container.read(ascentsRepositoryProvider);

        final s = await _dbWork(
          tester,
          () => _seed(database, '1', wallName: 'Wall Y', routeNumber: 2),
        );
        final ascent = await _dbWork(
          tester,
          () => repo.logAscent(
            routeId: s.routeId,
            wallId: s.wallId,
            climbedAt: DateTime.utc(2026, 1, 1),
            style: AscentStyle.flash,
          ),
        );

        await tester.pumpWidget(_wrap(container, const LogbookScreen()));
        await _drain(tester);

        await tester.tap(
          find.byKey(Key('logbook-entry-delete-${ascent.id}')),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        expect(
          find.byKey(Key('logbook-entry-${ascent.id}')),
          findsOneWidget,
        );
      },
    );
  });
}
