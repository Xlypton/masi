import 'package:supabase_flutter/supabase_flutter.dart';

import '../../backup/data/sync_remote.dart' show sharedPhotoPath;

/// Cloud-thumbnail companions of a published photo live directly under this
/// prefix — mirrors `SyncRemote.sharedThumbPath`'s `shared/thumbs/<id>.jpg`
/// convention (`lib/features/backup/data/sync_remote.dart`, currently only on
/// the sibling `perf/photo-pipeline-and-boot` branch, not yet merged with this
/// one). Duplicated here rather than imported, for the same reason
/// [SupabaseModerationRemote._photoBucket] duplicates the bucket name instead
/// of importing it (see this file's header) — and, right now, for the more
/// concrete reason that the symbol is not reachable from here at all.
const String _sharedThumbPrefix = 'shared/thumbs/';

/// The published-thumbnail object path for [photoId] — the small companion
/// object a takedown must remove alongside the full-resolution original at
/// [sharedPhotoPath]. Thumbnails are always `.jpg` regardless of the
/// original's extension (the thumbnail pipeline re-encodes to JPEG), which is
/// why this needs no `ext` parameter the way [sharedPhotoPath] does.
String _sharedThumbPath(String photoId) => '$_sharedThumbPrefix$photoId.jpg';

/// Whether [objectPath] is a published-thumbnail companion (lives under
/// `shared/thumbs/`) rather than an original.
///
/// This is the whole basis for keeping a takedown's REPORTED count about
/// PHOTOS, not raw Storage objects: see
/// [SupabaseModerationRemote.removePublishedPhotoObjects] and
/// `moderation_providers.dart`'s `TakedownResult`/`AdminDeleteResult`.
bool isSharedThumbObjectPath(String objectPath) =>
    objectPath.startsWith(_sharedThumbPrefix);

/// The Storage object paths a takedown should request for [wallId]'s
/// published photos, given [rows] — raw `photos` table rows already scoped to
/// the wall (the shape `SupabaseModerationRemote.publishedPhotoObjects`
/// selects: `id, localPath, parentPhotoId, deletedAt`).
///
/// The pure decision half of
/// [SupabaseModerationRemote.publishedPhotoObjects], split out so the
/// enumeration logic — in particular, that BOTH the original and its
/// thumbnail companion are requested for every qualifying row — is testable
/// without a Supabase client.
///
/// Two paths per qualifying row: the full-resolution original at
/// [sharedPhotoPath], and its cloud-thumbnail companion at [_sharedThumbPath].
/// The thumbnail is requested UNCONDITIONALLY, even for a photo published
/// before the thumbnail tier existed and which therefore has no such object —
/// see [isSharedThumbObjectPath] and
/// [SupabaseModerationRemote.removePublishedPhotoObjects] for why that must
/// not be conflated with a failed delete of the original.
Set<String> publishedPhotoObjectPathsFor(
  Iterable<Map<String, dynamic>> rows,
) {
  final paths = <String>{};
  for (final row in rows) {
    // A slice points at its original's file, so its object is already
    // covered by that original's row — see
    // [SupabaseModerationRemote.publishedPhotoObjects].
    if (row['parentPhotoId'] != null) continue;
    if (row['deletedAt'] != null) continue;
    final id = row['id'];
    final localPath = row['localPath'];
    if (id is! String || localPath is! String) continue;
    final dot = localPath.lastIndexOf('.');
    // The extension is part of the object NAME, so a row without one cannot
    // be turned into a path to delete. Skipped rather than guessed: deleting
    // `shared/<id>` when the object is `shared/<id>.jpg` would report a
    // success that removed nothing.
    if (dot < 0 || dot == localPath.length - 1) continue;
    paths.add(sharedPhotoPath(id, localPath.substring(dot)));
    paths.add(_sharedThumbPath(id));
  }
  return paths;
}

/// How many of [objectPaths] are ORIGINALS — i.e. excludes cloud-thumbnail
/// companions (see [isSharedThumbObjectPath]).
///
/// This is what a takedown's admin-facing count must mean. Both
/// `TakedownService.remove` and `AdminDeleteService.deleteTopo`
/// (`moderation_providers.dart`) surface `requested - removed` to the admin as
/// "N image(s) could not be removed" — the count has to mean "images", not
/// "Storage objects". A thumbnail is a best-effort derivative of the publish
/// pipeline, written best-effort and possibly not written at all for a photo
/// published before the thumbnail tier existed (see
/// [SupabaseModerationRemote.removePublishedPhotoObjects]): requesting one
/// that was never there must not make a fully-successful takedown of the
/// original read as "1 of 2 removed".
int originalPhotoRequestCount(Iterable<String> objectPaths) =>
    objectPaths.where((path) => !isSharedThumbObjectPath(path)).length;

/// Reads moderation state from the cloud.
///
/// Deliberately a SEPARATE seam from `SyncRemote` rather than another method
/// on it, for two reasons:
///
///  1. The sync engine must not know this data exists (COMMUNITY_PLAN.md
///     guardrail G-1). `SyncRemote` is the push/pull engine for the user's
///     OWN rows; moderation state is server-owned and travels one way only.
///     Putting a fetch on `SyncRemote` would put moderation one careless
///     `syncTableNames` edit away from being pushed back up.
///  2. `SyncRemote` has seven implementations across lib and test. A new
///     abstract member there is seven edits and seven fakes that have to
///     pretend to understand moderation. This seam has one implementation
///     and one fake.
///
/// There is NO write method here, and there is not meant to be one. Every
/// mutation goes through a `SECURITY DEFINER` RPC so the action and its
/// audit-log entry cannot diverge, and the server refuses direct writes
/// anyway — `public.wall_moderation` has a SELECT policy and no write policy
/// at all.
abstract class ModerationRemote {
  /// Moderation rows for [wallIds], as raw column maps.
  ///
  /// Returns only what RLS permits: a published topo's row is readable by
  /// anyone, a non-published one only by its owner or an admin. A wall whose
  /// row is simply absent from the result is NOT an error — it means "you
  /// may not see this one", which callers treat exactly like "no information",
  /// never like "not moderated".
  ///
  /// Never throws: any network or PostgREST failure resolves to an empty
  /// list, because a moderation banner failing to load must not be able to
  /// break the screen it decorates.
  Future<List<Map<String, dynamic>>> fetchWallModeration(Set<String> wallIds);

  /// Whether the signed-in user is an admin.
  ///
  /// A read of `admins`, whose SELECT policy is `"userId" = auth.uid()` — so
  /// this answers "am I one?" without exposing the list. `false` on any
  /// failure, including signed-out: the admin surface must fail closed.
  ///
  /// This is a UI hint ONLY. Every admin RPC re-checks membership server-side,
  /// so a client that lies to itself gains nothing.
  Future<bool> isAdmin();

  /// Pending submissions, oldest first, via the `moderation_queue` RPC.
  ///
  /// Throws if the caller is not an admin — deliberately, unlike the
  /// best-effort reads above. A queue that silently renders empty for an
  /// admin whose session has expired is worse than an error: it says "nothing
  /// to review" when the truth is "we could not ask".
  Future<List<Map<String, dynamic>>> fetchQueue({int limit});

  /// Published topos whose owner has stopped answering suggestions (C-11).
  ///
  /// An owner who abandons the app freezes their topos forever: suggestions
  /// pile up, nothing is applied, and because owner approval is final (C-5c)
  /// the community cannot fix an error everyone can see.
  ///
  /// Admin-only and throws like [fetchQueue], for the same reason: an empty
  /// list that silently means "we could not ask" reads as "nothing is
  /// abandoned", which is exactly the wrong conclusion.
  ///
  /// A topo qualifies only when its oldest pending suggestion predates
  /// [inactiveDays] AND the owner has done nothing at all since then. That
  /// second condition is what keeps the list meaningful — an owner who simply
  /// disagrees with a suggestion and leaves it open is not abandoning anything.
  Future<List<Map<String, dynamic>>> fetchAbandoned({
    int inactiveDays,
    int limit,
  });

  /// Published topos that changed shape after they were approved (C-5d).
  ///
  /// Newest first, unlike [fetchQueue]. Nobody is waiting on these — it is a
  /// watch list, and the topo that changed an hour ago is the one that might
  /// still be being changed right now.
  ///
  /// Admin-only and throws like [fetchQueue]: an empty list that silently
  /// means "we could not ask" reads as "nothing has been tampered with".
  Future<List<Map<String, dynamic>>> fetchMaterialChanges({int limit});

  /// Marks a material-change notice as looked at. Admin-only, idempotent.
  ///
  /// Deliberately has no verdict parameter. A material change is not an
  /// accusation and nothing follows from clearing it; if the change WAS
  /// vandalism, reverting (C-8) and taking down (C-7) are the actions that
  /// carry a consequence, and both already exist.
  Future<void> resolveMaterialChange(String noticeId);

  /// The standing deletion request for [wallId], or null if there is none.
  ///
  /// Read on demand, at the moment the owner reaches for Delete, rather than
  /// mirrored locally. Deletion is meant to be rare, so this is one read on a
  /// rare path — mirroring it would put a table and a sync rule in the way of
  /// every ordinary write for a state almost no topo is ever in.
  ///
  /// Returns null on failure too. The caller's fallback is to explain that the
  /// topo cannot be deleted yet, which is the truth whatever the reason.
  Future<Map<String, dynamic>?> deletionRequestFor(String wallId);

  /// Asks an admin to approve deleting [wallId]. Owner-only, published or
  /// taken-down topos only, and idempotent — asking twice returns the same
  /// request rather than queueing a duplicate.
  Future<String> requestDeletion(String wallId, {String? reason});

  /// Pending deletion requests, oldest first. Admin-only, throws like
  /// [fetchQueue] — somebody is waiting on each of these.
  Future<List<Map<String, dynamic>>> fetchDeletionRequests({int limit});

  /// Approves or rejects one. Admin-only. Approving grants PERMISSION; the
  /// owner still performs the deletion, so an admin's mis-tap destroys nothing.
  Future<String> reviewDeletion({
    required String requestId,
    required bool approve,
    String? note,
  });

  /// Approves or rejects a pending topo. Admin-only, enforced server-side.
  /// Returns the resulting state. [reason] is shown to the owner on rejection.
  Future<String> reviewTopo({
    required String wallId,
    required bool approve,
    String? reason,
  });

  /// Takes down an already-published topo. Admin-only. The content is
  /// retained, not destroyed (COMMUNITY_PLAN.md §3.3), so this is reversible.
  Future<void> removeTopo({required String wallId, String? reason});

  /// The Storage object names of [wallId]'s PUBLISHED photo copies — the
  /// full-resolution original at `shared/<canonicalPhotoId><ext>`, PLUS its
  /// cloud-thumbnail companion at `shared/thumbs/<canonicalPhotoId>.jpg`, one
  /// pair per original photo (W-2, and its thumbnail-tier follow-up: the
  /// thumbnail tier shipped on a sibling branch without this enumeration
  /// being updated to match, which is the gap this pair of doc comments and
  /// [originalPhotoRequestCount] exist to close).
  ///
  /// The thumbnail path is requested UNCONDITIONALLY, even for a photo
  /// published before the thumbnail tier existed and which therefore has no
  /// such object — see [removePublishedPhotoObjects] for why that must not be
  /// conflated with a failed delete of the original. See
  /// [publishedPhotoObjectPathsFor] for the actual (testable) enumeration
  /// logic.
  ///
  /// **Must be called BEFORE [removeTopo].** The shared-photo SELECT policy is
  /// `is_wall_public("wallId")`, and a takedown makes that false, so afterwards
  /// even an admin cannot enumerate what there was to delete. Reading first is
  /// not an optimisation; it is the only order that works.
  ///
  /// Slices are excluded: a slice shares its original's single on-disk file and
  /// therefore its single Storage object, so listing it would produce a
  /// duplicate delete of a path already covered. That mirrors the uploader's own
  /// canonical-id rule.
  ///
  /// Never throws — an enumeration failure returns empty and the caller reports
  /// having removed nothing, which is honest. It must never take down the
  /// moderation decision itself.
  Future<List<String>> publishedPhotoObjects(String wallId);

  /// Deletes [objectPaths] from the public prefix, returning how many
  /// ORIGINALS were ACTUALLY removed.
  ///
  /// [objectPaths] mixes two kinds of object, as built by
  /// [publishedPhotoObjectPathsFor]: the full-resolution original at
  /// `shared/<id><ext>`, and its cloud-thumbnail companion at
  /// `shared/thumbs/<id>.jpg` (see [isSharedThumbObjectPath]). They are
  /// deliberately NOT counted the same way, and both are still removed.
  ///
  /// THE RETURNED COUNT IS ABOUT ORIGINALS ONLY — see
  /// [originalPhotoRequestCount]. The count is the point (below), and both
  /// callers (`TakedownService.remove`, `AdminDeleteService.deleteTopo` in
  /// `moderation_providers.dart`) surface `requested - removed` to the admin
  /// as "N image(s) could not be removed", so the count has to mean "images",
  /// not "Storage objects". A thumbnail is a best-effort derivative of the
  /// publish pipeline and may not exist at all for a photo published before
  /// the thumbnail tier existed — requesting one that was never there must
  /// not make a fully-successful takedown of the ORIGINAL read as "1 of 2
  /// removed". So thumbnails ARE removed (nothing may outlive the original it
  /// was derived from — the whole point of this fix) but their removal is
  /// best-effort and kept OUT of the returned count.
  ///
  /// The count is the point for ORIGINALS, and it is why this does not reuse
  /// `SyncRemote.removeSharedPhoto` (which returns void and swallows). A
  /// Storage delete that RLS filtered to nothing returns HTTP 200 and an empty
  /// list — indistinguishable from success unless you count. That exact
  /// false-success hid W-2: there was no DELETE policy for `shared/` at all, so
  /// every removal since the feature shipped silently removed nothing. That
  /// detectability is preserved HERE for originals specifically: a genuinely
  /// filtered/failed delete of an original still shows up as a shortfall,
  /// because originals and thumbnails are removed — and counted — separately.
  ///
  /// Never throws; a failure removing originals reports 0. A failure removing
  /// thumbnails is swallowed entirely (best-effort, see above).
  Future<int> removePublishedPhotoObjects(List<String> objectPaths);

  /// Soft-deletes ANY topo, whoever owns it, and everything hanging off it —
  /// photos, routes, and every ascent, comment and like on the wall.
  ///
  /// Admin-only, enforced by `admin_delete_topo`'s own `is_admin()` check. The
  /// RPC is the ONLY path to this: the local repositories refuse to write a row
  /// the signed-in user does not own, and the push query filters on
  /// `ownerId = uid`, so there is no client-side route to a foreign delete and
  /// there is not meant to be one.
  ///
  /// Returns the deletion instant in epoch ms — the same `deletedAt` stamped on
  /// every row of the sweep, which is what [adminRestoreTopo] later matches on.
  /// Deleting an already-deleted topo returns its EXISTING instant and writes
  /// no second audit-log entry, so a double tap costs nothing.
  ///
  /// Throws on failure, deliberately: an admin who believes they removed
  /// something they did not is the worst outcome this feature has.
  Future<int?> adminDeleteTopo({required String wallId, String? reason});

  /// Undoes one [adminDeleteTopo] sweep, putting back exactly the rows that
  /// sweep took — matched on the wall's own `deletedAt` instant, so rows the
  /// OWNER deleted themselves months earlier stay deleted.
  ///
  /// Returns the restore instant, or null when the topo was not deleted (a
  /// double tap, which is not an error).
  ///
  /// Note what this does NOT put back: the published photo BYTES.
  /// [AdminDeleteService.deleteTopo] removes the world-readable `shared/` copies
  /// from Storage, and Storage has no undelete. That is self-healing rather than
  /// terminal — push re-reads and re-sends its own rows every time (D-4, no
  /// outbox), so the owner's next sync re-uploads the shared copy from the
  /// private original, which is never touched.
  Future<int?> adminRestoreTopo({required String wallId, String? reason});

  /// Soft-deletes ANY ascent and its thread — the comments and likes on it go
  /// too, because a comment whose ascent is gone is unreachable text that still
  /// notifies people and still counts.
  ///
  /// Admin-only, returns the deletion instant, idempotent, throws on failure —
  /// all as [adminDeleteTopo].
  Future<int?> adminDeleteAscent({required String ascentId, String? reason});

  /// Soft-deletes ANY single comment, in either thread (a topo comment carries
  /// `wallId`, an ascent comment carries `ascentId`; this needs to know
  /// neither).
  ///
  /// This is the finest-grained control an admin has, and the one the takedown
  /// path could never offer: `remove_topo` hides a whole topo to deal with one
  /// abusive line of text.
  Future<int?> adminDeleteComment({required String commentId, String? reason});

  /// Starts the ten-day withdrawal clock on a published topo (C-3). Returns
  /// the epoch-ms instant the clock started from — which for a second call is
  /// the ORIGINAL one, not a fresh one: asking twice must not silently cost
  /// the owner ten more days.
  ///
  /// Owner-or-admin, enforced server-side. Throws if the topo is not
  /// published, because a client showing a countdown for something that was
  /// never public is worse than an error.
  Future<int?> requestWithdrawal(String wallId);

  /// Stops the clock, and returns the resulting state.
  ///
  /// Two outcomes, decided by the server rather than here: cancelling a
  /// running withdrawal returns `published` (nothing happened), while
  /// cancelling one whose ten days already elapsed is a RE-SUBMISSION and
  /// returns `pending`. The topo left public view; coming back goes through
  /// review again.
  Future<String> cancelWithdrawal(String wallId);
}

/// The real [ModerationRemote], backed by the anon/publishable Supabase
/// client — the same one the rest of the app uses. Nothing here needs
/// elevated access: RLS decides what comes back.
class SupabaseModerationRemote implements ModerationRemote {
  SupabaseModerationRemote(this._client);

  final SupabaseClient _client;

  /// Same bucket `SyncRemote` uploads to. Duplicated rather than imported
  /// because the two seams are deliberately independent (see this file's
  /// header) and one shared string is not worth coupling them over.
  static const String _photoBucket = 'topo-photos';

  /// Chunk size for the `IN` filter. PostgREST puts the id list in the query
  /// string, so an unbounded list eventually exceeds the URL length limit and
  /// fails as an opaque 414 rather than as anything diagnosable.
  static const int _chunkSize = 100;

  @override
  Future<List<Map<String, dynamic>>> fetchWallModeration(
    Set<String> wallIds,
  ) async {
    if (wallIds.isEmpty) return const [];
    final ids = wallIds.toList(growable: false);
    final rows = <Map<String, dynamic>>[];
    try {
      for (var i = 0; i < ids.length; i += _chunkSize) {
        final chunk = ids.sublist(
          i,
          i + _chunkSize > ids.length ? ids.length : i + _chunkSize,
        );
        final response = await _client
            .from('wall_moderation')
            .select()
            .inFilter('wallId', chunk);
        for (final row in response) {
          rows.add(Map<String, dynamic>.from(row));
        }
      }
    } catch (_) {
      // Best-effort by contract (see the abstract doc). A partial result from
      // an earlier chunk is still returned: knowing the state of some topos
      // beats knowing none, and the caller merges rather than replaces.
      return rows;
    }
    return rows;
  }

  @override
  Future<bool> isAdmin() async {
    try {
      final rows = await _client.from('admins').select('userId').limit(1);
      return rows.isNotEmpty;
    } catch (_) {
      // Signed out, offline, or RLS refused. All of them mean "do not show
      // the admin surface", and none of them is worth an error to a user who
      // was never an admin in the first place.
      return false;
    }
  }

  @override
  Future<List<Map<String, dynamic>>> fetchQueue({int limit = 50}) async {
    final rows = await _client.rpc<dynamic>(
      'moderation_queue',
      params: {'limit_count': limit},
    );
    if (rows is! List) return const [];
    return [for (final row in rows) Map<String, dynamic>.from(row as Map)];
  }

  @override
  Future<List<Map<String, dynamic>>> fetchAbandoned({
    int inactiveDays = 90,
    int limit = 50,
  }) async {
    final rows = await _client.rpc<dynamic>(
      'abandoned_topos',
      params: {'inactive_days': inactiveDays, 'limit_count': limit},
    );
    if (rows is! List) return const [];
    return [for (final row in rows) Map<String, dynamic>.from(row as Map)];
  }

  @override
  Future<List<Map<String, dynamic>>> fetchMaterialChanges({
    int limit = 50,
  }) async {
    final rows = await _client.rpc<dynamic>(
      'material_changes',
      params: {'limit_count': limit},
    );
    if (rows is! List) return const [];
    return [for (final row in rows) Map<String, dynamic>.from(row as Map)];
  }

  @override
  Future<void> resolveMaterialChange(String noticeId) async {
    await _client.rpc<dynamic>(
      'resolve_material_change',
      params: {'notice_id': noticeId},
    );
  }

  @override
  Future<Map<String, dynamic>?> deletionRequestFor(String wallId) async {
    try {
      final rows = await _client
          .from('deletion_requests')
          .select()
          .eq('wallId', wallId)
          .order('createdAt', ascending: false)
          .limit(1);
      if (rows.isEmpty) return null;
      return Map<String, dynamic>.from(rows.first);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String> requestDeletion(String wallId, {String? reason}) async {
    final result = await _client.rpc<dynamic>(
      'request_deletion',
      params: {'wall_id': wallId, 'reason': reason},
    );
    return result is String ? result : '';
  }

  @override
  Future<List<Map<String, dynamic>>> fetchDeletionRequests({
    int limit = 50,
  }) async {
    final rows = await _client.rpc<dynamic>(
      'deletion_requests_queue',
      params: {'limit_count': limit},
    );
    if (rows is! List) return const [];
    return [for (final row in rows) Map<String, dynamic>.from(row as Map)];
  }

  @override
  Future<String> reviewDeletion({
    required String requestId,
    required bool approve,
    String? note,
  }) async {
    final result = await _client.rpc<dynamic>(
      'review_deletion',
      params: {'request_id': requestId, 'approve': approve, 'note': note},
    );
    return result is String ? result : (approve ? 'approved' : 'rejected');
  }

  @override
  Future<String> reviewTopo({
    required String wallId,
    required bool approve,
    String? reason,
  }) async {
    final result = await _client.rpc<dynamic>(
      'review_topo',
      params: {'wall_id': wallId, 'approve': approve, 'reason': reason},
    );
    return result is String ? result : (approve ? 'published' : 'rejected');
  }

  @override
  Future<void> removeTopo({required String wallId, String? reason}) async {
    await _client.rpc<dynamic>(
      'remove_topo',
      params: {'wall_id': wallId, 'reason': reason},
    );
  }

  @override
  Future<List<String>> publishedPhotoObjects(String wallId) async {
    try {
      final rows = await _client
          .from('photos')
          .select('id, localPath, parentPhotoId, deletedAt')
          .eq('wallId', wallId);
      return publishedPhotoObjectPathsFor(
        rows.map(Map<String, dynamic>.from),
      ).toList();
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<int> removePublishedPhotoObjects(List<String> objectPaths) async {
    if (objectPaths.isEmpty) return 0;

    final originals = [
      for (final path in objectPaths)
        if (!isSharedThumbObjectPath(path)) path,
    ];
    final thumbs = [
      for (final path in objectPaths)
        if (isSharedThumbObjectPath(path)) path,
    ];

    var removedOriginals = 0;
    if (originals.isNotEmpty) {
      try {
        final removed = await _client.storage
            .from(_photoBucket)
            .remove(originals);
        removedOriginals = removed.length;
      } catch (_) {
        removedOriginals = 0;
      }
    }

    // Best-effort, deliberately uncounted — see this method's doc comment on
    // the abstract class. A missing or failed thumbnail delete must never be
    // observable as a failed takedown.
    if (thumbs.isNotEmpty) {
      try {
        await _client.storage.from(_photoBucket).remove(thumbs);
      } catch (_) {
        // Swallowed — best-effort.
      }
    }

    return removedOriginals;
  }

  @override
  Future<int?> adminDeleteTopo({
    required String wallId,
    String? reason,
  }) async => _epochMs(
    await _client.rpc<dynamic>(
      'admin_delete_topo',
      params: {'wall_id': wallId, 'reason': reason},
    ),
  );

  @override
  Future<int?> adminRestoreTopo({
    required String wallId,
    String? reason,
  }) async => _epochMs(
    await _client.rpc<dynamic>(
      'admin_restore_topo',
      params: {'wall_id': wallId, 'reason': reason},
    ),
  );

  @override
  Future<int?> adminDeleteAscent({
    required String ascentId,
    String? reason,
  }) async => _epochMs(
    await _client.rpc<dynamic>(
      'admin_delete_ascent',
      params: {'ascent_id': ascentId, 'reason': reason},
    ),
  );

  @override
  Future<int?> adminDeleteComment({
    required String commentId,
    String? reason,
  }) async => _epochMs(
    await _client.rpc<dynamic>(
      'admin_delete_comment',
      params: {'comment_id': commentId, 'reason': reason},
    ),
  );

  /// A `bigint` epoch-ms out of PostgREST, whatever shape the JSON arrived in.
  ///
  /// Postgres `bigint` does not fit a JavaScript number, so PostgREST serialises
  /// it as a JSON STRING on some paths and a number on others — and on web the
  /// Dart value lands as `double` rather than `int`. Parsing all three is not
  /// defensive padding: an `int` cast here would throw on wasm for a value the
  /// server sent correctly. Mirrors [requestWithdrawal]'s existing switch.
  static int? _epochMs(dynamic result) => switch (result) {
    final int v => v,
    final num v => v.toInt(),
    final String v => int.tryParse(v),
    _ => null,
  };

  @override
  Future<int?> requestWithdrawal(String wallId) async {
    final result = await _client.rpc<dynamic>(
      'request_withdrawal',
      params: {'wall_id': wallId},
    );
    return switch (result) {
      final int v => v,
      final num v => v.toInt(),
      final String v => int.tryParse(v),
      _ => null,
    };
  }

  @override
  Future<String> cancelWithdrawal(String wallId) async {
    final result = await _client.rpc<dynamic>(
      'cancel_withdrawal',
      params: {'wall_id': wallId},
    );
    // Falling back to `published` rather than to something alarming: the RPC
    // only ever returns from the happy path, and the common cancellation is
    // the one that leaves the topo exactly as public as it was.
    return result is String ? result : 'published';
  }
}
