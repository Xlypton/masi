import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/db/app_database.dart' as db;
import '../domain/comment_mentions.dart';

/// Immutable read model for a non-deleted [db.Comment] row: a discussion
/// comment left on EITHER a Wall (topo) or an ascent log (Feature #12 —
/// public opt-in ascent logs), never both — exactly one of [wallId]/
/// [ascentId] is non-null on any given [Comment].
class Comment {
  const Comment({
    required this.id,
    this.wallId,
    this.ascentId,
    required this.body,
    this.authorName,
    this.ownerId,
    required this.createdAt,
    required this.updatedAt,
    this.mentionedUids = const [],
  });

  final String id;
  final String? wallId;
  final String? ascentId;
  final String body;
  final String? authorName;
  final String? ownerId;
  final int createdAt;
  final int updatedAt;

  /// The uids this comment tags, already decoded — see
  /// [db.Comments.mentionedUids] for why they are uids and not names.
  ///
  /// A `List<String>`, never the raw column text: the JSON is a storage detail,
  /// and a repository that handed it out as a string would push the parse (and
  /// every one of its failure modes — see [decodeMentionedUids]) onto whichever
  /// widget happened to need it. Empty for the overwhelming majority of
  /// comments, which tag nobody.
  final List<String> mentionedUids;

  @override
  bool operator ==(Object other) =>
      other is Comment &&
      other.id == id &&
      other.wallId == wallId &&
      other.ascentId == ascentId &&
      other.body == body &&
      other.authorName == authorName &&
      other.ownerId == ownerId &&
      other.createdAt == createdAt &&
      other.updatedAt == updatedAt &&
      _sameUids(other.mentionedUids, mentionedUids);

  @override
  int get hashCode => Object.hash(
    id,
    wallId,
    ascentId,
    body,
    authorName,
    ownerId,
    createdAt,
    updatedAt,
    Object.hashAll(mentionedUids),
  );

  @override
  String toString() =>
      'Comment(id: $id, wallId: $wallId, ascentId: $ascentId, body: $body, '
      'authorName: $authorName, ownerId: $ownerId, createdAt: $createdAt, '
      'updatedAt: $updatedAt, mentionedUids: $mentionedUids)';

  /// Lists don't compare by value in Dart, and [Comment] equality is what the
  /// comment-thread widgets rebuild off — comparing the fields by identity
  /// would make every rebuild look like a change.
  static bool _sameUids(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Create/read/soft-delete for Wall (and, as of Feature #12, ascent-log)
/// comments — the `community` feature's discussion thread on a topo or a
/// shared ascent.
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
  ///
  /// [mentionedUids] are the climbers this comment tags (see
  /// [Comment.mentionedUids]); omit it, or pass an empty list, for the usual
  /// comment that tags nobody.
  Future<Comment> addComment({
    required String wallId,
    required String body,
    String? authorName,
    Iterable<String> mentionedUids = const [],
  }) {
    return _addComment(
      body: body,
      authorName: authorName,
      wallId: wallId,
      ascentId: null,
      mentionedUids: mentionedUids,
    );
  }

  /// Ascent-targeted mirror of [addComment]: adds a new comment to the
  /// ascent-log row [ascentId] (Feature #12 — public opt-in ascent logs can
  /// be commented on like shared topos), writing `ascentId` set and `wallId`
  /// left `NULL` so ascent-comments never mix with wall-comments. Same
  /// owner-stamping/`dirty` behavior as [addComment] — see its doc.
  Future<Comment> addAscentComment({
    required String ascentId,
    required String body,
    String? authorName,
    Iterable<String> mentionedUids = const [],
  }) {
    return _addComment(
      body: body,
      authorName: authorName,
      wallId: null,
      ascentId: ascentId,
      mentionedUids: mentionedUids,
    );
  }

  Future<Comment> _addComment({
    required String body,
    required String? authorName,
    required String? wallId,
    required String? ascentId,
    required Iterable<String> mentionedUids,
  }) async {
    final now = nowMs();
    final id = _uuid.v4();
    final ownerId = currentUid();
    // Encoded once and decoded straight back, rather than trusting the caller's
    // list: the row and the returned model must agree about blanks, duplicates
    // and ordering, and the column is the side that decides.
    final encodedMentions = encodeMentionedUids(mentionedUids);
    await _db
        .into(_db.comments)
        .insert(
          db.CommentsCompanion.insert(
            id: id,
            createdAt: now,
            updatedAt: now,
            wallId: Value(wallId),
            ascentId: Value(ascentId),
            body: body,
            authorName: Value(authorName),
            ownerId: Value(ownerId),
            dirty: const Value(true),
            mentionedUids: Value(encodedMentions),
          ),
        );
    return Comment(
      id: id,
      wallId: wallId,
      ascentId: ascentId,
      body: body,
      authorName: authorName,
      ownerId: ownerId,
      createdAt: now,
      updatedAt: now,
      mentionedUids: decodeMentionedUids(encodedMentions),
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

  /// Non-deleted comments on the ascent log [ascentId], chronological
  /// ascending (oldest first). Ascent-targeted mirror of [commentsForWall].
  Future<List<Comment>> commentsForAscent(String ascentId) async {
    final rows = await _ascentCommentsQuery(ascentId).get();
    return rows.map(_fromRow).toList();
  }

  /// Live version of [commentsForAscent].
  Stream<List<Comment>> watchCommentsForAscent(String ascentId) {
    return _ascentCommentsQuery(
      ascentId,
    ).watch().map((rows) => rows.map(_fromRow).toList());
  }

  /// Soft-deletes comment [id]: sets `deletedAt`/`updatedAt` to `nowMs()` and
  /// marks it `dirty`. The row is never physically removed so a future sync
  /// layer can still see the tombstone. Works for both wall- and
  /// ascent-attached comments — the lookup is by `id` alone.
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
      ..where(
        (t) =>
            t.wallId.equals(wallId) &
            t.ascentId.isNull() &
            t.deletedAt.isNull(),
      )
      ..orderBy([(t) => OrderingTerm(expression: t.createdAt)]);
  }

  SimpleSelectStatement<db.$CommentsTable, db.Comment> _ascentCommentsQuery(
    String ascentId,
  ) {
    return _db.select(_db.comments)
      ..where(
        (t) =>
            t.ascentId.equals(ascentId) &
            t.wallId.isNull() &
            t.deletedAt.isNull(),
      )
      ..orderBy([(t) => OrderingTerm(expression: t.createdAt)]);
  }

  Comment _fromRow(db.Comment row) => Comment(
    id: row.id,
    // wallId/ascentId are read nullably straight off the row: as of
    // Feature #12 (public opt-in ascent logs) exactly one of them is set
    // per row (wall-attached comments have ascentId NULL and vice versa —
    // see `core/db/tables.dart`'s doc comments), so force-unwrapping either
    // here would crash on the other kind's rows.
    wallId: row.wallId,
    ascentId: row.ascentId,
    body: row.body,
    authorName: row.authorName,
    ownerId: row.ownerId,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    // Decoded at the repository boundary so no caller ever sees the JSON —
    // and so a malformed value written by an older client or a future server
    // degrades to "tags nobody" here instead of throwing inside a widget.
    mentionedUids: decodeMentionedUids(row.mentionedUids),
  );
}
