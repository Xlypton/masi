import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/database_provider.dart';
import '../../../core/location/location_service.dart';
import '../../../shared/filtering/grade_range.dart';
import '../../logbook/application/ascents_providers.dart';
import '../../logbook/data/ascents_repository.dart';
import '../../moderation/application/duplicate_providers.dart';
import '../data/community_repository.dart';
import '../domain/topo_group.dart';

/// The [CommunityRepository] wired to the shared [appDatabaseProvider] /
/// [photoFilesProvider], matching the pattern used by
/// `library_providers.dart`'s `libraryCrudRepositoryProvider`. Read-only (no
/// `nowMs`/`currentUid` seam — this repo never writes a row).
final communityRepositoryProvider = Provider<CommunityRepository>(
  (ref) => CommunityRepository(
    ref.watch(appDatabaseProvider),
    photoFiles: ref.watch(photoFilesProvider),
  ),
);

/// Live list of every shared topo (a non-deleted Wall with
/// `visibility == 'shared'`), newest-first. Backs the Community feed + map.
final sharedToposProvider = StreamProvider<List<SharedTopo>>(
  (ref) => ref.watch(communityRepositoryProvider).watchSharedTopos(),
);

/// One entry in the Community Feed's UNION of shared topos + shared ascent
/// logs (#12 Wave 3, ST5) — the Feed used to render [SharedTopo]s only; it
/// now also surfaces every opt-in-`shared` [SharedAscentEntry], since Wave 3
/// removes the logbook's dedicated home-screen icon (see `feedItemsProvider`
/// for where the "My logbook" entry point moved instead). A sealed class
/// (Dart 3 pattern-matching, per this codebase's `Notifier`/modern-Dart
/// conventions) rather than a plain enum-tagged record, so `_FeedView`'s
/// `itemBuilder` can `switch` on the concrete variant exhaustively.
sealed class FeedItem {
  const FeedItem();

  /// Millisecond sort key shared across both variants, used to interleave
  /// them newest-first in [feedItemsProvider] — a topo's [SharedTopo.createdAt]
  /// (when the wall it wraps has one; see that field's doc) or an ascent's
  /// [SharedAscentEntry.climbedAt].
  int get sortKeyMs;

  /// When this entry ENTERED the feed, which is a different question from
  /// [sortKeyMs] and answered by a different column.
  ///
  /// [sortKeyMs] orders the list by when the climb happened or the topo was
  /// drawn, which is what a reader wants to scroll. This one drives the Feed
  /// tab's unseen dot, and for that the only thing that matters is when the
  /// thing became visible to other people — publishing a topo drawn in January
  /// is a January `createdAt` and a today `updatedAt`. See
  /// [SharedTopo.updatedAt] for the trade-off that choice carries.
  int get feedArrivalMs;

  /// Who this belongs to, so the dot can skip the user's own posts — see
  /// `newestForeignArrival`.
  String? get ownerId;
}

/// A [FeedItem] wrapping a shared topo — renders as the existing `_FeedRow`
/// in `community_screen.dart`, completely unchanged.
class TopoFeedItem extends FeedItem {
  const TopoFeedItem(this.topo, {this.alternates = const []});

  final SharedTopo topo;

  /// Other topos of the SAME PLACE, best first (community editing phase 8b /
  /// C-6.2). Empty for almost every row.
  ///
  /// [topo] is the group's HEAD — the best-ranked member, not necessarily the
  /// canonical one an admin linked to. See `groupTopos`.
  final List<SharedTopo> alternates;

  @override
  int get sortKeyMs => topo.createdAt;

  /// The GROUP's arrival, not just the head's. A duplicate-group row collapses
  /// several topos of one place into one entry (`groupTopos`), and a fresh
  /// alternate appearing under an old head is still something new in the feed.
  @override
  int get feedArrivalMs {
    var newest = topo.updatedAt;
    for (final alternate in alternates) {
      if (alternate.updatedAt > newest) newest = alternate.updatedAt;
    }
    return newest;
  }

  @override
  String? get ownerId => topo.ownerId;

  @override
  bool operator ==(Object other) =>
      other is TopoFeedItem &&
      other.topo == topo &&
      other.alternates.length == alternates.length &&
      _sameOrder(other.alternates, alternates);

  @override
  int get hashCode => Object.hash(topo, Object.hashAll(alternates));

  static bool _sameOrder(List<SharedTopo> a, List<SharedTopo> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// A [FeedItem] wrapping a shared ascent-log entry — renders as
/// `community_screen.dart`'s new `_AscentFeedRow`.
class AscentFeedItem extends FeedItem {
  const AscentFeedItem(this.entry);

  final SharedAscentEntry entry;

  @override
  int get sortKeyMs => entry.climbedAt.millisecondsSinceEpoch;

  @override
  int get feedArrivalMs => entry.updatedAt;

  @override
  String? get ownerId => entry.ownerId;

  @override
  bool operator ==(Object other) =>
      other is AscentFeedItem && other.entry == entry;

  @override
  int get hashCode => entry.hashCode;
}

/// The Community Feed's combined data source (#12 Wave 3, ST5): a UNION of
/// [sharedToposProvider] + [sharedAscentsProvider], merged into one
/// newest-first [FeedItem] list by [FeedItem.sortKeyMs].
///
/// A plain (non-stream) [Provider] rather than a `StreamProvider` combining
/// two streams manually (e.g. via `Rx.combineLatest2`, which this project
/// doesn't depend on): Riverpod already re-runs this provider's body
/// whenever either upstream `ref.watch` dependency emits a new value, so a
/// plain synchronous combinator gets the same "re-emits on either source
/// updating" behavior for free. Kept NON-`autoDispose` to match
/// [sharedToposProvider]/[sharedAscentsProvider] (both plain, app-lifetime
/// `StreamProvider`s) — the Feed screen watches this for as long as it's
/// mounted, same as before.
///
/// Error/loading propagate from whichever upstream source hit them first
/// (checked topos-then-ascents, an arbitrary but deterministic order) so
/// `CommunityFeedScreen`'s existing `asyncFeedItems.when(...)` friendly
/// error/loading states keep working unchanged — see
/// `community_screen_test.dart`'s "UX: friendly themed error state" group,
/// which fails `sharedToposProvider` specifically and expects exactly this.
final feedItemsProvider = Provider<AsyncValue<List<FeedItem>>>((ref) {
  final toposAsync = ref.watch(sharedToposProvider);
  final ascentsAsync = ref.watch(sharedAscentsProvider);

  if (toposAsync.hasError) {
    return AsyncValue.error(toposAsync.error!, toposAsync.stackTrace!);
  }
  if (ascentsAsync.hasError) {
    return AsyncValue.error(ascentsAsync.error!, ascentsAsync.stackTrace!);
  }

  final topos = toposAsync.asData?.value;
  final ascents = ascentsAsync.asData?.value;
  if (topos == null || ascents == null) {
    return const AsyncValue.loading();
  }

  // Duplicates of the same place collapse to one card (phase 8b / C-6.2).
  // `??` rather than awaiting: the links are a server read, and a feed that
  // blocked on it would stop rendering offline — where it matters most. Until
  // they arrive (or when they never do, at a crag with no signal) the feed
  // shows every topo separately, which is exactly what it did before this
  // phase. Grouping is an improvement on the view, never a precondition for it.
  final links =
      ref.watch(alternateGroupsProvider).asData?.value ??
      const AlternateGroups.empty();
  final groups = groupTopos(topos, links, nowMs: ref.watch(nowMsProvider)());

  final items = <FeedItem>[
    for (final group in groups)
      TopoFeedItem(group.head, alternates: group.alternates),
    for (final ascent in ascents) AscentFeedItem(ascent),
  ]..sort((a, b) => b.sortKeyMs.compareTo(a.sortKeyMs));

  return AsyncValue.data(items);
});

/// Which shared topos are alternates of which (phase 8b / C-6.2).
///
/// Server-only, with no local mirror — a deliberate difference from
/// `wall_moderation`. A missing link degrades to "shown separately", which is
/// the pre-8b feed and costs a reader nothing; a missing MODERATION row would
/// degrade to showing something as approved that is not, which is why that one
/// is mirrored and this one is not.
///
/// Scoped to the wall ids actually in the feed rather than fetched wholesale,
/// so this stays proportional to what is on screen.
final alternateGroupsProvider = FutureProvider<AlternateGroups>((ref) async {
  final topos = ref.watch(sharedToposProvider).asData?.value;
  if (topos == null || topos.isEmpty) return const AlternateGroups.empty();
  final rows = await ref
      .watch(duplicatesRemoteProvider)
      .alternatesFor({for (final topo in topos) topo.wallId});
  return AlternateGroups.fromRows(rows);
});

/// The Community feed/map's grade-range + style filter, held independently
/// of the (Dart-side, in-widget) name search — see `CommunityScreen`'s
/// `_FeedView`/`_MapView`, which AND the two together.
///
/// Immutable value type; screen-agnostic like `GradeRange`/
/// `StyleFilterChips`, but scoped to Community (unlike those two, this type
/// composes them for one screen's specific filter shape, so it lives here
/// rather than under `shared/filtering/`).
class CommunityFilter {
  const CommunityFilter({
    this.grade = const GradeRange(),
    this.styles = const {},
    this.styleTags = const {},
  });

  /// The grade-range bound (see `GradeRange.isActive`/`matchesSortKey`).
  final GradeRange grade;

  /// The selected route styles (a subset of `styleFilterOptions`'s values);
  /// empty means "no style filter" (matches every style).
  final Set<String> styles;

  /// The selected style-TAG keys (a subset of `kCuratedRouteStyles`'
  /// `key`s, e.g. `'dyno'`/`'crimpy'` -- see
  /// `core/routes/route_styles.dart`); empty means "no style-tag filter"
  /// (matches every topo regardless of its routes' tags). Distinct from
  /// [styles]: that's the older single-value sport/trad/boulder facet, this
  /// is the newer multi-tag facet (`SharedTopo.routeStyleTags` /
  /// `StyleTagFilterChips`).
  final Set<String> styleTags;

  /// Whether any sub-filter is currently constraining the feed — used to
  /// show/hide the filter button's active-indicator dot and to pick the
  /// "no topos match your filters" vs. "no shared topos yet" empty state.
  bool get isActive =>
      grade.isActive || styles.isNotEmpty || styleTags.isNotEmpty;

  /// Whether [topo] satisfies every sub-filter (AND): when [grade] is
  /// active, at least one of [topo]'s `routeGradeKeys` must fall in range;
  /// when [styles] is non-empty, at least one of [topo]'s `routeStyles`
  /// must be selected; when [styleTags] is non-empty, at least one of
  /// [topo]'s `routeStyleTags` must be selected. An inactive sub-filter
  /// always matches.
  bool matches(SharedTopo topo) {
    final gradeOk =
        !grade.isActive || topo.routeGradeKeys.any(grade.matchesSortKey);
    final stylesOk = styles.isEmpty || topo.routeStyles.any(styles.contains);
    final styleTagsOk =
        styleTags.isEmpty || topo.routeStyleTags.any(styleTags.contains);
    return gradeOk && stylesOk && styleTagsOk;
  }

  CommunityFilter copyWith({
    GradeRange? grade,
    Set<String>? styles,
    Set<String>? styleTags,
  }) {
    return CommunityFilter(
      grade: grade ?? this.grade,
      styles: styles ?? this.styles,
      styleTags: styleTags ?? this.styleTags,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CommunityFilter &&
          other.grade == grade &&
          other.styles.length == styles.length &&
          other.styles.containsAll(styles) &&
          other.styleTags.length == styleTags.length &&
          other.styleTags.containsAll(styleTags));

  @override
  int get hashCode => Object.hash(
    grade,
    Object.hashAllUnordered(styles),
    Object.hashAllUnordered(styleTags),
  );

  @override
  String toString() =>
      'CommunityFilter(grade: $grade, styles: $styles, '
      'styleTags: $styleTags)';
}

/// Holds the current [CommunityFilter] for the Community screen. Riverpod
/// v3 `Notifier` (not `StateProvider`, per project convention) — mirrors
/// `ActiveViewController`'s shape.
class CommunityFilterNotifier extends Notifier<CommunityFilter> {
  @override
  CommunityFilter build() => const CommunityFilter();

  /// Replaces the grade-range bound, e.g. from a `GradeRangePicker`'s
  /// `onChanged`.
  void setGrade(GradeRange grade) {
    state = state.copyWith(grade: grade);
  }

  /// Replaces the selected style set, e.g. from a `StyleFilterChips`'s
  /// `onChanged`.
  void setStyles(Set<String> styles) {
    state = state.copyWith(styles: styles);
  }

  /// Replaces the selected style-tag set, e.g. from a
  /// `StyleTagFilterChips`'s `onChanged`.
  void setStyleTags(Set<String> styleTags) {
    state = state.copyWith(styleTags: styleTags);
  }

  /// Resets every sub-filter (grade, styles, styleTags) to inactive.
  void clear() {
    state = const CommunityFilter();
  }
}

final communityFilterProvider =
    NotifierProvider<CommunityFilterNotifier, CommunityFilter>(
      CommunityFilterNotifier.new,
    );

/// The device's current position, fetched once (best-effort, via
/// [locationServiceProvider]) whenever the Community map's `_MapView` first
/// watches this — i.e. on opening the Map tab. Backs the "you are here"
/// marker; `AsyncLoading`/`AsyncError`/a `null` `AsyncData` all mean "don't
/// draw the marker", never a crash (see `LocationService.currentLocation`'s
/// "never throws" contract — this can only ever end up `AsyncError` if a
/// [locationServiceProvider] override itself throws, which a well-behaved
/// implementation never does).
///
/// `autoDispose` so leaving the Community screen drops the cached result —
/// coming back later re-fetches rather than showing an arbitrarily stale
/// position from a previous visit.
final myLocationProvider = FutureProvider.autoDispose<DeviceLocation?>(
  (ref) => ref.watch(locationServiceProvider).currentLocation(),
);
