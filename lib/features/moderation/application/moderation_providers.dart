import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/app_database.dart' as db;
import '../../../core/db/database_provider.dart';
import '../../../core/config/supabase_providers.dart';
import '../data/moderation_remote.dart';
import '../data/moderation_repository.dart';
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
