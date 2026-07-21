// Visual review flow for the new filter sheets (Topos home, Community,
// Logbook) plus a look at the Topos-home AppBar under its new action count
// (filter/organize/community/logbook/account), in LIGHT theme.
//
// Same DB-file seeding seam as `canvas_review_test.dart` / `full_sweep_test.dart`:
// a real, decodable PNG written to disk plus rows inserted directly into the
// app's real sqlite file via the real repos, the seed connection closed
// BEFORE `app.main()` opens its own.
//
// Seeds one wall ("Filter Wall") with an attached photo and 5 graded routes
// spanning a mix of grades/styles (mirroring canvas_review_test's
// `_gradedRoutes`), PUBLISHES it (visibility -> 'shared') so it shows up in
// the Community feed, and logs 3 ascents against 3 of its routes (mixed
// styles/dates) so the Logbook has rows to filter over.
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
import 'package:climbtopo/features/logbook/data/ascents_repository.dart';
import 'package:climbtopo/features/topo/data/route_repository.dart';
import 'package:climbtopo/features/topo/domain/topo_route.dart';
import 'package:climbtopo/main.dart' as app;

/// Same gradient/grid/shapes recipe as `canvas_review_test.dart`'s
/// `_generateWallImage`, just reused here so the seeded wall has a real
/// decodable photo (never a real-image-codec-under-fake-async trap since
/// this runs on-device via `flutter drive`, not `flutter test`).
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

/// Five routes, one per French grade rung with varying styles, mirroring
/// `canvas_review_test.dart`'s `_gradedRoutes` shape so the filter sheets
/// (grade range + style chips) have a real spread to filter over.
const List<(int number, String grade, String style)> _gradedRoutes = [
  (1, '5c', 'sport'),
  (2, '6a+', 'sport'),
  (3, '6c', 'trad'),
  (4, '7a', 'sport'),
  (5, '8a', 'boulder'),
];

/// Seeds "Filter Wall" directly into the app's real sqlite file (same file
/// `app.main()` will open), deleting any existing file first for a clean
/// slate:
///  - one attached photo,
///  - the 5 graded/styled routes above,
///  - published to Community (`visibility -> 'shared'`),
///  - 3 logged ascents against 3 of those routes (mixed styles/dates) so the
///    Logbook has rows.
/// Returns the wall id.
Future<String> _seedFilterReviewTopo(String imagePath) async {
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
    final ascentsRepo = AscentsRepository(seedDb, nowMs: nowMs);

    final wallId = await repo.createTopo('Filter Wall');
    final photoId = await repo.attachPhotoToWall(wallId, XFile(imagePath), 1200, 1600);

    for (final (number, grade, style) in _gradedRoutes) {
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

    // Publish so the Community feed (visibility == 'shared') shows it.
    await repo.publishTopo(wallId);

    // Resolve each route's real DB id (a uuid, distinct from the
    // sequential in-memory TopoRoute.id used above) to log ascents against.
    final routeDbIds = await routeRepo.routeDbIdsByNumber(wallId);
    final now = DateTime.now();
    await ascentsRepo.logAscent(
      routeId: routeDbIds[1]!,
      wallId: wallId,
      climbedAt: now,
      style: AscentStyle.redpoint,
      notes: 'Clean redpoint, felt great',
    );
    await ascentsRepo.logAscent(
      routeId: routeDbIds[3]!,
      wallId: wallId,
      climbedAt: now.subtract(const Duration(days: 2)),
      style: AscentStyle.onsight,
    );
    await ascentsRepo.logAscent(
      routeId: routeDbIds[5]!,
      wallId: wallId,
      climbedAt: now.subtract(const Duration(days: 5)),
      style: AscentStyle.attempt,
      notes: 'Fell at the crux, back for more',
    );

    return wallId;
  } finally {
    // Close BEFORE app.main() opens its own connection to the same file —
    // see canvas_review_test.dart's identical rationale.
    await seedDb.close();
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('filtering review: seeded+published wall with ascents, filter-sheet screenshots', (
    tester,
  ) async {
    final docsDir = await getApplicationDocumentsDirectory();
    final imagePath = p.join(docsDir.path, 'filter_review_wall.png');
    final pngBytes = await _generateWallImage(width: 1200, height: 1600);
    await File(imagePath).writeAsBytes(pngBytes, flush: true);

    final wallId = await _seedFilterReviewTopo(imagePath);

    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 2));

    final topoItem = find.byKey(Key('topo-item-$wallId'));
    expect(
      tester.any(topoItem),
      isTrue,
      reason: 'Seeded "Filter Wall" topo item not found on the Topos home',
    );

    // ------------------------------------------------------------------
    // 01. Topos home screen: AppBar (filter/organize/community/logbook/
    // account actions) + the seeded, published topo row.
    // ------------------------------------------------------------------
    await binding.takeScreenshot('filter-01-topos-screen');

    // ------------------------------------------------------------------
    // 02. Topos-home Filters sheet.
    // ------------------------------------------------------------------
    final toposFilterButton = find.byKey(const Key('topos-filter-button'));
    expect(
      tester.any(toposFilterButton),
      isTrue,
      reason: 'topos-filter-button not found',
    );
    await tester.tap(toposFilterButton);
    await tester.pumpAndSettle();
    await binding.takeScreenshot('filter-02-topos-sheet');

    // Dismiss the modal bottom sheet (tap the scrim).
    await tester.tapAt(const Offset(20, 40));
    await tester.pumpAndSettle();

    // ------------------------------------------------------------------
    // 03. Community screen (feed tab), showing the published "Filter Wall".
    // Feed is now a persistent bottom-nav tab (`nav-tab-feed`) rather than
    // an in-screen Feed/Map toggle reached via a home AppBar button.
    // ------------------------------------------------------------------
    final feedTab = find.byKey(const Key('nav-tab-feed'));
    expect(
      tester.any(feedTab),
      isTrue,
      reason: 'nav-tab-feed not found',
    );
    await tester.tap(feedTab);
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await binding.takeScreenshot('filter-03-community-screen');

    // ------------------------------------------------------------------
    // 04. Community Filters sheet.
    // ------------------------------------------------------------------
    final communityFilterButton = find.byKey(const Key('community-filter-button'));
    expect(
      tester.any(communityFilterButton),
      isTrue,
      reason: 'community-filter-button not found',
    );
    await tester.tap(communityFilterButton);
    await tester.pumpAndSettle();
    await binding.takeScreenshot('filter-04-community-sheet');

    // Dismiss the modal bottom sheet (tap the scrim).
    await tester.tapAt(const Offset(20, 40));
    await tester.pumpAndSettle();

    // ------------------------------------------------------------------
    // 05. Logbook screen, showing the 3 seeded ascents.
    // Feed/Map are persistent bottom-nav branches now (no back-arrow to pop
    // back to Topos home) and the Logbook's entry point moved onto the
    // Feed screen's own AppBar (`feed-logbook-button`) -- already on Feed
    // from step 03, so tap it directly.
    // ------------------------------------------------------------------
    final logbookButton = find.byKey(const Key('feed-logbook-button'));
    expect(
      tester.any(logbookButton),
      isTrue,
      reason: 'feed-logbook-button not found',
    );
    await tester.tap(logbookButton);
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await binding.takeScreenshot('filter-05-logbook-screen');

    // ------------------------------------------------------------------
    // 06. Logbook Filters sheet.
    // ------------------------------------------------------------------
    final logbookFilterButton = find.byKey(const Key('logbook-filter-button'));
    expect(
      tester.any(logbookFilterButton),
      isTrue,
      reason: 'logbook-filter-button not found',
    );
    await tester.tap(logbookFilterButton);
    await tester.pumpAndSettle();
    await binding.takeScreenshot('filter-06-logbook-sheet');
  });
}
