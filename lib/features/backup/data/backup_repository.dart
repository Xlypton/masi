import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart' show debugPrint, immutable;

import '../../../core/db/app_database.dart' as db;

/// Conflict-resolution strategy for [BackupRepository.importSnapshot].
enum ConflictMode {
  /// The incoming row always overwrites the local row. Used for an explicit,
  /// user-triggered force-restore from the cloud.
  replace,

  /// Last-write-wins by `updatedAt`: the incoming row overwrites the local
  /// row only when it's new locally (no local row with that `id` exists yet)
  /// or the incoming row's `updatedAt` is strictly newer than the local
  /// row's. Otherwise the local row is left untouched. This is what the
  /// automatic sign-in restore uses so it never clobbers newer local edits.
  lww,
}

/// One row [BackupRepository.importSnapshot] deliberately did NOT write,
/// because one of its foreign keys points at a parent row that exists neither
/// in the snapshot being imported nor in the local database.
///
/// This is a normal, expected outcome of a SYNC pull, not corruption. The
/// signed-in user's own row set (`SyncRemote.fetchOwnRows`, scoped
/// `ownerId = uid`) can contain an Ascent/Comment/Like the user made on
/// ANOTHER owner's shared topo — the parent Wall/Route belongs to that other
/// owner, so it is absent from the own batch by construction and arrives with
/// the SHARED batch instead, which imports afterwards. Inserting the child
/// first is an FK violation (`PRAGMA foreign_keys = ON`), and because the
/// insert used to be attempted unconditionally, ONE such row aborted the whole
/// `ascents`/`comments`/`likes` table for that pull — losing the user's own
/// ascents on their OWN topos too.
///
/// Deferring is not dropping: the row stays in the cloud, this object carries
/// the row JSON verbatim back to the caller (see [ImportReport.deferredRows]),
/// and `SyncService.pullOwnAndShared` re-imports exactly these rows once the
/// shared batch has landed their parents. Anything still deferred after that
/// is reported into `PullResult.errors`, i.e. onto the visible
/// "Couldn't sync … Retry" surface — never swallowed (#72's lesson).
@immutable
class DeferredRow {
  const DeferredRow({
    required this.table,
    required this.id,
    required this.column,
    required this.missingParentId,
  });

  /// Snapshot table name the row belongs to (e.g. `'ascents'`).
  final String table;

  /// The deferred row's own primary key.
  final String id;

  /// The FK column whose parent is missing (e.g. `'routeId'`).
  final String column;

  /// The id [column] points at, which no row currently has.
  final String missingParentId;

  @override
  String toString() => '$table $id: $column -> missing $missingParentId';
}

/// What [BackupRepository.importSnapshot] left unwritten without failing.
///
/// An empty report ([hasDeferrals] false) means every row in the snapshot was
/// either written or deliberately skipped by [ConflictMode.lww] because the
/// local copy is newer — nothing was lost either way.
@immutable
class ImportReport {
  const ImportReport({required this.deferred, required this.deferredRows});

  /// A clean report: nothing deferred.
  static const clean = ImportReport(
    deferred: <DeferredRow>[],
    deferredRows: <String, List<Map<String, dynamic>>>{},
  );

  /// Every row that was not written, with the FK that blocked it.
  final List<DeferredRow> deferred;

  /// The same rows' verbatim JSON, keyed by table name — shaped EXACTLY like
  /// `snapshot['tables']`, so a caller can hand it straight back to
  /// [BackupRepository.importSnapshot] once the missing parents have arrived.
  final Map<String, List<Map<String, dynamic>>> deferredRows;

  bool get hasDeferrals => deferred.isNotEmpty;

  /// One-line, log/UI-safe rendering of every deferral.
  String get summary => deferred.map((d) => '$d').join('; ');

  @override
  String toString() => 'ImportReport(${deferred.length} deferred: $summary)';
}

/// Collects [BackupRepository.importSnapshot]'s deferrals as it walks the
/// tables, in the exact JSON shape a re-import needs.
class _DeferralSink {
  final List<DeferredRow> _deferred = [];
  final Map<String, List<Map<String, dynamic>>> _rows = {};

  /// Rows dropped rather than deferred because they are themselves tombstones.
  int _droppedTombstones = 0;

  void defer({
    required String table,
    required String id,
    required String column,
    required String missingParentId,
    required Map<String, dynamic> json,
  }) {
    // A TOMBSTONE whose parent is unreachable is dropped, not deferred.
    //
    // This was a permanent, self-renewing sync failure on a real device: the
    // user deleted one of their own shared topos, which soft-deleted the wall,
    // its route and the shared ascent on it. The ascent is still visible to the
    // shared-ascent fetch (an owner policy), but its wall is NOT — the public
    // wall policy is `is_wall_public("wallId")`, which requires
    // `deletedAt IS NULL` — so the ascent arrived every pull with no parent,
    // deferred every pull, and `SyncService` reported `shared rows deferred
    // (parent row missing)` every pull. Retry could never clear it, because
    // nothing about the cloud state was going to change.
    //
    // Dropping is safe precisely BECAUSE the row is deleted: there is nothing
    // to render, nothing to count, and no state a later pull could recover.
    // The only job a tombstone has is to delete a local copy — and a local copy
    // cannot exist here, since it would require the parent row that is missing
    // (`_existingIds` deliberately counts tombstoned parents as present, so a
    // parent we hold at all, even deleted, resolves the FK and never reaches
    // this path). So this drops exactly the rows that are unreachable garbage
    // and nothing else.
    //
    // Deliberately NOT filtered earlier, in the fetch: a tombstone whose parent
    // IS present must still arrive, or deletions stop propagating. The
    // distinction that matters is "can this row be placed", which is only known
    // here.
    if (_isTombstone(json)) {
      _droppedTombstones++;
      debugPrint(
        'importSnapshot: dropped tombstoned $table $id — $column -> missing '
        '$missingParentId (deleted row, unreachable parent: nothing to place)',
      );
      return;
    }
    _deferred.add(
      DeferredRow(
        table: table,
        id: id,
        column: column,
        missingParentId: missingParentId,
      ),
    );
    (_rows[table] ??= <Map<String, dynamic>>[]).add(json);
    debugPrint(
      'importSnapshot: deferred $table $id — $column -> missing '
      '$missingParentId (parent not in snapshot nor local DB)',
    );
  }

  /// Whether [json] is a soft-deleted row.
  ///
  /// Both key spellings are accepted because this JSON reaches the importer
  /// from two sources with different conventions: Supabase rows use quoted
  /// camelCase columns (`deletedAt`), while a drift `toJson()` round-trip can
  /// carry the generated snake_case name. Treating only one as authoritative
  /// would make the drop above silently stop working for the other.
  static bool _isTombstone(Map<String, dynamic> json) {
    final raw = json['deletedAt'] ?? json['deleted_at'];
    if (raw is int) return raw > 0;
    if (raw is String) {
      final parsed = int.tryParse(raw);
      return parsed != null && parsed > 0;
    }
    return false;
  }

  /// How many tombstones were dropped rather than deferred — surfaced so a
  /// caller can tell "nothing to do" apart from "nothing happened".
  int get droppedTombstones => _droppedTombstones;

  ImportReport get report => ImportReport(
    deferred: List<DeferredRow>.of(_deferred),
    deferredRows: {
      for (final entry in _rows.entries)
        entry.key: List<Map<String, dynamic>>.of(entry.value),
    },
  );
}

/// Thrown when a snapshot exported by a NEWER build is handed to an OLDER
/// one to import.
///
/// This is `SchemaDowngradeException` (`lib/core/db/schema_downgrade.dart`)
/// arriving through the restore door instead of the database-open door, and
/// it is deliberately named, worded and framed to match: one hazard, one
/// explanation. There, an older shell opened a newer local database; here,
/// an older shell imports a snapshot whose rows were shaped by a newer
/// schema. The local one is effectively unreachable on native (binary and
/// schema ship together) and only bites on web via a stale cached shell.
/// THIS one is reachable everywhere and needs no staleness at all: phone A
/// updates and pushes, phone B is still on last week's build and pulls. Two
/// devices on one account is the ordinary case, not the edge case.
///
/// Why refuse the whole restore rather than import what fits:
///  - drift's generated `fromJson` reads only the columns it knows and
///    silently ignores the rest, so a newer row imports "successfully" minus
///    every field this build has never heard of, and a table added after
///    this build simply vanishes. Nothing throws; the loss is invisible.
///  - [exportSnapshot] then re-exports those truncated rows stamped with the
///    OLDER `schemaVersion`, and the next push overwrites the cloud backup
///    with the lossy copy. The newer data's only remaining copy is on the
///    device that wrote it. A partial restore is therefore not "some data is
///    better than none" — it is the mechanism that destroys the good copy.
///  - Refusing costs the user one app update. Importing costs them fields
///    they will not know are gone until they look for them.
///
/// The refusal is total and non-destructive, and the message says so because
/// it is true: [importSnapshot] throws before its first transaction opens and
/// [CloudBackupService.pullBackup] throws before it downloads a single photo
/// byte, so neither the local database nor the cloud row nor the photos
/// directory is touched on this path.
///
/// A missing or non-`int` `schemaVersion` is NOT this error. It means "no
/// claim was made", which is the shape `SyncService` hands [importSnapshot]
/// on every pull (`{'tables': ...}`, no version key) and the shape any
/// snapshot predating the field would have. Treating absence as fatal would
/// lock users out of their own backups and break sync outright, so absence
/// falls through to the ordinary import path.
class SnapshotSchemaDowngradeException implements Exception {
  const SnapshotSchemaDowngradeException({
    required this.snapshotVersion,
    required this.appVersion,
  });

  /// The schema version the snapshot claims it was exported at.
  final int snapshotVersion;

  /// `AppDatabase.schemaVersion` of the build trying to import it.
  final int appVersion;

  @override
  String toString() =>
      'This version of the app is older than the backup you are restoring, '
      'so it refused to import it rather than damage your library. Nothing '
      'has been changed or deleted, and the backup is still in the cloud '
      'exactly as it was. Update this device to the current version of the '
      'app and restore again. On the web that means reloading the page; if '
      'you are offline, reconnect first, because the reload has to fetch it. '
      '(SnapshotSchemaDowngradeException: backup snapshot schema version '
      '$snapshotVersion, this build understands version $appVersion)';
}

/// Exports/imports the entire local database as a plain JSON-serializable
/// [Map], for cloud backup + restore.
///
/// [exportSnapshot] reads ALL rows of every table, INCLUDING soft-deleted
/// tombstones (`deletedAt` set) — existing repositories filter tombstones
/// out for UI reads, but a backup must be a faithful mirror of local state
/// so a restore doesn't resurrect a logically-deleted row as "not deleted".
///
/// [importSnapshot] first refuses outright — before any row is read or any
/// transaction opens — a snapshot stamped with a `schemaVersion` NEWER than
/// this build's, throwing [SnapshotSchemaDowngradeException]. An absent or
/// unreadable stamp is not a refusal; see that class for both halves of the
/// reasoning. Otherwise it upserts every row by its `id` primary key, in FK
/// dependency order (Profiles → Areas → Sectors → Walls → Photos → Routes →
/// Ascents → Comments → Likes), and writes every row `dirty: false` — see
/// [_notDirty] for why that is a correctness requirement, not a detail.
/// Each table is imported inside its OWN
/// [db.AppDatabase.transaction] rather than one transaction wrapping every
/// table, so a malformed row that throws in one table only rolls back that
/// table — every other table that already imported successfully persists.
/// Any table that fails is recorded and importing continues with the rest;
/// once all tables have been attempted, [importSnapshot] throws a single
/// aggregate error if any table failed (callers still see a thrown error,
/// but the tables that succeeded are not rolled back because of it). Photos
/// has a self-FK (`parentPhotoId`), so within Photos, rows with no parent
/// (originals) are always imported before rows that reference a parent
/// (slices), regardless of the order they appear in the snapshot.
///
/// FK-dependency ORDER alone is not enough, though, and the missing half was a
/// live sync failure ("own rows import failed: FOREIGN KEY constraint failed",
/// 3 tables at once): a row can reference a parent that is in NO table of this
/// snapshot at all. Every child row is therefore FK-CHECKED against the actual
/// parent ids present (in the DB, after the parent tables of this same import
/// have been applied) before its insert is attempted; a row whose parent is
/// missing is DEFERRED — not inserted, not dropped — and returned verbatim in
/// the [ImportReport] for the caller to re-import once the parent arrives. See
/// [DeferredRow] for why the own-rows batch legitimately contains such rows and
/// how `SyncService.pullOwnAndShared` resolves them within the same pull.
class BackupRepository {
  BackupRepository(this._db);

  final db.AppDatabase _db;

  /// The schema version this build understands — the number
  /// [exportSnapshot] stamps into every snapshot and the ceiling
  /// [importSnapshot] refuses to import above.
  ///
  /// Exposed so [CloudBackupService.pullBackup] can apply the same ceiling to
  /// the `backups` row's `schema_version` COLUMN (which never reaches
  /// [importSnapshot]) without reaching past this repository for the database.
  int get appSchemaVersion => _db.schemaVersion;

  /// Throws [SnapshotSchemaDowngradeException] when [declaredVersion] is a
  /// version this build is too old to import.
  ///
  /// `null` and non-`int` values are "no claim was made", not "incompatible":
  /// see the class doc for why absence must stay importable.
  void assertRestorable(Object? declaredVersion) {
    if (declaredVersion is int && declaredVersion > _db.schemaVersion) {
      throw SnapshotSchemaDowngradeException(
        snapshotVersion: declaredVersion,
        appVersion: _db.schemaVersion,
      );
    }
  }

  Future<Map<String, dynamic>> exportSnapshot() async {
    final profiles = await _db.select(_db.profiles).get();
    final areas = await _db.select(_db.areas).get();
    final sectors = await _db.select(_db.sectors).get();
    final walls = await _db.select(_db.walls).get();
    final photos = await _db.select(_db.photos).get();
    final routes = await _db.select(_db.routes).get();
    final routeLines = await _db.select(_db.routeLines).get();
    final comments = await _db.select(_db.comments).get();
    final likes = await _db.select(_db.likes).get();
    final ascents = await _db.select(_db.ascents).get();

    return {
      'schemaVersion': _db.schemaVersion,
      'tables': {
        'profiles': [for (final row in profiles) row.toJson()],
        'areas': [for (final row in areas) row.toJson()],
        'sectors': [for (final row in sectors) row.toJson()],
        'walls': [for (final row in walls) row.toJson()],
        'photos': [for (final row in photos) row.toJson()],
        'routes': [for (final row in routes) row.toJson()],
        'route_lines': [for (final row in routeLines) row.toJson()],
        'comments': [for (final row in comments) row.toJson()],
        'likes': [for (final row in likes) row.toJson()],
        'ascents': [for (final row in ascents) row.toJson()],
      },
    };
  }

  /// Imports [snapshot], returning what it could NOT write — see
  /// [ImportReport]/[DeferredRow]. A clean import returns
  /// [ImportReport.clean]-shaped (empty) report; a table that genuinely FAILED
  /// (a malformed row, a decode error) still throws the aggregate [StateError]
  /// described on this class, which is a different thing from a deferral.
  Future<ImportReport> importSnapshot(
    Map<String, dynamic> snapshot, {
    ConflictMode mode = ConflictMode.replace,
  }) async {
    // FIRST statement, before `tables` is even read and long before the
    // first transaction opens: a snapshot from a newer build must not have
    // one row of it reach this database. This is the choke point every
    // restore funnels through, so the guard here covers callers that never
    // saw a `schema_version` column — see [SnapshotSchemaDowngradeException].
    assertRestorable(snapshot['schemaVersion']);

    final tables = (snapshot['tables'] as Map).cast<String, dynamic>();
    final failures = <String>[];
    final sink = _DeferralSink();

    // Runs one table's import inside its OWN transaction and isolates its
    // failure: if `run` throws, only that table's transaction rolls back —
    // tables already imported by earlier calls stay committed, and import
    // continues with the remaining tables instead of aborting the whole
    // section. This is the fix for the all-or-nothing bug where a single
    // malformed row anywhere in a snapshot rolled back every table.
    Future<void> importTable(String name, Future<void> Function() run) async {
      try {
        await _db.transaction(run);
      } catch (e) {
        failures.add('$name: $e');
        debugPrint('importSnapshot: table "$name" failed to import: $e');
      }
    }

    // Profiles have no FK deps (their `id` is the owning uid, not a
    // caller-generated one referencing anything else), so they're
    // imported first — matches [syncTableNames]'s ordering.
    await importTable(
      'profiles',
      () => _importProfiles(_rowsOf(tables, 'profiles'), mode),
    );
    await importTable(
      'areas',
      () => _importAreas(_rowsOf(tables, 'areas'), mode),
    );
    await importTable(
      'sectors',
      () => _importSectors(_rowsOf(tables, 'sectors'), mode, sink),
    );
    await importTable(
      'walls',
      () => _importWalls(_rowsOf(tables, 'walls'), mode, sink),
    );
    await importTable(
      'photos',
      () => _importPhotos(_rowsOf(tables, 'photos'), mode, sink),
    );
    await importTable(
      'routes',
      () => _importRoutes(_rowsOf(tables, 'routes'), mode, sink),
    );
    // After routes AND photos, both of which a line references.
    await importTable(
      'route_lines',
      () => _importRouteLines(_rowsOf(tables, 'route_lines'), mode, sink),
    );
    // Ascents must be imported BEFORE Comments/Likes: Feature #12 (public
    // opt-in ascent logs) added `Comments.ascentId`/`Likes.ascentId` FKs
    // referencing `Ascents.id` (in addition to their pre-existing `wallId`
    // FK), so a comment/like attached to an ascent would violate the FK
    // (`PRAGMA foreign_keys = ON`) if imported before that ascent exists.
    // Because each table now imports independently, a failed parent table
    // (e.g. Walls) may cause a child table (e.g. Routes) to legitimately
    // FK-violate and fail too — that's correct per-table isolation, not a
    // bug: each failure is still independent and recorded below.
    await importTable(
      'ascents',
      () => _importAscents(_rowsOf(tables, 'ascents'), mode, sink),
    );
    await importTable(
      'comments',
      () => _importComments(_rowsOf(tables, 'comments'), mode, sink),
    );
    await importTable(
      'likes',
      () => _importLikes(_rowsOf(tables, 'likes'), mode, sink),
    );

    if (failures.isNotEmpty) {
      throw StateError(
        'importSnapshot: ${failures.length} table(s) failed: '
        '${failures.join('; ')}',
      );
    }

    return sink.report;
  }

  /// The `id`s currently present in [sqlTable] — the FK-parent presence set
  /// every child-table import below checks a row against before attempting its
  /// insert.
  ///
  /// Reads the `id` COLUMN only (not whole rows), and includes soft-deleted
  /// tombstones deliberately: a tombstone is a perfectly real row as far as
  /// SQLite's FK enforcement is concerned, so a child pointing at a tombstoned
  /// parent IS importable and must not be deferred. (This is also why
  /// tombstone-skipping was never the cause of the live FK failure — nothing
  /// here or in `SyncRemote`'s fetches filters on `deletedAt` at all.)
  ///
  /// [sqlTable] is always one of this file's own hard-coded generated
  /// snake_case table names — never anything derived from a snapshot — so the
  /// interpolation carries no injection surface.
  Future<Set<String>> _existingIds(String sqlTable) async {
    final rows = await _db.customSelect('SELECT id FROM $sqlTable').get();
    return {for (final row in rows) row.read<String>('id')};
  }

  /// The first FK in [checks] whose non-null parent id is absent from its
  /// presence set, or `null` when every FK resolves. A `null` parent id (an
  /// optional FK, e.g. `Comments.wallId` since Feature #12) always resolves.
  (String, String)? _firstMissingFk(
    List<(String, String?, Set<String>)> checks,
  ) {
    for (final (column, parentId, presentIds) in checks) {
      if (parentId != null && !presentIds.contains(parentId)) {
        return (column, parentId);
      }
    }
    return null;
  }

  List<Map<String, dynamic>> _rowsOf(Map<String, dynamic> tables, String key) {
    final raw = tables[key] as List<dynamic>? ?? const [];
    return [for (final item in raw) (item as Map).cast<String, dynamic>()];
  }

  /// True when an incoming row (with `updatedAt` [incomingUpdatedAt]) should
  /// overwrite the local row, given the local row's `updatedAt`
  /// ([localUpdatedAt], null if no local row exists).
  bool _shouldWriteLww({
    required int? localUpdatedAt,
    required int incomingUpdatedAt,
  }) => localUpdatedAt == null || incomingUpdatedAt > localUpdatedAt;

  /// Every row arriving through [importSnapshot] is written `dirty: false`,
  /// unconditionally, whatever the incoming payload says.
  ///
  /// TWO reasons, both load-bearing:
  ///  1. S9 — an imported row is BY DEFINITION not a local change awaiting a
  ///     push. `importSnapshot`'s writes fire the same `tableUpdates()`
  ///     `SyncOrchestrator` debounces on, so before this every pull that
  ///     wrote anything scheduled a full re-push ~2s later. Now that the
  ///     push is gated on `dirty` (see `SyncService.hasPendingLocalChanges`),
  ///     a pull's writes are correctly invisible to it.
  ///  2. Decodability — `SyncService.pushOwn` no longer SENDS `dirty`/
  ///     `remoteId` (see `stripLocalOnlySyncColumns`), so a cloud row fetched
  ///     back may lack the key entirely, or carry the Postgres column default
  ///     rather than anything meaningful. `<Table>.fromJson`'s
  ///     `serializer.fromJson<bool>(json['dirty'])` throws on a null, so the
  ///     key must always be present here. Forcing it AFTER the spread (rather
  ///     than defaulting it before, the way `visibility`/`sortOrder`/
  ///     `isPrimary` are defaulted in [_importWalls]/[_importPhotos]/
  ///     [_importAscents]) is deliberate: those are "absent means use the
  ///     column default", this is "whatever arrived is wrong".
  static Map<String, dynamic> _notDirty(Map<String, dynamic> json) => {
    ...json,
    'dirty': false,
  };

  Future<void> _importProfiles(
    List<Map<String, dynamic>> rows,
    ConflictMode mode,
  ) async {
    final existing = mode == ConflictMode.lww
        ? {
            for (final r in await _db.select(_db.profiles).get())
              r.id: r.updatedAt,
          }
        : const <String, int>{};

    for (final json in rows) {
      final profile = db.Profile.fromJson(_notDirty(json));
      if (mode == ConflictMode.lww &&
          !_shouldWriteLww(
            localUpdatedAt: existing[profile.id],
            incomingUpdatedAt: profile.updatedAt,
          )) {
        continue;
      }
      await _db.into(_db.profiles).insertOnConflictUpdate(profile);
    }
  }

  Future<void> _importAreas(
    List<Map<String, dynamic>> rows,
    ConflictMode mode,
  ) async {
    final existing = mode == ConflictMode.lww
        ? {for (final r in await _db.select(_db.areas).get()) r.id: r.updatedAt}
        : const <String, int>{};

    for (final json in rows) {
      final area = db.Area.fromJson(_notDirty(json));
      if (mode == ConflictMode.lww &&
          !_shouldWriteLww(
            localUpdatedAt: existing[area.id],
            incomingUpdatedAt: area.updatedAt,
          )) {
        continue;
      }
      await _db.into(_db.areas).insertOnConflictUpdate(area);
    }
  }

  Future<void> _importSectors(
    List<Map<String, dynamic>> rows,
    ConflictMode mode,
    _DeferralSink sink,
  ) async {
    final existing = mode == ConflictMode.lww
        ? {
            for (final r in await _db.select(_db.sectors).get())
              r.id: r.updatedAt,
          }
        : const <String, int>{};
    final areaIds = await _existingIds('areas');

    for (final json in rows) {
      final sector = db.Sector.fromJson(_notDirty(json));
      if (mode == ConflictMode.lww &&
          !_shouldWriteLww(
            localUpdatedAt: existing[sector.id],
            incomingUpdatedAt: sector.updatedAt,
          )) {
        continue;
      }
      final missing = _firstMissingFk([('areaId', sector.areaId, areaIds)]);
      if (missing != null) {
        sink.defer(
          table: 'sectors',
          id: sector.id,
          column: missing.$1,
          missingParentId: missing.$2,
          json: json,
        );
        continue;
      }
      await _db.into(_db.sectors).insertOnConflictUpdate(sector);
    }
  }

  Future<void> _importWalls(
    List<Map<String, dynamic>> rows,
    ConflictMode mode,
    _DeferralSink sink,
  ) async {
    final existing = mode == ConflictMode.lww
        ? {for (final r in await _db.select(_db.walls).get()) r.id: r.updatedAt}
        : const <String, int>{};
    final sectorIds = await _existingIds('sectors');

    for (final json in rows) {
      // `visibility` (schema v2) is absent from pre-v2 snapshots; default it to
      // the column's DB default so cross-version restore/sync never crashes on
      // a non-null String cast in Wall.fromJson. Any value present in `json` wins.
      final wall = db.Wall.fromJson(
        _notDirty({'visibility': 'private', ...json}),
      );
      if (mode == ConflictMode.lww &&
          !_shouldWriteLww(
            localUpdatedAt: existing[wall.id],
            incomingUpdatedAt: wall.updatedAt,
          )) {
        continue;
      }
      final missing = _firstMissingFk([('sectorId', wall.sectorId, sectorIds)]);
      if (missing != null) {
        sink.defer(
          table: 'walls',
          id: wall.id,
          column: missing.$1,
          missingParentId: missing.$2,
          json: json,
        );
        continue;
      }
      await _db.into(_db.walls).insertOnConflictUpdate(wall);
    }
  }

  /// Imports Photos with originals (no `parentPhotoId`) inserted before
  /// slices (`parentPhotoId` set), regardless of the order they appear in
  /// [rows] — required so the self-FK never points at a not-yet-inserted
  /// row while `PRAGMA foreign_keys = ON`.
  Future<void> _importPhotos(
    List<Map<String, dynamic>> rows,
    ConflictMode mode,
    _DeferralSink sink,
  ) async {
    final existing = mode == ConflictMode.lww
        ? {
            for (final r in await _db.select(_db.photos).get())
              r.id: r.updatedAt,
          }
        : const <String, int>{};
    final wallIds = await _existingIds('walls');
    // GROWS as rows land: a slice's `parentPhotoId` may point at an original
    // being inserted in this very pass (originals go first, below), so the
    // presence set has to include what this loop has already written, not just
    // what the DB held when the pass started.
    final photoIds = await _existingIds('photos');

    // Old backup snapshots predate the `sortOrder`/`isPrimary` columns (added
    // in schema v6) entirely, so their photo JSON has no such keys. Inject
    // defaults matching the DB column defaults (sortOrder: 0, isPrimary:
    // false) before decoding, so importing a legacy snapshot doesn't throw a
    // null-cast error in the generated `Photo.fromJson`.
    final photos = [
      for (final json in rows)
        db.Photo.fromJson(
          _notDirty({'sortOrder': 0, 'isPrimary': false, ...json}),
        ),
    ];
    final originals = photos.where((p) => p.parentPhotoId == null);
    final slices = photos.where((p) => p.parentPhotoId != null);

    // Index the raw JSON by id so a deferral can carry the row back verbatim
    // (the decoded `Photo` had defaults injected above; the caller re-imports
    // through this same door, so the ORIGINAL json is what must be preserved).
    final jsonById = {for (final json in rows) json['id'] as String?: json};

    for (final photo in [...originals, ...slices]) {
      if (mode == ConflictMode.lww &&
          !_shouldWriteLww(
            localUpdatedAt: existing[photo.id],
            incomingUpdatedAt: photo.updatedAt,
          )) {
        continue;
      }
      final missing = _firstMissingFk([
        ('wallId', photo.wallId, wallIds),
        ('parentPhotoId', photo.parentPhotoId, photoIds),
      ]);
      if (missing != null) {
        sink.defer(
          table: 'photos',
          id: photo.id,
          column: missing.$1,
          missingParentId: missing.$2,
          json: jsonById[photo.id] ?? photo.toJson(),
        );
        continue;
      }
      await _db.into(_db.photos).insertOnConflictUpdate(photo);
      photoIds.add(photo.id);
    }
  }

  Future<void> _importRoutes(
    List<Map<String, dynamic>> rows,
    ConflictMode mode,
    _DeferralSink sink,
  ) async {
    final existing = mode == ConflictMode.lww
        ? {
            for (final r in await _db.select(_db.routes).get())
              r.id: r.updatedAt,
          }
        : const <String, int>{};
    final wallIds = await _existingIds('walls');
    final photoIds = await _existingIds('photos');

    for (final json in rows) {
      final route = db.Route.fromJson(_notDirty(json));
      if (mode == ConflictMode.lww &&
          !_shouldWriteLww(
            localUpdatedAt: existing[route.id],
            incomingUpdatedAt: route.updatedAt,
          )) {
        continue;
      }
      final missing = _firstMissingFk([
        ('wallId', route.wallId, wallIds),
        ('photoId', route.photoId, photoIds),
      ]);
      if (missing != null) {
        sink.defer(
          table: 'routes',
          id: route.id,
          column: missing.$1,
          missingParentId: missing.$2,
          json: json,
        );
        continue;
      }
      await _parkCollidingRouteNumber(route);
      await _db.into(_db.routes).insertOnConflictUpdate(route);
    }
  }

  /// Moves a DIFFERENT local climb off the number [incoming] is arriving with,
  /// so the write below cannot trip `idx_routes_wall_number_live`.
  ///
  /// `insertOnConflictUpdate` resolves conflicts on the PRIMARY KEY only, so
  /// the local partial unique index on `(wallId, number)` is a hard failure
  /// rather than an upsert — and one throw here fails the whole pull. The
  /// window is real and gets wider the more numbers move: another device
  /// renumbers a wall left to right ([RouteRepository.renumberByPosition]),
  /// pushes both halves of a swap, and this loop applies them ONE AT A TIME,
  /// so the first arrival lands on a number the second row still holds.
  ///
  /// Parking the other row at the wall's next free number rather than at a
  /// negative one keeps it a state the app can render — the pull is very
  /// likely carrying that row too, moments later, with its real number; if it
  /// is not, the owner's next open renumbers the wall and tidies it. A
  /// negative would show up in the legend as "Route -2" until then.
  ///
  /// Server-side there is no such constraint (verified 2026-09-02: `routes`
  /// carries only its primary key and two non-unique indexes), so nothing
  /// here needs to hold on the way out.
  Future<void> _parkCollidingRouteNumber(db.Route incoming) async {
    // Written with a plain fetch-and-filter rather than drift's expression
    // builders: this file deliberately imports only `Value` from drift (see
    // the import), and a wall's live routes are a handful of rows.
    final live = await _db.select(_db.routes).get();
    final onWall = [
      for (final r in live)
        if (r.wallId == incoming.wallId && r.deletedAt == null) r,
    ];
    final clash = onWall
        .where((r) => r.number == incoming.number && r.id != incoming.id)
        .firstOrNull;
    if (clash == null) return;

    var free = clash.number;
    for (final r in onWall) {
      if (r.number > free) free = r.number;
    }
    free += 1;
    await (_db.update(_db.routes)..where((t) => t.id.equals(clash.id))).write(
      // NOT marked dirty: this is a local shuffle to make somebody else's
      // write land, not an edit of ours to push back at them.
      db.RoutesCompanion(number: Value(free)),
    );
  }

  Future<void> _importRouteLines(
    List<Map<String, dynamic>> rows,
    ConflictMode mode,
    _DeferralSink sink,
  ) async {
    final existing = mode == ConflictMode.lww
        ? {
            for (final r in await _db.select(_db.routeLines).get())
              r.id: r.updatedAt,
          }
        : const <String, int>{};
    final routeIds = await _existingIds('routes');
    final photoIds = await _existingIds('photos');

    for (final json in rows) {
      final line = db.RouteLine.fromJson(_notDirty(json));
      if (mode == ConflictMode.lww &&
          !_shouldWriteLww(
            localUpdatedAt: existing[line.id],
            incomingUpdatedAt: line.updatedAt,
          )) {
        continue;
      }
      final missing = _firstMissingFk([
        ('routeId', line.routeId, routeIds),
        ('photoId', line.photoId, photoIds),
      ]);
      if (missing != null) {
        sink.defer(
          table: 'route_lines',
          id: line.id,
          column: missing.$1,
          missingParentId: missing.$2,
          json: json,
        );
        continue;
      }
      await _db.into(_db.routeLines).insertOnConflictUpdate(line);
    }
  }

  Future<void> _importComments(
    List<Map<String, dynamic>> rows,
    ConflictMode mode,
    _DeferralSink sink,
  ) async {
    final existing = mode == ConflictMode.lww
        ? {
            for (final r in await _db.select(_db.comments).get())
              r.id: r.updatedAt,
          }
        : const <String, int>{};
    final wallIds = await _existingIds('walls');
    final ascentIds = await _existingIds('ascents');

    for (final json in rows) {
      final comment = db.Comment.fromJson(_notDirty(json));
      if (mode == ConflictMode.lww &&
          !_shouldWriteLww(
            localUpdatedAt: existing[comment.id],
            incomingUpdatedAt: comment.updatedAt,
          )) {
        continue;
      }
      final missing = _firstMissingFk([
        ('wallId', comment.wallId, wallIds),
        ('ascentId', comment.ascentId, ascentIds),
      ]);
      if (missing != null) {
        sink.defer(
          table: 'comments',
          id: comment.id,
          column: missing.$1,
          missingParentId: missing.$2,
          json: json,
        );
        continue;
      }
      await _db.into(_db.comments).insertOnConflictUpdate(comment);
    }
  }

  Future<void> _importLikes(
    List<Map<String, dynamic>> rows,
    ConflictMode mode,
    _DeferralSink sink,
  ) async {
    final existing = mode == ConflictMode.lww
        ? {for (final r in await _db.select(_db.likes).get()) r.id: r.updatedAt}
        : const <String, int>{};
    final wallIds = await _existingIds('walls');
    final ascentIds = await _existingIds('ascents');

    for (final json in rows) {
      final like = db.Like.fromJson(_notDirty(json));
      if (mode == ConflictMode.lww &&
          !_shouldWriteLww(
            localUpdatedAt: existing[like.id],
            incomingUpdatedAt: like.updatedAt,
          )) {
        continue;
      }
      final missing = _firstMissingFk([
        ('wallId', like.wallId, wallIds),
        ('ascentId', like.ascentId, ascentIds),
      ]);
      if (missing != null) {
        sink.defer(
          table: 'likes',
          id: like.id,
          column: missing.$1,
          missingParentId: missing.$2,
          json: json,
        );
        continue;
      }
      await _db.into(_db.likes).insertOnConflictUpdate(like);
    }
  }

  /// Ascents may arrive here for TWO distinct reasons (Feature #12, public
  /// opt-in ascent logs): the signed-in user's own full row set (private or
  /// shared, imported via `SyncService.pullOwnAndShared`'s "own" call), or
  /// another owner's opt-in-`visibility == 'shared'` ascents (imported via
  /// its separate "shared" call, sourced from `SyncRemote.fetchSharedAscents`
  /// — NEVER from `fetchSharedTopos`, which still excludes ascents
  /// entirely). This import method itself stays agnostic to which case it's
  /// handling — it just imports whatever rows it's handed, importing BEFORE
  /// Comments/Likes (see the FK-ordering comment in [importSnapshot]) so
  /// their `ascentId` FK never points at a not-yet-inserted row. The privacy
  /// boundary (who gets to see whose ascents) lives one layer up, in what
  /// each `SyncRemote` fetch method chooses to return.
  Future<void> _importAscents(
    List<Map<String, dynamic>> rows,
    ConflictMode mode,
    _DeferralSink sink,
  ) async {
    final existing = mode == ConflictMode.lww
        ? {
            for (final r in await _db.select(_db.ascents).get())
              r.id: r.updatedAt,
          }
        : const <String, int>{};
    // The pair that produced the live failure: an ascent the signed-in user
    // logged on ANOTHER owner's shared route. `fetchOwnRows` can only see rows
    // whose `ownerId` is the caller, so neither parent is in the own batch.
    final routeIds = await _existingIds('routes');
    final wallIds = await _existingIds('walls');

    for (final json in rows) {
      // `visibility` (Feature #12) is absent from pre-#12 snapshots; default it
      // to the column's DB default so cross-version restore/sync never crashes
      // on a non-null String cast in Ascent.fromJson. Any value present in
      // `json` wins.
      final ascent = db.Ascent.fromJson(
        _notDirty({'visibility': 'private', ...json}),
      );
      if (mode == ConflictMode.lww &&
          !_shouldWriteLww(
            localUpdatedAt: existing[ascent.id],
            incomingUpdatedAt: ascent.updatedAt,
          )) {
        continue;
      }
      final missing = _firstMissingFk([
        ('routeId', ascent.routeId, routeIds),
        ('wallId', ascent.wallId, wallIds),
      ]);
      if (missing != null) {
        sink.defer(
          table: 'ascents',
          id: ascent.id,
          column: missing.$1,
          missingParentId: missing.$2,
          json: json,
        );
        continue;
      }
      await _db.into(_db.ascents).insertOnConflictUpdate(ascent);
    }
  }
}
