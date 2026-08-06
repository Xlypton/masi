import 'package:supabase_flutter/supabase_flutter.dart';

/// Reads and writes community facts (community editing, phase 4 / R-1).
///
/// A separate seam from both `SyncRemote` and `ModerationRemote`, for the
/// reasons set out on each of those. In particular it is NOT on `SyncRemote`:
/// these rows are other people's statements about a topo, and the sync engine
/// is scoped to `ownerId = auth.uid()` rows it re-reads and re-pushes whole.
/// Handing it rows the client does not own would either be refused by RLS or
/// require the outbox decision D-4 exists to avoid.
///
/// Unlike `ModerationRemote` this seam DOES have write methods, and that is
/// the entire point of the phase: there is no approval queue between a climber
/// and a statement about the world. The server's only constraint is that you
/// write in your own name.
///
/// **Writes here are online-only and throw on failure.** There is no local
/// queue and there is deliberately not going to be one. A hazard report that
/// silently sat on the device for a week while somebody else climbed past the
/// loose block would be worse than an error message; the user needs to know
/// their warning did not land.
abstract class CommunityFactsRemote {
  /// Every fact attached to [wallIds] — hazards and verifications by wall,
  /// grade opinions by the routes those walls contain.
  ///
  /// Returns three raw lists keyed `hazards` / `verifications` / `opinions`.
  /// Never throws: a failure resolves to whatever was gathered before it,
  /// because a hazard banner failing to load must not break the screen it
  /// decorates. The caller merges rather than replaces, so a partial result
  /// degrades to stale-but-present rather than to blank.
  Future<Map<String, List<Map<String, dynamic>>>> fetchFacts(
    Set<String> wallIds,
    Set<String> routeIds,
  );

  /// States (or restates) the caller's opinion of what [routeId] goes at.
  /// Upserts on `(routeId, authorId)` — one opinion per person per route, so
  /// changing your mind replaces rather than stacks.
  Future<Map<String, dynamic>> upsertGradeOpinion({
    required String routeId,
    required String gradeSystem,
    required String gradeRaw,
    required double? gradeSortKey,
  });

  /// Withdraws the caller's own grade opinion.
  Future<void> deleteGradeOpinion(String id);

  /// Records "I was there, and the topo does (not) match the rock".
  /// Upserts on `(wallId, authorId)`.
  Future<Map<String, dynamic>> upsertVerification({
    required String wallId,
    required bool accurate,
    String? note,
  });

  /// Files a hazard report. [routeId] is null for a hazard about the whole
  /// topo rather than one line.
  Future<Map<String, dynamic>> reportHazard({
    required String wallId,
    String? routeId,
    required String severity,
    required String body,
  });

  /// Marks a hazard resolved, or reopens it.
  ///
  /// Goes through the `resolve_hazard` SECURITY DEFINER RPC rather than a
  /// direct UPDATE, because Postgres RLS is row-level only: there is no way to
  /// write a policy that lets the topo owner set `resolvedAt` while forbidding
  /// them `body`. The RPC touches exactly two columns, so the report survives
  /// its own resolution and stays readable. Same reasoning as guardrail G-1.
  ///
  /// Throws if the caller is neither the report's author, the topo's owner,
  /// nor an admin.
  Future<void> resolveHazard({required String id, required bool resolved});
}

/// The real [CommunityFactsRemote], backed by the anon/publishable Supabase
/// client. Nothing here needs elevated access: RLS decides what comes back and
/// what is allowed in.
class SupabaseCommunityFactsRemote implements CommunityFactsRemote {
  SupabaseCommunityFactsRemote(this._client);

  final SupabaseClient _client;

  /// Chunk size for `IN` filters. PostgREST puts the id list in the query
  /// string, so an unbounded list eventually exceeds the URL length limit and
  /// fails as an opaque 414 rather than as anything diagnosable.
  static const int _chunkSize = 100;

  String get _uid {
    final id = _client.auth.currentUser?.id;
    if (id == null) {
      throw StateError('Sign in to contribute to a topo.');
    }
    return id;
  }

  Future<void> _forEachChunk(
    List<String> ids,
    Future<void> Function(List<String> chunk) body,
  ) async {
    for (var i = 0; i < ids.length; i += _chunkSize) {
      await body(
        ids.sublist(i, i + _chunkSize > ids.length ? ids.length : i + _chunkSize),
      );
    }
  }

  @override
  Future<Map<String, List<Map<String, dynamic>>>> fetchFacts(
    Set<String> wallIds,
    Set<String> routeIds,
  ) async {
    final hazards = <Map<String, dynamic>>[];
    final verifications = <Map<String, dynamic>>[];
    final opinions = <Map<String, dynamic>>[];

    try {
      final walls = wallIds.toList(growable: false);
      await _forEachChunk(walls, (chunk) async {
        for (final row
            in await _client.from('topo_hazards').select().inFilter(
              'wallId',
              chunk,
            )) {
          hazards.add(Map<String, dynamic>.from(row));
        }
        for (final row
            in await _client.from('topo_verifications').select().inFilter(
              'wallId',
              chunk,
            )) {
          verifications.add(Map<String, dynamic>.from(row));
        }
      });

      await _forEachChunk(routeIds.toList(growable: false), (chunk) async {
        for (final row
            in await _client.from('route_grade_opinions').select().inFilter(
              'routeId',
              chunk,
            )) {
          opinions.add(Map<String, dynamic>.from(row));
        }
      });
    } catch (_) {
      // Best-effort by contract (see the abstract doc). Whatever arrived
      // before the failure is still returned: knowing the hazards on some
      // topos beats knowing none.
    }

    return {
      'hazards': hazards,
      'verifications': verifications,
      'opinions': opinions,
    };
  }

  @override
  Future<Map<String, dynamic>> upsertGradeOpinion({
    required String routeId,
    required String gradeSystem,
    required String gradeRaw,
    required double? gradeSortKey,
  }) async {
    final uid = _uid;
    final row = await _client
        .from('route_grade_opinions')
        .upsert({
          // The id is only used when this INSERTs; on conflict the existing
          // row's id is kept, which is what makes "change your mind" a replace
          // rather than a second opinion under a new key.
          'id': '$routeId:$uid',
          'routeId': routeId,
          'authorId': uid,
          'gradeSystem': gradeSystem,
          'gradeRaw': gradeRaw,
          'gradeSortKey': gradeSortKey,
          'createdAt': DateTime.now().millisecondsSinceEpoch,
        }, onConflict: 'routeId,authorId')
        .select()
        .single();
    return Map<String, dynamic>.from(row);
  }

  @override
  Future<void> deleteGradeOpinion(String id) async {
    await _client.from('route_grade_opinions').delete().eq('id', id);
  }

  @override
  Future<Map<String, dynamic>> upsertVerification({
    required String wallId,
    required bool accurate,
    String? note,
  }) async {
    final uid = _uid;
    final row = await _client
        .from('topo_verifications')
        .upsert({
          'id': '$wallId:$uid',
          'wallId': wallId,
          'authorId': uid,
          'accurate': accurate,
          'note': note,
          'createdAt': DateTime.now().millisecondsSinceEpoch,
        }, onConflict: 'wallId,authorId')
        .select()
        .single();
    return Map<String, dynamic>.from(row);
  }

  @override
  Future<Map<String, dynamic>> reportHazard({
    required String wallId,
    String? routeId,
    required String severity,
    required String body,
  }) async {
    final uid = _uid;
    // Hazards are NOT unique per person: one climber can legitimately report
    // two different loose blocks on the same wall, so this is a plain insert
    // with a fresh key rather than the upsert the other two use.
    final row = await _client
        .from('topo_hazards')
        .insert({
          'id': '$wallId:$uid:${DateTime.now().microsecondsSinceEpoch}',
          'wallId': wallId,
          'routeId': routeId,
          'authorId': uid,
          'severity': severity,
          'body': body,
          'createdAt': DateTime.now().millisecondsSinceEpoch,
        })
        .select()
        .single();
    return Map<String, dynamic>.from(row);
  }

  @override
  Future<void> resolveHazard({
    required String id,
    required bool resolved,
  }) async {
    await _client.rpc<dynamic>(
      'resolve_hazard',
      params: {'hazard': id, 'resolved': resolved},
    );
  }
}
