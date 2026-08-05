// Boot-wiring coverage for the §1b persistent-storage request.
//
// Like `test/main_boot_app_seam_test.dart`, this deliberately does NOT call
// `bootApp()` — that performs real side effects (a real
// `Supabase.initialize`, `path_provider`) and builds its own container with
// no way to observe it. `requestPersistentStorageAtBoot` exists as a named
// top-level function precisely so the wiring can be driven against a test
// container instead.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/core/storage/storage_persistence_providers.dart';
import 'package:masi/core/storage/storage_persistence_service.dart';
import 'package:masi/core/storage/storage_persistence_types.dart';
import 'package:masi/main.dart' show requestPersistentStorageAtBoot;
import 'package:path/path.dart' as p;

/// Trimmed copy of `_FakeStoragePersistenceService` in
/// `test/core/storage/storage_persistence_providers_test.dart` (per-file
/// fakes are this repo's convention — cf. the three `_FakeAuthRepository`
/// declarations): just enough to count calls and to throw on demand.
class _FakeStoragePersistenceService implements StoragePersistenceService {
  _FakeStoragePersistenceService({this.throwEverything = false});

  final bool throwEverything;
  int requestCalls = 0;

  @override
  Future<StoragePersistOutcome> requestPersist() async {
    requestCalls++;
    if (throwEverything) throw StateError('persist-boom');
    return StoragePersistOutcome.granted;
  }

  @override
  Future<bool> isPersisted() async {
    if (throwEverything) throw StateError('persisted-boom');
    return true;
  }

  @override
  Future<StorageEstimateSnapshot?> estimate() async {
    if (throwEverything) throw StateError('estimate-boom');
    return const StorageEstimateSnapshot(usageBytes: 1024, quotaBytes: 8192);
  }
}

ProviderContainer _containerWith(StoragePersistenceService service) {
  final container = ProviderContainer(
    overrides: [storagePersistenceServiceProvider.overrideWithValue(service)],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test(
    'returns before the request resolves, so it can never delay the '
    'first frame',
    () async {
      final fake = _FakeStoragePersistenceService();
      final container = _containerWith(fake);

      requestPersistentStorageAtBoot(container);

      // Synchronously after the call the request is still in flight: the boot
      // wiring started it and returned, exactly as `runApp` needs.
      expect(
        container.read(storagePersistenceProvider).outcome,
        StoragePersistOutcome.notRequested,
      );

      // Calling the controller again returns the SAME memoised future, so this
      // awaits the in-flight boot request rather than starting a second one.
      await container
          .read(storagePersistenceProvider.notifier)
          .requestPersistenceOnce();

      expect(fake.requestCalls, 1);
      final status = container.read(storagePersistenceProvider);
      expect(status.outcome, StoragePersistOutcome.granted);
      expect(status.persisted, isTrue);
      expect(status.estimate?.quotaBytes, 8192);
    },
  );

  test(
    'a platform that throws everywhere can never surface an unhandled '
    'boot error',
    () async {
      final fake = _FakeStoragePersistenceService(throwEverything: true);
      final container = _containerWith(fake);

      // Fire-and-forget, exactly as boot does. If the controller propagated
      // instead of recording, this `unawaited` future would complete with an
      // error and the test zone would fail this test.
      requestPersistentStorageAtBoot(container);

      await container
          .read(storagePersistenceProvider.notifier)
          .requestPersistenceOnce();

      final status = container.read(storagePersistenceProvider);
      expect(status.outcome, StoragePersistOutcome.failed);
      expect(status.persisted, isFalse);
      expect(status.estimate, isNull);
    },
  );

  test('boot wiring is idempotent per container', () async {
    final fake = _FakeStoragePersistenceService();
    final container = _containerWith(fake);

    requestPersistentStorageAtBoot(container);
    requestPersistentStorageAtBoot(container);
    await container
        .read(storagePersistenceProvider.notifier)
        .requestPersistenceOnce();

    expect(fake.requestCalls, 1);
  });

  // --- REGRESSION GUARDS, not runtime proof ---------------------------
  //
  // Both re-ask paths added on top of the original one-shot boot request
  // (see `requestPersistentStorageAtBoot`'s doc in `lib/main.dart`) are
  // structurally UNREACHABLE under `flutter test`:
  //  - `pwaIsStandalone()` resolves to the native/VM stub
  //    (`lib/features/account/application/pwa_install_stub.dart`), which is
  //    hardcoded `false` — `dart.library.js_interop` is never available on
  //    the plain Dart VM this test runs on — so the standalone branch can
  //    never actually be taken here.
  //  - `listenForAppInstalled` resolves to the inert stub
  //    (`lib/core/storage/storage_persistence_stub.dart`) for the same
  //    reason, so the real `web.window.addEventListener('appinstalled', ...)`
  //    registration in `storage_persistence_web.dart` never executes.
  //
  // These two tests therefore pin the SOURCE, not the behaviour: that the
  // call sites exist and are wired to `requestPersistenceAgain()`. Proving
  // they actually fire needs a real browser
  // (`tool/drive_web.sh`, e.g. loading a page already in standalone display
  // mode, or dispatching a synthetic `appinstalled` event) or a physical
  // installed-PWA device test — neither of which this file can do.
  group('REGRESSION GUARDS (source-level — see comment above)', () {
    String readSource(String relativePath) {
      final file = File(p.join(Directory.current.path, relativePath));
      expect(
        file.existsSync(),
        isTrue,
        reason: 'expected $relativePath to exist',
      );
      return file.readAsStringSync();
    }

    test(
      'pwaIsStandalone() is consulted on the persistence boot path, and '
      'leads to requestPersistenceAgain()',
      () {
        final source = readSource('lib/main.dart');
        expect(source, contains('pwaIsStandalone()'));
        expect(source, contains('requestPersistenceAgain()'));
      },
    );

    test(
      'the appinstalled -> Dart bridge exists and is wired to '
      'requestPersistenceAgain()',
      () {
        expect(
          readSource('lib/main.dart'),
          contains('listenForAppInstalled'),
        );
        final webBackend = readSource(
          'lib/core/storage/storage_persistence_web.dart',
        );
        expect(webBackend, contains('listenForAppInstalled'));
        expect(webBackend, contains("'appinstalled'"));
        // The pre-existing handler this bridges alongside must still be
        // there — this change must never have replaced it.
        expect(
          readSource('web/index.html'),
          contains("addEventListener('appinstalled'"),
        );
      },
    );
  });
}
