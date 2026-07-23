// Ship 1 of the route-derived rock box (#68): the topo canvas's
// "highlight rock" toggle (`topo-highlight-rock-toggle` in
// topo_canvas_screen.dart) now paints a synchronous, route-derived
// `RockBoxPainter` box (see `rock_box.dart`'s `rockBoxFromRoutes`) instead
// of the old async Vision-segmentation mask. This exercises `TopoCanvas`
// directly (mirroring `topo_canvas_symbol_glyphs_test.dart`'s bare-TopoCanvas
// harness, plus `topo_canvas_zoom_overlay_test.dart`'s seeded-wall/photo/
// route helper for a real `activePhotoId` + committed routes to derive a
// box from) to prove:
//  - toggling the highlight ON with committed routes present renders a
//    `RockBoxPainter` matching `rockBoxFromRoutes(drawState.routes)`.
//  - toggling back OFF removes it.
//  - with the highlight ON but no routes/symbols on the photo at all
//    (nothing to derive a box from), nothing is painted either.
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/ar/domain/rock_box.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/topo/application/draw_controller.dart';
import 'package:masi/features/topo/application/rock_highlight_controller.dart';
import 'package:masi/features/topo/presentation/rock_mask_painter.dart';
import 'package:masi/features/topo/presentation/topo_canvas.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

const _imageSize = Size(400, 300);

Finder _rockBoxPainterFinder() => find.byWidgetPredicate(
      (w) => w is CustomPaint && w.painter is RockBoxPainter,
    );

Future<({AppDatabase db, ProviderContainer container, String wallId, String photoId})>
_seedWallWithPhoto(WidgetTester tester, {bool withRoute = true}) async {
  final db = AppDatabase(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      nowMsProvider.overrideWithValue(() => 1000),
    ],
  );
  final crud = container.read(libraryCrudRepositoryProvider);
  final area = await crud.createArea('Area');
  final sector = await crud.createSector(area.id, 'Sector');
  final wall = await crud.createWall(sector.id, 'Wall');
  // FIX #6 (autoDispose pending-timer gotcha, see route_legend_gap_test.dart's
  // `_seedRoutes`): keep this family member alive for the whole test via a
  // permanent listener -- otherwise every bare `container.read(...)` below
  // (before any widget is pumped) schedules an autoDispose teardown
  // `Timer(Duration.zero, ...)` that only fires on a duration-based
  // `tester.pump`, tripping flutter_test's `!timersPending` invariant.
  container.listen(drawControllerProvider(wall.id), (_, _) {});
  late String photoId;
  await tester.runAsync(() async {
    photoId = await crud.attachPhotoToWall(
      wall.id,
      XFile('/tmp/rock-highlight-test-photo.jpg'),
      400,
      300,
    );
  });

  final notifier = container.read(drawControllerProvider(wall.id).notifier);
  await notifier.loadForWall(wall.id, photoId);
  if (withRoute) {
    notifier.addPoint(const Offset(0.2, 0.3));
    notifier.addPoint(const Offset(0.7, 0.6));
    await notifier.commitRoute();
  }

  return (db: db, container: container, wallId: wall.id, photoId: photoId);
}

Future<TransformationController> _pumpCanvas(
  WidgetTester tester,
  ProviderContainer container,
  String wallId,
) async {
  final controller = TransformationController();
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: TopoCanvas(
            wallId: wallId,
            imagePath: '/nonexistent/rock-highlight-test.jpg',
            imageSize: _imageSize,
            transformationController: controller,
          ),
        ),
      ),
    ),
  );
  return controller;
}

void main() {
  testWidgets(
    'toggling the highlight ON with committed routes paints a RockBoxPainter '
    'matching rockBoxFromRoutes(drawState.routes); toggling OFF removes it',
    (tester) async {
      final seeded = await _seedWallWithPhoto(tester);
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);

      await _pumpCanvas(tester, seeded.container, seeded.wallId);

      // OFF by default -- no box layer at all.
      expect(_rockBoxPainterFinder(), findsNothing);

      seeded.container
          .read(rockHighlightControllerProvider(seeded.photoId).notifier)
          .toggle();
      await tester.pump();

      final expectedBox = rockBoxFromRoutes(
        seeded.container.read(drawControllerProvider(seeded.wallId)).routes,
      );
      expect(expectedBox, isNotNull);

      final finder = _rockBoxPainterFinder();
      expect(finder, findsOneWidget);
      final painter = (tester.widget(finder) as CustomPaint).painter as RockBoxPainter;
      expect(painter.box, expectedBox);
      expect(painter.imageSize, _imageSize);

      // Toggle back OFF -- the box layer disappears again.
      seeded.container
          .read(rockHighlightControllerProvider(seeded.photoId).notifier)
          .toggle();
      await tester.pump();
      expect(_rockBoxPainterFinder(), findsNothing);
    },
  );

  testWidgets(
    'highlight ON but the photo has no drawn routes/symbols at all -> '
    'rockBoxFromRoutes returns null, so nothing is painted',
    (tester) async {
      final seeded = await _seedWallWithPhoto(tester, withRoute: false);
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);

      await _pumpCanvas(tester, seeded.container, seeded.wallId);

      seeded.container
          .read(rockHighlightControllerProvider(seeded.photoId).notifier)
          .toggle();
      await tester.pump();

      expect(
        seeded.container.read(drawControllerProvider(seeded.wallId)).routes,
        isEmpty,
      );
      expect(_rockBoxPainterFinder(), findsNothing);
    },
  );
}
