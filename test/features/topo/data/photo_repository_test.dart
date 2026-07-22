import 'dart:io';

import 'package:masi/core/db/app_database.dart';
import 'package:masi/features/topo/data/photo_files.dart';
import 'package:masi/features/topo/data/photo_repository.dart';
import 'package:masi/features/topo/data/route_repository.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
import 'package:drift/drift.dart' show BooleanExpressionOperators, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late AppDatabase db;
  late PhotoRepository repo;
  const wallId = 'wall-1';
  const originalPhotoId = 'photo-original-1';
  const originalLocalPath = '/tmp/original.jpg';
  const originalWidth = 1000;
  const originalHeight = 2000;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    repo = PhotoRepository(db, nowMs: () => 1000);

    const now = 1000;
    await db
        .into(db.areas)
        .insert(
          AreasCompanion.insert(
            id: 'area-1',
            createdAt: now,
            updatedAt: now,
            name: 'Test Area',
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
            name: 'Test Sector',
            sortOrder: 0,
          ),
        );
    await db
        .into(db.walls)
        .insert(
          WallsCompanion.insert(
            id: wallId,
            createdAt: now,
            updatedAt: now,
            sectorId: 'sector-1',
            name: 'Test Wall',
            sortOrder: 0,
          ),
        );
    await db
        .into(db.photos)
        .insert(
          PhotosCompanion.insert(
            id: originalPhotoId,
            createdAt: now,
            updatedAt: now,
            wallId: wallId,
            localPath: originalLocalPath,
            kind: 'original',
            width: originalWidth,
            height: originalHeight,
          ),
        );
  });

  tearDown(() async {
    await db.close();
  });

  group(
    'S2: relative-path resolution + self-heal (container-rotation fix)',
    () {
      late Directory docsDir;
      late PhotoFiles photoFiles;
      late PhotoRepository healingRepo;

      String photosDirPath() => p.join(docsDir.path, 'photos');

      setUp(() async {
        docsDir = Directory.systemTemp.createTempSync(
          'photo_repository_docs_',
        );
        photoFiles = PhotoFiles(docsDir: () async => docsDir);
        // resolvePhotoPath drives resolution off PhotoFiles' memoized docs
        // path (it deliberately never awaits path_provider on its hot path,
        // so it can't hang a widget pump); warm that cache up front so these
        // await-driven unit tests see deterministic resolution/heal.
        await photoFiles.warmDocsPath();
        healingRepo = PhotoRepository(
          db,
          nowMs: () => 1000,
          photoFiles: photoFiles,
        );
      });

      tearDown(() {
        if (docsDir.existsSync()) docsDir.deleteSync(recursive: true);
      });

      Future<void> setOriginalLocalPath(String localPath) {
        return (db.update(
          db.photos,
        )..where((t) => t.id.equals(originalPhotoId))).write(
          PhotosCompanion(localPath: Value(localPath)),
        );
      }

      test(
        'loadOriginal resolves an already-relative stored localPath to an '
        'absolute path under the CURRENT docs dir, and does not rewrite the '
        'DB row (nothing to heal)',
        () async {
          await setOriginalLocalPath('photos/$originalPhotoId.jpg');

          final loaded = await healingRepo.loadOriginal(wallId);

          expect(
            loaded!.localPath,
            p.join(docsDir.path, 'photos/$originalPhotoId.jpg'),
          );

          final raw = await (db.select(
            db.photos,
          )..where((t) => t.id.equals(originalPhotoId))).getSingle();
          expect(raw.localPath, 'photos/$originalPhotoId.jpg');
        },
      );

      test(
        'loadOriginal self-heals a STALE absolute localPath (simulating a '
        'container-UUID rotation) whose file has moved to the current docs '
        'dir under the same basename: returns the new absolute path AND '
        'rewrites the DB row to the relative form, WITHOUT touching '
        'updatedAt/dirty',
        () async {
          Directory(photosDirPath()).createSync(recursive: true);
          File(
            p.join(photosDirPath(), '$originalPhotoId.jpg'),
          ).writeAsBytesSync(List<int>.filled(4, 1));
          const staleAbsolute =
              '/private/var/mobile/Containers/Data/Application/'
              'OLD-UUID/Documents/photos/photo-original-1.jpg';
          await setOriginalLocalPath(staleAbsolute);
          final before = await (db.select(
            db.photos,
          )..where((t) => t.id.equals(originalPhotoId))).getSingle();

          final loaded = await healingRepo.loadOriginal(wallId);

          expect(
            loaded!.localPath,
            p.join(photosDirPath(), '$originalPhotoId.jpg'),
          );

          final after = await (db.select(
            db.photos,
          )..where((t) => t.id.equals(originalPhotoId))).getSingle();
          expect(after.localPath, 'photos/$originalPhotoId.jpg');
          expect(
            after.updatedAt,
            before.updatedAt,
            reason: 'the self-heal must touch ONLY localPath, not updatedAt '
                '(it is a local-only heal, not a semantic edit that should '
                'trigger re-sync)',
          );
          expect(after.dirty, isFalse);
        },
      );

      test(
        'loadOriginal does NOT heal a stale absolute localPath whose '
        're-derived candidate does not exist either (the photo is '
        'genuinely missing, not just moved) — still returns a best-effort '
        'absolute path so the existing "missing photo" UI degrades '
        'gracefully',
        () async {
          const staleAbsolute =
              '/private/var/mobile/Containers/Data/Application/'
              'OLD-UUID/Documents/photos/photo-original-1.jpg';
          await setOriginalLocalPath(staleAbsolute);

          final loaded = await healingRepo.loadOriginal(wallId);

          expect(
            loaded!.localPath,
            p.join(photosDirPath(), '$originalPhotoId.jpg'),
          );

          final raw = await (db.select(
            db.photos,
          )..where((t) => t.id.equals(originalPhotoId))).getSingle();
          expect(
            raw.localPath,
            staleAbsolute,
            reason: 'must not heal to a relative path pointing at a file '
                'that was never confirmed to exist',
          );
        },
      );

      test(
        'loadOriginal treats a legacy absolute path whose file still '
        'exists AT THAT EXACT PATH as valid, unchanged — no heal needed',
        () async {
          final legacyAbsolute = p.join(docsDir.path, 'legacy-original.jpg');
          File(legacyAbsolute).writeAsBytesSync(List<int>.filled(4, 2));
          await setOriginalLocalPath(legacyAbsolute);

          final loaded = await healingRepo.loadOriginal(wallId);

          expect(loaded!.localPath, legacyAbsolute);

          final raw = await (db.select(
            db.photos,
          )..where((t) => t.id.equals(originalPhotoId))).getSingle();
          expect(raw.localPath, legacyAbsolute);
        },
      );
    },
  );

  group('multi-photo-per-topo: originals (#46 fix + P1-P6)', () {
    Future<String> insertOriginal(
      String id, {
      int createdAt = 1000,
      bool isPrimary = false,
      int sortOrder = 0,
    }) async {
      await db
          .into(db.photos)
          .insert(
            PhotosCompanion.insert(
              id: id,
              createdAt: createdAt,
              updatedAt: createdAt,
              wallId: wallId,
              localPath: '/tmp/$id.jpg',
              kind: 'original',
              width: 100,
              height: 200,
              sortOrder: Value(sortOrder),
              isPrimary: Value(isPrimary),
            ),
          );
      return id;
    }

    test(
      '#46 regression: loadOriginal does NOT throw with 2+ live originals '
      'on the same wall, and returns the one flagged isPrimary',
      () async {
        // originalPhotoId (from setUp) is NOT primary; a second and third
        // original are attached, one of them flagged primary — reproducing
        // the exact accumulated-multi-original shape the #46 bug produced.
        await insertOriginal('photo-2', createdAt: 2000);
        await insertOriginal('photo-3', createdAt: 3000, isPrimary: true);

        final loaded = await repo.loadOriginal(wallId);

        expect(loaded, isNotNull);
        expect(loaded!.id, 'photo-3');
        expect(loaded.isPrimary, isTrue);
      },
    );

    test(
      'loadOriginal falls back to the newest (createdAt DESC) when NO '
      'original is flagged primary',
      () async {
        await insertOriginal('photo-2', createdAt: 2000);
        await insertOriginal('photo-3', createdAt: 3000);

        final loaded = await repo.loadOriginal(wallId);

        expect(loaded!.id, 'photo-3');
      },
    );

    test(
      'loadOriginals returns every live original ordered by sortOrder '
      'ascending, then createdAt ascending',
      () async {
        // originalPhotoId already exists (sortOrder 0, createdAt 1000).
        await insertOriginal('photo-2', createdAt: 2000, sortOrder: 2);
        await insertOriginal('photo-3', createdAt: 1500, sortOrder: 1);

        final loaded = await repo.loadOriginals(wallId);

        expect(
          loaded.map((p) => p.id).toList(),
          [originalPhotoId, 'photo-3', 'photo-2'],
        );
      },
    );

    test(
      'watchWallOriginals emits the live set reactively as originals are '
      'attached',
      () async {
        final emissions = <int>[];
        final sub = repo.watchWallOriginals(wallId).listen(
          (list) => emissions.add(list.length),
        );
        addTearDown(sub.cancel);

        await pumpEventQueue();
        await insertOriginal('photo-2', createdAt: 2000);
        await pumpEventQueue();

        expect(emissions, [1, 2]);
      },
    );

    test(
      'setPrimaryPhoto enforces the single-primary invariant: flips the '
      'target on and every other live original on the wall off',
      () async {
        await insertOriginal('photo-2', createdAt: 2000, isPrimary: true);
        await insertOriginal('photo-3', createdAt: 3000);

        await repo.setPrimaryPhoto(wallId, 'photo-3');

        final rows = await (db.select(
          db.photos,
        )..where((t) => t.wallId.equals(wallId) & t.kind.equals('original')))
            .get();
        final byId = {for (final r in rows) r.id: r.isPrimary};
        expect(byId[originalPhotoId], isFalse);
        expect(byId['photo-2'], isFalse);
        expect(byId['photo-3'], isTrue);
      },
    );

    test(
      'deleteOriginalPhoto soft-deletes the photo AND cascades to its '
      'routes and child photo rows, returning the canonical + child stored '
      'paths for the caller to purge (E-A1)',
      () async {
        final route = RouteRepository(db, nowMs: () => 1000);
        await route.upsertRoute(
          wallId,
          originalPhotoId,
          TopoRoute(id: 1, number: 1, points: const [Offset(0, 0)]),
        );
        // A child `Photos` row (parentPhotoId set) — deleteOriginalPhoto's
        // cascade covers any child photo, regardless of what created it. A
        // DISTINCT localPath from the parent's so the returned stored-paths
        // list can be asserted precisely below.
        const childLocalPath = '/tmp/child.jpg';
        await db
            .into(db.photos)
            .insert(
              PhotosCompanion.insert(
                id: 'photo-child-1',
                createdAt: 1000,
                updatedAt: 1000,
                wallId: wallId,
                localPath: childLocalPath,
                kind: 'original',
                width: originalWidth,
                height: originalHeight,
                parentPhotoId: const Value(originalPhotoId),
              ),
            );

        final storedPaths = await repo.deleteOriginalPhoto(originalPhotoId);

        expect(
          storedPaths,
          unorderedEquals(<String>[originalLocalPath, childLocalPath]),
          reason: 'the caller purges bytes for the canonical photo AND '
              'every cascaded child photo (E-A1)',
        );

        final photoRow = await (db.select(
          db.photos,
        )..where((t) => t.id.equals(originalPhotoId))).getSingle();
        expect(photoRow.deletedAt, isNotNull);

        final routeRows = await (db.select(
          db.routes,
        )..where((t) => t.photoId.equals(originalPhotoId))).get();
        expect(routeRows, hasLength(1));
        expect(routeRows.single.deletedAt, isNotNull);

        final childRows = await (db.select(
          db.photos,
        )..where((t) => t.parentPhotoId.equals(originalPhotoId))).get();
        expect(childRows, hasLength(1));
        expect(childRows.single.deletedAt, isNotNull);
      },
    );

    test(
      'deleteOriginalPhoto returns an empty list (and is a no-op) when '
      'photoId does not resolve to a live photo',
      () async {
        final storedPaths = await repo.deleteOriginalPhoto('no-such-photo');

        expect(storedPaths, isEmpty);
      },
    );

    test(
      'deleteOriginalPhoto promotes the newest remaining original to '
      'primary when the deleted photo was primary',
      () async {
        await (db.update(
          db.photos,
        )..where((t) => t.id.equals(originalPhotoId))).write(
          const PhotosCompanion(isPrimary: Value(true)),
        );
        await insertOriginal('photo-2', createdAt: 2000);
        await insertOriginal('photo-3', createdAt: 3000);

        final storedPaths = await repo.deleteOriginalPhoto(originalPhotoId);
        expect(storedPaths, [originalLocalPath]);

        final remaining = await (db.select(db.photos)
              ..where(
                (t) =>
                    t.wallId.equals(wallId) &
                    t.kind.equals('original') &
                    t.deletedAt.isNull(),
              ))
            .get();
        expect(remaining, hasLength(2));
        final primary = remaining.where((r) => r.isPrimary).toList();
        expect(primary, hasLength(1));
        expect(
          primary.single.id,
          'photo-3',
          reason: 'the newest remaining live original is promoted',
        );
      },
    );

    test(
      'deleteOriginalPhoto is a no-op on the primary-promotion step when '
      'the deleted photo was not primary',
      () async {
        await insertOriginal('photo-2', createdAt: 2000, isPrimary: true);

        final storedPaths = await repo.deleteOriginalPhoto(originalPhotoId);
        expect(storedPaths, [originalLocalPath]);

        final remaining = await (db.select(db.photos)
              ..where(
                (t) =>
                    t.wallId.equals(wallId) &
                    t.kind.equals('original') &
                    t.deletedAt.isNull(),
              ))
            .getSingle();
        expect(remaining.id, 'photo-2');
        expect(remaining.isPrimary, isTrue);
      },
    );

    test('setPhotoOrder writes sortOrder = index for each id given', () async {
      await insertOriginal('photo-2', createdAt: 2000);
      await insertOriginal('photo-3', createdAt: 3000);

      await repo.setPhotoOrder(wallId, ['photo-3', originalPhotoId, 'photo-2']);

      final rows = await (db.select(
        db.photos,
      )..where((t) => t.wallId.equals(wallId))).get();
      final byId = {for (final r in rows) r.id: r.sortOrder};
      expect(byId['photo-3'], 0);
      expect(byId[originalPhotoId], 1);
      expect(byId['photo-2'], 2);
    });
  });
}
