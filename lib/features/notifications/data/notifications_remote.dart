import 'package:supabase_flutter/supabase_flutter.dart';

/// Reads and marks-read the signed-in user's notification inbox.
///
/// A separate seam from `SyncRemote`, for the same two reasons
/// `ModerationRemote` is (see that file's header): the sync engine must not
/// know this data exists, and a new abstract member on `SyncRemote` costs
/// seven implementations and seven fakes that would have to pretend to
/// understand notifications.
///
/// There is deliberately NO method here that creates a notification, and there
/// is no server-side door for one either — `public.notifications` has a SELECT
/// policy, no insert policy, and no write RPC. Every row is authored by a
/// SECURITY DEFINER trigger. If a "send a notification" method ever seems
/// necessary, the thing to add is a trigger, not a method: a client that can
/// author notifications can put a message in anybody's inbox.
abstract class NotificationsRemote {
  /// The caller's inbox, newest first, via the `my_notifications` RPC.
  ///
  /// Throws rather than swallowing — deliberately, and unlike the best-effort
  /// moderation reads. This screen's whole content is this call, so an empty
  /// list that actually meant "we could not ask" would read as "nothing has
  /// happened", which is the one conclusion it must never invite. The mirror
  /// underneath is what makes offline still work: see
  /// [NotificationsRepository.watchAll].
  Future<List<Map<String, dynamic>>> fetch({int limit});

  /// Marks [ids] read, or the caller's whole unread set when [ids] is null.
  /// Returns how many rows the server actually changed.
  Future<int> markRead({List<String>? ids});

  /// How many unread the SERVER holds.
  ///
  /// Best-effort — returns null on any failure, including signed-out. The
  /// badge falls back to the local mirror's count, which is the right answer
  /// offline and a stale-but-honest one otherwise. A badge is not worth an
  /// error dialog.
  Future<int?> unreadCount();
}

/// The real [NotificationsRemote], on the same anon/publishable client as the
/// rest of the app. Nothing here needs elevated access: the RPCs resolve
/// `auth.uid()` themselves and refuse a caller who has none.
class SupabaseNotificationsRemote implements NotificationsRemote {
  SupabaseNotificationsRemote(this._client);

  final SupabaseClient _client;

  @override
  Future<List<Map<String, dynamic>>> fetch({int limit = 50}) async {
    final rows = await _client.rpc<dynamic>(
      'my_notifications',
      params: {'limit_count': limit},
    );
    if (rows is! List) return const [];
    return [for (final row in rows) Map<String, dynamic>.from(row as Map)];
  }

  @override
  Future<int> markRead({List<String>? ids}) async {
    final result = await _client.rpc<dynamic>(
      'mark_notifications_read',
      params: {'ids': ids},
    );
    return switch (result) {
      final int v => v,
      final num v => v.toInt(),
      _ => 0,
    };
  }

  @override
  Future<int?> unreadCount() async {
    try {
      final result = await _client.rpc<dynamic>('unread_notification_count');
      return switch (result) {
        final int v => v,
        final num v => v.toInt(),
        _ => null,
      };
    } catch (_) {
      return null;
    }
  }
}
