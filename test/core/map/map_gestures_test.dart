// Quick zoom (double-tap, then drag) used to crash the map.
//
// flutter_map's default rule for that gesture scales the zoom change by the
// CURRENT zoom, which the gesture itself keeps changing, and neither map set a
// maxZoom. So the camera ran away: z11 to z74 in half a second and past 10^15
// in two, until the projection math overflowed. Measured in a real browser
// before the fix, and reproduced below with a real gesture through a real
// FlutterMap.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:masi/core/map/map_gestures.dart';

const _startZoom = 11.0;

/// Pumps a bare [FlutterMap] with [options] and returns its controller.
Future<MapController> _pumpMap(WidgetTester tester, MapOptions options) async {
  final controller = MapController();
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: FlutterMap(
        mapController: controller,
        options: options,
        children: const [],
      ),
    ),
  );
  return controller;
}

/// Double-taps and HOLDS at the centre of the screen, drags down [dragPx] in
/// small steps, then keeps holding for [holdFrames] frames, barely moving.
Future<void> _quickZoom(
  WidgetTester tester, {
  required double dragPx,
  int holdFrames = 0,
}) async {
  final centre = tester.getCenter(find.byType(FlutterMap));
  await tester.tapAt(centre);
  await tester.pump(const Duration(milliseconds: 50));
  final gesture = await tester.startGesture(centre);
  await tester.pump(const Duration(milliseconds: 50));
  const steps = 40;
  for (var i = 1; i <= steps; i++) {
    await gesture.moveTo(centre + Offset(0, dragPx * i / steps));
    await tester.pump(const Duration(milliseconds: 16));
  }
  for (var i = 0; i < holdFrames; i++) {
    // A real finger is never perfectly still; each tiny move is another
    // update, and each update re-applies the zoom rule.
    await gesture.moveBy(Offset(0, i.isEven ? 0.5 : -0.5));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  const origin = LatLng(46.6, 13.8);

  testWidgets(
    'the gesture really does run away under flutter_map defaults — the '
    'control that shows the tests below would catch the bug',
    (tester) async {
      final controller = await _pumpMap(
        tester,
        const MapOptions(initialCenter: origin, initialZoom: _startZoom),
      );
      await _quickZoom(tester, dragPx: 500, holdFrames: 60);
      expect(controller.camera.zoom, greaterThan(1000));
    },
  );

  testWidgets('with the shared options, a long quick-zoom hold never passes '
      'kMapMaxZoom', (tester) async {
    final controller = await _pumpMap(
      tester,
      const MapOptions(
        initialCenter: origin,
        initialZoom: _startZoom,
        minZoom: kMapMinZoom,
        maxZoom: kMapMaxZoom,
        interactionOptions: masiMapInteractionOptions,
      ),
    );
    await _quickZoom(tester, dragPx: 1500, holdFrames: 120);
    expect(tester.takeException(), isNull);
    expect(controller.camera.zoom, kMapMaxZoom);
  });

  testWidgets(
    'quick zoom moves one level per kQuickZoomPixelsPerLevel, however long '
    'the finger is held',
    (tester) async {
      final controller = await _pumpMap(
        tester,
        const MapOptions(
          initialCenter: origin,
          initialZoom: _startZoom,
          minZoom: kMapMinZoom,
          maxZoom: kMapMaxZoom,
          interactionOptions: masiMapInteractionOptions,
        ),
      );
      await _quickZoom(
        tester,
        dragPx: 3 * kQuickZoomPixelsPerLevel,
        holdFrames: 60,
      );
      // The gesture only engages once the drag passes the scale slop, so the
      // few pixels before that are not counted; the rest are exact.
      expect(controller.camera.zoom, closeTo(_startZoom + 3, 0.25));
    },
  );

  testWidgets('dragging up zooms out, and stops at kMapMinZoom', (
    tester,
  ) async {
    final controller = await _pumpMap(
      tester,
      const MapOptions(
        initialCenter: origin,
        initialZoom: 3,
        minZoom: kMapMinZoom,
        maxZoom: kMapMaxZoom,
        interactionOptions: masiMapInteractionOptions,
      ),
    );
    await _quickZoom(tester, dragPx: -350);
    expect(controller.camera.zoom, kMapMinZoom);
  });

  test('the quick-zoom change does not depend on the current zoom', () {
    MapCamera cameraAt(double zoom) => MapCamera(
      crs: const Epsg3857(),
      center: origin,
      zoom: zoom,
      rotation: 0,
      nonRotatedSize: const Size(400, 800),
    );
    expect(
      quickZoomChange(-250, cameraAt(3)),
      quickZoomChange(-250, cameraAt(18)),
    );
    expect(quickZoomChange(-kQuickZoomPixelsPerLevel, cameraAt(11)), -1);
  });

  test(
    'the shared options keep rotation off and every pan/zoom gesture on',
    () {
      final flags = masiMapInteractionOptions.flags;
      expect(InteractiveFlag.hasRotate(flags), isFalse);
      expect(InteractiveFlag.hasDrag(flags), isTrue);
      expect(InteractiveFlag.hasFlingAnimation(flags), isTrue);
      expect(InteractiveFlag.hasPinchMove(flags), isTrue);
      expect(InteractiveFlag.hasPinchZoom(flags), isTrue);
      expect(InteractiveFlag.hasDoubleTapZoom(flags), isTrue);
      expect(InteractiveFlag.hasDoubleTapDragZoom(flags), isTrue);
      expect(InteractiveFlag.hasScrollWheelZoom(flags), isTrue);
      expect(
        masiMapInteractionOptions.doubleTapDragZoomChangeCalculator,
        same(quickZoomChange),
      );
    },
  );
}
