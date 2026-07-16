// Visual review flow for the boulder MAP MARKERS: seeds one PRIVATE wall
// (renders as a dark "own" boulder) and one PUBLISHED wall (renders as a
// light "community" boulder) with close coordinates around Budapest, then
// screenshots the Community map so the boulder shape + dark(private)/
// light(public) tint can be eyeballed. Same DB-file seeding seam as
// map_review_test.dart (seed connection closed BEFORE app.main()).
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/features/library/data/library_crud_repository.dart';
import 'package:climbtopo/main.dart' as app;

Future<Uint8List> _wallImage(Color accent) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  const size = Size(1200, 1600);
  final rect = Rect.fromLTWH(0, 0, size.width, size.height);
  canvas.drawRect(
    rect,
    Paint()
      ..shader = ui.Gradient.linear(rect.topLeft, rect.bottomRight, [
        const Color(0xFF1B5E20),
        accent,
        const Color(0xFFB71C1C),
      ], const [0.0, 0.5, 1.0]),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(1200, 1600);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  return bytes!.buffer.asUint8List();
}

/// (name, lat, lng, publish?) — one private (dark), one published (light).
const _crags = <(String, double, double, bool)>[
  ('Private Boulder', 47.4979, 19.0402, false),
  ('Public Boulder', 47.5316, 19.0290, true),
];

Future<List<String>> _seed(String Function(String) imagePathFor) async {
  final docsDir = await getApplicationDocumentsDirectory();
  final dbFile = File(p.join(docsDir.path, 'climbtopo.sqlite'));
  if (await dbFile.exists()) await dbFile.delete();

  final seedDb = AppDatabase(NativeDatabase(dbFile));
  final wallIds = <String>[];
  try {
    final repo =
        LibraryCrudRepository(seedDb, nowMs: () => DateTime.now().millisecondsSinceEpoch);
    for (final (name, lat, lng, publish) in _crags) {
      final wallId = await repo.createTopo(name);
      final imagePath = imagePathFor(name);
      await File(imagePath).writeAsBytes(await _wallImage(const Color(0xFF6E56C6)), flush: true);
      await repo.attachPhotoToWall(wallId, imagePath, 1200, 1600);
      if (publish) await repo.publishTopo(wallId);
      await repo.setWallCoordinates(wallId, lat, lng);
      wallIds.add(wallId);
    }
    return wallIds;
  } finally {
    await seedDb.close();
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('boulder marker review: private (dark) + public (light) on the map', (
    tester,
  ) async {
    final docsDir = await getApplicationDocumentsDirectory();
    final wallIds = await _seed(
      (name) => p.join(docsDir.path, 'boulder_${name.toLowerCase().replaceAll(' ', '_')}.png'),
    );
    expect(wallIds, hasLength(2));

    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 2));

    await tester.tap(find.byKey(const Key('home-community-button')));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.byKey(const Key('community-map-toggle')));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));

    // private -> own (dark) marker; public -> community (light) marker.
    expect(
      tester.any(find.byKey(Key('community-map-own-marker-${wallIds[0]}'))),
      isTrue,
      reason: 'private wall should render as an own (dark) boulder',
    );
    expect(
      tester.any(find.byKey(Key('community-map-marker-${wallIds[1]}'))),
      isTrue,
      reason: 'public wall should render as a community (light) boulder',
    );

    await binding.takeScreenshot('boulder-01-map');
  });
}
