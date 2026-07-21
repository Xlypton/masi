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
import '../../backup/application/sync_orchestrator.dart';
import '../../logbook/data/ascents_repository.dart';
import '../../logbook/presentation/logbook_screen.dart' show styleLabel;
import '../../../shared/presentation/masi_shimmer.dart';
import '../../topo/presentation/photo_image.dart';
import '../application/community_providers.dart';
import '../application/community_topo_detail_providers.dart';
import '../data/community_repository.dart';
import 'community_shared.dart';

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
        child: asyncFeedItems.when(
          data: (items) => _FeedView(
            items: items,
            searchController: _searchController,
            query: _query,
          ),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stackTrace) => const CommunityErrorState(
            stateKey: Key('community-feed-error-state'),
            retryKey: Key('community-feed-retry'),
            message: "Couldn't load the community feed",
          ),
        ),
      ),
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
                          child: _EmptyState(message: emptyMessage),
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
                      TopoFeedItem(:final topo) => _FeedRow(topo: topo),
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
  const _FeedRow({required this.topo});

  final SharedTopo topo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final wallId = topo.wallId;
    final myUid = ref.watch(authStateProvider).asData?.value.uid;
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
