import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../core/grades/grade_system.dart';
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
      ),
      body: SafeArea(
        child: asyncEntries.when(
          data: (entries) {
            if (entries.isEmpty) {
              return const _EmptyState();
            }
            return _LogbookList(entries: entries);
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
