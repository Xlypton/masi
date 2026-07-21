part of 'topos_screen.dart';

class _EmptyState extends StatelessWidget {
  const _EmptyState({this.onNewTopo});

  /// Wired straight to `_ToposScreenState._handleNewTopo`, gated on the
  /// SAME `canCreate` guard the floating `topos-new-topo` button uses (see
  /// `ToposScreen.build`) -- `null` while the topos list hasn't finished
  /// loading yet or a create is already in flight, which this button
  /// renders as visually disabled rather than omitted, mirroring the
  /// floating button's own disabled treatment.
  final VoidCallback? onNewTopo;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    return Center(
      key: const Key('topos-empty-state'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'No topos yet',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(color: colors.ink2),
          ),
          const SizedBox(height: MasiSpacing.md),
          ElevatedButton(
            key: const Key('topos-empty-new-topo'),
            style: ElevatedButton.styleFrom(
              backgroundColor: colors.accent,
              foregroundColor: colors.onAccent,
            ),
            onPressed: onNewTopo,
            child: const Text('New topo'),
          ),
        ],
      ),
    );
  }
}

/// Shown instead of [_EmptyState] when there ARE topos but every one of them
/// was excluded by the active [ToposFilter] (see [applyToposFilter]) --
/// distinct from "no topos yet" so the user isn't misled into thinking their
/// library is empty when it's just the filter hiding everything.
class _FilteredEmptyState extends StatelessWidget {
  const _FilteredEmptyState();

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    return Center(
      key: const Key('topos-filtered-empty-state'),
      child: Text(
        'No topos match your filters',
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(color: colors.ink2),
      ),
    );
  }
}

/// Shown instead of [_EmptyState] / [_FilteredEmptyState] when there ARE
/// topos but the `topos-search-field` keyword query (see
/// [ToposScreen.build]'s [_matchesQuery] narrowing, checked BEFORE the
/// [ToposFilter] facets) excludes every one of them -- distinct from both
/// other empty states, mirroring `community_screen.dart`'s `_FeedView`
/// three-way split, so a user who typed a query that matches nothing sees a
/// message about their search specifically, not a generic/misleading one.
class _SearchEmptyState extends StatelessWidget {
  const _SearchEmptyState();

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    return Center(
      key: const Key('topos-search-empty-state'),
      child: Text(
        'No topos match your search',
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(color: colors.ink2),
      ),
    );
  }
}
