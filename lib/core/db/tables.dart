import 'package:drift/drift.dart';

/// Shared sync-ready columns mixed into every table:
/// - [id]: caller-supplied UUIDv4 primary key (TEXT).
/// - [createdAt] / [updatedAt]: ms-epoch timestamps.
/// - [deletedAt]: nullable ms-epoch soft-delete tombstone.
/// - [remoteId]: nullable id assigned by the future sync backend.
/// - [dirty]: true when local changes haven't been pushed to the backend yet.
mixin SyncColumns on Table {
  TextColumn get id => text()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();
  IntColumn get deletedAt => integer().nullable()();
  TextColumn get remoteId => text().nullable()();
  BoolColumn get dirty => boolean().withDefault(const Constant(false))();
}

class Areas extends Table with SyncColumns {
  TextColumn get name => text()();
  TextColumn get description => text().nullable()();
  RealColumn get latitude => real().nullable()();
  RealColumn get longitude => real().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class Sectors extends Table with SyncColumns {
  TextColumn get areaId => text().references(Areas, #id)();
  TextColumn get name => text()();
  IntColumn get sortOrder => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

class Walls extends Table with SyncColumns {
  TextColumn get sectorId => text().references(Sectors, #id)();
  TextColumn get name => text()();
  IntColumn get sortOrder => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

class Photos extends Table with SyncColumns {
  TextColumn get wallId => text().references(Walls, #id)();
  TextColumn get localPath => text()();
  // 'original' | 'slice'
  TextColumn get kind => text()();
  IntColumn get width => integer()();
  IntColumn get height => integer()();
  TextColumn get parentPhotoId => text().nullable().references(Photos, #id)();
  RealColumn get cropXpct => real().nullable()();
  RealColumn get cropWidthPct => real().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

// Partial unique index enforcing that no two *live* (non-soft-deleted)
// routes on the same wall share a `number`. Soft-deleted tombstones
// (deletedAt IS NOT NULL) are excluded so a deleted route's old number can
// be reused by a new route without violating uniqueness. `TableIndex` in
// this drift version has no `where:` parameter on its column-list
// constructor, so the partial index is expressed via the raw-SQL
// `TableIndex.sql` variant instead (still validated by drift_dev at build
// time). Column/table names below are the generated snake_case names
// (`routes`, `wall_id`, `deleted_at`) confirmed against app_database.g.dart.
@TableIndex.sql(
  'CREATE UNIQUE INDEX idx_routes_wall_number_live ON routes (wall_id, number) WHERE deleted_at IS NULL',
)
class Routes extends Table with SyncColumns {
  TextColumn get wallId => text().references(Walls, #id)();
  TextColumn get photoId => text().references(Photos, #id)();
  IntColumn get number => integer()();
  TextColumn get name => text().nullable()();
  TextColumn get gradeSystem => text().nullable()();
  TextColumn get gradeRaw => text().nullable()();
  RealColumn get gradeSortKey => real().nullable()();
  TextColumn get style => text().nullable()();
  TextColumn get description => text().nullable()();
  IntColumn get colorIndex => integer()();
  TextColumn get pointsJson => text()();
  TextColumn get symbolsJson => text()();
  IntColumn get sortOrder => integer()();
  BoolColumn get visible => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {id};
}
