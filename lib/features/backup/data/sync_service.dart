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

  /// Total row count pushed across all nine tables (profiles/areas/sectors/
  /// walls/photos/routes/comments/likes/ascents), INCLUDING tombstones.
  /// Always 0 when [outcome] isn't [SyncPushOutcome.pushed].
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
///
/// P0 fix (#72, "fresh install syncs nothing after login"): the own and
/// shared sides (and, within the shared side, its own sub-fetches — shared
/// topos, shared ascents, profiles, photo downloads) are now fetched AND
/// imported in independently try/caught sections (see [pullOwnAndShared]),
/// so a throw in ANY one section — e.g. a malformed cloud row's null-cast,
/// the original trigger — is caught and recorded in [errors] instead of
/// aborting the others. [ownImported]/[sharedImported] report whether each
/// side actually got imported this call; a `false` on one side never
/// implies a `false` on the other.
class PullResult {
  const PullResult.pulled({
    required this.ownRowsPulled,
    required this.sharedRowsPulled,
    required this.photosDownloaded,
    required this.ownImported,
    required this.sharedImported,
    required this.errors,
  }) : outcome = SyncPullOutcome.pulled;

  const PullResult.skippedSignedOut()
    : outcome = SyncPullOutcome.skippedSignedOut,
      ownRowsPulled = 0,
      sharedRowsPulled = 0,
      photosDownloaded = 0,
      ownImported = false,
      sharedImported = false,
      errors = const [];

  final SyncPullOutcome outcome;

  /// Total row count FETCHED from the signed-in user's own cloud rows
  /// (across all nine tables). Note this counts rows received, not rows
  /// actually WRITTEN locally — a row older than its local counterpart is
  /// fetched but then skipped by last-write-wins during import. 0 when
  /// [outcome] isn't [SyncPullOutcome.pulled], OR when the own-row fetch
  /// itself failed (see [errors]).
  final int ownRowsPulled;

  /// Total row count FETCHED from every currently-shared topo (any owner),
  /// same "fetched, not necessarily written" caveat as [ownRowsPulled]. 0
  /// when [outcome] isn't [SyncPullOutcome.pulled], OR when every shared
  /// sub-fetch failed (a partial shared failure still reports whatever the
  /// OTHER shared sub-fetches returned — see [errors]).
  final int sharedRowsPulled;

  /// Number of distinct photo files actually downloaded (own + shared
  /// combined; excludes rows whose remote object was missing, which are
  /// skipped gracefully, and excludes a side whose photo-download section
  /// threw — see [errors]). Always 0 when [outcome] isn't
  /// [SyncPullOutcome.pulled].
  final int photosDownloaded;

  /// True when the signed-in user's OWN rows were successfully fetched AND
  /// imported this call. `false` when signed out, or when the own-row
  /// fetch/import threw (see [errors]) — critically, a failure in the
  /// SHARED section(s) below can never flip this to `false` (that
  /// cross-contamination was the #72 bug: a single shared-fetch exception
  /// used to abort the own import too).
  final bool ownImported;

  /// True when the shared import (every currently-shared topo + shared
  /// ascent row gathered from whichever shared sub-fetches succeeded) was
  /// successfully written locally this call. `false` when signed out, when
  /// the shared import itself threw, or trivially when there was nothing to
  /// import — never influenced by whether [ownImported] succeeded or not.
  final bool sharedImported;

  /// One human-readable message per section that threw during this call —
  /// own-rows fetch/photo-download/import, shared-topos fetch,
  /// shared-ascents fetch, profiles fetch, shared photo-download, or
  /// shared import — each including the caught error's `toString()`. Empty
  /// when every section succeeded (the common case).
  final List<String> errors;

  bool get didPull => outcome == SyncPullOutcome.pulled;

  @override
  String toString() =>
      'PullResult(outcome: $outcome, ownRowsPulled: $ownRowsPulled, '
      'sharedRowsPulled: $sharedRowsPulled, '
      'photosDownloaded: $photosDownloaded, ownImported: $ownImported, '
      'sharedImported: $sharedImported, errors: $errors)';
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
///    Areas→Sectors→Walls→Photos(originals-before-slices)→Routes→Ascents→
///    Comments→Likes ordering and per-row `updatedAt` comparison apply
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
/// Ascents visibility model (Feature #12, public opt-in ascent logs): the
/// signed-in user's own ascents are always fully pulled via [fetchOwnRows]
/// (private or shared, same as any other own row — see
/// `AscentsRepository.watchLogbook`'s own-scoping doc). Separately, OTHER
/// users' opt-in-`visibility == 'shared'` ascents are pulled via
/// [SyncRemote.fetchSharedAscents] and merged into the same batch
/// [SyncRemote.fetchSharedTopos] returns — which itself still NEVER returns
/// ascent rows (a shared wall does not imply its ascents are public; see
/// that method's doc). A shared-ascent row keeps its original (foreign)
/// `ownerId` on import, exactly like a shared topo's rows above.
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

    // Read every own-table snapshot inside a single transaction so a
    // concurrent pull's transactional importSnapshot() write can't be
    // interleaved partway through — without this, the reads below could
    // observe (say) a wall from before an in-flight pull and a photo from
    // after it, uploading a cross-table snapshot that never actually existed
    // locally. This wraps READS only; conflict/LWW resolution (#2) is a
    // separate, deferred concern.
    late List<db.Profile> profiles;
    late List<db.Area> areas;
    late List<db.Sector> sectors;
    late List<db.Wall> walls;
    late List<db.Photo> photos;
    late List<db.Route> routes;
    late List<db.Comment> comments;
    late List<db.Like> likes;
    late List<db.Ascent> ascents;
    await _db.transaction(() async {
      profiles = await (_db.select(_db.profiles)..where((t) => t.ownerId.equals(uid))).get();
      areas = await (_db.select(_db.areas)..where((t) => t.ownerId.equals(uid))).get();
      sectors = await (_db.select(_db.sectors)..where((t) => t.ownerId.equals(uid))).get();
      walls = await (_db.select(_db.walls)..where((t) => t.ownerId.equals(uid))).get();
      photos = await (_db.select(_db.photos)..where((t) => t.ownerId.equals(uid))).get();
      routes = await (_db.select(_db.routes)..where((t) => t.ownerId.equals(uid))).get();
      comments = await (_db.select(_db.comments)..where((t) => t.ownerId.equals(uid))).get();
      likes = await (_db.select(_db.likes)..where((t) => t.ownerId.equals(uid))).get();
      ascents = await (_db.select(_db.ascents)..where((t) => t.ownerId.equals(uid))).get();
    });

    // Push-side NOT-NULL guard (sync-resilience hardening): drops (+
    // debugPrints, via filterValidSyncRows) any local row missing a required
    // NOT-NULL field before it's ever sent to Supabase, reusing the exact
    // same [syncRequiredFields] map + [hasRequiredSyncFields]/
    // [filterValidSyncRows] helpers the fetch side validates with (imported
    // from `sync_remote.dart`) — the symmetric guard to `fetchOwnRows`'s.
    // A normal local row set is unaffected: local Drift NOT-NULL column
    // constraints mean a genuinely null required field can only happen here
    // via local data corruption, not everyday use. The `?? const ['id']`
    // fallback is defensive only — every table name below has a matching
    // entry in [syncRequiredFields].
    final tablesToRows = <String, List<Map<String, dynamic>>>{
      'profiles': filterValidSyncRows(
        [for (final row in profiles) row.toJson()],
        syncRequiredFields['profiles'] ?? const ['id'],
        debugLabel: 'local profiles (push)',
      ),
      'areas': filterValidSyncRows(
        [for (final row in areas) row.toJson()],
        syncRequiredFields['areas'] ?? const ['id'],
        debugLabel: 'local areas (push)',
      ),
      'sectors': filterValidSyncRows(
        [for (final row in sectors) row.toJson()],
        syncRequiredFields['sectors'] ?? const ['id'],
        debugLabel: 'local sectors (push)',
      ),
      'walls': filterValidSyncRows(
        [for (final row in walls) row.toJson()],
        syncRequiredFields['walls'] ?? const ['id'],
        debugLabel: 'local walls (push)',
      ),
      'photos': filterValidSyncRows(
        [for (final row in photos) row.toJson()],
        syncRequiredFields['photos'] ?? const ['id'],
        debugLabel: 'local photos (push)',
      ),
      'routes': filterValidSyncRows(
        [for (final row in routes) row.toJson()],
        syncRequiredFields['routes'] ?? const ['id'],
        debugLabel: 'local routes (push)',
      ),
      'comments': filterValidSyncRows(
        [for (final row in comments) row.toJson()],
        syncRequiredFields['comments'] ?? const ['id'],
        debugLabel: 'local comments (push)',
      ),
      'likes': filterValidSyncRows(
        [for (final row in likes) row.toJson()],
        syncRequiredFields['likes'] ?? const ['id'],
        debugLabel: 'local likes (push)',
      ),
      // Ascents ARE pushed here (own-row push, no visibility distinction) —
      // it's fetchSharedTopos (pull side) that keeps them private, not push.
      'ascents': filterValidSyncRows(
        [for (final row in ascents) row.toJson()],
        syncRequiredFields['ascents'] ?? const ['id'],
        debugLabel: 'local ascents (push)',
      ),
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
  ///
  /// A TOMBSTONED photo (`deletedAt` set — see
  /// `PhotoRepository.deleteOriginalPhoto`) is never (re-)uploaded here:
  /// instead both its private and shared cloud copies are REMOVED (via
  /// [SyncRemote.removePhoto]/[SyncRemote.removeSharedPhoto]), unconditionally
  /// and regardless of whether either copy was ever actually uploaded —
  /// both calls are best-effort/idempotent on an absent object. Without
  /// this, a deleted photo's bytes would linger in Storage forever, and
  /// worse, a naive re-upload of the row's still-referenced `localPath`
  /// would resurrect bytes that local storage may have already purged.
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

      final ext = p.extension(photo.localPath);

      if (photo.deletedAt != null) {
        await _remote.removePhoto(uid: uid, photoId: canonicalId, ext: ext);
        await _remote.removeSharedPhoto(photoId: canonicalId, ext: ext);
        continue;
      }

      final needsPrivate = !alreadyPrivate.contains('$uid/$canonicalId$ext');
      final needsShared =
          wallVisibility[photo.wallId] == 'shared' &&
          !alreadyShared.contains(sharedPhotoPath(canonicalId, ext));
      if (!needsPrivate && !needsShared) continue;

      // `photo.localPath` as stored may be RELATIVE (`photos/<id>.jpg`, the
      // canonical form since #17) or an already-valid legacy ABSOLUTE path
      // — `readPhotoBytes` resolves either against the current platform's
      // storage (app documents dir natively, byte store on web) rather than
      // touching `dart:io` directly, and returns `null` (instead of
      // throwing) when the file can't be found/read. Read at most once even
      // when both copies are missing.
      final bytes = await _photoFiles.readPhotoBytes(photo.localPath);
      if (bytes == null) continue;
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
  /// P0 fix (#72, "fresh install syncs nothing after login"): every
  /// independent section below — own (fetch + own photo-download + own
  /// import), shared-topos fetch, shared-ascents fetch, profiles fetch,
  /// shared photo-download, and the shared import — runs inside its OWN
  /// try/catch. A throw ANYWHERE (the original trigger was a null field in
  /// one cloud row hitting a non-null `as String` cast in the shared-topo/
  /// ascent fetch — see [SyncRemote.fetchSharedTopos]/[fetchSharedAscents]
  /// for the accompanying per-row guard) is caught, recorded in
  /// [PullResult.errors], and does NOT prevent the OTHER sections from
  /// running — most importantly, the own section is fetched+imported
  /// FIRST and in total isolation, so a broken shared fetch can never again
  /// leave a fresh install with EVERYTHING empty. Never throws.
  ///
  /// No-ops (never throws) when signed out.
  Future<PullResult> pullOwnAndShared() async {
    final uid = _authRepository.currentSession.uid;
    if (uid == null) return const PullResult.skippedSignedOut();

    var ownRowsPulled = 0;
    var sharedRowsPulled = 0;
    var ownPhotosDownloaded = 0;
    var sharedPhotosDownloaded = 0;
    var ownImported = false;
    var sharedImported = false;
    final errors = <String>[];

    // ---- OWN section ----------------------------------------------------
    // Fetched, its photos downloaded, and imported FIRST and entirely
    // before any shared fetch is even attempted — the signed-in user's own
    // topos must come back on a fresh install regardless of what happens
    // below.
    var ownFetchOk = false;
    var ownHadError = false;
    var ownTables = <String, List<Map<String, dynamic>>>{};
    try {
      ownTables = await _remote.fetchOwnRows(uid);
      ownRowsPulled = _countRows(ownTables);
      ownFetchOk = true;
    } catch (e) {
      ownHadError = true;
      errors.add('own rows fetch failed: $e');
    }

    if (ownFetchOk) {
      try {
        ownPhotosDownloaded = await _downloadAndRewritePhotos(
          ownTables,
          (canonicalId, ext) =>
              _remote.downloadPhoto(uid: uid, objectPath: '$uid/$canonicalId$ext'),
        );
      } catch (e) {
        ownHadError = true;
        errors.add('own photo downloads failed: $e');
      }

      try {
        await _backupRepository.importSnapshot({'tables': ownTables}, mode: ConflictMode.lww);
        // ownImported reflects the WHOLE own pipeline (fetch + photo
        // download + import), not just this final write — a hiccup earlier
        // (e.g. the photo download) still means "own" wasn't a clean,
        // fully-successful pull this time, even though the rows themselves
        // did get written.
        ownImported = !ownHadError;
      } catch (e) {
        errors.add('own rows import failed: $e');
      }
    }

    // ---- SHARED section(s) -----------------------------------------------
    // Every currently-shared topo (any owner) — gathered from FOUR
    // independent sub-fetches (shared topos, shared ascents, profiles) plus
    // a photo-download pass, each isolated so one failing sub-fetch can't
    // lose rows another sub-fetch already gathered; the final shared
    // import is isolated too, so a photo-download exception (e.g. a
    // Storage error) still lets the metadata rows import (minus their
    // photo bytes) rather than losing the whole shared batch.
    final sharedTables = <String, List<Map<String, dynamic>>>{};
    var sharedHadError = false;

    try {
      sharedTables.addAll(await _remote.fetchSharedTopos());
    } catch (e) {
      sharedHadError = true;
      errors.add('shared topos fetch failed: $e');
    }

    // Feature #12 (public opt-in ascent logs): pull every OTHER owner's
    // opt-in-`shared` ascents via the separate fetchSharedAscents call and
    // merge its rows into the same `sharedTables` map fetchSharedTopos
    // built — NOT into `fetchSharedTopos` itself, which deliberately never
    // returns an `'ascents'` key (a shared wall doesn't imply its ascents
    // are public). Merging here means this whole batch flows through the
    // identical importSnapshot(mode: lww) call below, so Ascents importing
    // BEFORE Comments/Likes (see `BackupRepository.importSnapshot`'s
    // FK-ordering comment) applies uniformly to own AND shared rows alike.
    //
    // fetchSharedAscents ALSO returns each shared ascent's minimal
    // area/sector/wall/photo/route ancestor chain (see its doc) — required
    // because `Ascents.routeId`/`Ascents.wallId` are enforced FKs locally,
    // and a shared ascent's wall may well be `'private'` and otherwise
    // absent from `sharedTables` entirely. areas/sectors/walls/photos/
    // routes are CONCATENATED (not overwritten) with whatever
    // fetchSharedTopos already put there — a wall that's both openly shared
    // AND host to a shared ascent would otherwise get double-fetched rows,
    // which is harmless (idempotent per-id upsert on import) but the
    // concatenation avoids silently dropping either side's rows.
    try {
      final sharedAscentTables = await _remote.fetchSharedAscents();
      for (final key in const ['areas', 'sectors', 'walls', 'photos', 'routes']) {
        sharedTables[key] = [
          ...(sharedTables[key] ?? const []),
          ...(sharedAscentTables[key] ?? const []),
        ];
      }
      sharedTables['ascents'] = [
        ...(sharedTables['ascents'] ?? const []),
        ...(sharedAscentTables['ascents'] ?? const []),
      ];
    } catch (e) {
      sharedHadError = true;
      errors.add('shared ascents fetch failed: $e');
    }

    // Resolve display-name profiles for every uid a pulled SHARED row is
    // attributed to (e.g. a shared topo's owner), plus the signed-in user's
    // own uid, via one batched fetchProfiles call — [fetchOwnRows]'s generic
    // `ownerId = uid` loop already put the signed-in user's OWN profile row
    // into `ownTables['profiles']`, but has no way to reach any OTHER
    // user's profile, and [fetchSharedTopos] has no FK to a profile to join
    // on. Merged into `sharedTables['profiles']` (a key it doesn't otherwise
    // set) so it flows through the same importSnapshot(mode: lww) call as
    // every other shared row below; re-including the own uid here is
    // harmless (idempotent LWW re-write of the same row already imported
    // from `ownTables`).
    try {
      final profileUids = <String>{uid};
      for (final rows in sharedTables.values) {
        for (final row in rows) {
          final ownerId = row['ownerId'] as String?;
          if (ownerId != null) profileUids.add(ownerId);
        }
      }
      sharedTables['profiles'] = await _remote.fetchProfiles(profileUids);
    } catch (e) {
      sharedHadError = true;
      errors.add('profiles fetch failed: $e');
    }

    sharedRowsPulled = _countRows(sharedTables);

    try {
      sharedPhotosDownloaded = await _downloadAndRewritePhotos(
        sharedTables,
        (canonicalId, ext) => _remote.downloadSharedPhoto(sharedPhotoPath(canonicalId, ext)),
      );
    } catch (e) {
      sharedHadError = true;
      errors.add('shared photo downloads failed: $e');
    }

    try {
      await _backupRepository.importSnapshot({'tables': sharedTables}, mode: ConflictMode.lww);
      // sharedImported reflects the WHOLE shared pipeline (shared-topos +
      // shared-ascents + profiles fetches, photo downloads, and this final
      // import), not just this write — mirrors ownImported above.
      sharedImported = !sharedHadError;
    } catch (e) {
      errors.add('shared rows import failed: $e');
    }

    return PullResult.pulled(
      ownRowsPulled: ownRowsPulled,
      sharedRowsPulled: sharedRowsPulled,
      photosDownloaded: ownPhotosDownloaded + sharedPhotosDownloaded,
      ownImported: ownImported,
      sharedImported: sharedImported,
      errors: errors,
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
  /// necessarily written locally — see [PullResult.ownRowsPulled]).
  int _countRows(Map<String, List<Map<String, dynamic>>> tables) =>
      tables.values.fold<int>(0, (sum, rows) => sum + rows.length);

  /// The id a photo row's on-disk file is uploaded/downloaded under: a
  /// slice (`parentPhotoId` set) shares its original's file (see S1 in
  /// `photo_files.dart`), so it resolves to the ORIGINAL's id; an original
  /// (`parentPhotoId` null) resolves to its own id.
  String _canonicalPhotoId(db.Photo photo) => photo.parentPhotoId ?? photo.id;
}
