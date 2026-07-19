// Tests for the unified map-search overlay added to the Community screen's
// Map tab (`_MapView` in `community_screen.dart`) — Lane C2 / plan
// `masi-map-unified-search.md`'s Subtask 2 (assertions B1-B6).
//
// Deliberately a SEPARATE file from `community_screen_test.dart` (rather
// than appended to that already-large file): this feature only touches
// `_MapView`, and keeping it isolated avoids any merge/edit collision with
// that file while both are potentially in flux.
//
// Mirrors two existing idioms directly:
// - `community_screen_test.dart`'s `_wrap`/`_NoopTileProvider`/`_drain`
//   (real in-memory Drift DB + a `MaterialApp.router` host + a bounded
//   pump-loop instead of `pumpAndSettle`, since a `TileLayer`'s fade-in
//   `AnimationController` never settles).
// - `set_location_search_test.dart`'s `_FakeGeocodingService` (a
//   [GeocodingService] double that never touches the real network) and its
//   debounce-driving `tester.pump(const Duration(milliseconds: 400))`
//   pattern.
import 'dart:convert';

import 'package:climbtopo/app/theme.dart';
import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/core/db/database_provider.dart';
import 'package:climbtopo/core/location/geocoding_service.dart';
import 'package:climbtopo/features/community/presentation/community_screen.dart';
import 'package:climbtopo/features/library/application/library_providers.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// A minimal-but-real 1x1 transparent PNG (base64) — copied from
/// `community_screen_test.dart`'s identical fixture — used as the
/// (already-decoded) in-memory image every fake tile "loads".
final _tinyPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY'
  '42YAAAAASUVORK5CYII=',
);

/// A tile provider that never performs any network/file I/O — copied from
/// `community_screen_test.dart`'s identical private class — so the Map
/// tab's `TileLayer` never attempts a real network fetch under
/// `flutter_test`.
class _NoopTileProvider extends TileProvider {
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    return MemoryImage(_tinyPngBytes);
  }
}

/// A [GeocodingService] double that resolves every query to whatever fixed
/// [results] list it was constructed with, ignoring the query text —
/// mirrors `set_location_search_test.dart`'s `_FakeGeocodingService`
/// (simplified: this feature's tests don't need the stale-result-race
/// completer plumbing that file's version adds, since B2's seq-guard is
/// already covered by that file's tests for the shared skeleton).
class _FakeGeocodingService implements GeocodingService {
  _FakeGeocodingService(this.results);

  final List<PlaceResult> results;
  int callCount = 0;

  @override
  Future<List<PlaceResult>> search(String query) async {
    callCount++;
    return results;
  }
}

/// Builds a [ProviderContainer] wired to a fresh in-memory database, with
/// [geocodingServiceProvider] overridden to [geocoding] so no test ever
/// touches a real Nominatim endpoint.
ProviderContainer _makeContainer({required GeocodingService geocoding}) {
  final db = AppDatabase(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      nowMsProvider.overrideWithValue(() => 1000),
      geocodingServiceProvider.overrideWithValue(geocoding),
    ],
  );
  addTearDown(db.close);
  addTearDown(container.dispose);
  return container;
}

/// Wraps [screen] in a real (minimal) [GoRouter] — copied from
/// `community_screen_test.dart`'s identical `_wrap` — so any `context.push`
/// call inside [CommunityScreen] (e.g. tapping a boulder marker) resolves
/// against a real router instead of throwing for lack of one.
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

/// Advances real asynchronous work (Drift's in-memory background executor
/// AND a fake [GeocodingService]'s `Future`) that would otherwise never
/// make progress under `testWidgets`' fake-async clock, then pumps to flush
/// the resulting Riverpod-triggered rebuilds — copied from
/// `community_screen_test.dart`'s identical `_drain` (deliberately not
/// `pumpAndSettle`: a `TileLayer`'s fade-in `AnimationController` never
/// settles, and these assertions never depend on tile pixels).
Future<void> _drain(WidgetTester tester) async {
  // A slightly longer loop than `community_screen_test.dart`'s identical
  // helper (6 iterations): this file's local-content results additionally
  // depend on `locatedRoutesProvider`/`locatedSectorsProvider`/
  // `locatedAreasProvider`, which — unlike `toposProvider` (already watched
  // from `_MapView`'s very first build) — only start being watched the
  // FIRST time a query settles, i.e. mid-test rather than at
  // `pumpWidget` time. A freshly-started Drift `.watch()` stream's first
  // emission needs a few more real event-loop turns than one that's
  // already warm.
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 30));
  }
}

/// Seeds one located Area → Sector → Wall chain, all sharing a common name
/// fragment (so a single search query can match all three at once — the
/// same "Riverside"/"Sunny" fixture shape `map_search_providers_test.dart`
/// and `map_search_test.dart` already use for the data-layer half of this
/// feature) — via the real [LibraryCrudRepository], never a hand-rolled SQL
/// insert, so this exercises the exact same write path production code
/// uses.
Future<void> _seedLocatedChain(
  ProviderContainer container, {
  required String areaName,
  required String sectorName,
  required String wallName,
  required double latitude,
  required double longitude,
}) async {
  final repo = container.read(libraryCrudRepositoryProvider);
  final area = await repo.createArea(areaName);
  final sector = await repo.createSector(area.id, sectorName);
  final wall = await repo.createWall(sector.id, wallName);
  await repo.setWallCoordinates(wall.id, latitude, longitude);
}

/// Reads a `community-map-search-result-$i` row's title text, or `null` if
/// that row isn't a plain [Text] title (it always is, in this widget) — a
/// small helper to assert on grouping/ordering without depending on the
/// exact subtitle string this feature happens to render.
String? _titleTextOf(WidgetTester tester, Key key) {
  final tile = tester.widget<ListTile>(find.byKey(key));
  final title = tile.title;
  return title is Text ? title.data : null;
}

void main() {
  group('B1: community-map-search-field overlay', () {
    testWidgets('is present on the Map tab', (tester) async {
      final geocoding = _FakeGeocodingService(const []);
      final container = _makeContainer(geocoding: geocoding);

      await tester.pumpWidget(
        _wrap(
          container,
          CommunityMapScreen(tileProvider: _NoopTileProvider()),
        ),
      );
      await _drain(tester);

      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const Key('community-map-search-field')),
        findsOneWidget,
      );
      // B5: the find-me control this overlay is a sibling of must still be
      // present too. The compass/reset-north control was removed once
      // rotation was disabled (see community_screen_test.dart's MC4) --
      // there's nothing left for it to reset.
      expect(find.byKey(const Key('community-map-find-me')), findsOneWidget);
      expect(find.byKey(const Key('community-map-compass')), findsNothing);
    });
  });

  group('B2/B3: combined search — grouped local-then-places results', () {
    testWidgets(
      'a settled query shows local content (topo/sector/area) ranked above '
      'places, and calls the geocoding service exactly once for it',
      (tester) async {
        final places = const [
          PlaceResult(
            displayName: 'Sunnyvale, California',
            latitude: 37.36,
            longitude: -122.03,
          ),
          PlaceResult(
            displayName: 'Sunny Beach, Bulgaria',
            latitude: 42.68,
            longitude: 27.71,
          ),
        ];
        final geocoding = _FakeGeocodingService(places);
        final container = _makeContainer(geocoding: geocoding);
        await tester.runAsync(
          () => _seedLocatedChain(
            container,
            areaName: 'Sunny Crag',
            sectorName: 'Sunny Slabs',
            wallName: 'Sunny Boulder',
            latitude: 45.0,
            longitude: 7.0,
          ),
        );

        await tester.pumpWidget(
          _wrap(
            container,
            CommunityMapScreen(tileProvider: _NoopTileProvider()),
          ),
        );
        await _drain(tester);

        await tester.enterText(
          find.byKey(const Key('community-map-search-field')),
          'sunny',
        );
        // Before the debounce elapses, nothing has been queried yet.
        await tester.pump();
        expect(geocoding.callCount, 0);
        expect(
          find.byKey(const Key('community-map-search-result-0')),
          findsNothing,
        );

        await tester.pump(const Duration(milliseconds: 400));
        await _drain(tester);

        expect(tester.takeException(), isNull);
        expect(geocoding.callCount, 1);

        // Local hits (topo, sector, area — no routes seeded) occupy the
        // first 3 rows, in `mapContentSearch`'s topos-then-sectors-then-
        // areas order; the 2 fake places come after.
        expect(
          _titleTextOf(tester, const Key('community-map-search-result-0')),
          'Sunny Boulder',
        );
        expect(
          _titleTextOf(tester, const Key('community-map-search-result-1')),
          'Sunny Slabs',
        );
        expect(
          _titleTextOf(tester, const Key('community-map-search-result-2')),
          'Sunny Crag',
        );
        expect(
          _titleTextOf(tester, const Key('community-map-search-result-3')),
          'Sunnyvale, California',
        );
        expect(
          _titleTextOf(tester, const Key('community-map-search-result-4')),
          'Sunny Beach, Bulgaria',
        );
        expect(
          find.byKey(const Key('community-map-search-result-5')),
          findsNothing,
        );
      },
    );
  });

  group(
    'B4: selecting a result flies the map + drops the transient marker',
    () {
      testWidgets(
        'selecting a LOCAL result moves the injected MapController to its '
        'coordinates, shows the transient marker, and collapses the dropdown',
        (tester) async {
          final geocoding = _FakeGeocodingService(const []);
          final controller = MapController();
          addTearDown(controller.dispose);
          final container = _makeContainer(geocoding: geocoding);
          await tester.runAsync(
            () => _seedLocatedChain(
              container,
              areaName: 'Sunny Crag',
              sectorName: 'Sunny Slabs',
              wallName: 'Sunny Boulder',
              latitude: 45.0,
              longitude: 7.0,
            ),
          );

          await tester.pumpWidget(
            _wrap(
              container,
              CommunityMapScreen(
                tileProvider: _NoopTileProvider(),
                mapController: controller,
              ),
            ),
          );
          await _drain(tester);

          // Narrow the query to the topo alone (unlike the grouping test
          // above, which deliberately matches all three local kinds).
          await tester.enterText(
            find.byKey(const Key('community-map-search-field')),
            'sunny boulder',
          );
          await tester.pump(const Duration(milliseconds: 400));
          await _drain(tester);

          expect(
            _titleTextOf(tester, const Key('community-map-search-result-0')),
            'Sunny Boulder',
          );
          expect(
            find.byKey(const Key('community-map-search-marker')),
            findsNothing,
            reason: 'no selection has been made yet',
          );

          await tester.tap(
            find.byKey(const Key('community-map-search-result-0')),
          );
          await tester.pump();

          expect(tester.takeException(), isNull);
          final camera = controller.camera;
          expect(camera.center.latitude, closeTo(45.0, 0.01));
          expect(camera.center.longitude, closeTo(7.0, 0.01));
          expect(camera.zoom, 15);
          expect(
            find.byKey(const Key('community-map-search-marker')),
            findsOneWidget,
          );
          expect(
            find.byKey(const Key('community-map-search-result-0')),
            findsNothing,
            reason: 'a selection must collapse the dropdown',
          );
          expect(
            tester
                .widget<TextField>(
                  find.byKey(const Key('community-map-search-field')),
                )
                .controller!
                .text,
            'Sunny Boulder',
            reason:
                "the field must show what was picked, not the raw typed "
                'query',
          );

          // Give any (incorrectly) scheduled debounce timer a chance to fire,
          // to catch a regression where writing the picked title into the
          // field re-triggers a fresh search for it instead of no-oping. Only
          // ONE call happened so far (from the original "sunny boulder"
          // debounce, above) -- it must stay at 1, not climb to 2.
          await tester.pump(const Duration(milliseconds: 400));
          expect(geocoding.callCount, 1);
        },
      );

      testWidgets(
        'selecting a PLACE result moves the injected MapController to its '
        'coordinates and shows the transient marker',
        (tester) async {
          const place = PlaceResult(
            displayName: 'Railay Beach, Krabi, Thailand',
            latitude: 8.0104,
            longitude: 98.8375,
          );
          final geocoding = _FakeGeocodingService(const [place]);
          final controller = MapController();
          addTearDown(controller.dispose);
          // No local content seeded at all -- the query below can only ever
          // match the fake place, exercising the "index >= local count" half
          // of the dropdown's itemBuilder.
          final container = _makeContainer(geocoding: geocoding);

          await tester.pumpWidget(
            _wrap(
              container,
              CommunityMapScreen(
                tileProvider: _NoopTileProvider(),
                mapController: controller,
              ),
            ),
          );
          await _drain(tester);

          await tester.enterText(
            find.byKey(const Key('community-map-search-field')),
            'railay',
          );
          await tester.pump(const Duration(milliseconds: 400));
          await _drain(tester);

          expect(
            _titleTextOf(tester, const Key('community-map-search-result-0')),
            place.displayName,
          );

          await tester.tap(
            find.byKey(const Key('community-map-search-result-0')),
          );
          await tester.pump();

          expect(tester.takeException(), isNull);
          final camera = controller.camera;
          expect(camera.center.latitude, closeTo(place.latitude, 0.001));
          expect(camera.center.longitude, closeTo(place.longitude, 0.001));
          expect(camera.zoom, 15);
          expect(
            find.byKey(const Key('community-map-search-marker')),
            findsOneWidget,
          );
        },
      );

      testWidgets(
        'clearing the field removes the transient marker and the dropdown',
        (tester) async {
          final geocoding = _FakeGeocodingService(const []);
          final controller = MapController();
          addTearDown(controller.dispose);
          final container = _makeContainer(geocoding: geocoding);
          await tester.runAsync(
            () => _seedLocatedChain(
              container,
              areaName: 'Sunny Crag',
              sectorName: 'Sunny Slabs',
              wallName: 'Sunny Boulder',
              latitude: 45.0,
              longitude: 7.0,
            ),
          );

          await tester.pumpWidget(
            _wrap(
              container,
              CommunityMapScreen(
                tileProvider: _NoopTileProvider(),
                mapController: controller,
              ),
            ),
          );
          await _drain(tester);

          await tester.enterText(
            find.byKey(const Key('community-map-search-field')),
            'sunny boulder',
          );
          await tester.pump(const Duration(milliseconds: 400));
          await _drain(tester);
          await tester.tap(
            find.byKey(const Key('community-map-search-result-0')),
          );
          await tester.pump();

          expect(
            find.byKey(const Key('community-map-search-marker')),
            findsOneWidget,
            reason: 'sanity check: the selection above did drop a marker',
          );

          await tester.enterText(
            find.byKey(const Key('community-map-search-field')),
            '',
          );
          await tester.pump();

          expect(tester.takeException(), isNull);
          expect(
            find.byKey(const Key('community-map-search-marker')),
            findsNothing,
          );
          expect(
            find.byKey(const Key('community-map-search-result-0')),
            findsNothing,
          );
        },
      );
    },
  );

  group('B5: no regression — existing map behavior is preserved', () {
    testWidgets(
      'the "Private"/"Public" legend is still shown (now bottom-left, out '
      'of the search overlay\'s way)',
      (tester) async {
        final geocoding = _FakeGeocodingService(const []);
        final container = _makeContainer(geocoding: geocoding);

        await tester.pumpWidget(
          _wrap(
            container,
            CommunityMapScreen(tileProvider: _NoopTileProvider()),
          ),
        );
        await _drain(tester);

        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('community-map-legend')), findsOneWidget);
        expect(
          find.byKey(const Key('community-map-attribution')),
          findsOneWidget,
        );
      },
    );
  });

  group('B6: layout — no overflow at a 375px-wide viewport', () {
    testWidgets(
      'renders a long local name and a long place name together without a '
      'RenderFlex overflow',
      (tester) async {
        tester.view.physicalSize = const Size(375, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final geocoding = _FakeGeocodingService(const [
          PlaceResult(
            displayName:
                'A Very Long Place Display Name That Would Wrap Across '
                'Multiple Lines, Somewhere Specific, On Planet Earth',
            latitude: 1.0,
            longitude: 2.0,
          ),
        ]);
        final container = _makeContainer(geocoding: geocoding);
        await tester.runAsync(
          () => _seedLocatedChain(
            container,
            areaName: 'An Extremely Long Area Name That Keeps Going',
            sectorName: 'An Extremely Long Sector Name That Also Keeps Going',
            wallName: 'An Extremely Long Wall Name For The Topo Row Itself',
            latitude: 3.0,
            longitude: 4.0,
          ),
        );

        await tester.pumpWidget(
          _wrap(
            container,
            CommunityMapScreen(tileProvider: _NoopTileProvider()),
          ),
        );
        await _drain(tester);

        await tester.enterText(
          find.byKey(const Key('community-map-search-field')),
          'extremely long',
        );
        await tester.pump(const Duration(milliseconds: 400));
        await _drain(tester);

        expect(tester.takeException(), isNull);
        expect(
          find.byKey(const Key('community-map-search-result-0')),
          findsOneWidget,
        );
      },
    );
  });
}
