import 'dart:typed_data';

import 'package:drift/drift.dart' show BooleanExpressionOperators, Value;
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:path/path.dart' as p;

import '../../../core/db/app_database.dart' as db;
import '../../../core/storage/storage_persistence_service.dart';
import '../../account/data/auth_repository.dart';
import '../../topo/data/photo_files.dart';
import '../../topo/data/public_photo_prune_service.dart'
    show kPruneKeepNewestForeign, kPrunePressureHighWatermark;
import '../domain/shared_topo_scope.dart';
import 'backup_repository.dart';
import 'connectivity_service.dart';
import 'published_photo_metadata.dart';
import 'sync_remote.dart';

/// How many OTHER climbers' photos' BYTES one [SyncService.pullOwnAndShared]
/// will download.
///
/// Deliberately defined AS [kPruneKeepNewestForeign] rather than as a separate
/// literal that happens to be the same number. The two are the two ends of one
/// policy, and they must move together:
///
///  * `kPruneKeepNewestForeign` is the floor `PublicPhotoPruneService` refuses
///    to evict at ANY storage pressure — the newest N foreign photos, i.e. the
///    part of the community feed the user is actually browsing.
///  * Everything beyond that floor is, by that same policy's own definition,
///    the FIRST thing eviction throws away. Downloading more than N foreign
///    photos in one pull is therefore work whose result the eviction policy is
///    explicitly designed to discard first: megabytes of metered cellular
///    traffic and origin quota spent to produce eviction candidates.
///
/// So the bound is not "20 feels safe", it is "never fetch more than the
/// retention policy is willing to keep". Raise `kPruneKeepNewestForeign` and
/// this rises with it; a future edit cannot desynchronise them without
/// deleting this line.
const int kSharedPhotoByteBudgetPerPull = kPruneKeepNewestForeign;

/// Why a pull downloaded fewer OTHER climbers' photo bytes than it found
/// references for.
///
/// This is an ADVISORY, never an error — see
/// [PullResult.sharedPhotoBytesSkipped].
enum SharedPhotoBudgetReason {
  /// Nothing was withheld: every foreign photo whose bytes were missing got
  /// fetched. The overwhelmingly common outcome once the cache is warm.
  withinBudget,

  /// [SyncService.sharedPhotoByteBudget] was reached. The remaining photos
  /// keep their metadata and are healed on demand when actually looked at
  /// (`MissingPhotoByteResolver`), or by a later pull.
  budgetSpent,

  /// The origin is already above [kPrunePressureHighWatermark], so this pull
  /// downloaded ZERO foreign photo bytes rather than its usual budget —
  /// adding megabytes to a store that is about to be pruned is pure churn.
  storagePressure,
}

/// What one `_downloadAndRewritePhotos` pass did.
typedef PhotoDownloadPassOutcome = ({
  /// Distinct files actually fetched and written locally.
  int downloaded,

  /// Distinct foreign files whose bytes were NOT fetched because the pass ran
  /// out of budget (or had none to begin with, under storage pressure).
  int skippedForBudget,
});

/// How much of the signed-in user's own data one [SyncService.pushOwn] call
/// sends.
///
/// D-4 keeps the full-state re-push engine and fixes the SCHEDULER; this enum
/// is that split made explicit rather than an outbox:
///  - [full] re-reads and re-sends EVERY own row, exactly as `pushOwn` always
///    did. Idempotent and loss-proof: it cannot be defeated by a `dirty` flag
///    that was cleared without the row actually landing. `SyncOrchestrator`
///    runs one of these on app start and on every connectivity regain.
///  - [dirtyOnly] sends just the rows whose `dirty` flag is still set — the
///    fast path, and the fix for push cost scaling with library size instead
///    of change count (S7).
///
/// Defaults to [full] everywhere, so no existing caller changes behaviour.
///
/// PRECONDITION for [dirtyOnly], and the reason [full] is retained: every
/// push-worthy local write must set `dirty: true` alongside `updatedAt`. A
/// writer that does not is invisible to a [dirtyOnly] push until the next
/// [full] one. Every push-worthy writer now satisfies this:
/// `LibraryCrudRepository` as of §1e, and `RouteRepository`'s three writes
/// (`upsertRoute` insert/update, `softDeleteRoute`) since the route-dirty
/// fix — so a route-only edit schedules a push IMMEDIATELY rather than
/// waiting for the next app-start / connectivity-regain [full] push, which
/// is what it used to do. [full] is retained anyway: it is the safety net
/// that makes the engine loss-proof even if some future writer forgets the
/// flag. See `SyncService.hasPendingLocalChanges`.
enum PushScope { full, dirtyOnly }

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
///
/// S1 fix (§1d): [rowsFailed]/[errors] mirror [PullResult.errors]' shape on
/// the push side. Before this, a push could only report how many rows it
/// HANDED to the remote — every per-table failure was swallowed inside
/// [SyncRemote.upsertOwnRows] — so a push where literally nothing landed
/// still produced `outcome == pushed` with a healthy row count, and the
/// Account screen's `sync-status` line rendered "Synced • just now".
class PushSyncResult {
  const PushSyncResult.pushed({
    required this.rowsPushed,
    required this.photosUploaded,
    this.rowsFailed = 0,
    this.errors = const [],
    this.photosFailed = 0,
    this.photosMissingLocalBytes = 0,
    this.photoErrors = const [],
  }) : outcome = SyncPushOutcome.pushed;

  const PushSyncResult.skippedSignedOut()
    : outcome = SyncPushOutcome.skippedSignedOut,
      rowsPushed = 0,
      photosUploaded = 0,
      rowsFailed = 0,
      errors = const [],
      photosFailed = 0,
      photosMissingLocalBytes = 0,
      photoErrors = const [];

  const PushSyncResult.skippedNotWifi()
    : outcome = SyncPushOutcome.skippedNotWifi,
      rowsPushed = 0,
      photosUploaded = 0,
      rowsFailed = 0,
      errors = const [],
      photosFailed = 0,
      photosMissingLocalBytes = 0,
      photoErrors = const [];

  final SyncPushOutcome outcome;

  /// Total row count now KNOWN TO BE IN THE CLOUD across all nine tables
  /// (profiles/areas/sectors/walls/photos/routes/comments/likes/ascents),
  /// INCLUDING tombstones — rows this call upserted, plus rows the
  /// last-writer-wins pre-check skipped because the cloud copy is strictly
  /// newer (nothing left to send for those; see
  /// [TablePushOutcome.rowsSkippedNewerRemote]).
  ///
  /// S1 fix: this used to count rows merely HANDED TO the remote. Rows that
  /// did NOT land are in [rowsFailed]. It also EXCLUDES any photo row withheld
  /// because its bytes did not land (§1f — see [photosFailed]): such a row
  /// never entered `tablesToRows` at all. Always 0 when [outcome] isn't
  /// [SyncPushOutcome.pushed].
  final int rowsPushed;

  /// Number of distinct photo FILES actually uploaded (private copy and/or
  /// shared copy; excludes files already present remotely under a given
  /// path). Always 0 when [outcome] isn't [SyncPushOutcome.pushed].
  final int photosUploaded;

  /// Rows this push did NOT get into the cloud: every row of a table whose
  /// upsert failed (see [TablePushOutcome.failed]) PLUS every local row
  /// excluded by [SyncService.pushOwn]'s required-NOT-NULL-field guard (L5 —
  /// with no outbox, an excluded row used to be dropped from this and every
  /// future push, visible only as a `debugPrint`).
  final int rowsFailed;

  /// One human-readable message per table that failed to push or that had
  /// rows excluded by the required-field guard, each including the caught
  /// error's `toString()` where there was one. Empty when everything landed
  /// (the common case). Mirrors [PullResult.errors].
  final List<String> errors;

  /// Number of distinct photo files whose upload was REQUIRED this push and
  /// FAILED — the byte read threw, or `uploadPhoto`/`uploadSharedPhoto` threw.
  ///
  /// RETRYABLE, which is why it is a term of [fullyLanded]: a network blip /
  /// transient Storage error will succeed on a later attempt, at which point
  /// the rows withheld below go up too. That `fullyLanded` term is what
  /// actually drives the backoff loop — `SyncOrchestrator._runPush` keys the
  /// retry off `fullyLanded`, never off [hasPhotoFailures], which is a
  /// convenience predicate with no production caller. Each of these photos' `Photos` rows was HELD BACK from this push's
  /// metadata upsert (S5 — see [SyncService._uploadOwnPhotos]), which is what
  /// stops another device from ever pulling a row pointing at a Storage object
  /// that does not exist.
  ///
  /// Pre-fix this was a bare `continue` with no error and no counter, while
  /// the metadata had already been pushed.
  final int photosFailed;

  /// Number of distinct photo files that have NO local bytes on this device at
  /// all (`PhotoFiles.readPhotoBytes` returned `null`) despite an upload being
  /// required.
  ///
  /// Deliberately SEPARATE from [photosFailed], and deliberately NOT retried:
  /// nothing will ever make those bytes appear on this device (they were
  /// evicted, or the row predates the L3 fix), so counting it as a retryable
  /// failure would spin §1e's "retry until clean" loop forever. Such a row's
  /// metadata IS still pushed — it is the only surviving record of the photo
  /// (wall, dimensions, crop, isPrimary, sortOrder) and another device may
  /// well already hold the object — but it is reported in [photoErrors] rather
  /// than vanishing silently.
  ///
  /// It is not silent to the USER either: `SyncOrchestrator` derives
  /// `SyncOrchestratorState.lastPushWarning` from this count on every push,
  /// so the Account screen says the photo is not in the cloud and is not
  /// going to be — WITHOUT the app entering an error state, withholding
  /// `lastSyncedAt`, or retrying forever. Counting it without surfacing it
  /// would leave the push reporting "Synced • just now" while a photo
  /// silently went nowhere.
  final int photosMissingLocalBytes;

  /// One human-readable message per photo counted in [photosFailed] OR
  /// [photosMissingLocalBytes], each naming the canonical photo id and what
  /// went wrong. Empty on a clean push.
  final List<String> photoErrors;

  bool get didPush => outcome == SyncPushOutcome.pushed;

  /// True only when the push actually RAN and every row AND every photo file
  /// it was responsible for reached the cloud. The ONLY condition under which
  /// `SyncOrchestrator._runPush` may report [SyncStatus.idle] and stamp a
  /// fresh `lastSyncedAt` (S1).
  ///
  /// The `photosFailed == 0` term is load-bearing and closes the single
  /// highest-severity defect in the Stage-1 plan (reconciliation D-2). §1f
  /// WITHHOLDS a failed photo's row from `tablesToRows`, so a push in which
  /// EVERY photo's bytes failed leaves [rowsFailed] at 0 and [errors] empty.
  /// Without this term such a push reports `fullyLanded == true`, the
  /// orchestrator stamps a fresh `lastSyncedAt`, and the Account screen
  /// renders "Synced • just now" — precisely the S1 lie the whole of §1d
  /// exists to kill, re-entering through the photo path.
  ///
  /// [photosMissingLocalBytes] is DELIBERATELY EXCLUDED: it is not retryable,
  /// so including it would pin the app permanently outside [SyncStatus.idle]
  /// and would stop §1e's retry loop from ever terminating. Those photos are
  /// reported through [photoErrors] and, to the user, through
  /// `SyncOrchestratorState.lastPushWarning` instead.
  bool get fullyLanded =>
      didPush && rowsFailed == 0 && errors.isEmpty && photosFailed == 0;

  /// True when at least one photo's bytes failed to upload for a RETRYABLE
  /// reason. Deliberately does NOT include [photosMissingLocalBytes].
  ///
  /// A readability helper only: nothing in `lib/` calls it, because the
  /// retry is driven by [fullyLanded], which already embeds the identical
  /// `photosFailed == 0` term. Kept because it names the concept at the call
  /// sites that assert on it.
  bool get hasPhotoFailures => photosFailed > 0;

  @override
  String toString() =>
      'PushSyncResult(outcome: $outcome, rowsPushed: $rowsPushed, '
      'photosUploaded: $photosUploaded, rowsFailed: $rowsFailed, '
      'errors: $errors, photosFailed: $photosFailed, '
      'photosMissingLocalBytes: $photosMissingLocalBytes, '
      'photoErrors: $photoErrors)';
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
    this.ownRowsOrphaned = 0,
    this.sharedPhotoBytesSkipped = 0,
    this.sharedPhotoBudgetReason = SharedPhotoBudgetReason.withinBudget,
  }) : outcome = SyncPullOutcome.pulled;

  const PullResult.skippedSignedOut()
    : outcome = SyncPullOutcome.skippedSignedOut,
      ownRowsPulled = 0,
      sharedRowsPulled = 0,
      photosDownloaded = 0,
      ownImported = false,
      sharedImported = false,
      errors = const [],
      ownRowsOrphaned = 0,
      sharedPhotoBytesSkipped = 0,
      sharedPhotoBudgetReason = SharedPhotoBudgetReason.withinBudget;

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

  /// Own rows that could not be imported because the topo they hang off is no
  /// longer available to this account — deleted by its owner, un-shared, or
  /// taken down by a moderator.
  ///
  /// **Reported, but deliberately NOT an error.** These rows are untouched in
  /// the cloud and nothing is lost; the local library simply cannot render a
  /// climb logged on a topo that no longer exists. Counting them as a sync
  /// failure produced a red "Couldn't sync — Retry" banner that could never
  /// clear, because retrying re-fetches the same orphan every time — see the
  /// deferral block in [pullOwnAndShared] for the live case this came from.
  ///
  /// A non-zero value here is a fact about the world, not a defect to chase.
  /// If you want the row back, the topo has to come back.
  final int ownRowsOrphaned;

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

  /// Number of distinct OTHER climbers' photo files this pull deliberately did
  /// NOT download, because [SyncService.sharedPhotoByteBudget] was spent or
  /// because the origin is already under storage pressure (see
  /// [sharedPhotoBudgetReason]).
  ///
  /// DELIBERATELY NOT AN ERROR, and deliberately not in [errors]. This is the
  /// pull-side twin of [PushSyncResult.photosMissingLocalBytes] /
  /// `SyncOrchestratorState.lastPushWarning`: a settled, intended fact about a
  /// successful sync, not a retryable failure. `SyncOrchestrator._runPull`
  /// derives `lastPullError` exclusively from [errors], so keeping this out of
  /// that list is what stops the bound from flipping [SyncStatus.error],
  /// withholding a fresh `lastSyncedAt`, arming the backoff loop, or lighting
  /// up the Feed/Library "Couldn't sync — retry" empty states. The pull DID
  /// succeed; there is simply less of other people's cache on this device than
  /// the cloud could have supplied.
  ///
  /// Nothing is lost by it either: every withheld photo's metadata row imported
  /// normally, so the topo, its routes, grades and comments all read offline —
  /// only the picture is absent, and `MissingPhotoByteResolver` fetches that one
  /// photo's bytes on demand the moment it is actually looked at.
  final int sharedPhotoBytesSkipped;

  /// Why [sharedPhotoBytesSkipped] is what it is — enough to tell "the pull hit
  /// its normal budget" apart from "this device is nearly out of storage", which
  /// are very different things to see in a bug report.
  ///
  /// [SharedPhotoBudgetReason.withinBudget] whenever
  /// [sharedPhotoBytesSkipped] is 0.
  final SharedPhotoBudgetReason sharedPhotoBudgetReason;

  bool get didPull => outcome == SyncPullOutcome.pulled;

  @override
  String toString() =>
      'PullResult(outcome: $outcome, ownRowsPulled: $ownRowsPulled, '
      'sharedRowsPulled: $sharedRowsPulled, '
      'photosDownloaded: $photosDownloaded, ownImported: $ownImported, '
      'sharedImported: $sharedImported, errors: $errors, '
      'sharedPhotoBytesSkipped: $sharedPhotoBytesSkipped, '
      'sharedPhotoBudgetReason: ${sharedPhotoBudgetReason.name})';
}

/// Outcome of one [SyncService._uploadOwnPhotos] pass.
///
/// [failedCanonicalIds] is what makes bytes-before-metadata enforceable (S5):
/// a photo row whose canonical file id is in this set MUST be held back from
/// [SyncRemote.upsertOwnRows], so the cloud can never hold a `Photos` row
/// pointing at a Storage object that does not exist. It contains ONLY the
/// retryable failures — a photo with no local bytes at all is counted in
/// [PushSyncResult.photosMissingLocalBytes] and its row still pushes (see that
/// field's doc).
typedef PhotoUploadOutcome = ({
  int uploaded,
  int failed,
  int missingLocalBytes,
  Set<String> failedCanonicalIds,
  List<String> errors,
});

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
///    Profiles→Areas→Sectors→Walls→Photos(originals-before-slices)→Routes→
///    Ascents→Comments→Likes ordering and per-row `updatedAt` comparison
///    apply unchanged.
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
    Map<String, List<String>>? pushRequiredFields,
    StoragePersistenceService? storage,
    int? sharedPhotoByteBudget,
    bool? isWeb,
  }) : _db = db, // ignore: prefer_initializing_formals
       _backupRepository = backupRepository, // ignore: prefer_initializing_formals
       _remote = remote, // ignore: prefer_initializing_formals
       _authRepository = authRepository, // ignore: prefer_initializing_formals
       _connectivity = connectivity, // ignore: prefer_initializing_formals
       _photoFiles = photoFiles ?? PhotoFiles(),
       _wifiOnly = wifiOnly ?? (() => false),
       _pushRequiredFields = pushRequiredFields ?? syncRequiredFields,
       _storage = storage ?? const PlatformStoragePersistenceService(),
       sharedPhotoByteBudget =
           sharedPhotoByteBudget ?? kSharedPhotoByteBudgetPerPull,
       _isWeb = isWeb ?? kIsWeb;

  final db.AppDatabase _db;
  final BackupRepository _backupRepository;
  final SyncRemote _remote;
  final AuthRepository _authRepository;
  final ConnectivityService _connectivity;
  final PhotoFiles _photoFiles;
  final bool Function() _wifiOnly;

  /// The origin's usage/quota reading, used ONLY to decide whether this pull
  /// should fetch OTHER climbers' photo bytes at all (see
  /// [pullOwnAndShared]). Defaults to the real platform delegate, which on
  /// native and under `flutter test` is the inert stub whose `estimate()` is
  /// always `null` — i.e. "no pressure signal", which degrades to the plain
  /// count budget, never to zero.
  final StoragePersistenceService _storage;

  /// How many OTHER climbers' photo files one [pullOwnAndShared] may download.
  /// Defaults to [kSharedPhotoByteBudgetPerPull]; injectable so a test can
  /// assert the cap with two photos instead of twenty-one.
  ///
  /// NEVER applies to the signed-in user's OWN photos, on either side of the
  /// pull — see [pullOwnAndShared].
  final int sharedPhotoByteBudget;

  /// The per-table required-NOT-NULL-field map [pushOwn]'s push-side guard
  /// validates each local row against, defaulting to [syncRequiredFields].
  ///
  /// Injectable ONLY so a test can make an ordinary, perfectly valid local
  /// row fail that guard: every column [syncRequiredFields] names is NOT
  /// NULL in Drift, so a genuinely-missing required value is unreachable
  /// from a real local row set (it needs local data corruption) — yet the
  /// guard's reject branch is exactly what L5 is about, and it must be
  /// provable end-to-end that an excluded row reaches
  /// [PushSyncResult.rowsFailed]/[PushSyncResult.errors]. Production always
  /// uses the default.
  final Map<String, List<String>> _pushRequiredFields;

  /// Whether this pull should treat itself as running in a browser origin.
  /// Defaults to the real compile-time [kIsWeb] and only exists so a unit
  /// test can exercise BOTH branches without a real browser test runner,
  /// where the compile-time [kIsWeb] can't otherwise be flipped — mirrors
  /// `photo_source_sheet.dart`'s `showCameraOption`/`AuthRepository`'s
  /// `resolveMagicLinkRedirect` seam.
  ///
  /// Gates ONLY whether [pullOwnAndShared] applies [sharedPhotoByteBudget] to
  /// OTHER climbers' photo downloads — see that method's "NATIVE HAS NO
  /// ORIGIN QUOTA TO PROTECT" comment for why. Nothing else in this class
  /// reads it.
  final bool _isWeb;

  /// Pushes every LOCAL row owned by the signed-in user (all nine tables,
  /// INCLUDING soft-deleted tombstones) up to [SyncRemote.upsertOwnRows],
  /// then uploads each distinct not-yet-uploaded photo file those rows
  /// reference — a private copy always, plus a SECOND shared copy for any
  /// photo whose wall has `visibility == 'shared'` (see
  /// [SyncRemote.uploadSharedPhoto]).
  ///
  /// [scope] selects how much is sent: [PushScope.full] (the default, and
  /// what every pre-existing caller gets) re-sends everything;
  /// [PushScope.dirtyOnly] sends only rows still flagged `dirty`. See
  /// [PushScope] for why BOTH exist.
  ///
  /// Every row in a table the remote CONFIRMED ([TablePushOutcome.ok]) has
  /// its `dirty` flag cleared — by an (`id`, `updatedAt`) compare-and-swap
  /// that cannot clobber a local write made mid-push. Rows in a table that
  /// came back `failed` keep their flag, which is what makes the
  /// orchestrator's retry-until-clean loop both correct and terminating. See
  /// [_clearDirty].
  ///
  /// ORDER MATTERS (S5): the photo BYTES are uploaded FIRST, and only then are
  /// the metadata rows upserted — with any photo whose bytes did not land held
  /// back from that upsert. Previously the metadata went first, so a failed
  /// byte upload left every OTHER device holding a `Photos` row pointing at a
  /// Storage object that never existed, unhealable on web. See
  /// [_uploadOwnPhotos] for the three outcomes it distinguishes and
  /// [PushSyncResult.photosFailed] for which of them withholds a row.
  ///
  /// No-ops (never throws) when signed out, or when `wifiOnly` is on and the
  /// current connection isn't wifi — both report a `skipped*` outcome
  /// rather than pushing partial data. Idempotent: pushing again with
  /// nothing changed re-sends the same rows (upsert, so harmless) and
  /// re-uploads no photo files (already-present objects are skipped).
  Future<PushSyncResult> pushOwn({PushScope scope = PushScope.full}) async {
    final uid = _authRepository.currentSession.uid;
    if (uid == null) return const PushSyncResult.skippedSignedOut();

    if (_wifiOnly()) {
      final status = await _connectivity.currentStatus();
      if (status != NetworkStatus.wifi) {
        return const PushSyncResult.skippedNotWifi();
      }
    }

    final dirtyOnly = scope == PushScope.dirtyOnly;

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
    // wallId -> visibility for EVERY own wall, dirty or not. Read separately
    // (and as a projection, not whole rows) because [_uploadOwnPhotos] needs a
    // photo's wall visibility to decide whether a SHARED copy is owed — and
    // under [PushScope.dirtyOnly] `walls` above may not contain that wall at
    // all. Deriving the map from `walls` (as this used to) would silently stop
    // uploading the shared copy of a newly-added photo on an already-pushed,
    // therefore clean, shared wall.
    late Map<String, String> wallVisibility;
    await _db.transaction(() async {
      profiles = await (_db.select(_db.profiles)..where((t) => dirtyOnly ? t.ownerId.equals(uid) & t.dirty.equals(true) : t.ownerId.equals(uid))).get();
      areas = await (_db.select(_db.areas)..where((t) => dirtyOnly ? t.ownerId.equals(uid) & t.dirty.equals(true) : t.ownerId.equals(uid))).get();
      sectors = await (_db.select(_db.sectors)..where((t) => dirtyOnly ? t.ownerId.equals(uid) & t.dirty.equals(true) : t.ownerId.equals(uid))).get();
      walls = await (_db.select(_db.walls)..where((t) => dirtyOnly ? t.ownerId.equals(uid) & t.dirty.equals(true) : t.ownerId.equals(uid))).get();
      photos = await (_db.select(_db.photos)..where((t) => dirtyOnly ? t.ownerId.equals(uid) & t.dirty.equals(true) : t.ownerId.equals(uid))).get();
      routes = await (_db.select(_db.routes)..where((t) => dirtyOnly ? t.ownerId.equals(uid) & t.dirty.equals(true) : t.ownerId.equals(uid))).get();
      comments = await (_db.select(_db.comments)..where((t) => dirtyOnly ? t.ownerId.equals(uid) & t.dirty.equals(true) : t.ownerId.equals(uid))).get();
      likes = await (_db.select(_db.likes)..where((t) => dirtyOnly ? t.ownerId.equals(uid) & t.dirty.equals(true) : t.ownerId.equals(uid))).get();
      ascents = await (_db.select(_db.ascents)..where((t) => dirtyOnly ? t.ownerId.equals(uid) & t.dirty.equals(true) : t.ownerId.equals(uid))).get();

      final visibilityQuery = _db.selectOnly(_db.walls)
        ..addColumns([_db.walls.id, _db.walls.visibility])
        ..where(_db.walls.ownerId.equals(uid));
      wallVisibility = {
        for (final row in await visibilityQuery.get())
          row.read(_db.walls.id)!: row.read(_db.walls.visibility)!,
      };
    });

    // Bytes BEFORE metadata (S5). A `Photos` row must never reach the cloud
    // ahead of the Storage object it points at: on the receiving device
    // `_downloadAndRewritePhotos` only rewrites `localPath` when bytes
    // actually arrived, so a row whose object is missing keeps the
    // ORIGINATING device's path — and on web `resolvePhotoPath`/
    // `resolvePhotoPathSync` are identity passthroughs with no existence
    // check, making that path permanently dead there. Uploading first and
    // then filtering the photos table down to the rows whose bytes DID land
    // means the cloud can briefly hold an orphan OBJECT (harmless —
    // idempotently overwritten by the next push, and removed outright once
    // the photo is tombstoned) but never an orphan ROW.
    //
    // `wallVisibility` is NOT built here. §1e already reads it inside the
    // snapshot transaction as a `selectOnly` projection over EVERY own wall,
    // dirty or not — consume that (reconciliation D-4). Deriving it from the
    // `walls` list is silently wrong under [PushScope.dirtyOnly]: it stops
    // uploading the SHARED copy of a newly-added photo whose wall is already
    // pushed and therefore clean, so that wall's viewers never see the new
    // photo.
    final photoUpload = await _uploadOwnPhotos(uid, photos, wallVisibility);

    // Hold back exactly the photo rows whose bytes did NOT land this push.
    // Keyed by CANONICAL id (see [_canonicalPhotoId]) so a slice — which
    // shares its original's single on-disk file, and therefore its single
    // Storage object — is withheld alongside that original rather than
    // becoming an orphan row of its own. Every OTHER photo row (already
    // uploaded, just uploaded, tombstoned, or lacking local bytes entirely —
    // see [PushSyncResult.photosMissingLocalBytes]) still pushes, and every
    // other TABLE is untouched. The withheld rows are not lost: `pushOwn`
    // re-reads a full own-row snapshot every call (decision D-4), so the next
    // successful push carries them.
    final pushablePhotos = photoUpload.failedCanonicalIds.isEmpty
        ? photos
        : [
            for (final photo in photos)
              if (!photoUpload.failedCanonicalIds.contains(
                _canonicalPhotoId(photo),
              ))
                photo,
          ];

    // S1/L5 fix (§1d): the two accumulators EVERY push-failure channel
    // writes into — the required-field guard (immediately below) and the
    // per-table upsert outcomes further down. Declared HERE, above both, so
    // they exist exactly once in `pushOwn`.
    final errors = <String>[];
    var rowsFailed = 0;

    // Push-side NOT-NULL guard (sync-resilience hardening): drops any local
    // row missing a required NOT-NULL field before it's ever sent to
    // Supabase, reusing the exact same [syncRequiredFields] map +
    // [hasRequiredSyncFields]/[partitionSyncRows] helpers the fetch side
    // validates with (imported from `sync_remote.dart`) — the symmetric
    // guard to `fetchOwnRows`'s. A normal local row set is unaffected: local
    // Drift NOT-NULL column constraints mean a genuinely null required field
    // can only happen here via local data corruption, not everyday use. The
    // `?? const ['id']` fallback is defensive only — every table name below
    // has a matching entry in [syncRequiredFields].
    //
    // L5 fix (§1d): an excluded row is now REPORTED in [rowsFailed]/
    // [errors] rather than dropped with nothing but a debugPrint. With no
    // outbox, "excluded once" meant "excluded forever" — and invisibly.
    //
    // `errors`/`rowsFailed` were ALREADY declared immediately above this
    // comment. Do NOT re-declare them here.
    List<Map<String, dynamic>> guard(
      String table,
      List<Map<String, dynamic>> jsonRows,
    ) {
      final required = _pushRequiredFields[table] ?? const ['id'];
      final split = partitionSyncRows(
        jsonRows,
        required,
        debugLabel: 'local $table (push)',
      );
      if (split.invalid.isNotEmpty) {
        rowsFailed += split.invalid.length;
        errors.add(
          '$table: ${split.invalid.length} local row(s) excluded by the '
          'required-field guard ($required) and NOT pushed: '
          '${[for (final row in split.invalid) row['id']]}',
        );
      }
      return split.valid;
    }

    final tablesToRows = <String, List<Map<String, dynamic>>>{
      'profiles': guard('profiles', [
        for (final row in profiles) stripLocalOnlySyncColumns(row.toJson()),
      ]),
      'areas': guard('areas', [
        for (final row in areas) stripLocalOnlySyncColumns(row.toJson()),
      ]),
      'sectors': guard('sectors', [
        for (final row in sectors) stripLocalOnlySyncColumns(row.toJson()),
      ]),
      'walls': guard('walls', [
        for (final row in walls) stripLocalOnlySyncColumns(row.toJson()),
      ]),
      // `pushablePhotos`, NOT `photos`: a photo whose bytes did not land this
      // push is withheld from the metadata upsert (S5 — see the
      // bytes-before-metadata block above).
      'photos': guard('photos', [
        for (final row in pushablePhotos)
          stripLocalOnlySyncColumns(row.toJson()),
      ]),
      'routes': guard('routes', [
        for (final row in routes) stripLocalOnlySyncColumns(row.toJson()),
      ]),
      'comments': guard('comments', [
        for (final row in comments) stripLocalOnlySyncColumns(row.toJson()),
      ]),
      'likes': guard('likes', [
        for (final row in likes) stripLocalOnlySyncColumns(row.toJson()),
      ]),
      // Ascents ARE pushed here (own-row push, no visibility distinction) —
      // it's fetchSharedTopos (pull side) that keeps them private, not push.
      'ascents': guard('ascents', [
        for (final row in ascents) stripLocalOnlySyncColumns(row.toJson()),
      ]),
    };

    // S1 fix (§1d): upsertOwnRows now reports per-table outcomes instead of
    // swallowing each table's error behind a debugPrint and returning void.
    // A WHOLE-CALL throw (the remote itself unreachable) is converted into
    // an all-tables-failed result here, so the row phase never propagates
    // and never lies about what landed.
    //
    // `errors`/`rowsFailed` are the accumulators declared ABOVE the
    // `tablesToRows` construction — do NOT declare them again here.
    List<TablePushOutcome> outcomes;
    try {
      outcomes = await _remote.upsertOwnRows(uid, tablesToRows);
    } catch (e) {
      outcomes = [
        for (final entry in tablesToRows.entries)
          if (entry.value.isNotEmpty)
            TablePushOutcome.failed(
              table: entry.key,
              rowsFailed: entry.value.length,
              error: e,
            ),
      ];
    }

    // FAIL CLOSED. A table that was sent but came back with NO outcome at
    // all — neither ok nor failed — is treated exactly like a failure: not
    // confirmed, not cleared, reported, and retried.
    //
    // Not reachable through today's single `SupabaseSyncRemote`, which emits
    // one outcome per non-empty table, so this is latent. It is fixed anyway
    // because the DEFAULT was backwards: the clear below used to work by
    // subtracting the FAILED tables, so anything unreported fell through into
    // "confirmed" and had its `dirty` flag cleared. The cost of that default
    // being wrong once is a climber's edit marked clean while it is not in
    // the cloud — and since the retry loop is gated on `dirty`, never sent
    // again. Silent, permanent loss. "Not reported" must mean "not
    // confirmed".
    final reportedTables = <String>{for (final outcome in outcomes) outcome.table};
    for (final entry in tablesToRows.entries) {
      if (entry.value.isEmpty) continue;
      if (reportedTables.contains(entry.key)) continue;
      rowsFailed += entry.value.length;
      errors.add(
        '${entry.key}: ${entry.value.length} row(s) went unreported by the '
        'remote — neither confirmed nor rejected, so they are treated as NOT '
        'in the cloud',
      );
    }

    var rowsPushed = 0;
    for (final outcome in outcomes) {
      if (outcome.ok) {
        // A row the LWW pre-check skipped counts as pushed: the cloud holds
        // a strictly NEWER copy of it, so there is nothing left to send.
        rowsPushed += outcome.rowsUpserted + outcome.rowsSkippedNewerRemote;
      } else {
        rowsFailed += outcome.rowsFailed;
        errors.add(
          '${outcome.table}: ${outcome.rowsFailed} row(s) failed to push: '
          '${outcome.error}',
        );
      }
    }

    // Dirty flags are cleared HERE, LAST, and ONLY for the tables this push
    // CONFIRMED.
    //
    // WHY ONLY THE CONFIRMED TABLES (§1d interaction, load-bearing):
    // `upsertOwnRows` reports per-table outcomes and `pushOwn` converts even
    // a whole-call throw into an all-tables-`failed` result rather than
    // propagating it — so "pushOwn returned" is NOT "everything landed".
    // Clearing `dirty` for a table that came back `TablePushOutcome.failed`
    // would mark rows clean that are not in the cloud, and since the retry
    // loop is gated on `dirty` those rows would never be sent again. That is
    // strictly worse than the pre-fix behaviour, which at least never
    // claimed they were clean.
    //
    // WHY LAST: it needs `outcomes`, which only exist after the row push.
    // Note this is NOT the original §1e reasoning ("a row must not go clean
    // while its pixels are missing") — §1f flipped the order to
    // bytes-then-metadata, so a failed byte upload keeps that photo's row out
    // of `tablesToRows` altogether and it stays dirty by construction.
    // `_uploadOwnPhotos` now runs ABOVE `upsertOwnRows`; this clear stays at
    // the bottom. Do not "restore" the old ordering, and do not un-narrow
    // this clear.
    // Built from the CONFIRMED tables, not by subtracting the failed ones —
    // see the fail-closed block above the row accounting. Subtracting made
    // "unreported" indistinguishable from "confirmed".
    final confirmedTables = <String>{
      for (final outcome in outcomes)
        if (outcome.ok) outcome.table,
    };
    await _clearDirty({
      for (final entry in tablesToRows.entries)
        if (confirmedTables.contains(entry.key)) entry.key: entry.value,
    });

    return PushSyncResult.pushed(
      rowsPushed: rowsPushed,
      photosUploaded: photoUpload.uploaded,
      rowsFailed: rowsFailed,
      errors: errors,
      photosFailed: photoUpload.failed,
      photosMissingLocalBytes: photoUpload.missingLocalBytes,
      photoErrors: photoUpload.errors,
    );
  }

  /// Clears `dirty` for exactly the rows this push CONFIRMED, matched by the
  /// (`id`, `updatedAt`) PAIR — never by `id` alone.
  ///
  /// THE RACE THIS PREVENTS (the single most dangerous bug in this area): a
  /// local write can land while the push above is awaiting the network. Every
  /// repository write bumps that row's `updatedAt` to a fresh `nowMs()` AND
  /// re-sets `dirty: true` in the SAME companion. [tablesToRows] was
  /// snapshotted BEFORE the push and therefore carries the OLD `updatedAt`, so
  /// requiring `updatedAt` to still equal the pushed value turns this into a
  /// compare-and-swap: a row rewritten mid-push matches 0 rows, keeps
  /// `dirty: true`, and is picked up by the next push. A clear keyed on `id`
  /// alone would mark that newer edit as pushed and silently lose it.
  ///
  /// The CALLER is responsible for passing only the tables whose
  /// [TablePushOutcome] came back ok — see [pushOwn]'s `failedTables`.
  ///
  /// Rows are grouped by `updatedAt` so ONE statement covers every row a
  /// single user operation touched (a cascade delete stamps one `now` across
  /// area+sector+wall+photos+routes) instead of one statement per row.
  ///
  /// The `& dirty.equals(true)` term is NOT redundant with "these are the rows
  /// we just pushed": under [PushScope.full] most of them are already clean.
  /// Drift only fires `tableUpdates()` when a statement actually changes rows
  /// (`update.dart`'s `if (rows > 0)`), so restricting the WHERE to rows that
  /// are genuinely dirty makes a no-op clear silent — otherwise every
  /// confirmed push would notify, `SyncOrchestrator` would debounce another
  /// push off its own bookkeeping write, and that push would clear again, ad
  /// infinitum. `_runPush`'s nothing-pending early-out also breaks that cycle,
  /// but relying on a caller to stop a self-sustaining write loop is the wrong
  /// place for the guard.
  ///
  /// KNOWN, ACCEPTED, NARROW HOLE: two writes to the SAME row inside one
  /// millisecond share an `updatedAt`, so the second would be cleared by this
  /// push. That is the same resolution [shouldPushLww] already relies on, it
  /// needs two distinct user operations on one row within 1 ms, and the
  /// retained [PushScope.full] re-push (app start + every connectivity
  /// regain) re-sends the row regardless of its flag. Closing it properly
  /// needs a monotonic local revision column, i.e. a schema migration — out
  /// of scope here.
  Future<void> _clearDirty(
    Map<String, List<Map<String, dynamic>>> tablesToRows,
  ) async {
    await _db.transaction(() async {
      await _clearDirtyRows(
        tablesToRows['profiles'],
        (ids, updatedAt) => (_db.update(_db.profiles)
              ..where(
                (t) =>
                    t.id.isIn(ids) &
                    t.updatedAt.equals(updatedAt) &
                    t.dirty.equals(true),
              ))
            .write(const db.ProfilesCompanion(dirty: Value(false))),
      );
      await _clearDirtyRows(
        tablesToRows['areas'],
        (ids, updatedAt) => (_db.update(_db.areas)
              ..where(
                (t) =>
                    t.id.isIn(ids) &
                    t.updatedAt.equals(updatedAt) &
                    t.dirty.equals(true),
              ))
            .write(const db.AreasCompanion(dirty: Value(false))),
      );
      await _clearDirtyRows(
        tablesToRows['sectors'],
        (ids, updatedAt) => (_db.update(_db.sectors)
              ..where(
                (t) =>
                    t.id.isIn(ids) &
                    t.updatedAt.equals(updatedAt) &
                    t.dirty.equals(true),
              ))
            .write(const db.SectorsCompanion(dirty: Value(false))),
      );
      await _clearDirtyRows(
        tablesToRows['walls'],
        (ids, updatedAt) => (_db.update(_db.walls)
              ..where(
                (t) =>
                    t.id.isIn(ids) &
                    t.updatedAt.equals(updatedAt) &
                    t.dirty.equals(true),
              ))
            .write(const db.WallsCompanion(dirty: Value(false))),
      );
      await _clearDirtyRows(
        tablesToRows['photos'],
        (ids, updatedAt) => (_db.update(_db.photos)
              ..where(
                (t) =>
                    t.id.isIn(ids) &
                    t.updatedAt.equals(updatedAt) &
                    t.dirty.equals(true),
              ))
            .write(const db.PhotosCompanion(dirty: Value(false))),
      );
      await _clearDirtyRows(
        tablesToRows['routes'],
        (ids, updatedAt) => (_db.update(_db.routes)
              ..where(
                (t) =>
                    t.id.isIn(ids) &
                    t.updatedAt.equals(updatedAt) &
                    t.dirty.equals(true),
              ))
            .write(const db.RoutesCompanion(dirty: Value(false))),
      );
      await _clearDirtyRows(
        tablesToRows['ascents'],
        (ids, updatedAt) => (_db.update(_db.ascents)
              ..where(
                (t) =>
                    t.id.isIn(ids) &
                    t.updatedAt.equals(updatedAt) &
                    t.dirty.equals(true),
              ))
            .write(const db.AscentsCompanion(dirty: Value(false))),
      );
      await _clearDirtyRows(
        tablesToRows['comments'],
        (ids, updatedAt) => (_db.update(_db.comments)
              ..where(
                (t) =>
                    t.id.isIn(ids) &
                    t.updatedAt.equals(updatedAt) &
                    t.dirty.equals(true),
              ))
            .write(const db.CommentsCompanion(dirty: Value(false))),
      );
      await _clearDirtyRows(
        tablesToRows['likes'],
        (ids, updatedAt) => (_db.update(_db.likes)
              ..where(
                (t) =>
                    t.id.isIn(ids) &
                    t.updatedAt.equals(updatedAt) &
                    t.dirty.equals(true),
              ))
            .write(const db.LikesCompanion(dirty: Value(false))),
      );
    });
  }

  /// Groups [rows] by `updatedAt` and hands each `(ids, updatedAt)` batch to
  /// [clearBatch] — the shared body of [_clearDirty]'s nine per-table clears
  /// (each table needs its own statically-typed companion, so only the
  /// grouping can be factored out).
  Future<void> _clearDirtyRows(
    List<Map<String, dynamic>>? rows,
    Future<void> Function(List<String> ids, int updatedAt) clearBatch,
  ) async {
    if (rows == null || rows.isEmpty) return;
    final byUpdatedAt = <int, List<String>>{};
    for (final row in rows) {
      (byUpdatedAt[row['updatedAt'] as int] ??= <String>[])
          .add(row['id'] as String);
    }
    for (final entry in byUpdatedAt.entries) {
      await clearBatch(entry.value, entry.key);
    }
  }

  /// True when at least one row owned by the signed-in user is still `dirty`
  /// — i.e. carries a local change no push has ever CONFIRMED.
  ///
  /// This is the definition of "anything pending" that makes
  /// `SyncOrchestrator`'s retry loop well-defined and terminating (S2: retry
  /// until clean, never give up), and it is what stops a pull's own writes
  /// from triggering a pointless full re-push ~2s later (S9 —
  /// [BackupRepository.importSnapshot] writes every imported row
  /// `dirty: false`).
  ///
  /// `false` when signed out: there is nothing to push, which is not an error
  /// (mirrors [pushOwn]'s `skippedSignedOut`). Deliberately a LIMIT-1
  /// existence probe per table, short-circuiting on the first hit, rather
  /// than a count — the answer is a bool.
  ///
  /// This is only ever as truthful as its writers, and they all comply now:
  /// `LibraryCrudRepository` as of §1e, `RouteRepository`'s
  /// `upsertRoute`/`softDeleteRoute` since the route-dirty fix. A route-only
  /// edit therefore reads as "pending" here and is pushed immediately,
  /// instead of reading as "nothing pending" and waiting for the next
  /// [PushScope.full] push. The retained [full] re-push is the backstop if a
  /// future writer forgets the flag. See [PushScope].
  Future<bool> hasPendingLocalChanges() async {
    final uid = _authRepository.currentSession.uid;
    if (uid == null) return false;
    final probes = <Future<Object?> Function()>[
      () => (_db.select(_db.profiles)..where((t) => t.ownerId.equals(uid) & t.dirty.equals(true))..limit(1)).getSingleOrNull(),
      () => (_db.select(_db.areas)..where((t) => t.ownerId.equals(uid) & t.dirty.equals(true))..limit(1)).getSingleOrNull(),
      () => (_db.select(_db.sectors)..where((t) => t.ownerId.equals(uid) & t.dirty.equals(true))..limit(1)).getSingleOrNull(),
      () => (_db.select(_db.walls)..where((t) => t.ownerId.equals(uid) & t.dirty.equals(true))..limit(1)).getSingleOrNull(),
      () => (_db.select(_db.photos)..where((t) => t.ownerId.equals(uid) & t.dirty.equals(true))..limit(1)).getSingleOrNull(),
      () => (_db.select(_db.routes)..where((t) => t.ownerId.equals(uid) & t.dirty.equals(true))..limit(1)).getSingleOrNull(),
      () => (_db.select(_db.ascents)..where((t) => t.ownerId.equals(uid) & t.dirty.equals(true))..limit(1)).getSingleOrNull(),
      () => (_db.select(_db.comments)..where((t) => t.ownerId.equals(uid) & t.dirty.equals(true))..limit(1)).getSingleOrNull(),
      () => (_db.select(_db.likes)..where((t) => t.ownerId.equals(uid) & t.dirty.equals(true))..limit(1)).getSingleOrNull(),
    ];
    for (final probe in probes) {
      if (await probe() != null) return true;
    }
    return false;
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
  ///
  /// §1f-3: every skip is now COUNTED and DESCRIBED rather than a silent
  /// `continue`. Three outcomes are distinguished, because they need three
  /// different responses:
  ///  - upload attempted and THREW (or the local read threw) -> retryable;
  ///    counted in `failed`, id added to `failedCanonicalIds` so [pushOwn]
  ///    withholds that row's metadata (S5), and surfaced so §1e retries;
  ///  - no local bytes AT ALL -> not retryable; counted in
  ///    `missingLocalBytes`, row still pushed (see
  ///    [PushSyncResult.photosMissingLocalBytes]);
  ///  - already present remotely, or tombstoned -> not a problem at all;
  ///    counted nowhere.
  ///
  /// The two `list*ObjectPaths` calls ARE guarded, and that guard is a
  /// consequence of the bytes-before-metadata reorder rather than a style
  /// choice. §1f's own plan says to leave them un-guarded ("their throw
  /// semantics are §1d's concern") — which was true while this method ran
  /// AFTER `upsertOwnRows`, since a throw could then only cost the photo
  /// phase. Once it runs BEFORE the upsert, the identical throw aborts the
  /// WHOLE push before a single row is sent, so a Supabase STORAGE outage
  /// would stop areas/sectors/walls/routes — which have nothing to do with
  /// Storage — from reaching the cloud at all.
  ///
  /// A listing failure is therefore treated as "every candidate photo failed,
  /// retryably": their rows are withheld (no orphan rows), every other table
  /// still pushes, `fullyLanded` is false so nothing reports "Synced", and the
  /// retry loop re-sends them. Deliberately NOT "assume nothing is uploaded
  /// yet and re-upload everything" — that would resurrect S6's mass
  /// re-upload of full-resolution bytes on a transient hiccup.
  Future<PhotoUploadOutcome> _uploadOwnPhotos(
    String uid,
    List<db.Photo> photos,
    Map<String, String> wallVisibility,
  ) async {
    if (photos.isEmpty) {
      return (
        uploaded: 0,
        failed: 0,
        missingLocalBytes: 0,
        failedCanonicalIds: <String>{},
        errors: <String>[],
      );
    }

    final seenCanonicalIds = <String>{};
    final failedCanonicalIds = <String>{};
    final errors = <String>[];
    var uploaded = 0;
    var missingLocalBytes = 0;

    final Set<String> alreadyPrivate;
    final Set<String> alreadyShared;
    try {
      alreadyPrivate = await _remote.listPhotoObjectPaths(uid);
      alreadyShared = await _remote.listSharedPhotoObjectPaths();
    } catch (e) {
      // Without the skip-set there is no safe way to decide what still needs
      // uploading, so every non-tombstoned photo is reported as a retryable
      // failure and its row withheld. See this method's doc for why this is
      // guarded at all now that it runs before the row upsert.
      for (final photo in photos) {
        if (photo.deletedAt != null) continue;
        failedCanonicalIds.add(_canonicalPhotoId(photo));
      }
      for (final canonicalId in failedCanonicalIds) {
        errors.add(
          'photo $canonicalId: could not list already-uploaded objects, so '
          'nothing was uploaded: $e',
        );
      }
      return (
        uploaded: 0,
        failed: failedCanonicalIds.length,
        missingLocalBytes: 0,
        failedCanonicalIds: failedCanonicalIds,
        errors: errors,
      );
    }

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
      // when both copies are missing. Typed `List<int>?` (not `Uint8List?`)
      // purely to avoid a `dart:typed_data` import here; `uploadPhoto` takes
      // `List<int>`.
      List<int>? bytes;
      try {
        bytes = await _photoFiles.readPhotoBytes(photo.localPath);
      } catch (e) {
        // Web only, in practice: the native backend swallows read errors into
        // `null` itself, while the browser byte store can reject the read
        // outright (blocked upgrade, closed connection). Retryable, so this
        // withholds the row.
        failedCanonicalIds.add(canonicalId);
        errors.add('photo $canonicalId: reading local bytes failed: $e');
        continue;
      }
      if (bytes == null) {
        // NOT retryable and NOT withheld — see
        // [PushSyncResult.photosMissingLocalBytes]. Pre-fix this was a bare
        // `continue` with no error and no counter (the S5/1f-3 silent skip).
        missingLocalBytes++;
        errors.add(
          'photo $canonicalId: no local bytes at "${photo.localPath}" — '
          'nothing to upload; the row is still pushed',
        );
        continue;
      }

      // The PUBLIC copy — and only it — has its identifying metadata removed
      // (W-3). The private copy above stays byte-identical on purpose: it is
      // the user's own photo coming back to their own device on a restore, and
      // decision D-5 says that one is never degraded. Computed before either
      // upload so a strip refusal cannot leave the shared object half-written.
      Uint8List? sharedBytes;
      if (needsShared) {
        final strip = strippedForPublishing(bytes);
        if (!strip.isSafeToPublish) {
          // FAIL CLOSED. `strip.bytes` here is the original, still-identifying
          // photo, and publishing it is the exact leak this exists to stop.
          // Treated as an upload failure so the row is withheld and retried,
          // which surfaces as a stuck publish — visible and recoverable, unlike
          // GPS coordinates already cached in a world-readable bucket.
          failedCanonicalIds.add(canonicalId);
          errors.add(
            'photo $canonicalId: refusing to publish — could not strip '
            'metadata (${strip.outcome.name})',
          );
          continue;
        }
        sharedBytes = strip.bytes;
      }

      try {
        if (needsPrivate) {
          await _remote.uploadPhoto(
            uid: uid,
            photoId: canonicalId,
            ext: ext,
            bytes: bytes,
          );
        }
        if (sharedBytes != null) {
          await _remote.uploadSharedPhoto(
            photoId: canonicalId,
            ext: ext,
            bytes: sharedBytes,
          );
        }
        uploaded++;
      } catch (e) {
        failedCanonicalIds.add(canonicalId);
        errors.add('photo $canonicalId: byte upload failed: $e');
      }
    }

    return (
      uploaded: uploaded,
      failed: failedCanonicalIds.length,
      missingLocalBytes: missingLocalBytes,
      failedCanonicalIds: failedCanonicalIds,
      errors: errors,
    );
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
    var ownRowsOrphaned = 0;
    var sharedImported = false;
    var sharedPhotoBytesSkipped = 0;
    final errors = <String>[];

    // ---- OWN section ----------------------------------------------------
    // Fetched, its photos downloaded, and imported FIRST and entirely
    // before any shared fetch is even attempted — the signed-in user's own
    // topos must come back on a fresh install regardless of what happens
    // below.
    var ownFetchOk = false;
    var ownHadError = false;
    var ownTables = <String, List<Map<String, dynamic>>>{};
    // What the own import could not write because a foreign key pointed at
    // another owner's row — retried after the SHARED import below, which is
    // where those parents come from. See [DeferredRow].
    var ownReport = ImportReport.clean;
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
        // NO BUDGET, on purpose and permanently. The signed-in user's own
        // photos are the one thing this device must always be able to get
        // back — a fresh install after a lost phone is exactly this call —
        // and decision D-5 keeps them at full resolution. `foreignByteBudget`
        // is left null, which is the "unbounded" contract of the pass below.
        final ownPass = await _downloadAndRewritePhotos(
          ownTables,
          (canonicalId, ext) =>
              _remote.downloadPhoto(uid: uid, objectPath: '$uid/$canonicalId$ext'),
        );
        ownPhotosDownloaded = ownPass.downloaded;
      } catch (e) {
        ownHadError = true;
        errors.add('own photo downloads failed: $e');
      }

      try {
        ownReport = await _backupRepository.importSnapshot(
          {'tables': ownTables},
          mode: ConflictMode.lww,
        );
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
    // Every currently-shared topo (any owner) — gathered from THREE
    // independent sub-fetches (shared topos, shared ascents, profiles) plus
    // a photo-download pass, each isolated so one failing sub-fetch can't
    // lose rows another sub-fetch already gathered; the final shared
    // import is isolated too, so a photo-download exception (e.g. a
    // Storage error) still lets the metadata rows import (minus their
    // photo bytes) rather than losing the whole shared batch.
    final sharedTables = <String, List<Map<String, dynamic>>>{};
    var sharedHadError = false;

    try {
      sharedTables.addAll(
        await _remote.fetchSharedTopos(scope: await _sharedTopoScope()),
      );
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

    // S7, the bytes half: a first pull used to download EVERY shared photo at
    // full resolution — ~300 MB for a 100-photo community library, into a
    // phone browser's origin quota, before the user has looked at a single
    // one of them. The METADATA stays unbounded (it is kilobytes, and dropping
    // it would make public topos vanish from the feed outright, which is
    // strictly worse); only the megabyte-scale byte fetches are capped.
    //
    // Pressure-awareness: if the origin is ALREADY past the prune high
    // watermark, this pull takes zero foreign bytes rather than its usual
    // budget — piling more of other people's cache onto a store that is about
    // to be pruned is churn, and the prune pass that runs after a successful
    // pull would only throw it away again.
    //
    // A `null` estimate means "no pressure signal", NOT "under pressure":
    // native, `flutter test`, and any browser that refuses or throws from
    // `navigator.storage.estimate()` all land there, and off-web behaviour
    // must not silently become "never pull public photos".
    var budget = sharedPhotoByteBudget;
    var pressured = false;
    try {
      final fraction = (await _storage.estimate())?.usedFraction;
      if (fraction != null && fraction > kPrunePressureHighWatermark) {
        pressured = true;
        budget = 0;
      }
    } catch (_) {
      // Unreadable estimate == no signal == plain count budget.
    }

    // NATIVE HAS NO ORIGIN QUOTA TO PROTECT. `kSharedPhotoByteBudgetPerPull`
    // exists solely to keep this pull from busting a BROWSER origin's storage
    // quota (`photo_files_web.dart`'s L3 write throws on quota) — the exact
    // same reason `PublicPhotoPruneService` is a permanent no-op on native
    // (`estimate()` is always null there, and nothing should silently evict an
    // iOS/Android app's documents directory). So on native the budget buys
    // nothing and only costs function: `photo_image_source_native.dart` has no
    // on-demand healing path (`missingPhotoByteResolverProvider` is wired only
    // from the web display path — see that provider's "WEB-ONLY IN PRACTICE"
    // doc), so a foreign photo this budget withheld sits on a placeholder until
    // a later 30s-throttled pull happens to fetch it. [_isWeb] (real value
    // [kIsWeb], the documented seam for exactly this kind of platform
    // behavioural gate — it is NOT `dart:io`, so no conditional-import split is
    // warranted) — passing `null` here reuses `_downloadAndRewritePhotos`'s
    // existing "unbounded" contract, the same one the OWN-photo pass above
    // always uses, rather than adding a second code path. Web behaviour is
    // unchanged: `budget` (and the storage-pressure early-out that computed it
    // above) still applies exactly as before.
    try {
      final sharedPass = await _downloadAndRewritePhotos(
        sharedTables,
        (canonicalId, ext) => _remote.downloadSharedPhoto(sharedPhotoPath(canonicalId, ext)),
        foreignByteBudget: _isWeb ? budget : null,
        ownUid: uid,
      );
      sharedPhotosDownloaded = sharedPass.downloaded;
      sharedPhotoBytesSkipped = sharedPass.skippedForBudget;
    } catch (e) {
      sharedHadError = true;
      errors.add('shared photo downloads failed: $e');
    }

    try {
      final sharedReport = await _backupRepository.importSnapshot(
        {'tables': sharedTables},
        mode: ConflictMode.lww,
      );
      // sharedImported reflects the WHOLE shared pipeline (shared-topos +
      // shared-ascents + profiles fetches, photo downloads, and this final
      // import), not just this write — mirrors ownImported above.
      sharedImported = !sharedHadError;
      if (sharedReport.hasDeferrals) {
        // Should not normally happen: both shared fetches assemble their rows
        // WITH the ancestor chain those rows need. If it does, the rows stayed
        // in the cloud and are re-tried on the next pull — but it is reported,
        // never swallowed (#72).
        sharedImported = false;
        errors.add('shared rows deferred (parent row missing): ${sharedReport.summary}');
      }
    } catch (e) {
      errors.add('shared rows import failed: $e');
    }

    // ---- OWN, second pass ------------------------------------------------
    // The user's own Ascents/Comments/Likes on ANOTHER owner's shared topo
    // reference a Wall/Route that `fetchOwnRows` (scoped `ownerId = uid`)
    // structurally cannot return — those parents arrive with the SHARED batch,
    // which has only now been imported. Before this pass, every such row hit
    // `FOREIGN KEY constraint failed` and took its ENTIRE table down with it
    // (the live "own rows import failed: 3 table(s) failed" — ascents,
    // comments and likes, all three), so the user also lost their ascents on
    // their OWN topos. Re-importing exactly the deferred rows here resolves
    // them inside the SAME pull rather than leaving the user to hope a later
    // one happens to find the parents already local.
    if (ownReport.hasDeferrals) {
      try {
        final retry = await _backupRepository.importSnapshot(
          {'tables': ownReport.deferredRows},
          mode: ConflictMode.lww,
        );
        if (retry.hasDeferrals) {
          // A genuine orphan: the parent is in neither batch, because the topo
          // this row hangs off was deleted, un-shared, or taken down by a
          // moderator. **This is expected, terminal, and NOT a sync failure.**
          //
          // It used to set `ownImported = false` and push onto `errors`, which
          // is the red "Couldn't sync — Retry" banner. That was wrong in the
          // one way a sync error must never be wrong: it can NEVER clear.
          // Retrying re-fetches the same orphan and re-fails, forever, and the
          // banner tells the user their sync is broken when nothing is broken
          // and nothing is lost — the row is untouched in the cloud, and if the
          // topo ever comes back the next pull imports it (no outbox, D-4).
          //
          // Observed live on 2026-08-08: the user's own shared ascent on
          // another climber's topo, which that climber later deleted. Both this
          // and the shared-side half of it produced a permanent banner.
          //
          // Deliberately NOT re-openable by making takedowns readable. A
          // takedown hides content from everyone, including people who climbed
          // there (decided 2026-08-08) — so the parent is gone by design and
          // the client's job is to stop shouting about it, not to fetch it.
          //
          // This is not the swallowing #72 forbade. That was about losing a
          // failure nobody could see; here the count is reported on
          // [PullResult.ownRowsOrphaned] and logged. What changed is only
          // whether an expected, unfixable state is dressed up as breakage.
          ownRowsOrphaned = retry.deferredRows.values.fold(
            0,
            (sum, rows) => sum + rows.length,
          );
          debugPrint(
            'masi/sync: $ownRowsOrphaned own row(s) skipped — their topo is no '
            'longer available to this account: ${retry.summary}',
          );
        }
      } catch (e) {
        ownImported = false;
        errors.add('own deferred rows import failed: $e');
      }
    }

    return PullResult.pulled(
      ownRowsPulled: ownRowsPulled,
      sharedRowsPulled: sharedRowsPulled,
      photosDownloaded: ownPhotosDownloaded + sharedPhotosDownloaded,
      ownImported: ownImported,
      sharedImported: sharedImported,
      errors: errors,
      ownRowsOrphaned: ownRowsOrphaned,
      sharedPhotoBytesSkipped: sharedPhotoBytesSkipped,
      sharedPhotoBudgetReason: sharedPhotoBytesSkipped == 0
          ? SharedPhotoBudgetReason.withinBudget
          : pressured
          ? SharedPhotoBudgetReason.storagePressure
          : SharedPhotoBudgetReason.budgetSpent,
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
  /// A file this device ALREADY holds is not downloaded again. This is the
  /// difference between a pull costing "every new photo" and a pull costing
  /// "the entire public photo library, again". `fetchSharedTopos` selects
  /// EVERY globally-shared wall with no bound (S7), originals are retained at
  /// FULL resolution (decision D-5, ~2-5 MB each), and a pull fires on
  /// sign-in, on app resume, and on EVERY connectivity regain — which at a
  /// crag with flaky signal is repeatedly. Pre-fix, `downloadedPaths` deduped
  /// only WITHIN one call, so each of those triggers re-fetched and re-wrote
  /// the whole public library: hundreds of megabytes of metered cellular
  /// traffic, and on web the same number of bytes rewritten into the origin
  /// quota that the user's OWN topos live in — directly against "do not lose
  /// topos recorded offline".
  ///
  /// The skip is a real PRESENCE check ([PhotoFiles.readPhotoBytes] on the
  /// LOCAL row's path), never a "the row exists locally" shortcut: the L6
  /// split between metadata (drift) and pixels (a separate byte store) means
  /// pixels can vanish under a surviving row, and re-healing exactly that is
  /// what this pass is FOR. A local read is orders of magnitude cheaper than
  /// a metered network round trip, and — the part that matters most on web —
  /// it avoids the redundant WRITE entirely.
  ///
  /// S7's remaining half is now fixed too, but only for BYTES: pass
  /// [foreignByteBudget] and this pass will download at most that many
  /// DEFINITELY-FOREIGN photo files, newest-wall-first. `null` (the default,
  /// and what the own-photo pass always passes) means unbounded — the
  /// signed-in user's own photos are never rationed. See
  /// [kSharedPhotoByteBudgetPerPull] for why the number is what it is, and
  /// [pullOwnAndShared] for why the row/metadata fetch stays unbounded.
  ///
  /// TWO ORDERING/OWNERSHIP RULES, both of which mirror
  /// `PublicPhotoPruneService` and must keep mirroring it:
  ///
  ///  1. ORDER IS THE EXACT DUAL OF EVICTION ORDER. Eviction deletes
  ///     oldest-`wallUpdatedAt` first; this downloads newest-`wallUpdatedAt`
  ///     first. That pairing is the whole reason a bounded pull converges
  ///     instead of thrashing: the N photos this pass chooses to fetch are
  ///     precisely the N photos eviction's `kPruneKeepNewestForeign` floor
  ///     refuses to delete. Reverse either one and the two policies start
  ///     fighting — a pull downloads exactly what the next prune throws away,
  ///     forever, over cell data. If you change the sort here, change
  ///     `PublicPhotoPruner`'s with it.
  ///  2. AMBIGUOUS OWNERSHIP LEANS THE OPPOSITE WAY FROM EVICTION, for the
  ///     same underlying reason. Eviction's ambiguous case is KEEP (never
  ///     delete what might be the user's own); a bound's ambiguous case must
  ///     therefore be PULL (never starve what might be the user's own). So a
  ///     photo only counts against the budget when its wall is DEFINITELY
  ///     foreign — `ownerId != null && ownerId != ownUid`, the pruner's exact
  ///     predicate, read off the WALL row exactly as the pruner reads it. A
  ///     null `ownerId` ("created while signed out", or predating the column),
  ///     an absent wall row, an unparseable timestamp, or a missing [ownUid]
  ///     all mean "could be the user's own", and all of them fetch.
  ///     `fetchSharedTopos` really does return the signed-in user's OWN shared
  ///     walls alongside everyone else's, so this is not a theoretical case:
  ///     it is how a second device gets its owner's own published topos back.
  ///
  /// A photo whose bytes this device ALREADY holds costs no budget — it never
  /// reaches the download at all (see the [_localPhotoPathWithBytes] branch),
  /// so a warm cache does not spend the allowance on no-ops.
  ///
  /// A photo skipped for budget keeps whatever `localPath` its cloud row
  /// carried — exactly as a photo whose remote object is missing does — so its
  /// row still imports and still names the key its bytes WILL live under. That
  /// makes the skip self-healing: `MissingPhotoByteResolver` fetches that one
  /// photo on demand when it is actually looked at, and a later pull picks it
  /// up in the ordinary way.
  Future<PhotoDownloadPassOutcome> _downloadAndRewritePhotos(
    Map<String, List<Map<String, dynamic>>> tables,
    Future<List<int>?> Function(String canonicalId, String ext) download, {
    int? foreignByteBudget,
    String? ownUid,
  }) async {
    final photos = tables['photos'];
    if (photos == null || photos.isEmpty) {
      return (downloaded: 0, skippedForBudget: 0);
    }

    final bounded = foreignByteBudget != null && ownUid != null;

    // wallId -> (ownerId, updatedAt) for every wall in THIS batch, read from
    // the same fetched rows the photos came from. The wall is the ownership
    // source of truth here because it is the one `PublicPhotoPruneService`
    // uses (`_candidateSql`), and the two must agree or the download/eviction
    // pairing above is not actually a pairing.
    final wallOwner = <String, String?>{};
    final wallStamp = <String, int?>{};
    if (bounded) {
      for (final wall in tables['walls'] ?? const <Map<String, dynamic>>[]) {
        final id = wall['id'] as String?;
        if (id == null) continue;
        wallOwner[id] = wall['ownerId'] as String?;
        final updatedAt = wall['updatedAt'];
        wallStamp[id] = updatedAt is int ? updatedAt : null;
      }
    }

    /// Whether [photo]'s bytes count against (and can be withheld by) the
    /// budget. Only a provably foreign wall does; see rule 2 above.
    bool countsAgainstBudget(Map<String, dynamic> photo) {
      if (!bounded) return false;
      final wallId = photo['wallId'] as String?;
      if (wallId == null || !wallOwner.containsKey(wallId)) return false;
      final owner = wallOwner[wallId];
      return owner != null && owner != ownUid;
    }

    /// [photo]'s wall's `updatedAt`, or `null` when unknowable — which sorts
    /// FIRST (treated as the newest possible), matching rule 2's lean.
    int? stampOf(Map<String, dynamic> photo) {
      final wallId = photo['wallId'] as String?;
      return wallId == null ? null : wallStamp[wallId];
    }

    // Unbounded passes keep the original row order byte-for-byte: nothing
    // about the own pull changes.
    final Iterable<Map<String, dynamic>> ordered;
    if (!bounded) {
      ordered = photos;
    } else {
      final indexed = [
        for (var i = 0; i < photos.length; i++) (index: i, row: photos[i]),
      ];
      indexed.sort((a, b) {
        final sa = stampOf(a.row);
        final sb = stampOf(b.row);
        if (sa != sb) {
          if (sa == null) return -1;
          if (sb == null) return 1;
          return sb.compareTo(sa); // newest wall first
        }
        return a.index.compareTo(b.index); // stable within one timestamp
      });
      ordered = [for (final entry in indexed) entry.row];
    }

    // canonicalId -> the local path to use, so a shared file (original + its
    // slices) is only considered once regardless of row order. Seeded by
    // [_localPhotoPathWithBytes] hits as well as by fresh downloads, so a
    // slice never re-probes its original.
    final downloadedPaths = <String, String>{};
    var restoredCount = 0;
    var budgetedDownloads = 0;
    final skippedCanonicalIds = <String>{};

    // ONE batched read of every canonical id's stored path, up front, instead
    // of a `SELECT ... WHERE id = ?` per photo inside the loop below.
    //
    // The per-photo form was an N+1 whose every round trip is individually
    // bounded by `kDatabaseQueryTimeout` (30s), and a pull is precisely when
    // the executor is busiest — it is importing rows, and every `watch()`-backed
    // provider in the app re-runs behind each table update. One read losing that
    // race aborts the WHOLE photo pass with "the local database did not answer a
    // read within 30s", which is the failure this replaces.
    final storedPaths = await _storedPhotoPaths({
      for (final photo in ordered)
        (photo['parentPhotoId'] as String?) ?? photo['id'] as String,
    });

    for (final photo in ordered) {
      final canonicalId = (photo['parentPhotoId'] as String?) ?? photo['id'] as String;
      final localPath = photo['localPath'] as String? ?? '';
      final ext = p.extension(localPath);

      var newLocalPath = downloadedPaths[canonicalId];
      if (newLocalPath == null) {
        final alreadyHere = await _localPathIfBytesPresent(
          storedPaths[canonicalId],
        );
        if (alreadyHere != null) {
          // Already on this device — no download, no write, no budget spent,
          // and NOT counted as "restored": nothing was restored.
          newLocalPath = alreadyHere;
          downloadedPaths[canonicalId] = alreadyHere;
        } else {
          final budgeted = countsAgainstBudget(photo);
          if (budgeted && budgetedDownloads >= foreignByteBudget!) {
            skippedCanonicalIds.add(canonicalId);
          } else {
            final bytes = await download(canonicalId, ext);
            if (bytes != null) {
              newLocalPath = await _photoFiles.writePhotoBytes(canonicalId, ext, bytes);
              downloadedPaths[canonicalId] = newLocalPath;
              restoredCount++;
              if (budgeted) budgetedDownloads++;
            }
          }
        }
      }

      if (newLocalPath != null) {
        photo['localPath'] = newLocalPath;
      }
    }

    return (
      downloaded: restoredCount,
      skippedForBudget: skippedCanonicalIds.length,
    );
  }

  /// How many ids one batched `id IN (...)` lookup carries.
  ///
  /// Well under sqlite3's variable ceiling (999 on the conservative build
  /// setting, 32766 on modern ones), so the chunking can never be the thing
  /// that breaks: the point is to collapse hundreds of round trips into a
  /// handful, and 250 already achieves that with room to spare.
  static const int _photoPathLookupChunk = 250;

  /// `canonicalId -> localPath` for every id in [canonicalIds] that has a
  /// non-empty stored path, read in [_photoPathLookupChunk]-sized batches.
  ///
  /// Ids with no row, or a row whose `localPath` is empty, are simply absent
  /// from the result — the same "nothing stored here" answer the per-id lookup
  /// used to return as `null`.
  Future<Map<String, String>> _storedPhotoPaths(
    Set<String> canonicalIds,
  ) async {
    if (canonicalIds.isEmpty) return const <String, String>{};
    final ids = canonicalIds.toList();
    final paths = <String, String>{};
    for (var start = 0; start < ids.length; start += _photoPathLookupChunk) {
      final end = (start + _photoPathLookupChunk).clamp(0, ids.length);
      final chunk = ids.sublist(start, end);
      final rows = await (_db.select(
        _db.photos,
      )..where((t) => t.id.isIn(chunk))).get();
      for (final row in rows) {
        final storedPath = row.localPath;
        if (storedPath.isEmpty) continue;
        paths[row.id] = storedPath;
      }
    }
    return paths;
  }

  /// [storedPath] when this device genuinely holds that photo's bytes right
  /// now, else `null`.
  ///
  /// Both halves are load-bearing. The row lookup alone (which
  /// [_storedPhotoPaths] does, and which supplies [storedPath]) would be a lie
  /// — L6: metadata (drift) and pixels (a separate, non-transactional byte
  /// store) can diverge, so a row can outlive its pixels. A presence probe
  /// alone has no path to probe. Together they answer the only question the
  /// caller has: "would downloading this actually give me anything I do not
  /// already have?"
  ///
  /// `hasPhotoBytes`, NOT `readPhotoBytes`. This is a presence question, and
  /// the previous code answered it by loading the entire — potentially
  /// multi-megabyte — blob out of IndexedDB and then throwing it away, once per
  /// photo in the batch. Tens of megabytes of pointless reads per pull, on the
  /// main thread, competing with the very database reads the pull is bounded
  /// on. `PhotoFiles.hasPhotoBytes`' own doc names this exact use ("looks the
  /// key up without loading the blob, which is what makes it affordable to ask
  /// about many keys in a row"); `PublicPhotoPruneService` already used it that
  /// way and this path simply never did.
  ///
  /// Behaviour is unchanged on both backends: on web `exists` and
  /// `readBytes != null` answer the same question, and on native
  /// `resolvePhotoPathSync` runs the same resolution — legacy-absolute healing
  /// branch included — as its async counterpart, given the docs path that
  /// `bootApp` warms before the first frame. A cold cache there answers
  /// "absent", which re-downloads: the safe direction, and exactly what an
  /// unreadable store already did.
  Future<String?> _localPathIfBytesPresent(String? storedPath) async {
    if (storedPath == null || storedPath.isEmpty) return null;
    try {
      return await _photoFiles.hasPhotoBytes(storedPath) ? storedPath : null;
    } catch (_) {
      // An unreadable local store is indistinguishable from absent bytes for
      // this decision, and must never abort the pull — fall through to the
      // download, which is the safe direction. (`hasPhotoBytes` is documented
      // never to throw; the guard stays because this must hold regardless.)
      return null;
    }
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

  /// How much of the shared world the next pull should carry (W-1).
  ///
  /// Anchored on the user's own most-recently-updated wall that has
  /// coordinates — see [anchorFromOwnWalls] for why that beats a centroid. A
  /// user with no placed topos yet gets no anchor, which
  /// [SharedTopoScope.boundingBox] treats as "no geographic preference": still
  /// capped, just not narrowed.
  ///
  /// Reads LOCAL rows, not the cloud, so it costs no round trip and works
  /// offline. It is also self-correcting: the anchor follows the user as they
  /// place topos in a new region, and because the pull is an idempotent
  /// per-id upsert that never deletes (decision D-4), a topo fetched under an
  /// older, wider scope simply stays on the device.
  Future<SharedTopoScope> _sharedTopoScope() async {
    final uid = _authRepository.currentSession.uid;
    if (uid == null) return const SharedTopoScope.unbounded();
    try {
      final own =
          await (_db.select(_db.walls)..where(
                (w) =>
                    w.ownerId.equals(uid) &
                    w.deletedAt.isNull() &
                    w.latitude.isNotNull() &
                    w.longitude.isNotNull(),
              ))
              .get();
      return SharedTopoScope(
        anchor: anchorFromOwnWalls([
          for (final wall in own)
            (
              updatedAt: wall.updatedAt,
              latitude: wall.latitude,
              longitude: wall.longitude,
            ),
        ]),
      );
    } catch (_) {
      // A scope we could not compute must not lose the pull. Falling back to
      // the capped-but-unanchored scope keeps W-1's ceiling in force, which is
      // the part that actually protects the device.
      return const SharedTopoScope();
    }
  }
}
