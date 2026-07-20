// Visual-UX-review screenshot flow for the topo canvas.
//
// This is a sibling to `full_sweep_test.dart` / `canvas_demo_test.dart` /
// `graded_routes_demo_test.dart` (same DB-file seeding seam: a real,
// decodable PNG written to disk plus rows inserted directly into the app's
// real sqlite file via the real repos, the seed connection closed BEFORE
// `app.main()` opens its own — see those files for the full rationale). It
// exists specifically to capture the canvas in several UI states (plain
// view, zoomed, draw mode, back to view) while the full-bleed image +
// permanent legend-overlay work is landing concurrently in `lib/`, so a
// reviewer can judge the visual result without re-running the whole sweep.
//
// Seeds one wall ("Sunset Wall") with an attached photo and 5 graded routes
// (French 5c/6a+/6c/7a/8a), each a short multi-point polyline, so the
// legend has enough rows and the canvas has enough drawn strokes to be a
// meaningful visual review target.
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
import 'package:climbtopo/core/grades/grade_system.dart';
import 'package:climbtopo/features/library/data/library_crud_repository.dart';
import 'package:climbtopo/features/topo/data/photo_repository.dart';
import 'package:climbtopo/features/topo/data/route_repository.dart';
import 'package:climbtopo/features/topo/domain/slice_geometry.dart';
import 'package:climbtopo/features/topo/domain/topo_route.dart';
import 'package:climbtopo/main.dart' as app;

/// Renders a 1200x1600 (portrait-ish, like a real crag-wall photo) PNG with
/// a gradient background, a grid, and a few high-contrast shapes (same
/// recipe as `full_sweep_test.dart`'s `_generateWallImage`, just a different
/// aspect ratio) so the wall photo, route strokes, and the legend overlay
/// all have plenty of contrast to review.
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
  canvas.drawCircle(Offset(size.width * 0.3, size.height * 0.25), 130, shapePaint);
  canvas.drawRect(
    Rect.fromCenter(
      center: Offset(size.width * 0.65, size.height * 0.6),
      width: 260,
      height: 340,
    ),
    Paint()..color = Colors.purpleAccent,
  );

  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  return byteData!.buffer.asUint8List();
}

/// Five routes, one per French grade rung, with varying style labels so the
/// legend shows a mix — mirrors `full_sweep_test.dart` /
/// `graded_routes_demo_test.dart`'s `_gradedRoutes` shape.
const List<(int number, String grade, String style)> _gradedRoutes = [
  (1, '5c', 'sport'),
  (2, '6a+', 'sport'),
  (3, '6c', 'trad'),
  (4, '7a', 'sport'),
  (5, '8a', 'boulder'),
];

/// The two topo ids this file's seed produces, so the test body can target
/// each wall's canvas directly by Key.
class _ReviewIds {
  const _ReviewIds({required this.wallId, required this.slicedWallId});

  /// "Sunset Wall": photo + 5 graded routes, no slices — the "normal" wall
  /// used for the plain view/zoom-in/draw/zoom-out screenshots.
  final String wallId;

  /// "Sliced Wall": photo + 3 persisted slices, no routes — used to verify
  /// the full-bleed-photo-plus-floating-slice-picker fix.
  final String slicedWallId;
}

/// Seeds two photo-first "topos" (walls) directly into the app's real
/// sqlite file (same file `app.main()` will open), deleting any existing
/// file first for a clean slate:
///  - "Sunset Wall": one attached photo plus 5 committed, graded routes
///    (each a 4-point polyline in percent space spanning the photo), so the
///    canvas, its route strokes, and the legend are all populated for a
///    visual review.
///  - "Sliced Wall": one attached photo plus 3 persisted slices (via
///    `PhotoRepository.replaceSlices`, same recipe as
///    `full_sweep_test.dart`'s `_seedFullSweep`), so the sliced-wall canvas
///    (full-bleed photo + floating slice-picker) can be reviewed too.
/// Returns both walls' ids.
Future<_ReviewIds> _seedReviewTopo(
  String imagePath,
  String slicedImagePath,
) async {
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
    final photoRepo = PhotoRepository(seedDb, nowMs: nowMs);

    final wallId = await repo.createTopo('Sunset Wall');
    final photoId = await repo.attachPhotoToWall(wallId, XFile(imagePath), 1200, 1600);

    for (final (number, grade, style) in _gradedRoutes) {
      // Each route is a 4-point polyline, horizontally offset by number so
      // all five render as distinct, non-overlapping strokes (and distinct
      // legend rows) spanning across the photo rather than stacking on top
      // of each other.
      final xBase = 0.10 + (number - 1) * 0.18;
      final points = [
        Offset(xBase, 0.90),
        Offset(xBase + 0.03, 0.65),
        Offset(xBase - 0.02, 0.40),
        Offset(xBase + 0.05, 0.12),
      ];
      final sortKey = gradeSortKey(GradeSystem.french, grade);
      await routeRepo.upsertRoute(
        wallId,
        photoId,
        TopoRoute(
          id: number,
          number: number,
          points: points,
          colorIndex: routeColorIndexFor(number),
          gradeSystem: GradeSystem.french,
          gradeRaw: grade,
          gradeSortKey: sortKey,
          style: style,
        ),
      );
    }

    // -- Second wall: photo + 3 persisted slices (2 interior cuts), to
    // review the sliced-wall canvas (full-bleed photo + floating
    // slice-picker) fix.
    final slicedWallId = await repo.createTopo('Sliced Wall');
    final slicedPhotoId = await repo.attachPhotoToWall(
      slicedWallId,
      XFile(slicedImagePath),
      1200,
      1600,
    );
    await photoRepo.replaceSlices(
      slicedWallId,
      slicedPhotoId,
      1200,
      1600,
      slicedImagePath,
      slicesFromCuts([0.33, 0.66]),
    );

    return _ReviewIds(wallId: wallId, slicedWallId: slicedWallId);
  } finally {
    // Close BEFORE app.main() opens its own connection to the same file —
    // see full_sweep_test.dart's identical rationale.
    await seedDb.close();
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('canvas review: seeded graded wall, view/zoom/draw screenshots', (
    tester,
  ) async {
    final docsDir = await getApplicationDocumentsDirectory();
    final imagePath = p.join(docsDir.path, 'review_wall.png');
    final pngBytes = await _generateWallImage(width: 1200, height: 1600);
    await File(imagePath).writeAsBytes(pngBytes, flush: true);

    final slicedImagePath = p.join(docsDir.path, 'review_wall_sliced.png');
    final slicedPngBytes = await _generateWallImage(width: 1200, height: 1600);
    await File(slicedImagePath).writeAsBytes(slicedPngBytes, flush: true);

    final ids = await _seedReviewTopo(imagePath, slicedImagePath);
    final wallId = ids.wallId;
    final slicedWallId = ids.slicedWallId;

    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 2));

    final topoItem = find.byKey(Key('topo-item-$wallId'));
    expect(
      tester.any(topoItem),
      isTrue,
      reason: 'Seeded "Sunset Wall" topo item not found on the Topos home',
    );
    await tester.tap(topoItem);
    await tester.pumpAndSettle(const Duration(seconds: 1));
    // Give the freshly-written PNG's ImageStream decode extra time to
    // resolve, same pacing as full_sweep_test.dart's '07-canvas-with-photo'.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // The canvas itself is a hard requirement for this review to mean
    // anything; the legend key, however, is mid-change concurrently in
    // lib/ (becoming a permanent `topo-route-legend-overlay`), so that
    // check below is soft — see the file-level doc comment.
    expect(
      find.byKey(const Key('topo-interactive-viewer')),
      findsOneWidget,
      reason: 'topo-interactive-viewer not found; canvas did not render',
    );

    final legendOverlay = find.byKey(const Key('topo-route-legend-overlay'));
    if (tester.any(legendOverlay)) {
      debugPrint('INFO: found topo-route-legend-overlay (new permanent overlay key).');
    } else {
      final legendFallback = find.byKey(const Key('topo-route-legend'));
      if (tester.any(legendFallback)) {
        debugPrint(
          'INFO: topo-route-legend-overlay not found; found fallback '
          'topo-route-legend instead.',
        );
      } else {
        debugPrint(
          'INFO: neither topo-route-legend-overlay nor topo-route-legend '
          'found; legend not visible in this state.',
        );
      }
    }

    // ------------------------------------------------------------------
    // 01. Plain view mode: photo + 5 graded route strokes + legend.
    // ------------------------------------------------------------------
    await binding.takeScreenshot('canvas-01-view');

    // ------------------------------------------------------------------
    // 01b. Log-ascent visual gate: the routes panel showing each row's new
    // per-route tick/log icon (`topo-log-ascent-<id>`), then the
    // `LogAscentSheet` opened by tapping the first seeded route's icon.
    // ------------------------------------------------------------------
    await binding.takeScreenshot('canvas-log-01-legend');

    final logAscentButton = find.byKey(const Key('topo-log-ascent-1'));
    if (tester.any(logAscentButton)) {
      await tester.tap(logAscentButton);
      await tester.pumpAndSettle();
      await binding.takeScreenshot('canvas-log-02-sheet');

      // Dismiss the modal bottom sheet (tap the scrim) so the rest of this
      // flow's navigation (zoom/draw/back-button steps below) proceeds
      // against the plain canvas exactly as before this addition.
      await tester.tapAt(const Offset(20, 40));
      await tester.pumpAndSettle();
    } else {
      debugPrint(
        'INFO: topo-log-ascent-1 not found; skipping canvas-log-02-sheet.',
      );
    }

    // ------------------------------------------------------------------
    // 02. Best-effort pinch/zoom on the InteractiveViewer. Wrapped so a
    // gesture-recognition quirk (or a concurrent lib/ change to the
    // viewer's key/behavior) can't abort the rest of the flow.
    // ------------------------------------------------------------------
    try {
      final center = tester.getCenter(
        find.byKey(const Key('topo-interactive-viewer')),
      );
      final g1 = await tester.startGesture(center - const Offset(10, 0));
      final g2 = await tester.startGesture(center + const Offset(10, 0));

      // Move pointers apart incrementally in 5 steps (±50 each = ±250 total)
      for (int i = 0; i < 5; i++) {
        await g1.moveBy(const Offset(-50, 0));
        await g2.moveBy(const Offset(50, 0));
        await tester.pump(const Duration(milliseconds: 20));
      }

      await g1.up();
      await g2.up();
      await tester.pumpAndSettle();
    } catch (e, st) {
      debugPrint('INFO: pinch/zoom gesture failed, continuing: $e\n$st');
    }
    await binding.takeScreenshot('canvas-02-zoomed');

    // ------------------------------------------------------------------
    // 03. Draw mode (bottom chrome + symbol palette).
    // ------------------------------------------------------------------
    final modeToggle = find.byKey(const Key('topo-mode-toggle'));
    expect(tester.any(modeToggle), isTrue, reason: 'topo-mode-toggle not found');
    await tester.tap(modeToggle);
    await tester.pumpAndSettle();
    await binding.takeScreenshot('canvas-03-draw');

    // ------------------------------------------------------------------
    // 04. Back to view mode (best-effort: tap the same toggle again).
    // ------------------------------------------------------------------
    final modeToggleBack = find.byKey(const Key('topo-mode-toggle'));
    if (tester.any(modeToggleBack)) {
      await tester.tap(modeToggleBack);
      await tester.pumpAndSettle();
    } else {
      debugPrint('INFO: topo-mode-toggle not found on return; skipping toggle-back.');
    }
    await binding.takeScreenshot('canvas-04-view2');

    // ------------------------------------------------------------------
    // 05. A wall WITH slices: verifies the photo is now full-bleed with a
    // floating slice-picker, rather than the old letterboxed-with-inline-
    // chips layout. Navigate back to the Topos home, then into the seeded
    // "Sliced Wall".
    // ------------------------------------------------------------------
    final backButtonToSliced = find.byKey(const Key('topo-back-button'));
    expect(
      tester.any(backButtonToSliced),
      isTrue,
      reason: 'topo-back-button not found',
    );
    await tester.tap(backButtonToSliced);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    final slicedTopoItem = find.byKey(Key('topo-item-$slicedWallId'));
    expect(
      tester.any(slicedTopoItem),
      isTrue,
      reason: 'Seeded "Sliced Wall" topo item not found on the Topos home',
    );
    await tester.tap(slicedTopoItem);
    await tester.pumpAndSettle(const Duration(seconds: 1));
    // Give the freshly-written PNG's ImageStream decode extra time to
    // resolve, same pacing as the first wall's load above.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    await tester.pumpAndSettle(const Duration(seconds: 2));

    expect(
      find.byKey(const Key('topo-interactive-viewer')),
      findsOneWidget,
      reason: 'topo-interactive-viewer not found; sliced-wall canvas did not render',
    );
    // Soft check (not `findsOneWidget`): the full-bleed-photo +
    // floating-slice-picker rework is landing concurrently in lib/, and has
    // been observed to transiently render 2 widgets sharing the
    // `photo-selector` key (e.g. an old inline selector plus the new
    // floating one) mid-edit. Any match is enough evidence the
    // slice-picker is present for this visual review; see this file's
    // `topo-route-legend-overlay`/`topo-route-legend` soft-check above and
    // `full_sweep_test.dart`'s `13-photo-selector-chips` for the same
    // leniency pattern.
    final photoSelector = find.byKey(const Key('photo-selector'));
    expect(
      tester.any(photoSelector),
      isTrue,
      reason:
          'photo-selector not found on the sliced wall; expected the '
          'floating slice-picker to be present',
    );
    await binding.takeScreenshot('canvas-05-sliced');

    // ------------------------------------------------------------------
    // 06. Zoomed-OUT state on a normal (non-sliced) wall: verifies the
    // photo can now be shrunk below screen width. Navigate back to the
    // Topos home, then back into "Sunset Wall", and pinch-IN (pointers
    // starting apart, moving together) to zoom out.
    // ------------------------------------------------------------------
    final backButtonToSunset = find.byKey(const Key('topo-back-button'));
    expect(
      tester.any(backButtonToSunset),
      isTrue,
      reason: 'topo-back-button not found',
    );
    await tester.tap(backButtonToSunset);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    final wallItemAgain = find.byKey(Key('topo-item-$wallId'));
    expect(
      tester.any(wallItemAgain),
      isTrue,
      reason: 'Seeded "Sunset Wall" topo item not found for zoom-out revisit',
    );
    await tester.tap(wallItemAgain);
    await tester.pumpAndSettle(const Duration(seconds: 1));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    await tester.pumpAndSettle(const Duration(seconds: 2));

    try {
      final center = tester.getCenter(
        find.byKey(const Key('topo-interactive-viewer')),
      );
      final g1 = await tester.startGesture(center - const Offset(260, 0));
      final g2 = await tester.startGesture(center + const Offset(260, 0));

      // Move pointers TOGETHER incrementally in 5 steps (±50 each, pinch-IN
      // => zoom OUT), mirroring the pinch-apart zoom-in gesture above.
      for (int i = 0; i < 5; i++) {
        await g1.moveBy(const Offset(50, 0));
        await g2.moveBy(const Offset(-50, 0));
        await tester.pump(const Duration(milliseconds: 20));
      }

      await g1.up();
      await g2.up();
      await tester.pumpAndSettle();
    } catch (e, st) {
      debugPrint('INFO: pinch-in (zoom-out) gesture failed, continuing: $e\n$st');
    }
    await binding.takeScreenshot('canvas-06-zoomout');
  });
}
