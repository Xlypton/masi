// Evidence-gathering integration test for two just-landed UI fixes:
//
//  1. Grade-band route colors now use the canonical DESIGN.md hexes
//     (`presentation/grade_colors.dart`'s `_beginnerColor` #2F9E6B green /
//     `_intermediateColor` #3B82C4 blue / `_advancedColor` #E08A2B orange /
//     `_hardColor` #D6483B red / `_eliteColor` #8A5CD1 purple) on both the
//     canvas route STROKE (`TopoPainter`, via `topoRouteColor` ->
//     `colorForRoute`) and the `RouteLegend` swatch — previously a
//     divergent, brighter Material palette (`kRoutePalette`).
//  2. In draw mode, the bottom undo/redo/close/check toolbar cluster
//     (`TopoCanvasScreen._buildBottomChrome`) no longer overlaps
//     `RouteLegend`: a `MasiSpacing.sm` (see that method's doc) gap is now
//     reserved above it.
//
// This is a sibling to `canvas_demo_test.dart` (same seeding pattern: a
// real, decodable PNG written to disk plus Area -> Sector -> Wall -> Photo
// rows inserted directly into the app's real sqlite file) rather than an
// edit to it, so this run's route seeding (5 routes, one per grade band)
// doesn't change the route count/numbering that `canvas_demo_test.dart`'s
// own screenshots (14-18) already document for the unrelated "thin
// stroke"/"small image" bug reports.
//
// Routes are seeded directly via `RouteRepository.upsertRoute` (bypassing
// `RouteMetadataSheet`'s UI) so every grade band can be demonstrated in one
// screenshot without driving five separate draw+commit+grade-picker cycles
// through the UI.
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

import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/grades/grade_system.dart';
import 'package:masi/features/library/data/library_crud_repository.dart';
import 'package:masi/features/topo/data/route_repository.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
import 'package:masi/main.dart' as app;

/// Renders a 1600x1200 PNG with a plain, muted gradient background (no
/// grid/shapes — unlike `canvas_demo_test.dart`'s busier demo image) so the
/// five grade-band route colors read clearly against it with minimal visual
/// competition.
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
    const [Color(0xFF37474F), Color(0xFF263238)],
    const [0.0, 1.0],
  );
  canvas.drawRect(rect, Paint()..shader = gradient);

  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  return byteData!.buffer.asUint8List();
}

/// One route per [GradeBand] (see `core/grades/grade_system.dart`'s
/// `bandForSortKey` for the exact French-grade cut points this list is
/// derived from):
///
///  - number 1, French `4a`  (sortKey 1.0  <= 3.5)  -> beginner     -> green
///  - number 2, French `6a`  (sortKey 7.0  <= 7.5)  -> intermediate -> blue
///  - number 3, French `6b`  (sortKey 9.0  <= 12.5) -> advanced     -> orange
///  - number 4, French `7b`  (sortKey 15.0 <= 18.5) -> hard         -> red
///  - number 5, French `8a`  (sortKey 19.0 > 18.5)  -> elite        -> purple
const List<(int number, String grade)> _gradedRoutes = [
  (1, '4a'),
  (2, '6a'),
  (3, '6b'),
  (4, '7b'),
  (5, '8a'),
];

/// Seeds Area -> Sector -> Wall -> attached original Photo directly into the
/// app's real sqlite file (same mechanism as `canvas_demo_test.dart`'s
/// `_seedDemoTopo`), then seeds one committed route per grade band directly
/// via `RouteRepository.upsertRoute` so the legend/canvas show all five
/// grade-band colors without needing five separate draw+commit UI cycles.
Future<({String areaId, String sectorId, String wallId})> _seedGradedDemoTopo(
  String imagePath,
) async {
  final docsDir = await getApplicationDocumentsDirectory();
  final dbFile = File(p.join(docsDir.path, 'climbtopo.sqlite'));
  // Start from a clean slate so re-runs of this test don't accumulate
  // duplicate "Graded Demo Crag" entries, and so `canvas_demo_test.dart`'s
  // own seeded rows (if that flow ran previously in this same simulator
  // install) don't leak into this screenshot's route/legend counts.
  if (await dbFile.exists()) {
    await dbFile.delete();
  }

  final seedDb = AppDatabase(NativeDatabase(dbFile));
  try {
    int nowMs() => DateTime.now().millisecondsSinceEpoch;
    final repo = LibraryCrudRepository(seedDb, nowMs: nowMs);
    final area = await repo.createArea('Graded Demo Crag');
    final sector = await repo.createSector(area.id, 'Graded Demo Sector');
    final wall = await repo.createWall(sector.id, 'Graded Demo Wall');
    final photoId = await repo.attachPhotoToWall(wall.id, XFile(imagePath), 1600, 1200);

    final routeRepo = RouteRepository(seedDb, nowMs: nowMs);
    for (final (number, grade) in _gradedRoutes) {
      // Each route is a short diagonal line, horizontally offset by number
      // so all five render as distinct, non-overlapping strokes (and
      // distinct legend rows) instead of stacking on top of each other.
      final xBase = 0.12 + (number - 1) * 0.16;
      final points = [
        Offset(xBase, 0.85),
        Offset(xBase + 0.06, 0.55),
        Offset(xBase + 0.10, 0.15),
      ];
      final sortKey = gradeSortKey(GradeSystem.french, grade);
      await routeRepo.upsertRoute(
        wall.id,
        photoId,
        TopoRoute(
          id: number,
          number: number,
          points: points,
          colorIndex: routeColorIndexFor(number),
          gradeSystem: GradeSystem.french,
          gradeRaw: grade,
          gradeSortKey: sortKey,
        ),
      );
    }

    return (areaId: area.id, sectorId: sector.id, wallId: wall.id);
  } finally {
    // Close BEFORE app.main() opens its own connection to the same file, so
    // there's no lock/contention window between the seed connection and the
    // app's runtime connection (same reasoning as `canvas_demo_test.dart`).
    await seedDb.close();
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('graded routes demo: multi-band legend colors, draw-mode toolbar/legend gap', (
    tester,
  ) async {
    final docsDir = await getApplicationDocumentsDirectory();
    final imagePath = p.join(docsDir.path, 'graded_demo_wall.png');
    final pngBytes = await _generateDemoWallImage(width: 1600, height: 1200);
    await File(imagePath).writeAsBytes(pngBytes, flush: true);

    final ids = await _seedGradedDemoTopo(imagePath);

    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 2));

    final topoItem = find.byKey(Key('topo-item-${ids.wallId}'));
    expect(
      tester.any(topoItem),
      isTrue,
      reason: 'Seeded "Graded Demo Wall" topo item not found on the Topos home',
    );
    await tester.tap(topoItem);
    await tester.pumpAndSettle(const Duration(seconds: 1));
    // Give the ImageStream decode of the freshly-written PNG extra time to
    // resolve before judging the canvas's rendered state (same pacing as
    // `canvas_demo_test.dart`'s `13-canvas-with-image`).
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // KEY screenshot for fix #1 (grade-band colors): view mode, showing all
    // 5 committed routes' strokes on the canvas AND their matching swatches
    // in `RouteLegend`, one per grade band (green/blue/orange/red/purple).
    await binding.takeScreenshot('10-view-graded-routes');

    // Switch to Draw mode via the AppBar toggle (Icons.edit <-> pan tool).
    final modeToggle = find.byKey(const Key('topo-mode-toggle'));
    expect(
      tester.any(modeToggle),
      isTrue,
      reason: 'topo-mode-toggle not found; cannot enter draw mode.',
    );
    await tester.tap(modeToggle);
    await tester.pumpAndSettle();

    final drawArea = find.byKey(const Key('topo-draw-gesture-detector'));
    expect(
      tester.any(drawArea),
      isTrue,
      reason: 'topo-draw-gesture-detector not found; cannot draw a route.',
    );
    final topLeft = tester.getTopLeft(drawArea);
    final size = tester.getSize(drawArea);
    // A short 3-point in-progress polyline (each tapAt is a separate
    // pointer down+up with no movement, exactly the gesture
    // `canvas_demo_test.dart` uses to place route vertices one tap at a
    // time) placed in the upper-right, away from the 5 seeded routes'
    // lower-left diagonals, so it reads as a clearly distinct 6th
    // (uncommitted) route.
    final routePoints = [
      Offset(size.width * 0.78, size.height * 0.70),
      Offset(size.width * 0.85, size.height * 0.45),
      Offset(size.width * 0.90, size.height * 0.20),
    ];
    for (final point in routePoints) {
      await tester.tapAt(topLeft + point);
      await tester.pump(const Duration(milliseconds: 200));
    }
    await tester.pumpAndSettle();

    // KEY screenshot for fix #2 (toolbar/legend gap): draw mode, with the
    // bottom undo/redo/close(discard)/check(commit) toolbar cluster
    // (`topo-undo-button`/`topo-redo-button`/`topo-clear-button`/
    // `topo-commit-button`) and the 5-route `RouteLegend` both on screen at
    // once, with the reserved `MasiSpacing.sm` gap between them (see
    // `TopoCanvasScreen._buildBottomChrome`'s doc) instead of the toolbar
    // overlapping the legend's bottom row(s).
    await binding.takeScreenshot('11-draw-toolbar-and-legend');
  });
}
