import 'package:drift/drift.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../../../core/db/app_database.dart' as db;
import '../../../core/grades/grade_system.dart';
import '../../topo/data/photo_files.dart';
import '../domain/library_refs.dart';

// Split out of this god-file (pure refactor, zero behavior change): the
// read-model/domain classes (AreaRef, SectorRef, WallRef, TopoRef,
// LocatedRouteRef, LocatedSectorRef, LocatedAreaRef) moved to
// `../domain/library_refs.dart`, matching the topo/ar feature's
// data/domain split. Re-exported here so every existing importer of this
// file (the router, providers, screens, and this feature's own tests)
// keeps resolving with no edit required on their end.
export '../domain/library_refs.dart';

/// Parses a `group_concat(DISTINCT r.grade_sort_key)` column value (e.g.
/// `'0.0,7.5,13.0'`) into a sorted `List<double>`, silently skipping any
/// malformed token (defensive against locale/precision anomalies -- in
/// practice SQLite always renders a REAL with a `.`-decimal, non-locale
/// form). Returns an empty list for `null`/empty (a wall with no live,
/// graded routes). See [TopoRef.routeGradeKeys].
List<double> _parseGradeKeys(String? raw) {
  if (raw == null || raw.isEmpty) return const [];
  final keys =
      raw
          .split(',')
          .map((token) => double.tryParse(token.trim()))
          .whereType<double>()
          .toList()
        ..sort();
  return keys;
}

/// Sentinel default value for [LibraryCrudRepository.watchTopos]'s optional
/// `ownerUid` parameter — lets that method distinguish "caller omitted the
/// argument" (fall back to invoking `currentUid`) from "caller explicitly
/// passed `null`" (a genuinely signed-out scope, used as-is), which a plain
/// `= null` default parameter value can't tell apart. See that method's doc.
/// A marker string that is never a real Supabase Auth uid (a v4 UUID), so
/// it can't collide with a legitimate `ownerUid` argument.
const _unsetOwnerUid = '__unset_owner_uid__';

/// Why an `_ownOrUnowned`-guarded mutation refused to report success — see
/// [LibraryWriteLostException].
enum LibraryWriteLostReason {
  /// The write ran with NO uid while this device DOES have a known local
  /// session ([LibraryCrudRepository.hasKnownSession] is `true`), so the
  /// ownership predicate collapsed to `ownerId IS NULL` and could not match
  /// the caller's own owner-stamped rows. Audit item L4 (2026-07-30): this
  /// used to update 0 rows and report success — a rename/move/GPS-stamp/
  /// delete silently discarded.
  ownerIdentityUnknown,

  /// The target row is present, live and own-or-unowned under the CURRENT
  /// uid, yet the UPDATE still matched 0 rows — an invariant violation (e.g.
  /// ownership changed underneath the statement). Never swallowed.
  unexpectedZeroRows,
}

/// Thrown by a guarded [LibraryCrudRepository] mutation that matched **no
/// rows** for a reason that is NOT one of the two documented no-ops (target
/// absent or soft-deleted; target genuinely foreign-owned under a known
/// uid).
///
/// Exists because those UPDATEs previously discarded their affected-row
/// count: `.write(...)` returns the number of rows it touched and nothing
/// read it, so "I could not tell whose row this is" was indistinguishable
/// from "done". Callers surface this as a user-visible failure (see
/// `crud_list_scaffold.dart`'s `_runGuarded` and `topos_row.dart`'s).
class LibraryWriteLostException implements Exception {
  const LibraryWriteLostException({
    required this.operation,
    required this.rowId,
    required this.reason,
  });

  /// The repository method that failed, e.g. `'renameWall'` — for logs.
  final String operation;

  /// The primary key the mutation targeted.
  final String rowId;

  final LibraryWriteLostReason reason;

  @override
  String toString() =>
      'LibraryWriteLostException($operation, row $rowId, ${reason.name}): '
      'the write matched 0 rows and must not be reported as success';
}

/// Ownership verdict for one guarded-mutation target, resolved by
/// [LibraryCrudRepository._classifyGuardTarget].
enum _GuardOutcome {
  /// No such row, or it is already soft-deleted — a documented silent no-op.
  absent,

  /// Live and owned by a DIFFERENT, known uid — the deliberate Hole-B
  /// rejection, also a documented silent no-op.
  notOwned,

  /// Live and own-or-unowned: the mutation SHOULD have matched it.
  writable,

  /// Live and owner-stamped, but this device has no uid to compare against
  /// while it does have a known local session — ownership is unknowable, so
  /// neither "yours" nor "theirs" may be asserted. Audit item L4.
  identityUnknown,
}

/// CRUD + cascading soft-delete for the Area -> Sector -> Wall library
/// hierarchy (and the Photos/Routes hanging off a Wall).
///
/// Soft-delete semantics: deleting a node sets `deletedAt` on the node
/// itself AND every non-deleted descendant in its subtree (siblings and
/// ancestors are left untouched). Rows are never physically removed here,
/// so a future sync layer can still see tombstones. All cascades run inside
/// a single [db.AppDatabase.transaction] so a crash mid-cascade can't leave
/// a subtree half soft-deleted.
class LibraryCrudRepository {
  LibraryCrudRepository(
    this._db, {
    required this.nowMs,
    PhotoFiles? photoFiles,
    this.currentUid = _noUid,
    this.hasKnownSession = _noSession,
  }) : _photoFiles = photoFiles ?? PhotoFiles();

  final db.AppDatabase _db;
  final int Function() nowMs;

  /// The Supabase Auth uid of the signed-in user (or `null` if signed out),
  /// read lazily at each INSERT to stamp the new row's `ownerId`. Defaults
  /// to always-`null` so existing constructors/tests that don't pass this
  /// keep their pre-sync-pivot signed-out behavior unchanged.
  final String? Function() currentUid;

  static String? _noUid() => null;

  /// Whether this device has a KNOWN local session — wired from
  /// `hasKnownLocalSessionProvider` (spec §1c: live-session uid, else the
  /// persisted `lastKnownUid`). Read only to DISAMBIGUATE a `null`
  /// [currentUid]:
  ///
  ///  * `currentUid() == null && !hasKnownSession()` — a device nobody has
  ///    ever signed in on. `ownerId IS NULL` is then the honest predicate and
  ///    an owner-stamped row genuinely is somebody else's: silent no-op,
  ///    exactly as before.
  ///  * `currentUid() == null && hasKnownSession()` — L4. We had an identity
  ///    and lost it; `ownerId IS NULL` is a LIE and the row may well be ours.
  ///    The mutation must fail loudly instead of updating 0 rows and
  ///    returning normally.
  ///
  /// Defaults to always-`false` so every existing constructor/test keeps its
  /// current behaviour unchanged.
  final bool Function() hasKnownSession;

  static bool _noSession() => false;

  /// Write-time own-or-unowned guard (Hole B, adversarial-review
  /// 2026-07-21): every wall/topo mutation reachable from the Topos home
  /// (rename, soft-delete, coordinates, publish/unpublish, move) must
  /// require this in its UPDATE's WHERE, not just `id` + `deletedAt`.
  /// Without it, a foreign-owned wall that ever leaked into a local read
  /// (e.g. a synced-down shared topo, or a stale-uid stream — see
  /// [watchTopos]'s Hole-A doc) would still be fully editable/deletable.
  ///
  /// Same null-collapses-to-IS-NULL shape as [watchTopos]'s SQL predicate:
  /// when [currentUid] is `null` (signed out), this reduces to exactly
  /// `ownerId IS NULL` (a foreign row can never match); a legitimately
  /// unowned row (`ownerId IS NULL`) is always writable regardless of who,
  /// if anyone, is signed in.
  Expression<bool> _ownOrUnowned(TextColumn ownerId) {
    final uid = currentUid();
    return uid == null
        ? ownerId.isNull()
        : (ownerId.isNull() | ownerId.equals(uid));
  }

  /// Classifies one guarded-mutation target with a single ownership-FREE
  /// re-read, run only when the guarded statement affected 0 rows (or, for
  /// the cascade entry points, before the cascade starts). Reads `ownerId` +
  /// `deletedAt` by primary key — one indexed row, no join.
  Future<_GuardOutcome> _classifyGuardTarget({
    required TableInfo<Table, dynamic> table,
    required TextColumn idColumn,
    required TextColumn ownerColumn,
    required IntColumn deletedAtColumn,
    required String id,
  }) async {
    final query = _db.selectOnly(table)
      ..addColumns([ownerColumn, deletedAtColumn])
      ..where(idColumn.equals(id))
      ..limit(1);
    final row = await query.getSingleOrNull();
    if (row == null) return _GuardOutcome.absent;
    if (row.read(deletedAtColumn) != null) return _GuardOutcome.absent;

    final owner = row.read(ownerColumn);
    final uid = currentUid();
    if (uid == null) {
      // An unowned row matches `ownerId IS NULL` regardless of who we are,
      // so it is never ambiguous.
      if (owner == null) return _GuardOutcome.writable;
      return hasKnownSession()
          ? _GuardOutcome.identityUnknown
          : _GuardOutcome.notOwned;
    }
    return (owner == null || owner == uid)
        ? _GuardOutcome.writable
        : _GuardOutcome.notOwned;
  }

  /// Awaits [write] — an already-issued `_ownOrUnowned`-guarded UPDATE — and
  /// VERIFIES its affected-row count instead of discarding it. A 0-row result
  /// stays silent only for the two documented no-ops ([_GuardOutcome.absent],
  /// [_GuardOutcome.notOwned]); anything else throws
  /// [LibraryWriteLostException].
  ///
  /// Every guarded single-row mutation routes through this ONE helper rather
  /// than growing its own ad-hoc row-count check, so the "when is 0 rows OK"
  /// policy lives in exactly one place.
  Future<void> _guardedWrite({
    required String operation,
    required String id,
    required Future<int> write,
    required TableInfo<Table, dynamic> table,
    required TextColumn idColumn,
    required TextColumn ownerColumn,
    required IntColumn deletedAtColumn,
  }) async {
    final updated = await write;
    if (updated > 0) return;
    final outcome = await _classifyGuardTarget(
      table: table,
      idColumn: idColumn,
      ownerColumn: ownerColumn,
      deletedAtColumn: deletedAtColumn,
      id: id,
    );
    switch (outcome) {
      case _GuardOutcome.absent:
      case _GuardOutcome.notOwned:
        return;
      case _GuardOutcome.identityUnknown:
        throw LibraryWriteLostException(
          operation: operation,
          rowId: id,
          reason: LibraryWriteLostReason.ownerIdentityUnknown,
        );
      case _GuardOutcome.writable:
        throw LibraryWriteLostException(
          operation: operation,
          rowId: id,
          reason: LibraryWriteLostReason.unexpectedZeroRows,
        );
    }
  }

  /// Check-then-act half of the write-time ownership guard, for mutations
  /// that cascade beyond a single row (see [softDeleteArea]/
  /// [softDeleteSector]/[softDeleteWall]/[_setWallVisibility], whose inner
  /// per-row updates key off the parent id alone and so cannot carry the
  /// ownership predicate themselves).
  ///
  /// Replaces the three `_isOwnOrUnownedX` bool probes: `false` for the two
  /// documented silent no-ops (absent/soft-deleted target, or a genuinely
  /// foreign row under a known uid), `true` for an own-or-unowned target,
  /// and a [LibraryWriteLostException] when ownership is UNKNOWABLE (L4) —
  /// bailing quietly there is exactly the silent-write-loss bug.
  ///
  /// Called inside the caller's [db.AppDatabase.transaction], so a throw
  /// rolls the whole cascade back rather than leaving a subtree half
  /// soft-deleted.
  Future<bool> _guardedCascadeAllowed({
    required String operation,
    required String id,
    required TableInfo<Table, dynamic> table,
    required TextColumn idColumn,
    required TextColumn ownerColumn,
    required IntColumn deletedAtColumn,
  }) async {
    final outcome = await _classifyGuardTarget(
      table: table,
      idColumn: idColumn,
      ownerColumn: ownerColumn,
      deletedAtColumn: deletedAtColumn,
      id: id,
    );
    switch (outcome) {
      case _GuardOutcome.absent:
      case _GuardOutcome.notOwned:
        return false;
      case _GuardOutcome.identityUnknown:
        throw LibraryWriteLostException(
          operation: operation,
          rowId: id,
          reason: LibraryWriteLostReason.ownerIdentityUnknown,
        );
      case _GuardOutcome.writable:
        return true;
    }
  }

  /// Owns the on-disk lifecycle of attached photo files (copies a picked
  /// file into the app-documents `photos/` dir and, on load, relocates any
  /// legacy picker-cache path in). Injectable so tests can point it at a
  /// temp directory without a `path_provider` platform fake; defaults to the
  /// real app-documents-backed [PhotoFiles].
  final PhotoFiles _photoFiles;

  static const _uuid = Uuid();

  // ---------------------------------------------------------------------
  // Areas
  // ---------------------------------------------------------------------

  Future<AreaRef> createArea(String name, {String? description}) {
    _rejectReservedName(name);
    return _insertArea(name, description: description);
  }

  /// Unvalidated insert shared by [createArea] and [_ensureDefaultAreaId] —
  /// the latter must be able to create the hidden `__default__` sentinel
  /// itself, which [_rejectReservedName] would otherwise block.
  Future<AreaRef> _insertArea(String name, {String? description}) async {
    final now = nowMs();
    final id = _uuid.v4();
    await _db
        .into(_db.areas)
        .insert(
          db.AreasCompanion.insert(
            id: id,
            createdAt: now,
            updatedAt: now,
            dirty: const Value(true),
            name: name,
            description: Value(description),
            ownerId: Value(currentUid()),
          ),
        );
    return AreaRef(id: id, name: name, description: description);
  }

  Future<void> renameArea(String id, String name) async {
    _rejectReservedName(name);
    final now = nowMs();
    await _guardedWrite(
      operation: 'renameArea',
      id: id,
      table: _db.areas,
      idColumn: _db.areas.id,
      ownerColumn: _db.areas.ownerId,
      deletedAtColumn: _db.areas.deletedAt,
      write: (_db.update(_db.areas)..where(
            (t) =>
                t.id.equals(id) &
                t.deletedAt.isNull() &
                _ownOrUnowned(t.ownerId),
          ))
          .write(
            db.AreasCompanion(
              name: Value(name),
              updatedAt: Value(now),
              dirty: const Value(true),
            ),
          ),
    );
  }

  Future<List<AreaRef>> listAreas() async {
    final rows = await _areaQuery().get();
    return rows.map(_areaRefFromRow).toList();
  }

  Stream<List<AreaRef>> watchAreas() {
    return _areaQuery().watch().map(
      (rows) => rows.map(_areaRefFromRow).toList(),
    );
  }

  Future<void> softDeleteArea(String id) {
    return _db.transaction(() async {
      // Hole B guard (Area/Sector follow-up, adversarial-review 2026-07-21):
      // bail before the cascade even starts on a FOREIGN-owned area — the
      // per-row selects/updates inside the cascade key off `areaId` alone,
      // so a check-then-act existence guard up front, mirroring
      // [softDeleteWall]'s, is what actually protects the whole subtree.
      if (!await _guardedCascadeAllowed(
        operation: 'softDeleteArea',
        id: id,
        table: _db.areas,
        idColumn: _db.areas.id,
        ownerColumn: _db.areas.ownerId,
        deletedAtColumn: _db.areas.deletedAt,
      )) {
        return;
      }
      await _cascadeSoftDeleteAreaSubtree(id, nowMs());
    });
  }

  /// Non-deleted, non-default Areas usable as a MOVE destination for
  /// [moveSector] (see `sectors_screen.dart`'s destination-area picker):
  /// owned by [uid], or unowned (`ownerId == null`, e.g. created offline/
  /// signed-out).
  ///
  /// Deliberately excludes any Area owned by a DIFFERENT uid — a "foreign"
  /// Area pulled in locally from discovering someone else's shared topo
  /// (see `community_repository.dart`). Moving one of this device's own
  /// Sectors under a foreign Area would create a parent reference that
  /// never gets pushed back up for the foreign owner to see (this device
  /// only ever pushes rows it itself owns), leaving a dangling reference on
  /// their other devices.
  Future<List<AreaRef>> listOwnAreas(String? uid) async {
    final rows =
        await (_db.select(_db.areas)
              ..where(
                (t) =>
                    t.deletedAt.isNull() &
                    t.name.equals(_defaultAreaName).not() &
                    (uid == null
                        ? t.ownerId.isNull()
                        : (t.ownerId.isNull() | t.ownerId.equals(uid))),
              )
              ..orderBy([
                (t) => OrderingTerm(expression: t.name),
                (t) => OrderingTerm(expression: t.createdAt),
              ]))
            .get();
    return rows.map(_areaRefFromRow).toList();
  }

  // ---------------------------------------------------------------------
  // Sectors
  // ---------------------------------------------------------------------

  Future<SectorRef> createSector(String areaId, String name) {
    _rejectReservedName(name);
    return _insertSector(areaId, name);
  }

  /// Unvalidated insert shared by [createSector] and
  /// [_ensureDefaultSectorId] — see [_insertArea]'s identical rationale.
  Future<SectorRef> _insertSector(String areaId, String name) async {
    final now = nowMs();
    final id = _uuid.v4();
    final sortOrder = await _nextSortOrder(
      table: _db.sectors,
      sortOrderColumn: _db.sectors.sortOrder,
      scope: _db.sectors.areaId.equals(areaId),
    );
    await _db
        .into(_db.sectors)
        .insert(
          db.SectorsCompanion.insert(
            id: id,
            createdAt: now,
            updatedAt: now,
            dirty: const Value(true),
            areaId: areaId,
            name: name,
            sortOrder: sortOrder,
            ownerId: Value(currentUid()),
          ),
        );
    return SectorRef(id: id, areaId: areaId, name: name, sortOrder: sortOrder);
  }

  Future<void> renameSector(String id, String name) async {
    _rejectReservedName(name);
    final now = nowMs();
    await _guardedWrite(
      operation: 'renameSector',
      id: id,
      table: _db.sectors,
      idColumn: _db.sectors.id,
      ownerColumn: _db.sectors.ownerId,
      deletedAtColumn: _db.sectors.deletedAt,
      write: (_db.update(_db.sectors)..where(
            (t) =>
                t.id.equals(id) &
                t.deletedAt.isNull() &
                _ownOrUnowned(t.ownerId),
          ))
          .write(
            db.SectorsCompanion(
              name: Value(name),
              updatedAt: Value(now),
              dirty: const Value(true),
            ),
          ),
    );
  }

  Future<List<SectorRef>> listSectors(String areaId) async {
    final rows = await _sectorQuery(areaId).get();
    return rows.map(_sectorRefFromRow).toList();
  }

  Stream<List<SectorRef>> watchSectors(String areaId) {
    return _sectorQuery(
      areaId,
    ).watch().map((rows) => rows.map(_sectorRefFromRow).toList());
  }

  Future<void> softDeleteSector(String id) {
    return _db.transaction(() async {
      // Hole B guard, same rationale as [softDeleteArea]'s.
      if (!await _guardedCascadeAllowed(
        operation: 'softDeleteSector',
        id: id,
        table: _db.sectors,
        idColumn: _db.sectors.id,
        ownerColumn: _db.sectors.ownerId,
        deletedAtColumn: _db.sectors.deletedAt,
      )) {
        return;
      }
      await _cascadeSoftDeleteSectorSubtree(id, nowMs());
    });
  }

  /// Non-deleted, non-default Sectors, across ALL areas (unlike
  /// [listSectors], which is scoped to a single area), usable as a MOVE
  /// destination for [moveWall] (see `topos_screen.dart`'s destination-
  /// sector picker). Same own-or-unowned ownership filter as [listOwnAreas],
  /// and for the same dangling-foreign-parent reason — see that doc.
  Future<List<SectorRef>> listOwnSectors(String? uid) async {
    final rows =
        await (_db.select(_db.sectors)
              ..where(
                (t) =>
                    t.deletedAt.isNull() &
                    t.name.equals(_defaultSectorName).not() &
                    (uid == null
                        ? t.ownerId.isNull()
                        : (t.ownerId.isNull() | t.ownerId.equals(uid))),
              )
              ..orderBy([
                (t) => OrderingTerm(expression: t.areaId),
                (t) => OrderingTerm(expression: t.sortOrder),
                (t) => OrderingTerm(expression: t.createdAt),
              ]))
            .get();
    return rows.map(_sectorRefFromRow).toList();
  }

  // ---------------------------------------------------------------------
  // Walls
  // ---------------------------------------------------------------------

  Future<WallRef> createWall(String sectorId, String name) async {
    final now = nowMs();
    final id = _uuid.v4();
    final sortOrder = await _nextSortOrder(
      table: _db.walls,
      sortOrderColumn: _db.walls.sortOrder,
      scope: _db.walls.sectorId.equals(sectorId),
    );
    await _db
        .into(_db.walls)
        .insert(
          db.WallsCompanion.insert(
            id: id,
            createdAt: now,
            updatedAt: now,
            dirty: const Value(true),
            sectorId: sectorId,
            name: name,
            sortOrder: sortOrder,
            ownerId: Value(currentUid()),
            // `visibility` left at its column default ('private').
          ),
        );
    return WallRef(
      id: id,
      sectorId: sectorId,
      name: name,
      sortOrder: sortOrder,
    );
  }

  Future<void> renameWall(String id, String name) async {
    final now = nowMs();
    await _guardedWrite(
      operation: 'renameWall',
      id: id,
      table: _db.walls,
      idColumn: _db.walls.id,
      ownerColumn: _db.walls.ownerId,
      deletedAtColumn: _db.walls.deletedAt,
      write: (_db.update(_db.walls)..where(
            (t) =>
                t.id.equals(id) &
                t.deletedAt.isNull() &
                _ownOrUnowned(t.ownerId),
          ))
          .write(
            db.WallsCompanion(
              name: Value(name),
              updatedAt: Value(now),
              dirty: const Value(true),
            ),
          ),
    );
  }

  Future<List<WallRef>> listWalls(String sectorId) async {
    final rows = await _wallQuery(sectorId).get();
    return rows.map(_wallRefFromRow).toList();
  }

  Stream<List<WallRef>> watchWalls(String sectorId) {
    return _wallQuery(
      sectorId,
    ).watch().map((rows) => rows.map(_wallRefFromRow).toList());
  }

  Future<void> softDeleteWall(String id) {
    return _db.transaction(() async {
      // Hole B guard: bail before the cascade even starts on a
      // FOREIGN-owned wall — the per-row updates below key off `wallId`
      // alone, with no ownership check of their own, so a check-then-act
      // existence guard up front is what actually protects them.
      if (!await _guardedCascadeAllowed(
        operation: 'softDeleteWall',
        id: id,
        table: _db.walls,
        idColumn: _db.walls.id,
        ownerColumn: _db.walls.ownerId,
        deletedAtColumn: _db.walls.deletedAt,
      )) {
        return;
      }
      await _cascadeSoftDeleteWallSubtree(id, nowMs());
    });
  }

  /// Publishes [wallId] to Community: flips its [db.Wall.visibility] to
  /// `'shared'` and marks the wall itself plus every non-deleted [db.Photo]
  /// and [db.Route] on it `dirty:true` with a freshly bumped `updatedAt`, so
  /// a future sync push picks up the whole newly-visible subtree together
  /// (not just the wall row). Runs in one [db.AppDatabase.transaction], same
  /// shape as [_cascadeSoftDeleteWallSubtree] but deliberately never touches
  /// `deletedAt` — this is a visibility flip, not a delete.
  Future<void> publishTopo(String wallId) {
    return _db.transaction(() => _setWallVisibility(wallId, 'shared'));
  }

  /// Reverts [wallId] to private (`visibility = 'private'`), bumping the
  /// same dirty/updatedAt subtree as [publishTopo] so a future sync push
  /// also picks up the un-sharing.
  Future<void> unpublishTopo(String wallId) {
    return _db.transaction(() => _setWallVisibility(wallId, 'private'));
  }

  /// Records [latitude]/[longitude] as [wallId]'s GPS coordinates and marks
  /// the wall dirty for sync, bumping `updatedAt` — the same wall-row update
  /// shape [_setWallVisibility] and [renameWall] use (every push-worthy write
  /// in this class now bumps `updatedAt` and sets `dirty` together, §1e).
  ///
  /// Called automatically after a fresh photo pick that carries EXIF GPS
  /// (see `core/location/photo_gps.dart`'s `extractGpsFromImageBytes`, wired
  /// in from `topos_screen.dart`'s `_handleNewTopo` and
  /// `topo_canvas_screen.dart`'s `captureWallGpsFromPhoto`) — never called
  /// directly by any UI as of this feature.
  Future<void> setWallCoordinates(
    String wallId,
    double latitude,
    double longitude,
  ) async {
    final now = nowMs();
    await _guardedWrite(
      operation: 'setWallCoordinates',
      id: wallId,
      table: _db.walls,
      idColumn: _db.walls.id,
      ownerColumn: _db.walls.ownerId,
      deletedAtColumn: _db.walls.deletedAt,
      write: (_db.update(_db.walls)..where(
            (t) =>
                t.id.equals(wallId) &
                t.deletedAt.isNull() &
                _ownOrUnowned(t.ownerId),
          ))
          .write(
            db.WallsCompanion(
              latitude: Value(latitude),
              longitude: Value(longitude),
              updatedAt: Value(now),
              dirty: const Value(true),
            ),
          ),
    );
  }

  /// Re-parents [wallId] to [newSectorId]: updates its `sectorId`,
  /// recomputes `sortOrder` via [_nextSortOrder] scoped to [newSectorId] so
  /// the wall appends at the end of the destination sector's siblings
  /// (avoiding a collision with a destination sibling's existing
  /// `sortOrder`), and marks the wall dirty with a bumped `updatedAt` — the
  /// same wall-row update shape [setWallCoordinates]/[_setWallVisibility]
  /// use. Guarded to non-deleted walls (`deletedAt.isNull()`), so calling
  /// this on a soft-deleted wallId is a silent no-op. The sortOrder read and
  /// the update run inside one [db.AppDatabase.transaction], mirroring
  /// [createWall]/[createSector]'s append-at-end pattern.
  ///
  /// [newSectorId] must reference a live [db.Sector] row: `PRAGMA
  /// foreign_keys = ON` (see `app_database.dart`) makes writing an
  /// unknown/nonexistent sector id throw.
  ///
  /// The Wall-level half of the Area/Sector/Wall re-parenting pair added so
  /// an existing topo can be moved to a different wall's sector; see
  /// [moveSector] for the Sector-level half (moving a sector — and its whole
  /// subtree of walls — to a different area).
  Future<void> moveWall(String wallId, String newSectorId) {
    return _db.transaction(() async {
      final now = nowMs();
      final sortOrder = await _nextSortOrder(
        table: _db.walls,
        sortOrderColumn: _db.walls.sortOrder,
        scope: _db.walls.sectorId.equals(newSectorId),
      );
      await _guardedWrite(
        operation: 'moveWall',
        id: wallId,
        table: _db.walls,
        idColumn: _db.walls.id,
        ownerColumn: _db.walls.ownerId,
        deletedAtColumn: _db.walls.deletedAt,
        write: (_db.update(_db.walls)..where(
              (t) =>
                  t.id.equals(wallId) &
                  t.deletedAt.isNull() &
                  _ownOrUnowned(t.ownerId),
            ))
            .write(
              db.WallsCompanion(
                sectorId: Value(newSectorId),
                sortOrder: Value(sortOrder),
                updatedAt: Value(now),
                dirty: const Value(true),
              ),
            ),
      );
    });
  }

  /// Re-parents [sectorId] to [newAreaId] — the Sector-level half of the
  /// [moveWall] re-parenting pair. Same shape: recomputes `sortOrder` via
  /// [_nextSortOrder] scoped to [newAreaId] (append at the end of the
  /// destination area's siblings), marks the sector dirty with a bumped
  /// `updatedAt`, is a no-op on a soft-deleted sectorId, runs in one
  /// [db.AppDatabase.transaction], and relies on `PRAGMA foreign_keys = ON`
  /// to throw if [newAreaId] doesn't reference a live [db.Area] row.
  ///
  /// Note this only moves the sector row itself — the walls underneath it
  /// keep their existing `sectorId` and simply come along transitively
  /// (their ancestor area changes, but their own row is untouched).
  Future<void> moveSector(String sectorId, String newAreaId) {
    return _db.transaction(() async {
      final now = nowMs();
      final sortOrder = await _nextSortOrder(
        table: _db.sectors,
        sortOrderColumn: _db.sectors.sortOrder,
        scope: _db.sectors.areaId.equals(newAreaId),
      );
      await _guardedWrite(
        operation: 'moveSector',
        id: sectorId,
        table: _db.sectors,
        idColumn: _db.sectors.id,
        ownerColumn: _db.sectors.ownerId,
        deletedAtColumn: _db.sectors.deletedAt,
        write: (_db.update(_db.sectors)..where(
              (t) =>
                  t.id.equals(sectorId) &
                  t.deletedAt.isNull() &
                  _ownOrUnowned(t.ownerId),
            ))
            .write(
              db.SectorsCompanion(
                areaId: Value(newAreaId),
                sortOrder: Value(sortOrder),
                updatedAt: Value(now),
                dirty: const Value(true),
              ),
            ),
      );
    });
  }

  Future<void> _setWallVisibility(String wallId, String visibility) async {
    // Hole B guard: bail before touching the wall OR its photos/routes on a
    // FOREIGN-owned wall — same check-then-act rationale as
    // [softDeleteWall], since the photos/routes updates below key off
    // `wallId` alone with no ownership check of their own.
    if (!await _guardedCascadeAllowed(
      operation: 'setWallVisibility',
      id: wallId,
      table: _db.walls,
      idColumn: _db.walls.id,
      ownerColumn: _db.walls.ownerId,
      deletedAtColumn: _db.walls.deletedAt,
    )) {
      return;
    }
    final now = nowMs();
    await (_db.update(
      _db.walls,
    )..where((t) => t.id.equals(wallId) & t.deletedAt.isNull())).write(
      db.WallsCompanion(
        visibility: Value(visibility),
        updatedAt: Value(now),
        dirty: const Value(true),
      ),
    );
    await (_db.update(
      _db.photos,
    )..where((t) => t.wallId.equals(wallId) & t.deletedAt.isNull())).write(
      db.PhotosCompanion(updatedAt: Value(now), dirty: const Value(true)),
    );
    await (_db.update(
      _db.routes,
    )..where((t) => t.wallId.equals(wallId) & t.deletedAt.isNull())).write(
      db.RoutesCompanion(updatedAt: Value(now), dirty: const Value(true)),
    );
  }

  // ---------------------------------------------------------------------
  // Photos
  // ---------------------------------------------------------------------

  /// Attaches a freshly-picked photo [xfile] to [wallId] as an
  /// `original`, returning the new photo's id.
  ///
  /// The picked file is COPIED into the app-owned `photos/` directory under
  /// the new row's id (via [PhotoFiles.importPhoto]) and it is THAT app-owned
  /// path — not the transient picker-cache path handed in — that is stored as
  /// `localPath`. This closes a latent local-loss bug (the OS may evict the
  /// picker cache out from under a row that still references it) and makes the
  /// path portable for cloud backup.
  ///
  /// The copy is best-effort ON NATIVE only: if the source doesn't exist (or
  /// the copy fails) [PhotoFiles.importPhoto] still returns the relative
  /// destination form, so the row is created and the picker's own file remains
  /// recoverable via `resolvePhotoPath`'s container-rotation healing.
  ///
  /// On WEB it is NOT best-effort (L3 fix): the byte store is the only copy of
  /// the pixels, so a refused write — quota exhaustion above all, since
  /// originals stay at FULL resolution per decision D-5 — throws a
  /// [PhotoWriteException] out of [PhotoFiles.importPhoto], which this method
  /// deliberately does NOT catch. Because that await happens BEFORE the insert
  /// transaction below, the throw means no [db.Photos] row is ever created:
  /// there is no such thing as a pixel-less row any more. Callers must handle
  /// it — see `topos_screen.dart`'s `_handleNewTopo` (which soft-deletes the
  /// wall it had just created) and `topo_canvas_screen.dart`'s
  /// `_attachPhotoAndLoad` (which clears the optimistically-selected path);
  /// both present [PhotoWriteException.userMessage] via
  /// `photoWriteFailureSnackBar`.
  ///
  /// Multi-photo bookkeeping: this ALWAYS inserts a new original (a wall can
  /// carry many) rather than replacing a previous one. The new row's
  /// `isPrimary` is `true` only when [wallId] currently has NO live
  /// original at all — i.e. the FIRST photo ever attached becomes primary
  /// by default (the "main" photo shown as the topo's thumbnail/opened by
  /// the canvas); every subsequent attach is `isPrimary: false` and must be
  /// promoted explicitly via [PhotoRepository.setPrimaryPhoto]. `sortOrder`
  /// is the current count of live originals (append-at-end), mirroring
  /// [createSector]/[createWall]'s sibling-sortOrder pattern.
  Future<String> attachPhotoToWall(
    String wallId,
    XFile xfile,
    int width,
    int height,
  ) async {
    final now = nowMs();
    final id = _uuid.v4();
    final ownedPath = await _photoFiles.importPhoto(xfile, id);
    // Bug #10: the live-original count-read and the insert deciding
    // isPrimary off it are check-then-act — without serialization, a fast
    // double-attach (e.g. a double-tap) could have both calls read "0
    // existing" and both insert isPrimary:true, giving the wall two
    // primaries. Wrapping in one transaction relies on drift serializing
    // `transaction` calls on a connection (see [createTopo]'s identical
    // rationale), so the second concurrent call's count-read can't run
    // until the first call's insert has committed.
    await _db.transaction(() async {
      final liveOriginalCount = await _liveOriginalCount(wallId);
      await _db
          .into(_db.photos)
          .insert(
            db.PhotosCompanion.insert(
              id: id,
              createdAt: now,
              updatedAt: now,
              dirty: const Value(true),
              wallId: wallId,
              localPath: ownedPath,
              kind: 'original',
              width: width,
              height: height,
              sortOrder: Value(liveOriginalCount),
              isPrimary: Value(liveOriginalCount == 0),
              ownerId: Value(currentUid()),
            ),
          );
    });
    return id;
  }

  /// The number of live (non-deleted) `kind:'original'` photos currently on
  /// [wallId] — used by [attachPhotoToWall] to decide the new photo's
  /// `sortOrder` (append-at-end) and whether it's the wall's first (hence
  /// primary) original.
  Future<int> _liveOriginalCount(String wallId) async {
    final query = _db.selectOnly(_db.photos)
      ..addColumns([_db.photos.id.count()])
      ..where(
        _db.photos.wallId.equals(wallId) &
            _db.photos.kind.equals('original') &
            _db.photos.deletedAt.isNull(),
      );
    final row = await query.getSingle();
    return row.read(_db.photos.id.count()) ?? 0;
  }

  /// The stored `localPath` of the Photos row [photoId] (regardless of
  /// `kind` or soft-delete state), or `null` if no such row exists.
  ///
  /// A direct primary-key lookup — unlike [PhotoRepository.loadOriginal]'s
  /// wallId+kind query, this can never throw on a wall that has accumulated
  /// more than one live `'original'` row (e.g. the user replaced a wall's
  /// photo more than once). Used right after [attachPhotoToWall] to recover
  /// the app-owned path it stored on the just-created row — that method
  /// itself only returns the new photo's id (see its doc) — so
  /// `topo_canvas_screen.dart`'s [resolveAttachedPhotoPath] can swap
  /// `selectedImageProvider` off the transient picker-cache path and onto
  /// the owned one. This closes the confirmed photo-ownership bug where
  /// `selectedImageProvider` kept holding the raw picker-cache path instead
  /// of the owned copy for the rest of the session.
  Future<String?> photoLocalPath(String photoId) async {
    final row =
        await (_db.select(_db.photos)
              ..where((t) => t.id.equals(photoId))
              ..limit(1))
            .getSingleOrNull();
    if (row == null) return null;
    // Sync, cache-backed resolver (NOT the awaiting resolvePhotoPath):
    // photoLocalPath is invoked from the canvas attach-resolve path which
    // can run under a widget pump, where awaiting real path_provider hangs.
    // The heal signal it returns is still applied via the async DB write.
    final resolution = _photoFiles.resolvePhotoPathSync(row.localPath);
    final healed = resolution.healedRelativePath;
    if (healed != null) {
      await (_db.update(_db.photos)..where((t) => t.id.equals(row.id))).write(
        db.PhotosCompanion(localPath: Value(healed)),
      );
    }
    return resolution.path;
  }

  /// The display name of the non-deleted [db.Wall] identified by [wallId],
  /// or `null` if it doesn't exist (or has been soft-deleted). Backs the
  /// topo canvas's title chrome (see `TopoCanvasScreen` / `wallNameProvider`
  /// in `library_providers.dart`), which falls back to a generic "Topo"
  /// label while this resolves or if it comes back null.
  Future<String?> wallName(String wallId) async {
    final row =
        await (_db.select(_db.walls)
              ..where((t) => t.id.equals(wallId) & t.deletedAt.isNull())
              ..limit(1))
            .getSingleOrNull();
    return row?.name;
  }

  /// The current `sectorId` of the non-deleted [db.Wall] identified by
  /// [wallId], or `null` if it doesn't exist (or has been soft-deleted).
  ///
  /// [TopoRef] (the Topos-home read model) deliberately carries no
  /// `sectorId` of its own — this is the one-shot lookup `topos_screen.
  /// dart`'s "Move to…" flow uses to resolve a topo's CURRENT sector so it
  /// can be excluded from the destination-sector picker's candidates (see
  /// [listOwnSectors]).
  Future<String?> wallSectorId(String wallId) async {
    final row =
        await (_db.select(_db.walls)
              ..where((t) => t.id.equals(wallId) & t.deletedAt.isNull())
              ..limit(1))
            .getSingleOrNull();
    return row?.sectorId;
  }

  /// Whether the non-deleted [db.Wall] identified by [wallId] currently has
  /// GPS coordinates recorded (`latitude` non-null) — `false` if it has none
  /// or the wall doesn't exist (or is soft-deleted).
  ///
  /// Data-corruption guard: `topo_canvas_screen.dart`'s
  /// [captureWallGpsFromPhoto]/`topos_screen.dart`'s `_handleNewTopo` read
  /// this before falling back to the device's current location for a
  /// no-EXIF photo, so that fallback only ever fills a VOID (a wall with no
  /// coordinates yet) and never overwrites coordinates the wall already has
  /// — e.g. from a previous photo's real EXIF GPS at the actual crag — with
  /// wherever the device happens to be right now (e.g. the user's home,
  /// weeks later, replacing the wall's photo with a screenshot).
  Future<bool> wallHasCoordinates(String wallId) async {
    final row =
        await (_db.select(_db.walls)
              ..where((t) => t.id.equals(wallId) & t.deletedAt.isNull())
              ..limit(1))
            .getSingleOrNull();
    return row?.latitude != null;
  }

  // ---------------------------------------------------------------------
  // Topos (flat Wall list for the Topos home)
  // ---------------------------------------------------------------------

  static const _defaultAreaName = '__default__';
  static const _defaultSectorName = '__default__';

  /// Rejects [name] (after trimming) if it collides with the hidden
  /// `__default__` sentinel Area/Sector name (bug #11) — see
  /// [_ensureDefaultAreaId]/[_ensureDefaultSectorId]. An Area/Sector
  /// actually named `__default__` would be indistinguishable from the
  /// sentinel and get silently filtered out of every UI list (see
  /// [_areaQuery]/[_sectorQuery]), effectively vanishing. Input validation
  /// only — no schema column. Called from the public
  /// [createArea]/[renameArea]/[createSector]/[renameSector] paths, NOT
  /// from [_insertArea]/[_insertSector], which the sentinel's own
  /// find-or-create path uses to create `__default__` itself.
  void _rejectReservedName(String name) {
    final trimmed = name.trim();
    if (trimmed == _defaultAreaName || trimmed == _defaultSectorName) {
      throw ArgumentError.value(name, 'name', 'reserved area/sector name');
    }
  }

  /// Live, flat list of every non-deleted [db.Wall], each paired with its
  /// PRIMARY (or, if none is flagged — e.g. legacy data untouched by the
  /// v5->v6 migration's backfill — the most recent) non-deleted
  /// `kind:'original'` [db.Photo]'s `localPath` (or `null` if it has none),
  /// a live count of its non-deleted [db.Route]s,
  /// the wall's representative grade — the display label
  /// (`gradeRaw`)/[GradeBand] of its hardest non-deleted, graded route (both
  /// `null` if the wall has no graded routes) —, its ancestor Area's id/name
  /// (`null`/`null` for a wall filed under the hidden `__default__`
  /// sentinel, or with no area at all -- see [TopoRef.areaId]'s doc), and
  /// every live graded route's `gradeSortKey` ([TopoRef.routeGradeKeys],
  /// used by the Topos-home grade filter), and the wall's own
  /// latitude/longitude ([TopoRef.latitude]/[TopoRef.longitude], `null` until
  /// set via [setWallCoordinates] — backs the Community map's "own topos"
  /// markers) — ordered by wall `createdAt` DESC (newest topo first).
  ///
  /// This is the first join/aggregate query in this repository. It's
  /// expressed as a raw [customSelect] (rather than a Drift `.join()`) so a
  /// wall with more than one live `'original'` photo doesn't multiply rows
  /// via `GROUP BY`; `readsFrom` is set explicitly to `{walls, photos,
  /// routes, sectors, areas}` so the auto-updating stream re-emits on
  /// changes to any of the five tables, not just `walls` (this also covers
  /// the top-grade subquery, which also reads `routes`, and the
  /// area/sector `LEFT JOIN`s added for [TopoRef.areaId]/[TopoRef.areaName]).
  ///
  /// The `area_id`/`area_name` columns detect the hidden `__default__`
  /// sentinel Area the SAME way [_areaQuery] does (by name), mapping it to
  /// `NULL` in SQL so a photo-first topo's [TopoRef.areaId]/[TopoRef.
  /// areaName] always come back `null` ("Unfiled") rather than ever
  /// surfacing the sentinel as a real area.
  ///
  /// Ownership scoping (bug #1): scoped to own-or-unowned walls, same
  /// pattern as [listOwnAreas]/[listOwnSectors] — `w.owner_id IS NULL OR
  /// w.owner_id = ?`, bound to the passed-in [ownerUid]. Without this, a
  /// foreign-owned wall synced down locally (e.g. while browsing someone
  /// else's shared topo — see `community_repository.dart`) would appear
  /// here as if it were the signed-in user's own, fully editable. A `null`
  /// [ownerUid] (signed out) makes `w.owner_id = ?` evaluate to SQL `NULL`
  /// (never true), so the `OR` collapses to exactly `w.owner_id IS NULL` —
  /// no separate branch needed.
  ///
  /// [ownerUid] is an EXPLICIT parameter (mirroring [listOwnAreas]/
  /// [listOwnSectors]) rather than always reading [currentUid] internally
  /// (Hole A, adversarial-review 2026-07-21): the OLD code called
  /// [currentUid] exactly once, at the moment this method built the query's
  /// bound `Variable` — the resulting *stream* then kept that one uid
  /// forever, even though `currentUid()` itself would return something
  /// fresh on a later call. `toposProvider` (`library_providers.dart`) is a
  /// plain provider that called this exactly once and never rebuilt on its
  /// own, so a frozen-uid stream silently kept showing a first account's own
  /// topos after an in-app sign-out/sign-in as a second account (this app
  /// is local-first, one on-device SQLite store shared by whoever is
  /// currently signed in — there's no separate per-account store to switch
  /// to). Making the uid an explicit parameter pushes the "read the CURRENT
  /// uid" responsibility out to the caller: `toposProvider` `ref.watch`es
  /// the live uid off `authStateProvider` and passes it in on every build,
  /// so an auth change rebuilds the provider and re-subscribes this stream
  /// with a fresh uid instead of reusing a stale one.
  ///
  /// [ownerUid] defaults to (i.e. an OMITTED argument falls back to)
  /// invoking [currentUid] — preserving every existing signed-out-by-
  /// default call site (most of this repository's own test suite) — but an
  /// explicitly-passed value, including an explicit `null`, is always used
  /// as-is and never overridden by [currentUid]. In practice the two never
  /// disagree: both ultimately trace back to the same signed-in/signed-out
  /// session, just read through two different doors (a live stream vs. a
  /// synchronous getter) — see [currentUidProvider]'s doc.
  ///
  /// Tiebreak note: the outer ordering, the thumbnail subquery, and the
  /// top-grade subquery all order by their respective columns DESC at
  /// coarse resolution (ms for `created_at`, and `grade_sort_key` ties are
  /// possible whenever two routes share a grade), which isn't fine-grained
  /// enough to distinguish ties. All three add a secondary `id DESC`
  /// tiebreak for deterministic, stable output across repeated reads; since
  /// ids are random UUIDs this tiebreak is arbitrary but consistent, not a
  /// proxy for "more recent" or "harder".
  Stream<List<TopoRef>> watchTopos([String? ownerUid = _unsetOwnerUid]) {
    final uid = ownerUid == _unsetOwnerUid ? currentUid() : ownerUid;
    const sql =
        '''
      SELECT
        w.id AS wall_id,
        w.name AS wall_name,
        w.created_at AS wall_created_at,
        w.visibility AS wall_visibility,
        w.latitude AS wall_latitude,
        w.longitude AS wall_longitude,
        (SELECT p.local_path FROM photos p
           WHERE p.wall_id = w.id AND p.kind = 'original' AND p.deleted_at IS NULL
           ORDER BY p.is_primary DESC, p.created_at DESC, p.id DESC LIMIT 1) AS thumbnail_path,
        (SELECT COUNT(*) FROM routes r
           WHERE r.wall_id = w.id AND r.deleted_at IS NULL) AS route_count,
        (SELECT r.grade_raw FROM routes r
           WHERE r.wall_id = w.id AND r.deleted_at IS NULL
             AND r.grade_sort_key IS NOT NULL
           ORDER BY r.grade_sort_key DESC, r.id DESC LIMIT 1) AS top_grade_raw,
        (SELECT r.grade_sort_key FROM routes r
           WHERE r.wall_id = w.id AND r.deleted_at IS NULL
             AND r.grade_sort_key IS NOT NULL
           ORDER BY r.grade_sort_key DESC, r.id DESC LIMIT 1) AS top_grade_sort_key,
        (SELECT group_concat(DISTINCT r.grade_sort_key) FROM routes r
           WHERE r.wall_id = w.id AND r.deleted_at IS NULL
             AND r.grade_sort_key IS NOT NULL) AS route_grade_keys,
        CASE WHEN a.name = '$_defaultAreaName' THEN NULL ELSE a.id END AS area_id,
        CASE WHEN a.name = '$_defaultAreaName' THEN NULL ELSE a.name END AS area_name
      FROM walls w
      LEFT JOIN sectors s ON s.id = w.sector_id
      LEFT JOIN areas a ON a.id = s.area_id
      WHERE w.deleted_at IS NULL
        AND (w.owner_id IS NULL OR w.owner_id = ?)
      ORDER BY w.created_at DESC, w.id DESC
    ''';
    return _db
        .customSelect(
          sql,
          variables: [Variable<String>(uid)],
          readsFrom: {
            _db.walls,
            _db.photos,
            _db.routes,
            _db.sectors,
            _db.areas,
          },
        )
        .watch()
        .map((rows) {
          // Synchronous mapping (NOT asyncMap): an async mapper on this
          // Drift stream wedges the `toposProvider` StreamProvider under
          // `flutter_test`'s fake clock, so any ToposScreen widget test
          // hangs `pumpAndSettle` forever. Thumbnails are resolved to an
          // absolute path via the synchronous best-effort
          // `resolvePhotoPathSync` (backed by PhotoFiles' memoized docs
          // path); the authoritative stale-path heal happens on the async
          // open-a-wall paths (loadOriginal/photoLocalPath), not here. See
          // PhotoFiles.resolvePhotoPathSync for the cold-cache
          // fallback (returns the stored value, which the ToposScreen
          // thumbnail gates via File(path).existsSync()).
          return [
            for (final row in rows)
              TopoRef(
                wallId: row.read<String>('wall_id'),
                name: row.read<String>('wall_name'),
                thumbnailPath: _resolveThumbnail(
                  row.readNullable<String>('thumbnail_path'),
                ),
                routeCount: row.read<int>('route_count'),
                createdAt: row.read<int>('wall_created_at'),
                visibility: row.read<String>('wall_visibility'),
                topGradeLabel: row.readNullable<String>('top_grade_raw'),
                topGradeBand:
                    row.readNullable<double>('top_grade_sort_key') == null
                    ? null
                    : bandForSortKey(
                        row.readNullable<double>('top_grade_sort_key')!,
                      ),
                areaId: row.readNullable<String>('area_id'),
                areaName: row.readNullable<String>('area_name'),
                routeGradeKeys: _parseGradeKeys(
                  row.readNullable<String>('route_grade_keys'),
                ),
                latitude: row.readNullable<double>('wall_latitude'),
                longitude: row.readNullable<double>('wall_longitude'),
              ),
          ];
        });
  }

  /// Resolves a stored thumbnail `localPath` to an absolute display path for
  /// the row's small tile, passing `null` through unchanged (walls with no
  /// photo).
  ///
  /// #56 fix: [thumbKeyFor] is applied FIRST, deriving the downscaled
  /// `thumbs/<id>.jpg` key from the stored ORIGINAL path, before resolving
  /// via [PhotoFiles.resolvePhotoPathSync] (synchronous, for the
  /// [watchTopos] stream) — so the Topos-home list decodes the small
  /// 512px-max-edge thumbnail generated at import time instead of the
  /// full-resolution original (`photo_strip.dart`'s existing precedent for
  /// its own 52px strip tile). [thumbKeyFor] only manipulates the basename
  /// (`path.join('thumbs', '$id.jpg')`), so it composes correctly with
  /// every case [resolvePhotoPathSync] itself handles — a relative stored
  /// path, a still-valid legacy absolute one, or a stale absolute one
  /// pending container-rotation self-heal — since all three ultimately
  /// resolve against the SAME current docs dir via the re-derived relative
  /// form. A wall whose photo predates thumbnail generation (no
  /// `thumbs/<id>.jpg` was ever written) resolves to a path that simply
  /// doesn't exist on disk; that degrades to [PhotoImage]'s `placeholder`
  /// gradient exactly like any other unreadable photo, never a blank tile.
  String? _resolveThumbnail(String? storedThumbnailPath) {
    if (storedThumbnailPath == null) return null;
    return _photoFiles
        .resolvePhotoPathSync(thumbKeyFor(storedThumbnailPath))
        .path;
  }

  // ---------------------------------------------------------------------
  // Map search reads (unified map search's data layer — see
  // `features/community/data/map_search.dart`'s `mapContentSearch`)
  // ---------------------------------------------------------------------

  /// Live list of every non-deleted [db.Route] on a non-deleted wall that
  /// has recorded GPS coordinates, newest-wall-first — see [LocatedRouteRef].
  /// A route with no coordinates of its own is only ever locatable through
  /// its wall, so a route on a wall with `latitude`/`longitude` still `null`
  /// is excluded entirely (never surfaced with a `(0, 0)` fallback).
  ///
  /// Raw [customSelect], mirroring [watchTopos]'s join style for the same
  /// reason: a plain Drift `.join()` would be the natural fit here (unlike
  /// `watchTopos`, there's no one-to-many photo/route aggregate that would
  /// multiply rows), but a raw query keeps this consistent with the rest of
  /// this repository's map-facing reads. `readsFrom` is `{routes, walls}` so
  /// the auto-updating stream re-emits on changes to either table (e.g. a
  /// wall's coordinates just got set via [setWallCoordinates]).
  Stream<List<LocatedRouteRef>> watchLocatedRoutes() {
    const sql = '''
      SELECT
        r.id AS route_id,
        r.number AS route_number,
        r.name AS route_name,
        w.id AS wall_id,
        w.name AS wall_name,
        w.latitude AS wall_latitude,
        w.longitude AS wall_longitude
      FROM routes r
      JOIN walls w ON w.id = r.wall_id
      WHERE r.deleted_at IS NULL
        AND w.deleted_at IS NULL
        AND w.latitude IS NOT NULL
        AND w.longitude IS NOT NULL
      ORDER BY w.created_at DESC, w.id DESC, r.sort_order ASC
    ''';
    return _db
        .customSelect(sql, readsFrom: {_db.routes, _db.walls})
        .watch()
        .map((rows) {
          // Synchronous mapping, same rationale as watchTopos/
          // watchSharedTopos: an async mapper on a Drift stream wedges under
          // flutter_test's fake clock.
          return [
            for (final row in rows)
              LocatedRouteRef(
                routeId: row.read<String>('route_id'),
                number: row.read<int>('route_number'),
                name: row.readNullable<String>('route_name'),
                wallId: row.read<String>('wall_id'),
                wallName: row.read<String>('wall_name'),
                latitude: row.read<double>('wall_latitude'),
                longitude: row.read<double>('wall_longitude'),
              ),
          ];
        });
  }

  /// Bug #17: a naive `AVG(w.longitude)` is wrong for a group of walls that
  /// straddles the antimeridian (e.g. `+179.9` and `-179.9`, ~0.2° apart in
  /// reality) — it averages to `~0`, the opposite side of the planet.
  /// Detects the straddle via `MAX(longitude) - MIN(longitude) > 180`
  /// (never true for a group that doesn't cross the line, since real
  /// longitudes span at most 360° and any non-crossing cluster's raw spread
  /// stays under 180°); when it fires, shifts every negative longitude by
  /// +360 before averaging (mapping the group onto one continuous span),
  /// then wraps the result back into `(-180, 180]` by subtracting 360 if it
  /// landed past 180. Expressed with only `MAX`/`MIN`/`AVG`/`CASE` inside
  /// the existing single-pass `GROUP BY` (no window functions or
  /// subqueries needed) so it drops into [watchLocatedSectors]/
  /// [watchLocatedAreas] without restructuring either query.
  static const _kAntimeridianSafeAvgLongitude =
      '''
      CASE WHEN (MAX(w.longitude) - MIN(w.longitude)) > 180 THEN
        CASE WHEN AVG(CASE WHEN w.longitude < 0 THEN w.longitude + 360 ELSE w.longitude END) > 180
          THEN AVG(CASE WHEN w.longitude < 0 THEN w.longitude + 360 ELSE w.longitude END) - 360
          ELSE AVG(CASE WHEN w.longitude < 0 THEN w.longitude + 360 ELSE w.longitude END)
        END
      ELSE AVG(w.longitude)
      END''';

  /// Live list of every non-deleted, non-sentinel [db.Sector] that has at
  /// least one located descendant wall, each paired with the arithmetic-mean
  /// centroid over exactly those located walls — see [LocatedSectorRef]. A
  /// sector with zero located walls (either no walls at all, or none with
  /// coordinates) never appears: the `JOIN` (not `LEFT JOIN`) to `walls`
  /// combined with the coordinate `WHERE` filter means SQLite's `GROUP BY`
  /// simply has no rows to group for that sector's id, so no row — and no
  /// `AVG(NULL)` fallback — is ever emitted for it.
  ///
  /// Excludes the hidden `__default__` sentinel Sector, same rationale as
  /// [_sectorQuery]: it's an internal filing detail for photo-first topos,
  /// never a real, nameable sector a search should be able to find.
  Stream<List<LocatedSectorRef>> watchLocatedSectors() {
    const sql =
        '''
      SELECT
        s.id AS sector_id,
        s.name AS sector_name,
        AVG(w.latitude) AS avg_latitude,
        $_kAntimeridianSafeAvgLongitude AS avg_longitude
      FROM sectors s
      JOIN walls w ON w.sector_id = s.id
      WHERE s.deleted_at IS NULL
        AND s.name != '$_defaultSectorName'
        AND w.deleted_at IS NULL
        AND w.latitude IS NOT NULL
        AND w.longitude IS NOT NULL
      GROUP BY s.id
      ORDER BY s.name
    ''';
    return _db
        .customSelect(sql, readsFrom: {_db.sectors, _db.walls})
        .watch()
        .map((rows) {
          return [
            for (final row in rows)
              LocatedSectorRef(
                id: row.read<String>('sector_id'),
                name: row.read<String>('sector_name'),
                latitude: row.read<double>('avg_latitude'),
                longitude: row.read<double>('avg_longitude'),
              ),
          ];
        });
  }

  /// Live list of every non-deleted, non-sentinel [db.Area] that has at
  /// least one located wall anywhere under its sectors, each paired with the
  /// arithmetic-mean centroid over ALL of those located walls across ALL of
  /// the area's sectors (a two-level `JOIN` through `sectors`, deliberately
  /// NOT an average of each sector's own [LocatedSectorRef] centroid — a
  /// sector with many located walls should pull the area centroid more than
  /// one with few) — see [LocatedAreaRef]. Same zero-located-walls exclusion
  /// as [watchLocatedSectors] (inner `JOIN`s + `GROUP BY`, no fallback row),
  /// and same hidden `__default__` sentinel-Area exclusion as [_areaQuery].
  Stream<List<LocatedAreaRef>> watchLocatedAreas() {
    const sql =
        '''
      SELECT
        a.id AS area_id,
        a.name AS area_name,
        AVG(w.latitude) AS avg_latitude,
        $_kAntimeridianSafeAvgLongitude AS avg_longitude
      FROM areas a
      JOIN sectors s ON s.area_id = a.id
      JOIN walls w ON w.sector_id = s.id
      WHERE a.deleted_at IS NULL
        AND a.name != '$_defaultAreaName'
        AND s.deleted_at IS NULL
        AND w.deleted_at IS NULL
        AND w.latitude IS NOT NULL
        AND w.longitude IS NOT NULL
      GROUP BY a.id
      ORDER BY a.name
    ''';
    return _db
        .customSelect(sql, readsFrom: {_db.areas, _db.sectors, _db.walls})
        .watch()
        .map((rows) {
          return [
            for (final row in rows)
              LocatedAreaRef(
                id: row.read<String>('area_id'),
                name: row.read<String>('area_name'),
                latitude: row.read<double>('avg_latitude'),
                longitude: row.read<double>('avg_longitude'),
              ),
          ];
        });
  }

  /// Finds (or, on first call, creates) the single hidden default
  /// [db.Area] (sentinel name `__default__`) that photo-first-created
  /// topos live under.
  Future<String> _ensureDefaultAreaId() async {
    final existing =
        await (_db.select(_db.areas)
              ..where(
                (t) => t.name.equals(_defaultAreaName) & t.deletedAt.isNull(),
              )
              ..limit(1))
            .getSingleOrNull();
    if (existing != null) return existing.id;
    // _insertArea, NOT createArea: the sentinel's own name IS the reserved
    // name [_rejectReservedName] blocks on the public path.
    final area = await _insertArea(_defaultAreaName);
    return area.id;
  }

  /// Finds (or, on first call, creates) the single hidden default
  /// [db.Sector] (sentinel name `__default__`) under [_ensureDefaultAreaId]
  /// that photo-first-created topos live under.
  Future<String> _ensureDefaultSectorId() async {
    final areaId = await _ensureDefaultAreaId();
    final existing =
        await (_db.select(_db.sectors)
              ..where(
                (t) =>
                    t.areaId.equals(areaId) &
                    t.name.equals(_defaultSectorName) &
                    t.deletedAt.isNull(),
              )
              ..limit(1))
            .getSingleOrNull();
    if (existing != null) return existing.id;
    // _insertSector, NOT createSector: same reserved-name rationale as
    // _ensureDefaultAreaId's _insertArea call above.
    final sector = await _insertSector(areaId, _defaultSectorName);
    return sector.id;
  }

  /// Creates a new [db.Wall] named [name] under the hidden default
  /// Area/Sector (idempotently found-or-created), returning the new wall's
  /// id. Powers the photo-first "New topo" flow, which doesn't ask the user
  /// to pick an area/sector up front.
  ///
  /// The find-or-create-default-area + find-or-create-default-sector +
  /// createWall sequence is check-then-act (SELECT then conditional
  /// INSERT), so without serialization two concurrent [createTopo] calls
  /// (e.g. a double-tap) could each see "no default row yet" and both
  /// insert, producing two `__default__` areas/sectors and splitting topos
  /// across two hidden hierarchies. Wrapping the whole sequence in a single
  /// [db.AppDatabase.transaction] relies on drift serializing `transaction`
  /// calls on a connection (only one runs at a time), so the second
  /// concurrent call's SELECT can't run until the first call's INSERT (and
  /// the whole transaction) has committed — it will then see the row the
  /// first call created and reuse it instead of creating a duplicate.
  Future<String> createTopo(String name) {
    return _db.transaction(() async {
      final sectorId = await _ensureDefaultSectorId();
      final wall = await createWall(sectorId, name);
      return wall.id;
    });
  }

  // ---------------------------------------------------------------------
  // Query builders
  // ---------------------------------------------------------------------

  /// Excludes the hidden sentinel `__default__` Area (created lazily by
  /// [_ensureDefaultAreaId] for photo-first topos) so it never surfaces in
  /// the Areas hierarchy ("Organize") UI — showing it there would invite a
  /// user to delete it, which would cascade-soft-delete every photo-first
  /// topo living under it. [watchTopos] intentionally does NOT apply this
  /// filter: the walls under the sentinel must still appear as topos.
  SimpleSelectStatement<db.$AreasTable, db.Area> _areaQuery() {
    return _db.select(_db.areas)
      ..where(
        (t) => t.deletedAt.isNull() & t.name.equals(_defaultAreaName).not(),
      )
      ..orderBy([
        (t) => OrderingTerm(expression: t.name),
        (t) => OrderingTerm(expression: t.createdAt),
      ]);
  }

  /// Excludes the hidden sentinel `__default__` Sector for the same reason
  /// as [_areaQuery] excludes the sentinel Area; see that doc comment.
  SimpleSelectStatement<db.$SectorsTable, db.Sector> _sectorQuery(
    String areaId,
  ) {
    return _db.select(_db.sectors)
      ..where(
        (t) =>
            t.areaId.equals(areaId) &
            t.deletedAt.isNull() &
            t.name.equals(_defaultSectorName).not(),
      )
      ..orderBy([
        (t) => OrderingTerm(expression: t.sortOrder),
        (t) => OrderingTerm(expression: t.createdAt),
      ]);
  }

  SimpleSelectStatement<db.$WallsTable, db.Wall> _wallQuery(String sectorId) {
    return _db.select(_db.walls)
      ..where((t) => t.sectorId.equals(sectorId) & t.deletedAt.isNull())
      ..orderBy([
        (t) => OrderingTerm(expression: t.sortOrder),
        (t) => OrderingTerm(expression: t.createdAt),
      ]);
  }

  AreaRef _areaRefFromRow(db.Area row) =>
      AreaRef(id: row.id, name: row.name, description: row.description);

  SectorRef _sectorRefFromRow(db.Sector row) => SectorRef(
    id: row.id,
    areaId: row.areaId,
    name: row.name,
    sortOrder: row.sortOrder,
  );

  WallRef _wallRefFromRow(db.Wall row) => WallRef(
    id: row.id,
    sectorId: row.sectorId,
    name: row.name,
    sortOrder: row.sortOrder,
  );

  /// Returns `(max sortOrder among live rows matching [scope]) + 1`, or `0`
  /// if there are none.
  Future<int> _nextSortOrder({
    required TableInfo<Table, dynamic> table,
    required IntColumn sortOrderColumn,
    required Expression<bool> scope,
  }) async {
    final query = _db.selectOnly(table)
      ..addColumns([sortOrderColumn.max()])
      ..where(scope);
    final row = await query.getSingle();
    final maxSortOrder = row.read(sortOrderColumn.max());
    return (maxSortOrder ?? -1) + 1;
  }

  // ---------------------------------------------------------------------
  // Cascading soft-delete
  // ---------------------------------------------------------------------

  Future<void> _cascadeSoftDeleteAreaSubtree(String areaId, int now) async {
    // Hole B guard: the child-sector select itself is also scoped
    // own-or-unowned, so a FOREIGN sector nested under an otherwise-owned
    // area (e.g. synced-down from someone else's shared topo) is skipped
    // entirely at every level, not just cascaded into with no filter.
    final sectors = await (_db.select(_db.sectors)..where(
          (t) =>
              t.areaId.equals(areaId) &
              t.deletedAt.isNull() &
              _ownOrUnowned(t.ownerId),
        ))
        .get();
    for (final sector in sectors) {
      await _cascadeSoftDeleteSectorSubtree(sector.id, now);
    }
    await _guardedWrite(
      operation: 'cascadeSoftDeleteArea',
      id: areaId,
      table: _db.areas,
      idColumn: _db.areas.id,
      ownerColumn: _db.areas.ownerId,
      deletedAtColumn: _db.areas.deletedAt,
      write: (_db.update(_db.areas)..where(
            (t) =>
                t.id.equals(areaId) &
                t.deletedAt.isNull() &
                _ownOrUnowned(t.ownerId),
          ))
          .write(
            db.AreasCompanion(
              deletedAt: Value(now),
              updatedAt: Value(now),
              dirty: const Value(true),
            ),
          ),
    );
  }

  Future<void> _cascadeSoftDeleteSectorSubtree(String sectorId, int now) async {
    // Hole B guard, same rationale as [_cascadeSoftDeleteAreaSubtree]'s: the
    // child-wall select is scoped own-or-unowned so a FOREIGN wall nested
    // under an otherwise-owned sector is never soft-deleted transitively.
    final walls = await (_db.select(_db.walls)..where(
          (t) =>
              t.sectorId.equals(sectorId) &
              t.deletedAt.isNull() &
              _ownOrUnowned(t.ownerId),
        ))
        .get();
    for (final wall in walls) {
      await _cascadeSoftDeleteWallSubtree(wall.id, now);
    }
    await _guardedWrite(
      operation: 'cascadeSoftDeleteSector',
      id: sectorId,
      table: _db.sectors,
      idColumn: _db.sectors.id,
      ownerColumn: _db.sectors.ownerId,
      deletedAtColumn: _db.sectors.deletedAt,
      write: (_db.update(_db.sectors)..where(
            (t) =>
                t.id.equals(sectorId) &
                t.deletedAt.isNull() &
                _ownOrUnowned(t.ownerId),
          ))
          .write(
            db.SectorsCompanion(
              deletedAt: Value(now),
              updatedAt: Value(now),
              dirty: const Value(true),
            ),
          ),
    );
  }

  Future<void> _cascadeSoftDeleteWallSubtree(String wallId, int now) async {
    await (_db.update(
      _db.photos,
    )..where((t) => t.wallId.equals(wallId) & t.deletedAt.isNull())).write(
      db.PhotosCompanion(
        deletedAt: Value(now),
        updatedAt: Value(now),
        dirty: const Value(true),
      ),
    );
    await (_db.update(
      _db.routes,
    )..where((t) => t.wallId.equals(wallId) & t.deletedAt.isNull())).write(
      db.RoutesCompanion(
        deletedAt: Value(now),
        updatedAt: Value(now),
        dirty: const Value(true),
      ),
    );
    // Bug #5: a soft-deleted wall's live Ascents (Logbook entries) were
    // previously left untouched, so a deleted topo's ascents lingered in
    // the Logbook forever. Comments/Likes are cascaded alongside for the
    // same reason. Every row in the cascade — Photos/Routes/Walls included —
    // is marked `dirty` (§1e): the push is gated on that flag (see
    // `SyncService.hasPendingLocalChanges`), so an unflagged tombstone would
    // never reach the backend and the row would resurrect on another device.
    // The Photos/Routes/Walls asymmetry this comment used to describe was
    // exactly that bug.
    await (_db.update(
      _db.ascents,
    )..where((t) => t.wallId.equals(wallId) & t.deletedAt.isNull())).write(
      db.AscentsCompanion(
        deletedAt: Value(now),
        updatedAt: Value(now),
        dirty: const Value(true),
      ),
    );
    await (_db.update(
      _db.comments,
    )..where((t) => t.wallId.equals(wallId) & t.deletedAt.isNull())).write(
      db.CommentsCompanion(
        deletedAt: Value(now),
        updatedAt: Value(now),
        dirty: const Value(true),
      ),
    );
    await (_db.update(
      _db.likes,
    )..where((t) => t.wallId.equals(wallId) & t.deletedAt.isNull())).write(
      db.LikesCompanion(
        deletedAt: Value(now),
        updatedAt: Value(now),
        dirty: const Value(true),
      ),
    );
    await (_db.update(_db.walls)
          ..where((t) => t.id.equals(wallId) & t.deletedAt.isNull()))
        .write(
          db.WallsCompanion(
            deletedAt: Value(now),
            updatedAt: Value(now),
            dirty: const Value(true),
          ),
        );
  }

  // ---------------------------------------------------------------------
  // Ownership backfill (P2 will call this on sign-in)
  // ---------------------------------------------------------------------

  /// Attributes every currently-unowned, non-deleted row across all 8
  /// sync-tracked tables (the original 5 — Areas, Sectors, Walls, Photos,
  /// Routes — plus the community tables added in schema v3 — Comments,
  /// Likes, Ascents) to [uid]: sets `ownerId = uid`, bumps `updatedAt` to
  /// `nowMs()`, and marks the row `dirty` so a future sync push picks it up.
  ///
  /// Scoped to `ownerId IS NULL AND deletedAt IS NULL` — rows already owned
  /// by someone else (or by [uid] itself) are left untouched, and
  /// soft-deleted tombstones are never claimed. Runs in one transaction so a
  /// crash mid-backfill can't leave some tables claimed and others not.
  ///
  /// Wired to fire once per sign-in from `MasiApp`'s
  /// `handleAuthStateForClaimOwnership` listener (see `lib/app/`) on the
  /// signed-out -> signed-in edge of `authStateProvider`.
  Future<void> claimOwnership(String uid) {
    return _db.transaction(() async {
      final now = nowMs();

      await (_db.update(
        _db.areas,
      )..where((t) => t.ownerId.isNull() & t.deletedAt.isNull())).write(
        db.AreasCompanion(
          ownerId: Value(uid),
          updatedAt: Value(now),
          dirty: const Value(true),
        ),
      );

      await (_db.update(
        _db.sectors,
      )..where((t) => t.ownerId.isNull() & t.deletedAt.isNull())).write(
        db.SectorsCompanion(
          ownerId: Value(uid),
          updatedAt: Value(now),
          dirty: const Value(true),
        ),
      );

      await (_db.update(
        _db.walls,
      )..where((t) => t.ownerId.isNull() & t.deletedAt.isNull())).write(
        db.WallsCompanion(
          ownerId: Value(uid),
          updatedAt: Value(now),
          dirty: const Value(true),
        ),
      );

      await (_db.update(
        _db.photos,
      )..where((t) => t.ownerId.isNull() & t.deletedAt.isNull())).write(
        db.PhotosCompanion(
          ownerId: Value(uid),
          updatedAt: Value(now),
          dirty: const Value(true),
        ),
      );

      await (_db.update(
        _db.routes,
      )..where((t) => t.ownerId.isNull() & t.deletedAt.isNull())).write(
        db.RoutesCompanion(
          ownerId: Value(uid),
          updatedAt: Value(now),
          dirty: const Value(true),
        ),
      );

      await (_db.update(
        _db.comments,
      )..where((t) => t.ownerId.isNull() & t.deletedAt.isNull())).write(
        db.CommentsCompanion(
          ownerId: Value(uid),
          updatedAt: Value(now),
          dirty: const Value(true),
        ),
      );

      await (_db.update(
        _db.likes,
      )..where((t) => t.ownerId.isNull() & t.deletedAt.isNull())).write(
        db.LikesCompanion(
          ownerId: Value(uid),
          updatedAt: Value(now),
          dirty: const Value(true),
        ),
      );

      await (_db.update(
        _db.ascents,
      )..where((t) => t.ownerId.isNull() & t.deletedAt.isNull())).write(
        db.AscentsCompanion(
          ownerId: Value(uid),
          updatedAt: Value(now),
          dirty: const Value(true),
        ),
      );
    });
  }
}
