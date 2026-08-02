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
    Comments,
    Likes,
    Ascents,
    Profiles,
    AppSettings,
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
  int get schemaVersion => 9;

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
      // `visibility`/`authorName`/`ascentId` baked in from the start. Re-running
      // the ADD COLUMN/alterTable steps below on such a fresh table would
      // fail (`duplicate column name`), so they only run for a database
      // that already had the pre-v7 (two-column-short) shape on disk, i.e.
      // one that reached v3+ before this migration was introduced.
      if (from < 7 && from >= 3) {
        await m.addColumn(ascents, ascents.visibility);
        await m.addColumn(ascents, ascents.authorName);

        await m.alterTable(
          TableMigration(likes, newColumns: [likes.ascentId]),
        );
        await m.alterTable(
          TableMigration(comments, newColumns: [comments.ascentId]),
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
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

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
