import 'package:supabase_flutter/supabase_flutter.dart';

/// Reads moderation state from the cloud.
///
/// Deliberately a SEPARATE seam from `SyncRemote` rather than another method
/// on it, for two reasons:
///
///  1. The sync engine must not know this data exists (COMMUNITY_PLAN.md
///     guardrail G-1). `SyncRemote` is the push/pull engine for the user's
///     OWN rows; moderation state is server-owned and travels one way only.
///     Putting a fetch on `SyncRemote` would put moderation one careless
///     `syncTableNames` edit away from being pushed back up.
///  2. `SyncRemote` has seven implementations across lib and test. A new
///     abstract member there is seven edits and seven fakes that have to
///     pretend to understand moderation. This seam has one implementation
///     and one fake.
///
/// There is NO write method here, and there is not meant to be one. Every
/// mutation goes through a `SECURITY DEFINER` RPC so the action and its
/// audit-log entry cannot diverge, and the server refuses direct writes
/// anyway — `public.wall_moderation` has a SELECT policy and no write policy
/// at all.
abstract class ModerationRemote {
  /// Moderation rows for [wallIds], as raw column maps.
  ///
  /// Returns only what RLS permits: a published topo's row is readable by
  /// anyone, a non-published one only by its owner or an admin. A wall whose
  /// row is simply absent from the result is NOT an error — it means "you
  /// may not see this one", which callers treat exactly like "no information",
  /// never like "not moderated".
  ///
  /// Never throws: any network or PostgREST failure resolves to an empty
  /// list, because a moderation banner failing to load must not be able to
  /// break the screen it decorates.
  Future<List<Map<String, dynamic>>> fetchWallModeration(Set<String> wallIds);
}

/// The real [ModerationRemote], backed by the anon/publishable Supabase
/// client — the same one the rest of the app uses. Nothing here needs
/// elevated access: RLS decides what comes back.
class SupabaseModerationRemote implements ModerationRemote {
  SupabaseModerationRemote(this._client);

  final SupabaseClient _client;

  /// Chunk size for the `IN` filter. PostgREST puts the id list in the query
  /// string, so an unbounded list eventually exceeds the URL length limit and
  /// fails as an opaque 414 rather than as anything diagnosable.
  static const int _chunkSize = 100;

  @override
  Future<List<Map<String, dynamic>>> fetchWallModeration(
    Set<String> wallIds,
  ) async {
    if (wallIds.isEmpty) return const [];
    final ids = wallIds.toList(growable: false);
    final rows = <Map<String, dynamic>>[];
    try {
      for (var i = 0; i < ids.length; i += _chunkSize) {
        final chunk = ids.sublist(
          i,
          i + _chunkSize > ids.length ? ids.length : i + _chunkSize,
        );
        final response = await _client
            .from('wall_moderation')
            .select()
            .inFilter('wallId', chunk);
        for (final row in response) {
          rows.add(Map<String, dynamic>.from(row));
        }
      }
    } catch (_) {
      // Best-effort by contract (see the abstract doc). A partial result from
      // an earlier chunk is still returned: knowing the state of some topos
      // beats knowing none, and the caller merges rather than replaces.
      return rows;
    }
    return rows;
  }
}
