import 'package:supabase_flutter/supabase_flutter.dart';

/// Reduces raw `moderation_log` rows — `targetType = 'wall'`, `action` in
/// (`admin_delete`, `admin_restore`) — down to the wall ids whose MOST RECENT
/// such entry is a delete, i.e. still awaiting an `admin_restore_topo` call.
///
/// This is the whole basis for [SupabaseAdminDeletionLogRemote
/// .fetchAdminDeletedTopos]'s list: a wall an admin deleted and LATER
/// restored must not keep showing up asking to be restored again, and the
/// only way to know which is which is to look at the most recent of the two
/// entries a wall can have, not merely whether a delete entry exists at all.
///
/// Import-free and independently testable, like [publishedPhotoObjectPathsFor]
/// next to `SupabaseModerationRemote` in `moderation_remote.dart` — the
/// decision of which rows still need attention should not require a Supabase
/// client to verify.
///
/// A row with no usable `targetId` or `createdAt` is skipped rather than
/// aborting the whole reduction; one malformed log entry must not hide every
/// other wall's answer.
///
/// EQUAL timestamps resolve to the RESTORE, whatever order the rows arrived in.
/// `createdAt` is a millisecond epoch stamped by the RPC, so a delete and a
/// restore of the same wall inside one millisecond are representable — and with
/// a strict "newer wins" the winner would then depend purely on iteration order
/// of a PostgREST page, i.e. a restored topo could keep sitting in the "awaiting
/// restore" list forever with no way for an admin to clear it. Ties therefore
/// break towards the LESS destructive reading, the same fail-safe direction the
/// rest of this feature takes.
List<Map<String, dynamic>> currentlyAdminDeletedWalls(
  Iterable<Map<String, dynamic>> rows,
) {
  final latestByWall = <String, Map<String, dynamic>>{};
  for (final row in rows) {
    final id = row['targetId'];
    final createdAt = row['createdAt'];
    if (id is! String || id.isEmpty) continue;
    if (createdAt is! int) continue;
    final current = latestByWall[id];
    if (current == null) {
      latestByWall[id] = row;
      continue;
    }
    final currentAt = current['createdAt'] as int;
    if (currentAt < createdAt) {
      latestByWall[id] = row;
    } else if (currentAt == createdAt && row['action'] != 'admin_delete') {
      // Order-independent tie-break: a restore at the same instant wins over
      // the delete it undoes, whichever of the two this loop happened to see
      // first.
      latestByWall[id] = row;
    }
  }
  return [
    for (final row in latestByWall.values)
      if (row['action'] == 'admin_delete') row,
  ];
}

/// The cloud read seam for "which topos has an admin deleted outright, that
/// nobody has restored yet".
///
/// Deliberately a SEPARATE seam from [ModerationRemote]
/// (`moderation_remote.dart`) rather than another method on it, for the exact
/// reason that file's own header gives for splitting itself off from
/// `SyncRemote`: [ModerationRemote] already has more than a dozen
/// implementations across lib and test (every admin-surface widget test fakes
/// it), so adding a member there is a dozen edits and a dozen fakes that have
/// to pretend to understand an audit-log query they do not otherwise touch.
/// This seam has one implementation and one fake.
///
/// There is no write method here, on purpose — restoring a topo is still
/// [ModerationRemote.adminRestoreTopo]'s `admin_restore_topo` RPC, which
/// writes the very log row this seam later reads back. This seam only reads.
abstract class AdminDeletionLogRemote {
  /// Admin-deleted topos still awaiting a restore, newest deletion first.
  ///
  /// Reads `public.moderation_log` directly rather than needing a dedicated
  /// RPC: the table already carries an admin-only SELECT policy
  /// (`moderation_log_admin_select`, `public.is_admin()`), and every
  /// `admin_delete_topo`/`admin_restore_topo` call writes exactly the row
  /// this needs — `action`, `targetId` (the wall id), `reason` and
  /// `createdAt` — in the SAME transaction as the mutation, so the log can
  /// never diverge from what actually happened.
  ///
  /// Not best-effort: an empty list that actually means "we could not ask"
  /// reads as "nothing to restore", which is the wrong conclusion for a
  /// surface whose whole point is noticing a takedown that looks one-way
  /// only because nobody could see it needed a second look. Throws on
  /// failure instead.
  Future<List<Map<String, dynamic>>> fetchAdminDeletedTopos({int limit = 50});
}

/// The real [AdminDeletionLogRemote], backed by the anon/publishable
/// Supabase client — RLS decides what comes back, same as every other remote
/// in this feature.
class SupabaseAdminDeletionLogRemote implements AdminDeletionLogRemote {
  SupabaseAdminDeletionLogRemote(this._client);

  final SupabaseClient _client;

  @override
  Future<List<Map<String, dynamic>>> fetchAdminDeletedTopos({
    int limit = 50,
  }) async {
    final rows = await _client
        .from('moderation_log')
        .select()
        .eq('targetType', 'wall')
        .inFilter('action', const ['admin_delete', 'admin_restore'])
        .order('createdAt', ascending: false)
        // Rows, not walls: a wall can carry two entries (a delete and a
        // later restore), so this window has to be wide enough that a
        // wall's pair is not split across the cutoff. `moderation_log` is a
        // small admin-only audit table with no delete path, so a generous
        // multiple of the caller's own limit is cheap rather than unbounded.
        .limit(limit * 8);

    final mapped = [for (final row in rows) Map<String, dynamic>.from(row)];
    final current = currentlyAdminDeletedWalls(mapped)
      ..sort(
        (a, b) => (b['createdAt'] as int).compareTo(a['createdAt'] as int),
      );
    return current.take(limit).toList();
  }
}
