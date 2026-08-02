part of 'topos_screen.dart';

/// Shared frame for all four empty states below.
///
/// Every one of them renders into the `Expanded` in [ToposScreen.build], i.e.
/// into whatever vertical space the banners above happen to leave — and each
/// was a bare `Center` + `Column`, which cannot give any of it back. That is
/// a hard `RenderFlex overflowed by N pixels` the moment a sibling grows:
/// with the [SyncBanner] above it, `_SyncErrorEmptyState` overflowed by 196px
/// on a 400x300 surface (pinned in `topos_screen_test.dart`'s "T2: the empty
/// states tolerate a tall banner above them").
///
/// The fix is to stop assuming the leftover height is enough. [minHeight] =
/// the available height keeps the content centered in the usual case where it
/// fits (visually identical to the old bare `Center`), and the enclosing
/// scroll view means the overflow case degrades into a short scroll instead
/// of a clipped, unreachable Retry / "New topo" button.
///
/// NOTE — this makes the empty states tolerant of a squeeze; it does not and
/// cannot fix a banner that is taller than the whole viewport. That overflows
/// [ToposScreen]'s OUTER `Column` before any height reaches here at all
/// (measured: `_StorageWarningBanner` renders 561px of copy into a 364px body
/// at 400x420, with the empty state then allotted 0px). Pre-existing and
/// independent of the banners added in T2.
///
/// [stateKey] rides on the outermost widget so every pre-existing
/// `find.byKey(const Key('topos-empty-state'))`-style lookup still resolves.
class _EmptyStateShell extends StatelessWidget {
  const _EmptyStateShell({required this.stateKey, required this.child});

  final Key stateKey;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      key: stateKey,
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          // An unbounded parent would make `minHeight: infinity` an assertion
          // failure. Never happens from `ToposScreen` (the `Expanded` bounds
          // it), but this widget should not be a trap for the next caller.
          constraints: BoxConstraints(
            minHeight: constraints.maxHeight.isFinite
                ? constraints.maxHeight
                : 0,
          ),
          child: Center(child: child),
        ),
      ),
    );
  }
}

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
    return _EmptyStateShell(
      stateKey: const Key('topos-empty-state'),
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

/// Shown instead of [_EmptyState] when the Topos home is genuinely empty
/// (no topos at all — the exact same condition [_EmptyState] itself covers)
/// AND the most recent sync pull actually reported a problem
/// (`SyncOrchestratorState.lastPullError`, non-null — see that field's doc
/// in `sync_orchestrator.dart`) -- #72 P1 fix: before this,
/// `SyncOrchestrator._runPull` silently swallowed a [PullResult] carrying
/// errors (own rows imported fine but the shared side threw, or vice versa
/// -- see that class's doc), so a fresh install whose pull partially/fully
/// failed showed the exact same "No topos yet" prompt a genuinely
/// brand-new, successfully-synced account would, with no way to tell the
/// two apart or retry. [message] is that field's value verbatim (already
/// formatted `'Sync failed: <the actual PullResult.errors text>'` by
/// `SyncOrchestrator._runPull`), so the real failure is readable on-device
/// without a debugger. [_FilteredEmptyState]/[_SearchEmptyState] below are
/// UNCHANGED by this -- there IS data in those cases, so a sync problem (if
/// any) isn't why the list looks empty.
class _SyncErrorEmptyState extends StatelessWidget {
  const _SyncErrorEmptyState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    return _EmptyStateShell(
      stateKey: const Key('topos-sync-error-empty'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          MasiIcon('warning', size: 40, color: colors.gradeHard),
          const SizedBox(height: MasiSpacing.md),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: MasiSpacing.lg),
            child: Text(
              "Couldn't sync — $message.",
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(color: colors.ink2),
            ),
          ),
          const SizedBox(height: MasiSpacing.md),
          TextButton(
            key: const Key('topos-sync-error-retry'),
            onPressed: onRetry,
            child: const Text('Retry'),
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
    return _EmptyStateShell(
      stateKey: const Key('topos-filtered-empty-state'),
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
    return _EmptyStateShell(
      stateKey: const Key('topos-search-empty-state'),
      child: Text(
        'No topos match your search',
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(color: colors.ink2),
      ),
    );
  }
}
