import 'dart:ui';

import 'package:flutter/foundation.dart';

/// The kind of marker rendered at a point on a [TopoRoute].
enum SymbolType { anchor, bolt, top, crux, rest }

/// A single marker (e.g. bolt, anchor) placed on a route, in percent space.
@immutable
class TopoSymbol {
  const TopoSymbol({required this.type, required this.position});

  final SymbolType type;
  final Offset position;

  TopoSymbol copyWith({SymbolType? type, Offset? position}) {
    return TopoSymbol(
      type: type ?? this.type,
      position: position ?? this.position,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is TopoSymbol &&
        other.type == type &&
        other.position == position;
  }

  @override
  int get hashCode => Object.hash(type, position);
}

/// An immutable, drawn climbing route: an ordered list of points plus any
/// symbols placed along it, expressed in percent space (coordinates
/// normalized to the image's width/height) so they stay valid regardless of
/// how the image is scaled or panned on screen.
@immutable
class TopoRoute {
  const TopoRoute({
    required this.id,
    required this.number,
    required this.points,
    this.symbols = const [],
    this.colorIndex = 0,
    this.visible = true,
  });

  final int id;
  final int number;
  final List<Offset> points;
  final List<TopoSymbol> symbols;
  final int colorIndex;
  final bool visible;

  TopoRoute copyWith({
    int? id,
    int? number,
    List<Offset>? points,
    List<TopoSymbol>? symbols,
    int? colorIndex,
    bool? visible,
  }) {
    return TopoRoute(
      id: id ?? this.id,
      number: number ?? this.number,
      points: points ?? this.points,
      symbols: symbols ?? this.symbols,
      colorIndex: colorIndex ?? this.colorIndex,
      visible: visible ?? this.visible,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is TopoRoute &&
        other.id == id &&
        other.number == number &&
        listEquals(other.points, points) &&
        listEquals(other.symbols, symbols) &&
        other.colorIndex == colorIndex &&
        other.visible == visible;
  }

  @override
  int get hashCode => Object.hash(
        id,
        number,
        Object.hashAll(points),
        Object.hashAll(symbols),
        colorIndex,
        visible,
      );
}

/// Number of distinct colors in the route palette; route colors cycle
/// through the palette as more routes are added.
const int kRoutePaletteLength = 8;

/// Maps a 1-based route [number] to a stable palette index, wrapping around
/// once the number exceeds [kRoutePaletteLength].
int routeColorIndexFor(int number) => (number - 1) % kRoutePaletteLength;
