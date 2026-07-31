import 'storage_persistence.dart';
import 'storage_persistence_types.dart';

/// The three storage-persistence capabilities behind an interface, purely so
/// tests can substitute a fake — the same reason
/// `ConnectivityService` (`lib/features/backup/data/connectivity_service.dart`)
/// and `PhotoByteStore` (`lib/features/topo/data/photo_byte_store.dart`) are
/// interfaces.
///
/// This matters more than usual here: the real implementation
/// (`storage_persistence_web.dart`) is only selected when
/// `dart.library.js_interop` is available, so its code NEVER runs under
/// `flutter test`. Every VM test of the controller and the boot wiring runs
/// against a fake through this interface, and the browser code itself is
/// covered by `integration_test/web_storage_persistence_test.dart` in real
/// headless Chrome.
abstract class StoragePersistenceService {
  /// Asks the platform to make this origin's storage persistent. Implementations
  /// must never throw — they report failure as
  /// [StoragePersistOutcome.failed].
  Future<StoragePersistOutcome> requestPersist();

  /// Whether storage IS persistent right now, regardless of who made it so.
  Future<bool> isPersisted();

  /// Current origin-wide usage/quota, or `null` when unavailable.
  Future<StorageEstimateSnapshot?> estimate();
}

/// Production [StoragePersistenceService]: a thin delegate to the
/// conditionally-exported platform functions in `storage_persistence.dart`
/// (web: real `navigator.storage`; native and `flutter test`: the inert
/// stub).
class PlatformStoragePersistenceService implements StoragePersistenceService {
  const PlatformStoragePersistenceService();

  @override
  Future<StoragePersistOutcome> requestPersist() => requestPersistentStorage();

  @override
  Future<bool> isPersisted() => isStoragePersisted();

  @override
  Future<StorageEstimateSnapshot?> estimate() => estimateStorage();
}
