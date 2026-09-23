/// Rewrites parts of the basemap style that `flutter_map_vector_tiles` reads
/// wrongly, before the package ever sees them.
///
/// There is one such part today, and it was visible to every user: town,
/// village and river labels printed as the literal text `{name_en}`.
///
/// CARTO Positron writes those labels as a legacy zoom function whose stop
/// values are token templates:
///
/// ```json
/// "text-field": {"stops": [[8, "{name_en}"], [13, "{name}"]]}
/// ```
///
/// meaning "the English name up to z13, the local name from there". The
/// package expands `{token}` templates only when the WHOLE property is a
/// string (`ThemeReader._string`); inside a function it hands the stop
/// values to the expression parser as plain literals, so the braces reach
/// the screen.
///
/// The rewrite turns each such function into the modern expression that
/// means the same thing, which the package parses correctly:
///
/// ```json
/// ["step", ["zoom"], ["to-string", ["get", "name_en"]], 13, ["to-string", ["get", "name"]]]
/// ```
///
/// A legacy string function is an INTERVAL function — the first stop's value
/// holds below it too — which is exactly `step`'s semantics.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Layout properties that take legacy `{token}` templates.
const _tokenProperties = {'text-field', 'icon-image'};

final _token = RegExp(r'\{([^{}]+)\}');

/// Returns [style] with every legacy token-template zoom function rewritten
/// as a `step` expression, or `null` when there was nothing to rewrite.
///
/// Anything this does not positively recognise is left untouched: a property
/// function (`"property": …`), a non-interval `type`, a stop value that is
/// not a string. A style it cannot improve reaches the package exactly as
/// the server sent it.
Map<String, Object?>? expandLegacyTokenStops(Map<String, Object?> style) {
  final layers = style['layers'];
  if (layers is! List) return null;
  var changed = false;
  final newLayers = [
    for (final layer in layers)
      if (layer is Map && layer['layout'] is Map)
        () {
          final layout = (layer['layout'] as Map).cast<String, Object?>();
          Map<String, Object?>? newLayout;
          for (final property in _tokenProperties) {
            final rewritten = _stepFromTokenStops(layout[property]);
            if (rewritten == null) continue;
            (newLayout ??= {...layout})[property] = rewritten;
          }
          if (newLayout == null) return layer;
          changed = true;
          return {...layer.cast<String, Object?>(), 'layout': newLayout};
        }()
      else
        layer,
  ];
  if (!changed) return null;
  return {...style, 'layers': newLayers};
}

/// `["step", ["zoom"], v0, z1, v1, …]` for a legacy zoom function whose
/// string stops contain tokens; `null` for anything else.
List<Object?>? _stepFromTokenStops(Object? value) {
  if (value is! Map) return null;
  if (value.containsKey('property')) return null;
  final type = value['type'];
  if (type != null && type != 'interval') return null;
  final stops = value['stops'];
  if (stops is! List || stops.isEmpty) return null;

  final zooms = <num>[];
  final outputs = <String>[];
  for (final stop in stops) {
    if (stop is! List || stop.length != 2) return null;
    final [zoom, output] = stop;
    if (zoom is! num || output is! String) return null;
    zooms.add(zoom);
    outputs.add(output);
  }
  if (!outputs.any(_token.hasMatch)) return null;

  return [
    'step',
    ['zoom'],
    _templateExpression(outputs.first),
    for (var i = 1; i < outputs.length; i++) ...[
      zooms[i],
      _templateExpression(outputs[i]),
    ],
  ];
}

/// A `{token}` template as an expression: a lone token is its property as a
/// string, anything else is a `concat` of literals and properties.
///
/// `to-string` is what makes a missing property read as an empty label
/// rather than the word "null", matching what the legacy template did.
Object? _templateExpression(String template) {
  final matches = _token.allMatches(template).toList();
  if (matches.isEmpty) return template;
  Object? property(RegExpMatch m) => [
    'to-string',
    ['get', m.group(1)],
  ];
  if (matches.length == 1 &&
      matches.first.start == 0 &&
      matches.first.end == template.length) {
    return property(matches.first);
  }
  final parts = <Object?>['concat'];
  var position = 0;
  for (final m in matches) {
    if (m.start > position) parts.add(template.substring(position, m.start));
    parts.add(property(m));
    position = m.end;
  }
  if (position < template.length) parts.add(template.substring(position));
  return parts;
}

/// An HTTP client that applies [expandLegacyTokenStops] to style documents
/// on their way to the package, and passes everything else through.
///
/// It sits OUTSIDE every cache, deliberately. Devices already hold the
/// unrewritten style — for up to 30 days in the web cache — and a rewrite
/// applied before caching would leave those labels broken until each entry
/// expired. Applied on the way out, it fixes a cached copy on the very next
/// read. It is cheap enough to repeat: one small JSON document, once per
/// app run.
class StyleCompatClient extends http.BaseClient {
  StyleCompatClient(this.inner);

  final http.Client inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await inner.send(request);
    if (request.method != 'GET' ||
        response.statusCode != 200 ||
        !request.url.path.endsWith('.json')) {
      return response;
    }
    final bytes = await response.stream.toBytes();
    final rewritten = _rewrite(bytes) ?? bytes;
    return http.StreamedResponse(
      Stream<List<int>>.value(rewritten),
      response.statusCode,
      contentLength: rewritten.length,
      request: request,
      headers: {...response.headers, 'content-length': '${rewritten.length}'},
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  /// The rewritten document, or `null` to serve [bytes] unchanged — which
  /// includes anything that is not a JSON object with a `layers` list
  /// (TileJSON, the sprite index), and anything that fails to parse.
  static Uint8List? _rewrite(Uint8List bytes) {
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    final rewritten = expandLegacyTokenStops(decoded.cast<String, Object?>());
    if (rewritten == null) return null;
    return Uint8List.fromList(utf8.encode(jsonEncode(rewritten)));
  }

  @override
  void close() {
    // Not ours to close — see `CachingStyleClient.close`.
  }
}
