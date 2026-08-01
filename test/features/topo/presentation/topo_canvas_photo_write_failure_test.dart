// F2 regression lock: `TopoCanvasScreen._attachPhotoAndLoad`'s
// `on PhotoWriteException catch` clause had ZERO test coverage — the clause
// could be deleted outright and the whole suite still passed.
//
// The §1f plan sanctioned that gap on the grounds that "its only state effects
// go through `settleFailedPhotoAttach`, which Task 4's container test already
// asserts". But that test calls `settleFailedPhotoAttach` DIRECTLY; nothing
// asserted that the SCREEN ever calls it. The standing assertion was a bare
// `grep -n 'on PhotoWriteException catch'`, which is not a test: it passes on
// prose and fails on a rename, and it says nothing about behavior.
//
// Consequence if it regressed: on web, the canvas add/replace-photo path would
// silently fall back to the `debugPrint`-only catch-all — the user picks a
// photo, the byte write is refused (quota), and the canvas sits on a spinner
// for an image that will never have a row, with no message. CI would not
// notice.
//
// This drives the REAL screen through the REAL flow (tap the empty state's
// add-photo button -> pick -> decode -> attach -> the byte write throws) and
// asserts all three effects the clause is responsible for. Delete the clause
// and every expectation below fails.
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/topo/application/draw_controller.dart';
import 'package:masi/features/topo/data/photo_files.dart';
import 'package:masi/features/topo/presentation/topo_canvas_screen.dart';

/// A 1x1 PNG — a REAL decodable image, because `_attachPickedPhoto` runs the
/// genuine `decodeImageSize` (`dart:ui`'s `instantiateImageCodec`) before it
/// ever reaches the attach. Driven under `tester.runAsync` for exactly the
/// reason `topos_screen_test.dart` does the same: a real codec decode makes no
/// progress under the fake-async clock.
final Uint8List _tinyPngBytes = Uint8List.fromList(<int>[
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, //
  0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4,
  0x89, 0x00, 0x00, 0x00, 0x0a, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9c, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0d, 0x0a, 0x2d, 0xb4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae,
  0x42, 0x60, 0x82,
]);

/// [PhotoFiles] whose [importPhoto] always fails the way the WEB backend does
/// when the browser refuses the byte write (`photo_files_web.dart`'s L3 fix).
/// Mirrors `topos_screen_test.dart`'s identical class (file-private there).
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

/// Advances the real asynchronous work (Drift's background executor, the image
/// decode) that would otherwise never progress under `testWidgets`' fake-async
/// clock, then pumps to flush the resulting rebuilds. Deliberately WITHOUT a
/// trailing `pumpAndSettle()` so the SnackBar is still on screen when asserted
/// (settling would run its 4s duration and exit animation to completion).
/// Mirrors `topos_screen_test.dart`'s `_drainNoSettle`.
Future<void> _drainNoSettle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 30));
  }
}

void main() {
  testWidgets(
    'F2: when the canvas add-photo flow cannot write the bytes, the screen '
    'reports it in a SnackBar, clears the optimistically-selected path, and '
    'settles the photo switch it opened',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          nowMsProvider.overrideWithValue(() => 1000),
          photoFilesProvider.overrideWithValue(_QuotaFailingPhotoFiles()),
        ],
      );
      addTearDown(container.dispose);

      final crud = container.read(libraryCrudRepositoryProvider);
      final area = await crud.createArea('Area');
      final sector = await crud.createSector(area.id, 'Sector');
      final wall = await crud.createWall(sector.id, 'Wall');

      late Directory tempDir;
      late File pngFile;
      await tester.runAsync(() async {
        tempDir = await Directory.systemTemp.createTemp('topo_canvas_f2');
        pngFile = File('${tempDir.path}/photo.png');
        await pngFile.writeAsBytes(_tinyPngBytes);
      });
      addTearDown(() {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: MasiTheme.light,
            home: TopoCanvasScreen(
              wallId: wall.id,
              photoSourcePicker: (context) async => ImageSource.gallery,
              photoPicker: (source) async => XFile(pngFile.path),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The wall has no photo yet, so the canvas shows its empty state.
      expect(find.byKey(const Key('topo-empty-state-add-photo')), findsOneWidget);
      await tester.tap(find.byKey(const Key('topo-empty-state-add-photo')));
      await _drainNoSettle(tester);

      expect(
        find.textContaining('Out of storage space'),
        findsOneWidget,
        reason: 'the byte write was refused — without the '
            '`on PhotoWriteException` clause this falls through to the '
            'debugPrint-only catch-all and the user is told nothing at all',
      );

      expect(
        container.read(selectedImageProvider),
        isNull,
        reason: '_pickImage optimistically selected the picked path so the '
            'canvas would show a spinner for it; with the write failed there '
            'is no Photos row behind that path and never will be, so the '
            'clause must clear it (via settleFailedPhotoAttach) rather than '
            'strand the canvas on an image it can neither load nor persist',
      );

      expect(
        container.read(drawControllerProvider(wall.id)).isSwitchingPhoto,
        isFalse,
        reason: 'every exit path out of _attachPhotoAndLoad must settle the '
            'switch generation it opened, or DrawState.isSwitchingPhoto stays '
            'stuck true and corrupts the next beginPhotoSwitch',
      );

      expect(
        tester.takeException(),
        isNull,
        reason: 'a refused byte write is a handled outcome, never an '
            'unhandled async error',
      );
    },
  );
}
