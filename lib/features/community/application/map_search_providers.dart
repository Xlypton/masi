import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../library/application/library_providers.dart';
import '../data/map_search.dart';

/// The unified map search's data layer: given a non-empty [query], returns
/// every matching located topo/route/sector/area as a [MapSearchResult] the
/// map UI can fly to (see `mapContentSearch`'s doc for exactly how each
/// kind is matched and filtered). Deliberately excludes Places/geocoding
/// results — the map UI merges those in separately via
/// `core/location/geocoding_service.dart`'s `GeocodingService`.
///
/// Reads the four underlying `StreamProvider`s ([toposProvider],
/// [locatedRoutesProvider], [locatedSectorsProvider],
/// [locatedAreasProvider]) via `.asData?.value ?? const []` — the same
/// "loading/error reads as empty, never crashes" pattern used elsewhere in
/// this app (e.g. `topos_screen.dart`'s `ref.read(toposProvider).asData
/// ?.value ?? const []`) — so a still-loading or errored stream just yields
/// no results for that kind rather than surfacing an exception to the
/// search UI.
///
/// An `autoDispose` `Provider.family`: each distinct [query] string gets its
/// own cached entry, recomputed whenever [query] changes or any of the four
/// underlying streams re-emits, and disposed once nothing is watching it —
/// so a long session issuing many distinct search queries doesn't
/// accumulate permanently-cached entries each subscribed to the underlying
/// Drift streams forever. Tests can override
/// [toposProvider]/[locatedRoutesProvider]/[locatedSectorsProvider]/
/// [locatedAreasProvider] to seed fixed data without touching a real
/// database.
final mapContentSearchProvider =
    Provider.autoDispose.family<List<MapSearchResult>, String>(
  (ref, query) {
    final topos = ref.watch(toposProvider).asData?.value ?? const [];
    final routes = ref.watch(locatedRoutesProvider).asData?.value ?? const [];
    final sectors = ref.watch(locatedSectorsProvider).asData?.value ?? const [];
    final areas = ref.watch(locatedAreasProvider).asData?.value ?? const [];

    return mapContentSearch(
      query: query,
      topos: topos,
      routes: routes,
      sectors: sectors,
      areas: areas,
    );
  },
);
