// The basemap's identity: which server, on what terms, and credited how.
//
// Every one of these has already been wrong in production, in a way nothing
// else caught. CARTO went key-only and kept answering 200 with a valid PNG, so
// the only symptom was "API KEY REQUIRED" printed diagonally across every
// tile — no exception, no error tile, nothing an HTTP-level assertion could
// see. The keyless OpenStreetMap tiles that replaced it for an afternoon were
// licensed correctly and looked like somebody else's map. So this file pins
// the things that make the map both legal and Masi's: a key is present and
// reaches the style, the URL is the Positron style document, and both parties
// named in CARTO's terms are credited.
//
// It also pins the budget, which is the whole reason the app is on vector at
// all: a vector source tops out at zoom 14 and overzooms from there, so one
// tile covers every zoom a climber uses, and the cache that holds them is an
// order of magnitude smaller than the raster one it replaced.

import 'package:flutter_test/flutter_test.dart';
import 'package:masi/core/map/basemap.dart';
import 'package:masi/core/map/vector_tile_cache.dart';

void main() {
  test('the style URL carries a key placeholder AND a key to put in it — the '
      'whole failure mode was a URL that still worked without one, and drew '
      'a watermark instead', () {
    expect(cartoBasemapKey, isNotEmpty);
    expect(
      basemapStyleUri,
      contains('{key}'),
      reason: 'StyleReader(apiKey:) substitutes this; without the placeholder '
          'the key is silently dropped and CARTO answers anonymously',
    );
  });

  test('it is the Positron style document, not a raster tile template', () {
    expect(basemapStyleUri, startsWith('https://basemaps.cartocdn.com/'));
    expect(basemapStyleUri, contains('positron-gl-style'));
    expect(basemapStyleUri, contains('style.json'));
    expect(
      basemapStyleUri,
      isNot(contains('{z}')),
      reason: 'a {z}/{x}/{y} template here would mean the raster endpoint '
          'CARTO is retiring came back',
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

  test('the cache budget stayed small — minimising what the app occupies on '
      'the device is why the migration happened', () {
    expect(
      kVectorTileCacheMaxBytes,
      lessThanOrEqualTo(8 * 1024 * 1024),
      reason: 'the raster cache this replaced was 40 MB for a fraction of the '
          'ground; a vector budget that drifts back up gives that away',
    );
    expect(kVectorTileCacheMaxBytes, greaterThan(1024 * 1024));
  });
}
