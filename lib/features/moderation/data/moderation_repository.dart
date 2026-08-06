
import '../../../core/db/app_database.dart' as db;
import '../domain/moderation_state.dart';

/// Local reads and pull-side writes over `WallModerationRows`, the on-device
/// mirror of the server's `public.wall_moderation`.
///
/// Every write here comes FROM the server. There is no method that originates
/// a moderation change locally, and adding one would be a bug: the client is
/// not the authority (COMMUNITY_PLAN.md G-1/G-2), and the server refuses
/// direct writes to that table regardless.
class ModerationRepository {
  ModerationRepository(this._db);

  final db.AppDatabase _db;

  /// Reactive moderation state for [wallId].
  ///
  /// Emits [ModerationState.draft] when no row is known — which covers both
  /// "this topo has never been submitted" and "the server did not tell us,
  /// because we are not allowed to know". Collapsing those two into the least
  /// public state is the fail-closed direction: the alternative would render
  /// a topo as approved on the strength of missing information.
  Stream<ModerationState> watchState(String wallId) {
    final query = _db.select(_db.wallModerationRows)
      ..where((t) => t.wallId.equals(wallId));
    return query
        .watchSingleOrNull()
        .map((row) => ModerationState.fromWire(row?.state));
  }

  /// The full local moderation row for [wallId], or null if none is known —
  /// for callers that need the rejection reason or the withdrawal countdown
  /// rather than just the state.
  Stream<db.WallModerationRow?> watchRow(String wallId) {
    final query = _db.select(_db.wallModerationRows)
      ..where((t) => t.wallId.equals(wallId));
    return query.watchSingleOrNull();
  }

  /// Replaces the local mirror for exactly the walls present in [rows].
  ///
  /// Upsert rather than delete-then-insert, and scoped to the ids actually
  /// returned rather than wholesale: a fetch only ever covers the walls the
  /// caller asked about, so clearing anything else would discard state for
  /// topos that were simply not in this batch. A malformed row (missing
  /// `wallId` or `state`) is skipped rather than throwing — one bad row from
  /// a future server version must not abort the whole import, the same
  /// discipline `filterValidSyncRows` applies on the sync path.
  Future<int> upsertFromRemote(List<Map<String, dynamic>> rows) async {
    if (rows.isEmpty) return 0;
    var written = 0;
    await _db.transaction(() async {
      for (final row in rows) {
        final wallId = row['wallId'];
        final state = row['state'];
        if (wallId is! String || wallId.isEmpty) continue;
        if (state is! String || state.isEmpty) continue;
        await _db
            .into(_db.wallModerationRows)
            .insertOnConflictUpdate(
              db.WallModerationRow(
                wallId: wallId,
                state: state,
                submittedAt: _asInt(row['submittedAt']),
                reviewedAt: _asInt(row['reviewedAt']),
                reviewerId: row['reviewerId'] as String?,
                rejectionReason: row['rejectionReason'] as String?,
                withdrawRequestedAt: _asInt(row['withdrawRequestedAt']),
                updatedAt: _asInt(row['updatedAt']) ?? 0,
              ),
            );
        written++;
      }
    });
    return written;
  }

  /// Drops every locally-mirrored row. Called on sign-out, so a second
  /// account on the same device never sees the first account's view of what
  /// was pending or rejected.
  Future<void> clear() => _db.delete(_db.wallModerationRows).go();

  /// PostgREST returns `bigint` as an `int`, but a JSON round trip through a
  /// fake or a future server change could hand back a `num`/`String`. Coerce
  /// defensively rather than letting an `as int` cast throw mid-import.
  static int? _asInt(Object? value) => switch (value) {
    final int v => v,
    final num v => v.toInt(),
    final String v => int.tryParse(v),
    _ => null,
  };
}
