import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Owns the on-disk lifecycle of picked photo files.
///
/// The photo picker (`image_picker`) hands back a path into an OS-managed
/// *cache* directory that the app does not own — iOS/Android are free to
/// evict it at any time, so a `Photos.localPath` pointing there is a latent
/// data-loss bug (the row survives, the pixels don't) and is not portable for
/// cloud backup/restore. [PhotoFiles] copies each picked file into a stable,
/// app-owned location — `<appDocuments>/photos/<photoId>.<ext>` — and hands
/// back a path to store, so the app fully owns every image it references.
///
/// [importPhoto]/[writePhotoBytes] always return a path RELATIVE to the app
/// documents directory (`photos/<photoId><ext>`), never an absolute one. An
/// absolute path baked into the DB goes stale the moment iOS rotates the
/// app's container UUID (reinstall/redeploy/OS restore) — the row survives
/// but the frozen absolute path no longer resolves to anything, even though
/// the file itself is still there under the (new) app documents directory at
/// the same relative location. Storing the relative form instead means the
/// path is always re-joined against whatever the CURRENT app documents
/// directory happens to be at read time (see [resolvePhotoPath]), so it
/// survives container rotation for free.
///
/// The app-documents directory is resolved through an injected [docsDir]
/// callback (defaulting to `path_provider`'s
/// [getApplicationDocumentsDirectory]) purely so tests can point it at a temp
/// directory without needing a `path_provider` platform fake — every method
/// that needs the docs dir goes through this one seam.
class PhotoFiles {
  PhotoFiles({Future<Directory> Function()? docsDir})
    : _docsDir = docsDir ?? getApplicationDocumentsDirectory;

  final Future<Directory> Function() _docsDir;

  static const _photosDirName = 'photos';

  /// The app-documents directory path, memoized after the first successful
  /// async resolution (via [resolvePhotoPath]/[canonicalStoredPath]/
  /// [_photosDir], or an explicit [warmDocsPath]). Stays `null` when no
  /// `path_provider` platform implementation is available (e.g. plain
  /// `flutter test` with no injected `docsDir`), which is exactly what lets
  /// [resolvePhotoPathSync] degrade to returning the stored value unchanged
  /// in that environment.
  ///
  /// Enables [resolvePhotoPathSync] — a synchronous best-effort resolver used
  /// by `watchTopos` (which must map its Drift stream synchronously; an
  /// `async` mapper there deadlocks `StreamProvider`-backed widget tests
  /// under the fake test clock).
  String? _cachedDocsPath;

  Future<void>? _warmFuture;

  /// Copies the file at [sourcePath] into the app-owned photos directory as
  /// `<appDocuments>/photos/<photoId><ext>` (preserving [sourcePath]'s
  /// extension) and returns the RELATIVE form `photos/<photoId><ext>` — never
  /// an absolute path, in any branch below.
  ///
  /// Best-effort and idempotent:
  ///  - if [sourcePath] does not exist (nothing to own yet), returns the
  ///    relative destination form directly WITHOUT resolving the docs dir —
  ///    so callers that pass a placeholder/missing path (and unit tests using
  ///    fake paths) never trigger a real `path_provider` lookup or a failed
  ///    copy;
  ///  - if the destination already exists, or [sourcePath] is already that
  ///    destination, no copy is performed but the relative destination path
  ///    is still returned;
  ///  - if the copy itself fails for any reason, the relative destination
  ///    form is still returned rather than throwing or handing back the
  ///    (stale) [sourcePath] — owning the file is an optimization, never a
  ///    hard prerequisite for attaching a photo, and the relative form is
  ///    always safe to persist even when nothing actually landed on disk.
  Future<String> importPhoto(String sourcePath, String photoId) async {
    final ext = p.extension(sourcePath);
    final relativeDest = p.join(_photosDirName, '$photoId$ext');
    final source = File(sourcePath);
    if (!await source.exists()) return relativeDest;
    try {
      final dir = await _photosDir();
      final dest = p.join(dir.path, '$photoId$ext');
      if (!p.equals(sourcePath, dest)) {
        final destFile = File(dest);
        if (!await destFile.exists()) {
          await source.copy(dest);
        }
      }
      return relativeDest;
    } catch (_) {
      return relativeDest;
    }
  }

  /// Writes [bytes] to `<appDocuments>/photos/<photoId><ext>` (creating the
  /// directory if needed), overwriting whatever was already at that
  /// destination, and returns the RELATIVE form `photos/<photoId><ext>`.
  ///
  /// This is [importPhoto]'s counterpart for cloud restore: [importPhoto]
  /// owns a file that already exists on disk (the picker's cache copy),
  /// while this owns bytes that only exist in memory so far (a photo just
  /// downloaded from cloud Storage) — both land at the exact same
  /// `<appDocuments>/photos/<photoId><ext>` convention so a restored
  /// `Photos.localPath` is indistinguishable from one produced locally.
  Future<String> writePhotoBytes(
    String photoId,
    String ext,
    List<int> bytes,
  ) async {
    final dir = await _photosDir();
    final dest = p.join(dir.path, '$photoId$ext');
    await File(dest).writeAsBytes(bytes, flush: true);
    return p.join(_photosDirName, '$photoId$ext');
  }

  /// Resolves a `Photos.localPath` value as stored in the DB ([stored]) to
  /// an absolute path usable for real file I/O / display, and reports
  /// whether the caller should heal (rewrite) the stored value.
  ///
  /// Algorithm:
  ///  1. [stored] is relative -> absolute = `<currentDocsDir>/<stored>`, no
  ///     heal needed (this is already the canonical, rotation-proof form).
  ///  2. [stored] is absolute and the file still exists there -> returned
  ///     unchanged (a legacy absolute path that happens to still be valid,
  ///     e.g. the container hasn't rotated since it was written), no heal.
  ///  3. [stored] is absolute and missing -> re-derive what the relative
  ///     form would be from the path's basename
  ///     (`photos/<basename(stored)>`) and resolve THAT against the CURRENT
  ///     docs dir. That candidate is always returned as the best-effort
  ///     absolute path (even if it also doesn't exist, so the app's existing
  ///     "missing photo" UI can degrade gracefully) — but healing is only
  ///     signaled when the candidate file genuinely exists, confirming the
  ///     photo really did move with the container rather than being lost.
  ///
  /// AWAITS the docs dir and resolves fully — for callers running in a plain
  /// async context (NOT under a `flutter_test` widget `pump()`): the cloud
  /// backup / sync UPLOAD paths (`CloudBackupService`/`SyncService`, which
  /// must turn a stored relative `localPath` into an absolute one before
  /// `File(...)`, or they'd resolve it against the process CWD and silently
  /// skip every photo), and this repo's own await-driven unit tests.
  ///
  /// Repository READ paths that run on a canvas widget mount
  /// (`loadOriginal`/`loadSlices`/`photoLocalPath`, `watchTopos`) must NOT
  /// use this — a real `path_provider` call does not complete under the
  /// fake widget clock without `runAsync`, so awaiting it there hard-hangs
  /// `pumpAndSettle`. Those use the synchronous, cache-backed
  /// [resolvePhotoPathSync] instead. Resolving here also memoizes the docs
  /// path (via [_resolveDocsPath]), warming that sync cache as a side effect.
  ///
  /// The whole body is wrapped in try/catch, falling back to returning
  /// [stored] unchanged with no heal — mirroring [importPhoto]'s defensive
  /// catch-all.
  Future<PhotoPathResolution> resolvePhotoPath(String stored) async {
    try {
      if (p.isRelative(stored)) {
        final docsPath = await _resolveDocsPath();
        return PhotoPathResolution(path: p.join(docsPath, stored));
      }
      if (File(stored).existsSync()) {
        return PhotoPathResolution(path: stored);
      }
      final relativeCandidate = p.join(_photosDirName, p.basename(stored));
      final docsPath = await _resolveDocsPath();
      final candidateAbsolute = p.join(docsPath, relativeCandidate);
      final candidateExists = File(candidateAbsolute).existsSync();
      return PhotoPathResolution(
        path: candidateAbsolute,
        healedRelativePath: candidateExists ? relativeCandidate : null,
      );
    } catch (_) {
      return PhotoPathResolution(path: stored);
    }
  }

  /// The write-side counterpart to [resolvePhotoPath]: normalizes a path
  /// that may already have been resolved to absolute (e.g. a caller-supplied
  /// `originalLocalPath` string) back to the canonical relative form BEFORE
  /// it is persisted, so a fresh write never bakes in a container-relative
  /// absolute path.
  ///
  /// [maybePath] relative -> returned unchanged (already canonical).
  /// [maybePath] absolute and within `<currentDocsDir>/photos/` -> stripped
  /// to the relative form. Otherwise (an external/foreign absolute path this
  /// app doesn't own) -> left absolute unchanged, since it can't be
  /// meaningfully canonicalized against the app-owned photos directory.
  ///
  /// Wrapped in the same try/catch-and-fall-back-to-input pattern as
  /// [resolvePhotoPath], for the same reason (no `path_provider` platform
  /// implementation available, e.g. in a plain unit test).
  Future<String> canonicalStoredPath(String maybePath) async {
    try {
      if (p.isRelative(maybePath)) return maybePath;
      final docsPath = await _resolveDocsPath();
      final photosDirAbsolute = p.join(docsPath, _photosDirName);
      if (!p.isWithin(photosDirAbsolute, maybePath)) return maybePath;
      return p.relative(maybePath, from: docsPath);
    } catch (_) {
      return maybePath;
    }
  }

  /// Synchronous, cache-backed counterpart to [resolvePhotoPath], for the
  /// callers that run under a `flutter_test` widget `pump()` and therefore
  /// CANNOT await a real `path_provider` call without hanging: the
  /// repository photo-load paths driven on a canvas mount
  /// ([PhotoRepository.loadOriginal]/`loadSlices`,
  /// [LibraryCrudRepository.photoLocalPath]) and the `watchTopos` Drift
  /// stream (which must map synchronously — an async mapper wedges a
  /// `StreamProvider`-backed widget under the fake clock).
  ///
  /// Resolution is driven off the memoized [_cachedDocsPath]; this method
  /// NEVER awaits `_docsDir()`:
  ///  - cache cold (nothing has warmed it yet — first read before any
  ///    [resolvePhotoPath]/`importPhoto`/[warmDocsPath], OR no `path_provider`
  ///    at all in a plain unit test) -> kicks a one-shot async [warmDocsPath]
  ///    for NEXT time and returns [stored] unchanged with no heal;
  ///  - cache warm + [stored] relative -> `join(docsPath, stored)`, no heal;
  ///  - cache warm + [stored] absolute-and-present -> [stored], no heal;
  ///  - cache warm + [stored] absolute-and-missing -> best-effort
  ///    `join(docsPath, photos/<basename>)`, and a [PhotoPathResolution.healedRelativePath]
  ///    IFF that candidate file exists (a confirmed container-rotation heal).
  ///
  /// The heal is only SIGNALLED here (there is no async DB write on a sync
  /// path); the awaited repository read path performs the actual
  /// `localPath` rewrite.
  PhotoPathResolution resolvePhotoPathSync(String stored) {
    try {
      final docsPath = _cachedDocsPath;
      if (docsPath == null) {
        unawaited(warmDocsPath());
        return PhotoPathResolution(path: stored);
      }
      if (p.isRelative(stored)) {
        return PhotoPathResolution(path: p.join(docsPath, stored));
      }
      if (File(stored).existsSync()) {
        return PhotoPathResolution(path: stored);
      }
      final relativeCandidate = p.join(_photosDirName, p.basename(stored));
      final candidateAbsolute = p.join(docsPath, relativeCandidate);
      final candidateExists = File(candidateAbsolute).existsSync();
      return PhotoPathResolution(
        path: candidateAbsolute,
        healedRelativePath: candidateExists ? relativeCandidate : null,
      );
    } catch (_) {
      return PhotoPathResolution(path: stored);
    }
  }

  /// Resolves and memoizes the app-documents directory path, so a later
  /// synchronous [resolvePhotoPathSync] can join relative photo paths
  /// without awaiting. One-shot: concurrent/repeat calls share a single
  /// in-flight resolution, and any failure (e.g. no `path_provider`) is
  /// swallowed and simply leaves the cache cold.
  Future<void> warmDocsPath() {
    if (_cachedDocsPath != null) return Future<void>.value();
    return _warmFuture ??= _docsDir()
        .then((dir) => _cachedDocsPath = dir.path)
        .then((_) {})
        .catchError((Object _) {})
        .whenComplete(() => _warmFuture = null);
  }

  /// Awaits [_docsDir] and memoizes its path into [_cachedDocsPath] as a
  /// side effect, so the sync resolver can reuse it. Callers still get the
  /// freshly-resolved path directly.
  Future<String> _resolveDocsPath() async {
    final docs = await _docsDir();
    _cachedDocsPath = docs.path;
    return docs.path;
  }

  /// The `<appDocuments>/photos` directory, created if it does not yet exist.
  Future<Directory> _photosDir() async {
    final docsPath = await _resolveDocsPath();
    final dir = Directory(p.join(docsPath, _photosDirName));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }
}

/// Result of [PhotoFiles.resolvePhotoPath]: the absolute [path] to actually
/// use for file I/O / display, and — only when non-null — a [healedRelativePath]
/// the caller should rewrite the DB row's `localPath` to (a local-only
/// self-heal, not a semantic edit; callers should update ONLY `localPath`,
/// leaving `dirty`/`updatedAt`/`remoteId` untouched so this never triggers a
/// spurious re-sync).
class PhotoPathResolution {
  const PhotoPathResolution({required this.path, this.healedRelativePath});

  /// Absolute path to use for real file I/O / display right now. Always
  /// non-null and always the best available answer, even in the degenerate
  /// case where nothing actually resolves (see [PhotoFiles.resolvePhotoPath]
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
