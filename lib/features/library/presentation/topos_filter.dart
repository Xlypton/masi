part of 'topos_screen.dart';

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

/// Like [_matchesQuery], but over a [ProximityTopoEntry] — an own entry
/// delegates straight to [_matchesQuery] against its [ProximityTopoEntry.
/// ownTopo]; a community entry (no [TopoRef.areaId]/`topGradeLabel` in the
/// same shape) matches on its name and, when present, its
/// [SharedTopo.topGradeLabel].
bool _matchesProximityQuery(ProximityTopoEntry entry, String query) {
  final own = entry.ownTopo;
  if (own != null) return _matchesQuery(own, query);
  if (entry.name.toLowerCase().contains(query)) return true;
  final grade = entry.communityTopo?.topGradeLabel;
  if (grade != null && grade.toLowerCase().contains(query)) return true;
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
            // `ValueListenableBuilder` (not a bare `TextField`) so the
            // clear ('x') suffix can appear/disappear as the controller's
            // text goes non-empty/empty, without this whole bar needing to
            // become stateful -- `TextEditingController` is itself a
            // `ValueListenable<TextEditingValue>`.
            child: ValueListenableBuilder<TextEditingValue>(
              valueListenable: searchController,
              builder: (context, value, _) {
                return TextField(
                  key: const Key('topos-search-field'),
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
                    suffixIcon: value.text.isEmpty
                        ? null
                        : IconButton(
                            key: const Key('topos-search-clear'),
                            icon: MasiIcon(
                              'close',
                              size: 16,
                              color: colors.ink3,
                            ),
                            tooltip: 'Clear search',
                            onPressed: searchController.clear,
                          ),
                    suffixIconConstraints: const BoxConstraints(
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
                );
              },
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
            icon: MasiIcon(
              isActive ? 'filter_active' : 'filter',
              color: colors.accent,
            ),
            tooltip: 'Filters',
            onPressed: onTap,
          ),
        ],
      ),
    );
  }
}

/// Opens the Topos-home Filters sheet (see [_ToposFiltersSheet]) from the
/// `topos-filter-button` app-bar action.
///
/// `useSafeArea: true` wraps the sheet in `SafeArea(bottom: false)` — it
/// keeps the sheet's TOP clear of the status bar/notch once the content is
/// tall enough to fill the screen, while deliberately leaving the BOTTOM
/// inset unconsumed so [_ToposFiltersSheet] can paint its surface all the
/// way to the screen edge (under `NavShell`'s floating bar) and pad only its
/// content away from it. See that widget's `bottomInset`.
Future<void> _showToposFiltersSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (context) => const _ToposFiltersSheet(),
  );
}

/// The Topos-home Filters sheet: a [GradeRangePicker], a minimum-rating
/// chip row ([MinStarsFilterChips]), a style-tag multi-select
/// ([StyleTagFilterChips] — the same widget and the same OR semantics the
/// Community filter uses), a visibility segmented control
/// (All/Shared/Private), and an area multi-select (every real area from
/// [areasProvider] plus an explicit "Unfiled" option mapping to
/// [ToposFilter.unfiledAreaId]), with a Clear action that resets
/// [toposFilterProvider] back to its default (inactive) value.
///
/// Purely a thin view over [toposFilterProvider]: every interaction writes
/// straight through to the shared [ToposFilterController], so the
/// underlying Topos list (watched by [ToposScreen], which stays mounted
/// underneath this modal sheet) updates live while the sheet is still open.
///
/// Layout: the grab handle and the title/Clear row are PINNED and only the
/// facets scroll, so Clear stays reachable no matter how far down the area
/// list the user has scrolled. The whole thing is a `mainAxisSize.min`
/// column with the scroll view in a [Flexible], so a sheet with two areas
/// is still short and only a genuinely tall one grows to fill the screen.
class _ToposFiltersSheet extends ConsumerWidget {
  const _ToposFiltersSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final filter = ref.watch(toposFilterProvider);
    final controller = ref.read(toposFilterProvider.notifier);
    final areas = ref.watch(areasProvider).asData?.value ?? const <AreaRef>[];

    // NOT a `SafeArea` wrapper (which is what this used to be, and was the
    // bug): a SafeArea puts the inset OUTSIDE the decorated box, so the
    // sheet's surface stopped short and the dimmed list plus `NavShell`'s
    // floating bar showed through beneath it. Under `Scaffold.extendBody`
    // this value is the REAL measured bottom-bar height (see `NavShell`'s
    // doc), so folding it into the SCROLL VIEW's padding instead keeps the
    // last chip clear of the bar while the surface itself runs to the
    // screen edge.
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        // `MasiRadii.large` (not `.card`) per DESIGN.md's radius token
        // table: a full-screen modal sheet's top corners use the larger
        // radius, `.card` is reserved for in-list row surfaces.
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(MasiRadii.large),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // iOS grab handle. Cosmetic, but it's the affordance that tells a
          // user this surface is draggable-to-dismiss at all.
          Center(
            child: Container(
              width: 36,
              height: 5,
              margin: const EdgeInsets.only(
                top: MasiSpacing.sm,
                bottom: MasiSpacing.xs,
              ),
              decoration: BoxDecoration(
                color: colors.separator,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              MasiSpacing.lg,
              MasiSpacing.xs,
              MasiSpacing.sm,
              0,
            ),
            child: Row(
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
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                MasiSpacing.lg,
                MasiSpacing.sm,
                MasiSpacing.lg,
                MasiSpacing.lg + bottomInset,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  GradeRangePicker(
                    value: filter.grade,
                    onChanged: controller.setGrade,
                  ),
                  _FilterSectionLabel('Rating', colors: colors),
                  MinStarsFilterChips(
                    selected: filter.minStars,
                    onChanged: controller.setMinStars,
                  ),
                  _FilterSectionLabel('Visibility', colors: colors),
                  _VisibilitySegmented(
                    value: filter.visibility,
                    onChanged: controller.setVisibility,
                  ),
                  _FilterSectionLabel('Area', colors: colors),
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
                  // Style LAST, deliberately: it is 18 curated chips, five or
                  // six wrapped rows on a phone, so putting it anywhere above
                  // Visibility/Area pushes both of those below the fold on a
                  // small screen for the facet climbers reach for least.
                  _FilterSectionLabel('Style', colors: colors),
                  StyleTagFilterChips(
                    selected: filter.styleTags,
                    onChanged: controller.setStyleTags,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A section heading inside [_ToposFiltersSheet], carrying its own leading
/// gap so the facet list reads as evenly-spaced groups rather than as one
/// run-on column — five hand-written `SizedBox`/`Text` pairs is exactly how
/// the spacing drifted between sections before.
class _FilterSectionLabel extends StatelessWidget {
  const _FilterSectionLabel(this.label, {required this.colors});

  final String label;
  final MasiColors colors;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(
        top: MasiSpacing.lg,
        bottom: MasiSpacing.sm,
      ),
      child: Text(
        label,
        style: Theme.of(
          context,
        ).textTheme.titleSmall?.copyWith(color: colors.ink2),
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
