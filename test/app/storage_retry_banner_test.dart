import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/app/nav_shell.dart';
import 'package:masi/app/page_reload.dart';
import 'package:masi/app/storage_retry_banner.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/core/db/storage_durability_provider.dart';
import 'package:masi/core/db/storage_retry_provider.dart';
import 'package:masi/features/account/application/pwa_install_providers.dart';
import 'package:masi/features/account/application/pwa_install_types.dart';

/// The visible half of UF-4's follow-up: is the retry actually REACHABLE?
///
/// Exercised through [ShellNotices] rather than [StorageRetryBanner] alone,
/// because the decision of WHEN to show it is the part that can regress — and
/// because the notice slot holds exactly one banner, so the install prompt's
/// suppression is part of the same contract.
//
// (Not a `///` library doc: a `library;` directive would have to precede the
// imports above.)

/// A [StorageRetryController] pinned to one status, so the banner's in-flight
/// rendering can be asserted without racing a real re-open (see the test that
/// uses it).
class _PinnedStorageRetryController extends StorageRetryController {
  _PinnedStorageRetryController(this._status);

  final StorageRetryStatus _status;

  @override
  StorageRetryStatus build() => _status;
}

void main() {
  /// A real [MasiTheme] is required: the banner reads `MasiColors.of(context)`,
  /// which throws when no `MasiColors` extension is registered (same reason
  /// `install_banner_test.dart`'s `_wrap` uses it). The `pwaInstallStatus`
  /// override is the one that WOULD render the install banner, so a test that
  /// finds the storage banner instead has proven the priority, not merely that
  /// the install banner was inert.
  Widget wrap(ProviderContainer container) => UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: MasiTheme.light,
      home: const Scaffold(body: ShellNotices()),
    ),
  );

  ({ProviderContainer container, int Function() opens}) makeContainer({
    StorageRetryStatus? retryStatus,
    void Function()? onReload,
  }) {
    var opens = 0;
    final container = ProviderContainer(
      overrides: [
        if (retryStatus != null)
          storageRetryProvider.overrideWith(
            () => _PinnedStorageRetryController(retryStatus),
          ),
        // Overriding this rather than calling through to the real
        // `page_reload.dart` seam is the whole point of injecting it via a
        // provider (see `storage_retry_banner.dart`'s doc): a widget test
        // must be able to observe the escalated action firing without a real
        // reload (which is a no-op off web anyway, but observing that a
        // no-op ran is not the same assertion as observing the SEAM was
        // called).
        if (onReload != null) pageReloadProvider.overrideWithValue(onReload),
        appDatabaseProvider.overrideWith((ref) {
          opens++;
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
      ],
    );
    addTearDown(container.dispose);
    return (container: container, opens: () => opens);
  }

  testWidgets(
    'a failed open shows the retry banner, with a reason and a button — and '
    'suppresses the install prompt',
    (tester) async {
      final (container: container, opens: _) = makeContainer();
      container
          .read(storageDurabilityProvider.notifier)
          .report(
            const StorageDurability.unavailable(
              'the local database did not answer its first query within 30s',
            ),
          );

      await tester.pumpWidget(wrap(container));
      await tester.pump();

      expect(find.byKey(const Key('storage-retry-banner')), findsOneWidget);
      expect(find.byKey(const Key('storage-retry-banner-action')), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      expect(
        find.textContaining("storage isn't responding"),
        findsOneWidget,
        reason: 'clearly worded: what is wrong, not "Error"',
      );
      expect(
        find.byKey(const Key('install-banner')),
        findsNothing,
        reason: '"add this to your home screen" is absurd advice while the app '
            "cannot open its own storage — and two sibling SafeAreas would "
            'open a status-bar-height gap between them',
      );
      expect(
        find.byKey(const Key('storage-retry-banner-reload')),
        findsNothing,
        reason: 'Step 3: at `idle` (a failure reported directly, no retry '
            'attempted yet) the escalated reload action must NOT appear — '
            'the nuclear option is not the first thing a merely-unlucky-once '
            'user should see',
      );
    },
  );

  testWidgets(
    'a merely-SLOW open shows NO retry banner: the boot deadlines exist so a '
    'slow open still paints, and must not be turned into a scary notice',
    (tester) async {
      final (container: container, opens: _) = makeContainer();
      // `probing` is exactly where web sits while `WasmDatabase.open` is still
      // fetching sqlite3.wasm and acquiring OPFS handles.
      expect(container.read(storageDurabilityProvider).isProbing, isTrue);

      await tester.pumpWidget(wrap(container));
      await tester.pump();

      expect(find.byKey(const Key('storage-retry-banner')), findsNothing);
      expect(
        find.byKey(const Key('install-banner')),
        findsOneWidget,
        reason: 'the normal path must be byte-identical to before',
      );
    },
  );

  testWidgets(
    'a schema downgrade shows NO retry banner — re-opening would be refused '
    'again, identically',
    (tester) async {
      final (container: container, opens: _) = makeContainer();
      container
          .read(storageDurabilityProvider.notifier)
          .report(
            const StorageDurability.unavailable(
              'db is newer',
              cause: StorageUnavailableCause.schemaDowngrade,
            ),
          );

      await tester.pumpWidget(wrap(container));
      await tester.pump();

      expect(find.byKey(const Key('storage-retry-banner')), findsNothing);
    },
  );

  testWidgets(
    'tapping "Try again" really re-opens the database, and the banner stands '
    'down once it answers',
    (tester) async {
      final (container: container, opens: opens) = makeContainer();
      container.read(appDatabaseProvider);
      container
          .read(storageDurabilityProvider.notifier)
          .report(const StorageDurability.unavailable('dead'));

      await tester.pumpWidget(wrap(container));
      await tester.pump();
      expect(opens(), 1);

      await tester.tap(find.byKey(const Key('storage-retry-banner-action')));
      await tester.pumpAndSettle();

      expect(
        opens(),
        2,
        reason: 'the tap must re-attempt the OPEN, not just rebuild a widget '
            'that reads an already-failed provider',
      );
      expect(container.read(storageRetryProvider), StorageRetryStatus.idle);
      expect(find.byKey(const Key('storage-retry-banner')), findsNothing);
    },
  );

  testWidgets(
    'the button reports progress and refuses a second tap while a retry is in '
    'flight — and the notice STAYS UP, so a slow web re-open does not look '
    'like it already succeeded',
    (tester) async {
      // The in-flight state is pinned rather than produced by a real retry: an
      // in-memory database re-opens within the same microtask drain as
      // `tester.pump()`, so a genuine attempt is always already finished by the
      // first frame. Pinning it is what makes the assertion about the WIDGET
      // rather than about drift's timing. `storage_retry_test.dart` covers the
      // controller's real transitions.
      final (container: container, opens: _) = makeContainer(
        retryStatus: StorageRetryStatus.retrying,
      );
      container
          .read(storageDurabilityProvider.notifier)
          .report(const StorageDurability.unavailable('dead'));

      await tester.pumpWidget(wrap(container));
      await tester.pump();

      expect(find.byKey(const Key('storage-retry-banner')), findsOneWidget);
      expect(find.text('Trying…'), findsOneWidget);
      final button = tester.widget<TextButton>(
        find.byKey(const Key('storage-retry-banner-action')),
      );
      expect(
        button.onPressed,
        isNull,
        reason: 'a second tap during a slow web re-open would be a no-op the '
            'user reads as a dead button',
      );
      expect(
        find.byKey(const Key('storage-retry-banner-reload')),
        findsNothing,
        reason: 'Step 3: at `retrying` the escalated action must NOT appear '
            'either — an attempt is genuinely in flight and has not been '
            'given the chance to fail yet',
      );
    },
  );

  group('Step 3 — the escalated reload action, offered only after a retry '
      'has already failed', () {
    testWidgets(
      'a FAILED retry shows the reload action, with copy that does not lie',
      (tester) async {
        final (container: container, opens: _) = makeContainer(
          retryStatus: StorageRetryStatus.failed,
        );
        container
            .read(storageDurabilityProvider.notifier)
            .report(const StorageDurability.unavailable('dead'));

        await tester.pumpWidget(wrap(container));
        await tester.pump();

        expect(find.byKey(const Key('storage-retry-banner')), findsOneWidget);
        // The ordinary action stays present and enabled at `failed` too — a
        // retry that failed once is still worth trying again; the reload is
        // an ESCALATION, not a replacement.
        expect(
          find.byKey(const Key('storage-retry-banner-action')),
          findsOneWidget,
        );
        expect(find.text('Try again'), findsOneWidget);
        expect(
          find.byKey(const Key('storage-retry-banner-reload')),
          findsOneWidget,
        );
        expect(
          find.textContaining(
            'Reloading restarts the app. Nothing saved is deleted, and '
            "nothing that hasn't saved yet can be saved while storage isn't "
            'responding.',
          ),
          findsOneWidget,
          reason: 'both halves of the honest copy have to be there: nothing '
              'saved is lost, AND nothing unsaved can be saved while storage '
              "isn't responding",
        );
      },
    );

    testWidgets(
      'tapping the reload action calls the injected seam exactly once',
      (tester) async {
        var reloadCalls = 0;
        final (container: container, opens: _) = makeContainer(
          retryStatus: StorageRetryStatus.failed,
          onReload: () => reloadCalls++,
        );
        container
            .read(storageDurabilityProvider.notifier)
            .report(const StorageDurability.unavailable('dead'));

        await tester.pumpWidget(wrap(container));
        await tester.pump();

        await tester.tap(find.byKey(const Key('storage-retry-banner-reload')));
        await tester.pump();

        expect(
          reloadCalls,
          1,
          reason: 'the widget must go through `pageReloadProvider`, never '
              'call `reloadPage()` directly — this is the only way a test '
              'can observe the escalated action firing at all',
        );
      },
    );
  });

  group('Step 3 — page_reload.dart seam', () {
    test(
      'REGRESSION GUARD: the stub resolved under `flutter test` (no '
      '`dart.library.js_interop`) is a no-op that returns normally',
      () {
        // `flutter test` runs on the VM, so `page_reload.dart`'s conditional
        // export always resolves to `page_reload_stub.dart` here — this is
        // the only way this branch is ever exercised outside a browser.
        // Reverting the stub to something that throws or never returns would
        // turn the one working recovery into a crash (or a second hang) on
        // every platform except a real browser, silently, because nothing
        // else in this suite ever reaches it.
        expect(reloadPage, returnsNormally);
      },
    );
  });
}
