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

// `_GradeBandDots` and `_colorForGradeBand` used to live here. Both moved to
// `shared/presentation/grade_band_dots.dart` as public `GradeBandDots` /
// `gradeBandColor` when the Community feed needed the same dots: it is a
// separate Dart library and cannot reach a `_`-prefixed widget, which is why
// it had been showing a single hardest-grade pill and quietly disagreeing with
// this screen about the same topo's grade span.

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

// (grade-band colour mapping moved to shared/presentation/grade_band_dots.dart
// as the public `gradeBandColor` — see the note above.)
