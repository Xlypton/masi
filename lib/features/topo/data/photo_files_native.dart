import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'image_ops/image_ops.dart';
import 'photo_path_resolution.dart';

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
  static const _thumbsDirName = 'thumbs';

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

  /// Copies the file at [xfile]'s path into the app-owned photos directory
  /// as `<appDocuments>/photos/<photoId><ext>` (preserving [xfile]'s
  /// extension) and returns the RELATIVE form `photos/<photoId><ext>` — never
  /// an absolute path, in any branch below.
  ///
  /// Best-effort and idempotent:
  ///  - if [xfile]'s source path does not exist (nothing to own yet), returns
  ///    the relative destination form directly WITHOUT resolving the docs
  ///    dir — so callers that pass a placeholder/missing path (and unit
  ///    tests using fake paths) never trigger a real `path_provider` lookup
  ///    or a failed copy;
  ///  - if the destination already exists, or the source is already that
  ///    destination, no copy is performed but the relative destination path
  ///    is still returned;
  ///  - if the copy itself fails for any reason, the relative destination
  ///    form is still returned rather than throwing or handing back the
  ///    (stale) source path — owning the file is an optimization, never a
  ///    hard prerequisite for attaching a photo, and the relative form is
  ///    always safe to persist even when nothing actually landed on disk.
  ///
  /// When the source exists and the copy succeeds, this also generates and
  /// writes a downscaled thumbnail to `<appDocuments>/thumbs/<photoId>.jpg`
  /// (via [generateThumbnail], run off the UI thread through `compute()`).
  /// Thumbnail generation is itself best-effort: any failure there is
  /// swallowed and never prevents the original's relative dest from being
  /// returned.
  ///
  /// DELIBERATELY still best-effort, unlike the WEB backend (see
  /// `photo_files_web.dart`'s L3 fix): this backend never throws
  /// [PhotoWriteException]. The two are not symmetric, and that is correct —
  /// here the picked file still exists at [xfile]'s own path even when the
  /// copy into the app-owned directory fails, and `resolvePhotoPath`'s
  /// container-rotation healing can recover it later; on web the byte store IS
  /// the only copy, so a failed write means the pixels do not exist anywhere.
  /// The shared callers' `on PhotoWriteException` clauses are therefore dead
  /// code on native, by design — native behaviour is unchanged by that fix.
  Future<String> importPhoto(XFile xfile, String photoId) async {
    final ext = p.extension(xfile.name).isNotEmpty
        ? p.extension(xfile.name)
        : '.jpg';
    // Literal `/`, not `p.join` — see [thumbKeyFor]. The RELATIVE form is a
    // storage key: it is persisted into `photos.localPath` and synced, so its
    // separator must be a property of the format rather than of the host. The
    // ABSOLUTE paths below keep `p.join`, which is where platform-correctness
    // genuinely belongs. On iOS/Android this is byte-identical either way
    // (`p.join` is posix there); it only diverges on a Windows host.
    final relativeDest = '$_photosDirName/$photoId$ext';
    final source = File(xfile.path);
    if (!await source.exists()) return relativeDest;
    try {
      final dir = await _photosDir();
      final dest = p.join(dir.path, '$photoId$ext');
      if (!p.equals(xfile.path, dest)) {
        final destFile = File(dest);
        if (!await destFile.exists()) {
          await source.copy(dest);
        }
      }
      await _writeThumbnailBestEffort(dest, photoId);
      return relativeDest;
    } catch (_) {
      return relativeDest;
    }
  }

  /// Best-effort thumbnail generation for the just-imported original at
  /// [originalAbsolutePath], written to
  /// `<appDocuments>/thumbs/<photoId>.jpg`. Any failure (decode, compute
  /// isolate spawn, disk write) is swallowed — a missing/stale thumbnail is
  /// always safe to regenerate later and must never turn into an
  /// [importPhoto] failure.
  Future<void> _writeThumbnailBestEffort(
    String originalAbsolutePath,
    String photoId,
  ) async {
    try {
      final bytes = await File(originalAbsolutePath).readAsBytes();
      final thumbBytes = await compute(generateThumbnail, bytes);
      final thumbsDirectory = await _thumbsDir();
      final thumbDest = p.join(thumbsDirectory.path, '$photoId.jpg');
      await File(thumbDest).writeAsBytes(thumbBytes, flush: true);
    } catch (_) {
      // Best-effort — a failed thumbnail must never break importPhoto.
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
    return '$_photosDirName/$photoId$ext';
  }

  /// Reads the bytes of the photo stored at [stored] (resolved via
  /// [resolvePhotoPath]), or `null` if it cannot be found/read — matching
  /// this class's established defensive, never-throws style.
  Future<Uint8List?> readPhotoBytes(String stored) async {
    try {
      final resolution = await resolvePhotoPath(stored);
      final file = File(resolution.path);
      if (!await file.exists()) return null;
      return await file.readAsBytes();
    } catch (_) {
      return null;
    }
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
  /// (`loadOriginal`/`photoLocalPath`, `watchTopos`) must NOT
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
        return PhotoPathResolution(path: _absoluteFor(docsPath, stored));
      }
      if (File(stored).existsSync()) {
        return PhotoPathResolution(path: stored);
      }
      final relativeCandidate = '$_photosDirName/${p.basename(stored)}';
      final docsPath = await _resolveDocsPath();
      final candidateAbsolute = _absoluteFor(docsPath, relativeCandidate);
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
      // Split with the host's semantics, rejoin with the key format's: the
      // return value is persisted and synced, so it must be `/`-separated
      // whatever platform derived it (see [thumbKeyFor]).
      return p.url.joinAll(p.split(p.relative(maybePath, from: docsPath)));
    } catch (_) {
      return maybePath;
    }
  }

  /// Synchronous, cache-backed counterpart to [resolvePhotoPath], for the
  /// callers that run under a `flutter_test` widget `pump()` and therefore
  /// CANNOT await a real `path_provider` call without hanging: the
  /// repository photo-load paths driven on a canvas mount
  /// ([PhotoRepository.loadOriginal],
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
        return PhotoPathResolution(path: _absoluteFor(docsPath, stored));
      }
      if (File(stored).existsSync()) {
        return PhotoPathResolution(path: stored);
      }
      final relativeCandidate = '$_photosDirName/${p.basename(stored)}';
      final candidateAbsolute = _absoluteFor(docsPath, relativeCandidate);
      final candidateExists = File(candidateAbsolute).existsSync();
      return PhotoPathResolution(
        path: candidateAbsolute,
        healedRelativePath: candidateExists ? relativeCandidate : null,
      );
    } catch (_) {
      return PhotoPathResolution(path: stored);
    }
  }

  /// Best-effort delete of the original photo file stored at [stored] (a
  /// `Photos.localPath` value, resolved via [resolvePhotoPathSync] — the
  /// SAME cache-backed algorithm [resolvePhotoPath] uses, just without
  /// awaiting it) AND its thumbnail (`thumbs/<id>.jpg`, via [thumbKeyFor]) —
  /// the on-disk counterpart to a DB-side tombstone
  /// (`PhotoRepository.deleteOriginalPhoto`): once a photo row is
  /// soft-deleted there is no reason to keep its bytes around, locally OR
  /// in cloud Storage (see `SyncService._uploadOwnPhotos`'s
  /// tombstone-skip-and-remove). NEVER throws, mirroring this class's
  /// established defensive style — deleting an already-missing file (or a
  /// thumbnail that was never generated) is a silent no-op, not an error.
  /// The original and thumbnail deletes are independent try/catch blocks so
  /// a failure on one never skips the other.
  ///
  /// Deliberately never awaits [_resolveDocsPath]/`_docsDir()` (a
  /// `path_provider` platform channel call): this is invoked as best-effort
  /// background cleanup from the delete tap-handler
  /// (`TopoCanvasScreen._handleDeletePhoto`) and must never hang a caller —
  /// under `flutter_test`, awaiting that channel with no mock handler wedges
  /// forever under a plain `pump()`. Instead this resolves off the already-
  /// memoized [_cachedDocsPath] (warmed via [warmDocsPath] at app startup,
  /// see `main.dart`). If it hasn't been warmed yet (e.g. a plain unit test
  /// with no explicit [warmDocsPath] call), there is nothing safely
  /// resolvable to delete yet, so this no-ops gracefully rather than
  /// attempting a delete against an unresolved path.
  Future<void> deletePhotoBytes(String stored) async {
    final docsPath = _cachedDocsPath;
    if (docsPath == null) return;
    try {
      final resolution = resolvePhotoPathSync(stored);
      final file = File(resolution.path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Best-effort — never throws.
    }
    try {
      final thumbFile = File(_absoluteFor(docsPath, thumbKeyFor(stored)));
      if (await thumbFile.exists()) await thumbFile.delete();
    } catch (_) {
      // Best-effort — never throws.
    }
  }

  /// Whether the original at [stored] currently exists on disk.
  ///
  /// Resolved through exactly the same path [deletePhotoBytes] uses — the
  /// memoized [_cachedDocsPath] plus [resolvePhotoPathSync], never awaiting
  /// `path_provider` — so the two agree by construction, which is the property
  /// its caller depends on: `true` here means a following [deletePhotoBytes]
  /// really does have a file to delete, and a cold docs path answers `false`
  /// for precisely the reason that method no-ops there. NEVER throws; an
  /// unanswerable probe is `false`.
  ///
  /// (`PublicPhotoPruneService` is the only caller and is a permanent no-op on
  /// native — `navigator.storage` does not exist, so nothing ever evicts an
  /// iOS/Android documents directory. This exists so the shared service, and
  /// its `flutter test` runs, have one honest answer on every backend.)
  Future<bool> hasPhotoBytes(String stored) async {
    if (_cachedDocsPath == null) return false;
    try {
      return await File(resolvePhotoPathSync(stored).path).exists();
    } catch (_) {
      return false;
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

  /// Resolves a `/`-separated storage [key] against [docsPath] into a path in
  /// the HOST's own form — the single boundary where the key format becomes a
  /// real filesystem path.
  ///
  /// Storage keys are always url-style (see [thumbKeyFor]); `File` wants the
  /// platform style. A bare `p.join` would leave the key's `/` untouched and
  /// produce a mixed `C:\docs\photos/x.jpg` on a Windows host, so the key is
  /// split with url semantics and rejoined with the platform's. On iOS and
  /// Android both styles are posix, making this byte-identical to `p.join`.
  static String _absoluteFor(String docsPath, String key) =>
      p.joinAll([docsPath, ...p.url.split(key)]);

  /// The `<appDocuments>/photos` directory, created if it does not yet exist.
  Future<Directory> _photosDir() async {
    final docsPath = await _resolveDocsPath();
    final dir = Directory(p.join(docsPath, _photosDirName));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// The `<appDocuments>/thumbs` directory, created if it does not yet exist.
  Future<Directory> _thumbsDir() async {
    final docsPath = await _resolveDocsPath();
    final dir = Directory(p.join(docsPath, _thumbsDirName));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }
}
