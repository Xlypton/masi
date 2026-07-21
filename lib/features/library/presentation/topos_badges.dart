part of 'topos_screen.dart';

/// Compact badge marking a Topos-home row as a nearby COMMUNITY topo (not
/// one of this device's own) -- the Topos-home-side counterpart of
/// `community_screen.dart`'s `_OwnBadge` (which marks the reverse case, an
/// own topo shown inside the Community feed).
class _CommunitySharedBadge extends StatelessWidget {
  const _CommunitySharedBadge({required this.wallId});

  final String wallId;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;

    return Semantics(
      label: 'Shared by the community',
      child: Container(
        key: Key('topo-shared-badge-$wallId'),
        padding: const EdgeInsets.symmetric(
          horizontal: MasiSpacing.xs,
          vertical: 2,
        ),
        decoration: BoxDecoration(
          color: colors.surface2,
          borderRadius: BorderRadius.circular(MasiRadii.control),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            MasiIcon('compass', size: 12, color: colors.ink3),
            const SizedBox(width: 2),
            Flexible(
              child: Text(
                'Shared',
                style: textTheme.labelSmall?.copyWith(
                  color: colors.ink3,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Row of small colored dots shown in a topo row's subtitle (see DESIGN.md
/// "Topos home"), one per distinct [GradeBand] present across the topo's
/// routes ([bands], already deduplicated and ordered easiest-to-hardest by
/// [gradeBandsFor]) -- replaces the old single hardest-grade pill so a topo
/// with, say, both a 5a and a 7a route visibly reads as spanning two bands
/// rather than showing only its hardest. Placed before the "N routes" text;
/// omitted entirely by the caller when a topo has no graded routes.
class _GradeBandDots extends StatelessWidget {
  const _GradeBandDots({required this.wallId, required this.bands});

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
                  color: _colorForGradeBand(colors, bands[i]),
                  shape: BoxShape.circle,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Compact badge marking a topo row's publish state — "Published" (accent
/// fill) for a topo shared to Community, or a muted "Private" otherwise —
/// so the Topos home reads as a clear division between community-visible
/// and owner-only topos. Placed inside the row's grade/route-count [Wrap]
/// (rather than the trailing icon cluster) so it wraps safely alongside
/// them at large text scales instead of widening the [Row] and risking the
/// overflow this row was JUST fixed for; text stays a single short word
/// with a matching icon, never flexible.
class _VisibilityBadge extends StatelessWidget {
  const _VisibilityBadge({required this.wallId, required this.isShared});

  final String wallId;
  final bool isShared;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final label = isShared ? 'Published' : 'Private';
    // `ink2` (not `ink3`) for the Private variant: `ink3` read as
    // low-contrast against `surface2` (DESIGN.md review) -- `ink2` is the
    // same tone every other secondary-metadata piece in this row (route
    // count, distance) already uses.
    final foreground = isShared ? colors.onAccent : colors.ink2;
    final background = isShared ? colors.accent : colors.surface2;

    return Semantics(
      label: isShared ? 'Published to Community' : 'Private, not shared',
      child: Container(
        key: Key('topo-visibility-badge-$wallId'),
        padding: const EdgeInsets.symmetric(
          horizontal: MasiSpacing.xs,
          vertical: 2,
        ),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(MasiRadii.control),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            MasiIcon(
              isShared ? 'globe' : 'lock',
              size: 12,
              color: foreground,
            ),
            const SizedBox(width: 2),
            // `Flexible` (not a bare `Text`) is required here: a `Row`
            // gives non-flexible children an UNBOUNDED main-axis
            // constraint, so without it `maxLines`/`overflow: ellipsis`
            // never engage and the badge overflows its `Wrap` slot at
            // large text scales (regression -- see the "AppBar Organize
            // action + _TopoRow" test this badge sits alongside).
            Flexible(
              child: Text(
                label,
                style: textTheme.labelSmall?.copyWith(
                  color: foreground,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Maps a [GradeBand] to its display color using the [MasiColors] grade
/// tokens (never a hard-coded hex — see DESIGN.md's grade-band table, which
/// these tokens mirror).
Color _colorForGradeBand(MasiColors colors, GradeBand band) {
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
