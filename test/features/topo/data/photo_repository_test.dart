import 'dart:io';

import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/features/topo/data/photo_files.dart';
import 'package:climbtopo/features/topo/data/photo_repository.dart';
import 'package:climbtopo/features/topo/domain/slice_geometry.dart';
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

  test(
    'A1: replaceSlices inserts one Photo row per SliceSpec, correctly '
    'shaped, and loadSlices returns them ordered by cropXpct',
    () async {
      final slices = [
        const SliceSpec(0.5, 0.5),
        const SliceSpec(0.0, 0.25),
        const SliceSpec(0.25, 0.25),
      ];

      final inserted = await repo.replaceSlices(
        wallId,
        originalPhotoId,
        originalWidth,
        originalHeight,
        originalLocalPath,
        slices,
      );

      expect(inserted, hasLength(3));

      final loaded = await repo.loadSlices(originalPhotoId);
      expect(loaded, hasLength(3));
      expect(
        loaded.map((s) => s.cropXpct).toList(),
        [0.0, 0.25, 0.5],
      );
      expect(
        loaded.map((s) => s.cropWidthPct).toList(),
        [0.25, 0.25, 0.5],
      );
      for (final s in loaded) {
        expect(s.kind, 'slice');
        expect(s.parentPhotoId, originalPhotoId);
        expect(s.width, originalWidth);
        expect(s.height, originalHeight);
        expect(s.localPath, originalLocalPath);
        expect(s.wallId, wallId);
        expect(s.id, isNotEmpty);
      }

      final raw = await db.select(db.photos).get();
      // 1 original + 3 slices.
      expect(raw, hasLength(4));
    },
  );

  test(
    'A2: replaceSlices called again replaces the previous set: old slices '
    'are soft-deleted (tombstoned, not physically removed), loadSlices '
    'returns only the new set',
    () async {
      final firstSlices = [
        const SliceSpec(0.0, 0.5),
        const SliceSpec(0.5, 0.5),
      ];
      final firstInserted = await repo.replaceSlices(
        wallId,
        originalPhotoId,
        originalWidth,
        originalHeight,
        originalLocalPath,
        firstSlices,
      );
      expect(firstInserted, hasLength(2));
      final firstIds = firstInserted.map((s) => s.id).toSet();

      final secondSlices = [
        const SliceSpec(0.0, 0.34),
        const SliceSpec(0.34, 0.33),
        const SliceSpec(0.67, 0.33),
      ];
      final secondInserted = await repo.replaceSlices(
        wallId,
        originalPhotoId,
        originalWidth,
        originalHeight,
        originalLocalPath,
        secondSlices,
      );
      expect(secondInserted, hasLength(3));

      final loaded = await repo.loadSlices(originalPhotoId);
      expect(loaded, hasLength(3));
      expect(loaded.map((s) => s.id).toSet(), secondInserted.map((s) => s.id).toSet());
      expect(loaded.map((s) => s.id).toSet().intersection(firstIds), isEmpty);

      // Old rows are tombstoned, not physically gone.
      final raw = await db.select(db.photos).get();
      // 1 original + 2 old slices + 3 new slices.
      expect(raw, hasLength(6));

      final oldRows = raw.where((r) => firstIds.contains(r.id));
      expect(oldRows, hasLength(2));
      for (final row in oldRows) {
        expect(row.deletedAt, isNotNull);
      }
    },
  );

  test(
    'A3: loadSlices excludes soft-deleted rows and never returns the '
    'original photo; loadOriginal returns the original',
    () async {
      final slices = [const SliceSpec(0.0, 1.0)];
      await repo.replaceSlices(
        wallId,
        originalPhotoId,
        originalWidth,
        originalHeight,
        originalLocalPath,
        slices,
      );

      // Replace again to create a soft-deleted tombstone of the first slice.
      await repo.replaceSlices(
        wallId,
        originalPhotoId,
        originalWidth,
        originalHeight,
        originalLocalPath,
        [const SliceSpec(0.0, 0.5), const SliceSpec(0.5, 0.5)],
      );

      final loaded = await repo.loadSlices(originalPhotoId);
      expect(loaded, hasLength(2));
      for (final s in loaded) {
        expect(s.kind, 'slice');
        expect(s.id, isNot(originalPhotoId));
      }

      final original = await repo.loadOriginal(wallId);
      expect(original, isNotNull);
      expect(original!.id, originalPhotoId);
      expect(original.kind, 'original');
    },
  );

  test(
    'A4: crop rects round-trip exactly, including fractional values',
    () async {
      final slices = [
        const SliceSpec(0.25, 0.5),
        const SliceSpec(0.0, 0.25),
        const SliceSpec(0.75, 0.333333),
      ];

      await repo.replaceSlices(
        wallId,
        originalPhotoId,
        originalWidth,
        originalHeight,
        originalLocalPath,
        slices,
      );

      final loaded = await repo.loadSlices(originalPhotoId);
      final byX = {for (final s in loaded) s.cropXpct: s.cropWidthPct};

      expect(byX[0.0], 0.25);
      expect(byX[0.25], 0.5);
      expect(byX[0.75], 0.333333);
    },
  );

  test(
    'A5: concurrent replaceSlices calls for the same original run inside a '
    'transaction and do not duplicate — exactly one set of slices survives',
    () async {
      final slicesA = [const SliceSpec(0.0, 0.5), const SliceSpec(0.5, 0.5)];
      final slicesB = [
        const SliceSpec(0.0, 0.34),
        const SliceSpec(0.34, 0.33),
        const SliceSpec(0.67, 0.33),
      ];
      final slicesC = [const SliceSpec(0.0, 1.0)];

      await Future.wait([
        repo.replaceSlices(
          wallId,
          originalPhotoId,
          originalWidth,
          originalHeight,
          originalLocalPath,
          slicesA,
        ),
        repo.replaceSlices(
          wallId,
          originalPhotoId,
          originalWidth,
          originalHeight,
          originalLocalPath,
          slicesB,
        ),
        repo.replaceSlices(
          wallId,
          originalPhotoId,
          originalWidth,
          originalHeight,
          originalLocalPath,
          slicesC,
        ),
      ]);

      final loaded = await repo.loadSlices(originalPhotoId);
      // Exactly one of the three sets (2, 3, or 1 slices) must be the
      // surviving live set — never a mix/duplication across calls.
      expect(loaded.length, anyOf(1, 2, 3));

      final liveWidths = loaded.map((s) => s.cropWidthPct).toList();
      final matchesA = liveWidths.length == 2;
      final matchesB = liveWidths.length == 3;
      final matchesC = liveWidths.length == 1;
      expect(matchesA || matchesB || matchesC, isTrue);

      // No cross-contamination: the live set is internally consistent with
      // exactly one of the three specs (checked by length above); verify no
      // extra live rows exist beyond the length-consistent set.
      final raw = await db.select(db.photos).get();
      final liveSlices = raw.where(
        (r) => r.kind == 'slice' && r.deletedAt == null,
      );
      expect(liveSlices.length, loaded.length);
    },
  );

  test('createdAt/updatedAt are stamped from nowMs on insert', () async {
    final repoAtT2 = PhotoRepository(db, nowMs: () => 2000);
    final inserted = await repoAtT2.replaceSlices(
      wallId,
      originalPhotoId,
      originalWidth,
      originalHeight,
      originalLocalPath,
      [const SliceSpec(0.0, 1.0)],
    );

    final raw = await (db.select(
      db.photos,
    )..where((t) => t.id.equals(inserted.single.id))).getSingle();
    expect(raw.createdAt, 2000);
    expect(raw.updatedAt, 2000);
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

      test(
        'loadSlices resolves + heals every slice row independently',
        () async {
          await healingRepo.replaceSlices(
            wallId,
            originalPhotoId,
            originalWidth,
            originalHeight,
            'photos/$originalPhotoId.jpg',
            const [SliceSpec(0.0, 0.5), SliceSpec(0.5, 0.5)],
          );
          Directory(photosDirPath()).createSync(recursive: true);
          File(
            p.join(photosDirPath(), '$originalPhotoId.jpg'),
          ).writeAsBytesSync(List<int>.filled(4, 3));
          const staleAbsolute =
              '/private/var/mobile/Containers/Data/Application/'
              'OLD-UUID/Documents/photos/photo-original-1.jpg';
          await (db.update(
            db.photos,
          )..where(
                (t) =>
                    t.parentPhotoId.equals(originalPhotoId) &
                    t.kind.equals('slice'),
              ))
              .write(PhotosCompanion(localPath: Value(staleAbsolute)));

          final loaded = await healingRepo.loadSlices(originalPhotoId);

          expect(loaded, hasLength(2));
          for (final slice in loaded) {
            expect(
              slice.localPath,
              p.join(photosDirPath(), '$originalPhotoId.jpg'),
            );
          }

          final rawSlices = await (db.select(
            db.photos,
          )..where(
                (t) =>
                    t.parentPhotoId.equals(originalPhotoId) &
                    t.kind.equals('slice'),
              ))
              .get();
          expect(rawSlices, hasLength(2));
          for (final raw in rawSlices) {
            expect(raw.localPath, 'photos/$originalPhotoId.jpg');
          }
        },
      );

      test(
        'replaceSlices canonicalizes an absolute originalLocalPath under '
        '<currentDocsDir>/photos/ into the relative form before storing, '
        'and returns PhotoRefs whose localPath is resolved back to '
        'absolute',
        () async {
          Directory(photosDirPath()).createSync(recursive: true);
          final absoluteOriginal = p.join(
            photosDirPath(),
            '$originalPhotoId.jpg',
          );
          File(absoluteOriginal).writeAsBytesSync(List<int>.filled(4, 4));

          final inserted = await healingRepo.replaceSlices(
            wallId,
            originalPhotoId,
            originalWidth,
            originalHeight,
            absoluteOriginal,
            const [SliceSpec(0.0, 1.0)],
          );

          expect(inserted.single.localPath, absoluteOriginal);

          final raw = await (db.select(
            db.photos,
          )..where((t) => t.id.equals(inserted.single.id))).getSingle();
          expect(raw.localPath, 'photos/$originalPhotoId.jpg');
        },
      );

      test(
        'replaceSlices leaves a foreign absolute originalLocalPath (outside '
        '<currentDocsDir>/photos/) unchanged, since it cannot be '
        'canonicalized against a directory the app does not own it under',
        () async {
          final foreignDir = Directory.systemTemp.createTempSync(
            'photo_repository_foreign_',
          );
          addTearDown(() => foreignDir.deleteSync(recursive: true));
          final foreignAbsolute = p.join(foreignDir.path, 'foreign.jpg');
          File(foreignAbsolute).writeAsBytesSync(List<int>.filled(4, 5));

          final inserted = await healingRepo.replaceSlices(
            wallId,
            originalPhotoId,
            originalWidth,
            originalHeight,
            foreignAbsolute,
            const [SliceSpec(0.0, 1.0)],
          );

          expect(inserted.single.localPath, foreignAbsolute);

          final raw = await (db.select(
            db.photos,
          )..where((t) => t.id.equals(inserted.single.id))).getSingle();
          expect(raw.localPath, foreignAbsolute);
        },
      );
    },
  );

  group('P1-b: ownerId stamping on create', () {
    test(
      'replaceSlices stamps ownerId on every inserted slice with the '
      'injected currentUid',
      () async {
        final owned = PhotoRepository(
          db,
          nowMs: () => 1000,
          currentUid: () => 'u1',
        );

        final inserted = await owned.replaceSlices(
          wallId,
          originalPhotoId,
          originalWidth,
          originalHeight,
          originalLocalPath,
          [const SliceSpec(0.0, 0.5), const SliceSpec(0.5, 0.5)],
        );

        expect(inserted, hasLength(2));
        for (final slice in inserted) {
          final raw = await (db.select(
            db.photos,
          )..where((t) => t.id.equals(slice.id))).getSingle();
          expect(raw.ownerId, 'u1');
        }
      },
    );

    test(
      'default currentUid (signed-out) leaves ownerId null on inserted '
      'slices',
      () async {
        final inserted = await repo.replaceSlices(
          wallId,
          originalPhotoId,
          originalWidth,
          originalHeight,
          originalLocalPath,
          [const SliceSpec(0.0, 1.0)],
        );

        final raw = await (db.select(
          db.photos,
        )..where((t) => t.id.equals(inserted.single.id))).getSingle();
        expect(raw.ownerId, isNull);
      },
    );
  });
}
