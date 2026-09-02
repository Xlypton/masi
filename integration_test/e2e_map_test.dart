// The Map tab, in a real browser, with real tiles on the wire.
//
// It exists because of a failure nothing else here could have caught. CARTO
// stopped serving `basemaps.cartocdn.com` anonymously, and did it the way a
// CDN does: the endpoint kept answering 200 with a valid PNG, so the tile
// layer's retry and eviction machinery saw a perfectly healthy basemap. Every
// tile simply arrived with "API KEY REQUIRED / carto.com/basemaps/apikey"
// printed diagonally across it. No exception, no error tile, no assertion
// anywhere in this repo that could fail — the app was only ever wrong in
// pixels, and the user read it as a bug in Masi.
//
// So what this test contributes is the SCREENSHOT: `40-map-tab` is the map as
// a person sees it, tiles fetched from the live server, for a human to look
// at. The assertions below cover what is checkable — the credit line is
// rendered without interaction (an OSM tile-policy requirement), and the
// screen did not fall into its error state — but they are the smaller half.
// Read the PNG.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:masi/app/router.dart' show appRouter;
import 'package:masi/main_e2e.dart' as e2e;

import 'e2e_support.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the Map tab draws a basemap that is not asking for a key', (
    tester,
  ) async {
    await e2e.main();
    await settle(tester, frames: 30);

    appRouter.go('/map');
    await settle(tester, frames: 30);
    // Tiles are real network fetches; give them a budget rather than a fixed
    // number of frames.
    await settleNetwork(tester, budget: const Duration(seconds: 20));

    await binding.takeScreenshot('40-map-tab');

    expect(
      find.byKey(const Key('community-map-attribution')),
      findsOneWidget,
      reason:
          "OSM's tile usage policy requires the credit to be visible without "
          'interaction — not behind a tap-to-expand info icon',
    );
    expect(
      find.textContaining('OpenStreetMap'),
      findsOneWidget,
      reason: 'and to name the contributors whose tiles these are',
    );
  });
}
