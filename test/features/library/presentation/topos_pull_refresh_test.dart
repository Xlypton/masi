// Pull-to-refresh on the Topos home — in EVERY state, not just the populated
// one.
//
// The Feed and both moderation lists have had this for a while; the landing
// screen, which is also the screen that renders the sync banner, had nothing but
// a Retry button that only exists once a pull error has been recorded. So the
// user whose library came up stale or empty had no way to ask again.
//
// The trap the owner called out, and what most of this file is about: the Topos
// home returns one of seven things from the same slot, and SIX of them are not
// the list — four empty states, the first-load skeleton, and `MasiAsyncView`'s
// hard error. A `RefreshIndicator` wrapped around `_ToposList` would therefore
// arm the gesture in the one state where the user least needs it and kill it in
// every state where they most do. Each state is asserted separately below for
// that reason.
//
// TEST TRAP (documented in `community_pull_refresh_test.dart` and again on
// `_ToposRefreshScope.indicatorKey`): a `RefreshIndicator` occupies its whole
// child's box, so `tester.tap(find.byKey(...))` on it lands on whatever sits
// mid-list. The gesture is always driven with a `fling` on the state's OWN
// scroll view.

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/backup/application/backup_providers.dart';
import 'package:masi/features/backup/application/sync_orchestrator.dart';
import 'package:masi/features/backup/data/connectivity_service.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/library/data/library_crud_repository.dart';
import 'package:masi/features/library/presentation/areas_screen.dart';
import 'package:masi/features/library/presentation/sectors_screen.dart';
import 'package:masi/features/library/presentation/topos_screen.dart';
import 'package:masi/features/library/presentation/walls_screen.dart';
import 'package:masi/shared/presentation/masi_async_view.dart';

import '../../../support/async_drain.dart';

/// Counts [pullNow] calls and nothing else — the presentation layer only needs
/// the pull to have been asked for. [initialState] lets a test start out already
/// carrying a `lastPullError` so the sync-error empty state renders.
class _FakeSyncOrchestrator extends SyncOrchestrator {
  _FakeSyncOrchestrator({SyncOrchestratorState? initialState})
    : _initialState = initialState ?? const SyncOrchestratorState();

  final SyncOrchestratorState _initialState;
  int pullNowCallCount = 0;

  @override
  SyncOrchestratorState build() => _initialState;

  @override
  Future<void> pullNow({bool throttled = false}) async {
    pullNowCallCount++;
  }
}

class _ScriptedConnectivity implements ConnectivityService {
  _ScriptedConnectivity({required this.reachable});

  final bool reachable;

  @override
  Future<bool> isBackendReachable() async => reachable;

  @override
  Future<NetworkStatus> currentStatus() async => NetworkStatus.wifi;

  @override
  Stream<NetworkStatus> statusChanges() => const Stream.empty();
}

const _oneTopo = [
  TopoRef(
    wallId: 'w-1',
    name: 'Warm Up Slab',
    thumbnailPath: null,
    routeCount: 1,
    createdAt: 1000,
    routeStars: [1],
  ),
];

ProviderContainer _makeContainer({
  required _FakeSyncOrchestrator orchestrator,
  List<TopoRef>? topos,
  bool failTopos = false,
  bool reachable = true,
}) {
  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final container = ProviderContainer(
    // Without this a deliberately-always-failing `toposProvider` sits in
    // `AsyncLoading(error: ...)` for several seconds of Riverpod's exponential
    // backoff rather than reaching a terminal `AsyncError`.
    retry: failTopos ? (retryCount, error) => null : null,
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      nowMsProvider.overrideWithValue(() => 1000),
      connectivityServiceProvider.overrideWithValue(
        _ScriptedConnectivity(reachable: reachable),
      ),
      syncOrchestratorProvider.overrideWith(() => orchestrator),
      if (failTopos)
        toposProvider.overrideWith(
          (ref) => Stream<List<TopoRef>>.error(Exception('boom-drift')),
        )
      else
        toposProvider.overrideWith((ref) => Stream.value(topos ?? const [])),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Widget _wrap(ProviderContainer container, Widget screen) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (context, state) => screen),
      GoRoute(
        path: '/walls/:wallId',
        builder: (context, state) => const SizedBox(),
      ),
      GoRoute(path: '/areas', builder: (context, state) => const SizedBox()),
      GoRoute(
        path: '/areas/:areaId/sectors',
        builder: (context, state) => const SizedBox(),
      ),
      GoRoute(
        path: '/sectors/:sectorId/walls',
        builder: (context, state) => const SizedBox(),
      ),
      GoRoute(path: '/account', builder: (context, state) => const SizedBox()),
    ],
  );
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(theme: MasiTheme.light, routerConfig: router),
  );
}

Future<void> _drain(WidgetTester tester) async {
  await drainAsync(tester, rounds: 6, settle: false);
  await tester.pumpAndSettle();
}

/// The scroll view belonging to a specific empty state, scoped by that state's
/// own key rather than by `find.byType`.
///
/// `SingleChildScrollView` is not unique on this screen once a [SyncBanner] is
/// also on it, so a bare type finder resolves to two widgets and the gesture
/// would be aimed at whichever came first. `_EmptyStateShell` puts the state key
/// on the ancestor `LayoutBuilder`, so this resolves the right one every time.
Finder _emptyStateScrollView(Key stateKey) => find.descendant(
  of: find.byKey(stateKey),
  matching: find.byType(SingleChildScrollView),
);

/// The repo's pull-to-refresh idiom: a downward `fling` on the state's OWN
/// scroll view (never a tap on the indicator's key — see this file's header),
/// then the pumps that let the indicator run its callback.
Future<void> _pullToRefresh(WidgetTester tester, Finder scrollView) async {
  expect(
    scrollView,
    findsOneWidget,
    reason:
        'the state under test must expose exactly one scroll view for the '
        'gesture to act on',
  );
  await tester.fling(scrollView, const Offset(0, 300), 1000);
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  await _drain(tester);
}

void main() {
  group('the Topos home re-pulls on a pull-to-refresh', () {
    testWidgets('POPULATED: dragging the list down calls pullNow()', (
      tester,
    ) async {
      final orchestrator = _FakeSyncOrchestrator();
      final container = _makeContainer(
        orchestrator: orchestrator,
        topos: _oneTopo,
      );
      await tester.pumpWidget(_wrap(container, const ToposScreen()));
      await _drain(tester);

      expect(find.byKey(const Key('topo-item-w-1')), findsOneWidget);
      expect(find.byType(RefreshIndicator), findsOneWidget);
      expect(orchestrator.pullNowCallCount, 0);

      await _pullToRefresh(tester, find.byType(ListView));

      expect(tester.takeException(), isNull);
      expect(orchestrator.pullNowCallCount, 1);
    });

    testWidgets(
      'EMPTY (no topos, online, no error): the "No topos yet" state is still '
      'overscroll-able',
      (tester) async {
        final orchestrator = _FakeSyncOrchestrator();
        final container = _makeContainer(orchestrator: orchestrator);
        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        expect(find.byKey(const Key('topos-empty-state')), findsOneWidget);

        await _pullToRefresh(
          tester,
          _emptyStateScrollView(const Key('topos-empty-state')),
        );

        expect(tester.takeException(), isNull);
        expect(orchestrator.pullNowCallCount, 1);
      },
    );

    testWidgets('EMPTY + a recorded pull error: the sync-error state too', (
      tester,
    ) async {
      final orchestrator = _FakeSyncOrchestrator(
        initialState: const SyncOrchestratorState(
          lastPullError: 'Sync failed: own rows fetch failed',
        ),
      );
      final container = _makeContainer(orchestrator: orchestrator);
      await tester.pumpWidget(_wrap(container, const ToposScreen()));
      await _drain(tester);

      expect(find.byKey(const Key('topos-sync-error-empty')), findsOneWidget);

      await _pullToRefresh(
        tester,
        _emptyStateScrollView(const Key('topos-sync-error-empty')),
      );

      expect(tester.takeException(), isNull);
      expect(orchestrator.pullNowCallCount, 1);
    });

    testWidgets('EMPTY + offline: the offline state too', (tester) async {
      final orchestrator = _FakeSyncOrchestrator();
      final container = _makeContainer(
        orchestrator: orchestrator,
        reachable: false,
      );
      await tester.pumpWidget(_wrap(container, const ToposScreen()));
      await _drain(tester);

      expect(find.byKey(const Key('topos-offline-empty')), findsOneWidget);

      // Offline is exactly the state a manual pull must still reach: the probe
      // can be wrong (a captive portal that has since let go), so the gesture
      // asks the network rather than trusting the last verdict.
      await _pullToRefresh(
        tester,
        _emptyStateScrollView(const Key('topos-offline-empty')),
      );

      expect(tester.takeException(), isNull);
      expect(orchestrator.pullNowCallCount, 1);
    });

    testWidgets('SEARCH-narrowed to nothing: that empty state too', (
      tester,
    ) async {
      final orchestrator = _FakeSyncOrchestrator();
      final container = _makeContainer(
        orchestrator: orchestrator,
        topos: _oneTopo,
      );
      await tester.pumpWidget(_wrap(container, const ToposScreen()));
      await _drain(tester);

      await tester.enterText(
        find.byKey(const Key('topos-search-field')),
        'nothing-matches-this',
      );
      await _drain(tester);
      expect(find.byKey(const Key('topos-search-empty-state')), findsOneWidget);

      await _pullToRefresh(
        tester,
        _emptyStateScrollView(const Key('topos-search-empty-state')),
      );

      expect(tester.takeException(), isNull);
      expect(orchestrator.pullNowCallCount, 1);
    });

    testWidgets('FILTER-narrowed to nothing: that empty state too', (
      tester,
    ) async {
      final orchestrator = _FakeSyncOrchestrator();
      final container = _makeContainer(
        orchestrator: orchestrator,
        topos: _oneTopo,
      );
      await tester.pumpWidget(_wrap(container, const ToposScreen()));
      await _drain(tester);

      // A 3-star minimum against a 1-star topo excludes everything.
      await tester.tap(find.byKey(const Key('topos-filter-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('filter-minstars-3')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('topos-filter-done')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('topos-filtered-empty-state')),
        findsOneWidget,
      );

      await _pullToRefresh(
        tester,
        _emptyStateScrollView(const Key('topos-filtered-empty-state')),
      );

      expect(tester.takeException(), isNull);
      expect(orchestrator.pullNowCallCount, 1);
    });

    testWidgets('ERROR (toposProvider failed hard, no cached value): the '
        '"Couldn\'t load your topos" state is overscroll-able as well — a state '
        'with no scroll view of its own is given one', (tester) async {
      final orchestrator = _FakeSyncOrchestrator();
      final container = _makeContainer(
        orchestrator: orchestrator,
        failTopos: true,
      );
      await tester.pumpWidget(_wrap(container, const ToposScreen()));
      await _drain(tester);

      expect(find.byKey(MasiAsyncView.errorKey), findsOneWidget);

      await _pullToRefresh(tester, find.byType(SingleChildScrollView));

      expect(tester.takeException(), isNull);
      expect(
        orchestrator.pullNowCallCount,
        1,
        reason:
            'a hard load error is the state where a re-pull is the only '
            'sensible action; it must not be the one state that cannot ask '
            'for one',
      );
    });

    testWidgets(
      'POPULATED with the offline sync banner above it (i.e. through the '
      'NestedScrollView the banner introduces) still refreshes',
      (tester) async {
        final orchestrator = _FakeSyncOrchestrator();
        final container = _makeContainer(
          orchestrator: orchestrator,
          topos: _oneTopo,
          reachable: false,
        );
        await tester.pumpWidget(_wrap(container, const ToposScreen()));
        await _drain(tester);

        expect(find.byType(NestedScrollView), findsOneWidget);
        expect(find.byKey(const Key('topo-item-w-1')), findsOneWidget);

        await _pullToRefresh(tester, find.byType(ListView));

        expect(tester.takeException(), isNull);
        expect(orchestrator.pullNowCallCount, 1);
      },
    );
  });

  group('Areas/Sectors/Walls are untouched — they are purely local', () {
    testWidgets('AreasScreen has no refresh gesture', (tester) async {
      final orchestrator = _FakeSyncOrchestrator();
      final container = _makeContainer(orchestrator: orchestrator);
      await tester.pumpWidget(_wrap(container, const AreasScreen()));
      await _drain(tester);

      expect(find.byType(RefreshIndicator), findsNothing);
    });

    testWidgets('SectorsScreen has no refresh gesture', (tester) async {
      final orchestrator = _FakeSyncOrchestrator();
      final container = _makeContainer(orchestrator: orchestrator);
      await tester.pumpWidget(
        _wrap(container, const SectorsScreen(areaId: 'a-1')),
      );
      await _drain(tester);

      expect(find.byType(RefreshIndicator), findsNothing);
    });

    testWidgets('WallsScreen has no refresh gesture', (tester) async {
      final orchestrator = _FakeSyncOrchestrator();
      final container = _makeContainer(orchestrator: orchestrator);
      await tester.pumpWidget(
        _wrap(container, const WallsScreen(sectorId: 's-1')),
      );
      await _drain(tester);

      expect(find.byType(RefreshIndicator), findsNothing);
    });
  });
}
