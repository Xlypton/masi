// Visual review flow for the Community MAP view: seeds 3 published walls
// with distinct-but-close coordinates (three crags around Budapest) so all
// their pin markers land in frame at the map's default zoom, then
// screenshots the map with markers over the CartoDB Positron basemap.
//
// Same DB-file seeding seam as `filtering_review_test.dart` /
// `canvas_review_test.dart`: a real, decodable PNG written to disk plus rows
// inserted directly into the app's real sqlite file via the real repos, the
// seed connection closed BEFORE `app.main()` opens its own.
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
import 'package:masi/features/library/data/library_crud_repository.dart';
import 'package:masi/main.dart' as app;

/// Same gradient/grid/shapes recipe as `filtering_review_test.dart`'s
/// `_generateWallImage`, reused so each seeded wall has a real decodable
/// photo (never a real-image-codec-under-fake-async trap since this runs
/// on-device via `flutter drive`, not `flutter test`).
Future<Uint8List> _generateWallImage({
  required int width,
  required int height,
  required Color accent,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final size = Size(width.toDouble(), height.toDouble());
  final rect = Rect.fromLTWH(0, 0, size.width, size.height);

  final gradient = ui.Gradient.linear(
    rect.topLeft,
    rect.bottomRight,
    [const Color(0xFF1B5E20), accent, const Color(0xFFB71C1C)],
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

  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  return byteData!.buffer.asUint8List();
}

/// Three crags around Budapest, close enough together to all land in frame
/// at the Community map's default zoom (11) around their centroid.
const List<(String name, double lat, double lng, Color accent)> _mapCrags = [
  ('Map Crag Danube', 47.4979, 19.0402, Color(0xFFF9A825)),
  ('Map Crag Buda Hills', 47.5316, 19.0290, Color(0xFF29B6F6)),
  ('Map Crag Gellert', 47.4813, 19.0530, Color(0xFFAB47BC)),
];

/// Seeds the three [_mapCrags] directly into the app's real sqlite file
/// (same file `app.main()` will open), deleting any existing file first for
/// a clean slate. Each wall gets an attached photo, is published
/// (`visibility -> 'shared'`) so it shows up on the Community map, and has
/// its coordinates set via [LibraryCrudRepository.setWallCoordinates].
/// Returns the seeded wall ids in the same order as [_mapCrags].
Future<List<String>> _seedMapReviewTopos(String Function(String name) imagePathFor) async {
  final docsDir = await getApplicationDocumentsDirectory();
  final dbFile = File(p.join(docsDir.path, 'climbtopo.sqlite'));
  if (await dbFile.exists()) {
    await dbFile.delete();
  }

  final seedDb = AppDatabase(NativeDatabase(dbFile));
  final wallIds = <String>[];
  try {
    int nowMs() => DateTime.now().millisecondsSinceEpoch;
    final repo = LibraryCrudRepository(seedDb, nowMs: nowMs);

    for (final (name, lat, lng, accent) in _mapCrags) {
      final wallId = await repo.createTopo(name);

      final imagePath = imagePathFor(name);
      final pngBytes = await _generateWallImage(
        width: 1200,
        height: 1600,
        accent: accent,
      );
      await File(imagePath).writeAsBytes(pngBytes, flush: true);
      await repo.attachPhotoToWall(wallId, XFile(imagePath), 1200, 1600);

      await repo.publishTopo(wallId);
      await repo.setWallCoordinates(wallId, lat, lng);

      wallIds.add(wallId);
    }

    return wallIds;
  } finally {
    // Close BEFORE app.main() opens its own connection to the same file —
    // see filtering_review_test.dart's identical rationale.
    await seedDb.close();
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('map review: seeded+published walls with coordinates, community map screenshots', (
    tester,
  ) async {
    final docsDir = await getApplicationDocumentsDirectory();

    final wallIds = await _seedMapReviewTopos(
      (name) => p.join(
        docsDir.path,
        'map_review_${name.toLowerCase().replaceAll(' ', '_')}.png',
      ),
    );
    expect(wallIds, hasLength(3));

    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // ------------------------------------------------------------------
    // Navigate: Topos home -> Map (persistent bottom-nav tab).
    // ------------------------------------------------------------------
    final mapTab = find.byKey(const Key('nav-tab-map'));
    expect(
      tester.any(mapTab),
      isTrue,
      reason: 'nav-tab-map not found',
    );
    await tester.tap(mapTab);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // ------------------------------------------------------------------
    // Map is a persistent bottom-nav tab now -- there is no more in-screen
    // Feed/Map toggle to tap; just let the map settle.
    // ------------------------------------------------------------------
    // Do NOT pumpAndSettle: flutter_map's tile fade-in animation never
    // settles. Pump fixed durations instead to give tiles a chance to load
    // (real network in the simulator) before screenshotting.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));

    // ------------------------------------------------------------------
    // 01. Community map overview: 3 pin markers over the CartoDB basemap.
    // ------------------------------------------------------------------
    for (final wallId in wallIds) {
      final marker = find.byKey(Key('community-map-marker-$wallId'));
      expect(
        tester.any(marker),
        isTrue,
        reason: 'community-map-marker-$wallId not found',
      );
    }
    await binding.takeScreenshot('map-01-overview');

    // ------------------------------------------------------------------
    // 02. Tap the first marker. This navigates to the topo detail screen
    // (see community_screen.dart's `_MapView` marker `onTap`), so
    // screenshot the detail rather than the map.
    // ------------------------------------------------------------------
    final firstMarker = find.byKey(Key('community-map-marker-${wallIds.first}'));
    await tester.tap(firstMarker);
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await binding.takeScreenshot('map-02-detail');
  });
}
