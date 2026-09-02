// The basemap's identity: which server, and what it looks like when it gets
// here.
//
// Both halves have already been wrong in production, in ways nothing else
// caught. CARTO went key-only and kept answering 200 with a valid PNG, so the
// only symptom was "API KEY REQUIRED" printed across every tile. The swap to
// OSM fixed the licensing and cost the app its look — saturated greens and
// yellow roads under Masi's purple markers, which the user reported as the map
// being ugly. So this file pins both: no key in the URL, and a filter that
// actually lightens and desaturates rather than merely existing.

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/core/map/basemap.dart';

/// Applies [basemapTint]'s matrix the way the compositor does, so the test
/// reasons about the colours a viewer actually sees.
({int r, int g, int b}) tinted(int r, int g, int b) {
  // ColorFilter has no public accessor for its matrix, so the constants are
  // repeated here on purpose: this test is the SPEC, and a change to the
  // filter has to be a deliberate change to both.
  const matrix = <double>[
    0.19184, 0.39262, 0.03954, 0, 99.0, //
    0.11696, 0.46750, 0.03954, 0, 97.8, //
    0.11696, 0.39262, 0.11442, 0, 101.2, //
    0, 0, 0, 1, 0, //
  ];
  expect(
    basemapTint,
    ColorFilter.matrix(matrix),
    reason: 'the filter and this spec must not drift apart',
  );
  int ch(int row) =>
      (matrix[row * 5] * r +
              matrix[row * 5 + 1] * g +
              matrix[row * 5 + 2] * b +
              matrix[row * 5 + 4])
          .round()
          .clamp(0, 255);
  return (r: ch(0), g: ch(1), b: ch(2));
}

void main() {
  test('the tile URL carries no API key, and is not CARTO', () {
    expect(basemapUrlTemplate, contains('{z}/{x}/{y}'));
    expect(basemapUrlTemplate, isNot(contains('cartocdn')));
    expect(basemapUrlTemplate, isNot(contains('key')));
    expect(basemapUrlTemplate, isNot(contains('api')));
    expect(basemapUrlTemplate, startsWith('https://'));
  });

  test('the credit names OpenStreetMap, which its licence requires', () {
    expect(basemapAttribution, contains('OpenStreetMap'));
  });

  test('white ground stays white — a basemap that greys out its own paper '
      'reads as fog, not as cartography', () {
    final white = tinted(255, 255, 255);
    expect(white.r, 255);
    expect(white.g, 255);
    expect(white.b, 255);
  });

  test('black lifts to a mid grey, so labels and paths stay legible instead '
      'of vanishing into the tint', () {
    final black = tinted(0, 0, 0);
    for (final v in [black.r, black.g, black.b]) {
      expect(v, greaterThan(80), reason: 'lifted off pure black');
      expect(v, lessThan(130), reason: 'but still clearly darker than paper');
    }
  });

  test("OSM's saturated forest green comes out desaturated and pale — the "
      'colour that fought the purple markers hardest', () {
    // #C8E6A0-ish: the standard style's woodland fill.
    final green = tinted(0xC8, 0xE6, 0xA0);
    final spread =
        [green.r, green.g, green.b].reduce((a, b) => a > b ? a : b) -
        [green.r, green.g, green.b].reduce((a, b) => a < b ? a : b);
    expect(
      spread,
      lessThan(24),
      reason: 'a near-neutral has almost no channel spread left',
    );
    expect(
      [green.r, green.g, green.b].reduce((a, b) => a < b ? a : b),
      greaterThan(200),
      reason: 'and it sits up near the paper, not in the midtones',
    );
  });

  test('the tint pulls toward the app\'s own lavender, not toward neutral '
      'grey — this is what makes it Masi\'s map', () {
    // Mid grey in, cool cast out: blue must lead red must lead green, the
    // same ordering as MasiColors.light.amethyst100.
    final grey = tinted(128, 128, 128);
    expect(grey.b, greaterThan(grey.r));
    expect(grey.r, greaterThan(grey.g));
    const lavender = MasiColors.light;
    final tint = lavender.amethyst100;
    expect(
      tint.b > tint.r && tint.r > tint.g,
      isTrue,
      reason: 'the target lavender has that same ordering',
    );
  });
}
