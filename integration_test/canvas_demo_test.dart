// Reusable evidence-gathering integration test for the topo canvas.
//
// Seeds a full Area -> Sector -> Wall -> (attached original) Photo directly
// into the SAME sqlite file the app opens at runtime
// (`<applicationDocumentsDirectory>/climbtopo.sqlite`, see
// `lib/core/db/database_provider.dart`'s `_openConnection`), using a real,
// decodable PNG written to disk. Because the wall already has an attached
// "original" photo, `TopoCanvasScreen` restores it automatically on open
// (see `loadWallOriginalPhoto`/`_loadInitialPhotoForWall` in
// `topo_canvas_screen.dart`) — no native photo picker is ever involved, so
// this flow is fully driveable by `flutter drive`.
//
// This is evidence-gathering for two reported bugs (the wall image
// rendering too small, and route draw-lines being too thin) plus a general
// bug hunt: it captures screenshots of every meaningful state along the
// Areas -> Sectors -> Walls -> Canvas -> Draw-mode -> Drawn-route path.
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

/// Renders a 1600x1200 PNG with a gradient background, a grid, and a few
/// high-contrast shapes, so any rendered route line has plenty of contrast
/// to be visually assessed against (both for size and for stroke width).
Future<Uint8List> _generateDemoWallImage({
  required int width,
  required int height,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final size = Size(width.toDouble(), height.toDouble());
  final rect = Rect.fromLTWH(0, 0, size.width, size.height);

  final gradient = ui.Gradient.linear(
    rect.topLeft,
    rect.bottomRight,
    const [Color(0xFF1B5E20), Color(0xFFF9A825), Color(0xFFB71C1C)],
    const [0.0, 0.5, 1.0],
  );
  canvas.drawRect(rect, Paint()..shader = gradient);

  final gridPaint = Paint()
    ..color = Colors.white.withValues(alpha: 0.6)
    ..strokeWidth = 3;
  for (var x = 0; x < width; x += 100) {
    canvas.drawLine(
      Offset(x.toDouble(), 0),
      Offset(x.toDouble(), size.height),
      gridPaint,
    );
  }
  for (var y = 0; y < height; y += 100) {
    canvas.drawLine(
      Offset(0, y.toDouble()),
      Offset(size.width, y.toDouble()),
      gridPaint,
    );
  }

  final shapePaint = Paint()..color = Colors.blueAccent;
  canvas.drawCircle(Offset(size.width * 0.3, size.height * 0.3), 150, shapePaint);
  canvas.drawRect(
    Rect.fromCenter(
      center: Offset(size.width * 0.7, size.height * 0.65),
      width: 300,
      height: 220,
    ),
    Paint()..color = Colors.purpleAccent,
  );

  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  return byteData!.buffer.asUint8List();
}

/// Seeds Area -> Sector -> Wall -> attached original Photo directly into the
/// app's real sqlite file, so opening the wall in the running app shows the
/// image with no picker interaction required. Returns the created ids so
/// the test can navigate straight to them by widget key.
Future<({String areaId, String sectorId, String wallId})> _seedDemoTopo(
  String imagePath,
) async {
  final docsDir = await getApplicationDocumentsDirectory();
  final dbFile = File(p.join(docsDir.path, 'climbtopo.sqlite'));
  // Start from a clean slate so re-runs of this test don't accumulate
  // duplicate "Demo Crag" entries across sessions.
  if (await dbFile.exists()) {
    await dbFile.delete();
  }

  final seedDb = AppDatabase(NativeDatabase(dbFile));
  try {
    final repo = LibraryCrudRepository(
      seedDb,
      nowMs: () => DateTime.now().millisecondsSinceEpoch,
    );
    final area = await repo.createArea('Demo Crag');
    final sector = await repo.createSector(area.id, 'Demo Sector');
    final wall = await repo.createWall(sector.id, 'Demo Wall');
    await repo.attachPhotoToWall(wall.id, XFile(imagePath), 1600, 1200);
    return (areaId: area.id, sectorId: sector.id, wallId: wall.id);
  } finally {
    // Close BEFORE app.main() opens its own connection to the same file, so
    // there's no lock/contention window between the seed connection and the
    // app's runtime connection.
    await seedDb.close();
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('canvas demo: seeded topo, image render, drawn route', (
    tester,
  ) async {
    final docsDir = await getApplicationDocumentsDirectory();
    final imagePath = p.join(docsDir.path, 'demo_wall.png');
    final pngBytes = await _generateDemoWallImage(width: 1600, height: 1200);
    await File(imagePath).writeAsBytes(pngBytes, flush: true);

    final ids = await _seedDemoTopo(imagePath);

    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 2));
    // `/` is now the flat Topos home: the seeded wall (which has an
    // attached "original" photo) appears directly as a topo row here, with
    // no Area/Sector drill-down required.
    await binding.takeScreenshot('10-topos-with-demo');

    final topoItem = find.byKey(Key('topo-item-${ids.wallId}'));
    expect(
      tester.any(topoItem),
      isTrue,
      reason: 'Seeded "Demo Wall" topo item not found on the Topos home',
    );
    await tester.tap(topoItem);
    await tester.pumpAndSettle(const Duration(seconds: 1));
    // Give the ImageStream decode of the freshly-written PNG extra time
    // to resolve before judging the canvas's rendered state.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    await tester.pumpAndSettle(const Duration(seconds: 2));
    // KEY screenshot for the "wall image renders too small" bug report.
    await binding.takeScreenshot('13-canvas-with-image');

    // Switch to Draw mode via the AppBar toggle (Icons.edit <-> pan tool).
    final modeToggle = find.byKey(const Key('topo-mode-toggle'));
    if (tester.any(modeToggle)) {
      await tester.tap(modeToggle);
      await tester.pumpAndSettle();
    } else {
      debugPrint('WARNING: topo-mode-toggle not found; cannot enter draw mode.');
    }

    final drawArea = find.byKey(const Key('topo-draw-gesture-detector'));
    if (tester.any(drawArea)) {
      final topLeft = tester.getTopLeft(drawArea);
      final size = tester.getSize(drawArea);
      // A simple zig-zag polyline across the canvas: each tapAt is a
      // separate pointer down+up with no movement, which
      // TopoCanvas._beginInteraction treats as "add a new point" (since it
      // never lands on an existing handle at a different location) — this
      // is exactly how a real user places route vertices one tap at a time.
      final routePoints = [
        Offset(size.width * 0.15, size.height * 0.75),
        Offset(size.width * 0.30, size.height * 0.55),
        Offset(size.width * 0.45, size.height * 0.60),
        Offset(size.width * 0.62, size.height * 0.35),
        Offset(size.width * 0.80, size.height * 0.25),
      ];
      for (final point in routePoints) {
        await tester.tapAt(topLeft + point);
        await tester.pump(const Duration(milliseconds: 200));
      }
      await tester.pumpAndSettle();
      // KEY screenshot for the "route lines are too thin" bug report: the
      // in-progress (uncommitted) route, drawn with its draggable handles.
      await binding.takeScreenshot('14-canvas-drawn-line');

      // Committing opens RouteMetadataSheet automatically
      // (TopoCanvasScreen._handleCommitRoute) — capture it, then close it,
      // then capture the canvas again with the now-COMMITTED (palette
      // colored, handle-less) route for comparison against the in-progress
      // one above.
      final commitButton = find.byKey(const Key('topo-commit-button'));
      if (tester.any(commitButton)) {
        await tester.tap(commitButton);
        await tester.pumpAndSettle();
        final saveButton = find.byKey(const Key('topo-meta-save'));
        if (tester.any(saveButton)) {
          await binding.takeScreenshot('15-route-metadata-sheet');
          await tester.tap(saveButton);
          await tester.pumpAndSettle();
        } else {
          final cancelButton = find.byKey(const Key('topo-meta-cancel'));
          if (tester.any(cancelButton)) {
            await tester.tap(cancelButton);
            await tester.pumpAndSettle();
          }
        }
        await binding.takeScreenshot('16-canvas-committed-route');
        // KEY screenshot for the "editor stays open / covers the route
        // list" bug fix: TopoCanvasScreen._handleCommitRoute now returns
        // to DrawMode.view on a successful commit (see that method's doc),
        // so by this point the bottom undo/redo/cancel/commit cluster
        // (draw-mode-only — see _buildBottomChrome's doc) should be gone
        // and RouteLegend's "Route 1 · ..." row should be fully visible,
        // uncovered.
        await binding.takeScreenshot('18-view-mode-after-commit');
      } else {
        debugPrint('WARNING: topo-commit-button not found; route not committed.');
      }
    } else {
      debugPrint(
        'WARNING: topo-draw-gesture-detector not found; skipping drawing gestures.',
      );
      await binding.takeScreenshot('14-canvas-drawn-line');
    }
  });
}
