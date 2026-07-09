import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/core/db/database_provider.dart';
import 'package:climbtopo/features/library/application/library_providers.dart';
import 'package:climbtopo/features/library/data/library_crud_repository.dart';
import 'package:climbtopo/features/library/presentation/sectors_screen.dart';
import 'package:climbtopo/features/library/presentation/walls_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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
    child: MaterialApp(home: child),
  );
}

/// See the doc on `_drain` in areas_screen_test.dart: advances Drift's real
/// in-memory async under `testWidgets`' fake clock (which never would on its
/// own), then pumps to flush rebuilds/transitions — no `pumpAndSettle`, so
/// the loading spinner can never hang the test.
Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 30));
  }
}

/// Runs [body]'s real Drift async work under the real event loop.
Future<T> _dbWork<T>(WidgetTester tester, Future<T> Function() body) async {
  late T result;
  await tester.runAsync(() async {
    result = await body();
  });
  return result;
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
        expect(find.widgetWithText(ListTile, 'Sector A1'), findsOneWidget);
        final sectorsInA = await _dbWork(
          tester,
          () => repo.listSectors(areaA.id),
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
        expect(find.widgetWithText(ListTile, 'Wall A1'), findsOneWidget);
        final wallsInA = await _dbWork(
          tester,
          () => repo.listWalls(sectorA.id),
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
}
