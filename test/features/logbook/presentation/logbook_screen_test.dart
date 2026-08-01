import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart' as db;
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/core/grades/grade_system.dart';
import 'package:masi/features/logbook/application/ascents_providers.dart';
import 'package:masi/features/logbook/data/ascents_repository.dart';
import 'package:masi/features/logbook/presentation/logbook_screen.dart';
import 'package:masi/shared/presentation/masi_icon.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../../support/async_drain.dart';

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
  String? style,
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
          style: Value(style),
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
  await drainAsync(tester, rounds: 6, settle: false);
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

  group('C3: filter button + sheet', () {
    testWidgets(
      'logbook-filter-button opens a sheet exposing all three filter '
      'facets',
      (tester) async {
        final container = _makeContainer();
        final database = container.read(appDatabaseProvider);
        final repo = container.read(ascentsRepositoryProvider);
        final s = await _dbWork(tester, () => _seed(database, '1'));
        await _dbWork(
          tester,
          () => repo.logAscent(
            routeId: s.routeId,
            wallId: s.wallId,
            climbedAt: DateTime.utc(2026, 1, 1),
            style: AscentStyle.onsight,
          ),
        );

        await tester.pumpWidget(_wrap(container, const LogbookScreen()));
        await _drain(tester);

        expect(find.byKey(const Key('logbook-filter-button')), findsOneWidget);

        await tester.tap(find.byKey(const Key('logbook-filter-button')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('filter-grade-min')), findsOneWidget);
        expect(find.byKey(const Key('filter-grade-max')), findsOneWidget);
        expect(find.byKey(const Key('filter-style-sport')), findsOneWidget);
        expect(find.byKey(const Key('filter-style-trad')), findsOneWidget);
        expect(find.byKey(const Key('filter-style-boulder')), findsOneWidget);
        expect(
          find.byKey(const Key('filter-ascent-onsight')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('filter-ascent-flash')), findsOneWidget);
      },
    );

    testWidgets(
      'no active filter indicator before any facet is chosen',
      (tester) async {
        final container = _makeContainer();
        await tester.pumpWidget(_wrap(container, const LogbookScreen()));
        await _drain(tester);

        expect(
          find.byWidgetPredicate((w) => w is MasiIcon && w.name == 'filter_active'),
          findsNothing,
        );
      },
    );
  });

  group('C3: live filtering by route style', () {
    testWidgets(
      'selecting a style chip narrows the list to matching entries and '
      'shows the active indicator; Clear restores the full list',
      (tester) async {
        final container = _makeContainer();
        final database = container.read(appDatabaseProvider);
        final repo = container.read(ascentsRepositoryProvider);

        final sport = await _dbWork(
          tester,
          () => _seed(database, 'sport', wallName: 'Sport Wall', style: 'sport'),
        );
        final trad = await _dbWork(
          tester,
          () => _seed(database, 'trad', wallName: 'Trad Wall', style: 'trad'),
        );
        final sportAscent = await _dbWork(
          tester,
          () => repo.logAscent(
            routeId: sport.routeId,
            wallId: sport.wallId,
            climbedAt: DateTime.utc(2026, 1, 1),
            style: AscentStyle.onsight,
          ),
        );
        final tradAscent = await _dbWork(
          tester,
          () => repo.logAscent(
            routeId: trad.routeId,
            wallId: trad.wallId,
            climbedAt: DateTime.utc(2026, 1, 2),
            style: AscentStyle.flash,
          ),
        );

        await tester.pumpWidget(_wrap(container, const LogbookScreen()));
        await _drain(tester);

        expect(
          find.byKey(Key('logbook-entry-${sportAscent.id}')),
          findsOneWidget,
        );
        expect(
          find.byKey(Key('logbook-entry-${tradAscent.id}')),
          findsOneWidget,
        );

        await tester.tap(find.byKey(const Key('logbook-filter-button')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('filter-style-sport')));
        await tester.pumpAndSettle();

        expect(
          find.byKey(Key('logbook-entry-${sportAscent.id}')),
          findsOneWidget,
        );
        expect(
          find.byKey(Key('logbook-entry-${tradAscent.id}')),
          findsNothing,
        );
        expect(
          find.byWidgetPredicate((w) => w is MasiIcon && w.name == 'filter_active'),
          findsOneWidget,
        );

        await tester.tap(find.byKey(const Key('logbook-filter-clear')));
        await tester.pumpAndSettle();

        expect(
          find.byKey(Key('logbook-entry-${sportAscent.id}')),
          findsOneWidget,
        );
        expect(
          find.byKey(Key('logbook-entry-${tradAscent.id}')),
          findsOneWidget,
        );
        expect(
          find.byWidgetPredicate((w) => w is MasiIcon && w.name == 'filter_active'),
          findsNothing,
        );
      },
    );
  });

  group('C3: live filtering by ascent type', () {
    testWidgets(
      'selecting an ascent-type chip narrows the list to matching entries',
      (tester) async {
        final container = _makeContainer();
        final database = container.read(appDatabaseProvider);
        final repo = container.read(ascentsRepositoryProvider);

        final s = await _dbWork(tester, () => _seed(database, '1'));
        final onsight = await _dbWork(
          tester,
          () => repo.logAscent(
            routeId: s.routeId,
            wallId: s.wallId,
            climbedAt: DateTime.utc(2026, 1, 1),
            style: AscentStyle.onsight,
          ),
        );
        final attempt = await _dbWork(
          tester,
          () => repo.logAscent(
            routeId: s.routeId,
            wallId: s.wallId,
            climbedAt: DateTime.utc(2026, 1, 2),
            style: AscentStyle.attempt,
          ),
        );

        await tester.pumpWidget(_wrap(container, const LogbookScreen()));
        await _drain(tester);

        await tester.tap(find.byKey(const Key('logbook-filter-button')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('filter-ascent-onsight')));
        await tester.pumpAndSettle();

        expect(
          find.byKey(Key('logbook-entry-${onsight.id}')),
          findsOneWidget,
        );
        expect(
          find.byKey(Key('logbook-entry-${attempt.id}')),
          findsNothing,
        );
      },
    );
  });

  group('C3: live filtering by grade range', () {
    testWidgets(
      'picking a min grade narrows the list to entries at or above it',
      (tester) async {
        final container = _makeContainer();
        final database = container.read(appDatabaseProvider);
        final repo = container.read(ascentsRepositoryProvider);

        final easy = await _dbWork(
          tester,
          () => _seed(
            database,
            'easy',
            wallName: 'Easy Wall',
            gradeRaw: '5a',
            gradeSortKey: gradeSortKey(GradeSystem.french, '5a'),
          ),
        );
        final hard = await _dbWork(
          tester,
          () => _seed(
            database,
            'hard',
            wallName: 'Hard Wall',
            gradeRaw: '7a',
            gradeSortKey: gradeSortKey(GradeSystem.french, '7a'),
          ),
        );
        final easyAscent = await _dbWork(
          tester,
          () => repo.logAscent(
            routeId: easy.routeId,
            wallId: easy.wallId,
            climbedAt: DateTime.utc(2026, 1, 1),
            style: AscentStyle.onsight,
          ),
        );
        final hardAscent = await _dbWork(
          tester,
          () => repo.logAscent(
            routeId: hard.routeId,
            wallId: hard.wallId,
            climbedAt: DateTime.utc(2026, 1, 2),
            style: AscentStyle.redpoint,
          ),
        );

        await tester.pumpWidget(_wrap(container, const LogbookScreen()));
        await _drain(tester);

        await tester.tap(find.byKey(const Key('logbook-filter-button')));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('filter-grade-min')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('6a').last);
        await tester.pumpAndSettle();

        expect(
          find.byKey(Key('logbook-entry-${hardAscent.id}')),
          findsOneWidget,
        );
        expect(
          find.byKey(Key('logbook-entry-${easyAscent.id}')),
          findsNothing,
        );
      },
    );
  });

  group('C3: filtered-empty state', () {
    testWidgets(
      'entries exist but none match the active filters shows a distinct '
      'empty state (not the "no ascents logged yet" one)',
      (tester) async {
        final container = _makeContainer();
        final database = container.read(appDatabaseProvider);
        final repo = container.read(ascentsRepositoryProvider);

        final s = await _dbWork(
          tester,
          () => _seed(database, '1', style: 'sport'),
        );
        await _dbWork(
          tester,
          () => repo.logAscent(
            routeId: s.routeId,
            wallId: s.wallId,
            climbedAt: DateTime.utc(2026, 1, 1),
            style: AscentStyle.onsight,
          ),
        );

        await tester.pumpWidget(_wrap(container, const LogbookScreen()));
        await _drain(tester);

        await tester.tap(find.byKey(const Key('logbook-filter-button')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('filter-style-trad')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('logbook-empty')), findsNothing);
        expect(find.byKey(const Key('logbook-filtered-empty')), findsOneWidget);
        expect(find.text('No ascents match your filters'), findsOneWidget);
      },
    );

    testWidgets(
      'the filtered-empty state\'s "Clear filters" button resets the '
      'active filter and restores the full list',
      (tester) async {
        final container = _makeContainer();
        final database = container.read(appDatabaseProvider);
        final repo = container.read(ascentsRepositoryProvider);

        final s = await _dbWork(
          tester,
          () => _seed(database, '1', style: 'sport'),
        );
        final ascent = await _dbWork(
          tester,
          () => repo.logAscent(
            routeId: s.routeId,
            wallId: s.wallId,
            climbedAt: DateTime.utc(2026, 1, 1),
            style: AscentStyle.onsight,
          ),
        );

        await tester.pumpWidget(_wrap(container, const LogbookScreen()));
        await _drain(tester);

        await tester.tap(find.byKey(const Key('logbook-filter-button')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('filter-style-trad')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('logbook-filtered-empty')), findsOneWidget);

        // The Filters sheet is still open (a modal bottom sheet, so it sits
        // in front of and intercepts taps on the body behind it) — the
        // filtered-empty state's own "Clear filters" button only becomes
        // reachable once the user dismisses the sheet, same as a real user
        // would have to. Close it via its own Navigator before tapping the
        // body's Clear button.
        Navigator.of(
          tester.element(find.byKey(const Key('logbook-filter-sheet'))),
        ).pop();
        await tester.pumpAndSettle();

        await tester.tap(
          find.byKey(const Key('logbook-filtered-empty-clear')),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('logbook-filtered-empty')), findsNothing);
        expect(
          find.byKey(Key('logbook-entry-${ascent.id}')),
          findsOneWidget,
        );
        expect(
          find.byWidgetPredicate((w) => w is MasiIcon && w.name == 'filter_active'),
          findsNothing,
          reason: 'Clear filters must reset every facet, matching the '
              'sheet\'s own Clear action',
        );
      },
    );
  });

  group('#15: local-day date formatting', () {
    testWidgets(
      'an ascent logged near local midnight shows the LOCAL calendar day, '
      'not the UTC one',
      (tester) async {
        final container = _makeContainer();
        final database = container.read(appDatabaseProvider);
        final repo = container.read(ascentsRepositoryProvider);

        // A UTC instant chosen so that converting to this machine's local
        // timezone lands on a different calendar day than the raw UTC
        // components would -- the exact regression #15 describes (an
        // ascent logged at 00:30 local in UTC+2 showing the previous UTC
        // date). Deriving the expected label via the SAME `.toLocal()`
        // conversion (rather than hard-coding a date) keeps this test
        // correct regardless of the host machine's own timezone.
        final climbedAtUtc = DateTime.utc(2026, 7, 4, 23, 30);
        final local = climbedAtUtc.toLocal();

        final s = await _dbWork(
          tester,
          () => _seed(database, '1', wallName: 'Midnight Wall'),
        );
        await _dbWork(
          tester,
          () => repo.logAscent(
            routeId: s.routeId,
            wallId: s.wallId,
            climbedAt: climbedAtUtc,
            style: AscentStyle.onsight,
          ),
        );

        await tester.pumpWidget(_wrap(container, const LogbookScreen()));
        await _drain(tester);

        const monthAbbreviations = [
          'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
          'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
        ];
        final expectedLabel =
            '${monthAbbreviations[local.month - 1]} ${local.day}, '
            '${local.year}';

        expect(find.textContaining(expectedLabel), findsOneWidget);
      },
    );
  });

  group('layout overflow regression: Filters sheet', () {
    /// Wraps [screen] in the same plain [MaterialApp] as [_wrap], plus a
    /// [MediaQuery] override so `textScaler` can be forced to a large value
    /// independently of the surface size set via [setViewportSize].
    Widget wrapWithScale(
      ProviderContainer container,
      Widget screen,
      double textScale,
    ) {
      return UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: MasiTheme.light,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: screen,
        ),
      );
    }

    void setViewportSize(WidgetTester tester, Size size) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    testWidgets(
      'vertical stress: 360x500 @ 2.5x text scale — opening the Filters '
      'sheet does not overflow vertically',
      (tester) async {
        setViewportSize(tester, const Size(360, 500));
        final container = _makeContainer();

        await tester.pumpWidget(
          wrapWithScale(container, const LogbookScreen(), 2.5),
        );
        await _drain(tester);

        await tester.tap(find.byKey(const Key('logbook-filter-button')));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'horizontal stress: 320x800 @ 3.0x text scale — the "Filters"/Clear '
      'header row does not overflow horizontally (regression: the title '
      'must truncate rather than push Clear off-screen)',
      (tester) async {
        setViewportSize(tester, const Size(320, 800));
        final container = _makeContainer();

        await tester.pumpWidget(
          wrapWithScale(container, const LogbookScreen(), 3.0),
        );
        await _drain(tester);

        await tester.tap(find.byKey(const Key('logbook-filter-button')));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
      },
    );
  });

  group(
    'layout overflow regression: populated _LogbookRow at phone width '
    '(regression: the trailing grade Text must not be an unbounded Row '
    'child)',
    () {
      Widget wrapWithScale(
        ProviderContainer container,
        Widget screen,
        double textScale,
      ) {
        return UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: MasiTheme.light,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
            home: screen,
          ),
        );
      }

      void setViewportSize(WidgetTester tester, Size size) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
      }

      testWidgets(
        'a populated logbook row (route title + grade label) at 360x800 '
        '@ 3.0x text scale does not overflow',
        (tester) async {
          setViewportSize(tester, const Size(360, 800));
          final container = _makeContainer();
          final database = container.read(appDatabaseProvider);
          final repo = container.read(ascentsRepositoryProvider);

          // A deliberately long route name (so the title's Flexible shrinks
          // as far as it can) AND a longer-than-usual grade token (written
          // directly to the DB, bypassing `isValidGrade`'s french/uiaa
          // ladder -- exactly as a corrupt/legacy/future-grade-system value
          // could reach this screen) is needed to actually reproduce the
          // trailing grade Text's unbounded-width overflow: a realistic
          // short "8c+"-style label alone does not overflow this Row at
          // this width/scale.
          final s = await _dbWork(
            tester,
            () => _seed(
              database,
              '1',
              wallName: 'Stress Wall',
              routeNumber: 1,
              routeName: 'An Extremely Long Route Name For Stress Testing',
              gradeRaw: '9c+/5.15d (sandbagged)',
              gradeSortKey: gradeSortKey(GradeSystem.french, '8c+'),
            ),
          );
          await _dbWork(
            tester,
            () => repo.logAscent(
              routeId: s.routeId,
              wallId: s.wallId,
              climbedAt: DateTime.utc(2026, 7, 1),
              style: AscentStyle.redpoint,
            ),
          );

          await tester.pumpWidget(
            wrapWithScale(container, const LogbookScreen(), 3.0),
          );
          await _drain(tester);

          expect(tester.takeException(), isNull);
        },
      );
    },
  );
}
