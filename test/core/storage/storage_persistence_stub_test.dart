import 'package:flutter_test/flutter_test.dart';
import 'package:masi/core/storage/storage_persistence.dart';
import 'package:masi/core/storage/storage_persistence_types.dart';

/// Verifies the native/test storage-persistence backend
/// (`storage_persistence_stub.dart`, reached here through the
/// `storage_persistence.dart` facade because plain-VM `flutter_test` has no
/// `dart.library.js_interop`) is completely inert: nothing outside a browser
/// can evict this app's local data, so there is nothing to request and
/// nothing to measure. Mirrors
/// `test/features/account/application/pwa_install_stub_test.dart`.
void main() {
  group('storage_persistence stub backend', () {
    test('requestPersistentStorage reports notApplicable', () async {
      expect(
        await requestPersistentStorage(),
        StoragePersistOutcome.notApplicable,
      );
    });

    test('requestPersistentStorage is inert when called repeatedly', () async {
      expect(
        await requestPersistentStorage(),
        StoragePersistOutcome.notApplicable,
      );
      expect(
        await requestPersistentStorage(),
        StoragePersistOutcome.notApplicable,
      );
    });

    test('isStoragePersisted is always false', () async {
      expect(await isStoragePersisted(), isFalse);
    });

    test('estimateStorage is always null (unknown, not zero)', () async {
      expect(await estimateStorage(), isNull);
    });
  });
}
