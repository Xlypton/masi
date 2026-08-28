import 'package:drift/drift.dart';
// For `@visibleForTesting`. `package:meta` itself is not a direct
// dependency of this package; foundation re-exports the annotation.
import 'package:flutter/foundation.dart';

import 'connection/connection.dart' show commitNeedsExplicitFlush;
import 'schema_downgrade.dart';
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
  tables: [
    Areas,
    Sectors,
    Walls,
    Photos,
    Routes,
    RouteLines,
    Comments,
    Likes,
    Ascents,
    Profiles,
    AppSettings,
    WallModerationRows,
    GradeOpinionRows,
    TopoVerificationRows,
    TopoHazardRows,
    NotificationRows,
  ],
)
class AppDatabase extends _$AppDatabase {
  /// [flushAfterCommit] overrides the platform default
  /// ([commitNeedsExplicitFlush]) for the post-commit durability flush that
  /// [transaction] performs.
  ///
  /// It exists ONLY so `flutter test` — which always runs the `dart:io` seam,
  /// where the flag is `false` — can still exercise the real depth-counting,
  /// rollback and ordering behaviour of that override against an in-memory
  /// `NativeDatabase`. Production code must never pass it; the platform seam
  /// is the answer everywhere else.
  AppDatabase(super.e, {@visibleForTesting bool? flushAfterCommit})
    : _flushAfterCommit = flushAfterCommit ?? commitNeedsExplicitFlush;

  final bool _flushAfterCommit;

  @override
  int get schemaVersion => 16;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      // L7 GUARD — must stay the FIRST statement in this callback.
      //
      // drift calls `onUpgrade` for any version CHANGE, downgrades included
      // (`OpeningDetails.hadUpgrade` is `!wasCreated && versionBefore !=
      // versionNow`, drift 2.34.2 `query_builder/migration.dart:647`, branched
      // on at `api/db_base.dart:131-137`). Every branch below is
      // `if (from < N)`, so a downgrade runs NONE of them, returns normally,
      // and lets `DelegatedDatabase._runMigrations` stamp the OLDER version
      // into `PRAGMA user_version` (`executor/helpers/engines.dart:562`) —
      // after which the next current-shell load re-runs the intervening
      // branches against tables that already exist, with the user's library
      // stranded behind a database that will not open.
      //
      // Throwing here happens BEFORE that `setSchemaVersion` (it is called on
      // line 562 only after `beforeOpen` returns on line 557), so the on-disk
      // version and every row are left exactly as they were. Refusing to open
      // is recoverable — the user reloads and gets the current shell.
      // Downgrading is not. See `schema_downgrade.dart` and
      // `test/core/db/schema_downgrade_test.dart`.
      if (from > to) {
        throw SchemaDowngradeException(storedVersion: from, appVersion: to);
      }

      // IDEMPOTENCE HELPERS — every schema-changing step below goes through
      // one of these, and must stay safe to re-run against a database that
      // already has the thing it is adding.
      //
      // `onUpgrade` is not atomic. Drift stamps `PRAGMA user_version` only
      // after the whole callback returns
      // (`executor/helpers/engines.dart:562`), while each `ALTER TABLE`
      // commits on its own. Lose the process between the two — a killed tab,
      // an OOM, a swipe-away mid-open — and the column is on disk with the
      // OLD version still recorded. The next open re-runs the same branch,
      // SQLite answers `duplicate column name` (it has no `ADD COLUMN IF NOT
      // EXISTS`), and every open after that fails the same way, with the
      // user's entire local library behind a database that will not open.
      // Guarding each step turns that from a permanent brick into a retry.
      //
      // The live exposure today is small: only a stored version of v1-6
      // reaches the adds that used to be unguarded, and v7 shipped the same
      // day the PWA did. This hardens the mechanism for the NEXT
      // `addColumn` migration rather than fixing an outage.
      //
      // Cost: `PRAGMA table_info` is read ONCE PER TABLE and cached for the
      // rest of the run, never once per column. On web every one of these is
      // a main-thread -> worker round-trip inside an already-tight 30s open
      // budget, so the 24 guarded steps below cost at most 9 reads (one per
      // distinct table ever inspected), and at most 2 more than the two
      // hand-rolled guards that came before this.
      final tableColumnCache = <String, Set<String>>{};

      /// Column names currently on [table], read at most once per run.
      ///
      /// The returned set is the LIVE cache entry: [addIfMissing] and
      /// [addViaRebuildIfMissing] mutate it after a successful add so a later
      /// guard on the same table sees the new column without another PRAGMA.
      Future<Set<String>> columnsOf(TableInfo<Table, dynamic> table) async {
        final cached = tableColumnCache[table.actualTableName];
        if (cached != null) return cached;
        final rows = await customSelect(
          "PRAGMA table_info('${table.actualTableName}')",
        ).get();
        return tableColumnCache[table.actualTableName] = {
          for (final row in rows) row.read<String>('name'),
        };
      }

      /// `ALTER TABLE ... ADD COLUMN`, skipped when [column] is already there.
      Future<void> addIfMissing(
        TableInfo<Table, dynamic> table,
        GeneratedColumn<Object> column,
      ) async {
        final columns = await columnsOf(table);
        if (columns.contains(column.name)) return;
        await m.addColumn(table, column);
        columns.add(column.name);
      }

      /// The 12-step table rebuild that adds [column] to [table], skipped when
      /// [column] is already there.
      ///
      /// This guard matters MORE than the plain-ADD-COLUMN one, because its
      /// failure mode is quieter. Re-running an unguarded `newColumns:`
      /// rebuild does not throw: `newColumns` is precisely the promise that
      /// the column is absent from the old table, so drift leaves it out of
      /// the copy-INSERT's column list (drift 2.34.2
      /// `query_builder/migration.dart:231`) and every existing value comes
      /// back NULL. A crash is recoverable; silently blanking a column of
      /// real rows is not.
      ///
      /// [alsoNew] names FURTHER columns that this rebuild must also declare
      /// as new. It is not a convenience: `alterTable` rebuilds against the
      /// CURRENT generated schema and copies every column it is not told is
      /// new, so any column added to [table] by a LATER migration must be
      /// named here too, or this branch emits a copy-INSERT that selects a
      /// column the old on-disk table does not have and every upgrade from
      /// before this version dies. The guard stays on [column] alone: a
      /// completed rebuild wrote the current schema, so [alsoNew] is present
      /// whenever [column] is.
      Future<void> addViaRebuildIfMissing(
        TableInfo<Table, dynamic> table,
        GeneratedColumn<Object> column, {
        List<GeneratedColumn<Object>> alsoNew = const [],
      }) async {
        final columns = await columnsOf(table);
        if (columns.contains(column.name)) return;
        await m.alterTable(
          TableMigration(table, newColumns: [column, ...alsoNew]),
        );
        columns.add(column.name);
        for (final added in alsoNew) {
          columns.add(added.name);
        }
      }

      // (`m.createTable` needs no guard of its own — drift emits
      // `CREATE TABLE IF NOT EXISTS`, `migration.dart:319`.)

      // v1 -> v2: row-level cloud-sync pivot (Phase 1). Adds a nullable
      // `ownerId` to every SyncColumns table (ADD COLUMN is non-destructive;
      // pre-existing rows come back with `ownerId == null`, i.e.
      // unattributed until a future `claimOwnership` backfill) plus a
      // `visibility` column (default `'private'`) on Walls only — the topo
      // = a Wall, and this is the sharing flag, deliberately distinct from
      // the existing per-route `visible` render flag.
      if (from < 2) {
        await addIfMissing(areas, areas.ownerId);
        await addIfMissing(sectors, sectors.ownerId);
        await addIfMissing(walls, walls.ownerId);
        await addIfMissing(photos, photos.ownerId);
        await addIfMissing(routes, routes.ownerId);
        await addIfMissing(walls, walls.visibility);
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
        await addIfMissing(walls, walls.latitude);
        await addIfMissing(walls, walls.longitude);
      }
      // v4 -> v5: per-route metadata (#41 beta-video URL, #42 style tags,
      // #44 0-3 star rating) — three nullable ADD COLUMNs on Routes, so
      // every pre-existing route comes back with all three `null`
      // (unrated / no tags / no beta link) rather than losing any data.
      if (from < 5) {
        await addIfMissing(routes, routes.betaVideoUrl);
        await addIfMissing(routes, routes.styleTagsJson);
        await addIfMissing(routes, routes.stars);
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
        await addIfMissing(photos, photos.sortOrder);
        await addIfMissing(photos, photos.isPrimary);

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
      // v6 -> v7: Feature #12 (public opt-in ascent logs). Adds an
      // owner-controlled `visibility`/`authorName` pair to Ascents (same
      // shape as Walls' existing sharing flag — 'private' default, app
      // enforces the two values, no DB CHECK) so a climber can choose to
      // publish an ascent log to the Community feed. Comments and Likes
      // gain a nullable `ascentId` FK so either can attach to an ascent
      // log instead of only a wall (topo); their `wallId` is relaxed from
      // NOT NULL to nullable to make room for that (app-level invariant
      // "exactly one of wallId/ascentId set" is enforced by the
      // repositories, not the DB). Ascents' two new columns are plain
      // nullable/defaulted ADD COLUMNs — lossless by construction. Likes
      // and Comments need a full `TableMigration`/`m.alterTable` rebuild
      // instead (drift's ADD COLUMN can't relax an existing NOT NULL), but
      // it's still lossless: `newColumns: [ascentId]` tells drift that
      // column doesn't exist in the old on-disk table, so the rebuild's
      // copy-INSERT only copies columns present on both sides (every
      // existing column, including `wallId`, by name) while `ascentId`
      // comes back `null` on every pre-existing row; the rebuilt table's
      // CREATE TABLE is sourced from the (already-edited) `tables.dart`,
      // so `wallId` lands nullable in the new schema with nothing left to
      // violate even though old rows still have it populated.
      //
      // Guarded on `from >= 3`: Comments/Likes/Ascents didn't exist before
      // v2->v3, where they're brought into being via `m.createTable`, which
      // stamps them from the CURRENT (already-edited) `tables.dart`
      // definitions — i.e. any upgrade path that passes through the
      // `from < 3` branch above already creates these three tables with
      // `visibility`/`authorName`/`ascentId` baked in from the start, so
      // there is simply nothing here for those paths to do. The per-column
      // guards below would no-op anyway; keeping the version bound just
      // saves them three `PRAGMA table_info` round-trips.
      //
      // The `ascentId` pair goes through [addViaRebuildIfMissing] rather than
      // a bare `m.alterTable`, because a re-run of that rebuild is the one
      // step here that LOSES DATA instead of throwing — see that helper's
      // doc. Both a v7-interrupted upgrade and any harness that synthesizes
      // an "old" database via `createAll` before stamping an old
      // `user_version` reach this branch with `ascent_id` already populated.
      if (from < 7 && from >= 3) {
        await addIfMissing(ascents, ascents.visibility);
        await addIfMissing(ascents, ascents.authorName);

        await addViaRebuildIfMissing(likes, likes.ascentId);
        // `mentionedUids` is listed as a new column here even though it
        // arrives in v15, several branches below. `alterTable` rebuilds the
        // table against the CURRENT generated schema and copies every column
        // it is not told is new — so the moment v15 added `mentionedUids`,
        // this v6 -> v7 rebuild started emitting
        // `INSERT INTO tmp … SELECT …, "mentioned_uids" FROM comments`
        // against a v6 table that has no such column, and every upgrade from
        // a pre-v7 database died here. Anything added to `Comments` in future
        // has to be named here too, for the same reason.
        await addViaRebuildIfMissing(
          comments,
          comments.ascentId,
          alsoNew: [comments.mentionedUids],
        );
      }
      // v7 -> v8: adds the brand-new `Profiles` table (#18, editable synced
      // display name). A fresh table, unrelated to any existing row/column,
      // so this is a pure `m.createTable` with nothing to backfill — no
      // pre-existing data is touched. See `tables.dart`'s `Profiles` doc for
      // why its `id` is the user's Supabase uid rather than a generated
      // UUID.
      if (from < 8) {
        await m.createTable(profiles);
      }
      // v8 -> v9: adds the local-only `AppSettings` key/value table (§1c),
      // the durable home of `lastKnownUid` — the uid local reads/writes are
      // scoped by when no live session is available (a captive-portal hard
      // sign-out, an offline token-refresh failure, or a cold boot before
      // Supabase resolves). Same shape as the v7 -> v8 `Profiles` addition: a
      // brand-new table unrelated to any existing row/column, so a pure
      // `m.createTable` with nothing to backfill and no pre-existing data
      // touched. NOT a SyncColumns table and NOT in `syncTableNames` — see
      // `tables.dart`'s `AppSettings` doc for why device state must never
      // sync.
      if (from < 9) {
        await m.createTable(appSettings);
      }
      // v9 -> v10: FK lookup indexes. Purely additive and data-free — no
      // column, table or row is touched; only SQLite's own query plans change.
      //
      // SQLite gives a foreign key NO index of its own (only the PARENT's
      // primary key is indexed), so before this the schema carried exactly one
      // index — `idx_routes_photo_number_live`, created for uniqueness rather
      // than for lookups — and every `where(wallId.equals(...))`-shaped read
      // was a full table scan. That is invisible on a small library and gets
      // steadily worse as one grows, and it grows from BOTH directions here:
      // the user's own topos, plus every shared topo pulled in from the
      // community feed, which lands in these same tables.
      //
      // Each one is PARTIAL on `deleted_at IS NULL` to match the actual query
      // predicate (deletes are soft, and reads pair the FK filter with
      // `deletedAt.isNull()`) — see the block comment above `Routes` in
      // `tables.dart`.
      //
      // `IF NOT EXISTS` on every statement: a fresh install already has all of
      // them from `onCreate`/`createAll` via the `@TableIndex.sql` annotations,
      // and this branch must stay re-runnable, exactly like the v6 index swap
      // above.
      if (from < 10) {
        const liveFkIndexes = <String>[
          'CREATE INDEX IF NOT EXISTS idx_sectors_area_live '
              'ON sectors (area_id) WHERE deleted_at IS NULL',
          'CREATE INDEX IF NOT EXISTS idx_walls_sector_live '
              'ON walls (sector_id) WHERE deleted_at IS NULL',
          'CREATE INDEX IF NOT EXISTS idx_photos_wall_live '
              'ON photos (wall_id) WHERE deleted_at IS NULL',
          'CREATE INDEX IF NOT EXISTS idx_photos_parent_live '
              'ON photos (parent_photo_id) WHERE deleted_at IS NULL',
          'CREATE INDEX IF NOT EXISTS idx_routes_wall_live '
              'ON routes (wall_id) WHERE deleted_at IS NULL',
          'CREATE INDEX IF NOT EXISTS idx_comments_wall_live '
              'ON comments (wall_id) WHERE deleted_at IS NULL',
          'CREATE INDEX IF NOT EXISTS idx_comments_ascent_live '
              'ON comments (ascent_id) WHERE deleted_at IS NULL',
          'CREATE INDEX IF NOT EXISTS idx_likes_wall_live '
              'ON likes (wall_id) WHERE deleted_at IS NULL',
          'CREATE INDEX IF NOT EXISTS idx_likes_ascent_live '
              'ON likes (ascent_id) WHERE deleted_at IS NULL',
          'CREATE INDEX IF NOT EXISTS idx_ascents_route_live '
              'ON ascents (route_id) WHERE deleted_at IS NULL',
          'CREATE INDEX IF NOT EXISTS idx_ascents_wall_live '
              'ON ascents (wall_id) WHERE deleted_at IS NULL',
        ];
        for (final statement in liveFkIndexes) {
          await customStatement(statement);
        }
      }
      // v10 -> v11: `Profiles.avatarUrl` — the user's profile picture, either
      // an OAuth provider's `https://` avatar or an inline `data:` URL for a
      // picture they picked themselves (see `tables.dart`'s doc for why it is
      // stored inline rather than in Supabase Storage).
      //
      // Nullable with no default, so every existing profile row simply reads
      // back `null` ("no picture yet") and nothing needs backfilling. The
      // matching live-Supabase column is `supabase/migrations/
      // 2026-08-06_profiles_avatar_url.sql`; pushing a row with an unknown
      // column is what schema drift looks like here (bugs #64/#65/#72), so
      // that migration must be applied BEFORE a build carrying this ships.
      //
      // Three real paths reach this branch with the column already present,
      // which is what [addIfMissing] is for: the v7 -> v8 branch above, whose
      // `m.createTable(profiles)` builds the table from its CURRENT
      // definition; an upgrade interrupted after the ALTER committed but
      // before `user_version` was stamped; and any harness that synthesizes
      // an "old" database via `createAll` and then stamps an old
      // `user_version` (which is exactly what `app_database_migration_test`
      // does). Same re-runnability discipline as the v9 -> v10 index branch's
      // `IF NOT EXISTS`.
      if (from < 11) {
        await addIfMissing(profiles, profiles.avatarUrl);
      }
      // v11 -> v12: `WallModerationRows` — the local, pull-only mirror of the
      // server's `wall_moderation` (community editing, phase 1). Same shape as
      // the v7 -> v8 `Profiles` and v8 -> v9 `AppSettings` additions: a
      // brand-new table unrelated to any existing row or column, so a plain
      // `createTable` with nothing to backfill and no existing data touched.
      //
      // NOT a SyncColumns table and NOT in `syncTableNames` — see the table's
      // own doc in `tables.dart` for why moderation state must never travel
      // back up through the sync engine.
      if (from < 12) {
        await m.createTable(wallModerationRows);
      }
      // v12 -> v13: `accessState`/`accessNote` on Areas, Sectors and Walls —
      // access and closure as a first-class, inheriting field (community
      // editing phase 2 / R-2; see `AccessColumns` in `tables.dart`).
      //
      // Six plain nullable ADD COLUMNs, so every pre-existing row comes back
      // with both null ("nothing stated"). Unlike moderation state these are
      // on SYNCED tables and are owner-writable, so they need no sync-engine
      // change: `toJson()`/`fromJson()` round-trip them like every other
      // column. The matching live-Supabase columns are in
      // `supabase/migrations/2026-08-06_community_phase2_access.sql` and must
      // be applied BEFORE a build carrying v13 ships.
      //
      // Each add is guarded on the column not already existing, for the same
      // reason the v10 -> v11 branch is: SQLite has no
      // `ADD COLUMN IF NOT EXISTS`, a duplicate add is a hard error, and both
      // a re-run and any harness that synthesizes an "old" database via
      // `createAll` before stamping an old `user_version` reach this branch
      // with the columns already present. (These six were where the
      // [addIfMissing] helper originally lived, before it was hoisted to
      // cover every branch.)
      if (from < 13) {
        await addIfMissing(areas, areas.accessState);
        await addIfMissing(areas, areas.accessNote);
        await addIfMissing(sectors, sectors.accessState);
        await addIfMissing(sectors, sectors.accessNote);
        await addIfMissing(walls, walls.accessState);
        await addIfMissing(walls, walls.accessNote);
      }
      // v13 -> v14: the local mirror of community facts — grade opinions,
      // verifications and hazards (community editing phase 4 / R-1). Three
      // brand-new tables with nothing to backfill, so the same plain
      // `createTable` shape as the v11 -> v12 `WallModerationRows` addition.
      //
      // None of them is a SyncColumns table and none is in `syncTableNames`:
      // they are written by going directly to Supabase and mirrored back, not
      // pushed by the sync engine. See `GradeOpinionRows` in `tables.dart` for
      // why. The matching live tables are in
      // `supabase/migrations/2026-08-06_community_phase4_facts.sql` and must be
      // applied BEFORE a build carrying v14 ships.
      if (from < 14) {
        await m.createTable(gradeOpinionRows);
        await m.createTable(topoVerificationRows);
        await m.createTable(topoHazardRows);
      }
      // v14 -> v15: the feed overhaul's two additions — tagging someone in a
      // comment, and the notifications that tagging (and commenting, liking,
      // suggesting) produces.
      //
      // `Comments.mentionedUids` is a plain nullable column on an existing
      // SyncColumns table, so it goes through `addIfMissing` like every other
      // added column here; `null` on every pre-existing row is exactly right,
      // because no comment written before this feature tagged anybody.
      //
      // `NotificationRows` is a mirror table, not a synced one — the server
      // authors every row, and a client that could insert one could put a
      // message in anyone's inbox. Same plain `createTable` shape as the
      // v13 -> v14 additions. The matching live table lives in
      // `supabase/migrations/2026-08-08_notifications.sql` and must be applied
      // BEFORE a build carrying v15 ships.
      if (from < 15) {
        await addIfMissing(comments, comments.mentionedUids);
        await m.createTable(notificationRows);
      }
      // v15 -> v16: the Face Layout System.
      //
      // Three separable things, in the order they must happen:
      //
      // 1. Per-face capture sensors and the manual pin on `photos`, plus the
      //    authored baseline on `walls`. All nullable columns on existing
      //    SyncColumns tables, so `addIfMissing` handles them and `null` on
      //    every pre-existing row is exactly right: no photo taken before this
      //    build recorded a heading, and nobody has dragged anything. Capture
      //    ORDER needs no column — `Photos.sortOrder` already is it (it starts
      //    as the upload sequence and is changed only by a human reordering
      //    the rail, which is precisely the spec's rule that order changes
      //    only by hand).
      //
      // 2. `route_lines`, the same climb drawn on another photo.
      //
      // 3. Route numbers move from per-PHOTO to per-WALL, which needs the old
      //    unique index dropped, the rows renumbered, and the new one built —
      //    strictly in that order, because the wall-scoped index cannot be
      //    created while two photos on one wall still each hold a "1", and
      //    that is the normal state of every existing multi-photo topo.
      //
      // The matching live Supabase migration is
      // `supabase/migrations/2026-08-28_face_layout.sql` and must be applied
      // BEFORE a build carrying v16 ships.
      if (from < 16) {
        await addIfMissing(walls, walls.baselineJson);
        await addIfMissing(photos, photos.captureLatitude);
        await addIfMissing(photos, photos.captureLongitude);
        await addIfMissing(photos, photos.captureAccuracyMeters);
        await addIfMissing(photos, photos.captureBearingDegrees);
        await addIfMissing(photos, photos.layoutPinnedT);
        await m.createTable(routeLines);
        await _renumberRoutesPerWall(m);
      }
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

  /// Moves route numbering from per-photo to per-wall (schema v16).
  ///
  /// Every live route on a wall is renumbered 1..n in a stable, explainable
  /// order — by its photo's position in the strip, then by the number it
  /// already had, then by id so the result is identical on every device that
  /// runs it. That determinism is not decoration: the same rows are renumbered
  /// independently on each of a user's devices, and sync reconciles the
  /// results by last-writer-wins with no notion of "these two disagree". Two
  /// devices computing different numbers for one route would settle it by
  /// whoever pushed last.
  ///
  /// Renumbering is unconditional rather than collision-only. Preserving
  /// existing numbers where they happen not to clash sounds gentler and
  /// produces a topo numbered 1, 2, 5, 3, 4 — which is worse to read at the
  /// rock than one numbered in the order you walk past the lines.
  ///
  /// The rows are NOT marked dirty. A renumber is a schema migration every
  /// client performs for itself on first open of this build, so pushing it
  /// would have every device upload its whole route table to agree on values
  /// they all computed identically anyway.
  Future<void> _renumberRoutesPerWall(Migrator m) async {
    // All three indexes go first, the new one included. `onUpgrade` replays
    // from whatever version the file claims, and a database that is already
    // current — the interrupted-migration tests stamp exactly that back to
    // v1 — still carries `idx_routes_wall_number_live`. Renumbering under it
    // trips the very uniqueness the renumber exists to establish, and
    // recreating it afterwards fails as "already exists".
    await customStatement('DROP INDEX IF EXISTS idx_routes_photo_number_live');
    await customStatement('DROP INDEX IF EXISTS idx_routes_wall_live');
    await customStatement('DROP INDEX IF EXISTS idx_routes_wall_number_live');
    await customStatement('DROP INDEX IF EXISTS idx_routes_photo_live');

    // The ranking is computed from a SNAPSHOT rather than from `routes`
    // itself. Ranking each row by counting the rows that sort before it means
    // reading `number` while the same statement is writing `number`, and
    // SQLite is free to show a subquery the already-updated value — which
    // silently collapses several routes onto one new number and then fails on
    // the unique index, if you are lucky enough for it to fail at all.
    await customStatement('DROP TABLE IF EXISTS _route_renumber');
    await customStatement("""
      CREATE TEMP TABLE _route_renumber AS
      SELECT r.id AS rid,
             r.wall_id AS wid,
             COALESCE(
               (SELECT p.sort_order FROM photos p WHERE p.id = r.photo_id),
               0) AS pso,
             r.number AS onum
        FROM routes r
       WHERE r.deleted_at IS NULL
    """);

    await customStatement("""
      UPDATE routes
         SET number = (
               SELECT COUNT(*) + 1
                 FROM _route_renumber e
                WHERE e.wid = (SELECT s.wid FROM _route_renumber s
                                WHERE s.rid = routes.id)
                  AND (
                    e.pso < (SELECT s.pso FROM _route_renumber s
                              WHERE s.rid = routes.id)
                    OR (e.pso = (SELECT s.pso FROM _route_renumber s
                                  WHERE s.rid = routes.id)
                        AND (
                          e.onum < (SELECT s.onum FROM _route_renumber s
                                     WHERE s.rid = routes.id)
                          OR (e.onum = (SELECT s.onum FROM _route_renumber s
                                         WHERE s.rid = routes.id)
                              AND e.rid < routes.id)
                        ))
                  )
             )
       WHERE deleted_at IS NULL
    """);

    await customStatement('DROP TABLE IF EXISTS _route_renumber');

    // Created by hand rather than through `m.createIndex` so they carry
    // IF NOT EXISTS — the same replay that made the drops necessary can reach
    // here twice.
    await customStatement(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_routes_wall_number_live '
      'ON routes (wall_id, number) WHERE deleted_at IS NULL',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_routes_photo_live '
      'ON routes (photo_id) WHERE deleted_at IS NULL',
    );
  }


  /// Nesting depth of [transaction] calls made through this database.
  ///
  /// Only the OUTERMOST one may flush. A nested transaction is a `SAVEPOINT`;
  /// drift keeps `isInTransaction` set for it
  /// (`executor/helpers/engines.dart:300-302` clears the flag only at
  /// `depth == 0`), so a statement issued after a nested release would still
  /// be inside the outer transaction and would not flush anything.
  int _openTransactions = 0;

  /// The statement issued after a top-level commit purely for its SIDE
  /// EFFECT on drift's web delegate.
  ///
  /// Nothing about `SELECT 1` matters except that it is a statement, that it
  /// is dispatched outside a transaction, and that it is free. Drift's
  /// `_WasmDelegate._runWithArgs` awaits `_flush()` after ANY statement it is
  /// handed while `isInTransaction` is false (`drift/lib/wasm.dart:362-368`),
  /// and that `flush()` drains sqlite3's ENTIRE pending write queue
  /// (`sqlite3/src/wasm/vfs/indexed_db.dart:606-608` ->
  /// `_startWorkingIfNeeded(isImplicit: false)` -> `_performWrites`), waiting
  /// on the IndexedDB transaction's own `oncomplete`
  /// (`indexed_db.dart:100-103`, `:118-139`). So one cheap statement after the
  /// commit persists everything the commit left behind.
  ///
  /// `customStatement` is deliberate: it routes to `runCustom` and does NOT
  /// notify drift's stream queries, so this cannot make a `watch()` re-emit.
  static const String _postCommitFlushStatement = 'SELECT 1';

  /// Wraps drift's [transaction] so that a top-level commit is DURABLE by the
  /// time the returned future completes, on platforms where drift's own
  /// commit path does not persist ([commitNeedsExplicitFlush] — web only; see
  /// that declaration in `connection/connection_web.dart` for the full
  /// mechanism, the measurement and the drift/sqlite3 line references).
  ///
  /// Without this, every write made inside a transaction sits in the drift
  /// worker's memory until some LATER unrelated statement happens to flush
  /// it, so the last transaction before the tab closes is lost — silently,
  /// permanently, and invisibly to the sync engine (the row never reaches the
  /// database, so `dirty` is never set and "nothing pending" is the truthful
  /// answer).
  ///
  /// Three deliberate choices:
  ///
  ///  * AFTER `super.transaction` returns, not inside a `QueryInterceptor`'s
  ///    `commitTransaction`. Drift releases the executor lock via
  ///    `_release()`'s `_done.complete()` (`engines.dart:300-307`) which the
  ///    parent's `_synchronized` block awaits — issuing a root-level
  ///    statement before that resumes risks deadlocking against the lock the
  ///    committing transaction still holds.
  ///  * Only at depth 0, for the reason on [_openTransactions].
  ///  * The flush is AWAITED and its failure PROPAGATES. A flush that fails
  ///    means the data is not on disk, and returning normally would be the
  ///    same silent-loss bug in a new place. This is also consistent with
  ///    what already happens for writes OUTSIDE a transaction: drift awaits
  ///    the identical `_flush()` inside `runInsert`/`runUpdate`, so a bare
  ///    `INSERT` already throws when the mirror cannot be written. Callers
  ///    saw that behaviour before this change; they now see it for
  ///    transactions too.
  ///
  /// A rolled-back transaction flushes nothing: the exception propagates out
  /// of the `finally` before the flush, which is correct — there is no
  /// committed state to persist.
  @override
  Future<T> transaction<T>(
    Future<T> Function() action, {
    bool requireNew = false,
  }) async {
    _openTransactions++;
    final T result;
    try {
      result = await super.transaction(action, requireNew: requireNew);
    } finally {
      _openTransactions--;
    }
    // No `await` between the decrement and this check, so no other
    // transaction can interleave and hide the flush. Even if one could, the
    // gate is conservative rather than lossy: `flush()` drains the whole
    // queue, so whichever transaction finishes last persists the work of
    // every transaction that overlapped it.
    if (_flushAfterCommit && _openTransactions == 0) {
      await customStatement(_postCommitFlushStatement);
    }
    return result;
  }
}
