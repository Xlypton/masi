import 'package:path/path.dart' as p;

/// Result of `PhotoFiles.resolvePhotoPath`: the absolute [path] to actually
/// use for file I/O / display, and — only when non-null — a [healedRelativePath]
/// the caller should rewrite the DB row's `localPath` to (a local-only
/// self-heal, not a semantic edit; callers should update ONLY `localPath`,
/// leaving `dirty`/`updatedAt`/`remoteId` untouched so this never triggers a
/// spurious re-sync).
class PhotoPathResolution {
  const PhotoPathResolution({required this.path, this.healedRelativePath});

  /// Absolute path to use for real file I/O / display right now. Always
  /// non-null and always the best available answer, even in the degenerate
  /// case where nothing actually resolves (see `PhotoFiles.resolvePhotoPath`
  /// case 3's best-effort candidate) — callers can still hand this to
  /// existing "missing photo" UI, which already handles a path whose file
  /// doesn't exist.
  final String path;

  /// Non-null only when the caller should rewrite the DB row's `localPath`
  /// to this (relative) value, because the stored absolute path was found to
  /// be stale AND the photo was confirmed to still exist at the re-derived
  /// location.
  final String? healedRelativePath;

  @override
  String toString() =>
      'PhotoPathResolution(path: $path, healedRelativePath: '
      '$healedRelativePath)';
}

/// Maps a stored original-photo key (`photos/<id><ext>`) to its thumbnail's
/// key (`thumbs/<id>.jpg`) — pure string manipulation, platform-agnostic, so
/// both the native and web `PhotoFiles` backends can share the exact same
/// naming convention without duplicating it.
///
/// The `/` is written literally rather than via `p.join`, because this is a
/// STORAGE KEY, not a host filesystem path: it is persisted into `photos.
/// localPath`, synced to Supabase, and used verbatim as an IndexedDB key by
/// the web backend. `p.join` picks the separator of whatever platform the
/// code happens to be running on, which would emit `thumbs\<id>.jpg` on a
/// Windows host — a different key for the same photo, and one iOS/web could
/// never resolve. The separator has to be a property of the format, not of
/// the machine. Callers on native re-join this against the documents
/// directory with `p.join`, which is where platform-correctness belongs.
String thumbKeyFor(String storedOriginal) {
  final id = p.basenameWithoutExtension(storedOriginal);
  return 'thumbs/$id.jpg';
}

/// The single directory component every thumbnail key/path carries — the
/// `thumbs` in [thumbKeyFor]'s `thumbs/<id>.jpg`, and (with a `shared/`
/// prefix) in the cloud's `shared/thumbs/<id>.jpg`.
const String kThumbDirName = 'thumbs';

/// Whether [key] names a THUMBNAIL rather than an original.
///
/// The extension is NOT a discriminator: a thumbnail is always `.jpg` and so
/// are most originals. What distinguishes them is the directory component
/// [thumbKeyFor] puts them in, so that is what this checks — and it checks the
/// PARENT directory rather than a `startsWith('thumbs/')`, because the native
/// backend hands display code the absolute form (`<docs>/thumbs/<id>.jpg`)
/// while the web backend hands it the bare key. Both must answer the same.
///
/// This exists because a thumbnail key has, by construction, LOST the
/// original's extension — `thumbKeyFor` derives `<id>` and hard-codes `.jpg`.
/// Anything that has to map a key back to a remote object therefore cannot
/// treat `p.extension(key)` as the photo's extension; it has to know which
/// kind of key it is holding first. See `MissingPhotoByteResolver.resolve`,
/// where getting that wrong meant asking the cloud for `shared/<id>.jpg` on
/// behalf of a `.jpeg` photo — an object that cannot exist.
bool isThumbKey(String key) => p.basename(p.dirname(key)) == kThumbDirName;
