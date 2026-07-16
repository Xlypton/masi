import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../app/theme.dart';
import '../../../core/grades/grade_system.dart';
import '../../../core/location/location_service.dart';
import '../../../shared/filtering/grade_range_picker.dart';
import '../../../shared/filtering/style_filter_chips.dart';
import '../../account/application/auth_providers.dart';
import '../../account/application/email_initials.dart';
import '../../topo/presentation/photo_source_sheet.dart';
import '../../topo/presentation/topo_canvas_screen.dart'
    show captureWallGpsFromPhoto, gpsCaptureResultSnackBar;
import '../application/library_providers.dart';
import '../data/library_crud_repository.dart';
import 'move_target_picker.dart';

/// The new flat "photo-first" home (see DESIGN.md "Topos home"): every
/// non-deleted [db.Wall] rendered as a single "topo" row (thumbnail + name +
/// route count), with no Area/Sector hierarchy visible up front. That
/// hierarchy still exists underneath (every topo is secretly filed under a
/// hidden `__default__` Area/Sector, see
/// [LibraryCrudRepository.createTopo]) and remains reachable via the
/// trailing "Organize" action, which pushes `/areas`.
///
/// [photoSourcePicker] / [photoPicker] are injectable seams (defaulting to
/// the real [showPhotoSourceSheet] / [pickPhotoFrom]) so widget tests can
/// drive the "New topo" flow without touching the real camera/gallery UI.
///
/// A [ConsumerStatefulWidget] (rather than a stateless [ConsumerWidget])
/// so it can hold the [_creating] re-entrancy flag: without it, a fast
/// double-tap on "New topo" would fire two concurrent creation flows that
/// both read the same stale topo count and both push a route, stacking two
/// navigations and leaving a duplicate topo behind.
class ToposScreen extends ConsumerStatefulWidget {
  const ToposScreen({
    super.key,
    this.photoSourcePicker = showPhotoSourceSheet,
    this.photoPicker = pickPhotoFrom,
  });

  final Future<ImageSource?> Function(BuildContext) photoSourcePicker;
  final Future<XFile?> Function(ImageSource) photoPicker;

  @override
  ConsumerState<ToposScreen> createState() => _ToposScreenState();
}

class _ToposScreenState extends ConsumerState<ToposScreen> {
  /// Re-entrancy guard for [_handleNewTopo]: true for the whole duration of
  /// an in-flight "New topo" flow (source picker -> photo picker -> decode
  /// -> createTopo -> attachPhotoToWall -> navigate). While true, the
  /// button is disabled and a second tap is a no-op.
  bool _creating = false;

  /// Keyword search over the Topos home, mirroring
  /// `community_screen.dart`'s `_CommunityScreenState` search field: the
  /// controller backs the `topos-search-field` [TextField], and [_query] is
  /// its trimmed/lowercased text, updated only when it actually changes so
  /// unrelated rebuilds (e.g. a caret move) don't trigger extra work.
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
    final asyncTopos = ref.watch(toposProvider);
    final filter = ref.watch(toposFilterProvider);
    // Only an *actually loaded* topo list (AsyncData) is a safe source for
    // the "New topo" count; while still loading or errored there is no
    // trustworthy count to derive "Topo N+1" from, so the button must be
    // disabled rather than fall back to an empty list and mint "Topo 1"
    // over an existing topo.
    final loadedTopos = asyncTopos.asData?.value;
    final canCreate = loadedTopos != null && !_creating;

    // The account button shows initials once actually signed in with a
    // real (non-empty) email; any other state of the auth stream —
    // signed-out, still loading, or errored (e.g. Supabase never
    // initialized) — degrades to the generic person icon rather than
    // guessing, per `authStateProvider`'s doc comment.
    final authSession = ref.watch(authStateProvider).asData?.value;
    final signedInEmail =
        (authSession != null &&
            authSession.isSignedIn &&
            authSession.email!.isNotEmpty)
        ? authSession.email!
        : null;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Topos',
          style: Theme.of(context).textTheme.displaySmall,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        centerTitle: false,
        actions: [
          IconButton(
            key: const Key('topos-organize'),
            icon: Icon(Icons.folder_outlined, color: colors.accent),
            tooltip: 'Organize',
            onPressed: () => context.push('/areas'),
          ),
          IconButton(
            key: const Key('home-community-button'),
            icon: Icon(Icons.explore_outlined, color: colors.accent),
            tooltip: 'Community',
            onPressed: () => context.push('/community'),
          ),
          IconButton(
            key: const Key('home-logbook-button'),
            icon: Icon(Icons.menu_book_outlined, color: colors.accent),
            tooltip: 'Logbook',
            onPressed: () => context.push('/logbook'),
          ),
          IconButton(
            key: const Key('topos-account-button'),
            icon: signedInEmail != null
                ? CircleAvatar(
                    key: const Key('topos-account-avatar'),
                    radius: 14,
                    backgroundColor: colors.accent,
                    foregroundColor: colors.onAccent,
                    child: Text(
                      emailInitials(signedInEmail),
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  )
                : Icon(Icons.person_outline, color: colors.accent),
            tooltip: 'Account',
            onPressed: () => context.push('/account'),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            _ToposFilterBar(
              searchController: _searchController,
              isActive: filter.isActive,
              onTap: () => _showToposFiltersSheet(context),
            ),
            Expanded(
              child: asyncTopos.when(
                data: (topos) {
                  if (topos.isEmpty) {
                    return const _EmptyState();
                  }
                  // Search narrows first, then the filter facets (mirrors
                  // `community_screen.dart`'s `_FeedView`), so the two stay
                  // independently diagnosable: a query that matches nothing
                  // shows the search-specific empty state even if the
                  // active filter would otherwise also exclude everything.
                  final query = _query;
                  final searchFiltered = query.isEmpty
                      ? topos
                      : topos.where((t) => _matchesQuery(t, query)).toList();
                  if (searchFiltered.isEmpty) {
                    return const _SearchEmptyState();
                  }
                  final filtered = applyToposFilter(searchFiltered, filter);
                  if (filtered.isEmpty) {
                    return const _FilteredEmptyState();
                  }
                  return _ToposList(topos: filtered);
                },
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, stackTrace) => Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Something went wrong: $error'),
                      const SizedBox(height: 8),
                      ElevatedButton(
                        key: const Key('topos-retry'),
                        onPressed: () => ref.invalidate(toposProvider),
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                MasiSpacing.lg,
                MasiSpacing.md,
                MasiSpacing.lg,
                MasiSpacing.lg,
              ),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  key: const Key('topos-new-topo'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: colors.accent,
                    foregroundColor: colors.onAccent,
                    // Without these, Material's disabled-state fallback
                    // (onSurface @ ~38% alpha) takes over while the topos
                    // list is loading or a create is in-flight, reading as
                    // dark low-contrast text on the still-purple background.
                    // Keep the accent fill so the button doesn't visibly
                    // change shape/color, but dim the label just enough to
                    // read as "disabled" while staying legible.
                    disabledBackgroundColor: colors.accent,
                    disabledForegroundColor: colors.onAccent.withValues(
                      alpha: 0.7,
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(13),
                    ),
                  ),
                  onPressed: canCreate ? _handleNewTopo : null,
                  child: const Text('New topo'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Photo-first "New topo" creation flow: pick a source, pick a photo,
  /// decode its pixel size, create a wall named after the current topo
  /// count, attach the photo to it, then navigate straight into the canvas.
  ///
  /// Deliberately defensive (try/catch + `debugPrint`, no rethrow) to match
  /// the rest of the app's style for picker/decode failures (see
  /// `topo_canvas_screen.dart`'s `_attachPhotoAndLoad`): a cancelled/failed
  /// picker or a corrupt image must never crash the Topos home.
  ///
  /// Guarded twice against a stale/absent topo count and against
  /// re-entrancy: it bails out (no-op) unless `toposProvider` currently
  /// holds real `AsyncData` (never invoked while loading/erroring — the
  /// button is disabled then too, but this guard makes it safe even if
  /// invoked programmatically), and it bails out if a previous invocation
  /// is still in flight (`_creating`), so a fast double-tap can only ever
  /// create one topo.
  Future<void> _handleNewTopo() async {
    if (_creating) return;
    if (ref.read(toposProvider).asData == null) return;

    setState(() => _creating = true);
    try {
      final source = await widget.photoSourcePicker(context);
      if (source == null) return;

      final xfile = await widget.photoPicker(source);
      if (xfile == null) return;

      final bytes = await xfile.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      int width;
      int height;
      try {
        final frame = await codec.getNextFrame();
        width = frame.image.width;
        height = frame.image.height;
        frame.image.dispose();
      } finally {
        codec.dispose();
      }

      // Re-read at creation time (rather than trusting a value captured
      // before the picker/decode awaits) so the count reflects the latest
      // loaded state; still guarded against a (unlikely) transition back
      // to loading/error mid-flow.
      final currentTopos = ref.read(toposProvider).asData?.value ?? const [];
      final count = currentTopos.length;
      final repo = ref.read(libraryCrudRepositoryProvider);
      final wallId = await repo.createTopo('Topo ${count + 1}');
      await repo.attachPhotoToWall(wallId, xfile.path, width, height);

      // Best-effort GPS capture: delegates to the SAME
      // `captureWallGpsFromPhoto` the topo canvas's own add/replace-photo
      // flow calls (`topo_canvas_screen.dart`'s `_attachPhotoAndLoad`), so
      // both flows share one implementation and present an identical
      // outcome to the user. This re-reads `xfile.path` from disk rather
      // than reusing the `bytes` already decoded above for the dimension
      // check -- a second, tiny file read that trades a negligible bit of
      // I/O for a single source of truth on the EXIF-wins/device-fallback/
      // never-clobber contract (see that function's doc). It never throws
      // -- including a `setWallCoordinates` DB-write failure, which it
      // isolates in its OWN try/catch -- so a coords failure can never be
      // caught by the outer try/catch below and abort the topo+photo
      // creation that already committed above, nor block the navigation
      // that follows.
      final gpsResult = await captureWallGpsFromPhoto(
        repo,
        wallId,
        xfile.path,
        locationService: ref.read(locationServiceProvider),
      );

      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(gpsCaptureResultSnackBar(gpsResult));
      context.push('/walls/$wallId');
    } catch (e, st) {
      debugPrint('Failed to create new topo: $e\n$st');
    } finally {
      if (mounted) {
        setState(() => _creating = false);
      }
    }
  }
}

/// Whether [topo] matches keyword [query] (already trimmed/lowercased): its
/// name, top grade label, or area name contains it. Mirrors
/// `community_screen.dart`'s `_FeedView`'s name-only search, but widened to
/// also match [TopoRef.topGradeLabel] / [TopoRef.areaName] so a "keyword"
/// like a grade ("7a") or an area ("Squamish") also narrows the list, not
/// just the topo's own name.
bool _matchesQuery(TopoRef topo, String query) {
  if (topo.name.toLowerCase().contains(query)) return true;
  final grade = topo.topGradeLabel;
  if (grade != null && grade.toLowerCase().contains(query)) return true;
  final area = topo.areaName;
  if (area != null && area.toLowerCase().contains(query)) return true;
  return false;
}

/// Search field + filter trigger shown in the body, above the topos list
/// (see [ToposScreen.build]): a [Row] holding the `topos-search-field`
/// [TextField] (mirrors `community_screen.dart`'s `_FeedView` search field:
/// same hint text and prefix icon) alongside the `topos-filter-button` icon
/// button -- same key, [Icons.tune] icon, `topos-filter-active-indicator`
/// badge, and [_showToposFiltersSheet] behavior as before. The filter
/// trigger was relocated out of the AppBar's trailing actions: with a fifth
/// action there (this button alongside Organize/Community/Logbook/Account),
/// the "Topos" title itself was truncating to "Top…" at normal text scale.
class _ToposFilterBar extends StatelessWidget {
  const _ToposFilterBar({
    required this.searchController,
    required this.isActive,
    required this.onTap,
  });

  final TextEditingController searchController;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        MasiSpacing.lg,
        MasiSpacing.xs,
        MasiSpacing.sm,
        0,
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: const Key('topos-search-field'),
              controller: searchController,
              decoration: const InputDecoration(
                hintText: 'Search topos',
                prefixIcon: Icon(Icons.search),
              ),
            ),
          ),
          const SizedBox(width: MasiSpacing.sm),
          if (isActive)
            Padding(
              padding: const EdgeInsets.only(right: MasiSpacing.xs),
              child: Text(
                'Filters active',
                style: textTheme.labelMedium?.copyWith(color: colors.accent),
              ),
            ),
          IconButton(
            key: const Key('topos-filter-button'),
            icon: Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(Icons.tune, color: colors.accent),
                if (isActive)
                  Positioned(
                    key: const Key('topos-filter-active-indicator'),
                    right: -2,
                    top: -2,
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: colors.accent,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
            tooltip: 'Filters',
            onPressed: onTap,
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

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

/// Opens the Topos-home Filters sheet (see [_ToposFiltersSheet]) from the
/// `topos-filter-button` app-bar action.
Future<void> _showToposFiltersSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => const _ToposFiltersSheet(),
  );
}

/// The Topos-home Filters sheet: a [GradeRangePicker], a visibility
/// segmented control (All/Shared/Private), and an area multi-select (every
/// real area from [areasProvider] plus an explicit "Unfiled" option mapping
/// to [ToposFilter.unfiledAreaId]), with a Clear action that resets
/// [toposFilterProvider] back to its default (inactive) value.
///
/// Purely a thin view over [toposFilterProvider]: every interaction writes
/// straight through to the shared [ToposFilterController], so the
/// underlying Topos list (watched by [ToposScreen], which stays mounted
/// underneath this modal sheet) updates live while the sheet is still open.
class _ToposFiltersSheet extends ConsumerWidget {
  const _ToposFiltersSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final filter = ref.watch(toposFilterProvider);
    final controller = ref.read(toposFilterProvider.notifier);
    final areas = ref.watch(areasProvider).asData?.value ?? const <AreaRef>[];

    return SafeArea(
      child: Container(
        padding: const EdgeInsets.all(MasiSpacing.lg),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(MasiRadii.card),
          ),
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      'Filters',
                      style: textTheme.titleLarge,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TextButton(
                    key: const Key('topos-filter-clear'),
                    onPressed: controller.clear,
                    child: const Text('Clear'),
                  ),
                ],
              ),
              const SizedBox(height: MasiSpacing.md),
              GradeRangePicker(
                value: filter.grade,
                onChanged: controller.setGrade,
              ),
              const SizedBox(height: MasiSpacing.md),
              Text(
                'Visibility',
                style: textTheme.titleSmall?.copyWith(color: colors.ink2),
              ),
              const SizedBox(height: MasiSpacing.xs),
              _VisibilitySegmented(
                value: filter.visibility,
                onChanged: controller.setVisibility,
              ),
              const SizedBox(height: MasiSpacing.md),
              Text(
                'Area',
                style: textTheme.titleSmall?.copyWith(color: colors.ink2),
              ),
              const SizedBox(height: MasiSpacing.xs),
              Wrap(
                spacing: MasiSpacing.sm,
                runSpacing: MasiSpacing.sm,
                children: [
                  FilterChoiceChip(
                    key: const Key('topos-filter-area-unfiled'),
                    label: 'Unfiled',
                    selected: filter.areaIds.contains(
                      ToposFilter.unfiledAreaId,
                    ),
                    onPressed: () =>
                        controller.toggleArea(ToposFilter.unfiledAreaId),
                  ),
                  for (final area in areas)
                    FilterChoiceChip(
                      key: Key('topos-filter-area-${area.id}'),
                      label: area.name,
                      selected: filter.areaIds.contains(area.id),
                      onPressed: () => controller.toggleArea(area.id),
                    ),
                ],
              ),
              const SizedBox(height: MasiSpacing.lg),
            ],
          ),
        ),
      ),
    );
  }
}

/// A [ToposVisibilityFilter] segmented toggle (All/Shared/Private) for
/// [_ToposFiltersSheet], visually mirroring [GradeRangePicker]'s
/// `CupertinoSlidingSegmentedControl` (that widget's own segment-label
/// helper is private to its file, so this replicates rather than imports
/// it). Purely controlled: [value] is the current selection, [onChanged]
/// fires with the new value on every tap.
class _VisibilitySegmented extends StatelessWidget {
  const _VisibilitySegmented({required this.value, required this.onChanged});

  final ToposVisibilityFilter value;
  final ValueChanged<ToposVisibilityFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    return CupertinoSlidingSegmentedControl<ToposVisibilityFilter>(
      key: const Key('topos-filter-visibility'),
      groupValue: value,
      backgroundColor: colors.surface2,
      thumbColor: colors.accent,
      children: {
        ToposVisibilityFilter.all: _FilterSegmentLabel(
          key: const Key('topos-filter-visibility-all'),
          label: 'All',
          selected: value == ToposVisibilityFilter.all,
          colors: colors,
        ),
        ToposVisibilityFilter.shared: _FilterSegmentLabel(
          key: const Key('topos-filter-visibility-shared'),
          label: 'Shared',
          selected: value == ToposVisibilityFilter.shared,
          colors: colors,
        ),
        ToposVisibilityFilter.private: _FilterSegmentLabel(
          key: const Key('topos-filter-visibility-private'),
          label: 'Private',
          selected: value == ToposVisibilityFilter.private,
          colors: colors,
        ),
      },
      onValueChanged: (next) {
        if (next != null) onChanged(next);
      },
    );
  }
}

/// A label used inside [_VisibilitySegmented]'s `CupertinoSlidingSegmentedControl`
/// `children` map, carrying the caller-supplied [Key] so tests can target
/// each segment directly.
class _FilterSegmentLabel extends StatelessWidget {
  const _FilterSegmentLabel({
    super.key,
    required this.label,
    required this.selected,
    required this.colors,
  });

  final String label;
  final bool selected;
  final MasiColors colors;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        vertical: MasiSpacing.xs,
        horizontal: MasiSpacing.sm,
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: selected ? colors.onAccent : colors.ink2,
        ),
      ),
    );
  }
}

class _ToposList extends StatelessWidget {
  const _ToposList({required this.topos});

  final List<TopoRef> topos;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(
        horizontal: MasiSpacing.lg,
        vertical: MasiSpacing.md,
      ),
      itemCount: topos.length,
      separatorBuilder: (context, index) =>
          const SizedBox(height: MasiSpacing.sm),
      itemBuilder: (context, index) => _TopoRow(topo: topos[index]),
    );
  }
}

class _TopoRow extends ConsumerWidget {
  const _TopoRow({required this.topo});

  final TopoRef topo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final routeCount = topo.routeCount;

    return Material(
      key: Key('topo-item-${topo.wallId}'),
      color: colors.surface,
      borderRadius: BorderRadius.circular(MasiRadii.card),
      child: InkWell(
        borderRadius: BorderRadius.circular(MasiRadii.card),
        onTap: () => context.push('/walls/${topo.wallId}'),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: MasiSpacing.md,
            vertical: MasiSpacing.sm,
          ),
          child: Row(
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
                          '$routeCount route${routeCount == 1 ? '' : 's'}',
                          style: textTheme.titleSmall?.copyWith(
                            color: colors.ink2,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        _VisibilityBadge(
                          wallId: topo.wallId,
                          isShared: topo.visibility == 'shared',
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                key: Key('topo-menu-${topo.wallId}'),
                icon: Icon(Icons.more_vert, color: colors.ink3),
                onSelected: (value) {
                  switch (value) {
                    case 'rename':
                      _handleRename(context, ref, topo);
                    case 'move':
                      _handleMove(context, ref, topo);
                    case 'publish':
                      _handlePublish(context, ref, topo);
                    case 'unpublish':
                      _handleUnpublish(ref, topo);
                    case 'show-on-map':
                      _handleShowOnMap(context, topo);
                    case 'delete':
                      _handleDelete(context, ref, topo);
                  }
                },
                itemBuilder: (context) {
                  final isShared = topo.visibility == 'shared';
                  final hasCoords =
                      topo.latitude != null && topo.longitude != null;
                  return [
                    PopupMenuItem(
                      key: Key('topo-rename-${topo.wallId}'),
                      value: 'rename',
                      child: const Text('Rename'),
                    ),
                    PopupMenuItem(
                      key: Key('topo-move-${topo.wallId}'),
                      value: 'move',
                      child: const Text('Move to…'),
                    ),
                    PopupMenuItem(
                      key: Key('topo-publish-${topo.wallId}'),
                      value: isShared ? 'unpublish' : 'publish',
                      child: Text(isShared ? 'Unpublish' : 'Publish'),
                    ),
                    // Enabled only when the wall actually has coordinates
                    // (from EXIF/device GPS capture at photo-attach time —
                    // see `setWallCoordinates`); a located topo pushes
                    // straight into `/community`'s Map tab, focused on this
                    // wall (see `_handleShowOnMap`). Rather than omitting the
                    // item entirely when unlocated, it stays visible but
                    // disabled with a "No location set" hint, so a user
                    // isn't left wondering why the action is missing.
                    PopupMenuItem(
                      key: Key('topo-show-on-map-${topo.wallId}'),
                      value: 'show-on-map',
                      enabled: hasCoords,
                      child: hasCoords
                          ? const Text('Show on map')
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Text('Show on map'),
                                Text(
                                  'No location set',
                                  style: textTheme.labelSmall?.copyWith(
                                    color: colors.ink3,
                                  ),
                                ),
                              ],
                            ),
                    ),
                    PopupMenuItem(
                      key: Key('topo-delete-${topo.wallId}'),
                      value: 'delete',
                      child: const Text('Delete'),
                    ),
                  ];
                },
              ),
              Icon(Icons.chevron_right, color: colors.ink3),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _handleRename(
    BuildContext context,
    WidgetRef ref,
    TopoRef topo,
  ) async {
    final newName = await showDialog<String>(
      context: context,
      builder: (dialogContext) => _TopoNameDialog(initialValue: topo.name),
    );
    if (newName == null) return;
    await ref
        .read(libraryCrudRepositoryProvider)
        .renameWall(topo.wallId, newName);
  }

  /// "Move to…" flow: resolves [topo]'s destination-sector candidates
  /// (this device's own, non-default sectors across every area — see
  /// [LibraryCrudRepository.listOwnSectors]'s doc for why FOREIGN sectors
  /// are never offered — minus [topo]'s CURRENT sector, resolved via
  /// [LibraryCrudRepository.wallSectorId] since [TopoRef] itself carries no
  /// `sectorId`), labels each candidate `"AreaName › SectorName"` (area
  /// names come from the unfiltered [LibraryCrudRepository.listAreas] purely
  /// for display — a sector's own ownership, not its area's, gates whether
  /// it's offered), shows [showMoveTargetPicker], and on a selection calls
  /// [LibraryCrudRepository.moveWall] followed by a confirmation [SnackBar].
  /// A no-op if the sheet is dismissed without a selection.
  Future<void> _handleMove(
    BuildContext context,
    WidgetRef ref,
    TopoRef topo,
  ) async {
    final repo = ref.read(libraryCrudRepositoryProvider);
    final myUid = ref.read(authStateProvider).asData?.value.uid;
    final currentSectorId = await repo.wallSectorId(topo.wallId);
    final areas = await repo.listAreas();
    final areaNames = {for (final area in areas) area.id: area.name};
    final ownSectors = await repo.listOwnSectors(myUid);
    final candidates = ownSectors
        .where((sector) => sector.id != currentSectorId)
        .toList();
    if (!context.mounted) return;

    final targetSectorId = await showMoveTargetPicker(
      context,
      title: 'Move "${topo.name}" to…',
      keyPrefix: 'move-target-sector',
      emptyMessage: 'No other sectors available',
      options: [
        for (final sector in candidates)
          MoveTargetOption(
            id: sector.id,
            label: '${areaNames[sector.areaId] ?? 'Unknown'} › ${sector.name}',
          ),
      ],
    );
    if (targetSectorId == null) return;

    try {
      await repo.moveWall(topo.wallId, targetSectorId);
    } catch (e, st) {
      debugPrint('Failed to move topo: $e\n$st');
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't move — please try again")),
      );
      return;
    }
    if (!context.mounted) return;

    final targetSector = candidates.firstWhere((s) => s.id == targetSectorId);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Moved to ${targetSector.name}')),
    );
  }

  /// Publishes [topo] to Community after an explicit confirm (this is the
  /// one-way-feeling, "everyone can see this" action, so — mirroring
  /// [_handleDelete]'s confirm-then-act shape — it asks first rather than
  /// firing straight off the menu tap). [_handleUnpublish] (the reverse
  /// direction) needs no such confirmation.
  Future<void> _handlePublish(
    BuildContext context,
    WidgetRef ref,
    TopoRef topo,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Publish to Community?'),
        content: Text(
          '"${topo.name}" will become visible to everyone in Community. '
          'You can unpublish it again at any time.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: Key('topo-publish-confirm-${topo.wallId}'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Publish'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(libraryCrudRepositoryProvider).publishTopo(topo.wallId);
    }
  }

  Future<void> _handleUnpublish(WidgetRef ref, TopoRef topo) {
    return ref.read(libraryCrudRepositoryProvider).unpublishTopo(topo.wallId);
  }

  /// Pushes straight into `/community`'s Map tab, centered/zoomed on
  /// [topo] (see `CommunityScreen`'s `initialTab`/`focusWallId` and
  /// `_MapView`'s `focusWallId` doc). Only ever reachable when the menu
  /// item is enabled (i.e. [topo] has coordinates) — see this row's
  /// `itemBuilder`.
  void _handleShowOnMap(BuildContext context, TopoRef topo) {
    context.push('/community?tab=map&focus=${topo.wallId}');
  }

  Future<void> _handleDelete(
    BuildContext context,
    WidgetRef ref,
    TopoRef topo,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete?'),
        content: Text('Delete "${topo.name}"? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: Key('topo-delete-confirm-${topo.wallId}'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(libraryCrudRepositoryProvider).softDeleteWall(topo.wallId);
    }
  }
}

/// Small grade pill shown in a topo row's subtitle (see DESIGN.md "Topos
/// home"): [band]-color background, white text = [label]. Placed before the
/// "N routes" text; omitted entirely by the caller when a topo has no
/// graded route.
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

/// Compact badge marking a topo row's publish state — "Published" (accent
/// fill) for a topo shared to Community, or a muted "Private" otherwise —
/// so the Topos home reads as a clear division between community-visible
/// and owner-only topos. Placed inside the row's grade/route-count [Wrap]
/// (rather than the trailing icon cluster) so it wraps safely alongside
/// them at large text scales instead of widening the [Row] and risking the
/// overflow this row was JUST fixed for; text stays a single short word
/// with a matching icon, never flexible.
class _VisibilityBadge extends StatelessWidget {
  const _VisibilityBadge({required this.wallId, required this.isShared});

  final String wallId;
  final bool isShared;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final label = isShared ? 'Published' : 'Private';
    final foreground = isShared ? colors.onAccent : colors.ink3;
    final background = isShared ? colors.accent : colors.surface2;

    return Semantics(
      label: isShared ? 'Published to Community' : 'Private, not shared',
      child: Container(
        key: Key('topo-visibility-badge-$wallId'),
        padding: const EdgeInsets.symmetric(
          horizontal: MasiSpacing.xs,
          vertical: 2,
        ),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(MasiRadii.control),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isShared ? Icons.public : Icons.lock_outline,
              size: 12,
              color: foreground,
            ),
            const SizedBox(width: 2),
            // `Flexible` (not a bare `Text`) is required here: a `Row`
            // gives non-flexible children an UNBOUNDED main-axis
            // constraint, so without it `maxLines`/`overflow: ellipsis`
            // never engage and the badge overflows its `Wrap` slot at
            // large text scales (regression -- see the "AppBar Organize
            // action + _TopoRow" test this badge sits alongside).
            Flexible(
              child: Text(
                label,
                style: textTheme.labelSmall?.copyWith(
                  color: foreground,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Maps a [GradeBand] to its display color using the [MasiColors] grade
/// tokens (never a hard-coded hex — see DESIGN.md's grade-band table, which
/// these tokens mirror).
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

/// 52x52 rounded thumbnail: the topo's most recent `kind:'original'` photo
/// when it has one and the file is still readable, else an amethyst gradient
/// placeholder. `errorBuilder` covers the file existing-at-query-time but
/// failing to decode/load; `existsSync` covers it having been moved/deleted
/// out from under us, so neither path ever surfaces a broken-image icon.
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

/// Mirrors `crud_list_scaffold.dart`'s `_NameDialog` (controller, disabled
/// submit while empty/whitespace, `onSubmitted`) for the rename flow. Not
/// reused directly: that class is library-private to `crud_list_scaffold.dart`.
/// Reuses its `crud-name-field` / `crud-name-submit` keys, which is safe
/// because only one such dialog is ever on screen at a time.
class _TopoNameDialog extends StatefulWidget {
  const _TopoNameDialog({required this.initialValue});

  final String initialValue;

  @override
  State<_TopoNameDialog> createState() => _TopoNameDialogState();
}

class _TopoNameDialogState extends State<_TopoNameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialValue,
  );
  late bool _canSubmit = _controller.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
  }

  void _onChanged() {
    final canSubmit = _controller.text.trim().isNotEmpty;
    if (canSubmit != _canSubmit) {
      setState(() => _canSubmit = canSubmit);
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename topo'),
      content: TextField(
        key: const Key('crud-name-field'),
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'Name'),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () {
            FocusManager.instance.primaryFocus?.unfocus();
            Navigator.of(context).pop();
          },
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const Key('crud-name-submit'),
          onPressed: _canSubmit ? _submit : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
