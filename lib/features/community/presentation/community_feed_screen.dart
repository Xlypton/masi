import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../core/grades/grade_system.dart';
import '../../../shared/presentation/masi_icon.dart';
import '../../../shared/filtering/grade_range_picker.dart';
import '../../../shared/filtering/style_filter_chips.dart';
import '../../../shared/filtering/style_tag_filter_chips.dart';
import '../../account/application/auth_providers.dart';
import '../../account/application/profile_providers.dart';
import '../../backup/application/offline_banner_dismissal.dart';
import '../../backup/application/reachability_providers.dart';
import '../../backup/application/sync_orchestrator.dart';
import '../../backup/data/sync_service.dart' show SharedPhotoBudgetReason;
import '../../logbook/application/ascents_providers.dart';
import '../../logbook/data/ascents_repository.dart';
import '../../logbook/presentation/logbook_screen.dart' show styleLabel;
import '../../notifications/presentation/notification_bell.dart';
import '../../../shared/presentation/masi_async_view.dart';
import '../../../shared/presentation/masi_pending_button.dart';
import '../../../shared/presentation/masi_shimmer.dart';
import '../../../shared/presentation/masi_skeleton.dart';
import '../../../shared/presentation/sync_banner.dart';
import '../../topo/presentation/photo_image.dart';
import '../application/community_providers.dart';
import '../application/community_topo_detail_providers.dart';
import '../data/community_repository.dart';

/// The Community Feed tab (bottom-nav branch `/feed`): a searchable list of
/// every shared topo (thumbnail, name, grade pill, like/comment counts,
/// owner) — see [_FeedView]. The other half of the former combined
/// `CommunityScreen`; see `CommunityMapScreen`'s doc for why the two are now
/// separate, permanent bottom-nav screens rather than a shared toggle.
class CommunityFeedScreen extends ConsumerStatefulWidget {
  const CommunityFeedScreen({super.key});

  @override
  ConsumerState<CommunityFeedScreen> createState() =>
      _CommunityFeedScreenState();
}

class _CommunityFeedScreenState extends ConsumerState<CommunityFeedScreen> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    // Seed the reachability verdict `_FeedView` renders. The provider is
    // probe-on-demand — nothing schedules it — so a screen that wants an
    // answer has to ask at mount. `refresh()` never throws, and concurrent
    // callers (this screen and `ToposScreen` mounting in the same frame)
    // collapse onto one probe, so this is safe to fire and forget.
    Future.microtask(() => ref.read(reachabilityProvider.notifier).refresh());
  }

  void _onSearchChanged() {
    final query = _searchController.text.trim().toLowerCase();
    if (query != _query) {
      setState(() => _query = query);
    }
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  /// `MasiAsyncView`'s retry, carrying over exactly what the deleted
  /// `CommunityErrorState` did (#57): re-run the REAL remote pull FIRST, then
  /// invalidate both halves of `feedItemsProvider`'s union. A local-only
  /// invalidate can never recover data that was simply never pulled — that was
  /// the original bug — and invalidating `sharedAscentsProvider` too is what
  /// makes this recover the whole union rather than only its topo half.
  ///
  /// `pullNow()` never throws (safe no-op when signed out / Supabase is
  /// unavailable — see its doc), so no try/catch is needed.
  Future<void> _retry() async {
    await ref.read(syncOrchestratorProvider.notifier).pullNow();
    if (!mounted) return;
    ref.invalidate(sharedToposProvider);
    ref.invalidate(sharedAscentsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final asyncFeedItems = ref.watch(feedItemsProvider);

    return Scaffold(
      key: const Key('community-feed-screen'),
      appBar: AppBar(
        title: Text(
          'Feed',
          style: Theme.of(context).textTheme.displaySmall,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        centerTitle: false,
        actions: [
          // The notification centre sits on the Feed rather than on the home
          // screen because everything it reports — a comment, a tag, a like, a
          // suggested edit — happens in the community half of the app, so this
          // is where a user is when the answer to "what happened?" matters.
          const NotificationBell(),
          // #12 Wave 3, ST5: the home-screen's own Logbook icon is removed
          // in this wave, so the Feed — the screen a "shared ascent" row
          // now links a climber's other activity from — carries the entry
          // point back to the personal Logbook instead.
          IconButton(
            key: const Key('feed-logbook-button'),
            icon: MasiIcon('logbook', color: colors.ink),
            tooltip: 'My logbook',
            onPressed: () => context.push('/logbook'),
          ),
        ],
      ),
      // `bottom: false` (#51, mirrors `CommunityMapScreen`'s identical
      // `SafeArea` above): NavShell's Scaffold now extends every branch
      // full-bleed behind its floating glass bar, so this screen's REAL
      // measured bottom clearance must reach `_FeedView`'s list unconsumed
      // rather than being padded away here — see that widget's `build` for
      // where it's actually applied.
      body: SafeArea(
        bottom: false,
        // The shared loading system, replacing this screen's own
        // `.when(loading: spinner, error: CommunityErrorState)`: a shaped
        // skeleton for the first load, the rows the user already has KEPT on
        // screen (with a hairline cue) whenever `feedItemsProvider` re-emits,
        // and one built-in retry for the failure case.
        child: MasiAsyncView<List<FeedItem>>(
          value: asyncFeedItems,
          errorMessage: "Couldn't load the community feed",
          // The raw exception stays off screen. `feedItemsProvider` is a local
          // Drift stream, so its error object is a SQLite/serialization
          // sentence that means nothing to a climber — and this screen already
          // has a place where the real text DOES surface, because that's the
          // one the user can act on: `_SyncErrorEmptyState`/`SyncBanner` print
          // the actual pull failure verbatim (#72).
          showErrorDetail: false,
          onRetry: () => _retry(),
          skeleton: (context) => const _FeedSkeleton(),
          data: (context, items) => _FeedView(
            items: items,
            searchController: _searchController,
            query: _query,
          ),
        ),
      ),
    );
  }
}

/// The Feed's first-load placeholder: the search row's box reserved at its
/// real height, then [MasiSkeletonList.feedCards] for the rows it precedes.
///
/// The search row is part of the skeleton deliberately. [_FeedView] owns that
/// row, so during the first load it is not mounted at all — a bare list of
/// card skeletons would start [searchRowHeight] px higher than the real first
/// card and the whole feed would jump downwards when the data landed, which is
/// worse than a spinner (see [MasiSkeleton]'s doc). The two shapes drawn here
/// are the field's pill and the filter glyph, nothing else: a skeleton must
/// never look like a control that can be pressed.
class _FeedSkeleton extends StatelessWidget {
  const _FeedSkeleton();

  /// The MEASURED height of [_FeedView]'s real search row: its `TextField`
  /// (17 px text in Material's default outline content padding) is taller than
  /// the 48 px filter [IconButton] beside it, so the field is what sets the
  /// row's height. Not a guess and not a round number on purpose — it is
  /// asserted against the real screen in `community_loading_test.dart`, so a
  /// change to the field's decoration fails that test instead of silently
  /// reintroducing the jump this skeleton exists to prevent.
  static const double searchRowHeight = 58;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            MasiSpacing.lg,
            0,
            MasiSpacing.lg,
            MasiSpacing.sm,
          ),
          child: Row(
            children: const [
              Expanded(
                child: MasiSkeleton.box(
                  key: Key('community-feed-skeleton-search'),
                  height: searchRowHeight,
                  radius: 24,
                ),
              ),
              SizedBox(width: MasiSpacing.sm),
              // The filter button's glyph, not its 48 px hit box: an empty
              // 48 px circle would read as a tappable disc.
              SizedBox(
                width: 48,
                child: Center(child: MasiSkeleton.circle(diameter: 24)),
              ),
            ],
          ),
        ),
        const Expanded(child: MasiSkeletonList.feedCards()),
      ],
    );
  }
}

/// The Feed tab: a search field + filter button over a list of [_FeedRow]s
/// (shared topos) interleaved with [_AscentFeedRow]s (shared ascent-log
/// entries, #12 Wave 3 ST5), or [_EmptyState] when there's nothing shared at
/// all (or nothing matching the search / the [communityFilterProvider]
/// grade+style filter).
///
/// Name search and the grade/style filter are ANDed together but kept as
/// two independently-diagnosable empty states (search narrows first, then
/// the filter) so a user who typed a matching name but filtered out every
/// result sees "No topos match your filters" rather than the more generic
/// "No topos match your search".
///
/// The grade/style [CommunityFilter] only ever applies to [TopoFeedItem]s —
/// [CommunityFilter.matches] takes a [SharedTopo] and reads its
/// route-grade/style/style-tag aggregates, none of which a [SharedAscentEntry]
/// carries in a comparable shape (its own `style` is the CLIMB style —
/// onsight/flash/redpoint/… — an entirely different axis from a route's
/// sport/trad/boulder [CommunityFilter.styles]). Rather than silently
/// dropping every ascent row the instant any grade/style filter is active,
/// [AscentFeedItem]s are exempted from that filter entirely and always pass
/// it; name search, by contrast, DOES apply to both — an ascent matches by
/// its route or wall name (see [_matchesQuery]) since there's no comparably
/// natural "name" field on an ascent otherwise.
class _FeedView extends ConsumerWidget {
  const _FeedView({
    required this.items,
    required this.searchController,
    required this.query,
  });

  final List<FeedItem> items;
  final TextEditingController searchController;
  final String query;

  bool _matchesQuery(FeedItem item) {
    if (query.isEmpty) return true;
    return switch (item) {
      TopoFeedItem(:final topo) => topo.name.toLowerCase().contains(query),
      AscentFeedItem(:final entry) =>
        (entry.routeName?.toLowerCase().contains(query) ?? false) ||
            entry.wallName.toLowerCase().contains(query),
    };
  }

  bool _matchesFilter(FeedItem item, CommunityFilter filter) {
    return switch (item) {
      TopoFeedItem(:final topo) => filter.matches(topo),
      // Ascents sit outside the topo grade/style filter's axes entirely —
      // see this class's doc — so they always pass it.
      AscentFeedItem() => true,
    };
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MasiColors.of(context);
    final filter = ref.watch(communityFilterProvider);
    // The floating bottom bar's occupied height (#51 — see `nav_shell.dart`'s
    // doc): `CommunityFeedScreen`'s own `SafeArea` above uses `bottom: false`
    // so this real measured value reaches here unconsumed, then gets folded
    // into the list's own bottom padding below so its last row scrolls clear
    // of the bar instead of ending up hidden behind it.
    final bottomChromeInset = MediaQuery.of(context).padding.bottom;
    final searchFiltered = items.where(_matchesQuery).toList();
    final filtered = searchFiltered
        .where((item) => _matchesFilter(item, filter))
        .toList();

    final String? emptyMessage = items.isEmpty
        ? 'No shared topos yet'
        : searchFiltered.isEmpty
        ? 'No topos match your search'
        : filtered.isEmpty
        ? 'No topos match your filters'
        : null;

    // #72 P1 fix: when the feed is GENUINELY empty (no shared topos at
    // all, not merely filtered/searched down to nothing) AND the most
    // recent pull actually reported a problem
    // (`SyncOrchestratorState.lastPullError`, non-null — see that field's
    // doc), show `_SyncErrorEmptyState` instead of the plain "No shared
    // topos yet" message — a user on a fresh install whose pull silently
    // failed used to see the exact same empty feed a genuinely-synced,
    // nothing-shared-yet account would, with no way to tell the two apart
    // or retry. Deliberately gated on `items.isEmpty` specifically (not
    // `emptyMessage != null`): the search/filter-narrowed empty states
    // below are unaffected by a sync problem — there IS data in that case.
    final syncState = ref.watch(syncOrchestratorProvider);
    final syncError = syncState.lastPullError;
    final showSyncError = items.isEmpty && syncError != null;

    // Stage 3 (T2). The `showSyncError` gate above is empty-feed-only, so a
    // user with cached rows was told nothing at all when the feed silently
    // stopped refreshing. [SyncBanner] renders above the list irrespective of
    // how much is in it.
    //
    // `isKnownOffline`, never `!= online`: `Reachability.unknown` is the
    // pre-probe state, and treating it as offline flashes this banner for a
    // frame on every cold start (see `reachability_providers.dart`). Moved
    // above `showSyncError`'s sibling gate below because that gate now needs
    // the verdict too.
    //
    // It yields the sync-failure case to `_SyncErrorEmptyState` (that is
    // exactly `showSyncError`), which says the same sentence larger and with
    // its own Retry — printing both would repeat one sentence twice on one
    // screen. The OFFLINE banner never yields: no empty state mentions
    // reachability at all.
    //
    // Lives here rather than in `CommunityFeedScreen.build` deliberately:
    // `feedItemsProvider` is a local Drift stream, so its loading/error
    // branches are local-database states that losing signal does not cause
    // and an offline banner would not explain.
    final reachability = ref.watch(reachabilityProvider);
    // Stage 3 offline-reads gap: a genuinely empty feed with NO reported
    // pull error can still mean "the app cannot currently tell" rather than
    // "this account really has nothing shared to it" — a device that never
    // pulled at all, or whose last pull succeeded before the signal dropped.
    // Gated on `items.isEmpty` exactly like `showSyncError` (the search/
    // filter-narrowed empty states are untouched — there IS data in those
    // cases) and yields to `showSyncError`: a real reported failure is more
    // specific than "no signal" and should win when both are true.
    final showOfflineEmpty =
        items.isEmpty && !showSyncError && reachability.isKnownOffline;
    // #49 P2 fix: lowest priority — see `topos_screen.dart`'s identical
    // reasoning. This is the screen the withheld photos are actually
    // MISSING FROM (the shared pull is what skips them), so it is the more
    // important of the two call sites for this banner, not a copy-paste
    // extra.
    final sharedPhotosWithheld =
        syncState.lastSharedPhotoBudgetReason ==
        SharedPhotoBudgetReason.storagePressure;
    final SyncBannerKind? bannerKind = reachability.isKnownOffline
        ? SyncBannerKind.offline
        : (syncError != null && !showSyncError)
        ? SyncBannerKind.syncFailed
        : sharedPhotosWithheld
        ? SyncBannerKind.sharedPhotosWithheld
        : null;
    // Shared with the Library's copy of this banner (see
    // `offline_banner_dismissal.dart`): closing it there closes it here, since
    // it is one condition acknowledged once — and it comes back on the next
    // offline episode. Suppresses the OFFLINE kind only; it never promotes the
    // stale pull error that `bannerKind` deliberately ranks below it.
    final offlineBannerDismissed = ref.watch(offlineBannerDismissedProvider);

    return Column(
      children: [
        // Dismissed means no widget at all — not a zero-height box that still
        // contributes the banner's own margin.
        if (bannerKind != null &&
            !(bannerKind == SyncBannerKind.offline && offlineBannerDismissed))
          SyncBanner(
            kind: bannerKind,
            detail: syncError,
            // Nothing useful to press while genuinely offline.
            onRetry: bannerKind == SyncBannerKind.syncFailed
                ? () => ref.read(syncOrchestratorProvider.notifier).pullNow()
                : null,
            // Offline only — `SyncBanner.onDismiss` enforces that structurally
            // too, so a future call site cannot make "Couldn't sync" closable.
            onDismiss: bannerKind == SyncBannerKind.offline
                ? () => ref
                      .read(offlineBannerDismissedProvider.notifier)
                      .dismiss()
                : null,
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            MasiSpacing.lg,
            0,
            MasiSpacing.lg,
            MasiSpacing.sm,
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('community-search-field'),
                  controller: searchController,
                  decoration: InputDecoration(
                    hintText: 'Search topos',
                    prefixIcon: Padding(
                      padding: const EdgeInsets.only(left: 12, right: 8),
                      child: MasiIcon('search', size: 20, color: colors.ink3),
                    ),
                    prefixIconConstraints: const BoxConstraints(
                      minWidth: 0,
                      minHeight: 0,
                    ),
                    filled: true,
                    fillColor: colors.surface2,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide(color: colors.separator),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide(color: colors.separator),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide(color: colors.accent, width: 1.5),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: MasiSpacing.sm),
              _FilterButton(filter: filter),
            ],
          ),
        ),
        Expanded(
          // #57: pull-to-refresh re-runs the SAME remote pull the
          // signed-out -> signed-in edge used to be the only trigger for
          // (see `SyncOrchestrator.pullNow`'s doc) — `sharedToposProvider`/
          // `sharedAscentsProvider` are plain `StreamProvider`s watching
          // Drift, so once the pull writes fresh rows locally they emit on
          // their own; no explicit invalidate needed here.
          child: RefreshIndicator(
            key: const Key('community-feed-refresh'),
            onRefresh: () =>
                ref.read(syncOrchestratorProvider.notifier).pullNow(),
            child: emptyMessage != null
                // `RefreshIndicator` needs an `AlwaysScrollableScrollPhysics`
                // scrollable ancestor to arm its overscroll gesture even
                // when there's nothing to scroll — a bare, non-scrollable
                // `_EmptyState` (the previous body here) could never be
                // pulled. `LayoutBuilder` + a height-matched `SizedBox`
                // keeps `_EmptyState`'s own `Center` filling/centering in
                // exactly the same visual spot as before, now inside a
                // (trivially) scrollable `ListView`.
                ? LayoutBuilder(
                    builder: (context, constraints) => ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        SizedBox(
                          height: constraints.maxHeight,
                          child: showSyncError
                              ? _SyncErrorEmptyState(message: syncError)
                              : showOfflineEmpty
                              ? const _OfflineEmptyState()
                              : _EmptyState(message: emptyMessage),
                        ),
                      ],
                    ),
                  )
                : ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: EdgeInsets.fromLTRB(
                      MasiSpacing.lg,
                      MasiSpacing.sm,
                      MasiSpacing.lg,
                      MasiSpacing.sm + bottomChromeInset,
                    ),
                    itemCount: filtered.length,
                    separatorBuilder: (context, index) =>
                        const SizedBox(height: MasiSpacing.sm),
                    itemBuilder: (context, index) => switch (filtered[index]) {
                      TopoFeedItem(:final topo, :final alternates) => _FeedRow(
                        topo: topo,
                        alternates: alternates,
                      ),
                      AscentFeedItem(:final entry) => _AscentFeedRow(
                        entry: entry,
                      ),
                    },
                  ),
          ),
        ),
      ],
    );
  }
}

/// The `community-filter-button`: a `tune` icon that opens
/// [_CommunityFiltersSheet], showing `filter_active` whenever [filter] is
/// active so a user can tell at a glance that the feed is currently narrowed.
class _FilterButton extends StatelessWidget {
  const _FilterButton({required this.filter});

  final CommunityFilter filter;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    return IconButton(
      key: const Key('community-filter-button'),
      icon: MasiIcon(
        filter.isActive ? 'filter_active' : 'filter',
        color: colors.accent,
      ),
      tooltip: 'Filters',
      onPressed: () => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (_) => const _CommunityFiltersSheet(),
      ),
    );
  }
}

/// The Community feed/map's "Filters" bottom sheet: a [GradeRangePicker] +
/// [StyleFilterChips] + [StyleTagFilterChips] wired directly to
/// [communityFilterProvider], plus a Clear action. Purely reactive to the
/// provider (no local widget state of its own), so edits made here are
/// visible live in the feed/map behind it without needing to close the
/// sheet first.
class _CommunityFiltersSheet extends ConsumerWidget {
  const _CommunityFiltersSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MasiColors.of(context);
    final filter = ref.watch(communityFilterProvider);
    final notifier = ref.read(communityFilterProvider.notifier);

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          MasiSpacing.lg,
          MasiSpacing.lg,
          MasiSpacing.lg,
          MediaQuery.of(context).viewInsets.bottom + MasiSpacing.lg,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Filters',
                      style: Theme.of(context).textTheme.titleLarge,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TextButton(
                    key: const Key('community-filter-clear'),
                    onPressed: notifier.clear,
                    child: const Text('Clear'),
                  ),
                ],
              ),
              const SizedBox(height: MasiSpacing.md),
              Text(
                'Grade',
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(color: colors.ink2),
              ),
              const SizedBox(height: MasiSpacing.sm),
              GradeRangePicker(
                value: filter.grade,
                onChanged: notifier.setGrade,
              ),
              const SizedBox(height: MasiSpacing.lg),
              Text(
                'Style',
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(color: colors.ink2),
              ),
              const SizedBox(height: MasiSpacing.sm),
              StyleFilterChips(
                selected: filter.styles,
                onChanged: notifier.setStyles,
              ),
              const SizedBox(height: MasiSpacing.lg),
              Text(
                'Tags',
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(color: colors.ink2),
              ),
              const SizedBox(height: MasiSpacing.sm),
              StyleTagFilterChips(
                selected: filter.styleTags,
                onChanged: notifier.setStyleTags,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    return Center(
      key: const Key('community-empty'),
      child: Text(
        message,
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(color: colors.ink2),
      ),
    );
  }
}

/// Shown instead of [_EmptyState] when the feed is genuinely empty (no
/// shared topos at all) AND the most recent pull actually reported a
/// problem — see [_FeedView.build]'s `showSyncError` gate and
/// `SyncOrchestratorState.lastPullError`'s doc for exactly when that is.
/// [message] is that field's value verbatim (already formatted
/// `'Sync failed: <the actual PullResult.errors text>'` by
/// `SyncOrchestrator._runPull`), so the real failure is readable on-device
/// without a debugger (#72). "Retry" re-runs the SAME `pullNow()` the
/// list's own pull-to-refresh and `MasiAsyncView`'s "Try again"
/// ([_CommunityFeedScreenState._retry]) call — no explicit provider
/// invalidation needed here either, for the same reason documented on this
/// file's `RefreshIndicator.onRefresh` above.
class _SyncErrorEmptyState extends ConsumerWidget {
  const _SyncErrorEmptyState({required this.message});

  final String message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MasiColors.of(context);
    return Center(
      key: const Key('community-sync-error-empty'),
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
          // A pending button, not a plain one: `pullNow()` is a real network
          // round trip, and a Retry that looked idle for two seconds invited a
          // second tap and a second pull.
          MasiPendingButton.text(
            key: const Key('community-sync-error-retry'),
            onPressed: () =>
                ref.read(syncOrchestratorProvider.notifier).pullNow(),
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

/// Shown instead of [_EmptyState] when the feed is genuinely empty (no
/// shared topos at all) AND reachability has completed and FAILED
/// (`Reachability.isKnownOffline` -- never `unknown`, the same guard
/// [SyncBanner] uses) AND there is no [SyncOrchestratorState.lastPullError]
/// to report instead -- when there IS one, [_SyncErrorEmptyState] takes
/// priority (see [_FeedView.build]'s `showOfflineEmpty` gate), since a real
/// reported failure is more specific than "no signal".
///
/// Stage 3's design-doc gap: before this state existed, offline with an
/// empty feed and NO pull error -- a device that never pulled at all, or
/// whose last pull succeeded before the signal dropped -- fell all the way
/// through to [_EmptyState]'s plain "No shared topos yet", indistinguishable
/// from a genuinely empty, fully-synced account. [SyncBanner] above the list
/// already says "you're offline" (T2), so this widget deliberately does NOT
/// repeat that sentence -- it is the "what you can do about it" surface:
/// Retry re-probes reachability and, only if the signal is actually back,
/// immediately re-pulls too.
///
/// Wrapped in a [SingleChildScrollView] rather than a bare [Center] --
/// unlike `topos_empty_states.dart`'s `_EmptyStateShell`-backed states, this
/// screen's `_EmptyState`/`_SyncErrorEmptyState` neighbors have no such
/// squeeze-tolerance of their own, and this widget MEASURABLY overflowed
/// (`RenderFlex overflowed by 124 pixels`) at 400x300 with the offline
/// [SyncBanner] rendered above it -- the exact same shape of bug
/// `topos_empty_states.dart`'s doc comment describes fixing for two other
/// widgets. A scrollable degrades the squeeze into a short scroll instead.
class _OfflineEmptyState extends ConsumerWidget {
  const _OfflineEmptyState();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MasiColors.of(context);
    return SingleChildScrollView(
      key: const Key('community-offline-empty'),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MasiIcon('phone_off', size: 40, color: colors.accent),
            const SizedBox(height: MasiSpacing.md),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: MasiSpacing.lg),
              child: Text(
                "Can't check for shared topos while you're offline",
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(color: colors.ink2),
              ),
            ),
            const SizedBox(height: MasiSpacing.md),
            // Re-probes reachability first, then re-pulls ONLY if that fresh
            // probe actually came back online -- same reasoning as
            // `_ToposScreenState._handleOfflineRetry`. Never throws:
            // `refresh()`/`pullNow()` are both documented not to.
            MasiPendingButton.text(
              key: const Key('community-offline-retry'),
              onPressed: () async {
                final verdict = await ref
                    .read(reachabilityProvider.notifier)
                    .refresh();
                if (verdict.isKnownOnline) {
                  await ref.read(syncOrchestratorProvider.notifier).pullNow();
                }
              },
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}

/// A single shared-topo row: thumbnail + name + grade pill + route count,
/// then like/comment counts + owner. Visually mirrors
/// `topos_screen.dart`'s `_TopoRow` (same 52x52 thumbnail, grade pill), plus
/// the community-specific like/comment/owner line.
///
/// A [ConsumerWidget] (rather than [StatelessWidget]) so it can watch
/// [authStateProvider] for the signed-in uid and mark the row as [_OwnBadge]
/// when [topo.ownerId] matches it — the row must rebuild live on sign-in/out,
/// not just render once with a stale uid.
class _FeedRow extends ConsumerWidget {
  const _FeedRow({required this.topo, this.alternates = const []});

  final SharedTopo topo;

  /// Other topos of the same PLACE (community editing phase 8b / C-6.2).
  /// Empty for almost every row.
  final List<SharedTopo> alternates;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final wallId = topo.wallId;
    // §1c: the single local-data uid door — never `authStateProvider.asData`,
    // which reads null on AsyncError too.
    final myUid = ref.watch(effectiveUidProvider);
    final isMine = topo.ownerId != null && topo.ownerId == myUid;

    // #18: resolve the owner's synced display name rather than showing the
    // raw uid. `null` (no ownerId at all, no profile row yet, or an empty
    // name) all collapse to the same "Unknown climber" fallback below — the
    // raw uid must never render.
    final ownerId = topo.ownerId;
    final ownerDisplayName = ownerId != null
        ? ref.watch(profileDisplayNameProvider(ownerId)).asData?.value
        : null;

    return Material(
      key: Key('community-topo-row-$wallId'),
      color: colors.surface,
      borderRadius: BorderRadius.circular(MasiRadii.card),
      child: InkWell(
        borderRadius: BorderRadius.circular(MasiRadii.card),
        onTap: () {
          FocusManager.instance.primaryFocus?.unfocus();
          context.push('/community/topo/$wallId');
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: MasiSpacing.md,
            vertical: MasiSpacing.sm,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Thumbnail(path: topo.thumbnailPath),
              const SizedBox(width: MasiSpacing.md),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      topo.name,
                      style: textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Wrap(
                      spacing: MasiSpacing.xs,
                      runSpacing: 2,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (topo.topGradeLabel != null &&
                            topo.topGradeBand != null)
                          _GradePill(
                            label: topo.topGradeLabel!,
                            band: topo.topGradeBand!,
                          ),
                        Text(
                          '${topo.routeCount} route${topo.routeCount == 1 ? '' : 's'}',
                          style: textTheme.titleSmall?.copyWith(
                            color: colors.ink2,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (isMine) _OwnBadge(wallId: wallId),
                        if (alternates.isNotEmpty)
                          _PlaceBadge(
                            wallId: wallId,
                            count: alternates.length + 1,
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Flexible(
                          child: Text(
                            '♥ ${topo.likeCount}',
                            key: Key('community-topo-row-$wallId-likes'),
                            style: textTheme.titleSmall?.copyWith(
                              color: colors.ink2,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: MasiSpacing.sm),
                        Flexible(
                          child: Row(
                            key: Key('community-topo-row-$wallId-comments'),
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              MasiIcon(
                                'comment',
                                size: 16,
                                color: colors.ink3,
                              ),
                              const SizedBox(width: 2),
                              Text(
                                '${topo.commentCount}',
                                style: textTheme.titleSmall?.copyWith(
                                  color: colors.ink2,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: MasiSpacing.sm),
                        Expanded(
                          child: Text(
                            (ownerDisplayName != null &&
                                    ownerDisplayName.isNotEmpty)
                                ? 'by $ownerDisplayName'
                                : 'Unknown climber',
                            style: textTheme.bodySmall?.copyWith(
                              color: colors.ink3,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              MasiIcon('chevron_right', color: colors.ink3),
            ],
          ),
        ),
      ),
    );
  }
}

/// A single shared-ascent-log row (#12 Wave 3, ST5): the [FeedItem] union's
/// other variant alongside [_FeedRow] — a climber's opt-in-`shared`
/// [SharedAscentEntry] rather than a shared topo. Visually echoes
/// `logbook_screen.dart`'s `_LogbookEntryRow` (grade swatch + title/grade +
/// wall + "style · date" line — reusing that screen's public [styleLabel]
/// helper for the exact same style label text) PLUS [_FeedRow]'s
/// like/comment-count + attributed-owner line, since a Feed row needs both
/// the climb's own metadata AND community engagement counts that a purely
/// personal Logbook entry never shows.
///
/// A [ConsumerWidget] so it can watch [profileDisplayNameProvider] (the same
/// #18 owner-name resolution [_FeedRow] uses — "Unknown climber" is the
/// identical fallback, never a raw uid) and the ascent-scoped
/// `likeCountForAscentProvider`/`commentsForAscentProvider` live.
class _AscentFeedRow extends ConsumerWidget {
  const _AscentFeedRow({required this.entry});

  final SharedAscentEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final ascentId = entry.ascentId;

    // #18-style resolution (see `_FeedRow`'s identical block above): `null`
    // ownerId, no profile row yet, or an empty name all collapse to the same
    // "Unknown climber" fallback — the raw uid must never render.
    final ownerId = entry.ownerId;
    final climberName = ownerId != null
        ? ref.watch(profileDisplayNameProvider(ownerId)).asData?.value
        : null;

    final likeCount =
        ref.watch(likeCountForAscentProvider(ascentId)).asData?.value ?? 0;
    final commentCount =
        ref.watch(commentsForAscentProvider(ascentId)).asData?.value.length ??
        0;

    final routeName = entry.routeName;
    final title = (routeName != null && routeName.isNotEmpty)
        ? routeName
        : 'Route ${entry.routeNumber ?? '?'}';

    return Material(
      key: Key('community-ascent-row-$ascentId'),
      color: colors.surface,
      borderRadius: BorderRadius.circular(MasiRadii.card),
      child: InkWell(
        borderRadius: BorderRadius.circular(MasiRadii.card),
        onTap: () {
          FocusManager.instance.primaryFocus?.unfocus();
          context.push('/community/ascent/$ascentId');
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: MasiSpacing.md,
            vertical: MasiSpacing.sm,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _AscentGradeSwatch(band: entry.gradeBand),
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
                      '${_formatAscentDate(entry.climbedAt)}',
                      style: textTheme.titleSmall?.copyWith(
                        color: colors.ink2,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Flexible(
                          child: Row(
                            key: Key(
                              'community-ascent-row-$ascentId-likes',
                            ),
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              MasiIcon('heart', size: 16, color: colors.ink3),
                              const SizedBox(width: 2),
                              Text(
                                '$likeCount',
                                style: textTheme.titleSmall?.copyWith(
                                  color: colors.ink2,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: MasiSpacing.sm),
                        Flexible(
                          child: Row(
                            key: Key(
                              'community-ascent-row-$ascentId-comments',
                            ),
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              MasiIcon(
                                'comment',
                                size: 16,
                                color: colors.ink3,
                              ),
                              const SizedBox(width: 2),
                              Text(
                                '$commentCount',
                                style: textTheme.titleSmall?.copyWith(
                                  color: colors.ink2,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: MasiSpacing.sm),
                        Expanded(
                          child: Text(
                            (climberName != null && climberName.isNotEmpty)
                                ? 'by $climberName'
                                : 'Unknown climber',
                            style: textTheme.bodySmall?.copyWith(
                              color: colors.ink3,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              MasiIcon('chevron_right', color: colors.ink3),
            ],
          ),
        ),
      ),
    );
  }
}

/// Small rounded grade-band swatch, colored via [_colorForGradeBand] —
/// mirrors `logbook_screen.dart`'s private `_GradeSwatch` exactly (not
/// reused directly: that one is library-private to `logbook_screen.dart`,
/// and this file already carries its own [_colorForGradeBand] helper for
/// [_GradePill]). A `null` [band] (no graded route resolved for this ascent)
/// renders a neutral placeholder fill.
class _AscentGradeSwatch extends StatelessWidget {
  const _AscentGradeSwatch({required this.band});

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

const List<String> _ascentMonthAbbreviations = [
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

/// Formats [date] as e.g. `'Jul 1, 2026'` — mirrors `logbook_screen.dart`'s
/// private `_formatDate` exactly (not reused directly: that one is
/// library-private). Converts to local time first (`toLocal()`) —
/// `SharedAscentEntry.climbedAt` is stored as UTC, so extracting
/// month/day/year directly off it would show the UTC calendar day, not the
/// user's local day.
String _formatAscentDate(DateTime date) {
  final local = date.toLocal();
  return '${_ascentMonthAbbreviations[local.month - 1]} ${local.day}, '
      '${local.year}';
}

/// Compact "Yours" badge marking a feed row as one of the signed-in user's
/// own published topos — the Community-side half of the "clear division
/// between community and own topos" pairing with `topos_screen.dart`'s
/// `_VisibilityBadge`. Placed inside the row's grade/route-count [Wrap]
/// (never the likes/comments/owner [Row] below, which stays untouched) so
/// it wraps safely at large text scales instead of widening anything; text
/// is a single short word, never flexible.
class _OwnBadge extends StatelessWidget {
  const _OwnBadge({required this.wallId});

  final String wallId;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;

    return Semantics(
      label: 'Your topo',
      child: Container(
        key: Key('community-own-badge-$wallId'),
        padding: const EdgeInsets.symmetric(
          horizontal: MasiSpacing.xs,
          vertical: 2,
        ),
        decoration: BoxDecoration(
          color: colors.accent,
          borderRadius: BorderRadius.circular(MasiRadii.control),
        ),
        child: Text(
          'Yours',
          style: textTheme.labelSmall?.copyWith(
            color: colors.onAccent,
            fontWeight: FontWeight.w600,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}

/// "3 topos" — this card stands for a PLACE with more than one topo of it
/// (community editing phase 8b / C-6.2).
///
/// Muted rather than accented, and it does not compete with "Yours": several
/// people having drawn the same boulder is context, not an alert. The feed
/// collapsed them into one card so the reader is not scrolling past four
/// near-identical rows; this badge is the affordance that says the other three
/// are still there and reachable.
class _PlaceBadge extends StatelessWidget {
  const _PlaceBadge({required this.wallId, required this.count});

  final String wallId;
  final int count;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;

    return Semantics(
      label: '$count topos of this place',
      child: Container(
        key: Key('community-place-badge-$wallId'),
        padding: const EdgeInsets.symmetric(
          horizontal: MasiSpacing.xs,
          vertical: 2,
        ),
        decoration: BoxDecoration(
          color: colors.surface2,
          borderRadius: BorderRadius.circular(MasiRadii.control),
          border: Border.all(color: colors.separator),
        ),
        child: Text(
          '$count topos',
          style: textTheme.labelSmall?.copyWith(
            color: colors.ink2,
            fontWeight: FontWeight.w600,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}

/// Small grade pill matching `topos_screen.dart`'s `_GradePill` /
/// `grade_colors.dart`'s band-color convention (not reused directly: that
/// class is library-private to `topos_screen.dart`).
class _GradePill extends StatelessWidget {
  const _GradePill({required this.label, required this.band});

  final String label;
  final GradeBand band;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: MasiSpacing.sm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: _colorForGradeBand(colors, band),
        borderRadius: BorderRadius.circular(MasiRadii.control),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w600,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

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

/// 52x52 rounded thumbnail, mirroring `topos_screen.dart`'s `_Thumbnail`:
/// the topo's downscaled `thumbs/<id>.jpg` thumbnail (#56 — NOT the
/// full-resolution original) when readable, else an amethyst gradient
/// placeholder (never a broken-image icon) — see that class's doc for what
/// [PhotoImage]'s `placeholder`/`loadingPlaceholder` cover.
class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.path});

  final String? path;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final radius = BorderRadius.circular(10);
    final thumbnailPath = path;
    // #56: decode at display size, not the original's full resolution —
    // the tile is 52 LOGICAL px, so the decode target is that times the
    // device's pixel ratio.
    final cachePx = (52 * MediaQuery.of(context).devicePixelRatio).round();

    final child = thumbnailPath == null
        ? _GradientFallback(colors: colors)
        : PhotoImage(
            thumbnailPath,
            width: 52,
            height: 52,
            fit: BoxFit.cover,
            cacheWidth: cachePx,
            cacheHeight: cachePx,
            placeholder: () => _GradientFallback(colors: colors),
            loadingPlaceholder: () => const MasiShimmer(),
          );

    return ClipRRect(
      borderRadius: radius,
      child: SizedBox(width: 52, height: 52, child: child),
    );
  }
}

class _GradientFallback extends StatelessWidget {
  const _GradientFallback({required this.colors});

  final MasiColors colors;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [colors.amethyst300, colors.amethyst500],
        ),
      ),
    );
  }
}
