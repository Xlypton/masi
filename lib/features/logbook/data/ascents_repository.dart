import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/db/app_database.dart' as db;

/// The manner in which a route was climbed, persisted as the enum's [name]
/// (via [toDbString]/[fromDbString]) in the `Ascents.style` TEXT column.
enum AscentStyle {
  onsight,
  flash,
  redpoint,
  repeat,
  attempt;

  /// The exact string stored in the `style` column.
  String toDbString() => name;

  /// Parses a stored `style` value back into an [AscentStyle]. Throws
  /// [ArgumentError] if [value] doesn't match a known style (a corrupt row
  /// or a future style added to the DB by a newer app version that this
  /// build doesn't know about).
  static AscentStyle fromDbString(String value) {
    for (final style in AscentStyle.values) {
      if (style.name == value) return style;
    }
    throw ArgumentError('Unknown AscentStyle db value: $value');
  }
}

/// Immutable read model for a non-deleted `Ascents` row — a personal logbook
/// entry recording that the signed-in (or local, signed-out) user climbed
/// [routeId] on [wallId].
///
/// [createdAt]/[updatedAt] are ms-epoch timestamps (matching the rest of
/// this codebase's domain refs, e.g. `TopoRef.createdAt` in
/// `library_crud_repository.dart`), while [climbedAt] — the user-entered
/// date the climb happened — is a real [DateTime] since it is edited/
/// displayed as a date, not compared against `nowMs()` plumbing.
class Ascent {
  const Ascent({
    required this.id,
    required this.routeId,
    required this.wallId,
    required this.climbedAt,
    required this.style,
    this.notes,
    this.gradeOpinion,
    this.ownerId,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String routeId;
  final String wallId;
  final DateTime climbedAt;
  final AscentStyle style;
  final String? notes;
  final String? gradeOpinion;
  final String? ownerId;
  final int createdAt;
  final int updatedAt;

  @override
  bool operator ==(Object other) =>
      other is Ascent &&
      other.id == id &&
      other.routeId == routeId &&
      other.wallId == wallId &&
      other.climbedAt == climbedAt &&
      other.style == style &&
      other.notes == notes &&
      other.gradeOpinion == gradeOpinion &&
      other.ownerId == ownerId &&
      other.createdAt == createdAt &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(
    id,
    routeId,
    wallId,
    climbedAt,
    style,
    notes,
    gradeOpinion,
    ownerId,
    createdAt,
    updatedAt,
  );

  @override
  String toString() =>
      'Ascent(id: $id, routeId: $routeId, wallId: $wallId, '
      'climbedAt: $climbedAt, style: $style, notes: $notes, '
      'gradeOpinion: $gradeOpinion, ownerId: $ownerId, '
      'createdAt: $createdAt, updatedAt: $updatedAt)';
}

/// CRUD (+ personal-logbook reads) over the `Ascents` table.
///
/// Mirrors the ownership/soft-delete/dirty conventions established by
/// `LibraryCrudRepository`: rows are stamped with `ownerId` from the
/// injected [currentUid] seam at create time (never changed afterwards),
/// soft-deleted via `deletedAt` (never physically removed, so a future sync
/// pass can still see the tombstone), and every write marks `dirty: true` so
/// a future sync push knows to pick the row up.
///
/// "Own" scoping (used by [ascentsForRoute], [logbook], [watchLogbook]) means
/// `ownerId == currentUid()` when signed in, or `ownerId IS NULL` — i.e. the
/// local, unattributed rows created while signed-out — when [currentUid]
/// returns `null`. This keeps a signed-out user's logbook showing exactly
/// the ascents they logged locally, and a signed-in user's logbook scoped to
/// just their own rows once ownership is established.
class AscentsRepository {
  AscentsRepository(this._db, {required this.nowMs, this.currentUid = _noUid});

  final db.AppDatabase _db;
  final int Function() nowMs;

  /// The Supabase Auth uid of the signed-in user (or `null` if signed out),
  /// read lazily at each INSERT/query to stamp/scope by `ownerId`. Defaults
  /// to always-`null` so callers that don't pass this get signed-out
  /// behavior.
  final String? Function() currentUid;

  static String? _noUid() => null;

  static const _uuid = Uuid();

  /// Logs a new ascent, stamping `ownerId` from [currentUid], marking the
  /// row `dirty`, and setting `createdAt == updatedAt == nowMs()`.
  Future<Ascent> logAscent({
    required String routeId,
    required String wallId,
    required DateTime climbedAt,
    required AscentStyle style,
    String? notes,
    String? gradeOpinion,
  }) async {
    final now = nowMs();
    final id = _uuid.v4();
    final ownerId = currentUid();
    await _db
        .into(_db.ascents)
        .insert(
          db.AscentsCompanion.insert(
            id: id,
            createdAt: now,
            updatedAt: now,
            dirty: const Value(true),
            ownerId: Value(ownerId),
            routeId: routeId,
            wallId: wallId,
            climbedAt: climbedAt.millisecondsSinceEpoch,
            style: style.toDbString(),
            notes: Value(notes),
            gradeOpinion: Value(gradeOpinion),
          ),
        );
    return Ascent(
      id: id,
      routeId: routeId,
      wallId: wallId,
      // Round-tripped through the same ms-epoch + isUtc:true reconstruction
      // as `_fromRow` (rather than echoing the caller's `climbedAt` object
      // as-is), so a freshly-logged Ascent compares `==` to what a
      // subsequent `logbook()`/`ascentsForRoute()` read of the same row
      // would return regardless of whether the caller passed a local or a
      // UTC DateTime — `DateTime.==` considers the `isUtc` flag, not just
      // the instant, so without this normalization two DateTimes at the
      // exact same moment could compare unequal.
      climbedAt: DateTime.fromMillisecondsSinceEpoch(
        climbedAt.millisecondsSinceEpoch,
        isUtc: true,
      ),
      style: style,
      notes: notes,
      gradeOpinion: gradeOpinion,
      ownerId: ownerId,
      createdAt: now,
      updatedAt: now,
    );
  }

  /// Updates the non-deleted ascent [id] in place: only the fields passed
  /// (non-null) are changed, `updatedAt` is bumped to `nowMs()`, and the row
  /// is marked `dirty`. `ownerId` and `createdAt` are never touched.
  ///
  /// A caller that wants to change a field to an *empty* value should pass
  /// an empty string (e.g. `notes: ''`) — passing `null` for [notes] or
  /// [gradeOpinion] here means "leave unchanged", matching [climbedAt] and
  /// [style]'s "omit to leave unchanged" behavior (both of which are
  /// non-nullable columns, so there is no other way to express "no change"
  /// for them).
  Future<Ascent> updateAscent({
    required String id,
    DateTime? climbedAt,
    AscentStyle? style,
    String? notes,
    String? gradeOpinion,
  }) async {
    final now = nowMs();
    await (_db.update(
      _db.ascents,
    )..where((t) => t.id.equals(id) & t.deletedAt.isNull())).write(
      db.AscentsCompanion(
        updatedAt: Value(now),
        dirty: const Value(true),
        climbedAt: climbedAt == null
            ? const Value.absent()
            : Value(climbedAt.millisecondsSinceEpoch),
        style: style == null
            ? const Value.absent()
            : Value(style.toDbString()),
        notes: notes == null ? const Value.absent() : Value(notes),
        gradeOpinion: gradeOpinion == null
            ? const Value.absent()
            : Value(gradeOpinion),
      ),
    );
    final row = await (_db.select(
      _db.ascents,
    )..where((t) => t.id.equals(id))).getSingle();
    return _fromRow(row);
  }

  /// Soft-deletes the ascent [id] by setting `deletedAt`/`updatedAt` to
  /// `nowMs()` and marking it `dirty`. The row remains physically present
  /// (tombstone) for a future sync pass.
  Future<void> softDeleteAscent(String id) async {
    final now = nowMs();
    await (_db.update(
      _db.ascents,
    )..where((t) => t.id.equals(id) & t.deletedAt.isNull())).write(
      db.AscentsCompanion(
        deletedAt: Value(now),
        updatedAt: Value(now),
        dirty: const Value(true),
      ),
    );
  }

  /// Own, non-deleted ascents logged against [routeId], newest [Ascent.climbedAt]
  /// first.
  Future<List<Ascent>> ascentsForRoute(String routeId) async {
    final rows = await _ownQuery(routeId: routeId).get();
    return rows.map(_fromRow).toList();
  }

  /// Every own, non-deleted ascent across all routes/walls, newest
  /// [Ascent.climbedAt] first. Backs the personal Logbook screen.
  Future<List<Ascent>> logbook() async {
    final rows = await _ownQuery().get();
    return rows.map(_fromRow).toList();
  }

  /// Reactive [logbook].
  Stream<List<Ascent>> watchLogbook() {
    return _ownQuery().watch().map((rows) => rows.map(_fromRow).toList());
  }

  Ascent _fromRow(db.Ascent row) => Ascent(
    id: row.id,
    routeId: row.routeId,
    wallId: row.wallId,
    // isUtc:true so this always compares `==` to the same-instant value
    // `logAscent` hands back (see its doc comment) regardless of the
    // timezone the caller originally passed in.
    climbedAt: DateTime.fromMillisecondsSinceEpoch(
      row.climbedAt,
      isUtc: true,
    ),
    style: AscentStyle.fromDbString(row.style),
    notes: row.notes,
    gradeOpinion: row.gradeOpinion,
    ownerId: row.ownerId,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  );

  /// Builds the shared "own, non-deleted, newest-climbedAt-first" query used
  /// by [ascentsForRoute]/[logbook]/[watchLogbook], optionally narrowed to a
  /// single [routeId]. "Own" means `ownerId == currentUid()` when signed in,
  /// or `ownerId IS NULL` (the local unowned rows) when [currentUid] returns
  /// `null` — see the class doc. A secondary `id DESC` tiebreak makes
  /// ordering deterministic when two ascents share the exact same
  /// `climbedAt`, matching the tiebreak convention used by
  /// `LibraryCrudRepository.watchTopos`.
  SimpleSelectStatement<db.$AscentsTable, db.Ascent> _ownQuery({
    String? routeId,
  }) {
    final uid = currentUid();
    return _db.select(_db.ascents)
      ..where((t) {
        var predicate =
            t.deletedAt.isNull() &
            (uid == null ? t.ownerId.isNull() : t.ownerId.equals(uid));
        if (routeId != null) {
          predicate = predicate & t.routeId.equals(routeId);
        }
        return predicate;
      })
      ..orderBy([
        (t) => OrderingTerm(expression: t.climbedAt, mode: OrderingMode.desc),
        (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc),
      ]);
  }
}
