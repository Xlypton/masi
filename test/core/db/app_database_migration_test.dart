import 'dart:io';

import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/settings_store.dart';
import 'package:drift/drift.dart'
    show BooleanExpressionOperators, OrderingTerm, Value;
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
        'masi_migration_test_',
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
        'masi_migration_test_',
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
                wallId: const Value('wall-1'),
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
                wallId: const Value('wall-1'),
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

  group('P3: v3 -> v4 migration (wall coordinates)', () {
    late Directory tempDir;
    late File dbFile;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'masi_migration_test_',
      );
      dbFile = File(p.join(tempDir.path, 'v3.sqlite'));
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'ADD COLUMN migration adds latitude/longitude to walls without '
      'losing pre-existing rows: both come back null for a pre-migration '
      'wall, and a post-migration wall can set/read them',
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

          CREATE TABLE comments (
            id TEXT NOT NULL PRIMARY KEY,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            deleted_at INTEGER NULL,
            remote_id TEXT NULL,
            dirty INTEGER NOT NULL DEFAULT 0,
            owner_id TEXT NULL,
            wall_id TEXT NOT NULL REFERENCES walls (id),
            body TEXT NOT NULL,
            author_name TEXT NULL
          );

          CREATE TABLE likes (
            id TEXT NOT NULL PRIMARY KEY,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            deleted_at INTEGER NULL,
            remote_id TEXT NULL,
            dirty INTEGER NOT NULL DEFAULT 0,
            owner_id TEXT NULL,
            wall_id TEXT NOT NULL REFERENCES walls (id)
          );

          CREATE TABLE ascents (
            id TEXT NOT NULL PRIMARY KEY,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            deleted_at INTEGER NULL,
            remote_id TEXT NULL,
            dirty INTEGER NOT NULL DEFAULT 0,
            owner_id TEXT NULL,
            route_id TEXT NOT NULL REFERENCES routes (id),
            wall_id TEXT NOT NULL REFERENCES walls (id),
            climbed_at INTEGER NOT NULL,
            style TEXT NOT NULL,
            notes TEXT NULL,
            grade_opinion TEXT NULL
          );

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

          PRAGMA user_version = 3;
        ''');
        raw.close();

        // Open the SAME file with the current AppDatabase (schemaVersion
        // 4). Drift reads the on-disk user_version (3), sees it doesn't
        // match the target (4), and runs onUpgrade(m, 3, 4) — exercising
        // only the `if (from < 4)` branch (the earlier branches are no-ops
        // here since `3 < 2` and `3 < 3` are both false).
        final db = AppDatabase(NativeDatabase(dbFile));
        addTearDown(db.close);

        final wall = await (db.select(
          db.walls,
        )..where((t) => t.id.equals('wall-1'))).getSingle();
        expect(
          wall.name,
          'Pre-migration Wall',
          reason: 'pre-existing row must survive the migration',
        );
        expect(
          wall.latitude,
          isNull,
          reason:
              'the new latitude column must ADD COLUMN as null for '
              'pre-existing rows',
        );
        expect(wall.longitude, isNull);

        // Post-migration: the new columns are wired into the generated
        // Companion/table (not just physically present in SQLite), and a
        // fresh wall can set + read back real coordinates.
        await db
            .into(db.walls)
            .insert(
              WallsCompanion.insert(
                id: 'wall-2',
                createdAt: 2000,
                updatedAt: 2000,
                sectorId: 'sector-1',
                name: 'Post-migration Wall',
                sortOrder: 1,
                latitude: const Value(47.4979),
                longitude: const Value(19.0402),
              ),
            );
        final newWall = await (db.select(
          db.walls,
        )..where((t) => t.id.equals('wall-2'))).getSingle();
        expect(newWall.latitude, 47.4979);
        expect(newWall.longitude, 19.0402);
      },
    );
  });

  group('P4: v4 -> v5 migration (per-route metadata #41/#42/#44)', () {
    late Directory tempDir;
    late File dbFile;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'masi_migration_test_',
      );
      dbFile = File(p.join(tempDir.path, 'v4.sqlite'));
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'ADD COLUMN migration adds betaVideoUrl/styleTagsJson/stars to '
      'routes without losing pre-existing rows: all three come back null '
      'for a pre-migration route, and a post-migration route can set/read '
      'them',
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
            visibility TEXT NOT NULL DEFAULT 'private',
            latitude REAL NULL,
            longitude REAL NULL
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

          CREATE TABLE comments (
            id TEXT NOT NULL PRIMARY KEY,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            deleted_at INTEGER NULL,
            remote_id TEXT NULL,
            dirty INTEGER NOT NULL DEFAULT 0,
            owner_id TEXT NULL,
            wall_id TEXT NOT NULL REFERENCES walls (id),
            body TEXT NOT NULL,
            author_name TEXT NULL
          );

          CREATE TABLE likes (
            id TEXT NOT NULL PRIMARY KEY,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            deleted_at INTEGER NULL,
            remote_id TEXT NULL,
            dirty INTEGER NOT NULL DEFAULT 0,
            owner_id TEXT NULL,
            wall_id TEXT NOT NULL REFERENCES walls (id)
          );

          CREATE TABLE ascents (
            id TEXT NOT NULL PRIMARY KEY,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            deleted_at INTEGER NULL,
            remote_id TEXT NULL,
            dirty INTEGER NOT NULL DEFAULT 0,
            owner_id TEXT NULL,
            route_id TEXT NOT NULL REFERENCES routes (id),
            wall_id TEXT NOT NULL REFERENCES walls (id),
            climbed_at INTEGER NOT NULL,
            style TEXT NOT NULL,
            notes TEXT NULL,
            grade_opinion TEXT NULL
          );

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

          PRAGMA user_version = 4;
        ''');
        raw.close();

        // Open the SAME file with the current AppDatabase (schemaVersion
        // 5). Drift reads the on-disk user_version (4), sees it doesn't
        // match the target (5), and runs onUpgrade(m, 4, 5) — exercising
        // only the `if (from < 5)` branch (the earlier branches are no-ops
        // here since 4 is not < 2/3/4).
        final db = AppDatabase(NativeDatabase(dbFile));
        addTearDown(db.close);

        final route = await (db.select(
          db.routes,
        )..where((t) => t.id.equals('route-1'))).getSingle();
        expect(
          route.wallId,
          'wall-1',
          reason: 'pre-existing row must survive the migration',
        );
        expect(
          route.betaVideoUrl,
          isNull,
          reason:
              'the new betaVideoUrl column must ADD COLUMN as null for '
              'pre-existing rows',
        );
        expect(route.styleTagsJson, isNull);
        expect(route.stars, isNull);

        // Post-migration: the new columns are wired into the generated
        // Companion/table (not just physically present in SQLite), and a
        // fresh route can set + read back all three.
        await db
            .into(db.routes)
            .insert(
              RoutesCompanion.insert(
                id: 'route-2',
                createdAt: 2000,
                updatedAt: 2000,
                wallId: 'wall-1',
                photoId: 'photo-1',
                number: 2,
                colorIndex: 0,
                pointsJson: '[]',
                symbolsJson: '[]',
                sortOrder: 1,
                betaVideoUrl: const Value('https://example.com/beta'),
                styleTagsJson: const Value('["dyno"]'),
                stars: const Value(3),
              ),
            );
        final newRoute = await (db.select(
          db.routes,
        )..where((t) => t.id.equals('route-2'))).getSingle();
        expect(newRoute.betaVideoUrl, 'https://example.com/beta');
        expect(newRoute.styleTagsJson, '["dyno"]');
        expect(newRoute.stars, 3);
      },
    );
  });

  group('P5: v5 -> v6 migration (multi-photo-per-topo + #46 fix)', () {
    late Directory tempDir;
    late File dbFile;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'masi_migration_test_',
      );
      dbFile = File(p.join(tempDir.path, 'v5.sqlite'));
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    /// Hand-builds a v5 (pre-`sortOrder`/`isPrimary`) on-disk database: three
    /// walls exercising every shape the v5->v6 data migration must handle
    /// defensively — `wall-two-originals` has accumulated 2 live `'original'`
    /// photos (the exact #46 bug shape: `attachPhotoToWall` never superseded
    /// a wall's previous original), `wall-one-original` has exactly 1, and
    /// `wall-no-photo` has none at all.
    Future<void> seedV5Database() async {
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
          visibility TEXT NOT NULL DEFAULT 'private',
          latitude REAL NULL,
          longitude REAL NULL
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
          visible INTEGER NOT NULL DEFAULT 1,
          beta_video_url TEXT NULL,
          style_tags_json TEXT NULL,
          stars INTEGER NULL
        );

        CREATE UNIQUE INDEX idx_routes_wall_number_live
          ON routes (wall_id, number) WHERE deleted_at IS NULL;

        CREATE TABLE comments (
          id TEXT NOT NULL PRIMARY KEY,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          deleted_at INTEGER NULL,
          remote_id TEXT NULL,
          dirty INTEGER NOT NULL DEFAULT 0,
          owner_id TEXT NULL,
          wall_id TEXT NOT NULL REFERENCES walls (id),
          body TEXT NOT NULL,
          author_name TEXT NULL
        );

        CREATE TABLE likes (
          id TEXT NOT NULL PRIMARY KEY,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          deleted_at INTEGER NULL,
          remote_id TEXT NULL,
          dirty INTEGER NOT NULL DEFAULT 0,
          owner_id TEXT NULL,
          wall_id TEXT NOT NULL REFERENCES walls (id)
        );

        CREATE TABLE ascents (
          id TEXT NOT NULL PRIMARY KEY,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          deleted_at INTEGER NULL,
          remote_id TEXT NULL,
          dirty INTEGER NOT NULL DEFAULT 0,
          owner_id TEXT NULL,
          route_id TEXT NOT NULL REFERENCES routes (id),
          wall_id TEXT NOT NULL REFERENCES walls (id),
          climbed_at INTEGER NOT NULL,
          style TEXT NOT NULL,
          notes TEXT NULL,
          grade_opinion TEXT NULL
        );

        INSERT INTO areas (id, created_at, updated_at, name)
          VALUES ('area-1', 1000, 1000, 'Pre-migration Area');

        INSERT INTO sectors
          (id, created_at, updated_at, area_id, name, sort_order)
          VALUES
          ('sector-1', 1000, 1000, 'area-1', 'Pre-migration Sector', 0);

        INSERT INTO walls
          (id, created_at, updated_at, sector_id, name, sort_order)
          VALUES
          ('wall-two-originals', 1000, 1000, 'sector-1',
           'Wall With Two Originals (#46 shape)', 0),
          ('wall-one-original', 1000, 1000, 'sector-1',
           'Wall With One Original', 1),
          ('wall-no-photo', 1000, 1000, 'sector-1',
           'Wall With No Photo', 2);

        -- wall-two-originals: two live 'original' photos, the exact #46
        -- accumulation bug shape — nothing on-disk distinguishes them yet.
        INSERT INTO photos
          (id, created_at, updated_at, wall_id, local_path, kind, width,
           height)
          VALUES
          ('photo-older', 1000, 1000, 'wall-two-originals',
           '/tmp/older.jpg', 'original', 100, 200),
          ('photo-newer', 2000, 2000, 'wall-two-originals',
           '/tmp/newer.jpg', 'original', 100, 200);

        -- wall-one-original: exactly one live original.
        INSERT INTO photos
          (id, created_at, updated_at, wall_id, local_path, kind, width,
           height)
          VALUES
          ('photo-single', 1500, 1500, 'wall-one-original',
           '/tmp/single.jpg', 'original', 100, 200);

        INSERT INTO routes
          (id, created_at, updated_at, wall_id, photo_id, number,
           color_index, points_json, symbols_json, sort_order)
          VALUES
          ('route-1', 1000, 1000, 'wall-two-originals', 'photo-older', 1, 0,
           '[]', '[]', 0);

        PRAGMA user_version = 5;
      ''');
      raw.close();
    }

    test(
      'ADD COLUMN migration adds sortOrder/isPrimary to photos, replaces '
      'the wall-scoped route index with the photo-scoped one, and the #46 '
      'data backfill flags exactly one primary per wall + assigns ordinal '
      'sortOrder — defensively across 2/1/0-original walls',
      () async {
        await seedV5Database();

        // Open the SAME file with the current AppDatabase (schemaVersion
        // 6). Drift reads the on-disk user_version (5), sees it doesn't
        // match the target (6), and runs onUpgrade(m, 5, 6) — exercising
        // only the `if (from < 6)` branch (the earlier branches are no-ops
        // here since 5 is not < 2/3/4/5).
        final db = AppDatabase(NativeDatabase(dbFile));
        addTearDown(db.close);

        // --- wall-two-originals: the #46 bug shape ---------------------
        final twoOriginals =
            await (db.select(db.photos)
                  ..where(
                    (t) =>
                        t.wallId.equals('wall-two-originals') &
                        t.kind.equals('original'),
                  )
                  ..orderBy([(t) => OrderingTerm(expression: t.createdAt)]))
                .get();
        expect(twoOriginals, hasLength(2));

        final primaryFlags = twoOriginals.map((p) => p.isPrimary).toList();
        expect(
          primaryFlags.where((f) => f).length,
          1,
          reason: 'exactly one of the two accumulated originals must be '
              'flagged primary — no row is ever deleted',
        );
        final newest = twoOriginals.firstWhere((p) => p.id == 'photo-newer');
        expect(
          newest.isPrimary,
          isTrue,
          reason: 'the NEWEST (max createdAt) live original becomes primary',
        );
        final older = twoOriginals.firstWhere((p) => p.id == 'photo-older');
        expect(older.isPrimary, isFalse);

        // sortOrder assigned ascending by createdAt (0, 1, 2...).
        expect(older.sortOrder, 0);
        expect(newest.sortOrder, 1);

        // Pre-existing route row survives untouched.
        final route = await (db.select(
          db.routes,
        )..where((t) => t.id.equals('route-1'))).getSingle();
        expect(route.wallId, 'wall-two-originals');
        expect(route.photoId, 'photo-older');

        // --- wall-one-original: single original, trivially becomes '01' -
        final oneOriginal = await (db.select(
          db.photos,
        )..where((t) => t.wallId.equals('wall-one-original'))).getSingle();
        expect(oneOriginal.isPrimary, isTrue);
        expect(oneOriginal.sortOrder, 0);

        // --- wall-no-photo: zero originals, migration must not crash on --
        // --- (and produces nothing to assert on) --------------------------
        final noPhotoRows = await (db.select(
          db.photos,
        )..where((t) => t.wallId.equals('wall-no-photo'))).get();
        expect(noPhotoRows, isEmpty);

        // --- the route unique index moved from wall-scoped to photo------
        // --- scoped: a second photo on wall-two-originals can now reuse --
        // --- route number 1 (previously would have violated the old ------
        // --- wall_id+number index). -------------------------------------
        await db
            .into(db.photos)
            .insert(
              PhotosCompanion.insert(
                id: 'photo-post-migration',
                createdAt: 4000,
                updatedAt: 4000,
                wallId: 'wall-two-originals',
                localPath: '/tmp/post.jpg',
                kind: 'original',
                width: 100,
                height: 200,
              ),
            );
        await db
            .into(db.routes)
            .insert(
              RoutesCompanion.insert(
                id: 'route-2',
                createdAt: 4000,
                updatedAt: 4000,
                wallId: 'wall-two-originals',
                photoId: 'photo-post-migration',
                number: 1,
                colorIndex: 0,
                pointsJson: '[]',
                symbolsJson: '[]',
                sortOrder: 0,
              ),
            );
        final bothNumberOnes = await (db.select(
          db.routes,
        )..where((t) => t.wallId.equals('wall-two-originals'))).get();
        expect(
          bothNumberOnes.map((r) => r.number).toList(),
          [1, 1],
          reason: 'two different photos on the same wall can each have '
              'their own route 1 now that the unique index is photo-scoped',
        );

        // The OLD wall-scoped index must be gone — a duplicate (wall_id,
        // number) pair across DIFFERENT photos (proven above) would have
        // violated it were it still present.
        final indexNames = await db
            .customSelect(
              "SELECT name FROM sqlite_master WHERE type = 'index' "
              "AND tbl_name = 'routes'",
            )
            .map((row) => row.read<String>('name'))
            .get();
        expect(indexNames, contains('idx_routes_photo_number_live'));
        expect(indexNames, isNot(contains('idx_routes_wall_number_live')));
      },
    );
  });

  group(
    'P6: v6 -> v7 migration (ascent visibility + likes/comments ascentId)',
    () {
      late Directory tempDir;
      late File dbFile;

      setUp(() async {
        tempDir = await Directory.systemTemp.createTemp(
          'masi_migration_test_',
        );
        dbFile = File(p.join(tempDir.path, 'v6.sqlite'));
      });

      tearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      test(
        'ADD COLUMN migration adds visibility/authorName to ascents, and '
        'the alterTable rebuild of likes/comments adds a nullable ascentId '
        'while preserving every pre-existing row (wallId intact, ascentId '
        'null) — post-migration inserts can attach a like/comment to an '
        'ascent instead of a wall',
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
            visibility TEXT NOT NULL DEFAULT 'private',
            latitude REAL NULL,
            longitude REAL NULL
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
            crop_width_pct REAL NULL,
            sort_order INTEGER NOT NULL DEFAULT 0,
            is_primary INTEGER NOT NULL DEFAULT 0
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
            visible INTEGER NOT NULL DEFAULT 1,
            beta_video_url TEXT NULL,
            style_tags_json TEXT NULL,
            stars INTEGER NULL
          );

          CREATE UNIQUE INDEX idx_routes_photo_number_live
            ON routes (photo_id, number) WHERE deleted_at IS NULL;

          CREATE TABLE comments (
            id TEXT NOT NULL PRIMARY KEY,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            deleted_at INTEGER NULL,
            remote_id TEXT NULL,
            dirty INTEGER NOT NULL DEFAULT 0,
            owner_id TEXT NULL,
            wall_id TEXT NOT NULL REFERENCES walls (id),
            body TEXT NOT NULL,
            author_name TEXT NULL
          );

          CREATE TABLE likes (
            id TEXT NOT NULL PRIMARY KEY,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            deleted_at INTEGER NULL,
            remote_id TEXT NULL,
            dirty INTEGER NOT NULL DEFAULT 0,
            owner_id TEXT NULL,
            wall_id TEXT NOT NULL REFERENCES walls (id)
          );

          CREATE TABLE ascents (
            id TEXT NOT NULL PRIMARY KEY,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            deleted_at INTEGER NULL,
            remote_id TEXT NULL,
            dirty INTEGER NOT NULL DEFAULT 0,
            owner_id TEXT NULL,
            route_id TEXT NOT NULL REFERENCES routes (id),
            wall_id TEXT NOT NULL REFERENCES walls (id),
            climbed_at INTEGER NOT NULL,
            style TEXT NOT NULL,
            notes TEXT NULL,
            grade_opinion TEXT NULL
          );

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

          INSERT INTO ascents
            (id, created_at, updated_at, route_id, wall_id, climbed_at, style)
            VALUES
            ('ascent-1', 1000, 1000, 'route-1', 'wall-1', 1000, 'redpoint');

          INSERT INTO likes
            (id, created_at, updated_at, wall_id)
            VALUES
            ('like-1', 1000, 1000, 'wall-1');

          INSERT INTO comments
            (id, created_at, updated_at, wall_id, body)
            VALUES
            ('comment-1', 1000, 1000, 'wall-1', 'Nice line!');

          PRAGMA user_version = 6;
        ''');
          raw.close();

          // Open the SAME file with the current AppDatabase (schemaVersion
          // 7). Drift reads the on-disk user_version (6), sees it doesn't
          // match the target (7), and runs onUpgrade(m, 6, 7) — exercising
          // only the `if (from < 7)` branch (the earlier branches are
          // no-ops here since 6 is not < 2/3/4/5/6).
          final db = AppDatabase(NativeDatabase(dbFile));
          addTearDown(db.close);

          // Pre-existing Likes row survives with wallId intact, ascentId
          // null (the alterTable rebuild's copy-INSERT only copies columns
          // present in the old table, by name).
          final like = await (db.select(
            db.likes,
          )..where((t) => t.id.equals('like-1'))).getSingle();
          expect(
            like.wallId,
            'wall-1',
            reason:
                'the alterTable rebuild must preserve every pre-existing '
                "like's wallId",
          );
          expect(like.ascentId, isNull);

          // Pre-existing Comments row survives with wallId intact, ascentId
          // null.
          final comment = await (db.select(
            db.comments,
          )..where((t) => t.id.equals('comment-1'))).getSingle();
          expect(
            comment.wallId,
            'wall-1',
            reason:
                'the alterTable rebuild must preserve every pre-existing '
                "comment's wallId",
          );
          expect(comment.ascentId, isNull);
          expect(comment.body, 'Nice line!');

          // Pre-existing Ascents row survives, and the two new ADD COLUMNs
          // land with visibility's default ('private') and authorName
          // null — SQLite's ADD COLUMN ... DEFAULT applies retroactively.
          final ascent = await (db.select(
            db.ascents,
          )..where((t) => t.id.equals('ascent-1'))).getSingle();
          expect(
            ascent.style,
            'redpoint',
            reason: 'pre-existing row must survive the migration',
          );
          expect(
            ascent.visibility,
            'private',
            reason:
                'the new visibility column must ADD COLUMN with its '
                'default for pre-existing rows',
          );
          expect(ascent.authorName, isNull);

          // Post-migration: a new Like AND a new Comment can each attach to
          // an ascent instead of a wall (ascentId set, wallId null) with no
          // constraint violation — proves the nullability relaxation and
          // the new FK are both wired into the generated Companions, not
          // just physically present in SQLite.
          await db
              .into(db.likes)
              .insert(
                LikesCompanion.insert(
                  id: 'like-2',
                  createdAt: 2000,
                  updatedAt: 2000,
                  wallId: const Value(null),
                  ascentId: const Value('ascent-1'),
                ),
              );
          final newLike = await (db.select(
            db.likes,
          )..where((t) => t.id.equals('like-2'))).getSingle();
          expect(newLike.wallId, isNull);
          expect(newLike.ascentId, 'ascent-1');

          await db
              .into(db.comments)
              .insert(
                CommentsCompanion.insert(
                  id: 'comment-2',
                  createdAt: 2000,
                  updatedAt: 2000,
                  body: 'Sent it!',
                  wallId: const Value(null),
                  ascentId: const Value('ascent-1'),
                ),
              );
          final newComment = await (db.select(
            db.comments,
          )..where((t) => t.id.equals('comment-2'))).getSingle();
          expect(newComment.wallId, isNull);
          expect(newComment.ascentId, 'ascent-1');
          expect(newComment.body, 'Sent it!');
        },
      );
    },
  );

  group('P7: v7 -> v8 migration (Profiles table, #18)', () {
    late Directory tempDir;
    late File dbFile;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'masi_migration_test_',
      );
      dbFile = File(p.join(tempDir.path, 'v7.sqlite'));
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'creates the brand-new profiles table and preserves every '
      'pre-existing row on the v7-era tables untouched',
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
            visibility TEXT NOT NULL DEFAULT 'private',
            latitude REAL NULL,
            longitude REAL NULL
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
            crop_width_pct REAL NULL,
            sort_order INTEGER NOT NULL DEFAULT 0,
            is_primary INTEGER NOT NULL DEFAULT 0
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
            visible INTEGER NOT NULL DEFAULT 1,
            beta_video_url TEXT NULL,
            style_tags_json TEXT NULL,
            stars INTEGER NULL
          );

          CREATE UNIQUE INDEX idx_routes_photo_number_live
            ON routes (photo_id, number) WHERE deleted_at IS NULL;

          CREATE TABLE comments (
            id TEXT NOT NULL PRIMARY KEY,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            deleted_at INTEGER NULL,
            remote_id TEXT NULL,
            dirty INTEGER NOT NULL DEFAULT 0,
            owner_id TEXT NULL,
            wall_id TEXT NULL REFERENCES walls (id),
            ascent_id TEXT NULL REFERENCES ascents (id),
            body TEXT NOT NULL,
            author_name TEXT NULL
          );

          CREATE TABLE likes (
            id TEXT NOT NULL PRIMARY KEY,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            deleted_at INTEGER NULL,
            remote_id TEXT NULL,
            dirty INTEGER NOT NULL DEFAULT 0,
            owner_id TEXT NULL,
            wall_id TEXT NULL REFERENCES walls (id),
            ascent_id TEXT NULL REFERENCES ascents (id)
          );

          CREATE TABLE ascents (
            id TEXT NOT NULL PRIMARY KEY,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            deleted_at INTEGER NULL,
            remote_id TEXT NULL,
            dirty INTEGER NOT NULL DEFAULT 0,
            owner_id TEXT NULL,
            route_id TEXT NOT NULL REFERENCES routes (id),
            wall_id TEXT NOT NULL REFERENCES walls (id),
            climbed_at INTEGER NOT NULL,
            style TEXT NOT NULL,
            notes TEXT NULL,
            grade_opinion TEXT NULL,
            visibility TEXT NOT NULL DEFAULT 'private',
            author_name TEXT NULL
          );

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

          PRAGMA user_version = 7;
        ''');
        raw.close();

        // Open the SAME file with the current AppDatabase (schemaVersion
        // 8). Drift reads the on-disk user_version (7), sees it doesn't
        // match the target (8), and runs onUpgrade(m, 7, 8) — exercising
        // only the `if (from < 8)` branch (the earlier branches are
        // no-ops here since 7 is not < 2/3/4/5/6/7).
        final db = AppDatabase(NativeDatabase(dbFile));
        addTearDown(db.close);

        // Pre-existing v7-era row survives untouched.
        final wall = await (db.select(
          db.walls,
        )..where((t) => t.id.equals('wall-1'))).getSingle();
        expect(
          wall.name,
          'Pre-migration Wall',
          reason: 'pre-existing row must survive the migration',
        );

        // profiles must exist and be usable (proves the generated
        // Companion/table is wired, not just physically present in SQLite),
        // starting out with zero rows (a purely new, empty table).
        final profilesBefore = await db.select(db.profiles).get();
        expect(profilesBefore, isEmpty);

        await db
            .into(db.profiles)
            .insert(
              ProfilesCompanion.insert(
                id: 'user-1',
                createdAt: 2000,
                updatedAt: 2000,
                ownerId: const Value('user-1'),
                displayName: const Value('Alex'),
              ),
            );
        final profile = await (db.select(
          db.profiles,
        )..where((t) => t.id.equals('user-1'))).getSingle();
        expect(profile.displayName, 'Alex');
        expect(profile.ownerId, 'user-1');
        expect(profile.dirty, isFalse);
      },
    );
  });

  group('fresh onCreate (schemaVersion 4)', () {
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
          'profiles',
          'app_settings',
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
              wallId: const Value('wall-1'),
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
              wallId: const Value('wall-1'),
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

      await db
          .into(db.profiles)
          .insert(
            ProfilesCompanion.insert(
              id: 'user-1',
              createdAt: now,
              updatedAt: now,
              displayName: const Value('Alex'),
              deletedAt: const Value(6000),
              remoteId: const Value('remote-profile-1'),
              dirty: const Value(true),
              ownerId: const Value('user-1'),
            ),
          );
      final profile = await (db.select(
        db.profiles,
      )..where((t) => t.id.equals('user-1'))).getSingle();
      expect(profile.displayName, 'Alex');
      expect(profile.createdAt, now);
      expect(profile.updatedAt, now);
      expect(profile.deletedAt, 6000);
      expect(profile.remoteId, 'remote-profile-1');
      expect(profile.dirty, isTrue);
      expect(profile.ownerId, 'user-1');
    });
  });

  group('v8 -> v9 migration (local-only app_settings KV table)', () {
    late Directory tempDir;
    late File dbFile;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('masi_v9_migration_');
      dbFile = File(p.join(tempDir.path, 'v8.sqlite'));
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    test(
      'creates app_settings on an existing v8 database without losing rows',
      () async {
        // Build a REAL current-schema file via onCreate, seed a row, then
        // rewind it to the pre-v9 shape on disk (drop the new table, stamp
        // user_version = 8). Reopening then forces drift down the
        // onUpgrade(m, 8, 9) path a real updating device takes.
        final fresh = AppDatabase(NativeDatabase(dbFile));
        await fresh
            .into(fresh.areas)
            .insert(
              AreasCompanion.insert(
                id: 'area-v8',
                createdAt: 100,
                updatedAt: 100,
                name: 'Pre-v9 Area',
              ),
            );
        await fresh.close();

        final raw = sqlite3lib.sqlite3.open(dbFile.path);
        raw.execute('DROP TABLE app_settings; PRAGMA user_version = 8;');
        expect(raw.select('PRAGMA user_version;').first.values.first, 8);
        raw.close();

        final db = AppDatabase(NativeDatabase(dbFile));
        addTearDown(db.close);

        // Forces the migration to actually run (drift is lazy).
        final area = await (db.select(db.areas)
              ..where((t) => t.id.equals('area-v8')))
            .getSingle();
        expect(
          area.name,
          'Pre-v9 Area',
          reason: 'pre-existing row must survive the v8 -> v9 migration',
        );

        final tableNames = await db
            .customSelect(
              "SELECT name FROM sqlite_master WHERE type = 'table' "
              "AND name NOT LIKE 'sqlite_%'",
            )
            .map((row) => row.read<String>('name'))
            .get();
        expect(
          tableNames,
          contains('app_settings'),
          reason: 'the from < 9 branch must createTable(appSettings)',
        );

        // The new table is usable immediately after the migration.
        final store = SettingsStore(db, nowMs: () => 900);
        await store.write(SettingsStore.lastKnownUidKey, 'user-u1');
        expect(await store.read(SettingsStore.lastKnownUidKey), 'user-u1');
      },
    );
  });

  group('v9 -> v10 migration (FK lookup indexes)', () {
    /// Every index the `from < 10` branch is responsible for, as
    /// `index name -> table`.
    const expectedIndexes = <String, String>{
      'idx_sectors_area_live': 'sectors',
      'idx_walls_sector_live': 'walls',
      'idx_photos_wall_live': 'photos',
      'idx_photos_parent_live': 'photos',
      'idx_routes_wall_live': 'routes',
      'idx_comments_wall_live': 'comments',
      'idx_comments_ascent_live': 'comments',
      'idx_likes_wall_live': 'likes',
      'idx_likes_ascent_live': 'likes',
      'idx_ascents_route_live': 'ascents',
      'idx_ascents_wall_live': 'ascents',
    };

    late Directory tempDir;
    late File dbFile;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('masi_v10_migration_');
      dbFile = File(p.join(tempDir.path, 'v9.sqlite'));
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    Future<Set<String>> indexNames(AppDatabase db) async => (await db
            .customSelect("SELECT name FROM sqlite_master WHERE type = 'index'")
            .map((row) => row.read<String>('name'))
            .get())
        .toSet();

    test('a fresh install gets every FK index straight from onCreate',
        () async {
      final db = AppDatabase(NativeDatabase(dbFile));
      addTearDown(db.close);
      // Forces onCreate to actually run (drift is lazy).
      await db.customSelect('SELECT 1').get();

      expect(
        await indexNames(db),
        containsAll(expectedIndexes.keys),
        reason: 'the @TableIndex.sql annotations in tables.dart are what '
            'createAll() emits — if a fresh install and an upgraded install '
            'disagree about the index set, the migration branch and the '
            'annotations have drifted apart.',
      );
    });

    test('creates every FK index on an existing v9 database without losing '
        'rows', () async {
      // Build a REAL current-schema file via onCreate, seed a row, then rewind
      // it to the pre-v10 shape on disk (drop the new indexes, stamp
      // user_version = 9). Reopening forces drift down the onUpgrade(m, 9, 10)
      // path a real updating device takes.
      final fresh = AppDatabase(NativeDatabase(dbFile));
      await fresh.into(fresh.areas).insert(
            AreasCompanion.insert(
              id: 'area-v9',
              createdAt: 100,
              updatedAt: 100,
              name: 'Pre-v10 Area',
            ),
          );
      await fresh.close();

      final raw = sqlite3lib.sqlite3.open(dbFile.path);
      for (final name in expectedIndexes.keys) {
        raw.execute('DROP INDEX $name;');
      }
      raw.execute('PRAGMA user_version = 9;');
      expect(raw.select('PRAGMA user_version;').first.values.first, 9);
      expect(
        raw
            .select("SELECT name FROM sqlite_master WHERE type = 'index'")
            .map((r) => r['name'] as String),
        isNot(anyElement(isIn(expectedIndexes.keys))),
        reason: 'the rewind must actually remove them, or this test would '
            'pass without the migration doing anything',
      );
      raw.close();

      final db = AppDatabase(NativeDatabase(dbFile));
      addTearDown(db.close);

      // Forces the migration to actually run (drift is lazy).
      final area = await (db.select(db.areas)
            ..where((t) => t.id.equals('area-v9')))
          .getSingle();
      expect(
        area.name,
        'Pre-v10 Area',
        reason: 'this migration is purely additive — no row may be touched',
      );

      expect(await indexNames(db), containsAll(expectedIndexes.keys));
    });

    test('is re-runnable: a v9 stamp on a database that already has the '
        'indexes does not fail', () async {
      // The `IF NOT EXISTS` guard matters because a downgrade-then-reupgrade,
      // or a partially-applied migration, can leave some indexes already
      // present when the branch runs.
      final fresh = AppDatabase(NativeDatabase(dbFile));
      await fresh.customSelect('SELECT 1').get();
      await fresh.close();

      final raw = sqlite3lib.sqlite3.open(dbFile.path);
      // Indexes deliberately LEFT IN PLACE; only the version is rewound.
      raw.execute('PRAGMA user_version = 9;');
      raw.close();

      final db = AppDatabase(NativeDatabase(dbFile));
      addTearDown(db.close);

      await expectLater(db.customSelect('SELECT 1').get(), completes);
      expect(await indexNames(db), containsAll(expectedIndexes.keys));
    });

    test('SQLite actually PLANS with the new indexes, not just stores them',
        () async {
      // The point of the migration is query plans, so assert on the plan.
      // Without an index, `EXPLAIN QUERY PLAN` for these reads says
      // "SCAN routes"; with it, "SEARCH routes USING INDEX
      // idx_routes_wall_live". A test that only checks sqlite_master would
      // pass for an index the planner never chooses.
      final db = AppDatabase(NativeDatabase(dbFile));
      addTearDown(db.close);

      Future<String> planFor(String sql) async {
        final rows = await db.customSelect('EXPLAIN QUERY PLAN $sql').get();
        return rows.map((r) => r.read<String>('detail')).join(' | ');
      }

      expect(
        await planFor(
          "SELECT * FROM routes WHERE wall_id = 'w' AND deleted_at IS NULL",
        ),
        contains('idx_routes_wall_live'),
      );
      expect(
        await planFor(
          "SELECT * FROM photos WHERE wall_id = 'w' AND deleted_at IS NULL",
        ),
        contains('idx_photos_wall_live'),
      );
      expect(
        await planFor(
          "SELECT * FROM walls WHERE sector_id = 's' AND deleted_at IS NULL",
        ),
        contains('idx_walls_sector_live'),
      );
    });
  });
}
