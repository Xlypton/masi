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

/// LOCAL-ONLY key/value store for tiny device-scoped settings. Deliberately
/// does NOT mix in [SyncColumns] and is deliberately absent from
/// `syncTableNames` (`features/backup/data/sync_remote.dart`) and from
/// `BackupRepository`'s hand-enumerated export/import lists — both enumerate
/// tables explicitly, so nothing here can ever reach the cloud. This is where
/// state that must survive a *sign-out* lives, which is exactly why it must
/// not be owned by, keyed by, or synced with any account.
///
/// Introduced (schema v9) for `lastKnownUid` — see
/// `features/account/application/auth_providers.dart`'s `LastKnownUid`. Drift
/// is used rather than `shared_preferences` because it is the ONLY durable
/// local store this repo already has on both web (OPFS/IndexedDB) and native
/// (SQLite file), with one implementation and no conditional-import seam.
@DataClassName('AppSettingRow')
class AppSettings extends Table {
  /// Opaque setting name. Not called `key` — `KEY` is a SQLite keyword and
  /// `key` collides with `Widget.key` conventions in generated code.
  TextColumn get settingKey => text()();

  /// The setting's value, always TEXT (callers encode/decode). Nullable so a
  /// present-but-unset key is expressible; `SettingsStore.remove` deletes the
  /// row outright rather than nulling it.
  TextColumn get settingValue => text().nullable()();

  /// ms-epoch of the last write, from the injected `nowMs` clock seam — purely
  /// diagnostic (nothing reads it for behavior).
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => {settingKey};
}

/// Local, PULL-ONLY mirror of the server's `public.wall_moderation` — the
/// moderation state of a published topo (community editing, phase 1).
///
/// Deliberately NOT a [SyncColumns] table and deliberately NOT in
/// `syncTableNames`, and that is the whole point rather than an oversight.
/// The sync engine re-reads and re-pushes WHOLE rows with client-side
/// last-writer-wins where local wins ties (`shouldPushLww`), and it has no
/// outbox (decision D-4). So a moderation column on a synced table would be
/// silently reverted by the owner's very next push: a moderator approves a
/// topo, the owner's client re-sends its own stale copy of that row, and the
/// decision is gone. Not maliciously — that is simply what the engine does.
/// See COMMUNITY_PLAN.md §0 (guardrail G-1).
///
/// Consequently this table has exactly one direction of travel: pulled from
/// the server, written locally, never sent back. The server enforces the same
/// thing from its side — `public.wall_moderation` has a SELECT policy and no
/// write policy at all, so a client attempting to push is refused by RLS
/// regardless of what any local code does.
///
/// It is mirrored locally (rather than read live) so a moderation banner
/// renders from cold and offline, exactly like every other read in this
/// local-first app.
@DataClassName('WallModerationRow')
class WallModerationRows extends Table {
  /// The moderated wall's id. Not a Drift `references(Walls, #id)` FK: rows
  /// arrive from the server pull, and a moderation row can legitimately land
  /// for a wall this device has not pulled yet (or has since dropped), which
  /// a real FK with `PRAGMA foreign_keys = ON` would reject outright.
  TextColumn get wallId => text()();

  /// `draft` | `pending` | `published` | `rejected` | `withdrawn` | `removed`.
  /// Stored as the raw server string and parsed at the edge (see
  /// `ModerationState.fromWire`) so an unknown future state degrades to a
  /// safe default instead of throwing on read.
  TextColumn get state => text()();

  IntColumn get submittedAt => integer().nullable()();
  IntColumn get reviewedAt => integer().nullable()();
  TextColumn get reviewerId => text().nullable()();

  /// Why a submission was rejected, shown to the owner. A silent rejection
  /// teaches nobody anything.
  TextColumn get rejectionReason => text().nullable()();

  /// When the owner asked to withdraw, or null. The topo stays visible for
  /// 10 days from this instant (C-3) — a window the SERVER evaluates inside
  /// its visibility predicate, so this column is for showing the countdown,
  /// never for deciding visibility.
  IntColumn get withdrawRequestedAt => integer().nullable()();

  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => {wallId};
}

/// A signed-in user's editable, synced display name (#18).
///
/// Unlike every other [SyncColumns] table, [id] here is NOT a caller-
/// generated UUIDv4 — it IS the Supabase Auth uid (`auth.uid()`), so a
/// profile row's [SyncColumns.ownerId] is always equal to its own [id]
/// (stamped that way by `ProfileRepository.setMyDisplayName`; there is no
/// signed-out profile row, since there is no uid to key one by). This makes
/// "my profile" and "resolve display name for uid X" the same lookup
/// (`profiles.id == uid`), and lets `SyncRemote.fetchOwnRows`'s generic
/// `ownerId = auth.uid()` scoping fetch exactly one row — the caller's own —
/// with no special-casing.
class Profiles extends Table with SyncColumns {
  /// The user-chosen display name shown in place of their email/uid
  /// wherever another user's identity is surfaced (Community feed,
  /// comments, ascent logs, ...). `null` until the user sets one.
  TextColumn get displayName => text().nullable()();

  /// The user's profile picture, or `null` for "no picture" (callers fall
  /// back to the initials chip). Two shapes are valid and both render:
  ///
  ///  - an `https://` URL — what an OAuth provider hands over in the
  ///    session's user metadata (Google's `avatar_url`/`picture`). Not
  ///    stored here by the app; it is read live off the session and only
  ///    used when this column is null, so it can never go stale.
  ///  - a `data:image/...;base64,...` URL — a picture the user chose
  ///    themselves. Stored inline rather than uploaded to Supabase Storage
  ///    because that needs no bucket, no storage RLS and no second failure
  ///    mode: the picture is downscaled to at most 512px and rides the
  ///    profile row through the EXISTING sync engine, so it works offline
  ///    (write now, push on the next pull, per decision D-4's no-outbox
  ///    model) and arrives with any other user's profile for free.
  TextColumn get avatarUrl => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class Areas extends Table with SyncColumns {
  TextColumn get name => text()();
  TextColumn get description => text().nullable()();
  RealColumn get latitude => real().nullable()();
  RealColumn get longitude => real().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

// FK LOOKUP INDEX. SQLite does NOT index a foreign key just because it is
// declared as one — only the parent's PRIMARY KEY gets an implicit index — so
// every `where(sectorId.equals(...))`-shaped read is a full table scan until an
// index like this exists. See the block comment above `Routes` for why all of
// these are PARTIAL on `deleted_at IS NULL`.
@TableIndex.sql(
  'CREATE INDEX idx_sectors_area_live ON sectors (area_id) '
  'WHERE deleted_at IS NULL',
)
class Sectors extends Table with SyncColumns {
  TextColumn get areaId => text().references(Areas, #id)();
  TextColumn get name => text()();
  IntColumn get sortOrder => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

@TableIndex.sql(
  'CREATE INDEX idx_walls_sector_live ON walls (sector_id) '
  'WHERE deleted_at IS NULL',
)
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

// `parent_photo_id` gets its own index because slice lookups
// (`parentPhotoId.equals(photoId)`) are a distinct access path from the
// wall-scoped photo list, and neither index can serve the other.
@TableIndex.sql(
  'CREATE INDEX idx_photos_wall_live ON photos (wall_id) '
  'WHERE deleted_at IS NULL',
)
@TableIndex.sql(
  'CREATE INDEX idx_photos_parent_live ON photos (parent_photo_id) '
  'WHERE deleted_at IS NULL',
)
class Photos extends Table with SyncColumns {
  TextColumn get wallId => text().references(Walls, #id)();
  TextColumn get localPath => text()();
  // 'original' | 'slice' — 'slice' is DEPRECATED/DORMANT: the photo
  // cut/slice feature was removed (2026-07-20); no code path writes
  // `kind: 'slice'` rows anymore, but any pre-existing ones are left as-is
  // (soft-delete-only, never queried by current code) rather than migrated,
  // since a Drift column/value drop needs a risky table-recreate. See
  // [cropXpct]/[cropWidthPct]'s docs.
  TextColumn get kind => text()();
  IntColumn get width => integer()();
  IntColumn get height => integer()();
  TextColumn get parentPhotoId => text().nullable().references(Photos, #id)();

  /// DEPRECATED/DORMANT (slice feature removed 2026-07-20): only ever
  /// populated on legacy `kind:'slice'` rows, which are no longer created or
  /// read by any code path. Left in place (nullable, unused) rather than
  /// dropped, to avoid a Drift table-recreate migration for two columns that
  /// cost nothing sitting idle. Do not read or write these in new code.
  RealColumn get cropXpct => real().nullable()();

  /// DEPRECATED/DORMANT — see [cropXpct].
  RealColumn get cropWidthPct => real().nullable()();

  /// Display order among a wall's live `kind:'original'` photos (the
  /// multi-photo-per-topo strip) — 0-based, ascending. Backfilled ascending
  /// by `createdAt` for pre-existing rows by the v5->v6 migration (see
  /// `app_database.dart`); set by `LibraryCrudRepository.attachPhotoToWall`
  /// (append-at-end) and `PhotoRepository.setPhotoOrder` (explicit reorder)
  /// thereafter.
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  /// Whether this is the wall's PRIMARY original — the one shown as the
  /// topo's thumbnail ([LibraryCrudRepository.watchTopos]) and returned by
  /// [PhotoRepository.loadOriginal] (the canvas's default photo to open).
  /// At most one live original per wall should ever have this `true` (the
  /// single-primary invariant enforced by
  /// [PhotoRepository.setPrimaryPhoto]/[PhotoRepository.deleteOriginalPhoto]
  /// and by [LibraryCrudRepository.attachPhotoToWall], which only flags a
  /// freshly-attached photo primary when the wall has no live original yet).
  /// Backfilled by the v5->v6 migration: the newest (max `createdAt`) live
  /// original on each wall is flagged primary — this SAFELY resolves the
  /// #46 bug's accumulated multi-original walls without deleting any row.
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
//
// WHY EVERY INDEX IN THIS FILE IS PARTIAL ON `deleted_at IS NULL`: deletes here
// are soft (a tombstone row that stays for sync), and essentially every read
// pairs its FK filter with `deletedAt.isNull()` — 84 such call sites across the
// repositories. A partial index therefore matches the real query predicate,
// covers only live rows, and lets the tombstones a long-lived library
// accumulates sit outside the index entirely instead of bloating it.
//
// `idx_routes_photo_number_live` below leads with `photo_id`, so it already
// serves plain `photoId.equals(...)` lookups on Routes as a prefix match —
// there is deliberately no separate single-column index for that.
@TableIndex.sql(
  'CREATE UNIQUE INDEX idx_routes_photo_number_live ON routes (photo_id, number) WHERE deleted_at IS NULL',
)
@TableIndex.sql(
  'CREATE INDEX idx_routes_wall_live ON routes (wall_id) '
  'WHERE deleted_at IS NULL',
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

// Two indexes because a comment attaches to EITHER a wall or an ascent (see
// `wallId`/`ascentId` below) and both are read paths: the topo detail screen
// filters on one, the ascent detail screen on the other.
@TableIndex.sql(
  'CREATE INDEX idx_comments_wall_live ON comments (wall_id) '
  'WHERE deleted_at IS NULL',
)
@TableIndex.sql(
  'CREATE INDEX idx_comments_ascent_live ON comments (ascent_id) '
  'WHERE deleted_at IS NULL',
)
class Comments extends Table with SyncColumns {
  /// Nullable as of Feature #12 (public opt-in ascent logs): a comment now
  /// attaches to EITHER a wall (topo) OR an ascent, never both — see
  /// [ascentId]. Pre-existing rows keep their wallId; only newly-created
  /// ascent comments leave this `null`.
  TextColumn get wallId => text().nullable().references(Walls, #id)();
  TextColumn get body => text()();
  TextColumn get authorName => text().nullable()();

  /// FK making this comment attach to an ascent log rather than a wall —
  /// see [wallId]. App-level invariant "exactly one of wallId/ascentId is
  /// set" is enforced by the repositories, NOT a DB CHECK constraint.
  /// `null` for every pre-Feature-#12 comment (all wall-attached).
  TextColumn get ascentId => text().nullable().references(Ascents, #id)();

  @override
  Set<Column> get primaryKey => {id};
}

@TableIndex.sql(
  'CREATE INDEX idx_likes_wall_live ON likes (wall_id) '
  'WHERE deleted_at IS NULL',
)
@TableIndex.sql(
  'CREATE INDEX idx_likes_ascent_live ON likes (ascent_id) '
  'WHERE deleted_at IS NULL',
)
class Likes extends Table with SyncColumns {
  /// Nullable as of Feature #12 (public opt-in ascent logs): a like now
  /// attaches to EITHER a wall (topo) OR an ascent, never both — see
  /// [ascentId]. Pre-existing rows keep their wallId; only newly-created
  /// ascent likes leave this `null`.
  TextColumn get wallId => text().nullable().references(Walls, #id)();

  /// FK making this like attach to an ascent log rather than a wall — see
  /// [wallId]. App-level invariant "exactly one of wallId/ascentId is set"
  /// is enforced by the repositories, NOT a DB CHECK constraint. `null`
  /// for every pre-Feature-#12 like (all wall-attached).
  TextColumn get ascentId => text().nullable().references(Ascents, #id)();

  @override
  Set<Column> get primaryKey => {id};
}

@TableIndex.sql(
  'CREATE INDEX idx_ascents_route_live ON ascents (route_id) '
  'WHERE deleted_at IS NULL',
)
@TableIndex.sql(
  'CREATE INDEX idx_ascents_wall_live ON ascents (wall_id) '
  'WHERE deleted_at IS NULL',
)
class Ascents extends Table with SyncColumns {
  TextColumn get routeId => text().references(Routes, #id)();
  TextColumn get wallId => text().references(Walls, #id)();
  IntColumn get climbedAt => integer()();
  TextColumn get style => text()();
  TextColumn get notes => text().nullable()();
  TextColumn get gradeOpinion => text().nullable()();

  /// Cloud-sharing visibility for this logged ascent, added by Feature #12
  /// (public opt-in ascent logs): `'private'` (default; owner-only, the
  /// original ascent-logbook behavior) or `'shared'` (visible on the
  /// Community ascent feed). Same shape as [Walls.visibility] — app
  /// enforces the two values, no DB CHECK constraint.
  TextColumn get visibility =>
      text().withDefault(const Constant('private'))();

  /// Optional display name of the ascent's author, shown alongside a
  /// `'shared'` ascent on the Community feed. Mirrors
  /// [Comments.authorName]'s shape/purpose. `null` for every pre-Feature-#12
  /// ascent and for any private one that never sets it.
  TextColumn get authorName => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}
