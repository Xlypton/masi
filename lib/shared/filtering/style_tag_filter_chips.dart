import 'package:flutter/material.dart';

import 'package:masi/app/theme.dart';
import 'package:masi/core/routes/route_styles.dart';

import 'style_filter_chips.dart';

/// A multi-select row of style-TAG chips (Dyno/Crimpy/Juggy/... — the
/// curated set in [kCuratedRouteStyles]) for filter sheets, screen-agnostic
/// so it's reusable across Community/Logbook/Topos filter UIs. Mirrors
/// [StyleFilterChips]'s shape and look, but for the newer multi-tag facet
/// (`Routes.styleTagsJson` / `SharedTopo.routeStyleTags` /
/// `CommunityFilter.styleTags`) rather than the older single-value
/// sport/trad/boulder `style` facet that [StyleFilterChips] renders.
///
/// Purely controlled: [selected] is the current chosen set of style-tag
/// `key`s, [onChanged] fires with the NEW set on every tap (toggle
/// semantics) — callers own the state (e.g. a filter `Notifier`), this
/// widget holds none itself.
///
/// Each chip has key `filter-styletag-<key>` (e.g. `filter-styletag-dyno`).
class StyleTagFilterChips extends StatelessWidget {
  const StyleTagFilterChips({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  /// The currently-selected style-tag keys (a subset of
  /// [kCuratedRouteStyles]'s `key`s).
  final Set<String> selected;

  /// Fired with the full new selected set whenever a chip is toggled.
  final ValueChanged<Set<String>> onChanged;

  void _toggle(String key) {
    final next = Set<String>.from(selected);
    if (!next.remove(key)) next.add(key);
    onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: MasiSpacing.sm,
      runSpacing: MasiSpacing.sm,
      children: [
        for (final style in kCuratedRouteStyles)
          FilterChoiceChip(
            key: Key('filter-styletag-${style.key}'),
            label: style.label,
            selected: selected.contains(style.key),
            onPressed: () => _toggle(style.key),
          ),
      ],
    );
  }
}
