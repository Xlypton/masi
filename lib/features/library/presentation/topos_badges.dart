part of 'topos_screen.dart';

/// Compact badge marking a Topos-home row as a nearby COMMUNITY topo (not
/// one of this device's own) -- the Topos-home-side counterpart of
/// `community_screen.dart`'s `_OwnBadge` (which marks the reverse case, an
/// own topo shown inside the Community feed).
///
/// **It says "Community" (or the owner's name), never "Shared"** — the owner's
/// decision, option B. Before this, ONE screen used the word "Shared" for three
/// different things at once: this badge (somebody else's topo), the
/// [_VisibilityBadge]'s own-topo state, and the Filters sheet's
/// All/Shared/Private visibility segment. Three distinct facts now get three
/// distinct words:
///
/// * [_VisibilityBadge] says **Published** / **Private** about your own topo;
/// * this badge says **Community** (or the owner's name) about everybody
///   else's;
/// * the Filters sheet's visibility segment says **Published** — the SAME word
///   as the badge, because it selects exactly the rows that badge marks.
///
/// That last one lagged the other two for a while, and the mismatch was
/// user-visible: filtering by *Shared* returned rows badged *Published*.
/// `topos_filter.dart`'s `_VisibilitySegmented` now carries the badge's word,
/// and `topos_filter_wording_test.dart` asserts the two strings are equal so
/// they cannot drift apart again. Only the LABELS were reconciled — the
/// `ToposVisibilityFilter.shared` enum value and the stored
/// `walls.visibility == 'shared'` are untouched.
///
/// [ownerName] upgrades that to the owner's actual display name when it has
/// ALREADY been resolved — `profileDisplayNameProvider` is a live Drift watch
/// over the locally-synced `profiles` row (the same door
/// `community_feed_screen.dart`'s `_FeedRow` and `comment_row.dart` use), so
/// reading it here adds a local subscription and NOT a fetch. Unresolved (no
/// `ownerId` at all, no profile row pulled yet, a blank name) all collapse back
/// to "Community": a raw uid must never render, and a badge that flickers
/// through a placeholder is worse than one that is simply generic.
class _CommunitySharedBadge extends StatelessWidget {
  const _CommunitySharedBadge({required this.wallId, this.ownerName});

  final String wallId;

  /// The owner's resolved `profiles.displayName`, or null for "not resolved".
  final String? ownerName;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;

    final trimmed = ownerName?.trim();
    final named = trimmed != null && trimmed.isNotEmpty;
    final label = named ? trimmed : 'Community';

    return Semantics(
      label: named ? 'Shared by $trimmed' : 'Shared by the community',
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
        // A display name is user-supplied and can be arbitrarily long, unlike
        // the fixed word this badge used to carry, so cap it: `Flexible` below
        // only ellipsizes against the enclosing `Wrap`'s full width, which on a
        // phone is the whole row. 160 keeps the badge a badge.
        constraints: const BoxConstraints(maxWidth: 160),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            MasiIcon('compass', size: 12, color: colors.ink3),
            const SizedBox(width: 2),
            Flexible(
              child: Text(
                label,
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
class _VisibilityBadge extends ConsumerWidget {
  const _VisibilityBadge({required this.wallId, required this.isShared});

  final String wallId;

  /// The owner's own `visibility` flag — "I have shared this" — which since
  /// community editing phase 3 is no longer the same thing as "people can see
  /// this". [isShared] decides whether to consult moderation at all; the
  /// moderation state decides what the badge then says.
  final bool isShared;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;

    // Watched only for a shared topo. A private one has nothing to ask about,
    // and a family stream per private row would be pure cost.
    final view = isShared
        ? ref.watch(wallModerationViewProvider(wallId)).asData?.value
        : null;
    final style = _VisibilityBadgeStyle.of(isShared: isShared, view: view);

    // `ink2` (not `ink3`) for the Private variant: `ink3` read as
    // low-contrast against `surface2` (DESIGN.md review) -- `ink2` is the
    // same tone every other secondary-metadata piece in this row (route
    // count, distance) already uses.
    final foreground = switch (style.tone) {
      _BadgeTone.live => colors.onAccent,
      _BadgeTone.problem => colors.onAccent,
      _BadgeTone.quiet => colors.ink2,
    };
    final background = switch (style.tone) {
      _BadgeTone.live => colors.accent,
      _BadgeTone.problem => colors.gradeHard,
      _BadgeTone.quiet => colors.surface2,
    };

    return Semantics(
      label: style.semantics,
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
            MasiIcon(style.icon, size: 12, color: foreground),
            const SizedBox(width: 2),
            // `Flexible` (not a bare `Text`) is required here: a `Row`
            // gives non-flexible children an UNBOUNDED main-axis
            // constraint, so without it `maxLines`/`overflow: ellipsis`
            // never engage and the badge overflows its `Wrap` slot at
            // large text scales (regression -- see the "AppBar Organize
            // action + _TopoRow" test this badge sits alongside).
            Flexible(
              child: Text(
                style.label,
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

enum _BadgeTone { live, problem, quiet }

/// What [_VisibilityBadge] says, split out from the widget so the mapping from
/// moderation state to words is testable on its own and cannot drift from the
/// enum it switches over.
class _VisibilityBadgeStyle {
  const _VisibilityBadgeStyle({
    required this.label,
    required this.icon,
    required this.tone,
    required this.semantics,
  });

  final String label;
  final String icon;
  final _BadgeTone tone;
  final String semantics;

  /// Deliberate default when [view] is null or its state is unknown: keep
  /// saying "Published" for a shared topo, exactly as this badge did before
  /// moderation existed.
  ///
  /// The moderation mirror is a pull-only cache and can legitimately be empty
  /// — a cold start, an offline session, a topo whose row this account is not
  /// allowed to read. Rendering "In review" or "Withdrawn" off missing
  /// information would tell the owner something alarming and false about their
  /// own topo. Under-reporting a transitional state for a few seconds is the
  /// cheap failure; inventing one is not. Note this is the opposite direction
  /// from `ModerationState.fromWire`'s fail-closed default, and for the same
  /// underlying reason: there, the risk is exposing unreviewed content, so the
  /// safe answer is the least public one; here, nothing is exposed either way
  /// and the risk is purely misinforming the owner.
  factory _VisibilityBadgeStyle.of({
    required bool isShared,
    required ModerationView? view,
  }) {
    if (!isShared) {
      return const _VisibilityBadgeStyle(
        label: 'Private',
        icon: 'lock',
        tone: _BadgeTone.quiet,
        semantics: 'Private, not shared',
      );
    }
    if (view != null && view.isWithdrawing) {
      final days = view.daysRemaining;
      return _VisibilityBadgeStyle(
        label: 'Withdrawing',
        icon: 'warning',
        tone: _BadgeTone.problem,
        semantics: days == null
            ? 'Being withdrawn from Community'
            : 'Being withdrawn from Community in $days '
                  'day${days == 1 ? '' : 's'}',
      );
    }
    return switch (view?.effectiveState) {
      ModerationState.pending => const _VisibilityBadgeStyle(
        label: 'In review',
        icon: 'sync',
        tone: _BadgeTone.quiet,
        semantics: 'Submitted, waiting for review',
      ),
      ModerationState.rejected => const _VisibilityBadgeStyle(
        label: 'Not approved',
        icon: 'warning',
        tone: _BadgeTone.problem,
        semantics: 'Not approved by a moderator',
      ),
      ModerationState.withdrawn => const _VisibilityBadgeStyle(
        label: 'Withdrawn',
        icon: 'eye_off',
        tone: _BadgeTone.quiet,
        semantics: 'Withdrawn from Community',
      ),
      ModerationState.removed => const _VisibilityBadgeStyle(
        label: 'Removed',
        icon: 'warning',
        tone: _BadgeTone.problem,
        semantics: 'Removed from Community by a moderator',
      ),
      _ => const _VisibilityBadgeStyle(
        label: 'Published',
        icon: 'globe',
        tone: _BadgeTone.live,
        semantics: 'Published to Community',
      ),
    };
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
