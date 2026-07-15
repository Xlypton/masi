import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../../app/theme.dart';
import '../../../core/grades/grade_system.dart';
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

/// The Feed tab: a search field over a list of [_FeedRow]s, or [_EmptyState]
/// when there are no shared topos at all (or none matching the search).
class _FeedView extends StatelessWidget {
  const _FeedView({
    required this.topos,
    required this.searchController,
    required this.query,
  });

  final List<SharedTopo> topos;
  final TextEditingController searchController;
  final String query;

  @override
  Widget build(BuildContext context) {
    final filtered = query.isEmpty
        ? topos
        : topos.where((t) => t.name.toLowerCase().contains(query)).toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            MasiSpacing.lg,
            0,
            MasiSpacing.lg,
            MasiSpacing.sm,
          ),
          child: TextField(
            key: const Key('community-search-field'),
            controller: searchController,
            decoration: const InputDecoration(
              hintText: 'Search topos',
              prefixIcon: Icon(Icons.search),
            ),
          ),
        ),
        Expanded(
          child: topos.isEmpty
              ? const _EmptyState(message: 'No shared topos yet')
              : filtered.isEmpty
              ? const _EmptyState(message: 'No topos match your search')
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
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (topo.topGradeLabel != null &&
                            topo.topGradeBand != null) ...[
                          _GradePill(
                            label: topo.topGradeLabel!,
                            band: topo.topGradeBand!,
                          ),
                          const SizedBox(width: MasiSpacing.xs),
                        ],
                        Text(
                          '${topo.routeCount} route${topo.routeCount == 1 ? '' : 's'}',
                          style: textTheme.titleSmall?.copyWith(
                            color: colors.ink2,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Text(
                          '♥ ${topo.likeCount}',
                          key: Key('community-topo-row-$wallId-likes'),
                          style: textTheme.titleSmall?.copyWith(
                            color: colors.ink2,
                          ),
                        ),
                        const SizedBox(width: MasiSpacing.sm),
                        Text(
                          '\u{1F4AC} ${topo.commentCount}',
                          key: Key('community-topo-row-$wallId-comments'),
                          style: textTheme.titleSmall?.copyWith(
                            color: colors.ink2,
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
/// topo that [SharedTopo.hasCoordinates] — topos without coordinates are
/// simply omitted from the marker list, never crash the map.
class _MapView extends StatelessWidget {
  const _MapView({required this.topos, required this.tileProvider});

  final List<SharedTopo> topos;
  final TileProvider? tileProvider;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final withCoords = topos.where((t) => t.hasCoordinates).toList();

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
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.climbtopo.climbtopo',
          tileProvider: tileProvider ?? NetworkTileProvider(),
        ),
        MarkerLayer(
          markers: [
            for (final topo in withCoords)
              Marker(
                point: LatLng(topo.latitude!, topo.longitude!),
                width: 40,
                height: 40,
                child: GestureDetector(
                  key: Key('community-map-marker-${topo.wallId}'),
                  onTap: () {
                    FocusManager.instance.primaryFocus?.unfocus();
                    context.push('/community/topo/${topo.wallId}');
                  },
                  child: Icon(
                    Icons.location_pin,
                    color: colors.accent,
                    size: 36,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
