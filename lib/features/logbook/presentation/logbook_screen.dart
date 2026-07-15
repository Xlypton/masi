import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../core/grades/grade_system.dart';
import '../../../shared/filtering/ascent_type_filter_chips.dart';
import '../../../shared/filtering/grade_range_picker.dart';
import '../../../shared/filtering/style_filter_chips.dart';
import '../application/ascents_providers.dart';
import '../data/ascents_repository.dart';
import 'logbook_providers.dart';

/// The personal Logbook screen (see `CLIMBTOPO.md`): every own, non-deleted
/// `Ascent` the signed-in (or local, signed-out) user has logged, newest
/// [LogbookEntry.climbedAt] first — see [logbookEntriesProvider].
///
/// A plain [ConsumerWidget]: unlike `ToposScreen`, there is no
/// re-entrancy-guarded creation flow here, only a live list + a per-row
/// delete action, so no local widget state is needed.
class LogbookScreen extends ConsumerWidget {
  const LogbookScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncEntries = ref.watch(logbookEntriesProvider);
    final filter = ref.watch(logbookFilterProvider);
    return Scaffold(
      key: const Key('logbook-screen'),
      appBar: AppBar(
        title: Text(
          'Logbook',
          style: Theme.of(context).textTheme.displaySmall,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        centerTitle: false,
        actions: [
          IconButton(
            key: const Key('logbook-filter-button'),
            tooltip: 'Filters',
            icon: _FilterIcon(active: filter.isActive),
            onPressed: () => _openFilterSheet(context),
          ),
        ],
      ),
      body: SafeArea(
        child: asyncEntries.when(
          data: (entries) {
            if (entries.isEmpty) {
              return const _EmptyState();
            }
            final filtered = [
              for (final entry in entries)
                if (filter.matches(entry)) entry,
            ];
            if (filtered.isEmpty) {
              return const _FilteredEmptyState();
            }
            return _LogbookList(entries: filtered);
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stackTrace) => Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Something went wrong: $error'),
                const SizedBox(height: 8),
                ElevatedButton(
                  key: const Key('logbook-retry'),
                  onPressed: () => ref.invalidate(logbookEntriesProvider),
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openFilterSheet(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _LogbookFilterSheet(),
    );
  }
}

/// The `Icons.tune` filter-bar-chart icon, with a small accent-colored dot
/// (keyed `logbook-filter-active-indicator`) overlaid when [active] — the
/// Logbook screen's visual cue that at least one filter facet is currently
/// narrowing the list.
class _FilterIcon extends StatelessWidget {
  const _FilterIcon({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        const Icon(Icons.tune),
        if (active)
          Positioned(
            right: -2,
            top: -2,
            child: Container(
              key: const Key('logbook-filter-active-indicator'),
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: colors.accent,
                shape: BoxShape.circle,
              ),
            ),
          ),
      ],
    );
  }
}

/// The Logbook's Filters bottom sheet: [GradeRangePicker] + [StyleFilterChips]
/// + [AscentTypeFilterChips], each wired straight to [logbookFilterProvider],
/// plus a Clear action that resets every facet back to inactive. Purely a
/// thin view over that Notifier — it holds no state of its own, so every
/// interaction updates the provider immediately and (via `LogbookScreen`'s
/// `ref.watch`) the underlying list re-filters live while this sheet is
/// still open.
class _LogbookFilterSheet extends ConsumerWidget {
  const _LogbookFilterSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(logbookFilterProvider);
    final notifier = ref.read(logbookFilterProvider.notifier);
    return Padding(
      key: const Key('logbook-filter-sheet'),
      padding: EdgeInsets.only(
        left: MasiSpacing.lg,
        right: MasiSpacing.lg,
        top: MasiSpacing.lg,
        bottom: MediaQuery.viewInsetsOf(context).bottom + MasiSpacing.lg,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    'Filters',
                    style: Theme.of(context).textTheme.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  key: const Key('logbook-filter-clear'),
                  onPressed: notifier.clear,
                  child: const Text('Clear'),
                ),
              ],
            ),
            const SizedBox(height: MasiSpacing.md),
            GradeRangePicker(value: filter.grade, onChanged: notifier.setGrade),
            const SizedBox(height: MasiSpacing.md),
            const _SheetSectionLabel('Route style'),
            const SizedBox(height: MasiSpacing.sm),
            StyleFilterChips(
              selected: filter.routeStyles,
              onChanged: notifier.setRouteStyles,
            ),
            const SizedBox(height: MasiSpacing.md),
            const _SheetSectionLabel('Ascent type'),
            const SizedBox(height: MasiSpacing.sm),
            AscentTypeFilterChips(
              selected: filter.ascentTypes,
              onChanged: notifier.setAscentTypes,
            ),
          ],
        ),
      ),
    );
  }
}

/// A small section-header label used above each filter facet in
/// [_LogbookFilterSheet] (e.g. "Route style", "Ascent type").
class _SheetSectionLabel extends StatelessWidget {
  const _SheetSectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    return Text(
      label,
      style: Theme.of(
        context,
      ).textTheme.titleSmall?.copyWith(color: colors.ink2),
    );
  }
}

/// Shown instead of [_LogbookList]/[_EmptyState] when the Logbook has
/// ascents but the current [LogbookFilter] excludes all of them — distinct
/// from [_EmptyState] (which means there is nothing logged at all) so the
/// user isn't told to go log a climb when they actually just need to loosen
/// a filter.
class _FilteredEmptyState extends StatelessWidget {
  const _FilteredEmptyState();

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    return Center(
      key: const Key('logbook-filtered-empty'),
      child: Text(
        'No ascents match your filters',
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(color: colors.ink2),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    return Center(
      key: const Key('logbook-empty'),
      child: Text(
        'No ascents logged yet',
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(color: colors.ink2),
      ),
    );
  }
}

class _LogbookList extends StatelessWidget {
  const _LogbookList({required this.entries});

  final List<LogbookEntry> entries;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(
        horizontal: MasiSpacing.lg,
        vertical: MasiSpacing.md,
      ),
      itemCount: entries.length,
      separatorBuilder: (context, index) =>
          const SizedBox(height: MasiSpacing.sm),
      itemBuilder: (context, index) => _LogbookRow(entry: entries[index]),
    );
  }
}

class _LogbookRow extends ConsumerWidget {
  const _LogbookRow({required this.entry});

  final LogbookEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final routeName = entry.routeName;
    final title = (routeName != null && routeName.isNotEmpty)
        ? routeName
        : 'Route ${entry.routeNumber ?? '?'}';

    return Material(
      key: Key('logbook-entry-${entry.ascentId}'),
      color: colors.surface,
      borderRadius: BorderRadius.circular(MasiRadii.card),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: MasiSpacing.md,
          vertical: MasiSpacing.sm,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _GradeSwatch(band: entry.gradeBand),
            const SizedBox(width: MasiSpacing.md),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          style: textTheme.titleMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (entry.gradeLabel != null) ...[
                        const SizedBox(width: MasiSpacing.xs),
                        Text(
                          entry.gradeLabel!,
                          style: textTheme.titleSmall?.copyWith(
                            color: colors.ink2,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    entry.wallName,
                    style: textTheme.bodySmall?.copyWith(color: colors.ink2),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${_styleLabel(entry.style)} · '
                    '${_formatDate(entry.climbedAt)}',
                    style: textTheme.titleSmall?.copyWith(color: colors.ink3),
                  ),
                ],
              ),
            ),
            IconButton(
              key: Key('logbook-entry-delete-${entry.ascentId}'),
              icon: Icon(Icons.delete_outline, color: colors.ink3),
              tooltip: 'Delete',
              onPressed: () => _handleDelete(context, ref, entry),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleDelete(
    BuildContext context,
    WidgetRef ref,
    LogbookEntry entry,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete ascent?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: Key('logbook-entry-delete-confirm-${entry.ascentId}'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(ascentsRepositoryProvider).softDeleteAscent(
        entry.ascentId,
      );
    }
  }
}

/// Small rounded grade-band swatch, colored via the [MasiColors] grade
/// tokens (never a hard-coded hex — mirrors `ToposScreen`'s `_GradePill`
/// convention, per DESIGN.md's grade-band table). A `null` [band] (the
/// route has no grade set) renders a neutral placeholder fill.
class _GradeSwatch extends StatelessWidget {
  const _GradeSwatch({required this.band});

  final GradeBand? band;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final gradeBand = band;
    final color = gradeBand == null
        ? colors.surface2
        : _colorForGradeBand(colors, gradeBand);
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(MasiRadii.control),
      ),
    );
  }
}

/// Maps a [GradeBand] to its display color using the [MasiColors] grade
/// tokens. Mirrors `ToposScreen`'s private `_colorForGradeBand` helper
/// (not reused directly: that one is library-private to `topos_screen.dart`).
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

/// Human-readable label for an [AscentStyle], e.g. `AscentStyle.onsight` ->
/// `'Onsight'`.
String _styleLabel(AscentStyle style) {
  switch (style) {
    case AscentStyle.onsight:
      return 'Onsight';
    case AscentStyle.flash:
      return 'Flash';
    case AscentStyle.redpoint:
      return 'Redpoint';
    case AscentStyle.repeat:
      return 'Repeat';
    case AscentStyle.attempt:
      return 'Attempt';
  }
}

const List<String> _monthAbbreviations = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// Formats [date] as e.g. `'Jul 1, 2026'`. Hand-rolled (rather than pulling
/// in `package:intl`, which this project does not currently depend on) since
/// the Logbook only needs one fixed, locale-agnostic display format.
String _formatDate(DateTime date) =>
    '${_monthAbbreviations[date.month - 1]} ${date.day}, ${date.year}';
