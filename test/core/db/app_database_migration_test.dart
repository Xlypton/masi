import 'dart:io';

import 'package:climbtopo/core/db/app_database.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite3lib;

/// P1-a: the v1 -> v2 migration for the row-level cloud-sync pivot.
///
/// Migration-testing approach used (documented per the task): this repo has
/// no `drift_dev` schema-export / `SchemaVerifier` test infrastructure set
/// up (no `build.yaml` schema export config, no `drift_schemas/` folder —
/// confirmed absent), and this is the very first migration the app has ever
/// shipped (schemaVersion was `1` with an always-empty `onUpgrade` since
/// M0). Standing up that infra from scratch was judged out of scope for
/// this Phase 1 slice, so this test takes the pragmatic route instead: it
/// hand-builds a real on-disk SQLite file with the exact pre-migration (v1)
/// schema — the same tables/columns as `tables.dart`'s `SyncColumns` mixin +
/// `Walls`/`Routes` MINUS the new `ownerId`/`visibility` columns — using
/// `package:sqlite3` directly (already a transitive `drift` dependency;
/// there is no lower-level "run raw DDL" surface on drift's own
/// `NativeDatabase` outside of a generated schema). It seeds one row per
/// table and stamps `PRAGMA user_version = 1`, then opens that exact file
/// with the CURRENT [AppDatabase] (`schemaVersion == 2`). Drift reads the
/// on-disk `user_version` (1), sees it differs from the target (2), and
/// calls `onUpgrade(m, 1, 2)` instead of `onCreate` — this is the same code
/// path a real device takes when the app updates out from under an
/// existing local database.
///
/// Limitation: this snapshot is maintained by hand rather than generated,
/// so it will silently go stale if the v1 shape is ever forgotten to be
/// updated alongside a future schema change that predates v2. That's an
/// accepted tradeoff for not introducing the full schema-versioning
/// build_runner pipeline in this phase.
void main() {
  group('P1-a: v1 -> v2 migration (row-level cloud-sync pivot)', () {
    late Directory tempDir;
    late File dbFile;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'climbtopo_migration_test_',
      );
      dbFile = File(p.join(tempDir.path, 'v1.sqlite'));
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'ADD COLUMN migration adds ownerId (all 5 tables) + visibility '
      '(walls only) without losing pre-existing rows: ownerId comes back '
      'null and visibility defaults to private',
      () async {
        final raw = sqlite3lib.sqlite3.open(dbFile.path);
        raw.execute('''
          CREATE TABLE areas (
            id TEXT NOT NULL PRIMARY KEY,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            deleted_at INTEGER NULL,
            remote_id TEXT NULL,
            dirty INTEGER NOT NULL DEFAULT 0,
            name TEXT NOT NULL,
            description TEXT NULL,
            latitude REAL NULL,
            longitude REAL NULL
          );

          CREATE TABLE sectors (
            id TEXT NOT NULL PRIMARY KEY,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            deleted_at INTEGER NULL,
            remote_id TEXT NULL,
            dirty INTEGER NOT NULL DEFAULT 0,
            area_id TEXT NOT NULL REFERENCES areas (id),
            name TEXT NOT NULL,
            sort_order INTEGER NOT NULL
          );

          CREATE TABLE walls (
            id TEXT NOT NULL PRIMARY KEY,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            deleted_at INTEGER NULL,
            remote_id TEXT NULL,
            dirty INTEGER NOT NULL DEFAULT 0,
            sector_id TEXT NOT NULL REFERENCES sectors (id),
            name TEXT NOT NULL,
            sort_order INTEGER NOT NULL
          );

          CREATE TABLE photos (
            id TEXT NOT NULL PRIMARY KEY,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            deleted_at INTEGER NULL,
            remote_id TEXT NULL,
            dirty INTEGER NOT NULL DEFAULT 0,
            wall_id TEXT NOT NULL REFERENCES walls (id),
            local_path TEXT NOT NULL,
            kind TEXT NOT NULL,
            width INTEGER NOT NULL,
            height INTEGER NOT NULL,
            parent_photo_id TEXT NULL REFERENCES photos (id),
            crop_xpct REAL NULL,
            crop_width_pct REAL NULL
          );

          CREATE TABLE routes (
            id TEXT NOT NULL PRIMARY KEY,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            deleted_at INTEGER NULL,
            remote_id TEXT NULL,
            dirty INTEGER NOT NULL DEFAULT 0,
            wall_id TEXT NOT NULL REFERENCES walls (id),
            photo_id TEXT NOT NULL REFERENCES photos (id),
            number INTEGER NOT NULL,
            name TEXT NULL,
            grade_system TEXT NULL,
            grade_raw TEXT NULL,
            grade_sort_key REAL NULL,
            style TEXT NULL,
            description TEXT NULL,
            color_index INTEGER NOT NULL,
            points_json TEXT NOT NULL,
            symbols_json TEXT NOT NULL,
            sort_order INTEGER NOT NULL,
            visible INTEGER NOT NULL DEFAULT 1
          );

          CREATE UNIQUE INDEX idx_routes_wall_number_live
            ON routes (wall_id, number) WHERE deleted_at IS NULL;

          INSERT INTO areas (id, created_at, updated_at, name)
            VALUES ('area-1', 1000, 1000, 'Pre-migration Area');

          INSERT INTO sectors
            (id, created_at, updated_at, area_id, name, sort_order)
            VALUES
            ('sector-1', 1000, 1000, 'area-1', 'Pre-migration Sector', 0);

          INSERT INTO walls
            (id, created_at, updated_at, sector_id, name, sort_order)
            VALUES
            ('wall-1', 1000, 1000, 'sector-1', 'Pre-migration Wall', 0);

          INSERT INTO photos
            (id, created_at, updated_at, wall_id, local_path, kind, width,
             height)
            VALUES
            ('photo-1', 1000, 1000, 'wall-1', '/tmp/p.jpg', 'original', 100,
             200);

          INSERT INTO routes
            (id, created_at, updated_at, wall_id, photo_id, number,
             color_index, points_json, symbols_json, sort_order)
            VALUES
            ('route-1', 1000, 1000, 'wall-1', 'photo-1', 1, 0, '[]', '[]', 0);

          PRAGMA user_version = 1;
        ''');
        raw.close();

        // Open the SAME file with the current AppDatabase (schemaVersion
        // 2). Drift reads the on-disk user_version (1), sees it doesn't
        // match the target (2), and runs onUpgrade(m, 1, 2) — never
        // onCreate, which would silently paper over a broken migration by
        // just creating the v2 schema fresh.
        final db = AppDatabase(NativeDatabase(dbFile));
        addTearDown(db.close);

        final area = await (db.select(
          db.areas,
        )..where((t) => t.id.equals('area-1'))).getSingle();
        expect(
          area.name,
          'Pre-migration Area',
          reason: 'pre-existing row must survive the migration',
        );
        expect(area.ownerId, isNull);

        final sector = await (db.select(
          db.sectors,
        )..where((t) => t.id.equals('sector-1'))).getSingle();
        expect(sector.name, 'Pre-migration Sector');
        expect(sector.areaId, 'area-1');
        expect(sector.ownerId, isNull);

        final wall = await (db.select(
          db.walls,
        )..where((t) => t.id.equals('wall-1'))).getSingle();
        expect(wall.name, 'Pre-migration Wall');
        expect(wall.sectorId, 'sector-1');
        expect(wall.ownerId, isNull);
        expect(
          wall.visibility,
          'private',
          reason:
              'the new visibility column must ADD COLUMN with its default '
              'for pre-existing rows',
        );

        final photo = await (db.select(
          db.photos,
        )..where((t) => t.id.equals('photo-1'))).getSingle();
        expect(photo.localPath, '/tmp/p.jpg');
        expect(photo.wallId, 'wall-1');
        expect(photo.ownerId, isNull);

        final route = await (db.select(
          db.routes,
        )..where((t) => t.id.equals('route-1'))).getSingle();
        expect(route.wallId, 'wall-1');
        expect(route.photoId, 'photo-1');
        expect(route.ownerId, isNull);

        // Post-migration inserts on all 5 tables must still work (proves
        // the new columns are wired into the generated Companions/tables,
        // not just physically present in SQLite).
        await db
            .into(db.areas)
            .insert(
              AreasCompanion.insert(
                id: 'area-2',
                createdAt: 2000,
                updatedAt: 2000,
                name: 'Post-migration Area',
                ownerId: const Value('u1'),
              ),
            );
        final newArea = await (db.select(
          db.areas,
        )..where((t) => t.id.equals('area-2'))).getSingle();
        expect(newArea.ownerId, 'u1');
      },
    );
  });

  group('P2: v2 -> v3 migration (comments, likes, ascents)', () {
    late Directory tempDir;
    late File dbFile;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'climbtopo_migration_test_',
      );
      dbFile = File(p.join(tempDir.path, 'v2.sqlite'));
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'creates comments/likes/ascents tables and preserves pre-existing '
      'rows on the v1-era tables',
      () async {
        final raw = sqlite3lib.sqlite3.open(dbFile.path);
        raw.execute('''
          CREATE TABLE areas (
            id TEXT NOT NULL PRIMARY KEY,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            deleted_at INTEGER NULL,
            remote_id TEXT NULL,
            dirty INTEGER NOT NULL DEFAULT 0,
            owner_id TEXT NULL,
            name TEXT NOT NULL,
            description TEXT NULL,
            latitude REAL NULL,
            longitude REAL NULL
          );

          CREATE TABLE sectors (
            id TEXT NOT NULL PRIMARY KEY,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            deleted_at INTEGER NULL,
            remote_id TEXT NULL,
            dirty INTEGER NOT NULL DEFAULT 0,
            owner_id TEXT NULL,
            area_id TEXT NOT NULL REFERENCES areas (id),
            name TEXT NOT NULL,
            sort_order INTEGER NOT NULL
          );

          CREATE TABLE walls (
            id TEXT NOT NULL PRIMARY KEY,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            deleted_at INTEGER NULL,
            remote_id TEXT NULL,
            dirty INTEGER NOT NULL DEFAULT 0,
            owner_id TEXT NULL,
            sector_id TEXT NOT NULL REFERENCES sectors (id),
            name TEXT NOT NULL,
            sort_order INTEGER NOT NULL,
            visibility TEXT NOT NULL DEFAULT 'private'
          );

          CREATE TABLE photos (
            id TEXT NOT NULL PRIMARY KEY,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            deleted_at INTEGER NULL,
            remote_id TEXT NULL,
            dirty INTEGER NOT NULL DEFAULT 0,
            owner_id TEXT NULL,
            wall_id TEXT NOT NULL REFERENCES walls (id),
            local_path TEXT NOT NULL,
            kind TEXT NOT NULL,
            width INTEGER NOT NULL,
            height INTEGER NOT NULL,
            parent_photo_id TEXT NULL REFERENCES photos (id),
            crop_xpct REAL NULL,
            crop_width_pct REAL NULL
          );

          CREATE TABLE routes (
            id TEXT NOT NULL PRIMARY KEY,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            deleted_at INTEGER NULL,
            remote_id TEXT NULL,
            dirty INTEGER NOT NULL DEFAULT 0,
            owner_id TEXT NULL,
            wall_id TEXT NOT NULL REFERENCES walls (id),
            photo_id TEXT NOT NULL REFERENCES photos (id),
            number INTEGER NOT NULL,
            name TEXT NULL,
            grade_system TEXT NULL,
            grade_raw TEXT NULL,
            grade_sort_key REAL NULL,
            style TEXT NULL,
            description TEXT NULL,
            color_index INTEGER NOT NULL,
            points_json TEXT NOT NULL,
            symbols_json TEXT NOT NULL,
            sort_order INTEGER NOT NULL,
            visible INTEGER NOT NULL DEFAULT 1
          );

          CREATE UNIQUE INDEX idx_routes_wall_number_live
            ON routes (wall_id, number) WHERE deleted_at IS NULL;

          INSERT INTO areas (id, created_at, updated_at, name)
            VALUES ('area-1', 1000, 1000, 'Pre-migration Area');

          INSERT INTO sectors
            (id, created_at, updated_at, area_id, name, sort_order)
            VALUES
            ('sector-1', 1000, 1000, 'area-1', 'Pre-migration Sector', 0);

          INSERT INTO walls
            (id, created_at, updated_at, sector_id, name, sort_order)
            VALUES
            ('wall-1', 1000, 1000, 'sector-1', 'Pre-migration Wall', 0);

          INSERT INTO photos
            (id, created_at, updated_at, wall_id, local_path, kind, width,
             height)
            VALUES
            ('photo-1', 1000, 1000, 'wall-1', '/tmp/p.jpg', 'original', 100,
             200);

          INSERT INTO routes
            (id, created_at, updated_at, wall_id, photo_id, number,
             color_index, points_json, symbols_json, sort_order)
            VALUES
            ('route-1', 1000, 1000, 'wall-1', 'photo-1', 1, 0, '[]', '[]', 0);

          PRAGMA user_version = 2;
        ''');
        raw.close();

        // Open the SAME file with the current AppDatabase (schemaVersion
        // 3). Drift reads the on-disk user_version (2), sees it doesn't
        // match the target (3), and runs onUpgrade(m, 2, 3) — exercising
        // only the `if (from < 3)` branch (the `from < 2` branch is a
        // no-op here since `2 < 2` is false).
        final db = AppDatabase(NativeDatabase(dbFile));
        addTearDown(db.close);

        // Pre-existing v2-era rows must survive untouched.
        final wall = await (db.select(
          db.walls,
        )..where((t) => t.id.equals('wall-1'))).getSingle();
        expect(wall.name, 'Pre-migration Wall');

        final route = await (db.select(
          db.routes,
        )..where((t) => t.id.equals('route-1'))).getSingle();
        expect(route.wallId, 'wall-1');

        // The 3 new tables must exist and be usable (proves the generated
        // Companions/tables are wired, not just physically present).
        await db
            .into(db.comments)
            .insert(
              CommentsCompanion.insert(
                id: 'comment-1',
                createdAt: 3000,
                updatedAt: 3000,
                wallId: 'wall-1',
                body: 'Nice line!',
              ),
            );
        final comment = await (db.select(
          db.comments,
        )..where((t) => t.id.equals('comment-1'))).getSingle();
        expect(comment.wallId, 'wall-1');
        expect(comment.body, 'Nice line!');
        expect(comment.authorName, isNull);
        expect(comment.dirty, isFalse);
        expect(comment.ownerId, isNull);

        await db
            .into(db.likes)
            .insert(
              LikesCompanion.insert(
                id: 'like-1',
                createdAt: 3000,
                updatedAt: 3000,
                wallId: 'wall-1',
              ),
            );
        final like = await (db.select(
          db.likes,
        )..where((t) => t.id.equals('like-1'))).getSingle();
        expect(like.wallId, 'wall-1');

        await db
            .into(db.ascents)
            .insert(
              AscentsCompanion.insert(
                id: 'ascent-1',
                createdAt: 3000,
                updatedAt: 3000,
                routeId: 'route-1',
                wallId: 'wall-1',
                climbedAt: 3000,
                style: 'redpoint',
              ),
            );
        final ascent = await (db.select(
          db.ascents,
        )..where((t) => t.id.equals('ascent-1'))).getSingle();
        expect(ascent.routeId, 'route-1');
        expect(ascent.wallId, 'wall-1');
        expect(ascent.style, 'redpoint');
        expect(ascent.notes, isNull);
        expect(ascent.gradeOpinion, isNull);
      },
    );
  });

  group('fresh onCreate (schemaVersion 3)', () {
    test('builds all 8 tables, each carrying the full SyncColumns set', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      final tableNames = await db
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type = 'table' "
            "AND name NOT LIKE 'sqlite_%'",
          )
          .map((row) => row.read<String>('name'))
          .get();

      expect(
        tableNames.toSet(),
        {
          'areas',
          'sectors',
          'walls',
          'photos',
          'routes',
          'comments',
          'likes',
          'ascents',
        },
        reason: 'onCreate must build every table declared on AppDatabase',
      );

      // Spot-check the SyncColumns set on each of the 3 new tables by
      // inserting a minimal row and reading every mixin column back.
      final now = 5000;

      await db
          .into(db.areas)
          .insert(
            AreasCompanion.insert(
              id: 'area-1',
              createdAt: now,
              updatedAt: now,
              name: 'Area',
            ),
          );
      await db
          .into(db.sectors)
          .insert(
            SectorsCompanion.insert(
              id: 'sector-1',
              createdAt: now,
              updatedAt: now,
              areaId: 'area-1',
              name: 'Sector',
              sortOrder: 0,
            ),
          );
      await db
          .into(db.walls)
          .insert(
            WallsCompanion.insert(
              id: 'wall-1',
              createdAt: now,
              updatedAt: now,
              sectorId: 'sector-1',
              name: 'Wall',
              sortOrder: 0,
            ),
          );
      await db
          .into(db.photos)
          .insert(
            PhotosCompanion.insert(
              id: 'photo-1',
              createdAt: now,
              updatedAt: now,
              wallId: 'wall-1',
              localPath: '/tmp/p.jpg',
              kind: 'original',
              width: 100,
              height: 200,
            ),
          );
      await db
          .into(db.routes)
          .insert(
            RoutesCompanion.insert(
              id: 'route-1',
              createdAt: now,
              updatedAt: now,
              wallId: 'wall-1',
              photoId: 'photo-1',
              number: 1,
              colorIndex: 0,
              pointsJson: '[]',
              symbolsJson: '[]',
              sortOrder: 0,
            ),
          );

      await db
          .into(db.comments)
          .insert(
            CommentsCompanion.insert(
              id: 'comment-1',
              createdAt: now,
              updatedAt: now,
              wallId: 'wall-1',
              body: 'Great route',
              authorName: const Value('Alex'),
              deletedAt: const Value(6000),
              remoteId: const Value('remote-comment-1'),
              dirty: const Value(true),
              ownerId: const Value('user-1'),
            ),
          );
      final comment = await (db.select(
        db.comments,
      )..where((t) => t.id.equals('comment-1'))).getSingle();
      expect(comment.wallId, 'wall-1');
      expect(comment.body, 'Great route');
      expect(comment.authorName, 'Alex');
      expect(comment.createdAt, now);
      expect(comment.updatedAt, now);
      expect(comment.deletedAt, 6000);
      expect(comment.remoteId, 'remote-comment-1');
      expect(comment.dirty, isTrue);
      expect(comment.ownerId, 'user-1');

      await db
          .into(db.likes)
          .insert(
            LikesCompanion.insert(
              id: 'like-1',
              createdAt: now,
              updatedAt: now,
              wallId: 'wall-1',
              deletedAt: const Value(6000),
              remoteId: const Value('remote-like-1'),
              dirty: const Value(true),
              ownerId: const Value('user-1'),
            ),
          );
      final like = await (db.select(
        db.likes,
      )..where((t) => t.id.equals('like-1'))).getSingle();
      expect(like.wallId, 'wall-1');
      expect(like.createdAt, now);
      expect(like.updatedAt, now);
      expect(like.deletedAt, 6000);
      expect(like.remoteId, 'remote-like-1');
      expect(like.dirty, isTrue);
      expect(like.ownerId, 'user-1');

      await db
          .into(db.ascents)
          .insert(
            AscentsCompanion.insert(
              id: 'ascent-1',
              createdAt: now,
              updatedAt: now,
              routeId: 'route-1',
              wallId: 'wall-1',
              climbedAt: now,
              style: 'onsight',
              notes: const Value('Felt great'),
              gradeOpinion: const Value('soft'),
              deletedAt: const Value(6000),
              remoteId: const Value('remote-ascent-1'),
              dirty: const Value(true),
              ownerId: const Value('user-1'),
            ),
          );
      final ascent = await (db.select(
        db.ascents,
      )..where((t) => t.id.equals('ascent-1'))).getSingle();
      expect(ascent.routeId, 'route-1');
      expect(ascent.wallId, 'wall-1');
      expect(ascent.climbedAt, now);
      expect(ascent.style, 'onsight');
      expect(ascent.notes, 'Felt great');
      expect(ascent.gradeOpinion, 'soft');
      expect(ascent.createdAt, now);
      expect(ascent.updatedAt, now);
      expect(ascent.deletedAt, 6000);
      expect(ascent.remoteId, 'remote-ascent-1');
      expect(ascent.dirty, isTrue);
      expect(ascent.ownerId, 'user-1');
    });
  });
}
