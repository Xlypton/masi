import 'package:flutter/material.dart'
    show
        BorderRadius,
        BoxDecoration,
        BuildContext,
        CircleAvatar,
        Color,
        Container,
        EdgeInsets,
        FontWeight,
        StatelessWidget,
        Text,
        TextOverflow,
        Theme,
        Widget;

import 'package:masi/app/theme.dart' show MasiRadii;
import 'package:masi/core/grades/grade_system.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
import 'package:masi/features/topo/presentation/route_palette.dart';

/// Stroke/swatch color for [GradeBand.beginner].
const Color _beginnerColor = Color(0xFF2F9E6B); // green

/// Stroke/swatch color for [GradeBand.intermediate].
const Color _intermediateColor = Color(0xFF3B82C4); // blue

/// Stroke/swatch color for [GradeBand.advanced].
const Color _advancedColor = Color(0xFFE08A2B); // orange

/// Stroke/swatch color for [GradeBand.hard].
const Color _hardColor = Color(0xFFD6483B); // red

/// Stroke/swatch color for [GradeBand.elite].
const Color _eliteColor = Color(0xFF8A5CD1); // purple

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

/// The shared/feed-surface hardness-signal dot: a small filled circle,
/// visually identical to [RouteLegend]'s own leading
/// `CircleAvatar(backgroundColor: color, radius: 8)` swatch, so a route's
/// grade band reads the same way everywhere it's shown — not just on the
/// owner's own topo.
///
/// Deliberately a dumb "paint this color" widget rather than one that takes
/// a [TopoRoute]/[GradeBand] itself: callers resolve their own color first
/// ([colorForRoute] when a full [TopoRoute] — and its ungraded/palette
/// fallback — is available, [colorForGradeBand] when only a [GradeBand] is
/// known, e.g. a feed/ascent-log entry with no `TopoRoute.colorIndex` to
/// fall back to), so this widget never needs its own copy of either
/// resolution's logic.
class GradeBandDot extends StatelessWidget {
  const GradeBandDot({super.key, required this.color, this.radius = 8});

  /// The resolved swatch color — see the class doc for how callers get one.
  final Color color;

  /// Matches [RouteLegend]'s own swatch radius by default; callers in a
  /// tighter layout (e.g. inline beside a text run) may pass a smaller value.
  final double radius;

  @override
  Widget build(BuildContext context) =>
      CircleAvatar(backgroundColor: color, radius: radius);
}

/// The grade itself, set in white on its band's color — for the surfaces
/// where a row is about ONE route with ONE grade.
///
/// This is the shape `community_feed_screen.dart`'s deleted `_GradePill` had,
/// brought back by request (2026-08-11: "I liked the white number in coloured
/// square version for the grade in case of an ascent better") and made public
/// so it lives beside [GradeBandDot] and [colorForGradeBand] rather than as a
/// third private copy of the band-colour convention.
///
/// **When to use which.** The pill and the dot are not interchangeable, and
/// the distinction is what got `_GradePill` deleted from the TOPO row in the
/// first place: a topo spans many routes, so a single pill there could only
/// show the hardest one and made a 5a–7a wall call itself "7a". A dot per
/// band present says the true thing in that case. An ASCENT is one route on
/// one day at one grade — there is no span to flatten — so the pill states it
/// outright instead of making the reader decode a colour.
class GradeBandPill extends StatelessWidget {
  const GradeBandPill({super.key, required this.label, required this.color});

  /// The grade as it should read, e.g. `'6b'` — already formatted by the
  /// caller in whatever system that surface displays.
  final String label;

  /// The band colour behind it — [colorForGradeBand]. White-on-band is fixed
  /// (every band colour in this file is dark enough to carry white text), so
  /// there is no foreground parameter to get wrong.
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(MasiRadii.control),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: const Color(0xFFFFFFFF),
          fontWeight: FontWeight.w600,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
