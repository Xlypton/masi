import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../shared/presentation/bottom_safe_inset.dart';
import '../../../shared/presentation/masi_dialogs.dart';
import '../../../shared/presentation/masi_icon.dart';
import '../../../shared/presentation/masi_toast.dart';
import '../../../shared/presentation/masi_loading_indicator.dart';
import '../application/moderation_providers.dart';
import '../application/topo_version_providers.dart';
import '../domain/topo_version.dart';

/// A topo's recorded history (community editing phase 6a / C-8).
///
/// Two audiences again, and this time they want the same list for different
/// reasons. A reader gets "what changed here since I was last on this rock",
/// which is genuinely useful and not a moderation feature at all. An ADMIN
/// gets a restore button, which is the reason the history is kept: rather than
/// enumerating and blocking every destructive act, all of them become
/// reversible and attributed.
Future<void> showTopoHistory(
  BuildContext context, {
  required String wallId,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  backgroundColor: Colors.transparent,
  builder: (_) => TopoHistorySheet(wallId: wallId),
);

class TopoHistorySheet extends ConsumerWidget {
  const TopoHistorySheet({super.key, required this.wallId});

  final String wallId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MasiColors.of(context);
    final versions = ref.watch(topoVersionsProvider(wallId));
    final isAdmin = ref.watch(isAdminProvider).asData?.value ?? false;
    // Two callers, one inside `NavShell` (`topos_row.dart`, where the
    // measured nav-bar padding already exceeds the floor and wins
    // unchanged) and one outside it (`CommunityTopoDetailScreen`, where the
    // device inset is otherwise zero in a standalone PWA) — `masiBottomInset`
    // maxes against both, so this one call is correct for either world.
    final bottomInset = masiBottomInset(context, ref);

    return Container(
      key: const Key('topo-history-sheet'),
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
              MasiSpacing.sm,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'History',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
          ),
          // The three states written out rather than delegated to
          // `MasiAsyncView`. That widget puts its content in an `Expanded`,
          // which is right on a screen and wrong in a bottom sheet: it made
          // this sheet fill the display edge to edge, leaving no scrim to tap
          // and no way to dismiss it at all. (Found by opening it in a
          // browser; every widget test passed, because a test never tries to
          // tap outside a sheet.)
          //
          // What is kept from that widget is the part that matters here: a
          // FAILED fetch shows an error, never an empty list. An empty history
          // is a CLAIM — "nothing has ever changed here" — so rendering one
          // because the request failed would state something false about the
          // exact thing the reader opened this sheet to check.
          Flexible(
            child: switch (versions) {
              AsyncValue(hasValue: true, value: final list?) => list.isEmpty
                  ? Padding(
                      key: const Key('topo-history-empty'),
                      padding: EdgeInsets.fromLTRB(
                        MasiSpacing.lg,
                        MasiSpacing.md,
                        MasiSpacing.lg,
                        MasiSpacing.lg + bottomInset,
                      ),
                      child: Text(
                        'Nothing recorded yet. History starts when a topo '
                        'is published.',
                        style: Theme.of(
                          context,
                        ).textTheme.bodyMedium?.copyWith(color: colors.ink2),
                      ),
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      padding: EdgeInsets.fromLTRB(
                        MasiSpacing.lg,
                        0,
                        MasiSpacing.lg,
                        MasiSpacing.lg + bottomInset,
                      ),
                      itemCount: list.length,
                      separatorBuilder: (_, _) =>
                          const SizedBox(height: MasiSpacing.sm),
                      itemBuilder: (_, index) => _VersionTile(
                        version: list[index],
                        change: TopoVersionChange.between(list, index),
                        // The newest version IS the current state, so
                        // "restore" on it would be a no-op dressed up as an
                        // action.
                        onRestore: isAdmin && index > 0
                            ? () => _restore(context, ref, list[index])
                            : null,
                      ),
                    ),
              AsyncValue(hasError: true) => Padding(
                key: const Key('topo-history-error'),
                padding: EdgeInsets.fromLTRB(
                  MasiSpacing.lg,
                  MasiSpacing.md,
                  MasiSpacing.lg,
                  MasiSpacing.lg + bottomInset,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "Couldn't load this topo's history",
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    TextButton(
                      key: const Key('topo-history-retry'),
                      onPressed: () =>
                          ref.invalidate(topoVersionsProvider(wallId)),
                      child: const Text('Try again'),
                    ),
                  ],
                ),
              ),
              _ => const Padding(
                padding: EdgeInsets.all(MasiSpacing.xxl),
                child: Center(child: MasiLoadingIndicator.standalone()),
              ),
            },
          ),
        ],
      ),
    );
  }

  Future<void> _restore(
    BuildContext context,
    WidgetRef ref,
    TopoVersion version,
  ) async {
    final confirmed = await showMasiConfirm(
      context,
      title: 'Restore this version?',
      message:
          'The topo goes back to how it stood on ${_formatDate(version.at)}, '
          'with ${version.routeCount} route'
          '${version.routeCount == 1 ? '' : 's'}. Anything added since is '
          'removed, and the current state is saved first so this can be '
          'undone.',
      confirmLabel: 'Restore',
      confirmKey: Key('topo-history-restore-confirm-${version.id}'),
      isDestructive: true,
    );
    if (!confirmed || !context.mounted) return;

    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final routes = await ref
          .read(topoVersionServiceProvider)
          .revert(wallId: wallId, versionId: version.id);
      messenger?.showMasiToast(
        'Restored — $routes route'
            '${routes == 1 ? '' : 's'}',
        kind: MasiToastKind.success,
      );
    } catch (error) {
      // Loud. An admin who believes a vandalised topo has been repaired when
      // it has not is the single worst outcome this whole phase exists to
      // prevent.
      messenger?.showMasiToast(
        'Could not restore that version. $error',
        kind: MasiToastKind.error,
      );
    }
  }
}

class _VersionTile extends StatelessWidget {
  const _VersionTile({
    required this.version,
    required this.change,
    this.onRestore,
  });

  final TopoVersion version;
  final TopoVersionChange change;
  final VoidCallback? onRestore;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final summary = change.summary;

    return Container(
      key: Key('topo-version-row-${version.id}'),
      padding: const EdgeInsets.all(MasiSpacing.md),
      decoration: BoxDecoration(
        color: colors.surface2,
        borderRadius: BorderRadius.circular(MasiRadii.card),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MasiIcon('edit_note', size: 18, color: colors.ink3),
          const SizedBox(width: MasiSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _formatDate(version.at),
                  style: textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${version.actorLabel} · ${version.routeCount} route'
                  '${version.routeCount == 1 ? '' : 's'}',
                  style: textTheme.bodySmall?.copyWith(color: colors.ink2),
                ),
                // Omitted rather than faked when nothing visible changed. A
                // redrawn line, a corrected grade or an edited description all
                // leave the route count and the name alone, and this list
                // cannot see them — inventing a difference would be worse than
                // admitting there is nothing to report.
                if (summary != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    summary,
                    key: Key('topo-version-change-${version.id}'),
                    style: textTheme.bodySmall?.copyWith(color: colors.accent),
                  ),
                ],
              ],
            ),
          ),
          if (onRestore != null)
            TextButton(
              key: Key('topo-history-restore-${version.id}'),
              onPressed: onRestore,
              child: const Text('Restore'),
            ),
        ],
      ),
    );
  }
}

/// "7 Aug 2026, 14:03" — a date a person can match against "the week I was
/// there", which is the only comparison a history list is ever used for.
String _formatDate(DateTime at) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final local = at.toLocal();
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  return '${local.day} ${months[local.month - 1]} ${local.year}, $hh:$mm';
}
