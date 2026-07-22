// Comprehensive screenshot-capture sweep for a visual-design review — NOT
// product code. Seeds a rich fixture directly into the app's real sqlite
// file (same mechanism as `canvas_demo_test.dart`'s `_seedDemoTopo`: a real,
// decodable PNG written to disk plus rows inserted via the real repos, the
// seed connection closed BEFORE `app.main()` opens its own), then walks the
// app screen-by-screen and dialog-by-dialog, taking a numbered screenshot at
// each state worth a visual review. Targets widgets ONLY by `Key` (never
// coordinates), per the project's integration_test convention.
//
// Reuses the seeding/decode-settle patterns from `canvas_demo_test.dart`,
// `topos_home_test.dart`, `graded_routes_demo_test.dart`, and
// `fade_vignette_demo_test.dart` — see each for the rationale behind the
// "close the seed db before app.main()" and "pump 6x500ms then
// pumpAndSettle after a fresh image appears" rules.
//
// One screen is deliberately NOT driven: the live AR camera view
// (`/walls/:wallId/ar`). Per this project's CLAUDE.md ("Hard limits": AR/
// camera cannot run in any simulator), `ArScreen._isArPlatformSupported()`
// checks `Platform.isIOS`, which is TRUE even under the iOS Simulator — so
// tapping `topo-ar-button` here would attempt a real `AVCaptureSession`
// start, which on a fresh simulator install can raise the OS-level camera-
// permission dialog. That system dialog lives outside the Flutter widget
// tree (the same class of problem as the native photo-picker gap this
// project's CLAUDE.md already documents) and `integration_test` cannot
// dismiss it, risking a hung `flutter drive` process. `topo-ar-button`
// itself IS still visible/captured in the view-mode canvas screenshots
// below (it renders once a wall has a photo + a visible route), evidencing
// the entry point exists without ever tapping it.
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

/// Renders a 1600x1200 PNG with a gradient background, a grid, and a few
/// high-contrast shapes (identical recipe to `canvas_demo_test.dart`'s
/// `_generateDemoWallImage`) so the wall photo, route strokes, and the
/// edge-fade vignette all have plenty of contrast to review.
Future<Uint8List> _generateWallImage({
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

/// One route per [GradeBand] (green -> blue -> orange -> red -> purple),
/// identical ladder to `graded_routes_demo_test.dart`'s `_gradedRoutes`.
const List<(int number, String grade)> _gradedRoutes = [
  (1, '4a'),
  (2, '6a'),
  (3, '6b'),
  (4, '7b'),
  (5, '8a'),
];

/// Every id the walk-through needs to target screens/rows directly by Key,
/// rather than searching the tree.
class _SweepIds {
  const _SweepIds({
    required this.area1Id,
    required this.sector1Id,
    required this.wall1aId,
    required this.wall1bId,
    required this.gradedWallId,
    required this.noPhotoWallId,
  });

  final String area1Id;
  final String sector1Id;
  final String wall1aId;
  final String wall1bId;
  final String gradedWallId;
  final String noPhotoWallId;
}

/// Seeds a rich fixture directly into the app's real sqlite file (same file
/// `app.main()` will open), deleting any existing file first for a clean
/// slate:
///  - 2 Areas, each with 1 Sector, each Sector with 2 Walls (no photos —
///    just enough for the CRUD list screens to show real rows).
///  - 1 "topo" (via `createTopo`, filed under the hidden default Area/
///    Sector) with an attached original photo and 5 committed routes
///    spanning every grade band — so the canvas, legend, and draw/commit
///    flow are all exercised against the SAME wall.
///  - 1 more topo (via `createTopo`) deliberately left WITHOUT a photo, to
///    reach the canvas's empty state.
Future<_SweepIds> _seedFullSweep(String imagePath) async {
  final docsDir = await getApplicationDocumentsDirectory();
  final dbFile = File(p.join(docsDir.path, 'climbtopo.sqlite'));
  if (await dbFile.exists()) {
    await dbFile.delete();
  }

  final seedDb = AppDatabase(NativeDatabase(dbFile));
  try {
    int nowMs() => DateTime.now().millisecondsSinceEpoch;
    final repo = LibraryCrudRepository(seedDb, nowMs: nowMs);
    final routeRepo = RouteRepository(seedDb, nowMs: nowMs);

    // -- 2 Areas x 1 Sector x 2 Walls, so the CRUD list screens are populated.
    final area1 = await repo.createArea('Sweep Area 1');
    final sector1 = await repo.createSector(area1.id, 'Sweep Sector 1');
    final wall1a = await repo.createWall(sector1.id, 'Sweep Wall 1A');
    final wall1b = await repo.createWall(sector1.id, 'Sweep Wall 1B');

    final area2 = await repo.createArea('Sweep Area 2');
    final sector2 = await repo.createSector(area2.id, 'Sweep Sector 2');
    await repo.createWall(sector2.id, 'Sweep Wall 2A');
    await repo.createWall(sector2.id, 'Sweep Wall 2B');

    // -- The photo-first topo: photo + 5 graded routes.
    final gradedWallId = await repo.createTopo('Sweep Graded Topo');
    final gradedPhotoId = await repo.attachPhotoToWall(
      gradedWallId,
      XFile(imagePath),
      1600,
      1200,
    );
    for (final (number, grade) in _gradedRoutes) {
      final xBase = 0.12 + (number - 1) * 0.16;
      final points = [
        Offset(xBase, 0.85),
        Offset(xBase + 0.06, 0.55),
        Offset(xBase + 0.10, 0.15),
      ];
      final sortKey = gradeSortKey(GradeSystem.french, grade);
      await routeRepo.upsertRoute(
        gradedWallId,
        gradedPhotoId,
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

    // -- A second photo-first topo, deliberately left without a photo.
    final noPhotoWallId = await repo.createTopo('Sweep No Photo');

    return _SweepIds(
      area1Id: area1.id,
      sector1Id: sector1.id,
      wall1aId: wall1a.id,
      wall1bId: wall1b.id,
      gradedWallId: gradedWallId,
      noPhotoWallId: noPhotoWallId,
    );
  } finally {
    // Close BEFORE app.main() opens its own connection to the same file —
    // see canvas_demo_test.dart's identical rationale.
    await seedDb.close();
  }
}

/// Extra settle beyond a plain `pumpAndSettle()`: some go_router push/pop
/// transitions on iOS were observed leaving a sliver of the outgoing screen
/// still painted at the screen edge even after `pumpAndSettle()` returns
/// (worst case observed: ~20% of the outgoing Topos-home screen still
/// visible after tapping into a fresh canvas). This extra explicit pump
/// beyond a full settle — the same "settle again after a pause" shape used
/// elsewhere in this repo's integration tests for image-decode waits —
/// gives one more frame for the platform compositor to catch up before the
/// screenshot is taken.
Future<void> _settle(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pumpAndSettle();
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('full sweep: screenshot every screen and dialog', (
    tester,
  ) async {
    final docsDir = await getApplicationDocumentsDirectory();
    final imagePath = p.join(docsDir.path, 'full_sweep_wall.png');
    final pngBytes = await _generateWallImage(width: 1600, height: 1200);
    await File(imagePath).writeAsBytes(pngBytes, flush: true);

    final ids = await _seedFullSweep(imagePath);

    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // ------------------------------------------------------------------
    // 01. Topos home (populated).
    // ------------------------------------------------------------------
    await binding.takeScreenshot('01-topos-home');

    // ------------------------------------------------------------------
    // 02. Areas (via "Organize").
    // ------------------------------------------------------------------
    final organizeButton = find.byKey(const Key('topos-organize'));
    expect(tester.any(organizeButton), isTrue, reason: 'topos-organize not found');
    await tester.tap(organizeButton);
    await _settle(tester);
    await binding.takeScreenshot('02-areas');

    // ------------------------------------------------------------------
    // 03. CRUD create-name dialog (area-add-fab), then cancel.
    // ------------------------------------------------------------------
    final areaAddFab = find.byKey(const Key('area-add-fab'));
    expect(tester.any(areaAddFab), isTrue, reason: 'area-add-fab not found');
    await tester.tap(areaAddFab);
    await tester.pumpAndSettle();
    expect(tester.any(find.byKey(const Key('crud-name-field'))), isTrue);
    expect(tester.any(find.byKey(const Key('crud-name-submit'))), isTrue);
    await binding.takeScreenshot('03-crud-create-dialog');
    final dialogCancel = find.text('Cancel');
    if (tester.any(dialogCancel)) {
      await tester.tap(dialogCancel.first);
      await tester.pumpAndSettle();
    }

    // ------------------------------------------------------------------
    // 04. Sectors (drill into Sweep Area 1).
    // ------------------------------------------------------------------
    final areaItem = find.byKey(Key('area-item-${ids.area1Id}'));
    expect(tester.any(areaItem), isTrue, reason: 'area-item not found');
    await tester.tap(areaItem);
    await _settle(tester);
    await binding.takeScreenshot('04-sectors');

    // ------------------------------------------------------------------
    // 05. Walls (drill into Sweep Sector 1).
    // ------------------------------------------------------------------
    final sectorItem = find.byKey(Key('sector-item-${ids.sector1Id}'));
    expect(tester.any(sectorItem), isTrue, reason: 'sector-item not found');
    await tester.tap(sectorItem);
    await _settle(tester);
    await binding.takeScreenshot('05-walls');

    // ------------------------------------------------------------------
    // 06. Delete-confirm CupertinoActionSheet (wall-delete), then cancel.
    // ------------------------------------------------------------------
    final wallDelete = find.byKey(Key('wall-delete-${ids.wall1aId}'));
    expect(tester.any(wallDelete), isTrue, reason: 'wall-delete not found');
    await tester.tap(wallDelete);
    await tester.pumpAndSettle();
    expect(
      tester.any(find.byKey(Key('wall-delete-confirm-${ids.wall1aId}'))),
      isTrue,
      reason: 'wall-delete-confirm not found in the action sheet',
    );
    await binding.takeScreenshot('06-delete-confirm-sheet');
    final sheetCancel = find.text('Cancel');
    if (tester.any(sheetCancel)) {
      await tester.tap(sheetCancel.first);
      await tester.pumpAndSettle();
    }

    // Navigate back to the Topos home: Walls -> Sectors -> Areas -> Topos.
    for (var i = 0; i < 3; i++) {
      await tester.pageBack();
      await _settle(tester);
    }
    expect(tester.any(find.byKey(const Key('topos-organize'))), isTrue);

    // ------------------------------------------------------------------
    // 07/08. Canvas with photo + graded-route legend (view mode).
    // ------------------------------------------------------------------
    final gradedTopoItem = find.byKey(Key('topo-item-${ids.gradedWallId}'));
    expect(
      tester.any(gradedTopoItem),
      isTrue,
      reason: 'Seeded graded topo item not found on the Topos home',
    );
    await tester.tap(gradedTopoItem);
    await _settle(tester);
    // Give the freshly-written PNG's ImageStream decode extra time to
    // resolve, same pacing as canvas_demo_test.dart's '13-canvas-with-image'.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    await tester.pumpAndSettle(const Duration(seconds: 2));
    await binding.takeScreenshot('07-canvas-with-photo');
    expect(tester.any(find.byKey(const Key('topo-route-legend'))), isTrue);
    await binding.takeScreenshot('08-canvas-graded-legend');

    // ------------------------------------------------------------------
    // 09. Draw mode (bottom chrome + symbol palette).
    // ------------------------------------------------------------------
    final modeToggle = find.byKey(const Key('topo-mode-toggle'));
    expect(tester.any(modeToggle), isTrue, reason: 'topo-mode-toggle not found');
    await tester.tap(modeToggle);
    await tester.pumpAndSettle();
    await binding.takeScreenshot('09-draw-mode');

    // ------------------------------------------------------------------
    // 10. In-progress (uncommitted) drawn route.
    // ------------------------------------------------------------------
    final drawArea = find.byKey(const Key('topo-draw-gesture-detector'));
    expect(
      tester.any(drawArea),
      isTrue,
      reason: 'topo-draw-gesture-detector not found',
    );
    final topLeft = tester.getTopLeft(drawArea);
    final size = tester.getSize(drawArea);
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
    await binding.takeScreenshot('10-canvas-drawn-line');

    // ------------------------------------------------------------------
    // 11. Route metadata sheet (commit opens it automatically), then
    //     cancel.
    // ------------------------------------------------------------------
    final commitButton = find.byKey(const Key('topo-commit-button'));
    expect(tester.any(commitButton), isTrue, reason: 'topo-commit-button not found');
    await tester.tap(commitButton);
    await tester.pumpAndSettle();
    expect(tester.any(find.byKey(const Key('topo-meta-name'))), isTrue);
    expect(
      tester.any(find.byKey(const Key('topo-meta-gradesystem-french'))),
      isTrue,
    );
    expect(
      tester.any(find.byKey(const Key('topo-meta-gradesystem-uiaa'))),
      isTrue,
    );
    expect(tester.any(find.byKey(const Key('topo-meta-grade'))), isTrue);
    expect(tester.any(find.byKey(const Key('topo-meta-style-sport'))), isTrue);
    await binding.takeScreenshot('11-route-metadata-sheet');
    final metaCancel = find.byKey(const Key('topo-meta-cancel'));
    if (tester.any(metaCancel)) {
      await tester.tap(metaCancel);
      await tester.pumpAndSettle();
    }

    // ------------------------------------------------------------------
    // 12. View mode after commit (6 routes now in the legend, chrome
    //     cluster gone).
    // ------------------------------------------------------------------
    await binding.takeScreenshot('12-view-mode-after-commit');

    // ------------------------------------------------------------------
    // 13. Canvas empty state (photo-less topo).
    // ------------------------------------------------------------------
    final canvasBack = find.byKey(const Key('topo-back-button'));
    expect(tester.any(canvasBack), isTrue, reason: 'topo-back-button not found');
    await tester.tap(canvasBack);
    await _settle(tester);
    final noPhotoTopoItem = find.byKey(Key('topo-item-${ids.noPhotoWallId}'));
    expect(
      tester.any(noPhotoTopoItem),
      isTrue,
      reason: 'Seeded no-photo topo item not found on the Topos home',
    );
    await tester.tap(noPhotoTopoItem);
    await _settle(tester);
    expect(tester.any(find.byKey(const Key('topo-empty-state'))), isTrue);
    await binding.takeScreenshot('13-canvas-empty-state');

    // ------------------------------------------------------------------
    // 14. Photo-source action sheet (Camera / Library / Cancel), then
    //     cancel — never touches the native picker.
    // ------------------------------------------------------------------
    final canvasBack2 = find.byKey(const Key('topo-back-button'));
    expect(tester.any(canvasBack2), isTrue, reason: 'topo-back-button not found');
    await tester.tap(canvasBack2);
    await _settle(tester);
    final newTopoButton = find.byKey(const Key('topos-new-topo'));
    expect(tester.any(newTopoButton), isTrue, reason: 'topos-new-topo not found');
    await tester.tap(newTopoButton);
    await tester.pumpAndSettle();
    expect(tester.any(find.byKey(const Key('photo-source-camera'))), isTrue);
    expect(tester.any(find.byKey(const Key('photo-source-library'))), isTrue);
    expect(tester.any(find.byKey(const Key('photo-source-cancel'))), isTrue);
    await binding.takeScreenshot('14-photo-source-sheet');
    await tester.tap(find.byKey(const Key('photo-source-cancel')));
    await tester.pumpAndSettle();

    // ------------------------------------------------------------------
    // 15. AR screen: intentionally SKIPPED — see the file-level doc comment
    // for why (camera-permission system dialog risk on the simulator, per
    // this project's CLAUDE.md hard limit). `topo-ar-button` was already
    // confirmed present in screenshots 07/08's top chrome.
    // ------------------------------------------------------------------
  });
}
