import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/db/app_database.dart' as db;
import '../../account/data/auth_repository.dart';
import '../../topo/data/photo_files.dart';
import 'backup_repository.dart';
import 'connectivity_service.dart';
import 'sync_remote.dart';

/// Outcome of a [SyncService.pushOwn] call.
enum SyncPushOutcome {
  /// The signed-in user's own rows (and any not-yet-uploaded photos) were
  /// pushed.
  pushed,

  /// No-op: nobody is signed in, so there's no uid to scope the push to.
  skippedSignedOut,

  /// No-op: `wifiOnly` is set and the current connection isn't wifi.
  skippedNotWifi,
}

/// Result of a [SyncService.pushOwn] call.
class PushSyncResult {
  const PushSyncResult.pushed({required this.rowsPushed, required this.photosUploaded})
    : outcome = SyncPushOutcome.pushed;

  const PushSyncResult.skippedSignedOut()
    : outcome = SyncPushOutcome.skippedSignedOut,
      rowsPushed = 0,
      photosUploaded = 0;

  const PushSyncResult.skippedNotWifi()
    : outcome = SyncPushOutcome.skippedNotWifi,
      rowsPushed = 0,
      photosUploaded = 0;

  final SyncPushOutcome outcome;

  /// Total row count pushed across all eight tables (areas/sectors/walls/
  /// photos/routes/comments/likes/ascents), INCLUDING tombstones. Always 0
  /// when [outcome] isn't [SyncPushOutcome.pushed].
  final int rowsPushed;

  /// Number of distinct photo FILES actually uploaded (private copy and/or
  /// shared copy; excludes files already present remotely under a given
  /// path). Always 0 when [outcome] isn't [SyncPushOutcome.pushed].
  final int photosUploaded;

  bool get didPush => outcome == SyncPushOutcome.pushed;

  @override
  String toString() =>
      'PushSyncResult(outcome: $outcome, rowsPushed: $rowsPushed, '
      'photosUploaded: $photosUploaded)';
}

/// Outcome of a [SyncService.pullOwnAndShared] call.
enum SyncPullOutcome {
  /// The signed-in user's own rows and every currently-shared topo were
  /// fetched and merged locally (by last-write-wins).
  pulled,

  /// No-op: nobody is signed in.
  skippedSignedOut,
}

/// Result of a [SyncService.pullOwnAndShared] call.
class PullSyncResult {
  const PullSyncResult.pulled({
    required this.ownRowsPulled,
    required this.sharedRowsPulled,
    required this.photosDownloaded,
  }) : outcome = SyncPullOutcome.pulled;

  const PullSyncResult.skippedSignedOut()
    : outcome = SyncPullOutcome.skippedSignedOut,
      ownRowsPulled = 0,
      sharedRowsPulled = 0,
      photosDownloaded = 0;

  final SyncPullOutcome outcome;

  /// Total row count FETCHED from the signed-in user's own cloud rows
  /// (across all eight tables). Note this counts rows received, not rows
  /// actually WRITTEN locally — a row older than its local counterpart is
  /// fetched but then skipped by last-write-wins during import. Always 0
  /// when [outcome] isn't [SyncPullOutcome.pulled].
  final int ownRowsPulled;

  /// Total row count FETCHED from every currently-shared topo (any owner),
  /// same "fetched, not necessarily written" caveat as [ownRowsPulled].
  /// Always 0 when [outcome] isn't [SyncPullOutcome.pulled].
  final int sharedRowsPulled;

  /// Number of distinct photo files actually downloaded (own + shared
  /// combined; excludes rows whose remote object was missing, which are
  /// skipped gracefully). Always 0 when [outcome] isn't
  /// [SyncPullOutcome.pulled].
  final int photosDownloaded;

  bool get didPull => outcome == SyncPullOutcome.pulled;

  @override
  String toString() =>
      'PullSyncResult(outcome: $outcome, ownRowsPulled: $ownRowsPulled, '
      'sharedRowsPulled: $sharedRowsPulled, '
      'photosDownloaded: $photosDownloaded)';
}

/// Row-level cloud sync engine (P2 of the sync pivot): pushes the signed-in
/// user's own rows (every table, INCLUDING tombstones) up to the cloud, and
/// pulls both the user's own rows AND every OTHER user's shared topos back
/// down, merging everything into the local database by last-write-wins.
///
/// Every collaborator is injected so this is fully testable against fakes —
/// no real network, platform channel, or `path_provider` call is reachable
/// from a unit test that supplies its own [SyncRemote], [ConnectivityService],
/// [AuthRepository], and [PhotoFiles]:
///  - [SyncRemote]: the row-level cloud tables + `topo-photos` Storage
///    bucket (private `<uid>/...` and shared `shared/...` prefixes).
///  - [BackupRepository]: reused ONLY for its `importSnapshot`
///    FK-ordered-import + last-write-wins machinery — [pullOwnAndShared]
///    hands it `{'tables': <fetched rows>}` maps, the exact shape
///    [BackupRepository.exportSnapshot] produces, so the existing
///    Areas→Sectors→Walls→Photos(originals-before-slices)→Routes→Comments→
///    Likes→Ascents ordering and per-row `updatedAt` comparison apply
///    unchanged.
///  - [AuthRepository]: gates push/pull on being signed in and supplies the
///    uid every own-row/private-photo path is scoped to.
///  - [ConnectivityService]: gates `wifiOnly` pushes on the current network
///    (mirrors [CloudBackupService]; pulls are never wifi-gated, also
///    mirroring [CloudBackupService.pullBackup]).
///  - [PhotoFiles]: where downloaded photo bytes land locally
///    (`<appDocuments>/photos/<photoId><ext>`).
///
/// CRITICAL invariant for shared rows: a row pulled from
/// [SyncRemote.fetchSharedTopos] keeps its ORIGINAL (foreign) `ownerId` when
/// imported locally — [pullOwnAndShared] never rewrites it to the signed-in
/// user's own uid. That `ownerId` is what lets the UI later treat a pulled
/// shared topo as read-only (not the signed-in user's own row).
///
/// CRITICAL invariant for Ascents: a private per-user logbook, never part of
/// [SyncRemote.fetchSharedTopos]'s return — [pullOwnAndShared] only ever
/// imports another user's ascents if a future [SyncRemote] implementation
/// mistakenly added them there, which this class has no way to prevent by
/// itself; the guarantee lives in [SyncRemote.fetchSharedTopos]'s contract.
class SyncService {
  // Named (not positional) so call sites can't silently swap two
  // same-typed collaborators; the private fields below intentionally stay
  // underscore-prefixed for internal encapsulation, so these assignments
  // can't be collapsed into `this.<field>` initializing formals without
  // also renaming the public parameters — hence the per-line ignores.
  SyncService({
    required db.AppDatabase db,
    required BackupRepository backupRepository,
    required SyncRemote remote,
    required AuthRepository authRepository,
    required ConnectivityService connectivity,
    PhotoFiles? photoFiles,
    bool Function()? wifiOnly,
  }) : _db = db, // ignore: prefer_initializing_formals
       _backupRepository = backupRepository, // ignore: prefer_initializing_formals
       _remote = remote, // ignore: prefer_initializing_formals
       _authRepository = authRepository, // ignore: prefer_initializing_formals
       _connectivity = connectivity, // ignore: prefer_initializing_formals
       _photoFiles = photoFiles ?? PhotoFiles(),
       _wifiOnly = wifiOnly ?? (() => false);

  final db.AppDatabase _db;
  final BackupRepository _backupRepository;
  final SyncRemote _remote;
  final AuthRepository _authRepository;
  final ConnectivityService _connectivity;
  final PhotoFiles _photoFiles;
  final bool Function() _wifiOnly;

  /// Pushes every LOCAL row owned by the signed-in user (all eight tables,
  /// INCLUDING soft-deleted tombstones) up to [SyncRemote.upsertOwnRows],
  /// then uploads each distinct not-yet-uploaded photo file those rows
  /// reference — a private copy always, plus a SECOND shared copy for any
  /// photo whose wall has `visibility == 'shared'` (see
  /// [SyncRemote.uploadSharedPhoto]).
  ///
  /// No-ops (never throws) when signed out, or when `wifiOnly` is on and the
  /// current connection isn't wifi — both report a `skipped*` outcome
  /// rather than pushing partial data. Idempotent: pushing again with
  /// nothing changed re-sends the same rows (upsert, so harmless) and
  /// re-uploads no photo files (already-present objects are skipped).
  Future<PushSyncResult> pushOwn() async {
    final uid = _authRepository.currentSession.uid;
    if (uid == null) return const PushSyncResult.skippedSignedOut();

    if (_wifiOnly()) {
      final status = await _connectivity.currentStatus();
      if (status != NetworkStatus.wifi) {
        return const PushSyncResult.skippedNotWifi();
      }
    }

    final areas = await (_db.select(_db.areas)..where((t) => t.ownerId.equals(uid))).get();
    final sectors = await (_db.select(_db.sectors)..where((t) => t.ownerId.equals(uid))).get();
    final walls = await (_db.select(_db.walls)..where((t) => t.ownerId.equals(uid))).get();
    final photos = await (_db.select(_db.photos)..where((t) => t.ownerId.equals(uid))).get();
    final routes = await (_db.select(_db.routes)..where((t) => t.ownerId.equals(uid))).get();
    final comments = await (_db.select(_db.comments)..where((t) => t.ownerId.equals(uid))).get();
    final likes = await (_db.select(_db.likes)..where((t) => t.ownerId.equals(uid))).get();
    final ascents = await (_db.select(_db.ascents)..where((t) => t.ownerId.equals(uid))).get();

    final tablesToRows = <String, List<Map<String, dynamic>>>{
      'areas': [for (final row in areas) row.toJson()],
      'sectors': [for (final row in sectors) row.toJson()],
      'walls': [for (final row in walls) row.toJson()],
      'photos': [for (final row in photos) row.toJson()],
      'routes': [for (final row in routes) row.toJson()],
      'comments': [for (final row in comments) row.toJson()],
      'likes': [for (final row in likes) row.toJson()],
      // Ascents ARE pushed here (own-row push, no visibility distinction) —
      // it's fetchSharedTopos (pull side) that keeps them private, not push.
      'ascents': [for (final row in ascents) row.toJson()],
    };

    await _remote.upsertOwnRows(uid, tablesToRows);

    final wallVisibility = {for (final wall in walls) wall.id: wall.visibility};
    final photosUploaded = await _uploadOwnPhotos(uid, photos, wallVisibility);

    final rowsPushed = tablesToRows.values.fold<int>(0, (sum, rows) => sum + rows.length);
    return PushSyncResult.pushed(rowsPushed: rowsPushed, photosUploaded: photosUploaded);
  }

  /// Uploads every DISTINCT on-disk photo file referenced by [photos],
  /// skipping objects already present remotely. Slices share their
  /// original's file (see [_canonicalPhotoId]), so each on-disk file is
  /// considered at most once regardless of how many rows reference it. A
  /// photo whose wall (per [wallVisibility], keyed by wall id) is
  /// `'shared'` is ALSO uploaded to the shared object path, in addition to
  /// its always-uploaded private copy.
  Future<int> _uploadOwnPhotos(
    String uid,
    List<db.Photo> photos,
    Map<String, String> wallVisibility,
  ) async {
    if (photos.isEmpty) return 0;

    final alreadyPrivate = await _remote.listPhotoObjectPaths(uid);
    final alreadyShared = await _remote.listSharedPhotoObjectPaths();
    final seenCanonicalIds = <String>{};
    var uploaded = 0;

    for (final photo in photos) {
      final canonicalId = _canonicalPhotoId(photo);
      if (!seenCanonicalIds.add(canonicalId)) {
        continue; // this on-disk file was already handled via another row
      }

      // `photo.localPath` as stored may be RELATIVE (`photos/<id>.jpg`, the
      // canonical form since #17) — resolve it against the current app
      // documents directory before touching the filesystem, so a relative
      // path doesn't silently resolve (and fail to exist) against the
      // process CWD instead. `resolvePhotoPath` also passes an already-valid
      // legacy ABSOLUTE path through unchanged.
      final resolved = await _photoFiles.resolvePhotoPath(photo.localPath);
      final file = File(resolved.path);
      if (!await file.exists()) continue;

      final ext = p.extension(photo.localPath);
      final needsPrivate = !alreadyPrivate.contains('$uid/$canonicalId$ext');
      final needsShared =
          wallVisibility[photo.wallId] == 'shared' &&
          !alreadyShared.contains(sharedPhotoPath(canonicalId, ext));
      if (!needsPrivate && !needsShared) continue;

      // Read the file at most once even when both copies are missing.
      final bytes = await file.readAsBytes();
      if (needsPrivate) {
        await _remote.uploadPhoto(uid: uid, photoId: canonicalId, ext: ext, bytes: bytes);
      }
      if (needsShared) {
        await _remote.uploadSharedPhoto(photoId: canonicalId, ext: ext, bytes: bytes);
      }
      uploaded++;
    }

    return uploaded;
  }

  /// Fetches the signed-in user's own cloud rows AND every currently-shared
  /// topo (any owner), downloads/rewrites each side's photos into this
  /// device's `<appDocuments>/photos/`, then imports both sides via
  /// [BackupRepository.importSnapshot] under [ConflictMode.lww] — so a
  /// pull never clobbers a local row that's newer than its cloud
  /// counterpart, on EITHER side.
  ///
  /// A shared row's `ownerId` is whatever the cloud reports (some OTHER
  /// user, usually) — never rewritten to the signed-in user's own uid, so
  /// the UI can tell a pulled shared topo apart from the signed-in user's
  /// own data.
  ///
  /// No-ops (never throws) when signed out.
  Future<PullSyncResult> pullOwnAndShared() async {
    final uid = _authRepository.currentSession.uid;
    if (uid == null) return const PullSyncResult.skippedSignedOut();

    final ownTables = await _remote.fetchOwnRows(uid);
    final sharedTables = await _remote.fetchSharedTopos();

    final ownPhotosDownloaded = await _downloadAndRewritePhotos(
      ownTables,
      (canonicalId, ext) =>
          _remote.downloadPhoto(uid: uid, objectPath: '$uid/$canonicalId$ext'),
    );
    final sharedPhotosDownloaded = await _downloadAndRewritePhotos(
      sharedTables,
      (canonicalId, ext) => _remote.downloadSharedPhoto(sharedPhotoPath(canonicalId, ext)),
    );

    // Own rows first, then shared — order doesn't matter for correctness
    // (distinct row ids on each side in the normal case; per-row LWW would
    // make either order safe even if they overlapped), but pushing the
    // user's own data through the identical, already-tested
    // BackupRepository.importSnapshot() path first keeps this readable as
    // "restore mine, then layer in everyone else's shared topos".
    await _backupRepository.importSnapshot({'tables': ownTables}, mode: ConflictMode.lww);
    await _backupRepository.importSnapshot({'tables': sharedTables}, mode: ConflictMode.lww);

    return PullSyncResult.pulled(
      ownRowsPulled: _countRows(ownTables),
      sharedRowsPulled: _countRows(sharedTables),
      photosDownloaded: ownPhotosDownloaded + sharedPhotosDownloaded,
    );
  }

  /// Downloads each DISTINCT remote photo object referenced by
  /// `tables['photos']` via [download] (a canonicalId+ext -> bytes fetcher,
  /// so callers can point this at either the private or the shared object
  /// path), writes it into the app-owned photos directory via
  /// [PhotoFiles.writePhotoBytes], and rewrites every row's `localPath` (in
  /// place, mutating [tables]) to that new path. A row whose remote object
  /// is missing is left with whatever `localPath` it already had (skip
  /// that file, keep the row) rather than failing the whole pull.
  ///
  /// Returns the number of distinct files actually downloaded.
  Future<int> _downloadAndRewritePhotos(
    Map<String, List<Map<String, dynamic>>> tables,
    Future<List<int>?> Function(String canonicalId, String ext) download,
  ) async {
    final photos = tables['photos'];
    if (photos == null || photos.isEmpty) return 0;

    // canonicalId -> the new local path once downloaded, so a shared file
    // (original + its slices) is only fetched once regardless of row order.
    final downloadedPaths = <String, String>{};
    var restoredCount = 0;

    for (final photo in photos) {
      final canonicalId = (photo['parentPhotoId'] as String?) ?? photo['id'] as String;
      final localPath = photo['localPath'] as String? ?? '';
      final ext = p.extension(localPath);

      var newLocalPath = downloadedPaths[canonicalId];
      if (newLocalPath == null) {
        final bytes = await download(canonicalId, ext);
        if (bytes != null) {
          newLocalPath = await _photoFiles.writePhotoBytes(canonicalId, ext, bytes);
          downloadedPaths[canonicalId] = newLocalPath;
          restoredCount++;
        }
      }

      if (newLocalPath != null) {
        photo['localPath'] = newLocalPath;
      }
    }

    return restoredCount;
  }

  /// Total row count across every table in [tables] (rows FETCHED, not
  /// necessarily written locally — see [PullSyncResult.ownRowsPulled]).
  int _countRows(Map<String, List<Map<String, dynamic>>> tables) =>
      tables.values.fold<int>(0, (sum, rows) => sum + rows.length);

  /// The id a photo row's on-disk file is uploaded/downloaded under: a
  /// slice (`parentPhotoId` set) shares its original's file (see S1 in
  /// `photo_files.dart`), so it resolves to the ORIGINAL's id; an original
  /// (`parentPhotoId` null) resolves to its own id.
  String _canonicalPhotoId(db.Photo photo) => photo.parentPhotoId ?? photo.id;
}
