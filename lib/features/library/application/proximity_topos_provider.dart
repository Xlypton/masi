import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/location/location_service.dart';
import '../../community/application/community_providers.dart';
import '../../community/data/community_repository.dart';
import '../data/library_crud_repository.dart';
import 'library_providers.dart';

/// Earth radius (km) used by [haversineKm] — the standard mean radius, same
/// constant every other haversine implementation uses.
const double kEarthRadiusKm = 6371.0;

/// How far (km) a [SharedTopo] may be from the device's current position and
/// still count as "nearby community" for [sortedByProximityToposProvider].
/// Community topos farther than this are omitted entirely rather than sunk
/// to the bottom of the list — the Topos-home proximity list is meant to
/// surface only topos actually near the climber, not a full community feed.
const double kNearbyRadiusKm = 100.0;

/// Great-circle distance (km) between two WGS84 points via the haversine
/// formula. Pure and top-level (no provider/ref dependency) so it is
/// directly unit-testable in isolation from the merge/sort logic that uses
/// it.
double haversineKm(double lat1, double lng1, double lat2, double lng2) {
  final dLat = _degToRad(lat2 - lat1);
  final dLng = _degToRad(lng2 - lng1);
  final a =
      math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(_degToRad(lat1)) *
          math.cos(_degToRad(lat2)) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  return kEarthRadiusKm * c;
}

double _degToRad(double deg) => deg * math.pi / 180.0;

/// Which side [ProximityTopoEntry] came from — drives how the Topos-home
/// proximity list renders/navigates a row (an owned wall vs. a
/// community-shared one) and is also how [mergeAndSortByProximity]
/// distinguishes the two before de-duplicating.
enum ProximityTopoSource { own, community }

/// A single row of the proximity-sorted Topos-home list: either one of the
/// signed-in device's own topos ([ownTopo] non-null, from [toposProvider])
/// or a nearby community-shared topo ([communityTopo] non-null, from
/// [sharedToposProvider]) that doesn't already belong to the device — see
/// [mergeAndSortByProximity]'s de-duplication rule.
///
/// Carries just enough (id, name, coordinates, source, computed distance)
/// to sort and to render a row / navigate on tap; the full underlying
/// [TopoRef]/[SharedTopo] is kept alongside for anything else the UI needs
/// (thumbnail, grade, route count, ...) rather than duplicating every field
/// here.
class ProximityTopoEntry {
  ProximityTopoEntry.own(TopoRef topo, {this.distanceKm})
    : wallId = topo.wallId,
      name = topo.name,
      latitude = topo.latitude,
      longitude = topo.longitude,
      source = ProximityTopoSource.own,
      ownTopo = topo,
      communityTopo = null;

  ProximityTopoEntry.community(SharedTopo topo, {this.distanceKm})
    : wallId = topo.wallId,
      name = topo.name,
      latitude = topo.latitude,
      longitude = topo.longitude,
      source = ProximityTopoSource.community,
      ownTopo = null,
      communityTopo = topo;

  /// The underlying wall id — [TopoRef.wallId]/[SharedTopo.wallId]. Used to
  /// de-duplicate a community entry against an own one, and as the
  /// navigation target for a row tap.
  final String wallId;

  final String name;
  final double? latitude;
  final double? longitude;

  /// Whether this row is one of the device's own topos or a nearby
  /// community one — see [ProximityTopoSource].
  final ProximityTopoSource source;

  /// Great-circle distance (km) from the device's current position via
  /// [haversineKm], or `null` when it couldn't be computed: no location fix
  /// ([DeviceLocation]), or this topo itself has no recorded coordinates.
  /// Entries with a `null` distance always sort last — see
  /// [mergeAndSortByProximity].
  final double? distanceKm;

  /// Non-null exactly when [source] is [ProximityTopoSource.own].
  final TopoRef? ownTopo;

  /// Non-null exactly when [source] is [ProximityTopoSource.community].
  final SharedTopo? communityTopo;

  bool get hasCoordinates => latitude != null && longitude != null;

  @override
  bool operator ==(Object other) =>
      other is ProximityTopoEntry &&
      other.wallId == wallId &&
      other.name == name &&
      other.latitude == latitude &&
      other.longitude == longitude &&
      other.source == source &&
      other.distanceKm == distanceKm;

  @override
  int get hashCode =>
      Object.hash(wallId, name, latitude, longitude, source, distanceKm);

  @override
  String toString() =>
      'ProximityTopoEntry(wallId: $wallId, name: $name, source: $source, '
      'distanceKm: $distanceKm)';
}

/// Pure merge/sort core of [sortedByProximityToposProvider], factored out so
/// it's unit-testable without standing up a [ProviderContainer]/database.
///
/// - Every entry in [own] is always included, regardless of distance.
/// - Entries in [community] are included only when [fix] is non-null AND
///   the community topo [SharedTopo.hasCoordinates] AND its distance from
///   [fix] is `<= radiusKm`. A community topo whose [SharedTopo.wallId]
///   matches one already in [own] is dropped (de-duplicated) — the own
///   entry wins since it's the device's own record of that same wall.
/// - The combined list sorts ascending by [ProximityTopoEntry.distanceKm];
///   entries with no distance (no [fix], or the topo itself has no
///   coordinates) sort last, in their original relative order (own topos in
///   [own]'s order, since no community entry is ever distance-less —
///   distance-less community topos are excluded above, not sunk to the
///   bottom). The sort is stable by explicit index tie-break rather than
///   relying on [List.sort]'s unspecified stability.
/// - When [fix] is `null` (no fix / still loading / denied — callers pass
///   `null` for all of those, never let an error propagate), every [own]
///   entry gets a `null` distance and no [community] entry is ever added,
///   so the result is exactly [own] in its original order — the documented
///   fallback behaviour.
List<ProximityTopoEntry> mergeAndSortByProximity({
  required List<TopoRef> own,
  required List<SharedTopo> community,
  required DeviceLocation? fix,
  double radiusKm = kNearbyRadiusKm,
}) {
  final ownWallIds = {for (final topo in own) topo.wallId};

  final entries = <ProximityTopoEntry>[
    for (final topo in own)
      ProximityTopoEntry.own(
        topo,
        distanceKm:
            (fix == null ||
                topo.latitude == null ||
                topo.longitude == null)
            ? null
            : haversineKm(
                fix.latitude,
                fix.longitude,
                topo.latitude!,
                topo.longitude!,
              ),
      ),
  ];

  if (fix != null) {
    for (final topo in community) {
      if (ownWallIds.contains(topo.wallId)) continue;
      if (!topo.hasCoordinates) continue;
      final distance = haversineKm(
        fix.latitude,
        fix.longitude,
        topo.latitude!,
        topo.longitude!,
      );
      if (distance > radiusKm) continue;
      entries.add(ProximityTopoEntry.community(topo, distanceKm: distance));
    }
  }

  final indexed = List<MapEntry<int, ProximityTopoEntry>>.generate(
    entries.length,
    (i) => MapEntry(i, entries[i]),
  );
  indexed.sort((a, b) {
    final da = a.value.distanceKm;
    final db = b.value.distanceKm;
    if (da == null && db == null) return a.key.compareTo(b.key);
    if (da == null) return 1;
    if (db == null) return -1;
    final byDistance = da.compareTo(db);
    return byDistance != 0 ? byDistance : a.key.compareTo(b.key);
  });

  return [for (final pair in indexed) pair.value];
}

/// Proximity-sorted list backing the Topos-home "nearby" tab: every one of
/// the device's own topos ([toposProvider]) plus any community-shared topo
/// ([sharedToposProvider]) within [kNearbyRadiusKm] of the device's current
/// position ([myLocationProvider]), nearest-first — see
/// [mergeAndSortByProximity] for the exact merge/sort/de-dup rules.
///
/// Reads all three source providers via `.asData?.value` (loading/error
/// reads as "no data yet" — `const []`/`null` — never a crash), the same
/// pattern `mapContentSearchProvider` uses. In particular a `null`
/// [myLocationProvider] result (no fix, still resolving, or a denied
/// permission — [LocationService.currentLocation] never throws) falls back
/// to the plain [toposProvider] order with every [ProximityTopoEntry.
/// distanceKm] `null`, per [mergeAndSortByProximity]'s doc.
final sortedByProximityToposProvider = Provider<List<ProximityTopoEntry>>((
  ref,
) {
  final own = ref.watch(toposProvider).asData?.value ?? const [];
  final community = ref.watch(sharedToposProvider).asData?.value ?? const [];
  final fix = ref.watch(myLocationProvider).asData?.value;
  return mergeAndSortByProximity(own: own, community: community, fix: fix);
});
