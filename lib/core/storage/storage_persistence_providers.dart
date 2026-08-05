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

  /// De-dupes concurrent [requestPersistenceAgain] calls onto a single
  /// in-flight `persist()` — same `_inFlight`-style shape as
  /// `ReachabilityController.refresh()`
  /// (`lib/features/backup/application/reachability_providers.dart`):
  /// assigned SYNCHRONOUSLY (before [_request] reaches its first `await`), so
  /// same-microtask callers collapse onto one request; CLEARED on completion
  /// (unlike [_requestOnce]), so a later, separate re-ask (e.g. a second
  /// `appinstalled`-shaped event, however unlikely) is not permanently
  /// blocked by an earlier one having already run.
  Future<void>? _reRequestInFlight;

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

  /// Re-request entry point for LATER in the same session, once a stronger
  /// grant signal becomes available than existed at boot — an installed PWA
  /// at a later cold boot, or the `appinstalled` event firing mid-session
  /// (`lib/main.dart`'s `requestPersistentStorageAtBoot` is the only caller
  /// today). Unlike [requestPersistenceOnce] this is deliberately NOT
  /// memoised for the container's whole lifetime: a denial is not sticky —
  /// both engines re-evaluate the same heuristics on a later call (see this
  /// seam's design doc, §1b) — so calling this again after a real-world event
  /// must be able to produce a fresh `persist()`, not the first call's
  /// long-since-completed future.
  ///
  /// Still guarded against hammering the API, two ways:
  ///  - concurrent callers collapse onto ONE in-flight `persist()` via
  ///    [_reRequestInFlight], exactly like [requestPersistenceOnce]'s
  ///    [_requestOnce] guard;
  ///  - skipped ENTIRELY, before any `persist()` call, when [state] already
  ///    reports [StoragePersistOutcome.granted] or `persisted == true`
  ///    (nothing left to gain) or [StoragePersistOutcome.unsupported]
  ///    (nothing to ask) — see [_canGainFromReRequest].
  ///
  /// Same never-throws contract as [requestPersistenceOnce]: every `await`
  /// inside [_request] is guarded, so a fire-and-forget caller can never
  /// produce an unhandled async error.
  Future<void> requestPersistenceAgain() {
    if (!_canGainFromReRequest()) return Future<void>.value();
    return _reRequestInFlight ??= _request().whenComplete(
      () => _reRequestInFlight = null,
    );
  }

  /// Whether a fresh `persist()` call could plausibly change anything.
  /// `false` for [StoragePersistOutcome.granted] and `persisted == true`
  /// (already have what a re-request buys) and for
  /// [StoragePersistOutcome.unsupported] (no API to call at all — asking
  /// again would just re-derive the same "no API" answer). `true` for
  /// everything else, INCLUDING the initial [StoragePersistOutcome.notRequested]
  /// and a prior `denied`/`failed`/`notApplicable` — a denial is not sticky,
  /// so it is always worth asking again given a genuinely new signal.
  bool _canGainFromReRequest() {
    final current = state;
    if (current.outcome == StoragePersistOutcome.unsupported) return false;
    if (current.outcome == StoragePersistOutcome.granted) return false;
    if (current.persisted) return false;
    return true;
  }

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
