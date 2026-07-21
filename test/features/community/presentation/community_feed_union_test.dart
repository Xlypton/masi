import 'package:climbtopo/app/theme.dart';
import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/core/db/database_provider.dart';
import 'package:climbtopo/features/account/application/auth_providers.dart';
import 'package:climbtopo/features/community/presentation/community_screen.dart';
import 'package:climbtopo/features/logbook/application/ascents_providers.dart';
import 'package:climbtopo/features/logbook/data/ascents_repository.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// #12 Wave 3, ST5: the Community Feed is now a UNION of shared topos
/// ([TopoFeedItem]) + shared ascent-log entries ([AscentFeedItem]), merged
/// by `feedItemsProvider` (`community_providers.dart`). This file tests
/// that union end-to-end (both variants render, the new `_AscentFeedRow`
/// resolves its climber's name and navigates correctly) plus the new
/// "My logbook" entry point that replaces the removed home-screen icon —
/// kept as its own file (rather than added to the already-3000+-line
/// `community_screen_test.dart`) to avoid colliding with other Wave 3
/// agents editing that file concurrently.
///
/// Mirrors `community_screen_test.dart`'s `_makeContainer`/seeding-helper
/// shapes exactly (duplicated locally since those are file-private).

ProviderContainer _makeContainer({String? currentUid}) {
  final db = AppDatabase(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      nowMsProvider.overrideWithValue(() => 1000),
      if (currentUid != null)
        currentUidProvider.overrideWithValue(() => currentUid),
    ],
  );
  addTearDown(db.close);
  addTearDown(container.dispose);
  return container;
}

/// Wraps [screen] in a real (minimal) [GoRouter] so `context.push` calls to
/// `/community/topo/:wallId`, `/community/ascent/:id`, and `/logbook` all
/// resolve against a real router (each destination a keyed placeholder
/// carrying the pushed path param, so a test can confirm which one was
/// actually reached) instead of throwing for lack of a route.
Widget _wrap(ProviderContainer container, Widget screen) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (context, state) => screen),
      GoRoute(
        path: '/community/topo/:wallId',
        builder: (context, state) => Text(
          'topo-detail-${state.pathParameters['wallId']}',
          key: const Key('topo-detail-placeholder'),
        ),
      ),
      GoRoute(
        path: '/community/ascent/:ascentId',
        builder: (context, state) => Text(
          'ascent-detail-${state.pathParameters['ascentId']}',
          key: const Key('ascent-detail-placeholder'),
        ),
      ),
      GoRoute(
        path: '/logbook',
        builder: (context, state) => const Text(
          'logbook-placeholder',
          key: Key('logbook-placeholder'),
        ),
      ),
    ],
  );
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(theme: MasiTheme.light, routerConfig: router),
  );
}

/// Advances real asynchronous work (Drift's in-memory background executor)
/// that would otherwise never make progress under `testWidgets`' fake-async
/// clock, then pumps to flush the resulting Riverpod-triggered rebuilds.
/// Mirrors `community_screen_test.dart`'s `_drain`.
Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 30));
  }
}

Future<void> _seedArea(AppDatabase db, {required String id}) {
  return db
      .into(db.areas)
      .insert(
        AreasCompanion.insert(id: id, createdAt: 1000, updatedAt: 1000, name: 'Area $id'),
      );
}

Future<void> _seedSector(AppDatabase db, {required String id, required String areaId}) {
  return db
      .into(db.sectors)
      .insert(
        SectorsCompanion.insert(
          id: id,
          createdAt: 1000,
          updatedAt: 1000,
          areaId: areaId,
          name: 'Sector $id',
          sortOrder: 0,
        ),
      );
}

Future<void> _seedWall(
  AppDatabase db, {
  required String id,
  required String sectorId,
  required String name,
  String visibility = 'private',
  String? ownerId,
}) {
  return db
      .into(db.walls)
      .insert(
        WallsCompanion.insert(
          id: id,
          createdAt: 1000,
          updatedAt: 1000,
          sectorId: sectorId,
          name: name,
          sortOrder: 0,
          visibility: Value(visibility),
          ownerId: Value(ownerId),
        ),
      );
}

Future<String> _seedPhoto(AppDatabase db, {required String id, required String wallId}) {
  return db
      .into(db.photos)
      .insert(
        PhotosCompanion.insert(
          id: id,
          createdAt: 1000,
          updatedAt: 1000,
          wallId: wallId,
          localPath: '/tmp/$id.jpg',
          kind: 'original',
          width: 100,
          height: 100,
        ),
      )
      .then((_) => id);
}

Future<String> _seedRoute(
  AppDatabase db, {
  required String id,
  required String wallId,
  required String photoId,
  required int number,
  String? gradeRaw,
  double? gradeSortKey,
}) {
  return db
      .into(db.routes)
      .insert(
        RoutesCompanion.insert(
          id: id,
          createdAt: 1000,
          updatedAt: 1000,
          wallId: wallId,
          photoId: photoId,
          number: number,
          colorIndex: 0,
          pointsJson: '[]',
          symbolsJson: '[]',
          sortOrder: 0,
          gradeRaw: Value(gradeRaw),
          gradeSortKey: Value(gradeSortKey),
        ),
      )
      .then((_) => id);
}

Future<void> _seedProfile(AppDatabase db, {required String id, required String displayName}) {
  return db
      .into(db.profiles)
      .insert(
        ProfilesCompanion.insert(
          id: id,
          createdAt: 1000,
          updatedAt: 1000,
          displayName: Value(displayName),
        ),
      );
}

/// Seeds ONE shared topo (`wall-topo`, no ascent attached) plus ONE
/// separate wall (`wall-ascent`) carrying a graded route and a single
/// opt-in-`shared` ascent logged by `climberUid`, attributed to a seeded
/// `profiles` row so `profileDisplayNameProvider` resolves a real name
/// (never the raw uid) — proves both [TopoFeedItem] and [AscentFeedItem]
/// variants render side-by-side in the same feed.
Future<String> _seedUnionScenario(
  ProviderContainer container, {
  required String climberUid,
}) async {
  final db = container.read(appDatabaseProvider);

  await _seedArea(db, id: 'area-1');
  await _seedSector(db, id: 'sector-1', areaId: 'area-1');
  await _seedWall(
    db,
    id: 'wall-topo',
    sectorId: 'sector-1',
    name: 'Shared Topo Wall',
    visibility: 'shared',
    ownerId: 'other-owner',
  );

  await _seedWall(
    db,
    id: 'wall-ascent',
    sectorId: 'sector-1',
    name: 'Ascent Wall',
    ownerId: 'other-owner',
  );
  final photoId = await _seedPhoto(db, id: 'photo-ascent', wallId: 'wall-ascent');
  final routeId = await _seedRoute(
    db,
    id: 'route-ascent',
    wallId: 'wall-ascent',
    photoId: photoId,
    number: 1,
    gradeRaw: '7a',
    gradeSortKey: 12.0,
  );

  await _seedProfile(db, id: climberUid, displayName: 'Alex Boulder');

  final ascent = await container.read(ascentsRepositoryProvider).logAscent(
    routeId: routeId,
    wallId: 'wall-ascent',
    climbedAt: DateTime.utc(2026, 7, 1),
    style: AscentStyle.redpoint,
    shared: true,
  );
  return ascent.id;
}

void main() {
  group('Community Feed union (#12 Wave 3, ST5)', () {
    testWidgets(
      'renders both a shared-topo row and a shared-ascent row, the ascent '
      'row resolves the climber display name',
      (tester) async {
        final container = _makeContainer(currentUid: 'climber-1');
        final ascentId = await _seedUnionScenario(container, climberUid: 'climber-1');

        await tester.pumpWidget(_wrap(container, const CommunityFeedScreen()));
        await _drain(tester);

        expect(find.byKey(const Key('community-topo-row-wall-topo')), findsOneWidget);
        final ascentRowFinder = find.byKey(Key('community-ascent-row-$ascentId'));
        expect(ascentRowFinder, findsOneWidget);
        expect(
          find.descendant(of: ascentRowFinder, matching: find.text('by Alex Boulder')),
          findsOneWidget,
        );
      },
    );

    testWidgets('tapping the ascent row navigates to /community/ascent/:id', (tester) async {
      final container = _makeContainer(currentUid: 'climber-1');
      final ascentId = await _seedUnionScenario(container, climberUid: 'climber-1');

      await tester.pumpWidget(_wrap(container, const CommunityFeedScreen()));
      await _drain(tester);

      await tester.tap(find.byKey(Key('community-ascent-row-$ascentId')));
      await _drain(tester);

      expect(find.byKey(const Key('ascent-detail-placeholder')), findsOneWidget);
      expect(find.text('ascent-detail-$ascentId'), findsOneWidget);
    });

    testWidgets(
      '"Unknown climber" fallback when the ascent owner has no profile row',
      (tester) async {
        final container = _makeContainer(currentUid: 'climber-no-profile');
        final db = container.read(appDatabaseProvider);
        await _seedArea(db, id: 'area-1');
        await _seedSector(db, id: 'sector-1', areaId: 'area-1');
        await _seedWall(db, id: 'wall-ascent', sectorId: 'sector-1', name: 'Ascent Wall');
        final photoId = await _seedPhoto(db, id: 'photo-1', wallId: 'wall-ascent');
        final routeId = await _seedRoute(
          db,
          id: 'route-1',
          wallId: 'wall-ascent',
          photoId: photoId,
          number: 1,
        );
        final ascent = await container.read(ascentsRepositoryProvider).logAscent(
          routeId: routeId,
          wallId: 'wall-ascent',
          climbedAt: DateTime.utc(2026, 7, 1),
          style: AscentStyle.onsight,
          shared: true,
        );

        await tester.pumpWidget(_wrap(container, const CommunityFeedScreen()));
        await _drain(tester);

        final ascentRowFinder = find.byKey(Key('community-ascent-row-${ascent.id}'));
        expect(ascentRowFinder, findsOneWidget);
        expect(
          find.descendant(of: ascentRowFinder, matching: find.text('Unknown climber')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'feed-logbook-button is present and routes to /logbook',
      (tester) async {
        final container = _makeContainer();

        await tester.pumpWidget(_wrap(container, const CommunityFeedScreen()));
        await _drain(tester);

        final logbookButton = find.byKey(const Key('feed-logbook-button'));
        expect(logbookButton, findsOneWidget);

        await tester.tap(logbookButton);
        await _drain(tester);

        expect(find.byKey(const Key('logbook-placeholder')), findsOneWidget);
      },
    );
  });
}
