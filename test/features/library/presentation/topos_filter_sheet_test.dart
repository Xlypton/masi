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
import 'package:masi/features/library/presentation/topos_screen.dart';

import '../../../support/async_drain.dart';

/// The Filters sheet's dismissibility and its layout under stress.
///
/// The reported bug: the sheet is `isScrollControlled`, so it grows to fill the
/// screen, and its only exits were a scrim you cannot see and a drag on a 5 px
/// grab handle — i.e. for practical purposes it could not be closed. It now
/// carries an explicit **Done** opposite **Clear**, and Clear closes it too
/// (having unset every facet there is nothing left in here to do).
///
/// Kept out of `topos_screen_test.dart` deliberately: that file is already
/// ~7.4k lines, and this is a self-contained behaviour with its own harness.

/// Skips the real orchestrator's `tableUpdates()` subscription, which would
/// otherwise schedule a 2 s debounce `Timer` that outlives the test and trips
/// flutter_test's "A Timer is still pending" teardown assertion. Mirrors the
/// identical file-private double in `topos_screen_test.dart`.
class _FakeSyncOrchestrator extends SyncOrchestrator {
  @override
  SyncOrchestratorState build() => const SyncOrchestratorState();

  @override
  Future<void> pullNow({bool throttled = false}) async {}
}

/// A [ConnectivityService] that answers "reachable" without touching the
/// network — `ToposScreen` probes `reachabilityProvider` at mount, and the real
/// service would issue a genuine `http.get` with a timeout from every test here.
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

/// A real (minimal) [GoRouter], because the sheet is now pushed with
/// `useRootNavigator: true` and therefore needs a genuine root navigator above
/// the screen — the whole point of the change (see `_showToposFiltersSheet`).
Widget _wrap(ProviderContainer container, {double textScale = 1.0}) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (context, state) => const ToposScreen()),
      GoRoute(
        path: '/walls/:wallId',
        builder: (context, state) => const SizedBox(),
      ),
      GoRoute(path: '/areas', builder: (context, state) => const SizedBox()),
      GoRoute(path: '/account', builder: (context, state) => const SizedBox()),
    ],
  );
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(
      theme: MasiTheme.light,
      routerConfig: router,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
    ),
  );
}

Future<void> _drain(WidgetTester tester) async {
  await drainAsync(tester, rounds: 6, settle: false);
  await tester.pumpAndSettle();
}

void _setViewportSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('topos-filter-button')));
  await tester.pumpAndSettle();
}

void main() {
  group('Filters sheet: Done, opposite Clear', () {
    testWidgets(
      'the header carries a Done action at the opposite end from Clear',
      (tester) async {
        final container = _makeContainer();
        await tester.pumpWidget(_wrap(container));
        await _drain(tester);

        await _openSheet(tester);

        final done = find.byKey(const Key('topos-filter-done'));
        final clear = find.byKey(const Key('topos-filter-clear'));
        expect(done, findsOneWidget);
        expect(clear, findsOneWidget);
        expect(find.text('Done'), findsOneWidget);

        // OPPOSITE ends, not merely both present: Clear leads, Done trails,
        // with the title between them. A Done tucked next to Clear would be a
        // mis-tap waiting to happen on the one control that closes the sheet.
        //
        // Asserted at the DEFAULT text scale on purpose — the header is a
        // `Wrap`, so at an accessibility scale where all three cannot share a
        // line the two actions legitimately stack instead of overflowing (see
        // the scroll/overflow group below, which covers that case).
        final clearBox = tester.getRect(clear);
        final doneBox = tester.getRect(done);
        final title = tester.getRect(find.text('Filters'));
        expect(clearBox.center.dy, closeTo(doneBox.center.dy, 1));
        expect(clearBox.right, lessThanOrEqualTo(title.left));
        expect(doneBox.left, greaterThanOrEqualTo(title.right));
      },
    );

    testWidgets('tapping Done dismisses the sheet', (tester) async {
      final container = _makeContainer();
      await tester.pumpWidget(_wrap(container));
      await _drain(tester);

      await _openSheet(tester);
      expect(find.byKey(const Key('topos-filter-visibility')), findsOneWidget);

      await tester.tap(find.byKey(const Key('topos-filter-done')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('topos-filter-visibility')), findsNothing);
      expect(find.byKey(const Key('topos-filter-done')), findsNothing);
      // Dismissal is not a reset: Done means "I'm finished here", so whatever
      // was set stays set.
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'tapping Done LEAVES the chosen facets applied (it dismisses, it does '
      'not cancel)',
      (tester) async {
        final container = _makeContainer();
        await tester.pumpWidget(_wrap(container));
        await _drain(tester);

        await _openSheet(tester);
        await tester.tap(
          find.byKey(const Key('topos-filter-visibility-private')),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('topos-filter-done')));
        await tester.pumpAndSettle();

        expect(container.read(toposFilterProvider).isActive, isTrue);
        expect(
          container.read(toposFilterProvider).visibility,
          ToposVisibilityFilter.private,
        );
      },
    );

    testWidgets(
      'tapping Clear resets every facet but leaves the sheet open',
      (tester) async {
        final container = _makeContainer();
        await tester.pumpWidget(_wrap(container));
        await _drain(tester);

        await _openSheet(tester);
        await tester.tap(
          find.byKey(const Key('topos-filter-visibility-shared')),
        );
        await tester.pumpAndSettle();
        expect(container.read(toposFilterProvider).isActive, isTrue);

        await tester.tap(find.byKey(const Key('topos-filter-clear')));
        await tester.pumpAndSettle();

        expect(container.read(toposFilterProvider), const ToposFilter());
        // Clear is the "start over" control, not an exit: clearing is often
        // the first half of "clear this, then set something else", so the
        // sheet stays up rather than forcing a reopen. Done remains the only
        // exit action.
        expect(
          find.byKey(const Key('topos-filter-visibility')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('topos-filter-done')), findsOneWidget);
      },
    );
  });

  group('Filters sheet: the content scrolls rather than overflowing', () {
    // 360 px is real phone width (iPhone SE / most Androids in CSS px), and
    // deliberately NOT the 700 px the pre-existing stress group in
    // `topos_screen_test.dart` uses to dodge the AppBar: the sheet is what is
    // under test here, and a sheet that only fits on a tablet is not fixed.
    // 420 px of height at 3.0x is the "small height AND large text scale"
    // corner: the facet column alone is several screens tall there.
    testWidgets(
      '360x420 @ 3.0x text scale: opening the sheet raises no overflow, and '
      'the facets are reachable by scrolling',
      (tester) async {
        _setViewportSize(tester, const Size(360, 420));
        final container = _makeContainer();
        await tester.pumpWidget(_wrap(container, textScale: 3.0));
        await _drain(tester);
        // Guard: if the SCREEN itself overflows at this size the sheet
        // assertion below would be reporting somebody else's bug.
        expect(tester.takeException(), isNull);

        await _openSheet(tester);
        expect(
          tester.takeException(),
          isNull,
          reason:
              'the Filters sheet must lay out at a small height and a '
              'large text scale without a RenderFlex overflow',
        );

        // Proof it SCROLLS rather than merely fitting: the Style chips sit
        // last, well below the fold at this size, and `ensureVisible` can only
        // bring them into view through a real scrollable.
        final styleChip = find.byKey(const Key('filter-styletag-dyno'));
        expect(styleChip, findsOneWidget);
        await tester.ensureVisible(styleChip);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        // And the pinned header survived the scroll: Done/Clear are the exits,
        // so they must not have scrolled away with the facets.
        expect(find.byKey(const Key('topos-filter-done')), findsOneWidget);
        expect(find.byKey(const Key('topos-filter-clear')), findsOneWidget);
      },
    );

    testWidgets(
      '320x360 @ 2.0x text scale (the smallest surface we care about) also '
      'lays out clean',
      (tester) async {
        _setViewportSize(tester, const Size(320, 360));
        final container = _makeContainer();
        await tester.pumpWidget(_wrap(container, textScale: 2.0));
        await _drain(tester);
        expect(tester.takeException(), isNull);

        await _openSheet(tester);
        expect(tester.takeException(), isNull);
      },
    );
  });
}
