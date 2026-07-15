import 'dart:convert';

import 'package:climbtopo/app/theme.dart';
import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/core/db/database_provider.dart';
import 'package:climbtopo/features/community/presentation/community_screen.dart';
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

/// Builds a [ProviderContainer] wired to a fresh in-memory database.
/// Mirrors `topos_screen_test.dart`'s `_makeContainer`.
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
  await _seedArea(
    db,
    id: 'area-coords',
    name: 'Area With Coords',
    latitude: 45.0,
    longitude: 7.0,
  );
  await _seedSector(db, id: 'sector-coords', areaId: 'area-coords', name: 'S1');
  await _seedWall(
    db,
    id: 'wall-shared-1',
    sectorId: 'sector-coords',
    name: 'Shared One',
    visibility: 'shared',
    createdAt: 2000,
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
}
