// Editing a COMMITTED route's geometry, driven in a real headless Chrome
// against real drift-on-browser-storage.
//
//     tool/drive_web.sh integration_test/web_route_geometry_edit_test.dart
//
// ---------------------------------------------------------------------
// WHY THIS EXISTS WHEN THE WIDGET TESTS ARE ALREADY GREEN
// ---------------------------------------------------------------------
// `topo_canvas_route_geometry_gesture_test.dart` drives the same gestures
// under `flutter_test`, and passes. What it cannot speak for is everything
// that is only real in a browser: the fit transform against a photo that was
// actually decoded rather than declared, the pointer pipeline through a real
// Chrome, and — the one that matters most — whether the edit reaches drift's
// browser backend at all. A canvas that renders perfectly and writes nothing
// looks identical to one that works, right up until the topo is reopened.
//
// So this asserts the round trip: edit, then read the geometry back through
// `RouteRepository` rather than off the controller that just changed it.
//
// ---------------------------------------------------------------------
// WHAT IT DELIBERATELY DOES NOT DO
// ---------------------------------------------------------------------
// It does not press F5. `integration_test` cannot: the test isolate dies with
// the page, which is why the photo-durability proof is a chained PAIR of
// `flutter drive` runs (`web_photo_offline_seed_test.dart`). Reading back
// through the repository is strictly weaker than a cold restart — the same
// page wrote it — and this header is the place that says so rather than
// letting a green tick imply more.
//
// It also seeds the route through the repository instead of drawing it by
// tapping. Drawing is already covered by `web_smoke_test.dart`'s flow and by
// unit tests; conflating "can I draw a line" with "can I edit a committed
// one" would mean a failure in either half reads as a failure of both.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart' show XFile;
import 'package:integration_test/integration_test.dart';
import 'package:masi/app/app.dart' show MasiApp;
import 'package:masi/features/account/application/auth_providers.dart';
import 'package:masi/core/db/database_provider.dart'
    show routeRepositoryProvider;
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/topo/application/draw_controller.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
import 'package:masi/features/topo/presentation/topo_canvas.dart';
import 'package:masi/features/topo/presentation/topo_painter.dart';
import 'package:masi/main.dart' show bootApp;

import 'web_photo_offline_fixture.dart' show buildPhotoBytes;

const _wallName = 'Route geometry edit';

/// The three points the seeded route is drawn through, far enough apart that
/// the 20px handle hit radius cannot confuse two of them at any fit scale this
/// photo produces.
const _seededPoints = [
  Offset(0.25, 0.25),
  Offset(0.5, 0.5),
  Offset(0.75, 0.75),
];
const _seededMarker = TopoSymbol(
  type: SymbolType.bolt,
  position: Offset(0.35, 0.6),
);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final observed = <String, Object?>{};
  void record(Map<String, Object?> entries) {
    observed.addAll(entries);
    binding.reportData = Map<String, Object?>.from(observed);
  }

  ProviderContainer containerOf(WidgetTester tester) =>
      ProviderScope.containerOf(
        tester.element(find.byType(MasiApp)),
        listen: false,
      );

  /// Percent space -> the global point to touch, derived from what is actually
  /// on screen rather than assumed.
  ///
  /// The photo's DECODED size is the authority here, not the 900x600 that was
  /// declared at import: `TopoCanvas` re-fits to the real decode when it lands
  /// (`_effectiveImageSize`), and in a browser that decode is real. Reading the
  /// size back off the painter — which is the same value the hit-tests use —
  /// means this helper cannot drift from the code it is testing.
  Offset atPercent(WidgetTester tester, double x, double y) {
    final painter =
        tester
                .widgetList<CustomPaint>(
                  find.descendant(
                    of: find.byType(TopoCanvas),
                    matching: find.byType(CustomPaint),
                  ),
                )
                .map((c) => c.painter)
                .whereType<TopoPainter>()
                .first;
    final viewer = tester.widget<InteractiveViewer>(
      find.descendant(
        of: find.byType(TopoCanvas),
        matching: find.byType(InteractiveViewer),
      ),
    );
    final scene = Offset(
      painter.imageSize.width * x,
      painter.imageSize.height * y,
    );
    final local = MatrixUtils.transformPoint(
      viewer.transformationController!.value,
      scene,
    );
    final box = tester.renderObject<RenderBox>(find.byType(TopoCanvas));
    return box.localToGlobal(local);
  }

  testWidgets('a committed route can be reshaped, and the change persists', (
    tester,
  ) async {
    bootApp(overrides: [webAuthGateEnabledProvider.overrideWithValue(false)]);
    await tester.pumpAndSettle(const Duration(seconds: 3));
    await binding.takeScreenshot('geom-00-home');

    // ---------------------------------------------------------------
    // 1. Seed a topo with a photo and one committed route.
    // ---------------------------------------------------------------
    final container = containerOf(tester);
    final crud = container.read(libraryCrudRepositoryProvider);
    final wallId = await crud.createTopo(_wallName);
    final bytes = buildPhotoBytes();
    final photoId = await crud.attachPhotoToWall(
      wallId,
      XFile.fromData(bytes, name: 'geom.jpg', mimeType: 'image/jpeg'),
      900,
      600,
    );
    final repository = container.read(routeRepositoryProvider);
    await repository.upsertRoute(
      wallId,
      photoId,
      const TopoRoute(
        id: 1,
        number: 1,
        points: _seededPoints,
        symbols: [_seededMarker],
        name: 'Seeded',
      ),
    );
    record({'wall_id': wallId, 'photo_id': photoId, 'photo_len': bytes.length});
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // ---------------------------------------------------------------
    // 2. Reach the canvas through the real router, by tapping the topo.
    // ---------------------------------------------------------------
    final row = find.text(_wallName);
    expect(
      row,
      findsWidgets,
      reason: 'the seeded topo never appeared on Topos home',
    );
    await tester.tap(row.first);
    await tester.pumpAndSettle(const Duration(seconds: 3));
    await binding.takeScreenshot('geom-01-canvas');
    expect(
      find.byType(TopoCanvas),
      findsOneWidget,
      reason: 'tapping the topo did not land on the canvas',
    );

    final notifier = container.read(drawControllerProvider(wallId).notifier);
    DrawState state() => container.read(drawControllerProvider(wallId));
    expect(
      state().routes,
      hasLength(1),
      reason: 'the seeded route did not load from browser storage',
    );

    // ---------------------------------------------------------------
    // 3. Draw mode, route selected — the state in which handles appear.
    // ---------------------------------------------------------------
    await tester.tap(find.byKey(const Key('topo-mode-toggle')));
    await tester.pumpAndSettle();
    expect(state().mode, DrawMode.draw);
    notifier.selectRoute(1);
    await tester.pumpAndSettle();
    await binding.takeScreenshot('geom-02-draw-selected');

    // ---------------------------------------------------------------
    // 4. Drag the middle point. Real pointer, real transform.
    // ---------------------------------------------------------------
    final from = atPercent(tester, 0.5, 0.5);
    final to = atPercent(tester, 0.7, 0.35);
    final gesture = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.moveTo(Offset.lerp(from, to, 0.5)!);
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.moveTo(to);
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.up();
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await binding.takeScreenshot('geom-03-point-moved');

    final movedPoint = state().routes.single.points[1];
    record({'moved_point': '${movedPoint.dx},${movedPoint.dy}'});
    expect(
      movedPoint.dx,
      closeTo(0.7, 0.02),
      reason: 'the drag did not reach the committed route in a real browser',
    );
    expect(movedPoint.dy, closeTo(0.35, 0.02));
    expect(
      state().routes.single.points,
      hasLength(3),
      reason: 'a drag must move a point, never add or remove one',
    );

    // ---------------------------------------------------------------
    // 5. The eraser removes the marker it is tapped on.
    // ---------------------------------------------------------------
    expect(state().routes.single.symbols, hasLength(1));
    notifier.setEraserActive(true);
    await tester.pumpAndSettle();
    expect(state().activeTool, DrawTool.eraser);
    expect(
      state().activeSymbol,
      isNull,
      reason: 'the eraser must clear the active symbol, not shadow it',
    );
    await tester.tapAt(atPercent(tester, 0.35, 0.6));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await binding.takeScreenshot('geom-04-marker-erased');
    expect(
      state().routes.single.symbols,
      isEmpty,
      reason: 'the eraser did not remove the marker under it',
    );

    // ---------------------------------------------------------------
    // 6. The part the widget tests cannot reach: is it actually STORED?
    // ---------------------------------------------------------------
    final stored = await repository.loadRoutes(wallId, photoId);
    expect(stored, hasLength(1));
    final storedRoute = stored.single;
    record({
      'stored_points': storedRoute.points
          .map(
            (Offset p) =>
                '${p.dx.toStringAsFixed(3)},${p.dy.toStringAsFixed(3)}',
          )
          .toList(),
      'stored_symbols': storedRoute.symbols.length,
    });
    expect(
      storedRoute.points[1].dx,
      closeTo(0.7, 0.02),
      reason:
          'the moved point never reached browser storage — the canvas would '
          'show the edit until the topo was reopened, and then lose it',
    );
    expect(
      storedRoute.symbols,
      isEmpty,
      reason: 'the erased marker came back from storage',
    );
    expect(
      storedRoute.number,
      1,
      reason:
          "route identity must survive an edit — ascents resolve by number, "
          'so a renumbered route detaches somebody\'s logged climb',
    );
  });
}
