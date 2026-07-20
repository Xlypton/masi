import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;

import 'image_ops/image_ops.dart';
import 'photo_byte_store.dart';
import 'photo_path_resolution.dart';

/// Web-only [PhotoFiles] backend: no filesystem, so originals + thumbnails
/// live in the browser's IndexedDB via [PhotoByteStore], addressed by the
/// same logical `photos/<id><ext>` / `thumbs/<id>.jpg` keys the native
/// backend uses as relative paths — the key IS the stored value, so there is
/// no path resolution/healing to do (see [resolvePhotoPath]).
class PhotoFiles {
  PhotoFiles({PhotoByteStore? byteStore})
    : _store = byteStore ?? createPhotoByteStore();

  final PhotoByteStore _store;

  /// Writes [xfile]'s bytes under `photos/<photoId><ext>` and derives +
  /// stores a downscaled thumbnail under `thumbs/<photoId>.jpg`. Best-effort,
  /// mirroring the native backend's contract: any failure is swallowed and
  /// the logical key is still returned.
  Future<String> importPhoto(XFile xfile, String photoId) async {
    final ext = p.extension(xfile.name).isNotEmpty
        ? p.extension(xfile.name)
        : '.jpg';
    final key = p.join('photos', '$photoId$ext');
    try {
      final bytes = await xfile.readAsBytes();
      await _store.writeBytes(key, bytes);
      try {
        final thumbBytes = await generateThumbnail(bytes);
        await _store.writeBytes(thumbKeyFor(key), thumbBytes);
      } catch (_) {
        // Thumbnail generation is best-effort — never blocks importPhoto.
      }
      return key;
    } catch (_) {
      return key;
    }
  }

  /// Writes [bytes] under `photos/<photoId><ext>` and regenerates + stores
  /// its thumbnail, mirroring [importPhoto]'s convention. This is the
  /// counterpart used for cloud restore, where bytes arrive already decoded
  /// in memory rather than as a picked [XFile].
  Future<String> writePhotoBytes(
    String photoId,
    String ext,
    List<int> bytes,
  ) async {
    final key = p.join('photos', '$photoId$ext');
    final byteData = Uint8List.fromList(bytes);
    await _store.writeBytes(key, byteData);
    try {
      final thumbBytes = await generateThumbnail(byteData);
      await _store.writeBytes(thumbKeyFor(key), thumbBytes);
    } catch (_) {
      // Thumbnail generation is best-effort — never blocks the write.
    }
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

  /// Synchronous counterpart to [resolvePhotoPath] — identical passthrough,
  /// since resolution here never needs to await anything.
  PhotoPathResolution resolvePhotoPathSync(String stored) =>
      PhotoPathResolution(path: stored);

  /// Logical keys are already canonical; returned unchanged.
  Future<String> canonicalStoredPath(String maybePath) async => maybePath;

  /// No docs directory to warm on web — a no-op.
  Future<void> warmDocsPath() => Future<void>.value();
}
