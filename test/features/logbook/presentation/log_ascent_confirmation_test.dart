// The post-save confirmation on [LogAscentSheet], and the Logbook signpost it
// carries.
//
// Logging an ascent used to end in silence: the sheet popped and nothing said
// the ascent had been written, let alone that a Logbook existed to see it in.
// The confirmation is raised inside the SHARED sheet rather than at either call
// site (`CommunityTopoDetailScreen._openLogAscentSheet` and
// `_TopoCanvasScreenState._openLogAscentSheet`), so both entry points get it
// from one place — these tests drive the shared widget directly, which is what
// makes that coverage claim honest.
//
// Seeding mirrors `log_ascent_sheet_test.dart`'s real Area -> Sector -> Wall ->
// Photo -> Route chain, because `Ascents.wallId`/`Ascents.routeId` are real
// foreign keys and `logAscent` throws against made-up ids.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/logbook/presentation/log_ascent_sheet.dart';
import 'package:masi/features/topo/data/route_repository.dart';
import 'package:masi/features/topo/domain/topo_route.dart';

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
        XFile('/tmp/log-ascent-confirmation-test-photo.jpg'),
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
      ),
    );
    final dbIds = await routeRepo.routeDbIdsByNumber(wall.id);

    return (db: db, container: container, wallId: wall.id, routeDbId: dbIds[1]!);
  }

  /// The harness the real call sites reproduce: a go_router-routed app whose
  /// start route opens [LogAscentSheet] as a modal bottom sheet, plus a marker
  /// widget on `/logbook`.
  ///
  /// A REAL [GoRouter] is the point — the sheet captures the router before
  /// popping itself, since a popped route's context can no longer look one up,
  /// and only a routed harness proves that capture works.
  Future<void> pumpHarness(
    WidgetTester tester,
    ProviderContainer container, {
    required String routeId,
    required String wallId,
  }) async {
    final router = GoRouter(
      initialLocation: '/topo',
      routes: [
        GoRoute(
          path: '/topo',
          builder: (context, state) => Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                key: const Key('open-log-ascent-sheet'),
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => LogAscentSheet(
                    routeId: routeId,
                    wallId: wallId,
                    keyPrefix: 'test',
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/logbook',
          builder: (context, state) =>
              const Scaffold(key: Key('stub-logbook'), body: Text('Logbook')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: MasiTheme.light,
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Seeds, pumps, opens the sheet and saves — leaving the confirmation on
  /// screen.
  Future<void> logAnAscent(WidgetTester tester) async {
    final seeded = await seedWallWithRoute(tester);
    addTearDown(seeded.db.close);
    addTearDown(seeded.container.dispose);

    await pumpHarness(
      tester,
      seeded.container,
      routeId: seeded.routeDbId,
      wallId: seeded.wallId,
    );

    await tester.tap(find.byKey(const Key('open-log-ascent-sheet')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('test-log-ascent-sheet')), findsOneWidget);

    await tester.tap(find.byKey(const Key('test-ascent-save')));
    await tester.pumpAndSettle();

    // The sheet is gone — the confirmation therefore has to come from a
    // messenger captured BEFORE the pop, which is the thing most likely to
    // regress here.
    expect(find.byKey(const Key('test-log-ascent-sheet')), findsNothing);
  }

  testWidgets(
    'A1: saving an ascent confirms it, and the confirmation offers a '
    '"View logbook" action',
    (tester) async {
      await logAnAscent(tester);

      expect(find.byKey(const Key('ascent-logged-snack')), findsOneWidget);
      expect(find.text('Ascent logged'), findsOneWidget);
      expect(
        find.byKey(const Key('ascent-logged-view-logbook')),
        findsOneWidget,
      );
      expect(find.text('View logbook'), findsOneWidget);
    },
  );

  testWidgets('A2: tapping "View logbook" navigates to the Logbook route', (
    tester,
  ) async {
    await logAnAscent(tester);

    await tester.tap(find.byKey(const Key('ascent-logged-view-logbook')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('stub-logbook')), findsOneWidget);
  });

  testWidgets(
    'A1b: the confirmation stays up long enough for its action to be reached '
    "— Material's 4 s default is too short for a signpost nobody is expecting",
    (tester) async {
      await logAnAscent(tester);

      final snack = tester.widget<SnackBar>(
        find.byKey(const Key('ascent-logged-snack')),
      );
      expect(snack.duration, kAscentLoggedSnackDuration);
      expect(
        snack.duration,
        greaterThan(const Duration(seconds: 4)),
        reason:
            'longer than the Material default, deliberately — this snackbar '
            'carries the app\'s main signal that a Logbook exists',
      );

      // Prove it in the running tree too, not just in the field: past the
      // 4 s the default would have dismissed at, the action is still tappable.
      await tester.pump(const Duration(milliseconds: 4500));
      expect(
        find.byKey(const Key('ascent-logged-view-logbook')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('ascent-logged-view-logbook')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('stub-logbook')), findsOneWidget);
    },
  );
}
