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
/// button -- same key, filter glyph (`MasiIcon('filter')`, swapped for
/// `filter_active` while any facet is set), `topos-filter-active-indicator`
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
/// way to the screen edge and pad only its content away from it. See that
/// widget's `bottomInset`.
///
/// **`useRootNavigator: true` is load-bearing, not a detail.** Without it the
/// sheet is pushed onto the SHELL BRANCH's navigator, i.e. INSIDE
/// `NavShell`'s body — so `NavShell`'s floating nav pill, which lives in the
/// `Scaffold.bottomNavigationBar` slot outside that body, was painted ON TOP
/// of the sheet (the reported bug). On the ROOT navigator the sheet route sits
/// above the shell route, which does two things at once: the sheet's own
/// barrier and surface now cover the pill's strip, and the shell route stops
/// being `isCurrent`, which is exactly the route-derived signal `NavShell`
/// reads to hide the pill (see `nav_shell.dart`'s `isFrontmost`). That signal
/// is derived, so it cannot get stuck: it is restored by every way out of this
/// sheet — Done, Clear, a scrim tap, or a back gesture — with nothing for a
/// sheet to remember to reset.
Future<void> _showToposFiltersSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    useRootNavigator: true,
    backgroundColor: Colors.transparent,
    builder: (context) => const _ToposFiltersSheet(),
  );
}

/// The Topos-home Filters sheet: a [GradeRangePicker], a minimum-rating
/// chip row ([MinStarsFilterChips]), a style-tag multi-select
/// ([StyleTagFilterChips] — the same widget and the same OR semantics the
/// Community filter uses), a visibility segmented control
/// (All/Published/Private), and an area multi-select (every real area from
/// [areasProvider] plus an explicit "Unfiled" option mapping to
/// [ToposFilter.unfiledAreaId]), with a Clear action that resets
/// [toposFilterProvider] back to its default (inactive) value.
///
/// Purely a thin view over [toposFilterProvider]: every interaction writes
/// straight through to the shared [ToposFilterController], so the
/// underlying Topos list (watched by [ToposScreen], which stays mounted
/// underneath this modal sheet) updates live while the sheet is still open.
///
/// Layout: the grab handle and the Clear/title/Done row are PINNED and only
/// the facets scroll, so both actions stay reachable no matter how far down the
/// area list the user has scrolled. The whole thing is a `mainAxisSize.min`
/// column with the scroll view in a [Flexible], so a sheet with two areas
/// is still short and only a genuinely tall one grows to fill the screen.
///
/// **There is an explicit "Done", opposite "Clear".** The sheet is
/// `isScrollControlled` and grows to fill the screen, and a full-screen sheet
/// whose only exits are a scrim tap you cannot see and a drag on a 5 px handle
/// is not dismissible in any way a user would find — that was the reported bug.
///
/// Clear resets the facets and STAYS. It is the "start over" control, not a
/// second exit: clearing is very often the first half of "clear this, then set
/// something else", and dismissing on Clear forces the user to reopen the sheet
/// to finish the thought. "Done" is the only exit action, which is the whole
/// point of adding it.
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
    // sheet's surface stopped short and the dimmed list showed through
    // beneath it. Folding the inset into the SCROLL VIEW's padding instead
    // keeps the last chip clear of the screen edge while the surface itself
    // runs all the way to it.
    //
    // NOTE what this value now is, because it CHANGED with
    // `useRootNavigator: true`. This used to read the branch Scaffold's
    // `extendBody`-measured bottom-bar height, so the padding also cleared
    // `NavShell`'s floating pill. The sheet is now a ROOT-navigator route, so
    // this is the plain device safe-area inset — which is the correct number,
    // because the pill is hidden for as long as this sheet is up (see
    // `nav_shell.dart`'s `isFrontmost`) and there is no longer a bar down there
    // to clear.
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
          // Clear leading, Done trailing, title between them — and a [Wrap],
          // NOT a [Row].
          //
          // A Row cannot survive this. Measured at 360x420 @ 3.0x text scale:
          // Material scales a TextButton's padding with the text, so "Clear"
          // alone renders 263 px wide and "Done" 212 px, i.e. 475 px of buttons
          // in a 352 px sheet — a 124 px `RenderFlex overflowed on the right`
          // however the title is flexed, because neither button is compressible
          // and both must stay tappable. Giving the buttons a flex instead just
          // moves the failure: `Flexible` children that take less than their
          // share leave the leftover as a trailing gap, and shrinking them
          // ellipsises the label on the one control that closes the sheet.
          //
          // A Wrap makes the extra text scale cost VERTICAL space instead, which
          // this sheet has (the facet list below is `Flexible` and simply gets
          // shorter). At normal scale all three fit one line and
          // `spaceBetween` renders exactly the intended header — Clear at one
          // end, Done at the other; at a large scale they stack, each fully
          // legible, and nothing overflows. Every child is still bounded by the
          // Wrap's own width, so no single one can overflow either.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: MasiSpacing.xs),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton(
                  key: const Key('topos-filter-clear'),
                  // Resets the facets and stays open — see the class doc.
                  onPressed: controller.clear,
                  child: const Text(
                    'Clear',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: MasiSpacing.xs,
                  ),
                  child: Text(
                    'Filters',
                    style: textTheme.titleLarge,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  key: const Key('topos-filter-done'),
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text(
                    'Done',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
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

/// A [ToposVisibilityFilter] segmented toggle (All/Published/Private) for
/// [_ToposFiltersSheet], visually mirroring [GradeRangePicker]'s
/// `CupertinoSlidingSegmentedControl` (that widget's own segment-label
/// helper is private to its file, so this replicates rather than imports
/// it). Purely controlled: [value] is the current selection, [onChanged]
/// fires with the new value on every tap.
///
/// **The middle segment reads "Published", not "Shared"** — the same word
/// [_VisibilityBadge] stamps on the rows this segment selects (see
/// `topos_badges.dart`'s header for the owner's three-words-for-three-facts
/// decision). It said "Shared" until the two were reconciled, which meant
/// filtering by *Shared* returned rows badged *Published*. The enum value is
/// still [ToposVisibilityFilter.shared] and the stored `walls.visibility`
/// column still holds `'shared'`: this is a label, and renaming data to match
/// a label would be a migration for no gain.
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
          label: 'Published',
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
