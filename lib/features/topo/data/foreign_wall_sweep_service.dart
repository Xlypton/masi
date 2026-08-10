/// Reconciles cached FOREIGN walls against the server's per-id verdict and
/// hard-deletes the ones it no longer shows this user — the I/O half of the
/// sweep. `foreign_wall_sweep_policy.dart` (pure, import-free) decides
/// *which* ids are safe to delete; this file gathers the inputs it needs (a
/// drift read of every locally-cached wall/sector/area, the current uid and
/// reachability verdict, and a chunked by-id probe via
/// `SyncRemote.fetchVisibleWallIds`), applies that policy, and performs the
/// irreversible part: the row deletes.
///
/// ## Why this exists
///
/// A foreign wall can be HARD-deleted server-side (an admin reset, a
/// moderation takedown, an owner deletion) with no tombstone left behind —
/// `deletedAt` only exists to travel through THIS app's own sync engine, and
/// a row a hard delete removed outright never had one written. Nothing then
/// ever tells a device that cached that wall's Area→Sector→Wall→Photo/Route
/// subtree to remove it: [SyncService.pullOwnAndShared] is an idempotent
/// per-id upsert that never deletes (decision D-4), so the cached copy is
/// stuck on the device forever, showing a topo that no longer exists
/// anywhere else.
///
/// ## Why this is a per-id PROBE, never inferred from a pull
///
/// See `foreign_wall_sweep_policy.dart`'s library doc for the full argument.
/// In short: `SyncRemote.fetchSharedTopos` is capped and geo-scoped
/// (`SharedTopoScope`, W-1), so a wall's absence from one pull proves
/// nothing about deletion. [fetchVisibleWallIds] asks about EXACTLY the ids
/// this device already holds, chunked so a large cache cannot build one
/// giant request; that is uncapped and ungeo-scoped by construction — the
/// only filter in play is RLS itself (`is_wall_public`).
///
/// ## Never fails a pull
///
/// This is triggered as fire-and-forget housekeeping after a successful pull
/// (mirroring `PublicPhotoPruneService`'s one production trigger in
/// `SyncOrchestrator`), so [sweepStaleForeignWalls] never throws — every
/// failure mode (offline, a probe error, an unexpected exception) is caught
/// and reported as an [ForeignWallSweepOutcome], never propagated.
///
/// ## Rows, not bytes — real deletes, not tombstones
///
/// Unlike [PublicPhotoPruneService] (which only ever drops cached PIXELS and
/// leaves the row intact so the topo stays readable offline), this service
/// deletes the ROWS themselves: `Photos`, `Routes`, foreign `Ascents`/
/// `Comments`/`Likes` on the wall, the `Walls` row, and any `Sectors`/`Areas`
/// left childless and themselves provably foreign. A soft-delete
/// (tombstone) would be wrong here specifically because there is no outbox
/// (decision D-4) and this row is not the user's own: a tombstone written
/// locally would sit dirty forever with nothing to push it TO (the sync
/// engine only re-pushes `ownerId == auth.uid()` rows), and if it somehow
/// were pushed, the server has no matching row for it to reconcile against.
library;

import 'package:drift/drift.dart' show BooleanExpressionOperators;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/app_database.dart';
import '../../../core/db/database_provider.dart';
import '../../account/application/auth_providers.dart';
import '../../backup/application/reachability_providers.dart';
import '../../backup/application/sync_providers.dart';
import '../../backup/data/sync_remote.dart';
import 'foreign_wall_sweep_policy.dart';

/// Ids per probe round trip. Sized to the middle of the requested 100-200
/// range: large enough that a big cache does not need hundreds of round
/// trips, small enough that [isChunkResponseSuspicious]'s threshold check
/// stays meaningful (a single request is never asking about the caller's
/// ENTIRE cache at once).
const int kForeignWallSweepChunkSize = 150;

/// Why a sweep pass did what it did (or nothing).
enum ForeignWallSweepReason {
  /// [Reachability] has not confirmed reach — see
  /// [ReachabilityVerdict.isKnownOnline]. An unproven connection is not
  /// grounds to probe, let alone delete.
  notKnownOnline,

  /// No signed-in identity is known, so "foreign" cannot be established for
  /// any wall (rule 1 needs [ownUid] to compare against).
  unknownSession,

  /// This device holds zero provably-foreign walls. Nothing to reconcile.
  nothingToSweep,

  /// A probe round trip threw. An error is not evidence of deletion, so the
  /// WHOLE sweep aborts rather than acting on the chunks that did answer.
  probeFailed,

  /// The probe ran cleanly, but nothing ended up purgeable: every candidate
  /// was either confirmed still visible, protected by the user's own data,
  /// or never validly probed (every chunk asking about it was distrusted —
  /// see [isChunkResponseSuspicious]).
  nothingToPurge,

  /// At least one wall (and possibly its now-childless foreign ancestors)
  /// was deleted.
  swept,

  /// Something else threw partway through (a DB error, an unexpected
  /// exception) — caught, logged, and reported here rather than escaping.
  unexpectedError,
}

/// What one sweep pass did.
class ForeignWallSweepOutcome {
  const ForeignWallSweepOutcome({
    required this.reason,
    this.purgedWallIds = const {},
    this.purgedSectorIds = const {},
    this.purgedAreaIds = const {},
    this.error,
  });

  final ForeignWallSweepReason reason;
  final Set<String> purgedWallIds;
  final Set<String> purgedSectorIds;
  final Set<String> purgedAreaIds;

  /// Set only for [ForeignWallSweepReason.probeFailed]/[unexpectedError].
  final String? error;

  bool get didSweep =>
      purgedWallIds.isNotEmpty || purgedSectorIds.isNotEmpty || purgedAreaIds.isNotEmpty;

  @override
  String toString() =>
      'ForeignWallSweepOutcome(reason: ${reason.name}, '
      'walls: ${purgedWallIds.length}, sectors: ${purgedSectorIds.length}, '
      'areas: ${purgedAreaIds.length}'
      '${error != null ? ', error: $error' : ''})';
}

/// Reconciles cached foreign walls against the server's per-id verdict and
/// hard-deletes the ones it confirms are gone.
class ForeignWallSweepService {
  ForeignWallSweepService({
    required AppDatabase db,
    required SyncRemote remote,
    required String? Function() currentUid,
    required Reachability Function() currentReachability,
    this.policy = const ForeignWallSweepPolicy(),
    this.chunkSize = kForeignWallSweepChunkSize,
    // Private fields with named params, matching `SyncService`/
    // `PublicPhotoPruneService`'s house pattern.
  }) : _db = db, // ignore: prefer_initializing_formals
       _remote = remote, // ignore: prefer_initializing_formals
       _currentUid = currentUid, // ignore: prefer_initializing_formals
       _currentReachability = currentReachability; // ignore: prefer_initializing_formals

  final AppDatabase _db;
  final SyncRemote _remote;
  final String? Function() _currentUid;
  final Reachability Function() _currentReachability;
  final ForeignWallSweepPolicy policy;
  final int chunkSize;

  /// Runs one sweep pass and returns what it did. Never throws — the caller
  /// is a sync path, and a housekeeping sweep must never be able to fail a
  /// pull.
  Future<ForeignWallSweepOutcome> sweepStaleForeignWalls() async {
    try {
      return await _sweep();
    } catch (e, st) {
      debugPrint('ForeignWallSweepService: sweep threw: $e\n$st');
      return ForeignWallSweepOutcome(
        reason: ForeignWallSweepReason.unexpectedError,
        error: e.toString(),
      );
    }
  }

  Future<ForeignWallSweepOutcome> _sweep() async {
    if (!_currentReachability().isKnownOnline) {
      return const ForeignWallSweepOutcome(reason: ForeignWallSweepReason.notKnownOnline);
    }

    final ownUid = _currentUid();
    if (ownUid == null) {
      return const ForeignWallSweepOutcome(reason: ForeignWallSweepReason.unknownSession);
    }

    final wallRows = await _db.select(_db.walls).get();
    final localWalls = [
      for (final w in wallRows)
        LocalWallFact(id: w.id, sectorId: w.sectorId, ownerId: w.ownerId),
    ];
    final candidateIds = [
      for (final w in localWalls)
        if (w.ownerId != null && w.ownerId != ownUid) w.id,
    ];
    if (candidateIds.isEmpty) {
      return const ForeignWallSweepOutcome(reason: ForeignWallSweepReason.nothingToSweep);
    }

    // Probe the server, chunked. A chunk that throws aborts the WHOLE sweep
    // (an error is not evidence of deletion, and the chunks that already
    // answered do not justify acting alone); a chunk whose response is
    // wholly empty for a non-trivial ask is distrusted and skipped — its ids
    // simply never become "probed", per [isChunkResponseSuspicious].
    final probedWallIds = <String>{};
    final confirmedVisibleWallIds = <String>{};
    for (final chunk in _chunks(candidateIds)) {
      List<String> visible;
      try {
        visible = await _remote.fetchVisibleWallIds(chunk);
      } catch (e) {
        return ForeignWallSweepOutcome(
          reason: ForeignWallSweepReason.probeFailed,
          error: e.toString(),
        );
      }
      if (isChunkResponseSuspicious(askedCount: chunk.length, returnedCount: visible.length)) {
        continue;
      }
      probedWallIds.addAll(chunk);
      confirmedVisibleWallIds.addAll(visible);
    }

    // Own-data protection only needs computing for walls that could
    // actually be purged (validly probed and not confirmed visible) — no
    // point resolving it for walls that are being kept regardless.
    final possiblyGone = <String>{
      for (final id in probedWallIds)
        if (!confirmedVisibleWallIds.contains(id)) id,
    };
    final ownDataWallIds = await _ownDataWallIds(
      ownUid: ownUid,
      candidateWallIds: possiblyGone,
    );

    final wallIdsToPurge = policy.wallIdsToPurge(
      localWalls: localWalls,
      ownUid: ownUid,
      probedWallIds: probedWallIds,
      confirmedVisibleWallIds: confirmedVisibleWallIds,
      ownDataWallIds: ownDataWallIds,
    );
    if (wallIdsToPurge.isEmpty) {
      return const ForeignWallSweepOutcome(reason: ForeignWallSweepReason.nothingToPurge);
    }

    final sectorRows = await _db.select(_db.sectors).get();
    final localSectors = [
      for (final s in sectorRows) LocalSectorFact(id: s.id, areaId: s.areaId, ownerId: s.ownerId),
    ];
    final sectorIdsToPurge = policy.childlessForeignSectorIds(
      localSectors: localSectors,
      localWalls: localWalls,
      ownUid: ownUid,
      purgedWallIds: wallIdsToPurge,
    );

    final areaRows = await _db.select(_db.areas).get();
    final localAreas = [
      for (final a in areaRows) LocalAreaFact(id: a.id, ownerId: a.ownerId),
    ];
    final areaIdsToPurge = policy.childlessForeignAreaIds(
      localAreas: localAreas,
      localSectors: localSectors,
      ownUid: ownUid,
      purgedSectorIds: sectorIdsToPurge,
    );

    await _deleteSubtree(
      wallIds: wallIdsToPurge,
      sectorIds: sectorIdsToPurge,
      areaIds: areaIdsToPurge,
    );

    return ForeignWallSweepOutcome(
      reason: ForeignWallSweepReason.swept,
      purgedWallIds: wallIdsToPurge,
      purgedSectorIds: sectorIdsToPurge,
      purgedAreaIds: areaIdsToPurge,
    );
  }

  /// Resolves [ForeignWallSweepPolicy.ownDataWallIds] against the local
  /// database, scoped to [candidateWallIds] (the walls that could actually
  /// be purged) rather than every wall — an ascent/comment/like on a wall
  /// that is being kept regardless is irrelevant here.
  Future<Set<String>> _ownDataWallIds({
    required String ownUid,
    required Set<String> candidateWallIds,
  }) async {
    if (candidateWallIds.isEmpty) return const {};

    final ownAscents = <({String wallId, String ownerId})>[];
    for (final chunk in _chunks(candidateWallIds.toList())) {
      final rows = await (_db.select(_db.ascents)
            ..where((a) => a.ownerId.equals(ownUid) & a.wallId.isIn(chunk)))
          .get();
      ownAscents.addAll([
        for (final a in rows) (wallId: a.wallId, ownerId: a.ownerId!),
      ]);
    }

    // Own comments/likes can attach to ANY ascent, not just one already
    // known to be on a candidate wall, so they are read unscoped and
    // resolved against `wallIdByAscentId` below.
    final ownComments = await (_db.select(_db.comments)..where((c) => c.ownerId.equals(ownUid)))
        .get();
    final ownLikes = await (_db.select(_db.likes)..where((l) => l.ownerId.equals(ownUid))).get();

    final neededAscentIds = <String>{
      for (final c in ownComments)
        if (c.ascentId != null) c.ascentId!,
      for (final l in ownLikes)
        if (l.ascentId != null) l.ascentId!,
    }.toList();
    final wallIdByAscentId = <String, String>{};
    for (final chunk in _chunks(neededAscentIds)) {
      final rows = await (_db.select(_db.ascents)..where((a) => a.id.isIn(chunk))).get();
      for (final a in rows) {
        wallIdByAscentId[a.id] = a.wallId;
      }
    }

    return policy.ownDataWallIds(
      ownUid: ownUid,
      ascents: ownAscents,
      comments: [
        for (final c in ownComments) (wallId: c.wallId, ascentId: c.ascentId, ownerId: c.ownerId!),
      ],
      likes: [
        for (final l in ownLikes) (wallId: l.wallId, ascentId: l.ascentId, ownerId: l.ownerId!),
      ],
      wallIdByAscentId: wallIdByAscentId,
    );
  }

  /// Deletes [wallIds]' foreign subtree (photos, routes, foreign ascents/
  /// comments/likes) plus [sectorIds]/[areaIds], leaf-to-root, respecting
  /// `PRAGMA foreign_keys = ON` (`app_database.dart`'s `beforeOpen`). One
  /// transaction: a partial delete here is exactly the FK-violating half-
  /// state that ordering is meant to prevent.
  Future<void> _deleteSubtree({
    required Set<String> wallIds,
    required Set<String> sectorIds,
    required Set<String> areaIds,
  }) async {
    if (wallIds.isEmpty) return;
    final wallIdList = wallIds.toList();

    await _db.transaction(() async {
      // Ascent ids under the walls being purged — needed so comments/likes
      // attached via `ascentId` (rather than `wallId` directly) are caught
      // too. Every ascent found here is guaranteed foreign at this point:
      // `wallIdsToPurge` only returns a wall id when NO own ascent/comment/
      // like references it (rule 4), so nothing selected below can be the
      // user's own.
      final ascentIds = [
        for (final a in await (_db.select(_db.ascents)..where((a) => a.wallId.isIn(wallIdList))).get())
          a.id,
      ];

      // 1-2. Leaves: comments/likes, wall- or ascent-attached.
      await (_db.delete(_db.comments)
            ..where(
              (c) => ascentIds.isEmpty
                  ? c.wallId.isIn(wallIdList)
                  : c.wallId.isIn(wallIdList) | c.ascentId.isIn(ascentIds),
            ))
          .go();
      await (_db.delete(_db.likes)
            ..where(
              (l) => ascentIds.isEmpty
                  ? l.wallId.isIn(wallIdList)
                  : l.wallId.isIn(wallIdList) | l.ascentId.isIn(ascentIds),
            ))
          .go();

      // 3. Ascents (now unreferenced by any comment/like).
      await (_db.delete(_db.ascents)..where((a) => a.wallId.isIn(wallIdList))).go();

      // 4. Routes (now unreferenced by any ascent).
      await (_db.delete(_db.routes)..where((r) => r.wallId.isIn(wallIdList))).go();

      // 5. Photos, two-phase for the `parentPhotoId` self-reference: a slice
      // (deprecated/dormant, but not impossible on old data) must go before
      // the original it points at.
      await (_db.delete(_db.photos)
            ..where((p) => p.wallId.isIn(wallIdList) & p.parentPhotoId.isNotNull()))
          .go();
      await (_db.delete(_db.photos)..where((p) => p.wallId.isIn(wallIdList))).go();

      // 6. The walls themselves.
      await (_db.delete(_db.walls)..where((w) => w.id.isIn(wallIdList))).go();

      // 7-8. Now-childless foreign ancestors.
      if (sectorIds.isNotEmpty) {
        await (_db.delete(_db.sectors)..where((s) => s.id.isIn(sectorIds.toList()))).go();
      }
      if (areaIds.isNotEmpty) {
        await (_db.delete(_db.areas)..where((a) => a.id.isIn(areaIds.toList()))).go();
      }
    });
  }

  Iterable<List<String>> _chunks(List<String> ids) sync* {
    for (var i = 0; i < ids.length; i += chunkSize) {
      yield ids.sublist(i, i + chunkSize > ids.length ? ids.length : i + chunkSize);
    }
  }
}

/// App-wide [ForeignWallSweepService]. A plain [Provider]: the service holds
/// no state of its own, mirroring [publicPhotoPruneServiceProvider].
final foreignWallSweepServiceProvider = Provider<ForeignWallSweepService>(
  (ref) => ForeignWallSweepService(
    db: ref.watch(appDatabaseProvider),
    remote: ref.watch(syncRemoteProvider),
    currentUid: ref.watch(currentUidProvider),
    currentReachability: () => ref.read(reachabilityProvider),
  ),
);
