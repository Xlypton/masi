import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/database_provider.dart';
import '../../../shared/filtering/grade_range.dart';
import '../../account/application/auth_providers.dart';
import '../data/library_crud_repository.dart';

/// The [LibraryCrudRepository] wired to the shared [appDatabaseProvider] /
/// [nowMsProvider], matching the pattern used by the other repository
/// providers in `database_provider.dart`. `currentUid` comes from the
/// shared [currentUidProvider] seam, which reads the signed-in uid lazily
/// (per INSERT) and degrades to signed-out (`null`) if auth is unavailable
/// — see its doc for the local-first rationale. `photoFiles` comes from the
/// shared [photoFilesProvider] so this repo's photo-path resolution shares
/// its memoized docs-path cache with [photoRepositoryProvider] (and with
/// whatever pre-warmed it at startup — see `main.dart`) instead of each
/// repo carrying its own cold, unshared `PhotoFiles()`.
final libraryCrudRepositoryProvider = Provider<LibraryCrudRepository>(
  (ref) => LibraryCrudRepository(
    ref.watch(appDatabaseProvider),
    nowMs: ref.watch(nowMsProvider),
    currentUid: ref.watch(currentUidProvider),
    // Disambiguates a null `currentUid` (see `hasKnownSession`'s doc): read
    // lazily per call, like `currentUid` itself, so this provider never
    // rebuilds on an auth change and no guarded mutation freezes a stale
    // answer into itself.
    hasKnownSession: () => ref.read(hasKnownLocalSessionProvider),
    photoFiles: ref.watch(photoFilesProvider),
  ),
);

/// Live list of non-deleted areas, ordered by name then creation time.
final areasProvider = StreamProvider<List<AreaRef>>(
  (ref) => ref.watch(libraryCrudRepositoryProvider).watchAreas(),
);

/// Live list of non-deleted sectors scoped to a single area, ordered by
/// sortOrder then creation time.
final sectorsProvider = StreamProvider.family<List<SectorRef>, String>(
  (ref, areaId) =>
      ref.watch(libraryCrudRepositoryProvider).watchSectors(areaId),
);

/// Live list of non-deleted walls scoped to a single sector, ordered by
/// sortOrder then creation time.
final wallsProvider = StreamProvider.family<List<WallRef>, String>(
  (ref, sectorId) =>
      ref.watch(libraryCrudRepositoryProvider).watchWalls(sectorId),
);

/// Live flat list of every non-deleted wall (a "topo"), each paired with its
/// thumbnail path and route count, ordered newest-first. Backs the flat
/// Topos-home list.
///
/// Reactive to auth (Hole A, adversarial-review 2026-07-21): `ref.watch`es
/// the CURRENT uid off [authStateProvider] and passes it to
/// [LibraryCrudRepository.watchTopos] on every build, rather than letting
/// the repository read a `currentUid` closure once and freeze it into the
/// stream forever. Riverpod rebuilds this provider (dropping the old
/// subscription and opening a fresh one with the new uid) whenever
/// [authStateProvider] emits a new session — including an in-app account
/// switch (sign out -> sign in as someone else, no app restart, since this
/// app is local-first with one on-device SQLite store) and first sign-in
/// (where [LibraryCrudRepository.watchTopos]'s own-or-unowned predicate
/// already includes the caller's not-yet-claimed unowned rows, so nothing
/// has to wait for `claimOwnership` to land before it's visible).
/// Scoped through [effectiveUidProvider] — the SINGLE local-data uid door
/// (§1c). It must NOT read `authStateProvider.asData?.value.uid`: `asData` is
/// null for `AsyncError` as well as `AsyncLoading`, so one transient
/// auth-stream error (gotrue's offline 10s refresh ticker `addError`s on every
/// tick) collapsed `watchTopos`' owner filter to `owner_id IS NULL` and — since
/// `claimOwnership` stamps `ownerId` on every row at first sign-in — rendered
/// the whole library as a SUCCESSFUL empty stream ("No topos yet", no Retry).
/// [effectiveUidProvider] still rebuilds this provider on every auth emission,
/// so the account-switch reactivity described above is unchanged.
final toposProvider = StreamProvider<List<TopoRef>>((ref) {
  final ownerUid = ref.watch(effectiveUidProvider);
  return ref.watch(libraryCrudRepositoryProvider).watchTopos(ownerUid);
});

/// The display name of a single wall (a "topo"), or `null` if it has none /
/// doesn't exist. Backs the topo canvas screen's title chrome — see
/// `TopoCanvasScreen` in `topo_canvas_screen.dart`, which falls back to a
/// generic "Topo" label while this is loading or resolves to null.
final wallNameProvider = FutureProvider.family<String?, String>(
  (ref, wallId) => ref.watch(libraryCrudRepositoryProvider).wallName(wallId),
);

// ---------------------------------------------------------------------
// Map search reads — see `features/community/data/map_search.dart`'s
// `mapContentSearch`, which combines these with [toposProvider].
// ---------------------------------------------------------------------

/// Live list of every non-deleted route on a GPS-located wall — see
/// [LocatedRouteRef]. Backs the map search's route results.
final locatedRoutesProvider = StreamProvider<List<LocatedRouteRef>>(
  (ref) => ref.watch(libraryCrudRepositoryProvider).watchLocatedRoutes(),
);

/// Live list of every non-deleted, non-sentinel sector with at least one
/// located descendant wall, paired with its centroid — see
/// [LocatedSectorRef]. Backs the map search's sector results.
final locatedSectorsProvider = StreamProvider<List<LocatedSectorRef>>(
  (ref) => ref.watch(libraryCrudRepositoryProvider).watchLocatedSectors(),
);

/// Live list of every non-deleted, non-sentinel area with at least one
/// located wall anywhere under its sectors, paired with its centroid — see
/// [LocatedAreaRef]. Backs the map search's area results.
final locatedAreasProvider = StreamProvider<List<LocatedAreaRef>>(
  (ref) => ref.watch(libraryCrudRepositoryProvider).watchLocatedAreas(),
);

// ---------------------------------------------------------------------
// Topos-home filtering (Subtask D, ~/.claude/plans/masi-filtering.md)
// ---------------------------------------------------------------------

/// Which visibility bucket a [ToposFilter] restricts the Topos home to:
/// `all` (no restriction), `shared` (published to Community, see
/// [TopoRef.visibility]), or `private` (owner-only).
enum ToposVisibilityFilter { all, shared, private }

/// Filter state for the Topos home (see `ToposScreen`'s Filters sheet,
/// opened via its `topos-filter-button`): a [GradeRange] over each topo's
/// live route grades ([TopoRef.routeGradeKeys]), a [ToposVisibilityFilter],
/// and a set of area ids to restrict to.
///
/// [areaIds] may contain [unfiledAreaId], a pseudo-id matching a topo with
/// no real area ([TopoRef.areaId] == null — filed under the hidden
/// `__default__` sentinel; see [LibraryCrudRepository.watchTopos]'s doc).
class ToposFilter {
  const ToposFilter({
    this.grade = const GradeRange(),
    this.visibility = ToposVisibilityFilter.all,
    this.areaIds = const {},
  });

  /// Pseudo area-id in [areaIds] that matches a topo with `areaId == null`
  /// (i.e. filed under the hidden `__default__` sentinel Area/Sector).
  static const String unfiledAreaId = '__unfiled__';

  final GradeRange grade;
  final ToposVisibilityFilter visibility;
  final Set<String> areaIds;

  /// Whether any facet of this filter actually restricts the list — when
  /// `false`, [matches] accepts every topo.
  bool get isActive =>
      grade.isActive ||
      visibility != ToposVisibilityFilter.all ||
      areaIds.isNotEmpty;

  /// Whether [topo] satisfies every ACTIVE facet of this filter (AND across
  /// facets — an inactive facet never excludes anything):
  /// - grade: at least one of [TopoRef.routeGradeKeys] falls in [grade]'s
  ///   range (only checked when [GradeRange.isActive]; a topo with no
  ///   graded routes is excluded by an active grade filter).
  /// - visibility: [TopoRef.visibility] matches (`'shared'`/`'private'`),
  ///   only checked when [visibility] isn't [ToposVisibilityFilter.all].
  /// - area: [TopoRef.areaId] (or [unfiledAreaId] when `null`) is a member
  ///   of [areaIds], only checked when [areaIds] is non-empty.
  bool matches(TopoRef topo) {
    if (grade.isActive && !topo.routeGradeKeys.any(grade.matchesSortKey)) {
      return false;
    }
    if (visibility != ToposVisibilityFilter.all) {
      final wantsShared = visibility == ToposVisibilityFilter.shared;
      if ((topo.visibility == 'shared') != wantsShared) return false;
    }
    if (areaIds.isNotEmpty && !areaIds.contains(topo.areaId ?? unfiledAreaId)) {
      return false;
    }
    return true;
  }

  ToposFilter copyWith({
    GradeRange? grade,
    ToposVisibilityFilter? visibility,
    Set<String>? areaIds,
  }) {
    return ToposFilter(
      grade: grade ?? this.grade,
      visibility: visibility ?? this.visibility,
      areaIds: areaIds ?? this.areaIds,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ToposFilter &&
          other.grade == grade &&
          other.visibility == visibility &&
          setEquals(other.areaIds, areaIds));

  @override
  int get hashCode =>
      Object.hash(grade, visibility, Object.hashAllUnordered(areaIds));

  @override
  String toString() =>
      'ToposFilter(grade: $grade, visibility: $visibility, '
      'areaIds: $areaIds)';
}

/// Filters [topos] down to those matching every active facet of [filter]
/// (see [ToposFilter.matches]), preserving [topos]' relative order. Returns
/// every topo (as a new list) when [filter] is inactive.
List<TopoRef> applyToposFilter(List<TopoRef> topos, ToposFilter filter) =>
    topos.where(filter.matches).toList();

/// Holds the Topos-home [ToposFilter] (see `ToposScreen`'s Filters sheet).
/// Starts at the default, inactive filter (every topo shown); every
/// setter/toggle/clear method REPLACES [state] with a new [ToposFilter]
/// (never mutates one in place) so Riverpod's equality-based
/// rebuild-skipping (via [ToposFilter.==]) behaves correctly.
class ToposFilterController extends Notifier<ToposFilter> {
  @override
  ToposFilter build() => const ToposFilter();

  void setGrade(GradeRange grade) {
    state = state.copyWith(grade: grade);
  }

  void setVisibility(ToposVisibilityFilter visibility) {
    state = state.copyWith(visibility: visibility);
  }

  /// Toggles [areaId] (a real Area's id, or [ToposFilter.unfiledAreaId]) in
  /// the selected area set: adds it if absent, removes it if present.
  void toggleArea(String areaId) {
    final next = Set<String>.from(state.areaIds);
    if (!next.remove(areaId)) next.add(areaId);
    state = state.copyWith(areaIds: next);
  }

  /// Resets every facet back to the default (inactive) filter.
  void clear() {
    state = const ToposFilter();
  }
}

final toposFilterProvider =
    NotifierProvider<ToposFilterController, ToposFilter>(
      ToposFilterController.new,
    );
