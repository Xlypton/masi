import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/db/app_database.dart' as db;

/// CRUD over the `Likes` table: one row per (ownerId, wallId) pair, one
/// "like" a signed-in user (or, when signed out, this device) can toggle on
/// a wall. Rows are never physically removed — a like is retracted via
/// soft-delete (`deletedAt`), matching `LibraryCrudRepository`'s pattern, so
/// a future sync layer can still see the tombstone.
///
/// A signed-out `currentUid()` (`null`) is treated as a first-class owner
/// value identifying "this device's single local like", not as "no owner to
/// match" — so lookups compare against `ownerId IS NULL` (via
/// [Column.isNull]) rather than `ownerId = NULL`, which never matches
/// anything in SQL regardless of the row's actual `ownerId`.
class LikesRepository {
  LikesRepository(this._db, {required this.nowMs, this.currentUid = _noUid});

  final db.AppDatabase _db;
  final int Function() nowMs;

  /// The Supabase Auth uid of the signed-in user (or `null` if signed out),
  /// read lazily on each call so tests/providers can swap it without
  /// reconstructing this repository. Mirrors `LibraryCrudRepository`'s seam.
  final String? Function() currentUid;

  static String? _noUid() => null;

  static const _uuid = Uuid();

  /// Toggles the current owner's like on [wallId].
  ///
  /// If an ACTIVE like (`deletedAt IS NULL`) already exists for
  /// (currentUid, wallId), it is soft-deleted and this returns `false` (now
  /// unliked). Otherwise, any existing soft-deleted like for the same pair
  /// is revived in place (`deletedAt` cleared) rather than inserting a
  /// second row, or — if no row for the pair exists at all — a fresh one is
  /// inserted; either way this returns `true` (now liked).
  ///
  /// INVARIANT: there is never more than one ACTIVE like for the same
  /// (ownerId, wallId) pair. This holds because every toggle first looks up
  /// the (at most one, by construction) existing row for the pair — active
  /// or tombstoned — and flips ITS `deletedAt` rather than blindly
  /// inserting a new row alongside it.
  ///
  /// The lookup-then-insert/update is wrapped in a single `_db.transaction`
  /// so it is atomic: Drift serializes transactions on a connection, so two
  /// concurrent `toggleLike` calls on the same (ownerId, wallId) pair can't
  /// both observe "no existing row" and both insert — the second call's
  /// transaction blocks until the first commits, and then sees (and flips)
  /// the row the first one created, rather than inserting a duplicate.
  Future<bool> toggleLike(String wallId) async {
    final uid = currentUid();
    final now = nowMs();

    return _db.transaction(() async {
      final existing =
          await (_db.select(_db.likes)
                ..where((t) => _ownerMatch(t, uid) & t.wallId.equals(wallId))
                ..limit(1))
              .getSingleOrNull();

      if (existing == null) {
        await _db
            .into(_db.likes)
            .insert(
              db.LikesCompanion.insert(
                id: _uuid.v4(),
                createdAt: now,
                updatedAt: now,
                wallId: Value(wallId),
                ownerId: Value(uid),
                dirty: const Value(true),
              ),
            );
        return true;
      }

      final wasActive = existing.deletedAt == null;
      await (_db.update(_db.likes)..where((t) => t.id.equals(existing.id)))
          .write(
            db.LikesCompanion(
              deletedAt: Value(wasActive ? now : null),
              updatedAt: Value(now),
              dirty: const Value(true),
            ),
          );
      return !wasActive;
    });
  }

  /// Count of ACTIVE likes on [wallId], across all owners.
  Future<int> likeCountForWall(String wallId) async {
    final countExp = _db.likes.id.count();
    final query = _db.selectOnly(_db.likes)
      ..addColumns([countExp])
      ..where(_db.likes.wallId.equals(wallId) & _db.likes.deletedAt.isNull());
    final row = await query.getSingle();
    return row.read(countExp) ?? 0;
  }

  /// Whether the current owner (`currentUid()`, or this device if signed
  /// out) has an ACTIVE like on [wallId].
  Future<bool> hasLiked(String wallId) async {
    final uid = currentUid();
    final row =
        await (_db.select(_db.likes)
              ..where(
                (t) =>
                    _ownerMatch(t, uid) &
                    t.wallId.equals(wallId) &
                    t.deletedAt.isNull(),
              )
              ..limit(1))
            .getSingleOrNull();
    return row != null;
  }

  /// Live, auto-updating count of ACTIVE likes on [wallId].
  Stream<int> watchLikeCountForWall(String wallId) {
    final countExp = _db.likes.id.count();
    final query = _db.selectOnly(_db.likes)
      ..addColumns([countExp])
      ..where(_db.likes.wallId.equals(wallId) & _db.likes.deletedAt.isNull());
    return query.watch().map((rows) => rows.first.read(countExp) ?? 0);
  }

  /// `ownerId IS NULL` when [uid] is `null` (signed-out / this device),
  /// otherwise `ownerId = [uid]`. See class doc for why the null case can't
  /// just be `t.ownerId.equals(uid)`.
  Expression<bool> _ownerMatch(db.$LikesTable t, String? uid) {
    return uid == null ? t.ownerId.isNull() : t.ownerId.equals(uid);
  }
}
