import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
/// table name (`areas`/`sectors`/`walls`/`photos`/`routes`, see
/// [syncTableNames]).
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
  Future<Map<String, List<Map<String, dynamic>>>> fetchSharedTopos();

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
  Future<void> uploadSharedPhoto({
    required String photoId,
    required String ext,
    required List<int> bytes,
  });

  /// Downloads the object at [objectPath] (already `shared/`-prefixed, see
  /// [sharedPhotoPath]), or `null` if no such object exists.
  Future<List<int>?> downloadSharedPhoto(String objectPath);

  /// Every object path that currently exists under the shared `shared/`
  /// folder — used to skip re-uploading a shared photo already there.
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

  /// Removes the object at the SHARED object path (`shared/<photoId><ext>`,
  /// see [sharedPhotoPath]) for a just-tombstoned photo. Best-effort/
  /// idempotent, mirroring [removePhoto].
  Future<void> removeSharedPhoto({
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
}

/// The shared-bucket object path for a photo with canonical id [photoId]
/// (see `CloudBackupService._canonicalPhotoId` for what "canonical" means —
/// a slice shares its original's id/file) and extension [ext] (including
/// the leading dot, e.g. `.jpg`).
String sharedPhotoPath(String photoId, String ext) => 'shared/$photoId$ext';

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

/// Filters [rows] down to those satisfying [hasRequiredSyncFields] for
/// [requiredFields] — every OTHER (valid) row in the same batch still
/// passes through untouched. A dropped row is logged via [debugPrint]
/// (tagged with [debugLabel], e.g. `'shared wall'`) rather than silently
/// vanishing, to aid diagnosing a real backend data-quality issue.
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

List<Map<String, dynamic>> filterValidSyncRows(
  Iterable<Map<String, dynamic>> rows,
  List<String> requiredFields, {
  required String debugLabel,
}) => partitionSyncRows(rows, requiredFields, debugLabel: debugLabel).valid;

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
/// LIVE: all eight tables (`areas`/`sectors`/`walls`/`photos`/`routes`/
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
    final result = <String, List<Map<String, dynamic>>>{};
    for (final tableName in syncTableNames) {
      final rows = await _client.from(tableName).select().eq('ownerId', uid);
      final mapped = [for (final row in rows) Map<String, dynamic>.from(row)];
      // Full required-NOT-NULL-field validation per table (sync-resilience
      // hardening) — was `const ['id']` only (P0 fix, #72), which caught a
      // missing primary key but let a row with any OTHER null NOT-NULL
      // column (e.g. a null `sortOrder`/`width`/`climbedAt`) through to
      // throw deeper in `<Table>.fromJson()`/`BackupRepository.
      // importSnapshot`. [syncRequiredFields] is the authoritative map (see
      // its doc); the `?? const ['id']` fallback is defensive only — every
      // name in [syncTableNames] has a matching entry there.
      result[tableName] = filterValidSyncRows(
        mapped,
        syncRequiredFields[tableName] ?? const ['id'],
        debugLabel: 'own $tableName',
      );
    }
    return result;
  }

  @override
  Future<Map<String, List<Map<String, dynamic>>>> fetchSharedTopos() async {
    // TODO(P0 backend): this is the naive client-side, multi-round-trip join
    // this phase's fake mirrors (walls -> sectors -> areas, plus
    // photos/routes/comments/likes by wallId). The real backend should
    // probably expose this as a single RPC/view instead — both for
    // round-trip cost and because RLS on `sectors`/`areas` has no
    // `visibility` column of its own to filter on; it would need to derive
    // "ancestor of a shared wall" the same way this client-side code does,
    // e.g. via a security-definer function.
    final rawWalls = <Map<String, dynamic>>[
      for (final row in await _client.from('walls').select().eq('visibility', 'shared'))
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

    final rawSectors = <Map<String, dynamic>>[
      for (final row in await _client.from('sectors').select().inFilter('id', sectorIds))
        Map<String, dynamic>.from(row),
    ];
    final sectorRows = filterValidSyncRows(
      rawSectors,
      const ['id', 'areaId'],
      debugLabel: 'shared sector',
    );
    final areaIds = {for (final s in sectorRows) s['areaId'] as String}.toList();

    final rawAreas = <Map<String, dynamic>>[
      for (final row in await _client.from('areas').select().inFilter('id', areaIds))
        Map<String, dynamic>.from(row),
    ];
    final areaRows = filterValidSyncRows(rawAreas, const ['id'], debugLabel: 'shared area');

    final rawPhotos = <Map<String, dynamic>>[
      for (final row in await _client.from('photos').select().inFilter('wallId', wallIds))
        Map<String, dynamic>.from(row),
    ];
    final photoRows = filterValidSyncRows(rawPhotos, const ['id'], debugLabel: 'shared photo');

    final rawRoutes = <Map<String, dynamic>>[
      for (final row in await _client.from('routes').select().inFilter('wallId', wallIds))
        Map<String, dynamic>.from(row),
    ];
    final routeRows = filterValidSyncRows(rawRoutes, const ['id'], debugLabel: 'shared route');

    final rawComments = <Map<String, dynamic>>[
      for (final row in await _client.from('comments').select().inFilter('wallId', wallIds))
        Map<String, dynamic>.from(row),
    ];
    final commentRows = filterValidSyncRows(rawComments, const ['id'], debugLabel: 'shared comment');

    final rawLikes = <Map<String, dynamic>>[
      for (final row in await _client.from('likes').select().inFilter('wallId', wallIds))
        Map<String, dynamic>.from(row),
    ];
    final likeRows = filterValidSyncRows(rawLikes, const ['id'], debugLabel: 'shared like');

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

    final rawWalls = <Map<String, dynamic>>[
      for (final row in await _client.from('walls').select().inFilter('id', wallIds))
        Map<String, dynamic>.from(row),
    ];
    final wallRows = filterValidSyncRows(
      rawWalls,
      const ['id', 'sectorId'],
      debugLabel: 'shared-ascent wall',
    );
    final sectorIds = {for (final w in wallRows) w['sectorId'] as String}.toList();

    final rawSectors = <Map<String, dynamic>>[
      for (final row in await _client.from('sectors').select().inFilter('id', sectorIds))
        Map<String, dynamic>.from(row),
    ];
    final sectorRows = filterValidSyncRows(
      rawSectors,
      const ['id', 'areaId'],
      debugLabel: 'shared-ascent sector',
    );
    final areaIds = {for (final s in sectorRows) s['areaId'] as String}.toList();

    final rawAreas = <Map<String, dynamic>>[
      for (final row in await _client.from('areas').select().inFilter('id', areaIds))
        Map<String, dynamic>.from(row),
    ];
    final areaRows = filterValidSyncRows(rawAreas, const ['id'], debugLabel: 'shared-ascent area');

    final rawRoutes = <Map<String, dynamic>>[
      for (final row in await _client.from('routes').select().inFilter('id', routeIds))
        Map<String, dynamic>.from(row),
    ];
    final routeRows = filterValidSyncRows(
      rawRoutes,
      const ['id', 'photoId'],
      debugLabel: 'shared-ascent route',
    );
    final photoIds = {for (final r in routeRows) r['photoId'] as String}.toList();

    final rawPhotos = <Map<String, dynamic>>[
      for (final row in await _client.from('photos').select().inFilter('id', photoIds))
        Map<String, dynamic>.from(row),
    ];
    final photoRows = filterValidSyncRows(rawPhotos, const ['id'], debugLabel: 'shared-ascent photo');

    return {
      'areas': areaRows,
      'sectors': sectorRows,
      'walls': wallRows,
      'photos': photoRows,
      'routes': routeRows,
      'ascents': ascentRows,
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

  @override
  Future<Set<String>> listPhotoObjectPaths(String uid) async {
    final files = await _client.storage.from(_bucket).list(path: uid);
    return {for (final file in files) '$uid/${file.name}'};
  }

  @override
  Future<void> uploadSharedPhoto({
    required String photoId,
    required String ext,
    required List<int> bytes,
  }) async {
    await _client.storage
        .from(_bucket)
        .uploadBinary(
          sharedPhotoPath(photoId, ext),
          Uint8List.fromList(bytes),
          fileOptions: const FileOptions(upsert: true),
        );
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
    final files = await _client.storage.from(_bucket).list(path: 'shared');
    return {for (final file in files) 'shared/${file.name}'};
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
  Future<void> removeSharedPhoto({
    required String photoId,
    required String ext,
  }) async {
    try {
      await _client.storage.from(_bucket).remove([sharedPhotoPath(photoId, ext)]);
    } on StorageException {
      // Best-effort/idempotent.
    }
  }

  @override
  Future<List<Map<String, dynamic>>> fetchProfiles(Set<String> uids) async {
    if (uids.isEmpty) return const [];
    final rows = await _client.from('profiles').select().inFilter('id', uids.toList());
    return [for (final row in rows) Map<String, dynamic>.from(row)];
  }
}
