import '../../../core/grades/grade_system.dart';

/// Immutable read model for a non-deleted Area row.
class AreaRef {
  const AreaRef({required this.id, required this.name, this.description});

  final String id;
  final String name;
  final String? description;

  @override
  bool operator ==(Object other) =>
      other is AreaRef &&
      other.id == id &&
      other.name == name &&
      other.description == description;

  @override
  int get hashCode => Object.hash(id, name, description);

  @override
  String toString() =>
      'AreaRef(id: $id, name: $name, description: $description)';
}

/// Immutable read model for a non-deleted Sector row.
class SectorRef {
  const SectorRef({
    required this.id,
    required this.areaId,
    required this.name,
    required this.sortOrder,
  });

  final String id;
  final String areaId;
  final String name;
  final int sortOrder;

  @override
  bool operator ==(Object other) =>
      other is SectorRef &&
      other.id == id &&
      other.areaId == areaId &&
      other.name == name &&
      other.sortOrder == sortOrder;

  @override
  int get hashCode => Object.hash(id, areaId, name, sortOrder);

  @override
  String toString() =>
      'SectorRef(id: $id, areaId: $areaId, name: $name, '
      'sortOrder: $sortOrder)';
}

/// Immutable read model for a non-deleted Wall row.
class WallRef {
  const WallRef({
    required this.id,
    required this.sectorId,
    required this.name,
    required this.sortOrder,
  });

  final String id;
  final String sectorId;
  final String name;
  final int sortOrder;

  @override
  bool operator ==(Object other) =>
      other is WallRef &&
      other.id == id &&
      other.sectorId == sectorId &&
      other.name == name &&
      other.sortOrder == sortOrder;

  @override
  int get hashCode => Object.hash(id, sectorId, name, sortOrder);

  @override
  String toString() =>
      'WallRef(id: $id, sectorId: $sectorId, name: $name, '
      'sortOrder: $sortOrder)';
}

/// Immutable read model for a flat "topo" row: a non-deleted Wall paired
/// with its live `kind:'original'` photo (as a thumbnail path, if any), a
/// live count of its non-deleted routes, and the wall's representative grade
/// (the hardest non-deleted, graded route on the wall). Backs the flat
/// Topos-home list.
class TopoRef {
  const TopoRef({
    required this.wallId,
    required this.name,
    required this.thumbnailPath,
    required this.routeCount,
    required this.createdAt,
    this.topGradeLabel,
    this.topGradeBand,
    this.visibility = 'private',
    this.areaId,
    this.areaName,
    this.routeGradeKeys = const [],
    this.latitude,
    this.longitude,
  });

  final String wallId;
  final String name;
  final String? thumbnailPath;
  final int routeCount;
  final int createdAt;

  /// Display label ([db.Route.gradeRaw]) of the hardest non-deleted, graded
  /// route on this wall, or `null` if the wall has no graded routes.
  final String? topGradeLabel;

  /// [GradeBand] (classified via `core/grades`'s [bandForSortKey] from the
  /// hardest route's `gradeSortKey`) matching [topGradeLabel]. Always
  /// non-null exactly when [topGradeLabel] is non-null.
  final GradeBand? topGradeBand;

  /// This wall's [db.Wall.visibility]: `'private'` (default; owner-only) or
  /// `'shared'` (published to Community — see [LibraryCrudRepository.
  /// publishTopo]/[LibraryCrudRepository.unpublishTopo]). Backs the Topos
  /// home row's Publish/Unpublish menu item.
  final String visibility;

  /// The id of this topo's ancestor Area (Wall -> Sector -> Area), or `null`
  /// when the wall is filed under the hidden `__default__` sentinel Area
  /// (see [LibraryCrudRepository._ensureDefaultAreaId]/[LibraryCrudRepository
  /// .createTopo]) -- treated as "Unfiled" by the Topos-home area filter
  /// (see `ToposFilter` in `library_providers.dart`). Never the sentinel's
  /// own id -- see [watchTopos]'s doc for the detection.
  final String? areaId;

  /// The display name of [areaId]'s Area, or `null` under the same
  /// conditions as [areaId] (including when the wall has no area at all).
  final String? areaName;

  /// The `gradeSortKey` of every live (non-deleted), graded route on this
  /// wall, deduplicated (via `group_concat(DISTINCT ...)`) and sorted
  /// ascending -- parsed from [watchTopos]'s `route_grade_keys` column.
  /// Empty when the wall has no graded routes. Used to filter the Topos
  /// home by grade range (see `ToposFilter.matches` in
  /// `library_providers.dart`): a topo matches an active `GradeRange` iff
  /// ANY of its route grade keys falls in range.
  final List<double> routeGradeKeys;

  /// Coordinates captured directly on this wall (see [db.Walls.latitude]/
  /// [db.Walls.longitude], populated automatically from a freshly-picked
  /// photo's EXIF GPS tags via [LibraryCrudRepository.setWallCoordinates]),
  /// or `null` if none have been recorded. Mirrors `SharedTopo.latitude`/
  /// `longitude` in `community_repository.dart` — backs the Community map's
  /// "own topos" markers (see `_MapView` in `community_screen.dart`).
  final double? latitude;
  final double? longitude;

  @override
  bool operator ==(Object other) =>
      other is TopoRef &&
      other.wallId == wallId &&
      other.name == name &&
      other.thumbnailPath == thumbnailPath &&
      other.routeCount == routeCount &&
      other.createdAt == createdAt &&
      other.topGradeLabel == topGradeLabel &&
      other.topGradeBand == topGradeBand &&
      other.visibility == visibility &&
      other.areaId == areaId &&
      other.areaName == areaName &&
      _listEquals(other.routeGradeKeys, routeGradeKeys) &&
      other.latitude == latitude &&
      other.longitude == longitude;

  @override
  int get hashCode => Object.hash(
    wallId,
    name,
    thumbnailPath,
    routeCount,
    createdAt,
    topGradeLabel,
    topGradeBand,
    visibility,
    areaId,
    areaName,
    Object.hashAll(routeGradeKeys),
    Object.hash(latitude, longitude),
  );

  @override
  String toString() =>
      'TopoRef(wallId: $wallId, name: $name, thumbnailPath: $thumbnailPath, '
      'routeCount: $routeCount, createdAt: $createdAt, '
      'topGradeLabel: $topGradeLabel, topGradeBand: $topGradeBand, '
      'visibility: $visibility, areaId: $areaId, areaName: $areaName, '
      'routeGradeKeys: $routeGradeKeys, latitude: $latitude, '
      'longitude: $longitude)';
}

/// Order-sensitive element-wise equality for [TopoRef.routeGradeKeys] (a
/// plain `List<double>` doesn't override `==` to mean "same elements");
/// safe to compare positionally since [_parseGradeKeys] sorts its output,
/// keeping repeated parses of the same underlying data deterministic.
/// Mirrors `CommunityRepository`'s analogous `SharedTopo.routeGradeKeys`
/// helper.
bool _listEquals(List<double> a, List<double> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Immutable read model for a single non-deleted [db.Route] whose wall has
/// recorded GPS coordinates ([db.Walls.latitude]/[longitude] non-null) —
/// i.e. a route that can be placed on the map. Backs the map search's route
/// results (see `mapContentSearch` in
/// `features/community/data/map_search.dart`); returned by
/// [LibraryCrudRepository.watchLocatedRoutes].
class LocatedRouteRef {
  const LocatedRouteRef({
    required this.routeId,
    required this.number,
    this.name,
    required this.wallId,
    required this.wallName,
    required this.latitude,
    required this.longitude,
  });

  final String routeId;
  final int number;

  /// The route's own name, or `null`/empty when the climber never named it.
  /// See [title] for the display fallback.
  final String? name;

  final String wallId;

  /// The name of this route's wall (its "topo") — used as the map search
  /// result's subtitle for a route hit.
  final String wallName;

  /// This route's wall's GPS coordinates — a route has no coordinates of
  /// its own (see `db.Routes`' doc in `core/db/tables.dart`), so it is
  /// placed wherever its wall is.
  final double latitude;
  final double longitude;

  /// Display title: [name] if non-empty (after trimming), else `'Route
  /// &lt;number&gt;'`. Mirrors how `topo_canvas_screen.dart` labels an
  /// unnamed route in its route list.
  String get title {
    final trimmed = name?.trim();
    return (trimmed != null && trimmed.isNotEmpty) ? trimmed : 'Route $number';
  }

  @override
  bool operator ==(Object other) =>
      other is LocatedRouteRef &&
      other.routeId == routeId &&
      other.number == number &&
      other.name == name &&
      other.wallId == wallId &&
      other.wallName == wallName &&
      other.latitude == latitude &&
      other.longitude == longitude;

  @override
  int get hashCode =>
      Object.hash(routeId, number, name, wallId, wallName, latitude, longitude);

  @override
  String toString() =>
      'LocatedRouteRef(routeId: $routeId, number: $number, name: $name, '
      'wallId: $wallId, wallName: $wallName, latitude: $latitude, '
      'longitude: $longitude)';
}

/// Immutable read model for a non-deleted [db.Sector] that has at least one
/// located descendant wall ([db.Walls.latitude]/[longitude] non-null) —
/// [latitude]/[longitude] are the arithmetic-mean centroid over exactly
/// those located walls (see [LibraryCrudRepository.watchLocatedSectors]). A
/// sector with zero located walls has no [LocatedSectorRef] at all — there
/// is deliberately no all-zero/fallback instance.
class LocatedSectorRef {
  const LocatedSectorRef({
    required this.id,
    required this.name,
    required this.latitude,
    required this.longitude,
  });

  final String id;
  final String name;

  /// Centroid latitude/longitude over this sector's located walls.
  final double latitude;
  final double longitude;

  @override
  bool operator ==(Object other) =>
      other is LocatedSectorRef &&
      other.id == id &&
      other.name == name &&
      other.latitude == latitude &&
      other.longitude == longitude;

  @override
  int get hashCode => Object.hash(id, name, latitude, longitude);

  @override
  String toString() =>
      'LocatedSectorRef(id: $id, name: $name, latitude: $latitude, '
      'longitude: $longitude)';
}

/// Immutable read model for a non-deleted [db.Area] that has at least one
/// located wall anywhere under its sectors — [latitude]/[longitude] are the
/// arithmetic-mean centroid over ALL of the area's located walls across ALL
/// of its sectors (NOT the mean of each sector's own centroid — see
/// [LibraryCrudRepository.watchLocatedAreas]). An area with zero located
/// walls has no [LocatedAreaRef] at all, same exclusion rule as
/// [LocatedSectorRef].
class LocatedAreaRef {
  const LocatedAreaRef({
    required this.id,
    required this.name,
    required this.latitude,
    required this.longitude,
  });

  final String id;
  final String name;

  /// Centroid latitude/longitude over every located wall under this area
  /// (through all of its sectors).
  final double latitude;
  final double longitude;

  @override
  bool operator ==(Object other) =>
      other is LocatedAreaRef &&
      other.id == id &&
      other.name == name &&
      other.latitude == latitude &&
      other.longitude == longitude;

  @override
  int get hashCode => Object.hash(id, name, latitude, longitude);

  @override
  String toString() =>
      'LocatedAreaRef(id: $id, name: $name, latitude: $latitude, '
      'longitude: $longitude)';
}
