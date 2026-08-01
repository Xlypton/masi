// Browser-executed coverage for the §1b storage-persistence seam.
//
// This is the ONLY place `lib/core/storage/storage_persistence_web.dart`
// ever runs: the facade selects it only when `dart.library.js_interop` is
// available, so `flutter test` (Dart VM) always gets the inert stub and can
// never catch a wrong interop type. Run it with:
//
//   tool/drive_web.sh integration_test/web_storage_persistence_test.dart
//
// Deliberately dependency-light: it does not boot the whole app (no router,
// no Supabase, no drift), it drives the seam and the boot wiring directly.
//
// `flutter drive -d web-server` does NOT relay the browser's `debugPrint` to
// the terminal, so the values the browser actually reported are pushed out
// through `binding.reportData` instead — the driver
// (`test_driver/integration_test.dart` -> `integrationDriver`'s default
// `writeResponseData`) persists it to
// `build/integration_response_data.json`. That file is the record of what
// `persist()`/`persisted()`/`estimate()` really returned in a real browser,
// which is otherwise unobservable from the run output.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:masi/core/storage/storage_persistence.dart';
import 'package:masi/core/storage/storage_persistence_providers.dart';
import 'package:masi/core/storage/storage_persistence_types.dart';
import 'package:masi/main.dart' show requestPersistentStorageAtBoot;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// Accumulates observations across the four tests — `reportData` is written
  /// once at the end of the whole run, so each test merges into it rather than
  /// replacing it.
  final observed = <String, Object?>{};
  void record(Map<String, Object?> entries) {
    observed.addAll(entries);
    binding.reportData = Map<String, Object?>.from(observed);
  }

  group('web navigator.storage seam', () {
    testWidgets('persist() resolves to a real grant decision', (tester) async {
      final outcome = await requestPersistentStorage();

      record({'persist_outcome': outcome.name});

      // Headless Chrome on localhost IS a secure context and does expose
      // `navigator.storage.persist`. Which way it decides depends on
      // engagement heuristics (a fresh profile is usually denied), so both
      // answers are acceptable — but `unsupported` or `failed` here means
      // the js_interop binding is wrong, not that the browser lacks the API.
      expect(
        outcome,
        anyOf(StoragePersistOutcome.granted, StoragePersistOutcome.denied),
        reason:
            'persist() must resolve to a real boolean decision; got $outcome',
      );
    });

    testWidgets('persisted() agrees with a granted request', (tester) async {
      final outcome = await requestPersistentStorage();
      final persisted = await isStoragePersisted();

      record({
        'persisted_after_request': persisted,
        'persisted_request_outcome': outcome.name,
      });

      if (outcome == StoragePersistOutcome.granted) {
        expect(persisted, isTrue);
      } else {
        // Nothing to assert about a denied bucket beyond "it answered a
        // boolean without throwing", which the type already guarantees.
        expect(persisted, isA<bool>());
      }
    });

    testWidgets('estimate() returns real usage and quota numbers', (
      tester,
    ) async {
      final estimate = await estimateStorage();

      record({
        'estimate_usage_bytes': estimate?.usageBytes,
        'estimate_quota_bytes': estimate?.quotaBytes,
        'estimate_used_fraction': estimate?.usedFraction,
      });

      expect(
        estimate,
        isNotNull,
        reason: 'navigator.storage.estimate() is available in headless '
            'Chrome; null means the interop read failed',
      );
      expect(estimate!.quotaBytes, isNotNull);
      expect(estimate.quotaBytes! > 0, isTrue);
      expect(estimate.usageBytes, isNotNull);
      expect(estimate.usageBytes! >= 0, isTrue);
      expect(estimate.usedFraction, isNotNull);
    });

    testWidgets(
      'the boot wiring records the real browser outcome exactly once',
      (tester) async {
        // No provider overrides: this runs the production
        // PlatformStoragePersistenceService against the real browser.
        final container = ProviderContainer();
        addTearDown(container.dispose);

        requestPersistentStorageAtBoot(container);
        final synchronousOutcome = container
            .read(storagePersistenceProvider)
            .outcome;
        expect(
          synchronousOutcome,
          StoragePersistOutcome.notRequested,
          reason: 'boot must not block on the request',
        );

        await container
            .read(storagePersistenceProvider.notifier)
            .requestPersistenceOnce();

        final status = container.read(storagePersistenceProvider);
        record({
          'boot_outcome_synchronous': synchronousOutcome.name,
          'boot_outcome': status.outcome.name,
          'boot_persisted': status.persisted,
          'boot_quota_bytes': status.estimate?.quotaBytes,
          'boot_usage_bytes': status.estimate?.usageBytes,
        });

        expect(
          status.outcome,
          anyOf(StoragePersistOutcome.granted, StoragePersistOutcome.denied),
        );
        expect(status.estimate, isNotNull);
        expect(status.estimate!.quotaBytes, isNotNull);

        // refresh() must not re-request, and must still produce numbers.
        await container.read(storagePersistenceProvider.notifier).refresh();
        final refreshed = container.read(storagePersistenceProvider);
        record({
          'refreshed_outcome': refreshed.outcome.name,
          'refreshed_quota_bytes': refreshed.estimate?.quotaBytes,
        });
        expect(refreshed.outcome, status.outcome);
        expect(refreshed.estimate, isNotNull);
      },
    );
  });
}
