// The Feed tab's unseen dot, over a REAL `NavShell` and a real
// `StatefulNavigationShell`.
//
// A minimal three-branch router rather than the app's own `appRouter`: the dot
// lives entirely in `NavShell`'s bottom bar, and pulling in the real branch
// screens would drag half the app's providers into a test about one 9 px
// circle. `feedHasUnseenProvider` is overridden for most of these for the same
// reason — WHAT it derives its answer from is covered against the pure
// functions in `test/features/community/domain/feed_freshness_test.dart`;
// what matters here is the shell's behaviour around it.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:masi/app/nav_shell.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/core/db/settings_store.dart';
import 'package:masi/core/db/storage_durability_provider.dart';
import 'package:masi/features/backup/application/sync_orchestrator.dart';
import 'package:masi/features/community/application/feed_freshness_providers.dart';

class _FakeStorageDurability extends StorageDurabilityNotifier {
  @override
  StorageDurability build() =>
      const StorageDurability(backend: StorageBackend.opfsLocks);
}

/// Skips the real orchestrator's `tableUpdates()` subscription, which would
/// otherwise schedule a 2s debounce `Timer` that outlives the test and trips
/// flutter_test's "A Timer is still pending" teardown assertion. Mirrors the
/// identical file-private double in `nav_shell_test.dart`.
class _FakeSyncOrchestrator extends SyncOrchestrator {
  @override
  SyncOrchestratorState build() => const SyncOrchestratorState();

  @override
  Future<void> pullNow({bool throttled = false}) async {}
}

void main() {
  ProviderContainer makeContainer({
    bool? hasUnseen,
    int Function()? clock,
  }) {
    final db = AppDatabase(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        nowMsProvider.overrideWithValue(clock ?? () => 1000),
        syncOrchestratorProvider.overrideWith(_FakeSyncOrchestrator.new),
        storageDurabilityProvider.overrideWith(_FakeStorageDurability.new),
        if (hasUnseen != null)
          feedHasUnseenProvider.overrideWithValue(hasUnseen),
      ],
    );
    addTearDown(db.close);
    addTearDown(container.dispose);
    return container;
  }

  Widget wrap(ProviderContainer container, {String initial = '/topos'}) {
    final router = GoRouter(
      initialLocation: initial,
      routes: [
        StatefulShellRoute.indexedStack(
          builder: (context, state, shell) => NavShell(navigationShell: shell),
          branches: [
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/topos',
                  builder: (context, state) => const Scaffold(body: SizedBox()),
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
      ],
    );
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(theme: MasiTheme.light, routerConfig: router),
    );
  }

  const dot = Key('nav-tab-feed-dot');

  testWidgets('appears when there is something new and you are elsewhere', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(makeContainer(hasUnseen: true)));
    await tester.pumpAndSettle();

    expect(find.byKey(dot), findsOneWidget);
  });

  testWidgets('is absent when there is nothing new', (tester) async {
    await tester.pumpWidget(wrap(makeContainer(hasUnseen: false)));
    await tester.pumpAndSettle();

    expect(find.byKey(dot), findsNothing);
  });

  testWidgets(
    'never shows while you are ALREADY on the Feed — that tab is showing you '
    'the very thing the dot would point at',
    (tester) async {
      await tester.pumpWidget(
        wrap(makeContainer(hasUnseen: true), initial: '/feed'),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(dot), findsNothing);
    },
  );

  testWidgets('tapping the Feed tab stamps the baseline', (tester) async {
    final container = makeContainer(clock: () => 5000);

    await tester.pumpWidget(wrap(container));
    await tester.pumpAndSettle();
    expect(
      container.read(feedLastSeenProvider),
      isNull,
      reason: 'a device that has never opened the Feed has no baseline',
    );

    await tester.tap(find.byKey(const Key('nav-tab-feed')));
    await tester.pumpAndSettle();

    expect(container.read(feedLastSeenProvider), 5000);
  });

  testWidgets(
    'LEAVING the Feed re-stamps too — the list updates live, so somebody '
    'sitting on it for ten minutes has genuinely seen what landed during that '
    'time, and stamping only on entry would dot the tab the moment they '
    'walked away',
    (tester) async {
      var now = 5000;
      final container = makeContainer(clock: () => now);

      await tester.pumpWidget(wrap(container, initial: '/feed'));
      await tester.pumpAndSettle();
      expect(
        container.read(feedLastSeenProvider),
        5000,
        reason:
            'a cold start that lands ON the Feed must stamp too, or a user '
            'who mostly reloads onto /feed would never get a baseline at all',
      );

      now = 9000;
      await tester.tap(find.byKey(const Key('nav-tab-topos')));
      await tester.pumpAndSettle();

      expect(container.read(feedLastSeenProvider), 9000);
    },
  );

  testWidgets('the baseline is persisted, in the signed-out bucket', (
    tester,
  ) async {
    final container = makeContainer(clock: () => 7000);

    await container.read(feedLastSeenProvider.notifier).markSeen();

    expect(
      await container
          .read(settingsStoreProvider)
          .read(SettingsStore.feedLastSeenKey(null)),
      '7000',
      reason:
          'keyed by uid so switching accounts on one device does not inherit '
          "the other's baseline; signed-out gets its own bucket rather than "
          'sharing one with whoever signed in last',
    );
  });
}
