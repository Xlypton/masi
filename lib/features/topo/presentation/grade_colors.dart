import 'package:flutter/painting.dart' show Color;

import 'package:climbtopo/core/grades/grade_system.dart';
import 'package:climbtopo/features/topo/domain/topo_route.dart';
import 'package:climbtopo/features/topo/presentation/route_palette.dart';

/// Stroke/swatch color for [GradeBand.beginner].
const Color _beginnerColor = Color(0xFF43A047); // green

/// Stroke/swatch color for [GradeBand.intermediate].
const Color _intermediateColor = Color(0xFF1E88E5); // blue

/// Stroke/swatch color for [GradeBand.advanced].
const Color _advancedColor = Color(0xFFFB8C00); // orange

/// Stroke/swatch color for [GradeBand.hard].
const Color _hardColor = Color(0xFFE53935); // red

/// Stroke/swatch color for [GradeBand.elite].
const Color _eliteColor = Color(0xFF8E24AA); // purple

/// Fallback color used by [colorForRoute] when a route has no grade AND an
/// empty palette is passed in (mirrors `TopoPainter`'s own empty-palette
/// fallback).
const Color _defaultRouteColor = Color(0xFF2E7D32);

/// Maps a coarse difficulty [band] to its display color.
///
/// Plain [Color] literals (not `MaterialColor`s) are used so equality
/// comparisons in tests (and [TopoPainter]'s `Paint.color` checks) stay
/// exact rather than tripping over `MaterialColor`'s swatch-vs-primary
/// distinction.
Color colorForGradeBand(GradeBand band) {
  switch (band) {
    case GradeBand.beginner:
      return _beginnerColor;
    case GradeBand.intermediate:
      return _intermediateColor;
    case GradeBand.advanced:
      return _advancedColor;
    case GradeBand.hard:
      return _hardColor;
    case GradeBand.elite:
      return _eliteColor;
  }
}

/// The display color for [route]: if it has been graded (i.e.
/// [TopoRoute.gradeSortKey] is non-null), the color of its [GradeBand] (see
/// [colorForGradeBand]); otherwise the [palette] color at its
/// [TopoRoute.colorIndex] (wrapping via `%`, same convention as
/// `TopoPainter`), or [_defaultRouteColor] if [palette] is empty.
Color colorForRoute(TopoRoute route, List<Color> palette) {
  final sortKey = route.gradeSortKey;
  if (sortKey != null) {
    return colorForGradeBand(bandForSortKey(sortKey));
  }
  if (palette.isEmpty) return _defaultRouteColor;
  return palette[route.colorIndex % palette.length];
}

/// [colorForRoute] pinned to [kRoutePalette], for use as a
/// [TopoPainter.routeColorResolver].
///
/// Deliberately a stable top-level function (not a fresh closure built per
/// build, e.g. `(route) => colorForRoute(route, kRoutePalette)` inlined at
/// the call site) so `TopoPainter.shouldRepaint`'s `routeColorResolver !=
/// oldDelegate.routeColorResolver` reference check stays stable across
/// rebuilds: a top-level function tears off to the same identical value
/// every time, whereas a closure literal would be a new instance on every
/// build, forcing a repaint every frame.
Color topoRouteColor(TopoRoute route) => colorForRoute(route, kRoutePalette);
