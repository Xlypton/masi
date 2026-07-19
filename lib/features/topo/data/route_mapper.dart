/// JSON (de)serialization and row<->domain mapping for [TopoRoute].
library;

import 'dart:convert';
import 'dart:ui';

import '../../../core/db/app_database.dart' as db;
import '../../../core/grades/grade_system.dart';
import '../../../core/routes/route_styles.dart';
import '../domain/topo_route.dart';

/// Parses a persisted `gradeSystem` column value (the enum's `.name`
/// string) back into a [GradeSystem]. Returns null if [raw] is null or
/// does not match any [GradeSystem] value, rather than throwing — a
/// corrupt/unknown value should degrade to "no grade system" instead of
/// crashing the load.
GradeSystem? _parseGradeSystem(String? raw) {
  if (raw == null) return null;
  for (final system in GradeSystem.values) {
    if (system.name == raw) return system;
  }
  return null;
}

/// Encodes [points] (percent-space coordinates) as a JSON array of
/// `{"x": .., "y": ..}` objects.
String encodePoints(List<Offset> points) {
  return jsonEncode([
    for (final p in points) {'x': p.dx, 'y': p.dy},
  ]);
}

/// Decodes a JSON array produced by [encodePoints] back into a point list.
List<Offset> decodePoints(String json) {
  final decoded = jsonDecode(json) as List<dynamic>;
  return [
    for (final entry in decoded)
      Offset(
        (entry['x'] as num).toDouble(),
        (entry['y'] as num).toDouble(),
      ),
  ];
}

/// Encodes [symbols] as a JSON array of `{"type": .., "x": .., "y": ..}`
/// objects. `type` is the [SymbolType] enum name (see [SymbolType.name]).
String encodeSymbols(List<TopoSymbol> symbols) {
  return jsonEncode([
    for (final s in symbols)
      {'type': s.type.name, 'x': s.position.dx, 'y': s.position.dy},
  ]);
}

/// Decodes a JSON array produced by [encodeSymbols] back into a symbol list.
List<TopoSymbol> decodeSymbols(String json) {
  final decoded = jsonDecode(json) as List<dynamic>;
  return [
    for (final entry in decoded)
      TopoSymbol(
        type: SymbolType.values.byName(entry['type'] as String),
        position: Offset(
          (entry['x'] as num).toDouble(),
          (entry['y'] as num).toDouble(),
        ),
      ),
  ];
}

/// Maps a persisted [db.Route] row to a [TopoRoute] domain object.
///
/// [intId] is the caller-assigned, in-memory sequential id (routes have no
/// stable int id in the database — only a uuid `id` column — so the
/// repository assigns 1..n on every load; see [rowToDomain] callers).
TopoRoute rowToDomain(db.Route row, int intId) {
  return TopoRoute(
    id: intId,
    number: row.number,
    points: decodePoints(row.pointsJson),
    symbols: decodeSymbols(row.symbolsJson),
    colorIndex: row.colorIndex,
    visible: row.visible,
    name: row.name,
    gradeSystem: _parseGradeSystem(row.gradeSystem),
    gradeRaw: row.gradeRaw,
    gradeSortKey: row.gradeSortKey,
    style: row.style,
    description: row.description,
    betaVideoUrl: row.betaVideoUrl,
    styleTags: decodeStyleTags(row.styleTagsJson),
    stars: row.stars,
  );
}
