import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:masi/app/theme.dart';
import 'package:masi/core/grades/grade_system.dart';
import 'package:masi/shared/filtering/grade_range.dart';
import 'package:masi/shared/presentation/masi_icon.dart';

/// A grade-system toggle plus min/max grade dropdowns for filter sheets,
/// screen-agnostic so it's reusable across Community/Logbook/Topos filter
/// UIs. Visually mirrors `RouteMetadataSheet`'s grade-system segmented
/// control and grade dropdown (that file's widgets are private, so this
/// replicates the MasiColors/MasiSpacing/MasiRadii styling rather than
/// importing them).
///
/// Purely controlled, like [StyleFilterChips]/[AscentTypeFilterChips]:
/// [value] is the current [GradeRange], [onChanged] fires with the new
/// value on every interaction; this widget holds no state of its own.
///
/// Behavior:
/// - Switching [GradeSystem] resets both bounds to null (rather than
///   remapping a token from one ladder onto the other) -- the two
///   ladders' tokens aren't 1:1, so silently carrying a French token over
///   while showing UIAA options (or vice versa) would either display a
///   stale value the new dropdown doesn't offer, or require a lossy
///   nearest-match remap. Resetting is the simplest, least-surprising
///   choice; revisit if a screen ever wants system-preserving remap.
/// - Picking a min grade harder than the current max grade bumps the max
///   up to match it (and symmetrically, picking a max grade easier than
///   the current min bumps the min down to match) -- this picker never
///   lets the user create an inverted range through its own UI (though
///   [GradeRange] itself still tolerates and normalizes one -- see its
///   class doc).
///
/// Keys: `filter-grade-system` (the segmented toggle; its two options are
/// individually keyed `filter-grade-system-french` /
/// `filter-grade-system-uiaa`), `filter-grade-min` and `filter-grade-max`
/// (the two dropdowns, each offering an "Any" option that clears the
/// corresponding bound).
class GradeRangePicker extends StatelessWidget {
  const GradeRangePicker({super.key, required this.value, required this.onChanged});

  final GradeRange value;
  final ValueChanged<GradeRange> onChanged;

  void _onSystemChanged(GradeSystem system) {
    if (system == value.system) return;
    onChanged(GradeRange(system: system));
  }

  void _onMinChanged(String? token) {
    final maxKey = value.maxKey;
    final tokenKey = token == null ? null : gradeSortKey(value.system, token);
    // If the newly-picked min is harder than the current max, bump the max
    // up to match rather than allowing an inverted range.
    final nextMax = (token != null && maxKey != null && tokenKey! > maxKey)
        ? token
        : value.maxToken;
    onChanged(value.copyWith(minToken: token, maxToken: nextMax));
  }

  void _onMaxChanged(String? token) {
    final minKey = value.minKey;
    final tokenKey = token == null ? null : gradeSortKey(value.system, token);
    // If the newly-picked max is easier than the current min, bump the min
    // down to match rather than allowing an inverted range.
    final nextMin = (token != null && minKey != null && tokenKey! < minKey)
        ? token
        : value.minToken;
    onChanged(value.copyWith(minToken: nextMin, maxToken: token));
  }

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final options = gradeOptions(value.system);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CupertinoSlidingSegmentedControl<GradeSystem>(
          key: const Key('filter-grade-system'),
          groupValue: value.system,
          backgroundColor: colors.surface2,
          thumbColor: colors.accent,
          children: {
            GradeSystem.french: _SegmentLabel(
              key: const Key('filter-grade-system-french'),
              label: 'French',
              selected: value.system == GradeSystem.french,
              colors: colors,
            ),
            GradeSystem.uiaa: _SegmentLabel(
              key: const Key('filter-grade-system-uiaa'),
              label: 'UIAA',
              selected: value.system == GradeSystem.uiaa,
              colors: colors,
            ),
          },
          onValueChanged: (system) {
            if (system != null) _onSystemChanged(system);
          },
        ),
        const SizedBox(height: MasiSpacing.sm),
        Row(
          children: [
            Expanded(
              child: _GradeBoundField(
                fieldKey: const Key('filter-grade-min'),
                label: 'Min',
                colors: colors,
                value: value.minToken,
                options: options,
                onChanged: _onMinChanged,
              ),
            ),
            const SizedBox(width: MasiSpacing.sm),
            Expanded(
              child: _GradeBoundField(
                fieldKey: const Key('filter-grade-max'),
                label: 'Max',
                colors: colors,
                value: value.maxToken,
                options: options,
                onChanged: _onMaxChanged,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// A label used inside [CupertinoSlidingSegmentedControl]'s `children` map
/// for the grade-system (French/UIAA) chooser, carrying the caller-supplied
/// [Key] so tests/callers can target each segment directly.
class _SegmentLabel extends StatelessWidget {
  const _SegmentLabel({
    super.key,
    required this.label,
    required this.selected,
    required this.colors,
  });

  final String label;
  final bool selected;
  final MasiColors colors;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        vertical: MasiSpacing.xs,
        horizontal: MasiSpacing.sm,
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: selected ? colors.onAccent : colors.ink2,
        ),
      ),
    );
  }
}

/// A field label + [DropdownButton] over [options] (a grade ladder), with
/// a leading "Any" entry (value null) that clears the bound.
class _GradeBoundField extends StatelessWidget {
  const _GradeBoundField({
    required this.fieldKey,
    required this.label,
    required this.colors,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final Key fieldKey;
  final String label;
  final MasiColors colors;
  final String? value;
  final List<String> options;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          label,
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w400, color: colors.ink2),
        ),
        const SizedBox(height: MasiSpacing.xs),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: MasiSpacing.md),
          decoration: BoxDecoration(
            color: colors.surface2,
            borderRadius: BorderRadius.circular(MasiRadii.control),
            border: Border.all(color: colors.separator),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String?>(
              key: fieldKey,
              isExpanded: true,
              value: value,
              dropdownColor: colors.surface,
              icon: MasiIcon('chevron_down', size: 16, color: colors.ink2),
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w400, color: colors.ink),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('Any')),
                for (final option in options)
                  DropdownMenuItem<String?>(value: option, child: Text(option)),
              ],
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    );
  }
}
