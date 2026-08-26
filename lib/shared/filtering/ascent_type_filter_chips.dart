import 'package:flutter/material.dart';

import 'package:masi/app/theme.dart';
import 'package:masi/features/logbook/data/ascents_repository.dart';
import 'package:masi/features/logbook/presentation/logbook_screen.dart'
    show styleLabel;
import 'package:masi/shared/filtering/style_filter_chips.dart' show FilterChoiceChip;

/// Display label for an [AscentStyle] on a filter chip.
///
/// Delegates to the logbook's [styleLabel] rather than capitalizing
/// [AscentStyle.name] itself, which is what this used to do. Those two agreed
/// for the original five styles purely by luck — every one of them happened to
/// be its own label — and diverged the moment `send` was added, whose label is
/// "Sent". A filter chip reading "Send" next to logbook rows reading "Sent" is
/// the same thing under two names, so there is now exactly one function that
/// decides. Same cross-feature import `community_feed_screen.dart` and
/// `ascent_detail_screen.dart` already use for this symbol.
String ascentStyleLabel(AscentStyle style) => styleLabel(style);

/// A multi-select row of ascent-type chips (Sent/Onsight/Flash/Redpoint/
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
