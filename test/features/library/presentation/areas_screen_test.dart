import 'dart:async';

import 'package:masi/app/router.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/library/data/library_crud_repository.dart';
import 'package:masi/features/library/presentation/areas_screen.dart';
import 'package:masi/features/library/presentation/sectors_screen.dart';
import 'package:masi/shared/presentation/masi_async_view.dart';
import 'package:masi/shared/presentation/masi_skeleton.dart';
import 'package:drift/native.dart';
import 'package:flutter/cupertino.dart';
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
/// background executor isolate.
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

/// Advances real asynchronous work (Drift's in-memory background executor —
/// stream re-queries AND awaited futures) that would otherwise never make
/// progress under `testWidgets`' fake-async clock, then pumps to flush the
/// resulting Riverpod-triggered rebuilds and any in-flight route/dialog
/// transitions.
///
/// A bare `pumpAndSettle` can't be used up front: until the watch stream's
/// first emission lands the library screens render a shimmering
/// [MasiSkeletonList], and pumpAndSettle would spin forever on that unbounded
/// animation because the fake clock never lets Drift's background isolate emit
/// (see the M3 NOTE in test/widget_test.dart). So this first interleaves
/// `runAsync` (real clock, lets Drift emit) with a fixed-duration `pump` (fake
/// clock, advances rebuilds) to get past the loading state, and only THEN
/// settles.
///
/// Note the interaction with `MasiMotion.loadingRevealDelay`: phase 1 advances
/// 180 ms of FAKE time in total, i.e. right up to the skeleton's reveal, so a
/// stream that does emit gets its data on screen before any shimmer starts and
/// the trailing settle stays safe. A provider that never emits at all must not
/// use this helper.
Future<void> _drain(WidgetTester tester) async {
  await drainAsync(tester, rounds: 6, settle: false);
  // The Drift-backed stream has now emitted (real data on screen), so no
  // unbounded spinner remains and pumpAndSettle is safe here: it flushes
  // bounded motion the fixed pumps above may not have finished — dialog
  // open/close transitions (otherwise the dialog's TextField lingers and
  // double-matches a just-created item) and microtask-delivered AsyncError
  // rebuilds.
  await tester.pumpAndSettle();
}

/// A stream that immediately errors when listened — a reliably-delivered
/// AsyncError source for the error-state test (unlike `Stream.error`, whose
/// close-after-error timing can race the widget's first build under the test
/// clock). A fresh instance is returned per provider (re)build, so the Retry
/// button's `ref.invalidate` re-errors rather than resubscribing a spent
/// single-subscription stream.
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

void main() {
  group('A1: AreasScreen empty state + create', () {
    testWidgets(
      'empty DB shows the empty state; add FAB opens a dialog; entering a '
      'name + confirm creates an area and the list then shows it',
      (tester) async {
        final container = _makeContainer();

        await tester.pumpWidget(_wrap(container, const AreasScreen()));
        await _drain(tester);

        expect(
          find.text('No areas yet — tap + to add one'),
          findsOneWidget,
        );

        await tester.tap(find.byKey(const Key('area-add-fab')));
        await _drain(tester);

        expect(find.byKey(const Key('crud-name-field')), findsOneWidget);

        await tester.enterText(
          find.byKey(const Key('crud-name-field')),
          'Frankenjura',
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('crud-name-submit')));
        // Dismiss the dialog (safe: data already loaded, so no unbounded
        // spinner is on screen), THEN drain Drift's real async so the write
        // lands and the watch stream re-emits.
        await tester.pumpAndSettle();
        await _drain(tester);

        expect(find.byKey(const Key('crud-name-field')), findsNothing);
        final areas = await _dbWork(
          tester,
          () => container.read(libraryCrudRepositoryProvider).listAreas(),
        );
        final createdArea = areas.singleWhere((a) => a.name == 'Frankenjura');
        // Scope to the row's card (via its Key): a bare find.text also
        // matches the dialog's EditableText while the dialog is still
        // animating out.
        expect(
          find.descendant(
            of: find.byKey(Key('area-item-${createdArea.id}')),
            matching: find.text('Frankenjura'),
          ),
          findsOneWidget,
        );
        expect(
          find.text('No areas yet — tap + to add one'),
          findsNothing,
        );
      },
    );
  });

  group('A6: empty-name create is blocked', () {
    testWidgets(
      'submit is disabled for an empty/whitespace name; no area is created',
      (tester) async {
        final container = _makeContainer();

        await tester.pumpWidget(_wrap(container, const AreasScreen()));
        await _drain(tester);

        await tester.tap(find.byKey(const Key('area-add-fab')));
        await _drain(tester);

        final submitButton = tester.widget<CupertinoDialogAction>(
          find.byKey(const Key('crud-name-submit')),
        );
        expect(
          submitButton.onPressed,
          isNull,
          reason: 'submit must be disabled while the field is empty',
        );

        await tester.enterText(
          find.byKey(const Key('crud-name-field')),
          '   ',
        );
        await tester.pump();

        final submitAfterWhitespace = tester.widget<CupertinoDialogAction>(
          find.byKey(const Key('crud-name-submit')),
        );
        expect(
          submitAfterWhitespace.onPressed,
          isNull,
          reason: 'whitespace-only input must not enable submit',
        );

        // Dismiss the dialog without creating anything.
        await tester.tap(find.text('Cancel'));
        await _drain(tester);

        expect(
          find.text('No areas yet — tap + to add one'),
          findsOneWidget,
        );
        final areas = await _dbWork(
          tester,
          () => container.read(libraryCrudRepositoryProvider).listAreas(),
        );
        expect(areas, isEmpty);
      },
    );
  });

  group('A3: delete confirm flow', () {
    testWidgets(
      'delete icon opens a confirm dialog; confirming calls softDelete and '
      'the item disappears',
      (tester) async {
        final container = _makeContainer();
        final area = await _dbWork(
          tester,
          () => container
              .read(libraryCrudRepositoryProvider)
              .createArea('Squamish'),
        );

        await tester.pumpWidget(_wrap(container, const AreasScreen()));
        await _drain(tester);

        expect(find.text('Squamish'), findsOneWidget);

        await tester.tap(find.byKey(Key('area-delete-${area.id}')));
        await _drain(tester);

        // Confirm sheet (CupertinoActionSheet) is up; the area must still
        // be present underneath.
        expect(find.text('Delete "Squamish"?'), findsOneWidget);

        await tester.tap(find.byKey(Key('area-delete-confirm-${area.id}')));
        await _drain(tester);

        expect(find.text('Squamish'), findsNothing);
        expect(
          find.text('No areas yet — tap + to add one'),
          findsOneWidget,
        );
        final areas = await _dbWork(
          tester,
          () => container.read(libraryCrudRepositoryProvider).listAreas(),
        );
        expect(areas, isEmpty);
      },
    );

    testWidgets('cancelling the confirm dialog keeps the item', (
      tester,
    ) async {
      final container = _makeContainer();
      final area = await _dbWork(
        tester,
        () => container
            .read(libraryCrudRepositoryProvider)
            .createArea('Squamish'),
      );

      await tester.pumpWidget(_wrap(container, const AreasScreen()));
      await _drain(tester);

      await tester.tap(find.byKey(Key('area-delete-${area.id}')));
      await _drain(tester);

      await tester.tap(find.text('Cancel'));
      await _drain(tester);

      expect(find.text('Squamish'), findsOneWidget);
    });
  });

  group('A5: loading and error AsyncValue states', () {
    testWidgets('loading shows a shaped skeleton, and only after the '
        'anti-flash window', (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          nowMsProvider.overrideWithValue(() => 1000),
          // A stream backed by a never-completing future stays in
          // AsyncLoading indefinitely, so the loading state is always on
          // screen.
          areasProvider.overrideWith(
            (ref) => Completer<List<AreaRef>>().future.asStream(),
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(_wrap(container, const AreasScreen()));
      await tester.pump();

      // Inside `MasiMotion.loadingRevealDelay` nothing loading-ish may be
      // painted at all — a skeleton that flashes for 80 ms reads as a bug.
      expect(
        find.byKey(MasiSkeletonList.listKey),
        findsNothing,
        reason: 'a load that resolves inside the reveal delay must paint no '
            'loading state whatsoever',
      );

      // Past it: the shape of the list that is coming, not a bare spinner.
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byKey(MasiSkeletonList.listKey), findsOneWidget);
      expect(find.byType(MasiSkeletonListRow), findsWidgets);
      expect(
        find.text('No areas yet — tap + to add one'),
        findsNothing,
        reason: 'the empty state must never stand in for "still loading" — '
            'that is the confusion the skeleton exists to end',
      );
      // The shimmer never settles, so this test must not pumpAndSettle.
    });

    testWidgets(
      'error state renders the message + a Retry that invalidates the '
      'provider, without crashing',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        var callCount = 0;
        final container = ProviderContainer(
          // Riverpod v3 re-runs a failed provider on its own, with exponential
          // backoff. That is not what this test is about, and leaving it on
          // makes it lie in both directions: `callCount` climbs without anyone
          // pressing anything, and whichever backoff timer is pending when the
          // body ends trips flutter_test's "a Timer is still pending" invariant
          // (the container outlives the tree — `addTearDown` runs LIFO). Off,
          // so every re-invocation counted below is the MANUAL retry.
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

        // The failure sentence names what could not be loaded — "Something
        // went wrong: <exception>" told the user nothing they could act on.
        expect(find.text("Couldn't load your areas"), findsOneWidget);
        expect(find.byKey(MasiAsyncView.errorKey), findsOneWidget);
        expect(find.byKey(MasiAsyncView.retryKey), findsOneWidget);
        final callsAfterFirstBuild = callCount;

        await tester.tap(find.byKey(MasiAsyncView.retryKey));
        await _drain(tester);

        // Invalidation re-creates the provider (re-invoking its create
        // callback), and the screen keeps rendering the error state without
        // crashing.
        expect(callCount, greaterThan(callsAfterFirstBuild));
        expect(find.text("Couldn't load your areas"), findsOneWidget);
      },
    );
  });

  group('A2: tapping an area navigates to /areas/:areaId/sectors', () {
    testWidgets(
      "threads the tapped area's id and name into SectorsScreen",
      (tester) async {
        // Own the container (rather than a framework-managed ProviderScope)
        // so it is disposed in addTearDown — i.e. in real async AFTER the
        // test body — instead of inside the widget tree's fake-async
        // finalizeTree, where Drift's stream-cancel schedules a 0-duration
        // timer that would never fire ("A Timer is still pending").
        final db = AppDatabase(NativeDatabase.memory());
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 1000),
          ],
        );
        addTearDown(db.close);
        addTearDown(container.dispose);
        final repo = container.read(libraryCrudRepositoryProvider);
        late AreaRef areaA;
        late SectorRef sectorInA;
        await tester.runAsync(() async {
          areaA = await repo.createArea('Area A');
          final areaB = await repo.createArea('Area B');
          sectorInA = await repo.createSector(areaA.id, 'Sector in A');
          await repo.createSector(areaB.id, 'Sector in B');
        });

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp.router(
              routerConfig: appRouter,
              // `/` now renders ToposScreen first (see below), which reads
              // MasiColors.of(context) — without this theme, that lookup's
              // ThemeExtension is absent and the very first build crashes.
              theme: MasiTheme.light,
            ),
          ),
        );
        await _drain(tester);

        // `/` now renders ToposScreen (the new flat home), not AreasScreen —
        // navigate to the Areas hierarchy explicitly before exercising it.
        appRouter.go('/areas');
        await _drain(tester);

        expect(find.text('Area A'), findsOneWidget);
        expect(find.text('Area B'), findsOneWidget);

        await tester.tap(find.text('Area A'));
        await _drain(tester);

        // SectorsScreen(areaId: areaA.id) is rendered, with the area's name
        // threaded through as the app-bar title, and only areaA's sectors
        // visible (sectorsProvider is correctly scoped by areaId).
        expect(find.byType(SectorsScreen), findsOneWidget);
        final sectorsScreen = tester.widget<SectorsScreen>(
          find.byType(SectorsScreen),
        );
        expect(sectorsScreen.areaId, areaA.id);
        // Scope the title check to the new screen's AppBar: the previous
        // AreasScreen route may still be mounted beneath the new one, so a
        // bare find.text('Area A') could also match its ListTile.
        expect(
          find.descendant(
            of: find.byType(AppBar),
            matching: find.text('Area A'),
          ),
          findsOneWidget,
        );
        expect(find.text('Sector in A'), findsOneWidget);
        expect(find.text('Sector in B'), findsNothing);
        expect(sectorInA.areaId, areaA.id);

        // This test uses a real (owning) ProviderScope, so unmount the whole
        // tree here so Riverpod disposes the StreamProviders and cancels their
        // live Drift watch subscriptions now. Draining lets Drift's
        // stream-close cleanup timer run to completion instead of being left
        // pending (which trips the "Timer still pending after the widget tree
        // was disposed" invariant), and means the addTearDown `db.close` later
        // closes the DB with no live watch subscription still attached (which
        // would otherwise hang on "Cannot add event while adding stream").
        await tester.pumpWidget(const SizedBox());
        await _drain(tester);
      },
    );
  });
}
