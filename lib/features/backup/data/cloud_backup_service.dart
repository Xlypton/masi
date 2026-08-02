import 'package:path/path.dart' as p;

import '../../account/data/auth_repository.dart';
import '../../topo/data/photo_files.dart';
import 'backup_remote.dart';
import 'backup_repository.dart';
import 'connectivity_service.dart';

/// Outcome of a [CloudBackupService.pushBackup] call.
enum PushOutcome {
  /// The snapshot (and any not-yet-uploaded photos) was pushed.
  pushed,

  /// No-op: nobody is signed in, so there's no uid to scope the backup to.
  skippedSignedOut,

  /// No-op: `wifiOnly` is set and the current connection isn't wifi.
  skippedNotWifi,
}

/// Result of a [CloudBackupService.pushBackup] call.
class PushBackupResult {
  const PushBackupResult.pushed({required this.photosUploaded})
    : outcome = PushOutcome.pushed;

  const PushBackupResult.skippedSignedOut()
    : outcome = PushOutcome.skippedSignedOut,
      photosUploaded = 0;

  const PushBackupResult.skippedNotWifi()
    : outcome = PushOutcome.skippedNotWifi,
      photosUploaded = 0;

  final PushOutcome outcome;

  /// Number of photo files actually uploaded (excludes ones skipped because
  /// they were already present remotely). Always 0 when [outcome] isn't
  /// [PushOutcome.pushed].
  final int photosUploaded;

  bool get didPush => outcome == PushOutcome.pushed;

  @override
  String toString() =>
      'PushBackupResult(outcome: $outcome, photosUploaded: $photosUploaded)';
}

/// Outcome of a [CloudBackupService.pullBackup] call.
enum PullOutcome {
  /// A remote snapshot existed and was imported.
  restored,

  /// No-op: nobody is signed in.
  skippedSignedOut,

  /// The signed-in user has never pushed a backup — nothing to restore.
  nothingToRestore,
}

/// Result of a [CloudBackupService.pullBackup] call.
class PullBackupResult {
  const PullBackupResult.restored({required this.photosRestored})
    : outcome = PullOutcome.restored;

  const PullBackupResult.skippedSignedOut()
    : outcome = PullOutcome.skippedSignedOut,
      photosRestored = 0;

  const PullBackupResult.nothingToRestore()
    : outcome = PullOutcome.nothingToRestore,
      photosRestored = 0;

  final PullOutcome outcome;

  /// Number of distinct photo files actually downloaded (excludes rows
  /// whose remote object was missing, which are skipped gracefully). Always
  /// 0 when [outcome] isn't [PullOutcome.restored].
  final int photosRestored;

  bool get didRestore => outcome == PullOutcome.restored;

  @override
  String toString() =>
      'PullBackupResult(outcome: $outcome, photosRestored: $photosRestored)';
}

/// Cloud backup engine: pushes the local snapshot ([BackupRepository]) plus
/// its referenced photo files to Supabase, and pulls them back down onto a
/// (possibly fresh) local database + photos directory.
///
/// Every collaborator is injected so this is fully testable against fakes —
/// no real network, platform channel, or `path_provider` call is reachable
/// from a unit test that supplies its own [BackupRemote], [ConnectivityService],
/// [AuthRepository], and [PhotoFiles]:
///  - [BackupRemote]: the `backups` table + `topo-photos` Storage bucket.
///  - [AuthRepository]: gates push/pull on being signed in and supplies the
///    uid every remote path is prefixed with.
///  - [ConnectivityService]: gates `wifiOnly` pushes on the current network.
///  - [PhotoFiles]: where restored photo bytes land locally
///    (`<appDocuments>/photos/<photoId><ext>`).
class CloudBackupService {
  // Named (not positional) so call sites can't silently swap two
  // same-typed collaborators; the private fields below intentionally stay
  // underscore-prefixed for internal encapsulation, so these assignments
  // can't be collapsed into `this.<field>` initializing formals without
  // also renaming the public parameters — hence the per-line ignores.
  CloudBackupService({
    required BackupRepository backupRepository,
    required AuthRepository authRepository,
    required BackupRemote remote,
    required ConnectivityService connectivity,
    PhotoFiles? photoFiles,
    bool Function()? wifiOnly,
  }) : _backupRepository = backupRepository, // ignore: prefer_initializing_formals
       _authRepository = authRepository, // ignore: prefer_initializing_formals
       _remote = remote, // ignore: prefer_initializing_formals
       _connectivity = connectivity, // ignore: prefer_initializing_formals
       _photoFiles = photoFiles ?? PhotoFiles(),
       _wifiOnly = wifiOnly ?? (() => false);

  final BackupRepository _backupRepository;
  final AuthRepository _authRepository;
  final BackupRemote _remote;
  final ConnectivityService _connectivity;
  final PhotoFiles _photoFiles;
  final bool Function() _wifiOnly;

  /// Pushes the full local snapshot + every not-yet-uploaded photo file to
  /// the cloud, scoped to the signed-in user's uid.
  ///
  /// No-ops (never throws) when signed out, or when `wifiOnly` is on and
  /// the current connection isn't wifi — both report a `skipped*` outcome
  /// rather than pushing partial/no data.
  Future<PushBackupResult> pushBackup() async {
    final uid = _authRepository.currentSession.uid;
    if (uid == null) return const PushBackupResult.skippedSignedOut();

    if (_wifiOnly()) {
      final status = await _connectivity.currentStatus();
      if (status != NetworkStatus.wifi) {
        return const PushBackupResult.skippedNotWifi();
      }
    }

    final snapshot = await _backupRepository.exportSnapshot();
    await _remote.upsertSnapshot(
      uid: uid,
      snapshot: snapshot,
      schemaVersion: snapshot['schemaVersion'] as int,
    );

    final photosUploaded = await _uploadPhotos(uid, snapshot);
    return PushBackupResult.pushed(photosUploaded: photosUploaded);
  }

  /// Uploads every DISTINCT on-disk photo file referenced by [snapshot]'s
  /// Photos rows, skipping objects already present remotely. Slices share
  /// their original's file (see [_canonicalPhotoId]), so each on-disk file
  /// is uploaded at most once regardless of how many rows reference it.
  Future<int> _uploadPhotos(String uid, Map<String, dynamic> snapshot) async {
    final photos = _photosOf(snapshot);
    if (photos.isEmpty) return 0;

    final alreadyRemote = await _remote.listPhotoObjectPaths(uid);
    final seenCanonicalIds = <String>{};
    var uploaded = 0;

    for (final photo in photos) {
      final canonicalId = _canonicalPhotoId(photo);
      if (!seenCanonicalIds.add(canonicalId)) {
        continue; // this on-disk file was already handled via another row
      }

      final localPath = photo['localPath'] as String?;
      if (localPath == null) continue;

      final ext = p.extension(localPath);
      final objectPath = '$uid/$canonicalId$ext';
      if (alreadyRemote.contains(objectPath)) continue;

      // `localPath` as stored may be RELATIVE (`photos/<id>.jpg`, the
      // canonical form since #17) or an already-valid legacy ABSOLUTE path
      // — `readPhotoBytes` resolves either against the current platform's
      // storage (app documents dir natively, byte store on web) rather than
      // touching `dart:io` directly, and returns `null` (instead of
      // throwing) when the file can't be found/read.
      final bytes = await _photoFiles.readPhotoBytes(localPath);
      if (bytes == null) continue;
      await _remote.uploadPhoto(
        uid: uid,
        photoId: canonicalId,
        ext: ext,
        bytes: bytes,
      );
      uploaded++;
    }

    return uploaded;
  }

  /// Pulls the signed-in user's remote snapshot down, restoring every
  /// referenced photo into this device's `<appDocuments>/photos/` and
  /// rewriting each restored row's `localPath` to point there BEFORE
  /// importing, then imports via [BackupRepository.importSnapshot] under
  /// [mode] (defaults to [ConflictMode.lww] so an automatic restore never
  /// clobbers newer local edits; pass [ConflictMode.replace] for an
  /// explicit force-restore).
  ///
  /// No-ops when signed out, or when the signed-in user has never pushed a
  /// backup (nothing to restore) — neither case throws.
  ///
  /// Throws [SnapshotSchemaDowngradeException], having changed nothing at
  /// all, when the remote snapshot was written by a build newer than this
  /// one. That refusal happens before the first photo byte is downloaded;
  /// see the guard's comment below and the exception's own doc for why a
  /// partial restore is the worse outcome.
  ///
  /// Restore is NOT all-or-nothing: [BackupRepository.importSnapshot] imports
  /// each table in its own transaction, so a partial-failure restore (e.g. one
  /// corrupt/incompatible table in an old backup) keeps the tables that
  /// imported and rethrows an aggregate naming the ones that failed, rather
  /// than rolling the whole restore back. Intended — matches the resilient
  /// per-section sync-pull behavior.
  Future<PullBackupResult> pullBackup({
    ConflictMode mode = ConflictMode.lww,
  }) async {
    final uid = _authRepository.currentSession.uid;
    if (uid == null) return const PullBackupResult.skippedSignedOut();

    final remote = await _remote.fetchSnapshot(uid);
    if (remote == null) return const PullBackupResult.nothingToRestore();

    final snapshot = Map<String, dynamic>.from(remote.snapshot);

    // Refuse a snapshot from a newer build HERE, before
    // `_downloadAndRewritePhotos` writes a single byte into this device's
    // photos directory. `BackupRepository.importSnapshot` carries the same
    // guard, but it only runs after the photo download — and a refusal that
    // has already littered the photos directory cannot honestly say
    // "nothing has been changed".
    //
    // Both claims are checked: the `backups` row's `schema_version` COLUMN
    // (the table's metadata contract, and the only one a server-side or
    // listing query would ever see) and the `schemaVersion` INSIDE the
    // snapshot blob. `pushBackup` derives the former from the latter, so
    // they agree for anything this app wrote; if they ever disagree, the
    // higher claim wins, because a snapshot whose two version stamps
    // contradict each other is not one to import optimistically.
    _backupRepository.assertRestorable(remote.schemaVersion);
    _backupRepository.assertRestorable(snapshot['schemaVersion']);

    final tables = Map<String, dynamic>.from(snapshot['tables'] as Map);

    final photosRestored = await _downloadAndRewritePhotos(uid, tables);

    snapshot['tables'] = tables;
    await _backupRepository.importSnapshot(snapshot, mode: mode);

    return PullBackupResult.restored(photosRestored: photosRestored);
  }

  /// Downloads each DISTINCT remote photo object referenced by
  /// `tables['photos']`, writes it into the app-owned photos directory via
  /// [PhotoFiles.writePhotoBytes], and rewrites every row's `localPath` (in
  /// place, mutating [tables]) to that new path. A row whose remote object
  /// is missing is left with whatever `localPath` it already had (skip that
  /// file, keep the row) rather than failing the whole pull.
  ///
  /// Returns the number of distinct files actually downloaded.
  Future<int> _downloadAndRewritePhotos(
    String uid,
    Map<String, dynamic> tables,
  ) async {
    final rawPhotos = tables['photos'] as List<dynamic>? ?? const [];
    if (rawPhotos.isEmpty) return 0;

    final photos = [
      for (final item in rawPhotos) Map<String, dynamic>.from(item as Map),
    ];

    // canonicalId -> the new local path once downloaded, so a shared file
    // (original + its slices) is only fetched once regardless of row order.
    final downloaded = <String, String>{};
    var restoredCount = 0;

    for (final photo in photos) {
      final canonicalId = _canonicalPhotoId(photo);
      final localPath = photo['localPath'] as String? ?? '';
      final ext = p.extension(localPath);

      var newLocalPath = downloaded[canonicalId];
      if (newLocalPath == null) {
        final objectPath = '$uid/$canonicalId$ext';
        final bytes = await _remote.downloadPhoto(
          uid: uid,
          objectPath: objectPath,
        );
        if (bytes != null) {
          newLocalPath = await _photoFiles.writePhotoBytes(
            canonicalId,
            ext,
            bytes,
          );
          downloaded[canonicalId] = newLocalPath;
          restoredCount++;
        }
      }

      if (newLocalPath != null) {
        photo['localPath'] = newLocalPath;
      }
    }

    tables['photos'] = photos;
    return restoredCount;
  }

  List<Map<String, dynamic>> _photosOf(Map<String, dynamic> snapshot) {
    final tables = (snapshot['tables'] as Map).cast<String, dynamic>();
    final raw = tables['photos'] as List<dynamic>? ?? const [];
    return [for (final item in raw) Map<String, dynamic>.from(item as Map)];
  }

  /// The id a photo row's on-disk file is uploaded/downloaded under: a
  /// slice (`parentPhotoId` set) shares its original's file (see S1 in
  /// `photo_files.dart`), so it resolves to the ORIGINAL's id; an original
  /// (`parentPhotoId` null) resolves to its own id.
  String _canonicalPhotoId(Map<String, dynamic> photo) {
    final parentId = photo['parentPhotoId'] as String?;
    return parentId ?? photo['id'] as String;
  }
}
