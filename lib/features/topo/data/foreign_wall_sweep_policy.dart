/// Decides which cached FOREIGN (someone else's) walls are safe to hard-
/// delete because the server no longer shows them to this user — never a
/// wall that might be the signed-in user's own, and never one the user has
/// their own data attached to.
///
/// Deliberately IMPORT-FREE and I/O-free, mirroring `public_photo_pruner.dart`:
/// this is pure judgement over plain data, unit-testable on the bare Dart VM
/// with no drift, no network, and no clock. `foreign_wall_sweep_service.dart`
/// supplies the rows (local drift queries) and the server verdict (a
/// `SyncRemote.fetchVisibleWallIds` probe); this file only ever answers
/// "which ids, if any, are safe to delete right now."
///
/// ## Why "absent from a pull" is NOT the signal this uses
///
/// An earlier version of this sweep inferred "gone" from a wall's absence in
/// one `fetchSharedTopos` pull. That is unsound: `fetchSharedTopos` is
/// deliberately capped and geo-scoped (`SharedTopoScope`, decision W-1) — up
/// to `kSharedTopoLimit` (500) published walls, anchored within
/// `kSharedTopoRadiusKm` (250 km) of the user's own most-recently-touched
/// wall — so a wall can be absent from one pull purely because it is outside
/// this trip's window, not because the server deleted it. Treating that
/// absence as deletion would purge walls that are still live the moment the
/// user's anchor moves or a region holds more than 500 published topos.
///
/// This file instead answers a narrower, sound question: "of EXACTLY the ids
/// we asked about, which did the server confirm still visible?" — a plain
/// by-id `SELECT ... WHERE id IN (...)`, gated only by RLS
/// (`is_wall_public`/the owner policy), with no cap, no geo scope, and no
/// pagination (see `SyncRemote.fetchVisibleWallIds`'s doc). An id that was
/// validly asked about and not returned really is gone as far as this user
/// is concerned — hard-deleted, withdrawn, or made private — and every one
/// of those is a case where the cached copy should not persist.
///
/// ## The property this file exists to protect
///
/// **A wall that might be the user's own, or that the user has their own data
/// on, is NEVER purged, under any input.** A `null`/unclaimed owner, an id
/// the probe never validly covered, a wholly-empty probe response for a
/// non-trivial ask (an auth/RLS blip looks exactly like "everything was
/// deleted") — every ambiguous case below resolves to "keep, never purge".
/// The two failure modes are not symmetric: wrongly keeping a stale foreign
/// row costs nothing but a few bytes; wrongly deleting a live cached topo, or
/// the user's own logged ascent, destroys something that cannot be
/// regenerated locally.
library;

/// Minimum number of ids asked about in one probe chunk before a WHOLLY EMPTY
/// response (zero rows back) is distrusted rather than taken at face value.
///
/// Below this, an all-empty response is unremarkable — a handful of walls
/// really can all have been deleted/unshared/taken-down at once. At or above
/// it, getting back literally nothing looks exactly like an auth/RLS/policy
/// blip rather than "every single one of these is gone", and is not trusted.
/// The asymmetry to respect: distrusting a legitimate empty chunk costs one
/// stale row staying cached a little longer; trusting a blip costs real
/// cached data. Chosen small on purpose — the failure mode a blip produces is
/// "everything vanished", so even a modest ask should not vanish entirely.
const int kChunkSuspicionMinAsked = 5;

/// Whether a probe chunk's response should be DISTRUSTED entirely — none of
/// its ids may be treated as "confirmed gone", even though the server
/// returned nothing for them. See the library doc and
/// [kChunkSuspicionMinAsked] for why.
///
/// A response that returned ANYTHING (`returnedCount > 0`) is never
/// suspicious, however small: getting real rows back is itself strong
/// evidence the query executed and RLS is evaluating normally, so the other
/// ids' absence in that same response is meaningful.
bool isChunkResponseSuspicious({
  required int askedCount,
  required int returnedCount,
}) => returnedCount == 0 && askedCount >= kChunkSuspicionMinAsked;

/// One locally-cached wall's ownership + hierarchy facts, as read off a wall
/// row — not its content, just what the sweep policy needs.
class LocalWallFact {
  const LocalWallFact({
    required this.id,
    required this.sectorId,
    required this.ownerId,
  });

  final String id;
  final String sectorId;

  /// `null` means "ownership not yet claimed locally" (the pre-
  /// `LibraryCrudRepository.claimOwnership` shape) — see
  /// [ForeignWallSweepPolicy.wallIdsToPurge] for why that is always kept.
  final String? ownerId;
}

/// One locally-cached sector's ownership + hierarchy facts.
class LocalSectorFact {
  const LocalSectorFact({
    required this.id,
    required this.areaId,
    required this.ownerId,
  });

  final String id;
  final String areaId;
  final String? ownerId;
}

/// One locally-cached area's ownership facts.
class LocalAreaFact {
  const LocalAreaFact({required this.id, required this.ownerId});

  final String id;
  final String? ownerId;
}

/// Pure sweep-selection policy for cached foreign walls (and their now-
/// childless ancestor sectors/areas) that the server has confirmed are gone.
class ForeignWallSweepPolicy {
  const ForeignWallSweepPolicy();

  /// Returns the subset of [localWalls] safe to hard-delete right now.
  ///
  /// A wall is purged if and only if ALL of:
  ///
  ///  1. [LocalWallFact.ownerId] is non-null and differs from [ownUid] —
  ///     provably foreign. `null` (unclaimed pre-sync data — see
  ///     [LocalWallFact.ownerId]'s doc) and `== ownUid` (the user's own wall)
  ///     are both kept unconditionally, before anything else here is even
  ///     consulted.
  ///  2. Its id is in [probedWallIds] — the server was VALIDLY asked about it
  ///     (i.e. its probe chunk was not [isChunkResponseSuspicious]). An id
  ///     never validly probed is "unknown", never "gone".
  ///  3. Its id is NOT in [confirmedVisibleWallIds] — the server's probe
  ///     response for exactly this id.
  ///  4. Its id is NOT in [ownDataWallIds] — the user has an ascent/comment/
  ///     like of their own attached to it (see [ownDataWallIds]). Their own
  ///     record is theirs regardless of who owns the topo it hangs off.
  ///
  /// An empty [probedWallIds] (nothing was validly probed — every chunk was
  /// distrusted, or nothing was asked) purges NOTHING, by rule 2: every wall
  /// fails the "validly probed" test and is kept.
  Set<String> wallIdsToPurge({
    required Iterable<LocalWallFact> localWalls,
    required String ownUid,
    required Set<String> probedWallIds,
    required Set<String> confirmedVisibleWallIds,
    required Set<String> ownDataWallIds,
  }) {
    final result = <String>{};
    for (final w in localWalls) {
      final ownerId = w.ownerId;
      if (ownerId == null) continue; // rule 1: unclaimed, never touch.
      if (ownerId == ownUid) continue; // rule 1: the user's own wall.
      if (!probedWallIds.contains(w.id)) continue; // rule 2: never validly asked about.
      if (confirmedVisibleWallIds.contains(w.id)) continue; // rule 3: still visible.
      if (ownDataWallIds.contains(w.id)) continue; // rule 4: user's own data attached.
      result.add(w.id);
    }
    return result;
  }

  /// Wall ids protected because the signed-in user ([ownUid]) has an
  /// ascent/comment/like of their OWN attached to them — directly (a wall-
  /// attached comment/like, or an ascent logged on the wall), or indirectly
  /// via one of the wall's ascents (a comment/like whose `ascentId` names an
  /// ascent on that wall). [wallIdByAscentId] resolves the indirect case;
  /// an ascent id absent from it (e.g. the ascent itself was never fetched)
  /// resolves to "cannot attribute", which is silently skipped rather than
  /// protecting nothing — the caller is expected to have populated it for
  /// every ascent id any own [comments]/[likes] row names.
  ///
  /// Every row here is re-checked against [ownUid] even though callers are
  /// expected to have already scoped their queries to `ownerId == ownUid` —
  /// defense in depth, so this function's own safety does not depend on the
  /// caller getting that scoping right.
  Set<String> ownDataWallIds({
    required String ownUid,
    required Iterable<({String wallId, String ownerId})> ascents,
    required Iterable<({String? wallId, String? ascentId, String ownerId})> comments,
    required Iterable<({String? wallId, String? ascentId, String ownerId})> likes,
    required Map<String, String> wallIdByAscentId,
  }) {
    final result = <String>{};
    for (final a in ascents) {
      if (a.ownerId == ownUid) result.add(a.wallId);
    }
    for (final rows in [comments, likes]) {
      for (final r in rows) {
        if (r.ownerId != ownUid) continue;
        final direct = r.wallId;
        if (direct != null) {
          result.add(direct);
          continue;
        }
        final ascentId = r.ascentId;
        final resolved = ascentId == null ? null : wallIdByAscentId[ascentId];
        if (resolved != null) result.add(resolved);
      }
    }
    return result;
  }

  /// Sector ids that become childless once [purgedWallIds] are gone AND are
  /// themselves provably foreign (same rule 1 as [wallIdsToPurge]: `null` or
  /// `== ownUid` is always kept).
  ///
  /// "Childless" is evaluated against the FULL local wall set minus
  /// [purgedWallIds] — a sector with any surviving wall (purged or not is
  /// irrelevant to walls NOT in [purgedWallIds]) is never returned.
  Set<String> childlessForeignSectorIds({
    required Iterable<LocalSectorFact> localSectors,
    required Iterable<LocalWallFact> localWalls,
    required String ownUid,
    required Set<String> purgedWallIds,
  }) {
    final survivingSectorIds = <String>{
      for (final w in localWalls)
        if (!purgedWallIds.contains(w.id)) w.sectorId,
    };
    return {
      for (final s in localSectors)
        if (s.ownerId != null && s.ownerId != ownUid && !survivingSectorIds.contains(s.id))
          s.id,
    };
  }

  /// Area ids that become childless once [purgedSectorIds] are gone AND are
  /// themselves provably foreign. Mirrors [childlessForeignSectorIds] one
  /// level up.
  Set<String> childlessForeignAreaIds({
    required Iterable<LocalAreaFact> localAreas,
    required Iterable<LocalSectorFact> localSectors,
    required String ownUid,
    required Set<String> purgedSectorIds,
  }) {
    final survivingAreaIds = <String>{
      for (final s in localSectors)
        if (!purgedSectorIds.contains(s.id)) s.areaId,
    };
    return {
      for (final a in localAreas)
        if (a.ownerId != null && a.ownerId != ownUid && !survivingAreaIds.contains(a.id))
          a.id,
    };
  }
}
