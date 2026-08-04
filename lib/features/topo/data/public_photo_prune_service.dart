/// Observes real browser storage pressure and, only under it, deletes the
/// cached bytes of OTHER climbers' photos — never the signed-in user's own.
///
/// This is the I/O half of the pruning story. `public_photo_pruner.dart`
/// (pure, import-free) decides *which* keys are safe to drop; this file
/// gathers the inputs it needs (a drift join for ownership + recency, a
/// `navigator.storage.estimate()` reading for pressure), applies that policy,
/// and performs the irreversible part: the byte deletes.
///
/// ## Why this exists
///
/// Every publicly shared photo in the app is downloaded to this device at full
/// resolution by the shared pull, into the same origin quota the user's own
/// photos live in — unbounded, and with no eviction. Since a failed own-photo
/// write now throws rather than silently producing a pixel-less row, a pile of
/// strangers' photos can make the user's next import fail. Bounding the public
/// cache is therefore a data-loss fix, not a housekeeping nicety.
///
/// ## Pruning drops PIXELS, never ROWS — and that is the steady state
///
/// This service never touches a `Photos` or `Walls` row. After a prune the
/// database still holds a `Photos` row whose `localPath` names bytes that no
/// longer exist, and that is correct and intended:
///
///  * the row is what keeps the topo's name, grade, routes and comments
///    readable offline — only the picture goes;
///  * the render paths already degrade a missing key to the gradient
///    placeholder, and `readPhotoBytes` answers `null` rather than throwing;
///  * the next shared pull re-downloads the object and rewrites `localPath` to
///    the very same key, healing the cache for free.
///
/// The consequence for failure handling is worth stating plainly: because a
/// pruned cache is *defined* as "rows whose bytes are absent", a sweep that
/// dies halfway through — a closed IndexedDB connection, a hot restart, the
/// tab being killed — leaves no torn or ambiguous state. Every prefix of the
/// eviction list is a valid, self-consistent outcome, indistinguishable from a
/// sweep that was simply asked to free less. There is nothing to roll back and
/// no repair pass to run. Per-photo deletes are independent and already
/// best-effort on both real backends (`photo_files_web.dart` swallows; the
/// native one no-ops off a cold docs path), and this service additionally
/// catches around each one so a hypothetical throwing backend cannot abort the
/// remainder of the sweep.
///
/// ## Why pruning is rare, batched, and capped
///
/// Three failure modes were traded off against each other:
///
///  * *Pruning too eagerly* churns IndexedDB on every pull for no benefit, so
///    the trigger is a strict crossing of [kPrunePressureHighWatermark] and
///    the sweep stops at the lower [kPrunePressureLowWatermark]. The gap
///    between them is deliberate hysteresis: without it a device parked on the
///    threshold would delete one photo per pull, forever.
///  * *Pruning one photo at a time* is a busy-loop, and worse, it is
///    unmeasurable — browsers pad and round `estimate()`, so a single
///    full-resolution photo can be lost in the noise. Deletes therefore happen
///    in batches of [kPruneBatchSize] and the estimate is re-read once per
///    batch, which is large enough to move the reported number.
///  * *Pruning until the number finally moves* is the dangerous one. If the
///    estimate is stale, padded, or dominated by the user's OWN photos, no
///    amount of foreign deletion will reach the low watermark, and an
///    uncapped loop would wipe the entire public cache — a cache the user then
///    re-downloads over cell data. [kPruneMaxDeletionsPerPass] bounds one
///    pass; sustained genuine pressure is resolved across successive pulls
///    instead, which converges just as surely and far less destructively.
///
/// [kPruneKeepNewestForeign] then floors the most-recently-touched foreign
/// photos off-limits at any pressure, so the part of the community feed the
/// user is actually browsing does not go blank underneath them.
///
/// ## A ROW is not BYTES — why every candidate is probed before it is charged
///
/// The candidate query below is over `photos` ROWS, and a row naming a key is
/// not evidence that the key holds anything: a pruned photo, a photo the pull's
/// byte budget skipped, and a photo whose remote object was missing are ALL
/// defined as "a row whose bytes are absent" (see the section above). So the
/// eviction order has to be filtered against the byte store before it is spent,
/// and that is not a micro-optimisation — it was a confirmed bug:
///
///  * the bounded shared pull fetches foreign photos NEWEST-wall-first and the
///    pruner evicts OLDEST-wall-first, and those two orders are *exact duals*.
///    That is deliberate and it does stop a download/evict ping-pong — but it
///    also means the set the pruner offers is, on a cold device, precisely the
///    set the pull has never fetched. The only foreign keys holding bytes after
///    one pull are the newest `kSharedPhotoByteBudgetPerPull` of them, and that
///    is the very floor [kPruneKeepNewestForeign] refuses to offer (they are
///    the same constant);
///  * `PhotoFiles.deletePhotoBytes` is best-effort and cannot report that it
///    deleted nothing, so every byte-less key still landed in
///    [PublicPhotoPruneOutcome.deletedKeys] and still consumed
///    [kPruneMaxDeletionsPerPass].
///
/// Result before the fix: under real pressure a pass "deleted" 50 keys, freed
/// zero bytes, reported `capReached` with an unmoved fraction, and did the exact
/// same thing on every subsequent pull — while the user's next own-photo import
/// failed on quota, which is the failure this service exists to prevent. Now
/// [PhotoFiles.hasPhotoBytes] (a key lookup, never a blob read) filters the
/// order first, so the cap is only ever spent on keys that hold something, and
/// "nothing of ours is actually cached" reports honestly as
/// [PublicPhotoPruneReason.nothingPrunable] instead of as 50 deletions.
///
/// What that fix does NOT do is invent bytes to free. Where the pressure is the
/// user's OWN photos and no evictable foreign bytes exist, the honest outcome is
/// that this service cannot help, and it must not: the floor and the
/// never-evict-own rule are the two things here that do not bend. Foreign bytes
/// do accumulate past the floor in ordinary use — a photo already on the device
/// costs the pull no budget, so successive pulls reach steadily older photos,
/// and `MissingPhotoByteResolver` writes bytes for whatever the user opens — so
/// the evictable set is genuinely non-empty as soon as more than one pull's
/// worth of foreign bytes is cached. It is only ever empty when there is
/// nothing this service was allowed to free in the first place.
///
/// On native there is no `navigator.storage`, so `estimate()` is always `null`
/// and this service is a permanent no-op — which is right: nothing silently
/// evicts an iOS/Android app's documents directory.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/app_database.dart';
import '../../../core/db/database_provider.dart';
import '../../../core/storage/storage_persistence_providers.dart';
import '../../../core/storage/storage_persistence_service.dart';
import '../../account/application/auth_providers.dart';
import 'photo_files.dart';
import 'public_photo_pruner.dart';

/// Fraction of the origin quota above which pruning becomes permissible.
/// Strictly above — a device sitting exactly on the line does not churn.
const double kPrunePressureHighWatermark = 0.75;

/// Fraction the sweep tries to get back down to before stopping. The gap to
/// [kPrunePressureHighWatermark] is the hysteresis band that stops a device
/// parked at the threshold from pruning on every single pull.
const double kPrunePressureLowWatermark = 0.60;

/// Photos deleted between two `estimate()` readings. Sized to exceed the
/// padding/rounding browsers apply to storage estimates, so each re-read
/// carries real information; one-at-a-time would be both a busy-loop and
/// unmeasurable.
const int kPruneBatchSize = 10;

/// Hard ceiling on one pass, for when the estimate does not respond to
/// deletion (stale reading, or a quota dominated by the user's own photos).
/// Without it a single pass could evict the entire public cache chasing a
/// number that was never going to move.
const int kPruneMaxDeletionsPerPass = 50;

/// The most-recently-touched foreign photos that are never evicted, at any
/// pressure — the working set the user is browsing right now.
const int kPruneKeepNewestForeign = 20;

/// Why a prune pass stopped when it did. Recorded rather than logged so the
/// caller (the shared pull) can report it without this service knowing
/// anything about sync.
enum PublicPhotoPruneReason {
  /// The platform reported no usable usage/quota, so there is no pressure
  /// signal. Nothing is deleted — acting on a guess is worse than waiting.
  /// This is the permanent state on native.
  noEstimate,

  /// Storage is not under pressure. The overwhelmingly common outcome.
  belowHighWatermark,

  /// No signed-in identity is known on this device, so ownership cannot be
  /// established for any photo and nothing is safe to delete.
  unknownSession,

  /// Under pressure, but nothing was prunable: no definitely-foreign photos;
  /// or all of them protected by the keepNewest floor or a shared key; or none
  /// of the ones it WAS allowed to offer actually holds bytes on this device.
  ///
  /// That last case is a normal, expected state, not a failure — a public
  /// `Photos` row whose bytes are absent is what a budget-skipped or
  /// already-pruned photo IS (see the library doc's "A ROW is not BYTES"). It
  /// means this pass genuinely had nothing to free, which is very different from
  /// the pre-fix behaviour of "freeing" 50 keys that held nothing.
  nothingPrunable,

  /// Pressure fell back under [kPrunePressureLowWatermark]. The success case.
  relieved,

  /// The estimate became unreadable partway through; the sweep stopped rather
  /// than keep deleting blind.
  estimateLost,

  /// [PublicPhotoPruneService.maxDeletionsPerPass] was reached while still
  /// over the low watermark. Remaining pressure is left to the next pass.
  capReached,

  /// Everything prunable was pruned and pressure is still high. There is
  /// nothing further this service is permitted to delete.
  poolExhausted,
}

/// What one prune pass did.
class PublicPhotoPruneOutcome {
  const PublicPhotoPruneOutcome({
    required this.reason,
    this.deletedKeys = const [],
    this.failedDeleteCount = 0,
    this.usedFractionBefore,
    this.usedFractionAfter,
  });

  final PublicPhotoPruneReason reason;

  /// Keys whose bytes were successfully deleted, in deletion order
  /// (oldest-touched first).
  final List<String> deletedKeys;

  /// Deletes that threw. The bytes may or may not still be there; either way
  /// the sweep continued and nothing else was affected.
  final int failedDeleteCount;

  /// `usedFraction` that triggered (or did not trigger) the pass.
  final double? usedFractionBefore;

  /// Last `usedFraction` read during the pass.
  final double? usedFractionAfter;

  /// Whether any bytes were actually freed.
  bool get didPrune => deletedKeys.isNotEmpty;

  @override
  String toString() =>
      'PublicPhotoPruneOutcome(reason: ${reason.name}, '
      'deleted: ${deletedKeys.length}, failed: $failedDeleteCount, '
      'fraction: $usedFractionBefore -> $usedFractionAfter)';
}

/// Every live photo row paired with its owning wall's ownership + recency.
///
/// A LEFT JOIN, deliberately: a photo whose wall row is missing entirely — a
/// partial sync, a hand-edited database — must still appear, with a `NULL`
/// owner, so it is counted as unknown-ownership and protected rather than
/// silently vanishing from consideration. An INNER JOIN would also keep it
/// safe by omission, but it would hide the row from the shared-key protection
/// pass below, where its absence would be a real hole.
///
/// Soft-deleted rows are included on purpose. Ownership is a property of the
/// wall, not of its tombstone state: a tombstoned FOREIGN wall's bytes are
/// pure waste and worth reclaiming, while a tombstoned OWN row must still
/// protect its key from a foreign row that happens to share it.
const String _candidateSql = '''
  SELECT p.local_path AS photo_key,
         w.owner_id   AS owner_id,
         w.updated_at AS wall_updated_at
  FROM photos p
  LEFT JOIN walls w ON w.id = p.wall_id
''';

/// Deletes cached foreign photo bytes when — and only when — the origin is
/// genuinely short of storage.
class PublicPhotoPruneService {
  PublicPhotoPruneService({
    required AppDatabase db,
    required PhotoFiles photoFiles,
    required StoragePersistenceService storage,
    required String? Function() currentUid,
    this.pruner = const PublicPhotoPruner(),
    this.highWatermark = kPrunePressureHighWatermark,
    this.lowWatermark = kPrunePressureLowWatermark,
    this.batchSize = kPruneBatchSize,
    this.maxDeletionsPerPass = kPruneMaxDeletionsPerPass,
    this.keepNewestForeign = kPruneKeepNewestForeign,
    // Private fields with named params, matching `SyncService`'s house
    // pattern: a named parameter cannot itself be private, so the initializing
    // formal the lint asks for is not expressible here.
  }) : _db = db, // ignore: prefer_initializing_formals
       _photoFiles = photoFiles, // ignore: prefer_initializing_formals
       _storage = storage, // ignore: prefer_initializing_formals
       _currentUid = currentUid; // ignore: prefer_initializing_formals

  final AppDatabase _db;
  final PhotoFiles _photoFiles;
  final StoragePersistenceService _storage;

  /// Read lazily, per pass, so a sign-out between construction and the prune
  /// is seen — matching how the repositories consume `currentUidProvider`.
  final String? Function() _currentUid;

  final PublicPhotoPruner pruner;
  final double highWatermark;
  final double lowWatermark;
  final int batchSize;
  final int maxDeletionsPerPass;
  final int keepNewestForeign;

  /// Runs one prune pass if storage is under pressure, and returns what it
  /// did. Never throws: the caller is a sync path, and a housekeeping sweep
  /// must never be able to fail a pull.
  Future<PublicPhotoPruneOutcome> pruneIfUnderPressure() async {
    final before = await _readFraction();
    if (before == null) {
      return const PublicPhotoPruneOutcome(
        reason: PublicPhotoPruneReason.noEstimate,
      );
    }
    if (before <= highWatermark) {
      return PublicPhotoPruneOutcome(
        reason: PublicPhotoPruneReason.belowHighWatermark,
        usedFractionBefore: before,
        usedFractionAfter: before,
      );
    }

    // No known identity means no photo can be proven foreign. The pruner
    // enforces this too; checking here avoids a pointless query and gives the
    // caller a distinguishable reason.
    final ownUid = _currentUid();
    if (ownUid == null) {
      return PublicPhotoPruneOutcome(
        reason: PublicPhotoPruneReason.unknownSession,
        usedFractionBefore: before,
        usedFractionAfter: before,
      );
    }

    final order = await _keysHoldingBytes(await _evictionOrder(ownUid));
    if (order.isEmpty) {
      return PublicPhotoPruneOutcome(
        reason: PublicPhotoPruneReason.nothingPrunable,
        usedFractionBefore: before,
        usedFractionAfter: before,
      );
    }

    return _sweep(order: order, before: before);
  }

  /// [order], narrowed to the keys that ACTUALLY hold bytes right now.
  ///
  /// Without this the pass spends [maxDeletionsPerPass] on keys whose bytes are
  /// already gone, frees nothing, and reports the no-ops as deletions — see the
  /// library doc's "A ROW is not BYTES" for the confirmed failure that is.
  /// [PhotoFiles.hasPhotoBytes] is a key lookup rather than a blob read, so
  /// probing is much cheaper than the delete it is deciding about, and the walk
  /// stops as soon as it has more keys than this pass could possibly delete.
  ///
  /// It collects [maxDeletionsPerPass] + 1 rather than exactly the cap so
  /// [_sweep] can still distinguish its two stopping reasons: a leftover key is
  /// what tells "the cap stopped me" ([PublicPhotoPruneReason.capReached]) from
  /// "I ran out of things I was allowed to delete"
  /// ([PublicPhotoPruneReason.poolExhausted]).
  ///
  /// Order is preserved, so the sweep still deletes oldest-touched first.
  Future<List<String>> _keysHoldingBytes(List<String> order) async {
    final wanted = maxDeletionsPerPass + 1;
    final present = <String>[];
    for (final key in order) {
      if (present.length >= wanted) break;
      bool holdsBytes;
      try {
        holdsBytes = await _photoFiles.hasPhotoBytes(key);
      } catch (_) {
        // A probe that throws is "cannot tell", and cannot-tell must not spend
        // a deletion — the real backends never throw here, this is for one that
        // does.
        holdsBytes = false;
      }
      if (holdsBytes) present.add(key);
    }
    return present;
  }

  /// Builds the ordered list of keys this pass is ALLOWED to delete: the
  /// pruner's oldest-first verdict, minus any key that is also referenced by a
  /// row the pruner declined to offer, minus duplicates.
  ///
  /// Permission only — this speaks about rows, so a key here may well hold no
  /// bytes at all. [_keysHoldingBytes] is what turns permission into work.
  Future<List<String>> _evictionOrder(String ownUid) async {
    final rows = await _db.customSelect(_candidateSql).get();

    final candidates = <PrunablePhoto>[];

    /// Surrogate key -> the real stored key it stands for. Two photo rows can
    /// legitimately name the SAME stored key (the shared pull writes one
    /// object per distinct remote id and rewrites every referring row's
    /// `localPath` to it), so the pruner — which speaks in keys — has to be
    /// asked about ROWS instead, or a verdict about one row would be
    /// misattributed to another that merely shares its bytes.
    ///
    /// The surrogate is `<storedKey>\u0000<rowIndex>`. NUL sorts below every
    /// character that can occur in a photo key, so surrogates sort exactly as
    /// their stored keys do and the row index breaks ties only between rows
    /// that share a key — the pruner's deterministic key tie-break survives
    /// intact.
    final storedKeyBySurrogate = <String, String>{};

    /// Keys that must survive no matter what the pruner says, because some
    /// row referencing them could not be ranked at all (missing wall row, or
    /// a malformed `updated_at`).
    final unrankable = <String>{};

    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      final key = row.readNullable<String>('photo_key');
      // A row with no addressable key names no bytes; there is nothing to
      // delete and nothing to protect.
      if (key == null || key.isEmpty) continue;

      final wallUpdatedAt = row.readNullable<int>('wall_updated_at');
      if (wallUpdatedAt == null) {
        // The join could not establish this row's wall — so it can establish
        // neither its ownership nor its age. Keep it, and protect its bytes.
        unrankable.add(key);
        continue;
      }

      final surrogate = '$key\u0000$i';
      storedKeyBySurrogate[surrogate] = key;
      candidates.add(
        PrunablePhoto(
          key: surrogate,
          wallUpdatedAt: DateTime.fromMillisecondsSinceEpoch(wallUpdatedAt),
          ownerId: row.readNullable<String>('owner_id'),
        ),
      );
    }

    final offered = pruner.selectForEviction(
      photos: candidates,
      ownUid: ownUid,
      keepNewest: keepNewestForeign,
    );
    final offeredSurrogates = offered.toSet();

    // Bytes are shared but deletion is not: dropping a key that ANY withheld
    // row still needs would blank that row too, and if the withheld row is the
    // user's own that is exactly the unacceptable outcome. So a key is
    // evictable only if EVERY row naming it was offered up. Asking this of
    // surrogates subsumes both ownership (an own row is never offered) and the
    // keepNewest floor (a floored row is not offered either) without
    // re-deriving either rule here.
    final withheld = <String>{...unrankable};
    storedKeyBySurrogate.forEach((surrogate, storedKey) {
      if (!offeredSurrogates.contains(surrogate)) withheld.add(storedKey);
    });

    final order = <String>[];
    final seen = <String>{};
    for (final surrogate in offered) {
      final storedKey = storedKeyBySurrogate[surrogate]!;
      if (withheld.contains(storedKey)) continue;
      if (seen.add(storedKey)) order.add(storedKey);
    }
    return order;
  }

  /// Deletes [order] in batches, re-measuring after each one.
  Future<PublicPhotoPruneOutcome> _sweep({
    required List<String> order,
    required double before,
  }) async {
    final deleted = <String>[];
    var failures = 0;
    var fraction = before;
    var index = 0;
    var reason = PublicPhotoPruneReason.poolExhausted;

    while (index < order.length) {
      final budget = maxDeletionsPerPass - deleted.length - failures;
      if (budget <= 0) {
        reason = PublicPhotoPruneReason.capReached;
        break;
      }

      final take = _min3(batchSize, budget, order.length - index);
      for (var i = 0; i < take; i++) {
        final key = order[index + i];
        try {
          await _photoFiles.deletePhotoBytes(key);
          deleted.add(key);
        } catch (_) {
          // Both real backends already swallow their own failures; this guard
          // is for a backend that does not. One stubborn key must not strand
          // the rest of the sweep.
          failures++;
        }
      }
      index += take;

      final next = await _readFraction();
      if (next == null) {
        // The pressure signal went dark. Continuing would be deleting on a
        // guess, which is the one thing this service refuses to do.
        reason = PublicPhotoPruneReason.estimateLost;
        break;
      }
      fraction = next;
      if (fraction <= lowWatermark) {
        reason = PublicPhotoPruneReason.relieved;
        break;
      }
    }

    return PublicPhotoPruneOutcome(
      reason: reason,
      deletedKeys: deleted,
      failedDeleteCount: failures,
      usedFractionBefore: before,
      usedFractionAfter: fraction,
    );
  }

  /// Current origin-wide `usage / quota`, or `null` when the platform will not
  /// say. Never throws — an unreadable estimate is "no pressure signal", which
  /// is a skip, not an error.
  Future<double?> _readFraction() async {
    try {
      final estimate = await _storage.estimate();
      return estimate?.usedFraction;
    } catch (_) {
      return null;
    }
  }

  static int _min3(int a, int b, int c) {
    final ab = a < b ? a : b;
    return ab < c ? ab : c;
  }
}

/// App-wide [PublicPhotoPruneService].
///
/// A plain [Provider] because the service holds no state — each pass reads its
/// own pressure and ownership facts fresh. The uid is passed as
/// `currentUidProvider`'s lazy `String? Function()` rather than a resolved
/// value so this provider does not rebuild on every auth change, matching the
/// seven repository providers that already consume it that way.
final publicPhotoPruneServiceProvider = Provider<PublicPhotoPruneService>(
  (ref) => PublicPhotoPruneService(
    db: ref.watch(appDatabaseProvider),
    photoFiles: ref.watch(photoFilesProvider),
    storage: ref.watch(storagePersistenceServiceProvider),
    currentUid: ref.watch(currentUidProvider),
  ),
);
