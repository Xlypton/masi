import 'package:drift/drift.dart';

import 'tables.dart';

part 'app_database.g.dart';

/// App-wide Drift database.
///
/// Tables declare real foreign-key references (Sectors.areaId -> Areas.id,
/// etc.), so FK enforcement is turned on for every connection via
/// [beforeOpen]. This catches dangling-reference bugs (e.g. inserting a
/// Route for a Photo that doesn't exist) at write time instead of silently
/// leaving orphaned rows.
@DriftDatabase(
  tables: [Areas, Sectors, Walls, Photos, Routes, Comments, Likes, Ascents],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  int get schemaVersion => 6;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      // v1 -> v2: row-level cloud-sync pivot (Phase 1). Adds a nullable
      // `ownerId` to every SyncColumns table (ADD COLUMN is non-destructive;
      // pre-existing rows come back with `ownerId == null`, i.e.
      // unattributed until a future `claimOwnership` backfill) plus a
      // `visibility` column (default `'private'`) on Walls only — the topo
      // = a Wall, and this is the sharing flag, deliberately distinct from
      // the existing per-route `visible` render flag.
      if (from < 2) {
        await m.addColumn(areas, areas.ownerId);
        await m.addColumn(sectors, sectors.ownerId);
        await m.addColumn(walls, walls.ownerId);
        await m.addColumn(photos, photos.ownerId);
        await m.addColumn(routes, routes.ownerId);
        await m.addColumn(walls, walls.visibility);
      }
      // v2 -> v3: adds community features (comments, likes, ascent logging)
      // as three brand-new tables, each carrying the full SyncColumns set
      // (id/createdAt/updatedAt/deletedAt/remoteId/dirty/ownerId) so they
      // slot into the same future sync pipeline as every other table.
      if (from < 3) {
        await m.createTable(comments);
        await m.createTable(likes);
        await m.createTable(ascents);
      }
      // v3 -> v4: adds nullable `latitude`/`longitude` to Walls, captured
      // automatically from a freshly-picked photo's EXIF GPS tags (see
      // `core/location/photo_gps.dart` + `LibraryCrudRepository.
      // setWallCoordinates`) so a topo can be placed on the Community map
      // without the user ever having to enter coordinates by hand. Plain
      // ADD COLUMN, so every pre-existing wall comes back with both `null`.
      if (from < 4) {
        await m.addColumn(walls, walls.latitude);
        await m.addColumn(walls, walls.longitude);
      }
      // v4 -> v5: per-route metadata (#41 beta-video URL, #42 style tags,
      // #44 0-3 star rating) — three nullable ADD COLUMNs on Routes, so
      // every pre-existing route comes back with all three `null`
      // (unrated / no tags / no beta link) rather than losing any data.
      if (from < 5) {
        await m.addColumn(routes, routes.betaVideoUrl);
        await m.addColumn(routes, routes.styleTagsJson);
        await m.addColumn(routes, routes.stars);
      }
      // v5 -> v6: multiple photos per topo, each with its own route overlay
      // (#46 fix + the underlying feature). Three parts:
      //
      // 1. ADD COLUMN `sortOrder`/`isPrimary` on Photos (display order among
      //    a wall's live originals, and which one is the "main" photo).
      // 2. Route numbers move from per-wall to per-photo uniqueness: the old
      //    `idx_routes_wall_number_live` partial index is dropped and
      //    replaced with `idx_routes_photo_number_live` (see `tables.dart`'s
      //    `@TableIndex.sql` on `Routes`, now expressing the new index — a
      //    fresh install gets it straight from `onCreate`/`createAll`, but an
      //    upgrading install needs it created explicitly here since
      //    `onUpgrade` never re-runs `createAll`).
      // 3. Data migration for the #46 bug itself: `attachPhotoToWall` always
      //    INSERTed a new `kind:'original'` row and never superseded the
      //    previous one, so some walls may already have accumulated 2+ live
      //    originals with nothing distinguishing them — `PhotoRepository.
      //    loadOriginal`'s old `getSingleOrNull()` throws on exactly that
      //    shape, and the canvas silently swallowed the throw (blank
      //    canvas). This backfill flags the NEWEST (max `createdAt`) live
      //    original per wall as `isPrimary`, and assigns `sortOrder`
      //    ascending by `createdAt` (0, 1, 2...) — no rows are deleted or
      //    altered beyond these two columns; it merely classifies data that
      //    was always there. Written defensively: walls with zero, one, or
      //    many live originals are all handled by the same loop.
      if (from < 6) {
        await m.addColumn(photos, photos.sortOrder);
        await m.addColumn(photos, photos.isPrimary);

        await customStatement(
          'DROP INDEX IF EXISTS idx_routes_wall_number_live',
        );
        await customStatement(
          'CREATE UNIQUE INDEX IF NOT EXISTS '
          'idx_routes_photo_number_live ON routes (photo_id, number) '
          'WHERE deleted_at IS NULL',
        );

        final wallsWithOriginals = await customSelect(
          "SELECT DISTINCT wall_id FROM photos "
          "WHERE kind = 'original' AND deleted_at IS NULL",
        ).get();

        for (final wallRow in wallsWithOriginals) {
          final wallId = wallRow.read<String>('wall_id');
          final originals = await customSelect(
            "SELECT id FROM photos WHERE wall_id = ? AND kind = 'original' "
            "AND deleted_at IS NULL ORDER BY created_at ASC, id ASC",
            variables: [Variable<String>(wallId)],
          ).get();

          for (var i = 0; i < originals.length; i++) {
            final photoId = originals[i].read<String>('id');
            final isNewest = i == originals.length - 1;
            await customStatement(
              'UPDATE photos SET sort_order = ?, is_primary = ? '
              'WHERE id = ?',
              [i, isNewest ? 1 : 0, photoId],
            );
          }
        }
      }
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );
}
