import 'dart:async';

import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/core/db/database_provider.dart';
import 'package:climbtopo/features/library/application/library_providers.dart';
import 'package:climbtopo/features/library/data/library_crud_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a [ProviderContainer] wired to a fresh in-memory database and
/// registers teardown of both the container and the database connection.
ProviderContainer _makeContainer() {
  final db = AppDatabase(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      nowMsProvider.overrideWithValue(() => 1000),
    ],
  );
  // addTearDown runs LIFO, so register db.close() first: the container must
  // be disposed (cancelling Riverpod's live watch subscriptions) *before*
  // the underlying Drift connection is closed, otherwise closing the
  // database out from under a still-active watch stream hangs waiting on
  // the background executor isolate.
  addTearDown(db.close);
  addTearDown(container.dispose);
  return container;
}

/// Listens to [provider] and collects every emitted data value into a list.
///
/// Riverpod 3 providers are auto-disposed by default once nothing is
/// listening, so a plain `container.read(provider.future)` can race the
/// provider being torn down before the stream ever emits. Holding a live
/// [ProviderSubscription] for the lifetime of the test (closed via
/// [addTearDown]) keeps the provider alive and lets us assert on the full
/// emission history deterministically.
List<T> _listenAndCollect<T>(
  ProviderContainer container,
  StreamProvider<T> provider,
) {
  final emissions = <T>[];
  final sub = container.listen<AsyncValue<T>>(
    provider,
    (previous, next) => next.whenData(emissions.add),
    fireImmediately: true,
  );
  addTearDown(sub.close);
  return emissions;
}

/// Polls [predicate] against [emissions] until it's satisfied or [timeout]
/// elapses, yielding to the event loop between checks so pending
/// microtasks (e.g. a Drift watch stream re-querying after a write) get a
/// chance to run.
Future<void> _waitUntil<T>(
  List<T> emissions,
  bool Function(List<T> emissions) predicate, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate(emissions)) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException(
        'Condition not met within $timeout. Emissions so far: $emissions',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void main() {
  group('A1: areasProvider', () {
    test(
      'emits an empty list for an empty database, then the created area',
      () async {
        final container = _makeContainer();

        final emissions = _listenAndCollect<List<AreaRef>>(
          container,
          areasProvider,
        );

        await _waitUntil(emissions, (e) => e.isNotEmpty);
        expect(emissions.single, isEmpty);

        final created = await container
            .read(libraryCrudRepositoryProvider)
            .createArea('Frankenjura');

        await _waitUntil(emissions, (e) => e.length >= 2);
        expect(emissions.last, contains(created));
      },
    );
  });

  group('A2: sectorsProvider / wallsProvider scoping', () {
    test('sectorsProvider(areaId) only emits sectors for that area', () async {
      final container = _makeContainer();

      final repo = container.read(libraryCrudRepositoryProvider);
      final areaA = await repo.createArea('Area A');
      final areaB = await repo.createArea('Area B');

      final sectorA0 = await repo.createSector(areaA.id, 'A Sector 0');
      final sectorA1 = await repo.createSector(areaA.id, 'A Sector 1');
      await repo.createSector(areaB.id, 'B Sector 0');

      final emissions = _listenAndCollect<List<SectorRef>>(
        container,
        sectorsProvider(areaA.id),
      );
      await _waitUntil(emissions, (e) => e.isNotEmpty);

      final sectorsA = emissions.last;
      expect(sectorsA, hasLength(2));
      expect(sectorsA, containsAll([sectorA0, sectorA1]));
      expect(sectorsA.every((s) => s.areaId == areaA.id), isTrue);
    });

    test('wallsProvider(sectorId) only emits walls for that sector', () async {
      final container = _makeContainer();

      final repo = container.read(libraryCrudRepositoryProvider);
      final area = await repo.createArea('Area');
      final sectorA = await repo.createSector(area.id, 'Sector A');
      final sectorB = await repo.createSector(area.id, 'Sector B');

      final wallA0 = await repo.createWall(sectorA.id, 'A Wall 0');
      await repo.createWall(sectorB.id, 'B Wall 0');

      final emissions = _listenAndCollect<List<WallRef>>(
        container,
        wallsProvider(sectorA.id),
      );
      await _waitUntil(emissions, (e) => e.isNotEmpty);

      final wallsA = emissions.last;
      expect(wallsA, hasLength(1));
      expect(wallsA.single, wallA0);
    });
  });
}
