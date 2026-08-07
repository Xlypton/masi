import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/app_database.dart' as db;
import '../../../core/db/database_provider.dart';
import '../../../core/config/supabase_providers.dart';
import '../../account/application/auth_providers.dart';
import '../data/moderation_remote.dart';
import '../data/moderation_repository.dart';
import '../domain/abandoned_topo.dart';
import '../domain/access_state.dart';
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
/// unrelated sync. They let the RPC's own errors propagate — unlike the
/// best-effort reads, a withdrawal that silently failed would leave the owner
/// believing a ten-day clock is running when it is not.
class WithdrawalService {
  const WithdrawalService(this._ref);

  final Ref _ref;

  /// Starts the clock. Returns the epoch-ms instant it started from.
  Future<int?> request(String wallId) async {
    final at = await _ref.read(moderationRemoteProvider).requestWithdrawal(wallId);
    await refreshWallModeration(_ref, {wallId});
    return at;
  }

  /// Stops the clock. Returns the resulting state — `published` for a normal
  /// cancellation, `pending` when the window had already elapsed and this was
  /// therefore a re-submission.
  Future<String> cancel(String wallId) async {
    final state = await _ref.read(moderationRemoteProvider).cancelWithdrawal(wallId);
    await refreshWallModeration(_ref, {wallId});
    return state;
  }
}

final withdrawalServiceProvider = Provider<WithdrawalService>(
  WithdrawalService.new,
);

/// What a takedown actually accomplished.
///
/// [photoObjects] vs [photoBytesRemoved] are reported separately on purpose: a
/// takedown that changed the moderation state but removed none of the bytes is
/// the exact failure W-2 describes, and collapsing the two into a bool is how
/// it stayed invisible for so long.
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
    return (photoObjects: objects.length, photoBytesRemoved: removed);
  }
}

final takedownServiceProvider = Provider<TakedownService>(TakedownService.new);

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
