// Integration-style test against a REAL in-memory AppDatabase (drift +
// sqlite3, `PRAGMA foreign_keys = ON` — see `app_database.dart`'s
// `beforeOpen`). Where `foreign_wall_sweep_policy_test.dart` proves the pure
// decision logic in isolation, this file proves the WHOLE service: the rows
// and their subtree actually go, the user's own rows and own topos survive
// completely untouched, no FK constraint is violated by the delete order,
// and every abort condition (offline, unknown session, a probe error, an
// all-empty response to a non-trivial ask) leaves the database exactly as
// it was.
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/features/backup/application/reachability_providers.dart';
import 'package:masi/features/backup/data/sync_remote.dart';
import 'package:masi/features/topo/data/foreign_wall_sweep_service.dart';

const _me = 'uid-me';

/// A [SyncRemote] stand-in whose only reachable member is
/// [fetchVisibleWallIds] — every other member throws via [noSuchMethod],
/// mirroring `missing_photo_byte_resolver_test.dart`'s `_FakeRemote`, so
/// reaching any of them would itself be the bug (this service must never
/// call anything else on [SyncRemote]).
class _FakeProbeRemote implements SyncRemote {
  _FakeProbeRemote({Set<String> visibleWallIds = const {}, this.throwOnFetch = false})
    : visibleWallIds = Set.of(visibleWallIds);

  final Set<String> visibleWallIds;
  final bool throwOnFetch;

  /// Every chunk asked about, in order — so a test can prove chunking
  /// happened (or didn't need to).
  final List<List<String>> requestedChunks = [];

  @override
  Future<List<String>> fetchVisibleWallIds(List<String> ids) async {
    requestedChunks.add(ids);
    if (throwOnFetch) throw Exception('probe failed: simulated network error');
    return [for (final id in ids) if (visibleWallIds.contains(id)) id];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'the sweep service must only ever call fetchVisibleWallIds, not '
    '${invocation.memberName}',
  );
}

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  /// Inserts a full area->sector->wall->photo->route chain, all owned by
  /// [ownerId] (or unclaimed if `null`), returning nothing — callers refer
  /// back to the ids they passed in.
  Future<void> seedChain({
    required String areaId,
    required String sectorId,
    required String wallId,
    required String photoId,
    required String routeId,
    required String? ownerId,
    int now = 1000,
  }) async {
    await db
        .into(db.areas)
        .insert(
          AreasCompanion.insert(
            id: areaId,
            createdAt: now,
            updatedAt: now,
            name: 'Area $areaId',
            ownerId: Value(ownerId),
          ),
        );
    await db
        .into(db.sectors)
        .insert(
          SectorsCompanion.insert(
            id: sectorId,
            createdAt: now,
            updatedAt: now,
            areaId: areaId,
            name: 'Sector $sectorId',
            sortOrder: 0,
            ownerId: Value(ownerId),
          ),
        );
    await db
        .into(db.walls)
        .insert(
          WallsCompanion.insert(
            id: wallId,
            createdAt: now,
            updatedAt: now,
            sectorId: sectorId,
            name: 'Wall $wallId',
            sortOrder: 0,
            ownerId: Value(ownerId),
          ),
        );
    await db
        .into(db.photos)
        .insert(
          PhotosCompanion.insert(
            id: photoId,
            createdAt: now,
            updatedAt: now,
            wallId: wallId,
            localPath: '/tmp/$photoId.jpg',
            kind: 'original',
            width: 1024,
            height: 768,
            ownerId: Value(ownerId),
          ),
        );
    await db
        .into(db.routes)
        .insert(
          RoutesCompanion.insert(
            id: routeId,
            createdAt: now,
            updatedAt: now,
            wallId: wallId,
            photoId: photoId,
            number: 1,
            colorIndex: 0,
            pointsJson: '[]',
            symbolsJson: '[]',
            sortOrder: 0,
            ownerId: Value(ownerId),
          ),
        );
  }

  Future<bool> wallExists(String id) async =>
      (await (db.select(db.walls)..where((w) => w.id.equals(id))).getSingleOrNull()) != null;
  Future<bool> sectorExists(String id) async =>
      (await (db.select(db.sectors)..where((s) => s.id.equals(id))).getSingleOrNull()) != null;
  Future<bool> areaExists(String id) async =>
      (await (db.select(db.areas)..where((a) => a.id.equals(id))).getSingleOrNull()) != null;
  Future<bool> photoExists(String id) async =>
      (await (db.select(db.photos)..where((p) => p.id.equals(id))).getSingleOrNull()) != null;
  Future<bool> routeExists(String id) async =>
      (await (db.select(db.routes)..where((r) => r.id.equals(id))).getSingleOrNull()) != null;
  Future<bool> ascentExists(String id) async =>
      (await (db.select(db.ascents)..where((a) => a.id.equals(id))).getSingleOrNull()) != null;
  Future<bool> commentExists(String id) async =>
      (await (db.select(db.comments)..where((c) => c.id.equals(id))).getSingleOrNull()) != null;
  Future<bool> likeExists(String id) async =>
      (await (db.select(db.likes)..where((l) => l.id.equals(id))).getSingleOrNull()) != null;

  group('the full sweep', () {
    test(
      'deletes a fully-gone foreign subtree (incl. a slice-shaped '
      'parentPhotoId self-reference, foreign ascent/comment/like), '
      'protects the own topo untouched, protects a still-visible foreign '
      'wall (and its sibling sector), protects an own-data-guarded foreign '
      'wall (and its sector/area), and never touches an unclaimed wall — '
      'with no FK violation from the delete order',
      () async {
        // --- OWN topo: must survive untouched. ---------------------------
        await seedChain(
          areaId: 'area-own',
          sectorId: 'sector-own',
          wallId: 'wall-own',
          photoId: 'photo-own',
          routeId: 'route-own',
          ownerId: _me,
        );
        await db
            .into(db.ascents)
            .insert(
              AscentsCompanion.insert(
                id: 'ascent-own',
                createdAt: 1000,
                updatedAt: 1000,
                routeId: 'route-own',
                wallId: 'wall-own',
                climbedAt: 1000,
                style: 'redpoint',
                ownerId: const Value(_me),
              ),
            );

        // --- FULLY GONE foreign topo: must be entirely deleted. ----------
        await seedChain(
          areaId: 'area-gone',
          sectorId: 'sector-gone',
          wallId: 'wall-gone',
          photoId: 'photo-gone-original',
          routeId: 'route-gone',
          ownerId: 'stranger-a',
        );
        // A slice-shaped child photo, to exercise the parentPhotoId
        // self-reference delete ordering.
        await db
            .into(db.photos)
            .insert(
              PhotosCompanion.insert(
                id: 'photo-gone-slice',
                createdAt: 1000,
                updatedAt: 1000,
                wallId: 'wall-gone',
                localPath: '/tmp/photo-gone-slice.jpg',
                kind: 'slice',
                width: 100,
                height: 100,
                parentPhotoId: const Value('photo-gone-original'),
                ownerId: const Value('stranger-a'),
              ),
            );
        await db
            .into(db.ascents)
            .insert(
              AscentsCompanion.insert(
                id: 'ascent-gone',
                createdAt: 1000,
                updatedAt: 1000,
                routeId: 'route-gone',
                wallId: 'wall-gone',
                climbedAt: 1000,
                style: 'redpoint',
                ownerId: const Value('stranger-a'),
              ),
            );
        await db
            .into(db.comments)
            .insert(
              CommentsCompanion.insert(
                id: 'comment-gone-on-wall',
                createdAt: 1000,
                updatedAt: 1000,
                wallId: const Value('wall-gone'),
                body: 'Nice line',
                ownerId: const Value('stranger-b'),
              ),
            );
        await db
            .into(db.comments)
            .insert(
              CommentsCompanion.insert(
                id: 'comment-gone-on-ascent',
                createdAt: 1000,
                updatedAt: 1000,
                ascentId: const Value('ascent-gone'),
                body: 'Nice send',
                ownerId: const Value('stranger-b'),
              ),
            );
        await db
            .into(db.likes)
            .insert(
              LikesCompanion.insert(
                id: 'like-gone',
                createdAt: 1000,
                updatedAt: 1000,
                wallId: const Value('wall-gone'),
                ownerId: const Value('stranger-b'),
              ),
            );

        // --- SHARED sector: one wall gone, one wall still visible. The
        // sector (and its area) must survive because of the survivor. ------
        await seedChain(
          areaId: 'area-shared',
          sectorId: 'sector-shared',
          wallId: 'wall-gone-2',
          photoId: 'photo-gone-2',
          routeId: 'route-gone-2',
          ownerId: 'stranger-c',
        );
        // A second wall in the SAME sector, still visible per the server.
        await db
            .into(db.walls)
            .insert(
              WallsCompanion.insert(
                id: 'wall-visible',
                createdAt: 1000,
                updatedAt: 1000,
                sectorId: 'sector-shared',
                name: 'Wall visible',
                sortOrder: 1,
                ownerId: const Value('stranger-c'),
              ),
            );

        // --- OWN-DATA-GUARDED foreign topo: server says gone, but the user
        // has their own ascent on it — must survive entirely. ---------------
        await seedChain(
          areaId: 'area-protected',
          sectorId: 'sector-protected',
          wallId: 'wall-protected',
          photoId: 'photo-protected',
          routeId: 'route-protected',
          ownerId: 'stranger-d',
        );
        await db
            .into(db.ascents)
            .insert(
              AscentsCompanion.insert(
                id: 'ascent-protecting',
                createdAt: 1000,
                updatedAt: 1000,
                routeId: 'route-protected',
                wallId: 'wall-protected',
                climbedAt: 1000,
                style: 'redpoint',
                ownerId: const Value(_me),
              ),
            );

        // --- UNCLAIMED wall (ownerId == null): never touched, whatever the
        // server says. --------------------------------------------------
        await seedChain(
          areaId: 'area-unclaimed',
          sectorId: 'sector-unclaimed',
          wallId: 'wall-unclaimed',
          photoId: 'photo-unclaimed',
          routeId: 'route-unclaimed',
          ownerId: null,
        );

        final remote = _FakeProbeRemote(
          visibleWallIds: {'wall-visible'},
        );
        final service = ForeignWallSweepService(
          db: db,
          remote: remote,
          currentUid: () => _me,
          currentReachability: () => Reachability.online,
        );

        final outcome = await service.sweepStaleForeignWalls();

        expect(outcome.reason, ForeignWallSweepReason.swept);
        expect(
          outcome.purgedWallIds,
          {'wall-gone', 'wall-gone-2'},
          reason: 'wall-visible, wall-protected, wall-own and '
              'wall-unclaimed must all be excluded',
        );
        expect(outcome.purgedSectorIds, {'sector-gone'});
        expect(outcome.purgedAreaIds, {'area-gone'});

        // The fully-gone subtree is entirely gone.
        expect(await wallExists('wall-gone'), isFalse);
        expect(await photoExists('photo-gone-original'), isFalse);
        expect(await photoExists('photo-gone-slice'), isFalse);
        expect(await routeExists('route-gone'), isFalse);
        expect(await ascentExists('ascent-gone'), isFalse);
        expect(await commentExists('comment-gone-on-wall'), isFalse);
        expect(await commentExists('comment-gone-on-ascent'), isFalse);
        expect(await likeExists('like-gone'), isFalse);
        expect(await sectorExists('sector-gone'), isFalse);
        expect(await areaExists('area-gone'), isFalse);

        // The own topo is completely untouched.
        expect(await wallExists('wall-own'), isTrue);
        expect(await photoExists('photo-own'), isTrue);
        expect(await routeExists('route-own'), isTrue);
        expect(await ascentExists('ascent-own'), isTrue);
        expect(await sectorExists('sector-own'), isTrue);
        expect(await areaExists('area-own'), isTrue);

        // The shared sector: one wall gone, its sibling and the sector/area
        // survive.
        expect(await wallExists('wall-gone-2'), isFalse);
        expect(await wallExists('wall-visible'), isTrue);
        expect(await sectorExists('sector-shared'), isTrue);
        expect(await areaExists('area-shared'), isTrue);

        // The own-data-guarded foreign topo survives whole.
        expect(await wallExists('wall-protected'), isTrue);
        expect(await photoExists('photo-protected'), isTrue);
        expect(await routeExists('route-protected'), isTrue);
        expect(await ascentExists('ascent-protecting'), isTrue);
        expect(await sectorExists('sector-protected'), isTrue);
        expect(await areaExists('area-protected'), isTrue);

        // The unclaimed wall is never touched.
        expect(await wallExists('wall-unclaimed'), isTrue);
        expect(await sectorExists('sector-unclaimed'), isTrue);
        expect(await areaExists('area-unclaimed'), isTrue);
      },
    );
  });

  group('abort conditions', () {
    test('reachability not known-online: does nothing and never probes', () async {
      await seedChain(
        areaId: 'area-1',
        sectorId: 'sector-1',
        wallId: 'wall-1',
        photoId: 'photo-1',
        routeId: 'route-1',
        ownerId: 'stranger',
      );
      final remote = _FakeProbeRemote();
      final service = ForeignWallSweepService(
        db: db,
        remote: remote,
        currentUid: () => _me,
        currentReachability: () => Reachability.unknown,
      );

      final outcome = await service.sweepStaleForeignWalls();

      expect(outcome.reason, ForeignWallSweepReason.notKnownOnline);
      expect(remote.requestedChunks, isEmpty);
      expect(await wallExists('wall-1'), isTrue);
    });

    test('unknown session (no signed-in uid): does nothing and never probes', () async {
      await seedChain(
        areaId: 'area-1',
        sectorId: 'sector-1',
        wallId: 'wall-1',
        photoId: 'photo-1',
        routeId: 'route-1',
        ownerId: 'stranger',
      );
      final remote = _FakeProbeRemote();
      final service = ForeignWallSweepService(
        db: db,
        remote: remote,
        currentUid: () => null,
        currentReachability: () => Reachability.online,
      );

      final outcome = await service.sweepStaleForeignWalls();

      expect(outcome.reason, ForeignWallSweepReason.unknownSession);
      expect(remote.requestedChunks, isEmpty);
      expect(await wallExists('wall-1'), isTrue);
    });

    test('zero locally-cached foreign walls: does nothing and never probes', () async {
      await seedChain(
        areaId: 'area-own',
        sectorId: 'sector-own',
        wallId: 'wall-own',
        photoId: 'photo-own',
        routeId: 'route-own',
        ownerId: _me,
      );
      final remote = _FakeProbeRemote();
      final service = ForeignWallSweepService(
        db: db,
        remote: remote,
        currentUid: () => _me,
        currentReachability: () => Reachability.online,
      );

      final outcome = await service.sweepStaleForeignWalls();

      expect(outcome.reason, ForeignWallSweepReason.nothingToSweep);
      expect(remote.requestedChunks, isEmpty);
    });

    test('the probe throwing aborts the WHOLE sweep — nothing is deleted', () async {
      await seedChain(
        areaId: 'area-1',
        sectorId: 'sector-1',
        wallId: 'wall-1',
        photoId: 'photo-1',
        routeId: 'route-1',
        ownerId: 'stranger',
      );
      final remote = _FakeProbeRemote(throwOnFetch: true);
      final service = ForeignWallSweepService(
        db: db,
        remote: remote,
        currentUid: () => _me,
        currentReachability: () => Reachability.online,
      );

      final outcome = await service.sweepStaleForeignWalls();

      expect(outcome.reason, ForeignWallSweepReason.probeFailed);
      expect(await wallExists('wall-1'), isTrue);
    });

    test(
      'a wholly-empty response to a non-trivial ask (>= '
      'kChunkSuspicionMinAsked) is distrusted — nothing is purged even '
      'though every one of those walls really is gone',
      () async {
        // 5 foreign walls, all in ONE chunk (default chunk size), all
        // genuinely gone (none are in `visibleWallIds`) — the server would
        // answer this chunk with an empty list, which is EXACTLY what an
        // auth/RLS blip also looks like. The service must not tell them
        // apart and must therefore keep every one.
        for (var i = 0; i < 5; i++) {
          await seedChain(
            areaId: 'area-$i',
            sectorId: 'sector-$i',
            wallId: 'wall-$i',
            photoId: 'photo-$i',
            routeId: 'route-$i',
            ownerId: 'stranger',
          );
        }
        final remote = _FakeProbeRemote(); // visible: {} — all report gone.
        final service = ForeignWallSweepService(
          db: db,
          remote: remote,
          currentUid: () => _me,
          currentReachability: () => Reachability.online,
        );

        final outcome = await service.sweepStaleForeignWalls();

        expect(outcome.reason, ForeignWallSweepReason.nothingToPurge);
        for (var i = 0; i < 5; i++) {
          expect(await wallExists('wall-$i'), isTrue);
        }
      },
    );

    test(
      'a wholly-empty response to a SMALL (below-threshold) ask IS trusted '
      'and purges — the below-threshold case is unremarkable, not a blip',
      () async {
        await seedChain(
          areaId: 'area-1',
          sectorId: 'sector-1',
          wallId: 'wall-1',
          photoId: 'photo-1',
          routeId: 'route-1',
          ownerId: 'stranger',
        );
        final remote = _FakeProbeRemote(); // below kChunkSuspicionMinAsked.
        final service = ForeignWallSweepService(
          db: db,
          remote: remote,
          currentUid: () => _me,
          currentReachability: () => Reachability.online,
        );

        final outcome = await service.sweepStaleForeignWalls();

        expect(outcome.reason, ForeignWallSweepReason.swept);
        expect(await wallExists('wall-1'), isFalse);
      },
    );
  });
}
