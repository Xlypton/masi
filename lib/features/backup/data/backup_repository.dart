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
/// [importSnapshot] upserts every row by its `id` primary key inside a
/// single [db.AppDatabase.transaction], in FK dependency order (Areas →
/// Sectors → Walls → Photos → Routes). Photos has a self-FK
/// (`parentPhotoId`), so within Photos, rows with no parent (originals) are
/// always imported before rows that reference a parent (slices), regardless
/// of the order they appear in the snapshot.
class BackupRepository {
  BackupRepository(this._db);

  final db.AppDatabase _db;

  Future<Map<String, dynamic>> exportSnapshot() async {
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

    await _db.transaction(() async {
      await _importAreas(_rowsOf(tables, 'areas'), mode);
      await _importSectors(_rowsOf(tables, 'sectors'), mode);
      await _importWalls(_rowsOf(tables, 'walls'), mode);
      await _importPhotos(_rowsOf(tables, 'photos'), mode);
      await _importRoutes(_rowsOf(tables, 'routes'), mode);
      // Comments/Likes reference Walls only (already imported above); Ascents
      // additionally references Routes (also already imported above), hence
      // all three are safely imported last regardless of FK dependency.
      await _importComments(_rowsOf(tables, 'comments'), mode);
      await _importLikes(_rowsOf(tables, 'likes'), mode);
      await _importAscents(_rowsOf(tables, 'ascents'), mode);
    });
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

    final photos = [for (final json in rows) db.Photo.fromJson(json)];
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

  /// Ascents are a private per-user logbook: pushed/pulled for their OWNER
  /// only. This import method itself is agnostic to that policy (it just
  /// imports whatever rows it's handed) — the privacy guarantee lives one
  /// layer up, in `SyncRemote.fetchSharedTopos` never returning an
  /// `'ascents'` key, so `SyncService.pullOwnAndShared` never hands this
  /// method any OTHER user's ascent rows.
  Future<void> _importAscents(
    List<Map<String, dynamic>> rows,
    ConflictMode mode,
  ) async {
    final existing = mode == ConflictMode.lww
        ? {for (final r in await _db.select(_db.ascents).get()) r.id: r.updatedAt}
        : const <String, int>{};

    for (final json in rows) {
      final ascent = db.Ascent.fromJson(json);
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
