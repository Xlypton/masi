import 'package:latlong2/latlong.dart';

import '../../library/data/library_crud_repository.dart'
    show LocatedAreaRef, LocatedRouteRef, LocatedSectorRef, TopoRef;

/// The kind of located library entity a [MapSearchResult] represents —
/// drives which icon/label the map search UI shows for a hit, and (for
/// [topo]/[route]) which real wall a tap can drill into via
/// [MapSearchResult.wallId].
enum MapSearchKind { topo, route, sector, area }

/// A single unified-map-search hit: some local, GPS-located library entity
/// (a topo/wall, a route, a sector, or an area — see [MapSearchKind]) whose
/// name matched the query, paired with the coordinates the map should fly
/// to when the user picks it.
///
/// Deliberately does NOT cover Places/geocoding hits ([PlaceResult] in
/// `core/location/geocoding_service.dart`) — those come from a remote
/// lookup via `GeocodingService` and are merged in by the map UI
/// separately; see [mapContentSearch]'s doc for what this type covers
/// instead.
class MapSearchResult {
  const MapSearchResult({
    required this.kind,
    required this.title,
    required this.location,
    this.subtitle,
    this.wallId,
  });

  final MapSearchKind kind;

  /// The primary label shown for this hit: a topo/wall's name, a route's
  /// display title (its name, or `'Route &lt;number&gt;'` — see
  /// [LocatedRouteRef.title]), or a sector's/area's name.
  final String title;

  /// A secondary label for context, or `null` when there is none. A
  /// route's subtitle is its wall's (topo's) name; a topo's subtitle is its
  /// ancestor area's name (`null` when unfiled). Sectors and areas have no
  /// natural subtitle — [MapSearchKind] already says what they are.
  final String? subtitle;

  /// Where the map should fly to for this hit: a wall's own recorded GPS
  /// coordinates for [MapSearchKind.topo]/[MapSearchKind.route], or a
  /// derived centroid over located descendant walls for
  /// [MapSearchKind.sector]/[MapSearchKind.area] — see
  /// `LibraryCrudRepository.watchLocatedSectors`/`watchLocatedAreas`.
  final LatLng location;

  /// The id of the underlying wall this hit is (for [MapSearchKind.topo])
  /// or belongs to (for [MapSearchKind.route]), or `null` for
  /// [MapSearchKind.sector]/[MapSearchKind.area] hits, which don't
  /// correspond to a single wall.
  final String? wallId;

  @override
  bool operator ==(Object other) =>
      other is MapSearchResult &&
      other.kind == kind &&
      other.title == title &&
      other.subtitle == subtitle &&
      other.location == location &&
      other.wallId == wallId;

  @override
  int get hashCode => Object.hash(kind, title, subtitle, location, wallId);

  @override
  String toString() =>
      'MapSearchResult(kind: $kind, title: $title, subtitle: $subtitle, '
      'location: $location, wallId: $wallId)';
}

/// Case-insensitive substring match used by [mapContentSearch] for every
/// kind: `true` iff [haystack] contains [needleLower] once both are
/// lowercased. [needleLower] is expected to already be lowercased by the
/// caller (avoids re-lowercasing it once per candidate).
bool _matches(String haystack, String needleLower) =>
    haystack.toLowerCase().contains(needleLower);

/// Searches this device's located library content — topos (walls), routes,
/// sectors, and areas — for [query], returning every match as a
/// [MapSearchResult] the map UI can fly to. Un-locatable entities (no GPS
/// coordinates of their own, and — for a sector/area — no located
/// descendant wall either) are never returned; there is no `(0, 0)`
/// fallback anywhere in this function or its inputs.
///
/// Matching is a case-insensitive substring test against each entity's
/// display title:
/// - a topo/wall: [TopoRef.name], only when it has coordinates
///   ([TopoRef.latitude]/[TopoRef.longitude] both non-null) — [topos] is
///   expected to be the raw, unfiltered `toposProvider` data (which
///   includes walls with no coordinates yet), so that filter is applied
///   here rather than upstream.
/// - a route: [LocatedRouteRef.title] (its name, or `'Route &lt;number&gt;'`) —
///   [routes] is expected to already be pre-filtered to located routes only
///   (see `LibraryCrudRepository.watchLocatedRoutes`), so every entry here
///   always has a wall location to use.
/// - a sector: [LocatedSectorRef.name] — [sectors] is expected to already
///   be pre-filtered to sectors with at least one located wall (see
///   `LibraryCrudRepository.watchLocatedSectors`).
/// - an area: [LocatedAreaRef.name] — same pre-filtering expectation, via
///   `LibraryCrudRepository.watchLocatedAreas`.
///
/// [query] is trimmed before matching; an empty or all-whitespace [query]
/// short-circuits to an empty list without inspecting any input list.
/// Results are returned topos-then-routes-then-sectors-then-areas, each
/// group in its input list's order — this function never re-sorts within a
/// group.
List<MapSearchResult> mapContentSearch({
  required String query,
  required List<TopoRef> topos,
  required List<LocatedRouteRef> routes,
  required List<LocatedSectorRef> sectors,
  required List<LocatedAreaRef> areas,
}) {
  final trimmed = query.trim();
  if (trimmed.isEmpty) return const [];
  final needle = trimmed.toLowerCase();

  final results = <MapSearchResult>[];

  for (final topo in topos) {
    if (topo.latitude == null || topo.longitude == null) continue;
    if (!_matches(topo.name, needle)) continue;
    results.add(
      MapSearchResult(
        kind: MapSearchKind.topo,
        title: topo.name,
        subtitle: topo.areaName,
        location: LatLng(topo.latitude!, topo.longitude!),
        wallId: topo.wallId,
      ),
    );
  }

  for (final route in routes) {
    if (!_matches(route.title, needle)) continue;
    results.add(
      MapSearchResult(
        kind: MapSearchKind.route,
        title: route.title,
        subtitle: route.wallName,
        location: LatLng(route.latitude, route.longitude),
        wallId: route.wallId,
      ),
    );
  }

  for (final sector in sectors) {
    if (!_matches(sector.name, needle)) continue;
    results.add(
      MapSearchResult(
        kind: MapSearchKind.sector,
        title: sector.name,
        location: LatLng(sector.latitude, sector.longitude),
      ),
    );
  }

  for (final area in areas) {
    if (!_matches(area.name, needle)) continue;
    results.add(
      MapSearchResult(
        kind: MapSearchKind.area,
        title: area.name,
        location: LatLng(area.latitude, area.longitude),
      ),
    );
  }

  return results;
}
