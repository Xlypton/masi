import 'package:path/path.dart' as p;

import '../../../core/db/app_database.dart' as db;
import '../../backup/data/backup_repository.dart';
import '../../backup/data/sync_remote.dart';
import '../../topo/data/photo_files.dart';

/// Hydrates ONE published ("shared") wall's full graph from Supabase (via the
/// anon-capable [SharedWallRemote]) into local Drift + the local photo store,
/// so a cold, signed-OUT visitor to a shareable topo link (Feature #15 Wave
/// 2) gets exactly the same local rows a signed-in user's
/// `SyncService.pullOwnAndShared` would have produced for that wall — which
/// means the EXISTING detail/canvas render path works verbatim afterwards,
/// with no render-side changes needed.
///
/// Deliberately mirrors (rather than reuses directly, since it's a private
/// method) `SyncService._downloadAndRewritePhotos`' download-then-rewrite-
/// `localPath` pattern, and reuses [BackupRepository.importSnapshot] for the
/// actual FK-ordered insert (the same machinery `SyncService.pullOwnAndShared`
/// uses) rather than reinventing per-table upserts — see that class's doc
/// for why Areas->Sectors->Walls->Photos->Routes must be inserted in that
/// order.
///
/// NEVER touches auth/session state — there is no `AuthRepository` field at
/// all. A signed-out visitor is the ONLY case this class exists for; nothing
/// here can accidentally hard-gate on a uid.
class SharedWallHydrator {
  SharedWallHydrator({
    required db.AppDatabase db,
    required BackupRepository backupRepository,
    required SharedWallRemote remote,
    PhotoFiles? photoFiles,
  }) : _db = db, // ignore: prefer_initializing_formals
       _backupRepository = backupRepository, // ignore: prefer_initializing_formals
       _remote = remote, // ignore: prefer_initializing_formals
       _photoFiles = photoFiles ?? PhotoFiles();

  final db.AppDatabase _db;
  final BackupRepository _backupRepository;
  final SharedWallRemote _remote;
  final PhotoFiles _photoFiles;

  /// Ensures wall [wallId] (and its ancestor area/sector, its photo(s) +
  /// downloaded bytes, its routes, and its author's profile) exist in the
  /// LOCAL database, fetching + importing them from the cloud only if
  /// they're not already there.
  ///
  /// FAST NO-OP PATH: if a wall row with this id already exists locally
  /// (whether it was hydrated by an earlier call, synced down normally by a
  /// signed-in pull, or is simply the signed-in owner's own device), this
  /// returns immediately WITHOUT calling [_remote] at all — so repeatedly
  /// opening the same shared link, or opening it on the owner's own already-
  /// populated device, never makes a redundant network round trip.
  ///
  /// Idempotent when the wall is NOT yet local: [BackupRepository
  /// .importSnapshot] upserts by primary key under last-write-wins, so
  /// calling this twice in a row for a not-yet-existing wall (e.g. a retry
  /// after a dropped connection) never creates duplicate rows.
  ///
  /// A `null` return from [SharedWallRemote.fetchSharedWallGraph] (wall not
  /// found, or exists but isn't `visibility == 'shared'` — RLS makes those
  /// indistinguishable, see that method's doc) is a silent no-op: nothing is
  /// written locally, and no exception is thrown. Callers (Wave 3's UI) are
  /// expected to treat "still not local afterwards" as "this link doesn't
  /// point at a real shared topo".
  Future<void> ensureSharedWallLocal(String wallId) async {
    final existing = await (_db.select(
      _db.walls,
    )..where((t) => t.id.equals(wallId))).getSingleOrNull();
    if (existing != null) return;

    final graph = await _remote.fetchSharedWallGraph(wallId);
    if (graph == null) return;

    final photos = [for (final row in graph.photos) Map<String, dynamic>.from(row)];
    await _downloadAndRewritePhotos(photos);

    final snapshot = <String, dynamic>{
      'tables': {
        'profiles': graph.authorProfile != null ? [graph.authorProfile!] : <Map<String, dynamic>>[],
        'areas': [graph.area],
        'sectors': [graph.sector],
        'walls': [graph.wall],
        'photos': photos,
        'routes': graph.routes,
      },
    };
    await _backupRepository.importSnapshot(snapshot, mode: ConflictMode.lww);
  }

  /// Downloads each DISTINCT photo object referenced by [photos] (via
  /// [SharedWallRemote.downloadSharedPhotoAnon], anon-safe per the Wave-1
  /// Storage RLS — see [SharedWallRemote]'s doc), writes it into the LOCAL
  /// photo store via [PhotoFiles.writePhotoBytes], and rewrites each row's
  /// `localPath` IN PLACE to that new local key/path — the exact same
  /// `<appDocuments>/photos/<id><ext>` (native) / `photos/<id><ext>`
  /// (web, `PhotoByteStore` key) convention every render call site already
  /// reads via `PhotoFiles.resolvePhotoPathSync`, so the hydrated photo
  /// renders with zero changes to the display path.
  ///
  /// Mirrors `SyncService._downloadAndRewritePhotos`' canonical-id
  /// deduplication (a slice shares its original's file via `parentPhotoId`)
  /// so a shared wall with multiple photo rows pointing at the same
  /// underlying file only downloads it once. A row whose remote object is
  /// missing is left with whatever `localPath` the cloud row had (skip that
  /// file, keep the row) rather than failing the whole hydration.
  Future<void> _downloadAndRewritePhotos(List<Map<String, dynamic>> photos) async {
    if (photos.isEmpty) return;

    final downloadedPaths = <String, String>{};

    for (final photo in photos) {
      final canonicalId = (photo['parentPhotoId'] as String?) ?? photo['id'] as String;
      final localPath = photo['localPath'] as String? ?? '';
      final ext = p.extension(localPath);

      var newLocalPath = downloadedPaths[canonicalId];
      if (newLocalPath == null) {
        final bytes = await _remote.downloadSharedPhotoAnon(sharedPhotoPath(canonicalId, ext));
        if (bytes != null) {
          newLocalPath = await _photoFiles.writePhotoBytes(canonicalId, ext, bytes);
          downloadedPaths[canonicalId] = newLocalPath;
        }
      }

      if (newLocalPath != null) {
        photo['localPath'] = newLocalPath;
      }
    }
  }
}
