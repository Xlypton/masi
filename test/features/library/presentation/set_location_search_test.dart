// Tests for the place-search field added to the "Set location" map picker
// (`set_location_picker.dart`): typing a query, debounced results appearing,
// and tapping a result moving the map + enabling Save. Mirrors
// `topos_screen_test.dart`'s "S-L5"/"S-L6" direct-`showSetLocationPicker`
// harness pattern (a captured `BuildContext` via `Builder`, a real
// `MapController`, and a `_NoopTileProvider` so `FlutterMap`'s `TileLayer`
// never attempts real network I/O) rather than seeding a whole
// Area/Sector/Wall — this picker's search behavior doesn't depend on any of
// that plumbing.

import 'dart:async' show Completer, unawaited;

import 'package:masi/app/theme.dart';
import 'package:masi/core/location/geocoding_service.dart';
import 'package:masi/features/backup/application/backup_providers.dart';
import 'package:masi/features/backup/data/connectivity_service.dart';
import 'package:masi/core/location/location_service.dart';
import 'package:masi/features/library/presentation/set_location_picker.dart';
import 'package:masi/shared/presentation/masi_loading_indicator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../../support/fake_basemap.dart';

/// A tile provider that never performs any network/file I/O: every tile
/// request resolves synchronously to the same tiny in-memory image (copied
/// from `topos_screen_test.dart`'s identical private class).
/// A [GeocodingService] double that, by default, resolves every query to
/// whatever fixed [results] list it was constructed with — no real network/
/// Nominatim call ever happens under `flutter_test`. Tracks [callCount]/
/// [lastQuery] so tests can assert on debounce behavior (one call per
/// settled query, not one per keystroke).
///
/// For the out-of-order/stale-result race (F1), a query can instead be
/// wired to a caller-controlled [Completer] via [pending]: registering one
/// under a query string makes [search] return that completer's future
/// INSTEAD of resolving immediately, so a test can decide exactly when
/// (and with what) a specific query's lookup finishes — e.g. to simulate a
/// slow search for an earlier query that only resolves AFTER a faster,
/// more recent one already has.
class _FakeGeocodingService implements GeocodingService {
  _FakeGeocodingService(this.results);

  final List<PlaceResult> results;
  int callCount = 0;
  String? lastQuery;
  final Map<String, Completer<List<PlaceResult>>> pending = {};

  @override
  Future<List<PlaceResult>> search(String query) {
    callCount++;
    lastQuery = query;
    final completer = pending[query];
    if (completer != null) return completer.future;
    return Future.value(results);
  }
}

/// A [ConnectivityService] double whose reachability answer is scripted —
/// mirrors `reachability_providers_test.dart`'s `_ScriptedConnectivity`
/// (that one is private to its own file, so this is its own copy).
/// [statusChanges] degrades to a never-emitting stream, exactly as
/// `ConnectivityService.statusChanges`'s contract requires of an
/// implementation with no real platform signal behind it.
///
/// [gate], when set, makes [isBackendReachable] wait on it instead of
/// resolving immediately. An immediately-resolving fake would let the
/// offline-hint tests below pass even if the production code never
/// genuinely awaited the probe (a false pass for what is fundamentally
/// async state) — gating it proves the hint only appears once the probe
/// actually settles, not the instant a search comes back empty.
class _FakeConnectivityService implements ConnectivityService {
  _FakeConnectivityService(this.reachable);

  bool reachable;
  int probeCount = 0;
  Completer<void>? gate;

  @override
  Future<bool> isBackendReachable() async {
    probeCount++;
    if (gate != null) await gate!.future;
    return reachable;
  }

  @override
  Future<NetworkStatus> currentStatus() async => NetworkStatus.wifi;

  @override
  Stream<NetworkStatus> statusChanges() => const Stream.empty();
}

const _railay = PlaceResult(
  displayName: 'Railay Beach, Krabi, Thailand',
  latitude: 8.0104,
  longitude: 98.8375,
);
const _railayEast = PlaceResult(
  displayName: 'Railay East, Krabi, Thailand',
  latitude: 8.015,
  longitude: 98.84,
);

/// Pumps a bare host app and returns its captured [BuildContext] -- mirrors
/// `topos_screen_test.dart`'s S-L5/S-L6 harness (a `Builder` capturing
/// `context` for a direct [showSetLocationPicker] call, rather than seeding
/// a whole Area/Sector/Wall to reach the picker via a real screen).
///
/// Deliberately split from the [showSetLocationPicker] call itself: that
/// call returns the route's pop future (which by design doesn't resolve
/// until Save/Cancel is tapped, later in the test), so it must never be
/// `await`ed here -- only the harness's OWN `pumpWidget`/`pumpAndSettle`
/// work is awaited by this helper, exactly like every other pattern in this
/// codebase's widget tests.
///
/// [connectivity] backs `connectivityServiceProvider` — the picker's
/// `initState` fires an unconditional, fire-and-forget reachability probe
/// (see `set_location_picker.dart`'s doc), so every test needs a real
/// `ProviderScope` ancestor for that `ref.read` to resolve against, even
/// tests that never look at the offline hint themselves. Defaults to an
/// always-reachable fake so pre-existing assertions (written before the
/// offline hint existed) see no behavioral change.
Future<BuildContext> _pumpHarness(
  WidgetTester tester, {
  ConnectivityService? connectivity,
}) async {
  late BuildContext capturedContext;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
      ...fakeBasemapOverrides(),
        connectivityServiceProvider.overrideWithValue(
          connectivity ?? _FakeConnectivityService(true),
        ),
      ],
      child: MaterialApp(
        theme: MasiTheme.light,
        home: Builder(
          builder: (context) {
            capturedContext = context;
            return const SizedBox();
          },
        ),
      ),
    ),
  );
  return capturedContext;
}

/// A [LocationService] double whose fix only lands when [gate] is completed,
/// so a test can observe the "use my location" button DURING the fix rather
/// than only after it. [calls] proves a second tap mid-fix starts nothing.
class _GatedLocationService implements LocationService {
  _GatedLocationService(this.gate);

  final Completer<DeviceLocation?> gate;
  int calls = 0;

  @override
  Future<DeviceLocation?> currentLocation() {
    calls++;
    return gate.future;
  }
}

void main() {
  group('set-location-search-field', () {
    testWidgets(
      'typing a query shows nothing until the debounce elapses, then shows '
      'up to 5 tappable results',
      (tester) async {
        final controller = MapController();
        addTearDown(controller.dispose);
        final geocoding = _FakeGeocodingService([_railay, _railayEast]);

        final context = await _pumpHarness(tester);
        final pickerFuture = showSetLocationPicker(
          context,
          controller: controller,
          geocodingService: geocoding,
        );
        // Never tapped to completion in this test -- this picker's own
        // route-pop future intentionally stays pending.
        unawaited(pickerFuture);
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('set-location-search-field')),
          'railay',
        );
        await tester.pump();

        expect(
          find.byKey(const Key('set-location-search-result-0')),
          findsNothing,
          reason: 'results must not appear before the debounce elapses',
        );
        expect(geocoding.callCount, 0);

        // Past the ~350ms debounce.
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();

        expect(geocoding.callCount, 1);
        expect(geocoding.lastQuery, 'railay');
        expect(
          find.byKey(const Key('set-location-search-result-0')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('set-location-search-result-1')),
          findsOneWidget,
        );
        expect(find.text('Railay Beach, Krabi, Thailand'), findsOneWidget);
        expect(find.text('Railay East, Krabi, Thailand'), findsOneWidget);
      },
    );

    testWidgets(
      'debounces rapid keystrokes into a single search call for the '
      'settled query',
      (tester) async {
        final controller = MapController();
        addTearDown(controller.dispose);
        final geocoding = _FakeGeocodingService([_railay]);

        final context = await _pumpHarness(tester);
        final pickerFuture = showSetLocationPicker(
          context,
          controller: controller,
          geocodingService: geocoding,
        );
        unawaited(pickerFuture);
        await tester.pumpAndSettle();

        final field = find.byKey(const Key('set-location-search-field'));
        await tester.enterText(field, 'r');
        await tester.pump(const Duration(milliseconds: 100));
        await tester.enterText(field, 'ra');
        await tester.pump(const Duration(milliseconds: 100));
        await tester.enterText(field, 'rai');
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();

        expect(
          geocoding.callCount,
          1,
          reason:
              'each keystroke must cancel the prior debounce timer, so only '
              'the final settled query ever reaches the service',
        );
        expect(geocoding.lastQuery, 'rai');
      },
    );

    testWidgets(
      'a query matching nothing WHILE ONLINE shows no result rows, never '
      'crashes, and does not show the offline hint -- a legitimately-empty '
      'result is not the same state as "can\'t search"',
      (tester) async {
        final controller = MapController();
        addTearDown(controller.dispose);
        final geocoding = _FakeGeocodingService(const []);
        final connectivity = _FakeConnectivityService(true);

        final context = await _pumpHarness(tester, connectivity: connectivity);
        final pickerFuture = showSetLocationPicker(
          context,
          controller: controller,
          geocodingService: geocoding,
        );
        unawaited(pickerFuture);
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('set-location-search-field')),
          'nowhere',
        );
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();
        await tester.pump();

        expect(geocoding.callCount, 1);
        expect(
          find.byKey(const Key('set-location-search-result-0')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('set-location-search-offline')),
          findsNothing,
          reason: 'the backend answered fine -- this is a genuine "no such '
              'place", not an offline condition, so no hint must render',
        );
      },
    );

    testWidgets(
      'a query matching nothing WHILE OFFLINE shows the "needs a '
      'connection" hint instead of a silent empty dropdown -- and only '
      'once the reachability probe genuinely settles, not the instant the '
      'search comes back empty',
      (tester) async {
        final controller = MapController();
        addTearDown(controller.dispose);
        final geocoding = _FakeGeocodingService(const []);
        final connectivity = _FakeConnectivityService(false)
          ..gate = Completer<void>();

        final context = await _pumpHarness(tester, connectivity: connectivity);
        final pickerFuture = showSetLocationPicker(
          context,
          controller: controller,
          geocodingService: geocoding,
        );
        unawaited(pickerFuture);
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('set-location-search-field')),
          'nowhere',
        );
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();

        expect(geocoding.callCount, 1);
        expect(
          find.byKey(const Key('set-location-search-offline')),
          findsNothing,
          reason: 'the reachability probe this empty result triggered is '
              'still in flight (gated) -- nothing has been decided yet, so '
              'the hint must not render prematurely off an unresolved fake',
        );

        // Now let the gated probe actually resolve.
        connectivity.gate!.complete();
        await tester.pump();
        await tester.pump();

        expect(
          find.byKey(const Key('set-location-search-offline')),
          findsOneWidget,
        );
        expect(find.text('Search needs a connection.'), findsOneWidget);
        expect(
          find.byKey(const Key('set-location-search-result-0')),
          findsNothing,
        );
      },
    );

    testWidgets(
      'clearing the query hides the offline hint immediately, same as it '
      'hides a normal results dropdown',
      (tester) async {
        final controller = MapController();
        addTearDown(controller.dispose);
        final geocoding = _FakeGeocodingService(const []);
        final connectivity = _FakeConnectivityService(false);

        final context = await _pumpHarness(tester, connectivity: connectivity);
        final pickerFuture = showSetLocationPicker(
          context,
          controller: controller,
          geocodingService: geocoding,
        );
        unawaited(pickerFuture);
        await tester.pumpAndSettle();

        final field = find.byKey(const Key('set-location-search-field'));
        await tester.enterText(field, 'nowhere');
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();
        await tester.pump();
        expect(
          find.byKey(const Key('set-location-search-offline')),
          findsOneWidget,
          reason: 'sanity check: the hint is up before clearing',
        );

        await tester.enterText(field, '');
        await tester.pump();

        expect(
          find.byKey(const Key('set-location-search-offline')),
          findsNothing,
        );
      },
    );

    testWidgets('clearing the query hides the results dropdown', (
      tester,
    ) async {
      final controller = MapController();
      addTearDown(controller.dispose);
      final geocoding = _FakeGeocodingService([_railay]);

      final context = await _pumpHarness(tester);
      final pickerFuture = showSetLocationPicker(
        context,
        controller: controller,
        geocodingService: geocoding,
      );
      unawaited(pickerFuture);
      await tester.pumpAndSettle();

      final field = find.byKey(const Key('set-location-search-field'));
      await tester.enterText(field, 'railay');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(
        find.byKey(const Key('set-location-search-result-0')),
        findsOneWidget,
      );

      await tester.enterText(field, '');
      await tester.pump();

      expect(
        find.byKey(const Key('set-location-search-result-0')),
        findsNothing,
        reason: 'an emptied query must hide results immediately, without '
            'waiting for another debounce/service round-trip',
      );
    });

    testWidgets(
      'a slow, superseded search never overwrites a faster, more recent '
      "search's results, even though it resolves later",
      (tester) async {
        final controller = MapController();
        addTearDown(controller.dispose);
        // Default result (used for any query with no registered completer,
        // i.e. the second/fresher query below) is Railay East; the first
        // (slow, superseded) query is wired to a completer this test
        // controls directly.
        final geocoding = _FakeGeocodingService([_railayEast]);
        final firstCompleter = Completer<List<PlaceResult>>();
        geocoding.pending['first'] = firstCompleter;

        final context = await _pumpHarness(tester);
        final pickerFuture = showSetLocationPicker(
          context,
          controller: controller,
          geocodingService: geocoding,
        );
        unawaited(pickerFuture);
        await tester.pumpAndSettle();

        final field = find.byKey(const Key('set-location-search-field'));

        // Query A ("first"): debounce elapses, the lookup fires, but its
        // completer is deliberately left unresolved -- this is the slow
        // search.
        await tester.enterText(field, 'first');
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();
        expect(geocoding.callCount, 1);
        expect(geocoding.lastQuery, 'first');
        expect(
          find.byKey(const Key('set-location-search-result-0')),
          findsNothing,
          reason: "query A's lookup is still pending -- nothing to show yet",
        );

        // Query B ("second"): typed and settled entirely before A resolves.
        // Its lookup is NOT wired to a completer, so it resolves on the
        // very next microtask.
        await tester.enterText(field, 'second');
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();
        expect(geocoding.callCount, 2);
        expect(geocoding.lastQuery, 'second');
        expect(
          find.text(_railayEast.displayName),
          findsOneWidget,
          reason: "query B's (faster, more recent) results must show",
        );

        // NOW let query A's stale search finally resolve, with a result
        // that must never be allowed to appear.
        firstCompleter.complete(const [_railay]);
        await tester.pump();

        expect(
          find.text(_railayEast.displayName),
          findsOneWidget,
          reason: "query B's results must remain, undisturbed by A's late "
              'completion',
        );
        expect(
          find.text(_railay.displayName),
          findsNothing,
          reason: "query A's late-arriving result must never overwrite "
              "query B's, since A was superseded before it resolved",
        );
      },
    );

    testWidgets(
      'clearing the query while a search is in flight prevents its late '
      'result from repopulating the (now-empty) dropdown',
      (tester) async {
        final controller = MapController();
        addTearDown(controller.dispose);
        final geocoding = _FakeGeocodingService([_railay]);
        final ghostCompleter = Completer<List<PlaceResult>>();
        geocoding.pending['ghost'] = ghostCompleter;

        final context = await _pumpHarness(tester);
        final pickerFuture = showSetLocationPicker(
          context,
          controller: controller,
          geocodingService: geocoding,
        );
        unawaited(pickerFuture);
        await tester.pumpAndSettle();

        final field = find.byKey(const Key('set-location-search-field'));
        await tester.enterText(field, 'ghost');
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();
        expect(geocoding.callCount, 1);
        expect(
          find.byKey(const Key('set-location-search-result-0')),
          findsNothing,
          reason: "the 'ghost' lookup is still pending",
        );

        // Clear the field entirely while that lookup is still in flight.
        await tester.enterText(field, '');
        await tester.pump();
        expect(
          find.byKey(const Key('set-location-search-result-0')),
          findsNothing,
        );

        // The stale lookup finally resolves -- it must not repopulate the
        // dropdown the user already cleared.
        ghostCompleter.complete(const [_railay]);
        await tester.pump();

        expect(
          find.byKey(const Key('set-location-search-result-0')),
          findsNothing,
          reason: 'a cleared query must stay cleared, even once its old '
              'in-flight search finally resolves',
        );
      },
    );

    testWidgets(
      'tapping a result moves the map there, populates the field with its '
      'name (without firing a new search), enables Save, and collapses '
      'the dropdown; Save then pops exactly that coordinate',
      (tester) async {
        final controller = MapController();
        addTearDown(controller.dispose);
        final geocoding = _FakeGeocodingService([_railay, _railayEast]);

        final context = await _pumpHarness(tester);
        final pickerFuture = showSetLocationPicker(
          context,
          controller: controller,
          geocodingService: geocoding,
        );
        await tester.pumpAndSettle();

        expect(
          tester
              .widget<TextButton>(find.byKey(const Key('set-location-save')))
              .onPressed,
          isNull,
          reason: 'no interaction yet -- Save must start disabled',
        );

        final field = find.byKey(const Key('set-location-search-field'));
        await tester.enterText(field, 'railay');
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();
        expect(geocoding.callCount, 1);

        await tester.tap(
          find.byKey(const Key('set-location-search-result-0')),
        );
        await tester.pump();

        final center = controller.camera.center;
        expect((center.latitude - _railay.latitude).abs(), lessThan(0.001));
        expect((center.longitude - _railay.longitude).abs(), lessThan(0.001));

        expect(
          find.byKey(const Key('set-location-search-result-0')),
          findsNothing,
          reason: 'selecting a result must collapse the dropdown',
        );
        expect(
          tester.widget<TextField>(field).controller!.text,
          _railay.displayName,
          reason: 'the field must show what was picked, not the raw typed '
              'query',
        );
        expect(
          geocoding.callCount,
          1,
          reason: 'writing the picked name into the field must not itself '
              'trigger a new search for that name',
        );
        expect(
          tester
              .widget<TextButton>(find.byKey(const Key('set-location-save')))
              .onPressed,
          isNotNull,
          reason:
              'a searched place IS an active choice, exactly like "use my '
              'location" -- Save must now be enabled',
        );

        // Give any (incorrectly) scheduled debounce timer a chance to fire,
        // to catch a regression where setting the field's text re-triggers
        // `_onSearchChanged`'s debounced path instead of no-oping.
        await tester.pump(const Duration(milliseconds: 400));
        expect(geocoding.callCount, 1);

        await tester.tap(find.byKey(const Key('set-location-save')));
        await tester.pumpAndSettle();

        final picked = await pickerFuture;
        expect(picked, isNotNull);
        expect((picked!.latitude - _railay.latitude).abs(), lessThan(0.001));
        expect(
          (picked.longitude - _railay.longitude).abs(),
          lessThan(0.001),
        );
      },
    );

    testWidgets(
      'the results dropdown stays height-capped and scrollable at a large '
      'text scale on a small viewport, with 5 long-named results',
      (tester) async {
        // Mirrors this codebase's standard viewport-resize idiom (see e.g.
        // `topo_overflow_test.dart`'s `setViewportSize`): a small phone-ish
        // logical viewport, with `devicePixelRatio: 1.0` so `physicalSize`
        // IS the logical size.
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final controller = MapController();
        addTearDown(controller.dispose);

        final longResults = List.generate(
          5,
          (i) => PlaceResult(
            displayName:
                'Result $i: An Extremely Long Crag Name That Will Wrap '
                'Onto Two Full Lines Of Text Even Before Any Text-Scale '
                'Is Applied, Somewhere Very Far Away',
            latitude: 8.0 + i * 0.01,
            longitude: 98.0 + i * 0.01,
          ),
        );
        final geocoding = _FakeGeocodingService(longResults);

        late BuildContext capturedContext;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
      ...fakeBasemapOverrides(),
              connectivityServiceProvider.overrideWithValue(
                _FakeConnectivityService(true),
              ),
            ],
            child: MaterialApp(
              theme: MasiTheme.light,
              // The large-text-scale override itself, applied the same way
              // as every other "layout overflow regression" test in this
              // codebase (e.g. `topo_overflow_test.dart`): a `MediaQuery`
              // wrapped around the whole app via `MaterialApp.builder`.
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(3.0)),
                child: child!,
              ),
              home: Builder(
                builder: (context) {
                  capturedContext = context;
                  return const SizedBox();
                },
              ),
            ),
          ),
        );

        final pickerFuture = showSetLocationPicker(
          capturedContext,
          controller: controller,
          geocodingService: geocoding,
        );
        unawaited(pickerFuture);
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('set-location-search-field')),
          'result',
        );
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();

        expect(
          tester.takeException(),
          isNull,
          reason: 'a large text scale + long result names on a small '
              'viewport must never throw a layout (RenderFlex overflow) '
              'exception',
        );
        expect(
          find.byKey(const Key('set-location-search-result-0')),
          findsOneWidget,
        );

        // The dropdown's own scroll viewport must be clamped to its cap
        // (see `_SetLocationPickerState._searchResultsMaxHeight`) rather
        // than growing to fit all 5 two-line, 3x-scaled titles -- and
        // clamped exactly AT the cap is itself proof this scenario really
        // does exceed it (a shorter, unclamped list would report a height
        // strictly less than the cap instead).
        final listView = find.byType(ListView);
        expect(tester.getSize(listView).height, closeTo(260.0, 0.5));

        // Capped, not clipped: the tail result must still be reachable by
        // scrolling the dropdown's own list.
        await tester.scrollUntilVisible(
          find.byKey(const Key('set-location-search-result-4')),
          300.0,
          scrollable: find.descendant(
            of: listView,
            matching: find.byType(Scrollable),
          ),
        );
        expect(tester.takeException(), isNull);
        expect(
          find.byKey(const Key('set-location-search-result-4')),
          findsOneWidget,
          reason: 'the capped dropdown must remain scrollable -- the last '
              'result is reachable, not clipped away permanently',
        );
      },
    );
  });

  group('rotation is disabled on the set-location picker map', () {
    testWidgets(
      "the FlutterMap's InteractionOptions.flags excludes "
      'InteractiveFlag.rotate (an accidental two-finger twist must never '
      'spin the map), while the usual pan/zoom flags stay enabled',
      (tester) async {
        final controller = MapController();
        addTearDown(controller.dispose);
        final geocoding = _FakeGeocodingService(const []);

        final context = await _pumpHarness(tester);
        final pickerFuture = showSetLocationPicker(
          context,
          controller: controller,
          geocodingService: geocoding,
        );
        unawaited(pickerFuture);
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        final flutterMap = tester.widget<FlutterMap>(find.byType(FlutterMap));
        final flags = flutterMap.options.interactionOptions.flags;
        expect(InteractiveFlag.hasRotate(flags), isFalse);
        expect(InteractiveFlag.hasDrag(flags), isTrue);
        expect(InteractiveFlag.hasPinchZoom(flags), isTrue);
        expect(InteractiveFlag.hasPinchMove(flags), isTrue);
        expect(InteractiveFlag.hasDoubleTapZoom(flags), isTrue);
        expect(InteractiveFlag.hasScrollWheelZoom(flags), isTrue);
      },
    );
  });

  // Both waits on this screen were completely unannounced: a debounced network
  // place lookup, and a cold GPS fix that can take seconds.
  group('the picker reports its own waits', () {
    testWidgets('the search field shows a cue while the lookup is in flight, '
        'never during the debounce', (tester) async {
      final controller = MapController();
      addTearDown(controller.dispose);
      final geocoding = _FakeGeocodingService([_railay]);
      final slow = Completer<List<PlaceResult>>();
      geocoding.pending['railay'] = slow;

      final context = await _pumpHarness(tester);
      unawaited(
        showSetLocationPicker(
          context,
          controller: controller,
          geocodingService: geocoding,
        ),
      );
      await tester.pumpAndSettle();

      final cue = find.descendant(
        of: find.byKey(const Key('set-location-search-progress')),
        matching: find.byKey(MasiLoadingIndicator.spinnerKey),
      );

      await tester.enterText(
        find.byKey(const Key('set-location-search-field')),
        'railay',
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        cue,
        findsNothing,
        reason: '350ms of "searching…" on every keystroke pause is noise — the '
            'cue belongs to the lookup, not to the debounce',
      );

      // Past the debounce: the lookup is now genuinely in flight, but still
      // inside the reveal delay.
      await tester.pump(const Duration(milliseconds: 400));
      expect(geocoding.callCount, 1);
      expect(
        cue,
        findsNothing,
        reason: 'a lookup that answers inside the anti-flash window must paint '
            'no cue at all',
      );

      await tester.pump(const Duration(milliseconds: 250));
      expect(cue, findsOneWidget);

      slow.complete([_railay]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(cue, findsNothing);
      expect(
        find.byKey(const Key('set-location-search-result-0')),
        findsOneWidget,
      );
    });

    testWidgets('"use my location" reports the fix it is waiting on and takes '
        'exactly one tap', (tester) async {
      final controller = MapController();
      addTearDown(controller.dispose);
      final gate = Completer<DeviceLocation?>();
      final location = _GatedLocationService(gate);

      final context = await _pumpHarness(tester);
      unawaited(
        showSetLocationPicker(
          context,
          controller: controller,
          locationService: location,
        ),
      );
      await tester.pumpAndSettle();

      final fab = find.byKey(const Key('set-location-my-location'));
      final cue = find.descendant(
        of: find.byKey(const Key('set-location-locating')),
        matching: find.byKey(MasiLoadingIndicator.spinnerKey),
      );

      await tester.tap(fab);
      await tester.pump();
      expect(location.calls, 1);
      expect(cue, findsNothing, reason: 'anti-flash window');

      await tester.pump(const Duration(milliseconds: 250));
      expect(cue, findsOneWidget);
      expect(
        tester.widget<FloatingActionButton>(fab).onPressed,
        isNull,
        reason: 'every impatient re-tap used to start another concurrent fix, '
            'whose late answer could yank the camera off a position the user '
            'had since panned to by hand',
      );

      await tester.tap(fab, warnIfMissed: false);
      await tester.pump();
      expect(location.calls, 1);

      gate.complete((latitude: 8.0104, longitude: 98.8375));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(cue, findsNothing);
      expect(
        tester.widget<FloatingActionButton>(fab).onPressed,
        isNotNull,
      );
      expect(controller.camera.center.latitude, closeTo(8.0104, 1e-4));
    });
  });
}
