import 'package:supabase_flutter/supabase_flutter.dart';

/// The cloud seam for topo version history (community editing phase 6a /
/// C-8).
///
/// A separate seam from [ModerationRemote] for the same reason that one is
/// separate from `SyncRemote`: versions are server-written and travel one way
/// only, and the sync engine must never learn they exist. There is no local
/// mirror either — unlike moderation state, history is not needed offline. It
/// is consulted deliberately, on a screen the user opened on purpose, and a
/// history that cannot load says so rather than showing a stale one.
abstract class TopoVersionsRemote {
  /// Recorded versions for [wallId], newest first.
  ///
  /// Throws rather than swallowing. This is the opposite choice from the
  /// moderation banner reads, and for the opposite reason: a banner that
  /// silently declines to render costs nothing, but a history list that
  /// renders empty on failure says "this topo has never changed", which is a
  /// claim, and a false one.
  Future<List<Map<String, dynamic>>> fetchVersions(
    String wallId, {
    int limit = 30,
  });

  /// Restores [versionId]. Admin-only, enforced server-side; returns how many
  /// routes the snapshot carried.
  ///
  /// The server snapshots the CURRENT state before overwriting it, so this is
  /// itself reversible — a revert to the wrong version is a mistake, not a
  /// disaster.
  Future<int> revert({required String wallId, required String versionId});
}

class SupabaseTopoVersionsRemote implements TopoVersionsRemote {
  SupabaseTopoVersionsRemote(this._client);

  final SupabaseClient _client;

  @override
  Future<List<Map<String, dynamic>>> fetchVersions(
    String wallId, {
    int limit = 30,
  }) async {
    final rows = await _client.rpc<dynamic>(
      'topo_version_list',
      params: {'wall_id': wallId, 'limit_count': limit},
    );
    if (rows is! List) return const [];
    return [for (final row in rows) Map<String, dynamic>.from(row as Map)];
  }

  @override
  Future<int> revert({
    required String wallId,
    required String versionId,
  }) async {
    final result = await _client.rpc<dynamic>(
      'revert_topo',
      params: {'wall_id': wallId, 'version_id': versionId},
    );
    return switch (result) {
      final int v => v,
      final num v => v.toInt(),
      _ => 0,
    };
  }
}
