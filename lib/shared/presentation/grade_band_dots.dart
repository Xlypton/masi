import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/grades/grade_system.dart';

/// Maps a [GradeBand] to its display color using the [MasiColors] grade
/// tokens (never a hard-coded hex — see DESIGN.md's grade-band table, which
/// these tokens mirror).
///
/// Public and shared because this mapping had been copied verbatim into three
/// separate files, each with a comment explaining that it mirrors the others
/// and could not reach them — the Topos home, the Community feed and the
/// logbook are three different Dart libraries, so a `_`-prefixed helper in one
/// is genuinely unreachable from the next. Three copies of a colour table is
/// three chances for the app to disagree with itself about what "hard" looks
/// like.
Color gradeBandColor(MasiColors colors, GradeBand band) {
  switch (band) {
    case GradeBand.beginner:
      return colors.gradeBeginner;
    case GradeBand.intermediate:
      return colors.gradeIntermediate;
    case GradeBand.advanced:
      return colors.gradeAdvanced;
    case GradeBand.hard:
      return colors.gradeHard;
    case GradeBand.elite:
      return colors.gradeElite;
  }
}

/// Row of small colored dots shown in a topo row's subtitle (see DESIGN.md
/// "Topos home"), one per distinct [GradeBand] present across the topo's
/// routes ([bands], already deduplicated and ordered easiest-to-hardest by
/// [gradeBandsFor]) — replaces the old single hardest-grade pill so a topo
/// with, say, both a 5a and a 7a route visibly reads as spanning two bands
/// rather than showing only its hardest. Placed before the "N routes" text;
/// omitted entirely by the caller when a topo has no graded routes.
///
/// Public, and living in `shared/` rather than beside the Topos home, for the
/// same reason [SyncBanner] does: the Community feed is a separate Dart
/// library and cannot reach a library-private widget. It previously showed a
/// single hardest-grade pill instead, so the same topo advertised a different
/// grade span depending on which screen you were looking at.
///
/// [wallId] is only used to key each dot, so a widget test (and the E2E suite)
/// can assert which bands a specific row is claiming rather than counting
/// anonymous circles.
class GradeBandDots extends StatelessWidget {
  const GradeBandDots({super.key, required this.wallId, required this.bands});

  final String wallId;
  final List<GradeBand> bands;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    return Semantics(
      label: 'Grade bands present: ${bands.map((b) => b.name).join(', ')}',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < bands.length; i++)
            Padding(
              padding: EdgeInsets.only(
                right: i == bands.length - 1 ? 0 : MasiSpacing.xs,
              ),
              child: Container(
                key: Key('topo-grade-dot-$wallId-${bands[i].name}'),
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: gradeBandColor(colors, bands[i]),
                  shape: BoxShape.circle,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
