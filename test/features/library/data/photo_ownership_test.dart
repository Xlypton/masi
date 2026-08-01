import 'dart:io';

import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/features/library/data/library_crud_repository.dart';
import 'package:masi/features/topo/application/draw_controller.dart';
import 'package:masi/features/topo/data/photo_files.dart';
import 'package:masi/features/topo/data/photo_repository.dart';
import 'package:masi/features/topo/presentation/topo_canvas.dart';
import 'package:masi/features/topo/presentation/topo_canvas_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;

/// FIX #6 (family-keyed `drawControllerProvider`): stand-in wallId, paired
/// consistently everywhere this file constructs `TopoCanvasBody` or reads
/// the provider directly.
const _testWallId = 'test-wall';

/// [PhotoFiles] whose [importPhoto] always fails the way the WEB backend now
/// does when the browser refuses the byte write (see `photo_files_web.dart`'s
/// L3 fix). Every other member is inherited, so the rest of the repository's
/// real path handling still runs.
///
/// `PhotoFiles` is resolved by the ANALYZER to `photo_files_stub.dart` (the
/// unconditional branch of the `photo_files.dart` facade, whose ctor is
/// `PhotoFiles({Object? docsDir, Object? byteStore})`) and by the VM compiler
/// to `photo_files_native.dart`, whose ctor is
/// `PhotoFiles({Future<Directory> Function()? docsDir})`. Both declare
/// `importPhoto(XFile, String) -> Future<String>` identically and both accept
/// a zero-argument `super()`, so this subclass binds under either — see
/// `photo_files_stub.dart`'s own doc for why the variants are kept
/// signature-compatible.
class _QuotaFailingPhotoFiles extends PhotoFiles {
  @override
  Future<String> importPhoto(XFile xfile, String photoId) async {
    throw PhotoWriteException(
      failure: PhotoWriteFailure.quotaExceeded,
      key: 'photos/$photoId.jpg',
      cause: Exception('QuotaExceededError: The quota has been exceeded.'),
    );
  }
}

/// S1 (Own the photo files): a picked photo is COPIED into the app-owned
/// `<appDocuments>/photos/<photoId>.<ext>` at attach, and `localPath` stores
/// that app-owned path — closing the latent local-loss bug (picker cache is
/// evictable) and making paths portable for backup.
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
    docsDir = Directory.systemTemp.createTempSync('masi_docs_');
    srcDir = Directory.systemTemp.createTempSync('masi_src_');
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

  group('L3: a failed byte write creates no Photos row', () {
    test(
      "attachPhotoToWall rethrows PhotoFiles.importPhoto's "
      'PhotoWriteException and leaves the photos table EMPTY — the insert '
      'transaction is never reached, so a pixel-less row can no longer exist',
      () async {
        final wall = await seedWall();
        final failingRepo = LibraryCrudRepository(
          db,
          nowMs: () => 1000,
          photoFiles: _QuotaFailingPhotoFiles(),
        );

        await expectLater(
          failingRepo.attachPhotoToWall(
            wall.id,
            XFile(p.join(srcDir.path, 'picked.jpg')),
            640,
            480,
          ),
          throwsA(
            isA<PhotoWriteException>().having(
              (e) => e.failure,
              'failure',
              PhotoWriteFailure.quotaExceeded,
            ),
          ),
        );

        expect(
          await db.select(db.photos).get(),
          isEmpty,
          reason: 'no Photos row may be created when the pixels were never '
              'written (L3) — attachPhotoToWall awaits importPhoto BEFORE its '
              'insert transaction, which is what makes this hold',
        );
      },
    );

    test(
      'the wall itself is untouched — the caller decides whether to undo it '
      "(topos_screen's New topo flow soft-deletes the wall it just created; "
      'the canvas flow has no wall to undo)',
      () async {
        final wall = await seedWall();
        final failingRepo = LibraryCrudRepository(
          db,
          nowMs: () => 1000,
          photoFiles: _QuotaFailingPhotoFiles(),
        );

        await expectLater(
          failingRepo.attachPhotoToWall(wall.id, XFile('/tmp/x.jpg'), 1, 1),
          throwsA(isA<PhotoWriteException>()),
        );

        final row = await (db.select(db.walls)
              ..where((t) => t.id.equals(wall.id)))
            .getSingle();
        expect(row.deletedAt, isNull);
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

  group(
    'S1 regression (confirmed photo-ownership bug): same-session pick→'
    'resolveAttachedPhotoPath persists the owned path',
    () {
      test(
        'resolving the attached photo path right after picking it in the '
        'SAME session swaps selectedImageProvider onto the app-owned '
        'path, not the transient picker-cache path it held at pick time',
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
                    final drawState = ref.watch(drawControllerProvider(_testWallId));
                    return TopoCanvasBody(
                      wallId: _testWallId,
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
