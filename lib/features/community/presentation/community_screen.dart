import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
// `hide Path`: latlong2 exports its own generic `Path<T>` (a geodesic path
// helper we never use here), which otherwise shadows dart:ui's `Path` (from
// `package:flutter/material.dart`) needed by `_PinPointerPainter` below.
import 'package:latlong2/latlong.dart' hide Path;

import '../../../app/theme.dart';
import '../../../core/grades/grade_system.dart';
import '../../../shared/filtering/grade_range_picker.dart';
import '../../../shared/filtering/style_filter_chips.dart';
import '../application/community_providers.dart';
import '../data/community_repository.dart';

/// Which of the Community screen's two views is currently shown.
enum _CommunityTab { feed, map }

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
class CommunityScreen extends ConsumerStatefulWidget {
  const CommunityScreen({super.key, this.tileProvider});

  final TileProvider? tileProvider;

  @override
  ConsumerState<CommunityScreen> createState() => _CommunityScreenState();
}

class _CommunityScreenState extends ConsumerState<CommunityScreen> {
  _CommunityTab _tab = _CommunityTab.feed;
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
                data: (topos) => _tab == _CommunityTab.feed
                    ? _FeedView(
                        topos: topos,
                        searchController: _searchController,
                        query: _query,
                      )
                    : _MapView(topos: topos, tileProvider: widget.tileProvider),
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

  final _CommunityTab tab;
  final ValueChanged<_CommunityTab> onChanged;

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
              selected: tab == _CommunityTab.feed,
              onTap: () => onChanged(_CommunityTab.feed),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: _TabButton(
              key: const Key('community-map-toggle'),
              label: 'Map',
              selected: tab == _CommunityTab.map,
              onTap: () => onChanged(_CommunityTab.map),
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
                  decoration: const InputDecoration(
                    hintText: 'Search topos',
                    prefixIcon: Icon(Icons.search),
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
/// [_CommunityFiltersSheet], with a small accent dot overlay whenever
/// [filter] is active (`community-filter-active-dot`) so a user can tell at
/// a glance that the feed is currently narrowed.
class _FilterButton extends StatelessWidget {
  const _FilterButton({required this.filter});

  final CommunityFilter filter;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        IconButton(
          key: const Key('community-filter-button'),
          icon: const Icon(Icons.tune),
          tooltip: 'Filters',
          onPressed: () => showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            builder: (_) => const _CommunityFiltersSheet(),
          ),
        ),
        if (filter.isActive)
          Positioned(
            right: 8,
            top: 8,
            child: IgnorePointer(
              child: Container(
                key: const Key('community-filter-active-dot'),
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: colors.accent,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
      ],
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
class _FeedRow extends StatelessWidget {
  const _FeedRow({required this.topo});

  final SharedTopo topo;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final wallId = topo.wallId;

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
              Icon(Icons.chevron_right, color: colors.ink3),
            ],
          ),
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
/// crash the map.
class _MapView extends ConsumerWidget {
  const _MapView({required this.topos, required this.tileProvider});

  final List<SharedTopo> topos;
  final TileProvider? tileProvider;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(communityFilterProvider);
    final filteredTopos = topos.where(filter.matches).toList();
    final colors = MasiColors.of(context);
    final withCoords = filteredTopos.where((t) => t.hasCoordinates).toList();
    // Best-effort device position (see myLocationProvider's doc): loading,
    // error, and denied/unavailable (a `null` AsyncData) all collapse to
    // "no marker" here — the map and every topo marker render exactly the
    // same either way.
    final myLocation = ref.watch(myLocationProvider).asData?.value;

    final center = withCoords.isEmpty
        ? const LatLng(0, 0)
        : LatLng(
            withCoords.map((t) => t.latitude!).reduce((a, b) => a + b) /
                withCoords.length,
            withCoords.map((t) => t.longitude!).reduce((a, b) => a + b) /
                withCoords.length,
          );

    return FlutterMap(
      options: MapOptions(
        initialCenter: center,
        initialZoom: withCoords.isEmpty ? 1.5 : 11,
      ),
      children: [
        TileLayer(
          urlTemplate:
              'https://basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png',
          userAgentPackageName: 'com.climbtopo.climbtopo',
          tileProvider: tileProvider ?? NetworkTileProvider(),
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
            for (final topo in withCoords)
              Marker(
                point: LatLng(topo.latitude!, topo.longitude!),
                width: 40,
                height: _MapPinBadge.totalHeight,
                alignment: Alignment.topCenter,
                child: GestureDetector(
                  key: Key('community-map-marker-${topo.wallId}'),
                  onTap: () {
                    FocusManager.instance.primaryFocus?.unfocus();
                    context.push('/community/topo/${topo.wallId}');
                  },
                  child: _MapPinBadge(accentColor: colors.accent),
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
      ],
    );
  }
}

/// The Map tab's "you are here" marker: a small filled blue dot with a white
/// ring (the familiar device-position convention), deliberately NOT styled
/// like [_MapPinBadge] — a plain dot centered exactly on the coordinate
/// (rather than a pin whose tip points at it) reads unambiguously as "this
/// is where I am", distinct from every topo's pin.
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

/// The Map tab's per-topo marker: the app's raster logo in a small white
/// circular badge — subtle shadow, thin accent-tinted ring — sitting atop a
/// tiny downward-pointing triangle, so it reads as a map pin (tip anchored to
/// the coordinate via the [Marker]'s `Alignment.topCenter`) rather than a
/// generic dot, and stays legible against the light CartoDB Positron basemap.
class _MapPinBadge extends StatelessWidget {
  const _MapPinBadge({required this.accentColor});

  final Color accentColor;

  static const double _badgeSize = 34;
  static const double _pointerSize = 8;

  /// Total rendered height of the badge + downward pointer, with zero
  /// vertical slack. The enclosing [Marker]'s `height` MUST equal this
  /// exactly: flutter_map's `Marker.alignment` doc states that
  /// [Alignment.topCenter] anchors the marker BOX's bottom edge to the
  /// geographic point. If the box were any taller than this content, the
  /// [Column] below (tight-constrained to the box's full height, so
  /// `mainAxisSize.min` cannot shrink it) would pack its children at the
  /// top and leave the extra space below the pointer — floating the
  /// pointer's visual tip above the actual coordinate.
  static const double totalHeight = _badgeSize + (_pointerSize - 2);

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: _badgeSize,
          height: _badgeSize,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            border: Border.all(color: accentColor, width: 1.5),
            boxShadow: const [
              BoxShadow(
                color: Colors.black26,
                blurRadius: 4,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: ClipOval(
            child: Image.asset(
              'assets/icon/masi_icon.png',
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => Icon(
                Icons.place,
                size: _badgeSize - 8,
                color: accentColor,
              ),
            ),
          ),
        ),
        CustomPaint(
          size: const Size(_pointerSize, _pointerSize - 2),
          painter: _PinPointerPainter(accentColor),
        ),
      ],
    );
  }
}

/// Paints the small downward triangle beneath [_MapPinBadge]'s circle,
/// tinted to match the badge's accent ring so the whole marker reads as one
/// cohesive pin shape.
class _PinPointerPainter extends CustomPainter {
  const _PinPointerPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _PinPointerPainter oldDelegate) =>
      oldDelegate.color != color;
}
