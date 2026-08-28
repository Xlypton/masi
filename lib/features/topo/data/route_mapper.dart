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

/// Looks up [name] in [SymbolType.values] by [SymbolType.name], returning
/// null instead of throwing when there is no match — unlike
/// [Iterable.byName]. Used by [decodeSymbols] so a legacy persisted symbol
/// type that no longer exists in the enum (e.g. the removed `'rest'`) is
/// silently dropped rather than crashing the load of an old topo.
SymbolType? _symbolTypeByNameOrNull(String name) {
  for (final type in SymbolType.values) {
    if (type.name == name) return type;
  }
  return null;
}

/// Decodes a JSON array produced by [encodeSymbols] back into a symbol list.
///
/// Defensive against legacy persisted data: any entry whose `'type'` is not
/// a current [SymbolType] name (e.g. a pre-existing route whose
/// `symbolsJson` still contains a now-removed type like the old `'rest'`
/// marker) is silently dropped rather than thrown on, so an old topo still
/// loads with its remaining, still-valid symbols intact.
List<TopoSymbol> decodeSymbols(String json) {
  final decoded = jsonDecode(json) as List<dynamic>;
  return [
    for (final entry in decoded)
      if (_symbolTypeByNameOrNull(entry['type'] as String) != null)
        TopoSymbol(
          type: _symbolTypeByNameOrNull(entry['type'] as String)!,
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
/// [lineOverride], when given, supplies the geometry INSTEAD of the row's
/// own: the same climb drawn on a different photo of the same rock (see
/// `RouteLines`). Everything else — name, grade, stars, tags — still comes
/// from the climb, which is the entire point of the split. The same rock from
/// 90 degrees round is a different shape, and it is still the same climb.
TopoRoute rowToDomain(db.Route row, int intId, {db.RouteLine? lineOverride}) {
  return TopoRoute(
    id: intId,
    number: row.number,
    points: decodePoints(lineOverride?.pointsJson ?? row.pointsJson),
    symbols: decodeSymbols(lineOverride?.symbolsJson ?? row.symbolsJson),
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
