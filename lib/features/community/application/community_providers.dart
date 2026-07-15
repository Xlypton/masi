import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/database_provider.dart';
import '../../../shared/filtering/grade_range.dart';
import '../data/community_repository.dart';

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
  });

  /// The grade-range bound (see `GradeRange.isActive`/`matchesSortKey`).
  final GradeRange grade;

  /// The selected route styles (a subset of `styleFilterOptions`'s values);
  /// empty means "no style filter" (matches every style).
  final Set<String> styles;

  /// Whether either sub-filter is currently constraining the feed — used to
  /// show/hide the filter button's active-indicator dot and to pick the
  /// "no topos match your filters" vs. "no shared topos yet" empty state.
  bool get isActive => grade.isActive || styles.isNotEmpty;

  /// Whether [topo] satisfies both sub-filters (AND): when [grade] is
  /// active, at least one of [topo]'s `routeGradeKeys` must fall in range;
  /// when [styles] is non-empty, at least one of [topo]'s `routeStyles`
  /// must be selected. An inactive sub-filter always matches.
  bool matches(SharedTopo topo) {
    final gradeOk =
        !grade.isActive || topo.routeGradeKeys.any(grade.matchesSortKey);
    final stylesOk = styles.isEmpty || topo.routeStyles.any(styles.contains);
    return gradeOk && stylesOk;
  }

  CommunityFilter copyWith({GradeRange? grade, Set<String>? styles}) {
    return CommunityFilter(
      grade: grade ?? this.grade,
      styles: styles ?? this.styles,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CommunityFilter &&
          other.grade == grade &&
          other.styles.length == styles.length &&
          other.styles.containsAll(styles));

  @override
  int get hashCode => Object.hash(grade, Object.hashAllUnordered(styles));

  @override
  String toString() => 'CommunityFilter(grade: $grade, styles: $styles)';
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

  /// Resets both sub-filters to inactive.
  void clear() {
    state = const CommunityFilter();
  }
}

final communityFilterProvider =
    NotifierProvider<CommunityFilterNotifier, CommunityFilter>(
      CommunityFilterNotifier.new,
    );
