import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/app/nav_shell.dart';
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
  }) {
    var opens = 0;
    final container = ProviderContainer(
      overrides: [
        if (retryStatus != null)
          storageRetryProvider.overrideWith(
            () => _PinnedStorageRetryController(retryStatus),
          ),
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
    },
  );
}
