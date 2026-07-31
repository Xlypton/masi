import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'storage_persistence_service.dart';
import 'storage_persistence_types.dart';

/// The [StoragePersistenceService] boot's request and the Account screen's
/// diagnostics row go through. Defaults to the real platform delegate (web:
/// `navigator.storage`; native/tests: the inert stub); override it in tests
/// with a fake — see
/// `test/core/storage/storage_persistence_providers_test.dart`.
final storagePersistenceServiceProvider = Provider<StoragePersistenceService>(
  (ref) => const PlatformStoragePersistenceService(),
);

/// Owns the app's single [StoragePersistenceStatus]: the outcome of boot's
/// one-shot `navigator.storage.persist()` request plus the last known
/// `persisted()` / `estimate()` readings.
///
/// Riverpod v3 [Notifier] (never `StateProvider` — see CLAUDE.md), mirroring
/// `WifiOnlySetting` in
/// `lib/features/backup/application/backup_providers.dart`.
class StoragePersistenceController extends Notifier<StoragePersistenceStatus> {
  /// Memoised [requestPersistenceOnce] future — the "exactly once" guard.
  /// Assigned SYNCHRONOUSLY on the first call (before [_request] reaches its
  /// first `await`), so even two callers in the same microtask can only
  /// produce one `persist()`; kept after it completes, so a later caller gets
  /// the same already-completed future instead of a second request.
  Future<void>? _requestOnce;

  @override
  StoragePersistenceStatus build() => const StoragePersistenceStatus();

  /// Boot entry point (`requestPersistentStorageAtBoot` in `lib/main.dart`):
  /// requests persistent storage once, then records `persisted()` +
  /// `estimate()` into [state].
  ///
  /// NEVER completes with an error — every `await` inside is guarded — so the
  /// fire-and-forget `unawaited(...)` at boot cannot produce an unhandled
  /// async error, and a browser that refuses, lacks, or throws from the
  /// Storage API cannot affect boot. It also never blocks anything: boot
  /// starts the returned future and drops it.
  ///
  /// Idempotent PER CONTAINER. Production calls it once per page load;
  /// `integration_test/` files that call `bootApp()` repeatedly in one
  /// headless-Chrome page build a fresh container each time and so request
  /// once per boot — harmless, since `persist()` is itself idempotent in the
  /// browser and does not re-prompt.
  Future<void> requestPersistenceOnce() => _requestOnce ??= _request();

  Future<void> _request() async {
    final service = ref.read(storagePersistenceServiceProvider);
    StoragePersistOutcome outcome;
    try {
      outcome = await service.requestPersist();
    } catch (e) {
      debugPrint('storage-persistence: persist() threw: $e');
      outcome = StoragePersistOutcome.failed;
    }
    // Read the diagnostics even when the request itself failed: "denied, and
    // here is how full you are" is the interesting case.
    final persisted = await _readPersisted(service);
    final estimate = await _readEstimate(service);
    // This future can outlive its container (a disposed test container, a
    // torn-down page), and writing `state` after disposal throws.
    if (!ref.mounted) return;
    state = StoragePersistenceStatus(
      outcome: outcome,
      persisted: persisted,
      estimate: estimate,
    );
    if (outcome != StoragePersistOutcome.notApplicable) {
      // Deliberately NOT behind `kDebugMode`: alongside the drift storage
      // backend logged by `connection_web.dart`, this is the first thing to
      // check in any "my data vanished" web report — and release builds are
      // exactly where those come from. Silent on native, where the outcome
      // is always `notApplicable`.
      debugPrint(
        'storage-persistence: outcome=${outcome.name} persisted=$persisted '
        'estimate=$estimate',
      );
    }
  }

  /// Re-reads `persisted()` + `estimate()` WITHOUT re-requesting persistence
  /// — the refresh path for the Account screen's diagnostics row (usage grows
  /// as photos are imported). Preserves
  /// [StoragePersistenceStatus.outcome] and never throws.
  Future<void> refresh() async {
    final service = ref.read(storagePersistenceServiceProvider);
    final persisted = await _readPersisted(service);
    final estimate = await _readEstimate(service);
    if (!ref.mounted) return;
    state = StoragePersistenceStatus(
      outcome: state.outcome,
      persisted: persisted,
      estimate: estimate,
    );
  }

  Future<bool> _readPersisted(StoragePersistenceService service) async {
    try {
      return await service.isPersisted();
    } catch (e) {
      debugPrint('storage-persistence: persisted() threw: $e');
      return false;
    }
  }

  Future<StorageEstimateSnapshot?> _readEstimate(
    StoragePersistenceService service,
  ) async {
    try {
      return await service.estimate();
    } catch (e) {
      debugPrint('storage-persistence: estimate() threw: $e');
      return null;
    }
  }
}

/// App-wide storage-durability snapshot: written once at boot by
/// `requestPersistentStorageAtBoot` (`lib/main.dart`) and read by the Account
/// screen's storage-diagnostics row (design doc §2c), which can call
/// `ref.read(storagePersistenceProvider.notifier).refresh()` for a live
/// usage/quota re-read.
final storagePersistenceProvider =
    NotifierProvider<StoragePersistenceController, StoragePersistenceStatus>(
      StoragePersistenceController.new,
    );
