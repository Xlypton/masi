// End-to-end wiring test for `mapContentSearchProvider`: a real in-memory
// database behind `toposProvider`/`locatedRoutesProvider`/
// `locatedSectorsProvider`/`locatedAreasProvider`, proving the provider
// composes all four correctly (not just that `mapContentSearch` itself is
// correct — see `map_search_test.dart` for that). Mirrors
// `library_providers_test.dart`'s `_makeContainer` pattern.
import 'dart:async';

import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/core/db/database_provider.dart';
import 'package:climbtopo/features/community/application/map_search_providers.dart';
import 'package:climbtopo/features/community/data/map_search.dart';
import 'package:climbtopo/features/library/application/library_providers.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

/// Wires a [ProviderContainer] to a fresh in-memory [db], returning both so
/// the test can insert rows the repository has no dedicated method for
/// (e.g. a raw Route row — see `insertRoute` below) while the provider
/// graph reads the very same connection.
({ProviderContainer container, AppDatabase db}) _makeContainer() {
  final db = AppDatabase(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      nowMsProvider.overrideWithValue(() => 1000),
    ],
  );
  // Same ordering rationale as `library_providers_test.dart`: dispose the
  // container (cancelling live watch subscriptions) before closing the
  // underlying Drift connection.
  addTearDown(db.close);
  addTearDown(container.dispose);
  return (container: container, db: db);
}

/// Inserts a route row directly, mirroring the same-named helper in
/// `map_search_queries_test.dart` — `RouteRepository`'s API works in terms
/// of the `TopoRoute` domain model, which is more than this wiring test
/// needs.
Future<void> _insertRoute(
  AppDatabase db,
  String wallId,
  String photoId,
  String id, {
  int number = 1,
  String? name,
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
          name: Value(name),
          colorIndex: 0,
          pointsJson: '[]',
          symbolsJson: '[]',
          sortOrder: number,
        ),
      );
}

/// Keeps [toposProvider]/[locatedRoutesProvider]/[locatedSectorsProvider]/
/// [locatedAreasProvider] alive for the duration of a test — Riverpod 3
/// providers auto-dispose once nothing listens, which would otherwise drop
/// the underlying Drift watch subscriptions between `container.read` calls.
void _keepMapSearchInputsAlive(ProviderContainer container) {
  final subs = [
    container.listen(toposProvider, (_, _) {}),
    container.listen(locatedRoutesProvider, (_, _) {}),
    container.listen(locatedSectorsProvider, (_, _) {}),
    container.listen(locatedAreasProvider, (_, _) {}),
  ];
  addTearDown(() {
    for (final sub in subs) {
      sub.close();
    }
  });
}

/// Polls [mapContentSearchProvider]([query]) until [predicate] is satisfied,
/// yielding to the event loop between checks so a Drift watch stream's
/// re-query after a write gets a chance to land.
Future<List<MapSearchResult>> _waitForResults(
  ProviderContainer container,
  String query,
  bool Function(List<MapSearchResult> results) predicate, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    final results = container.read(mapContentSearchProvider(query));
    if (predicate(results)) return results;
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException(
        'mapContentSearchProvider($query) never satisfied the predicate. '
        'Last results: $results',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void main() {
  test(
    'mapContentSearchProvider finds a located topo, route, sector, and '
    'area sharing a common query substring, and excludes an unlocated wall',
    () async {
      final wired = _makeContainer();
      final container = wired.container;
      final db = wired.db;
      final repo = container.read(libraryCrudRepositoryProvider);
      _keepMapSearchInputsAlive(container);

      final area = await repo.createArea('Riverside Crag');
      final sector = await repo.createSector(area.id, 'Riverside Slabs');
      final wall = await repo.createWall(sector.id, 'Riverside Wall');
      final photoId = await repo.attachPhotoToWall(
        wall.id,
        XFile('/tmp/p.jpg'),
        100,
        200,
      );
      await repo.setWallCoordinates(wall.id, 40.0, -74.0);
      await _insertRoute(
        db,
        wall.id,
        photoId,
        'route-1',
        name: 'Riverside Traverse',
      );

      // A second wall in the same area with NO coordinates -- must never
      // surface as a topo hit even though its name matches.
      await repo.createWall(sector.id, 'Riverside Wall Unlocated');

      final results = await _waitForResults(
        container,
        'riverside',
        (r) => r.length >= 4, // topo + route + sector + area
      );

      final byKind = {for (final r in results) r.kind: r};
      expect(byKind[MapSearchKind.topo]!.title, 'Riverside Wall');
      expect(byKind[MapSearchKind.route]!.title, 'Riverside Traverse');
      expect(byKind[MapSearchKind.sector]!.title, 'Riverside Slabs');
      expect(byKind[MapSearchKind.area]!.title, 'Riverside Crag');
      expect(
        results.map((r) => r.title),
        isNot(contains('Riverside Wall Unlocated')),
      );
    },
  );

  test(
    'empty query yields no results even with located data present',
    () async {
      final wired = _makeContainer();
      final container = wired.container;
      final repo = container.read(libraryCrudRepositoryProvider);
      _keepMapSearchInputsAlive(container);

      final area = await repo.createArea('Area');
      final sector = await repo.createSector(area.id, 'Sector');
      final wall = await repo.createWall(sector.id, 'Wall');
      await repo.setWallCoordinates(wall.id, 1.0, 2.0);

      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(container.read(mapContentSearchProvider('')), isEmpty);
    },
  );
}
