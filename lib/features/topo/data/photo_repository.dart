import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/db/app_database.dart' as db;
import '../domain/slice_geometry.dart';
import 'photo_files.dart';

/// Domain-level view of a `Photos` row (original or slice), independent of
/// the generated drift data class.
class PhotoRef {
  const PhotoRef({
    required this.id,
    required this.wallId,
    required this.kind,
    required this.localPath,
    required this.width,
    required this.height,
    this.parentPhotoId,
    this.cropXpct,
    this.cropWidthPct,
  });

  final String id;
  final String wallId;
  final String kind;
  final String localPath;
  final int width;
  final int height;
  final String? parentPhotoId;
  final double? cropXpct;
  final double? cropWidthPct;

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
        other.cropXpct == cropXpct &&
        other.cropWidthPct == cropWidthPct;
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
        cropXpct,
        cropWidthPct,
      );

  @override
  String toString() =>
      'PhotoRef(id: $id, wallId: $wallId, kind: $kind, localPath: '
      '$localPath, width: $width, height: $height, parentPhotoId: '
      '$parentPhotoId, cropXpct: $cropXpct, cropWidthPct: $cropWidthPct)';
}

/// Persists sliced [PhotoRef]s (derived from an "original" `Photos` row) to
/// the `Photos` table.
///
/// Slices are replaced as a set: every call to [replaceSlices] soft-deletes
/// the previous live slices for the given original photo and inserts a
/// fresh row per [SliceSpec], so callers never have to diff old vs. new
/// slice geometry themselves.
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
  /// read lazily at INSERT time to stamp a new slice photo's `ownerId`.
  /// Defaults to always-`null` so existing constructors/tests keep their
  /// pre-sync-pivot signed-out behavior unchanged.
  final String? Function() currentUid;

  static String? _noUid() => null;

  static const _uuid = Uuid();

  /// Resolves a stored `localPath` (which may be the canonical relative
  /// form, or a legacy/stale absolute one — see [PhotoFiles.resolvePhotoPath])
  /// to an absolute path, self-healing the DB row when a stale absolute path
  /// is found to have moved (container rotation). Injectable so tests can
  /// point it at a temp directory without a `path_provider` platform fake;
  /// defaults to the real app-documents-backed [PhotoFiles].
  final PhotoFiles _photoFiles;

  /// Replaces the full set of slices for [originalPhotoId] with one row per
  /// entry in [slices].
  ///
  /// Runs inside a single transaction: existing non-deleted slice rows
  /// whose `parentPhotoId == originalPhotoId` are soft-deleted (tombstoned
  /// via `deletedAt`), then a new `Photos` row is inserted for each
  /// [SliceSpec] (`kind: 'slice'`), carrying over [originalWidth],
  /// [originalHeight], and [originalLocalPath] from the source image.
  /// Returns the newly inserted slices as [PhotoRef]s.
  Future<List<PhotoRef>> replaceSlices(
    String wallId,
    String originalPhotoId,
    int originalWidth,
    int originalHeight,
    String originalLocalPath,
    List<SliceSpec> slices,
  ) async {
    // Canonicalize BEFORE the transaction: originalLocalPath may already be
    // a resolved absolute path (e.g. handed back by
    // LibraryCrudRepository.photoLocalPath), and every slice row must store
    // the same rotation-proof relative form the original does. Resolve once
    // (not per-slice) for the in-memory PhotoRefs returned below, so their
    // `localPath` matches loadOriginal/loadSlices' always-absolute contract.
    final stored = await _photoFiles.canonicalStoredPath(originalLocalPath);
    final resolvedLocalPath = (await _photoFiles.resolvePhotoPath(
      stored,
    )).path;
    return _db.transaction(() async {
      final now = nowMs();

      await (_db.update(_db.photos)..where(
            (t) =>
                t.parentPhotoId.equals(originalPhotoId) &
                t.kind.equals('slice') &
                t.deletedAt.isNull(),
          ))
          .write(
            db.PhotosCompanion(
              deletedAt: Value(now),
              updatedAt: Value(now),
            ),
          );

      final inserted = <PhotoRef>[];
      for (final slice in slices) {
        final id = _uuid.v4();
        await _db
            .into(_db.photos)
            .insert(
              db.PhotosCompanion.insert(
                id: id,
                createdAt: now,
                updatedAt: now,
                wallId: wallId,
                localPath: stored,
                kind: 'slice',
                width: originalWidth,
                height: originalHeight,
                parentPhotoId: Value(originalPhotoId),
                cropXpct: Value(slice.cropXpct),
                cropWidthPct: Value(slice.cropWidthPct),
                ownerId: Value(currentUid()),
              ),
            );
        inserted.add(
          PhotoRef(
            id: id,
            wallId: wallId,
            kind: 'slice',
            localPath: resolvedLocalPath,
            width: originalWidth,
            height: originalHeight,
            parentPhotoId: originalPhotoId,
            cropXpct: slice.cropXpct,
            cropWidthPct: slice.cropWidthPct,
          ),
        );
      }

      return inserted;
    });
  }

  /// Loads every non-soft-deleted slice row whose `parentPhotoId ==
  /// [originalPhotoId]`, ordered by `cropXpct` ascending.
  Future<List<PhotoRef>> loadSlices(String originalPhotoId) async {
    final rows = await (_db.select(_db.photos)
          ..where(
            (t) =>
                t.parentPhotoId.equals(originalPhotoId) &
                t.kind.equals('slice') &
                t.deletedAt.isNull(),
          )
          ..orderBy([(t) => OrderingTerm(expression: t.cropXpct)]))
        .get();

    return Future.wait([for (final row in rows) _rowToRef(row)]);
  }

  /// Loads the non-deleted `kind: 'original'` photo for [wallId], or `null`
  /// if there isn't one.
  Future<PhotoRef?> loadOriginal(String wallId) async {
    final row = await (_db.select(_db.photos)..where(
          (t) =>
              t.wallId.equals(wallId) &
              t.kind.equals('original') &
              t.deletedAt.isNull(),
        ))
        .getSingleOrNull();

    return row == null ? null : await _rowToRef(row);
  }

  /// Resolves [row]'s stored `localPath` to an absolute path and self-heals
  /// the DB row's `localPath` (and ONLY `localPath` — not
  /// `dirty`/`updatedAt`/`remoteId`, since this is a local-only self-heal,
  /// not a semantic edit that should trigger re-sync) when a stale absolute
  /// path is found to have moved.
  ///
  /// Uses [PhotoFiles.resolvePhotoPathSync] (NOT the awaiting
  /// [PhotoFiles.resolvePhotoPath]): `loadOriginal`/`loadSlices` are driven
  /// on the canvas widget mount under a `flutter_test` `pump()`, where
  /// awaiting a real `path_provider` call never completes and hard-hangs
  /// `pumpAndSettle`. The sync resolver is cache-backed and returns
  /// immediately; on a cold cache it best-effort returns the stored value
  /// (and warms for next time), so a first load may be unresolved but never
  /// hangs. The heal signal it returns is still applied here via the
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
      cropXpct: row.cropXpct,
      cropWidthPct: row.cropWidthPct,
    );
  }
}
