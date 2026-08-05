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
import 'package:masi/features/backup/application/sync_orchestrator.dart';
import 'package:masi/features/library/presentation/topos_screen.dart';

/// Composition-level coverage for the device-screenshot bug this fix
/// addresses: `NavShell`'s `ShellNotices` (`StorageRetryBanner`) stacked
/// directly above `ToposScreen`'s own storage notice reported the SAME
/// failure twice, once in each voice, filling the screen with red — and the
/// `topos-new-topo` FAB floated on top of the second block's text.
///
/// `NavShell` itself needs a real `StatefulNavigationShell` from go_router's
/// `StatefulShellRoute`, which is awkward to construct in isolation without a
/// full router. Instead this harness reproduces `NavShell.build`'s own body
/// shape verbatim — `Column([ShellNotices(), Expanded(child: <branch>)])`,
/// see that class's doc — with `ToposScreen` standing in for the branch,
/// which is exactly what the Topos tab really is. Anything asserted here
/// about that `Column` is true of the genuine `NavShell` too, since the
/// `Column` is the entire slice of `NavShell.build` this bug lives in; the
/// bottom nav bar itself is untouched by this fix and isn't reproduced here.
class _FakeStorageDurability extends StorageDurabilityNotifier {
  _FakeStorageDurability(this._verdict);

  final StorageDurability _verdict;

  @override
  StorageDurability build() => _verdict;
}

/// Skips the real orchestrator's `tableUpdates()` subscription, which would
/// otherwise schedule a 2s debounce `Timer` that outlives the test and trips
/// flutter_test's "A Timer is still pending" teardown assertion. Mirrors
/// `topos_screen_test.dart`/`topos_storage_banner_test.dart`'s identical
/// file-private double.
class _FakeSyncOrchestrator extends SyncOrchestrator {
  @override
  SyncOrchestratorState build() => const SyncOrchestratorState();

  @override
  Future<void> pullNow({bool throttled = false}) async {}
}

ProviderContainer _makeContainer(StorageDurability durability) {
  final db = AppDatabase(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      nowMsProvider.overrideWithValue(() => 1000),
      syncOrchestratorProvider.overrideWith(_FakeSyncOrchestrator.new),
      storageDurabilityProvider.overrideWith(
        () => _FakeStorageDurability(durability),
      ),
    ],
  );
  addTearDown(db.close);
  addTearDown(container.dispose);
  return container;
}

Widget _wrap(ProviderContainer container) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const Scaffold(
          body: Column(
            children: [ShellNotices(), Expanded(child: ToposScreen())],
          ),
        ),
      ),
      GoRoute(
        path: '/walls/:wallId',
        builder: (context, state) => const SizedBox(),
      ),
      GoRoute(path: '/areas', builder: (context, state) => const SizedBox()),
      GoRoute(
        path: '/community',
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
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 30));
  }
  await tester.pumpAndSettle();
}

void main() {
  const unavailableFailed = StorageDurability.unavailable(
    'the local database did not answer its first query within 30s',
  );

  group('say it once — storage-unavailable composition', () {
    testWidgets(
      'the shell retry banner shows, the in-body full explanation does not, '
      'and its detail line survives',
      (tester) async {
        await tester.pumpWidget(_wrap(_makeContainer(unavailableFailed)));
        await _drain(tester);

        expect(
          find.byKey(const Key('storage-retry-banner')),
          findsOneWidget,
          reason: 'the shell owns the human sentence + the retry action',
        );
        expect(
          find.byKey(const Key('topos-storage-warning')),
          findsNothing,
          reason: '_StorageWarningBanner would restate the shell banner\'s '
              'exact sentence in its own words — that repetition is the bug '
              'this fix removes',
        );
        expect(find.text("Can't open your saved topos"), findsNothing);
        expect(
          find.byKey(const Key('topos-storage-detail-only')),
          findsOneWidget,
          reason: 'the technical detail line the compact shell banner has no '
              'room for must still be reachable, not simply deleted',
        );
        // The reason string is the one piece of text both surfaces could
        // plausibly have carried — pin it appears exactly ONCE across the
        // whole composed tree, not once per surface.
        expect(
          find.textContaining(
            'the local database did not answer its first query within 30s',
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'the shell retry action is present and actually retries',
      (tester) async {
        final container = _makeContainer(unavailableFailed);
        await tester.pumpWidget(_wrap(container));
        await _drain(tester);

        final button = tester.widget<TextButton>(
          find.byKey(const Key('storage-retry-banner-action')),
        );
        expect(button.onPressed, isNotNull);

        await tester.tap(find.byKey(const Key('storage-retry-banner-action')));
        await _drain(tester);

        // A fresh in-memory NativeDatabase always opens and answers `SELECT
        // 1` cleanly, so a real retry must clear the failed verdict.
        expect(
          container.read(storageDurabilityProvider).isEphemeral,
          isFalse,
          reason: 'retry must not be a decorative no-op button',
        );
        expect(find.byKey(const Key('storage-retry-banner')), findsNothing);
      },
    );

    testWidgets(
      'the topos-new-topo FAB is absent, so it cannot overlap the detail '
      'text',
      (tester) async {
        await tester.pumpWidget(_wrap(_makeContainer(unavailableFailed)));
        await _drain(tester);

        expect(find.byKey(const Key('topos-new-topo')), findsNothing);
      },
    );

    testWidgets(
      'a squeezed 400x420 viewport (the measured real repro in '
      "topos_storage_banner.dart's own doc) does not overflow with the "
      'shell banner AND an AppBar both stacked above this screen\'s body',
      (tester) async {
        // NOT 400x300: at that height an AppBar (56) plus
        // `StorageRetryBanner`'s own un-capped content already leaves
        // `ToposScreen`'s body under 10px regardless of what renders inside
        // it — a pre-existing ceiling on how much chrome this shell can carry
        // above ANY branch, not something this fix's tiny
        // `_StorageDetailNotice` introduces (confirmed: `ToposScreen` in
        // isolation, no shell banner, tolerates 400x300 fine — see
        // `topos_screen_test.dart`'s "the compact detail notice tolerates a
        // squeezed 400x300 viewport"). 400x420 is the dimension this
        // codebase already measured a real failure at for the banner this
        // fix touches, so it is the realistic squeeze to hold this
        // composition to.
        tester.view.physicalSize = const Size(400, 420);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(_wrap(_makeContainer(unavailableFailed)));
        await _drain(tester);

        expect(
          tester.takeException(),
          isNull,
          reason: 'two banners have already overflowed this exact codebase '
              'once each at this dimension — see topos_storage_banner.dart\'s '
              'and community_screen.dart\'s doc comments',
        );
      },
    );
  });

  group('negative control — healthy storage', () {
    const healthy = StorageDurability(backend: StorageBackend.opfsLocks);

    testWidgets(
      'neither error surface renders, and the FAB is present as before',
      (tester) async {
        await tester.pumpWidget(_wrap(_makeContainer(healthy)));
        await _drain(tester);

        expect(find.byKey(const Key('storage-retry-banner')), findsNothing);
        expect(find.byKey(const Key('topos-storage-warning')), findsNothing);
        expect(
          find.byKey(const Key('topos-storage-detail-only')),
          findsNothing,
        );
        expect(find.byKey(const Key('topos-new-topo')), findsOneWidget);
      },
    );
  });
}
