import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/db/app_database.dart' as db;

/// Ensures a minimal Area/Sector/Wall/Photo hierarchy exists for an imported
/// image, so a freshly-picked photo always has somewhere to attach routes.
///
/// Design choice (documented, per subtask spec): [ensureDefaultForImage] is
/// idempotent per `localPath` — calling it twice with the same path returns
/// the same four ids and creates no new rows. A *different* `localPath`
/// always creates its own brand-new Area("Default")/Sector("Default")/
/// Wall("Default")/Photo chain rather than reusing one shared default
/// hierarchy. This keeps each imported photo's subtree independent and
/// independently deletable, at the cost of multiple "Default"-named
/// areas/sectors/walls accumulating over time — acceptable for M3, where
/// the library UI for renaming/merging these doesn't exist yet.
class LibraryRepository {
  LibraryRepository(this._db, {required this.nowMs});

  final db.AppDatabase _db;
  final int Function() nowMs;

  static const _uuid = Uuid();

  /// Returns the (area, sector, wall, photo) ids for [localPath], creating
  /// a new Default hierarchy if no non-deleted Photo row with that path
  /// exists yet.
  ///
  /// The whole check-then-create sequence runs inside a single
  /// [db.AppDatabase.transaction] so concurrent callers for the same
  /// [localPath] can't both observe "no existing photo" and each create
  /// their own duplicate Area/Sector/Wall/Photo chain: Drift serializes
  /// transactions against the same connection, so the second caller's
  /// SELECT only runs after the first caller's INSERTs are committed, and
  /// it correctly finds the row the first call created.
  Future<({String areaId, String sectorId, String wallId, String photoId})>
  ensureDefaultForImage(String localPath, int width, int height) {
    return _db.transaction(() async {
      final existingPhoto = await (_db.select(
        _db.photos,
      )..where((t) => t.localPath.equals(localPath) & t.deletedAt.isNull())).getSingleOrNull();

      if (existingPhoto != null) {
        final wall = await (_db.select(
          _db.walls,
        )..where((t) => t.id.equals(existingPhoto.wallId))).getSingle();
        final sector = await (_db.select(
          _db.sectors,
        )..where((t) => t.id.equals(wall.sectorId))).getSingle();
        return (
          areaId: sector.areaId,
          sectorId: sector.id,
          wallId: wall.id,
          photoId: existingPhoto.id,
        );
      }

      final now = nowMs();
      final areaId = _uuid.v4();
      final sectorId = _uuid.v4();
      final wallId = _uuid.v4();
      final photoId = _uuid.v4();

      await _db
          .into(_db.areas)
          .insert(
            db.AreasCompanion.insert(
              id: areaId,
              createdAt: now,
              updatedAt: now,
              name: 'Default',
            ),
          );
      await _db
          .into(_db.sectors)
          .insert(
            db.SectorsCompanion.insert(
              id: sectorId,
              createdAt: now,
              updatedAt: now,
              areaId: areaId,
              name: 'Default',
              sortOrder: 0,
            ),
          );
      await _db
          .into(_db.walls)
          .insert(
            db.WallsCompanion.insert(
              id: wallId,
              createdAt: now,
              updatedAt: now,
              sectorId: sectorId,
              name: 'Default',
              sortOrder: 0,
            ),
          );
      await _db
          .into(_db.photos)
          .insert(
            db.PhotosCompanion.insert(
              id: photoId,
              createdAt: now,
              updatedAt: now,
              wallId: wallId,
              localPath: localPath,
              kind: 'original',
              width: width,
              height: height,
            ),
          );

      return (
        areaId: areaId,
        sectorId: sectorId,
        wallId: wallId,
        photoId: photoId,
      );
    });
  }
}
