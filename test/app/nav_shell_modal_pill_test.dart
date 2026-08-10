// The floating nav pill must get out of the way of a modal sheet — and must
// come back by EVERY route out of that sheet.
//
// The reported bug: the pill lives in `Scaffold.bottomNavigationBar`, a sibling
// of the branch content, so a `showModalBottomSheet` opened from a branch
// screen (which defaults to that branch's own navigator, i.e. INSIDE the
// shell's body) could not cover it — the pill floated on top of the Filters
// sheet. The fix is two-sided: the sheet is pushed on the ROOT navigator
// (`useRootNavigator: true`, `topos_filter.dart`), and `NavShell` hides the pill
// while it is not the frontmost route (`ModalRoute.of(context)!.isCurrent`).
//
// The point of testing all four exits separately is that the signal must be
// DERIVED, not a flag: a flag that some path forgot to clear would leave the
// pill hidden for the rest of the session, which is strictly worse than the bug
// it replaced. A real `StatefulNavigationShell` + a real root navigator is
// therefore load-bearing here — this cannot be proven against a hand-built
// stand-in for `NavShell.build`.

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:masi/app/nav_shell.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/core/db/storage_durability_provider.dart';
import 'package:masi/features/backup/application/backup_providers.dart';
import 'package:masi/features/backup/application/sync_orchestrator.dart';
import 'package:masi/features/backup/data/connectivity_service.dart';
import 'package:masi/features/community/application/feed_freshness_providers.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/library/data/library_crud_repository.dart';
import 'package:masi/features/library/presentation/topos_screen.dart';

import '../support/async_drain.dart';

class _FakeStorageDurability extends StorageDurabilityNotifier {
  @override
  StorageDurability build() =>
      const StorageDurability(backend: StorageBackend.opfsLocks);
}

/// Skips the real orchestrator's `tableUpdates()` subscription, which would
/// otherwise schedule a 2 s debounce `Timer` that outlives the test. Mirrors the
/// identical file-private double in `nav_feed_dot_test.dart`.
class _FakeSyncOrchestrator extends SyncOrchestrator {
  @override
  SyncOrchestratorState build() => const SyncOrchestratorState();

  @override
  Future<void> pullNow({bool throttled = false}) async {}
}

class _ReachableConnectivity implements ConnectivityService {
  @override
  Future<bool> isBackendReachable() async => true;

  @override
  Future<NetworkStatus> currentStatus() async => NetworkStatus.wifi;

  @override
  Stream<NetworkStatus> statusChanges() => const Stream.empty();
}

ProviderContainer _makeContainer() {
  final db = AppDatabase(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      nowMsProvider.overrideWithValue(() => 1000),
      connectivityServiceProvider.overrideWithValue(_ReachableConnectivity()),
      syncOrchestratorProvider.overrideWith(_FakeSyncOrchestrator.new),
      storageDurabilityProvider.overrideWith(_FakeStorageDurability.new),
      feedHasUnseenProvider.overrideWithValue(false),
      toposProvider.overrideWith(
        (ref) => Stream.value(const [
          TopoRef(
            wallId: 'w-1',
            name: 'Warm Up Slab',
            thumbnailPath: null,
            routeCount: 1,
            createdAt: 1000,
          ),
        ]),
      ),
    ],
  );
  addTearDown(db.close);
  addTearDown(container.dispose);
  return container;
}

/// A REAL three-branch `StatefulShellRoute.indexedStack` (mirrors
/// `nav_feed_dot_test.dart`'s harness) with the REAL [ToposScreen] in the first
/// branch, because the sheet under test is opened from it.
Widget _wrap(ProviderContainer container) {
  final router = GoRouter(
    initialLocation: '/topos',
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => NavShell(navigationShell: shell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/topos',
                builder: (context, state) => const ToposScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/map',
                builder: (context, state) => const Scaffold(body: SizedBox()),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/feed',
                builder: (context, state) => const Scaffold(body: SizedBox()),
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: '/walls/:wallId',
        builder: (context, state) => const Scaffold(body: SizedBox()),
      ),
      GoRoute(
        path: '/areas',
        builder: (context, state) => const Scaffold(body: SizedBox()),
      ),
      GoRoute(
        path: '/account',
        builder: (context, state) => const Scaffold(body: SizedBox()),
      ),
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

/// Reads the pill's visibility off the derived signal itself — the tabs stay in
/// the tree while hidden (`maintainState`, so the branch layout does not
/// reflow), which is exactly why a `findsNothing` on a tab key would prove
/// nothing here. See [NavShell.navBarVisibilityKey].
bool _pillVisible(WidgetTester tester) =>
    tester.widget<Visibility>(find.byKey(NavShell.navBarVisibilityKey)).visible;

Future<void> _openFiltersSheet(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('topos-filter-button')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the pill is visible on a plain Topos home', (tester) async {
    final container = _makeContainer();
    await tester.pumpWidget(_wrap(container));
    await _drain(tester);

    expect(find.byKey(const Key('nav-tab-topos')), findsOneWidget);
    expect(_pillVisible(tester), isTrue);
  });

  testWidgets('the pill is hidden while the Filters sheet is up', (
    tester,
  ) async {
    final container = _makeContainer();
    await tester.pumpWidget(_wrap(container));
    await _drain(tester);

    await _openFiltersSheet(tester);

    expect(find.byKey(const Key('topos-filter-visibility')), findsOneWidget);
    expect(
      _pillVisible(tester),
      isFalse,
      reason: 'the sheet fills the screen; the pill must not float over it',
    );
    // The bar keeps its SPACE (only its paint and hit-testing go away), so the
    // branch content underneath does not reflow and reflow back.
    expect(find.byKey(const Key('nav-tab-topos')), findsOneWidget);
  });

  group('the pill comes back by every route out of the sheet', () {
    testWidgets('Done', (tester) async {
      final container = _makeContainer();
      await tester.pumpWidget(_wrap(container));
      await _drain(tester);

      await _openFiltersSheet(tester);
      expect(_pillVisible(tester), isFalse);

      await tester.tap(find.byKey(const Key('topos-filter-done')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('topos-filter-visibility')), findsNothing);
      expect(_pillVisible(tester), isTrue);
    });

    testWidgets('a tap on the scrim', (tester) async {
      final container = _makeContainer();
      await tester.pumpWidget(_wrap(container));
      await _drain(tester);

      await _openFiltersSheet(tester);
      expect(_pillVisible(tester), isFalse);

      // The barrier is the full-screen `ModalBarrier` the sheet route inserts;
      // tapping near the very top of the screen lands on it rather than on the
      // sheet surface. (`tester.tapAt` on an absolute offset, not a widget
      // finder: the sheet's own surface sits under most of the screen.)
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('topos-filter-visibility')), findsNothing);
      expect(_pillVisible(tester), isTrue);
    });

    testWidgets('the Android/browser back gesture', (tester) async {
      final container = _makeContainer();
      await tester.pumpWidget(_wrap(container));
      await _drain(tester);

      await _openFiltersSheet(tester);
      expect(_pillVisible(tester), isFalse);

      // The system back button/gesture, i.e. what a browser's Back and
      // Android's back gesture both arrive as.
      final handled = await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(handled, isTrue);
      expect(find.byKey(const Key('topos-filter-visibility')), findsNothing);
      expect(_pillVisible(tester), isTrue);
    });
  });

  testWidgets(
    'the pill stays hidden after tapping Clear (the sheet is still up)',
    (tester) async {
      final container = _makeContainer();
      await tester.pumpWidget(_wrap(container));
      await _drain(tester);

      await _openFiltersSheet(tester);
      expect(_pillVisible(tester), isFalse);

      await tester.tap(find.byKey(const Key('topos-filter-clear')));
      await tester.pumpAndSettle();

      // Clear only resets facets now — it is not a route out of the sheet —
      // so the sheet is still up and the pill must stay hidden underneath it.
      expect(
        find.byKey(const Key('topos-filter-visibility')),
        findsOneWidget,
      );
      expect(
        _pillVisible(tester),
        isFalse,
        reason:
            'Clear no longer dismisses the sheet; a regression here would '
            'let the pill float back over an open sheet',
      );
    },
  );
}
