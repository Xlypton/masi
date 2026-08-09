// Widget-level test for the proactive "storage is nearly full" banner (#49
// P3 / task #51). Exercised through `ShellNotices` — like
// `storage_retry_banner_test.dart` — because the decision of WHEN to show it
// (and its priority against the other two shell notices) is the part that
// can regress, not merely the banner's own rendering.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/app/nav_shell.dart';
import 'package:masi/app/storage_pressure_banner.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/core/db/storage_durability_provider.dart';
import 'package:masi/features/account/application/pwa_install_providers.dart';
import 'package:masi/features/account/application/pwa_install_types.dart';
import 'package:masi/features/backup/application/sync_orchestrator.dart';
import 'package:masi/features/topo/application/community_photo_clear_controller.dart';
import 'package:masi/features/topo/data/public_photo_prune_service.dart';

void setViewportSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// A [SyncOrchestrator] pinned to one state — mirrors `topos_screen_test
/// .dart`'s `_FakeSyncOrchestrator`: overriding only `build()` skips the real
/// constructor's timers/subscriptions entirely, so this is safe in a bare
/// widget test with no debounce `Timer` left pending at teardown.
class _PinnedSyncOrchestrator extends SyncOrchestrator {
  _PinnedSyncOrchestrator(this._state);

  final SyncOrchestratorState _state;

  @override
  SyncOrchestratorState build() => _state;
}

/// A [CommunityPhotoClearController] whose `clear()` is scripted rather than
/// backed by a real service — this file is about the BANNER's wiring
/// (visibility, priority, the consent gate), not the clear policy itself
/// (already proven end-to-end in `community_photo_clear_controller_test
/// .dart` and `public_photo_prune_service_test.dart`).
class _ScriptedClearController extends CommunityPhotoClearController {
  _ScriptedClearController({this.outcome, this.throwOnClear = false});

  final PublicPhotoManualClearOutcome? outcome;
  final bool throwOnClear;
  int clearCallCount = 0;

  @override
  CommunityPhotoClearStatus build() => CommunityPhotoClearStatus.idle;

  @override
  Future<void> clear() async {
    clearCallCount++;
    if (throwOnClear) {
      state = CommunityPhotoClearStatus.failed;
      return;
    }
    state = CommunityPhotoClearStatus.clearing;
    lastOutcome = outcome ?? const PublicPhotoManualClearOutcome();
    state = CommunityPhotoClearStatus.succeeded;
  }
}

void main() {
  Widget wrap(ProviderContainer container) => UncontrolledProviderScope(
    container: container,
    child: MaterialApp(theme: MasiTheme.light, home: const Scaffold(body: ShellNotices())),
  );

  ProviderContainer makeContainer({
    PublicPhotoPruneOutcome? pruneOutcome,
    _ScriptedClearController? clearController,
  }) {
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) {
          final db = AppDatabase(NativeDatabase.memory());
          ref.onDispose(db.close);
          return db;
        }),
        pwaInstallStatusProvider.overrideWithValue(
          const PwaInstallStatus(
            isStandalone: false,
            canPrompt: true,
            platform: PwaPlatform.other,
          ),
        ),
        syncOrchestratorProvider.overrideWith(
          () => _PinnedSyncOrchestrator(
            SyncOrchestratorState(lastPublicPhotoPruneOutcome: pruneOutcome),
          ),
        ),
        if (clearController != null)
          communityPhotoClearProvider.overrideWith(() => clearController),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('ShellNotices — visibility and priority', () {
    testWidgets(
      'nothingPrunable under pressure shows the storage-pressure banner and '
      'suppresses the install prompt',
      (tester) async {
        final container = makeContainer(
          pruneOutcome: const PublicPhotoPruneOutcome(
            reason: PublicPhotoPruneReason.nothingPrunable,
            usedFractionBefore: 0.9,
            usedFractionAfter: 0.9,
          ),
        );

        await tester.pumpWidget(wrap(container));
        await tester.pump();

        expect(find.byKey(const Key('storage-pressure-banner')), findsOneWidget);
        expect(find.byKey(const Key('storage-pressure-banner-clear')), findsOneWidget);
        expect(find.text('Clear cached photos'), findsOneWidget);
        expect(find.byKey(const Key('install-banner')), findsNothing);
      },
    );

    testWidgets('poolExhausted under pressure ALSO shows the banner', (tester) async {
      final container = makeContainer(
        pruneOutcome: const PublicPhotoPruneOutcome(
          reason: PublicPhotoPruneReason.poolExhausted,
          usedFractionBefore: 0.85,
          usedFractionAfter: 0.85,
        ),
      );

      await tester.pumpWidget(wrap(container));
      await tester.pump();

      expect(find.byKey(const Key('storage-pressure-banner')), findsOneWidget);
    });

    testWidgets(
      'comfortable headroom (belowHighWatermark) shows NO banner — the '
      'normal path stays byte-identical',
      (tester) async {
        final container = makeContainer(
          pruneOutcome: const PublicPhotoPruneOutcome(
            reason: PublicPhotoPruneReason.belowHighWatermark,
            usedFractionBefore: 0.3,
            usedFractionAfter: 0.3,
          ),
        );

        await tester.pumpWidget(wrap(container));
        await tester.pump();

        expect(find.byKey(const Key('storage-pressure-banner')), findsNothing);
        expect(find.byKey(const Key('install-banner')), findsOneWidget);
      },
    );

    testWidgets(
      'a pass that hit its cap (capReached) shows NO banner — there is more '
      'prunable content and the next pull will likely resolve it',
      (tester) async {
        final container = makeContainer(
          pruneOutcome: const PublicPhotoPruneOutcome(
            reason: PublicPhotoPruneReason.capReached,
            usedFractionBefore: 0.9,
            usedFractionAfter: 0.85,
          ),
        );

        await tester.pumpWidget(wrap(container));
        await tester.pump();

        expect(find.byKey(const Key('storage-pressure-banner')), findsNothing);
      },
    );

    testWidgets(
      'no pull has completed yet (null outcome) shows NO banner',
      (tester) async {
        final container = makeContainer();

        await tester.pumpWidget(wrap(container));
        await tester.pump();

        expect(find.byKey(const Key('storage-pressure-banner')), findsNothing);
        expect(find.byKey(const Key('install-banner')), findsOneWidget);
      },
    );

    testWidgets(
      'an unopenable database still wins — the retry banner is the more '
      'urgent fault and takes the one notice slot',
      (tester) async {
        final container = makeContainer(
          pruneOutcome: const PublicPhotoPruneOutcome(
            reason: PublicPhotoPruneReason.nothingPrunable,
            usedFractionBefore: 0.9,
            usedFractionAfter: 0.9,
          ),
        );
        container
            .read(storageDurabilityProvider.notifier)
            .report(const StorageDurability.unavailable('dead'));

        await tester.pumpWidget(wrap(container));
        await tester.pump();

        expect(find.byKey(const Key('storage-retry-banner')), findsOneWidget);
        expect(find.byKey(const Key('storage-pressure-banner')), findsNothing);
      },
    );
  });

  group('the consented "clear cached photos" action', () {
    testWidgets(
      'tapping the button opens a confirmation dialog and does NOT clear '
      'anything until it is confirmed',
      (tester) async {
        final clearController = _ScriptedClearController();
        final container = makeContainer(
          pruneOutcome: const PublicPhotoPruneOutcome(
            reason: PublicPhotoPruneReason.nothingPrunable,
            usedFractionBefore: 0.9,
            usedFractionAfter: 0.9,
          ),
          clearController: clearController,
        );

        await tester.pumpWidget(wrap(container));
        await tester.pump();
        await tester.tap(find.byKey(const Key('storage-pressure-banner-clear')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('storage-pressure-clear-dialog')), findsOneWidget);
        expect(
          clearController.clearCallCount,
          0,
          reason: 'opening the dialog must not itself trigger the clear',
        );
      },
    );

    testWidgets(
      'cancelling the dialog leaves the controller untouched — explicit '
      'consent means "no" really means nothing happens',
      (tester) async {
        final clearController = _ScriptedClearController();
        final container = makeContainer(
          pruneOutcome: const PublicPhotoPruneOutcome(
            reason: PublicPhotoPruneReason.nothingPrunable,
            usedFractionBefore: 0.9,
            usedFractionAfter: 0.9,
          ),
          clearController: clearController,
        );

        await tester.pumpWidget(wrap(container));
        await tester.pump();
        await tester.tap(find.byKey(const Key('storage-pressure-banner-clear')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('storage-pressure-clear-cancel')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('storage-pressure-clear-dialog')), findsNothing);
        expect(clearController.clearCallCount, 0);
        expect(
          container.read(communityPhotoClearProvider),
          CommunityPhotoClearStatus.idle,
        );
      },
    );

    testWidgets(
      'confirming the dialog calls clear() exactly once and reports how many '
      'photos were cleared',
      (tester) async {
        final clearController = _ScriptedClearController(
          outcome: const PublicPhotoManualClearOutcome(
            clearedKeys: ['photos/a.jpg', 'photos/b.jpg'],
          ),
        );
        final container = makeContainer(
          pruneOutcome: const PublicPhotoPruneOutcome(
            reason: PublicPhotoPruneReason.nothingPrunable,
            usedFractionBefore: 0.9,
            usedFractionAfter: 0.9,
          ),
          clearController: clearController,
        );

        await tester.pumpWidget(wrap(container));
        await tester.pump();
        await tester.tap(find.byKey(const Key('storage-pressure-banner-clear')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('storage-pressure-clear-confirm')));
        await tester.pumpAndSettle();

        expect(clearController.clearCallCount, 1);
        expect(find.text('Cleared 2 cached photos.'), findsOneWidget);
      },
    );

    testWidgets(
      'a clear that finds nothing to free reports that plainly, not as an '
      'error',
      (tester) async {
        final clearController = _ScriptedClearController(
          outcome: const PublicPhotoManualClearOutcome(),
        );
        final container = makeContainer(
          pruneOutcome: const PublicPhotoPruneOutcome(
            reason: PublicPhotoPruneReason.nothingPrunable,
            usedFractionBefore: 0.9,
            usedFractionAfter: 0.9,
          ),
          clearController: clearController,
        );

        await tester.pumpWidget(wrap(container));
        await tester.pump();
        await tester.tap(find.byKey(const Key('storage-pressure-banner-clear')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('storage-pressure-clear-confirm')));
        await tester.pumpAndSettle();

        expect(find.text('Nothing to clear.'), findsOneWidget);
      },
    );

    testWidgets(
      'a clear that fails outright reports that plainly too, rather than '
      'crashing or silently doing nothing',
      (tester) async {
        final clearController = _ScriptedClearController(throwOnClear: true);
        final container = makeContainer(
          pruneOutcome: const PublicPhotoPruneOutcome(
            reason: PublicPhotoPruneReason.nothingPrunable,
            usedFractionBefore: 0.9,
            usedFractionAfter: 0.9,
          ),
          clearController: clearController,
        );

        await tester.pumpWidget(wrap(container));
        await tester.pump();
        await tester.tap(find.byKey(const Key('storage-pressure-banner-clear')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('storage-pressure-clear-confirm')));
        await tester.pumpAndSettle();

        expect(clearController.clearCallCount, 1);
        expect(find.text("Couldn't clear cached photos — try again."), findsOneWidget);
      },
    );
  });

  group('dismissibility (the user\'s decision — every banner in this family '
      'closes, episode-scoped)', () {
    /// Exercises [StoragePressureBanner] directly, with [show] toggling
    /// whether it is even in the tree — the widget's own dismiss/re-arm
    /// contract is what's under test, not `ShellNotices`' decision of WHEN
    /// to show it (already covered above). Unmounting/remounting here
    /// stands in for `ShellNotices` swapping this widget out once the prune
    /// outcome no longer warrants it, and back in once it recurs.
    Widget wrapDirect(ProviderContainer container, {bool show = true}) =>
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: MasiTheme.light,
            home: Scaffold(
              body: show ? const StoragePressureBanner() : const SizedBox.shrink(),
            ),
          ),
        );

    testWidgets('tapping dismiss hides the banner', (tester) async {
      final container = makeContainer();

      await tester.pumpWidget(wrapDirect(container));
      await tester.pump();
      expect(find.byKey(const Key('storage-pressure-banner')), findsOneWidget);

      await tester.tap(
        find.byKey(const Key('storage-pressure-banner-dismiss')),
      );
      await tester.pump();

      expect(find.byKey(const Key('storage-pressure-banner')), findsNothing);
    });

    testWidgets(
      'a fresh mount (the condition clearing and then recurring) is not '
      'suppressed by an earlier dismissal',
      (tester) async {
        final container = makeContainer();

        await tester.pumpWidget(wrapDirect(container));
        await tester.pump();
        await tester.tap(
          find.byKey(const Key('storage-pressure-banner-dismiss')),
        );
        await tester.pump();
        expect(find.byKey(const Key('storage-pressure-banner')), findsNothing);

        // The condition clearing removes this widget from the tree entirely
        // (`ShellNotices` would swap in the install banner instead).
        await tester.pumpWidget(wrapDirect(container, show: false));
        await tester.pump();

        // ...and recurring mounts a BRAND NEW `StoragePressureBanner`, with
        // a brand-new State — undismissed, even though the message (fixed,
        // see [StoragePressureBanner.message]) is identical to before.
        await tester.pumpWidget(wrapDirect(container));
        await tester.pump();

        expect(
          find.byKey(const Key('storage-pressure-banner')),
          findsOneWidget,
          reason: 'a new episode of the same condition must re-arm, not '
              'stay hidden behind the earlier dismissal',
        );
      },
    );
  });

  group('the height cap — #26/#30 were both an unbounded-height notice', () {
    testWidgets(
      'leaves most of a small viewport to the tab content beneath it',
      (tester) async {
        const surface = Size(400, 420);
        setViewportSize(tester, surface);
        final container = makeContainer(
          pruneOutcome: const PublicPhotoPruneOutcome(
            reason: PublicPhotoPruneReason.nothingPrunable,
            usedFractionBefore: 0.9,
            usedFractionAfter: 0.9,
          ),
        );

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: MasiTheme.light,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: const TextScaler.linear(3.0),
                ),
                child: child!,
              ),
              home: Scaffold(
                body: Column(
                  children: [
                    const ShellNotices(),
                    Expanded(child: Container(key: const Key('the-content'))),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        expect(
          tester.getSize(find.byKey(const Key('storage-pressure-banner'))).height,
          lessThan(surface.height * 0.5),
          reason: 'a notice that eats the viewport hides the tab it warns about',
        );
        expect(
          tester.getSize(find.byKey(const Key('the-content'))).height,
          greaterThan(0),
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('an ordinary phone viewport is unaffected', (tester) async {
      setViewportSize(tester, const Size(390, 844));
      final container = makeContainer(
        pruneOutcome: const PublicPhotoPruneOutcome(
          reason: PublicPhotoPruneReason.nothingPrunable,
          usedFractionBefore: 0.9,
          usedFractionAfter: 0.9,
        ),
      );

      await tester.pumpWidget(wrap(container));
      await tester.pump();

      expect(
        find.textContaining('Storage is nearly full'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
