import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/app_database.dart' as db;
import '../../../core/db/database_provider.dart';
import '../../../core/config/supabase_providers.dart';
import '../../account/application/auth_providers.dart';
import '../../backup/application/sync_orchestrator.dart';
import '../../library/application/library_providers.dart';
import '../data/admin_deletion_log_remote.dart';
import '../data/moderation_remote.dart';
import '../data/moderation_repository.dart';
import '../domain/abandoned_topo.dart';
import '../domain/access_state.dart';
import '../domain/admin_deleted_topo.dart';
import '../domain/deletion_request.dart';
import '../domain/material_change.dart';
import '../domain/moderation_state.dart';

/// The cloud read seam for moderation state. Overridden in tests with an
/// in-memory fake — never the real one, which would touch the network.
final moderationRemoteProvider = Provider<ModerationRemote>(
  (ref) => SupabaseModerationRemote(ref.watch(supabaseClientProvider)),
);

/// Local reads/writes over the on-device mirror.
final moderationRepositoryProvider = Provider<ModerationRepository>(
  (ref) => ModerationRepository(ref.watch(appDatabaseProvider)),
);

/// The cloud read seam for "which topos has an admin deleted outright, that
/// nobody has restored yet" — see [AdminDeletionLogRemote]'s own doc for why
/// this is a separate seam from [moderationRemoteProvider] rather than
/// another method on it. Overridden in tests with an in-memory fake.
final adminDeletionLogRemoteProvider = Provider<AdminDeletionLogRemote>(
  (ref) => SupabaseAdminDeletionLogRemote(ref.watch(supabaseClientProvider)),
);

/// Reactive moderation state for one topo.
///
/// Resolves to [ModerationState.draft] when nothing is known locally — see
/// [ModerationRepository.watchState] for why the unknown case fails closed
/// rather than open.
///
/// `autoDispose` + `family`: a topo the user is no longer looking at should
/// not keep a Drift subscription open for the life of the app, and the state
/// of an arbitrary number of walls would otherwise accumulate one live
/// stream each.
final wallModerationStateProvider = StreamProvider.autoDispose
    .family<ModerationState, String>(
      (ref, wallId) =>
          ref.watch(moderationRepositoryProvider).watchState(wallId),
    );

/// The full local moderation row for one topo — for the rejection reason and
/// the withdrawal countdown, which [wallModerationStateProvider] flattens
/// away.
final wallModerationRowProvider = StreamProvider.autoDispose
    .family<db.WallModerationRow?, String>(
      (ref, wallId) => ref.watch(moderationRepositoryProvider).watchRow(wallId),
    );

/// One topo's moderation status as a reader experiences it, including the
/// withdrawal countdown (community editing phase 5 / C-3).
///
/// Prefer this over [wallModerationRowProvider] anywhere the answer is shown
/// to a person: it is the only place that reconciles a stored `published`
/// with an elapsed ten-day window, which the server deliberately never writes
/// back (COMMUNITY_IMPL.md §0.2).
///
/// Resolves to a draft view when nothing is mirrored locally — the same
/// fail-closed direction [ModerationRepository.watchState] takes.
final wallModerationViewProvider = StreamProvider.autoDispose
    .family<ModerationView, String>(
      (ref, wallId) => ref
          .watch(moderationRepositoryProvider)
          .watchRow(wallId)
          .map(
            (row) => ModerationView.fromRow(
              state: row?.state,
              withdrawRequestedAt: row?.withdrawRequestedAt,
              rejectionReason: row?.rejectionReason,
            ),
          ),
    );

/// Whether the signed-in user may see the admin surface.
///
/// A UI hint only — every admin RPC re-checks membership server-side, so this
/// deciding wrongly costs a wasted tap and an error, never access. Resolves to
/// `false` while loading and on any failure, so the surface fails closed.
///
/// Keyed on the current uid so signing in as a different account re-resolves
/// rather than carrying the previous answer.
final isAdminProvider = FutureProvider<bool>((ref) async {
  final uid = ref.watch(effectiveUidProvider);
  if (uid == null) return false;
  return ref.watch(moderationRemoteProvider).isAdmin();
});

/// One pending submission awaiting review.
class ModerationQueueEntry {
  const ModerationQueueEntry({
    required this.wallId,
    required this.wallName,
    required this.ownerId,
    required this.submittedAt,
    required this.routeCount,
    required this.areaName,
  });

  final String wallId;
  final String wallName;
  final String? ownerId;
  final int? submittedAt;
  final int routeCount;

  /// `null` for a topo filed under the hidden `__default__` sentinel Area —
  /// mapped here rather than surfaced raw, the same way
  /// `LibraryCrudRepository.watchTopos` maps it, so the sentinel never
  /// reaches a screen.
  final String? areaName;

  static const String _sentinelAreaName = '__default__';

  factory ModerationQueueEntry.fromRow(Map<String, dynamic> row) {
    final area = row['areaName'] as String?;
    return ModerationQueueEntry(
      wallId: row['wallId'] as String? ?? '',
      wallName: (row['wallName'] as String?)?.trim().isNotEmpty == true
          ? row['wallName'] as String
          : 'Untitled topo',
      ownerId: row['ownerId'] as String?,
      submittedAt: (row['submittedAt'] as num?)?.toInt(),
      routeCount: (row['routeCount'] as num?)?.toInt() ?? 0,
      areaName: (area == null || area == _sentinelAreaName) ? null : area,
    );
  }
}

/// The admin review queue: pending submissions, oldest first.
///
/// Deliberately NOT best-effort. An error here surfaces as an error, because
/// a queue that silently renders empty for an admin whose session expired
/// says "nothing to review" when the truth is "we could not ask".
final moderationQueueProvider = FutureProvider.autoDispose<
  List<ModerationQueueEntry>
>((ref) async {
  final rows = await ref.watch(moderationRemoteProvider).fetchQueue();
  return [for (final row in rows) ModerationQueueEntry.fromRow(row)];
});

/// Published topos whose owner has stopped answering suggestions (C-11),
/// longest-stuck first.
///
/// Not best-effort, for the same reason as [moderationQueueProvider]: an empty
/// list that actually means "we could not ask" reads as "nothing is abandoned",
/// and this is the one surface whose whole job is noticing that something has
/// been quietly stuck for a very long time.
///
/// Malformed rows are dropped rather than half-built — the decision this list
/// leads to is taking someone's topo away from them, and a row an admin cannot
/// read is a row they should not be acting on.
final abandonedToposProvider =
    FutureProvider.autoDispose<List<AbandonedTopo>>((ref) async {
      final rows = await ref.watch(moderationRemoteProvider).fetchAbandoned();
      return [
        for (final row in rows) ?AbandonedTopo.fromRow(row),
      ];
    });

/// Published topos that changed shape after approval (C-5d), newest first.
///
/// Not best-effort, for the same reason as [moderationQueueProvider]: an empty
/// list that actually means "we could not ask" reads here as "nothing has been
/// tampered with", which is precisely the conclusion this surface exists to
/// stop an admin drawing by default.
final materialChangesProvider =
    FutureProvider.autoDispose<List<MaterialChange>>((ref) async {
      final rows = await ref.watch(moderationRemoteProvider).fetchMaterialChanges();
      return [
        for (final row in rows) ?MaterialChange.fromRow(row),
      ];
    });

/// Clearing a material-change notice.
///
/// A one-line service rather than a direct remote call from the widget, so the
/// list refresh cannot be forgotten at a call site: a row that stays on screen
/// after being cleared invites a second tap, and while the RPC is idempotent
/// the admin has no way to know that.
class MaterialChangeService {
  const MaterialChangeService(this._ref);

  final Ref _ref;

  Future<void> resolve(String noticeId) async {
    await _ref.read(moderationRemoteProvider).resolveMaterialChange(noticeId);
    _ref.invalidate(materialChangesProvider);
  }
}

final materialChangeServiceProvider = Provider<MaterialChangeService>(
  MaterialChangeService.new,
);

/// Owners asking permission to delete a topo that has been public, oldest
/// first — somebody is waiting on each of these.
///
/// Not best-effort, for the same reason as [moderationQueueProvider]: an empty
/// list that actually means "we could not ask" reads as "nobody is waiting",
/// and the person waiting has been told a moderator will look.
final deletionRequestsProvider =
    FutureProvider.autoDispose<List<DeletionRequest>>((ref) async {
      final rows = await ref
          .watch(moderationRemoteProvider)
          .fetchDeletionRequests();
      return [
        for (final row in rows) ?DeletionRequest.fromRow(row),
      ];
    });

/// Deciding a deletion request.
///
/// Approving GRANTS PERMISSION — it deletes nothing. The owner still performs
/// the deletion, so the destructive act stays with the person whose work it is
/// and an admin's mis-tap costs nobody their topo. That is also why this
/// service cannot delete anything itself, and has no method that could.
class DeletionReviewService {
  const DeletionReviewService(this._ref);

  final Ref _ref;

  Future<String> review({
    required String requestId,
    required bool approve,
    String? note,
  }) async {
    final result = await _ref
        .read(moderationRemoteProvider)
        .reviewDeletion(requestId: requestId, approve: approve, note: note);
    _ref.invalidate(deletionRequestsProvider);
    return result;
  }
}

final deletionReviewServiceProvider = Provider<DeletionReviewService>(
  DeletionReviewService.new,
);

/// Admin-deleted topos still awaiting a restore, newest deletion first — see
/// [AdminDeletionLogRemote.fetchAdminDeletedTopos].
///
/// Not best-effort, for the same reason [deletionRequestsProvider] isn't: an
/// empty list that actually means "we could not ask" reads as "nothing to
/// restore", which defeats the one thing this list exists to prevent — a
/// reversible admin delete staying one-way in practice just because nobody
/// could see it needed a second look.
///
/// Malformed rows are dropped rather than half-built, like every other list
/// in this feature.
final adminDeletedToposProvider =
    FutureProvider.autoDispose<List<AdminDeletedTopo>>((ref) async {
      final rows = await ref
          .watch(adminDeletionLogRemoteProvider)
          .fetchAdminDeletedTopos();
      return [
        for (final row in rows) ?AdminDeletedTopo.fromRow(row),
      ];
    });

/// The effective access/closure state for one topo, after inheritance up the
/// Wall → Sector → Area chain (community editing phase 2 / R-2).
///
/// Reads local Drift only — access state rides the ordinary sync engine on
/// synced, owner-writable columns, so it is already on the device and works
/// offline like every other read in this app. Nothing here needs the network.
final wallAccessProvider = StreamProvider.autoDispose
    .family<ResolvedAccess, String>(
      (ref, wallId) =>
          ref.watch(moderationRepositoryProvider).watchAccess(wallId),
    );

/// The write side of the withdrawal flow (community editing phase 5 / C-3).
///
/// Deliberately NOT part of [ModerationRepository]: that class mirrors what
/// the server says and has no method that originates a moderation change,
/// which is a property worth keeping. A withdrawal is an RPC call followed by
/// a re-pull, so it belongs here, next to the other things that talk to the
/// cloud and then refresh the mirror.
///
/// Both methods re-pull the affected wall before returning, so the countdown
/// banner is correct the moment the sheet closes rather than after the next
/// unrelated sync. They let THE RPC's OWN errors propagate — unlike the
/// best-effort reads, a withdrawal that silently failed would leave the owner
/// believing a ten-day clock is running when it is not.
///
/// Everything AFTER the RPC is best-effort and cannot throw, which is a
/// different claim and a deliberate one. Once the RPC has returned, the change
/// is committed server-side; letting a failed local write or a failed reconcile
/// re-pull surface as a thrown error would tell the owner their withdrawal did
/// not happen when it did — the exact inversion the paragraph above is there to
/// prevent, just from the other side.
///
/// Both also write the RPC's OWN answer into the local mirror BEFORE that
/// re-pull, so a re-pull that fails cannot leave the mirror contradicting a
/// change the server has already committed. [cancel] explains why that ordering
/// is load-bearing rather than tidy.
class WithdrawalService {
  const WithdrawalService(this._ref);

  final Ref _ref;

  /// Starts the clock. Returns the epoch-ms instant it started from.
  ///
  /// Deliberately does NOT delete the wall's published photo bytes. A requested
  /// withdrawal leaves `wall_moderation.state = 'published'` and only sets
  /// `withdrawRequestedAt`, and `is_wall_public()` keeps returning true for the
  /// full 10-day grace period — so deleting the bytes here would leave the topo
  /// in the community feed with blank images for ten days, and `cancel` would
  /// restore a topo with no pictures at all. Byte cleanup happens in the sync
  /// push once the window has actually matured (SEC-2, `sync_service.dart`).
  Future<int?> request(String wallId) async {
    final at = await _ref
        .read(moderationRemoteProvider)
        .requestWithdrawal(wallId);
    // Before the refresh, and for the same reason [cancel] does it — see there.
    // This direction cannot destroy bytes (a mirror that has not heard about a
    // withdrawal computes `withdrawalMatured == false`, which KEEPS them), but
    // it can strand them: nothing ever flips `visibility` or `state` when the
    // window matures, so a mirror that never learned the clock started will not
    // notice it running out either, and the published bytes of a topo the server
    // has stopped serving stay world-readable until some later refresh happens
    // to succeed.
    // A null [at] means the RPC's answer was unreadable, NOT that no clock is
    // running — writing it would clear a countdown the server just started.
    if (at != null) await _recordCountdown(wallId, at);
    await _reconcile(wallId);
    return at;
  }

  /// Stops the clock. Returns the resulting state — `published` for a normal
  /// cancellation, `pending` when the window had already elapsed and this was
  /// therefore a re-submission.
  Future<String> cancel(String wallId) async {
    final state = await _ref.read(moderationRemoteProvider).cancelWithdrawal(wallId);

    // BEFORE the refresh, and not merely as an optimisation. The RPC has already
    // COMMITTED — the server has nulled `withdrawRequestedAt` — so its success is
    // itself authoritative that no countdown is running any more. If the refresh
    // below then throws (an offline moment, a PostgREST hiccup), the mirror would
    // otherwise keep the OLD timestamp, and once that timestamp matures SEC-2 in
    // `sync_service.dart` computes `shouldBeShared == false` from it and DELETES
    // the published bytes of a topo the server just put back. Writing the
    // server's answer down first makes the destructive outcome unreachable from a
    // failed refresh.
    await _recordCountdown(wallId, null);

    await _reconcile(wallId);
    return state;
  }

  /// Mirrors the countdown the RPC just reported, guarded.
  ///
  /// Swallows, because the moderation change itself has already succeeded
  /// server-side and reporting a local bookkeeping failure as a failed
  /// withdrawal tells the owner the opposite of the truth. The provider read is
  /// inside the guard as well — `moderationRepositoryProvider` is an ordinary
  /// `Provider` whose `build()` failure propagates through `read()` (see
  /// [AdminDeleteService._settle] for the same hazard).
  Future<void> _recordCountdown(String wallId, int? at) async {
    try {
      await _ref
          .read(moderationRepositoryProvider)
          .recordWithdrawRequestedAt(wallId, at);
    } catch (_) {
      // Deliberately swallowed — see this method's doc.
    }
  }

  /// Re-pulls the wall so the rest of the row (a re-submission's `state`,
  /// `submittedAt`, cleared `reviewedAt`) matches the server too, since
  /// [_recordCountdown] only ever writes the one column it was told about.
  ///
  /// Guarded for the same reason, and in a SEPARATE try from the mirror write so
  /// neither can skip the other. [refreshWallModeration] documents itself as
  /// never throwing, and via the real `SupabaseModerationRemote` it does not —
  /// but it reads `moderationRepositoryProvider` and `moderationRemoteProvider`,
  /// and an ordinary `Provider` whose `build()` fails (no Supabase, no database)
  /// propagates straight through `read()`. That is the throw this catches, and
  /// it is why the mirror write above happens FIRST rather than relying on this.
  Future<void> _reconcile(String wallId) async {
    try {
      await refreshWallModeration(_ref, {wallId});
    } catch (_) {
      // Deliberately swallowed — see this method's doc.
    }
  }
}

final withdrawalServiceProvider = Provider<WithdrawalService>(
  WithdrawalService.new,
);

/// What a takedown actually accomplished.
///
/// [photoObjects] counts ORIGINAL photos only — not the cloud-thumbnail
/// companion Storage removes alongside each one, best-effort (see
/// `ModerationRemote.removePublishedPhotoObjects` and
/// [originalPhotoRequestCount]). [photoObjects] vs [photoBytesRemoved] are
/// reported separately on purpose: a takedown that changed the moderation
/// state but removed none of the bytes is the exact failure W-2 describes,
/// and collapsing the two into a bool is how it stayed invisible for so long.
typedef TakedownResult = ({int photoObjects, int photoBytesRemoved});

/// Takes a published topo down, and removes its PUBLIC photo bytes with it
/// (W-2).
///
/// ## Why the bytes, when §3.3 says never destroy anything
///
/// These do not conflict, because they are about different objects. §3.3
/// protects the topo RECORD — routes, ascents, comments, version history — and
/// none of that is touched here. W-2 is about the world-readable COPY of the
/// photo: a moderator taking down inappropriate imagery has to be able to take
/// down the imagery, not just the row pointing at it.
///
/// The takedown also stays reversible, which is what makes deleting the public
/// copy safe: the owner's private `<uid>/<photoId><ext>` object is never
/// touched, and because push re-reads and re-sends its own rows every time
/// (decision D-4, no outbox), re-publishing simply re-uploads the shared copy.
/// The deletion is self-healing rather than terminal.
///
/// ## Order is not stylistic
///
/// The photo objects are enumerated FIRST, before the RPC. The shared-photo
/// SELECT policy is `is_wall_public("wallId")`, which the takedown makes false —
/// so afterwards even an admin cannot list what there was to delete. Reading
/// after removing would always report zero and always leave the bytes.
class TakedownService {
  const TakedownService(this._ref);

  final Ref _ref;

  /// Removes [wallId] from public view and deletes its published photo bytes.
  ///
  /// The RPC's errors propagate — an admin who thinks they took something down
  /// when they did not is the worst outcome here. The byte deletion does NOT
  /// throw, but its result is returned rather than swallowed, so the caller can
  /// say "taken down, but 2 of 3 images could not be removed" instead of a bare
  /// success.
  Future<TakedownResult> remove({required String wallId, String? reason}) async {
    final remote = _ref.read(moderationRemoteProvider);

    // BEFORE the RPC — see this class's doc.
    final objects = await remote.publishedPhotoObjects(wallId);

    await remote.removeTopo(wallId: wallId, reason: reason);

    final removed = await remote.removePublishedPhotoObjects(objects);

    await refreshWallModeration(_ref, {wallId});
    return (
      photoObjects: originalPhotoRequestCount(objects),
      photoBytesRemoved: removed,
    );
  }
}

final takedownServiceProvider = Provider<TakedownService>(TakedownService.new);

/// What one admin delete actually accomplished.
///
/// [deletedAt] is the server's instant, not the client's — it is what
/// [AdminDeleteService.restoreTopo] matches on later, and a clock skew of a
/// few seconds between the phone and Postgres would make a locally-stamped one
/// match nothing.
///
/// [photoObjects] counts ORIGINAL photos only, for the same reason
/// [TakedownResult] does — see [originalPhotoRequestCount]. [photoObjects] vs
/// [photoBytesRemoved] are reported separately for the same reason
/// [TakedownResult] does it: a delete that tombstoned every row but removed
/// none of the world-readable bytes is the W-2 failure, and collapsing the two
/// into a bool is how it stayed invisible. Both are zero for an ascent or a
/// comment, neither of which owns any photo bytes.
typedef AdminDeleteResult = ({
  int? deletedAt,
  int photoObjects,
  int photoBytesRemoved,
});

/// An admin's power to delete ANY topo and ANY feed item — not just their own.
///
/// ## Why this is not the ordinary delete path
///
/// It cannot be. `LibraryCrudRepository.softDeleteWall` refuses to touch a row
/// whose `ownerId` is not the signed-in uid, and even if it did, the push query
/// is hard-filtered `ownerId = uid` so the tombstone would never leave the
/// device. Both walls are deliberate. So every method here goes through a
/// `SECURITY DEFINER` RPC, which re-checks `is_admin()` server-side and writes
/// the `moderation_log` entry in the SAME transaction as the delete — the
/// action and its audit record cannot diverge, because nothing can commit one
/// without the other.
///
/// ## Why soft delete
///
/// Sync is a dirty-scoped full-state re-push with tombstoned soft-delete and no
/// outbox (D-4): a delete reaches other devices as `deletedAt` on a row that is
/// still there. A hard `DELETE` would remove it from Postgres and tell nobody —
/// every device already holding the topo would keep it forever, because a pull
/// sees an absence and an absence means nothing. A hard delete is not a
/// stronger delete here; it is one that does not propagate.
///
/// ## Why the photo bytes go too, and why the order is not stylistic
///
/// Same argument, and the same trap, as [TakedownService]: the shared-photo
/// SELECT policy is `is_wall_public("wallId")`, and `admin_delete_topo` sets
/// `wall_moderation.state` to `removed`, which makes it false. Enumerate after
/// the RPC and you always list nothing and always leave world-readable copies
/// of the imagery you were asked to remove. Reading first is the only order
/// that works.
class AdminDeleteService {
  const AdminDeleteService(this._ref);

  final Ref _ref;

  /// Deletes [wallId] and its whole subtree, whoever owns it, and removes its
  /// published photo bytes.
  ///
  /// The RPC's errors propagate (see the class doc); the byte removal never
  /// throws but its count is returned rather than swallowed, so the caller can
  /// say "deleted, but 2 of 3 images could not be removed" instead of a bare
  /// success.
  Future<AdminDeleteResult> deleteTopo({
    required String wallId,
    String? reason,
  }) async {
    final remote = _ref.read(moderationRemoteProvider);

    // BEFORE the RPC — see this class's doc. Not an optimisation.
    final objects = await remote.publishedPhotoObjects(wallId);

    final deletedAt = await remote.adminDeleteTopo(
      wallId: wallId,
      reason: reason,
    );

    final removed = await remote.removePublishedPhotoObjects(objects);

    // The RPC has committed server-side by this point, so the admin's own
    // device is now the one place still showing a topo the server already
    // deleted — `CommunityRepository.watchSharedTopos` is a local Drift
    // stream with no moderation awareness, and the admin's cached copy is a
    // FOREIGN row that the ordinary `softDeleteWall` guard would refuse to
    // touch. `softDeleteWallAsModerator` (see its doc) mirrors the tombstone
    // locally without that guard, safely, because it only copies what the
    // server already authorised. Swallowed the same way `_settle` swallows
    // below: the delete already succeeded, so a local-mirror failure here
    // must not turn a successful admin action into a reported one.
    try {
      await _ref
          .read(libraryCrudRepositoryProvider)
          .softDeleteWallAsModerator(wallId);
    } catch (_) {
      // Deliberately swallowed — see the comment above.
    }

    await _settle({wallId});
    return (
      deletedAt: deletedAt,
      photoObjects: originalPhotoRequestCount(objects),
      photoBytesRemoved: removed,
    );
  }

  /// Puts back one [deleteTopo] sweep.
  ///
  /// The moderation state stays `removed`: restoring the rows gives the owner
  /// their topo back, and putting it in front of the public again is a separate
  /// decision with a separate control (`review_topo(..., approve: true)`).
  ///
  /// Returns null when the topo was not deleted — a double tap, which is not an
  /// error and must not be reported as one.
  Future<int?> restoreTopo({required String wallId, String? reason}) async {
    final restoredAt = await _ref
        .read(moderationRemoteProvider)
        .adminRestoreTopo(wallId: wallId, reason: reason);
    await _settle({wallId});
    // The "Removed" admin tab (`adminDeletedToposProvider`) is built from the
    // audit log this RPC just added a row to, and unlike the local mirror it
    // has no other trigger to refresh on — invalidating it here is the only
    // thing that gets a just-restored topo off that list without waiting for
    // an unrelated screen visit.
    _ref.invalidate(adminDeletedToposProvider);
    return restoredAt;
  }

  /// Deletes any ascent, and the comments and likes hanging off it.
  Future<int?> deleteAscent({required String ascentId, String? reason}) async {
    final deletedAt = await _ref
        .read(moderationRemoteProvider)
        .adminDeleteAscent(ascentId: ascentId, reason: reason);
    await _settle(const {});
    return deletedAt;
  }

  /// Deletes any single comment, in either thread.
  Future<int?> deleteComment({
    required String commentId,
    String? reason,
  }) async {
    final deletedAt = await _ref
        .read(moderationRemoteProvider)
        .adminDeleteComment(commentId: commentId, reason: reason);
    await _settle(const {});
    return deletedAt;
  }

  /// Brings the local mirror in line with what the server now says.
  ///
  /// Two different jobs, and both are needed. The moderation refresh updates
  /// the banner tables; the PULL is what actually brings the tombstones down,
  /// because the deleted rows belong to someone else and nothing on this device
  /// can mark them deleted on its own — the repositories refuse to write a
  /// foreign row.
  ///
  /// Never throws. The risk is not the `syncOrchestratorProvider.notifier`
  /// read below — reading `.notifier` on a `NotifierProvider` hands back the
  /// notifier without running (or re-running) `build()`, so a build failure
  /// there could not propagate through this call even if one happened. The
  /// real risk is inside [refreshWallModeration]: it reads
  /// `moderationRepositoryProvider`, an ORDINARY `Provider`, whose `build()`
  /// failure DOES propagate through `.read()` — e.g. if `appDatabaseProvider`
  /// underneath it is unavailable. Either way, the delete has already
  /// committed server-side by the time this runs, so a failure here means a
  /// stale list for one refresh cycle, not a failed moderation action — and
  /// reporting it as an error would tell an admin their delete did not work
  /// when it did.
  Future<void> _settle(Set<String> wallIds) async {
    try {
      if (wallIds.isNotEmpty) await refreshWallModeration(_ref, wallIds);
      await _ref.read(syncOrchestratorProvider.notifier).pullNow();
    } catch (_) {
      // Deliberately swallowed — see this method's doc.
    }
  }
}

final adminDeleteServiceProvider = Provider<AdminDeleteService>(
  AdminDeleteService.new,
);

/// Pulls moderation state for [wallIds] and writes it to the local mirror.
///
/// Best-effort and never throws: [ModerationRemote.fetchWallModeration]
/// swallows network failures by contract, and a moderation banner that fails
/// to refresh must never be able to break the screen it decorates. Returns
/// the number of rows written, for tests and diagnostics.
///
/// Call this where the answer is about to be rendered — opening a topo,
/// refreshing the feed — rather than on a timer. Nothing here polls, matching
/// how `reachabilityProvider` is probed on demand rather than subscribed to.
Future<int> refreshWallModeration(Ref ref, Set<String> wallIds) =>
    pullWallModeration(
      remote: ref.read(moderationRemoteProvider),
      repository: ref.read(moderationRepositoryProvider),
      wallIds: wallIds,
    );

/// [refreshWallModeration] for a widget, which holds a [WidgetRef] rather than
/// a [Ref] — and which must not be able to take its screen down.
///
/// The try/catch covers the PROVIDER READS, not just the pull. That is the
/// part that actually throws: `moderationRemoteProvider` builds a
/// `SupabaseModerationRemote` from `supabaseClientProvider`, which raises
/// `'_instance._isInitialized'` if Supabase has not been initialised — during
/// early boot, after a failed init, and in every widget test that does not
/// stand up a fake client. A banner quietly declining to refresh is the
/// correct outcome in all three; a topo canvas that fails to open because a
/// decoration could not load is not.
Future<int> refreshWallModerationFrom(
  WidgetRef ref,
  Set<String> wallIds,
) async {
  try {
    return await pullWallModeration(
      remote: ref.read(moderationRemoteProvider),
      repository: ref.read(moderationRepositoryProvider),
      wallIds: wallIds,
    );
  } catch (_) {
    return 0;
  }
}

/// The collaborator-explicit half of [refreshWallModeration].
///
/// Split out so tests can drive the pull with a `ProviderContainer` (which is
/// not a [Ref]) and with hand-built fakes, rather than having to stand up a
/// widget tree just to obtain a `Ref`.
Future<int> pullWallModeration({
  required ModerationRemote remote,
  required ModerationRepository repository,
  required Set<String> wallIds,
}) async {
  // Short-circuits before touching the network: the common case on a fresh
  // library is an empty set, and PostgREST would otherwise be asked for an
  // empty `IN` list.
  if (wallIds.isEmpty) return 0;
  final rows = await remote.fetchWallModeration(wallIds);
  return repository.upsertFromRemote(rows);
}
