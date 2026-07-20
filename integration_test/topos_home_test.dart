// Integration test for the new flat "Topos" home screen
// (`lib/features/library/presentation/topos_screen.dart`). Seeds a handful
// of topos directly into the app's real sqlite file (same pattern as
// `canvas_demo_test.dart`'s `_seedDemoTopo`) — some with an attached
// "original" photo (to exercise the thumbnail render path) and at least one
// WITHOUT a photo (to exercise the amethyst-gradient fallback) — then boots
// the app and asserts the seeded rows are present on screen.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/features/library/data/library_crud_repository.dart';
import 'package:climbtopo/main.dart' as app;

/// Renders a small solid-color PNG — enough to be a real, decodable image
/// so `Image.file` in `ToposScreen`'s thumbnail row can actually load it.
/// (A trimmed-down variant of `canvas_demo_test.dart`'s
/// `_generateDemoWallImage`; this test doesn't need the grid/shapes detail,
/// just a valid PNG at a known size.)
Future<Uint8List> _generateTopoThumbnailImage({
  required int width,
  required int height,
  required Color color,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final size = Size(width.toDouble(), height.toDouble());
  canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), Paint()..color = color);
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  return byteData!.buffer.asUint8List();
}

/// Seeds 2-3 topos directly into the app's real sqlite file, deleting any
/// existing file first for a clean slate (mirrors
/// `canvas_demo_test.dart`'s `_seedDemoTopo`). Uses the repository's
/// `createTopo(name)` (which files the wall under the hidden `__default__`
/// Area/Sector, exactly as the real "New topo" flow does) rather than
/// `createArea`/`createSector`/`createWall` directly, since the router now
/// treats every non-deleted wall as a topo regardless of which
/// area/sector it lives under.
///
/// Returns the created wall ids so the test can assert their
/// `topo-item-<id>` rows are present.
Future<List<String>> _seedTopos() async {
  final docsDir = await getApplicationDocumentsDirectory();
  final dbFile = File(p.join(docsDir.path, 'climbtopo.sqlite'));
  if (await dbFile.exists()) {
    await dbFile.delete();
  }

  final seedDb = AppDatabase(NativeDatabase(dbFile));
  try {
    final repo = LibraryCrudRepository(
      seedDb,
      nowMs: () => DateTime.now().millisecondsSinceEpoch,
    );

    final wallIds = <String>[];

    // Topo 1: has an attached original photo -> renders a real thumbnail.
    final wallId1 = await repo.createTopo('Topo Home Demo 1');
    final imagePath1 = p.join(docsDir.path, 'topos_home_demo_1.png');
    final bytes1 = await _generateTopoThumbnailImage(
      width: 400,
      height: 300,
      color: const Color(0xFF2E7D32),
    );
    await File(imagePath1).writeAsBytes(bytes1, flush: true);
    await repo.attachPhotoToWall(wallId1, XFile(imagePath1), 400, 300);
    wallIds.add(wallId1);

    // Topo 2: also has an attached original photo -> a second real
    // thumbnail, distinct color, to prove per-row thumbnails don't bleed
    // into each other.
    final wallId2 = await repo.createTopo('Topo Home Demo 2');
    final imagePath2 = p.join(docsDir.path, 'topos_home_demo_2.png');
    final bytes2 = await _generateTopoThumbnailImage(
      width: 400,
      height: 300,
      color: const Color(0xFF6A1B9A),
    );
    await File(imagePath2).writeAsBytes(bytes2, flush: true);
    await repo.attachPhotoToWall(wallId2, XFile(imagePath2), 400, 300);
    wallIds.add(wallId2);

    // Topo 3: deliberately left WITHOUT a photo -> exercises the
    // amethyst-gradient fallback thumbnail.
    final wallId3 = await repo.createTopo('Topo Home Demo 3 (no photo)');
    wallIds.add(wallId3);

    return wallIds;
  } finally {
    // Close BEFORE app.main() opens its own connection to the same file, so
    // there's no lock/contention window between the seed connection and the
    // app's runtime connection.
    await seedDb.close();
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Topos home: seeded topos (with and without photos) render', (
    tester,
  ) async {
    final wallIds = await _seedTopos();

    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 2));
    // Give any freshly-written thumbnail PNGs' ImageStream decode extra
    // time to resolve before capturing.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    await tester.pumpAndSettle(const Duration(seconds: 2));

    for (final wallId in wallIds) {
      final itemFinder = find.byKey(Key('topo-item-$wallId'));
      expect(
        tester.any(itemFinder),
        isTrue,
        reason: 'Seeded topo item $wallId not found on the Topos home',
      );
    }

    await binding.takeScreenshot('20-topos-home');
  });
}
