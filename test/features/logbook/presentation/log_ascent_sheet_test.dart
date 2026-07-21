// Widget tests for the shared [LogAscentSheet] (masi-log-ascent-own-routes
// plan, Subtask 1 / assertion A1): extracted from
// `CommunityTopoDetailScreen`'s original private `_LogAscentSheet` so BOTH
// the community detail screen and the user's own topo canvas can open the
// exact same sheet. See `test/features/community/presentation/
// community_topo_detail_test.dart`'s D4d/D4e for the pre-extraction
// behavior this must still reproduce for the community call site (covered
// there via `keyPrefix: 'community'`); this file exercises the shared
// widget directly and generically via a distinct `keyPrefix`.
//
// Seeding follows the same real Area -> Sector -> Wall -> Photo -> Route
// repository chain used throughout this suite (e.g.
// `route_legend_intent_test.dart`'s `_seedRoutes`), since `Ascents.wallId`/
// `Ascents.routeId` are real foreign keys (`AppDatabase.beforeOpen` runs
// `PRAGMA foreign_keys = ON` — see `ascents_repository_test.dart`'s doc) —
// `logAscent` would throw against made-up ids.
import 'package:climbtopo/app/theme.dart';
import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/core/db/database_provider.dart';
import 'package:climbtopo/features/library/application/library_providers.dart';
import 'package:climbtopo/features/logbook/application/ascents_providers.dart';
import 'package:climbtopo/features/logbook/data/ascents_repository.dart';
import 'package:climbtopo/features/logbook/presentation/log_ascent_sheet.dart';
import 'package:climbtopo/features/topo/data/route_repository.dart';
import 'package:climbtopo/features/topo/domain/topo_route.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

void main() {
  /// Seeds a real Area -> Sector -> Wall -> Photo -> Route chain and
  /// returns the wall id plus the route's real (uuid) DB id — exactly the
  /// id `LogAscentSheet.routeId` (and `logAscent`) must be given, NOT
  /// `TopoRoute.id`'s locally-reassigned sequential int (see
  /// `RouteRepository`'s class doc).
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
        XFile('/tmp/log-ascent-sheet-test-photo.jpg'),
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

    return (
      db: db,
      container: container,
      wallId: wall.id,
      routeDbId: dbIds[1]!,
    );
  }

  /// A minimal harness Scaffold whose button opens [LogAscentSheet] as a
  /// modal bottom sheet — mirroring exactly how both real call sites
  /// (`CommunityTopoDetailScreen._openLogAscentSheet`,
  /// `_TopoCanvasScreenState._openLogAscentSheet`) present it, so `Save`'s
  /// `Navigator.of(context).pop()` has a real sheet route to pop.
  Future<void> pumpHarness(
    WidgetTester tester,
    ProviderContainer container, {
    required String routeId,
    required String wallId,
  }) {
    return tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: MasiTheme.light,
          home: Scaffold(
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
      ),
    );
  }

  testWidgets(
    'A1: Save calls logAscent with the given routeId+wallId, climbedAt≈now, '
    'the chosen style and notes, then dismisses the sheet',
    (tester) async {
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

      // Choose a non-default style (sheet defaults to redpoint) and enter
      // notes, so both are proven to flow through to logAscent rather than
      // just asserting the hard-coded default.
      await tester.tap(find.byKey(const Key('test-ascent-style-onsight')));
      await tester.enterText(
        find.byKey(const Key('test-ascent-notes')),
        'Felt great',
      );
      await tester.pump();

      final before = DateTime.now();
      await tester.tap(find.byKey(const Key('test-ascent-save')));
      await tester.pumpAndSettle();
      final after = DateTime.now();

      // The sheet is dismissed.
      expect(find.byKey(const Key('test-log-ascent-sheet')), findsNothing);

      final ascentsRepo = seeded.container.read(ascentsRepositoryProvider);
      final ascents = await ascentsRepo.ascentsForRoute(seeded.routeDbId);
      expect(ascents, hasLength(1));
      final logged = ascents.single;
      expect(logged.routeId, seeded.routeDbId);
      expect(logged.wallId, seeded.wallId);
      expect(logged.style, AscentStyle.onsight);
      expect(logged.notes, 'Felt great');
      expect(
        logged.climbedAt.isAfter(before.subtract(const Duration(seconds: 5))) &&
            logged.climbedAt.isBefore(after.add(const Duration(seconds: 5))),
        isTrue,
        reason:
            'climbedAt (${logged.climbedAt}) must be stamped to "now" '
            '(between $before and $after)',
      );
    },
  );

  testWidgets(
    'style chips render capitalized labels (e.g. "Onsight"), not the raw '
    'enum name ("onsight")',
    (tester) async {
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

      for (final style in AscentStyle.values) {
        expect(
          find.byKey(Key('test-ascent-style-${style.name}')),
          findsOneWidget,
          reason: 'the chip Key must still be the raw enum name',
        );
        expect(find.text(style.name), findsNothing);
      }
      expect(find.text('Onsight'), findsOneWidget);
      expect(find.text('Flash'), findsOneWidget);
      expect(find.text('Redpoint'), findsOneWidget);
      expect(find.text('Repeat'), findsOneWidget);
      expect(find.text('Attempt'), findsOneWidget);
    },
  );

  testWidgets(
    '#16: a fast double-tap on Save only ever logs one ascent '
    '(re-entrancy guard regression test)',
    (tester) async {
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

      // Two taps back-to-back with no `pump` in between: the second tap's
      // gesture is still delivered to the button's `onPressed` captured at
      // the PREVIOUS build (still non-null, since no rebuild has happened
      // yet to disable it) -- exactly the scenario `_save`'s synchronous
      // `if (_saving) return;` guard at the top of the function must catch.
      await tester.tap(find.byKey(const Key('test-ascent-save')));
      await tester.tap(find.byKey(const Key('test-ascent-save')));
      await tester.pumpAndSettle();

      final ascentsRepo = seeded.container.read(ascentsRepositoryProvider);
      final ascents = await ascentsRepo.ascentsForRoute(seeded.routeDbId);
      expect(
        ascents,
        hasLength(1),
        reason: 'a double-tap must not log a duplicate ascent',
      );
    },
  );

  testWidgets(
    'A1b: leaving notes empty logs a null notes field (optional field '
    'contract preserved)',
    (tester) async {
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

      await tester.tap(find.byKey(const Key('test-ascent-save')));
      await tester.pumpAndSettle();

      final ascentsRepo = seeded.container.read(ascentsRepositoryProvider);
      final ascents = await ascentsRepo.ascentsForRoute(seeded.routeDbId);
      expect(ascents, hasLength(1));
      expect(ascents.single.notes, isNull);
      expect(
        ascents.single.style,
        AscentStyle.redpoint,
        reason: 'redpoint is the sheet\'s documented default style',
      );
    },
  );

  testWidgets(
    '#12 ST4: the share toggle defaults OFF and Save logs a private '
    '(unshared) ascent when left untouched',
    (tester) async {
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

      final toggle = tester.widget<SwitchListTile>(
        find.byKey(const Key('log-ascent-share-toggle')),
      );
      expect(
        toggle.value,
        isFalse,
        reason: 'sharing must be opt-in, off by default',
      );

      await tester.tap(find.byKey(const Key('test-ascent-save')));
      await tester.pumpAndSettle();

      final ascentsRepo = seeded.container.read(ascentsRepositoryProvider);
      final ascents = await ascentsRepo.ascentsForRoute(seeded.routeDbId);
      expect(ascents, hasLength(1));
      expect(ascents.single.visibility, 'private');
      expect(ascents.single.isShared, isFalse);
    },
  );

  testWidgets(
    '#12 ST4: toggling the share switch ON and Save logs a shared ascent',
    (tester) async {
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

      await tester.tap(find.byKey(const Key('log-ascent-share-toggle')));
      await tester.pump();

      final toggle = tester.widget<SwitchListTile>(
        find.byKey(const Key('log-ascent-share-toggle')),
      );
      expect(toggle.value, isTrue);

      await tester.tap(find.byKey(const Key('test-ascent-save')));
      await tester.pumpAndSettle();

      final ascentsRepo = seeded.container.read(ascentsRepositoryProvider);
      final ascents = await ascentsRepo.ascentsForRoute(seeded.routeDbId);
      expect(ascents, hasLength(1));
      expect(ascents.single.visibility, 'shared');
      expect(ascents.single.isShared, isTrue);
    },
  );
}
