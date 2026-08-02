import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/core/db/storage_durability_provider.dart';
import 'package:masi/features/backup/application/sync_orchestrator.dart';
import 'package:masi/features/library/presentation/topos_screen.dart';

/// Copy-level coverage for `_StorageWarningBanner`
/// (`topos_storage_banner.dart`), which speaks to the user at the single
/// worst moment the app has — "we cannot keep, or cannot open, your library".
///
/// Deliberately a SEPARATE file from `topos_screen_test.dart`, whose §1a group
/// owns the interlock's *behaviour* (buttons disabled, picker never opened).
/// That file is large and concurrently maintained; this one is only about what
/// the banner SAYS, and keeping it apart means neither set has to be rewritten
/// when the other changes. The harness below is therefore the minimum needed
/// to render `ToposScreen` with a chosen verdict — no photo picker, no GPS, no
/// image fixtures.
///
/// Why the copy matters enough to pin: `StorageDurability.unavailable` covers
/// two situations with opposite user meanings. A blocked browser really has
/// lost the ability to save anything. An L7 schema downgrade
/// (`core/db/schema_downgrade.dart`) has lost NOTHING — the guard's whole
/// purpose is that the database is untouched — and telling that user their
/// topos can't be saved is a false alarm about their life's climbing records.
class _FakeStorageDurability extends StorageDurabilityNotifier {
  _FakeStorageDurability(this._verdict);

  final StorageDurability _verdict;

  @override
  StorageDurability build() => _verdict;
}

/// Skips the real orchestrator's `tableUpdates()` subscription, which would
/// otherwise schedule a 2s debounce `Timer` that outlives the test and trips
/// flutter_test's "A Timer is still pending" teardown assertion. Mirrors
/// `topos_screen_test.dart`'s identical file-private double.
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
      GoRoute(path: '/', builder: (context, state) => const ToposScreen()),
      GoRoute(
        path: '/walls/:wallId',
        builder: (context, state) => const SizedBox(),
      ),
      GoRoute(path: '/areas', builder: (context, state) => const SizedBox()),
      GoRoute(path: '/community', builder: (context, state) => const SizedBox()),
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

String _titleOf(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const Key('topos-storage-warning-title')))
    .data!;

String _bodyOf(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const Key('topos-storage-warning-body')))
    .data!;

String _detailOf(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const Key('topos-storage-warning-detail')))
    .data!;

void main() {
  group('schema-downgrade verdict (L7)', () {
    const downgrade = StorageDurability.unavailable(
      'This version of the app is older than your saved data, so it refused '
      'to open your library rather than damage it. Nothing has been changed '
      'or deleted. Reload to pick up the current version of the app — if you '
      'are offline, reconnect first, because the reload has to fetch it. '
      '(SchemaDowngradeException: local database schema version 9, this '
      'build understands version 8)',
      cause: StorageUnavailableCause.schemaDowngrade,
    );

    testWidgets('leads with the data being safe, not with losing it', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(_makeContainer(downgrade)));
      await _drain(tester);

      expect(find.byKey(const Key('topos-storage-warning')), findsOneWidget);
      expect(
        _titleOf(tester),
        contains('safe'),
        reason: 'the guard exists precisely BECAUSE the data is intact; the '
            'headline must not imply the opposite',
      );
      expect(_bodyOf(tester), contains('Nothing has been lost'));
    });

    testWidgets('tells the user to reload, and that reloading needs a '
        'connection', (tester) async {
      await tester.pumpWidget(_wrap(_makeContainer(downgrade)));
      await _drain(tester);

      final body = _bodyOf(tester);
      // The remedy is a newer shell, which `web/sw.js` (network-first with a
      // cache FALLBACK) can only fetch while online — an offline reload
      // re-serves the same stale shell and lands right back here.
      expect(body, contains('Reload'));
      expect(body, contains('offline'));
    });

    testWidgets('does NOT blame the browser or private browsing', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(_makeContainer(downgrade)));
      await _drain(tester);

      final text = '${_titleOf(tester)} ${_bodyOf(tester)}';
      // Every clause of the in-memory copy is false here: the browser is fine,
      // private browsing is irrelevant, and a normal window changes nothing.
      expect(text, isNot(contains('Private browsing')));
      expect(text, isNot(contains('normal window')));
      expect(text, isNot(contains("browser can't")));
    });

    testWidgets('still disables creation — the interlock is unchanged', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(_makeContainer(downgrade)));
      await _drain(tester);

      expect(
        tester
            .widget<ElevatedButton>(find.byKey(const Key('topos-new-topo')))
            .onPressed,
        isNull,
        reason: 'a database we are refusing to open must not be written to '
            'either, whatever the banner says',
      );
    });
  });

  group('unclassified unavailable verdict', () {
    const failed = StorageDurability.unavailable('Bad worker: boom');

    testWidgets('gets its own copy, and still does not blame private '
        'browsing', (tester) async {
      await tester.pumpWidget(_wrap(_makeContainer(failed)));
      await _drain(tester);

      expect(find.byKey(const Key('topos-storage-warning')), findsOneWidget);
      final text = '${_titleOf(tester)} ${_bodyOf(tester)}';
      expect(text, isNot(contains('Private browsing')));
      // A failed OPEN deletes nothing, so this copy may say so honestly.
      expect(_bodyOf(tester), contains('not been deleted'));
    });

    testWidgets('surfaces unavailableReason in the detail line', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(_makeContainer(failed)));
      await _drain(tester);

      final detail = _detailOf(tester);
      // Independent of the downgrade work: holding a real reason string and
      // rendering `Storage: unknown` was a bug of its own — it threw away the
      // one line that makes a field report answerable.
      expect(detail, contains('Bad worker: boom'));
      expect(detail, isNot(contains('unknown')));
    });
  });

  group('height is bounded', () {
    // The banner used to size itself purely to its content. Measured at this
    // surface it rendered 561px into a 364px body, took the whole `Expanded`
    // beneath it to 0px, and overflowed `ToposScreen`'s outer Column by 421px
    // — the entire topo list and its create affordance pushed off-screen by a
    // warning. The situations where this banner shows are exactly the ones
    // where the user most needs to reach the rest of the screen.
    //
    // 400x420 is the measured repro; a phone at a large accessibility text
    // scale is the same shape.
    const smallSurface = Size(400, 420);
    const longReason = StorageDurability.unavailable(
      'This version of the app is older than your saved data, so it refused '
      'to open your library rather than damage it. Nothing has been changed '
      'or deleted. Reload to pick up the current version of the app — if you '
      'are offline, reconnect first, because the reload has to fetch it. '
      '(SchemaDowngradeException: local database schema version 9, this '
      'build understands version 8)',
      cause: StorageUnavailableCause.schemaDowngrade,
    );

    Future<void> pumpAt(WidgetTester tester, Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_wrap(_makeContainer(longReason)));
      await _drain(tester);
    }

    testWidgets('leaves most of a small viewport to the list', (tester) async {
      await pumpAt(tester, smallSurface);

      final height = tester
          .getSize(find.byKey(const Key('topos-storage-warning')))
          .height;
      expect(
        height,
        lessThan(smallSurface.height * 0.5),
        reason: 'a notice that eats the viewport hides the very thing the '
            'user opened the app for',
      );
    });

    testWidgets('does not overflow its parent', (tester) async {
      await pumpAt(tester, smallSurface);

      expect(
        tester.takeException(),
        isNull,
        reason: 'the outer Column used to overflow by 421px here',
      );
    });

    testWidgets('keeps the reassurance and the remedy visible when squeezed — '
        'the exception detail is what gives', (tester) async {
      await pumpAt(tester, smallSurface);

      // Priority order: "nothing is lost" and "what to do" outrank the raw
      // exception text, which survives in the `masi/storage:` log line either
      // way. The title sits at the top of the scrollable region, so it is the
      // last thing to leave the visible area rather than the first.
      expect(_titleOf(tester), contains('safe'));
      expect(_bodyOf(tester), contains('Reload'));
    });

    testWidgets('an ordinary phone-height viewport is unaffected', (
      tester,
    ) async {
      // The cap must not shrink the banner in the normal case; at a real phone
      // height the content still fits well inside it.
      await pumpAt(tester, const Size(390, 844));

      expect(_titleOf(tester), contains('safe'));
      expect(_detailOf(tester), contains('SchemaDowngradeException'));
    });
  });

  group('non-durable backend (the pre-existing in-memory case)', () {
    const inMemory = StorageDurability(
      backend: StorageBackend.inMemory,
      missingFeatures: {StorageMissingFeature.sharedArrayBuffers},
    );

    testWidgets('keeps its original copy verbatim — that copy is correct for '
        'what it was written for', (tester) async {
      await tester.pumpWidget(_wrap(_makeContainer(inMemory)));
      await _drain(tester);

      expect(_titleOf(tester), "This browser can't save your topos");
      expect(_bodyOf(tester), contains('Private browsing'));
      expect(_bodyOf(tester), contains('install the app to your home screen'));
    });

    testWidgets('keeps naming the backend and the missing features', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(_makeContainer(inMemory)));
      await _drain(tester);

      final detail = _detailOf(tester);
      expect(detail, contains('inMemory'));
      expect(detail, contains('sharedArrayBuffers'));
    });
  });
}
