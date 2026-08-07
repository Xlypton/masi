// Duplicate topos collapse to one map pin (community editing phase 8b /
// C-6.2, the MAP half — the feed half lives in topo_group_test.dart).
//
// Grouping matters more here than in the feed, and for a reason that is
// geometric rather than aesthetic: four topos of one boulder sit within a few
// metres of each other, so at any zoom a climber actually uses they are one
// overlapping smudge. The reader cannot tell there is more than one listing,
// cannot tap a specific one, and — because the pins are stacked — reliably
// opens whichever happens to paint last.
//
// So the tests here are about the two things that fixes: ONE pin per place,
// and a way to choose between the topos behind it.

import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/community/presentation/community_map_screen.dart';
import 'package:masi/features/moderation/application/duplicate_providers.dart';
import 'package:masi/features/moderation/data/duplicates_remote.dart';

import '../../../support/async_drain.dart';

final _tinyPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY'
  '42YAAAAASUVORK5CYII=',
);

class _NoopTileProvider extends TileProvider {
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      MemoryImage(_tinyPngBytes);
}

/// Returns the configured alternate links and records nothing else — the map
/// must never reach the network in a widget test.
class _FakeDuplicates implements DuplicatesRemote {
  _FakeDuplicates(this.links);

  /// `{wallId: canonicalId}`.
  final Map<String, String> links;

  @override
  Future<List<Map<String, dynamic>>> alternatesFor(Set<String> wallIds) async =>
      [
        for (final entry in links.entries)
          if (wallIds.contains(entry.key))
            {'wallId': entry.key, 'canonicalId': entry.value},
      ];

  @override
  Future<List<Map<String, dynamic>>> nearby({
    required double latitude,
    required double longitude,
    double radiusM = 50,
    String? excludeWallId,
  }) async => const [];

  @override
  Future<String> link({
    required String duplicateId,
    required String canonicalId,
    String? note,
  }) async => canonicalId;

  @override
  Future<void> unlink(String wallId) async {}
}

const _otherOwnerId = 'other-user';

Future<void> _seed(AppDatabase db) async {
  await db.into(db.areas).insert(
    AreasCompanion.insert(
      id: 'area-1',
      createdAt: 1000,
      updatedAt: 1000,
      name: 'Area One',
    ),
  );
  await db.into(db.sectors).insert(
    SectorsCompanion.insert(
      id: 'sector-1',
      createdAt: 1000,
      updatedAt: 1000,
      areaId: 'area-1',
      name: 'S1',
      sortOrder: 0,
    ),
  );
  // Three topos of ONE boulder, metres apart, plus an unrelated fourth.
  await _wall(db, 'wall-a', 'Alpha', 45.0000, 7.0000, routes: 0);
  await _wall(db, 'wall-b', 'Beta', 45.00003, 7.00003, routes: 5);
  await _wall(db, 'wall-c', 'Gamma', 45.00005, 7.00001, routes: 0);
  // ~250 m away: a genuinely different boulder at the same crag, not another
  // country. Keeping the whole fixture inside one camera frame is what lets
  // flutter_map actually build every marker (see `_drain`).
  await _wall(db, 'wall-z', 'Elsewhere', 45.0022, 7.0022, routes: 0);
}

Future<void> _wall(
  AppDatabase db,
  String id,
  String name,
  double lat,
  double lng, {
  required int routes,
}) async {
  await db.into(db.walls).insert(
    WallsCompanion.insert(
      id: id,
      createdAt: 1000,
      updatedAt: 1000,
      sectorId: 'sector-1',
      name: name,
      sortOrder: 0,
      visibility: const Value('shared'),
      latitude: Value(lat),
      longitude: Value(lng),
      ownerId: const Value(_otherOwnerId),
    ),
  );
  if (routes == 0) return;
  // A photo is needed because the feed's route aggregates are scoped to the
  // wall's primary live original.
  await db.into(db.photos).insert(
    PhotosCompanion.insert(
      id: 'photo-$id',
      createdAt: 1000,
      updatedAt: 1000,
      wallId: id,
      localPath: '/tmp/none.jpg',
      kind: 'original',
      width: 100,
      height: 100,
      isPrimary: const Value(true),
    ),
  );
  for (var i = 0; i < routes; i++) {
    await db.into(db.routes).insert(
      RoutesCompanion.insert(
        id: '$id-route-$i',
        createdAt: 1000,
        updatedAt: 1000,
        wallId: id,
        photoId: 'photo-$id',
        number: i + 1,
        colorIndex: 0,
        pointsJson: '[{"x":0.1,"y":0.1},{"x":0.2,"y":0.9}]',
        symbolsJson: '[]',
        sortOrder: i,
      ),
    );
  }
}

String? _pushedPath;

Widget _wrap(ProviderContainer container) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) =>
            CommunityMapScreen(tileProvider: _NoopTileProvider()),
      ),
      GoRoute(
        path: '/walls/:wallId',
        builder: (_, state) {
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

ProviderContainer _container(Map<String, String> links) {
  final db = AppDatabase(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      nowMsProvider.overrideWithValue(() => 1000),
      duplicatesRemoteProvider.overrideWithValue(_FakeDuplicates(links)),
    ],
  );
  addTearDown(db.close);
  addTearDown(container.dispose);
  return container;
}

/// Drains the Drift stream AND lets flutter_map lay itself out.
///
/// The second half is not optional and cost an hour to find: `MarkerLayer`
/// builds markers LAZILY by viewport, so a `MarkerLayer` holding four markers
/// puts none of them in the widget tree until the map has sized itself and
/// fitted its camera. Draining the provider alone leaves you looking at a
/// layer that demonstrably has the right markers and a `find.byKey` that
/// returns nothing.
Future<void> _drain(WidgetTester tester) async {
  await drainAsync(tester, rounds: 8, settle: false);
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

void main() {
  setUp(() => _pushedPath = null);


  testWidgets(
    'three topos of one boulder render ONE pin, and the unrelated fourth '
    'keeps its own',
    (tester) async {
      final c = _container({'b': 'a', 'c': 'a'}.map(
        (k, v) => MapEntry('wall-$k', 'wall-$v'),
      ));
      await tester.runAsync(() => _seed(c.read(appDatabaseProvider)));
      await tester.pumpWidget(_wrap(c));
      await _drain(tester);

      // 'wall-b' heads the group: it is the only one with routes, and
      // completeness outranks everything else (see TopoRank).
      expect(find.byKey(const Key('community-map-marker-wall-b')), findsOneWidget);
      expect(find.byKey(const Key('community-map-marker-wall-a')), findsNothing);
      expect(find.byKey(const Key('community-map-marker-wall-c')), findsNothing);
      expect(find.byKey(const Key('community-map-marker-wall-z')), findsOneWidget);
    },
  );

  testWidgets(
    'the grouped pin says how many topos it stands for — without the count '
    'it is indistinguishable from a place with one, and the reader has no '
    'reason to tap it',
    (tester) async {
      final c = _container({'wall-b': 'wall-a', 'wall-c': 'wall-a'});
      await tester.runAsync(() => _seed(c.read(appDatabaseProvider)));
      await tester.pumpWidget(_wrap(c));
      await _drain(tester);

      expect(find.text('3'), findsOneWidget);
    },
  );

  testWidgets(
    'tapping a grouped pin ASKS which topo, rather than silently opening the '
    'best-ranked one. §C-6 is explicit that the second photo is often the '
    'better one and only the reader can tell',
    (tester) async {
      final c = _container({'wall-b': 'wall-a', 'wall-c': 'wall-a'});
      await tester.runAsync(() => _seed(c.read(appDatabaseProvider)));
      await tester.pumpWidget(_wrap(c));
      await _drain(tester);

      await tester.tap(find.byKey(const Key('community-map-marker-wall-b')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('map-place-picker-sheet')), findsOneWidget);
      expect(_pushedPath, isNull, reason: 'it must not navigate before asking');
      for (final id in ['wall-a', 'wall-b', 'wall-c']) {
        expect(find.byKey(Key('map-place-option-$id')), findsOneWidget);
      }

      await tester.tap(find.byKey(const Key('map-place-option-wall-a')));
      await tester.pumpAndSettle();
      expect(_pushedPath, '/walls/wall-a?readonly=1');
    },
  );

  testWidgets(
    'an UNGROUPED pin still opens its topo directly — grouping must not add a '
    'tap to the overwhelmingly common case',
    (tester) async {
      final c = _container(const {});
      await tester.runAsync(() => _seed(c.read(appDatabaseProvider)));
      await tester.pumpWidget(_wrap(c));
      await _drain(tester);

      await tester.tap(find.byKey(const Key('community-map-marker-wall-z')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('map-place-picker-sheet')), findsNothing);
      expect(_pushedPath, '/walls/wall-z?readonly=1');
    },
  );

  testWidgets(
    'with NO links — offline, or not yet fetched — every topo keeps its own '
    'pin. Grouping improves the map; it is never a precondition for it',
    (tester) async {
      final c = _container(const {});
      await tester.runAsync(() => _seed(c.read(appDatabaseProvider)));
      await tester.pumpWidget(_wrap(c));
      await _drain(tester);

      for (final id in ['wall-a', 'wall-b', 'wall-c', 'wall-z']) {
        expect(find.byKey(Key('community-map-marker-$id')), findsOneWidget);
      }
    },
  );
}
