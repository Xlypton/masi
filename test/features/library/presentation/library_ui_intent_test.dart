// Intended-behavior UI tests for Subtask A6 (library CRUD + topos home +
// empty/error states + canvas title). These assertions are derived from the
// SPEC (MASI.md / DESIGN.md contract items J2/J3/K1/K3/K6 — see
// `## Harness facts` and `### Subtask A6` in
// `/Users/kerip/.claude/plans/masi-intended-behavior-ui-tests.md`), NOT from
// whatever the current code happens to do. A failing assertion here is
// EXPECTED and identifies a real bug — do not weaken/skip/bend an assertion
// to make it pass, and do not edit anything under lib/.
//
// Pump/seed/drain patterns are copied verbatim from
// `test/features/library/presentation/areas_screen_test.dart`,
// `sectors_walls_screen_test.dart`, and `topos_screen_test.dart`.

import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/backup/application/sync_orchestrator.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/library/data/library_crud_repository.dart';
import 'package:masi/features/library/presentation/areas_screen.dart';
import 'package:masi/features/library/presentation/sectors_screen.dart';
import 'package:masi/features/library/presentation/topos_screen.dart';
import 'package:masi/features/library/presentation/walls_screen.dart';
import 'package:masi/features/topo/presentation/topo_canvas_screen.dart';
import 'package:masi/shared/presentation/masi_async_view.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../../support/async_drain.dart';

/// Builds a [ProviderContainer] wired to a fresh in-memory database and
/// registers teardown of both the container and the database connection.
///
/// addTearDown runs LIFO, so `db.close` is registered first: the container
/// must be disposed (cancelling Riverpod's live watch subscriptions) BEFORE
/// the underlying Drift connection is closed, otherwise closing the database
/// out from under a still-active watch stream hangs waiting on the
/// background executor isolate. (Mirrors `areas_screen_test.dart`.)
///
/// [syncOrchestratorProvider] is overridden to a no-op [_FakeSyncOrchestrator]
/// (test-harness only — nothing under `lib/` changes) -- #72 P1 fix:
/// `ToposScreen`'s empty-state branch now `ref.watch`es
/// `syncOrchestratorProvider` (see `topos_screen.dart`'s `build`), which
/// this file's A6e group reaches by seeding rows into a genuinely-empty
/// screen. In PRODUCTION that's a no-op (`MasiApp` already keeps the REAL
/// orchestrator alive for the whole app run well before `ToposScreen` ever
/// renders), but a bare widget test here has no such root: without this,
/// the real `SyncOrchestrator`'s live `tableUpdates()` subscription would
/// tick on that seed write and schedule a genuine 2-second debounce `Timer`
/// that outlives the test, tripping flutter_test's "A Timer is still
/// pending" teardown assertion. Mirrors `topos_screen_test.dart`'s
/// identical fix.
ProviderContainer _makeContainer() {
  final db = AppDatabase(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      nowMsProvider.overrideWithValue(() => 1000),
      syncOrchestratorProvider.overrideWith(() => _FakeSyncOrchestrator()),
    ],
  );
  addTearDown(db.close);
  addTearDown(container.dispose);
  return container;
}

/// A [SyncOrchestrator] test double that skips ALL of the real class's
/// wiring (`build()`'s `ref.watch(appDatabaseProvider)` /
/// `ref.listen(authStateProvider, ...)` / `tableUpdates()` subscription) --
/// mirrors `community_pull_refresh_test.dart`'s/`topos_screen_test.dart`'s
/// identical class (duplicated locally since those are file-private). This
/// file never taps a retry affordance, so [pullNow] doesn't need to count
/// calls -- just resolve immediately.
class _FakeSyncOrchestrator extends SyncOrchestrator {
  @override
  SyncOrchestratorState build() => const SyncOrchestratorState();

  @override
  Future<void> pullNow({bool throttled = false}) async {}
}

/// Plain (router-less) wrap: every screen exercised in this file only calls
/// `context.push`/`pop`/`go` inside button `onPressed` handlers this suite
/// never taps (Organize, row-tap, back, AR) — see the research backing
/// Subtask A6 — so a real `GoRouter` is unnecessary. `MaterialApp` alone
/// supplies the `MasiColors.of(context)` theme lookup every one of these
/// screens needs on its very first build.
Widget _wrap(ProviderContainer container, Widget child) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(home: child, theme: MasiTheme.light),
  );
}

/// Advances real asynchronous work (Drift's in-memory background executor —
/// stream re-queries AND awaited futures) that would otherwise never make
/// progress under `testWidgets`' fake-async clock, then pumps to flush the
/// resulting Riverpod-triggered rebuilds and any in-flight route/dialog
/// transitions. Copied verbatim from `areas_screen_test.dart`.
Future<void> _drain(WidgetTester tester) async {
  await drainAsync(tester, rounds: 6, settle: false);
  await tester.pumpAndSettle();
}

/// A stream that immediately errors when listened — a reliably-delivered
/// AsyncError source for the error-state test. Copied from
/// `areas_screen_test.dart`.
Stream<List<AreaRef>> _boomStream() async* {
  throw Exception('boom');
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

/// Types the given [name] into the shared `crud-name-field` dialog and taps
/// `crud-name-submit`, then dismisses/drains. Mirrors the inline sequence
/// used repeatedly in `areas_screen_test.dart` / `sectors_walls_screen_test.dart`.
Future<void> _submitNameDialog(WidgetTester tester, String name) async {
  expect(find.byKey(const Key('crud-name-field')), findsOneWidget);
  await tester.enterText(find.byKey(const Key('crud-name-field')), name);
  await tester.pump();
  await tester.tap(find.byKey(const Key('crud-name-submit')));
  await tester.pumpAndSettle();
  await _drain(tester);
}

void main() {
  group('A6a: <entity>-add-fab + crud-name-field/submit creates an item '
      'that appears as <entity>-item-<id>', () {
    testWidgets(
      'Area, Sector, and Wall list screens each support create-via-fab',
      (tester) async {
        final container = _makeContainer();
        final repo = container.read(libraryCrudRepositoryProvider);

        // --- Area ---
        await tester.pumpWidget(_wrap(container, const AreasScreen()));
        await _drain(tester);

        await tester.tap(find.byKey(const Key('area-add-fab')));
        await _drain(tester);
        await _submitNameDialog(tester, 'Frankenjura');

        final areas = await _dbWork(tester, () => repo.listAreas());
        final area = areas.singleWhere((a) => a.name == 'Frankenjura');
        expect(find.byKey(Key('area-item-${area.id}')), findsOneWidget);

        // Unmount before switching screens: cancels the live watch stream
        // cleanly (see the AreasScreen->SectorsScreen navigation test in
        // areas_screen_test.dart for the same rationale).
        await tester.pumpWidget(const SizedBox());
        await _drain(tester);

        // --- Sector (scoped to the just-created area) ---
        await tester.pumpWidget(
          _wrap(container, SectorsScreen(areaId: area.id)),
        );
        await _drain(tester);

        await tester.tap(find.byKey(const Key('sector-add-fab')));
        await _drain(tester);
        await _submitNameDialog(tester, 'Sector One');

        final sectors = await _dbWork(tester, () => repo.listSectors(area.id));
        final sector = sectors.singleWhere((s) => s.name == 'Sector One');
        expect(find.byKey(Key('sector-item-${sector.id}')), findsOneWidget);

        await tester.pumpWidget(const SizedBox());
        await _drain(tester);

        // --- Wall (scoped to the just-created sector) ---
        await tester.pumpWidget(
          _wrap(container, WallsScreen(sectorId: sector.id)),
        );
        await _drain(tester);

        await tester.tap(find.byKey(const Key('wall-add-fab')));
        await _drain(tester);
        await _submitNameDialog(tester, 'Wall One');

        final walls = await _dbWork(tester, () => repo.listWalls(sector.id));
        final wall = walls.singleWhere((w) => w.name == 'Wall One');
        expect(find.byKey(Key('wall-item-${wall.id}')), findsOneWidget);

        await tester.pumpWidget(const SizedBox());
        await _drain(tester);
      },
    );
  });

  group('A6b: <entity>-rename-<id> edits the name (reflected in the row)', () {
    testWidgets(
      'renaming an Area, a Sector, and a Wall each updates the displayed '
      'name in place',
      (tester) async {
        final container = _makeContainer();
        final repo = container.read(libraryCrudRepositoryProvider);
        late AreaRef area;
        late SectorRef sector;
        late WallRef wall;
        await tester.runAsync(() async {
          area = await repo.createArea('Old Area');
          sector = await repo.createSector(area.id, 'Old Sector');
          wall = await repo.createWall(sector.id, 'Old Wall');
        });

        // --- Area rename ---
        await tester.pumpWidget(_wrap(container, const AreasScreen()));
        await _drain(tester);
        expect(find.text('Old Area'), findsOneWidget);

        await tester.tap(find.byKey(Key('area-rename-${area.id}')));
        await _drain(tester);
        await _submitNameDialog(tester, 'New Area');

        expect(find.text('New Area'), findsOneWidget);
        expect(find.text('Old Area'), findsNothing);

        await tester.pumpWidget(const SizedBox());
        await _drain(tester);

        // --- Sector rename ---
        await tester.pumpWidget(
          _wrap(container, SectorsScreen(areaId: area.id)),
        );
        await _drain(tester);
        expect(find.text('Old Sector'), findsOneWidget);

        await tester.tap(find.byKey(Key('sector-rename-${sector.id}')));
        await _drain(tester);
        await _submitNameDialog(tester, 'New Sector');

        expect(find.text('New Sector'), findsOneWidget);
        expect(find.text('Old Sector'), findsNothing);

        await tester.pumpWidget(const SizedBox());
        await _drain(tester);

        // --- Wall rename ---
        await tester.pumpWidget(
          _wrap(container, WallsScreen(sectorId: sector.id)),
        );
        await _drain(tester);
        expect(find.text('Old Wall'), findsOneWidget);

        await tester.tap(find.byKey(Key('wall-rename-${wall.id}')));
        await _drain(tester);
        await _submitNameDialog(tester, 'New Wall');

        expect(find.text('New Wall'), findsOneWidget);
        expect(find.text('Old Wall'), findsNothing);

        await tester.pumpWidget(const SizedBox());
        await _drain(tester);
      },
    );
  });

  group(
    'A6c: <entity>-delete-<id> opens a confirm sheet; the item is removed '
    'ONLY after <entity>-delete-confirm-<id>; cancelling keeps it',
    () {
      testWidgets(
        'Area: delete opens a confirm sheet, cancel keeps the item, '
        'confirm removes it',
        (tester) async {
          final container = _makeContainer();
          final repo = container.read(libraryCrudRepositoryProvider);
          late AreaRef area;
          await tester.runAsync(() async {
            area = await repo.createArea('Squamish');
          });

          await tester.pumpWidget(_wrap(container, const AreasScreen()));
          await _drain(tester);
          expect(find.text('Squamish'), findsOneWidget);

          // Tapping delete opens the confirm sheet WITHOUT removing the item.
          await tester.tap(find.byKey(Key('area-delete-${area.id}')));
          await _drain(tester);
          expect(
            find.byKey(Key('area-delete-confirm-${area.id}')),
            findsOneWidget,
          );
          expect(find.text('Squamish'), findsOneWidget);

          // Cancelling the sheet keeps the item.
          await tester.tap(find.text('Cancel'));
          await _drain(tester);
          expect(find.text('Squamish'), findsOneWidget);
          final areasAfterCancel = await _dbWork(
            tester,
            () => repo.listAreas(),
          );
          expect(areasAfterCancel.map((a) => a.name), contains('Squamish'));

          // Re-open and confirm: NOW it is removed.
          await tester.tap(find.byKey(Key('area-delete-${area.id}')));
          await _drain(tester);
          await tester.tap(find.byKey(Key('area-delete-confirm-${area.id}')));
          await _drain(tester);

          expect(find.text('Squamish'), findsNothing);
          final areasAfterConfirm = await _dbWork(
            tester,
            () => repo.listAreas(),
          );
          expect(areasAfterConfirm.map((a) => a.name), isNot(contains('Squamish')));

          await tester.pumpWidget(const SizedBox());
          await _drain(tester);
        },
      );

      testWidgets(
        'Sector: delete opens a confirm sheet, cancel keeps the item, '
        'confirm removes it',
        (tester) async {
          final container = _makeContainer();
          final repo = container.read(libraryCrudRepositoryProvider);
          late AreaRef area;
          late SectorRef sector;
          await tester.runAsync(() async {
            area = await repo.createArea('Area');
            sector = await repo.createSector(area.id, 'Sector to delete');
          });

          await tester.pumpWidget(
            _wrap(container, SectorsScreen(areaId: area.id)),
          );
          await _drain(tester);
          expect(find.text('Sector to delete'), findsOneWidget);

          await tester.tap(find.byKey(Key('sector-delete-${sector.id}')));
          await _drain(tester);
          expect(
            find.byKey(Key('sector-delete-confirm-${sector.id}')),
            findsOneWidget,
          );
          expect(find.text('Sector to delete'), findsOneWidget);

          await tester.tap(find.text('Cancel'));
          await _drain(tester);
          expect(find.text('Sector to delete'), findsOneWidget);

          await tester.tap(find.byKey(Key('sector-delete-${sector.id}')));
          await _drain(tester);
          await tester.tap(
            find.byKey(Key('sector-delete-confirm-${sector.id}')),
          );
          await _drain(tester);

          expect(find.text('Sector to delete'), findsNothing);

          await tester.pumpWidget(const SizedBox());
          await _drain(tester);
        },
      );

      testWidgets(
        'Wall: delete opens a confirm sheet, cancel keeps the item, '
        'confirm removes it',
        (tester) async {
          final container = _makeContainer();
          final repo = container.read(libraryCrudRepositoryProvider);
          late SectorRef sector;
          late WallRef wall;
          await tester.runAsync(() async {
            final area = await repo.createArea('Area');
            sector = await repo.createSector(area.id, 'Sector');
            wall = await repo.createWall(sector.id, 'Wall to delete');
          });

          await tester.pumpWidget(
            _wrap(container, WallsScreen(sectorId: sector.id)),
          );
          await _drain(tester);
          expect(find.text('Wall to delete'), findsOneWidget);

          await tester.tap(find.byKey(Key('wall-delete-${wall.id}')));
          await _drain(tester);
          expect(
            find.byKey(Key('wall-delete-confirm-${wall.id}')),
            findsOneWidget,
          );
          expect(find.text('Wall to delete'), findsOneWidget);

          await tester.tap(find.text('Cancel'));
          await _drain(tester);
          expect(find.text('Wall to delete'), findsOneWidget);

          await tester.tap(find.byKey(Key('wall-delete-${wall.id}')));
          await _drain(tester);
          await tester.tap(find.byKey(Key('wall-delete-confirm-${wall.id}')));
          await _drain(tester);

          expect(find.text('Wall to delete'), findsNothing);

          await tester.pumpWidget(const SizedBox());
          await _drain(tester);
        },
      );
    },
  );

  group(
    'A6d: empty area list shows its empty state; error state shows retry',
    () {
      testWidgets('empty DB shows the AreasScreen empty state', (
        tester,
      ) async {
        final container = _makeContainer();

        await tester.pumpWidget(_wrap(container, const AreasScreen()));
        await _drain(tester);

        expect(find.text('No areas yet — tap + to add one'), findsOneWidget);
      });

      testWidgets(
        'an AsyncError renders a retry affordance that re-invokes the '
        'provider, without crashing',
        (tester) async {
          final db = AppDatabase(NativeDatabase.memory());
          addTearDown(db.close);
          var callCount = 0;
          final container = ProviderContainer(
            // See `areas_screen_test.dart`'s twin: Riverpod v3's own backoff
            // retries would both inflate `callCount` and leave a pending timer
            // behind, so the only re-invocation this test can observe is the
            // manual one it performs.
            retry: (retryCount, error) => null,
            overrides: [
              appDatabaseProvider.overrideWithValue(db),
              nowMsProvider.overrideWithValue(() => 1000),
              areasProvider.overrideWith((ref) {
                callCount++;
                return _boomStream();
              }),
            ],
          );
          addTearDown(container.dispose);

          await tester.pumpWidget(_wrap(container, const AreasScreen()));
          await _drain(tester);

          // Same intent as before, restated against the shared failure state
          // the screen now delegates to (`MasiAsyncView`): a sentence naming
          // what could not be loaded, plus something to press. The generic
          // "Something went wrong: <exception>" line and the per-entity
          // `area-retry` key are gone, not the requirement.
          expect(find.text("Couldn't load your areas"), findsOneWidget);
          expect(find.byKey(MasiAsyncView.retryKey), findsOneWidget);
          final callsAfterFirstBuild = callCount;

          await tester.tap(find.byKey(MasiAsyncView.retryKey));
          await _drain(tester);

          expect(callCount, greaterThan(callsAfterFirstBuild));
          expect(tester.takeException(), isNull);
        },
      );
    },
  );

  group(
    'A6e: Topos home — empty vs populated',
    () {
      testWidgets(
        'empty shows topos-empty-state + topos-new-topo; populated shows '
        'one topo-item-<wallId> per wall plus topos-organize',
        (tester) async {
          final container = _makeContainer();
          final repo = container.read(libraryCrudRepositoryProvider);

          // Empty.
          await tester.pumpWidget(_wrap(container, const ToposScreen()));
          await _drain(tester);

          expect(find.byKey(const Key('topos-empty-state')), findsOneWidget);
          expect(find.byKey(const Key('topos-new-topo')), findsOneWidget);

          await tester.pumpWidget(const SizedBox());
          await _drain(tester);

          // Populate with two topos (each a wall under a hidden default
          // area/sector, per LibraryCrudRepository.createTopo).
          late String wallId1;
          late String wallId2;
          await tester.runAsync(() async {
            wallId1 = await repo.createTopo('Topo A');
            wallId2 = await repo.createTopo('Topo B');
          });

          await tester.pumpWidget(_wrap(container, const ToposScreen()));
          await _drain(tester);

          expect(find.byKey(Key('topo-item-$wallId1')), findsOneWidget);
          expect(find.byKey(Key('topo-item-$wallId2')), findsOneWidget);
          expect(
            find.descendant(
              of: find.byType(AppBar),
              matching: find.byKey(const Key('topos-organize')),
            ),
            findsOneWidget,
          );

          await tester.pumpWidget(const SizedBox());
          await _drain(tester);
        },
      );
    },
  );

  group(
    'A6f: canvas nav title equals the wall name (never the literal app '
    'name), truncating with an ellipsis',
    () {
      testWidgets(
        'a wall named "North Face" renders that exact string as the nav '
        'title, with maxLines 1 and TextOverflow.ellipsis — never '
        '"Masi" or "masi"',
        (tester) async {
          final container = _makeContainer();
          final repo = container.read(libraryCrudRepositoryProvider);
          late WallRef wall;
          await tester.runAsync(() async {
            final area = await repo.createArea('Area');
            final sector = await repo.createSector(area.id, 'Sector');
            wall = await repo.createWall(sector.id, 'North Face');
          });

          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp(
                theme: MasiTheme.light,
                home: TopoCanvasScreen(wallId: wall.id),
              ),
            ),
          );
          await tester.pumpAndSettle();

          expect(
            find.text('Masi'),
            findsNothing,
            reason: 'nav title must never be the literal app name',
          );
          expect(find.text('masi'), findsNothing);
          expect(find.text('North Face'), findsOneWidget);

          final titleText = tester.widget<Text>(find.text('North Face'));
          expect(titleText.maxLines, 1);
          expect(titleText.overflow, TextOverflow.ellipsis);

          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
        },
      );
    },
  );
}
