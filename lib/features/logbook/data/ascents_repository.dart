import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/db/app_database.dart' as db;
import '../../../core/grades/grade_system.dart';

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
    this.visibility = 'private',
    this.authorName,
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

  /// `'private'` (default) or `'shared'` — Feature #12's public opt-in
  /// ascent logs. `'shared'` means this ascent is discoverable by every
  /// signed-in user via [AscentsRepository.watchSharedAscents]/the sync
  /// layer's `fetchSharedAscents`, regardless of whether its wall (topo) is
  /// itself shared. See [isShared].
  final String visibility;

  /// Free-text display name the owner chose to attach to this ascent (shown
  /// on a shared/public feed in lieu of exposing account info). `null` if
  /// unset.
  final String? authorName;
  final int createdAt;
  final int updatedAt;

  /// Convenience for `visibility == 'shared'`.
  bool get isShared => visibility == 'shared';

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
      other.visibility == visibility &&
      other.authorName == authorName &&
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
    visibility,
    authorName,
    createdAt,
    updatedAt,
  );

  @override
  String toString() =>
      'Ascent(id: $id, routeId: $routeId, wallId: $wallId, '
      'climbedAt: $climbedAt, style: $style, notes: $notes, '
      'gradeOpinion: $gradeOpinion, ownerId: $ownerId, '
      'visibility: $visibility, authorName: $authorName, '
      'createdAt: $createdAt, updatedAt: $updatedAt)';
}

/// Display-ready row for the cross-owner "public feed" of opt-in-`shared`
/// ascents (Feature #12): an [Ascent] with `visibility == 'shared'`, from
/// ANY owner, joined with its route's number/name/grade and its wall's
/// id/name — mirrors `LogbookEntry` (`logbook_providers.dart`'s personal,
/// own-scoped equivalent) in shape, but additionally carries [ownerId]/
/// [authorName] (meaningless for an own-scoped personal logbook, essential
/// for attributing a cross-owner feed row) and [wallId] (so the feed can
/// link back to the topo) plus [notes]/[gradeOpinion] (dropped from
/// `LogbookEntry` today, but worth carrying here since a feed reader has no
/// other way to see them).
class SharedAscentEntry {
  const SharedAscentEntry({
    required this.ascentId,
    this.ownerId,
    this.authorName,
    required this.climbedAt,
    required this.style,
    required this.wallId,
    required this.wallName,
    this.routeNumber,
    this.routeName,
    this.gradeLabel,
    this.gradeBand,
    this.gradeSortKey,
    this.notes,
    this.gradeOpinion,
    this.updatedAt = 0,
  });

  final String ascentId;

  /// The Supabase Auth uid that logged this ascent. `null` only in the
  /// theoretical case of a local, signed-out row somehow flipped to
  /// `'shared'` — every row this feed is meant to surface has round-tripped
  /// through cloud sync and carries its owner's uid.
  final String? ownerId;

  /// See [Ascent.authorName].
  final String? authorName;
  final DateTime climbedAt;
  final AscentStyle style;
  final String wallId;
  final String wallName;

  /// Null only if the route this ascent was logged against can no longer be
  /// joined (data-integrity edge case; the FK is enforced at insert time).
  final int? routeNumber;
  final String? routeName;
  final String? gradeLabel;
  final GradeBand? gradeBand;
  final double? gradeSortKey;
  final String? notes;
  final String? gradeOpinion;

  /// The ascent row's `updated_at` — **when this ascent entered the feed**.
  ///
  /// Not [climbedAt], which is when the CLIMB happened and can be backdated to
  /// any day the climber likes; an ascent logged today for a climb done last
  /// summer would never register as new. Sharing flips `visibility`, which is
  /// a local write, which bumps `updated_at`. See [SharedTopo.updatedAt] for
  /// the same reasoning, and the same trade-off, on the topo side.
  ///
  /// Defaults to `0` for the tests that construct an entry directly — those
  /// never exercise the Feed tab's unseen dot.
  final int updatedAt;

  @override
  bool operator ==(Object other) =>
      other is SharedAscentEntry &&
      other.ascentId == ascentId &&
      other.ownerId == ownerId &&
      other.authorName == authorName &&
      other.climbedAt == climbedAt &&
      other.style == style &&
      other.wallId == wallId &&
      other.wallName == wallName &&
      other.routeNumber == routeNumber &&
      other.routeName == routeName &&
      other.gradeLabel == gradeLabel &&
      other.gradeBand == gradeBand &&
      other.gradeSortKey == gradeSortKey &&
      other.notes == notes &&
      other.gradeOpinion == gradeOpinion;

  @override
  int get hashCode => Object.hash(
    ascentId,
    ownerId,
    authorName,
    climbedAt,
    style,
    wallId,
    wallName,
    routeNumber,
    routeName,
    gradeLabel,
    gradeBand,
    Object.hash(gradeSortKey, notes, gradeOpinion),
  );

  @override
  String toString() =>
      'SharedAscentEntry(ascentId: $ascentId, ownerId: $ownerId, '
      'authorName: $authorName, climbedAt: $climbedAt, style: $style, '
      'wallId: $wallId, wallName: $wallName, routeNumber: $routeNumber, '
      'routeName: $routeName, gradeLabel: $gradeLabel, '
      'gradeBand: $gradeBand, gradeSortKey: $gradeSortKey, notes: $notes, '
      'gradeOpinion: $gradeOpinion)';
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
///
/// [watchSharedAscents]/[sharedAscents] are the one deliberate exception:
/// Feature #12's public opt-in ascent feed reads every owner's rows with
/// `visibility == 'shared'`, with no `currentUid` scoping at all — see their
/// own doc comments.
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
  ///
  /// [shared] (default `false`, i.e. `'private'`) and [authorName] are
  /// Feature #12's public opt-in ascent-log fields, persisted straight to
  /// the `visibility`/`authorName` columns — see [Ascent.visibility]/
  /// [Ascent.authorName].
  Future<Ascent> logAscent({
    required String routeId,
    required String wallId,
    required DateTime climbedAt,
    required AscentStyle style,
    String? notes,
    String? gradeOpinion,
    bool shared = false,
    String? authorName,
  }) async {
    final now = nowMs();
    final id = _uuid.v4();
    final ownerId = currentUid();
    final visibility = shared ? 'shared' : 'private';
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
            visibility: Value(visibility),
            authorName: Value(authorName),
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
      visibility: visibility,
      authorName: authorName,
      createdAt: now,
      updatedAt: now,
    );
  }

  /// Updates the non-deleted ascent [id] in place: only the fields passed
  /// (non-null) are changed, `updatedAt` is bumped to `nowMs()`, and the row
  /// is marked `dirty`. `ownerId` and `createdAt` are never touched.
  ///
  /// A caller that wants to change a field to an *empty* value should pass
  /// an empty string (e.g. `notes: ''`) — passing `null` for [notes],
  /// [gradeOpinion], or [authorName] here means "leave unchanged", matching
  /// [climbedAt] and [style]'s "omit to leave unchanged" behavior (both of
  /// which are non-nullable columns, so there is no other way to express
  /// "no change" for them). [shared] follows the same "omit ==
  /// `null` == leave unchanged" convention — use
  /// [setAscentVisibility] instead if all you want is to flip visibility.
  Future<Ascent> updateAscent({
    required String id,
    DateTime? climbedAt,
    AscentStyle? style,
    String? notes,
    String? gradeOpinion,
    bool? shared,
    String? authorName,
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
        visibility: shared == null
            ? const Value.absent()
            : Value(shared ? 'shared' : 'private'),
        authorName: authorName == null
            ? const Value.absent()
            : Value(authorName),
      ),
    );
    final row = await (_db.select(
      _db.ascents,
    )..where((t) => t.id.equals(id))).getSingle();
    return _fromRow(row);
  }

  /// Flips the non-deleted ascent [id]'s `visibility` between `'private'`
  /// and `'shared'` (Feature #12, public opt-in ascent logs), bumping
  /// `updatedAt` to `nowMs()` and marking the row `dirty` — same mutation
  /// conventions as [updateAscent]/[softDeleteAscent]. `ownerId`/`createdAt`
  /// are never touched.
  Future<void> setAscentVisibility({
    required String id,
    required bool shared,
  }) async {
    final now = nowMs();
    await (_db.update(
      _db.ascents,
    )..where((t) => t.id.equals(id) & t.deletedAt.isNull())).write(
      db.AscentsCompanion(
        visibility: Value(shared ? 'shared' : 'private'),
        updatedAt: Value(now),
        dirty: const Value(true),
      ),
    );
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

  /// The raw-SQL join backing [watchSharedAscents]/[sharedAscents]: every
  /// non-deleted ascent (ANY owner — deliberately no `owner_id` predicate,
  /// unlike [_ownQuery]) with `visibility = 'shared'`, joined to its route's
  /// number/name/grade and its wall's name, newest `climbedAt` first with an
  /// `id DESC` tiebreak. Mirrors `logbookEntriesProvider`'s join shape
  /// (`logbook_providers.dart`) plus the extra owner/authorName/notes/
  /// gradeOpinion/wallId columns [SharedAscentEntry] carries.
  static const String _sharedAscentsSql = '''
      SELECT
        a.id AS ascent_id,
        a.owner_id AS owner_id,
        a.author_name AS author_name,
        a.climbed_at AS climbed_at,
        a.style AS ascent_style,
        a.notes AS notes,
        a.grade_opinion AS grade_opinion,
        a.wall_id AS wall_id,
        a.updated_at AS updated_at,
        r.number AS route_number,
        r.name AS route_name,
        r.grade_raw AS grade_raw,
        r.grade_sort_key AS grade_sort_key,
        w.name AS wall_name
      FROM ascents a
      LEFT JOIN routes r ON r.id = a.route_id
      LEFT JOIN walls w ON w.id = a.wall_id
      WHERE a.deleted_at IS NULL AND a.visibility = 'shared'
      ORDER BY a.climbed_at DESC, a.id DESC
      ''';

  /// Reactive, cross-owner feed of every non-deleted, opt-in-`shared` ascent
  /// (Feature #12) — the source for a PUBLIC feed of shared climbs, deliberately
  /// NOT scoped to `currentUid()` (unlike [watchLogbook]/[logbook]/
  /// [ascentsForRoute]): the whole point is to surface every user's shared
  /// ascents, so this query has no owner predicate at all.
  Stream<List<SharedAscentEntry>> watchSharedAscents() {
    return _db
        .customSelect(
          _sharedAscentsSql,
          readsFrom: {_db.ascents, _db.routes, _db.walls},
        )
        .watch()
        .map((rows) => rows.map(_sharedEntryFromRow).toList());
  }

  /// Non-reactive [watchSharedAscents].
  Future<List<SharedAscentEntry>> sharedAscents() async {
    final rows = await _db
        .customSelect(
          _sharedAscentsSql,
          readsFrom: {_db.ascents, _db.routes, _db.walls},
        )
        .get();
    return rows.map(_sharedEntryFromRow).toList();
  }

  SharedAscentEntry _sharedEntryFromRow(QueryRow row) {
    final gradeSortKey = row.readNullable<double>('grade_sort_key');
    return SharedAscentEntry(
      ascentId: row.read<String>('ascent_id'),
      ownerId: row.readNullable<String>('owner_id'),
      authorName: row.readNullable<String>('author_name'),
      climbedAt: DateTime.fromMillisecondsSinceEpoch(
        row.read<int>('climbed_at'),
        isUtc: true,
      ),
      style: AscentStyle.fromDbString(row.read<String>('ascent_style')),
      wallId: row.read<String>('wall_id'),
      wallName: row.readNullable<String>('wall_name') ?? 'Wall',
      routeNumber: row.readNullable<int>('route_number'),
      routeName: row.readNullable<String>('route_name'),
      gradeLabel: row.readNullable<String>('grade_raw'),
      gradeBand: gradeSortKey == null ? null : bandForSortKey(gradeSortKey),
      gradeSortKey: gradeSortKey,
      notes: row.readNullable<String>('notes'),
      gradeOpinion: row.readNullable<String>('grade_opinion'),
      updatedAt: row.read<int>('updated_at'),
    );
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
    visibility: row.visibility,
    authorName: row.authorName,
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
