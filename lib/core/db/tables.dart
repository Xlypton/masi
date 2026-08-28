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

/// Local mirror of community facts (community editing, phase 4 / R-1).
///
/// The three tables below — grade opinions, verifications, hazards — share
/// one design, so it is stated once here.
///
/// Like [WallModerationRows] these are NOT [SyncColumns] tables and are NOT in
/// `syncTableNames`, for a related but distinct reason. Moderation state must
/// not travel up because the server owns it. These CAN be written by any
/// signed-in user — but they are written by going DIRECTLY to Supabase, not
/// through the sync engine, and the local row is only ever a cache of what the
/// server confirmed.
///
/// That is a deliberate consequence of having no outbox (decision D-4). The
/// sync engine's re-read-and-re-push loop is what makes it loss-proof for the
/// user's OWN hierarchy, but it is scoped to `ownerId = auth.uid()` rows, and
/// these tables are full of other people's statements. Routing them through it
/// would mean either re-pushing rows the client does not own (which RLS
/// refuses) or building the retry queue D-4 exists to avoid. So a write here
/// is online-only and fails loudly when it cannot reach the server, rather
/// than being silently queued and forgotten — the honest behaviour for
/// something a stranger is relying on for safety information.
///
/// Reads are mirrored locally so a hazard warning still renders from cold and
/// offline, exactly like every other read in this local-first app. None of
/// these carry a Drift FK to [Walls]/[Routes] for the same reason
/// [WallModerationRows] does not: rows arrive from a server pull and can
/// legitimately reference a wall this device has never pulled.
@DataClassName('GradeOpinionRow')
class GradeOpinionRows extends Table {
  TextColumn get id => text()();
  TextColumn get routeId => text()();
  TextColumn get authorId => text()();

  /// `french` | `uiaa`, as the raw server string. Parsed at the edge so an
  /// unknown future system degrades instead of throwing on read.
  TextColumn get gradeSystem => text()();
  TextColumn get gradeRaw => text()();

  /// Position on the shared cross-system scale. Stored rather than recomputed
  /// so a French and a UIAA opinion on one route stay directly comparable
  /// without the reader knowing either ladder.
  RealColumn get gradeSortKey => real().nullable()();

  IntColumn get createdAt => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

/// See [GradeOpinionRows] for the shared design note.
@DataClassName('TopoVerificationRow')
class TopoVerificationRows extends Table {
  TextColumn get id => text()();
  TextColumn get wallId => text()();
  TextColumn get authorId => text()();

  /// Whether this person says the topo matches the rock.
  BoolColumn get accurate => boolean()();

  TextColumn get note => text().nullable()();
  IntColumn get createdAt => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

/// See [GradeOpinionRows] for the shared design note.
@DataClassName('TopoHazardRow')
class TopoHazardRows extends Table {
  TextColumn get id => text()();
  TextColumn get wallId => text()();

  /// `null` for a hazard about the whole topo — the approach, the descent,
  /// the belay — rather than one specific line.
  TextColumn get routeId => text().nullable()();

  TextColumn get authorId => text()();

  /// `note` | `caution` | `danger`, as the raw server string. Parsed by
  /// `HazardSeverity.fromWire`, which resolves an unknown value to `danger` —
  /// the opposite direction to moderation state, because a safety warning
  /// must fail loud rather than be quietly demoted.
  TextColumn get severity => text()();

  TextColumn get body => text()();

  /// When somebody marked this dealt with, or null. The report itself is
  /// never deleted by the topo owner — that is the point of the split (C-12).
  IntColumn get resolvedAt => integer().nullable()();

  /// Who resolved it. The reporter withdrawing their own report and the topo
  /// owner saying it is fixed are very different claims.
  TextColumn get resolvedBy => text().nullable()();

  IntColumn get createdAt => integer()();

  @override
  Set<Column> get primaryKey => {id};
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

/// Access/closure state, shared by [Areas], [Sectors] and [Walls] (community
/// editing, phase 2 / R-2).
///
/// `null` (nothing stated) | `open` | `restricted` | `closed` | `sensitive`.
/// Stored as a raw string rather than a Drift enum so a value written by a
/// newer client round-trips instead of throwing on read; parsing happens at
/// the edge in `AccessState.fromWire`.
///
/// These columns are on SYNCED tables and are owner-writable, unlike
/// moderation state. That is deliberate: whether a crag is closed is a fact
/// about the world that the community maintains, not the topo author's
/// creative work (COMMUNITY_PLAN.md §3.2, R-1). Putting "this crag is closed"
/// behind a review queue would be actively harmful.
///
/// The state INHERITS downward — a closure set on an Area applies to every
/// sector and wall beneath it — resolved at read time rather than
/// denormalised, so closing a crag is one write. See
/// `ResolvedAccess.resolve`.
mixin AccessColumns on Table {
  TextColumn get accessState => text().nullable()();

  /// Free text explaining the restriction ("Peregrine nesting until 31 Jul",
  /// "Private land, ask at the farmhouse"). theCrag's model: state the reason,
  /// because a bare "closed" with no explanation gets ignored.
  TextColumn get accessNote => text().nullable()();
}

class Areas extends Table with SyncColumns, AccessColumns {
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
class Sectors extends Table with SyncColumns, AccessColumns {
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
class Walls extends Table with SyncColumns, AccessColumns {
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

  /// The wall's semantic baseline — the rock's footprint seen from above, as
  /// the JSON written by `face_layout/baseline.dart`'s `Baseline.encode`
  /// (a polyline in metres east/north of [latitude]/[longitude], plus whether
  /// it closes).
  ///
  /// `null` means nobody has authored one, NOT that the wall has no layout: a
  /// provisional line is synthesised from the photos' own GPS and headings on
  /// every read (`resolveLayout`), so a contributor who does nothing still
  /// gets an arranged topo. Storing only the AUTHORED stroke is what makes
  /// that possible — a stored provisional one would freeze a guess made
  /// before half the photos existed, and §5's "recompute on every edit" could
  /// never improve it.
  ///
  /// Whether the stroke closes is the only thing separating a boulder from a
  /// wall in this model, which is why nothing in the UI ever asks.
  TextColumn get baselineJson => text().nullable()();

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

  /// Where this photo was taken, from its own EXIF GPS — the FACE-level fix,
  /// deliberately distinct from [Walls.latitude]/[Walls.longitude], which is
  /// the object-level pin shown on the map.
  ///
  /// The split is the whole of the layout spec's §5 signal hierarchy in two
  /// columns. A fix that is 10 m out is useless for saying which side of a
  /// 4 m boulder you are on and perfectly good for saying which valley the
  /// boulder is in; keeping one number for each question means no code can
  /// accidentally answer one with the other.
  RealColumn get captureLatitude => real().nullable()();
  RealColumn get captureLongitude => real().nullable()();

  /// Reported horizontal accuracy of that fix, in metres, or `null` when the
  /// photo did not say.
  ///
  /// `null` is treated as UNUSABLE rather than perfect (`FaceInput
  /// .hasUsableGps`). An unlabelled fix taken under a cliff is exactly the
  /// multipath case the hierarchy exists to distrust, and defaulting it to
  /// "good" would let the worst data outrank capture order.
  RealColumn get captureAccuracyMeters => real().nullable()();

  /// Camera heading in degrees clockwise from true north, from EXIF
  /// `GPSImgDirection`, or `null` — which is the common case, since many
  /// phones and most cameras write no heading at all.
  ///
  /// A hint and a sort key, never ground truth: iron-bearing rock and
  /// magnetic cases throw a magnetometer far enough off that a heading is
  /// only ever allowed to REFINE spacing, and any heading contradicting
  /// capture order is dropped as an outlier.
  RealColumn get captureBearingDegrees => real().nullable()();

  /// Where a human dragged this face to on the wall's baseline, as an
  /// arc-length fraction, or `null` if nobody has.
  ///
  /// One nullable column rather than the spec's `t` + `t_pinned` pair. The
  /// pair has a state nothing can arbitrate — a `t` with `t_pinned` false is
  /// a stale computed value — and full-row last-writer-wins sync (decision
  /// D-4) can land the two halves from different edits, producing a pin at a
  /// position nobody chose. A single nullable value cannot disagree with
  /// itself, and "unpinned" becomes the absence of a fact rather than a
  /// stored one.
  ///
  /// Authoritative once set: the resolver never overrides it, and every
  /// unpinned neighbour re-interpolates around it.
  RealColumn get layoutPinnedT => real().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

// Partial unique index enforcing that no two *live* (non-soft-deleted)
// routes on the same WALL share a `number`.
//
// This used to be scoped per PHOTO, on the reasoning that each photo carries
// its own overlay. That stopped being true when a route became a climb rather
// than a drawing: one line can now be drawn on several photos of the same
// rock (see [RouteLines]), and per-photo numbering meant the same physical
// climb could be "3" on the south face and "5" on the arête — two numbers for
// one thing, in a document whose entire job is to let someone at the rock say
// which line they mean. The v15->v16 migration renumbers each wall's routes
// sequentially to adopt it.
//
// Soft-deleted tombstones (deletedAt IS NOT NULL) are excluded so a deleted
// route's old number can be reused by a new route without violating
// uniqueness.
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
// `idx_routes_wall_number_live` leads with `wall_id`, so it also serves plain
// `wallId.equals(...)` lookups as a prefix match — which is why the separate
// single-column wall index it replaced is gone rather than kept alongside it.
// `photo_id` needs its own index again for the same reason it used to get one
// for free: reading "the routes whose home photo is this one" is still a real
// access path, and it is no longer any index's prefix.
@TableIndex.sql(
  'CREATE UNIQUE INDEX idx_routes_wall_number_live ON routes (wall_id, number) WHERE deleted_at IS NULL',
)
@TableIndex.sql(
  'CREATE INDEX idx_routes_photo_live ON routes (photo_id) '
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

/// The same climb, drawn on another photo of the same rock.
///
/// A route is a CLIMB — a name, a grade, the thing ascents and grade opinions
/// and hazards all point at — and a climb that wraps an arête is one climb
/// photographed twice, not two problems. [Routes] carries the climb and the
/// line on its home photo ([Routes.photoId]); this table carries the same
/// climb's line as drawn on every OTHER photo, with its own points and
/// symbols because the same rock from 90 degrees round is a different shape.
///
/// **Why the home line stays on [Routes] instead of moving here.** Full
/// normalisation — every line in this table, [Routes] holding no geometry —
/// is the tidier model and was not chosen. `Routes.photoId` and
/// `Routes.pointsJson` are NOT NULL, so emptying them needs a SQLite
/// table-recreate; the recreate would have to be mirrored in the live shared
/// Supabase project, which is not branched, so it would land for every user
/// of every other branch at the moment it ran. The asymmetry it avoids is one
/// this schema already carries deliberately elsewhere — `Photos.isPrimary`
/// designates one of a set the same way — and it keeps every existing read
/// path, sync mapping and moderation flow working untouched.
///
/// Consequences worth knowing rather than discovering: deleting a photo that
/// holds a route's home line promotes one of these rows in its place (exactly
/// as deleting a wall's primary photo promotes another), and "the lines on
/// photo P" is a union of `routes.photoId = P` and `route_lines.photoId = P`,
/// never one table alone.
@TableIndex.sql(
  'CREATE UNIQUE INDEX idx_route_lines_route_photo_live ON route_lines (route_id, photo_id) WHERE deleted_at IS NULL',
)
@TableIndex.sql(
  'CREATE INDEX idx_route_lines_photo_live ON route_lines (photo_id) '
  'WHERE deleted_at IS NULL',
)
class RouteLines extends Table with SyncColumns {
  /// The climb this line depicts. Every piece of shared data — name, grade,
  /// stars, tags, ascents — is read through here, which is what makes two
  /// drawings of one climb genuinely one climb.
  TextColumn get routeId => text().references(Routes, #id)();

  /// The photo this line is drawn on. Never the route's home photo: that
  /// line lives on the [Routes] row itself, and the partial unique index
  /// above stops a duplicate landing here for it.
  TextColumn get photoId => text().references(Photos, #id)();

  /// Normalised points, in the same encoding [Routes.pointsJson] uses, so
  /// both kinds of line render through one painter with no branch.
  TextColumn get pointsJson => text()();
  TextColumn get symbolsJson => text()();

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

  /// The uids this comment tags, as a JSON array of strings (`["uid-a"]`),
  /// or `null` for the overwhelming majority of comments, which tag nobody.
  ///
  /// **Uids, not names.** A mention could have been stored as the `@name` text
  /// already in [body] and re-resolved at render time, and that would have
  /// been less code. It would also have broken silently the first time
  /// somebody renamed themselves — display names are editable (#18), so the
  /// text is a description of who they were that day, not a reference. Two
  /// climbers may also legitimately choose the same display name, which a
  /// text match cannot tell apart and a uid can.
  ///
  /// A JSON array in one column rather than a join table: a mention has no
  /// attributes of its own, is only ever read as "who does this comment tag",
  /// and travels with the comment through the sync engine's full-row re-push
  /// (decision D-4) for free. A join table would need its own sync plumbing to
  /// carry exactly the same information.
  TextColumn get mentionedUids => text().nullable()();

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

/// A thing that happened to you, or to something you made — the local mirror
/// of `public.notifications`.
///
/// See [GradeOpinionRows] for the shared design note on mirror tables; this
/// one follows it for a stronger reason than any of them. A notification is
/// written by the SERVER, in a trigger, when somebody else acts. A client can
/// never author one, which is the whole security property: if the app could
/// insert notifications, anyone could put a message in anyone else's inbox.
/// So this is not a [SyncColumns] table and is not in `syncTableNames` — the
/// only local write is marking one read, and even that goes to Supabase first
/// and is mirrored back.
///
/// Deliberately no Drift FK to [Walls]/[Comments]/[Ascents]: rows arrive from
/// a server pull and can reference a topo this device has never held — which
/// is the normal case for a notification about somebody commenting on a topo
/// you have not opened in months.
@DataClassName('NotificationRow')
class NotificationRows extends Table {
  TextColumn get id => text()();

  /// Who this is FOR. Every read is scoped by it, and the server's RLS scopes
  /// on it too, so a pull can only ever return the signed-in user's own.
  TextColumn get recipientId => text()();

  /// What happened, as the raw server string (`comment`, `mention`, `like`,
  /// `suggestion`, …). Stored raw and parsed at the edge so a build that
  /// predates a new kind renders it as a generic entry instead of throwing on
  /// a value its enum has never heard of — the same rule [GradeOpinionRows]
  /// applies to grade systems.
  TextColumn get kind => text()();

  /// Who did it. Nullable because not every kind has a person behind it, and
  /// because an actor whose account is gone must not take the notification
  /// with them.
  TextColumn get actorId => text().nullable()();

  /// What it happened to. Which of these is set depends on [kind]; all are
  /// nullable so a new kind can arrive without a schema change.
  TextColumn get wallId => text().nullable()();
  TextColumn get ascentId => text().nullable()();
  TextColumn get commentId => text().nullable()();

  /// A short server-rendered summary — e.g. the first line of the comment.
  /// Nullable: an entry is perfectly readable without one.
  TextColumn get preview => text().nullable()();

  IntColumn get createdAt => integer()();

  /// When the user read it, or `null` while unread. A timestamp rather than a
  /// bool so "mark all read" is one write with one value, and so the unread
  /// badge is a plain `readAt IS NULL` count.
  IntColumn get readAt => integer().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}
