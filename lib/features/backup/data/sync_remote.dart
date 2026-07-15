import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

/// The eight row-level tables this app syncs, in FK dependency order
/// (Areas → Sectors → Walls → Photos → Routes → Comments → Likes → Ascents)
/// — the same order [BackupRepository.importSnapshot] applies rows in, and
/// the same set of keys used in [BackupRepository.exportSnapshot]'s `tables`
/// map. Comments/Likes/Ascents were added for the community-features sync
/// extension: Comments and Likes attach to a Wall (`wallId`) and are shared
/// alongside their wall (see [fetchSharedTopos]); Ascents additionally
/// references a Route (`routeId`) and is a private per-user logbook —
/// pushed/pulled for its owner via [upsertOwnRows]/[fetchOwnRows] like every
/// other table, but DELIBERATELY NEVER included in [fetchSharedTopos]'s
/// return, even when its wall is shared.
const List<String> syncTableNames = [
  'areas',
  'sectors',
  'walls',
  'photos',
  'routes',
  'comments',
  'likes',
  'ascents',
];

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
abstract class SyncRemote {
  /// Upserts every row in [tablesToRows] (keyed by table name, see
  /// [syncTableNames]) as belonging to [uid], INCLUDING soft-deleted
  /// tombstones (`deletedAt` set) — a tombstone must propagate to other
  /// devices the same as any other row change. Idempotent: re-upserting the
  /// same rows is a no-op change-wise.
  Future<void> upsertOwnRows(
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
  /// DELIBERATELY EXCLUDES Ascents (a private per-user logbook) — an ascent
  /// is never returned here even when its wall is shared. Callers must not
  /// add an `'ascents'` key to the returned map.
  Future<Map<String, List<Map<String, dynamic>>>> fetchSharedTopos();

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
}

/// The shared-bucket object path for a photo with canonical id [photoId]
/// (see `CloudBackupService._canonicalPhotoId` for what "canonical" means —
/// a slice shares its original's id/file) and extension [ext] (including
/// the leading dot, e.g. `.jpg`).
String sharedPhotoPath(String photoId, String ext) => 'shared/$photoId$ext';

/// Real [SyncRemote], backed by the Supabase client.
///
/// STUB for this phase — there is no real `areas`/`sectors`/`walls`/
/// `photos`/`routes`/`comments`/`likes`/`ascents` table on any backend yet
/// (P0 is deferred), so this class is written to the shape those tables
/// SHOULD have but is untested against a real Supabase project. [SyncService]
/// itself is fully tested against `FakeSyncRemote` instead. TODO(P0 backend):
/// stand up the eight tables (RLS: `owner_id = auth.uid()` for row-level own-data access,
/// plus a `visibility = 'shared'`-scoped SELECT policy with no owner check
/// for the shared-topo query below), and the `shared/` Storage policy
/// described on [SyncRemote.uploadSharedPhoto].
class SupabaseSyncRemote implements SyncRemote {
  SupabaseSyncRemote(this._client);

  final SupabaseClient _client;

  static const String _bucket = 'topo-photos';

  @override
  Future<void> upsertOwnRows(
    String uid,
    Map<String, List<Map<String, dynamic>>> tablesToRows,
  ) async {
    for (final tableName in syncTableNames) {
      final rows = tablesToRows[tableName];
      if (rows == null || rows.isEmpty) continue;
      // TODO(P0 backend): drift's `toJson()` keys are camelCase
      // (`ownerId`, `wallId`, ...); confirm the real Postgres tables use
      // matching camelCase quoted columns, or add a camelCase<->snake_case
      // key-mapping layer here once the real schema is decided.
      await _client.from(tableName).upsert(rows);
    }
  }

  @override
  Future<Map<String, List<Map<String, dynamic>>>> fetchOwnRows(
    String uid,
  ) async {
    final result = <String, List<Map<String, dynamic>>>{};
    for (final tableName in syncTableNames) {
      final rows = await _client.from(tableName).select().eq('ownerId', uid);
      result[tableName] = [for (final row in rows) Map<String, dynamic>.from(row)];
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
    final wallRows = <Map<String, dynamic>>[
      for (final row in await _client.from('walls').select().eq('visibility', 'shared'))
        Map<String, dynamic>.from(row),
    ];
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

    final sectorRows = <Map<String, dynamic>>[
      for (final row in await _client.from('sectors').select().inFilter('id', sectorIds))
        Map<String, dynamic>.from(row),
    ];
    final areaIds = {for (final s in sectorRows) s['areaId'] as String}.toList();

    final areaRows = <Map<String, dynamic>>[
      for (final row in await _client.from('areas').select().inFilter('id', areaIds))
        Map<String, dynamic>.from(row),
    ];
    final photoRows = <Map<String, dynamic>>[
      for (final row in await _client.from('photos').select().inFilter('wallId', wallIds))
        Map<String, dynamic>.from(row),
    ];
    final routeRows = <Map<String, dynamic>>[
      for (final row in await _client.from('routes').select().inFilter('wallId', wallIds))
        Map<String, dynamic>.from(row),
    ];
    final commentRows = <Map<String, dynamic>>[
      for (final row in await _client.from('comments').select().inFilter('wallId', wallIds))
        Map<String, dynamic>.from(row),
    ];
    final likeRows = <Map<String, dynamic>>[
      for (final row in await _client.from('likes').select().inFilter('wallId', wallIds))
        Map<String, dynamic>.from(row),
    ];

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
}
