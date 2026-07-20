import 'package:drift/drift.dart';

import '../../../core/db/app_database.dart' as db;
import 'photo_files.dart';

/// Domain-level view of a `Photos` row, independent of the generated drift
/// data class.
class PhotoRef {
  const PhotoRef({
    required this.id,
    required this.wallId,
    required this.kind,
    required this.localPath,
    required this.width,
    required this.height,
    this.parentPhotoId,
    this.sortOrder = 0,
    this.isPrimary = false,
  });

  final String id;
  final String wallId;
  final String kind;
  final String localPath;
  final int width;
  final int height;
  final String? parentPhotoId;

  /// Display order among a wall's live `kind:'original'` photos (the
  /// multi-photo strip). Defaults to `0` (matching `Photos.sortOrder`'s
  /// column default) so existing call sites that don't care about ordering
  /// (single-photo walls) don't need to pass it.
  final int sortOrder;

  /// Whether this is the wall's PRIMARY original (see `Photos.isPrimary`'s
  /// doc). Defaults to `false`.
  final bool isPrimary;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is PhotoRef &&
        other.id == id &&
        other.wallId == wallId &&
        other.kind == kind &&
        other.localPath == localPath &&
        other.width == width &&
        other.height == height &&
        other.parentPhotoId == parentPhotoId &&
        other.sortOrder == sortOrder &&
        other.isPrimary == isPrimary;
  }

  @override
  int get hashCode => Object.hash(
        id,
        wallId,
        kind,
        localPath,
        width,
        height,
        parentPhotoId,
        sortOrder,
        isPrimary,
      );

  @override
  String toString() =>
      'PhotoRef(id: $id, wallId: $wallId, kind: $kind, localPath: '
      '$localPath, width: $width, height: $height, parentPhotoId: '
      '$parentPhotoId, sortOrder: $sortOrder, isPrimary: $isPrimary)';
}

/// Reads and writes `Photos` rows.
class PhotoRepository {
  PhotoRepository(
    this._db, {
    required this.nowMs,
    this.currentUid = _noUid,
    PhotoFiles? photoFiles,
  }) : _photoFiles = photoFiles ?? PhotoFiles();

  final db.AppDatabase _db;
  final int Function() nowMs;

  /// The Supabase Auth uid of the signed-in user (or `null` if signed out),
  /// read lazily at INSERT time to stamp a newly-attached photo's `ownerId`.
  /// Defaults to always-`null` so existing constructors/tests keep their
  /// pre-sync-pivot signed-out behavior unchanged.
  final String? Function() currentUid;

  static String? _noUid() => null;

  /// Resolves a stored `localPath` (which may be the canonical relative
  /// form, or a legacy/stale absolute one — see [PhotoFiles.resolvePhotoPath])
  /// to an absolute path, self-healing the DB row when a stale absolute path
  /// is found to have moved (container rotation). Injectable so tests can
  /// point it at a temp directory without a `path_provider` platform fake;
  /// defaults to the real app-documents-backed [PhotoFiles].
  final PhotoFiles _photoFiles;

  /// Loads the wall's PRIMARY non-deleted `kind: 'original'` photo, or
  /// `null` if it has none.
  ///
  /// #46 fix: this used to be a `getSingleOrNull()` scoped only to
  /// `wallId`/`kind`, which THROWS the moment a wall has 2+ live originals
  /// (a shape `attachPhotoToWall` could always produce, since it never
  /// superseded a wall's previous original) — the canvas swallowed that
  /// throw, producing a blank canvas on reopen. Now ordered `isPrimary
  /// DESC, createdAt DESC` with `LIMIT 1` via [_liveOriginalsQuery], so it
  /// NEVER throws regardless of how many live originals exist: it returns
  /// the one flagged primary, or (if none is — e.g. a fresh row inserted
  /// outside [LibraryCrudRepository.attachPhotoToWall]'s single-primary
  /// bookkeeping) the newest by `createdAt`.
  Future<PhotoRef?> loadOriginal(String wallId) async {
    final row = await (_liveOriginalsQuery(wallId)..limit(1)).getSingleOrNull();
    return row == null ? null : await _rowToRef(row);
  }

  /// Every live (non-deleted) `kind:'original'` photo on [wallId], ordered
  /// by [db.Photos.sortOrder] ascending, then `createdAt` ascending —
  /// backs the multi-photo strip UI. See [watchWallOriginals] for the
  /// reactive/stream form.
  Future<List<PhotoRef>> loadOriginals(String wallId) async {
    final rows = await (_db.select(_db.photos)
          ..where(
            (t) =>
                t.wallId.equals(wallId) &
                t.kind.equals('original') &
                t.deletedAt.isNull(),
          )
          ..orderBy([
            (t) => OrderingTerm(expression: t.sortOrder),
            (t) => OrderingTerm(expression: t.createdAt),
          ]))
        .get();
    return Future.wait([for (final row in rows) _rowToRef(row)]);
  }

  /// Reactive (auto-updating) form of [loadOriginals] — backs
  /// `wallOriginalsProvider` so the multi-photo strip UI updates live as
  /// photos are attached/reordered/deleted.
  Stream<List<PhotoRef>> watchWallOriginals(String wallId) {
    return (_db.select(_db.photos)
          ..where(
            (t) =>
                t.wallId.equals(wallId) &
                t.kind.equals('original') &
                t.deletedAt.isNull(),
          )
          ..orderBy([
            (t) => OrderingTerm(expression: t.sortOrder),
            (t) => OrderingTerm(expression: t.createdAt),
          ]))
        .watch()
        .asyncMap((rows) => Future.wait([for (final row in rows) _rowToRef(row)]));
  }

  /// Shared query backing [loadOriginal]: every live original on [wallId],
  /// ordered so the PRIMARY one (if any) sorts first, tiebroken by the
  /// newest `createdAt` (then `id` for full determinism when `createdAt`
  /// itself ties). Callers add their own `..limit(1)`/etc.
  SimpleSelectStatement<db.$PhotosTable, db.Photo> _liveOriginalsQuery(
    String wallId,
  ) {
    return _db.select(_db.photos)
      ..where(
        (t) =>
            t.wallId.equals(wallId) &
            t.kind.equals('original') &
            t.deletedAt.isNull(),
      )
      ..orderBy([
        (t) => OrderingTerm(expression: t.isPrimary, mode: OrderingMode.desc),
        (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
        (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc),
      ]);
  }

  /// Sets [photoId] as [wallId]'s PRIMARY original (`isPrimary = true`) and
  /// clears the flag on every one of the wall's other live originals —
  /// enforcing the single-primary-per-wall invariant. Bumps `updatedAt`/
  /// `dirty` on every row touched. No-op (still bumps nothing) if [photoId]
  /// doesn't resolve to a live original on [wallId] — the WHERE clauses
  /// below simply match zero/one row in that case.
  Future<void> setPrimaryPhoto(String wallId, String photoId) async {
    final now = nowMs();
    await _db.transaction(() async {
      await (_db.update(_db.photos)..where(
            (t) =>
                t.wallId.equals(wallId) &
                t.kind.equals('original') &
                t.deletedAt.isNull() &
                t.id.equals(photoId).not(),
          ))
          .write(
            db.PhotosCompanion(
              isPrimary: const Value(false),
              updatedAt: Value(now),
              dirty: const Value(true),
            ),
          );

      await (_db.update(_db.photos)..where(
            (t) =>
                t.wallId.equals(wallId) &
                t.kind.equals('original') &
                t.deletedAt.isNull() &
                t.id.equals(photoId),
          ))
          .write(
            db.PhotosCompanion(
              isPrimary: const Value(true),
              updatedAt: Value(now),
              dirty: const Value(true),
            ),
          );
    });
  }

  /// Soft-deletes the original photo [photoId] AND cascades the soft-delete
  /// to its overlay routes (`Routes` rows whose `photoId == photoId`) and
  /// any child `Photos` rows (`parentPhotoId == photoId`) — deleting a
  /// photo takes its whole per-photo overlay with it. If
  /// [photoId] was the wall's primary and other live originals remain on
  /// the same wall, promotes the newest remaining one (`createdAt` DESC) to
  /// primary, preserving the single-primary invariant. Runs in one
  /// transaction. No-op if [photoId] doesn't resolve to a live photo.
  Future<void> deleteOriginalPhoto(String photoId) async {
    await _db.transaction(() async {
      final photo = await (_db.select(_db.photos)
            ..where((t) => t.id.equals(photoId) & t.deletedAt.isNull()))
          .getSingleOrNull();
      if (photo == null) return;

      final now = nowMs();

      await (_db.update(
        _db.photos,
      )..where((t) => t.id.equals(photoId))).write(
        db.PhotosCompanion(
          deletedAt: Value(now),
          updatedAt: Value(now),
          dirty: const Value(true),
        ),
      );

      await (_db.update(_db.routes)..where(
            (t) => t.photoId.equals(photoId) & t.deletedAt.isNull(),
          ))
          .write(
            db.RoutesCompanion(
              deletedAt: Value(now),
              updatedAt: Value(now),
              dirty: const Value(true),
            ),
          );

      await (_db.update(_db.photos)..where(
            (t) =>
                t.parentPhotoId.equals(photoId) & t.deletedAt.isNull(),
          ))
          .write(
            db.PhotosCompanion(
              deletedAt: Value(now),
              updatedAt: Value(now),
              dirty: const Value(true),
            ),
          );

      if (!photo.isPrimary) return;

      final remaining = await (_db.select(_db.photos)
            ..where(
              (t) =>
                  t.wallId.equals(photo.wallId) &
                  t.kind.equals('original') &
                  t.deletedAt.isNull(),
            )
            ..orderBy([
              (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
              (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc),
            ])
            ..limit(1))
          .getSingleOrNull();
      if (remaining == null) return;

      await (_db.update(
        _db.photos,
      )..where((t) => t.id.equals(remaining.id))).write(
        db.PhotosCompanion(
          isPrimary: const Value(true),
          updatedAt: Value(now),
          dirty: const Value(true),
        ),
      );
    });
  }

  /// Writes `sortOrder` for every id in [orderedPhotoIds] to its (0-based)
  /// index in the list — the reorder write-through for the multi-photo
  /// strip's drag-to-reorder. Ids not belonging to a live photo are simply
  /// no-ops (the WHERE clause matches zero rows for them); ids missing from
  /// [orderedPhotoIds] entirely are left with whatever `sortOrder` they
  /// already had. Bumps `updatedAt`/`dirty` on every row actually matched.
  Future<void> setPhotoOrder(
    String wallId,
    List<String> orderedPhotoIds,
  ) async {
    final now = nowMs();
    await _db.transaction(() async {
      for (var i = 0; i < orderedPhotoIds.length; i++) {
        await (_db.update(_db.photos)..where(
              (t) => t.wallId.equals(wallId) & t.id.equals(orderedPhotoIds[i]),
            ))
            .write(
              db.PhotosCompanion(
                sortOrder: Value(i),
                updatedAt: Value(now),
                dirty: const Value(true),
              ),
            );
      }
    });
  }

  /// Resolves [row]'s stored `localPath` to an absolute path and self-heals
  /// the DB row's `localPath` (and ONLY `localPath` — not
  /// `dirty`/`updatedAt`/`remoteId`, since this is a local-only self-heal,
  /// not a semantic edit that should trigger re-sync) when a stale absolute
  /// path is found to have moved.
  ///
  /// Uses [PhotoFiles.resolvePhotoPathSync] (NOT the awaiting
  /// [PhotoFiles.resolvePhotoPath]): `loadOriginal`/`loadOriginals` are
  /// driven on the canvas widget mount under a `flutter_test` `pump()`,
  /// where awaiting a real `path_provider` call never completes and
  /// hard-hangs `pumpAndSettle`. The sync resolver is cache-backed and
  /// returns immediately; on a cold cache it best-effort returns the stored
  /// value (and warms for next time), so a first load may be unresolved but
  /// never hangs. The heal signal it returns is still applied here via the
  /// (async) DB write.
  Future<PhotoRef> _rowToRef(db.Photo row) async {
    final resolution = _photoFiles.resolvePhotoPathSync(row.localPath);
    final healed = resolution.healedRelativePath;
    if (healed != null) {
      await (_db.update(
        _db.photos,
      )..where((t) => t.id.equals(row.id))).write(
        db.PhotosCompanion(localPath: Value(healed)),
      );
    }
    return PhotoRef(
      id: row.id,
      wallId: row.wallId,
      kind: row.kind,
      localPath: resolution.path,
      width: row.width,
      height: row.height,
      parentPhotoId: row.parentPhotoId,
      sortOrder: row.sortOrder,
      isPrimary: row.isPrimary,
    );
  }
}
