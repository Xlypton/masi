import 'package:drift/drift.dart';

import '../../../core/db/app_database.dart' as db;
import '../domain/app_notification.dart';

/// Local reads and mirror writes over [db.NotificationRows].
///
/// Reads come from the mirror, not from the network, so the inbox renders from
/// cold and offline like every other read in this local-first app — a climber
/// at a crag with no signal still sees what happened before they left. The
/// pull refreshes the mirror; it is not what the screen watches.
///
/// The write direction is server-first and has no local-first path, matching
/// the other mirrors (see `GradeOpinionRows` in `tables.dart`): marking read
/// goes to Supabase and is mirrored here only once the server has confirmed
/// it. There is deliberately no outbox (decision D-4) — a mark that fails is
/// simply not applied, and the next pull re-states the truth.
class NotificationsRepository {
  NotificationsRepository(this._db);

  final db.AppDatabase _db;

  /// The inbox for [recipientId], newest first.
  ///
  /// Scoped by recipient in the query and not merely by what the pull happened
  /// to write. Two accounts can share a device, and a stale row from the
  /// previous one must not appear in this one's inbox even for the frame
  /// before [clear] runs.
  Stream<List<AppNotification>> watchAll(String recipientId) {
    final query = _db.select(_db.notificationRows)
      ..where((t) => t.recipientId.equals(recipientId))
      ..orderBy([
        (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
      ]);
    return query.watch().map(
      (rows) => [for (final row in rows) ?_toNotification(row)],
    );
  }

  /// How many of [recipientId]'s notifications are unread.
  ///
  /// Read from the mirror rather than from the server, so the badge is correct
  /// offline and appears without a round trip on every screen that shows it.
  /// The server's own count is the authority and overrides this after a pull —
  /// see `unreadNotificationCountProvider`.
  Stream<int> watchUnreadCount(String recipientId) {
    final query = _db.select(_db.notificationRows)
      ..where((t) => t.recipientId.equals(recipientId) & t.readAt.isNull());
    return query.watch().map((rows) => rows.length);
  }

  /// Writes [rows] (raw `my_notifications` output) into the mirror.
  ///
  /// Upsert, not replace. The fetch is bounded (`limit_count`), so replacing
  /// wholesale would silently delete everything past the limit — the older
  /// half of a busy inbox would vanish on every refresh. Returns how many rows
  /// were written, for tests and diagnostics.
  ///
  /// A row missing an id or a timestamp is skipped rather than throwing: one
  /// unusable row from a future server version must not abort the import and
  /// leave the whole inbox empty.
  Future<int> upsertFromRemote(List<Map<String, dynamic>> rows) async {
    var written = 0;
    await _db.transaction(() async {
      for (final row in rows) {
        final id = row['id'];
        final recipientId = row['recipientId'];
        final kind = row['kind'];
        final createdAt = _asInt(row['createdAt']);
        if (id is! String || id.isEmpty) continue;
        if (recipientId is! String || recipientId.isEmpty) continue;
        if (kind is! String || kind.isEmpty) continue;
        if (createdAt == null) continue;
        await _db
            .into(_db.notificationRows)
            .insertOnConflictUpdate(
              db.NotificationRow(
                id: id,
                recipientId: recipientId,
                kind: kind,
                actorId: row['actorId'] as String?,
                wallId: row['wallId'] as String?,
                ascentId: row['ascentId'] as String?,
                commentId: row['commentId'] as String?,
                preview: row['preview'] as String?,
                createdAt: createdAt,
                readAt: _asInt(row['readAt']),
              ),
            );
        written++;
      }
    });
    return written;
  }

  /// Mirrors a server-confirmed mark-as-read.
  ///
  /// [ids] null means "everything unread for this recipient", matching the
  /// RPC. Only ever sets `readAt`, and only where it is currently null, so a
  /// re-mark leaves the original instant alone — "read at" stays the truth
  /// rather than drifting into "last tapped at". The same rule the RPC
  /// enforces server-side; kept here too so the mirror cannot disagree with it.
  Future<int> markReadLocally(
    String recipientId, {
    List<String>? ids,
    required int atMs,
  }) {
    final update = _db.update(_db.notificationRows)
      ..where((t) {
        final scope = t.recipientId.equals(recipientId) & t.readAt.isNull();
        return ids == null ? scope : scope & t.id.isIn(ids);
      });
    return update.write(db.NotificationRowsCompanion(readAt: Value(atMs)));
  }

  /// Drops every mirrored notification.
  ///
  /// Unwired today, matching `CommunityFactsRepository.clear` and
  /// `ModerationRepository`: nothing in this app clears local data on
  /// sign-out, because every read is scoped by `effectiveUidProvider` instead
  /// — which is why [watchAll] and [watchUnreadCount] filter on
  /// `recipientId` rather than trusting the mirror to hold one account's rows.
  /// Kept for the day that changes, and because a shared-device wipe is the
  /// one operation that must exist before it is needed.
  Future<void> clear() => _db.delete(_db.notificationRows).go();

  /// Never returns null today — the mirror's NOT NULL columns are exactly the
  /// two [AppNotification.fromRow] requires — but goes through the same parser
  /// as the remote rows on purpose, so the unknown-kind and missing-actor
  /// rules are written once and cannot diverge between the two paths.
  static AppNotification? _toNotification(db.NotificationRow row) =>
      AppNotification.fromRow({
        'id': row.id,
        'kind': row.kind,
        'actorId': row.actorId,
        'wallId': row.wallId,
        'ascentId': row.ascentId,
        'commentId': row.commentId,
        'preview': row.preview,
        'createdAt': row.createdAt,
        'readAt': row.readAt,
      });

  static int? _asInt(Object? value) => switch (value) {
    final int v => v,
    final num v => v.toInt(),
    final String v => int.tryParse(v),
    _ => null,
  };
}
