import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/core/storage/storage_persistence_providers.dart';
import 'package:masi/core/storage/storage_persistence_service.dart';
import 'package:masi/core/storage/storage_persistence_types.dart';

/// Counting [StoragePersistenceService] double.
///
/// The real browser backend (`storage_persistence_web.dart`) NEVER executes
/// under `flutter test` — the VM has no `dart.library.js_interop`, so the
/// facade resolves to the inert stub — which is exactly why
/// [StoragePersistenceController] talks to this interface instead of calling
/// the seam functions directly. The browser code itself is covered by
/// `integration_test/web_storage_persistence_test.dart`.
class _FakeStoragePersistenceService implements StoragePersistenceService {
  _FakeStoragePersistenceService({
    this.outcome = StoragePersistOutcome.granted,
    this.persisted = true,
    this.throwOnRequest = false,
    this.throwOnPersisted = false,
    this.throwOnEstimate = false,
  });

  final StoragePersistOutcome outcome;
  final bool throwOnRequest;
  final bool throwOnPersisted;
  final bool throwOnEstimate;

  // Mutable so a test can change what the browser "reports" between the
  // boot request and a later refresh(). `persisted` keeps its constructor
  // parameter because a test passes `persisted: false`; `estimateSnapshot` is
  // only ever reassigned mid-test, so initialising it directly here avoids an
  // unused constructor parameter (and the `unused_element_parameter`
  // suppression that used to sit on it).
  bool persisted;
  StorageEstimateSnapshot? estimateSnapshot = const StorageEstimateSnapshot(
    usageBytes: 1024,
    quotaBytes: 8192,
  );

  int requestCalls = 0;
  int persistedCalls = 0;
  int estimateCalls = 0;

  @override
  Future<StoragePersistOutcome> requestPersist() async {
    requestCalls++;
    if (throwOnRequest) throw StateError('persist-boom');
    return outcome;
  }

  @override
  Future<bool> isPersisted() async {
    persistedCalls++;
    if (throwOnPersisted) throw StateError('persisted-boom');
    return persisted;
  }

  @override
  Future<StorageEstimateSnapshot?> estimate() async {
    estimateCalls++;
    if (throwOnEstimate) throw StateError('estimate-boom');
    return estimateSnapshot;
  }
}

/// Container over [service], or over the production default when omitted.
ProviderContainer _makeContainer([StoragePersistenceService? service]) {
  final container = ProviderContainer(
    overrides: [
      if (service != null)
        storagePersistenceServiceProvider.overrideWithValue(service),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('starts at notRequested without touching the platform', () {
    final fake = _FakeStoragePersistenceService();
    final container = _makeContainer(fake);

    expect(
      container.read(storagePersistenceProvider),
      const StoragePersistenceStatus(),
    );
    expect(fake.requestCalls, 0);
    expect(fake.persistedCalls, 0);
    expect(fake.estimateCalls, 0);
  });

  test('records a granted request plus persisted() and estimate()', () async {
    final fake = _FakeStoragePersistenceService();
    final container = _makeContainer(fake);

    await container
        .read(storagePersistenceProvider.notifier)
        .requestPersistenceOnce();

    expect(
      container.read(storagePersistenceProvider),
      const StoragePersistenceStatus(
        outcome: StoragePersistOutcome.granted,
        persisted: true,
        estimate: StorageEstimateSnapshot(usageBytes: 1024, quotaBytes: 8192),
      ),
    );
    expect(fake.requestCalls, 1);
    expect(fake.persistedCalls, 1);
    expect(fake.estimateCalls, 1);
  });

  test('records a denied request without throwing', () async {
    final fake = _FakeStoragePersistenceService(
      outcome: StoragePersistOutcome.denied,
      persisted: false,
    );
    final container = _makeContainer(fake);

    await container
        .read(storagePersistenceProvider.notifier)
        .requestPersistenceOnce();

    final status = container.read(storagePersistenceProvider);
    expect(status.outcome, StoragePersistOutcome.denied);
    expect(status.persisted, isFalse);
    expect(status.estimate?.quotaBytes, 8192);
  });

  test('a throwing persist() degrades to failed; the future completes '
      'normally (an await that rethrew would fail this test)', () async {
    final fake = _FakeStoragePersistenceService(throwOnRequest: true);
    final container = _makeContainer(fake);

    await container
        .read(storagePersistenceProvider.notifier)
        .requestPersistenceOnce();

    final status = container.read(storagePersistenceProvider);
    expect(status.outcome, StoragePersistOutcome.failed);
    // The remaining reads still happen: a refused/broken persist() must not
    // cost us the diagnostics.
    expect(status.persisted, isTrue);
    expect(status.estimate?.usageBytes, 1024);
  });

  test('persist() is requested EXACTLY ONCE however many callers ask',
      () async {
    final fake = _FakeStoragePersistenceService();
    final container = _makeContainer(fake);
    final controller = container.read(storagePersistenceProvider.notifier);

    // Two callers in the same microtask, then a third after completion.
    await Future.wait([
      controller.requestPersistenceOnce(),
      controller.requestPersistenceOnce(),
    ]);
    await controller.requestPersistenceOnce();

    expect(fake.requestCalls, 1);
    expect(fake.persistedCalls, 1);
    expect(fake.estimateCalls, 1);
    expect(
      container.read(storagePersistenceProvider).outcome,
      StoragePersistOutcome.granted,
    );
  });

  test('an estimate() failure leaves usage/quota unknown but keeps the '
      'outcome', () async {
    final fake = _FakeStoragePersistenceService(throwOnEstimate: true);
    final container = _makeContainer(fake);

    await container
        .read(storagePersistenceProvider.notifier)
        .requestPersistenceOnce();

    final status = container.read(storagePersistenceProvider);
    expect(status.outcome, StoragePersistOutcome.granted);
    expect(status.persisted, isTrue);
    expect(status.estimate, isNull);
  });

  test('a persisted() failure reads as not-persistent and never throws',
      () async {
    final fake = _FakeStoragePersistenceService(throwOnPersisted: true);
    final container = _makeContainer(fake);

    await container
        .read(storagePersistenceProvider.notifier)
        .requestPersistenceOnce();

    final status = container.read(storagePersistenceProvider);
    expect(status.outcome, StoragePersistOutcome.granted);
    expect(status.persisted, isFalse);
    expect(status.estimate?.quotaBytes, 8192);
  });

  test('refresh() re-reads persisted()/estimate() and never re-requests '
      'persist()', () async {
    final fake = _FakeStoragePersistenceService();
    final container = _makeContainer(fake);
    final controller = container.read(storagePersistenceProvider.notifier);

    await controller.requestPersistenceOnce();
    fake.estimateSnapshot = const StorageEstimateSnapshot(
      usageBytes: 4096,
      quotaBytes: 8192,
    );

    await controller.refresh();

    final status = container.read(storagePersistenceProvider);
    expect(status.estimate?.usageBytes, 4096);
    expect(status.outcome, StoragePersistOutcome.granted,
        reason: 'refresh must preserve the boot request outcome');
    expect(fake.requestCalls, 1, reason: 'refresh must not re-request');
    expect(fake.estimateCalls, 2);
    expect(fake.persistedCalls, 2);
  });

  test('the production default service is inert off the browser', () async {
    // No override: `PlatformStoragePersistenceService` delegates to the
    // conditionally-exported seam, which on the Dart VM is the stub — the
    // same code path every native (iOS/Android) build takes.
    final container = _makeContainer();

    expect(
      container.read(storagePersistenceServiceProvider),
      isA<PlatformStoragePersistenceService>(),
    );

    await container
        .read(storagePersistenceProvider.notifier)
        .requestPersistenceOnce();

    expect(
      container.read(storagePersistenceProvider),
      const StoragePersistenceStatus(
        outcome: StoragePersistOutcome.notApplicable,
      ),
    );
  });
}
