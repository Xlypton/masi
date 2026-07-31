import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'connection/storage_durability.dart';

export 'connection/storage_durability.dart';

/// App-wide, release-observable answer to "can this device actually keep the
/// data we write?".
///
/// Fed by `appDatabaseProvider` (`database_provider.dart`), which hands
/// [StorageDurabilityNotifier.report] to `openConnection()` as its
/// `onStorageReport` callback:
///  - native reports [StorageBackend.nativeFile] synchronously, before the
///    executor is even returned, so it is in its final durable state on the
///    very first frame;
///  - web reports once `WasmDatabase.open`'s browser-feature probe resolves,
///    which is what makes L1 (a silent [StorageBackend.inMemory] backend that
///    loses the entire library on reload) visible for the first time.
///
/// Read by `topos_screen.dart` to disable BOTH create-topo affordances and
/// render `_StorageWarningBanner` whenever [StorageDurability.isEphemeral].
/// Stage 2's runtime-diagnostics row (design doc §2c) is expected to read the
/// same provider rather than re-probing.
///
/// Not `.autoDispose`: there is exactly one verdict per app run and every
/// later reader must see it, including ones that mount long after boot.
class StorageDurabilityNotifier extends Notifier<StorageDurability> {
  @override
  StorageDurability build() => const StorageDurability.probing();

  /// Records — and unconditionally logs — the connection layer's verdict.
  ///
  /// Logs BEFORE the `ref.mounted` check on purpose: a verdict that arrives
  /// after the container was torn down (a web probe resolving during a hot
  /// restart, say) is still the most valuable line in the console, and
  /// dropping it silently is the exact failure mode §1a exists to end.
  /// Assigning `state` after disposal would throw, hence the guard.
  void report(StorageDurability durability) {
    logStorageDurability(durability);
    if (!ref.mounted) return;
    state = durability;
  }
}

final storageDurabilityProvider =
    NotifierProvider<StorageDurabilityNotifier, StorageDurability>(
  StorageDurabilityNotifier.new,
);
