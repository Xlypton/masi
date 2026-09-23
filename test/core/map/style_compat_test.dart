// Town, lake and river labels printed as the literal text `{name_en}`.
//
// CARTO Positron writes those labels as a legacy zoom function whose stop
// values are token templates, and flutter_map_vector_tiles only expands
// tokens in a plain-string property. These tests run the package's OWN
// ThemeReader over a layer copied verbatim from the live style, so they fail
// if the rewrite stops producing something the renderer reads correctly —
// not merely if it stops producing the JSON written here.
import 'dart:convert';

import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:masi/core/map/basemap_style.dart';
import 'package:masi/core/map/style_compat.dart';

/// `watername_lake`, verbatim from the live Positron style (2026-09-23).
const _lakeLayerJson = '''
{"id":"watername_lake","type":"symbol","source":"carto","source-layer":"water_name","minzoom":4,
 "filter":["all",["has","name"],["==","\$type","Point"],["==","class","lake"]],
 "layout":{"text-field":{"stops":[[8,"{name_en}"],[13,"{name}"]]},"symbol-placement":"point",
   "text-size":{"stops":[[13,9],[14,10],[15,11],[16,12],[17,13]]},
   "text-font":["Montserrat Regular Italic","Open Sans Italic"]},
 "paint":{"text-color":"#7a96a0"}}
''';

Map<String, Object?> _style(List<Object?> layers) => {
  'version': 8,
  'name': 'test',
  'sources': <String, Object?>{},
  'layers': layers,
};

Map<String, Object?> _lakeLayer() =>
    (jsonDecode(_lakeLayerJson) as Map).cast<String, Object?>();

/// The label the renderer would draw for a lake called "Wörthersee"
/// (English "Lake Worth") at [zoom].
String _label(Map<String, Object?> style, double zoom) {
  final theme = const ThemeReader().read(style);
  final layer = theme.layers.whereType<SymbolThemeLayer>().single;
  return layer.textField.eval(
    EvalContext(
      zoom: zoom,
      geometryType: 'Point',
      properties: const {'name': 'Wörthersee', 'name_en': 'Lake Worth'},
    ),
  );
}

void main() {
  group('expandLegacyTokenStops', () {
    test('the bug: unrewritten, the renderer prints the braces', () {
      expect(_label(_style([_lakeLayer()]), 10), '{name_en}');
    });

    test('rewritten, the renderer prints the name for each zoom band', () {
      final fixed = expandLegacyTokenStops(_style([_lakeLayer()]))!;
      expect(_label(fixed, 6), 'Lake Worth', reason: 'below the first stop');
      expect(_label(fixed, 10), 'Lake Worth');
      expect(_label(fixed, 13), 'Wörthersee', reason: 'at the second stop');
      expect(_label(fixed, 16), 'Wörthersee');
    });

    test('the rewritten layer declares both properties it reads, so tile '
        'preparation does not trim them away', () {
      final fixed = expandLegacyTokenStops(_style([_lakeLayer()]))!;
      final layer = const ThemeReader()
          .read(fixed)
          .layers
          .whereType<SymbolThemeLayer>()
          .single;
      expect(layer.referencedProperties, containsAll(['name', 'name_en']));
    });

    test('a feature with no English name gets an empty label, not "null"', () {
      final fixed = expandLegacyTokenStops(_style([_lakeLayer()]))!;
      final layer = const ThemeReader()
          .read(fixed)
          .layers
          .whereType<SymbolThemeLayer>()
          .single;
      final text = layer.textField.eval(
        const EvalContext(
          zoom: 10,
          geometryType: 'Point',
          properties: {'name': 'Faaker See'},
        ),
      );
      expect(text, isEmpty);
    });

    test('a template with literal text becomes a concat', () {
      final fixed = expandLegacyTokenStops(
        _style([
          {
            'id': 'road',
            'type': 'symbol',
            'layout': {
              'text-field': {
                'stops': [
                  [10, '{ref}'],
                  [14, '{name} ({ref})'],
                ],
              },
            },
          },
        ]),
      )!;
      const properties = {'name': 'Tauernautobahn', 'ref': 'A10'};
      final layer = const ThemeReader()
          .read(fixed)
          .layers
          .whereType<SymbolThemeLayer>()
          .single;
      String at(double zoom) =>
          layer.textField.eval(EvalContext(zoom: zoom, properties: properties));
      expect(at(12), 'A10');
      expect(at(15), 'Tauernautobahn (A10)');
    });

    test('leaves everything it does not recognise alone', () {
      final untouched = _style([
        // Already a plain template: the package expands these itself.
        {
          'id': 'a',
          'layout': {'text-field': '{name}'},
        },
        // Numeric stops, no tokens.
        {
          'id': 'b',
          'layout': {
            'text-size': {
              'stops': [
                [13, 9],
                [17, 13],
              ],
            },
          },
        },
        // A property function is keyed on a feature property, not zoom.
        {
          'id': 'c',
          'layout': {
            'text-field': {
              'property': 'class',
              'type': 'categorical',
              'stops': [
                ['lake', '{name}'],
              ],
            },
          },
        },
        // String stops without any token.
        {
          'id': 'd',
          'layout': {
            'text-field': {
              'stops': [
                [8, 'A'],
                [13, 'B'],
              ],
            },
          },
        },
        {'id': 'e', 'type': 'background'},
      ]);
      expect(expandLegacyTokenStops(untouched), isNull);
      expect(expandLegacyTokenStops({'version': 8}), isNull);
    });

    test('is idempotent', () {
      final once = expandLegacyTokenStops(_style([_lakeLayer()]))!;
      expect(expandLegacyTokenStops(once), isNull);
    });
  });

  group('StyleCompatClient', () {
    const styleUrl = 'https://basemaps.example/gl/positron/style.json?key=k';

    http.Client clientServing(Map<String, http.Response> responses) =>
        StyleCompatClient(
          MockClient(
            (request) async =>
                responses[request.url.toString()] ?? http.Response('', 404),
          ),
        );

    test('rewrites the style document it serves', () async {
      final client = clientServing({
        styleUrl: http.Response(jsonEncode(_style([_lakeLayer()])), 200),
      });
      final body = await client.get(Uri.parse(styleUrl));
      final style = (jsonDecode(body.body) as Map).cast<String, Object?>();
      expect(body.statusCode, 200);
      expect(_label(style, 10), 'Lake Worth');
      expect(
        body.contentLength ?? body.bodyBytes.length,
        body.bodyBytes.length,
      );
    });

    test('passes other JSON, other files, and failures through byte for '
        'byte', () async {
      const tileJsonUrl = 'https://basemaps.example/tiles.json';
      const spriteUrl = 'https://basemaps.example/sprite.png';
      const brokenUrl = 'https://basemaps.example/broken.json';
      final tileJson = jsonEncode({
        'tiles': ['https://t/{z}/{x}/{y}.mvt'],
        'vector_layers': <Object?>[],
      });
      final client = clientServing({
        tileJsonUrl: http.Response(tileJson, 200),
        spriteUrl: http.Response.bytes([1, 2, 3], 200),
        brokenUrl: http.Response('{not json', 200),
      });
      expect((await client.get(Uri.parse(tileJsonUrl))).body, tileJson);
      expect((await client.get(Uri.parse(spriteUrl))).bodyBytes, [1, 2, 3]);
      expect((await client.get(Uri.parse(brokenUrl))).body, '{not json');
      expect((await client.get(Uri.parse(styleUrl))).statusCode, 404);
    });
  });

  test('the basemap reads its style through StyleCompatClient', () {
    // The web branch (StyleCompatClient over CachingStyleClient) needs a
    // browser and was verified in one: real town labels on the Map tab.
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(basemapHttpClientProvider), isA<StyleCompatClient>());
  });
}
