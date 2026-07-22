import 'package:flutter/material.dart';

import 'package:masi/app/theme.dart';

/// The style filter options offered by [StyleFilterChips], in display
/// order: `(value, label)` where `value` is the raw string stored on a
/// route (see `TopoRoute.style`) and `label` is the human-readable chip
/// text.
const List<(String value, String label)> styleFilterOptions = [
  ('sport', 'Sport'),
  ('trad', 'Trad'),
  ('boulder', 'Boulder'),
];

/// A multi-select row of style chips (Sport/Trad/Boulder) for filter
/// sheets, screen-agnostic so it's reusable across Community/Logbook/Topos
/// filter UIs.
///
/// Purely controlled: [selected] is the current chosen set, [onChanged]
/// fires with the NEW set on every tap (toggle semantics) -- callers own
/// the state (e.g. a filter `Notifier`), this widget holds none itself.
///
/// Each chip has key `filter-style-<value>` (e.g. `filter-style-sport`).
class StyleFilterChips extends StatelessWidget {
  const StyleFilterChips({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  /// The currently-selected style values (a subset of
  /// [styleFilterOptions]'s `value`s).
  final Set<String> selected;

  /// Fired with the full new selected set whenever a chip is toggled.
  final ValueChanged<Set<String>> onChanged;

  void _toggle(String value) {
    final next = Set<String>.from(selected);
    if (!next.remove(value)) next.add(value);
    onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: MasiSpacing.sm,
      runSpacing: MasiSpacing.sm,
      children: [
        for (final (value, label) in styleFilterOptions)
          FilterChoiceChip(
            key: Key('filter-style-$value'),
            label: label,
            selected: selected.contains(value),
            onPressed: () => _toggle(value),
          ),
      ],
    );
  }
}

/// A selectable chip: `accent`-tinted wash when selected, `surface2`
/// otherwise -- matches `RouteMetadataSheet`'s private `_StyleChip` look
/// (that widget is private to its own file, so this replicates rather than
/// imports it; see this package's other filter-chip widgets, which share
/// this same look via this widget).
class FilterChoiceChip extends StatelessWidget {
  const FilterChoiceChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
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
          child: Text(
            label,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: selected ? colors.accent : colors.ink2,
            ),
          ),
        ),
      ),
    );
  }
}
