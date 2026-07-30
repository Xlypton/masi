/// Value types for the browser storage-persistence seam
/// (`storage_persistence.dart`).
///
/// Kept in their own file — rather than beside the seam — so BOTH backends
/// (`storage_persistence_stub.dart`, `storage_persistence_web.dart`) can
/// import them without importing the facade that exports those backends,
/// which would be a circular import. Same layout as
/// `lib/features/account/application/pwa_install_types.dart`.
library;

import 'package:flutter/foundation.dart';

/// Result of the ONE-SHOT "please make this origin's storage persistent"
/// request the app fires during boot (see `StoragePersistenceController`).
///
/// Why this exists (design doc §1b, data-loss path L2): both of this app's
/// browser stores — the drift database `climbtopo`
/// (`lib/core/db/connection/connection_web.dart`) and the photo bytes
/// `climbtopo-photos` (`lib/features/topo/data/photo_byte_store.dart`) — are
/// BEST-EFFORT storage by default, i.e. the browser may evict them: iOS
/// Safari purges an unused origin after about 7 days, and Chrome evicts
/// non-persistent origins under storage pressure. A granted
/// `navigator.storage.persist()` exempts the origin from that ordinary
/// eviction. Nothing outside a browser can evict this app's data, which is
/// why the whole seam is web-only.
enum StoragePersistOutcome {
  /// Nothing has been asked yet — the initial `storagePersistenceProvider`
  /// state, and what it still reads as synchronously after boot has *started*
  /// the request.
  notRequested,

  /// This platform has no evictable-storage concept to protect: every
  /// non-browser build (iOS/Android/desktop, and plain-Dart `flutter test`)
  /// writes to a real file system that nothing silently purges. Terminal
  /// state off the browser.
  notApplicable,

  /// Running in a browser, but one that exposes no
  /// `navigator.storage.persist` to call. Also what an insecure context looks
  /// like: `navigator.storage` is only exposed to secure contexts (HTTPS or
  /// localhost).
  unsupported,

  /// The browser granted persistence — this origin's storage is now exempt
  /// from ordinary eviction.
  granted,

  /// The browser refused: its own engagement heuristics, or the user declined
  /// on the engines that show a prompt. Storage still works, it is simply
  /// best-effort/evictable.
  denied,

  /// The request threw/rejected. Recorded rather than propagated — a failed
  /// persistence request must never affect boot.
  failed,
}

/// `navigator.storage.estimate()`'s two numbers, in bytes, with `null`
/// meaning "the browser did not report it" (never zero — zero usage and
/// unknown usage are different facts).
///
/// Both numbers are ORIGIN-WIDE: they cover the drift database, the photo
/// byte store, the Cache API and everything else this origin stores, not any
/// single store. Browsers also deliberately pad/round them, so treat them as
/// approximate.
@immutable
class StorageEstimateSnapshot {
  const StorageEstimateSnapshot({this.usageBytes, this.quotaBytes});

  final int? usageBytes;
  final int? quotaBytes;

  /// `usage / quota` in `0.0 .. 1.0`, or `null` when either number is missing
  /// or the quota is not a positive number.
  double? get usedFraction {
    final usage = usageBytes;
    final quota = quotaBytes;
    if (usage == null || quota == null || quota <= 0) return null;
    return usage / quota;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StorageEstimateSnapshot &&
          other.usageBytes == usageBytes &&
          other.quotaBytes == quotaBytes);

  @override
  int get hashCode => Object.hash(usageBytes, quotaBytes);

  @override
  String toString() =>
      'StorageEstimateSnapshot(usageBytes: $usageBytes, '
      'quotaBytes: $quotaBytes)';
}

/// Everything the app knows about how durable this origin's local storage is.
/// Written once at boot by `requestPersistentStorageAtBoot` (`lib/main.dart`)
/// and read by the Account screen's storage-diagnostics row (design doc §2c).
@immutable
class StoragePersistenceStatus {
  const StoragePersistenceStatus({
    this.outcome = StoragePersistOutcome.notRequested,
    this.persisted = false,
    this.estimate,
  });

  /// What boot's one-shot `persist()` request answered.
  final StoragePersistOutcome outcome;

  /// Last known `navigator.storage.persisted()`: whether this origin's
  /// storage IS persistent right now, independent of whether our own request
  /// is what made it so (a previously-granted grant survives reloads).
  /// Always `false` off the browser — use [outcome] `notApplicable` to tell
  /// "no browser" apart from "browser said no".
  final bool persisted;

  /// Last known `navigator.storage.estimate()`, or `null` when it was never
  /// read or is unavailable.
  final StorageEstimateSnapshot? estimate;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StoragePersistenceStatus &&
          other.outcome == outcome &&
          other.persisted == persisted &&
          other.estimate == estimate);

  @override
  int get hashCode => Object.hash(outcome, persisted, estimate);

  @override
  String toString() =>
      'StoragePersistenceStatus(outcome: $outcome, persisted: $persisted, '
      'estimate: $estimate)';
}
