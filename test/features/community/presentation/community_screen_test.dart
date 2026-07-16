import 'dart:convert';

import 'package:climbtopo/app/theme.dart';
import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/core/db/database_provider.dart';
import 'package:climbtopo/core/location/location_service.dart';
import 'package:climbtopo/features/account/application/auth_providers.dart';
import 'package:climbtopo/features/account/data/auth_repository.dart';
import 'package:climbtopo/features/community/application/community_providers.dart';
import 'package:climbtopo/features/community/presentation/community_screen.dart';
import 'package:climbtopo/shared/presentation/masi_icon.dart';
import 'package:climbtopo/shared/filtering/grade_range.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' show BaseClient, BaseRequest, StreamedResponse;
import 'package:latlong2/latlong.dart';

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

/// A spy [Client] that resolves every request synchronously to a tiny fake
/// PNG response — never touching real DNS/sockets — and tracks whether
/// [close] was called. Used by FX3 (`community_screen_test.dart`'s MAJOR-2
/// create-once/dispose-closes-client group) to exercise
/// `_MapViewState`'s REAL `buildResilientTileHttpClient`/
/// `buildResilientTileProvider` wiring end-to-end, via
/// `CommunityScreen.tileHttpClientFactory`, without ever performing real
/// network I/O — which, like the real image-codec decode CLAUDE.md warns
/// never to drive in a widget test, would never resolve under
/// `flutter_test`'s FakeAsync zone (a real `Socket.connect` is genuine
/// OS-level async I/O, not a `Timer` FakeAsync can fast-forward — and a
/// fast local failure would still arm a real `RetryClient` backoff
/// `Timer`, which `flutter_test` flags as "a Timer is still pending" at
/// teardown).
class _SpyHttpClient extends BaseClient {
  bool closed = false;
  int sendCount = 0;

  @override
  Future<StreamedResponse> send(BaseRequest request) async {
    sendCount++;
    return StreamedResponse(Stream.value(_tinyPngBytes), 200);
  }

  @override
  void close() {
    closed = true;
    super.close();
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
///
/// Both carry an explicit foreign [_otherOwnerId] (a wallId these tests
/// never sign in as) rather than the default `null` owner: this is what a
/// wall pulled down onto this device from ANOTHER user's shared topo looks
/// like (see `SyncService.pullOwnAndShared`'s doc -- a pulled row keeps its
/// original, foreign `ownerId`, never rewritten to the signed-in uid), which
/// is exactly what these fixtures are meant to represent for the Community
/// feed/map's test purposes. Map own/community marker logic
/// (`_MapView.build` in `community_screen.dart`) treats a `null`-owner wall
/// as unambiguously local/own, so leaving these `null` would make every
/// existing map marker test below collide with the new "own topos" feature
/// (see M2/M3/M6 in the coords/own-marker test groups) -- an own-vs-shared
/// distinction these older fixtures simply never needed before.
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
    ownerId: _otherOwnerId,
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
    ownerId: _otherOwnerId,
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

/// Matches the `_BoulderMarker` (`community_screen.dart`) rendered as the
/// child of the map marker keyed [markerKey]. `_BoulderMarker` is a private
/// widget, so it can't be named via `find.byType` from this file's library
/// -- matching on `runtimeType.toString()` is the only way to find it from
/// outside its declaring library. Replaces the old `markerLogoFinder`,
/// which asserted an `Image.asset('assets/icon/masi_icon.png')` — the
/// logo-in-a-white-circle look the boulder marker replaced.
Finder _boulderMarkerFinder(Key markerKey) => find.descendant(
  of: find.byKey(markerKey),
  matching: find.byWidgetPredicate(
    (widget) => widget.runtimeType.toString() == '_BoulderMarker',
  ),
);

/// Reads the `isPublic` flag off the `_BoulderMarker` found by
/// [_boulderMarkerFinder]. Read through `dynamic` rather than a static
/// `_BoulderMarker` type -- Dart's library-privacy means `_BoulderMarker`
/// (declared in `community_screen.dart`) can't be named as a type from this
/// file's library at all, but a PUBLICLY-named member (`isPublic`, no
/// leading underscore) on an instance obtained dynamically is still
/// reachable regardless of which library declared or is naming the
/// instance's class.
bool _boulderMarkerIsPublic(WidgetTester tester, Key markerKey) {
  final widget = tester.widget(_boulderMarkerFinder(markerKey));
  return (widget as dynamic).isPublic as bool;
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

/// Owner uid these tests never sign in as (`_makeContainer` never overrides
/// `authStateProvider`, so `myUid` resolves to `null`) -- used to give the
/// pre-existing "community" fixture walls below (`wall-shared-1`,
/// `wall-sport`, `wall-trad`) a realistic foreign owner instead of the
/// default `null`, so the Map tab's new own-vs-community split (see
/// `_MapView.build`'s doc in `community_screen.dart`) correctly treats them
/// as NOT this device's own topos. See `_seedFilterScenario`'s doc for the
/// full rationale.
const _otherOwnerId = 'other-user';

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
    ownerId: _otherOwnerId,
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

  group(
    'Own-topo map markers (GPS-on-map fix): a user\'s own located topos '
    'must show on the map even while still private',
    () {
      testWidgets(
        'M2: an own (local, private) topo with coords shows '
        'community-map-own-marker-<id>; a shared topo owned by someone else '
        'shows community-map-marker-<id> -- both present, distinct keys',
        (tester) async {
          final container = _makeContainer();
          final db = container.read(appDatabaseProvider);
          await tester.runAsync(() async {
            await _seedArea(db, id: 'area-own', name: 'Area Own');
            await _seedSector(
              db,
              id: 'sector-own',
              areaId: 'area-own',
              name: 'S',
            );
            // Own: a private local wall with coordinates -- never shared,
            // so it is NOT in the sharedToposProvider feed at all. Kept
            // a hair away (not a full degree, like C1's my-location fixture)
            // from wall-community-1's coordinates so BOTH stay inside
            // flutter_map's on-screen culling bounds at the auto-computed
            // averaged center/zoom -- flutter_test's tiny default surface
            // only ever shows a small fraction of a degree at zoom 11.
            await _seedWall(
              db,
              id: 'wall-own-1',
              sectorId: 'sector-own',
              name: 'My Secret Wall',
              latitude: 45.0,
              longitude: 7.0,
            );
            // Community: shared, owned by someone else.
            await _seedWall(
              db,
              id: 'wall-community-1',
              sectorId: 'sector-own',
              name: 'Someone Else\'s Wall',
              visibility: 'shared',
              latitude: 45.001,
              longitude: 7.001,
              ownerId: _otherOwnerId,
            );
          });

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
            find.byKey(const Key('community-map-own-marker-wall-own-1')),
            findsOneWidget,
          );
          expect(
            find.byKey(const Key('community-map-marker-wall-own-1')),
            findsNothing,
          );
          expect(
            find.byKey(
              const Key('community-map-marker-wall-community-1'),
            ),
            findsOneWidget,
          );
          expect(
            find.byKey(
              const Key('community-map-own-marker-wall-community-1'),
            ),
            findsNothing,
          );
        },
      );

      testWidgets(
        'M3: a wall that is both own AND shared (a published own topo) '
        'renders exactly once, as the OWN marker -- the community marker '
        'for the same wallId is absent',
        (tester) async {
          final db = AppDatabase(NativeDatabase.memory());
          addTearDown(db.close);
          final container = ProviderContainer(
            overrides: [
              appDatabaseProvider.overrideWithValue(db),
              nowMsProvider.overrideWithValue(() => 1000),
              authStateProvider.overrideWith(
                (ref) => Stream.value(
                  const AuthSessionState.signedIn(
                    'me@example.com',
                    uid: 'me',
                  ),
                ),
              ),
            ],
          );
          addTearDown(container.dispose);

          await tester.runAsync(() async {
            await _seedArea(db, id: 'area-dedupe', name: 'Area Dedupe');
            await _seedSector(
              db,
              id: 'sector-dedupe',
              areaId: 'area-dedupe',
              name: 'S',
            );
            await _seedWall(
              db,
              id: 'wall-mine-shared',
              sectorId: 'sector-dedupe',
              name: 'My Published Wall',
              visibility: 'shared',
              latitude: 50.0,
              longitude: 60.0,
              ownerId: 'me',
            );
          });

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
            find.byKey(
              const Key('community-map-own-marker-wall-mine-shared'),
            ),
            findsOneWidget,
          );
          expect(
            find.byKey(const Key('community-map-marker-wall-mine-shared')),
            findsNothing,
          );
        },
      );

      testWidgets(
        'M4: own located topos with ZERO shared topos still render on the '
        'map (not empty) -- the map centers/zooms on the own markers',
        (tester) async {
          final container = _makeContainer();
          final db = container.read(appDatabaseProvider);
          await tester.runAsync(() async {
            await _seedArea(db, id: 'area-own-only', name: 'Area Own Only');
            await _seedSector(
              db,
              id: 'sector-own-only',
              areaId: 'area-own-only',
              name: 'S',
            );
            await _seedWall(
              db,
              id: 'wall-own-only',
              sectorId: 'sector-own-only',
              name: 'Only Mine',
              latitude: 12.0,
              longitude: 34.0,
            );
          });

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
            find.byKey(const Key('community-map-own-marker-wall-own-only')),
            findsOneWidget,
          );
          // No shared topos were seeded at all -> zero community markers,
          // yet the map is still zoomed in on the own marker(s) rather than
          // falling back to the empty (0,0)/1.5 world view.
          final flutterMap = tester.widget<FlutterMap>(
            find.byType(FlutterMap),
          );
          expect(flutterMap.options.initialZoom, 11);
          expect(flutterMap.options.initialCenter, const LatLng(12.0, 34.0));
        },
      );

      testWidgets(
        'M5: community-map-legend is shown, distinguishing Private from '
        'Public',
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
          final legendFinder = find.byKey(
            const Key('community-map-legend'),
          );
          expect(legendFinder, findsOneWidget);
          expect(
            find.descendant(
              of: legendFinder,
              matching: find.textContaining('Private'),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: legendFinder,
              matching: find.textContaining('Public'),
            ),
            findsOneWidget,
          );
        },
      );

      testWidgets(
        'F1 (safety regression): a shared topo with a null ownerId (a '
        'legacy/pre-ownership row with no owner stamp), viewed signed-out '
        '(myUid also null), must NOT be misclassified as own -- a '
        'null-owner must never be treated as equal to a null myUid. It '
        'renders as a COMMUNITY marker (read-only detail), never as the '
        'OWN marker, which would route into this device\'s wall editor '
        'for a wall this device does not actually own',
        (tester) async {
          final container = _makeContainer();
          final db = container.read(appDatabaseProvider);
          await tester.runAsync(() async {
            await _seedArea(
              db,
              id: 'area-foreign-null',
              name: 'Area Foreign Null',
            );
            await _seedSector(
              db,
              id: 'sector-foreign-null',
              areaId: 'area-foreign-null',
              name: 'S',
            );
            // A shared topo (present in the sync/community feed) whose
            // ownerId is null -- e.g. a legacy row synced before ownership
            // stamping existed. `_makeContainer` never overrides
            // `authStateProvider`, so `myUid` is also null here
            // (signed-out) -- exactly the null-owner/null-myUid collision
            // the safety fix guards against.
            await _seedWall(
              db,
              id: 'wall-foreign-null-owner',
              sectorId: 'sector-foreign-null',
              name: 'Foreign Null-Owner Wall',
              visibility: 'shared',
              latitude: 45.0,
              longitude: 7.0,
            );
          });

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
            find.byKey(
              const Key('community-map-marker-wall-foreign-null-owner'),
            ),
            findsOneWidget,
          );
          expect(
            find.byKey(
              const Key('community-map-own-marker-wall-foreign-null-owner'),
            ),
            findsNothing,
          );
        },
      );
    },
  );

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
          find.byWidgetPredicate((w) => w is MasiIcon && w.name == 'filter_active'),
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
          find.byWidgetPredicate((w) => w is MasiIcon && w.name == 'filter_active'),
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
          find.byWidgetPredicate((w) => w is MasiIcon && w.name == 'filter_active'),
          findsOneWidget,
        );

        await tester.tap(find.byKey(const Key('community-filter-clear')));
        await tester.pumpAndSettle();

        expect(_feedRowFinder(), findsNWidgets(2));
        expect(
          find.byWidgetPredicate((w) => w is MasiIcon && w.name == 'filter_active'),
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
      'marker box has no vertical slack: the box height equals '
      '_BoulderMarker.totalHeight (40px) exactly, so '
      "Alignment.topCenter's bottom-edge anchor (per flutter_map's "
      'Marker.alignment doc) keeps the bottom-anchored boulder marker '
      "sitting precisely on the coordinate rather than floating above it",
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

    testWidgets(
      'each topo marker renders the faceted boulder marker (replacing the '
      'old app-logo-in-a-white-circle pin), keeping its stable key',
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
        expect(
          _boulderMarkerFinder(
            const Key('community-map-marker-wall-shared-1'),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'boulder marker tint encodes visibility: an own PRIVATE topo renders '
      'isPublic == false, while an own PUBLIC (shared) topo and a '
      'community topo both render isPublic == true',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 1000),
            authStateProvider.overrideWith(
              (ref) => Stream.value(
                const AuthSessionState.signedIn('me@example.com', uid: 'me'),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        await tester.runAsync(() async {
          await _seedArea(db, id: 'area-tint', name: 'Area Tint');
          await _seedSector(db, id: 'sector-tint', areaId: 'area-tint', name: 'S');
          // Own, private: never shared, so it's not in the community feed
          // at all -- must render the DARK (private) boulder.
          await _seedWall(
            db,
            id: 'wall-own-private',
            sectorId: 'sector-tint',
            name: 'Own Private',
            latitude: 45.0,
            longitude: 7.0,
            ownerId: 'me',
          );
          // Own, public (shared): renders exactly once, as the own marker
          // (see M3) -- must render the LIGHT (public) boulder.
          await _seedWall(
            db,
            id: 'wall-own-public',
            sectorId: 'sector-tint',
            name: 'Own Public',
            visibility: 'shared',
            latitude: 45.001,
            longitude: 7.001,
            ownerId: 'me',
          );
          // Community: someone else's shared topo -- always renders the
          // LIGHT (public) boulder, per `CommunityRepository.watchSharedTopos`
          // only ever surfacing `visibility == 'shared'` rows.
          await _seedWall(
            db,
            id: 'wall-community',
            sectorId: 'sector-tint',
            name: 'Community Topo',
            visibility: 'shared',
            latitude: 45.002,
            longitude: 7.002,
            ownerId: _otherOwnerId,
          );
        });

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
          _boulderMarkerIsPublic(
            tester,
            const Key('community-map-own-marker-wall-own-private'),
          ),
          isFalse,
        );
        expect(
          _boulderMarkerIsPublic(
            tester,
            const Key('community-map-own-marker-wall-own-public'),
          ),
          isTrue,
        );
        expect(
          _boulderMarkerIsPublic(
            tester,
            const Key('community-map-marker-wall-community'),
          ),
          isTrue,
        );
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

    testWidgets(
      'C1/C2/C3: TileLayer evicts off-screen error tiles (so a transient '
      'fetch failure is re-requested on zoom/pan instead of staying a '
      'permanent gray rectangle), fetches real tiles up to native zoom 20, '
      'and keeps a slightly larger keep-buffer -- while the urlTemplate '
      'regression guard from the test above still holds',
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

        final tileLayer = tester.widget<TileLayer>(find.byType(TileLayer));
        // C1: off-screen error tiles must be evicted so zooming/panning
        // re-requests them instead of leaving a permanent gray hole.
        expect(
          tileLayer.evictErrorTileStrategy,
          EvictErrorTileStrategy.notVisibleRespectMargin,
        );
        // C2: CartoDB light_all serves real tiles through z20.
        expect(tileLayer.maxNativeZoom, 20);
        // C3 regression guard: urlTemplate is unchanged, and keepBuffer is
        // bumped from the default of 2 to 3.
        expect(
          tileLayer.urlTemplate,
          'https://basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png',
        );
        expect(tileLayer.keepBuffer, 3);
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

  group(
    'T2: own-topo badge — clear division between community and own topos '
    '(feed side of the pairing with T1\'s visibility badge)',
    () {
      testWidgets(
        'the signed-in uid\'s own shared topo shows the Yours badge; a '
        'topo owned by someone else, and one with no owner at all, do not',
        (tester) async {
          final db = AppDatabase(NativeDatabase.memory());
          addTearDown(db.close);
          final container = ProviderContainer(
            overrides: [
              appDatabaseProvider.overrideWithValue(db),
              nowMsProvider.overrideWithValue(() => 1000),
              authStateProvider.overrideWith(
                (ref) => Stream.value(
                  const AuthSessionState.signedIn(
                    'me@example.com',
                    uid: 'me',
                  ),
                ),
              ),
            ],
          );
          addTearDown(container.dispose);

          await tester.runAsync(() async {
            await _seedArea(db, id: 'area-own', name: 'Area Own');
            await _seedSector(
              db,
              id: 'sector-own',
              areaId: 'area-own',
              name: 'S',
            );
            await _seedWall(
              db,
              id: 'wall-mine',
              sectorId: 'sector-own',
              name: 'Mine',
              visibility: 'shared',
              ownerId: 'me',
            );
            await _seedWall(
              db,
              id: 'wall-other',
              sectorId: 'sector-own',
              name: 'Someone Else\'s',
              visibility: 'shared',
              ownerId: 'other',
            );
            await _seedWall(
              db,
              id: 'wall-no-owner',
              sectorId: 'sector-own',
              name: 'No Owner',
              visibility: 'shared',
            );
          });

          await tester.pumpWidget(
            _wrap(
              container,
              CommunityScreen(tileProvider: _NoopTileProvider()),
            ),
          );
          await _drain(tester);

          expect(tester.takeException(), isNull);
          expect(
            find.byKey(const Key('community-own-badge-wall-mine')),
            findsOneWidget,
          );
          expect(
            find.byKey(const Key('community-own-badge-wall-other')),
            findsNothing,
          );
          expect(
            find.byKey(const Key('community-own-badge-wall-no-owner')),
            findsNothing,
          );
        },
      );
    },
  );

  group('Q2/Q3: initialTab + focusWallId deep link', () {
    testWidgets(
      'CommunityScreen(initialTab: CommunityTab.map, focusWallId: X) opens '
      'on the Map tab, centered/zoomed on X\'s coordinates (not the '
      'combined-set center)',
      (tester) async {
        final container = _makeContainer();
        final db = container.read(appDatabaseProvider);
        await tester.runAsync(() async {
          await _seedArea(db, id: 'area-focus', name: 'Area Focus');
          await _seedSector(
            db,
            id: 'sector-focus',
            areaId: 'area-focus',
            name: 'S',
          );
          await _seedWall(
            db,
            id: 'wall-focus',
            sectorId: 'sector-focus',
            name: 'Focus Wall',
            latitude: 12.0,
            longitude: 34.0,
          );
          // A second, far-away located wall proves the map centers on the
          // FOCUSED wall specifically, not the average of both.
          await _seedWall(
            db,
            id: 'wall-other',
            sectorId: 'sector-focus',
            name: 'Other Wall',
            latitude: -50.0,
            longitude: 170.0,
          );
        });

        await tester.pumpWidget(
          _wrap(
            container,
            CommunityScreen(
              tileProvider: _NoopTileProvider(),
              initialTab: CommunityTab.map,
              focusWallId: 'wall-focus',
            ),
          ),
        );
        await _drain(tester);

        expect(tester.takeException(), isNull);
        // Opened straight on the Map tab: the Feed's search field is never
        // shown, and exactly one FlutterMap is built without needing to tap
        // `community-map-toggle` first.
        expect(find.byKey(const Key('community-search-field')), findsNothing);
        expect(find.byType(FlutterMap), findsOneWidget);

        final flutterMap = tester.widget<FlutterMap>(find.byType(FlutterMap));
        expect(flutterMap.options.initialCenter, const LatLng(12.0, 34.0));
        expect(flutterMap.options.initialZoom, 15);
      },
    );

    testWidgets(
      'a focusWallId that matches no rendered topo (not found / no coords) '
      'falls back to the existing combined-set center/zoom, never crashes',
      (tester) async {
        final container = _makeContainer();
        final db = container.read(appDatabaseProvider);
        await tester.runAsync(() async {
          await _seedArea(db, id: 'area-nofocus', name: 'Area No Focus');
          await _seedSector(
            db,
            id: 'sector-nofocus',
            areaId: 'area-nofocus',
            name: 'S',
          );
          await _seedWall(
            db,
            id: 'wall-real',
            sectorId: 'sector-nofocus',
            name: 'Real Wall',
            latitude: 12.0,
            longitude: 34.0,
          );
        });

        await tester.pumpWidget(
          _wrap(
            container,
            CommunityScreen(
              tileProvider: _NoopTileProvider(),
              initialTab: CommunityTab.map,
              focusWallId: 'does-not-exist',
            ),
          ),
        );
        await _drain(tester);

        expect(tester.takeException(), isNull);
        final flutterMap = tester.widget<FlutterMap>(find.byType(FlutterMap));
        expect(flutterMap.options.initialZoom, 11);
        expect(flutterMap.options.initialCenter, const LatLng(12.0, 34.0));
      },
    );

    testWidgets(
      'plain CommunityScreen() (no initialTab/focusWallId) still opens on '
      'the Feed tab -- regression',
      (tester) async {
        final container = _makeContainer();

        await tester.pumpWidget(
          _wrap(container, CommunityScreen(tileProvider: _NoopTileProvider())),
        );
        await _drain(tester);

        expect(tester.takeException(), isNull);
        expect(find.byType(FlutterMap), findsNothing);
        expect(
          find.byKey(const Key('community-search-field')),
          findsOneWidget,
        );
      },
    );
  });

  group('MC1: default map center — device location vs (0,0) fallback', () {
    testWidgets(
      'FX1 (MAJOR 1): no located topos + a device location fix -> the '
      'CAMERA is imperatively moved to that fix at zoom ~12 once the fix '
      'resolves (not merely `options.initialCenter`, which flutter_map only '
      'honors ONCE at first mount -- before an autoDispose FutureProvider '
      "like `myLocationProvider` has resolved -- so reading the map's "
      'actual camera, via an injected MapController, is what proves the '
      'production bug: before the fix, the camera stays parked at '
      '(0,0)/1.5 forever even though `options.initialCenter` recomputes '
      'correctly on the next rebuild)',
      (tester) async {
        final controller = MapController();
        addTearDown(controller.dispose);
        final container = _makeContainer(
          locationService: const _FakeLocationService((
            latitude: 51.5,
            longitude: -0.1,
          )),
        );
        final db = container.read(appDatabaseProvider);
        // No walls seeded at all -- no located topos, own or shared.
        await tester.runAsync(() async {
          await _seedArea(db, id: 'area-empty', name: 'Area Empty');
        });

        await tester.pumpWidget(
          _wrap(
            container,
            CommunityScreen(
              tileProvider: _NoopTileProvider(),
              initialTab: CommunityTab.map,
              mapController: controller,
            ),
          ),
        );
        await _drain(tester);

        expect(tester.takeException(), isNull);
        final camera = controller.camera;
        expect((camera.center.latitude - 51.5).abs(), lessThan(0.01));
        expect((camera.center.longitude - (-0.1)).abs(), lessThan(0.01));
        expect(camera.zoom, 12);
      },
    );

    testWidgets(
      'no located topos AND no device location -> still falls back to '
      '(0,0)/1.5 (regression)',
      (tester) async {
        final container = _makeContainer(
          locationService: const _FakeLocationService(null),
        );
        final db = container.read(appDatabaseProvider);
        await tester.runAsync(() async {
          await _seedArea(db, id: 'area-empty2', name: 'Area Empty 2');
        });

        await tester.pumpWidget(
          _wrap(
            container,
            CommunityScreen(
              tileProvider: _NoopTileProvider(),
              initialTab: CommunityTab.map,
            ),
          ),
        );
        await _drain(tester);

        expect(tester.takeException(), isNull);
        final flutterMap = tester.widget<FlutterMap>(find.byType(FlutterMap));
        expect(flutterMap.options.initialCenter, const LatLng(0, 0));
        expect(flutterMap.options.initialZoom, 1.5);
      },
    );
  });

  group(
    'FX2: device-location auto-center is one-shot and never overrides a '
    'located-topos framing',
    () {
      testWidgets(
        'FX2a: after the auto-center resolves, further map interaction '
        '(rotate) does not re-trigger it -- the camera center stays put',
        (tester) async {
          final controller = MapController();
          addTearDown(controller.dispose);
          final container = _makeContainer(
            locationService: const _FakeLocationService((
              latitude: 51.5,
              longitude: -0.1,
            )),
          );
          final db = container.read(appDatabaseProvider);
          await tester.runAsync(() async {
            await _seedArea(db, id: 'area-empty3', name: 'Area Empty 3');
          });

          await tester.pumpWidget(
            _wrap(
              container,
              CommunityScreen(
                tileProvider: _NoopTileProvider(),
                initialTab: CommunityTab.map,
                mapController: controller,
              ),
            ),
          );
          await _drain(tester);

          expect(
            (controller.camera.center.latitude - 51.5).abs(),
            lessThan(0.01),
          );

          controller.rotate(30);
          await tester.pump();

          expect(tester.takeException(), isNull);
          expect(controller.camera.rotation, 30);
          expect(
            (controller.camera.center.latitude - 51.5).abs(),
            lessThan(0.01),
          );
          expect(
            (controller.camera.center.longitude - (-0.1)).abs(),
            lessThan(0.01),
          );
        },
      );

      testWidgets(
        'FX2b: located topos are already present -> the device-location '
        'auto-center never fires; the camera stays framed on the topos\' '
        'combined center, never jumping to the (unrelated) device fix',
        (tester) async {
          final controller = MapController();
          addTearDown(controller.dispose);
          final container = _makeContainer(
            locationService: const _FakeLocationService((
              latitude: 51.5,
              longitude: -0.1,
            )),
          );
          final db = container.read(appDatabaseProvider);
          await tester.runAsync(() => _seedStandardScenario(db));

          await tester.pumpWidget(
            _wrap(
              container,
              CommunityScreen(
                tileProvider: _NoopTileProvider(),
                initialTab: CommunityTab.map,
                mapController: controller,
              ),
            ),
          );
          await _drain(tester);

          expect(tester.takeException(), isNull);
          final camera = controller.camera;
          // wall-shared-1 is the only located topo (45.0, 7.0) -- the
          // camera must stay framed there, never jumping to the fake
          // 51.5/-0.1 device fix.
          expect((camera.center.latitude - 45.0).abs(), lessThan(0.5));
          expect((camera.center.longitude - 7.0).abs(), lessThan(0.5));
        },
      );
    },
  );

  group('MC2: resilient tile provider factory', () {
    test(
      'buildResilientTileProvider() returns a non-null NetworkTileProvider '
      'without throwing (the retry behavior itself -- 429/5xx/connection- '
      'error retries with backoff -- is on-device-only and not exercised '
      'here)',
      () {
        final provider = buildResilientTileProvider();
        expect(provider, isA<NetworkTileProvider>());
      },
    );

    test(
      'buildResilientTileHttpClient(inner: ...) wraps the GIVEN client '
      'rather than allocating its own real http.Client() -- the seam '
      'FX3 below relies on to exercise the retry-policy wiring with a spy',
      () {
        final spy = _SpyHttpClient();
        final client = buildResilientTileHttpClient(inner: spy);
        expect(client, isNotNull);
        // Closing the returned (RetryClient-wrapped) client must close the
        // exact spy passed in -- RetryClient.close() delegates to its inner
        // client -- proving `inner` is genuinely wired through rather than
        // ignored in favor of a fresh internal Client().
        client.close();
        expect(spy.closed, isTrue);
      },
    );
  });

  group(
    'FX3 (MAJOR 2): resilient tile provider is created ONCE per '
    '_MapViewState (never per-rebuild) and its client is closed on dispose',
    () {
      testWidgets(
        'with NO injected tileProvider (only a spy tileHttpClientFactory, '
        'so no real network I/O ever happens), TileLayer.tileProvider stays '
        'the SAME instance across a rebuild triggered by the compass -- '
        'proving create-once -- and dispose() closes exactly the client '
        'this widget created',
        (tester) async {
          debugResetResilientTileClientCounters();
          final spyClient = _SpyHttpClient();
          final controller = MapController();
          addTearDown(controller.dispose);
          final container = _makeContainer();
          final db = container.read(appDatabaseProvider);
          await tester.runAsync(() => _seedStandardScenario(db));

          await tester.pumpWidget(
            _wrap(
              container,
              CommunityScreen(
                initialTab: CommunityTab.map,
                mapController: controller,
                tileHttpClientFactory: () => spyClient,
              ),
            ),
          );
          await _drain(tester);

          expect(tester.takeException(), isNull);
          expect(debugResilientTileClientCreateCount, 1);

          final firstProvider = tester
              .widget<TileLayer>(find.byType(TileLayer))
              .tileProvider;
          expect(firstProvider, isA<NetworkTileProvider>());

          // Trigger a rebuild via the compass's rotation-driven setState --
          // the exact path MAJOR 2's bug report identifies as the source of
          // the per-rebuild client leak.
          controller.rotate(30);
          await tester.pump();

          expect(tester.takeException(), isNull);
          final secondProvider = tester
              .widget<TileLayer>(find.byType(TileLayer))
              .tileProvider;
          expect(
            identical(firstProvider, secondProvider),
            isTrue,
            reason:
                'the SAME NetworkTileProvider instance must be reused '
                'across rebuilds, not reallocated',
          );
          expect(
            debugResilientTileClientCreateCount,
            1,
            reason: 'a second rebuild must not create a second client',
          );
          expect(spyClient.closed, isFalse);

          // Tear this widget down (replace the whole tree) so
          // `_MapViewState.dispose()` runs, then confirm it closed exactly
          // the client this widget itself created.
          await tester.pumpWidget(const SizedBox());
          await tester.pump();

          expect(tester.takeException(), isNull);
          expect(spyClient.closed, isTrue);
          expect(debugResilientTileClientCloseCount, 1);
        },
      );

      testWidgets(
        'an injected tileProvider (e.g. _NoopTileProvider, as every other '
        'test in this file uses) bypasses this entirely -- no resilient '
        'client is ever created, so dispose() has nothing of its own to '
        'close',
        (tester) async {
          debugResetResilientTileClientCounters();
          final container = _makeContainer();
          final db = container.read(appDatabaseProvider);
          await tester.runAsync(() => _seedStandardScenario(db));

          await tester.pumpWidget(
            _wrap(
              container,
              CommunityScreen(
                tileProvider: _NoopTileProvider(),
                initialTab: CommunityTab.map,
              ),
            ),
          );
          await _drain(tester);

          expect(tester.takeException(), isNull);
          expect(debugResilientTileClientCreateCount, 0);

          await tester.pumpWidget(const SizedBox());
          await tester.pump();

          expect(tester.takeException(), isNull);
          expect(debugResilientTileClientCloseCount, 0);
        },
      );
    },
  );

  group('MC3: find-me map control', () {
    testWidgets(
      'tapping community-map-find-me fetches a fresh fix and recenters/'
      'zooms the injected MapController to it',
      (tester) async {
        final controller = MapController();
        addTearDown(controller.dispose);
        final container = _makeContainer(
          locationService: const _FakeLocationService((
            latitude: 40.0,
            longitude: -3.7,
          )),
        );
        final db = container.read(appDatabaseProvider);
        await tester.runAsync(() => _seedStandardScenario(db));

        await tester.pumpWidget(
          _wrap(
            container,
            CommunityScreen(
              tileProvider: _NoopTileProvider(),
              initialTab: CommunityTab.map,
              mapController: controller,
            ),
          ),
        );
        await _drain(tester);

        await tester.tap(find.byKey(const Key('community-map-find-me')));
        await _drain(tester);

        expect(tester.takeException(), isNull);
        final camera = controller.camera;
        expect((camera.center.latitude - 40.0).abs(), lessThan(0.01));
        expect((camera.center.longitude - (-3.7)).abs(), lessThan(0.01));
        expect(camera.zoom, 14);
      },
    );

    testWidgets(
      'when the location service resolves null, shows a "Location '
      'unavailable" SnackBar instead of moving the map',
      (tester) async {
        final controller = MapController();
        addTearDown(controller.dispose);
        final container = _makeContainer(
          locationService: const _FakeLocationService(null),
        );
        final db = container.read(appDatabaseProvider);
        await tester.runAsync(() => _seedStandardScenario(db));

        await tester.pumpWidget(
          _wrap(
            container,
            CommunityScreen(
              tileProvider: _NoopTileProvider(),
              initialTab: CommunityTab.map,
              mapController: controller,
            ),
          ),
        );
        await _drain(tester);

        await tester.tap(find.byKey(const Key('community-map-find-me')));
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(find.text('Location unavailable'), findsOneWidget);
      },
    );
  });

  group('MC4: compass map control', () {
    testWidgets(
      'tapping community-map-compass resets the injected MapController\'s '
      'rotation to 0',
      (tester) async {
        final controller = MapController();
        addTearDown(controller.dispose);
        final container = _makeContainer();
        final db = container.read(appDatabaseProvider);
        await tester.runAsync(() => _seedStandardScenario(db));

        await tester.pumpWidget(
          _wrap(
            container,
            CommunityScreen(
              tileProvider: _NoopTileProvider(),
              initialTab: CommunityTab.map,
              mapController: controller,
            ),
          ),
        );
        await _drain(tester);

        controller.rotate(45);
        await tester.pump();

        expect(controller.camera.rotation, 45);

        await tester.tap(find.byKey(const Key('community-map-compass')));
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(controller.camera.rotation, 0);
      },
    );
  });

  group('MC5: no regression — map controls do not disturb existing behavior', () {
    testWidgets(
      'tile config (urlTemplate/evictErrorTileStrategy/maxNativeZoom/'
      'keepBuffer), attribution, legend, and my-location marker all still '
      'render as before once the Stack/MapController restructuring lands',
      (tester) async {
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
            CommunityScreen(
              tileProvider: _NoopTileProvider(),
              initialTab: CommunityTab.map,
            ),
          ),
        );
        await _drain(tester);

        expect(tester.takeException(), isNull);

        final tileLayer = tester.widget<TileLayer>(find.byType(TileLayer));
        expect(
          tileLayer.urlTemplate,
          'https://basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png',
        );
        expect(
          tileLayer.evictErrorTileStrategy,
          EvictErrorTileStrategy.notVisibleRespectMargin,
        );
        expect(tileLayer.maxNativeZoom, 20);
        expect(tileLayer.keepBuffer, 3);

        expect(
          find.byKey(const Key('community-map-attribution')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('community-map-legend')), findsOneWidget);
        expect(
          find.byKey(const Key('community-map-marker-wall-shared-1')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('community-map-my-location')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('community-map-find-me')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('community-map-compass')),
          findsOneWidget,
        );
      },
    );
  });
}
