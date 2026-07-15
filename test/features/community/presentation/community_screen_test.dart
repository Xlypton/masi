import 'dart:convert';

import 'package:climbtopo/app/theme.dart';
import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/core/db/database_provider.dart';
import 'package:climbtopo/core/location/location_service.dart';
import 'package:climbtopo/features/community/application/community_providers.dart';
import 'package:climbtopo/features/community/presentation/community_screen.dart';
import 'package:climbtopo/shared/filtering/grade_range.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// A minimal-but-real 1x1 transparent PNG (base64) — same known-valid bytes
/// `topos_screen_test.dart` decodes for its "New topo" flow — used as the
/// (already-decoded) in-memory image every fake tile "loads". See
/// [_NoopTileProvider].
final _tinyPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY'
  '42YAAAAASUVORK5CYII=',
);

/// A tile provider that never performs any network/file I/O: every tile
/// request resolves synchronously to the same tiny in-memory image. Wired
/// into every [CommunityScreen] built by this test file's [_wrap], so the
/// Map tab's `TileLayer` can never attempt a real network fetch under
/// `flutter_test` (see CLAUDE.md: "never hit the network in a widget test").
class _NoopTileProvider extends TileProvider {
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    return MemoryImage(_tinyPngBytes);
  }
}

/// A [LocationService] double that resolves to whatever fixed [result] it
/// was constructed with — no real geolocator/platform-channel call ever
/// happens under `flutter_test`.
class _FakeLocationService implements LocationService {
  const _FakeLocationService(this.result);

  final DeviceLocation? result;

  @override
  Future<DeviceLocation?> currentLocation() async => result;
}

/// Builds a [ProviderContainer] wired to a fresh in-memory database.
/// Mirrors `topos_screen_test.dart`'s `_makeContainer`.
///
/// [locationService], when given, overrides `locationServiceProvider` (see
/// `myLocationProvider`'s "you are here" marker) with a [_FakeLocationService]
/// so a test can script the device position without touching real
/// geolocation. Tests that don't pass it leave `locationServiceProvider`
/// un-overridden — the real `GeolocatorLocationService` still never throws
/// under `flutter_test` (no platform channel is registered, so its internal
/// try/catch resolves to `null`), so every pre-existing map test is
/// unaffected.
ProviderContainer _makeContainer({LocationService? locationService}) {
  final db = AppDatabase(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      nowMsProvider.overrideWithValue(() => 1000),
      if (locationService != null)
        locationServiceProvider.overrideWithValue(locationService),
    ],
  );
  addTearDown(db.close);
  addTearDown(container.dispose);
  return container;
}

/// Wraps [screen] in a real (minimal) [GoRouter] so `context.push` calls to
/// `/community/topo/:wallId` resolve against a real router instead of
/// throwing for lack of one.
Widget _wrap(ProviderContainer container, Widget screen) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (context, state) => screen),
      GoRoute(
        path: '/community/topo/:wallId',
        builder: (context, state) => const SizedBox(),
      ),
    ],
  );
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(theme: MasiTheme.light, routerConfig: router),
  );
}

/// Like [_wrap], but the `/community/topo/:wallId` destination renders a
/// keyed placeholder carrying the tapped wallId in its text, so a test can
/// confirm that tapping a map marker actually navigated (rather than just
/// that the `GestureDetector`'s key/onTap exist).
Widget _wrapWithDetailRoute(ProviderContainer container, Widget screen) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (context, state) => screen),
      GoRoute(
        path: '/community/topo/:wallId',
        builder: (context, state) => Text(
          'detail-${state.pathParameters['wallId']}',
          key: const Key('community-topo-detail-placeholder'),
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
/// Mirrors `topos_screen_test.dart`'s `_drain`, but avoids `pumpAndSettle` (a
/// `TileLayer`'s fade-in `AnimationController` is fine to leave mid-flight
/// for these assertions, which never depend on tile pixels).
Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 30));
  }
}

Future<void> _seedArea(
  AppDatabase db, {
  required String id,
  required String name,
  double? latitude,
  double? longitude,
}) {
  return db
      .into(db.areas)
      .insert(
        AreasCompanion.insert(
          id: id,
          createdAt: 1000,
          updatedAt: 1000,
          name: name,
          latitude: Value(latitude),
          longitude: Value(longitude),
        ),
      );
}

Future<void> _seedSector(
  AppDatabase db, {
  required String id,
  required String areaId,
  required String name,
}) {
  return db
      .into(db.sectors)
      .insert(
        SectorsCompanion.insert(
          id: id,
          createdAt: 1000,
          updatedAt: 1000,
          areaId: areaId,
          name: name,
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
  int createdAt = 1000,
  double? latitude,
  double? longitude,
  String? ownerId,
}) {
  return db
      .into(db.walls)
      .insert(
        WallsCompanion.insert(
          id: id,
          createdAt: createdAt,
          updatedAt: createdAt,
          sectorId: sectorId,
          name: name,
          sortOrder: 0,
          visibility: Value(visibility),
          latitude: Value(latitude),
          longitude: Value(longitude),
          ownerId: Value(ownerId),
        ),
      );
}

Future<void> _seedLike(AppDatabase db, {required String id, required String wallId}) {
  return db
      .into(db.likes)
      .insert(
        LikesCompanion.insert(
          id: id,
          createdAt: 1000,
          updatedAt: 1000,
          wallId: wallId,
        ),
      );
}

Future<void> _seedComment(
  AppDatabase db, {
  required String id,
  required String wallId,
  required String body,
}) {
  return db
      .into(db.comments)
      .insert(
        CommentsCompanion.insert(
          id: id,
          createdAt: 1000,
          updatedAt: 1000,
          wallId: wallId,
          body: body,
        ),
      );
}

Future<String> _seedPhoto(
  AppDatabase db, {
  required String id,
  required String wallId,
}) {
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

Future<void> _seedRoute(
  AppDatabase db, {
  required String id,
  required String wallId,
  required String photoId,
  required int number,
  String? gradeRaw,
  double? gradeSortKey,
  String? style,
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
          style: Value(style),
        ),
      );
}

/// Seeds two shared, coordinate-having walls with one route each -- a
/// "Sport Wall" graded 6a/sport and a "Trad Wall" graded 9a/trad -- used by
/// the Subtask B (Community filtering) test groups below.
Future<void> _seedFilterScenario(AppDatabase db) async {
  // Coordinates now live on the WALL itself (see
  // `LibraryCrudRepository.setWallCoordinates` /
  // `CommunityRepository.watchSharedTopos`), not its ancestor Area — set
  // below on `wall-sport`/`wall-trad` directly rather than on `area-filter`.
  await _seedArea(db, id: 'area-filter', name: 'Filter Area');
  await _seedSector(db, id: 'sector-filter', areaId: 'area-filter', name: 'S');

  await _seedWall(
    db,
    id: 'wall-sport',
    sectorId: 'sector-filter',
    name: 'Sport Wall',
    visibility: 'shared',
    createdAt: 2000,
    latitude: 45.0,
    longitude: 7.0,
  );
  final sportPhoto = await _seedPhoto(db, id: 'photo-sport', wallId: 'wall-sport');
  await _seedRoute(
    db,
    id: 'route-sport',
    wallId: 'wall-sport',
    photoId: sportPhoto,
    number: 1,
    gradeRaw: '6a',
    gradeSortKey: 7.0,
    style: 'sport',
  );

  await _seedWall(
    db,
    id: 'wall-trad',
    sectorId: 'sector-filter',
    name: 'Trad Wall',
    visibility: 'shared',
    createdAt: 1000,
    latitude: 46.0,
    longitude: 8.0,
  );
  final tradPhoto = await _seedPhoto(db, id: 'photo-trad', wallId: 'wall-trad');
  await _seedRoute(
    db,
    id: 'route-trad',
    wallId: 'wall-trad',
    photoId: tradPhoto,
    number: 1,
    gradeRaw: '9a',
    gradeSortKey: 25.0,
    style: 'trad',
  );
}

/// Matches the top-level `Material`/`InkWell` feed row for a shared topo
/// (`community-topo-row-<wallId>`), excluding the `-likes`/`-comments` text
/// keys nested inside it — used to count "exactly N rows" (D2a).
Finder _feedRowFinder() {
  return find.byWidgetPredicate((widget) {
    final key = widget.key;
    return key is ValueKey<String> &&
        key.value.startsWith('community-topo-row-') &&
        !key.value.endsWith('-likes') &&
        !key.value.endsWith('-comments');
  });
}

/// Seeds a standard scenario shared by several tests: two shared walls (one
/// with Area coordinates, one without) plus one private wall, which must
/// never surface anywhere in the Community screen.
Future<void> _seedStandardScenario(AppDatabase db) async {
  // Coordinates now live on the WALL itself (see
  // `LibraryCrudRepository.setWallCoordinates` /
  // `CommunityRepository.watchSharedTopos`), not its ancestor Area — set
  // below on `wall-shared-1` directly rather than on `area-coords`.
  await _seedArea(db, id: 'area-coords', name: 'Area With Coords');
  await _seedSector(db, id: 'sector-coords', areaId: 'area-coords', name: 'S1');
  await _seedWall(
    db,
    id: 'wall-shared-1',
    sectorId: 'sector-coords',
    name: 'Shared One',
    visibility: 'shared',
    createdAt: 2000,
    latitude: 45.0,
    longitude: 7.0,
  );
  await _seedLike(db, id: 'like-1', wallId: 'wall-shared-1');
  await _seedLike(db, id: 'like-2', wallId: 'wall-shared-1');
  await _seedComment(
    db,
    id: 'comment-1',
    wallId: 'wall-shared-1',
    body: 'Nice line!',
  );

  await _seedArea(db, id: 'area-no-coords', name: 'Area Without Coords');
  await _seedSector(
    db,
    id: 'sector-no-coords',
    areaId: 'area-no-coords',
    name: 'S2',
  );
  await _seedWall(
    db,
    id: 'wall-shared-2',
    sectorId: 'sector-no-coords',
    name: 'Shared Two',
    visibility: 'shared',
    createdAt: 1000,
  );

  await _seedArea(db, id: 'area-private', name: 'Area Private');
  await _seedSector(
    db,
    id: 'sector-private',
    areaId: 'area-private',
    name: 'S3',
  );
  await _seedWall(
    db,
    id: 'wall-private',
    sectorId: 'sector-private',
    name: 'Private Wall',
  );
}

void main() {
  group('D2a: feed populated rows (private excluded), counts shown', () {
    testWidgets(
      'exactly one row per shared wall, private wall never rendered, '
      'like/comment counts shown',
      (tester) async {
        final container = _makeContainer();
        final db = container.read(appDatabaseProvider);
        await tester.runAsync(() => _seedStandardScenario(db));

        await tester.pumpWidget(
          _wrap(
            container,
            CommunityScreen(tileProvider: _NoopTileProvider()),
          ),
        );
        await _drain(tester);

        expect(
          find.byKey(const Key('community-topo-row-wall-shared-1')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('community-topo-row-wall-shared-2')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('community-topo-row-wall-private')),
          findsNothing,
        );
        expect(_feedRowFinder(), findsNWidgets(2));

        // wall-shared-1 has 2 likes, 1 comment.
        expect(
          find.byKey(const Key('community-topo-row-wall-shared-1-likes')),
          findsOneWidget,
        );
        expect(find.text('♥ 2'), findsOneWidget);
        expect(find.text('\u{1F4AC} 1'), findsOneWidget);
        // wall-shared-2 has 0 likes, 0 comments.
        expect(find.text('♥ 0'), findsOneWidget);
        expect(find.text('\u{1F4AC} 0'), findsOneWidget);
      },
    );
  });

  group('D2b: search filters feed rows by name', () {
    testWidgets(
      'typing a query that matches only one shared topo hides the other',
      (tester) async {
        final container = _makeContainer();
        final db = container.read(appDatabaseProvider);
        await tester.runAsync(() => _seedStandardScenario(db));

        await tester.pumpWidget(
          _wrap(
            container,
            CommunityScreen(tileProvider: _NoopTileProvider()),
          ),
        );
        await _drain(tester);

        expect(_feedRowFinder(), findsNWidgets(2));

        await tester.enterText(
          find.byKey(const Key('community-search-field')),
          'One',
        );
        await tester.pump();

        expect(
          find.byKey(const Key('community-topo-row-wall-shared-1')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('community-topo-row-wall-shared-2')),
          findsNothing,
        );
        expect(_feedRowFinder(), findsOneWidget);
      },
    );
  });

  group('D2c: empty state', () {
    testWidgets(
      'zero shared topos shows community-empty and no rows',
      (tester) async {
        final container = _makeContainer();
        final db = container.read(appDatabaseProvider);
        // Only a private wall — no shared topos at all.
        await tester.runAsync(() async {
          await _seedArea(db, id: 'area-1', name: 'Area One');
          await _seedSector(db, id: 'sector-1', areaId: 'area-1', name: 'S1');
          await _seedWall(
            db,
            id: 'wall-private-only',
            sectorId: 'sector-1',
            name: 'Private Only',
          );
        });

        await tester.pumpWidget(
          _wrap(
            container,
            CommunityScreen(tileProvider: _NoopTileProvider()),
          ),
        );
        await _drain(tester);

        expect(find.byKey(const Key('community-empty')), findsOneWidget);
        expect(find.text('No shared topos yet'), findsOneWidget);
        expect(_feedRowFinder(), findsNothing);
      },
    );
  });

  group('D3a/D3b: map markers', () {
    testWidgets(
      'switching to Map shows exactly one marker per shared topo WITH '
      'coordinates, and no marker (and no crash) for the coord-less one',
      (tester) async {
        final container = _makeContainer();
        final db = container.read(appDatabaseProvider);
        await tester.runAsync(() => _seedStandardScenario(db));

        await tester.pumpWidget(
          _wrap(
            container,
            CommunityScreen(tileProvider: _NoopTileProvider()),
          ),
        );
        await _drain(tester);

        await tester.tap(find.byKey(const Key('community-map-toggle')));
        await _drain(tester);

        expect(tester.takeException(), isNull);
        expect(find.byType(FlutterMap), findsOneWidget);

        // D3a: wall-shared-1 has Area coordinates -> exactly one marker.
        expect(
          find.byKey(const Key('community-map-marker-wall-shared-1')),
          findsOneWidget,
        );
        // D3b: wall-shared-2 has no Area coordinates -> no marker, no crash.
        expect(
          find.byKey(const Key('community-map-marker-wall-shared-2')),
          findsNothing,
        );
        // The private wall must never appear on the map either.
        expect(
          find.byKey(const Key('community-map-marker-wall-private')),
          findsNothing,
        );
      },
    );
  });

  group('C: "you are here" device-location marker', () {
    testWidgets(
      'C1: a fixed device location renders community-map-my-location, '
      'alongside the topo markers',
      (tester) async {
        // A point close to wall-shared-1's (45.0, 7.0) coordinates -- which
        // is also this map's auto-centered viewport (see `_MapView`'s
        // `center` -- the average of every topo WITH coordinates) --  so it
        // stays inside flutter_map's `MarkerLayer` on-screen culling bounds
        // regardless of the test surface's exact pixel size/zoom.
        final container = _makeContainer(
          locationService: const _FakeLocationService((
            latitude: 45.001,
            longitude: 7.001,
          )),
        );
        final db = container.read(appDatabaseProvider);
        await tester.runAsync(() => _seedStandardScenario(db));

        await tester.pumpWidget(
          _wrap(
            container,
            CommunityScreen(tileProvider: _NoopTileProvider()),
          ),
        );
        await _drain(tester);

        await tester.tap(find.byKey(const Key('community-map-toggle')));
        await _drain(tester);

        expect(tester.takeException(), isNull);
        expect(
          find.byKey(const Key('community-map-my-location')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('community-map-marker-wall-shared-1')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'C2: a null device location (denied/unavailable/loading) renders no '
      'marker, and the map + topo markers still render with no crash',
      (tester) async {
        final container = _makeContainer(
          locationService: const _FakeLocationService(null),
        );
        final db = container.read(appDatabaseProvider);
        await tester.runAsync(() => _seedStandardScenario(db));

        await tester.pumpWidget(
          _wrap(
            container,
            CommunityScreen(tileProvider: _NoopTileProvider()),
          ),
        );
        await _drain(tester);

        await tester.tap(find.byKey(const Key('community-map-toggle')));
        await _drain(tester);

        expect(tester.takeException(), isNull);
        expect(find.byType(FlutterMap), findsOneWidget);
        expect(
          find.byKey(const Key('community-map-my-location')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('community-map-marker-wall-shared-1')),
          findsOneWidget,
        );
      },
    );
  });

  group('B3: filter button + Filters sheet', () {
    testWidgets(
      'no active-dot initially; tapping community-filter-button opens the '
      'sheet (grade picker + style chips visible)',
      (tester) async {
        final container = _makeContainer();
        final db = container.read(appDatabaseProvider);
        await tester.runAsync(() => _seedFilterScenario(db));

        await tester.pumpWidget(
          _wrap(container, CommunityScreen(tileProvider: _NoopTileProvider())),
        );
        await _drain(tester);

        expect(
          find.byKey(const Key('community-filter-active-dot')),
          findsNothing,
        );

        await tester.tap(find.byKey(const Key('community-filter-button')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('filter-grade-min')), findsOneWidget);
        expect(find.byKey(const Key('filter-grade-max')), findsOneWidget);
        expect(
          find.byKey(const Key('filter-style-sport')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('filter-style-trad')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('filter-style-boulder')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'selecting a style chip in the sheet narrows the feed LIVE (sheet '
      'stays open) and shows the active-dot',
      (tester) async {
        final container = _makeContainer();
        final db = container.read(appDatabaseProvider);
        await tester.runAsync(() => _seedFilterScenario(db));

        await tester.pumpWidget(
          _wrap(container, CommunityScreen(tileProvider: _NoopTileProvider())),
        );
        await _drain(tester);

        expect(_feedRowFinder(), findsNWidgets(2));

        await tester.tap(find.byKey(const Key('community-filter-button')));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('filter-style-sport')));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('community-topo-row-wall-sport')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('community-topo-row-wall-trad')),
          findsNothing,
        );
        expect(_feedRowFinder(), findsOneWidget);
        expect(
          find.byKey(const Key('community-filter-active-dot')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'a grade range that only wall-sport (6a/key 7.0) falls in narrows '
      'the feed live',
      (tester) async {
        final container = _makeContainer();
        final db = container.read(appDatabaseProvider);
        await tester.runAsync(() => _seedFilterScenario(db));

        await tester.pumpWidget(
          _wrap(container, CommunityScreen(tileProvider: _NoopTileProvider())),
        );
        await _drain(tester);

        // Drive the filter through the provider directly (GradeRangePicker's
        // own dropdown-interaction contract is already covered by Subtask
        // A's grade_range_picker_test.dart) -- this test's job is only to
        // confirm CommunityScreen reacts to communityFilterProvider live.
        container
            .read(communityFilterProvider.notifier)
            .setGrade(const GradeRange(minToken: '6a', maxToken: '6a'));
        await tester.pump();

        expect(
          find.byKey(const Key('community-topo-row-wall-sport')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('community-topo-row-wall-trad')),
          findsNothing,
        );
      },
    );

    testWidgets(
      'Clear resets both sub-filters and restores the full feed; the '
      'active-dot disappears',
      (tester) async {
        final container = _makeContainer();
        final db = container.read(appDatabaseProvider);
        await tester.runAsync(() => _seedFilterScenario(db));

        await tester.pumpWidget(
          _wrap(container, CommunityScreen(tileProvider: _NoopTileProvider())),
        );
        await _drain(tester);

        await tester.tap(find.byKey(const Key('community-filter-button')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('filter-style-sport')));
        await tester.pumpAndSettle();

        expect(_feedRowFinder(), findsOneWidget);
        expect(
          find.byKey(const Key('community-filter-active-dot')),
          findsOneWidget,
        );

        await tester.tap(find.byKey(const Key('community-filter-clear')));
        await tester.pumpAndSettle();

        expect(_feedRowFinder(), findsNWidgets(2));
        expect(
          find.byKey(const Key('community-filter-active-dot')),
          findsNothing,
        );
      },
    );

    testWidgets(
      'a filter matching nothing shows the "No topos match your filters" '
      'empty state (distinct from the search empty state)',
      (tester) async {
        final container = _makeContainer();
        final db = container.read(appDatabaseProvider);
        await tester.runAsync(() => _seedFilterScenario(db));

        await tester.pumpWidget(
          _wrap(container, CommunityScreen(tileProvider: _NoopTileProvider())),
        );
        await _drain(tester);

        container
            .read(communityFilterProvider.notifier)
            .setStyles({'boulder'});
        await tester.pump();

        expect(find.byKey(const Key('community-empty')), findsOneWidget);
        expect(find.text('No topos match your filters'), findsOneWidget);
        expect(_feedRowFinder(), findsNothing);
      },
    );
  });

  group('layout overflow regression: Filters sheet', () {
    /// Wraps [screen] in the same minimal [GoRouter] as [_wrap], plus a
    /// [MediaQuery] override so `textScaler` can be forced to a large value
    /// independently of the surface size set via [setViewportSize].
    Widget wrapWithScale(
      ProviderContainer container,
      Widget screen,
      double textScale,
    ) {
      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(path: '/', builder: (context, state) => screen),
          GoRoute(
            path: '/community/topo/:wallId',
            builder: (context, state) => const SizedBox(),
          ),
        ],
      );
      return UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: MasiTheme.light,
          routerConfig: router,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
        ),
      );
    }

    void setViewportSize(WidgetTester tester, Size size) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    // Deliberately seeds NO shared topos: with a populated feed, `_FeedRow`'s
    // own like/comment/owner Row has a separate, pre-existing overflow at
    // these extreme text scales (unrelated to the two filter-sheet bugs this
    // group targets, and out of scope here) that would contaminate these
    // assertions. An empty feed renders `_EmptyState` behind the sheet
    // instead, isolating exactly what these tests care about: the Filters
    // sheet's own layout.
    testWidgets(
      'vertical stress: 360x500 @ 2.5x text scale — opening the Filters '
      'sheet does not overflow vertically (regression: _CommunityFiltersSheet '
      'body must scroll, like the Topos/Logbook sheets do)',
      (tester) async {
        setViewportSize(tester, const Size(360, 500));
        final container = _makeContainer();

        await tester.pumpWidget(
          wrapWithScale(
            container,
            CommunityScreen(tileProvider: _NoopTileProvider()),
            2.5,
          ),
        );
        await _drain(tester);
        expect(tester.takeException(), isNull);

        await tester.tap(find.byKey(const Key('community-filter-button')));
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
          wrapWithScale(
            container,
            CommunityScreen(tileProvider: _NoopTileProvider()),
            3.0,
          ),
        );
        await _drain(tester);
        expect(tester.takeException(), isNull);

        await tester.tap(find.byKey(const Key('community-filter-button')));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
      },
    );
  });

  group('B4: map markers respect the same communityFilterProvider', () {
    testWidgets(
      'filtering to style=trad leaves only the Trad Wall marker on the map',
      (tester) async {
        final container = _makeContainer();
        final db = container.read(appDatabaseProvider);
        await tester.runAsync(() => _seedFilterScenario(db));

        await tester.pumpWidget(
          _wrap(container, CommunityScreen(tileProvider: _NoopTileProvider())),
        );
        await _drain(tester);

        container.read(communityFilterProvider.notifier).setStyles({'trad'});
        await tester.pump();

        await tester.tap(find.byKey(const Key('community-map-toggle')));
        await _drain(tester);

        expect(tester.takeException(), isNull);
        expect(
          find.byKey(const Key('community-map-marker-wall-trad')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('community-map-marker-wall-sport')),
          findsNothing,
        );
      },
    );
  });

  group('Subtask A: map polish — nicer tiles, attribution, logo markers', () {
    testWidgets(
      'Map tab uses the CartoDB Positron tile URL (no API key), keeps the '
      'injectable tileProvider seam, and shows the OSM/CARTO credit TEXT '
      'visibly at a realistic viewport WITHOUT any tap (regression: a '
      'collapsed RichAttributionWidget info-icon popup does not satisfy '
      'the "attribution must be visible without interaction" requirement)',
      (tester) async {
        // A realistic ≥360px-wide logical viewport (rather than
        // flutter_test's tiny ~267-logical-px default surface), so the
        // credit pill's overflow behaviour is exercised meaningfully.
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final container = _makeContainer();
        final db = container.read(appDatabaseProvider);
        await tester.runAsync(() => _seedStandardScenario(db));

        await tester.pumpWidget(
          _wrap(
            container,
            CommunityScreen(tileProvider: _NoopTileProvider()),
          ),
        );
        await _drain(tester);

        await tester.tap(find.byKey(const Key('community-map-toggle')));
        await _drain(tester);

        expect(tester.takeException(), isNull);

        final tileLayer = tester.widget<TileLayer>(find.byType(TileLayer));
        expect(
          tileLayer.urlTemplate,
          'https://basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png',
        );
        // Still the injected fake, never a real NetworkTileProvider — this
        // test must perform no real network I/O.
        expect(tileLayer.tileProvider, isA<_NoopTileProvider>());

        // The credit text must be rendered and visible WITHOUT any tap —
        // not merely present (opacity 0) somewhere in the tree, which is
        // exactly how `RichAttributionWidget`'s collapsed popup renders its
        // `TextSourceAttribution`s: still built, wrapped in an
        // `AnimatedOpacity(opacity: 0)`, so a bare `find.textContaining`
        // would pass even though nothing is visible on screen.
        final osmFinder = find.textContaining('OpenStreetMap');
        final cartoFinder = find.textContaining('CARTO');
        expect(osmFinder, findsOneWidget);
        expect(cartoFinder, findsOneWidget);

        for (final finder in [osmFinder, cartoFinder]) {
          final zeroOpacityAncestors = find.ancestor(
            of: finder,
            matching: find.byWidgetPredicate((widget) {
              if (widget is AnimatedOpacity) return widget.opacity == 0;
              if (widget is Opacity) return widget.opacity == 0;
              return false;
            }),
          );
          expect(
            zeroOpacityAncestors,
            findsNothing,
            reason:
                'credit text must not be hidden behind a zero-opacity '
                'wrapper (i.e. must be visible without any tap)',
          );
        }
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'marker box has no vertical slack: the box height equals the badge '
      '+ pointer content height (34 + 6 = 40px) exactly, so '
      "Alignment.topCenter's bottom-edge anchor (per flutter_map's "
      'Marker.alignment doc) lands the pointer tip precisely on the '
      'coordinate rather than floating above it',
      (tester) async {
        final container = _makeContainer();
        final db = container.read(appDatabaseProvider);
        await tester.runAsync(() => _seedStandardScenario(db));

        await tester.pumpWidget(
          _wrap(
            container,
            CommunityScreen(tileProvider: _NoopTileProvider()),
          ),
        );
        await _drain(tester);

        await tester.tap(find.byKey(const Key('community-map-toggle')));
        await _drain(tester);

        expect(tester.takeException(), isNull);

        final markerBoxSize = tester.getSize(
          find.byKey(const Key('community-map-marker-wall-shared-1')),
        );
        expect(markerBoxSize.height, 40.0);
      },
    );

    Finder markerLogoFinder(String wallId) => find.descendant(
      of: find.byKey(Key('community-map-marker-$wallId')),
      matching: find.byWidgetPredicate((widget) {
        if (widget is Image && widget.image is AssetImage) {
          return (widget.image as AssetImage).assetName ==
              'assets/icon/masi_icon.png';
        }
        return false;
      }),
    );

    testWidgets(
      'each topo marker renders the app-logo badge (an Image.asset of '
      'masi_icon.png) rather than the old pin icon, keeping its stable key',
      (tester) async {
        final container = _makeContainer();
        final db = container.read(appDatabaseProvider);
        await tester.runAsync(() => _seedStandardScenario(db));

        await tester.pumpWidget(
          _wrap(
            container,
            CommunityScreen(tileProvider: _NoopTileProvider()),
          ),
        );
        await _drain(tester);

        await tester.tap(find.byKey(const Key('community-map-toggle')));
        await _drain(tester);

        expect(tester.takeException(), isNull);
        expect(
          find.byKey(const Key('community-map-marker-wall-shared-1')),
          findsOneWidget,
        );
        expect(markerLogoFinder('wall-shared-1'), findsOneWidget);
      },
    );

    testWidgets(
      'tapping a logo marker still navigates to the topo detail route',
      (tester) async {
        final container = _makeContainer();
        final db = container.read(appDatabaseProvider);
        await tester.runAsync(() => _seedStandardScenario(db));

        await tester.pumpWidget(
          _wrapWithDetailRoute(
            container,
            CommunityScreen(tileProvider: _NoopTileProvider()),
          ),
        );
        await _drain(tester);

        await tester.tap(find.byKey(const Key('community-map-toggle')));
        await _drain(tester);

        await tester.tap(
          find.byKey(const Key('community-map-marker-wall-shared-1')),
        );
        // Bounded pumps (not pumpAndSettle) to advance the go_router push
        // transition without waiting on the TileLayer's own fade-in
        // animation underneath, which _drain's docs note is fine to leave
        // mid-flight.
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }

        expect(
          find.byKey(const Key('community-topo-detail-placeholder')),
          findsOneWidget,
        );
        expect(find.text('detail-wall-shared-1'), findsOneWidget);
      },
    );
  });

  group(
    'layout overflow regression: populated _FeedRow at phone width '
    '(regression: the grade-pill+routes row and the likes/comments/owner '
    'row must Wrap, not Row, at large text)',
    () {
      Widget wrapWithScale(
        ProviderContainer container,
        Widget screen,
        double textScale,
      ) {
        final router = GoRouter(
          initialLocation: '/',
          routes: [
            GoRoute(path: '/', builder: (context, state) => screen),
            GoRoute(
              path: '/community/topo/:wallId',
              builder: (context, state) => const SizedBox(),
            ),
          ],
        );
        return UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            theme: MasiTheme.light,
            routerConfig: router,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
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
        'a populated shared-topo feed row (grade pill + routes, likes/'
        'comments/owner) at 360x800 @ 3.0x text scale does not overflow '
        '(regression: the Filters-sheet group above deliberately seeds an '
        'EMPTY feed to dodge this exact defect)',
        (tester) async {
          setViewportSize(tester, const Size(360, 800));
          final container = _makeContainer();
          final db = container.read(appDatabaseProvider);
          await tester.runAsync(() async {
            await _seedFilterScenario(db);
            await _seedLike(db, id: 'like-stress-1', wallId: 'wall-sport');
            await _seedLike(db, id: 'like-stress-2', wallId: 'wall-sport');
            await _seedComment(
              db,
              id: 'comment-stress-1',
              wallId: 'wall-sport',
              body: 'Nice line!',
            );
          });

          await tester.pumpWidget(
            wrapWithScale(
              container,
              CommunityScreen(tileProvider: _NoopTileProvider()),
              3.0,
            ),
          );
          await _drain(tester);

          expect(tester.takeException(), isNull);
        },
      );
    },
  );

  group(
    'A: likes/comments/owner row — single line at normal scale, no '
    'overflow at large scale with a real owner (regression: RenderWrap '
    'gives every child the FULL available width, not the remaining space '
    'on the current run, so the "by <owner>" text — a 36-char Supabase '
    'auth uid, never shortened — reflows to a second line even at 1.0x)',
    () {
      Widget wrapWithScale(
        ProviderContainer container,
        Widget screen,
        double textScale,
      ) {
        final router = GoRouter(
          initialLocation: '/',
          routes: [
            GoRoute(path: '/', builder: (context, state) => screen),
            GoRoute(
              path: '/community/topo/:wallId',
              builder: (context, state) => const SizedBox(),
            ),
          ],
        );
        return UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            theme: MasiTheme.light,
            routerConfig: router,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
          ),
        );
      }

      void setViewportSize(WidgetTester tester, Size size) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
      }

      // A realistic 36-char Supabase Auth uid -- `SharedTopo.ownerId` is the
      // raw uid, never shortened, so this is exactly what ships in the "by
      // <owner>" text.
      const ownerUid = 'f1e2d3c4-b5a6-4c7d-8e9f-0a1b2c3d4e5f';

      testWidgets(
        'A1: at 390x800 @ 1.0x text scale, the owner text sits on the SAME '
        'line as the likes count',
        (tester) async {
          setViewportSize(tester, const Size(390, 800));
          final container = _makeContainer();
          final db = container.read(appDatabaseProvider);
          await tester.runAsync(() async {
            await _seedArea(db, id: 'area-a1', name: 'Area A1');
            await _seedSector(
              db,
              id: 'sector-a1',
              areaId: 'area-a1',
              name: 'S',
            );
            await _seedWall(
              db,
              id: 'wall-a1',
              sectorId: 'sector-a1',
              name: 'Wall A1',
              visibility: 'shared',
              ownerId: ownerUid,
            );
            await _seedLike(db, id: 'like-a1', wallId: 'wall-a1');
            await _seedComment(
              db,
              id: 'comment-a1',
              wallId: 'wall-a1',
              body: 'Nice!',
            );
          });

          await tester.pumpWidget(
            wrapWithScale(
              container,
              CommunityScreen(tileProvider: _NoopTileProvider()),
              1.0,
            ),
          );
          await _drain(tester);

          final ownerFinder = find.text('by $ownerUid');
          final likesFinder = find.byKey(
            const Key('community-topo-row-wall-a1-likes'),
          );
          expect(ownerFinder, findsOneWidget);
          expect(likesFinder, findsOneWidget);

          final dyDiff =
              (tester.getTopLeft(ownerFinder).dy -
                      tester.getTopLeft(likesFinder).dy)
                  .abs();
          expect(
            dyDiff,
            lessThan(0.5),
            reason:
                'owner text must sit on the same line as the likes count '
                'at normal text scale; observed dy diff was $dyDiff',
          );
        },
      );

      testWidgets(
        'A2: at 360x800 @ 3.0x text scale with a real non-null owner, the '
        'likes/comments/owner row does not overflow',
        (tester) async {
          setViewportSize(tester, const Size(360, 800));
          final container = _makeContainer();
          final db = container.read(appDatabaseProvider);
          await tester.runAsync(() async {
            await _seedArea(db, id: 'area-a2', name: 'Area A2');
            await _seedSector(
              db,
              id: 'sector-a2',
              areaId: 'area-a2',
              name: 'S',
            );
            await _seedWall(
              db,
              id: 'wall-a2',
              sectorId: 'sector-a2',
              name: 'Wall A2',
              visibility: 'shared',
              ownerId: ownerUid,
            );
            await _seedLike(db, id: 'like-a2', wallId: 'wall-a2');
            await _seedComment(
              db,
              id: 'comment-a2',
              wallId: 'wall-a2',
              body: 'Nice!',
            );
          });

          await tester.pumpWidget(
            wrapWithScale(
              container,
              CommunityScreen(tileProvider: _NoopTileProvider()),
              3.0,
            ),
          );
          await _drain(tester);

          expect(tester.takeException(), isNull);
        },
      );
    },
  );
}
