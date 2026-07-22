// Evidence-gathering integration test for the soft edge-fade ("feather"/
// vignette) fix: the fade used to live as a fixed, SCREEN-space overlay
// sibling of `TopoCanvas`'s `InteractiveViewer` (pinned to the viewport), so
// panning/zooming the photo left the fade stationary relative to the photo's
// actual edges. It now lives INSIDE the `InteractiveViewer`'s transformed
// `child`, stacked alongside `Image.file`/`CustomPaint` (see
// `topo_canvas.dart`'s `_TopoCanvasState.build`, the `edgeVignette` local
// keyed `'topo-canvas-edge-vignette'`) — so the fade pans/zooms WITH the
// photo instead of staying pinned to the viewport.
//
// This flow captures three screenshots of the SAME seeded topo:
//   1. `fade-01-rest`    - view mode at the default fit.
//   2. `fade-02-zoomed`  - after zooming the canvas in (transform scale
//      set directly on the real `TransformationController` the running
//      `TopoCanvas` widget holds — see below).
//   3. `fade-03-panned`  - after also panning the transform.
//
// Same seeding pattern as `canvas_demo_test.dart`/`graded_routes_demo_test.dart`:
// a real, decodable PNG written to disk plus Area -> Sector -> Wall -> Photo
// rows inserted directly into the app's real sqlite file, plus 3 committed
// routes (one per grade band) seeded directly via `RouteRepository.upsertRoute`
// so the canvas isn't empty. Uses a distinct "Fade Demo Crag" name so this
// flow's seed doesn't collide with the other demo flows if they've run
// against the same simulator install.
//
// The transform is driven deterministically rather than via a pinch gesture:
// `TopoCanvas` is a `ConsumerStatefulWidget` whose `transformationController`
// constructor field is public (see `topo_canvas.dart`'s `TopoCanvas` class),
// so `tester.widget<TopoCanvas>(find.byType(TopoCanvas))
// .transformationController` hands back the SAME `TransformationController`
// instance `TopoCanvasScreen` created and wired into the live
// `InteractiveViewer` (keyed `'topo-interactive-viewer'`) — setting `.value`
// on it is observed exactly like a real pinch/pan would be, without ever
// needing multi-pointer gesture simulation. `TopoCanvas` only re-applies its
// own fit/reframe transform once per distinct crop (see
// `_TopoCanvasState._hasFramed`/`_framedCropXpct` doc), so this manual
// override survives the subsequent `pump`s uncontested.
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
import 'package:masi/features/topo/presentation/topo_canvas.dart';
import 'package:masi/main.dart' as app;

/// Renders a 1600x1200 PNG with a bright gradient, a grid, and two
/// high-contrast shapes right up to the image's own edges — so the fade to
/// the dark `kCanvasBackdrop` at the photo's edges (see `topo_canvas.dart`'s
/// `edgeVignette`) reads clearly against it, both at rest and once
/// zoomed/panned.
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
  canvas.drawCircle(Offset(size.width * 0.15, size.height * 0.15), 140, shapePaint);
  canvas.drawRect(
    Rect.fromCenter(
      center: Offset(size.width * 0.85, size.height * 0.85),
      width: 280,
      height: 220,
    ),
    Paint()..color = Colors.purpleAccent,
  );

  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  return byteData!.buffer.asUint8List();
}

/// One route per a handful of [GradeBand]s (same derivation as
/// `graded_routes_demo_test.dart`'s `_gradedRoutes`), just enough (3) so the
/// canvas/legend aren't empty while the fade is the focus of these
/// screenshots.
const List<(int number, String grade)> _fadeDemoRoutes = [
  (1, '4a'),
  (2, '6b'),
  (3, '8a'),
];

/// Seeds Area -> Sector -> Wall -> attached original Photo directly into the
/// app's real sqlite file (same mechanism as `canvas_demo_test.dart`'s
/// `_seedDemoTopo`), then seeds 3 committed routes directly via
/// `RouteRepository.upsertRoute`.
Future<({String areaId, String sectorId, String wallId})> _seedFadeDemoTopo(
  String imagePath,
) async {
  final docsDir = await getApplicationDocumentsDirectory();
  final dbFile = File(p.join(docsDir.path, 'climbtopo.sqlite'));
  // Start from a clean slate so re-runs of this test don't accumulate
  // duplicate "Fade Demo Crag" entries, and so other demo flows' seeded rows
  // (if they ran previously in this same simulator install) don't leak into
  // this screenshot's route/legend counts.
  if (await dbFile.exists()) {
    await dbFile.delete();
  }

  final seedDb = AppDatabase(NativeDatabase(dbFile));
  try {
    int nowMs() => DateTime.now().millisecondsSinceEpoch;
    final repo = LibraryCrudRepository(seedDb, nowMs: nowMs);
    final area = await repo.createArea('Fade Demo Crag');
    final sector = await repo.createSector(area.id, 'Fade Demo Sector');
    final wall = await repo.createWall(sector.id, 'Fade Demo Wall');
    final photoId = await repo.attachPhotoToWall(wall.id, XFile(imagePath), 1600, 1200);

    final routeRepo = RouteRepository(seedDb, nowMs: nowMs);
    for (final (number, grade) in _fadeDemoRoutes) {
      final xBase = 0.20 + (number - 1) * 0.20;
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
    // app's runtime connection.
    await seedDb.close();
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('fade vignette demo: feather moves/scales with the photo', (
    tester,
  ) async {
    final docsDir = await getApplicationDocumentsDirectory();
    final imagePath = p.join(docsDir.path, 'fade_demo_wall.png');
    final pngBytes = await _generateDemoWallImage(width: 1600, height: 1200);
    await File(imagePath).writeAsBytes(pngBytes, flush: true);

    final ids = await _seedFadeDemoTopo(imagePath);

    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 2));

    final topoItem = find.byKey(Key('topo-item-${ids.wallId}'));
    expect(
      tester.any(topoItem),
      isTrue,
      reason: 'Seeded "Fade Demo Wall" topo item not found on the Topos home',
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

    final vignette = find.byKey(const Key('topo-canvas-edge-vignette'));
    expect(
      tester.any(vignette),
      isTrue,
      reason: 'topo-canvas-edge-vignette not found; cannot evidence the fade.',
    );

    // 1. Rest: default fit-to-viewport transform, straight out of
    // `TopoCanvas._reframeIfNeeded`. The photo's edges should visibly
    // feather into the dark backdrop here.
    await binding.takeScreenshot('fade-01-rest');

    // Grab the REAL TransformationController instance the running
    // TopoCanvas/InteractiveViewer are using (its constructor field is
    // public — see `topo_canvas.dart`'s `TopoCanvas.transformationController`
    // doc above), so setting `.value` here is observed by the live
    // InteractiveViewer exactly like a real pinch/pan would be.
    final topoCanvasWidget = tester.widget<TopoCanvas>(find.byType(TopoCanvas));
    final controller = topoCanvasWidget.transformationController;

    // 2. Zoomed: scale the transform up. If the fade fix holds, the
    // feathered edges should have moved/scaled WITH the photo (i.e. still
    // hug the photo's own edges, now further outside the viewport / less
    // visible depending on framing) rather than staying pinned to the
    // viewport's edges.
    controller.value = Matrix4.identity()..scaleByDouble(2.2, 2.2, 2.2, 1.0);
    await tester.pump();
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await binding.takeScreenshot('fade-02-zoomed');

    // 3. Panned: keep the same zoom, add a translation. `translateByDouble`
    // is called BEFORE `scaleByDouble` in this cascade, so the resulting
    // matrix is `T * S` — applied to a point `v` that's `S*v + t`: the image
    // is scaled first, then shifted by a fixed, screen-space `t` — a clean,
    // recognizable pixel-space pan on top of the existing zoom.
    controller.value = Matrix4.identity()
      ..translateByDouble(-220.0, -160.0, 0.0, 1.0)
      ..scaleByDouble(2.2, 2.2, 2.2, 1.0);
    await tester.pump();
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await binding.takeScreenshot('fade-03-panned');
  });
}
