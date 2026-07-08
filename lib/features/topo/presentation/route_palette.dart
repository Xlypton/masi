import 'package:flutter/material.dart';

import 'package:climbtopo/features/topo/domain/topo_route.dart';

/// The visually-distinct stroke colors used for committed routes, indexed
/// by [TopoRoute.colorIndex] (see [routeColorIndexFor]).
///
/// Length is exactly [kRoutePaletteLength] so every valid `colorIndex`
/// (`0 <= colorIndex < kRoutePaletteLength`) maps to a color here without
/// wrapping; [TopoPainter] additionally wraps via `%` and falls back to a
/// hardcoded default if an empty palette is ever passed, so this list is
/// the single source of truth for both the canvas painter and the route
/// legend's color swatches.
const List<Color> kRoutePalette = [
  Color(0xFFE53935), // red
  Color(0xFF1E88E5), // blue
  Color(0xFF43A047), // green
  Color(0xFFFB8C00), // orange
  Color(0xFF8E24AA), // purple
  Color(0xFF00ACC1), // cyan
  Color(0xFFF9A825), // amber
  Color(0xFF6D4C41), // brown
];
