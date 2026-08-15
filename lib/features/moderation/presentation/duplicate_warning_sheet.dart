import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../shared/presentation/bottom_safe_inset.dart';
import '../domain/nearby_topo.dart';

/// "3 topos already exist here", shown BEFORE a submission (community editing
/// phase 8b / C-6.1).
///
/// This is the cheapest intervention in the whole duplicate story and the only
/// one that costs nobody anything. §C-6 rules out resolving duplicates by
/// deletion and by refusing the second submission, which leaves exactly one
/// place to act cheaply: the moment before a second topo exists. "Many
/// duplicates stop right there."
///
/// ## It is a prompt, not a gate
///
/// The confirm button is always live and it does not hide behind a "type YES"
/// ritual. That is not softness — the plan is explicit that a second topo of
/// the same boulder is often the BETTER one, so a client that could block a
/// submission would be enforcing the opposite of the decision. What this sheet
/// buys is the case where somebody genuinely did not know: they are shown the
/// list, they recognise the crag, and they stop. Everybody else taps through in
/// one tap and loses two seconds.
///
/// Returns true if they went ahead.
Future<bool> showDuplicateWarning(
  BuildContext context, {
  required List<NearbyTopo> nearby,
  required String topoName,
  required bool trusted,
}) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _DuplicateWarningSheet(
      nearby: nearby,
      topoName: topoName,
      trusted: trusted,
    ),
  );
  return result ?? false;
}

class _DuplicateWarningSheet extends ConsumerWidget {
  const _DuplicateWarningSheet({
    required this.nearby,
    required this.topoName,
    required this.trusted,
  });

  final List<NearbyTopo> nearby;
  final String topoName;

  /// Whether this account auto-publishes (phase 8a). Only changes the button
  /// wording — a person told "Submit" whose topo is public thirty seconds later
  /// has been misled, and the publish confirm already makes this distinction.
  final bool trusted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final count = nearby.length;

    return Container(
      key: const Key('duplicate-warning-sheet'),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(MasiRadii.large),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: MasiSpacing.sm),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: colors.ink3,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              MasiSpacing.lg,
              MasiSpacing.md,
              MasiSpacing.lg,
              MasiSpacing.xs,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  count == 1
                      ? 'A topo already exists here'
                      : '$count topos already exist here',
                  key: const Key('duplicate-warning-title'),
                  style: textTheme.titleMedium,
                ),
                const SizedBox(height: MasiSpacing.xs),
                // Says the true thing rather than the discouraging one. A
                // second photo of the same boulder in different light is
                // useful; a duplicate of a topo that is already good is not.
                // Only the submitter can tell those apart, so the copy hands
                // them the distinction instead of a verdict.
                Text(
                  'Another angle or better light is worth having. If one of '
                  'these is already the same topo, suggesting a line on it '
                  'reaches more people than a second copy.',
                  key: const Key('duplicate-warning-body'),
                  style: textTheme.bodySmall?.copyWith(color: colors.ink2),
                ),
              ],
            ),
          ),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(
                horizontal: MasiSpacing.lg,
                vertical: MasiSpacing.sm,
              ),
              itemCount: nearby.length,
              separatorBuilder: (_, _) => const SizedBox(height: MasiSpacing.xs),
              itemBuilder: (_, index) => _NearbyRow(topo: nearby[index]),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              MasiSpacing.lg,
              MasiSpacing.sm,
              MasiSpacing.lg,
              // Currently fine as-is — this sheet's only caller
              // (`topos_row.dart`) is inside `NavShell`, where the measured
              // nav-bar padding already exceeds the standalone floor. Using
              // the helper anyway rather than the raw `MediaQuery` read is
              // preventative, not a bug fix: it stops this from silently
              // breaking if a second, non-shell caller is ever added.
              MasiSpacing.lg + masiBottomInset(context, ref),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ElevatedButton(
                  key: const Key('duplicate-warning-continue'),
                  onPressed: () => Navigator.of(context).pop(true),
                  child: Text(
                    trusted ? 'Publish "$topoName" anyway' : 'Submit anyway',
                  ),
                ),
                const SizedBox(height: MasiSpacing.xs),
                TextButton(
                  key: const Key('duplicate-warning-cancel'),
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Not now'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NearbyRow extends StatelessWidget {
  const _NearbyRow({required this.topo});

  final NearbyTopo topo;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final routes = topo.routeCount;

    return Container(
      key: Key('duplicate-warning-row-${topo.wallId}'),
      padding: const EdgeInsets.symmetric(
        horizontal: MasiSpacing.md,
        vertical: MasiSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: colors.surface2,
        borderRadius: BorderRadius.circular(MasiRadii.control),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            topo.name,
            style: textTheme.titleSmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            '${topo.distanceLabel} · '
            '$routes route${routes == 1 ? '' : 's'} · ${topo.ownerLabel}',
            style: textTheme.bodySmall?.copyWith(color: colors.ink2),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
