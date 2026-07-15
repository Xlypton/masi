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
  int get schemaVersion => 4;

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
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );
}
