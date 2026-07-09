import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/db/app_database.dart' as db;

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
  LibraryCrudRepository(this._db, {required this.nowMs});

  final db.AppDatabase _db;
  final int Function() nowMs;

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
          ),
        );
    return AreaRef(id: id, name: name, description: description);
  }

  Future<void> renameArea(String id, String name) async {
    final now = nowMs();
    await (_db.update(
      _db.areas,
    )..where((t) => t.id.equals(id) & t.deletedAt.isNull())).write(
      db.AreasCompanion(name: Value(name), updatedAt: Value(now)),
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
      await _cascadeSoftDeleteAreaSubtree(id, nowMs());
    });
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
          ),
        );
    return SectorRef(id: id, areaId: areaId, name: name, sortOrder: sortOrder);
  }

  Future<void> renameSector(String id, String name) async {
    final now = nowMs();
    await (_db.update(
      _db.sectors,
    )..where((t) => t.id.equals(id) & t.deletedAt.isNull())).write(
      db.SectorsCompanion(name: Value(name), updatedAt: Value(now)),
    );
  }

  Future<List<SectorRef>> listSectors(String areaId) async {
    final rows = await _sectorQuery(areaId).get();
    return rows.map(_sectorRefFromRow).toList();
  }

  Stream<List<SectorRef>> watchSectors(String areaId) {
    return _sectorQuery(areaId).watch().map(
      (rows) => rows.map(_sectorRefFromRow).toList(),
    );
  }

  Future<void> softDeleteSector(String id) {
    return _db.transaction(() async {
      await _cascadeSoftDeleteSectorSubtree(id, nowMs());
    });
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
          ),
        );
    return WallRef(id: id, sectorId: sectorId, name: name, sortOrder: sortOrder);
  }

  Future<void> renameWall(String id, String name) async {
    final now = nowMs();
    await (_db.update(
      _db.walls,
    )..where((t) => t.id.equals(id) & t.deletedAt.isNull())).write(
      db.WallsCompanion(name: Value(name), updatedAt: Value(now)),
    );
  }

  Future<List<WallRef>> listWalls(String sectorId) async {
    final rows = await _wallQuery(sectorId).get();
    return rows.map(_wallRefFromRow).toList();
  }

  Stream<List<WallRef>> watchWalls(String sectorId) {
    return _wallQuery(sectorId).watch().map(
      (rows) => rows.map(_wallRefFromRow).toList(),
    );
  }

  Future<void> softDeleteWall(String id) {
    return _db.transaction(() async {
      await _cascadeSoftDeleteWallSubtree(id, nowMs());
    });
  }

  // ---------------------------------------------------------------------
  // Photos
  // ---------------------------------------------------------------------

  Future<String> attachPhotoToWall(
    String wallId,
    String localPath,
    int width,
    int height,
  ) async {
    final now = nowMs();
    final id = _uuid.v4();
    await _db
        .into(_db.photos)
        .insert(
          db.PhotosCompanion.insert(
            id: id,
            createdAt: now,
            updatedAt: now,
            wallId: wallId,
            localPath: localPath,
            kind: 'original',
            width: width,
            height: height,
          ),
        );
    return id;
  }

  // ---------------------------------------------------------------------
  // Query builders
  // ---------------------------------------------------------------------

  SimpleSelectStatement<db.$AreasTable, db.Area> _areaQuery() {
    return _db.select(_db.areas)
      ..where((t) => t.deletedAt.isNull())
      ..orderBy([
        (t) => OrderingTerm(expression: t.name),
        (t) => OrderingTerm(expression: t.createdAt),
      ]);
  }

  SimpleSelectStatement<db.$SectorsTable, db.Sector> _sectorQuery(
    String areaId,
  ) {
    return _db.select(_db.sectors)
      ..where((t) => t.areaId.equals(areaId) & t.deletedAt.isNull())
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
    await (_db.update(
      _db.areas,
    )..where((t) => t.id.equals(areaId) & t.deletedAt.isNull())).write(
      db.AreasCompanion(deletedAt: Value(now), updatedAt: Value(now)),
    );
  }

  Future<void> _cascadeSoftDeleteSectorSubtree(
    String sectorId,
    int now,
  ) async {
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
    await (_db.update(
      _db.walls,
    )..where((t) => t.id.equals(wallId) & t.deletedAt.isNull())).write(
      db.WallsCompanion(deletedAt: Value(now), updatedAt: Value(now)),
    );
  }
}
