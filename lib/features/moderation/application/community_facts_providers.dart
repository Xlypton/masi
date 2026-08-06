import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/supabase_providers.dart';
import '../../../core/db/database_provider.dart';
import '../../../core/grades/grade_system.dart';
import '../../account/application/auth_providers.dart';
import '../data/community_facts_remote.dart';
import '../data/community_facts_repository.dart';
import '../domain/community_facts.dart';

/// The cloud seam for community facts. Overridden in tests with an in-memory
/// fake — never the real one, which would touch the network.
final communityFactsRemoteProvider = Provider<CommunityFactsRemote>(
  (ref) => SupabaseCommunityFactsRemote(ref.watch(supabaseClientProvider)),
);

/// Local reads over the on-device mirror.
final communityFactsRepositoryProvider = Provider<CommunityFactsRepository>(
  (ref) => CommunityFactsRepository(ref.watch(appDatabaseProvider)),
);

/// Every hazard reported on one topo, most serious unresolved first.
///
/// `autoDispose` + `family` for the same reason the moderation providers are:
/// a topo the user has navigated away from should not keep a Drift
/// subscription open for the life of the app.
final wallHazardsProvider = StreamProvider.autoDispose
    .family<List<HazardReport>, String>(
      (ref, wallId) =>
          ref.watch(communityFactsRepositoryProvider).watchHazards(wallId),
    );

/// The "anything I should know before I get on this?" summary for one topo.
final wallHazardSummaryProvider = StreamProvider.autoDispose
    .family<HazardSummary, String>(
      (ref, wallId) => ref
          .watch(communityFactsRepositoryProvider)
          .watchHazardSummary(wallId),
    );

/// Community confidence that a topo matches the rock.
final wallVerificationSummaryProvider = StreamProvider.autoDispose
    .family<VerificationSummary, String>(
      (ref, wallId) => ref
          .watch(communityFactsRepositoryProvider)
          .watchVerificationSummary(wallId),
    );

/// Who owns one topo — for deciding whether to offer a Resolve control on a
/// hazard. A UI hint only; the server re-checks.
final wallOwnerProvider = StreamProvider.autoDispose.family<String?, String>(
  (ref, wallId) =>
      ref.watch(communityFactsRepositoryProvider).watchWallOwner(wallId),
);

/// Identifies a route plus the author's own grade, so the consensus can be
/// rendered against it. A value type because Riverpod families key on
/// equality, and a bare record would rebuild the provider on every widget
/// build.
class ConsensusRequest {
  const ConsensusRequest({required this.routeId, this.authorSortKey});

  final String routeId;
  final double? authorSortKey;

  @override
  bool operator ==(Object other) =>
      other is ConsensusRequest &&
      other.routeId == routeId &&
      other.authorSortKey == authorSortKey;

  @override
  int get hashCode => Object.hash(routeId, authorSortKey);
}

/// What the community reckons a route goes at, beside the author's grade.
final routeGradeConsensusProvider = StreamProvider.autoDispose
    .family<GradeConsensus, ConsensusRequest>(
      (ref, request) => ref
          .watch(communityFactsRepositoryProvider)
          .watchConsensus(
            request.routeId,
            authorSortKey: request.authorSortKey,
          ),
    );

/// Every grade opinion on one route — for the detail list, where
/// [routeGradeConsensusProvider] only gives the aggregate.
final routeGradeOpinionsProvider = StreamProvider.autoDispose
    .family<List<GradeOpinion>, String>(
      (ref, routeId) =>
          ref.watch(communityFactsRepositoryProvider).watchOpinions(routeId),
    );

/// Writes community facts, then mirrors the server's answer locally.
///
/// A plain class rather than a `Notifier`: none of these has any state of its
/// own to hold — the state lives in Drift, and the stream providers above
/// re-emit on their own once the mirror is written.
///
/// Every method here throws on failure and none of them queues. That is the
/// deliberate consequence of having no outbox (decision D-4): a hazard report
/// that silently sat on the device while somebody climbed past the loose block
/// would be worse than an error message.
class CommunityFactsService {
  const CommunityFactsService({
    required CommunityFactsRemote remote,
    required CommunityFactsRepository repository,
  }) : this._(remote, repository);

  const CommunityFactsService._(this._remote, this._repository);

  final CommunityFactsRemote _remote;
  final CommunityFactsRepository _repository;

  /// States (or restates) the caller's opinion of what a route goes at.
  ///
  /// Rejects a grade that is not on [system]'s ladder rather than sending it:
  /// an opinion the server stores but no client can place on the shared scale
  /// is invisible to every consensus computation, which is a silent failure
  /// rather than a loud one.
  Future<void> stateGrade({
    required String routeId,
    required GradeSystem system,
    required String raw,
  }) async {
    if (!isValidGrade(system, raw)) {
      throw ArgumentError.value(raw, 'raw', 'Not a valid ${system.name} grade');
    }
    final row = await _remote.upsertGradeOpinion(
      routeId: routeId,
      gradeSystem: system.name,
      gradeRaw: normalizeGrade(system, raw),
      gradeSortKey: gradeSortKey(system, raw),
    );
    await _repository.mirrorOpinion(row);
  }

  /// Withdraws the caller's own grade opinion.
  Future<void> withdrawGrade(String opinionId) async {
    await _remote.deleteGradeOpinion(opinionId);
    await _repository.dropOpinion(opinionId);
  }

  /// Records "I was there, and the topo does (not) match the rock".
  Future<void> verify({
    required String wallId,
    required bool accurate,
    String? note,
  }) async {
    final row = await _remote.upsertVerification(
      wallId: wallId,
      accurate: accurate,
      note: note,
    );
    await _repository.mirrorVerification(row);
  }

  /// Files a hazard report. [routeId] is null for a hazard about the whole
  /// topo — the approach, the descent, the belay — rather than one line.
  Future<void> reportHazard({
    required String wallId,
    String? routeId,
    required HazardSeverity severity,
    required String body,
  }) async {
    final trimmed = body.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(body, 'body', 'A hazard needs a description');
    }
    final row = await _remote.reportHazard(
      wallId: wallId,
      routeId: routeId,
      severity: severity.wire,
      body: trimmed,
    );
    await _repository.mirrorHazard(row);
  }

  /// Marks a hazard resolved, or reopens it.
  ///
  /// Note what this is NOT: a delete. The topo owner can say a hazard has been
  /// dealt with, and that statement is recorded against their name, but they
  /// cannot make the report disappear (C-12). The server enforces it — the
  /// `topo_hazards` DELETE policy names the report's author and admins, and
  /// pointedly not the topo's owner.
  Future<void> resolveHazard({
    required String hazardId,
    required String wallId,
    required bool resolved,
  }) async {
    await _remote.resolveHazard(id: hazardId, resolved: resolved);
    // Re-pull the wall rather than patching the row locally: `resolvedAt` is
    // stamped by the SERVER clock inside the RPC, so guessing it here would
    // put a client-clock timestamp in the mirror that the next pull silently
    // corrects — a small lie that makes "who resolved this, and when" harder
    // to trust than it needs to be. [wallId] is required for exactly this
    // reason; without it there would be nothing to pull and the mirror would
    // sit stale until some unrelated refresh happened by.
    await pullCommunityFacts(
      remote: _remote,
      repository: _repository,
      wallIds: {wallId},
    );
  }
}

final communityFactsServiceProvider = Provider<CommunityFactsService>(
  (ref) => CommunityFactsService(
    remote: ref.watch(communityFactsRemoteProvider),
    repository: ref.watch(communityFactsRepositoryProvider),
  ),
);

/// Pulls community facts for [wallIds]/[routeIds] into the local mirror.
///
/// Best-effort and never throws: `fetchFacts` swallows network failures by
/// contract, and a hazard banner that fails to refresh must not break the
/// screen it decorates. Returns the number of rows written.
///
/// Call this where the answer is about to be rendered — opening a topo,
/// refreshing the feed — rather than on a timer, matching how
/// `reachabilityProvider` is probed on demand rather than subscribed to.
Future<int> refreshCommunityFacts(
  Ref ref, {
  required Set<String> wallIds,
  Set<String> routeIds = const {},
}) => pullCommunityFacts(
  remote: ref.read(communityFactsRemoteProvider),
  repository: ref.read(communityFactsRepositoryProvider),
  wallIds: wallIds,
  routeIds: routeIds,
);

/// The collaborator-explicit half of [refreshCommunityFacts].
///
/// Split out so tests can drive the pull with hand-built fakes rather than
/// standing up a widget tree just to obtain a [Ref] — the same split
/// `pullWallModeration` makes.
Future<int> pullCommunityFacts({
  required CommunityFactsRemote remote,
  required CommunityFactsRepository repository,
  required Set<String> wallIds,
  Set<String> routeIds = const {},
}) async {
  // Short-circuits before touching the network: the common case on a fresh
  // library is an empty set, and PostgREST would otherwise be asked for an
  // empty `IN` list.
  if (wallIds.isEmpty && routeIds.isEmpty) return 0;
  final facts = await remote.fetchFacts(wallIds, routeIds);
  return repository.upsertFromRemote(facts);
}

/// Whether the signed-in user has already stated an opinion on a route, so the
/// UI can offer "change your grade" rather than a second, stacking control.
final myGradeOpinionProvider = StreamProvider.autoDispose
    .family<GradeOpinion?, String>((ref, routeId) {
      final uid = ref.watch(effectiveUidProvider);
      return ref
          .watch(communityFactsRepositoryProvider)
          .watchOpinions(routeId)
          .map(
            (opinions) =>
                uid == null
                ? null
                : opinions.where((o) => o.authorId == uid).firstOrNull,
          );
    });
