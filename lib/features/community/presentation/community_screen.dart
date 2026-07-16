import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' show Client, ClientException;
import 'package:http/retry.dart' show RetryClient;
// `hide Path`: latlong2 exports its own generic `Path<T>` (a geodesic path
// helper we never use here), which otherwise shadows dart:ui's `Path` (from
// `package:flutter/material.dart`) needed by `_BoulderPainter` below.
import 'package:latlong2/latlong.dart' hide Path;

import '../../../app/theme.dart';
import '../../../core/grades/grade_system.dart';
import '../../../shared/presentation/masi_icon.dart';
import '../../../core/location/location_service.dart';
import '../../../shared/filtering/grade_range_picker.dart';
import '../../../shared/filtering/style_filter_chips.dart';
import '../../account/application/auth_providers.dart';
import '../../library/application/library_providers.dart';
import '../application/community_providers.dart';
import '../data/community_repository.dart';

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

/// Which of the Community screen's two views is currently shown. Public
/// (unlike the rest of this file's private widgets) so it can be selected
/// from outside — [CommunityScreen.initialTab], and in turn `/app/router.dart`'s
/// `/community` route (deep-linked to the Map tab from a topo's "Show on
/// map" action — see `topos_screen.dart`'s `_TopoRow`).
enum CommunityTab { feed, map }

/// The Community discovery screen: a segmented Feed/Map toggle over every
/// shared topo (a Wall with `visibility == 'shared'`). Feed is a searchable
/// list of rows (thumbnail, name, grade pill, like/comment counts, owner);
/// Map is an OpenStreetMap [FlutterMap] with one marker per shared topo that
/// has coordinates (inherited from its ancestor Area).
///
/// [tileProvider] is an injectable seam for the Map tab's [TileLayer],
/// defaulting (when `null`) to the real [NetworkTileProvider] backed by
/// OpenStreetMap tiles. Widget tests MUST override this with an in-memory
/// fake so switching to the Map tab never performs real network I/O.
///
/// [initialTab] selects which tab this screen opens on (`null`, the
/// default, opens on Feed — the screen's previous unconditional behavior).
/// [focusWallId], when the Map tab is shown, centers/zooms the map on that
/// wall's coordinates instead of the combined marker-set center — see
/// `_MapView`'s `focusWallId` doc.
class CommunityScreen extends ConsumerStatefulWidget {
  const CommunityScreen({
    super.key,
    this.tileProvider,
    this.initialTab,
    this.focusWallId,
    this.mapController,
    this.tileHttpClientFactory,
  });

  final TileProvider? tileProvider;
  final CommunityTab? initialTab;
  final String? focusWallId;

  /// Test-injectable [MapController] seam, threaded through to [_MapView] —
  /// see that class's `controller` doc. Production code (the app's real
  /// `/community` route) leaves this null.
  @visibleForTesting
  final MapController? mapController;

  /// Test-injectable factory for the INNER [Client] wrapped by the Map tab's
  /// resilient tile provider, threaded through to [_MapView] — see that
  /// class's `tileHttpClientFactory` doc. Production code leaves this null.
  @visibleForTesting
  final Client Function()? tileHttpClientFactory;

  @override
  ConsumerState<CommunityScreen> createState() => _CommunityScreenState();
}

class _CommunityScreenState extends ConsumerState<CommunityScreen> {
  late CommunityTab _tab;
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _tab = widget.initialTab ?? CommunityTab.feed;
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
      key: const Key('community-screen'),
      appBar: AppBar(
        title: Text(
          'Community',
          style: Theme.of(context).textTheme.displaySmall,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        centerTitle: false,
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                MasiSpacing.lg,
                MasiSpacing.md,
                MasiSpacing.lg,
                MasiSpacing.sm,
              ),
              child: _TabToggle(
                tab: _tab,
                onChanged: (tab) => setState(() => _tab = tab),
              ),
            ),
            Expanded(
              child: asyncSharedTopos.when(
                data: (topos) => _tab == CommunityTab.feed
                    ? _FeedView(
                        topos: topos,
                        searchController: _searchController,
                        query: _query,
                      )
                    : _MapView(
                        topos: topos,
                        tileProvider: widget.tileProvider,
                        focusWallId: widget.focusWallId,
                        controller: widget.mapController,
                        tileHttpClientFactory: widget.tileHttpClientFactory,
                      ),
                loading: () =>
                    const Center(child: CircularProgressIndicator()),
                error: (error, stackTrace) =>
                    Center(child: Text('Something went wrong: $error')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Hand-rolled segmented Feed/Map toggle (rather than Material's
/// `SegmentedButton`, whose `ButtonSegment` has no per-segment `Key`), so
/// each side can carry its own stable `community-*-toggle` key for tests.
class _TabToggle extends StatelessWidget {
  const _TabToggle({required this.tab, required this.onChanged});

  final CommunityTab tab;
  final ValueChanged<CommunityTab> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: colors.surface2,
        borderRadius: BorderRadius.circular(MasiRadii.control),
      ),
      child: Row(
        children: [
          Expanded(
            child: _TabButton(
              key: const Key('community-feed-toggle'),
              label: 'Feed',
              selected: tab == CommunityTab.feed,
              onTap: () => onChanged(CommunityTab.feed),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: _TabButton(
              key: const Key('community-map-toggle'),
              label: 'Map',
              selected: tab == CommunityTab.map,
              onTap: () => onChanged(CommunityTab.map),
            ),
          ),
        ],
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    return Material(
      color: selected ? colors.accent : Colors.transparent,
      borderRadius: BorderRadius.circular(MasiRadii.control - 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(MasiRadii.control - 2),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: selected ? colors.onAccent : colors.ink2,
              fontWeight: FontWeight.w600,
            ),
          ),
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
                    prefixIcon: const MasiIcon('search'),
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: MasiSpacing.lg,
                    vertical: MasiSpacing.sm,
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
/// [StyleFilterChips] wired directly to [communityFilterProvider], plus a
/// Clear action. Purely reactive to the provider (no local widget state of
/// its own), so edits made here are visible live in the feed/map behind it
/// without needing to close the sheet first.
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
                          child: Text(
                            '\u{1F4AC} ${topo.commentCount}',
                            key: Key('community-topo-row-$wallId-comments'),
                            style: textTheme.titleSmall?.copyWith(
                              color: colors.ink2,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
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
/// [MapController] for the find-me/compass controls added over the map —
/// see [_MapViewState].
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
  /// MC3/MC4: a test supplies its own controller and reads `controller.camera`
  /// after driving a tap on `community-map-find-me`/`community-map-compass`).
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
  /// so the compass button's icon can rotate to keep pointing north (see
  /// `_compassButton`) — kept as widget state (rather than read directly off
  /// `_mapController.camera` inside `build`) because a controller-driven
  /// rotation (a drag gesture, or this same compass button) does not, on its
  /// own, trigger a rebuild of this widget.
  double _rotationDegrees = 0;

  /// One-shot guard for the imperative device-location auto-center in
  /// [build]'s `ref.listen(myLocationProvider, ...)` — see MAJOR 1 in this
  /// class's fix history. Sticks at `true` for the rest of this
  /// [_MapViewState]'s lifetime once the camera has been auto-centered once,
  /// so a later, unrelated rebuild (e.g. the compass's rotation-driven
  /// `setState`) can never re-fight the user by moving the camera back.
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

  /// The Map tab's [TileLayer.tileProvider]: [widget.tileProvider] when
  /// injected (every existing test's `_NoopTileProvider`, bypassing this
  /// entirely so no client is ever created under `flutter_test`), else a
  /// resilient [NetworkTileProvider] built ONCE for this [_MapViewState]'s
  /// entire lifetime and reused on every subsequent `build()` call — see
  /// MAJOR 2 in this class's fix history: calling `buildResilientTileProvider()`
  /// directly inline inside `build` allocated a brand-new provider +
  /// `RetryClient` + `http.Client` on EVERY rebuild (and the compass's
  /// `mapEventStream` listener triggers a `setState` on every rotation
  /// frame), leaking one never-closed `http.Client` per rebuild — worse,
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
    // in this class's fix history. `myLocation` above comes from
    // `myLocationProvider`, an autoDispose FutureProvider that's still
    // `AsyncLoading` (null) on this widget's FIRST build — applying it only
    // via `MapOptions.initialCenter` (honored by flutter_map exactly ONCE, at
    // first mount) would leave the map stuck at the (0,0)/1.5 world view
    // forever once the fix resolves a moment later, since a later rebuild's
    // freshly-computed `center` below is never re-applied to an
    // already-mounted map. `ref.listen` instead fires the instant
    // `myLocationProvider` actually transitions to a resolved value, moving
    // the (by-then-mounted) map's camera directly.
    //
    // Guarded to fire at most once per `_MapViewState` (`_didAutoCenter`),
    // and only when there are NO located topos to frame instead and no
    // `focusWallId` deep link is in play — both of those DO work correctly
    // via `initialCenter`/`initialZoom` below, since `topos` is already
    // populated by this widget's first build — so it never fights the user
    // afterward (e.g. after they've since panned/zoomed/rotated away, or
    // once topos load in and should be framed instead).
    ref.listen<AsyncValue<DeviceLocation?>>(myLocationProvider, (
      previous,
      next,
    ) {
      if (_didAutoCenter) return;
      if (widget.focusWallId != null) return;
      if (combinedCoords.isNotEmpty) return;
      final loc = next.asData?.value;
      if (loc == null) return;
      _didAutoCenter = true;
      if (!mounted) return;
      try {
        _mapController.move(LatLng(loc.latitude, loc.longitude), 12);
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

    // When there are no located topos at all AND no `focusWallId` was even
    // requested, prefer centering on the device's current position (at a
    // moderate zoom) over the maximally-unhelpful (0,0)/1.5 whole-world
    // view. A `focusWallId` that failed to resolve to a point (not found /
    // filtered out / no coordinates, and no OTHER located topos exist
    // either) deliberately still falls through to the (0,0)/1.5 fallback
    // below rather than silently substituting the device's own location for
    // a link that named a specific, different place.
    final useMyLocationFallback = widget.focusWallId == null &&
        myLocation != null;

    final center =
        focusPoint ??
        (combinedCoords.isEmpty
            ? (useMyLocationFallback
                ? LatLng(myLocation.latitude, myLocation.longitude)
                : const LatLng(0, 0))
            : LatLng(
                combinedCoords.map((p) => p.latitude).reduce(
                      (a, b) => a + b,
                    ) /
                    combinedCoords.length,
                combinedCoords.map((p) => p.longitude).reduce(
                      (a, b) => a + b,
                    ) /
                    combinedCoords.length,
              ));
    final zoom = focusPoint != null
        ? 15.0
        : (combinedCoords.isEmpty
            ? (useMyLocationFallback ? 12.0 : 1.5)
            : 11.0);

    final flutterMap = FlutterMap(
      mapController: _mapController,
      options: MapOptions(initialCenter: center, initialZoom: zoom),
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
                  // rows), so this marker always paints the lighter, public
                  // boulder tint.
                  child: _BoulderMarker(isPublic: true, colors: colors),
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
                  child: _BoulderMarker(
                    isPublic: topo.visibility == 'shared',
                    colors: colors,
                  ),
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
              padding: const EdgeInsets.all(6),
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
        // A compact "Private" vs "Public" legend, top-left so it never
        // fights the bottom-right attribution pill for space. Purely
        // informational (no tap target of its own), like the attribution.
        IgnorePointer(
          child: Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: _MapLegend(colors: colors),
            ),
          ),
        ),
      ],
    );

    // Map controls (find-me/compass) are siblings of the FlutterMap in a
    // Stack, ABOVE it — FlutterMap.children are map LAYERS (they scroll/zoom
    // with the map), whereas these controls must stay fixed to the screen.
    // Positioned bottom-right, above the attribution pill (which sits
    // flush at the very bottom-right — see the `IgnorePointer`/`Align`
    // above), so neither overlaps the other or the top-left legend.
    return Stack(
      children: [
        flutterMap,
        Positioned(
          right: 8,
          bottom: 44,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _MapControlButton(
                mapControlKey: const Key('community-map-compass'),
                iconName: 'compass',
                tooltip: 'Reset north',
                colors: colors,
                rotationDegrees: -_rotationDegrees,
                onPressed: () => _mapController.rotate(0),
              ),
              const SizedBox(height: 8),
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

/// A compact, theme-aware circular icon button for the Map tab's find-me/
/// compass controls (`community-map-find-me`/`community-map-compass`) —
/// styled with [MasiColors] rather than Material's default
/// `FloatingActionButton` look, to sit consistently with the rest of the
/// app's chrome.
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
    this.rotationDegrees = 0,
  });

  final Key mapControlKey;
  final String iconName;
  final String tooltip;
  final MasiColors colors;
  final VoidCallback onPressed;
  final double rotationDegrees;

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
        icon: Transform.rotate(
          angle: rotationDegrees * math.pi / 180,
          child: MasiIcon(iconName, color: colors.ink),
        ),
      ),
    );
  }
}

/// The Map tab's "Private"/"Public" key (`community-map-legend`),
/// explaining [_BoulderMarker]'s visibility-encoded color: a dark swatch
/// (matching [_BoulderMarker.privateBase]) for private topos, a light one
/// (matching [_BoulderMarker.publicBase]) for public ones -- every marker on
/// the map (own or community) is colored by that same rule, regardless of
/// which `MarkerLayer`/tap-target it belongs to.
class _MapLegend extends StatelessWidget {
  const _MapLegend({required this.colors});

  final MasiColors colors;

  @override
  Widget build(BuildContext context) {
    final textStyle = Theme.of(
      context,
    ).textTheme.labelSmall?.copyWith(color: colors.ink2);
    final swatchBorder = colors.ink2.withValues(alpha: 0.35);
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
              swatchColor: _BoulderMarker.privateBase(colors),
              swatchBorderColor: swatchBorder,
              label: 'Private',
              textStyle: textStyle,
            ),
            const SizedBox(height: 4),
            _MapLegendRow(
              swatchColor: _BoulderMarker.publicBase(colors),
              swatchBorderColor: swatchBorder,
              label: 'Public',
              textStyle: textStyle,
            ),
          ],
        ),
      ),
    );
  }
}

class _MapLegendRow extends StatelessWidget {
  const _MapLegendRow({
    required this.swatchColor,
    required this.label,
    this.swatchBorderColor,
    this.textStyle,
  });

  final Color swatchColor;
  final Color? swatchBorderColor;
  final String label;
  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: swatchColor,
            shape: BoxShape.circle,
            border: swatchBorderColor != null
                ? Border.all(color: swatchBorderColor!, width: 1.5)
                : null,
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

/// The Map tab's per-topo marker: a faceted purple boulder silhouette
/// matching the app-icon mark (`assets/icon/masi_icon.png`, still used only
/// as the launcher icon — see this class's replacement of [
/// _MapPinBadge]/[_OwnMapPinBadge], the old logo-in-a-white-circle pins),
/// with a white zig-zag "crack" down the middle. Used by BOTH the community
/// and own `MarkerLayer`s in [_MapView.build] — the own-vs-community split
/// still exists (separate layers/tap targets), it just no longer changes the
/// marker's color. Instead, [isPublic] alone drives the fill: a lighter
/// lilac boulder for public/shared topos, a darker deep-purple one for
/// private topos, so a topo's visibility reads directly off the map without
/// needing the legend (see [_MapLegend], which explains the convention).
class _BoulderMarker extends StatelessWidget {
  const _BoulderMarker({required this.isPublic, required this.colors});

  final bool isPublic;
  final MasiColors colors;

  /// Total height of the enclosing [Marker] box. Unlike the old
  /// [_MapPinBadge]/[_OwnMapPinBadge] this replaces, this widget's own
  /// drawn content (see [_boulderSize]) is deliberately SMALLER than this —
  /// [MarkerLayer] wraps every marker's child in a `Positioned(width:,
  /// height:)` inside a `Stack`, which gives it TIGHT constraints of
  /// exactly (`width`, `height`) regardless of the child's own size (see
  /// flutter_map's `marker_layer.dart`), so this constant only has to match
  /// the call sites' `Marker.height` for box-height tests to keep passing —
  /// the boulder itself is bottom-anchored inside that box (see [build]),
  /// which is what keeps its visual base sitting on the actual coordinate
  /// per `Alignment.topCenter`'s "anchors the box's bottom edge" semantics.
  static const double totalHeight = 40;

  /// Size of the boulder silhouette actually drawn, in logical pixels — see
  /// [_BoulderPainter]'s silhouette/crack points, which are normalized
  /// (0..1) fractions of this box.
  static const Size _boulderSize = Size(34, 38);

  /// Base fill for a PUBLIC (shared/community-visible) topo: [colors.accent]
  /// lightened towards white — a light lilac. Shared with [_MapLegend] so
  /// the legend swatch always matches the marker exactly.
  static Color publicBase(MasiColors colors) =>
      Color.lerp(colors.accent, Colors.white, 0.42)!;

  /// Base fill for a PRIVATE topo: [colors.accent] darkened towards black —
  /// a deep purple. Shared with [_MapLegend] so the legend swatch always
  /// matches the marker exactly.
  static Color privateBase(MasiColors colors) =>
      Color.lerp(colors.accent, Colors.black, 0.34)!;

  @override
  Widget build(BuildContext context) {
    final base = isPublic ? publicBase(colors) : privateBase(colors);
    return Align(
      alignment: Alignment.bottomCenter,
      child: CustomPaint(
        size: _boulderSize,
        painter: _BoulderPainter(
          base: base,
          // Lighter top-left facet and darker right facet, both derived
          // from `base`, give the flat silhouette a faceted, 3D read like
          // the app-icon mark.
          topFacet: Color.lerp(base, Colors.white, 0.22)!,
          rightFacet: Color.lerp(base, Colors.black, 0.20)!,
          // The CartoDB basemap underneath is ALWAYS the light "Positron"
          // style, regardless of the app's own theme -- so a public boulder
          // in DARK app theme (a pale lilac `base`, lerped 42% towards
          // white) needs a darker-than-fill outline to stay legible against
          // that near-white map; a private boulder's already-dark `base`
          // gets the same treatment for a consistent, always-visible edge.
          outline: Color.lerp(base, Colors.black, 0.40)!,
          // Matches the crack to whichever end of the contrast range `base`
          // sits at, rather than always white: a light/public `base` gets a
          // dark crack (white on pale lilac was near-invisible against the
          // light map), a dark/private `base` keeps the original white.
          crackColor: base.computeLuminance() > 0.5
              ? Color.lerp(base, Colors.black, 0.40)!
              : Colors.white,
        ),
      ),
    );
  }
}

/// Paints [_BoulderMarker]'s faceted boulder: a filled silhouette stroked
/// with a darker [outline] (so its edge stays defined against the always-
/// light CartoDB basemap regardless of app theme -- see that field's doc), a
/// lighter top-left facet and darker right facet overlaid on top (clipped to
/// the silhouette) for a faceted 3D look, a contrast-adaptive [crackColor]
/// zig-zag stroked down the middle, and a soft shadow ellipse under the
/// base. All points below are normalized (0..1) fractions of the painted
/// [Size], x right / y down, kept as named consts so the
/// silhouette/crack/facets are easy to retune independently of each other.
class _BoulderPainter extends CustomPainter {
  const _BoulderPainter({
    required this.base,
    required this.topFacet,
    required this.rightFacet,
    required this.outline,
    required this.crackColor,
  });

  final Color base;
  final Color topFacet;
  final Color rightFacet;

  /// Silhouette edge stroke, darker than [base] -- see [_BoulderMarker.build]
  /// for why this exists: the CartoDB basemap is always the light Positron
  /// style, so without a defined edge a pale (dark-theme, public) `base`
  /// washes out against it.
  final Color outline;

  /// The crack's stroke color, contrast-adapted to [base] -- see
  /// [_BoulderMarker.build]. Always white before this fix, which was
  /// invisible on a light/public `base` against the light basemap.
  final Color crackColor;

  // Silhouette outline, in walk order.
  static const _peak = Offset(0.52, 0.16);
  static const _upperLeft = Offset(0.30, 0.28);
  static const _leftMid = Offset(0.15, 0.46);
  static const _lowerLeft = Offset(0.14, 0.66);
  static const _bottomLeft = Offset(0.26, 0.82);
  static const _bottomRight = Offset(0.74, 0.82);
  static const _rightLower = Offset(0.87, 0.66);
  static const _rightUpper = Offset(0.90, 0.48);
  static const _upperRight = Offset(0.71, 0.28);

  static const _silhouette = [
    _peak,
    _upperLeft,
    _leftMid,
    _lowerLeft,
    _bottomLeft,
    _bottomRight,
    _rightLower,
    _rightUpper,
    _upperRight,
  ];

  // The white crack, a simple zig-zag from the top ridge to the base.
  static const _crackPoints = [
    Offset(0.50, 0.24),
    Offset(0.57, 0.42),
    Offset(0.47, 0.55),
    Offset(0.55, 0.70),
    Offset(0.51, 0.81),
  ];

  static Offset _scale(Offset normalized, Size size) =>
      Offset(normalized.dx * size.width, normalized.dy * size.height);

  static Path _pathThrough(List<Offset> normalizedPoints, Size size) {
    final scaled = normalizedPoints.map((o) => _scale(o, size)).toList();
    return Path()..addPolygon(scaled, false);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final silhouette = Path()..addPolygon(
      _silhouette.map((o) => _scale(o, size)).toList(),
      true,
    );

    // Soft shadow, a low ellipse just under the boulder's base.
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(size.width * 0.52, size.height * 0.94),
        width: size.width * 0.72,
        height: size.height * 0.14,
      ),
      Paint()..color = Colors.black.withValues(alpha: 0.15),
    );

    // Base fill.
    canvas.drawPath(silhouette, Paint()..color = base);

    // Silhouette edge stroke -- see [outline]'s doc: without this, a pale
    // (dark-theme, public) fill has no defined boundary against the
    // always-light CartoDB basemap underneath.
    canvas.drawPath(
      silhouette,
      Paint()
        ..color = outline
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..strokeJoin = StrokeJoin.round,
    );

    // Facets: clipped to the silhouette so they never spill past its edge.
    canvas.save();
    canvas.clipPath(silhouette);
    final center = Offset(size.width * 0.5, size.height * 0.52);
    canvas.drawPath(
      Path()
        ..moveTo(_scale(_peak, size).dx, _scale(_peak, size).dy)
        ..lineTo(_scale(_upperLeft, size).dx, _scale(_upperLeft, size).dy)
        ..lineTo(_scale(_leftMid, size).dx, _scale(_leftMid, size).dy)
        ..lineTo(center.dx, center.dy)
        ..close(),
      Paint()..color = topFacet,
    );
    canvas.drawPath(
      Path()
        ..moveTo(_scale(_upperRight, size).dx, _scale(_upperRight, size).dy)
        ..lineTo(_scale(_rightUpper, size).dx, _scale(_rightUpper, size).dy)
        ..lineTo(_scale(_rightLower, size).dx, _scale(_rightLower, size).dy)
        ..lineTo(_scale(_bottomRight, size).dx, _scale(_bottomRight, size).dy)
        ..lineTo(center.dx, center.dy)
        ..close(),
      Paint()..color = rightFacet,
    );
    canvas.restore();

    // Crack, contrast-adapted to `base` -- see [crackColor]'s doc.
    canvas.drawPath(
      _pathThrough(_crackPoints, size),
      Paint()
        ..color = crackColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _BoulderPainter oldDelegate) =>
      oldDelegate.base != base ||
      oldDelegate.topFacet != topFacet ||
      oldDelegate.rightFacet != rightFacet ||
      oldDelegate.outline != outline ||
      oldDelegate.crackColor != crackColor;
}
