import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../../app/theme.dart';
import '../../../core/db/database_provider.dart';
import '../../../core/map/basemap.dart';
import '../../../core/map/basemap_layer.dart';
import '../../../shared/presentation/masi_async_view.dart';
import '../../../shared/presentation/masi_dialogs.dart';
import '../../../shared/presentation/masi_icon.dart';
import '../../../shared/presentation/masi_toast.dart';
import '../../../shared/presentation/masi_loading_indicator.dart';
import '../../../shared/presentation/masi_pending_icon_button.dart';
import '../../../core/location/geocoding_service.dart';
import '../../../core/location/location_service.dart';
import '../../account/application/auth_providers.dart';
import '../../backup/application/reachability_providers.dart';
import '../../backup/application/sync_orchestrator.dart';
import '../../library/application/library_providers.dart';
import '../application/community_providers.dart';
import '../application/map_search_providers.dart';
import '../data/community_repository.dart';
import '../data/map_search.dart';
import '../domain/topo_group.dart';

/// The Community Map tab (bottom-nav branch `/map`): an OpenStreetMap
/// [FlutterMap] with one marker per shared topo that has coordinates
/// (inherited from its ancestor Area), plus the signed-in user's own located
/// topos — see [_MapView]'s doc for the own-vs-community marker split. This
/// screen used to be one half of a combined `CommunityScreen`'s segmented
/// Feed/Map toggle; that toggle is gone (removed along with `CommunityTab`/
/// `CommunityScreen` entirely) now that the app's persistent bottom
/// navigation bar (`nav_shell.dart`) gives Map its own permanent branch,
/// independent of Feed ([CommunityFeedScreen]).
///
/// [focusWallId], when given, centers/zooms the map on that wall's
/// coordinates instead of the combined marker-set center — see [_MapView]'s
/// `focusWallId` doc. `router.dart`'s `/map` route builder passes this
/// straight from the `?focus=` query param, which is how the legacy
/// `/community?tab=map&focus=<id>` deep link (`topos_screen.dart`'s "Show on
/// map" action) still reaches a specific wall after being redirected here.
class CommunityMapScreen extends ConsumerStatefulWidget {
  const CommunityMapScreen({
    super.key,
    this.focusWallId,
    this.mapController,
  });

  final String? focusWallId;

  /// Test-injectable [MapController] seam, threaded through to [_MapView] —
  /// see that class's `controller` doc. Production code (the app's real
  /// `/map` route) leaves this null.
  @visibleForTesting
  final MapController? mapController;

  @override
  ConsumerState<CommunityMapScreen> createState() => _CommunityMapScreenState();
}

class _CommunityMapScreenState extends ConsumerState<CommunityMapScreen> {
  /// `MasiAsyncView`'s retry, carrying over exactly what the deleted
  /// `CommunityErrorState` did (#57): the REAL remote pull first, then a local
  /// re-query — a local-only invalidate can never recover data that was never
  /// pulled. `pullNow()` never throws, so no try/catch is needed.
  Future<void> _retry() async {
    await ref.read(syncOrchestratorProvider.notifier).pullNow();
    if (!mounted) return;
    ref.invalidate(sharedToposProvider);
  }

  @override
  Widget build(BuildContext context) {
    final asyncSharedTopos = ref.watch(sharedToposProvider);

    return Scaffold(
      key: const Key('community-map-screen'),
      // NO AppBar and NO SafeArea, deliberately (user request, 2026-08-06):
      // the map is the content, so it draws edge-to-edge on ALL four sides —
      // behind the status bar/notch at the top exactly as it already drew
      // behind `NavShell`'s translucent bar at the bottom. A "Map" title bar
      // over a map labels something the user is already looking at while
      // costing a fifth of a phone screen; the floating search pill below is
      // the only top chrome, and it insets ITSELF (see `_MapView`'s
      // `topChromeInset`).
      //
      // Consuming neither inset here is what keeps both of `_MapView`'s
      // reads live: `MediaQuery.padding.top` for the search pill, and
      // `padding.bottom` (#48/#51 — the REAL measured bottom-bar height
      // under `Scaffold.extendBody`, see `NavShell`'s doc) for the
      // find-me/refresh column and the legend/attribution pills.
      body: MasiAsyncView<List<SharedTopo>>(
        value: asyncSharedTopos,
        errorMessage: "Couldn't load the community map",
        // See `community_feed_screen.dart`'s identical decision: the raw
        // Drift error object is not a sentence for a climber, and the
        // actionable pull failure has its own surface.
        showErrorDetail: false,
        onRetry: () => _retry(),
        // A SPINNER, not a skeleton — the one place in this feature where
        // that is the honest answer. A skeleton works by matching the shape
        // of what is coming; what is coming here is a photographic tile
        // canvas with pins scattered over it, and the only placeholder that
        // "matches" it is a full-screen shimmering rectangle, which reads as
        // a broken image rather than as a map on its way. So: say what is
        // being waited on and nothing more. The gate still means a fast local
        // read paints no spinner at all.
        skeleton: (context) =>
            const MasiLoadingIndicator.standalone(label: 'Loading topos'),
        data: (context, topos) => _MapView(
          topos: topos,
          focusWallId: widget.focusWallId,
          controller: widget.mapController,
        ),
      ),
    );
  }
}

/// The Map tab: an OpenStreetMap [FlutterMap] with one [Marker] per shared
/// topo that [SharedTopo.hasCoordinates] AND matches the current
/// [communityFilterProvider] — topos without coordinates, and topos
/// excluded by the filter, are simply omitted from the marker list, never
/// crash the map — PLUS a second, visually distinct ("Yours") marker set for
/// the signed-in user's own located topos (from [toposProvider], which is
/// EVERY non-deleted local wall regardless of [TopoRef.visibility] — a
/// freshly-picked photo's GPS location must show up immediately even while
/// the topo is still private, before it's ever published). See this class's
/// `build` method for how "own" is determined and deduped against the
/// shared set.
///
/// A [ConsumerStatefulWidget] (rather than [ConsumerWidget]) so it can own a
/// [MapController] for the find-me control added over the map — see
/// [_MapViewState].
class _MapView extends ConsumerStatefulWidget {
  const _MapView({
    required this.topos,
    this.focusWallId,
    this.controller,
  });

  final List<SharedTopo> topos;

  /// When non-null AND found among this build's own/community located
  /// topos, overrides the map's initial center to that wall's coordinates
  /// at an elevated zoom (see [_MapViewState.build]'s `hasFocus` branch) so
  /// a single "Show on map" deep link (`topos_screen.dart`'s `_TopoRow`, via
  /// `/community?tab=map&focus=<wallId>`) frames that one boulder instead of
  /// the whole combined marker set. A `focusWallId` that doesn't match any
  /// rendered topo (not found, filtered out, or simply lacking coordinates)
  /// silently falls back to the existing combined-set center/zoom — it must
  /// never crash or blank the map.
  final String? focusWallId;

  /// Test-injectable [MapController] seam (see `community_screen_test.dart`'s
  /// MC3: a test supplies its own controller and reads `controller.camera`
  /// after driving a tap on `community-map-find-me`; FX2a/FX3 similarly
  /// inject a controller to call `.rotate(...)` directly — no on-screen
  /// control can trigger rotation anymore — see this class's `build`).
  /// Production code (`CommunityScreen`) leaves this null, and
  /// [_MapViewState] creates, owns, and disposes its own instead.
  @visibleForTesting
  final MapController? controller;

  @override
  ConsumerState<_MapView> createState() => _MapViewState();
}

class _MapViewState extends ConsumerState<_MapView> {
  late final MapController _mapController;
  late final bool _ownsController;

  /// One-shot guard for the imperative device-location auto-center in
  /// [build]'s `ref.listen(myLocationProvider, ...)` — see MAJOR 1 in this
  /// class's fix history. Sticks at `true` for the rest of this
  /// [_MapViewState]'s lifetime once the camera has been auto-centered once,
  /// so a later, unrelated rebuild can never re-fight the user by moving the
  /// camera back.
  bool _didAutoCenter = false;

  /// Backing state for the unified map-search overlay (`community-map-
  /// search-field`) — mirrors `set_location_picker.dart`'s
  /// `_SetLocationPickerState` search fields exactly (same debounce/seq-
  /// guard/programmatic-suppression skeleton), extended to merge in local
  /// library content alongside places.
  ///
  /// [_searchController] holds the typed/picked text, [_searchFocusNode]
  /// lets a selection unfocus the field afterward, [_debounce] is the
  /// in-flight "wait for the user to stop typing" timer (see
  /// [_onSearchChanged]).
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  Timer? _debounce;

  /// The last query the debounce timer actually SETTLED on (as opposed to
  /// every keystroke) — used to `ref.watch(mapContentSearchProvider(...))`
  /// reactively in [build] rather than one-shot `ref.read`ing it at debounce
  /// time, so local results stay live (and correctly empty rather than
  /// falsely-empty) even if the underlying located-topo/route/sector/area
  /// streams hadn't emitted their first snapshot yet the instant the
  /// debounce fired. Empty string means "no committed query" — [build]
  /// treats that as zero local results without even touching the provider.
  String _committedQuery = '';

  /// True from the moment a settled query's places lookup starts until it
  /// resolves (or is superseded) — drives the inline cue in the search field's
  /// `suffixIcon`, see [build].
  ///
  /// Without it the field was silent for the whole 350 ms debounce PLUS a real
  /// geocoding round trip, so a user who typed a place name and saw no
  /// dropdown could not tell "still looking" from "nothing found" — and the
  /// two have opposite responses (wait vs. retype). The local half needs no
  /// such cue: it is a synchronous-ish Drift read whose results appear with the
  /// keystroke.
  bool _placeSearchInFlight = false;

  /// The current async place (geocoding) results for [_committedQuery] —
  /// unlike local results, these can't be a reactive `ref.watch` (a
  /// [GeocodingService] call is a one-shot Future, not a stream), so they're
  /// held as plain state and applied by [_runPlaceSearch] once resolved.
  List<PlaceResult> _placeResults = const [];

  /// True when the MOST RECENT settled query's places lookup ([_runPlaceSearch])
  /// resolved with zero results AND a reachability probe taken at that same
  /// moment confirmed the device is offline — i.e. "the places half of this
  /// search can't work right now", never "it worked and genuinely found no
  /// matching place" (see [_runPlaceSearch]'s doc). Local content search
  /// (Drift/SQLite) is unaffected either way — it works fully offline, so
  /// this never gates it. Drives the `community-map-search-offline` hint in
  /// [build], shown only when BOTH halves of the combined dropdown are
  /// empty; local results alone are left to speak for themselves. Reset to
  /// `false` whenever the query is cleared or a selection is made (see
  /// [_onSearchChanged], [_selectLocalResult], [_selectPlaceResult]), so the
  /// hint never outlives the exact empty-and-offline moment that produced
  /// it.
  bool _placesOffline = false;

  /// Monotonically increasing "which search is current" generation counter —
  /// see `set_location_picker.dart`'s identically-named field for the full
  /// rationale (a slow lookup for an earlier query must never clobber a
  /// faster, more recent one's results). Bumped by every [_onSearchChanged]
  /// call and by every selection, and checked after every `await` before
  /// applying a result.
  int _searchSeq = 0;

  /// The exact (trimmed) query a selection last wrote into
  /// [_searchController] programmatically, or `null` when the field's
  /// current text was typed by the user — see `set_location_picker.dart`'s
  /// identically-named field. [_onSearchChanged] compares against this to
  /// no-op the synthetic "change" a selection's own `_searchController.text
  /// =` write fires, rather than kicking off a fresh search for the
  /// place/entity just picked.
  String? _lastProgrammaticQuery;

  /// The map location of the most recently selected search result (local or
  /// place), or `null` when there is none — drives the transient
  /// `community-map-search-marker` [MarkerLayer] in [build]. Cleared
  /// whenever the search field is cleared (see [_onSearchChanged]'s
  /// empty-query branch) or replaced by a fresh selection.
  LatLng? _selectedSearchResult;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _mapController = widget.controller ?? MapController();
    // Seeds a fresh reachability verdict at mount, fire-and-forget, so
    // [_runPlaceSearch]'s own `refresh()` call (below) can usually resolve
    // against an already-in-flight or already-known probe rather than
    // starting cold the first time a places lookup comes back empty.
    // Mirrors `set_location_picker.dart`'s identical seed exactly (see that
    // file's doc) — never awaited here, this map must never block on it.
    Future.microtask(() => ref.read(reachabilityProvider.notifier).refresh());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
    if (_ownsController) {
      _mapController.dispose();
    }
    super.dispose();
  }

  /// `community-map-search-field`'s `onChanged` handler — see
  /// `set_location_picker.dart`'s identically-shaped [_onSearchChanged] for
  /// the full debounce/seq-guard/programmatic-suppression rationale, which
  /// this mirrors exactly. The only difference: settling on a non-empty
  /// query here commits [_committedQuery] (driving the reactive local
  /// results in [build]) AND kicks off [_runPlaceSearch] (the async places
  /// half), rather than a single async lookup.
  void _onSearchChanged(String value) {
    if (value == _lastProgrammaticQuery) {
      _lastProgrammaticQuery = null;
      return;
    }
    _lastProgrammaticQuery = null;
    _debounce?.cancel();
    final query = value.trim();
    _searchSeq++;
    final seq = _searchSeq;
    if (query.isEmpty) {
      setState(() {
        _committedQuery = '';
        _placeResults = const [];
        _placesOffline = false;
        _placeSearchInFlight = false;
        _selectedSearchResult = null;
      });
      return;
    }
    _debounce = Timer(
      const Duration(milliseconds: 350),
      () => _settleSearch(query, seq),
    );
  }

  /// Runs once [_onSearchChanged]'s debounce timer fires for a non-empty,
  /// still-current ([seq] still matches [_searchSeq]) query: commits
  /// [_committedQuery] (so [build]'s `ref.watch(mapContentSearchProvider(...))`
  /// picks up local results reactively) and fires the async places lookup.
  void _settleSearch(String query, int seq) {
    if (!mounted || seq != _searchSeq) return;
    setState(() => _committedQuery = query);
    unawaited(_runPlaceSearch(query, seq));
  }

  /// The places half of a settled search: [GeocodingService.search] never
  /// throws (see its doc), so no try/catch is needed here. Discards the
  /// result when [seq] no longer matches [_searchSeq] by the time an
  /// `await` returns — i.e. a newer query (or a clear, or a selection) has
  /// superseded this one — so a slow lookup for an old query can never
  /// clobber a faster, more recent query's results.
  ///
  /// A ZERO-result response is genuinely ambiguous on its own: offline,
  /// [GeocodingService.search] resolves to an empty list exactly the same
  /// way a real "no such place" does (see its doc), so nothing about the
  /// result itself tells them apart. Only on that empty branch, this asks
  /// [reachabilityProvider] for a fresh verdict (`refresh()`, not the
  /// possibly-stale cached `state`, since this IS the moment the answer
  /// matters) and sets [_placesOffline] from
  /// [ReachabilityVerdict.isKnownOffline] — true only for a PROVEN offline
  /// probe, never for [Reachability.unknown], so a probe that hasn't
  /// resolved yet never flashes the hint prematurely. The [seq] guard is
  /// re-checked after this second `await` too, since a newer query (or a
  /// clear, or a selection) can supersede this one while the probe is still
  /// in flight.
  /// [_placeSearchInFlight] is set for exactly this lookup's lifetime, and only
  /// cleared on a branch that is still current ([seq] check) — a superseded
  /// lookup must not switch the cue off while the query that replaced it is
  /// still running.
  Future<void> _runPlaceSearch(String query, int seq) async {
    setState(() => _placeSearchInFlight = true);
    final service = ref.read(geocodingServiceProvider);
    final results = await service.search(query);
    if (!mounted || seq != _searchSeq) return;
    if (results.isEmpty) {
      final verdict = await ref.read(reachabilityProvider.notifier).refresh();
      if (!mounted || seq != _searchSeq) return;
      setState(() {
        _placeResults = const [];
        _placesOffline = verdict.isKnownOffline;
        _placeSearchInFlight = false;
      });
      return;
    }
    setState(() {
      _placeResults = results;
      _placesOffline = false;
      _placeSearchInFlight = false;
    });
  }

  /// A local-content search result row's `onTap`: flies the map to it and
  /// drops the transient `community-map-search-marker`. Mirrors
  /// [_selectPlaceResult] exactly except for the source of the flown-to
  /// point; see that method's doc for the programmatic-suppression/seq-bump
  /// rationale shared by both.
  void _selectLocalResult(MapSearchResult result) {
    _debounce?.cancel();
    _searchSeq++;
    _mapController.move(result.location, 15);
    _lastProgrammaticQuery = result.title;
    _searchController.text = result.title;
    setState(() {
      _selectedSearchResult = result.location;
      _committedQuery = '';
      _placeResults = const [];
      _placesOffline = false;
      _placeSearchInFlight = false;
    });
    _searchFocusNode.unfocus();
  }

  /// A place (geocoding) search result row's `onTap` — mirrors
  /// `set_location_picker.dart`'s `_selectSearchResult`: moves the map to
  /// the chosen place, then collapses the dropdown and unfocuses the field.
  ///
  /// Writes [result.displayName] into [_searchController] so the field
  /// visibly reflects what was picked. That write fires
  /// [TextEditingController]'s change notification straight into
  /// [_onSearchChanged] (the same listener `TextField.onChanged` uses),
  /// which would otherwise kick off a brand-new debounced search for the
  /// place's own name — so [_lastProgrammaticQuery] is set to the exact
  /// string being written FIRST, letting [_onSearchChanged] recognize and
  /// no-op that one synthetic change. [_searchSeq] is bumped independently
  /// too, invalidating any search still in flight for whatever the user had
  /// typed, so a stale in-flight lookup can never resurrect the dropdown
  /// after this selection.
  void _selectPlaceResult(PlaceResult result) {
    final location = LatLng(result.latitude, result.longitude);
    _debounce?.cancel();
    _searchSeq++;
    _mapController.move(location, 15);
    _lastProgrammaticQuery = result.displayName;
    _searchController.text = result.displayName;
    setState(() {
      _selectedSearchResult = location;
      _committedQuery = '';
      _placeResults = const [];
      _placesOffline = false;
      _placeSearchInFlight = false;
    });
    _searchFocusNode.unfocus();
  }

  /// `community-map-find-me`'s handler: fetches ONE fresh fix (never the
  /// possibly-stale [myLocationProvider] value already driving the "you are
  /// here" marker) and recenters the map on it at a walking-around zoom.
  /// [LocationService.currentLocation] never throws (see its doc) — a
  /// `null` result (denied/disabled/unavailable) surfaces as a SnackBar
  /// instead of moving the map.
  Future<void> _onFindMePressed() async {
    final location = await ref.read(locationServiceProvider).currentLocation();
    if (!mounted) return;
    if (location == null) {
      ScaffoldMessenger.of(
        context,
      ).showMasiToast('Location unavailable', kind: MasiToastKind.warning);
      return;
    }
    _mapController.move(LatLng(location.latitude, location.longitude), 14);
  }

  // `_onRefreshPressed` lived here — `community-map-refresh`'s handler (#57).
  // It went with the button (see the map-controls column in `build`).
  // `sharedToposProvider` is a `StreamProvider` watching Drift, so the markers
  // still update on their own the moment any OTHER trigger's pull writes fresh
  // rows locally; this screen never needed to run the pull itself, only to
  // offer a way to ask for one.

  @override
  Widget build(BuildContext context) {
    final filter = ref.watch(communityFilterProvider);
    final filteredTopos = widget.topos.where(filter.matches).toList();
    final colors = MasiColors.of(context);
    final withCoords = filteredTopos.where((t) => t.hasCoordinates).toList();

    // The Map branch draws full-bleed behind the floating glass bottom-nav
    // bar (#48, generalized to every branch by #51 — see `nav_shell.dart`'s
    // `NavShell` doc: `Scaffold.extendBody: true` unconditionally), so this
    // view's OWN bottom-anchored overlay chrome -- the find-me control below,
    // plus the attribution/
    // legend pills baked into `flutterMap`'s children -- must add clearance
    // itself or it renders obscured behind the bar. Under `extendBody`,
    // Flutter's `Scaffold` already computes exactly that clearance for us:
    // `MediaQuery.of(context).padding.bottom` here is the REAL measured
    // `bottomNavigationBar` height (maxed with the device safe-area inset —
    // see `_BodyBuilder`/`bottomWidgetsHeight` in Flutter's `scaffold.dart`),
    // reaching this widget unconsumed because `CommunityMapScreen`'s own
    // `SafeArea` above uses `bottom: false`. No hand-maintained height
    // constant needed, and it stays correct across text-scale/device
    // changes.
    final bottomChromeInset = MediaQuery.of(context).padding.bottom;

    // The mirror image of `bottomChromeInset`, now that `CommunityMapScreen`
    // has no AppBar and no `SafeArea` (see its `build`): the map itself runs
    // under the status bar/notch, so the ONLY top chrome — the search pill —
    // has to clear it on its own or it renders under the clock.
    final topChromeInset = MediaQuery.of(context).padding.top;

    // The unified map search's local-content half (B2): reactively watched
    // (rather than one-shot `ref.read`) so results stay correct even if the
    // underlying located-topo/route/sector/area streams hadn't emitted their
    // first snapshot yet the instant `_settleSearch` committed the query —
    // see `_committedQuery`'s doc. An empty committed query (nothing typed
    // yet, or the field was just cleared/a result just selected) skips the
    // provider entirely rather than watching `mapContentSearchProvider('')`
    // (which would return `[]` anyway, per that provider's doc, but every
    // OTHER query string still gets its own cached entry there).
    final localSearchResults = _committedQuery.isEmpty
        ? const <MapSearchResult>[]
        : ref.watch(mapContentSearchProvider(_committedQuery));
    // The offline hint is folded into this same gate (rather than a
    // separate `Positioned` of its own) so it occupies the exact slot the
    // results dropdown would have — only when BOTH halves are empty is it
    // even a candidate for rendering; local results alone are left to speak
    // for themselves (see `_placesOffline`'s doc).
    final showSearchDropdown =
        localSearchResults.isNotEmpty ||
        _placeResults.isNotEmpty ||
        _placesOffline;

    // "Own" located topos: every local wall (regardless of visibility) that
    // has coordinates AND isn't actually someone else's shared topo pulled
    // down onto this device by sync (see `SyncService.pullOwnAndShared` --
    // sync only ever pulls ANOTHER user's wall when it's already
    // `visibility == 'shared'`, so a wall this device has never seen in the
    // shared feed at all is guaranteed local-only, i.e. always "mine").
    // Cross-referencing the ALREADY-FETCHED, unfiltered `topos` (rather than
    // adding an `ownerId` column to `TopoRef`) keeps this a pure read of
    // data this widget already has.
    // §1c: the single local-data uid door — never `authStateProvider.asData`,
    // which reads null on AsyncError too.
    final myUid = ref.watch(effectiveUidProvider);
    final ownerByWallId = <String, String?>{
      for (final t in widget.topos) t.wallId: t.ownerId,
    };
    bool isMine(String wallId) {
      if (!ownerByWallId.containsKey(wallId)) {
        return true; // never surfaced in the shared feed -> local-only.
      }
      // A `null` owner on a wall that IS in the shared feed (a legacy/
      // pre-ownership row, or a transiently-null `myUid` while auth is
      // still resolving) can never be safely proven to be this device's
      // own -- `null == null` must NOT count as a match, or a foreign
      // shared topo with no owner stamp would be misclassified as "Yours"
      // and route into the EDITOR for a wall that isn't actually ours.
      // Degrade to the safe side (community / read-only detail) instead;
      // the `containsKey == false` branch above still correctly claims a
      // genuinely-local null-owner wall, since that one was never in the
      // shared feed at all.
      final owner = ownerByWallId[wallId];
      return owner != null && owner == myUid;
    }

    // Own markers are intentionally NEVER filtered by
    // `communityFilterProvider` (the grade/style filter above only applies
    // to `filteredTopos`/`withCoords`) -- they're the user's own reference
    // points and must always show regardless of the community filter.
    final ownTopos = ref.watch(toposProvider).asData?.value ?? [];
    final ownWithCoords = ownTopos
        .where((t) => t.latitude != null && t.longitude != null)
        .where((t) => isMine(t.wallId))
        .toList();

    // DEDUPE: a topo that is both own AND shared (a published own topo)
    // renders exactly once -- as the "Yours" marker below, never also as a
    // neutral community pin for the same wallId.
    final ownWallIds = ownWithCoords.map((t) => t.wallId).toSet();
    final communityWithCoords = withCoords
        .where((t) => !ownWallIds.contains(t.wallId))
        .toList();

    // Duplicates of one place collapse to ONE pin (phase 8b / C-6.2), the same
    // grouping the feed applies. It matters more here than in the feed: four
    // topos of one boulder are four pins metres apart, which at any real zoom
    // is a single unclickable smudge — the reader cannot even tell there is
    // more than one, let alone pick between them.
    //
    // Grouping runs AFTER the own-topo dedupe above, so a place where one of
    // the alternates is the user's own still renders their "Yours" pin
    // separately and unchanged. That is deliberate: the own marker is a
    // personal reference point, not a community listing, and folding it into a
    // group would make the user's own crag disappear behind somebody else's
    // photo of it.
    //
    // Best-effort, exactly as in the feed: no links (offline, or not yet
    // fetched) means one pin per topo, which is what the map did before.
    final links =
        ref.watch(alternateGroupsProvider).asData?.value ??
        const AlternateGroups.empty();
    final communityGroups = groupTopos(
      communityWithCoords,
      links,
      nowMs: ref.watch(nowMsProvider)(),
    );

    // Best-effort device position (see myLocationProvider's doc): loading,
    // error, and denied/unavailable (a `null` AsyncData) all collapse to
    // "no marker" here — the map and every topo marker render exactly the
    // same either way.
    final myLocation = ref.watch(myLocationProvider).asData?.value;

    // Centered/zoomed over the COMBINED (own + community, deduped)
    // coordinate set, so a user with only private, unpublished topos still
    // sees the map frame them, rather than the empty (0,0)/1.5 fallback.
    final combinedCoords = [
      for (final t in ownWithCoords) LatLng(t.latitude!, t.longitude!),
      for (final t in communityWithCoords) LatLng(t.latitude!, t.longitude!),
    ];

    // Imperative one-shot auto-center on the device's location — see MAJOR 1
    // / user request #39 in this class's fix history. `myLocation` above
    // comes from `myLocationProvider`, an autoDispose FutureProvider that's
    // still `AsyncLoading` (null) on this widget's FIRST build — applying it
    // only via `MapOptions.initialCenter` (honored by flutter_map exactly
    // ONCE, at first mount) would leave the map stuck at the (0,0)/1.5 world
    // view (or the topo-centroid frame) forever once the fix resolves a
    // moment later, since a later rebuild's freshly-computed `center` below
    // is never re-applied to an already-mounted map. `ref.listen` instead
    // fires the instant `myLocationProvider` actually transitions to a
    // resolved value, moving the (by-then-mounted) map's camera directly.
    //
    // Guarded to fire at most once per `_MapViewState` (`_didAutoCenter`),
    // and only when no `focusWallId` deep link is in play — deep links DO
    // work correctly via `initialCenter`/`initialZoom` below, since
    // `focusPoint` is already resolvable on this widget's first build — so
    // this never fights an explicit deep link. Deliberately fires REGARDLESS
    // of `combinedCoords` (user request #39: the map centers on the user's
    // OWN position even when located topos exist, overturning the previous
    // "frame the topos instead" rule) — and never fights the user
    // afterward (e.g. after they've since panned/zoomed/rotated away).
    ref.listen<AsyncValue<DeviceLocation?>>(myLocationProvider, (
      previous,
      next,
    ) {
      if (_didAutoCenter) return;
      if (widget.focusWallId != null) return;
      final loc = next.asData?.value;
      if (loc == null) return;
      _didAutoCenter = true;
      if (!mounted) return;
      try {
        _mapController.move(LatLng(loc.latitude, loc.longitude), 14);
      } catch (_) {
        // Defensive: a controller detached from its map (e.g. this widget
        // torn down in the same microtask the fix resolved) must never
        // crash — a missed one-shot auto-center is harmless; the user can
        // still center manually via `community-map-find-me`.
      }
    });

    // `focusWallId`, if given, overrides the combined center/zoom above --
    // checked against BOTH already-computed located sets (own first, since
    // an own+shared topo is deduped to render only as "own"; see this
    // class's doc), so a deep link works regardless of which marker family
    // the wall actually renders as. A focus id that matches neither (not
    // found / filtered out / no coordinates) leaves `focusPoint` null and
    // the combined-set behavior below is unaffected.
    LatLng? focusPoint;
    final focusId = widget.focusWallId;
    if (focusId != null) {
      for (final t in ownWithCoords) {
        if (t.wallId == focusId) {
          focusPoint = LatLng(t.latitude!, t.longitude!);
          break;
        }
      }
      if (focusPoint == null) {
        for (final t in communityWithCoords) {
          if (t.wallId == focusId) {
            focusPoint = LatLng(t.latitude!, t.longitude!);
            break;
          }
        }
      }
    }

    // User request #39: the map opens centered on the device's current
    // position, EVEN when located topos exist to frame instead — the
    // user's own position now wins over the topo-centroid frame. Priority:
    // `focusPoint` (an explicit deep link) > the device's location (whenever
    // no deep link is in play and a fix is available) > the topo centroid
    // (when located topos exist but no fix is available yet/ever) > the
    // maximally-unhelpful (0,0)/1.5 whole-world view. A `focusWallId` that
    // failed to resolve to a point (not found / filtered out / no
    // coordinates) deliberately still falls through to the location/centroid/
    // (0,0) chain below rather than silently substituting a DIFFERENT place
    // for a link that named a specific one.
    final useMyLocation = widget.focusWallId == null && myLocation != null;

    final center =
        focusPoint ??
        (useMyLocation
            ? LatLng(myLocation.latitude, myLocation.longitude)
            : (combinedCoords.isEmpty
                  ? const LatLng(0, 0)
                  : LatLng(
                      combinedCoords
                              .map((p) => p.latitude)
                              .reduce((a, b) => a + b) /
                          combinedCoords.length,
                      combinedCoords
                              .map((p) => p.longitude)
                              .reduce((a, b) => a + b) /
                          combinedCoords.length,
                    )));
    final zoom = focusPoint != null
        ? 15.0
        : (useMyLocation ? 14.0 : (combinedCoords.isEmpty ? 1.5 : 11.0));

    final flutterMap = FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: center,
        initialZoom: zoom,
        // Rotation is disabled outright — an accidental two-finger twist
        // must never spin the map. Every other usual pan/zoom gesture stays
        // enabled; only `InteractiveFlag.rotate` is omitted from the flags
        // that would otherwise default to `InteractiveFlag.all`.
        interactionOptions: const InteractionOptions(
          flags:
              InteractiveFlag.drag |
              InteractiveFlag.flingAnimation |
              InteractiveFlag.pinchMove |
              InteractiveFlag.pinchZoom |
              InteractiveFlag.doubleTapZoom |
              InteractiveFlag.doubleTapDragZoom |
              InteractiveFlag.scrollWheelZoom,
        ),
      ),
      children: [
        const BasemapLayer(),
        MarkerLayer(
          markers: [
            // `if (… case final topo)` purely to bind `group.head` to a name:
            // it is read four times below and `group.head.latitude!` repeated
            // is worse. The pattern always matches.
            for (final group in communityGroups)
              if (group.head case final topo)
                Marker(
                  point: LatLng(topo.latitude!, topo.longitude!),
                  width: 40,
                  height: _BoulderMarker.totalHeight,
                  alignment: Alignment.topCenter,
                  child: GestureDetector(
                    key: Key('community-map-marker-${topo.wallId}'),
                    onTap: () {
                      FocusManager.instance.primaryFocus?.unfocus();
                      if (group.isGrouped) {
                        // More than one topo of this boulder: ask which, rather
                        // than silently opening the best-ranked one. Picking for
                        // the reader is the thing §C-6 is at pains to avoid —
                        // the second photo is often the better one, and only
                        // they can tell.
                        _showPlacePicker(context, group);
                        return;
                      }
                      // Read-only topo canvas (wall photo + drawn routes), NOT
                      // the social/likes-first CommunityTopoDetailScreen -- that
                      // view stays reserved for the Feed (see the OWN marker
                      // just below, which pushes the same route unadorned).
                      context.push('/walls/${topo.wallId}?readonly=1');
                    },
                    // Community-feed topos are, by construction, always
                    // shared/public (see `CommunityRepository.watchSharedTopos`
                    // -- the feed only ever contains `visibility == 'shared'`
                    // rows), so this marker always renders at full opacity
                    // (the public look).
                    child: _BoulderMarker(
                      isPublic: true,
                      placeCount: group.count,
                    ),
                  ),
                ),
          ],
        ),
        // The signed-in user's own located topos -- see this class's `build`
        // doc for how "own" is determined/deduped. Its own [MarkerLayer]
        // (rather than sharing the one above) so ordering is explicit: own
        // markers paint above community ones, below "you are here".
        MarkerLayer(
          markers: [
            for (final topo in ownWithCoords)
              Marker(
                point: LatLng(topo.latitude!, topo.longitude!),
                width: 40,
                height: _BoulderMarker.totalHeight,
                alignment: Alignment.topCenter,
                child: GestureDetector(
                  key: Key('community-map-own-marker-${topo.wallId}'),
                  onTap: () {
                    FocusManager.instance.primaryFocus?.unfocus();
                    context.push('/walls/${topo.wallId}');
                  },
                  child: _BoulderMarker(isPublic: topo.visibility == 'shared'),
                ),
              ),
          ],
        ),
        // The "you are here" marker, in its own MarkerLayer placed AFTER the
        // topo markers' layer so it always paints above them (flutter_map
        // stacks `FlutterMap.children` in list order). Omitted entirely
        // whenever myLocation is null — loading, denied, disabled, or any
        // other resolution failure (see myLocationProvider's doc) — so the
        // map and topo markers are unaffected either way.
        if (myLocation != null)
          MarkerLayer(
            markers: [
              Marker(
                point: LatLng(myLocation.latitude, myLocation.longitude),
                width: _MyLocationMarker.size,
                height: _MyLocationMarker.size,
                alignment: Alignment.center,
                child: const KeyedSubtree(
                  key: Key('community-map-my-location'),
                  child: _MyLocationMarker(),
                ),
              ),
            ],
          ),
        // An always-visible custom credit pill — deliberately NOT a
        // `RichAttributionWidget`, whose credit text is hidden behind a
        // collapsed info-icon popup until tapped, which does not satisfy
        // OSM's requirement that attribution be visible without
        // interaction. `IgnorePointer` keeps the pill from stealing marker
        // taps, and bottom-right placement keeps it clear of the pins.
        IgnorePointer(
          child: Align(
            alignment: Alignment.bottomRight,
            child: Padding(
              padding: EdgeInsets.fromLTRB(6, 6, 6, 6 + bottomChromeInset),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.surface.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  child: Text(
                    basemapAttribution,
                    key: const Key('community-map-attribution'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(
                      context,
                    ).textTheme.labelSmall?.copyWith(color: colors.ink2),
                  ),
                ),
              ),
            ),
          ),
        ),
        // A compact "Private" vs "Public" legend, bottom-left (mirroring the
        // bottom-right attribution pill) so it never fights the search
        // overlay now anchored to the TOP of the map (see the outer Stack's
        // `community-map-search-field` `Positioned`, below) for space.
        // Purely informational (no tap target of its own), like the
        // attribution.
        IgnorePointer(
          child: Align(
            alignment: Alignment.bottomLeft,
            child: Padding(
              padding: EdgeInsets.fromLTRB(6, 6, 6, 6 + bottomChromeInset),
              child: _MapLegend(colors: colors),
            ),
          ),
        ),
        // The transient "search result" marker (B4): the map location most
        // recently flown to via a search selection (local content OR a
        // place), rendered in its OWN `MarkerLayer` added LAST in this list
        // so it always paints ABOVE every other marker layer above,
        // including the boulder/"you are here" ones (flutter_map stacks
        // `FlutterMap.children` in list order) — it's meant to read
        // unambiguously as "the spot you just searched for", never
        // confusable with an existing topo pin. Omitted entirely once
        // `_selectedSearchResult` is cleared (the field is cleared, or a
        // fresh selection replaces it — see `_onSearchChanged`/
        // `_selectLocalResult`/`_selectPlaceResult`).
        if (_selectedSearchResult != null)
          MarkerLayer(
            markers: [
              Marker(
                point: _selectedSearchResult!,
                width: 34,
                height: _SearchResultMarker.totalHeight,
                alignment: Alignment.topCenter,
                child: KeyedSubtree(
                  key: const Key('community-map-search-marker'),
                  child: _SearchResultMarker(colors: colors),
                ),
              ),
            ],
          ),
      ],
    );

    // Map controls (find-me) are siblings of the FlutterMap in a
    // Stack, ABOVE it — FlutterMap.children are map LAYERS (they scroll/zoom
    // with the map), whereas these controls must stay fixed to the screen.
    // Positioned bottom-right, above the attribution pill (which sits
    // flush at the very bottom-right — see the `IgnorePointer`/`Align`
    // above), so neither overlaps the other or the top-left legend.
    return Stack(
      children: [
        flutterMap,
        // The unified map-search overlay (B1): a pill search field + its
        // grouped results dropdown, anchored to the TOP of the map (the
        // bottom-left/bottom-right legend/attribution below leave this area
        // free — see their doc). A sibling of the bottom-right find-me
        // column in this same outer `Stack` (never a child of
        // `flutterMap` — unlike the marker layers above, this is fixed
        // screen chrome, not something that should pan/zoom with the map).
        Positioned(
          top: MasiSpacing.sm + topChromeInset,
          left: MasiSpacing.lg,
          right: MasiSpacing.lg,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Material(
                color: Colors.transparent,
                child: TextField(
                  key: const Key('community-map-search-field'),
                  controller: _searchController,
                  focusNode: _searchFocusNode,
                  onChanged: _onSearchChanged,
                  decoration: InputDecoration(
                    hintText: 'Search the map',
                    prefixIcon: Padding(
                      padding: const EdgeInsets.only(left: 12, right: 8),
                      child: MasiIcon('search', size: 20, color: colors.ink3),
                    ),
                    prefixIconConstraints: const BoxConstraints(
                      minWidth: 0,
                      minHeight: 0,
                    ),
                    // "Still looking" — see `_placeSearchInFlight`'s doc. The
                    // slot is ALWAYS this wide, cue or no cue, so the field's
                    // text does not reflow when a search starts; the cue itself
                    // goes through `MasiLoadingIndicator`'s gate, so a fast
                    // lookup never blinks it.
                    suffixIcon: SizedBox(
                      width: 36,
                      child: Center(
                        child: MasiLoadingIndicator.inline(
                          key: const Key('community-map-search-busy'),
                          isLoading: _placeSearchInFlight,
                          semanticLabel: 'Searching',
                        ),
                      ),
                    ),
                    suffixIconConstraints: const BoxConstraints(
                      minWidth: 36,
                      minHeight: 36,
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
                ),
              ),
              // The results dropdown: LOCAL content (topos/routes/sectors/
              // areas — B3) ranked ABOVE places, simply by list order —
              // `localSearchResults` (already topos-then-routes-then-
              // sectors-then-areas per `mapContentSearch`'s doc) come first,
              // `_placeResults` last. Hidden entirely whenever both are
              // empty (no query committed yet, or a settled query matched
              // nothing on either side) — never a separate "loading"/error
              // state, mirroring `set_location_picker.dart`'s dropdown.
              if (showSearchDropdown)
                Container(
                  margin: const EdgeInsets.only(top: MasiSpacing.xs),
                  child: Material(
                    color: colors.surface,
                    borderRadius: BorderRadius.circular(MasiRadii.control),
                    clipBehavior: Clip.antiAlias,
                    elevation: 4,
                    // Caps how tall the dropdown can grow, mirroring
                    // `set_location_picker.dart`'s identical
                    // `_searchResultsMaxHeight` fix — a large `textScaler`
                    // or many combined local+place rows must scroll rather
                    // than push the dropdown off the bottom of small
                    // screens or overflow its `RenderFlex`.
                    //
                    // When BOTH halves came back empty, this container is
                    // only showing at all because `_placesOffline` is true
                    // (see `showSearchDropdown`'s doc) — render the "needs a
                    // connection" hint INSTEAD of an empty `ListView` (which
                    // would otherwise render as a zero-height, visually
                    // empty pill), exactly mirroring
                    // `set_location_picker.dart`'s identical hint.
                    child: (localSearchResults.isEmpty && _placeResults.isEmpty)
                        ? Padding(
                            key: const Key('community-map-search-offline'),
                            padding: const EdgeInsets.symmetric(
                              horizontal: MasiSpacing.md,
                              vertical: MasiSpacing.sm,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                MasiIcon(
                                  'warning',
                                  size: 16,
                                  color: colors.ink2,
                                ),
                                const SizedBox(width: MasiSpacing.xs),
                                Flexible(
                                  child: Text(
                                    'Search needs a connection.',
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(color: colors.ink2),
                                  ),
                                ),
                              ],
                            ),
                          )
                        : ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 280),
                            child: ListView.separated(
                              shrinkWrap: true,
                              padding: EdgeInsets.zero,
                              itemCount:
                                  localSearchResults.length +
                                  _placeResults.length,
                              separatorBuilder: (_, _) =>
                                  Divider(height: 1, color: colors.separator),
                              itemBuilder: (context, i) {
                                if (i < localSearchResults.length) {
                                  final result = localSearchResults[i];
                                  return ListTile(
                                    key: Key('community-map-search-result-$i'),
                                    dense: true,
                                    leading: MasiIcon(
                                      _iconForSearchKind(result.kind),
                                      size: 18,
                                      color: colors.ink3,
                                    ),
                                    title: Text(
                                      result.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    subtitle: Text(
                                      result.subtitle != null
                                          ? '${_labelForSearchKind(result.kind)} · '
                                                '${result.subtitle}'
                                          : _labelForSearchKind(result.kind),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    onTap: () => _selectLocalResult(result),
                                  );
                                }
                                final place =
                                    _placeResults[i -
                                        localSearchResults.length];
                                return ListTile(
                                  key: Key('community-map-search-result-$i'),
                                  dense: true,
                                  leading: MasiIcon(
                                    'pin',
                                    size: 18,
                                    color: colors.ink3,
                                  ),
                                  title: Text(
                                    place.displayName,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: const Text(
                                    'Place',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  onTap: () => _selectPlaceResult(place),
                                );
                              },
                            ),
                          ),
                  ),
                ),
            ],
          ),
        ),
        Positioned(
          right: 8,
          bottom: 44 + bottomChromeInset,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // `community-map-refresh` used to sit here (#57: a manual
              // re-pull, because the map has no scrollable surface to hang a
              // RefreshIndicator off). Removed 2026-08-11 by request, in the
              // same breath as pull-to-refresh landing on the Topos home:
              // every OTHER surface refreshes by gesture, and a button that
              // exists only because this one screen cannot is a control the
              // user has to learn separately. The pull it ran is not lost —
              // it also runs on app resume, on connectivity regain, on the
              // sign-in edge, and now from the Topos home's own pull-down,
              // which shares one `pullNow()` and one set of shared rows with
              // this map.
              _MapControlButton(
                mapControlKey: const Key('community-map-find-me'),
                iconName: 'my_location',
                tooltip: 'Find my location',
                colors: colors,
                onPressed: _onFindMePressed,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A compact, theme-aware circular icon button for the Map tab's find-me and
/// refresh controls — styled with [MasiColors] rather than Material's default
/// `FloatingActionButton` look, to sit consistently with the rest of the app's
/// chrome.
///
/// Both of its actions are slow, invisible work: `currentLocation()` is a cold
/// GPS fix (seconds on a real phone) and `pullNow()` is a network round trip.
/// Before the pending cue below, both buttons looked idle throughout — so the
/// map appeared to have ignored the tap, and the natural response was to tap
/// again and start a second fix/pull. [PendingIconButton] both shows the cue
/// ON the control that was touched and swallows that second tap.
///
/// [mapControlKey] (rather than a bare `key` ctor param) so the wrapping
/// [Material] — the actual hit-testable/keyed widget a test taps — carries
/// the stable key, since [_MapControlButton] itself is a plain
/// [StatelessWidget] whose own `key` only identifies it to Flutter's element
/// tree, not to `find.byKey` callers reaching for the tappable surface.
class _MapControlButton extends StatelessWidget {
  const _MapControlButton({
    required this.mapControlKey,
    required this.iconName,
    required this.tooltip,
    required this.colors,
    required this.onPressed,
  });

  final Key mapControlKey;
  final String iconName;
  final String tooltip;
  final MasiColors colors;

  /// The action, awaited by [PendingIconButton] — see this class's doc.
  final Future<void> Function() onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: mapControlKey,
      color: colors.surface,
      shape: const CircleBorder(),
      elevation: 2,
      child: PendingIconButton(
        // No `buttonKey`: the wrapping Material above already carries the key
        // callers/tests reach for (see this class's doc).
        tooltip: tooltip,
        onPressed: onPressed,
        icon: MasiIcon(iconName, color: colors.ink),
      ),
    );
  }
}

/// The Map tab's "Private"/"Public" key (`community-map-legend`),
/// explaining [_BoulderMarker]'s visibility-encoded look: since the marker
/// is now just the bare `boulder_logo` glyph (no ring/disc background --
/// see that class's doc), the cue for visibility is color -- a grayscale
/// swatch (matching [_BoulderMarker.greyscale]/`_privateMuteOpacity`) for
/// private topos, a full-color one for public -- every marker on the map
/// (own or community) follows that same rule, regardless of which
/// `MarkerLayer`/tap-target it belongs to.
class _MapLegend extends StatelessWidget {
  const _MapLegend({required this.colors});

  final MasiColors colors;

  @override
  Widget build(BuildContext context) {
    final textStyle = Theme.of(
      context,
    ).textTheme.labelSmall?.copyWith(color: colors.ink2);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          key: const Key('community-map-legend'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _MapLegendRow(
              isPublic: false,
              label: 'Private',
              textStyle: textStyle,
            ),
            const SizedBox(height: 4),
            _MapLegendRow(
              isPublic: true,
              label: 'Public',
              textStyle: textStyle,
            ),
          ],
        ),
      ),
    );
  }
}

class _MapLegendRow extends StatelessWidget {
  const _MapLegendRow({
    required this.isPublic,
    required this.label,
    this.textStyle,
  });

  final bool isPublic;
  final String label;
  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) {
    const swatch = MasiIcon('boulder_logo', tinted: false, size: 14);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        isPublic
            ? swatch
            : const Opacity(
                opacity: _BoulderMarker._privateMuteOpacity,
                child: ColorFiltered(
                  colorFilter: _BoulderMarker.greyscale,
                  child: swatch,
                ),
              ),
        const SizedBox(width: 6),
        Text(
          label,
          style: textStyle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

/// The Map tab's "you are here" marker: a small filled blue dot with a white
/// ring (the familiar device-position convention), deliberately NOT styled
/// like [_BoulderMarker] — a plain dot centered exactly on the coordinate
/// (rather than a shape whose base sits at it) reads unambiguously as "this
/// is where I am", distinct from every topo's marker.
class _MyLocationMarker extends StatelessWidget {
  const _MyLocationMarker();

  static const double size = 18;

  /// Fixed "you are here" dot color — the conventional device-position
  /// blue, kept deliberately independent of light/dark [MasiColors] (this
  /// sits on top of OSM map tiles, which stay the same light color
  /// regardless of the app's own theme, so the marker needs to keep its own
  /// fixed contrast against the map rather than following app chrome).
  /// Named consts here rather than bare `Colors.*` literals so this widget
  /// no longer reaches into Material's default palette directly.
  static const Color _dotColor = Color(0xFF2196F3);
  static const Color _ringColor = Color(0xFFFFFFFF);
  static const Color _shadowColor = Color(0x61000000); // ~38% black

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        color: _dotColor,
        shape: BoxShape.circle,
        border: Border.fromBorderSide(BorderSide(color: _ringColor, width: 3)),
        boxShadow: [
          BoxShadow(color: _shadowColor, blurRadius: 4, offset: Offset(0, 1)),
        ],
      ),
    );
  }
}

/// The transient "search result" marker (B4) `_MapViewState` drops at
/// `_selectedSearchResult` — a solid pin glyph, deliberately NOT
/// [_BoulderMarker]'s boulder-logo badge (that would read as "an existing
/// topo lives here") and NOT [_MyLocationMarker]'s plain dot (that already
/// means "this is my device"), so a searched-for spot reads unambiguously
/// as its own third thing on the map.
class _SearchResultMarker extends StatelessWidget {
  const _SearchResultMarker({required this.colors});

  final MasiColors colors;

  /// Total height of the enclosing [Marker] box — mirrors
  /// [_BoulderMarker.totalHeight]'s doc: [MarkerLayer] gives its child TIGHT
  /// `(width, height)` constraints regardless of the child's own size, so
  /// this only has to match the call site's `Marker.height`.
  static const double totalHeight = 34;

  @override
  Widget build(BuildContext context) {
    // A white halo behind the glyph keeps it legible over the basemap
    // regardless of the app's own light/dark theme, mirroring
    // `set_location_picker.dart`'s crosshair.
    return Align(
      alignment: Alignment.bottomCenter,
      child: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          MasiIcon('pin_fill', size: totalHeight, color: Colors.white),
          MasiIcon('pin_fill', size: totalHeight - 6, color: colors.accent),
        ],
      ),
    );
  }
}

/// Per-[MapSearchKind] type-hint icon for a `community-map-search-result-$i`
/// row (B3) — a topo IS a [TopoRef]/wall, hence `'wall'` rather than
/// [_BoulderMarker]'s full-color `'boulder_logo'` (which would be an
/// oddly heavy, multi-tone glyph for a small dropdown row).
String _iconForSearchKind(MapSearchKind kind) {
  switch (kind) {
    case MapSearchKind.topo:
      return 'wall';
    case MapSearchKind.route:
      return 'route';
    case MapSearchKind.sector:
      return 'signpost';
    case MapSearchKind.area:
      return 'mountain';
  }
}

/// Per-[MapSearchKind] type-hint label for a `community-map-search-result-$i`
/// row's subtitle (B3), prefixed onto [MapSearchResult.subtitle] when
/// present (a route/topo's parent wall/area name) or shown alone (sectors/
/// areas have no natural subtitle — see that field's doc).
String _labelForSearchKind(MapSearchKind kind) {
  switch (kind) {
    case MapSearchKind.topo:
      return 'Topo';
    case MapSearchKind.route:
      return 'Route';
    case MapSearchKind.sector:
      return 'Sector';
    case MapSearchKind.area:
      return 'Area';
  }
}

/// The Map tab's per-topo marker: JUST the app's `masi_boulder_logo` mark (a
/// full-color, multi-tone purple SVG — see `assets/icons/masi/`), with no
/// ring/disc background behind it — replacing this class's earlier look (a
/// colored ring badge + neutral inner disc behind the same logo), which
/// itself replaced an even older hand-painted faceted-boulder
/// `CustomPaint`/`_BoulderPainter`, and before that an app-icon-in-a-white-
/// circle pin (see [_MapPinBadge]/[_OwnMapPinBadge]). Used by BOTH the
/// community and own `MarkerLayer`s in [_MapView.build] — the own-vs-
/// community split still exists (separate layers/tap targets), it just
/// doesn't change the marker's look beyond [isPublic]'s color treatment
/// (below).
///
/// `masi_boulder_logo` is full-color/multi-tone, not a single-color glyph,
/// so it's rendered via `MasiIcon('boulder_logo', tinted: false)` — opting
/// out of [MasiIcon]'s default `BlendMode.srcIn` tint (see that widget's
/// `build`) so the logo shows its own natural colors instead of being
/// flattened to one. Since an un-tinted render ignores [MasiIcon.color]
/// entirely, and there's no background shape left to carry a color either,
/// the public/private distinction is carried by [greyscale]: public/shared
/// topos render the full-color glyph as-is, private ones render the SAME
/// glyph desaturated to grayscale (via [ColorFiltered]) plus a small extra
/// opacity fade ([_privateMuteOpacity]) for emphasis — color-vs-gray is the
/// PRIMARY cue (opacity alone, at 0.55, proved too subtle to read at a
/// glance — see this class's fix history), not opacity alone. Shared with
/// [_MapLegend]/[_MapLegendRow] so the legend's swatches always match the
/// marker exactly.
/// Asks which topo of a place the reader wants (community editing phase 8b /
/// C-6.2).
///
/// Ordered by rank, best first — the same order the feed's card uses, so the
/// two surfaces cannot disagree about which drawing of a boulder leads. The
/// subtitle is the concrete stuff a climber picks on (how many lines, how many
/// people liked it), not a score: the ranking decides the ORDER, and exposing
/// its arithmetic would invite arguing with it (see `TopoRank`, and Open
/// Question 3 on why there is no rating widget here).
Future<void> _showPlacePicker(BuildContext context, TopoGroup group) async {
  final picked = await showMasiActionSheet<String>(
    context,
    sheetKey: const Key('map-place-picker-sheet'),
    title: '${group.count} topos of this boulder',
    message: 'Different photos, different angles. Best first.',
    actions: [
      for (final topo in group.all)
        MasiSheetAction(
          key: Key('map-place-option-${topo.wallId}'),
          label: topo.name,
          value: topo.wallId,
          subtitle:
              '${topo.routeCount} route${topo.routeCount == 1 ? '' : 's'}'
              '${topo.likeCount > 0 ? ' · ♥ ${topo.likeCount}' : ''}',
        ),
    ],
  );
  if (picked == null || !context.mounted) return;
  context.push('/walls/$picked?readonly=1');
}

class _BoulderMarker extends StatelessWidget {
  const _BoulderMarker({required this.isPublic, this.placeCount = 1});

  final bool isPublic;

  /// How many topos of the SAME PLACE this pin stands for (community editing
  /// phase 8b / C-6.2). 1 — the overwhelming majority — draws the bare glyph
  /// exactly as before; more adds a small count badge.
  ///
  /// Without this the map was the one surface where duplicates still looked
  /// like separate crags: four topos of one boulder are four pins within a few
  /// metres, which at any real zoom is one smudge that cannot be tapped apart.
  final int placeCount;

  /// Total height of the enclosing [Marker] box. This widget's own drawn
  /// content (see [_iconSize]) is deliberately SMALLER than this —
  /// [MarkerLayer] wraps every marker's child in a `Positioned(width:,
  /// height:)` inside a `Stack`, which gives it TIGHT constraints of
  /// exactly (`width`, `height`) regardless of the child's own size (see
  /// flutter_map's `marker_layer.dart`), so this constant only has to match
  /// the call sites' `Marker.height` for box-height tests to keep passing —
  /// the glyph itself is bottom-anchored inside that box (see [build]),
  /// which is what keeps its visual base sitting on the actual coordinate
  /// per `Alignment.topCenter`'s "anchors the box's bottom edge" semantics.
  /// Kept comfortably above [_iconSize] so the tap target stays generous
  /// even though the glyph itself shrank (28 -> 22, per user feedback that
  /// the marker read as too big).
  static const double totalHeight = 40;

  /// Size of the bare boulder-logo glyph. Shrunk from the previous 28 (user
  /// feedback: "the boulder icon on the map is a bit too big") while
  /// [totalHeight] stays unchanged, so the tap target doesn't shrink with
  /// it.
  static const double _iconSize = 22;

  /// Luminance-weighted (ITU-R BT.709) grayscale [ColorFilter] applied to a
  /// PRIVATE topo's glyph — the PRIMARY cue distinguishing private from
  /// public markers now that opacity alone ([_privateMuteOpacity]'s much
  /// milder fade) proved too subtle on its own. Shared with
  /// [_MapLegendRow] so the legend's "Private" swatch always matches the
  /// marker exactly.
  static const ColorFilter greyscale = ColorFilter.matrix(<double>[
    0.2126,
    0.7152,
    0.0722,
    0,
    0,
    0.2126,
    0.7152,
    0.0722,
    0,
    0,
    0.2126,
    0.7152,
    0.0722,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ]);

  /// Small secondary fade layered on top of [greyscale] for a PRIVATE
  /// glyph, for extra muting — never the primary distinction (that's
  /// color-vs-gray above).
  static const double _privateMuteOpacity = 0.85;

  @override
  Widget build(BuildContext context) {
    const glyph = MasiIcon('boulder_logo', tinted: false, size: _iconSize);
    final Widget marker = isPublic
        ? glyph
        : const Opacity(
            opacity: _privateMuteOpacity,
            child: ColorFiltered(colorFilter: greyscale, child: glyph),
          );
    return Align(
      alignment: Alignment.bottomCenter,
      child: placeCount <= 1
          ? marker
          : Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.bottomCenter,
              children: [
                marker,
                // Offset up-and-right of the glyph rather than centred on it,
                // so the badge never covers the boulder shape that tells a
                // reader what the pin IS.
                Positioned(
                  top: -2,
                  right: -6,
                  child: _PlaceCountBadge(count: placeCount),
                ),
              ],
            ),
    );
  }
}

/// "3" on a map pin that stands for three topos of one boulder.
class _PlaceCountBadge extends StatelessWidget {
  const _PlaceCountBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      constraints: const BoxConstraints(minWidth: 16),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.separator),
      ),
      child: Text(
        '$count',
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: colors.ink,
          fontWeight: FontWeight.w700,
          height: 1.1,
        ),
      ),
    );
  }
}
