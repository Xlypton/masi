// Quick zoom (double-tap, then drag) on the Map tab, in a real browser, with
// the real vector basemap.
//
// flutter_map's default quick-zoom rule scales each step by the CURRENT zoom,
// so the steps grow as the gesture goes on, and the Map tab set no maxZoom.
// Measured here before the fix: a 350px drag took the camera from z11 to z74
// in half a second, and holding it went past 10^15 in two, with the map blank
// the whole way until the projection math overflowed.
//
// `test/core/map/map_gestures_test.dart` drives the real gesture in a widget
// test. Synthesized pointer events do not reach the map through this harness,
// so this file replays the gesture's zoom sequence through the map's own
// controller instead: the same path the gesture's result takes. What only a
// browser can show is the screenshot: the basemap still draws at the zoom
// the camera now stops at.

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:masi/app/router.dart' show appRouter;
import 'package:masi/core/map/map_gestures.dart';
import 'package:masi/main_e2e.dart' as e2e;

import 'e2e_support.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a long quick-zoom drag stops at kMapMaxZoom and still draws', (
    tester,
  ) async {
    await e2e.main();
    await settle(tester, frames: 30);
    appRouter.go('/map');
    await settle(tester, frames: 30);
    await settleNetwork(tester, budget: const Duration(seconds: 10));

    final inMap = find.byType(MarkerLayer).first;
    final controller = MapController.of(tester.element(inMap));
    MapCamera camera() => MapCamera.of(tester.element(inMap));

    // flutter_map's DEFAULT rule, on purpose: the fix has to hold even if a
    // future screen forgets `masiMapInteractionOptions`, as long as the
    // limits are set. A 500px drag, held for about two seconds.
    final start = camera().zoom;
    final zooms = <double>[start];
    for (var i = 1; i <= 120; i++) {
      final offset = -500.0 * (i > 30 ? 1 : i / 30);
      controller.move(camera().center, start - camera().zoom * offset / 360);
      await tester.pump(const Duration(milliseconds: 16));
      zooms.add(camera().zoom);
    }
    (binding.reportData ??= {})['zooms'] = [
      for (final z in zooms) z.toStringAsFixed(3),
    ];

    await settleNetwork(tester, budget: const Duration(seconds: 8));
    await binding.takeScreenshot('45-map-quick-zoom-max');

    expect(tester.takeException(), isNull);
    expect(zooms.reduce((a, b) => a > b ? a : b), kMapMaxZoom);
    expect(camera().zoom, kMapMaxZoom);
    expect(find.byKey(const Key('basemap-vector-layer')), findsOneWidget);
  });
}
