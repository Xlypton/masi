import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;

import 'image_ops/image_ops.dart';
import 'photo_byte_store.dart';
import 'photo_path_resolution.dart';
import 'photo_write_exception.dart';

/// Web-only [PhotoFiles] backend: no filesystem, so originals + thumbnails
/// live in the browser's IndexedDB via [PhotoByteStore], addressed by the
/// same logical `photos/<id><ext>` / `thumbs/<id>.jpg` keys the native
/// backend uses as relative paths — the key IS the stored value, so there is
/// no path resolution/healing to do (see [resolvePhotoPath]).
class PhotoFiles {
  PhotoFiles({PhotoByteStore? byteStore})
    : _store = byteStore ?? createPhotoByteStore();

  final PhotoByteStore _store;

  /// Writes [xfile]'s bytes under `photos/<photoId><ext>` and derives + stores
  /// a downscaled thumbnail under `thumbs/<photoId>.jpg`.
  ///
  /// L3 fix (silent data loss): the ORIGINAL's byte write is NO LONGER
  /// best-effort. It used to sit inside a `catch (_) { return key; }`, so a
  /// browser that refused the write still handed back a key that
  /// `LibraryCrudRepository.attachPhotoToWall` then persisted as a `Photos`
  /// row's `localPath` — a pixel-less row, i.e. a topo whose photo is
  /// permanently a placeholder, with nothing anywhere reporting why. Quota
  /// exhaustion is the realistic trigger and it is reachable in ORDINARY use
  /// because originals are never downscaled (decision D-5): `pickPhotoFrom`
  /// passes no `imageQuality`/`maxWidth` and this backend stores
  /// `readAsBytes()` verbatim; only the 512px/q80 thumbnail is shrunk.
  ///
  /// Any failure now throws a [PhotoWriteException], classified via
  /// [classifyPhotoWriteFailure] so a quota exhaustion is distinguishable and
  /// user-presentable. `attachPhotoToWall` awaits this call BEFORE opening its
  /// insert transaction, so a throw here means no row is ever written and
  /// there is nothing to clean up.
  ///
  /// The THUMBNAIL write stays best-effort (see
  /// [_writeThumbnailBestEffort]) — mirroring the native backend, and because
  /// a thumbnail is derivable and disposable.
  Future<String> importPhoto(XFile xfile, String photoId) async {
    final ext = p.extension(xfile.name).isNotEmpty
        ? p.extension(xfile.name)
        : '.jpg';
    // Literal `/`, not `p.join` — see [thumbKeyFor]: this is a storage key
    // that gets persisted and synced, so its separator belongs to the format,
    // not to whatever platform is running the code.
    final key = 'photos/$photoId$ext';
    try {
      final bytes = await xfile.readAsBytes();
      await _store.writeBytes(key, bytes);
      await _writeThumbnailBestEffort(key, bytes);
      return key;
    } catch (e) {
      throw PhotoWriteException(
        failure: classifyPhotoWriteFailure(e),
        key: key,
        cause: e,
      );
    }
  }

  /// Best-effort thumbnail for the just-written original at [key]. NEVER
  /// throws, which is what keeps it safe to call from inside [importPhoto]'s
  /// single try block: a thumbnail is always regenerable and the photo strip /
  /// `PhotoImageCache` fall back to the original, so a failed thumbnail must
  /// never turn into a failed import. Mirrors the native backend's
  /// `_writeThumbnailBestEffort`.
  Future<void> _writeThumbnailBestEffort(String key, Uint8List bytes) async {
    try {
      final thumbBytes = await generateThumbnail(bytes);
      await _store.writeBytes(thumbKeyFor(key), thumbBytes);
    } catch (_) {
      // Best-effort — never blocks importPhoto/writePhotoBytes.
    }
  }

  /// Writes [bytes] under `photos/<photoId><ext>` and regenerates + stores its
  /// thumbnail, mirroring [importPhoto]'s convention. This is the counterpart
  /// used for cloud restore, where bytes arrive already decoded in memory
  /// rather than as a picked [XFile].
  ///
  /// L3 fix (continued): the byte write already propagated its raw store error
  /// here — now it propagates a CLASSIFIED [PhotoWriteException] instead, so
  /// `SyncService._downloadAndRewritePhotos`' caller records a quota
  /// exhaustion as such in `PullResult.errors` rather than an opaque
  /// `DatabaseError` string.
  Future<String> writePhotoBytes(
    String photoId,
    String ext,
    List<int> bytes,
  ) async {
    final key = 'photos/$photoId$ext';
    final byteData = Uint8List.fromList(bytes);
    try {
      await _store.writeBytes(key, byteData);
    } catch (e) {
      throw PhotoWriteException(
        failure: classifyPhotoWriteFailure(e),
        key: key,
        cause: e,
      );
    }
    await _writeThumbnailBestEffort(key, byteData);
    return key;
  }

  /// Reads the bytes stored under the logical key [stored] directly — no
  /// path resolution needed, since on web the "stored" value already IS the
  /// [PhotoByteStore] key.
  Future<Uint8List?> readPhotoBytes(String stored) => _store.readBytes(stored);

  /// Logical keys are opaque and platform-agnostic: [stored] is returned
  /// unchanged, with no existence check and no healing (there is no
  /// container-rotation concept on web).
  Future<PhotoPathResolution> resolvePhotoPath(String stored) async =>
      PhotoPathResolution(path: stored);

  /// Best-effort delete of the bytes stored under the logical key [stored]
  /// AND its thumbnail (`thumbs/<id>.jpg`, via [thumbKeyFor]) — the
  /// IndexedDB counterpart to a DB-side tombstone
  /// (`PhotoRepository.deleteOriginalPhoto`). [PhotoByteStore.delete] is
  /// idempotent for an absent key, but the surrounding IndexedDB open/txn
  /// can still reject (blocked upgrade, private-browsing storage limits, a
  /// closed connection). Since the caller fires this unawaited, swallow any
  /// failure here so a byte-cleanup hiccup never becomes an unhandled async
  /// error — worst case is orphaned bytes, never a crash.
  Future<void> deletePhotoBytes(String stored) async {
    try {
      await _store.delete(stored);
    } catch (_) {}
    try {
      await _store.delete(thumbKeyFor(stored));
    } catch (_) {}
  }

  /// Whether the logical key [stored] currently holds bytes on this device.
  ///
  /// A PRESENCE probe, not a read: [PhotoByteStore.exists] looks the key up
  /// without loading the (potentially multi-megabyte) blob, which is what makes
  /// it affordable to ask about many keys in a row — `PublicPhotoPruneService`
  /// asks it about every key it is considering evicting, because a `Photos` row
  /// naming a key is NOT evidence that the key holds anything (a pruned or
  /// budget-skipped public photo is defined as exactly that: a row whose bytes
  /// are absent).
  ///
  /// NEVER throws, and answers `false` when it cannot tell — mirroring
  /// [deletePhotoBytes]'s best-effort stance, and erring the safe way for its
  /// caller: "we don't know" must mean "don't spend a deletion on it".
  Future<bool> hasPhotoBytes(String stored) async {
    try {
      return await _store.exists(stored);
    } catch (_) {
      return false;
    }
  }

  /// Synchronous counterpart to [resolvePhotoPath] — identical passthrough,
  /// since resolution here never needs to await anything.
  PhotoPathResolution resolvePhotoPathSync(String stored) =>
      PhotoPathResolution(path: stored);

  /// Logical keys are already canonical; returned unchanged.
  Future<String> canonicalStoredPath(String maybePath) async => maybePath;

  /// No docs directory to warm on web — a no-op.
  Future<void> warmDocsPath() => Future<void>.value();
}
