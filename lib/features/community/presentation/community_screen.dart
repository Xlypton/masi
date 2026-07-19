import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' show Client, ClientException;
import 'package:http/retry.dart' show RetryClient;
import 'package:latlong2/latlong.dart';

import '../../../app/theme.dart';
import '../../../core/grades/grade_system.dart';
import '../../../shared/presentation/masi_icon.dart';
import '../../../core/location/geocoding_service.dart';
import '../../../core/location/location_service.dart';
import '../../../shared/filtering/grade_range_picker.dart';
import '../../../shared/filtering/style_filter_chips.dart';
import '../../../shared/filtering/style_tag_filter_chips.dart';
import '../../account/application/auth_providers.dart';
import '../../library/application/library_providers.dart';
import '../application/community_providers.dart';
import '../application/map_search_providers.dart';
import '../data/community_repository.dart';
import '../data/map_search.dart';

/// Builds the `RetryClient`-wrapped [http.Client] used by
/// [buildResilientTileProvider] — split out into its own top-level function
/// so the RAW client (needed to `.close()` it later — see MAJOR 2 in
/// `_MapViewState`'s fix history) is reachable independently of the
/// [NetworkTileProvider] wrapper built around it.
///
/// [NetworkTileProvider]'s own default HTTP client only retries a bare `503`
/// response — never `429` (exactly what CartoDB returns once a device's tile
/// requests get throttled) nor a transient connection error/timeout. A tile
/// that fails once under the default client is never retried, so it renders
/// as flutter_map's flat gray error-tile placeholder forever, even long
/// after the throttling/network blip has cleared. Retrying 429/5xx and
/// `SocketException`/`ClientException` with a short exponential backoff
/// lets those same tiles succeed on a later attempt instead.
///
/// [inner] overrides the actual transport wrapped by the retry policy
/// (production leaves it null, getting a real [Client]) — used by
/// `_MapViewState._tileProvider` to accept a test-injected
/// `tileHttpClientFactory` (see `community_screen_test.dart`'s FX3), so a
/// test can exercise this exact retry-policy wiring with a fake, non-network
/// transport instead of a real socket.
Client buildResilientTileHttpClient({Client? inner}) {
  return RetryClient(
    inner ?? Client(),
    retries: 4,
    when: (response) =>
        response.statusCode == 429 || response.statusCode >= 500,
    whenError: (error, stackTrace) =>
        error is SocketException || error is ClientException,
    delay: (retryCount) => Duration(milliseconds: 200 * (1 << retryCount)),
  );
}

/// Builds the production [NetworkTileProvider] for the Map tab's [TileLayer],
/// backed by [buildResilientTileHttpClient]'s retry policy — or, when
/// [httpClient] is given, that client instead (used by [_MapViewState]'s
/// create-once tile-provider cache, which needs to hold onto the raw client
/// to close it later).
///
/// [cachingProvider] defaults to null, i.e. flutter_map's own default (the
/// on-disk [BuiltInMapCachingProvider]) — overridden to
/// [DisabledMapCachingProvider] only by `_MapViewState._tileProvider` when a
/// test's `tileHttpClientFactory` is in play, so that test never performs
/// real platform-channel/file I/O for a cache directory `flutter_test`
/// never provides. Production, which never sets `tileHttpClientFactory`, is
/// completely unaffected and keeps the real on-disk cache.
///
/// A named top-level function (rather than an inline `NetworkTileProvider()`
/// call at the `TileLayer` call site) so this policy is unit-testable on its
/// own — see `community_screen_test.dart`'s MC2 — without needing to pump a
/// full widget tree or perform real network I/O.
NetworkTileProvider buildResilientTileProvider({
  Client? httpClient,
  MapCachingProvider? cachingProvider,
}) {
  return NetworkTileProvider(
    httpClient: httpClient ?? buildResilientTileHttpClient(),
    cachingProvider: cachingProvider,
  );
}

/// Test-only instrumentation for MAJOR 2's create-once/dispose-closes-client
/// fix (see `_MapViewState`'s `_tileProvider`/`dispose`): incremented exactly
/// once per resilient tile HTTP client a `_MapViewState` itself creates
/// (never when a test injects its own `tileProvider`, e.g. `_NoopTileProvider`
/// — that path never touches these counters at all) and once per such client
/// a `dispose()` call actually closes. A secondary, always-safe confirmation
/// alongside `community_screen_test.dart`'s FX3, which primarily exercises
/// the real create-once/dispose-closes code path directly via a spy
/// `tileHttpClientFactory` (never real network I/O).
@visibleForTesting
int debugResilientTileClientCreateCount = 0;

@visibleForTesting
int debugResilientTileClientCloseCount = 0;

/// Resets [debugResilientTileClientCreateCount]/
/// [debugResilientTileClientCloseCount] to 0 — call from a test's setup so
/// counts from an earlier test in the same run never leak in.
@visibleForTesting
void debugResetResilientTileClientCounters() {
  debugResilientTileClientCreateCount = 0;
  debugResilientTileClientCloseCount = 0;
}

/// The Community Map tab (bottom-nav branch `/map`): an OpenStreetMap
/// [FlutterMap] with one marker per shared topo that has coordinates
/// (inherited from its ancestor Area), plus the signed-in user's own located
/// topos — see [_MapView]'s doc for the own-vs-community marker split. This
/// screen used to be one half of a combined `CommunityScreen`'s segmented
/// Feed/Map toggle; that toggle is gone (removed along with `CommunityTab`/
/// `CommunityScreen` entirely) now that the app's persistent bottom
/// navigation bar (`nav_shell.dart`) gives Map its own permanent branch,
/// independent of Feed ([CommunityFeedScreen]).
///
/// [tileProvider] is an injectable seam for the Map's [TileLayer], defaulting
/// (when `null`) to the real [NetworkTileProvider] backed by OpenStreetMap
/// tiles. Widget tests MUST override this with an in-memory fake so this
/// screen never performs real network I/O.
///
/// [focusWallId], when given, centers/zooms the map on that wall's
/// coordinates instead of the combined marker-set center — see [_MapView]'s
/// `focusWallId` doc. `router.dart`'s `/map` route builder passes this
/// straight from the `?focus=` query param, which is how the legacy
/// `/community?tab=map&focus=<id>` deep link (`topos_screen.dart`'s "Show on
/// map" action) still reaches a specific wall after being redirected here.
class CommunityMapScreen extends ConsumerStatefulWidget {
  const CommunityMapScreen({
    super.key,
    this.tileProvider,
    this.focusWallId,
    this.mapController,
    this.tileHttpClientFactory,
  });

  final TileProvider? tileProvider;
  final String? focusWallId;

  /// Test-injectable [MapController] seam, threaded through to [_MapView] —
  /// see that class's `controller` doc. Production code (the app's real
  /// `/map` route) leaves this null.
  @visibleForTesting
  final MapController? mapController;

  /// Test-injectable factory for the INNER [Client] wrapped by the Map's
  /// resilient tile provider, threaded through to [_MapView] — see that
  /// class's `tileHttpClientFactory` doc. Production code leaves this null.
  @visibleForTesting
  final Client Function()? tileHttpClientFactory;

  @override
  ConsumerState<CommunityMapScreen> createState() =>
      _CommunityMapScreenState();
}

class _CommunityMapScreenState extends ConsumerState<CommunityMapScreen> {
  @override
  Widget build(BuildContext context) {
    final asyncSharedTopos = ref.watch(sharedToposProvider);

    return Scaffold(
      key: const Key('community-map-screen'),
      appBar: AppBar(
        title: Text(
          'Map',
          style: Theme.of(context).textTheme.displaySmall,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        centerTitle: false,
      ),
      // `bottom: false` (#48, now shared by every branch since #51): this
      // screen's `_MapView` draws full-bleed behind `NavShell`'s translucent
      // bar (that Scaffold sets `extendBody: true` unconditionally — see its
      // doc), so the bottom device safe-area inset must NOT be consumed/
      // padded away here. If it were, the map would stop short at the
      // safe-area edge -- the SAME footprint as before extendBody -- rather
      // than truly extending behind the bar. `_MapView` reads that still-live
      // `MediaQuery.padding.bottom` itself (`bottomChromeInset`) to keep its
      // OWN bottom-anchored overlay controls floating above the bar instead.
      body: SafeArea(
        bottom: false,
        child: asyncSharedTopos.when(
          data: (topos) => _MapView(
            topos: topos,
            tileProvider: widget.tileProvider,
            focusWallId: widget.focusWallId,
            controller: widget.mapController,
            tileHttpClientFactory: widget.tileHttpClientFactory,
          ),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stackTrace) =>
              Center(child: Text('Something went wrong: $error')),
        ),
      ),
    );
  }
}

/// The Community Feed tab (bottom-nav branch `/feed`): a searchable list of
/// every shared topo (thumbnail, name, grade pill, like/comment counts,
/// owner) — see [_FeedView]. The other half of the former combined
/// `CommunityScreen`; see [CommunityMapScreen]'s doc for why the two are now
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
    final asyncSharedTopos = ref.watch(sharedToposProvider);

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
      ),
      // `bottom: false` (#51, mirrors `CommunityMapScreen`'s identical
      // `SafeArea` above): NavShell's Scaffold now extends every branch
      // full-bleed behind its floating glass bar, so this screen's REAL
      // measured bottom clearance must reach `_FeedView`'s list unconsumed
      // rather than being padded away here — see that widget's `build` for
      // where it's actually applied.
      body: SafeArea(
        bottom: false,
        child: asyncSharedTopos.when(
          data: (topos) => _FeedView(
            topos: topos,
            searchController: _searchController,
            query: _query,
          ),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stackTrace) =>
              Center(child: Text('Something went wrong: $error')),
        ),
      ),
    );
  }
}

/// The Feed tab: a search field + filter button over a list of [_FeedRow]s,
/// or [_EmptyState] when there are no shared topos at all (or none matching
/// the search / the [communityFilterProvider] grade+style filter).
///
/// Name search and the grade/style filter are ANDed together but kept as
/// two independently-diagnosable empty states (search narrows first, then
/// the filter) so a user who typed a matching name but filtered out every
/// result sees "No topos match your filters" rather than the more generic
/// "No topos match your search".
class _FeedView extends ConsumerWidget {
  const _FeedView({
    required this.topos,
    required this.searchController,
    required this.query,
  });

  final List<SharedTopo> topos;
  final TextEditingController searchController;
  final String query;

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
    final searchFiltered = query.isEmpty
        ? topos
        : topos.where((t) => t.name.toLowerCase().contains(query)).toList();
    final filtered = searchFiltered.where(filter.matches).toList();

    final String? emptyMessage = topos.isEmpty
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
                    prefixIcon: MasiIcon(
                      'search',
                      size: 13,
                      color: colors.ink3,
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
          child: emptyMessage != null
              ? _EmptyState(message: emptyMessage)
              : ListView.separated(
                  padding: EdgeInsets.fromLTRB(
                    MasiSpacing.lg,
                    MasiSpacing.sm,
                    MasiSpacing.lg,
                    MasiSpacing.sm + bottomChromeInset,
                  ),
                  itemCount: filtered.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: MasiSpacing.sm),
                  itemBuilder: (context, index) =>
                      _FeedRow(topo: filtered[index]),
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
                            topo.ownerId != null
                                ? 'by ${topo.ownerId}'
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
/// the topo's original photo when readable, else an amethyst gradient
/// placeholder (never a broken-image icon).
class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.path});

  final String? path;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final radius = BorderRadius.circular(10);
    final thumbnailPath = path;

    Widget child;
    if (thumbnailPath != null && File(thumbnailPath).existsSync()) {
      child = Image.file(
        File(thumbnailPath),
        width: 52,
        height: 52,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) =>
            _GradientFallback(colors: colors),
      );
    } else {
      child = _GradientFallback(colors: colors);
    }

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

/// The Map tab: an OpenStreetMap [FlutterMap] with one [Marker] per shared
/// topo that [SharedTopo.hasCoordinates] AND matches the current
/// [communityFilterProvider] — topos without coordinates, and topos
/// excluded by the filter, are simply omitted from the marker list, never
/// crash the map — PLUS a second, visually distinct ("Yours") marker set for
/// the signed-in user's own located topos (from [toposProvider], which is
/// EVERY non-deleted local wall regardless of [TopoRef.visibility] — a
/// freshly-picked photo's GPS location must show up immediately even while
/// the topo is still private, before it's ever published). See this class's
/// `build` method for how "own" is determined and deduped against the
/// shared set.
///
/// A [ConsumerStatefulWidget] (rather than [ConsumerWidget]) so it can own a
/// [MapController] for the find-me control added over the map — see
/// [_MapViewState].
class _MapView extends ConsumerStatefulWidget {
  const _MapView({
    required this.topos,
    required this.tileProvider,
    this.focusWallId,
    this.controller,
    this.tileHttpClientFactory,
  });

  final List<SharedTopo> topos;
  final TileProvider? tileProvider;

  /// When non-null AND found among this build's own/community located
  /// topos, overrides the map's initial center to that wall's coordinates
  /// at an elevated zoom (see [_MapViewState.build]'s `hasFocus` branch) so
  /// a single "Show on map" deep link (`topos_screen.dart`'s `_TopoRow`, via
  /// `/community?tab=map&focus=<wallId>`) frames that one boulder instead of
  /// the whole combined marker set. A `focusWallId` that doesn't match any
  /// rendered topo (not found, filtered out, or simply lacking coordinates)
  /// silently falls back to the existing combined-set center/zoom — it must
  /// never crash or blank the map.
  final String? focusWallId;

  /// Test-injectable [MapController] seam (see `community_screen_test.dart`'s
  /// MC3: a test supplies its own controller and reads `controller.camera`
  /// after driving a tap on `community-map-find-me`; FX2a/FX3 similarly
  /// inject a controller to call `.rotate(...)` directly — no on-screen
  /// control can trigger rotation anymore, see [_rotationDegrees]'s doc).
  /// Production code (`CommunityScreen`) leaves this null, and
  /// [_MapViewState] creates, owns, and disposes its own instead.
  @visibleForTesting
  final MapController? controller;

  /// Test-injectable factory for the INNER [Client] wrapped by
  /// [_MapViewState]'s create-once resilient tile provider (see that
  /// class's `_tileProvider` doc) — used by `community_screen_test.dart`'s
  /// FX3 to exercise the real `buildResilientTileHttpClient`/
  /// `buildResilientTileProvider` wiring, create-once caching, and
  /// dispose-closes-client behavior end-to-end with a spy [Client] that
  /// resolves fake responses synchronously, instead of a real socket.
  /// Deliberately separate from [tileProvider] (which bypasses this whole
  /// path). Production (`CommunityScreen`) leaves this null.
  @visibleForTesting
  final Client Function()? tileHttpClientFactory;

  @override
  ConsumerState<_MapView> createState() => _MapViewState();
}

class _MapViewState extends ConsumerState<_MapView> {
  late final MapController _mapController;
  late final bool _ownsController;
  StreamSubscription<MapEvent>? _mapEventSubscription;

  /// The map's current bearing, mirrored from [MapController.mapEventStream]
  /// — kept as widget state (rather than read directly off
  /// `_mapController.camera` inside `build`) because a controller-driven
  /// rotation does not, on its own, trigger a rebuild of this widget. No
  /// on-screen control reads this value anymore: the compass button that
  /// used to display/reset it was removed once accidental two-finger-twist
  /// rotation was disabled via `InteractionOptions.flags` in [build] (at
  /// which point production code can no longer rotate the camera at all —
  /// see [_MapControlButton] and this class's `build`). Retained so
  /// `community_screen_test.dart`'s FX3 (MAJOR 2) regression test still has
  /// an already-wired, lightweight way to force a [_MapViewState] rebuild
  /// (via the test's own `MapController.rotate(...)` call) and prove the
  /// resilient tile provider survives it unchanged.
  double _rotationDegrees = 0;

  /// One-shot guard for the imperative device-location auto-center in
  /// [build]'s `ref.listen(myLocationProvider, ...)` — see MAJOR 1 in this
  /// class's fix history. Sticks at `true` for the rest of this
  /// [_MapViewState]'s lifetime once the camera has been auto-centered once,
  /// so a later, unrelated rebuild (e.g. the rotation-tracking `setState`
  /// described in [_rotationDegrees]'s doc) can never re-fight the user by
  /// moving the camera back.
  bool _didAutoCenter = false;

  /// The resilient tile HTTP client THIS state created (see [_tileProvider]),
  /// held so [dispose] can close exactly it — never an injected
  /// `widget.tileProvider` (e.g. every existing test's `_NoopTileProvider`),
  /// which this widget never owns and must never touch. Stays `null` for
  /// this whole state's lifetime whenever `widget.tileProvider` is non-null.
  Client? _tileHttpClient;

  /// The create-once resilient [NetworkTileProvider] built by
  /// [_tileProvider] the first time it's needed — see that method's doc for
  /// why this must be cached rather than rebuilt on every `build()` call.
  NetworkTileProvider? _resilientTileProvider;

  /// Backing state for the unified map-search overlay (`community-map-
  /// search-field`) — mirrors `set_location_picker.dart`'s
  /// `_SetLocationPickerState` search fields exactly (same debounce/seq-
  /// guard/programmatic-suppression skeleton), extended to merge in local
  /// library content alongside places.
  ///
  /// [_searchController] holds the typed/picked text, [_searchFocusNode]
  /// lets a selection unfocus the field afterward, [_debounce] is the
  /// in-flight "wait for the user to stop typing" timer (see
  /// [_onSearchChanged]).
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  Timer? _debounce;

  /// The last query the debounce timer actually SETTLED on (as opposed to
  /// every keystroke) — used to `ref.watch(mapContentSearchProvider(...))`
  /// reactively in [build] rather than one-shot `ref.read`ing it at debounce
  /// time, so local results stay live (and correctly empty rather than
  /// falsely-empty) even if the underlying located-topo/route/sector/area
  /// streams hadn't emitted their first snapshot yet the instant the
  /// debounce fired. Empty string means "no committed query" — [build]
  /// treats that as zero local results without even touching the provider.
  String _committedQuery = '';

  /// The current async place (geocoding) results for [_committedQuery] —
  /// unlike local results, these can't be a reactive `ref.watch` (a
  /// [GeocodingService] call is a one-shot Future, not a stream), so they're
  /// held as plain state and applied by [_runPlaceSearch] once resolved.
  List<PlaceResult> _placeResults = const [];

  /// Monotonically increasing "which search is current" generation counter —
  /// see `set_location_picker.dart`'s identically-named field for the full
  /// rationale (a slow lookup for an earlier query must never clobber a
  /// faster, more recent one's results). Bumped by every [_onSearchChanged]
  /// call and by every selection, and checked after every `await` before
  /// applying a result.
  int _searchSeq = 0;

  /// The exact (trimmed) query a selection last wrote into
  /// [_searchController] programmatically, or `null` when the field's
  /// current text was typed by the user — see `set_location_picker.dart`'s
  /// identically-named field. [_onSearchChanged] compares against this to
  /// no-op the synthetic "change" a selection's own `_searchController.text
  /// =` write fires, rather than kicking off a fresh search for the
  /// place/entity just picked.
  String? _lastProgrammaticQuery;

  /// The map location of the most recently selected search result (local or
  /// place), or `null` when there is none — drives the transient
  /// `community-map-search-marker` [MarkerLayer] in [build]. Cleared
  /// whenever the search field is cleared (see [_onSearchChanged]'s
  /// empty-query branch) or replaced by a fresh selection.
  LatLng? _selectedSearchResult;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _mapController = widget.controller ?? MapController();
    _mapEventSubscription = _mapController.mapEventStream.listen((event) {
      final rotation = _mapController.camera.rotation;
      if (rotation != _rotationDegrees) {
        setState(() => _rotationDegrees = rotation);
      }
    });
  }

  @override
  void dispose() {
    _mapEventSubscription?.cancel();
    _debounce?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
    if (_ownsController) {
      _mapController.dispose();
    }
    // Close exactly the client THIS state created (see [_tileProvider]) —
    // an injected `widget.tileProvider` leaves `_tileHttpClient` null and is
    // never touched here; its lifecycle belongs to whoever injected it (see
    // MAJOR 2 in this class's fix history).
    final tileHttpClient = _tileHttpClient;
    if (tileHttpClient != null) {
      tileHttpClient.close();
      debugResilientTileClientCloseCount++;
    }
    super.dispose();
  }

  /// `community-map-search-field`'s `onChanged` handler — see
  /// `set_location_picker.dart`'s identically-shaped [_onSearchChanged] for
  /// the full debounce/seq-guard/programmatic-suppression rationale, which
  /// this mirrors exactly. The only difference: settling on a non-empty
  /// query here commits [_committedQuery] (driving the reactive local
  /// results in [build]) AND kicks off [_runPlaceSearch] (the async places
  /// half), rather than a single async lookup.
  void _onSearchChanged(String value) {
    if (value == _lastProgrammaticQuery) {
      _lastProgrammaticQuery = null;
      return;
    }
    _lastProgrammaticQuery = null;
    _debounce?.cancel();
    final query = value.trim();
    _searchSeq++;
    final seq = _searchSeq;
    if (query.isEmpty) {
      setState(() {
        _committedQuery = '';
        _placeResults = const [];
        _selectedSearchResult = null;
      });
      return;
    }
    _debounce = Timer(
      const Duration(milliseconds: 350),
      () => _settleSearch(query, seq),
    );
  }

  /// Runs once [_onSearchChanged]'s debounce timer fires for a non-empty,
  /// still-current ([seq] still matches [_searchSeq]) query: commits
  /// [_committedQuery] (so [build]'s `ref.watch(mapContentSearchProvider(...))`
  /// picks up local results reactively) and fires the async places lookup.
  void _settleSearch(String query, int seq) {
    if (!mounted || seq != _searchSeq) return;
    setState(() => _committedQuery = query);
    unawaited(_runPlaceSearch(query, seq));
  }

  /// The places half of a settled search: [GeocodingService.search] never
  /// throws (see its doc), so no try/catch is needed here. Discards the
  /// result when [seq] no longer matches [_searchSeq] by the time the
  /// `await` returns — i.e. a newer query (or a clear, or a selection) has
  /// superseded this one — so a slow lookup for an old query can never
  /// clobber a faster, more recent query's results.
  Future<void> _runPlaceSearch(String query, int seq) async {
    final service = ref.read(geocodingServiceProvider);
    final results = await service.search(query);
    if (!mounted || seq != _searchSeq) return;
    setState(() => _placeResults = results);
  }

  /// A local-content search result row's `onTap`: flies the map to it and
  /// drops the transient `community-map-search-marker`. Mirrors
  /// [_selectPlaceResult] exactly except for the source of the flown-to
  /// point; see that method's doc for the programmatic-suppression/seq-bump
  /// rationale shared by both.
  void _selectLocalResult(MapSearchResult result) {
    _debounce?.cancel();
    _searchSeq++;
    _mapController.move(result.location, 15);
    _lastProgrammaticQuery = result.title;
    _searchController.text = result.title;
    setState(() {
      _selectedSearchResult = result.location;
      _committedQuery = '';
      _placeResults = const [];
    });
    _searchFocusNode.unfocus();
  }

  /// A place (geocoding) search result row's `onTap` — mirrors
  /// `set_location_picker.dart`'s `_selectSearchResult`: moves the map to
  /// the chosen place, then collapses the dropdown and unfocuses the field.
  ///
  /// Writes [result.displayName] into [_searchController] so the field
  /// visibly reflects what was picked. That write fires
  /// [TextEditingController]'s change notification straight into
  /// [_onSearchChanged] (the same listener `TextField.onChanged` uses),
  /// which would otherwise kick off a brand-new debounced search for the
  /// place's own name — so [_lastProgrammaticQuery] is set to the exact
  /// string being written FIRST, letting [_onSearchChanged] recognize and
  /// no-op that one synthetic change. [_searchSeq] is bumped independently
  /// too, invalidating any search still in flight for whatever the user had
  /// typed, so a stale in-flight lookup can never resurrect the dropdown
  /// after this selection.
  void _selectPlaceResult(PlaceResult result) {
    final location = LatLng(result.latitude, result.longitude);
    _debounce?.cancel();
    _searchSeq++;
    _mapController.move(location, 15);
    _lastProgrammaticQuery = result.displayName;
    _searchController.text = result.displayName;
    setState(() {
      _selectedSearchResult = location;
      _committedQuery = '';
      _placeResults = const [];
    });
    _searchFocusNode.unfocus();
  }

  /// The Map tab's [TileLayer.tileProvider]: [widget.tileProvider] when
  /// injected (every existing test's `_NoopTileProvider`, bypassing this
  /// entirely so no client is ever created under `flutter_test`), else a
  /// resilient [NetworkTileProvider] built ONCE for this [_MapViewState]'s
  /// entire lifetime and reused on every subsequent `build()` call — see
  /// MAJOR 2 in this class's fix history: calling `buildResilientTileProvider()`
  /// directly inline inside `build` allocated a brand-new provider +
  /// `RetryClient` + `http.Client` on EVERY rebuild (and the rotation-
  /// tracking `mapEventStream` listener — see [_rotationDegrees]'s doc —
  /// triggers a `setState` on every rotation frame), leaking one
  /// never-closed `http.Client` per rebuild — worse,
  /// passing an explicit `httpClient:` marks it as externally-owned, so even
  /// flutter_map's own `TileLayer.dispose() -> tileProvider.dispose()` would
  /// never have closed it anyway (see [NetworkTileProvider]'s
  /// `_isInternallyCreatedClient` guard). [dispose] above closes the client
  /// captured here explicitly instead of relying on that.
  TileProvider _tileProvider() {
    final injected = widget.tileProvider;
    if (injected != null) return injected;
    final existing = _resilientTileProvider;
    if (existing != null) return existing;
    final testFactory = widget.tileHttpClientFactory;
    final client = buildResilientTileHttpClient(inner: testFactory?.call());
    _tileHttpClient = client;
    debugResilientTileClientCreateCount++;
    final provider = buildResilientTileProvider(
      httpClient: client,
      // A test-injected `tileHttpClientFactory` (see
      // `community_screen_test.dart`'s FX3) means we're under test with a
      // fake, non-network transport -- skip flutter_map's default on-disk
      // `BuiltInMapCachingProvider` in that case only, since it would
      // otherwise perform real platform-channel/file I/O for a cache
      // directory `flutter_test` never provides. Production
      // (`testFactory == null`) is completely unaffected and keeps the
      // default on-disk cache.
      cachingProvider:
          testFactory != null ? const DisabledMapCachingProvider() : null,
    );
    _resilientTileProvider = provider;
    return provider;
  }

  /// `community-map-find-me`'s handler: fetches ONE fresh fix (never the
  /// possibly-stale [myLocationProvider] value already driving the "you are
  /// here" marker) and recenters the map on it at a walking-around zoom.
  /// [LocationService.currentLocation] never throws (see its doc) — a
  /// `null` result (denied/disabled/unavailable) surfaces as a SnackBar
  /// instead of moving the map.
  Future<void> _onFindMePressed() async {
    final location = await ref.read(locationServiceProvider).currentLocation();
    if (!mounted) return;
    if (location == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Location unavailable')),
      );
      return;
    }
    _mapController.move(LatLng(location.latitude, location.longitude), 14);
  }

  @override
  Widget build(BuildContext context) {
    final filter = ref.watch(communityFilterProvider);
    final filteredTopos = widget.topos.where(filter.matches).toList();
    final colors = MasiColors.of(context);
    final withCoords = filteredTopos.where((t) => t.hasCoordinates).toList();

    // The Map branch draws full-bleed behind the floating glass bottom-nav
    // bar (#48, generalized to every branch by #51 — see `nav_shell.dart`'s
    // `NavShell` doc: `Scaffold.extendBody: true` unconditionally), so this
    // view's OWN bottom-anchored overlay chrome -- the find-me control below,
    // plus the attribution/
    // legend pills baked into `flutterMap`'s children -- must add clearance
    // itself or it renders obscured behind the bar. Under `extendBody`,
    // Flutter's `Scaffold` already computes exactly that clearance for us:
    // `MediaQuery.of(context).padding.bottom` here is the REAL measured
    // `bottomNavigationBar` height (maxed with the device safe-area inset —
    // see `_BodyBuilder`/`bottomWidgetsHeight` in Flutter's `scaffold.dart`),
    // reaching this widget unconsumed because `CommunityMapScreen`'s own
    // `SafeArea` above uses `bottom: false`. No hand-maintained height
    // constant needed, and it stays correct across text-scale/device
    // changes.
    final bottomChromeInset = MediaQuery.of(context).padding.bottom;

    // The unified map search's local-content half (B2): reactively watched
    // (rather than one-shot `ref.read`) so results stay correct even if the
    // underlying located-topo/route/sector/area streams hadn't emitted their
    // first snapshot yet the instant `_settleSearch` committed the query —
    // see `_committedQuery`'s doc. An empty committed query (nothing typed
    // yet, or the field was just cleared/a result just selected) skips the
    // provider entirely rather than watching `mapContentSearchProvider('')`
    // (which would return `[]` anyway, per that provider's doc, but every
    // OTHER query string still gets its own cached entry there).
    final localSearchResults = _committedQuery.isEmpty
        ? const <MapSearchResult>[]
        : ref.watch(mapContentSearchProvider(_committedQuery));
    final showSearchDropdown =
        localSearchResults.isNotEmpty || _placeResults.isNotEmpty;

    // "Own" located topos: every local wall (regardless of visibility) that
    // has coordinates AND isn't actually someone else's shared topo pulled
    // down onto this device by sync (see `SyncService.pullOwnAndShared` --
    // sync only ever pulls ANOTHER user's wall when it's already
    // `visibility == 'shared'`, so a wall this device has never seen in the
    // shared feed at all is guaranteed local-only, i.e. always "mine").
    // Cross-referencing the ALREADY-FETCHED, unfiltered `topos` (rather than
    // adding an `ownerId` column to `TopoRef`) keeps this a pure read of
    // data this widget already has.
    final myUid = ref.watch(authStateProvider).asData?.value.uid;
    final ownerByWallId = <String, String?>{
      for (final t in widget.topos) t.wallId: t.ownerId,
    };
    bool isMine(String wallId) {
      if (!ownerByWallId.containsKey(wallId)) {
        return true; // never surfaced in the shared feed -> local-only.
      }
      // A `null` owner on a wall that IS in the shared feed (a legacy/
      // pre-ownership row, or a transiently-null `myUid` while auth is
      // still resolving) can never be safely proven to be this device's
      // own -- `null == null` must NOT count as a match, or a foreign
      // shared topo with no owner stamp would be misclassified as "Yours"
      // and route into the EDITOR for a wall that isn't actually ours.
      // Degrade to the safe side (community / read-only detail) instead;
      // the `containsKey == false` branch above still correctly claims a
      // genuinely-local null-owner wall, since that one was never in the
      // shared feed at all.
      final owner = ownerByWallId[wallId];
      return owner != null && owner == myUid;
    }

    // Own markers are intentionally NEVER filtered by
    // `communityFilterProvider` (the grade/style filter above only applies
    // to `filteredTopos`/`withCoords`) -- they're the user's own reference
    // points and must always show regardless of the community filter.
    final ownTopos = ref.watch(toposProvider).asData?.value ?? [];
    final ownWithCoords = ownTopos
        .where((t) => t.latitude != null && t.longitude != null)
        .where((t) => isMine(t.wallId))
        .toList();

    // DEDUPE: a topo that is both own AND shared (a published own topo)
    // renders exactly once -- as the "Yours" marker below, never also as a
    // neutral community pin for the same wallId.
    final ownWallIds = ownWithCoords.map((t) => t.wallId).toSet();
    final communityWithCoords = withCoords
        .where((t) => !ownWallIds.contains(t.wallId))
        .toList();

    // Best-effort device position (see myLocationProvider's doc): loading,
    // error, and denied/unavailable (a `null` AsyncData) all collapse to
    // "no marker" here — the map and every topo marker render exactly the
    // same either way.
    final myLocation = ref.watch(myLocationProvider).asData?.value;

    // Centered/zoomed over the COMBINED (own + community, deduped)
    // coordinate set, so a user with only private, unpublished topos still
    // sees the map frame them, rather than the empty (0,0)/1.5 fallback.
    final combinedCoords = [
      for (final t in ownWithCoords) LatLng(t.latitude!, t.longitude!),
      for (final t in communityWithCoords) LatLng(t.latitude!, t.longitude!),
    ];

    // Imperative one-shot auto-center on the device's location — see MAJOR 1
    // / user request #39 in this class's fix history. `myLocation` above
    // comes from `myLocationProvider`, an autoDispose FutureProvider that's
    // still `AsyncLoading` (null) on this widget's FIRST build — applying it
    // only via `MapOptions.initialCenter` (honored by flutter_map exactly
    // ONCE, at first mount) would leave the map stuck at the (0,0)/1.5 world
    // view (or the topo-centroid frame) forever once the fix resolves a
    // moment later, since a later rebuild's freshly-computed `center` below
    // is never re-applied to an already-mounted map. `ref.listen` instead
    // fires the instant `myLocationProvider` actually transitions to a
    // resolved value, moving the (by-then-mounted) map's camera directly.
    //
    // Guarded to fire at most once per `_MapViewState` (`_didAutoCenter`),
    // and only when no `focusWallId` deep link is in play — deep links DO
    // work correctly via `initialCenter`/`initialZoom` below, since
    // `focusPoint` is already resolvable on this widget's first build — so
    // this never fights an explicit deep link. Deliberately fires REGARDLESS
    // of `combinedCoords` (user request #39: the map centers on the user's
    // OWN position even when located topos exist, overturning the previous
    // "frame the topos instead" rule) — and never fights the user
    // afterward (e.g. after they've since panned/zoomed/rotated away).
    ref.listen<AsyncValue<DeviceLocation?>>(myLocationProvider, (
      previous,
      next,
    ) {
      if (_didAutoCenter) return;
      if (widget.focusWallId != null) return;
      final loc = next.asData?.value;
      if (loc == null) return;
      _didAutoCenter = true;
      if (!mounted) return;
      try {
        _mapController.move(LatLng(loc.latitude, loc.longitude), 14);
      } catch (_) {
        // Defensive: a controller detached from its map (e.g. this widget
        // torn down in the same microtask the fix resolved) must never
        // crash — a missed one-shot auto-center is harmless; the user can
        // still center manually via `community-map-find-me`.
      }
    });

    // `focusWallId`, if given, overrides the combined center/zoom above --
    // checked against BOTH already-computed located sets (own first, since
    // an own+shared topo is deduped to render only as "own"; see this
    // class's doc), so a deep link works regardless of which marker family
    // the wall actually renders as. A focus id that matches neither (not
    // found / filtered out / no coordinates) leaves `focusPoint` null and
    // the combined-set behavior below is unaffected.
    LatLng? focusPoint;
    final focusId = widget.focusWallId;
    if (focusId != null) {
      for (final t in ownWithCoords) {
        if (t.wallId == focusId) {
          focusPoint = LatLng(t.latitude!, t.longitude!);
          break;
        }
      }
      if (focusPoint == null) {
        for (final t in communityWithCoords) {
          if (t.wallId == focusId) {
            focusPoint = LatLng(t.latitude!, t.longitude!);
            break;
          }
        }
      }
    }

    // User request #39: the map opens centered on the device's current
    // position, EVEN when located topos exist to frame instead — the
    // user's own position now wins over the topo-centroid frame. Priority:
    // `focusPoint` (an explicit deep link) > the device's location (whenever
    // no deep link is in play and a fix is available) > the topo centroid
    // (when located topos exist but no fix is available yet/ever) > the
    // maximally-unhelpful (0,0)/1.5 whole-world view. A `focusWallId` that
    // failed to resolve to a point (not found / filtered out / no
    // coordinates) deliberately still falls through to the location/centroid/
    // (0,0) chain below rather than silently substituting a DIFFERENT place
    // for a link that named a specific one.
    final useMyLocation = widget.focusWallId == null && myLocation != null;

    final center =
        focusPoint ??
        (useMyLocation
            ? LatLng(myLocation.latitude, myLocation.longitude)
            : (combinedCoords.isEmpty
                ? const LatLng(0, 0)
                : LatLng(
                    combinedCoords.map((p) => p.latitude).reduce(
                          (a, b) => a + b,
                        ) /
                        combinedCoords.length,
                    combinedCoords.map((p) => p.longitude).reduce(
                          (a, b) => a + b,
                        ) /
                        combinedCoords.length,
                  )));
    final zoom = focusPoint != null
        ? 15.0
        : (useMyLocation ? 14.0 : (combinedCoords.isEmpty ? 1.5 : 11.0));

    final flutterMap = FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: center,
        initialZoom: zoom,
        // Rotation is disabled outright — an accidental two-finger twist
        // must never spin the map. Every other usual pan/zoom gesture stays
        // enabled; only `InteractiveFlag.rotate` is omitted from the flags
        // that would otherwise default to `InteractiveFlag.all`.
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.drag |
              InteractiveFlag.flingAnimation |
              InteractiveFlag.pinchMove |
              InteractiveFlag.pinchZoom |
              InteractiveFlag.doubleTapZoom |
              InteractiveFlag.doubleTapDragZoom |
              InteractiveFlag.scrollWheelZoom,
        ),
      ),
      children: [
        TileLayer(
          urlTemplate:
              'https://basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png',
          userAgentPackageName: 'com.climbtopo.climbtopo',
          tileProvider: _tileProvider(),
          retinaMode: RetinaMode.isHighDensity(context),
          // Without this, a tile that fails once (transient CartoDB
          // throttling/network blip) is never evicted and therefore never
          // re-requested, leaving a permanent gray rectangle even as the
          // user zooms/pans past it. Evicting off-screen error tiles lets
          // them be re-fetched next time they scroll into view.
          evictErrorTileStrategy: EvictErrorTileStrategy.notVisibleRespectMargin,
          // CartoDB's light_all basemap serves real tiles through z20;
          // without this flutter_map stops fetching past its default native
          // zoom and upscales/blurs the last real tile instead.
          maxNativeZoom: 20,
          // Slightly larger than the default (2) ring of off-screen tiles
          // kept pre-fetched, so panning shows fewer transient gray edges.
          keepBuffer: 3,
        ),
        MarkerLayer(
          markers: [
            for (final topo in communityWithCoords)
              Marker(
                point: LatLng(topo.latitude!, topo.longitude!),
                width: 40,
                height: _BoulderMarker.totalHeight,
                alignment: Alignment.topCenter,
                child: GestureDetector(
                  key: Key('community-map-marker-${topo.wallId}'),
                  onTap: () {
                    FocusManager.instance.primaryFocus?.unfocus();
                    context.push('/community/topo/${topo.wallId}');
                  },
                  // Community-feed topos are, by construction, always
                  // shared/public (see `CommunityRepository.watchSharedTopos`
                  // -- the feed only ever contains `visibility == 'shared'`
                  // rows), so this marker always renders at full opacity
                  // (the public look).
                  child: _BoulderMarker(isPublic: true),
                ),
              ),
          ],
        ),
        // The signed-in user's own located topos -- see this class's `build`
        // doc for how "own" is determined/deduped. Its own [MarkerLayer]
        // (rather than sharing the one above) so ordering is explicit: own
        // markers paint above community ones, below "you are here".
        MarkerLayer(
          markers: [
            for (final topo in ownWithCoords)
              Marker(
                point: LatLng(topo.latitude!, topo.longitude!),
                width: 40,
                height: _BoulderMarker.totalHeight,
                alignment: Alignment.topCenter,
                child: GestureDetector(
                  key: Key('community-map-own-marker-${topo.wallId}'),
                  onTap: () {
                    FocusManager.instance.primaryFocus?.unfocus();
                    context.push('/walls/${topo.wallId}');
                  },
                  child: _BoulderMarker(isPublic: topo.visibility == 'shared'),
                ),
              ),
          ],
        ),
        // The "you are here" marker, in its own MarkerLayer placed AFTER the
        // topo markers' layer so it always paints above them (flutter_map
        // stacks `FlutterMap.children` in list order). Omitted entirely
        // whenever myLocation is null — loading, denied, disabled, or any
        // other resolution failure (see myLocationProvider's doc) — so the
        // map and topo markers are unaffected either way.
        if (myLocation != null)
          MarkerLayer(
            markers: [
              Marker(
                point: LatLng(myLocation.latitude, myLocation.longitude),
                width: _MyLocationMarker.size,
                height: _MyLocationMarker.size,
                alignment: Alignment.center,
                child: const KeyedSubtree(
                  key: Key('community-map-my-location'),
                  child: _MyLocationMarker(),
                ),
              ),
            ],
          ),
        // An always-visible custom credit pill — deliberately NOT a
        // `RichAttributionWidget`, whose OSM/CARTO text is hidden behind a
        // collapsed info-icon popup until tapped, which does not satisfy
        // OSM/CARTO's requirement that attribution be visible without
        // interaction. `IgnorePointer` keeps the pill from stealing marker
        // taps, and bottom-right placement keeps it clear of the pins.
        IgnorePointer(
          child: Align(
            alignment: Alignment.bottomRight,
            child: Padding(
              padding: EdgeInsets.fromLTRB(6, 6, 6, 6 + bottomChromeInset),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.surface.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  child: Text(
                    '© OpenStreetMap contributors · CARTO',
                    key: const Key('community-map-attribution'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: colors.ink2,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        // A compact "Private" vs "Public" legend, bottom-left (mirroring the
        // bottom-right attribution pill) so it never fights the search
        // overlay now anchored to the TOP of the map (see the outer Stack's
        // `community-map-search-field` `Positioned`, below) for space.
        // Purely informational (no tap target of its own), like the
        // attribution.
        IgnorePointer(
          child: Align(
            alignment: Alignment.bottomLeft,
            child: Padding(
              padding: EdgeInsets.fromLTRB(6, 6, 6, 6 + bottomChromeInset),
              child: _MapLegend(colors: colors),
            ),
          ),
        ),
        // The transient "search result" marker (B4): the map location most
        // recently flown to via a search selection (local content OR a
        // place), rendered in its OWN `MarkerLayer` added LAST in this list
        // so it always paints ABOVE every other marker layer above,
        // including the boulder/"you are here" ones (flutter_map stacks
        // `FlutterMap.children` in list order) — it's meant to read
        // unambiguously as "the spot you just searched for", never
        // confusable with an existing topo pin. Omitted entirely once
        // `_selectedSearchResult` is cleared (the field is cleared, or a
        // fresh selection replaces it — see `_onSearchChanged`/
        // `_selectLocalResult`/`_selectPlaceResult`).
        if (_selectedSearchResult != null)
          MarkerLayer(
            markers: [
              Marker(
                point: _selectedSearchResult!,
                width: 34,
                height: _SearchResultMarker.totalHeight,
                alignment: Alignment.topCenter,
                child: KeyedSubtree(
                  key: const Key('community-map-search-marker'),
                  child: _SearchResultMarker(colors: colors),
                ),
              ),
            ],
          ),
      ],
    );

    // Map controls (find-me) are siblings of the FlutterMap in a
    // Stack, ABOVE it — FlutterMap.children are map LAYERS (they scroll/zoom
    // with the map), whereas these controls must stay fixed to the screen.
    // Positioned bottom-right, above the attribution pill (which sits
    // flush at the very bottom-right — see the `IgnorePointer`/`Align`
    // above), so neither overlaps the other or the top-left legend.
    return Stack(
      children: [
        flutterMap,
        // The unified map-search overlay (B1): a pill search field + its
        // grouped results dropdown, anchored to the TOP of the map (the
        // bottom-left/bottom-right legend/attribution below leave this area
        // free — see their doc). A sibling of the bottom-right find-me
        // column in this same outer `Stack` (never a child of
        // `flutterMap` — unlike the marker layers above, this is fixed
        // screen chrome, not something that should pan/zoom with the map).
        Positioned(
          top: MasiSpacing.sm,
          left: MasiSpacing.lg,
          right: MasiSpacing.lg,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Material(
                color: Colors.transparent,
                child: TextField(
                  key: const Key('community-map-search-field'),
                  controller: _searchController,
                  focusNode: _searchFocusNode,
                  onChanged: _onSearchChanged,
                  decoration: InputDecoration(
                    hintText: 'Search the map',
                    prefixIcon: MasiIcon(
                      'search',
                      size: 13,
                      color: colors.ink3,
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
              // The results dropdown: LOCAL content (topos/routes/sectors/
              // areas — B3) ranked ABOVE places, simply by list order —
              // `localSearchResults` (already topos-then-routes-then-
              // sectors-then-areas per `mapContentSearch`'s doc) come first,
              // `_placeResults` last. Hidden entirely whenever both are
              // empty (no query committed yet, or a settled query matched
              // nothing on either side) — never a separate "loading"/error
              // state, mirroring `set_location_picker.dart`'s dropdown.
              if (showSearchDropdown)
                Container(
                  margin: const EdgeInsets.only(top: MasiSpacing.xs),
                  child: Material(
                    color: colors.surface,
                    borderRadius: BorderRadius.circular(MasiRadii.control),
                    clipBehavior: Clip.antiAlias,
                    elevation: 4,
                    // Caps how tall the dropdown can grow, mirroring
                    // `set_location_picker.dart`'s identical
                    // `_searchResultsMaxHeight` fix — a large `textScaler`
                    // or many combined local+place rows must scroll rather
                    // than push the dropdown off the bottom of small
                    // screens or overflow its `RenderFlex`.
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 280),
                      child: ListView.separated(
                        shrinkWrap: true,
                        padding: EdgeInsets.zero,
                        itemCount:
                            localSearchResults.length + _placeResults.length,
                        separatorBuilder: (_, _) =>
                            Divider(height: 1, color: colors.separator),
                        itemBuilder: (context, i) {
                          if (i < localSearchResults.length) {
                            final result = localSearchResults[i];
                            return ListTile(
                              key: Key('community-map-search-result-$i'),
                              dense: true,
                              leading: MasiIcon(
                                _iconForSearchKind(result.kind),
                                size: 18,
                                color: colors.ink3,
                              ),
                              title: Text(
                                result.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                result.subtitle != null
                                    ? '${_labelForSearchKind(result.kind)} · '
                                          '${result.subtitle}'
                                    : _labelForSearchKind(result.kind),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onTap: () => _selectLocalResult(result),
                            );
                          }
                          final place =
                              _placeResults[i - localSearchResults.length];
                          return ListTile(
                            key: Key('community-map-search-result-$i'),
                            dense: true,
                            leading: MasiIcon(
                              'pin',
                              size: 18,
                              color: colors.ink3,
                            ),
                            title: Text(
                              place.displayName,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: const Text(
                              'Place',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () => _selectPlaceResult(place),
                          );
                        },
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Positioned(
          right: 8,
          bottom: 44 + bottomChromeInset,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _MapControlButton(
                mapControlKey: const Key('community-map-find-me'),
                iconName: 'my_location',
                tooltip: 'Find my location',
                colors: colors,
                onPressed: _onFindMePressed,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A compact, theme-aware circular icon button for the Map tab's find-me
/// control (`community-map-find-me`) — styled with [MasiColors] rather than
/// Material's default `FloatingActionButton` look, to sit consistently with
/// the rest of the app's chrome.
///
/// [mapControlKey] (rather than a bare `key` ctor param) so the wrapping
/// [Material] — the actual hit-testable/keyed widget a test taps — carries
/// the stable key, since [_MapControlButton] itself is a plain
/// [StatelessWidget] whose own `key` only identifies it to Flutter's element
/// tree, not to `find.byKey` callers reaching for the tappable surface.
class _MapControlButton extends StatelessWidget {
  const _MapControlButton({
    required this.mapControlKey,
    required this.iconName,
    required this.tooltip,
    required this.colors,
    required this.onPressed,
  });

  final Key mapControlKey;
  final String iconName;
  final String tooltip;
  final MasiColors colors;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: mapControlKey,
      color: colors.surface,
      shape: const CircleBorder(),
      elevation: 2,
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: MasiIcon(iconName, color: colors.ink),
      ),
    );
  }
}

/// The Map tab's "Private"/"Public" key (`community-map-legend`),
/// explaining [_BoulderMarker]'s visibility-encoded look: since the marker
/// is now just the bare `boulder_logo` glyph (no ring/disc background --
/// see that class's doc), the cue for visibility is color -- a grayscale
/// swatch (matching [_BoulderMarker.greyscale]/`_privateMuteOpacity`) for
/// private topos, a full-color one for public -- every marker on the map
/// (own or community) follows that same rule, regardless of which
/// `MarkerLayer`/tap-target it belongs to.
class _MapLegend extends StatelessWidget {
  const _MapLegend({required this.colors});

  final MasiColors colors;

  @override
  Widget build(BuildContext context) {
    final textStyle = Theme.of(
      context,
    ).textTheme.labelSmall?.copyWith(color: colors.ink2);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          key: const Key('community-map-legend'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _MapLegendRow(
              isPublic: false,
              label: 'Private',
              textStyle: textStyle,
            ),
            const SizedBox(height: 4),
            _MapLegendRow(isPublic: true, label: 'Public', textStyle: textStyle),
          ],
        ),
      ),
    );
  }
}

class _MapLegendRow extends StatelessWidget {
  const _MapLegendRow({
    required this.isPublic,
    required this.label,
    this.textStyle,
  });

  final bool isPublic;
  final String label;
  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) {
    const swatch = MasiIcon('boulder_logo', tinted: false, size: 14);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        isPublic
            ? swatch
            : const Opacity(
                opacity: _BoulderMarker._privateMuteOpacity,
                child: ColorFiltered(
                  colorFilter: _BoulderMarker.greyscale,
                  child: swatch,
                ),
              ),
        const SizedBox(width: 6),
        Text(label, style: textStyle, maxLines: 1, overflow: TextOverflow.ellipsis),
      ],
    );
  }
}

/// The Map tab's "you are here" marker: a small filled blue dot with a white
/// ring (the familiar device-position convention), deliberately NOT styled
/// like [_BoulderMarker] — a plain dot centered exactly on the coordinate
/// (rather than a shape whose base sits at it) reads unambiguously as "this
/// is where I am", distinct from every topo's marker.
class _MyLocationMarker extends StatelessWidget {
  const _MyLocationMarker();

  static const double size = 18;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.blue,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: const [
          BoxShadow(
            color: Colors.black38,
            blurRadius: 4,
            offset: Offset(0, 1),
          ),
        ],
      ),
    );
  }
}

/// The transient "search result" marker (B4) `_MapViewState` drops at
/// `_selectedSearchResult` — a solid pin glyph, deliberately NOT
/// [_BoulderMarker]'s boulder-logo badge (that would read as "an existing
/// topo lives here") and NOT [_MyLocationMarker]'s plain dot (that already
/// means "this is my device"), so a searched-for spot reads unambiguously
/// as its own third thing on the map.
class _SearchResultMarker extends StatelessWidget {
  const _SearchResultMarker({required this.colors});

  final MasiColors colors;

  /// Total height of the enclosing [Marker] box — mirrors
  /// [_BoulderMarker.totalHeight]'s doc: [MarkerLayer] gives its child TIGHT
  /// `(width, height)` constraints regardless of the child's own size, so
  /// this only has to match the call site's `Marker.height`.
  static const double totalHeight = 34;

  @override
  Widget build(BuildContext context) {
    // A white halo behind the glyph keeps it legible over the light CartoDB
    // basemap regardless of the app's own light/dark theme, mirroring
    // `set_location_picker.dart`'s crosshair.
    return Align(
      alignment: Alignment.bottomCenter,
      child: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          MasiIcon('pin_fill', size: totalHeight, color: Colors.white),
          MasiIcon('pin_fill', size: totalHeight - 6, color: colors.accent),
        ],
      ),
    );
  }
}

/// Per-[MapSearchKind] type-hint icon for a `community-map-search-result-$i`
/// row (B3) — a topo IS a [TopoRef]/wall, hence `'wall'` rather than
/// [_BoulderMarker]'s full-color `'boulder_logo'` (which would be an
/// oddly heavy, multi-tone glyph for a small dropdown row).
String _iconForSearchKind(MapSearchKind kind) {
  switch (kind) {
    case MapSearchKind.topo:
      return 'wall';
    case MapSearchKind.route:
      return 'route';
    case MapSearchKind.sector:
      return 'signpost';
    case MapSearchKind.area:
      return 'mountain';
  }
}

/// Per-[MapSearchKind] type-hint label for a `community-map-search-result-$i`
/// row's subtitle (B3), prefixed onto [MapSearchResult.subtitle] when
/// present (a route/topo's parent wall/area name) or shown alone (sectors/
/// areas have no natural subtitle — see that field's doc).
String _labelForSearchKind(MapSearchKind kind) {
  switch (kind) {
    case MapSearchKind.topo:
      return 'Topo';
    case MapSearchKind.route:
      return 'Route';
    case MapSearchKind.sector:
      return 'Sector';
    case MapSearchKind.area:
      return 'Area';
  }
}

/// The Map tab's per-topo marker: JUST the app's `masi_boulder_logo` mark (a
/// full-color, multi-tone purple SVG — see `assets/icons/masi/`), with no
/// ring/disc background behind it — replacing this class's earlier look (a
/// colored ring badge + neutral inner disc behind the same logo), which
/// itself replaced an even older hand-painted faceted-boulder
/// `CustomPaint`/`_BoulderPainter`, and before that an app-icon-in-a-white-
/// circle pin (see [_MapPinBadge]/[_OwnMapPinBadge]). Used by BOTH the
/// community and own `MarkerLayer`s in [_MapView.build] — the own-vs-
/// community split still exists (separate layers/tap targets), it just
/// doesn't change the marker's look beyond [isPublic]'s color treatment
/// (below).
///
/// `masi_boulder_logo` is full-color/multi-tone, not a single-color glyph,
/// so it's rendered via `MasiIcon('boulder_logo', tinted: false)` — opting
/// out of [MasiIcon]'s default `BlendMode.srcIn` tint (see that widget's
/// `build`) so the logo shows its own natural colors instead of being
/// flattened to one. Since an un-tinted render ignores [MasiIcon.color]
/// entirely, and there's no background shape left to carry a color either,
/// the public/private distinction is carried by [greyscale]: public/shared
/// topos render the full-color glyph as-is, private ones render the SAME
/// glyph desaturated to grayscale (via [ColorFiltered]) plus a small extra
/// opacity fade ([_privateMuteOpacity]) for emphasis — color-vs-gray is the
/// PRIMARY cue (opacity alone, at 0.55, proved too subtle to read at a
/// glance — see this class's fix history), not opacity alone. Shared with
/// [_MapLegend]/[_MapLegendRow] so the legend's swatches always match the
/// marker exactly.
class _BoulderMarker extends StatelessWidget {
  const _BoulderMarker({required this.isPublic});

  final bool isPublic;

  /// Total height of the enclosing [Marker] box. This widget's own drawn
  /// content (see [_iconSize]) is deliberately SMALLER than this —
  /// [MarkerLayer] wraps every marker's child in a `Positioned(width:,
  /// height:)` inside a `Stack`, which gives it TIGHT constraints of
  /// exactly (`width`, `height`) regardless of the child's own size (see
  /// flutter_map's `marker_layer.dart`), so this constant only has to match
  /// the call sites' `Marker.height` for box-height tests to keep passing —
  /// the glyph itself is bottom-anchored inside that box (see [build]),
  /// which is what keeps its visual base sitting on the actual coordinate
  /// per `Alignment.topCenter`'s "anchors the box's bottom edge" semantics.
  /// Kept comfortably above [_iconSize] so the tap target stays generous
  /// even though the glyph itself shrank (28 -> 22, per user feedback that
  /// the marker read as too big).
  static const double totalHeight = 40;

  /// Size of the bare boulder-logo glyph. Shrunk from the previous 28 (user
  /// feedback: "the boulder icon on the map is a bit too big") while
  /// [totalHeight] stays unchanged, so the tap target doesn't shrink with
  /// it.
  static const double _iconSize = 22;

  /// Luminance-weighted (ITU-R BT.709) grayscale [ColorFilter] applied to a
  /// PRIVATE topo's glyph — the PRIMARY cue distinguishing private from
  /// public markers now that opacity alone ([_privateMuteOpacity]'s much
  /// milder fade) proved too subtle on its own. Shared with
  /// [_MapLegendRow] so the legend's "Private" swatch always matches the
  /// marker exactly.
  static const ColorFilter greyscale = ColorFilter.matrix(<double>[
    0.2126, 0.7152, 0.0722, 0, 0,
    0.2126, 0.7152, 0.0722, 0, 0,
    0.2126, 0.7152, 0.0722, 0, 0,
    0, 0, 0, 1, 0,
  ]);

  /// Small secondary fade layered on top of [greyscale] for a PRIVATE
  /// glyph, for extra muting — never the primary distinction (that's
  /// color-vs-gray above).
  static const double _privateMuteOpacity = 0.85;

  @override
  Widget build(BuildContext context) {
    const glyph = MasiIcon('boulder_logo', tinted: false, size: _iconSize);
    return Align(
      alignment: Alignment.bottomCenter,
      child: isPublic
          ? glyph
          : const Opacity(
              opacity: _privateMuteOpacity,
              child: ColorFiltered(colorFilter: greyscale, child: glyph),
            ),
    );
  }
}
