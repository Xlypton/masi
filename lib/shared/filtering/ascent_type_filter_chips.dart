import 'package:flutter/material.dart';

import 'package:climbtopo/app/theme.dart';
import 'package:climbtopo/features/logbook/data/ascents_repository.dart';
import 'package:climbtopo/shared/filtering/style_filter_chips.dart' show FilterChoiceChip;

/// Capitalizes an [AscentStyle]'s `name` for display (e.g. `onsight` ->
/// `Onsight`, `redpoint` -> `Redpoint`).
String ascentStyleLabel(AscentStyle style) {
  final name = style.name;
  return '${name[0].toUpperCase()}${name.substring(1)}';
}

/// A multi-select row of ascent-type chips (Onsight/Flash/Redpoint/
/// Repeat/Attempt) for the Logbook filter sheet. Same controlled contract
/// as [StyleFilterChips] (from `style_filter_chips.dart`): [selected] is
/// the current chosen set, [onChanged] fires with the NEW set on every
/// tap; this widget holds no state of its own.
///
/// Each chip has key `filter-ascent-<name>` (e.g. `filter-ascent-onsight`,
/// using [AscentStyle.name]).
class AscentTypeFilterChips extends StatelessWidget {
  const AscentTypeFilterChips({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  /// The currently-selected ascent styles.
  final Set<AscentStyle> selected;

  /// Fired with the full new selected set whenever a chip is toggled.
  final ValueChanged<Set<AscentStyle>> onChanged;

  void _toggle(AscentStyle style) {
    final next = Set<AscentStyle>.from(selected);
    if (!next.remove(style)) next.add(style);
    onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: MasiSpacing.sm,
      runSpacing: MasiSpacing.sm,
      children: [
        for (final style in AscentStyle.values)
          FilterChoiceChip(
            key: Key('filter-ascent-${style.name}'),
            label: ascentStyleLabel(style),
            selected: selected.contains(style),
            onPressed: () => _toggle(style),
          ),
      ],
    );
  }
}
