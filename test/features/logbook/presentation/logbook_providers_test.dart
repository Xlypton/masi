import 'dart:async';

import 'package:masi/core/db/app_database.dart' as db;
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/core/grades/grade_system.dart';
import 'package:masi/features/logbook/data/ascents_repository.dart';
import 'package:masi/features/logbook/presentation/logbook_providers.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Listens to [provider] and collects every emitted data value into a list.
///
/// Riverpod 3 providers are auto-disposed by default once nothing is
/// listening, so a plain `container.read(provider.future)` can race the
/// provider being torn down before the stream ever emits — see
/// `test/features/library/application/library_providers_test.dart`'s
/// identical helper/doc, which this mirrors. Holding a live
/// [ProviderSubscription] for the lifetime of the test (closed via
/// [addTearDown]) keeps the provider alive and lets us assert deterministically.
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
/// microtasks (e.g. a Drift watch stream's query) get a chance to run.
Future<void> _waitUntil<T>(
  List<T> emissions,
  bool Function(List<T> emissions) predicate, {
  // A safety valve, not a timing assumption — see the identical note in
  // `test/features/library/application/library_providers_test.dart`.
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

/// A seeded (wallId, routeId) pair satisfying the FK constraints on
/// `Ascents.wallId`/`Ascents.routeId`, via a minimal Area -> Sector -> Wall
/// -> Photo -> Route chain. Mirrors
/// `test/features/logbook/data/ascents_repository_test.dart`'s `_Seed`/
/// `seed`, extended with `style` (the new column this subtask exposes on
/// [LogbookEntry] as `routeStyle`).
class _Seed {
  const _Seed(this.wallId, this.routeId);
  final String wallId;
  final String routeId;
}

Future<_Seed> _seed(
  db.AppDatabase database,
  String n, {
  int routeNumber = 1,
  String? gradeRaw,
  double? gradeSortKey,
  String? style,
}) async {
  final areaId = 'area-$n';
  final sectorId = 'sector-$n';
  final wallId = 'wall-$n';
  final photoId = 'photo-$n';
  final routeId = 'route-$n';
  await database
      .into(database.areas)
      .insert(
        db.AreasCompanion.insert(id: areaId, createdAt: 0, updatedAt: 0, name: 'Area $n'),
      );
  await database
      .into(database.sectors)
      .insert(
        db.SectorsCompanion.insert(
          id: sectorId,
          createdAt: 0,
          updatedAt: 0,
          areaId: areaId,
          name: 'Sector $n',
          sortOrder: 0,
        ),
      );
  await database
      .into(database.walls)
      .insert(
        db.WallsCompanion.insert(
          id: wallId,
          createdAt: 0,
          updatedAt: 0,
          sectorId: sectorId,
          name: 'Wall $n',
          sortOrder: 0,
        ),
      );
  await database
      .into(database.photos)
      .insert(
        db.PhotosCompanion.insert(
          id: photoId,
          createdAt: 0,
          updatedAt: 0,
          wallId: wallId,
          localPath: '/tmp/$n.jpg',
          kind: 'original',
          width: 1,
          height: 1,
        ),
      );
  await database
      .into(database.routes)
      .insert(
        db.RoutesCompanion.insert(
          id: routeId,
          createdAt: 0,
          updatedAt: 0,
          wallId: wallId,
          photoId: photoId,
          number: routeNumber,
          gradeRaw: Value(gradeRaw),
          gradeSortKey: Value(gradeSortKey),
          style: Value(style),
          colorIndex: 0,
          pointsJson: '[]',
          symbolsJson: '[]',
          sortOrder: 0,
        ),
      );
  return _Seed(wallId, routeId);
}

void main() {
  late db.AppDatabase database;
  late ProviderContainer container;

  setUp(() {
    database = db.AppDatabase(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(database)],
    );
  });

  tearDown(() async {
    container.dispose();
    await database.close();
  });

  group('C1: LogbookEntry gradeSortKey + routeStyle', () {
    test(
      'exposes the route\'s numeric gradeSortKey and a lowercase-trimmed '
      'routeStyle',
      () async {
        final s = await _seed(
          database,
          '1',
          gradeRaw: '6a',
          gradeSortKey: gradeSortKey(GradeSystem.french, '6a'),
          style: ' Sport ',
        );
        final repo = AscentsRepository(database, nowMs: () => 1000);
        final ascent = await repo.logAscent(
          routeId: s.routeId,
          wallId: s.wallId,
          climbedAt: DateTime.utc(2026, 7, 1),
          style: AscentStyle.redpoint,
        );

        final emissions = _listenAndCollect<List<LogbookEntry>>(
          container,
          logbookEntriesProvider,
        );
        await _waitUntil(emissions, (e) => e.isNotEmpty && e.last.isNotEmpty);

        final entries = emissions.last;
        expect(entries, hasLength(1));
        final entry = entries.single;
        expect(entry.ascentId, ascent.id);
        expect(entry.gradeSortKey, gradeSortKey(GradeSystem.french, '6a'));
        expect(
          entry.routeStyle,
          'sport',
          reason: 'trimmed and lowercased for exact-match filtering',
        );
      },
    );

    test(
      'a route with no grade/style set leaves gradeSortKey/routeStyle null',
      () async {
        final s = await _seed(database, '1');
        final repo = AscentsRepository(database, nowMs: () => 1000);
        await repo.logAscent(
          routeId: s.routeId,
          wallId: s.wallId,
          climbedAt: DateTime.utc(2026, 1, 1),
          style: AscentStyle.attempt,
        );

        final emissions = _listenAndCollect<List<LogbookEntry>>(
          container,
          logbookEntriesProvider,
        );
        await _waitUntil(emissions, (e) => e.isNotEmpty && e.last.isNotEmpty);

        final entries = emissions.last;
        expect(entries, hasLength(1));
        expect(entries.single.gradeSortKey, isNull);
        expect(entries.single.routeStyle, isNull);
      },
    );

    test(
      'an empty-string route style normalizes to null rather than an '
      'empty string',
      () async {
        final s = await _seed(database, '1', style: '   ');
        final repo = AscentsRepository(database, nowMs: () => 1000);
        await repo.logAscent(
          routeId: s.routeId,
          wallId: s.wallId,
          climbedAt: DateTime.utc(2026, 1, 1),
          style: AscentStyle.attempt,
        );

        final emissions = _listenAndCollect<List<LogbookEntry>>(
          container,
          logbookEntriesProvider,
        );
        await _waitUntil(emissions, (e) => e.isNotEmpty && e.last.isNotEmpty);

        expect(emissions.last.single.routeStyle, isNull);
      },
    );
  });
}
