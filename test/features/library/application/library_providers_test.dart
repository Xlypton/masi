import 'dart:async';

import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/account/application/auth_providers.dart';
import 'package:masi/features/account/data/auth_repository.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/library/data/library_crud_repository.dart';
import 'package:masi/features/logbook/presentation/logbook_providers.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Riverpod 3 keeps `Override` out of the main barrel — it lives in `misc.dart`
// (same import `test/main_boot_app_seam_test.dart` uses for `bootApp`'s seam).
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

import '../../account/application/last_known_uid_test.dart'
    show StreamingFakeAuthRepository;

/// Builds a [ProviderContainer] wired to a fresh in-memory database and
/// registers teardown of both the container and the database connection.
ProviderContainer _makeContainer({List<Override> overrides = const []}) {
  final db = AppDatabase(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      nowMsProvider.overrideWithValue(() => 1000),
      ...overrides,
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
  // A safety valve, not a timing assumption. The loop exits the instant the
  // predicate holds, so a generous deadline costs nothing on an idle machine
  // and is the difference between "Drift was slow" and a spurious red on a
  // loaded one. (5 s used to be the bound; at load 100+ a Drift watch
  // stream's first emission can miss it.)
  Duration timeout = const Duration(seconds: 20),
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

  group('A3: toposProvider', () {
    test(
      'emits the same data as a direct watchTopos() call on the repository',
      () async {
        final container = _makeContainer();
        final repo = container.read(libraryCrudRepositoryProvider);

        final area = await repo.createArea('Area');
        final sector = await repo.createSector(area.id, 'Sector');
        final wall = await repo.createWall(sector.id, 'Wall');
        await repo.attachPhotoToWall(
          wall.id,
          XFile('/tmp/thumb.jpg'),
          100,
          200,
        );

        final emissions = _listenAndCollect<List<TopoRef>>(
          container,
          toposProvider,
        );
        await _waitUntil(emissions, (e) => e.isNotEmpty);

        final expected = await repo.watchTopos().first;

        expect(emissions.last, expected);
      },
    );
  });

  group('A3b: toposProvider goes through effectiveUidProvider (§1c)', () {
    test(
      'still emits the signed-in user own topos while authStateProvider is '
      'in an ERROR state (native silent-empty-library bug)',
      () async {
        final auth = StreamingFakeAuthRepository(
          const AuthSessionState.signedIn('u1@example.com', uid: 'user-u1'),
        );
        addTearDown(auth.dispose);
        final container = _makeContainer(
          overrides: [authRepositoryProvider.overrideWithValue(auth)],
        );

        final repo = container.read(libraryCrudRepositoryProvider);
        final area = await repo.createArea('Area');
        final sector = await repo.createSector(area.id, 'Sector');
        final wall = await repo.createWall(sector.id, 'Wall');
        // createWall stamps ownerId from the currentUid seam; assert that
        // rather than assuming it, so this test fails loudly if the write
        // door regresses instead of silently testing an unowned row.
        final ownerId = await container
            .read(appDatabaseProvider)
            .customSelect(
              'SELECT owner_id FROM walls WHERE id = ?',
              variables: [Variable<String>(wall.id)],
            )
            .map((r) => r.read<String?>('owner_id'))
            .getSingle();
        expect(ownerId, 'user-u1');

        final emissions = _listenAndCollect<List<TopoRef>>(
          container,
          toposProvider,
        );
        await _waitUntil(emissions, (e) => e.isNotEmpty);
        expect(emissions.last.map((t) => t.wallId), contains(wall.id));

        // gotrue's offline refresh ticker: addError only, session intact.
        auth.emitError(Exception('AuthRetryableFetchException'));
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(container.read(authStateProvider).hasError, isTrue);
        expect(
          emissions.last.map((t) => t.wallId),
          contains(wall.id),
          reason:
              'pre-fix asData?.value.uid was null here, collapsing the '
              'owner filter to owner_id IS NULL and emitting an empty list',
        );
      },
    );

    test(
      'still emits own topos after a sessionExpired sign-out (L4 read half)',
      () async {
        final auth = StreamingFakeAuthRepository(
          const AuthSessionState.signedIn('u1@example.com', uid: 'user-u1'),
        );
        addTearDown(auth.dispose);
        final container = _makeContainer(
          overrides: [authRepositoryProvider.overrideWithValue(auth)],
        );
        await container
            .read(lastKnownUidProvider.notifier)
            .remember('user-u1');

        final repo = container.read(libraryCrudRepositoryProvider);
        final area = await repo.createArea('Area');
        final sector = await repo.createSector(area.id, 'Sector');
        final wall = await repo.createWall(sector.id, 'Wall');

        final emissions = _listenAndCollect<List<TopoRef>>(
          container,
          toposProvider,
        );
        await _waitUntil(emissions, (e) => e.isNotEmpty);

        auth.emit(
          const AuthSessionState.signedOut(
            cause: AuthSignOutCause.sessionExpired,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(
          emissions.last.map((t) => t.wallId),
          contains(wall.id),
          reason: 'a hard sign-out must not hide the local library',
        );

        // And local WRITES still target the right ownerId, not IS NULL.
        await repo.renameWall(wall.id, 'Renamed');
        final name = await repo.wallName(wall.id);
        expect(name, 'Renamed');
      },
    );

    test('emits an empty list after a user-initiated sign-out', () async {
      final auth = StreamingFakeAuthRepository(
        const AuthSessionState.signedIn('u1@example.com', uid: 'user-u1'),
      );
      addTearDown(auth.dispose);
      final container = _makeContainer(
        overrides: [authRepositoryProvider.overrideWithValue(auth)],
      );
      final notifier = container.read(lastKnownUidProvider.notifier);
      await notifier.remember('user-u1');

      final repo = container.read(libraryCrudRepositoryProvider);
      final area = await repo.createArea('Area');
      final sector = await repo.createSector(area.id, 'Sector');
      await repo.createWall(sector.id, 'Wall');

      final emissions = _listenAndCollect<List<TopoRef>>(
        container,
        toposProvider,
      );
      await _waitUntil(emissions, (e) => e.isNotEmpty);

      auth.emit(
        const AuthSessionState.signedOut(
          cause: AuthSignOutCause.userInitiated,
        ),
      );
      await notifier.forget();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(
        emissions.last,
        isEmpty,
        reason: 'signing out on purpose must scope reads back to unowned',
      );
    });
  });

  group('A3c: logbookEntriesProvider goes through the same door', () {
    test('uses the last-known uid when the live session is gone', () async {
      final auth = StreamingFakeAuthRepository(
        const AuthSessionState.signedOut(
          cause: AuthSignOutCause.sessionExpired,
        ),
      );
      addTearDown(auth.dispose);
      final container = _makeContainer(
        overrides: [authRepositoryProvider.overrideWithValue(auth)],
      );
      await container.read(lastKnownUidProvider.notifier).remember('user-u1');
      expect(container.read(effectiveUidProvider), 'user-u1');
      // The query is built from effectiveUidProvider, so an owner-stamped
      // ascent stays visible. Emitting an empty (but successful) list is the
      // failure mode this guards.
      final emissions = _listenAndCollect<List<LogbookEntry>>(
        container,
        logbookEntriesProvider,
      );
      await _waitUntil(emissions, (e) => e.isNotEmpty);
      expect(emissions.last, isEmpty); // no ascents seeded; must not throw
    });
  });
}
