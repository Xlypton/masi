import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../topo/data/image_ops/image_ops.dart';
import '../domain/shared_topo_scope.dart';
import 'storage_pagination.dart';

/// The nine row-level tables this app syncs, in FK dependency order
/// (Profiles → Areas → Sectors → Walls → Photos → Routes → Ascents →
/// Comments → Likes) — the same order [BackupRepository.importSnapshot]
/// applies rows in, and the same set of keys used in
/// [BackupRepository.exportSnapshot]'s `tables` map.
///
/// Comments/Likes/Ascents were added for the community-features sync
/// extension: Comments and Likes attach to EITHER a Wall (`wallId`, shared
/// alongside their wall — see [fetchSharedTopos]) OR an Ascent (`ascentId`,
/// Feature #12); Ascents additionally references a Route (`routeId`) and is
/// pushed/pulled for its owner via [upsertOwnRows]/[fetchOwnRows] like every
/// other table (own rows push regardless of `visibility` — see
/// [fetchSharedAscents]'s doc for what actually controls OTHER users' read
/// access to a shared ascent).
///
/// **Ascents comes BEFORE Comments/Likes** — Feature #12 added
/// `Comments.ascentId`/`Likes.ascentId` FKs referencing `Ascents.id`, so a
/// comment/like attached to an ascent must never be pushed/imported before
/// the ascent it references exists remotely/locally, or the FK write fails
/// (`PRAGMA foreign_keys = ON` locally; a real FK constraint on the
/// Supabase side).
///
/// Profiles (#18, editable synced display name) is FIRST because it has no
/// FK deps, and because its `id` IS the owning uid (see `tables.dart`'s
/// `Profiles` doc) — [upsertOwnRows]/[fetchOwnRows]'s generic
/// `ownerId = uid` scoping happens to fetch exactly the caller's own profile
/// row via this same loop, with no special-casing. Resolving OTHER users'
/// profiles (e.g. a shared topo's author) is NOT part of that generic own-
/// row loop, nor of [fetchSharedTopos] (which has no FK to a profile to
/// join on) — that's what the separate [fetchProfiles] is for.
const List<String> syncTableNames = [
  'profiles',
  'areas',
  'sectors',
  'walls',
  'photos',
  'routes',
  'ascents',
  'comments',
  'likes',
];

/// Ids per by-id `inFilter` request in [SyncRemote.fetchEngagementByParentIds].
///
/// Matches `kForeignWallSweepChunkSize` (the other by-id probe in this app,
/// which chunks at the same 150) rather than inventing a second number: both
/// exist for the same reason, which is that a PostgREST `id=in.(...)` filter
/// travels in the URL, and a library with hundreds of published walls/ascents
/// would otherwise build a single request longer than an intermediary is willing
/// to forward. Deliberately NOT imported from `foreign_wall_sweep_service.dart`
/// — the dependency runs the other way (that file imports this one).
const int kInboundEngagementChunkSize = 150;

/// Outcome of pushing ONE table's rows within a single
/// [SyncRemote.upsertOwnRows] call.
///
/// S1 fix (§1d, web-offline reliability): `upsertOwnRows` used to return
/// `void` and swallow every per-table failure behind a [debugPrint], so
/// `SyncService.pushOwn` counted rows merely HANDED TO the remote as
/// "pushed" — a push where every single table's round trip failed still
/// surfaced as "Synced • just now" on the Account screen. Every attempted
/// table now reports back, success or failure, so the push result can tell
/// the truth.
@immutable
class TablePushOutcome {
  /// The table landed: [rowsUpserted] rows were written remotely and
  /// [rowsSkippedNewerRemote] were deliberately not sent because the cloud
  /// already holds a strictly newer copy (see [shouldPushLww]) — which is a
  /// SUCCESS, not a failure: there is nothing left to push for them.
  const TablePushOutcome.ok({
    required this.table,
    required this.rowsUpserted,
    this.rowsSkippedNewerRemote = 0,
  }) : rowsFailed = 0,
       error = null;

  /// The table did NOT land: [rowsFailed] rows are still only local and
  /// [error] (stringified, so this type stays free of any backend type)
  /// says why.
  ///
  /// Cannot be `const` despite the `@immutable`: the `'$error'` interpolation
  /// of an arbitrary caught [Object] is not a constant expression.
  // ignore: prefer_const_constructors_in_immutables
  TablePushOutcome.failed({
    required this.table,
    required this.rowsFailed,
    required Object error,
  }) : rowsUpserted = 0,
       rowsSkippedNewerRemote = 0,
       error = '$error';

  /// Table name, one of [syncTableNames].
  final String table;

  /// Rows this call actually upserted remotely.
  final int rowsUpserted;

  /// Rows the last-writer-wins pre-check dropped because the cloud row is
  /// strictly newer — counted separately from [rowsUpserted] so a caller can
  /// tell "nothing needed sending" apart from "nothing was sent".
  final int rowsSkippedNewerRemote;

  /// Rows handed in that did not reach the cloud. 0 on success.
  final int rowsFailed;

  /// `null` iff this table landed.
  final String? error;

  bool get ok => error == null;

  @override
  String toString() => ok
      ? 'TablePushOutcome.ok($table, rowsUpserted: $rowsUpserted, '
            'rowsSkippedNewerRemote: $rowsSkippedNewerRemote)'
      : 'TablePushOutcome.failed($table, rowsFailed: $rowsFailed, '
            'error: $error)';
}

/// Seam over the cloud backend the row-level [SyncService] talks to.
///
/// Unlike [BackupRemote] (one whole-snapshot JSON blob per user), this is
/// row-level: every table's rows travel as plain
/// `List<Map<String, dynamic>>` (each map being one row's
/// `<TableRow>.toJson()`/`<TableRow>.fromJson()` shape — camelCase keys,
/// e.g. `ownerId`, `wallId`, per drift's default serializer), keyed by the
/// table name — all nine of [syncTableNames], not just the original five.
///
/// Deliberately free of any Supabase type in its signatures (besides what
/// [SupabaseSyncRemote] itself touches internally) so tests can supply a
/// pure in-memory fake (`FakeSyncRemote` in
/// `test/features/backup/data/sync_service_test.dart`) instead of a real
/// network — mirrors [BackupRemote]'s fakeability.
///
/// SHARING MODEL: a Wall is the sync unit called a "topo" elsewhere in this
/// app. `Walls.visibility` (`'private'` default | `'shared'`) decides
/// whether OTHER users can ever see it — [fetchSharedTopos] is how a
/// signed-in user discovers every OTHER user's (and their own) shared
/// topos, alongside [fetchOwnRows] for their own full row set (shared or
/// not). The real backend enforces this split via RLS on each table
/// (`owner_id = auth.uid()` for own rows; `visibility = 'shared'` — with no
/// owner check — for the shared-topo query); the fake in tests simulates
/// the same split by filtering its in-memory rows the same way.
///
/// Feature #12 (public opt-in ascent logs) layers a SECOND, independent
/// visibility axis on top of this: `Ascents.visibility` (`'private'` default
/// | `'shared'`) decides whether OTHER users can see a given ascent log,
/// completely unrelated to whether the ascent's wall is itself shared — an
/// ascent on a private topo can be shared, and vice versa. [fetchSharedTopos]
/// still never returns ascent rows at all (see its doc); the cross-owner
/// ascent feed is [fetchSharedAscents] instead, again RLS-enforced on the
/// real backend the same `visibility = 'shared'`, no-owner-check way.
abstract class SyncRemote {
  /// Upserts every row in [tablesToRows] (keyed by table name, see
  /// [syncTableNames]) as belonging to [uid], INCLUDING soft-deleted
  /// tombstones (`deletedAt` set) — a tombstone must propagate to other
  /// devices the same as any other row change. Idempotent: re-upserting the
  /// same rows is a no-op change-wise.
  ///
  /// Returns ONE [TablePushOutcome] per table it actually ATTEMPTED — a
  /// table absent from [tablesToRows], or present but empty, is not
  /// attempted and therefore not reported. Real implementations report in
  /// [syncTableNames] (FK-dependency) order.
  ///
  /// S1 fix (§1d): implementations MUST NOT swallow a per-table failure. A
  /// table whose round trip errors comes back as [TablePushOutcome.failed]
  /// so `SyncService.pushOwn` can report `rowsFailed`/`errors` instead of
  /// pretending every handed-in row landed. Per-table isolation is
  /// unchanged and still required: one failing table must not prevent the
  /// remaining tables (nor `pushOwn`'s later photo-upload phase) from
  /// running — so implementations report a single table's failure rather
  /// than throwing. (`pushOwn` additionally defends against a whole-call
  /// throw, e.g. the remote being wholly unreachable.)
  Future<List<TablePushOutcome>> upsertOwnRows(
    String uid,
    Map<String, List<Map<String, dynamic>>> tablesToRows,
  );

  /// Every cloud row (across all [syncTableNames] tables) whose `ownerId`
  /// equals [uid] — the signed-in user's own full row set, shared or not.
  Future<Map<String, List<Map<String, dynamic>>>> fetchOwnRows(String uid);

  /// For every Wall (any owner) with `visibility == 'shared'`: that wall
  /// row, its Photos rows, its Routes rows, its Comments rows, its Likes
  /// rows, and its ancestor Sector + Area rows — so a shared topo can be
  /// rendered with its full context (which area/sector it's under) even on a
  /// device that has never seen that owner's other data. Rows keep their
  /// ORIGINAL `ownerId` (an ownership fact, not a "who's asking" scoping) —
  /// callers must not rewrite it.
  ///
  /// DELIBERATELY EXCLUDES Ascents — an ascent is never returned here even
  /// when its wall is shared; a wall's shared-ness says nothing about
  /// whether any ascent logged against it has opted in to being shared
  /// itself (see [fetchSharedAscents], the separate call for that). Callers
  /// must not add an `'ascents'` key to the returned map.
  /// [scope] bounds how much of the shared world one pull carries (W-1).
  /// Defaults to unbounded so every existing caller and fake keeps its old
  /// behaviour until it opts in — the scoping decision belongs to
  /// `SyncService`, which is the only thing that knows where the user climbs.
  Future<Map<String, List<Map<String, dynamic>>>> fetchSharedTopos({
    SharedTopoScope scope = const SharedTopoScope.unbounded(),
  });

  /// Every Ascent (any owner) with `visibility == 'shared'` (Feature #12,
  /// public opt-in ascent logs) — the source for a cross-owner public feed
  /// of shared climbs. Deliberately separate from [fetchSharedTopos] (which
  /// covers a shared Wall's own rows and still never returns an `'ascents'`
  /// key): an ascent's visibility is an independent, per-ascent opt-in,
  /// unrelated to whether its wall is itself shared — so a shared ascent's
  /// wall may well be `'private'` and absent from every other pulled table.
  ///
  /// Also returns each shared ascent's `'routes'`/`'walls'`/`'photos'`/
  /// `'sectors'`/`'areas'` ancestor chain (`Ascent.routeId`/`Ascent.wallId`
  /// → `Route.photoId` → `Wall.sectorId` → `Sector.areaId`), scoped to ONLY
  /// the specific rows those specific ascents reference (never a wall's
  /// OTHER routes/photos) — this is REQUIRED, not cosmetic: `Ascents.routeId`
  /// / `Ascents.wallId` are enforced FKs (`PRAGMA foreign_keys = ON`
  /// locally), so importing a shared ascent whose wall/route don't already
  /// exist on this device throws unless this context comes along with it.
  /// Scoping to the minimal chain (rather than the wall's full context, the
  /// way [fetchSharedTopos] does) avoids leaking a private topo's OTHER
  /// routes/photos just because one ascent on it opted in.
  ///
  /// Returns a map keyed like every other shared-fetch's table-name-keyed
  /// shape (`'areas'`/`'sectors'`/`'walls'`/`'photos'`/`'routes'`/
  /// `'ascents'`), so callers can hand it straight to
  /// `BackupRepository.importSnapshot` (merged with [fetchSharedTopos]'s
  /// return, as `SyncService.pullOwnAndShared` does).
  Future<Map<String, List<Map<String, dynamic>>>> fetchSharedAscents();

  /// Comments and Likes — BY ANY AUTHOR, not just the caller — attached to
  /// exactly the ascents [ascentIds] and the walls [wallIds]. Returns a
  /// table-name-keyed map with exactly the keys `'comments'` and `'likes'`, the
  /// same shape every other fetch here returns, so callers can merge it straight
  /// into a shared batch.
  ///
  /// ## The gap this closes
  ///
  /// Before this existed, NO pull path could ever fetch a comment somebody else
  /// wrote on an ASCENT. There were exactly three inbound row paths and each one
  /// structurally excluded it:
  ///
  ///  1. [fetchOwnRows] is `ownerId = uid` — only comments the caller WROTE.
  ///  2. [fetchSharedTopos] fetches comments by `inFilter('wallId', wallIds)`,
  ///     and an ascent comment has `wallId IS NULL`, so it can never match. It
  ///     is also [SharedTopoScope]-capped and geo-anchored, so even a WALL
  ///     comment on the caller's own published topo is missable when that topo
  ///     falls outside the scoped window.
  ///  3. [fetchSharedAscents] never queried comments at all.
  ///
  /// So the owner of a shared ascent got the server-side notification ("someone
  /// commented on your ascent", written by a trigger into `notifications` and
  /// read through the `my_notifications` RPC — an entirely separate path) and
  /// then found nothing on the ascent, forever, however many times they pulled.
  /// Reported live 2026-08-10. The same hole hid every third party's comment on
  /// every OTHER climber's shared ascent in the feed, and both halves applied
  /// identically to Likes.
  ///
  /// ## Contract
  ///
  /// - The caller supplies ids it can prove it HOLDS (own rows read from the
  ///   local database) or is importing in the same batch (the ascents
  ///   [fetchSharedAscents] just returned). This is a by-id fetch, never a
  ///   discovery query: nothing here widens what the caller can see, it only
  ///   asks about rows already on this device.
  /// - Implementations CHUNK both id lists at [kInboundEngagementChunkSize] and
  ///   issue one request per chunk — a single unbounded `inFilter` over a large
  ///   library is a URL-length failure waiting to happen.
  /// - Rows come back with their ORIGINAL (foreign) `ownerId`, like every other
  ///   shared fetch — callers must not rewrite it, and must import them through
  ///   the shared/foreign import path so they land `dirty: false`. A foreign row
  ///   marked dirty would be re-sent by the next push, RLS would reject it, and
  ///   per #64/#65 one rejected row can abort a whole table's push.
  /// - Row-level visibility stays entirely with the server. RLS returns a
  ///   comment on an ascent only when that ascent is `visibility = 'shared'`
  ///   (`comments_ascent_shared_select`) and one on a wall only when
  ///   `is_wall_public(wallId)` (`comments_shared_select`); asking about an id
  ///   that does not qualify simply returns nothing.
  /// - Returns empty lists for two empty id lists WITHOUT a round trip.
  /// - Tombstones (`deletedAt` set) come back like any other row, exactly as
  ///   [fetchOwnRows]/[fetchSharedTopos] do — a deletion must propagate. The
  ///   read path is what hides them (`CommentsRepository` filters
  ///   `deletedAt.isNull()`).
  Future<Map<String, List<Map<String, dynamic>>>> fetchEngagementByParentIds({
    required List<String> ascentIds,
    required List<String> wallIds,
  });

  /// Uploads [bytes] to the caller's OWN private object path
  /// (`<uid>/<photoId><ext>`) — readable (per real backend RLS) only by
  /// [uid] themself. Overwrites any existing object at that path.
  Future<void> uploadPhoto({
    required String uid,
    required String photoId,
    required String ext,
    required List<int> bytes,
  });

  /// Downloads the object at [objectPath] (already uid-prefixed, e.g.
  /// `<uid>/<photoId><ext>`), or `null` if no such object exists.
  Future<List<int>?> downloadPhoto({
    required String uid,
    required String objectPath,
  });

  /// Every object path (uid-prefixed) that currently exists under [uid]'s
  /// own private folder — used to skip re-uploading a photo already there.
  Future<Set<String>> listPhotoObjectPaths(String uid);

  /// Uploads [bytes] to a SHARED object path (`shared/<photoId><ext>`,
  /// see [sharedPhotoPath]) — distinct from the owner-only `<uid>/...`
  /// convention above because a shared topo's photo must be readable by ANY
  /// signed-in user, not just its owner. Overwrites any existing object at
  /// that path.
  ///
  /// ASSUMPTION for P0 (documented here since this phase has no real
  /// backend to enforce it): the real `topo-photos` bucket needs a SECOND
  /// Storage RLS policy — "readable by any authenticated user when the
  /// object path is under `shared/`" — separate from the existing
  /// per-owner `<uid>/...` policy. This phase keeps shared photos as a
  /// second copy under a flat `shared/` prefix rather than trying to make
  /// the owner-scoped path conditionally public, so the two policies never
  /// have to interact.
  ///
  /// PUBLISHES TWO OBJECTS, not one: the full-resolution original at
  /// [sharedPhotoPath], and a derived downscaled JPEG at [sharedThumbPath].
  /// The thumbnail is why: without it the ONLY object a viewer could fetch for
  /// an absent foreign photo was the multi-megabyte original, which every
  /// 52-pixel list tile then downloaded in full. Decision D-5 is untouched —
  /// the original is still stored at full resolution and the thumbnail is
  /// strictly an ADDITIONAL derivative, never a replacement.
  ///
  /// THE TWO OBJECTS ARE NOT EQUALS, and implementations must keep them
  /// unequal. The ORIGINAL is the publication: it is written FIRST, and it is
  /// the only one of the two whose failure may propagate out of this call —
  /// because `SyncService._uploadOwnPhotos` turns a throw here into
  /// `failedCanonicalIds`, which WITHHOLDS the photo's metadata row (S5),
  /// clears `PushSyncResult.fullyLanded` and re-arms the retry loop. That is
  /// the correct response to "the bytes a viewer needs are not in the cloud".
  /// It is the WRONG response to "the small derived tile is not in the cloud",
  /// which merely costs a viewer the tile-size win: the read path already falls
  /// back to the original for an absent thumbnail (see
  /// `SharedMissingPhotoByteResolver`). So the thumbnail is written SECOND and
  /// STRICTLY BEST-EFFORT — a failed thumbnail must never be observable as a
  /// failed publish.
  ///
  /// CALLER CONTRACT: [bytes] must ALREADY be safe to publish (EXIF stripped
  /// via `strippedForPublishing` — see `SyncService._uploadOwnPhotos`, the
  /// only caller). The thumbnail is derived FROM [bytes], so it inherits that
  /// guarantee rather than re-establishing it. Deriving it from unstripped
  /// bytes would leak: a photo already small enough to skip the resize comes
  /// back from `generateThumbnail` VERBATIM, metadata and all.
  Future<void> uploadSharedPhoto({
    required String photoId,
    required String ext,
    required List<int> bytes,
  });

  /// Downloads the object at [objectPath] (already `shared/`-prefixed, see
  /// [sharedPhotoPath]), or `null` if no such object exists.
  Future<List<int>?> downloadSharedPhoto(String objectPath);

  /// The shared object paths a push may treat as ALREADY PUBLISHED — i.e.
  /// the skip-set for [uploadSharedPhoto].
  ///
  /// "Already published" means THE ORIGINAL AT [sharedPhotoPath] EXISTS, and
  /// nothing more. Specifically it does NOT mean the photo's thumbnail is
  /// there too, even though [uploadSharedPhoto] writes both.
  ///
  /// That distinction is the whole safety property of this method, so it is
  /// worth stating what the other definition cost. `SyncService.
  /// _uploadOwnPhotos` derives `needsShared` from exactly this set, and a photo
  /// with `needsShared` runs the ENTIRE publish pipeline again — including the
  /// fail-closed EXIF-strip gate. Reporting an already-published original as
  /// unpublished merely because it predates the thumbnail tier therefore pushed
  /// the whole existing published corpus back through that gate, on bytes
  /// nothing had ever validated. Every refusal there withholds the photo's row,
  /// drops `fullyLanded` and re-arms the retry loop — and because no thumbnail
  /// is ever produced for a photo that was refused, it never enters the
  /// skip-set, so the loop never terminates. A derived, disposable, optional
  /// object must never be able to gate a publication that already happened.
  ///
  /// Backfilling the thumbnails of everything published BEFORE the tier existed
  /// is therefore a SIDE CHANNEL that cannot touch publish state at all — see
  /// [sharedOriginalsNeedingThumbs] and [SharedThumbBackfill]. There is no
  /// outbox to schedule a migration through (decision D-4), and this is why one
  /// is not needed: a missing thumbnail is not a failure to heal, it is a
  /// derivative that has not been computed yet, and the read path already
  /// degrades to the original for it.
  Future<Set<String>> listSharedPhotoObjectPaths();

  /// Removes the object at the caller's OWN private object path
  /// (`<uid>/<photoId><ext>`) for a just-tombstoned photo — the cloud-side
  /// counterpart to `PhotoRepository.deleteOriginalPhoto`'s local
  /// soft-delete. Best-effort/idempotent: removing an object that was never
  /// uploaded (or was already removed by an earlier push) must NOT throw —
  /// [SyncService._uploadOwnPhotos] calls this unconditionally for every
  /// tombstoned photo, regardless of whether a copy actually exists remotely.
  Future<void> removePhoto({
    required String uid,
    required String photoId,
    required String ext,
  });

  /// Removes the SHARED copy of a just-tombstoned photo — BOTH objects
  /// [uploadSharedPhoto] wrote, the original at [sharedPhotoPath] and the
  /// derived thumbnail at [sharedThumbPath]. Removing only the original would
  /// leave the thumbnail as a world-readable orphan of a photo the owner has
  /// deleted, which is the same leak the takedown exists to close.
  ///
  /// Best-effort/idempotent, mirroring [removePhoto]: either object may never
  /// have existed. Never throws.
  ///
  /// Returns the object paths Storage reports it ACTUALLY removed, which is the
  /// ONLY way to tell a real removal from a false success. A Storage delete
  /// that RLS filtered to nothing answers HTTP 200 with an EMPTY list — byte
  /// for byte indistinguishable from a successful delete unless you look at
  /// what came back. That exact false success hid W-2 (there was no DELETE
  /// policy for `shared/` at all, so every removal since the feature shipped
  /// removed nothing), and it is why
  /// `ModerationRemote.removePublishedPhotoObjects` counts instead of
  /// swallowing. This returns paths rather than a count so a caller can ask
  /// about a SPECIFIC object: two paths are requested and a photo published
  /// before the thumbnail tier existed legitimately has only one of them, so
  /// "fewer came back than were asked for" proves nothing on its own.
  ///
  /// An empty set is also what a caught `StorageException` returns — "nothing
  /// is known to have been removed" is the honest answer, and the caller
  /// decides whether that matters for the path it cared about.
  Future<Set<String>> removeSharedPhoto({
    required String photoId,
    required String ext,
  });

  /// Every cloud `profiles` row whose `id` (== owning uid) is in [uids] —
  /// used by [SyncService.pullOwnAndShared] to resolve display names for
  /// every OTHER user referenced by a just-pulled shared row (plus the
  /// signed-in user's own uid), something [fetchOwnRows]'s `ownerId = uid`
  /// scoping and [fetchSharedTopos]'s wall-FK join can't reach on their own.
  /// Returns an empty list for an empty [uids] set without a round trip.
  Future<List<Map<String, dynamic>>> fetchProfiles(Set<String> uids);

  /// Probes the server for which of exactly [ids] are still visible to the
  /// signed-in caller RIGHT NOW — a plain by-id `SELECT` gated only by RLS
  /// (`walls_shared_select USING (is_wall_public(id))`, plus the owner
  /// policy), never a scoped/paginated/geo-limited fetch. Deliberately NOT
  /// [fetchSharedTopos]: that call is capped and geo-anchored ([SharedTopoScope],
  /// W-1) so its absence-of-a-row proves nothing about deletion — see
  /// `ForeignWallSweepService`'s library doc for why this method exists as a
  /// separate, narrower probe.
  ///
  /// Returns the SUBSET of [ids] the server actually returned a row for.
  /// An id missing from the result was asked about and not returned — by a
  /// takedown, an owner hard-delete, an un-share, or any other reason RLS no
  /// longer lets this caller see it. [ids] should already be one request-
  /// sized batch (chunking is the caller's job); this issues exactly one
  /// round trip. Returns an empty list for an empty [ids] list without one.
  Future<List<String>> fetchVisibleWallIds(List<String> ids);
}

/// The shared-bucket object path for a photo with canonical id [photoId]
/// (see `CloudBackupService._canonicalPhotoId` for what "canonical" means —
/// a slice shares its original's id/file) and extension [ext] (including
/// the leading dot, e.g. `.jpg`).
String sharedPhotoPath(String photoId, String ext) => 'shared/$photoId$ext';

/// The extension a published THUMBNAIL always carries, whatever the original's
/// is. `generateThumbnail` re-encodes to JPEG, so this is a property of the
/// derivation, not of the source — which is exactly what makes the thumbnail
/// path derivable from a `thumbs/<id>.jpg` key that no longer remembers
/// whether its original was `.jpeg`, `.png` or `.JPG`.
const String kSharedThumbExt = '.jpg';

/// The shared-bucket object path for the THUMBNAIL of the photo with canonical
/// id [photoId] — the small companion object [SyncRemote.uploadSharedPhoto]
/// writes alongside the full-resolution [sharedPhotoPath].
///
/// Mirrors `thumbKeyFor`'s local `thumbs/<id>.jpg` convention one level down
/// from `shared/`, so a local thumbnail key and its cloud object differ only by
/// the `shared/` prefix.
String sharedThumbPath(String photoId) => 'shared/thumbs/$photoId$kSharedThumbExt';

/// The shared object paths that count as PUBLISHED, given the object NAMES
/// (not paths) listed directly under `shared/`.
///
/// The pure half of [SupabaseSyncRemote.listSharedPhotoObjectPaths] — see
/// [SyncRemote.listSharedPhotoObjectPaths] for why the thumbnail listing is
/// deliberately not an input here.
///
/// Entries with NO extension are dropped, which is how the pseudo-entry
/// Supabase returns for the `thumbs` FOLDER itself is excluded without naming
/// it: every real photo object is `<canonical id><ext>` with a non-empty
/// extension (`PhotoFiles` stores `photos/<id><ext>` and the publish path takes
/// `ext` straight off it), and a folder entry has none.
Set<String> publishedSharedOriginals(Iterable<String> originalNames) => {
  for (final name in originalNames)
    if (p.extension(name).isNotEmpty) 'shared/$name',
};

/// The ORIGINAL object NAMES under `shared/` that have no `shared/thumbs/`
/// companion yet — the side-channel backfill's worklist, in listing order.
///
/// The complement of a publication check, NOT a publication check: nothing here
/// feeds [SupabaseSyncRemote.listSharedPhotoObjectPaths]'s return value, and
/// nothing derived from it may ever reach `SyncService`'s
/// `failedCanonicalIds`/`missingLocalBytes` accounting. See
/// [SyncRemote.listSharedPhotoObjectPaths] for what happened when the two were
/// the same computation.
///
/// The join is on the id, i.e. the name minus its extension, because the two
/// sides deliberately do not share one: the original keeps whatever the
/// climber's camera produced (`.jpeg`, `.png`, `.JPG`) while the thumbnail is
/// always [kSharedThumbExt]. Matching on the full name is the mistake this
/// helper exists to make impossible.
///
/// Extension-less entries are skipped for the same reason as in
/// [publishedSharedOriginals], and here it is load-bearing rather than
/// cosmetic: the `thumbs` folder pseudo-entry would otherwise be worklisted
/// forever (nothing can ever produce a `thumbs.jpg` for it), and every pass
/// would spend a download attempt trying to read a directory as a photo.
List<String> sharedOriginalsNeedingThumbs({
  required Iterable<String> originalNames,
  required Set<String> thumbNames,
}) => [
  for (final name in originalNames)
    if (p.extension(name).isNotEmpty &&
        !thumbNames.contains(
          '${p.basenameWithoutExtension(name)}$kSharedThumbExt',
        ))
      name,
];

/// Derives the missing `shared/thumbs/<id>.jpg` companions of originals that
/// were published before the thumbnail tier existed — WITHOUT re-uploading a
/// single original, and without any connection to publish state.
///
/// ## Why a side channel and not the push
///
/// The obvious mechanism is to report a thumbnail-less original as unpublished
/// and let the ordinary push re-publish it. That is what this replaces, and it
/// was a defect rather than a shortcut: see
/// [SyncRemote.listSharedPhotoObjectPaths] for the retry loop it created. The
/// property this class exists to have is that NOTHING it does — a failed
/// download, an undecodable photo, a rejected upload, being offline for a
/// month — can be observed by `SyncService` at all. It reports nothing, throws
/// nothing, and returns nothing.
///
/// ## Cost, and why it is bounded the way it is
///
/// A thumbnail can only be derived from pixels, and the only copy of a legacy
/// photo's pixels this device is guaranteed to be able to reach is the one
/// already in the bucket — the local file may have been evicted, and on a
/// second device it was never there. So a backfill costs ONE DOWNLOAD of the
/// original, once, ever, per object; it uploads only the ~30 KB derivative. That
/// is the cheap direction of the same trade the push would have made: measured
/// on the live dev bucket when this landed, 21 legacy objects totalling 94 MB,
/// which as a re-PUSH would also have been 21 chances to withhold a row that
/// was already fine.
///
/// [maxPerPass] keeps one push from spending all of it at once (a phone browser
/// at a crag), and one pass runs at a time. The work is globally finite and
/// self-extinguishing: only objects published before the tier can ever appear
/// in the worklist, every success removes one permanently, and once the bucket
/// is converged every later pass finds an empty worklist and costs nothing.
///
/// Deliberately NOT scoped to the caller's own photos, even though the pass
/// runs during the caller's push. A legacy photo whose owner never opens the
/// app again would otherwise keep every VIEWER paying the full-original
/// fallback forever, and the derivative is computed from an object that is
/// already world-readable, so no one sees anything they could not already
/// fetch.
@visibleForTesting
class SharedThumbBackfill {
  SharedThumbBackfill({
    required Future<List<int>?> Function(String objectPath) download,
    required Future<void> Function(String objectPath, Uint8List bytes) upload,
    Future<Uint8List> Function(Uint8List original)? thumbnail,
    this.maxPerPass = 3,
    this.perStepTimeout = const Duration(seconds: 45),
    // Private fields with named params, matching `SyncService`'s and
    // `SharedMissingPhotoByteResolver`'s house pattern: a named parameter
    // cannot itself be private, so the initializing formal the lint asks for is
    // not expressible here.
  }) : _download = download, // ignore: prefer_initializing_formals
       _upload = upload, // ignore: prefer_initializing_formals
       _thumbnail = thumbnail ?? _computeThumbnail;

  static Future<Uint8List> _computeThumbnail(Uint8List original) =>
      compute(generateThumbnail, original);

  final Future<List<int>?> Function(String objectPath) _download;
  final Future<void> Function(String objectPath, Uint8List bytes) _upload;
  final Future<Uint8List> Function(Uint8List original) _thumbnail;

  /// How many originals one pass may backfill. Three keeps a single push's
  /// incidental cost in the same order as the push itself.
  final int maxPerPass;

  /// Ceiling on any ONE download/derive/upload step, so a stalled request
  /// cannot hold the single-pass latch for the rest of the session.
  final Duration perStepTimeout;

  /// Object names whose pixels this session could not turn into a thumbnail
  /// (undecodable container, a backend that refuses the bitmap). Retrying those
  /// costs a full download every pass and cannot start succeeding, so they are
  /// dropped for the session — and dropping them is FREE, because a missing
  /// thumbnail is a degradation to the original, not a failure.
  final Set<String> _givenUp = <String>{};

  bool _running = false;
  Future<void> _pending = Future<void>.value();

  /// The current (or most recent) pass. Only a test ever awaits it — production
  /// deliberately fires and forgets, because a push must not wait on, or be
  /// able to fail because of, a derivative.
  @visibleForTesting
  Future<void> get pending => _pending;

  /// Object names this session gave up deriving a thumbnail for.
  @visibleForTesting
  Set<String> get givenUp => Set.unmodifiable(_givenUp);

  /// Starts at most one pass over [originalNames] (the output of
  /// [sharedOriginalsNeedingThumbs]) and RETURNS IMMEDIATELY. Never throws.
  void schedule(Iterable<String> originalNames) {
    if (_running) return;
    final batch = <String>[];
    for (final name in originalNames) {
      if (_givenUp.contains(name)) continue;
      batch.add(name);
      if (batch.length == maxPerPass) break;
    }
    if (batch.isEmpty) return;
    _running = true;
    _pending = _runPass(batch).whenComplete(() => _running = false);
    // `_runPass` never throws, so this can never become an unhandled async
    // error — which is the only reason firing and forgetting is safe here.
    unawaited(_pending);
  }

  Future<void> _runPass(List<String> originalNames) async {
    for (final name in originalNames) {
      try {
        final original = await _download(
          'shared/$name',
        ).timeout(perStepTimeout);
        // Absent or empty: the object was deleted or unshared between the
        // listing and now. It will not be in the next listing either, so there
        // is nothing to remember.
        if (original == null || original.isEmpty) continue;
        final source = original is Uint8List
            ? original
            : Uint8List.fromList(original);

        final Uint8List thumb;
        try {
          thumb = await _thumbnail(source).timeout(perStepTimeout);
        } catch (_) {
          _givenUp.add(name);
          continue;
        }
        if (thumb.isEmpty) {
          _givenUp.add(name);
          continue;
        }

        await _upload(
          sharedThumbPath(p.basenameWithoutExtension(name)),
          thumb,
        ).timeout(perStepTimeout);
      } catch (_) {
        // Transient — offline, a Storage error, a timeout. Deliberately NOT
        // remembered: the object stays in the worklist exactly as long as it
        // genuinely lacks a thumbnail, so the next pass retries it and the
        // whole mechanism heals itself the way every other no-outbox path in
        // this app does (decision D-4).
      }
    }
  }
}

/// True when a LOCAL row (with `updatedAt` [localUpdatedAt]) should be
/// pushed up to the cloud, given the cloud's current `updatedAt` for that
/// same row ([remoteUpdatedAt], `null` if no cloud row exists yet) — i.e. a
/// row is skipped only when a remote row exists AND its `updatedAt` is
/// strictly newer than the local row's. Local wins ties (`>=`), since local
/// is the side being pushed (client-side last-writer-wins on push, #2).
///
/// Mirrors `BackupRepository._shouldWriteLww`'s predicate shape (used on the
/// pull/import side) so the two conflict-resolution rules stay consistent;
/// shared here (rather than duplicated) so [SupabaseSyncRemote] and the
/// `FakeSyncRemote` test double apply the identical rule.
bool shouldPushLww({required int localUpdatedAt, required int? remoteUpdatedAt}) =>
    remoteUpdatedAt == null || localUpdatedAt >= remoteUpdatedAt;

/// True when every field named in [requiredFields] is present in [row] AND
/// non-null — type-agnostic (works for any Drift column type: `String`,
/// `int`, `bool`, ...), not just `String` FK ids. The guard
/// [SupabaseSyncRemote.fetchOwnRows], [SupabaseSyncRemote.fetchSharedTopos],
/// [SupabaseSyncRemote.fetchSharedAscents], and — on the push side —
/// `SyncService.pushOwn` all apply this to each row (via
/// [filterValidSyncRows]) before using any of [requiredFields] as an FK id
/// to derive a follow-up query, before returning/sending the row at all, or
/// before trusting it to survive `<Table>.fromJson()` (which throws on a
/// null NOT-NULL column of ANY type, not just String).
///
/// P0 fix (#72, "fresh install syncs nothing after login"): a cloud row
/// with an unexpectedly-null required column used to hit a non-null
/// `as String` cast and throw, aborting the WHOLE fetch (and, upstream, the
/// whole pull — see `SyncService.pullOwnAndShared`'s per-section isolation
/// for the other half of this fix). This predicate lets the fetch SKIP just
/// that one malformed row instead.
///
/// Sync-resilience hardening: originally String-only (`row[field] is!
/// String`), which meant a required NOT-NULL non-String column (e.g.
/// `Photos.width`, `Ascents.climbedAt`, `Sectors.sortOrder`) could never be
/// validated by this predicate at all. Now checks presence + non-null
/// generically via [syncRequiredFields], so every NOT-NULL column can be
/// covered, not just the narrow FK-id sets this used to be called with.
bool hasRequiredSyncFields(Map<String, dynamic> row, List<String> requiredFields) {
  for (final field in requiredFields) {
    if (!row.containsKey(field) || row[field] == null) return false;
  }
  return true;
}

/// Authoritative per-table set of required (NOT NULL) column names, used as
/// the [hasRequiredSyncFields]/[filterValidSyncRows] `requiredFields` for a
/// full own-row validation — both on fetch ([SupabaseSyncRemote.fetchOwnRows])
/// and on push (`SyncService.pushOwn`'s local-row guard).
///
/// SOURCE OF TRUTH: derived directly from the NOT-NULL columns declared in
/// `lib/core/db/tables.dart`. Every table includes `id`/`createdAt`/
/// `updatedAt` because the shared `SyncColumns` mixin declares all three
/// NOT NULL (with no Drift-level default) on every table — including
/// `Profiles` and `Likes`, whose own business columns are all nullable —
/// so a row missing any of the three would equally crash `<Table>.fromJson()`
/// or the `row['updatedAt'] as int` cast `upsertOwnRows` relies on for its
/// last-writer-wins guard, regardless of table.
///
/// Beyond that floor, each table lists its own additional NOT-NULL columns
/// that carry no Drift `withDefault(...)` (a column WITH a Drift default —
/// `dirty`, `Photos.sortOrder`/`isPrimary`, `Routes.visible` — is excluded,
/// since those are non-corruption-signaling bookkeeping/cosmetic fields),
/// with one deliberate exception: `Walls.visibility`/`Ascents.visibility`
/// ARE required despite having a Drift default, because sharing/community
/// queries key directly off them (`.eq('visibility', 'shared')`) and a null
/// value there would silently corrupt that filtering.
const Map<String, List<String>> syncRequiredFields = {
  'profiles': ['id', 'createdAt', 'updatedAt'],
  'areas': ['id', 'createdAt', 'updatedAt', 'name'],
  'sectors': ['id', 'createdAt', 'updatedAt', 'areaId', 'name', 'sortOrder'],
  'walls': ['id', 'createdAt', 'updatedAt', 'sectorId', 'name', 'sortOrder', 'visibility'],
  'photos': ['id', 'createdAt', 'updatedAt', 'wallId', 'localPath', 'kind', 'width', 'height'],
  'routes': [
    'id',
    'createdAt',
    'updatedAt',
    'wallId',
    'photoId',
    'number',
    'colorIndex',
    'pointsJson',
    'symbolsJson',
    'sortOrder',
  ],
  'ascents': ['id', 'createdAt', 'updatedAt', 'routeId', 'wallId', 'climbedAt', 'style', 'visibility'],
  'comments': ['id', 'createdAt', 'updatedAt', 'body'],
  'likes': ['id', 'createdAt', 'updatedAt'],
};

/// [filterValidSyncRows]'s reporting counterpart: splits [rows] into those
/// satisfying [hasRequiredSyncFields] for [requiredFields] (`valid`) and
/// those that don't (`invalid`), logging each dropped row exactly the same
/// way [filterValidSyncRows] does.
///
/// L5 fix (§1d): the PUSH side needs to know WHICH rows it excluded so they
/// can surface in `PushSyncResult.rowsFailed`/`PushSyncResult.errors`. With
/// no outbox, an excluded row used to be dropped from this and every future
/// push with nothing but a [debugPrint] to show for it — "excluded once"
/// meant "excluded forever", invisibly.
({List<Map<String, dynamic>> valid, List<Map<String, dynamic>> invalid})
partitionSyncRows(
  Iterable<Map<String, dynamic>> rows,
  List<String> requiredFields, {
  required String debugLabel,
}) {
  final valid = <Map<String, dynamic>>[];
  final invalid = <Map<String, dynamic>>[];
  for (final row in rows) {
    if (hasRequiredSyncFields(row, requiredFields)) {
      valid.add(row);
    } else {
      invalid.add(row);
      debugPrint(
        'SyncRemote: skipping malformed $debugLabel row (missing one of '
        '$requiredFields as a non-null value): $row',
      );
    }
  }
  return (valid: valid, invalid: invalid);
}

/// Filters [rows] down to those satisfying [hasRequiredSyncFields] for
/// [requiredFields] — every OTHER (valid) row in the same batch still
/// passes through untouched. A dropped row is logged via [debugPrint]
/// (tagged with [debugLabel], e.g. `'shared wall'`) rather than silently
/// vanishing, to aid diagnosing a real backend data-quality issue.
///
/// Use [partitionSyncRows] instead when the caller must REPORT what it
/// dropped rather than merely skip it (the push side must — see L5).
List<Map<String, dynamic>> filterValidSyncRows(
  Iterable<Map<String, dynamic>> rows,
  List<String> requiredFields, {
  required String debugLabel,
}) => partitionSyncRows(rows, requiredFields, debugLabel: debugLabel).valid;

/// Drops rows from a shared-ascent batch whose own parents are not in the same
/// batch, so the importer is never handed something it structurally cannot
/// insert.
///
/// ## Why this is needed at all
///
/// The local schema enforces every one of these FKs, all NOT NULL:
/// `ascents.routeId → routes`, `ascents.wallId → walls`,
/// `routes.photoId → photos`, `routes.wallId → walls`,
/// `walls.sectorId → sectors`, `sectors.areaId → areas`. So a batch missing one
/// link cannot be written, and `BackupRepository.importSnapshot` defers the row
/// and reports `shared rows deferred (parent row missing)` — which reaches the
/// user as the red "Couldn't sync — Retry" banner on the feed.
///
/// [SupabaseSyncRemote.fetchSharedAscents] assembles the chain in four waves,
/// and **every wave after the first is subject to RLS on the table it reads**.
/// The ascent policy and the ancestor policies did not agree: a shared ascent
/// was readable on `visibility = 'shared'` alone, while its route and wall need
/// `is_wall_public(...)`. An ascent on a topo that had since been deleted,
/// unpublished, withdrawn, taken down or marked sensitive therefore came back
/// with no parents at all — and the resulting error could never heal, because
/// the parent was never going to be returned again.
///
/// `supabase/migrations/2026-08-08_shared_ascent_wall_visibility.sql` fixes the
/// asymmetry at the source. This is the client half, and it is worth having on
/// its own: the two halves of the chain are separate queries against a live
/// database, so a topo withdrawn *between* them produces the same orphan with
/// no bug at either end. That race heals on the next pull; what it must not do
/// is tell the user their sync is broken in the meantime.
///
/// ## What it does NOT do
///
/// It does not silence the deferral report. Dropping a row that provably cannot
/// be inserted is not the same as swallowing a failure (#72) — the batch this
/// returns is internally consistent, so any deferral the importer still reports
/// is a real defect worth showing.
///
/// Pruning runs bottom-up (areas → sectors → walls → photos → routes →
/// ascents), so a hole at any depth propagates to everything hanging off it in
/// a single pass; nothing here is order-independent.
Map<String, List<Map<String, dynamic>>> consistentSharedAscentBatch(
  Map<String, List<Map<String, dynamic>>> tables,
) {
  List<Map<String, dynamic>> rows(String key) => tables[key] ?? const [];
  Set<String> idsOf(Iterable<Map<String, dynamic>> from) => {
    for (final row in from)
      if (row['id'] case final String id) id,
  };
  bool has(Set<String> ids, Object? value) => value is String && ids.contains(value);

  final areaIds = idsOf(rows('areas'));
  final sectors = [
    for (final s in rows('sectors'))
      if (has(areaIds, s['areaId'])) s,
  ];

  final sectorIds = idsOf(sectors);
  final walls = [
    for (final w in rows('walls'))
      if (has(sectorIds, w['sectorId'])) w,
  ];

  // A slice points at its original via the nullable `parentPhotoId`. A null
  // parent is the ordinary case and must not be pruned; a non-null one that is
  // absent would break the FK exactly like any other missing parent.
  final wallIds = idsOf(walls);
  final photos = [
    for (final p in rows('photos'))
      if (has(wallIds, p['wallId'])) p,
  ];
  final photoIdsWithParents = idsOf(photos);
  final keptPhotos = [
    for (final p in photos)
      if (p['parentPhotoId'] == null || has(photoIdsWithParents, p['parentPhotoId']))
        p,
  ];

  final photoIds = idsOf(keptPhotos);
  final routes = [
    for (final r in rows('routes'))
      if (has(wallIds, r['wallId']) && has(photoIds, r['photoId'])) r,
  ];

  final routeIds = idsOf(routes);
  final ascents = [
    for (final a in rows('ascents'))
      if (has(wallIds, a['wallId']) && has(routeIds, a['routeId'])) a,
  ];

  return {
    ...tables,
    'areas': rows('areas'),
    'sectors': sectors,
    'walls': walls,
    'photos': keptPhotos,
    'routes': routes,
    'ascents': ascents,
  };
}

/// [ids] de-duplicated and split into request-sized batches of at most
/// [chunkSize], preserving first-appearance order.
///
/// Every id appears in EXACTLY ONE returned chunk — that is the property callers
/// depend on, and the reason this is a named pure function rather than an inline
/// `for (var i = 0; i < ...; i += n)` at each call site. Returns an empty list
/// for empty [ids], so `for (final chunk in chunkSyncIds(...))` is already the
/// "no round trips" case.
List<List<String>> chunkSyncIds(
  Iterable<String> ids, {
  int chunkSize = kInboundEngagementChunkSize,
}) {
  final unique = <String>[];
  final seen = <String>{};
  for (final id in ids) {
    if (seen.add(id)) unique.add(id);
  }
  final chunks = <List<String>>[];
  for (var i = 0; i < unique.length; i += chunkSize) {
    final end = i + chunkSize;
    chunks.add(unique.sublist(i, end > unique.length ? unique.length : end));
  }
  return chunks;
}

/// The subset of an inbound engagement batch (see
/// [SyncRemote.fetchEngagementByParentIds]) whose parents are PROVABLY present —
/// i.e. every non-null `ascentId` is in [knownAscentIds] and every non-null
/// `wallId` is in [knownWallIds].
///
/// `Comments.wallId`/`Comments.ascentId` (and the same pair on `Likes`) are
/// nullable but FK-enforced when set (`PRAGMA foreign_keys = ON`), and
/// `BackupRepository.importSnapshot` DEFERS a row whose parent is absent rather
/// than throwing — which `SyncService.pullOwnAndShared` then reports as
/// `shared rows deferred (parent row missing)`, i.e. the red "Couldn't sync —
/// Retry" banner. That banner can never clear if the parent is something this
/// device is never going to hold, so a row that provably cannot be inserted is
/// dropped here instead, exactly as [consistentSharedAscentBatch] does for the
/// shared-ascent chain.
///
/// In practice this drops nothing: the fetch asks by exactly these ids, an
/// ascent comment carries `wallId IS NULL`, and a wall comment carries
/// `ascentId IS NULL`. It exists for the row shape that sets BOTH — which no
/// current writer produces, and which would otherwise reach the importer as an
/// orphan on whichever of the two the caller did not ask about.
///
/// A row with NEITHER parent is KEPT: it has no FK to violate, so it is the
/// importer's business, not this filter's.
List<Map<String, dynamic>> consistentInboundEngagement(
  Iterable<Map<String, dynamic>> rows, {
  required Set<String> knownAscentIds,
  required Set<String> knownWallIds,
}) => [
  for (final row in rows)
    if ((row['ascentId'] == null || knownAscentIds.contains(row['ascentId'])) &&
        (row['wallId'] == null || knownWallIds.contains(row['wallId'])))
      row,
];

/// The columns present in every `<TableRow>.toJson()` that are LOCAL-ONLY
/// sync bookkeeping and must never travel to the cloud.
///
/// - `dirty` is this device's "has an unpushed local change" flag (see
///   `tables.dart`'s `SyncColumns` and `SyncService.hasPendingLocalChanges`).
///   Sending it is worse than useless: it is per-DEVICE state, so device A's
///   flag would land in the shared cloud row and come back down to device B
///   as if B had a pending change.
/// - `remoteId` is a reserved, never-written local column.
///
/// Both used to ship inside every pushed row (S8). Stripping them is safe on
/// the wire in both directions: `supabase/schema.sql` declares
/// `"dirty" BOOLEAN NOT NULL DEFAULT false` and `"remoteId" TEXT`, so an
/// INSERT that omits them takes the default / NULL and an
/// `ON CONFLICT DO UPDATE` leaves the stored value untouched; and on the way
/// back `BackupRepository.importSnapshot` forces `dirty: false` on every row
/// regardless (see its `_notDirty`). Neither name appears in
/// [syncRequiredFields], so stripping can never trip the NOT-NULL guard.
const Set<String> localOnlySyncColumns = {'dirty', 'remoteId'};

/// [row] without any [localOnlySyncColumns] key. Returns a COPY — the caller
/// still holds the original `toJson()` map, and `SyncService.pushOwn` relies
/// on the stripped map keeping `id` and `updatedAt` (both required, both
/// retained) for its confirmed-push `dirty` clear.
Map<String, dynamic> stripLocalOnlySyncColumns(Map<String, dynamic> row) {
  final stripped = Map<String, dynamic>.of(row);
  stripped.removeWhere((key, _) => localOnlySyncColumns.contains(key));
  return stripped;
}

/// Real [SyncRemote], backed by the Supabase client.
///
/// LIVE: all nine tables (`profiles`/`areas`/`sectors`/`walls`/`photos`/`routes`/
/// `comments`/`likes`/`ascents`) exist on the real Supabase project (see
/// `supabase/schema.sql`), with RLS (`"ownerId" = auth.uid()::text` for
/// row-level own-data access, plus a `visibility = 'shared'`-scoped SELECT
/// policy with no owner check for the shared-topo query below) and the
/// `shared/` Storage policy described on [SyncRemote.uploadSharedPhoto].
/// Verified end-to-end against the real backend via a two-account live
/// smoke test, in addition to [SyncService]'s full `FakeSyncRemote`-backed
/// unit-test coverage.
class SupabaseSyncRemote implements SyncRemote {
  SupabaseSyncRemote(this._client);

  final SupabaseClient _client;

  static const String _bucket = 'topo-photos';

  /// The side channel that gives pre-thumbnail-tier objects their
  /// `shared/thumbs/` companion. Driven from [listSharedPhotoObjectPaths],
  /// which is the one place that already knows both sides of the comparison —
  /// and which deliberately does not let the answer reach its own return value.
  ///
  /// `late final` rather than an initializer-list entry because it closes over
  /// this instance's own storage helpers.
  late final SharedThumbBackfill _thumbBackfill = SharedThumbBackfill(
    download: downloadSharedPhoto,
    upload: (objectPath, bytes) => _client.storage
        .from(_bucket)
        .uploadBinary(
          objectPath,
          bytes,
          // `upsert: false`, unlike every other upload in this class, and it is
          // load-bearing rather than a style choice. This is the ONE upload
          // that writes an object the caller does not own: the backfill is
          // deliberately cross-owner, and the SEC-3 storage policy permits that
          // only for a `shared/thumbs/` path the caller may already read
          // (`can_read_shared_photo_object`), while REPLACING any existing
          // object still requires ownership (`owns_shared_photo_object`, on
          // UPDATE). `x-upsert: true` asks for replace semantics up front, so
          // it risks being evaluated against the UPDATE policy even when the
          // object does not exist yet — which would make every foreign
          // backfill fail, silently, since the upload error is swallowed and
          // the only symptom is feed tiles quietly falling back to
          // multi-megabyte originals.
          //
          // Nothing is lost: `sharedOriginalsNeedingThumbs` only ever
          // worklists thumbs that are MISSING, so this closure never has an
          // existing object to overwrite.
          fileOptions: const FileOptions(upsert: false),
        ),
  );

  /// The backfill pass in flight, for tests that need to await it.
  @visibleForTesting
  SharedThumbBackfill get thumbBackfill => _thumbBackfill;

  @override
  Future<List<TablePushOutcome>> upsertOwnRows(
    String uid,
    Map<String, List<Map<String, dynamic>>> tablesToRows,
  ) async {
    final outcomes = <TablePushOutcome>[];
    for (final tableName in syncTableNames) {
      final rows = tablesToRows[tableName];
      if (rows == null || rows.isEmpty) continue;

      // Per-table push isolation (sync-resilience hardening): a rejected/
      // erroring table (bad data, a transient network blip on that one round
      // trip, a real backend constraint violation, ...) must not abort the
      // whole loop — every LATER table (and, upstream, `SyncService.pushOwn`'s
      // subsequent photo-upload phase) still needs to run regardless of one
      // earlier table's failure.
      //
      // S1 fix (§1d): the failure is now REPORTED to the caller as well as
      // logged. It used to be a bare `debugPrint` + `continue` under a
      // `Future<void>` return, which is what let a totally-failed offline
      // push read as "Synced • just now".
      try {
        // Client-side last-writer-wins guard on push (#2): fetch the remote's
        // current id+updatedAt for exactly the ids about to be pushed (one
        // batched round trip per table, not one per row), and drop any row a
        // strictly-newer remote row would otherwise get clobbered by. See
        // [shouldPushLww].
        final ids = [for (final row in rows) row['id'] as String];
        final remoteRows = await _client.from(tableName).select('id, updatedAt').inFilter('id', ids);
        final remoteUpdatedAt = <String, int>{
          for (final r in remoteRows) r['id'] as String: r['updatedAt'] as int,
        };
        final survivors = [
          for (final row in rows)
            if (shouldPushLww(
              localUpdatedAt: row['updatedAt'] as int,
              remoteUpdatedAt: remoteUpdatedAt[row['id']],
            ))
              row,
        ];
        final skipped = rows.length - survivors.length;
        if (survivors.isEmpty) {
          outcomes.add(
            TablePushOutcome.ok(
              table: tableName,
              rowsUpserted: 0,
              rowsSkippedNewerRemote: skipped,
            ),
          );
          continue;
        }

        // Confirmed live: the real Postgres tables (see `supabase/schema.sql`)
        // use matching camelCase quoted columns (`"ownerId"`, `"wallId"`, ...)
        // for drift's `toJson()` keys — no snake_case mapping layer needed.
        await _client.from(tableName).upsert(survivors);
        outcomes.add(
          TablePushOutcome.ok(
            table: tableName,
            rowsUpserted: survivors.length,
            rowsSkippedNewerRemote: skipped,
          ),
        );
      } catch (e) {
        debugPrint(
          'SyncRemote: upsertOwnRows failed for table "$tableName" '
          '(${rows.length} row(s)), reported to the caller — other tables '
          'still push: $e',
        );
        // Pessimistic on purpose: `rows.length`, not `survivors.length` —
        // the throw may have come from the LWW pre-check itself, before any
        // row was classified. Over-reporting unsynced work is safe;
        // under-reporting it is exactly the S1 bug.
        outcomes.add(
          TablePushOutcome.failed(
            table: tableName,
            rowsFailed: rows.length,
            error: e,
          ),
        );
      }
    }
    return outcomes;
  }

  @override
  Future<Map<String, List<Map<String, dynamic>>>> fetchOwnRows(
    String uid,
  ) async {
    // One SELECT per table, ISSUED CONCURRENTLY. These queries are mutually
    // independent — each is `ownerId = uid` against a different table, with no
    // value from one feeding another — so awaiting them in sequence spent
    // `syncTableNames.length` (9) round-trips of latency to do one round-trip
    // of work. On the mobile connection this app is actually used on (a phone
    // at a crag), that is the difference between a pull that feels instant and
    // one that visibly hangs.
    //
    // `Future.wait` WITHOUT `eagerError` on purpose: it waits for every query
    // to settle before completing, then reports the first error. `eagerError:
    // true` would complete on the first failure and leave the other in-flight
    // futures to fail into the zone as unhandled errors. Failure semantics for
    // the caller are unchanged either way — the whole fetch still throws.
    //
    // [syncTableNames] is FK dependency order and `result`'s INSERTION order
    // is load-bearing (`BackupRepository.importSnapshot` applies tables in the
    // order it iterates them), so the map is rebuilt by walking `tableNames`
    // in order after the wait — never by completion order.
    final tableNames = syncTableNames;
    final fetched = await Future.wait(<Future<List<Map<String, dynamic>>>>[
      for (final tableName in tableNames)
        _client.from(tableName).select().eq('ownerId', uid),
    ]);

    final result = <String, List<Map<String, dynamic>>>{};
    for (var i = 0; i < tableNames.length; i++) {
      final mapped = [
        for (final row in fetched[i]) Map<String, dynamic>.from(row),
      ];
      // Full required-NOT-NULL-field validation per table (sync-resilience
      // hardening) — was `const ['id']` only (P0 fix, #72), which caught a
      // missing primary key but let a row with any OTHER null NOT-NULL
      // column (e.g. a null `sortOrder`/`width`/`climbedAt`) through to
      // throw deeper in `<Table>.fromJson()`/`BackupRepository.
      // importSnapshot`. [syncRequiredFields] is the authoritative map (see
      // its doc); the `?? const ['id']` fallback is defensive only — every
      // name in [syncTableNames] has a matching entry there.
      result[tableNames[i]] = filterValidSyncRows(
        mapped,
        syncRequiredFields[tableNames[i]] ?? const ['id'],
        debugLabel: 'own ${tableNames[i]}',
      );
    }
    return result;
  }

  @override
  Future<Map<String, List<Map<String, dynamic>>>> fetchSharedTopos({
    SharedTopoScope scope = const SharedTopoScope.unbounded(),
  }) async {
    // TODO(P0 backend): this is still a client-side join (walls -> sectors ->
    // areas, plus photos/routes/comments/likes by wallId), the shape this
    // phase's fake mirrors. It is now issued in dependency WAVES rather than
    // one query at a time — 3 round-trips instead of 7 — but the real backend
    // should still expose it as a single RPC/view: three round-trips is the
    // floor for a client-side join, and RLS on `sectors`/`areas` has no
    // `visibility` column of its own to filter on, so it would need to derive
    // "ancestor of a shared wall" the same way this client-side code does,
    // e.g. via a security-definer function.
    final rawWalls = <Map<String, dynamic>>[
      for (final row in await _fetchScopedWalls(scope))
        Map<String, dynamic>.from(row),
    ];
    // `id`/`sectorId` are both used below to derive follow-up queries (and
    // `sectorId` is a NOT NULL FK), so a wall row missing either is skipped
    // rather than throwing on the non-null `as String` casts that used to
    // sit here directly — a single malformed row must not abort the whole
    // fetch (P0 fix, #72; see [hasRequiredSyncFields]/[filterValidSyncRows]).
    final wallRows = filterValidSyncRows(rawWalls, const ['id', 'sectorId'], debugLabel: 'shared wall');
    if (wallRows.isEmpty) {
      return {
        'areas': <Map<String, dynamic>>[],
        'sectors': <Map<String, dynamic>>[],
        'walls': <Map<String, dynamic>>[],
        'photos': <Map<String, dynamic>>[],
        'routes': <Map<String, dynamic>>[],
        'comments': <Map<String, dynamic>>[],
        'likes': <Map<String, dynamic>>[],
        // NOTE: deliberately no 'ascents' key — see [fetchSharedTopos] doc.
      };
    }

    final wallIds = [for (final w in wallRows) w['id'] as String];
    final sectorIds = {for (final w in wallRows) w['sectorId'] as String}.toList();

    // WAVE 2 — everything reachable from `wallRows` alone, issued together.
    // `sectors` is keyed on `sectorIds` and the other four on `wallIds`; all
    // five come straight off the wall rows, so nothing here waits on anything
    // else here. Only `areas` (wave 3) genuinely depends on a wave-2 result,
    // because its ids come out of the SECTOR rows. Sequencing all six cost six
    // round-trips of latency for two round-trips of actual dependency depth.
    // See [fetchOwnRows] for why `Future.wait` runs without `eagerError`.
    final wave2 = await Future.wait(<Future<List<Map<String, dynamic>>>>[
      _client.from('sectors').select().inFilter('id', sectorIds),
      _client.from('photos').select().inFilter('wallId', wallIds),
      _client.from('routes').select().inFilter('wallId', wallIds),
      _client.from('comments').select().inFilter('wallId', wallIds),
      _client.from('likes').select().inFilter('wallId', wallIds),
    ]);

    final rawSectors = <Map<String, dynamic>>[
      for (final row in wave2[0]) Map<String, dynamic>.from(row),
    ];
    final sectorRows = filterValidSyncRows(
      rawSectors,
      const ['id', 'areaId'],
      debugLabel: 'shared sector',
    );

    final rawPhotos = <Map<String, dynamic>>[
      for (final row in wave2[1]) Map<String, dynamic>.from(row),
    ];
    final photoRows = filterValidSyncRows(rawPhotos, const ['id'], debugLabel: 'shared photo');

    final rawRoutes = <Map<String, dynamic>>[
      for (final row in wave2[2]) Map<String, dynamic>.from(row),
    ];
    final routeRows = filterValidSyncRows(rawRoutes, const ['id'], debugLabel: 'shared route');

    final rawComments = <Map<String, dynamic>>[
      for (final row in wave2[3]) Map<String, dynamic>.from(row),
    ];
    final commentRows = filterValidSyncRows(rawComments, const ['id'], debugLabel: 'shared comment');

    final rawLikes = <Map<String, dynamic>>[
      for (final row in wave2[4]) Map<String, dynamic>.from(row),
    ];
    final likeRows = filterValidSyncRows(rawLikes, const ['id'], debugLabel: 'shared like');

    // WAVE 3 — areas, the one genuine dependency: its ids come from the
    // validated sector rows above, so it cannot be hoisted into wave 2.
    final areaIds = {for (final s in sectorRows) s['areaId'] as String}.toList();

    final rawAreas = <Map<String, dynamic>>[
      for (final row in await _client.from('areas').select().inFilter('id', areaIds))
        Map<String, dynamic>.from(row),
    ];
    final areaRows = filterValidSyncRows(rawAreas, const ['id'], debugLabel: 'shared area');

    return {
      'areas': areaRows,
      'sectors': sectorRows,
      'walls': wallRows,
      'photos': photoRows,
      'routes': routeRows,
      'comments': commentRows,
      'likes': likeRows,
      // NOTE: deliberately no 'ascents' key — see [fetchSharedTopos] doc.
    };
  }

  /// The published walls one pull should carry, per [scope] (W-1).
  ///
  /// Two queries rather than one when a bounding box applies, because a topo
  /// with NO coordinates cannot satisfy a coordinate filter and would otherwise
  /// vanish from every scoped pull forever — a worse bug than the unbounded
  /// fetch this replaces. They get their own small budget
  /// ([SharedTopoScope.uncoordinatedLimit]) so they can neither disappear nor
  /// crowd out the geographic result.
  ///
  /// Ordered by `updatedAt` descending wherever a limit applies: when something
  /// has to be dropped, the freshest topos are the ones worth keeping, and a
  /// deterministic order also stops two consecutive pulls from disagreeing
  /// about which half of a dense region the device holds.
  Future<List<Map<String, dynamic>>> _fetchScopedWalls(SharedTopoScope scope) async {
    List<Map<String, dynamic>> shape(Iterable<dynamic> rows) =>
        [for (final row in rows) Map<String, dynamic>.from(row as Map)];

    if (scope.isUnbounded) {
      return shape(
        await _client.from('walls').select().eq('visibility', 'shared'),
      );
    }

    final box = scope.boundingBox;
    if (box == null) {
      // No anchor (or a window that wraps the antimeridian): fall back to the
      // cap alone. Still bounded, just not geographic.
      final query = _client
          .from('walls')
          .select()
          .eq('visibility', 'shared')
          .order('updatedAt', ascending: false);
      return shape(await (scope.limit > 0 ? query.limit(scope.limit) : query));
    }

    final within = _client
        .from('walls')
        .select()
        .eq('visibility', 'shared')
        .gte('latitude', box.minLatitude)
        .lte('latitude', box.maxLatitude)
        .gte('longitude', box.minLongitude)
        .lte('longitude', box.maxLongitude)
        .order('updatedAt', ascending: false);

    final uncoordinated = _client
        .from('walls')
        .select()
        .eq('visibility', 'shared')
        .isFilter('latitude', null)
        .order('updatedAt', ascending: false);

    final results = await Future.wait([
      scope.limit > 0 ? within.limit(scope.limit) : within,
      scope.uncoordinatedLimit > 0
          ? uncoordinated.limit(scope.uncoordinatedLimit)
          : uncoordinated,
    ]);

    // Concatenated, not merged by id: the two queries are disjoint by
    // construction (one requires a latitude, the other requires none), and the
    // import is an idempotent per-id upsert regardless.
    return [...shape(results[0]), ...shape(results[1])];
  }

  @override
  Future<Map<String, List<Map<String, dynamic>>>> fetchSharedAscents() async {
    final rawAscents = <Map<String, dynamic>>[
      for (final row in await _client.from('ascents').select().eq('visibility', 'shared'))
        Map<String, dynamic>.from(row),
    ];
    // `id`/`wallId`/`routeId` are all used below to derive follow-up
    // queries (both NOT NULL FKs), so an ascent row missing any of them is
    // skipped rather than throwing on the non-null `as String` casts that
    // used to sit here directly (P0 fix, #72; see
    // [hasRequiredSyncFields]/[filterValidSyncRows]).
    final ascentRows = filterValidSyncRows(
      rawAscents,
      const ['id', 'wallId', 'routeId'],
      debugLabel: 'shared ascent',
    );
    if (ascentRows.isEmpty) {
      return {
        'areas': <Map<String, dynamic>>[],
        'sectors': <Map<String, dynamic>>[],
        'walls': <Map<String, dynamic>>[],
        'photos': <Map<String, dynamic>>[],
        'routes': <Map<String, dynamic>>[],
        'ascents': <Map<String, dynamic>>[],
      };
    }

    // Minimal ancestor/reference chain so the FK-enforced routeId/wallId (and
    // in turn a route's photoId, a wall's sectorId, a sector's areaId) all
    // resolve locally — see this method's doc for why this must be scoped to
    // exactly these ids, not a wall's full context.
    final wallIds = {for (final a in ascentRows) a['wallId'] as String}.toList();
    final routeIds = {for (final a in ascentRows) a['routeId'] as String}.toList();

    // The ancestor chain is a 4-deep DAG, not a 6-step line. Both `walls` and
    // `routes` key off the ascent rows; `sectors` needs walls and `photos`
    // needs routes, but NOT each other; only `areas` needs sectors. Walking it
    // depth-first cost six round-trips to resolve four levels. Issuing each
    // level's queries together costs four. See [fetchOwnRows] for why
    // `Future.wait` runs without `eagerError`.
    final wave2 = await Future.wait(<Future<List<Map<String, dynamic>>>>[
      _client.from('walls').select().inFilter('id', wallIds),
      _client.from('routes').select().inFilter('id', routeIds),
    ]);

    final rawWalls = <Map<String, dynamic>>[
      for (final row in wave2[0]) Map<String, dynamic>.from(row),
    ];
    final wallRows = filterValidSyncRows(
      rawWalls,
      const ['id', 'sectorId'],
      debugLabel: 'shared-ascent wall',
    );
    final sectorIds = {for (final w in wallRows) w['sectorId'] as String}.toList();

    final rawRoutes = <Map<String, dynamic>>[
      for (final row in wave2[1]) Map<String, dynamic>.from(row),
    ];
    final routeRows = filterValidSyncRows(
      rawRoutes,
      const ['id', 'photoId'],
      debugLabel: 'shared-ascent route',
    );
    final photoIds = {for (final r in routeRows) r['photoId'] as String}.toList();

    final wave3 = await Future.wait(<Future<List<Map<String, dynamic>>>>[
      _client.from('sectors').select().inFilter('id', sectorIds),
      _client.from('photos').select().inFilter('id', photoIds),
    ]);

    final rawSectors = <Map<String, dynamic>>[
      for (final row in wave3[0]) Map<String, dynamic>.from(row),
    ];
    final sectorRows = filterValidSyncRows(
      rawSectors,
      const ['id', 'areaId'],
      debugLabel: 'shared-ascent sector',
    );

    final rawPhotos = <Map<String, dynamic>>[
      for (final row in wave3[1]) Map<String, dynamic>.from(row),
    ];
    final photoRows = filterValidSyncRows(rawPhotos, const ['id'], debugLabel: 'shared-ascent photo');

    final areaIds = {for (final s in sectorRows) s['areaId'] as String}.toList();

    final rawAreas = <Map<String, dynamic>>[
      for (final row in await _client.from('areas').select().inFilter('id', areaIds))
        Map<String, dynamic>.from(row),
    ];
    final areaRows = filterValidSyncRows(rawAreas, const ['id'], debugLabel: 'shared-ascent area');

    // Every wave above is RLS-filtered independently of the ascent query that
    // seeded it, so this batch is NOT internally consistent by construction —
    // see [consistentSharedAscentBatch] for the failure it prevents.
    return consistentSharedAscentBatch({
      'areas': areaRows,
      'sectors': sectorRows,
      'walls': wallRows,
      'photos': photoRows,
      'routes': routeRows,
      'ascents': ascentRows,
    });
  }

  @override
  Future<Map<String, List<Map<String, dynamic>>>> fetchEngagementByParentIds({
    required List<String> ascentIds,
    required List<String> wallIds,
  }) async {
    // De-duplicated by row id across all four query streams below, because the
    // same row can legitimately come back twice: two chunks never overlap, but a
    // hypothetical row carrying BOTH a wallId and an ascentId we asked about
    // matches the ascent query AND the wall query. A map keyed on `id` makes that
    // idempotent instead of importing the row twice.
    final comments = <String, Map<String, dynamic>>{};
    final likes = <String, Map<String, dynamic>>{};

    // "No ids" must cost nothing — this runs on EVERY pull, including for an
    // account that has published neither an ascent nor a topo.
    if (ascentIds.isEmpty && wallIds.isEmpty) {
      return {
        'comments': <Map<String, dynamic>>[],
        'likes': <Map<String, dynamic>>[],
      };
    }

    Future<void> collect(
      String table,
      String column,
      List<String> ids,
      Map<String, Map<String, dynamic>> into,
    ) async {
      for (final chunk in chunkSyncIds(ids)) {
        final rows = await _client.from(table).select().inFilter(column, chunk);
        for (final row in rows) {
          final mapped = Map<String, dynamic>.from(row);
          if (mapped['id'] case final String id) into[id] = mapped;
        }
      }
    }

    // The four streams are mutually independent (different table/column pairs,
    // no value from one feeding another), so they go out together for the same
    // reason [fetchOwnRows]'s nine do — and for the same reason `Future.wait`
    // runs here WITHOUT `eagerError`. Chunks WITHIN one stream stay sequential:
    // that is the bound on how many requests this can have in flight at once,
    // which is the whole point of chunking a large library.
    await Future.wait(<Future<void>>[
      collect('comments', 'ascentId', ascentIds, comments),
      collect('comments', 'wallId', wallIds, comments),
      collect('likes', 'ascentId', ascentIds, likes),
      collect('likes', 'wallId', wallIds, likes),
    ]);

    return {
      'comments': filterValidSyncRows(
        comments.values,
        syncRequiredFields['comments'] ?? const ['id'],
        debugLabel: 'inbound comment',
      ),
      'likes': filterValidSyncRows(
        likes.values,
        syncRequiredFields['likes'] ?? const ['id'],
        debugLabel: 'inbound like',
      ),
    };
  }

  @override
  Future<void> uploadPhoto({
    required String uid,
    required String photoId,
    required String ext,
    required List<int> bytes,
  }) async {
    final path = '$uid/$photoId$ext';
    await _client.storage
        .from(_bucket)
        .uploadBinary(
          path,
          Uint8List.fromList(bytes),
          fileOptions: const FileOptions(upsert: true),
        );
  }

  @override
  Future<List<int>?> downloadPhoto({
    required String uid,
    required String objectPath,
  }) async {
    try {
      return await _client.storage.from(_bucket).download(objectPath);
    } on StorageException {
      return null;
    }
  }

  /// Lists EVERY object under [prefix], paging past the storage client's
  /// 100-object `SearchOptions` default (S6 — see `storage_pagination.dart`
  /// for why a single un-paged `list()` silently truncated the skip-set and
  /// what that cost at full resolution).
  Future<List<FileObject>> _listAllObjects(String prefix) {
    return collectPagedObjects<FileObject>(
      (limit, offset) => _client.storage
          .from(_bucket)
          .list(
            path: prefix,
            searchOptions: SearchOptions(limit: limit, offset: offset),
          ),
    );
  }

  @override
  Future<Set<String>> listPhotoObjectPaths(String uid) async {
    final files = await _listAllObjects(uid);
    return {for (final file in files) '$uid/${file.name}'};
  }

  @override
  Future<void> uploadSharedPhoto({
    required String photoId,
    required String ext,
    required List<int> bytes,
  }) async {
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);

    // ORIGINAL FIRST — this is the publication, and its throw is the only one
    // allowed out of here. See [SyncRemote.uploadSharedPhoto] for why the two
    // objects must not be treated as equals.
    await _client.storage
        .from(_bucket)
        .uploadBinary(
          sharedPhotoPath(photoId, ext),
          data,
          fileOptions: const FileOptions(upsert: true),
        );

    await _publishThumbBestEffort(photoId, data);
  }

  /// Derives and publishes the small companion at [sharedThumbPath] for an
  /// already-publish-safe [data] (see [SyncRemote.uploadSharedPhoto]'s caller
  /// contract). NEVER throws, on any failure, by construction.
  ///
  /// Reuses `generateThumbnail` — the app's ONE resampler, the same seam
  /// `PhotoFiles` uses for the local `thumbs/` tier — through `compute`, so the
  /// decode/resize/encode of a 24-megapixel photo does not run on the UI
  /// thread during a push. (`compute` calls the function inline on web, where
  /// the backend is already the browser's offscreen canvas and therefore
  /// already off Flutter's own codec path.)
  ///
  /// Failure means NO THUMBNAIL — not "publish the original under the thumbnail
  /// path", which is what an earlier draft did to guarantee the pair completed.
  /// That guarantee is no longer needed (the skip-set is the original alone,
  /// see [listSharedPhotoObjectPaths]) and it was actively harmful: a
  /// multi-megabyte object at a path every 52-pixel list tile fetches is
  /// precisely the defect the thumbnail tier exists to remove. Absent is
  /// better, because absent already has a defined meaning downstream — the read
  /// path falls back to the original — while a lying thumbnail does not.
  Future<void> _publishThumbBestEffort(String photoId, Uint8List data) async {
    try {
      final thumb = await compute(generateThumbnail, data);
      await _client.storage
          .from(_bucket)
          .uploadBinary(
            sharedThumbPath(photoId),
            thumb,
            fileOptions: const FileOptions(upsert: true),
          );
    } catch (e) {
      debugPrint(
        'SyncRemote: shared thumbnail for "$photoId" not published — the '
        'original IS published and readers fall back to it: $e',
      );
    }
  }

  @override
  Future<List<int>?> downloadSharedPhoto(String objectPath) async {
    try {
      return await _client.storage.from(_bucket).download(objectPath);
    } on StorageException {
      return null;
    }
  }

  @override
  Future<Set<String>> listSharedPhotoObjectPaths() async {
    // Two listings, not one: `list(path: 'shared')` returns only the objects
    // DIRECTLY under `shared/` (plus a pseudo-entry for the `thumbs` folder
    // itself, dropped by [publishedSharedOriginals] for having no extension),
    // so the thumbnails need their own call. The second listing exists ONLY to
    // feed the backfill below — it is not, and must never become, a term of the
    // skip-set this returns.
    final originals = await _listAllObjects('shared');
    final thumbs = await _listAllObjects('shared/thumbs');
    final originalNames = [for (final file in originals) file.name];

    // SIDE CHANNEL, fired and forgotten. It cannot delay this call, cannot fail
    // it, and cannot change what it returns — see [SharedThumbBackfill] for why
    // that isolation is the point rather than an optimisation.
    _thumbBackfill.schedule(
      sharedOriginalsNeedingThumbs(
        originalNames: originalNames,
        thumbNames: {for (final file in thumbs) file.name},
      ),
    );

    // KNOWN AND DELIBERATE (privacy): every original published before the
    // publish-side EXIF strip landed (2026-08-08) is in this set, so the push
    // skips it and its ORIGINAL METADATA — including GPS — stays in the
    // world-readable bucket. Re-publishing them would strip it retroactively,
    // and this is the decision not to: that is ~94 MB of re-upload traffic
    // across the legacy corpus and, far worse, it would route an
    // already-published photo back through the fail-closed strip gate, which is
    // the exact retry-loop defect [SyncRemote.listSharedPhotoObjectPaths]
    // describes. Healing it is a separate, deliberate re-upload (a one-off
    // migration, or a per-photo "re-publish" action), NOT a side effect of
    // widening this skip-set. Recorded here so it is a findable item rather
    // than a silent one.
    return publishedSharedOriginals(originalNames);
  }

  @override
  Future<void> removePhoto({
    required String uid,
    required String photoId,
    required String ext,
  }) async {
    try {
      await _client.storage.from(_bucket).remove(['$uid/$photoId$ext']);
    } on StorageException {
      // Best-effort/idempotent — an absent object must not fail the push.
    }
  }

  @override
  Future<Set<String>> removeSharedPhoto({
    required String photoId,
    required String ext,
  }) async {
    try {
      // One call, both objects — the original and the thumbnail published
      // alongside it. `remove` is idempotent per path, so a photo published
      // before the thumbnail tier existed (no thumbnail object) takes the
      // exact same path.
      final removed = await _client.storage.from(_bucket).remove([
        sharedPhotoPath(photoId, ext),
        sharedThumbPath(photoId),
      ]);
      // `FileObject.name` on a delete response is `storage.objects.name`, i.e.
      // the full path WITHIN the bucket (`shared/<id><ext>`) — the same shape
      // the paths were sent in, and the shape `sharedPhotoPath` produces, so a
      // caller can compare directly.
      return {for (final object in removed) object.name};
    } on StorageException {
      // Best-effort/idempotent — an absent object, or a Storage outage, must
      // not fail the push. The empty set says "nothing is known to have been
      // removed"; see the contract on [SyncRemote.removeSharedPhoto].
      return const <String>{};
    }
  }

  @override
  Future<List<Map<String, dynamic>>> fetchProfiles(Set<String> uids) async {
    if (uids.isEmpty) return const [];
    final rows = await _client.from('profiles').select().inFilter('id', uids.toList());
    return [for (final row in rows) Map<String, dynamic>.from(row)];
  }

  @override
  Future<List<String>> fetchVisibleWallIds(List<String> ids) async {
    if (ids.isEmpty) return const [];
    final rows = await _client.from('walls').select('id').inFilter('id', ids);
    return [for (final row in rows) row['id'] as String];
  }
}
