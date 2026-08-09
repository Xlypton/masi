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

  group('the height cap — the bound this banner was the only one missing', () {
    void setViewportSize(WidgetTester tester, Size size) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    /// Mirrors `storage_pressure_banner_test.dart`'s identical harness: the
    /// notice above a stand-in for the tab content, so "the content beneath
    /// stays reachable" is an assertion about a real `Column`, not about the
    /// banner in isolation.
    Widget wrapWithContent(ProviderContainer container, {double textScale = 1.0}) {
      return UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: MasiTheme.light,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
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
      );
    }

    testWidgets(
      'leaves most of a squeezed viewport to the tab content beneath it — the '
      'sibling notices all cap at this share, and this one did not',
      (tester) async {
        // The exact surface `nav_shell_test.dart` and
        // `topos_storage_banner.dart` both record a measured overflow at.
        // Unbounded, this banner sized itself to its content and pushed the
        // branch below it into an 11px `RenderFlex` overflow the moment its
        // actions were (correctly) raised to the 44pt tap-target floor.
        const surface = Size(400, 420);
        setViewportSize(tester, surface);
        final (container: container, opens: _) = makeContainer(
          retryStatus: StorageRetryStatus.failed,
        );
        container
            .read(storageDurabilityProvider.notifier)
            .report(
              const StorageDurability.unavailable(
                'the local database did not answer its first query within 30s',
              ),
            );

        await tester.pumpWidget(wrapWithContent(container, textScale: 3.0));
        await tester.pump();

        expect(
          tester.getSize(find.byKey(const Key('storage-retry-banner'))).height,
          lessThan(surface.height * 0.5),
          reason: 'a notice that eats the viewport hides the tab it warns '
              'about',
        );
        expect(
          tester.getSize(find.byKey(const Key('the-content'))).height,
          greaterThan(0),
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'the 44pt floor on both actions survives the cap — the overflow is '
      'fixed by bounding the banner, never by shrinking the tap targets',
      (tester) async {
        setViewportSize(tester, const Size(390, 844));
        final (container: container, opens: _) = makeContainer(
          retryStatus: StorageRetryStatus.failed,
        );
        container
            .read(storageDurabilityProvider.notifier)
            .report(const StorageDurability.unavailable('dead'));

        await tester.pumpWidget(wrapWithContent(container));
        await tester.pump();

        for (final key in const [
          Key('storage-retry-banner-action'),
          Key('storage-retry-banner-reload'),
        ]) {
          final size = tester.getSize(find.byKey(key));
          expect(
            size.width,
            greaterThanOrEqualTo(44.0),
            reason: '$key must stay at the HIG minimum tap target',
          );
          expect(size.height, greaterThanOrEqualTo(44.0), reason: '$key');
        }
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('an ordinary phone viewport is unaffected', (tester) async {
      setViewportSize(tester, const Size(390, 844));
      final (container: container, opens: _) = makeContainer();
      container
          .read(storageDurabilityProvider.notifier)
          .report(const StorageDurability.unavailable('dead'));

      await tester.pumpWidget(wrapWithContent(container));
      await tester.pump();

      expect(find.textContaining("storage isn't responding"), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('dismissibility (the user\'s decision — every banner in this family '
      'closes, episode-scoped)', () {
    /// Exercises [StorageRetryBanner] directly rather than through
    /// [ShellNotices]: the widget's own dismiss/re-arm contract is what is
    /// under test here, not `storageDurabilityProvider`'s computation of
    /// [notice] — that pipeline is already covered above.
    Widget wrapBannerDirect(ProviderContainer container, String notice) =>
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: MasiTheme.light,
            home: Scaffold(body: StorageRetryBanner(notice: notice)),
          ),
        );

    testWidgets('tapping dismiss hides the banner', (tester) async {
      final (container: container, opens: _) = makeContainer();

      await tester.pumpWidget(
        wrapBannerDirect(container, "Your topos couldn't be opened."),
      );
      await tester.pump();

      expect(find.byKey(const Key('storage-retry-banner')), findsOneWidget);

      await tester.tap(find.byKey(const Key('storage-retry-banner-dismiss')));
      await tester.pump();

      expect(find.byKey(const Key('storage-retry-banner')), findsNothing);
    });

    testWidgets(
      'a dismissed message re-arms the moment the notice text changes '
      '(escalation), even though the widget never unmounted',
      (tester) async {
        final (container: container, opens: _) = makeContainer();

        await tester.pumpWidget(wrapBannerDirect(container, 'Message A'));
        await tester.pump();
        await tester.tap(
          find.byKey(const Key('storage-retry-banner-dismiss')),
        );
        await tester.pump();
        expect(find.byKey(const Key('storage-retry-banner')), findsNothing);

        // Same widget slot, same State, but a DIFFERENT notice — mirrors
        // `idle` escalating to `failed` (the reload paragraph appearing).
        await tester.pumpWidget(wrapBannerDirect(container, 'Message B'));
        await tester.pump();

        expect(
          find.byKey(const Key('storage-retry-banner')),
          findsOneWidget,
          reason: 'a different message is a different episode and must not '
              'stay hidden behind an acknowledgement of the old one',
        );
      },
    );

    testWidgets(
      'the SAME message stays dismissed across rebuilds within one mount '
      '(a dismissal is not knocked loose by an unrelated rebuild)',
      (tester) async {
        final (container: container, opens: _) = makeContainer();

        await tester.pumpWidget(wrapBannerDirect(container, 'Message A'));
        await tester.pump();
        await tester.tap(
          find.byKey(const Key('storage-retry-banner-dismiss')),
        );
        await tester.pump();
        expect(find.byKey(const Key('storage-retry-banner')), findsNothing);

        // Rebuilding with the IDENTICAL notice must not resurrect it.
        await tester.pumpWidget(wrapBannerDirect(container, 'Message A'));
        await tester.pump();
        expect(find.byKey(const Key('storage-retry-banner')), findsNothing);
      },
    );

    testWidgets(
      'the condition clearing and then recurring re-arms a dismissal, even '
      'with the identical message — through the REAL ShellNotices path',
      (tester) async {
        final (container: container, opens: _) = makeContainer();
        container
            .read(storageDurabilityProvider.notifier)
            .report(const StorageDurability.unavailable('dead'));

        await tester.pumpWidget(wrap(container));
        await tester.pump();
        expect(find.byKey(const Key('storage-retry-banner')), findsOneWidget);

        await tester.tap(
          find.byKey(const Key('storage-retry-banner-dismiss')),
        );
        await tester.pump();
        expect(find.byKey(const Key('storage-retry-banner')), findsNothing);

        // The condition clears entirely — `ShellNotices` removes this
        // widget from the tree, disposing its State (and the dismissal
        // with it).
        container
            .read(storageDurabilityProvider.notifier)
            .report(const StorageDurability.probing());
        await tester.pump();
        expect(find.byKey(const Key('storage-retry-banner')), findsNothing);

        // ...and recurs, with the SAME message. A fresh episode of an old
        // failure must not stay silenced by the earlier acknowledgement.
        container
            .read(storageDurabilityProvider.notifier)
            .report(const StorageDurability.unavailable('dead'));
        await tester.pump();
        expect(
          find.byKey(const Key('storage-retry-banner')),
          findsOneWidget,
          reason: 'a new episode of the same failure must re-arm, not stay '
              'hidden behind the earlier dismissal',
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
