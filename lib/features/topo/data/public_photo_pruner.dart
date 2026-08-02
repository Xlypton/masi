/// Decides which cached PUBLIC (other climbers') photo bytes are safe to
/// evict when local storage is under pressure — never the ones that might
/// belong to the signed-in user.
///
/// Deliberately IMPORT-FREE and I/O-free: this is pure judgement over plain
/// data, unit-testable on the bare Dart VM with no drift, no IndexedDB, and
/// no clock. A later task (`public_photo_prune_service.dart`) supplies the
/// rows (from a drift query) and the storage-pressure signal (from
/// `StoragePersistenceService.estimate()`); this file only ever answers
/// "which keys, if any, are safe to delete right now."
///
/// The property this whole file exists to protect: **a photo that might be
/// the user's own is NEVER selected for eviction, under any input** —
/// missing owner ids, an owner id that matches nothing, empty inputs,
/// everything the same age, an unknown signed-in identity. Public photos are
/// re-downloadable from the cloud; the user's own offline-recorded topo is
/// not. The two failure modes are not symmetric: wrongly keeping a public
/// photo costs a future re-download; wrongly evicting an owned one destroys
/// irreplaceable work. Every ambiguous case below therefore resolves to
/// "keep", never to "evict".
library;

/// One candidate photo, as read off a wall row — not the byte data itself,
/// just the ownership + recency facts the eviction policy needs.
class PrunablePhoto {
  const PrunablePhoto({
    required this.key,
    required this.wallUpdatedAt,
    required this.ownerId,
  });

  /// The logical photo-byte-store key (e.g. `photos/<photoId>.jpg`) this
  /// decision is about.
  final String key;

  /// The owning wall's `updatedAt`, used as a recency proxy for "previously
  /// seen" content — there is no per-byte access-time record, and
  /// `walls.updatedAt` is already synced and already ordered by how recently
  /// anyone touched the wall.
  final DateTime wallUpdatedAt;

  /// The owning wall's `ownerId`, or `null` if nobody has claimed it locally
  /// yet (the pre-`claimOwnership` shape used elsewhere in
  /// `library_crud_repository.dart`'s `_ownOrUnowned`). `null` here means
  /// "ownership is not yet known", never "this is definitely a stranger's" —
  /// see [PublicPhotoPruner.selectForEviction] for why that is always kept.
  final String? ownerId;
}

/// Pure eviction-selection policy for cached public photo bytes.
class PublicPhotoPruner {
  const PublicPhotoPruner();

  /// Returns the keys of [photos] that are safe to delete right now: the
  /// oldest-by-[PrunablePhoto.wallUpdatedAt] photos that are DEFINITELY
  /// foreign, stopping once only [keepNewest] foreign photos remain.
  ///
  /// Ownership is decided in this order, and every branch that cannot prove
  /// "definitely foreign" falls through to "keep":
  ///
  ///  1. [ownUid] is `null` — no known signed-in identity on this device.
  ///     Ownership cannot be determined for ANY photo without one, so
  ///     nothing is ever evicted, no matter how confidently "foreign" the
  ///     data looks. A device between sessions must never have its own
  ///     topos guessed away.
  ///  2. [PrunablePhoto.ownerId] is `null` — unowned/pre-claim. Treated as
  ///     own, kept.
  ///  3. Otherwise, a photo is foreign — and therefore prunable — if and
  ///     only if `ownerId != ownUid`, a plain, non-fuzzy string comparison.
  ///     Any other string value, including one that matches nothing
  ///     recognisable on this device, is still a POSITIVE assertion of
  ///     someone else's ownership and is correctly treated as foreign; only
  ///     the ABSENCE of a value (`null`) is treated as unknown.
  ///
  /// [keepNewest] protects a floor of the most-recently-touched FOREIGN
  /// photos from eviction regardless of pressure — own photos are never in
  /// the eviction pool to begin with, so they never consume this budget.
  /// Negative values are clamped to zero rather than throwing.
  ///
  /// Ties on [PrunablePhoto.wallUpdatedAt] are broken by
  /// [PrunablePhoto.key] (ascending), so the ordering — and therefore the
  /// result — is deterministic and stable across runs for the same input,
  /// never dependent on incoming list order.
  List<String> selectForEviction({
    required List<PrunablePhoto> photos,
    required String? ownUid,
    required int keepNewest,
  }) {
    // No known local identity: ownership cannot be determined for anything,
    // so the only safe answer is to evict nothing at all.
    if (ownUid == null) return const [];

    final foreign =
        photos.where((p) => p.ownerId != null && p.ownerId != ownUid).toList()
          ..sort(_byOldestThenKey);

    final keep = keepNewest < 0 ? 0 : keepNewest;
    if (foreign.length <= keep) return const [];

    final evictCount = foreign.length - keep;
    return [for (final p in foreign.take(evictCount)) p.key];
  }

  static int _byOldestThenKey(PrunablePhoto a, PrunablePhoto b) {
    final byAge = a.wallUpdatedAt.compareTo(b.wallUpdatedAt);
    if (byAge != 0) return byAge;
    return a.key.compareTo(b.key);
  }
}
