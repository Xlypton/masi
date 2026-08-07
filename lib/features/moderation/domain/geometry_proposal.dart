/// A proposed climbing line, as it travels between a suggester and an owner
/// (community editing phase 7b / C-5b).
library;

import 'dart:ui';

import '../../topo/domain/topo_route.dart';

/// The most points a proposed line may carry, mirroring
/// `public.geometry_patch_error`. Two limits that disagree would mean a line
/// the canvas happily lets someone draw and the server then refuses, after
/// the work is done.
const int kMaxProposedPoints = 200;

/// The most markers a proposed line may carry. Same mirroring.
const int kMaxProposedSymbols = 64;

/// Points and markers in PERCENT SPACE — fractions of the photo's width and
/// height, exactly as [TopoRoute] stores them.
///
/// That normalisation is the reason a proposal is meaningless without the
/// photo it was drawn on, and the reason `topo_edit_suggestions."photoId"`
/// exists (§C-5b): `(0.4, 0.7)` names a hold on one image and a patch of sky
/// on another.
class GeometryProposal {
  const GeometryProposal({required this.points, this.symbols});

  final List<Offset> points;

  /// The markers along the line, or NULL when the proposal says nothing about
  /// them — which is different from an empty list, and the difference is a
  /// data-loss bug if collapsed.
  ///
  /// Phase 7b's canvas proposes a LINE and offers no way to place bolts or
  /// anchors. If "no markers proposed" arrived as `[]`, accepting a corrected
  /// line would wipe every bolt the owner had placed on that route, silently,
  /// as a side effect of fixing its shape. Null means leave them exactly as
  /// they are; an empty list would mean "remove them all", which nothing in
  /// this phase can express and nothing should.
  final List<TopoSymbol>? symbols;

  /// Two points make a line. One is a tap, and renders as a dot nobody reads
  /// as a route — the server refuses it too.
  bool get isDrawable => points.length >= 2;

  Map<String, Object?> toPatch() => {
    'points': [
      for (final p in points) {'x': p.dx, 'y': p.dy},
    ],
    if (symbols case final list?)
      'symbols': [
        for (final s in list)
          {'type': s.type.name, 'x': s.position.dx, 'y': s.position.dy},
      ],
  };

  /// Reads a stored patch, or returns null if it cannot be drawn.
  ///
  /// Null rather than a partial line, deliberately. A geometry suggestion the
  /// owner cannot see is one they cannot judge, and offering an "Apply" button
  /// over a half-decoded line would write points nobody reviewed.
  ///
  /// An unrecognised marker TYPE is the one thing dropped rather than
  /// refused — `route_mapper.decodeSymbols` does the same for stored routes,
  /// and for the same reason: it is what lets a topo survive a marker type
  /// that no longer exists in the app.
  static GeometryProposal? fromPatch(Map<String, Object?> patch) {
    final rawPoints = patch['points'];
    if (rawPoints is! List || rawPoints.length < 2) return null;
    if (rawPoints.length > kMaxProposedPoints) return null;

    final points = <Offset>[];
    for (final entry in rawPoints) {
      final point = _offset(entry);
      if (point == null) return null;
      points.add(point);
    }

    final rawSymbols = patch['symbols'];
    if (rawSymbols == null) {
      // The key is absent: this proposal says nothing about markers, and the
      // owner's stay untouched. See [symbols].
      return GeometryProposal(points: points);
    }
    if (rawSymbols is! List) return null;
    if (rawSymbols.length > kMaxProposedSymbols) return null;

    final symbols = <TopoSymbol>[];
    for (final entry in rawSymbols) {
      if (entry is! Map) return null;
      final position = _offset(entry);
      final type = _symbolType(entry['type']);
      if (position == null) return null;
      if (type == null) continue;
      symbols.add(TopoSymbol(type: type, position: position));
    }

    return GeometryProposal(points: points, symbols: symbols);
  }

  /// A point is only usable if it lands ON the photo. Out-of-range values
  /// would paint outside the image and, once applied, become a route with a
  /// leg going nowhere.
  static Offset? _offset(Object? entry) {
    if (entry is! Map) return null;
    final x = _asDouble(entry['x']);
    final y = _asDouble(entry['y']);
    if (x == null || y == null) return null;
    if (x < 0 || x > 1 || y < 0 || y > 1) return null;
    return Offset(x, y);
  }

  static double? _asDouble(Object? value) => switch (value) {
    final double v => v,
    final num v => v.toDouble(),
    final String v => double.tryParse(v),
    _ => null,
  };

  static SymbolType? _symbolType(Object? raw) {
    if (raw is! String) return null;
    for (final type in SymbolType.values) {
      if (type.name == raw) return type;
    }
    return null;
  }
}
