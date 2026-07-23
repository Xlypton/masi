import 'package:flutter/foundation.dart' show debugPrint;

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

/// Exports/imports the entire local database as a plain JSON-serializable
/// [Map], for cloud backup + restore.
///
/// [exportSnapshot] reads ALL rows of every table, INCLUDING soft-deleted
/// tombstones (`deletedAt` set) — existing repositories filter tombstones
/// out for UI reads, but a backup must be a faithful mirror of local state
/// so a restore doesn't resurrect a logically-deleted row as "not deleted".
///
/// [importSnapshot] upserts every row by its `id` primary key, in FK
/// dependency order (Profiles → Areas → Sectors → Walls → Photos → Routes →
/// Ascents → Comments → Likes). Each table is imported inside its OWN
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
class BackupRepository {
  BackupRepository(this._db);

  final db.AppDatabase _db;

  Future<Map<String, dynamic>> exportSnapshot() async {
    final profiles = await _db.select(_db.profiles).get();
    final areas = await _db.select(_db.areas).get();
    final sectors = await _db.select(_db.sectors).get();
    final walls = await _db.select(_db.walls).get();
    final photos = await _db.select(_db.photos).get();
    final routes = await _db.select(_db.routes).get();
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
        'comments': [for (final row in comments) row.toJson()],
        'likes': [for (final row in likes) row.toJson()],
        'ascents': [for (final row in ascents) row.toJson()],
      },
    };
  }

  Future<void> importSnapshot(
    Map<String, dynamic> snapshot, {
    ConflictMode mode = ConflictMode.replace,
  }) async {
    final tables = (snapshot['tables'] as Map).cast<String, dynamic>();
    final failures = <String>[];

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
      () => _importSectors(_rowsOf(tables, 'sectors'), mode),
    );
    await importTable(
      'walls',
      () => _importWalls(_rowsOf(tables, 'walls'), mode),
    );
    await importTable(
      'photos',
      () => _importPhotos(_rowsOf(tables, 'photos'), mode),
    );
    await importTable(
      'routes',
      () => _importRoutes(_rowsOf(tables, 'routes'), mode),
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
      () => _importAscents(_rowsOf(tables, 'ascents'), mode),
    );
    await importTable(
      'comments',
      () => _importComments(_rowsOf(tables, 'comments'), mode),
    );
    await importTable(
      'likes',
      () => _importLikes(_rowsOf(tables, 'likes'), mode),
    );

    if (failures.isNotEmpty) {
      throw StateError(
        'importSnapshot: ${failures.length} table(s) failed: '
        '${failures.join('; ')}',
      );
    }
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

  Future<void> _importProfiles(
    List<Map<String, dynamic>> rows,
    ConflictMode mode,
  ) async {
    final existing = mode == ConflictMode.lww
        ? {for (final r in await _db.select(_db.profiles).get()) r.id: r.updatedAt}
        : const <String, int>{};

    for (final json in rows) {
      final profile = db.Profile.fromJson(json);
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
      final area = db.Area.fromJson(json);
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
  ) async {
    final existing = mode == ConflictMode.lww
        ? {for (final r in await _db.select(_db.sectors).get()) r.id: r.updatedAt}
        : const <String, int>{};

    for (final json in rows) {
      final sector = db.Sector.fromJson(json);
      if (mode == ConflictMode.lww &&
          !_shouldWriteLww(
            localUpdatedAt: existing[sector.id],
            incomingUpdatedAt: sector.updatedAt,
          )) {
        continue;
      }
      await _db.into(_db.sectors).insertOnConflictUpdate(sector);
    }
  }

  Future<void> _importWalls(
    List<Map<String, dynamic>> rows,
    ConflictMode mode,
  ) async {
    final existing = mode == ConflictMode.lww
        ? {for (final r in await _db.select(_db.walls).get()) r.id: r.updatedAt}
        : const <String, int>{};

    for (final json in rows) {
      // `visibility` (schema v2) is absent from pre-v2 snapshots; default it to
      // the column's DB default so cross-version restore/sync never crashes on
      // a non-null String cast in Wall.fromJson. Any value present in `json` wins.
      final wall = db.Wall.fromJson({'visibility': 'private', ...json});
      if (mode == ConflictMode.lww &&
          !_shouldWriteLww(
            localUpdatedAt: existing[wall.id],
            incomingUpdatedAt: wall.updatedAt,
          )) {
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
  ) async {
    final existing = mode == ConflictMode.lww
        ? {for (final r in await _db.select(_db.photos).get()) r.id: r.updatedAt}
        : const <String, int>{};

    // Old backup snapshots predate the `sortOrder`/`isPrimary` columns (added
    // in schema v6) entirely, so their photo JSON has no such keys. Inject
    // defaults matching the DB column defaults (sortOrder: 0, isPrimary:
    // false) before decoding, so importing a legacy snapshot doesn't throw a
    // null-cast error in the generated `Photo.fromJson`.
    final photos = [
      for (final json in rows)
        db.Photo.fromJson({
          'sortOrder': 0,
          'isPrimary': false,
          ...json,
        }),
    ];
    final originals = photos.where((p) => p.parentPhotoId == null);
    final slices = photos.where((p) => p.parentPhotoId != null);

    for (final photo in [...originals, ...slices]) {
      if (mode == ConflictMode.lww &&
          !_shouldWriteLww(
            localUpdatedAt: existing[photo.id],
            incomingUpdatedAt: photo.updatedAt,
          )) {
        continue;
      }
      await _db.into(_db.photos).insertOnConflictUpdate(photo);
    }
  }

  Future<void> _importRoutes(
    List<Map<String, dynamic>> rows,
    ConflictMode mode,
  ) async {
    final existing = mode == ConflictMode.lww
        ? {for (final r in await _db.select(_db.routes).get()) r.id: r.updatedAt}
        : const <String, int>{};

    for (final json in rows) {
      final route = db.Route.fromJson(json);
      if (mode == ConflictMode.lww &&
          !_shouldWriteLww(
            localUpdatedAt: existing[route.id],
            incomingUpdatedAt: route.updatedAt,
          )) {
        continue;
      }
      await _db.into(_db.routes).insertOnConflictUpdate(route);
    }
  }

  Future<void> _importComments(
    List<Map<String, dynamic>> rows,
    ConflictMode mode,
  ) async {
    final existing = mode == ConflictMode.lww
        ? {for (final r in await _db.select(_db.comments).get()) r.id: r.updatedAt}
        : const <String, int>{};

    for (final json in rows) {
      final comment = db.Comment.fromJson(json);
      if (mode == ConflictMode.lww &&
          !_shouldWriteLww(
            localUpdatedAt: existing[comment.id],
            incomingUpdatedAt: comment.updatedAt,
          )) {
        continue;
      }
      await _db.into(_db.comments).insertOnConflictUpdate(comment);
    }
  }

  Future<void> _importLikes(
    List<Map<String, dynamic>> rows,
    ConflictMode mode,
  ) async {
    final existing = mode == ConflictMode.lww
        ? {for (final r in await _db.select(_db.likes).get()) r.id: r.updatedAt}
        : const <String, int>{};

    for (final json in rows) {
      final like = db.Like.fromJson(json);
      if (mode == ConflictMode.lww &&
          !_shouldWriteLww(
            localUpdatedAt: existing[like.id],
            incomingUpdatedAt: like.updatedAt,
          )) {
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
  ) async {
    final existing = mode == ConflictMode.lww
        ? {for (final r in await _db.select(_db.ascents).get()) r.id: r.updatedAt}
        : const <String, int>{};

    for (final json in rows) {
      // `visibility` (Feature #12) is absent from pre-#12 snapshots; default it
      // to the column's DB default so cross-version restore/sync never crashes
      // on a non-null String cast in Ascent.fromJson. Any value present in
      // `json` wins.
      final ascent = db.Ascent.fromJson({'visibility': 'private', ...json});
      if (mode == ConflictMode.lww &&
          !_shouldWriteLww(
            localUpdatedAt: existing[ascent.id],
            incomingUpdatedAt: ascent.updatedAt,
          )) {
        continue;
      }
      await _db.into(_db.ascents).insertOnConflictUpdate(ascent);
    }
  }
}
