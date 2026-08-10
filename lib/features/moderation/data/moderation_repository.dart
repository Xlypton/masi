import 'package:drift/drift.dart';


import '../../../core/db/app_database.dart' as db;
import '../domain/access_state.dart';
import '../domain/moderation_state.dart';

/// Local reads and pull-side writes over `WallModerationRows`, the on-device
/// mirror of the server's `public.wall_moderation`.
///
/// Every write here comes FROM the server. There is no method that originates
/// a moderation change locally, and adding one would be a bug: the client is
/// not the authority (COMMUNITY_PLAN.md G-1/G-2), and the server refuses
/// direct writes to that table regardless.
///
/// [recordWithdrawRequestedAt] is not an exception to that rule even though it
/// is not fed by a `fetchWallModeration` — read its own doc for why.
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

  /// Writes what the withdrawal RPCs just told us about [wallId]'s countdown —
  /// [at] for a started clock, `null` for a stopped one.
  ///
  /// Still a server-sourced write, so this class's "the client is not the
  /// authority" rule holds: the value is the RPC's own answer, taken from a call
  /// that has already COMMITTED server-side, not a local guess about what the
  /// server would say. It exists because `WithdrawalService` used to learn that
  /// answer and then throw it away, relying entirely on a follow-up
  /// `fetchWallModeration` to bring it back — and a failed follow-up left the
  /// mirror holding a timestamp the server had just cleared. That stale
  /// timestamp is not cosmetic: SEC-2 in `sync_service.dart` derives
  /// `shouldBeShared` from it, so the next push would compute a MATURED
  /// withdrawal for a topo the server had just put back and delete its
  /// published bytes.
  ///
  /// Scoped to an existing row (an `UPDATE`, never an insert): a wall with no
  /// mirrored row has no stale countdown to correct, and inventing one would
  /// mean inventing a `state` and an `updatedAt` this call does not know.
  ///
  /// `updatedAt` is deliberately NOT bumped. It is the server's own stamp, and
  /// leaving it alone keeps the next real pull authoritative over this partial,
  /// single-column correction.
  ///
  /// Returns the number of rows written (0 or 1), for tests and diagnostics.
  Future<int> recordWithdrawRequestedAt(String wallId, int? at) =>
      (_db.update(_db.wallModerationRows)
            ..where((t) => t.wallId.equals(wallId)))
          .write(
            db.WallModerationRowsCompanion(withdrawRequestedAt: Value(at)),
          );

  /// The effective access state for [wallId], after walking Wall → Sector →
  /// Area and taking the most restrictive level (community editing phase 2 /
  /// R-2).
  ///
  /// A raw [customSelect] rather than a Drift join because the three levels
  /// are LEFT joins whose columns all share names (`accessState` on each), and
  /// aliasing them explicitly here is clearer than unpicking a joined-row API.
  /// `readsFrom` is set to all three tables so the stream re-emits when a
  /// closure is set at ANY level — the whole point of inheritance is that a
  /// write on the Area repaints every topo beneath it.
  ///
  /// Resolution (most-restrictive-wins, ties to the most specific level) lives
  /// in [ResolvedAccess.resolve] rather than in SQL, so it is testable without
  /// a database and cannot drift from the enum's own severity ordering.
  Stream<ResolvedAccess> watchAccess(String wallId) {
    const sql = '''
      SELECT
        w.name             AS wall_name,
        w.access_state     AS wall_access_state,
        w.access_note      AS wall_access_note,
        s.name             AS sector_name,
        s.access_state     AS sector_access_state,
        s.access_note      AS sector_access_note,
        a.name             AS area_name,
        a.access_state     AS area_access_state,
        a.access_note      AS area_access_note
      FROM walls w
      LEFT JOIN sectors s ON s.id = w.sector_id
      LEFT JOIN areas   a ON a.id = s.area_id
      WHERE w.id = ?
    ''';
    return _db
        .customSelect(
          sql,
          variables: [Variable<String>(wallId)],
          readsFrom: {_db.walls, _db.sectors, _db.areas},
        )
        .watchSingleOrNull()
        .map((row) {
          if (row == null) return ResolvedAccess.none;
          return ResolvedAccess.resolve([
            // Most specific FIRST: ties resolve to the wall's own note.
            AccessLevel(
              state: AccessState.fromWire(
                row.readNullable<String>('wall_access_state'),
              ),
              note: row.readNullable<String>('wall_access_note'),
              sourceLabel: row.readNullable<String>('wall_name') ?? 'This topo',
            ),
            AccessLevel(
              state: AccessState.fromWire(
                row.readNullable<String>('sector_access_state'),
              ),
              note: row.readNullable<String>('sector_access_note'),
              sourceLabel: row.readNullable<String>('sector_name') ?? 'Sector',
            ),
            AccessLevel(
              state: AccessState.fromWire(
                row.readNullable<String>('area_access_state'),
              ),
              note: row.readNullable<String>('area_access_note'),
              sourceLabel: row.readNullable<String>('area_name') ?? 'Area',
            ),
          ]);
        });
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
