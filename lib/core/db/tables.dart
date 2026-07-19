import 'package:drift/drift.dart';

/// Shared sync-ready columns mixed into every table:
/// - [id]: caller-supplied UUIDv4 primary key (TEXT).
/// - [createdAt] / [updatedAt]: ms-epoch timestamps.
/// - [deletedAt]: nullable ms-epoch soft-delete tombstone.
/// - [remoteId]: nullable id assigned by the future sync backend.
/// - [dirty]: true when local changes haven't been pushed to the backend yet.
/// - [ownerId]: the Supabase Auth uid that created this row, or `null` for
///   rows created while signed-out (or created before this column existed —
///   see the v1->v2 migration in `app_database.dart`). Stamped once at
///   create time by each inserting repository's injected `currentUid` seam;
///   never overwritten on update. `null` rows can later be attributed to a
///   user via `LibraryCrudRepository.claimOwnership` once they sign in.
mixin SyncColumns on Table {
  TextColumn get id => text()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();
  IntColumn get deletedAt => integer().nullable()();
  TextColumn get remoteId => text().nullable()();
  BoolColumn get dirty => boolean().withDefault(const Constant(false))();
  TextColumn get ownerId => text().nullable()();
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

  /// Cloud-sharing visibility for this wall (a "topo"): `'private'` (default;
  /// visible only to its owner) or `'shared'`. Deliberately separate from
  /// [Routes.visible], which is a per-route render show/hide flag, not a
  /// sharing concept.
  TextColumn get visibility =>
      text().withDefault(const Constant('private'))();

  /// GPS coordinates for this wall/topo, captured automatically from a
  /// freshly-picked photo's EXIF GPS tags (see `core/location/photo_gps.dart`'s
  /// `extractGpsFromImageBytes` and `LibraryCrudRepository.setWallCoordinates`)
  /// — `null` until a photo with GPS EXIF has been attached. Unlike
  /// [Areas.latitude]/[Areas.longitude] (manually set, never actually
  /// populated by any UI as of v3), these are meant to be populated
  /// automatically and back the Community map (see `CommunityRepository.
  /// watchSharedTopos`).
  RealColumn get latitude => real().nullable()();
  RealColumn get longitude => real().nullable()();

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

  /// Display order among a wall's live `kind:'original'` photos (the
  /// multi-photo-per-topo strip) — 0-based, ascending. Meaningless for
  /// `kind:'slice'` rows (each slice's ordering is [cropXpct] instead).
  /// Backfilled ascending by `createdAt` for pre-existing rows by the v5->v6
  /// migration (see `app_database.dart`); set by
  /// `LibraryCrudRepository.attachPhotoToWall` (append-at-end) and
  /// `PhotoRepository.setPhotoOrder` (explicit reorder) thereafter.
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  /// Whether this is the wall's PRIMARY original — the one shown as the
  /// topo's thumbnail ([LibraryCrudRepository.watchTopos]) and returned by
  /// [PhotoRepository.loadOriginal] (the canvas's default photo to open).
  /// At most one live original per wall should ever have this `true` (the
  /// single-primary invariant enforced by
  /// [PhotoRepository.setPrimaryPhoto]/[PhotoRepository.deleteOriginalPhoto]
  /// and by [LibraryCrudRepository.attachPhotoToWall], which only flags a
  /// freshly-attached photo primary when the wall has no live original yet).
  /// Meaningless for `kind:'slice'` rows. Backfilled by the v5->v6 migration:
  /// the newest (max `createdAt`) live original on each wall is flagged
  /// primary — this SAFELY resolves the #46 bug's accumulated multi-original
  /// walls without deleting any row.
  BoolColumn get isPrimary => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

// Partial unique index enforcing that no two *live* (non-soft-deleted)
// routes on the same PHOTO share a `number` — route numbers are scoped per
// photo (each photo has its own overlay), not per wall, so two different
// photos on the same wall may each have their own "route 1". Soft-deleted
// tombstones (deletedAt IS NOT NULL) are excluded so a deleted route's old
// number can be reused by a new route without violating uniqueness.
// `TableIndex` in this drift version has no `where:` parameter on its
// column-list constructor, so the partial index is expressed via the
// raw-SQL `TableIndex.sql` variant instead (still validated by drift_dev at
// build time). Column/table names below are the generated snake_case names
// (`routes`, `photo_id`, `deleted_at`) confirmed against app_database.g.dart.
@TableIndex.sql(
  'CREATE UNIQUE INDEX idx_routes_photo_number_live ON routes (photo_id, number) WHERE deleted_at IS NULL',
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

  /// External beta-video URL (e.g. a YouTube/Instagram link) for this
  /// route. Free-form, validated only client-side (see
  /// `RouteMetadataSheet`) — `null` if unset.
  TextColumn get betaVideoUrl => text().nullable()();

  /// This route's style tags, encoded as a JSON array of strings via
  /// `core/routes/route_styles.dart`'s `encodeStyleTags`/`decodeStyleTags`
  /// (curated tags + arbitrary custom ones). `null` (rather than `'[]'`)
  /// when the route has no tags — `RouteRepository.upsertRoute` writes
  /// `null` for an empty tag list rather than the encoded empty array, so
  /// this column stays `null` for every route that predates this feature.
  TextColumn get styleTagsJson => text().nullable()();

  /// 0-3 star quality rating. `null` means unrated (distinct from `0`,
  /// which is an explicit "0 stars" rating).
  IntColumn get stars => integer().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class Comments extends Table with SyncColumns {
  TextColumn get wallId => text().references(Walls, #id)();
  TextColumn get body => text()();
  TextColumn get authorName => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class Likes extends Table with SyncColumns {
  TextColumn get wallId => text().references(Walls, #id)();

  @override
  Set<Column> get primaryKey => {id};
}

class Ascents extends Table with SyncColumns {
  TextColumn get routeId => text().references(Routes, #id)();
  TextColumn get wallId => text().references(Walls, #id)();
  IntColumn get climbedAt => integer()();
  TextColumn get style => text()();
  TextColumn get notes => text().nullable()();
  TextColumn get gradeOpinion => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}
