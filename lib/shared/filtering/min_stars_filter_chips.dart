import 'package:flutter/material.dart';

import 'package:masi/app/theme.dart';
import 'package:masi/shared/presentation/masi_icon.dart';

/// A single-select row of minimum-quality-rating chips (Any / ★+ / ★★+ /
/// ★★★) for filter sheets, screen-agnostic so it's reusable across
/// Topos/Community/Logbook filter UIs. Mirrors [StyleTagFilterChips]'
/// shape, look and controlled contract.
///
/// Purely controlled: [selected] is the current minimum (`null` = "Any",
/// the inactive default), [onChanged] fires with the NEW minimum on every
/// tap — callers own the state (e.g. a filter `Notifier`), this widget
/// holds none itself. Tapping the already-selected chip clears back to
/// "Any", so the facet can be undone without hunting for the Any chip.
///
/// Only 1..3 are offered. A `0` minimum would be satisfied by every
/// explicitly-rated route while still excluding every UNRATED one, which
/// reads as a no-op that mysteriously hides things — see
/// `ToposFilter.minStars`.
///
/// Each chip has key `filter-minstars-<n>` (`filter-minstars-any` for the
/// clear-the-facet chip).
class MinStarsFilterChips extends StatelessWidget {
  const MinStarsFilterChips({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  /// The current minimum star rating (1-3), or `null` for "any rating".
  final int? selected;

  /// Fired with the new minimum (or `null` to clear) on every tap.
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: MasiSpacing.sm,
      runSpacing: MasiSpacing.sm,
      children: [
        _StarsChip(
          key: const Key('filter-minstars-any'),
          stars: 0,
          selected: selected == null,
          onPressed: () => onChanged(null),
        ),
        for (var stars = 1; stars <= 3; stars++)
          _StarsChip(
            key: Key('filter-minstars-$stars'),
            stars: stars,
            selected: selected == stars,
            // Re-tapping the active chip clears the facet.
            onPressed: () => onChanged(selected == stars ? null : stars),
          ),
      ],
    );
  }
}

/// One [MinStarsFilterChips] chip: [stars] filled star glyphs (or the word
/// "Any" when [stars] is 0), in [FilterChoiceChip]'s selected/unselected
/// skin. Not built on [FilterChoiceChip] itself because that widget takes a
/// `String label` and these chips are glyphs, not text — the surface
/// styling is deliberately kept identical by hand.
class _StarsChip extends StatelessWidget {
  const _StarsChip({
    super.key,
    required this.stars,
    required this.selected,
    required this.onPressed,
  });

  final int stars;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final foreground = selected ? colors.accent : colors.ink2;
    return Material(
      color: selected ? colors.accent.withValues(alpha: 0.16) : colors.surface2,
      borderRadius: BorderRadius.circular(MasiRadii.control),
      child: InkWell(
        borderRadius: BorderRadius.circular(MasiRadii.control),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: MasiSpacing.md,
            vertical: MasiSpacing.sm,
          ),
          child: stars == 0
              ? Text(
                  'Any',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: foreground,
                  ),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < stars; i++)
                      MasiIcon('star_fill', size: 15, color: foreground),
                    // "2 stars OR BETTER", not "exactly 2" — without this the
                    // chips read as an exact-match set and a 3-star topo
                    // would look excluded from the 2-star filter.
                    if (stars < 3)
                      Padding(
                        padding: const EdgeInsets.only(left: 2),
                        child: Text(
                          '+',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: foreground,
                          ),
                        ),
                      ),
                  ],
                ),
        ),
      ),
    );
  }
}
