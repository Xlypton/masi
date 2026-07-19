import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/db/app_database.dart' as db;
import '../../../core/grades/grade_system.dart';
import '../../topo/data/photo_files.dart';

/// Immutable read model for a non-deleted Area row.
class AreaRef {
  const AreaRef({required this.id, required this.name, this.description});

  final String id;
  final String name;
  final String? description;

  @override
  bool operator ==(Object other) =>
      other is AreaRef &&
      other.id == id &&
      other.name == name &&
      other.description == description;

  @override
  int get hashCode => Object.hash(id, name, description);

  @override
  String toString() =>
      'AreaRef(id: $id, name: $name, description: $description)';
}

/// Immutable read model for a non-deleted Sector row.
class SectorRef {
  const SectorRef({
    required this.id,
    required this.areaId,
    required this.name,
    required this.sortOrder,
  });

  final String id;
  final String areaId;
  final String name;
  final int sortOrder;

  @override
  bool operator ==(Object other) =>
      other is SectorRef &&
      other.id == id &&
      other.areaId == areaId &&
      other.name == name &&
      other.sortOrder == sortOrder;

  @override
  int get hashCode => Object.hash(id, areaId, name, sortOrder);

  @override
  String toString() =>
      'SectorRef(id: $id, areaId: $areaId, name: $name, '
      'sortOrder: $sortOrder)';
}

/// Immutable read model for a non-deleted Wall row.
class WallRef {
  const WallRef({
    required this.id,
    required this.sectorId,
    required this.name,
    required this.sortOrder,
  });

  final String id;
  final String sectorId;
  final String name;
  final int sortOrder;

  @override
  bool operator ==(Object other) =>
      other is WallRef &&
      other.id == id &&
      other.sectorId == sectorId &&
      other.name == name &&
      other.sortOrder == sortOrder;

  @override
  int get hashCode => Object.hash(id, sectorId, name, sortOrder);

  @override
  String toString() =>
      'WallRef(id: $id, sectorId: $sectorId, name: $name, '
      'sortOrder: $sortOrder)';
}

/// Immutable read model for a flat "topo" row: a non-deleted Wall paired
/// with its live `kind:'original'` photo (as a thumbnail path, if any), a
/// live count of its non-deleted routes, and the wall's representative grade
/// (the hardest non-deleted, graded route on the wall). Backs the flat
/// Topos-home list.
class TopoRef {
  const TopoRef({
    required this.wallId,
    required this.name,
    required this.thumbnailPath,
    required this.routeCount,
    required this.createdAt,
    this.topGradeLabel,
    this.topGradeBand,
    this.visibility = 'private',
    this.areaId,
    this.areaName,
    this.routeGradeKeys = const [],
    this.latitude,
    this.longitude,
  });

  final String wallId;
  final String name;
  final String? thumbnailPath;
  final int routeCount;
  final int createdAt;

  /// Display label ([db.Route.gradeRaw]) of the hardest non-deleted, graded
  /// route on this wall, or `null` if the wall has no graded routes.
  final String? topGradeLabel;

  /// [GradeBand] (classified via `core/grades`'s [bandForSortKey] from the
  /// hardest route's `gradeSortKey`) matching [topGradeLabel]. Always
  /// non-null exactly when [topGradeLabel] is non-null.
  final GradeBand? topGradeBand;

  /// This wall's [db.Wall.visibility]: `'private'` (default; owner-only) or
  /// `'shared'` (published to Community — see [LibraryCrudRepository.
  /// publishTopo]/[LibraryCrudRepository.unpublishTopo]). Backs the Topos
  /// home row's Publish/Unpublish menu item.
  final String visibility;

  /// The id of this topo's ancestor Area (Wall -> Sector -> Area), or `null`
  /// when the wall is filed under the hidden `__default__` sentinel Area
  /// (see [LibraryCrudRepository._ensureDefaultAreaId]/[LibraryCrudRepository
  /// .createTopo]) -- treated as "Unfiled" by the Topos-home area filter
  /// (see `ToposFilter` in `library_providers.dart`). Never the sentinel's
  /// own id -- see [watchTopos]'s doc for the detection.
  final String? areaId;

  /// The display name of [areaId]'s Area, or `null` under the same
  /// conditions as [areaId] (including when the wall has no area at all).
  final String? areaName;

  /// The `gradeSortKey` of every live (non-deleted), graded route on this
  /// wall, deduplicated (via `group_concat(DISTINCT ...)`) and sorted
  /// ascending -- parsed from [watchTopos]'s `route_grade_keys` column.
  /// Empty when the wall has no graded routes. Used to filter the Topos
  /// home by grade range (see `ToposFilter.matches` in
  /// `library_providers.dart`): a topo matches an active `GradeRange` iff
  /// ANY of its route grade keys falls in range.
  final List<double> routeGradeKeys;

  /// Coordinates captured directly on this wall (see [db.Walls.latitude]/
  /// [db.Walls.longitude], populated automatically from a freshly-picked
  /// photo's EXIF GPS tags via [LibraryCrudRepository.setWallCoordinates]),
  /// or `null` if none have been recorded. Mirrors `SharedTopo.latitude`/
  /// `longitude` in `community_repository.dart` — backs the Community map's
  /// "own topos" markers (see `_MapView` in `community_screen.dart`).
  final double? latitude;
  final double? longitude;

  @override
  bool operator ==(Object other) =>
      other is TopoRef &&
      other.wallId == wallId &&
      other.name == name &&
      other.thumbnailPath == thumbnailPath &&
      other.routeCount == routeCount &&
      other.createdAt == createdAt &&
      other.topGradeLabel == topGradeLabel &&
      other.topGradeBand == topGradeBand &&
      other.visibility == visibility &&
      other.areaId == areaId &&
      other.areaName == areaName &&
      _listEquals(other.routeGradeKeys, routeGradeKeys) &&
      other.latitude == latitude &&
      other.longitude == longitude;

  @override
  int get hashCode => Object.hash(
    wallId,
    name,
    thumbnailPath,
    routeCount,
    createdAt,
    topGradeLabel,
    topGradeBand,
    visibility,
    areaId,
    areaName,
    Object.hashAll(routeGradeKeys),
    Object.hash(latitude, longitude),
  );

  @override
  String toString() =>
      'TopoRef(wallId: $wallId, name: $name, thumbnailPath: $thumbnailPath, '
      'routeCount: $routeCount, createdAt: $createdAt, '
      'topGradeLabel: $topGradeLabel, topGradeBand: $topGradeBand, '
      'visibility: $visibility, areaId: $areaId, areaName: $areaName, '
      'routeGradeKeys: $routeGradeKeys, latitude: $latitude, '
      'longitude: $longitude)';
}

/// Order-sensitive element-wise equality for [TopoRef.routeGradeKeys] (a
/// plain `List<double>` doesn't override `==` to mean "same elements");
/// safe to compare positionally since [_parseGradeKeys] sorts its output,
/// keeping repeated parses of the same underlying data deterministic.
/// Mirrors `CommunityRepository`'s analogous `SharedTopo.routeGradeKeys`
/// helper.
bool _listEquals(List<double> a, List<double> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

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

/// Immutable read model for a single non-deleted [db.Route] whose wall has
/// recorded GPS coordinates ([db.Walls.latitude]/[longitude] non-null) —
/// i.e. a route that can be placed on the map. Backs the map search's route
/// results (see `mapContentSearch` in
/// `features/community/data/map_search.dart`); returned by
/// [LibraryCrudRepository.watchLocatedRoutes].
class LocatedRouteRef {
  const LocatedRouteRef({
    required this.routeId,
    required this.number,
    this.name,
    required this.wallId,
    required this.wallName,
    required this.latitude,
    required this.longitude,
  });

  final String routeId;
  final int number;

  /// The route's own name, or `null`/empty when the climber never named it.
  /// See [title] for the display fallback.
  final String? name;

  final String wallId;

  /// The name of this route's wall (its "topo") — used as the map search
  /// result's subtitle for a route hit.
  final String wallName;

  /// This route's wall's GPS coordinates — a route has no coordinates of
  /// its own (see `db.Routes`' doc in `core/db/tables.dart`), so it is
  /// placed wherever its wall is.
  final double latitude;
  final double longitude;

  /// Display title: [name] if non-empty (after trimming), else `'Route
  /// &lt;number&gt;'`. Mirrors how `topo_canvas_screen.dart` labels an
  /// unnamed route in its route list.
  String get title {
    final trimmed = name?.trim();
    return (trimmed != null && trimmed.isNotEmpty) ? trimmed : 'Route $number';
  }

  @override
  bool operator ==(Object other) =>
      other is LocatedRouteRef &&
      other.routeId == routeId &&
      other.number == number &&
      other.name == name &&
      other.wallId == wallId &&
      other.wallName == wallName &&
      other.latitude == latitude &&
      other.longitude == longitude;

  @override
  int get hashCode =>
      Object.hash(routeId, number, name, wallId, wallName, latitude, longitude);

  @override
  String toString() =>
      'LocatedRouteRef(routeId: $routeId, number: $number, name: $name, '
      'wallId: $wallId, wallName: $wallName, latitude: $latitude, '
      'longitude: $longitude)';
}

/// Immutable read model for a non-deleted [db.Sector] that has at least one
/// located descendant wall ([db.Walls.latitude]/[longitude] non-null) —
/// [latitude]/[longitude] are the arithmetic-mean centroid over exactly
/// those located walls (see [LibraryCrudRepository.watchLocatedSectors]). A
/// sector with zero located walls has no [LocatedSectorRef] at all — there
/// is deliberately no all-zero/fallback instance.
class LocatedSectorRef {
  const LocatedSectorRef({
    required this.id,
    required this.name,
    required this.latitude,
    required this.longitude,
  });

  final String id;
  final String name;

  /// Centroid latitude/longitude over this sector's located walls.
  final double latitude;
  final double longitude;

  @override
  bool operator ==(Object other) =>
      other is LocatedSectorRef &&
      other.id == id &&
      other.name == name &&
      other.latitude == latitude &&
      other.longitude == longitude;

  @override
  int get hashCode => Object.hash(id, name, latitude, longitude);

  @override
  String toString() =>
      'LocatedSectorRef(id: $id, name: $name, latitude: $latitude, '
      'longitude: $longitude)';
}

/// Immutable read model for a non-deleted [db.Area] that has at least one
/// located wall anywhere under its sectors — [latitude]/[longitude] are the
/// arithmetic-mean centroid over ALL of the area's located walls across ALL
/// of its sectors (NOT the mean of each sector's own centroid — see
/// [LibraryCrudRepository.watchLocatedAreas]). An area with zero located
/// walls has no [LocatedAreaRef] at all, same exclusion rule as
/// [LocatedSectorRef].
class LocatedAreaRef {
  const LocatedAreaRef({
    required this.id,
    required this.name,
    required this.latitude,
    required this.longitude,
  });

  final String id;
  final String name;

  /// Centroid latitude/longitude over every located wall under this area
  /// (through all of its sectors).
  final double latitude;
  final double longitude;

  @override
  bool operator ==(Object other) =>
      other is LocatedAreaRef &&
      other.id == id &&
      other.name == name &&
      other.latitude == latitude &&
      other.longitude == longitude;

  @override
  int get hashCode => Object.hash(id, name, latitude, longitude);

  @override
  String toString() =>
      'LocatedAreaRef(id: $id, name: $name, latitude: $latitude, '
      'longitude: $longitude)';
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
  }) : _photoFiles = photoFiles ?? PhotoFiles();

  final db.AppDatabase _db;
  final int Function() nowMs;

  /// The Supabase Auth uid of the signed-in user (or `null` if signed out),
  /// read lazily at each INSERT to stamp the new row's `ownerId`. Defaults
  /// to always-`null` so existing constructors/tests that don't pass this
  /// keep their pre-sync-pivot signed-out behavior unchanged.
  final String? Function() currentUid;

  static String? _noUid() => null;

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

  Future<AreaRef> createArea(String name, {String? description}) async {
    final now = nowMs();
    final id = _uuid.v4();
    await _db
        .into(_db.areas)
        .insert(
          db.AreasCompanion.insert(
            id: id,
            createdAt: now,
            updatedAt: now,
            name: name,
            description: Value(description),
            ownerId: Value(currentUid()),
          ),
        );
    return AreaRef(id: id, name: name, description: description);
  }

  Future<void> renameArea(String id, String name) async {
    final now = nowMs();
    await (_db.update(_db.areas)
          ..where((t) => t.id.equals(id) & t.deletedAt.isNull()))
        .write(db.AreasCompanion(name: Value(name), updatedAt: Value(now)));
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

  Future<SectorRef> createSector(String areaId, String name) async {
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
            areaId: areaId,
            name: name,
            sortOrder: sortOrder,
            ownerId: Value(currentUid()),
          ),
        );
    return SectorRef(id: id, areaId: areaId, name: name, sortOrder: sortOrder);
  }

  Future<void> renameSector(String id, String name) async {
    final now = nowMs();
    await (_db.update(_db.sectors)
          ..where((t) => t.id.equals(id) & t.deletedAt.isNull()))
        .write(db.SectorsCompanion(name: Value(name), updatedAt: Value(now)));
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
    await (_db.update(_db.walls)
          ..where((t) => t.id.equals(id) & t.deletedAt.isNull()))
        .write(db.WallsCompanion(name: Value(name), updatedAt: Value(now)));
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
  /// shape [_setWallVisibility] uses (rather than [renameWall]'s, which
  /// leaves `dirty` untouched): coordinates, like visibility, need to reach
  /// the backend on the next push.
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
    await (_db.update(
      _db.walls,
    )..where((t) => t.id.equals(wallId) & t.deletedAt.isNull())).write(
      db.WallsCompanion(
        latitude: Value(latitude),
        longitude: Value(longitude),
        updatedAt: Value(now),
        dirty: const Value(true),
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
      await (_db.update(
        _db.walls,
      )..where((t) => t.id.equals(wallId) & t.deletedAt.isNull())).write(
        db.WallsCompanion(
          sectorId: Value(newSectorId),
          sortOrder: Value(sortOrder),
          updatedAt: Value(now),
          dirty: const Value(true),
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
      await (_db.update(
        _db.sectors,
      )..where((t) => t.id.equals(sectorId) & t.deletedAt.isNull())).write(
        db.SectorsCompanion(
          areaId: Value(newAreaId),
          sortOrder: Value(sortOrder),
          updatedAt: Value(now),
          dirty: const Value(true),
        ),
      );
    });
  }

  Future<void> _setWallVisibility(String wallId, String visibility) async {
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

  /// Attaches a freshly-picked photo at [localPath] to [wallId] as an
  /// `original`, returning the new photo's id.
  ///
  /// The picked file is COPIED into the app-owned `photos/` directory under
  /// the new row's id (via [PhotoFiles.importPhoto]) and it is THAT app-owned
  /// path — not the transient picker-cache path handed in — that is stored as
  /// `localPath`. This closes a latent local-loss bug (the OS may evict the
  /// picker cache out from under a row that still references it) and makes the
  /// path portable for cloud backup. The copy is best-effort: if the source
  /// doesn't exist (or the copy fails), [PhotoFiles.importPhoto] returns
  /// [localPath] unchanged so the row is still created.
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
    String localPath,
    int width,
    int height,
  ) async {
    final now = nowMs();
    final id = _uuid.v4();
    final ownedPath = await _photoFiles.importPhoto(localPath, id);
    final liveOriginalCount = await _liveOriginalCount(wallId);
    await _db
        .into(_db.photos)
        .insert(
          db.PhotosCompanion.insert(
            id: id,
            createdAt: now,
            updatedAt: now,
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
  /// the owned one before any same-session slice commit reads it. This
  /// closes the confirmed photo-ownership bug where slicing a
  /// freshly-attached photo in the same session persisted the raw
  /// picker-cache path onto every slice row instead of the owned copy.
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
  /// Tiebreak note: the outer ordering, the thumbnail subquery, and the
  /// top-grade subquery all order by their respective columns DESC at
  /// coarse resolution (ms for `created_at`, and `grade_sort_key` ties are
  /// possible whenever two routes share a grade), which isn't fine-grained
  /// enough to distinguish ties. All three add a secondary `id DESC`
  /// tiebreak for deterministic, stable output across repeated reads; since
  /// ids are random UUIDs this tiebreak is arbitrary but consistent, not a
  /// proxy for "more recent" or "harder".
  Stream<List<TopoRef>> watchTopos() {
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
      ORDER BY w.created_at DESC, w.id DESC
    ''';
    return _db
        .customSelect(
          sql,
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
          // open-a-wall paths (loadOriginal/loadSlices/photoLocalPath),
          // not here. See PhotoFiles.resolvePhotoPathSync for the cold-cache
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

  /// Resolves a stored thumbnail `localPath` to an absolute display path via
  /// [PhotoFiles.resolvePhotoPathSync] (synchronous, for the [watchTopos]
  /// stream), passing `null` through unchanged (walls with no photo).
  String? _resolveThumbnail(String? storedThumbnailPath) {
    if (storedThumbnailPath == null) return null;
    return _photoFiles.resolvePhotoPathSync(storedThumbnailPath).path;
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
        AVG(w.longitude) AS avg_longitude
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
        AVG(w.longitude) AS avg_longitude
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
    final area = await createArea(_defaultAreaName);
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
    final sector = await createSector(areaId, _defaultSectorName);
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
    final sectors = await (_db.select(
      _db.sectors,
    )..where((t) => t.areaId.equals(areaId) & t.deletedAt.isNull())).get();
    for (final sector in sectors) {
      await _cascadeSoftDeleteSectorSubtree(sector.id, now);
    }
    await (_db.update(_db.areas)
          ..where((t) => t.id.equals(areaId) & t.deletedAt.isNull()))
        .write(db.AreasCompanion(deletedAt: Value(now), updatedAt: Value(now)));
  }

  Future<void> _cascadeSoftDeleteSectorSubtree(String sectorId, int now) async {
    final walls = await (_db.select(
      _db.walls,
    )..where((t) => t.sectorId.equals(sectorId) & t.deletedAt.isNull())).get();
    for (final wall in walls) {
      await _cascadeSoftDeleteWallSubtree(wall.id, now);
    }
    await (_db.update(
      _db.sectors,
    )..where((t) => t.id.equals(sectorId) & t.deletedAt.isNull())).write(
      db.SectorsCompanion(deletedAt: Value(now), updatedAt: Value(now)),
    );
  }

  Future<void> _cascadeSoftDeleteWallSubtree(String wallId, int now) async {
    await (_db.update(
      _db.photos,
    )..where((t) => t.wallId.equals(wallId) & t.deletedAt.isNull())).write(
      db.PhotosCompanion(deletedAt: Value(now), updatedAt: Value(now)),
    );
    await (_db.update(
      _db.routes,
    )..where((t) => t.wallId.equals(wallId) & t.deletedAt.isNull())).write(
      db.RoutesCompanion(deletedAt: Value(now), updatedAt: Value(now)),
    );
    await (_db.update(_db.walls)
          ..where((t) => t.id.equals(wallId) & t.deletedAt.isNull()))
        .write(db.WallsCompanion(deletedAt: Value(now), updatedAt: Value(now)));
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
  /// Wired to fire once per sign-in from `ClimbTopoApp`'s
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
