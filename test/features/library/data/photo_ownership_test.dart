import 'dart:io';

import 'package:climbtopo/app/theme.dart';
import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/features/library/data/library_crud_repository.dart';
import 'package:climbtopo/features/topo/application/draw_controller.dart';
import 'package:climbtopo/features/topo/application/slice_controller.dart';
import 'package:climbtopo/features/topo/data/photo_files.dart';
import 'package:climbtopo/features/topo/data/photo_repository.dart';
import 'package:climbtopo/features/topo/domain/slice_geometry.dart';
import 'package:climbtopo/features/topo/presentation/topo_canvas.dart';
import 'package:climbtopo/features/topo/presentation/topo_canvas_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;

/// S1 (Own the photo files): a picked photo is COPIED into the app-owned
/// `<appDocuments>/photos/<photoId>.<ext>` at attach, and `localPath` stores
/// that app-owned path — closing the latent local-loss bug (picker cache is
/// evictable) and making paths portable for backup. Slices reuse the
/// original's now-app-owned file (no duplicate copy).
///
/// The app-documents directory is injected via [PhotoFiles]'s `docsDir` seam
/// pointed at a `Directory.systemTemp` sandbox, so these tests exercise REAL
/// file I/O without a `path_provider` platform fake.
void main() {
  late AppDatabase db;
  late Directory docsDir;
  late Directory srcDir;
  late PhotoFiles photoFiles;
  late LibraryCrudRepository repo;

  String photosDirPath() => p.join(docsDir.path, 'photos');

  /// Writes a real (non-empty) source file the copy can operate on. The bytes
  /// need not be a decodable image — S1's file plumbing is pure byte copy.
  File writeSource(String name) {
    final f = File(p.join(srcDir.path, name));
    f.writeAsBytesSync(List<int>.filled(16, 7));
    return f;
  }

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    docsDir = Directory.systemTemp.createTempSync('climbtopo_docs_');
    srcDir = Directory.systemTemp.createTempSync('climbtopo_src_');
    photoFiles = PhotoFiles(docsDir: () async => docsDir);
    repo = LibraryCrudRepository(db, nowMs: () => 1000, photoFiles: photoFiles);
  });

  tearDown(() async {
    await db.close();
    if (docsDir.existsSync()) docsDir.deleteSync(recursive: true);
    if (srcDir.existsSync()) srcDir.deleteSync(recursive: true);
  });

  Future<WallRef> seedWall() async {
    final area = await repo.createArea('Area');
    final sector = await repo.createSector(area.id, 'Sector');
    return repo.createWall(sector.id, 'Wall');
  }

  group('PhotoFiles helper', () {
    test(
      'importPhoto copies into <docs>/photos/<id><ext>, returns the '
      'RELATIVE form photos/<id><ext> (never an absolute path), and is '
      'idempotent',
      () async {
        final src = writeSource('picked.jpg');

        final dest = await photoFiles.importPhoto(XFile(src.path), 'abc123');

        expect(dest, 'photos/abc123.jpg');
        final absoluteDest = p.join(photosDirPath(), 'abc123.jpg');
        expect(File(absoluteDest).existsSync(), isTrue);

        // Idempotent: a second import returns the same path and does not
        // create a second file.
        final dest2 = await photoFiles.importPhoto(XFile(src.path), 'abc123');
        expect(dest2, dest);
        expect(Directory(photosDirPath()).listSync(), hasLength(1));
      },
    );

    test(
      'importPhoto with a missing source returns the relative destination '
      'form directly (best-effort) and never creates the photos dir for it',
      () async {
        final missing = p.join(srcDir.path, 'gone.jpg');

        final result = await photoFiles.importPhoto(XFile(missing), 'id1');

        expect(result, 'photos/id1.jpg');
        expect(Directory(photosDirPath()).existsSync(), isFalse);
      },
    );

  });

  group('S1-a: attach owns the file', () {
    test(
      'after attachPhotoToWall the stored localPath is under <docs>/photos '
      'and the file exists',
      () async {
        final wall = await seedWall();
        final src = writeSource('camera-roll.jpg');

        final photoId =
            await repo.attachPhotoToWall(wall.id, XFile(src.path), 640, 480);

        final photo = await PhotoRepository(
          db,
          nowMs: () => 1000,
          photoFiles: photoFiles,
        ).loadOriginal(wall.id);
        expect(photo, isNotNull);
        expect(photo!.id, photoId);
        expect(
          p.isWithin(photosDirPath(), photo.localPath),
          isTrue,
          reason: 'localPath must be under the app-owned photos/ dir, not the '
              'transient picker path (${src.path})',
        );
        expect(photo.localPath, isNot(src.path));
        expect(File(photo.localPath).existsSync(), isTrue);
        // Extension preserved; file named by the row id.
        expect(p.basename(photo.localPath), '$photoId.jpg');
      },
    );

    test(
      'attach with a missing/placeholder source still creates the row, '
      'storing the relative destination form (no path_provider dependency '
      'on the attach side); reading it back via a PhotoRepository with NO '
      'injected PhotoFiles (default, real path_provider) falls back to '
      'returning that relative value unchanged rather than throwing',
      () async {
        final wall = await seedWall();

        final photoId = await repo.attachPhotoToWall(
          wall.id,
          XFile('/tmp/does-not-exist.jpg'),
          1,
          1,
        );

        final photo = await PhotoRepository(db, nowMs: () => 1000)
            .loadOriginal(wall.id);
        expect(photo!.id, photoId);
        expect(photo.localPath, 'photos/$photoId.jpg');
        expect(Directory(photosDirPath()).existsSync(), isFalse);
      },
    );
  });

  group('S1-b: a slice reuses the original on-disk file (no duplicate copy)',
      () {
    test(
      'replaceSlices stores the original app-owned localPath verbatim on each '
      'slice and creates no new file on disk',
      () async {
        final wall = await seedWall();
        final src = writeSource('to-slice.jpg');
        final originalId = await repo.attachPhotoToWall(
          wall.id,
          XFile(src.path),
          1000,
          500,
        );

        final photoRepo = PhotoRepository(
          db,
          nowMs: () => 1000,
          photoFiles: photoFiles,
        );
        final original = await photoRepo.loadOriginal(wall.id);
        final ownedPath = original!.localPath;

        final filesBefore = Directory(photosDirPath()).listSync();
        expect(filesBefore, hasLength(1), reason: 'just the original file');

        final slices = await photoRepo.replaceSlices(
          wall.id,
          originalId,
          1000,
          500,
          ownedPath,
          const [SliceSpec(0.0, 0.5), SliceSpec(0.5, 0.5)],
        );

        expect(slices, hasLength(2));
        for (final slice in slices) {
          expect(
            slice.localPath,
            ownedPath,
            reason: 'a slice must point at the ORIGINAL app-owned file',
          );
        }

        // No second file was written: both slice rows share the original's
        // single on-disk file.
        final filesAfter = Directory(photosDirPath()).listSync();
        expect(filesAfter, hasLength(1));
        expect(File(ownedPath).existsSync(), isTrue);

        // And reload confirms the persisted slice rows carry the same path.
        final reloaded = await photoRepo.loadSlices(originalId);
        expect(reloaded, hasLength(2));
        expect(reloaded.every((s) => s.localPath == ownedPath), isTrue);
      },
    );
  });

  group(
    'S1 regression (confirmed photo-ownership bug): same-session '
    'pick→slice-commit persists the owned path',
    () {
      test(
        'committing a slice right after attaching a photo in the SAME '
        'session stores the slice\'s localPath under app documents, not '
        'the transient picker-cache path selectedImageProvider held at '
        'pick time',
        () async {
          final wall = await seedWall();
          final src = writeSource('same-session.jpg');

          final container = ProviderContainer();
          addTearDown(container.dispose);
          final selectedImage = container.read(
            selectedImageProvider.notifier,
          );

          // 1. Simulate _pickImage: the OS picker hands back its own
          //    transient, evictable cache path, and selectedImageProvider is
          //    set to it directly — exactly as _pickImage does, BEFORE
          //    attach even runs.
          selectedImage.select(src.path);

          // 2. Simulate _attachPhotoAndLoad's attach step: the file is
          //    copied into the app-owned photos/ dir and that owned path is
          //    stored on the new row (attachPhotoToWall only returns the
          //    id — see its doc).
          final photoId = await repo.attachPhotoToWall(
            wall.id,
            XFile(src.path),
            1000,
            500,
          );

          // 3. Simulate _attachPhotoAndLoad's fix: resolveAttachedPhotoPath
          //    re-reads the owned path and swaps selectedImageProvider onto
          //    it. This is the exact production function
          //    topo_canvas_screen.dart now calls — not a reimplementation.
          final ownedPath = await resolveAttachedPhotoPath(
            repo,
            selectedImage,
            photoId,
            src.path,
          );

          expect(
            p.isWithin(photosDirPath(), ownedPath),
            isTrue,
            reason: 'the resolved path must be the app-owned copy, not the '
                'picker path (${src.path})',
          );
          expect(
            container.read(selectedImageProvider),
            ownedPath,
            reason: 'selectedImageProvider must now hold the owned path, '
                'not the stale picker path it started with',
          );

          // 4. Simulate _handleSliceCommit: it reads selectedImageProvider
          //    (whatever it holds RIGHT NOW, post-fix) as originalLocalPath
          //    and commits through the real SliceController/PhotoRepository
          //    — the exact same call topo_canvas_screen.dart makes.
          final photoRepo = PhotoRepository(
            db,
            nowMs: () => 1000,
            photoFiles: photoFiles,
          );
          final sliceNotifier = container.read(
            sliceControllerProvider.notifier,
          );
          sliceNotifier.addCut(0.5);

          final committed = await sliceNotifier.commit(
            photoRepo,
            wallId: wall.id,
            originalPhotoId: photoId,
            originalWidth: 1000,
            originalHeight: 500,
            originalLocalPath: container.read(selectedImageProvider)!,
          );
          expect(committed, isTrue);

          final slices = await photoRepo.loadSlices(photoId);
          expect(slices, hasLength(2));
          for (final slice in slices) {
            expect(
              p.isWithin(photosDirPath(), slice.localPath),
              isTrue,
              reason:
                  'BUG: a slice committed in the same session as the pick '
                  'stored the transient picker path (${src.path}) instead '
                  'of the app-owned copy — slice.localPath='
                  '${slice.localPath}',
            );
            expect(slice.localPath, isNot(src.path));
            expect(slice.localPath, ownedPath);
          }
        },
      );
    },
  );

  group('S1-c: canvas rendering still works in the decode-free harness', () {
    testWidgets(
      'TopoCanvasBody renders TopoCanvas for an app-owned path with an '
      'injected imageSize and throws no exception (no real decode)',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final ownedPath = p.join(photosDirPath(), 'render.jpg');

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: MasiTheme.light,
              home: Scaffold(
                body: Consumer(
                  builder: (context, ref, _) {
                    final drawState = ref.watch(drawControllerProvider);
                    return TopoCanvasBody(
                      imagePath: ownedPath,
                      imageSize: const Size(400, 300),
                      drawState: drawState,
                      transformationController: TransformationController(),
                    );
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(find.byType(TopoCanvas), findsOneWidget);
      },
    );
  });
}
