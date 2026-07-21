import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/db/app_database.dart' as db;

/// Immutable read model for a non-deleted [db.Comment] row: a discussion
/// comment left on a Wall (topo).
class Comment {
  const Comment({
    required this.id,
    required this.wallId,
    required this.body,
    this.authorName,
    this.ownerId,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String wallId;
  final String body;
  final String? authorName;
  final String? ownerId;
  final int createdAt;
  final int updatedAt;

  @override
  bool operator ==(Object other) =>
      other is Comment &&
      other.id == id &&
      other.wallId == wallId &&
      other.body == body &&
      other.authorName == authorName &&
      other.ownerId == ownerId &&
      other.createdAt == createdAt &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(
    id,
    wallId,
    body,
    authorName,
    ownerId,
    createdAt,
    updatedAt,
  );

  @override
  String toString() =>
      'Comment(id: $id, wallId: $wallId, body: $body, '
      'authorName: $authorName, ownerId: $ownerId, createdAt: $createdAt, '
      'updatedAt: $updatedAt)';
}

/// Create/read/soft-delete for Wall comments (the `community` feature's
/// discussion thread on a topo).
///
/// Mirrors `LibraryCrudRepository`'s conventions: owner-stamping via a
/// lazily-read [currentUid] seam, a [nowMs] clock injected for deterministic
/// tests, fresh UUIDv4 ids, soft-delete via `deletedAt` (rows are never
/// physically removed so a future sync layer can still see tombstones), and
/// mapping Drift rows to a plain domain model ([Comment]) at the repo
/// boundary rather than leaking generated classes to callers.
class CommentsRepository {
  CommentsRepository(
    this._db, {
    required this.nowMs,
    this.currentUid = _noUid,
  });

  final db.AppDatabase _db;
  final int Function() nowMs;

  /// The Supabase Auth uid of the signed-in user (or `null` if signed out),
  /// read lazily at each INSERT to stamp the new row's `ownerId`. Defaults
  /// to always-`null` so callers/tests that don't pass this keep signed-out
  /// behavior unchanged; mirrors `LibraryCrudRepository.currentUid`.
  final String? Function() currentUid;

  static String? _noUid() => null;

  static const _uuid = Uuid();

  /// Adds a new comment to [wallId], owner-stamped with whatever
  /// [currentUid] returns (may be `null` if signed out) and marked `dirty`
  /// so a future sync push picks it up. Returns the newly-created [Comment].
  Future<Comment> addComment({
    required String wallId,
    required String body,
    String? authorName,
  }) async {
    final now = nowMs();
    final id = _uuid.v4();
    final ownerId = currentUid();
    await _db
        .into(_db.comments)
        .insert(
          db.CommentsCompanion.insert(
            id: id,
            createdAt: now,
            updatedAt: now,
            wallId: Value(wallId),
            body: body,
            authorName: Value(authorName),
            ownerId: Value(ownerId),
            dirty: const Value(true),
          ),
        );
    return Comment(
      id: id,
      wallId: wallId,
      body: body,
      authorName: authorName,
      ownerId: ownerId,
      createdAt: now,
      updatedAt: now,
    );
  }

  /// Non-deleted comments on [wallId], chronological ascending
  /// (oldest first).
  Future<List<Comment>> commentsForWall(String wallId) async {
    final rows = await _wallCommentsQuery(wallId).get();
    return rows.map(_fromRow).toList();
  }

  /// Live version of [commentsForWall].
  Stream<List<Comment>> watchCommentsForWall(String wallId) {
    return _wallCommentsQuery(
      wallId,
    ).watch().map((rows) => rows.map(_fromRow).toList());
  }

  /// Soft-deletes comment [id]: sets `deletedAt`/`updatedAt` to `nowMs()` and
  /// marks it `dirty`. The row is never physically removed so a future sync
  /// layer can still see the tombstone.
  Future<void> softDeleteComment(String id) async {
    final now = nowMs();
    await (_db.update(
      _db.comments,
    )..where((t) => t.id.equals(id) & t.deletedAt.isNull())).write(
      db.CommentsCompanion(
        deletedAt: Value(now),
        updatedAt: Value(now),
        dirty: const Value(true),
      ),
    );
  }

  SimpleSelectStatement<db.$CommentsTable, db.Comment> _wallCommentsQuery(
    String wallId,
  ) {
    return _db.select(_db.comments)
      ..where((t) => t.wallId.equals(wallId) & t.deletedAt.isNull())
      ..orderBy([(t) => OrderingTerm(expression: t.createdAt)]);
  }

  Comment _fromRow(db.Comment row) => Comment(
    id: row.id,
    // Non-null assertion: this repository only ever creates/queries
    // wall-attached comments (filtered by `t.wallId.equals(wallId)`), so
    // `wallId` is guaranteed non-null on every row it returns even though
    // the column itself became nullable when Feature #12 (public opt-in
    // ascent logs) added the ascent-attached alternative — see
    // `core/db/tables.dart`'s `Comments.wallId`/`ascentId` doc comments.
    wallId: row.wallId!,
    body: row.body,
    authorName: row.authorName,
    ownerId: row.ownerId,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  );
}
