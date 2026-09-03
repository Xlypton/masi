// A3 (bug fix): the Community Map tab's COMMUNITY (non-own) boulder marker
// must push the read-only topo canvas (`/walls/:wallId?readonly=1`), never
// the social/likes-first `/community/topo/:wallId` detail screen -- that
// view stays reserved for the Feed. The OWN marker (a different
// `GestureDetector`, keyed `community-map-own-marker-<id>`) must keep
// pushing the plain editable `/walls/:wallId` route, unaffected.
//
// Deliberately a separate, small file rather than appended to the very
// large `community_screen_test.dart`: this only touches the two markers'
// `onTap` destinations, and keeping it isolated avoids any merge/edit
// collision with that file. Seed helpers are duplicated (trimmed to just
// what's needed here) rather than imported, since `community_screen_test.dart`
// declares them as file-private (`_seedArea`/`_seedSector`/`_seedWall`).

import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/community/presentation/community_map_screen.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import '../../../support/async_drain.dart';
import '../../../support/fake_basemap.dart';

/// A tile provider that never performs any network/file I/O -- copied from
/// `community_screen_test.dart`'s identical private class -- so the Map
/// tab's `TileLayer` never attempts a real network fetch under
/// `flutter_test`.
Future<void> _seedArea(AppDatabase db, {required String id, required String name}) {
  return db
      .into(db.areas)
      .insert(
        AreasCompanion.insert(id: id, createdAt: 1000, updatedAt: 1000, name: name),
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
  required String visibility,
  required double latitude,
  required double longitude,
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
          latitude: Value(latitude),
          longitude: Value(longitude),
          ownerId: Value(ownerId),
        ),
      );
}

/// A shared wall owned by someone else (`_otherOwnerId`, never matching
/// `authStateProvider`'s -- unauthenticated in these tests -- `null` uid),
/// so it renders as the COMMUNITY marker (`community-map-marker-<id>`), not
/// the "Yours" one.
const _otherOwnerId = 'other-user';

Future<void> _seedCommunityWall(AppDatabase db) async {
  await _seedArea(db, id: 'area-1', name: 'Area One');
  await _seedSector(db, id: 'sector-1', areaId: 'area-1', name: 'S1');
  await _seedWall(
    db,
    id: 'wall-community-1',
    sectorId: 'sector-1',
    name: 'Community Boulder',
    visibility: 'shared',
    latitude: 45.0,
    longitude: 7.0,
    ownerId: _otherOwnerId,
  );
}

/// A wall owned by THIS device (`ownerId` left null, matching
/// `community_map_screen.dart`'s `isMine` "never surfaced in the shared
/// feed -> local-only" branch) with coordinates, so it renders as the OWN
/// marker (`community-map-own-marker-<id>`).
Future<void> _seedOwnWall(AppDatabase db) async {
  await _seedArea(db, id: 'area-own', name: 'Area Own');
  await _seedSector(db, id: 'sector-own', areaId: 'area-own', name: 'S1');
  await _seedWall(
    db,
    id: 'wall-own-1',
    sectorId: 'sector-own',
    name: 'My Own Boulder',
    visibility: 'private',
    latitude: 46.0,
    longitude: 8.0,
  );
}

ProviderContainer _makeContainer() {
  final db = AppDatabase(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      ...fakeBasemapOverrides(),
      appDatabaseProvider.overrideWithValue(db),
      nowMsProvider.overrideWithValue(() => 1000),
    ],
  );
  addTearDown(db.close);
  addTearDown(container.dispose);
  return container;
}

/// Wraps [screen] in a real (minimal) [GoRouter] with BOTH
/// `/walls/:wallId` and `/community/topo/:wallId` wired to keyed
/// placeholders that record the exact pushed location string -- so a test
/// can prove which one a tap actually landed on, not just that a push
/// happened.
String? _pushedPath;

Widget _wrap(ProviderContainer container, Widget screen) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (context, state) => screen),
      GoRoute(
        path: '/walls/:wallId',
        builder: (context, state) {
          _pushedPath = state.uri.toString();
          return const SizedBox();
        },
      ),
      GoRoute(
        path: '/community/topo/:wallId',
        builder: (context, state) {
          _pushedPath = state.uri.toString();
          return const SizedBox();
        },
      ),
    ],
  );
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(theme: MasiTheme.light, routerConfig: router),
  );
}

Future<void> _drain(WidgetTester tester) async {
  await drainAsync(tester, rounds: 6, settle: false);
}

void main() {
  setUp(() => _pushedPath = null);

  group('A3: Community Map community marker navigates to the read-only '
      'topo canvas, not the social detail screen', () {
    testWidgets(
      'tapping community-map-marker-<id> pushes /walls/<id>?readonly=1',
      (tester) async {
        final container = _makeContainer();
        final db = container.read(appDatabaseProvider);
        await tester.runAsync(() => _seedCommunityWall(db));

        await tester.pumpWidget(
          _wrap(container, const CommunityMapScreen()),
        );
        await _drain(tester);

        expect(
          find.byKey(const Key('community-map-marker-wall-community-1')),
          findsOneWidget,
        );

        await tester.tap(
          find.byKey(const Key('community-map-marker-wall-community-1')),
        );
        await tester.pump();

        expect(_pushedPath, '/walls/wall-community-1?readonly=1');
      },
    );
  });

  group('A4 regression: the OWN marker still pushes the plain editable '
      'route', () {
    testWidgets(
      'tapping community-map-own-marker-<id> pushes /walls/<id> (no '
      'readonly param)',
      (tester) async {
        final container = _makeContainer();
        final db = container.read(appDatabaseProvider);
        await tester.runAsync(() => _seedOwnWall(db));

        await tester.pumpWidget(
          _wrap(container, const CommunityMapScreen()),
        );
        await _drain(tester);

        expect(
          find.byKey(const Key('community-map-own-marker-wall-own-1')),
          findsOneWidget,
        );

        await tester.tap(
          find.byKey(const Key('community-map-own-marker-wall-own-1')),
        );
        await tester.pump();

        expect(_pushedPath, '/walls/wall-own-1');
      },
    );
  });
}
