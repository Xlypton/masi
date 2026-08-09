import 'dart:convert';

import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/backup/application/sync_orchestrator.dart';
import 'package:masi/features/community/application/community_providers.dart';
import 'package:masi/features/community/data/community_repository.dart';
import 'package:masi/features/community/presentation/community_screen.dart';
import 'package:masi/shared/presentation/masi_async_view.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import '../../../support/async_drain.dart';

/// #57 fix: the Community Feed/Map's manual refresh affordances
/// (`community-feed-refresh`'s `RefreshIndicator`, `community-map-refresh`'s
/// button, and `MasiAsyncView`'s "Try again") must all re-run the
/// REAL remote pull (`SyncOrchestrator.pullNow`) rather than just re-running
/// a LOCAL Drift re-query — the original bug was that nothing besides
/// sign-in ever called `pullOwnAndShared()` at all, so a local-only
/// invalidate could never have recovered from data that was simply never
/// pulled. Kept as its own file (mirrors `community_feed_union_test.dart`'s
/// stated rationale) rather than folded into the already-huge
/// `community_screen_test.dart`.

/// A minimal-but-real 1x1 transparent PNG (base64), duplicated locally from
/// `community_screen_test.dart`'s identically-named constant — used as the
/// tile every fake tile "loads", so `CommunityMapScreen`'s `TileLayer` never
/// attempts a real network fetch under `flutter_test`.
final _tinyPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY'
  '42YAAAAASUVORK5CYII=',
);

/// Duplicated locally from `community_screen_test.dart`'s
/// `_NoopTileProvider`: every tile request resolves synchronously to the
/// same tiny in-memory image, never performing real network/file I/O.
class _NoopTileProvider extends TileProvider {
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    return MemoryImage(_tinyPngBytes);
  }
}

/// A [SyncOrchestrator] test double that skips ALL of the real class's
/// wiring (`build()`'s `ref.watch(appDatabaseProvider)` /
/// `ref.listen(authStateProvider, ...)` / `tableUpdates()` subscription) and
/// just counts [pullNow] calls — the community presentation layer only ever
/// needs `pullNow()` to have been invoked; it does not need (and, for a
/// widget test, should not have to wire up) the real push/pull machinery
/// `sync_orchestrator_test.dart`/`app_test.dart` already cover directly.
///
/// [initialState] (#72 P1 fix's `_SyncErrorEmptyState` group below) lets a
/// test start the orchestrator already carrying a
/// [SyncOrchestratorState.lastPullError] — every pre-existing call site
/// here omits it and gets the exact same default `SyncOrchestratorState()`
/// as before.
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

/// Builds a [ProviderContainer] wired to a fresh in-memory database, with
/// [syncOrchestratorProvider] overridden to [fakeOrchestrator] so this
/// file's tests can assert on [_FakeSyncOrchestrator.pullNowCallCount].
/// Mirrors `community_screen_test.dart`'s `_makeContainer` shape.
ProviderContainer _makeContainer({
  required _FakeSyncOrchestrator fakeOrchestrator,
  bool failSharedTopos = false,
}) {
  final db = AppDatabase(NativeDatabase.memory());
  final container = ProviderContainer(
    // See `community_screen_test.dart`'s identical override + rationale:
    // without disabling retry, a deliberately-always-failing
    // `sharedToposProvider` override sits in `AsyncLoading(error: ...)`
    // (spinner) rather than a terminal `AsyncError` for several seconds of
    // exponential-backoff auto-retry, well past this test's short `_drain`
    // window.
    retry: failSharedTopos ? (retryCount, error) => null : null,
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      nowMsProvider.overrideWithValue(() => 1000),
      syncOrchestratorProvider.overrideWith(() => fakeOrchestrator),
      if (failSharedTopos)
        sharedToposProvider.overrideWith(
          (ref) => Stream<List<SharedTopo>>.error(Exception('boom-network')),
        ),
    ],
  );
  addTearDown(db.close);
  addTearDown(container.dispose);
  return container;
}

/// Wraps [screen] in a real (minimal) [GoRouter] — mirrors
/// `community_screen_test.dart`'s `_wrap`.
Widget _wrap(ProviderContainer container, Widget screen) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (context, state) => screen),
      GoRoute(
        path: '/community/topo/:wallId',
        builder: (context, state) => const SizedBox(),
      ),
    ],
  );
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(theme: MasiTheme.light, routerConfig: router),
  );
}

/// Mirrors `community_screen_test.dart`'s `_drain`: advances real
/// asynchronous Drift work alongside fake-clock pumps.
Future<void> _drain(WidgetTester tester) async {
  await drainAsync(tester, rounds: 6, settle: false);
}

void main() {
  group('#57: CommunityFeedScreen pull-to-refresh', () {
    testWidgets(
      'dragging the feed list down calls pullNow() on the orchestrator',
      (tester) async {
        final fakeOrchestrator = _FakeSyncOrchestrator();
        final container = _makeContainer(fakeOrchestrator: fakeOrchestrator);
        final db = container.read(appDatabaseProvider);

        // One shared topo, so the Feed renders its real (non-empty)
        // scrollable row-list branch rather than the empty-state
        // branch — either is a valid `RefreshIndicator` target after this
        // fix, but the non-empty branch is the common case.
        await tester.runAsync(() async {
          await db.into(db.areas).insert(
            AreasCompanion.insert(id: 'area-1', createdAt: 1000, updatedAt: 1000, name: 'Area'),
          );
          await db.into(db.sectors).insert(
            SectorsCompanion.insert(
              id: 'sector-1',
              createdAt: 1000,
              updatedAt: 1000,
              areaId: 'area-1',
              name: 'Sector',
              sortOrder: 0,
            ),
          );
          await db.into(db.walls).insert(
            WallsCompanion.insert(
              id: 'wall-1',
              createdAt: 1000,
              updatedAt: 1000,
              sectorId: 'sector-1',
              name: 'Shared Wall',
              sortOrder: 0,
              visibility: const Value('shared'),
            ),
          );
        });

        await tester.pumpWidget(_wrap(container, const CommunityFeedScreen()));
        await _drain(tester);

        expect(
          find.byKey(const Key('community-topo-row-wall-1')),
          findsOneWidget,
        );
        expect(find.byType(RefreshIndicator), findsOneWidget);
        expect(fakeOrchestrator.pullNowCallCount, 0);

        // A `CustomScrollView`, not a `ListView`: the feed is now ONE scroll
        // view for every state, so the sync/offline banner can be its first
        // sliver rather than an unreclaimable header above it (see
        // `SyncBanner`'s doc). The `RefreshIndicator` and its
        // `AlwaysScrollableScrollPhysics` are unchanged.
        await tester.fling(
          find.byType(CustomScrollView),
          const Offset(0, 300),
          1000,
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await _drain(tester);

        expect(tester.takeException(), isNull);
        expect(fakeOrchestrator.pullNowCallCount, 1);
      },
    );

    testWidgets(
      'dragging the EMPTY feed list still calls pullNow() (the empty '
      'state remains overscroll-able)',
      (tester) async {
        final fakeOrchestrator = _FakeSyncOrchestrator();
        final container = _makeContainer(fakeOrchestrator: fakeOrchestrator);

        await tester.pumpWidget(_wrap(container, const CommunityFeedScreen()));
        await _drain(tester);

        expect(find.byKey(const Key('community-empty')), findsOneWidget);

        // Same `CustomScrollView` in the empty branch — that ONE scroll view
        // hosting every state is exactly what keeps the banner from vanishing
        // here.
        await tester.fling(
          find.byType(CustomScrollView),
          const Offset(0, 300),
          1000,
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await _drain(tester);

        expect(tester.takeException(), isNull);
        expect(fakeOrchestrator.pullNowCallCount, 1);
      },
    );
  });

  group('#57: CommunityMapScreen manual refresh button', () {
    testWidgets(
      'tapping community-map-refresh calls pullNow() on the orchestrator',
      (tester) async {
        final fakeOrchestrator = _FakeSyncOrchestrator();
        final container = _makeContainer(fakeOrchestrator: fakeOrchestrator);

        await tester.pumpWidget(
          _wrap(
            container,
            CommunityMapScreen(tileProvider: _NoopTileProvider()),
          ),
        );
        await _drain(tester);

        expect(find.byKey(const Key('community-map-refresh')), findsOneWidget);
        expect(fakeOrchestrator.pullNowCallCount, 0);

        await tester.tap(find.byKey(const Key('community-map-refresh')));
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(fakeOrchestrator.pullNowCallCount, 1);

        // A second tap starts another pull too (not a one-shot control).
        await tester.tap(find.byKey(const Key('community-map-refresh')));
        await tester.pump();
        expect(fakeOrchestrator.pullNowCallCount, 2);
      },
    );
  });

  group('#57: MasiAsyncView\'s "Try again" pulls before invalidating', () {
    testWidgets(
      "CommunityFeedScreen's Try again calls pullNow() on the orchestrator "
      '(not just a local re-query)',
      (tester) async {
        final fakeOrchestrator = _FakeSyncOrchestrator();
        final container = _makeContainer(
          fakeOrchestrator: fakeOrchestrator,
          failSharedTopos: true,
        );

        await tester.pumpWidget(_wrap(container, const CommunityFeedScreen()));
        await _drain(tester);

        expect(
          find.byKey(MasiAsyncView.errorKey),
          findsOneWidget,
        );
        expect(fakeOrchestrator.pullNowCallCount, 0);

        await tester.tap(find.byKey(MasiAsyncView.retryKey));
        await _drain(tester);

        expect(tester.takeException(), isNull);
        expect(
          fakeOrchestrator.pullNowCallCount,
          1,
          reason: '"Try again" must trigger a real remote pull, not just '
              'invalidate the (still-failing) local provider',
        );
        // The override still errors on re-fetch, so the friendly error
        // state simply re-renders rather than crashing — mirrors
        // `community_screen_test.dart`'s identical assertion.
        expect(
          find.byKey(MasiAsyncView.errorKey),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      "CommunityMapScreen's Try again calls pullNow() on the orchestrator "
      '(not just a local re-query)',
      (tester) async {
        final fakeOrchestrator = _FakeSyncOrchestrator();
        final container = _makeContainer(
          fakeOrchestrator: fakeOrchestrator,
          failSharedTopos: true,
        );

        await tester.pumpWidget(
          _wrap(
            container,
            CommunityMapScreen(tileProvider: _NoopTileProvider()),
          ),
        );
        await _drain(tester);

        expect(
          find.byKey(MasiAsyncView.errorKey),
          findsOneWidget,
        );

        await tester.tap(find.byKey(MasiAsyncView.retryKey));
        await _drain(tester);

        expect(tester.takeException(), isNull);
        expect(fakeOrchestrator.pullNowCallCount, 1);
      },
    );
  });

  group('#72: CommunityFeedScreen sync-error empty state', () {
    testWidgets(
      'a genuinely empty feed with a lastPullError renders the '
      "sync-error affordance (not the plain 'No shared topos yet' "
      'message), and tapping Retry calls pullNow()',
      (tester) async {
        final fakeOrchestrator = _FakeSyncOrchestrator(
          initialState: const SyncOrchestratorState(
            lastPullError:
                'Sync failed: shared topos fetch failed: Exception: boom',
          ),
        );
        final container = _makeContainer(fakeOrchestrator: fakeOrchestrator);

        await tester.pumpWidget(_wrap(container, const CommunityFeedScreen()));
        await _drain(tester);

        expect(
          find.byKey(const Key('community-sync-error-empty')),
          findsOneWidget,
          reason: 'a genuinely empty feed with a reported pull error must '
              'show the sync-error affordance instead of the plain empty '
              'state',
        );
        expect(find.byKey(const Key('community-empty')), findsNothing);
        expect(
          find.textContaining(
            'Sync failed: shared topos fetch failed: Exception: boom',
          ),
          findsOneWidget,
          reason: 'the actual PullResult.errors text must be readable '
              'on-device without a debugger',
        );
        expect(
          find.byKey(const Key('community-sync-error-retry')),
          findsOneWidget,
        );

        expect(fakeOrchestrator.pullNowCallCount, 0);
        await tester.tap(find.byKey(const Key('community-sync-error-retry')));
        await tester.pump();

        expect(fakeOrchestrator.pullNowCallCount, 1);
      },
    );

    testWidgets(
      'a genuinely empty feed with NO lastPullError renders the normal '
      'empty state (no sync-error affordance)',
      (tester) async {
        final fakeOrchestrator = _FakeSyncOrchestrator();
        final container = _makeContainer(fakeOrchestrator: fakeOrchestrator);

        await tester.pumpWidget(_wrap(container, const CommunityFeedScreen()));
        await _drain(tester);

        expect(find.byKey(const Key('community-empty')), findsOneWidget);
        expect(find.text('No shared topos yet'), findsOneWidget);
        expect(
          find.byKey(const Key('community-sync-error-empty')),
          findsNothing,
        );
      },
    );
  });
}
