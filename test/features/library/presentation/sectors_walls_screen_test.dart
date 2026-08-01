import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/library/data/library_crud_repository.dart';
import 'package:masi/features/library/presentation/sectors_screen.dart';
import 'package:masi/features/library/presentation/walls_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../../support/async_drain.dart';

/// Mirrors `_makeContainer` in areas_screen_test.dart: an in-memory DB + a
/// fixed clock, with db.close registered before container.dispose (LIFO)
/// so tearing down doesn't hang a still-live watch stream.
ProviderContainer _makeContainer() {
  final db = AppDatabase(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      nowMsProvider.overrideWithValue(() => 1000),
    ],
  );
  addTearDown(db.close);
  addTearDown(container.dispose);
  return container;
}

Widget _wrap(ProviderContainer container, Widget child) {
  return UncontrolledProviderScope(
    container: container,
    // The restyled CrudListScaffold reads MasiColors.of(context) — without
    // this theme registered, that ThemeExtension lookup null-check-crashes
    // on the very first build.
    child: MaterialApp(home: child, theme: MasiTheme.light),
  );
}

/// See the doc on `_drain` in areas_screen_test.dart: advances Drift's real
/// in-memory async under `testWidgets`' fake clock (which never would on its
/// own), then pumps to flush rebuilds/transitions — no `pumpAndSettle`, so
/// the loading spinner can never hang the test.
Future<void> _drain(WidgetTester tester) async {
  await drainAsync(tester, rounds: 6, settle: false);
}

/// Runs [body]'s real Drift async work under the real event loop.
Future<T> _dbWork<T>(WidgetTester tester, Future<T> Function() body) async {
  late T result;
  await tester.runAsync(() async {
    result = await body();
  });
  return result;
}

/// A [LibraryCrudRepository] whose [moveSector] always throws, leaving
/// every other method backed by the real implementation against [db]. Used
/// to prove `SectorsScreen._handleMove`'s `await repo.moveSector(...)` is
/// guarded: a move failure (e.g. the destination area got hard-deleted
/// between the picker opening and the tap, tripping the `PRAGMA
/// foreign_keys = ON` FK check) must surface as an error SnackBar, never an
/// unhandled async error. Mirrors `topos_screen_test.dart`'s
/// `_ThrowingMoveWallRepository`.
class _ThrowingMoveSectorRepository extends LibraryCrudRepository {
  _ThrowingMoveSectorRepository(super.db, {required super.nowMs});

  @override
  Future<void> moveSector(String sectorId, String newAreaId) {
    throw Exception('moveSector boom (test)');
  }
}

void main() {
  group('A4: SectorsScreen(areaId) scoping + create + delete', () {
    testWidgets(
      'only renders sectors for the given areaId; create is scoped to it; '
      'delete removes just that sector',
      (tester) async {
        final container = _makeContainer();
        final repo = container.read(libraryCrudRepositoryProvider);
        late AreaRef areaA;
        late AreaRef areaB;
        late SectorRef sectorA;
        await tester.runAsync(() async {
          areaA = await repo.createArea('Area A');
          areaB = await repo.createArea('Area B');
          sectorA = await repo.createSector(areaA.id, 'Sector A0');
          await repo.createSector(areaB.id, 'Sector B0');
        });

        await tester.pumpWidget(
          _wrap(container, SectorsScreen(areaId: areaA.id)),
        );
        await _drain(tester);

        expect(find.text('Sector A0'), findsOneWidget);
        expect(find.text('Sector B0'), findsNothing);

        // Create, scoped to areaA.
        await tester.tap(find.byKey(const Key('sector-add-fab')));
        await _drain(tester);
        await tester.enterText(
          find.byKey(const Key('crud-name-field')),
          'Sector A1',
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('crud-name-submit')));
        await tester.pumpAndSettle();
        await _drain(tester);

        expect(find.byKey(const Key('crud-name-field')), findsNothing);
        final sectorsInA = await _dbWork(
          tester,
          () => repo.listSectors(areaA.id),
        );
        final createdSectorA1 = sectorsInA.singleWhere(
          (s) => s.name == 'Sector A1',
        );
        // Scope to the row's card (via its Key): a bare find.text also
        // matches the dialog's EditableText while the dialog is still
        // animating out.
        expect(
          find.descendant(
            of: find.byKey(Key('sector-item-${createdSectorA1.id}')),
            matching: find.text('Sector A1'),
          ),
          findsOneWidget,
        );
        expect(sectorsInA.map((s) => s.name), contains('Sector A1'));
        expect(
          sectorsInA.every((s) => s.areaId == areaA.id),
          isTrue,
          reason: 'created sector must be scoped to areaA, not areaB',
        );

        // Delete Sector A0.
        await tester.tap(find.byKey(Key('sector-delete-${sectorA.id}')));
        await _drain(tester);
        await tester.tap(
          find.byKey(Key('sector-delete-confirm-${sectorA.id}')),
        );
        await _drain(tester);

        expect(find.text('Sector A0'), findsNothing);
        expect(find.text('Sector A1'), findsOneWidget);
        // areaB's sector is untouched.
        final sectorsInB = await _dbWork(
          tester,
          () => repo.listSectors(areaB.id),
        );
        expect(sectorsInB.map((s) => s.name), ['Sector B0']);
      },
    );

    testWidgets('empty state when the scoped area has no sectors yet', (
      tester,
    ) async {
      final container = _makeContainer();
      final area = await _dbWork(
        tester,
        () => container.read(libraryCrudRepositoryProvider).createArea('Area'),
      );

      await tester.pumpWidget(
        _wrap(container, SectorsScreen(areaId: area.id)),
      );
      await _drain(tester);

      expect(find.text('No sectors yet — tap + to add one'), findsOneWidget);
    });
  });

  group('A4: WallsScreen(sectorId) scoping + create + delete', () {
    testWidgets(
      'only renders walls for the given sectorId; create is scoped to it; '
      'delete removes just that wall',
      (tester) async {
        final container = _makeContainer();
        final repo = container.read(libraryCrudRepositoryProvider);
        late SectorRef sectorA;
        late SectorRef sectorB;
        late WallRef wallA;
        await tester.runAsync(() async {
          final area = await repo.createArea('Area');
          sectorA = await repo.createSector(area.id, 'Sector A');
          sectorB = await repo.createSector(area.id, 'Sector B');
          wallA = await repo.createWall(sectorA.id, 'Wall A0');
          await repo.createWall(sectorB.id, 'Wall B0');
        });

        await tester.pumpWidget(
          _wrap(container, WallsScreen(sectorId: sectorA.id)),
        );
        await _drain(tester);

        expect(find.text('Wall A0'), findsOneWidget);
        expect(find.text('Wall B0'), findsNothing);

        // Create, scoped to sectorA.
        await tester.tap(find.byKey(const Key('wall-add-fab')));
        await _drain(tester);
        await tester.enterText(
          find.byKey(const Key('crud-name-field')),
          'Wall A1',
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('crud-name-submit')));
        await tester.pumpAndSettle();
        await _drain(tester);

        expect(find.byKey(const Key('crud-name-field')), findsNothing);
        final wallsInA = await _dbWork(
          tester,
          () => repo.listWalls(sectorA.id),
        );
        final createdWallA1 = wallsInA.singleWhere(
          (w) => w.name == 'Wall A1',
        );
        // Scope to the row's card (via its Key): a bare find.text also
        // matches the dialog's EditableText while the dialog is still
        // animating out.
        expect(
          find.descendant(
            of: find.byKey(Key('wall-item-${createdWallA1.id}')),
            matching: find.text('Wall A1'),
          ),
          findsOneWidget,
        );
        expect(wallsInA.map((w) => w.name), contains('Wall A1'));
        expect(wallsInA.every((w) => w.sectorId == sectorA.id), isTrue);

        // Delete Wall A0.
        await tester.tap(find.byKey(Key('wall-delete-${wallA.id}')));
        await _drain(tester);
        await tester.tap(find.byKey(Key('wall-delete-confirm-${wallA.id}')));
        await _drain(tester);

        expect(find.text('Wall A0'), findsNothing);
        expect(find.text('Wall A1'), findsOneWidget);
        final wallsInB = await _dbWork(
          tester,
          () => repo.listWalls(sectorB.id),
        );
        expect(wallsInB.map((w) => w.name), ['Wall B0']);
      },
    );

    testWidgets('empty state when the scoped sector has no walls yet', (
      tester,
    ) async {
      final container = _makeContainer();
      final repo = container.read(libraryCrudRepositoryProvider);
      late SectorRef sector;
      await tester.runAsync(() async {
        final area = await repo.createArea('Area');
        sector = await repo.createSector(area.id, 'Sector');
      });

      await tester.pumpWidget(
        _wrap(container, WallsScreen(sectorId: sector.id)),
      );
      await _drain(tester);

      expect(find.text('No walls yet — tap + to add one'), findsOneWidget);
    });
  });

  group('D8: "Move" — move a sector to another area', () {
    testWidgets(
      'V2: a sector row shows sector-move-<id>; tapping it opens an area '
      'picker; selecting move-target-area-<id> calls moveSector via the '
      'real repo (the sector\'s areaId actually changes -- it disappears '
      'from the source area\'s scoped list) and shows a confirmation '
      'SnackBar',
      (tester) async {
        final container = _makeContainer();
        final repo = container.read(libraryCrudRepositoryProvider);

        final sourceArea = await _dbWork(
          tester,
          () => repo.createArea('Source Area'),
        );
        final destArea = await _dbWork(
          tester,
          () => repo.createArea('Dest Area'),
        );
        final sector = await _dbWork(
          tester,
          () => repo.createSector(sourceArea.id, 'My Sector'),
        );

        await tester.pumpWidget(
          _wrap(container, SectorsScreen(areaId: sourceArea.id)),
        );
        await _drain(tester);

        expect(find.byKey(Key('sector-move-${sector.id}')), findsOneWidget);

        await tester.tap(find.byKey(Key('sector-move-${sector.id}')));
        await _drain(tester);

        expect(find.text('Dest Area'), findsOneWidget);
        expect(
          find.byKey(Key('move-target-area-${destArea.id}')),
          findsOneWidget,
        );

        await tester.tap(find.byKey(Key('move-target-area-${destArea.id}')));
        await _drain(tester);

        final sectorsInSource = await _dbWork(
          tester,
          () => repo.listSectors(sourceArea.id),
        );
        expect(sectorsInSource, isEmpty);
        final sectorsInDest = await _dbWork(
          tester,
          () => repo.listSectors(destArea.id),
        );
        expect(sectorsInDest.map((s) => s.id), contains(sector.id));
        expect(find.text('Moved to Dest Area'), findsOneWidget);
      },
    );

    testWidgets(
      'V3 (own-filter): a FOREIGN-owned area never appears as a candidate; '
      'an unowned (own-device) area does',
      (tester) async {
        final container = _makeContainer();
        final repo = container.read(libraryCrudRepositoryProvider);
        final db = container.read(appDatabaseProvider);

        final sourceArea = await _dbWork(
          tester,
          () => repo.createArea('Source Area'),
        );
        final sector = await _dbWork(
          tester,
          () => repo.createSector(sourceArea.id, 'My Sector'),
        );
        // Own (unowned, this device -- currentUid defaults to null).
        await _dbWork(tester, () => repo.createArea('Own Area'));
        // Foreign -- pulled in locally from discovering someone else's
        // shared topo -- must never be offered as a move destination.
        final foreignRepo = LibraryCrudRepository(
          db,
          nowMs: () => 1000,
          currentUid: () => 'foreign-uid',
        );
        await _dbWork(tester, () => foreignRepo.createArea('Foreign Area'));

        await tester.pumpWidget(
          _wrap(container, SectorsScreen(areaId: sourceArea.id)),
        );
        await _drain(tester);

        await tester.tap(find.byKey(Key('sector-move-${sector.id}')));
        await _drain(tester);

        expect(find.text('Own Area'), findsOneWidget);
        expect(find.text('Foreign Area'), findsNothing);
      },
    );

    testWidgets(
      'V4: the sector\'s CURRENT area is excluded from the candidate list',
      (tester) async {
        final container = _makeContainer();
        final repo = container.read(libraryCrudRepositoryProvider);

        final sourceArea = await _dbWork(
          tester,
          () => repo.createArea('Source Area'),
        );
        await _dbWork(tester, () => repo.createArea('Other Area'));
        final sector = await _dbWork(
          tester,
          () => repo.createSector(sourceArea.id, 'My Sector'),
        );

        await tester.pumpWidget(
          _wrap(container, SectorsScreen(areaId: sourceArea.id)),
        );
        await _drain(tester);

        await tester.tap(find.byKey(Key('sector-move-${sector.id}')));
        await _drain(tester);

        expect(find.text('Source Area'), findsNothing);
        expect(find.text('Other Area'), findsOneWidget);
      },
    );

    testWidgets(
      'E2: a repo whose moveSector throws (e.g. the destination area was '
      'hard-deleted between the picker opening and the tap, tripping the FK '
      'check) shows an error SnackBar and produces NO unhandled exception '
      '(regression -- the bare, un-try/catch-guarded await used to let the '
      'throw escape as a silent, unobserved async error)',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final repo = _ThrowingMoveSectorRepository(db, nowMs: () => 1000);
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 1000),
            libraryCrudRepositoryProvider.overrideWithValue(repo),
          ],
        );
        addTearDown(container.dispose);

        final sourceArea = await _dbWork(
          tester,
          () => repo.createArea('Source Area'),
        );
        final destArea = await _dbWork(
          tester,
          () => repo.createArea('Dest Area'),
        );
        final sector = await _dbWork(
          tester,
          () => repo.createSector(sourceArea.id, 'My Sector'),
        );

        await tester.pumpWidget(
          _wrap(container, SectorsScreen(areaId: sourceArea.id)),
        );
        await _drain(tester);

        await tester.tap(find.byKey(Key('sector-move-${sector.id}')));
        await _drain(tester);

        await tester.tap(find.byKey(Key('move-target-area-${destArea.id}')));
        await _drain(tester);

        expect(
          tester.takeException(),
          isNull,
          reason: 'a move failure must never surface as an unhandled async '
              'error',
        );
        expect(
          find.text("Couldn't move — please try again"),
          findsOneWidget,
        );

        final sectorsInSource = await _dbWork(
          tester,
          () => repo.listSectors(sourceArea.id),
        );
        expect(
          sectorsInSource.map((s) => s.id),
          contains(sector.id),
          reason: 'the throwing moveSector must not have actually moved it',
        );
      },
    );
  });
}
