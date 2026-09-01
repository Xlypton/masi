import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../app/web_back_button.dart';
import '../../../core/grades/grade_system.dart';
import '../../topo/presentation/grade_colors.dart' show colorForGradeBand;
import '../../../shared/filtering/ascent_type_filter_chips.dart';
import '../../../shared/filtering/grade_range_picker.dart';
import '../../../shared/filtering/style_filter_chips.dart';
import '../../../shared/presentation/bottom_safe_inset.dart';
import '../../../shared/presentation/masi_async_view.dart';
import '../../../shared/presentation/masi_dialogs.dart';
import '../../../shared/presentation/masi_icon.dart';
import '../../../shared/presentation/masi_toast.dart';
import '../../../shared/presentation/masi_loading_indicator.dart';
import '../../../shared/presentation/masi_skeleton.dart';
import '../application/ascents_providers.dart';
import '../data/ascents_repository.dart';
import 'logbook_providers.dart';

/// The personal Logbook screen (see `MASI.md`): every own, non-deleted
/// `Ascent` the signed-in (or local, signed-out) user has logged, newest
/// [LogbookEntry.climbedAt] first — see [logbookEntriesProvider].
///
/// A plain [ConsumerWidget]: unlike `ToposScreen`, there is no
/// re-entrancy-guarded creation flow here, only a live list + a per-row
/// delete action, so no local widget state is needed.
class LogbookScreen extends ConsumerWidget {
  const LogbookScreen({super.key, this.isWeb});

  /// Forces [webBackLeading]'s web branch in a widget test — see that
  /// function's doc. `null` (the default, used by the real route) keeps the
  /// real compile-time `kIsWeb`.
  final bool? isWeb;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncEntries = ref.watch(logbookEntriesProvider);
    final filter = ref.watch(logbookFilterProvider);
    return Scaffold(
      key: const Key('logbook-screen'),
      appBar: AppBar(
        leading: webBackLeading(context, isWeb: isWeb),
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
        child: MasiAsyncView<List<LogbookEntry>>(
          value: asyncEntries,
          onRetry: () => ref.invalidate(logbookEntriesProvider),
          errorMessage: "Couldn't load your logbook",
          // The real rows are `_LogbookRow`s — a 40 px grade swatch, a
          // title/wall/style stack and a trailing icon — which is exactly
          // `MasiSkeletonListRow`'s shape, inset with the same padding
          // `_LogbookList` uses so nothing shifts when the data lands.
          skeleton: (context) => const MasiSkeletonList.listRows(
            padding: EdgeInsets.symmetric(
              horizontal: MasiSpacing.lg,
              vertical: MasiSpacing.md,
            ),
          ),
          data: (context, entries) {
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

/// The filter icon — `filter_active` (with dot baked in) when [active],
/// plain `filter` otherwise. The Logbook screen's visual cue that at least
/// one filter facet is currently narrowing the list.
class _FilterIcon extends StatelessWidget {
  const _FilterIcon({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    return MasiIcon(active ? 'filter_active' : 'filter', color: colors.accent);
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
        // max, not +: keyboard inset vs. the standalone-PWA home-indicator
        // floor are alternatives, not a sum — this sheet has no text field
        // today, but the filter chips can gain a search field later, so
        // this stays correct rather than merely currently-correct.
        bottom:
            math.max(
              MediaQuery.viewInsetsOf(context).bottom,
              masiBottomInset(context, ref),
            ) +
            MasiSpacing.lg,
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
class _FilteredEmptyState extends ConsumerWidget {
  const _FilteredEmptyState();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MasiColors.of(context);
    // A scrollable (rather than a bare Center) so this — icon + heading +
    // Clear-filters button — doesn't hard-overflow at a small viewport
    // combined with a large text scale (regression guard: see the
    // "layout overflow regression" group in logbook_screen_test.dart,
    // which pumps this screen behind an open Filters sheet at 360x500
    // @2.5x scale).
    return Center(
      key: const Key('logbook-filtered-empty'),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MasiIcon('filter', size: 40, color: colors.ink3),
            const SizedBox(height: MasiSpacing.md),
            Text(
              'No ascents match your filters',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(color: colors.ink2),
            ),
            const SizedBox(height: MasiSpacing.sm),
            TextButton(
              key: const Key('logbook-filtered-empty-clear'),
              onPressed: ref.read(logbookFilterProvider.notifier).clear,
              child: const Text('Clear filters'),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    // See the matching comment in `_FilteredEmptyState.build` — same
    // scrollable guard against the same class of overflow.
    return Center(
      key: const Key('logbook-empty'),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MasiIcon('logbook', size: 40, color: colors.ink3),
            const SizedBox(height: MasiSpacing.md),
            Text(
              'No ascents logged yet',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(color: colors.ink2),
            ),
            const SizedBox(height: MasiSpacing.sm),
            Text(
              'Log a climb from any route to see it here',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: colors.ink3),
            ),
          ],
        ),
      ),
    );
  }
}

class _LogbookList extends ConsumerWidget {
  const _LogbookList({required this.entries});

  final List<LogbookEntry> entries;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView.separated(
      // `body: SafeArea(...)` on the parent Scaffold already consumes the
      // real device inset (default `bottom: true`), so a standalone iOS
      // PWA (device inset 0) leaves the last row flush on the home
      // indicator with nothing reserving the floor. `masiBottomInset`'s
      // device term reads 0 in this already-consumed subtree, so adding it
      // to the existing `vertical: md` bottom only ever contributes the
      // floor — it never double-counts a real device inset.
      padding: EdgeInsets.fromLTRB(
        MasiSpacing.lg,
        MasiSpacing.md,
        MasiSpacing.lg,
        MasiSpacing.md + masiBottomInset(context, ref),
      ),
      itemCount: entries.length,
      separatorBuilder: (context, index) =>
          const SizedBox(height: MasiSpacing.sm),
      itemBuilder: (context, index) => _LogbookRow(entry: entries[index]),
    );
  }
}

/// One Logbook row.
///
/// Stateful only because of [_deleting]: the delete action awaits a repo write
/// (and, once sync catches up, a network round-trip), and before this the row
/// gave no sign it was working — the trailing bin stayed tappable and the row
/// just silently vanished whenever the write happened to land.
class _LogbookRow extends ConsumerStatefulWidget {
  const _LogbookRow({required this.entry});

  final LogbookEntry entry;

  @override
  ConsumerState<_LogbookRow> createState() => _LogbookRowState();
}

class _LogbookRowState extends ConsumerState<_LogbookRow> {
  /// True from the confirmed delete until the soft-delete write settles. Also
  /// the re-entrancy guard: while it is up the bin is disabled, so a second
  /// tap can't fire `softDeleteAscent` twice.
  bool _deleting = false;

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
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
                        Flexible(
                          child: Text(
                            entry.gradeLabel!,
                            style: textTheme.titleSmall?.copyWith(
                              color: colors.ink2,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
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
                    '${styleLabel(entry.style)} · '
                    '${_formatDate(entry.climbedAt)}',
                    style: textTheme.titleSmall?.copyWith(color: colors.ink2),
                  ),
                ],
              ),
            ),
            IconButton(
              key: Key('logbook-entry-delete-${entry.ascentId}'),
              // The cue replaces the bin in the SAME slot. The 20 px inline
              // arc is 4 px smaller than the 24 px glyph, but IconButton's
              // fixed 48×48 box absorbs that, so the row does not reflow.
              icon: MasiLoadingIndicator.inline(
                isLoading: _deleting,
                child: MasiIcon('delete', color: colors.ink3),
              ),
              tooltip: 'Delete',
              onPressed: _deleting ? null : () => _handleDelete(entry),
            ),
          ],
        ),
      ),
    );
  }

  /// Uses `State.context` rather than taking one — the confirm dialog and the
  /// failure snackbar both straddle awaits, and only a `State.context` can be
  /// guarded by this class's own `mounted`.
  Future<void> _handleDelete(LogbookEntry entry) async {
    if (_deleting) return;
    // Was the app's ONLY `CupertinoAlertDialog` — a third look for what is
    // the same decision as deleting a topo or a photo. Now the shared
    // confirm sheet, so all three match.
    final confirmed = await showMasiConfirm(
      context,
      title: 'Delete ascent?',
      message: 'This cannot be undone.',
      confirmLabel: 'Delete',
      confirmKey: Key('logbook-entry-delete-confirm-${entry.ascentId}'),
    );
    if (!confirmed) return;
    // `mounted` and not `context.mounted`: the row itself can be gone by the
    // time the dialog closes (the list rebuilds on any ascent change).
    if (!mounted) return;
    setState(() => _deleting = true);
    try {
      await ref.read(ascentsRepositoryProvider).softDeleteAscent(
        entry.ascentId,
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showMasiToast(
          "Couldn't delete this ascent — please try again",
          kind: MasiToastKind.error,
        );
      }
    } finally {
      // The successful path usually disposes this row (the provider drops the
      // entry), so this only ever runs on failure or on a no-op write.
      if (mounted) setState(() => _deleting = false);
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

/// Maps a [GradeBand] to its display color.
///
/// Delegates to `grade_colors.dart`'s canonical [colorForGradeBand] (the
/// literal five band colors, `0xFF2F9E6B`.._eliteColor) rather than keeping
/// its own copy of the switch — this file (and `topos_screen.dart`'s
/// `_colorForGradeBand`/`community_feed_screen.dart`'s `_colorForGradeBand`)
/// used to each hand-maintain the identical five-case switch against the
/// `MasiColors` grade tokens, which are defined to the SAME literal values
/// (see `app/theme.dart`) — three independently-editable copies that could
/// silently drift apart. The `colors` param is kept (rather than dropped and
/// every call site updated) purely so every existing caller here stays
/// untouched.
Color _colorForGradeBand(MasiColors colors, GradeBand band) =>
    colorForGradeBand(band);

/// Human-readable label for an [AscentStyle], e.g. `AscentStyle.onsight` ->
/// `'Onsight'`. Public (not library-private) so `LogAscentSheet` can reuse
/// it for its style [ChoiceChip] labels instead of rendering the raw enum
/// name (`style.name`, e.g. `'onsight'`).
String styleLabel(AscentStyle style) {
  switch (style) {
    case AscentStyle.send:
      return 'Sent';
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
///
/// Converts to local time first (`toLocal()`) — `Ascent.climbedAt` is stored
/// as UTC, so extracting month/day/year directly off it would show the UTC
/// calendar day, not the user's local day (e.g. an ascent logged at 00:30
/// local in UTC+2 would render as the previous date).
String _formatDate(DateTime date) {
  final local = date.toLocal();
  return '${_monthAbbreviations[local.month - 1]} ${local.day}, '
      '${local.year}';
}
