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
String thumbKeyFor(String storedOriginal) {
  final id = p.basenameWithoutExtension(storedOriginal);
  return p.join('thumbs', '$id.jpg');
}
