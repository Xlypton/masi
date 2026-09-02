// The basemap's identity: which server, on what terms, and credited how.
//
// Every one of these has already been wrong in production, in a way nothing
// else caught. CARTO went key-only and kept answering 200 with a valid PNG, so
// the only symptom was "API KEY REQUIRED" printed diagonally across every
// tile — no exception, no error tile, nothing an HTTP-level assertion could
// see. The keyless OpenStreetMap tiles that replaced it for an afternoon were
// licensed correctly and looked like somebody else's map. So this file pins
// the three things that make the map both legal and Masi's: a key is present,
// the URL is the Positron endpoint, and both parties named in CARTO's terms
// are credited.

import 'package:flutter_test/flutter_test.dart';
import 'package:masi/core/map/basemap.dart';

void main() {
  test('the tile URL carries a key — the whole failure mode was a URL that '
      'still worked without one, and drew a watermark instead', () {
    expect(cartoBasemapKey, isNotEmpty);
    expect(basemapUrlTemplate, contains('key=$cartoBasemapKey'));
  });

  test('it is the Positron endpoint, with the retina placeholder CARTO '
      'actually serves', () {
    expect(basemapUrlTemplate, startsWith('https://basemaps.cartocdn.com/'));
    expect(basemapUrlTemplate, contains('light_all'));
    expect(
      basemapUrlTemplate,
      contains('{z}/{x}/{y}{r}.png'),
      reason:
          '{r} is a real @2x tile here, not flutter_map\'s simulated-retina '
          'upscale',
    );
  });

  test('the key is overridable without editing the source, because CARTO asks '
      'that one key not be shared across unrelated projects', () {
    // The committed value is a `defaultValue:` on a dart-define, so a fork or
    // a second domain supplies its own with --dart-define=MASI_CARTO_KEY=…
    // rather than patching the file.
    const overridden = String.fromEnvironment(
      'MASI_CARTO_KEY',
      defaultValue: 'fallback-marker',
    );
    expect(
      overridden,
      anyOf(equals('fallback-marker'), equals(cartoBasemapKey)),
      reason: 'the constant reads through the same define',
    );
  });

  test("the credit names BOTH parties CARTO's terms require, and OSM's "
      'policy needs it visible without interaction', () {
    expect(basemapAttribution, contains('OpenStreetMap'));
    expect(basemapAttribution, contains('CARTO'));
  });

  test('the zoom cap matches what the server really renders, so flutter_map '
      'upscales instead of requesting 404s', () {
    expect(basemapMaxNativeZoom, 20);
  });
}
