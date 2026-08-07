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

  /// Whether the signed-in user is an admin.
  ///
  /// A read of `admins`, whose SELECT policy is `"userId" = auth.uid()` — so
  /// this answers "am I one?" without exposing the list. `false` on any
  /// failure, including signed-out: the admin surface must fail closed.
  ///
  /// This is a UI hint ONLY. Every admin RPC re-checks membership server-side,
  /// so a client that lies to itself gains nothing.
  Future<bool> isAdmin();

  /// Pending submissions, oldest first, via the `moderation_queue` RPC.
  ///
  /// Throws if the caller is not an admin — deliberately, unlike the
  /// best-effort reads above. A queue that silently renders empty for an
  /// admin whose session has expired is worse than an error: it says "nothing
  /// to review" when the truth is "we could not ask".
  Future<List<Map<String, dynamic>>> fetchQueue({int limit});

  /// Approves or rejects a pending topo. Admin-only, enforced server-side.
  /// Returns the resulting state. [reason] is shown to the owner on rejection.
  Future<String> reviewTopo({
    required String wallId,
    required bool approve,
    String? reason,
  });

  /// Takes down an already-published topo. Admin-only. The content is
  /// retained, not destroyed (COMMUNITY_PLAN.md §3.3), so this is reversible.
  Future<void> removeTopo({required String wallId, String? reason});

  /// Starts the ten-day withdrawal clock on a published topo (C-3). Returns
  /// the epoch-ms instant the clock started from — which for a second call is
  /// the ORIGINAL one, not a fresh one: asking twice must not silently cost
  /// the owner ten more days.
  ///
  /// Owner-or-admin, enforced server-side. Throws if the topo is not
  /// published, because a client showing a countdown for something that was
  /// never public is worse than an error.
  Future<int?> requestWithdrawal(String wallId);

  /// Stops the clock, and returns the resulting state.
  ///
  /// Two outcomes, decided by the server rather than here: cancelling a
  /// running withdrawal returns `published` (nothing happened), while
  /// cancelling one whose ten days already elapsed is a RE-SUBMISSION and
  /// returns `pending`. The topo left public view; coming back goes through
  /// review again.
  Future<String> cancelWithdrawal(String wallId);
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

  @override
  Future<bool> isAdmin() async {
    try {
      final rows = await _client.from('admins').select('userId').limit(1);
      return rows.isNotEmpty;
    } catch (_) {
      // Signed out, offline, or RLS refused. All of them mean "do not show
      // the admin surface", and none of them is worth an error to a user who
      // was never an admin in the first place.
      return false;
    }
  }

  @override
  Future<List<Map<String, dynamic>>> fetchQueue({int limit = 50}) async {
    final rows = await _client.rpc<dynamic>(
      'moderation_queue',
      params: {'limit_count': limit},
    );
    if (rows is! List) return const [];
    return [for (final row in rows) Map<String, dynamic>.from(row as Map)];
  }

  @override
  Future<String> reviewTopo({
    required String wallId,
    required bool approve,
    String? reason,
  }) async {
    final result = await _client.rpc<dynamic>(
      'review_topo',
      params: {'wall_id': wallId, 'approve': approve, 'reason': reason},
    );
    return result is String ? result : (approve ? 'published' : 'rejected');
  }

  @override
  Future<void> removeTopo({required String wallId, String? reason}) async {
    await _client.rpc<dynamic>(
      'remove_topo',
      params: {'wall_id': wallId, 'reason': reason},
    );
  }

  @override
  Future<int?> requestWithdrawal(String wallId) async {
    final result = await _client.rpc<dynamic>(
      'request_withdrawal',
      params: {'wall_id': wallId},
    );
    return switch (result) {
      final int v => v,
      final num v => v.toInt(),
      final String v => int.tryParse(v),
      _ => null,
    };
  }

  @override
  Future<String> cancelWithdrawal(String wallId) async {
    final result = await _client.rpc<dynamic>(
      'cancel_withdrawal',
      params: {'wall_id': wallId},
    );
    // Falling back to `published` rather than to something alarming: the RPC
    // only ever returns from the happy path, and the common cancellation is
    // the one that leaves the topo exactly as public as it was.
    return result is String ? result : 'published';
  }
}
