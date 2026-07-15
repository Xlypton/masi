import '../../../core/db/app_database.dart' as db;
import '../../../core/grades/grade_system.dart';
import '../../topo/data/photo_files.dart';

/// Immutable read model for a single shared topo: a Wall with
/// `visibility == 'shared'`, joined to its thumbnail, route/like/comment
/// counts, representative grade, owner, and (if its ancestor Area has them)
/// coordinates. Backs the Community feed + map.
class SharedTopo {
  const SharedTopo({
    required this.wallId,
    required this.name,
    this.thumbnailPath,
    this.topGradeLabel,
    this.topGradeBand,
    required this.routeCount,
    required this.likeCount,
    required this.commentCount,
    this.ownerId,
    this.latitude,
    this.longitude,
    this.routeGradeKeys = const [],
    this.routeStyles = const {},
  });

  final String wallId;
  final String name;
  final String? thumbnailPath;

  /// Display label ([db.Route.gradeRaw]) of the hardest non-deleted, graded
  /// route on this wall, or `null` if the wall has no graded routes.
  final String? topGradeLabel;

  /// [GradeBand] matching [topGradeLabel]; always non-null exactly when
  /// [topGradeLabel] is non-null. Mirrors `TopoRef.topGradeBand`.
  final GradeBand? topGradeBand;

  final int routeCount;
  final int likeCount;
  final int commentCount;

  /// The Supabase Auth uid that owns this wall, or `null` if it was created
  /// while signed out (or before ownership tracking existed).
  final String? ownerId;

  /// Coordinates captured directly on this wall — see
  /// `LibraryCrudRepository.setWallCoordinates`, populated automatically
  /// from a freshly-picked photo's EXIF GPS tags — or `null` if none have
  /// been recorded. See [hasCoordinates].
  final double? latitude;
  final double? longitude;

  /// The `gradeSortKey` of every live (non-deleted), graded route on this
  /// wall, deduplicated but otherwise in no particular order — parsed from
  /// the query's `route_grade_keys` `group_concat` column. Empty when the
  /// wall has no graded routes. Used to filter the Community feed/map by
  /// grade range (see `CommunityFilter.matches`): a topo matches an active
  /// [GradeRange] iff ANY of its route grade keys falls in range.
  final List<double> routeGradeKeys;

  /// The distinct, lowercased-and-trimmed `style` of every live
  /// (non-deleted) route on this wall that has a non-empty style set —
  /// parsed from the query's `route_styles` `group_concat` column. Empty
  /// when the wall has no styled routes. Used to filter the Community
  /// feed/map by style (see `CommunityFilter.matches`): a topo matches an
  /// active style selection iff ANY of its route styles is selected.
  final Set<String> routeStyles;

  /// Whether this topo has known coordinates and can be placed on the
  /// Community map. The map view must omit — not crash on — any topo where
  /// this is `false`.
  bool get hasCoordinates => latitude != null && longitude != null;

  @override
  bool operator ==(Object other) =>
      other is SharedTopo &&
      other.wallId == wallId &&
      other.name == name &&
      other.thumbnailPath == thumbnailPath &&
      other.topGradeLabel == topGradeLabel &&
      other.topGradeBand == topGradeBand &&
      other.routeCount == routeCount &&
      other.likeCount == likeCount &&
      other.commentCount == commentCount &&
      other.ownerId == ownerId &&
      other.latitude == latitude &&
      other.longitude == longitude &&
      _listEquals(other.routeGradeKeys, routeGradeKeys) &&
      _setEquals(other.routeStyles, routeStyles);

  @override
  int get hashCode => Object.hash(
    wallId,
    name,
    thumbnailPath,
    topGradeLabel,
    topGradeBand,
    routeCount,
    likeCount,
    commentCount,
    ownerId,
    Object.hash(latitude, longitude),
    Object.hashAll(routeGradeKeys),
    Object.hashAllUnordered(routeStyles),
  );

  @override
  String toString() =>
      'SharedTopo(wallId: $wallId, name: $name, thumbnailPath: $thumbnailPath, '
      'topGradeLabel: $topGradeLabel, topGradeBand: $topGradeBand, '
      'routeCount: $routeCount, likeCount: $likeCount, '
      'commentCount: $commentCount, ownerId: $ownerId, latitude: $latitude, '
      'longitude: $longitude, routeGradeKeys: $routeGradeKeys, '
      'routeStyles: $routeStyles)';
}

/// Order-sensitive element-wise equality for [SharedTopo.routeGradeKeys]
/// (kept deterministic across parses by sorting at construction time — see
/// [_parseGradeKeys]).
bool _listEquals(List<double> a, List<double> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Order-independent set equality for [SharedTopo.routeStyles] (a plain
/// `Set<String>` doesn't override `==` to mean "same elements").
bool _setEquals(Set<String> a, Set<String> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  return a.containsAll(b);
}

/// Parses the `route_grade_keys` column — a `group_concat(DISTINCT
/// r.grade_sort_key)` of a wall's live, graded routes — into a sorted
/// (ascending, for deterministic equality/hashing regardless of SQLite's
/// unspecified `group_concat` element order) list of doubles. `null` (no
/// matching rows) or an empty string both yield an empty list; any
/// malformed token (should not occur, since the source column is a REAL)
/// is skipped rather than thrown.
List<double> _parseGradeKeys(String? raw) {
  if (raw == null || raw.isEmpty) return const [];
  final keys = <double>[];
  for (final token in raw.split(',')) {
    final parsed = double.tryParse(token.trim());
    if (parsed != null) keys.add(parsed);
  }
  keys.sort();
  return keys;
}

/// Parses the `route_styles` column — a `group_concat(DISTINCT r.style)` of
/// a wall's live routes with a non-empty style — into a lowercased,
/// trimmed, deduplicated set. `null` (no matching rows) or an empty string
/// both yield an empty set.
Set<String> _parseStyles(String? raw) {
  if (raw == null || raw.isEmpty) return const {};
  final styles = <String>{};
  for (final token in raw.split(',')) {
    final trimmed = token.trim().toLowerCase();
    if (trimmed.isNotEmpty) styles.add(trimmed);
  }
  return styles;
}

/// Read-only repository backing the Community discovery feed + map: every
/// non-deleted Wall with `visibility == 'shared'`, joined to its thumbnail,
/// aggregate counts, representative grade, and ancestor-Area coordinates.
///
/// Deliberately read-only (no `nowMs`/`currentUid` seam, unlike
/// `LibraryCrudRepository`/`LikesRepository`/`CommentsRepository`): nothing
/// here ever writes a row.
class CommunityRepository {
  CommunityRepository(this._db, {PhotoFiles? photoFiles})
    : _photoFiles = photoFiles ?? PhotoFiles();

  final db.AppDatabase _db;

  /// Resolves stored (possibly relative/stale) `Photos.localPath` values to
  /// absolute display paths. Shared with `LibraryCrudRepository` via the
  /// `photoFilesProvider` seam so its memoized docs-path cache is reused
  /// rather than re-warmed cold.
  final PhotoFiles _photoFiles;

  /// Live list of every shared topo (`Walls.visibility == 'shared'` AND
  /// `deletedAt IS NULL`), newest-first.
  ///
  /// Expressed as a raw [db.AppDatabase.customSelect] (mirroring
  /// `LibraryCrudRepository.watchTopos`'s join style) rather than a Drift
  /// `.join()`: a wall with more than one live `'original'` photo, like, or
  /// comment would otherwise multiply rows via `GROUP BY`. The route/grade,
  /// like, and comment aggregates are each expressed as correlated
  /// subqueries — same pattern as `watchTopos`'s `route_count`/`top_grade_*`
  /// columns — rather than calling `LikesRepository.likeCountForWall` /
  /// `CommentsRepository.commentsForWall` per row, which would mean N+1
  /// queries and a much harder-to-keep-live stream. `readsFrom` lists every
  /// table the SQL actually touches (including `sectors`/`areas`, joined to
  /// reach the wall's ancestor chain — coordinates themselves come straight
  /// off the wall row, see [SharedTopo.latitude]/[SharedTopo.longitude]'s
  /// doc) so the auto-updating stream re-emits on changes to any of them.
  Stream<List<SharedTopo>> watchSharedTopos() {
    const sql = '''
      SELECT
        w.id AS wall_id,
        w.name AS wall_name,
        w.owner_id AS owner_id,
        w.latitude AS latitude,
        w.longitude AS longitude,
        (SELECT p.local_path FROM photos p
           WHERE p.wall_id = w.id AND p.kind = 'original' AND p.deleted_at IS NULL
           ORDER BY p.created_at DESC, p.id DESC LIMIT 1) AS thumbnail_path,
        (SELECT COUNT(*) FROM routes r
           WHERE r.wall_id = w.id AND r.deleted_at IS NULL) AS route_count,
        (SELECT r.grade_raw FROM routes r
           WHERE r.wall_id = w.id AND r.deleted_at IS NULL
             AND r.grade_sort_key IS NOT NULL
           ORDER BY r.grade_sort_key DESC, r.id DESC LIMIT 1) AS top_grade_raw,
        (SELECT r.grade_sort_key FROM routes r
           WHERE r.wall_id = w.id AND r.deleted_at IS NULL
             AND r.grade_sort_key IS NOT NULL
           ORDER BY r.grade_sort_key DESC, r.id DESC LIMIT 1) AS top_grade_sort_key,
        (SELECT COUNT(*) FROM likes l
           WHERE l.wall_id = w.id AND l.deleted_at IS NULL) AS like_count,
        (SELECT COUNT(*) FROM comments c
           WHERE c.wall_id = w.id AND c.deleted_at IS NULL) AS comment_count,
        (SELECT group_concat(DISTINCT r.grade_sort_key) FROM routes r
           WHERE r.wall_id = w.id AND r.deleted_at IS NULL
             AND r.grade_sort_key IS NOT NULL) AS route_grade_keys,
        (SELECT group_concat(DISTINCT r.style) FROM routes r
           WHERE r.wall_id = w.id AND r.deleted_at IS NULL
             AND r.style IS NOT NULL AND r.style != '') AS route_styles
      FROM walls w
      JOIN sectors s ON s.id = w.sector_id
      JOIN areas a ON a.id = s.area_id
      WHERE w.deleted_at IS NULL AND w.visibility = 'shared'
      ORDER BY w.created_at DESC, w.id DESC
    ''';
    return _db
        .customSelect(
          sql,
          readsFrom: {
            _db.walls,
            _db.sectors,
            _db.areas,
            _db.photos,
            _db.routes,
            _db.likes,
            _db.comments,
          },
        )
        .watch()
        .map((rows) {
          // Synchronous mapping (NOT asyncMap) for the same reason as
          // `watchTopos`: an async mapper on this Drift stream wedges under
          // `flutter_test`'s fake clock and hangs any widget test's
          // `pumpAndSettle`.
          return [
            for (final row in rows)
              SharedTopo(
                wallId: row.read<String>('wall_id'),
                name: row.read<String>('wall_name'),
                thumbnailPath: _resolveThumbnail(
                  row.readNullable<String>('thumbnail_path'),
                ),
                routeCount: row.read<int>('route_count'),
                topGradeLabel: row.readNullable<String>('top_grade_raw'),
                topGradeBand:
                    row.readNullable<double>('top_grade_sort_key') == null
                    ? null
                    : bandForSortKey(
                        row.readNullable<double>('top_grade_sort_key')!,
                      ),
                likeCount: row.read<int>('like_count'),
                commentCount: row.read<int>('comment_count'),
                ownerId: row.readNullable<String>('owner_id'),
                latitude: row.readNullable<double>('latitude'),
                longitude: row.readNullable<double>('longitude'),
                routeGradeKeys: _parseGradeKeys(
                  row.readNullable<String>('route_grade_keys'),
                ),
                routeStyles: _parseStyles(
                  row.readNullable<String>('route_styles'),
                ),
              ),
          ];
        });
  }

  /// Resolves a stored thumbnail `localPath` to an absolute display path via
  /// [PhotoFiles.resolvePhotoPathSync], passing `null` through unchanged
  /// (walls with no photo). Mirrors
  /// `LibraryCrudRepository._resolveThumbnail`.
  String? _resolveThumbnail(String? storedThumbnailPath) {
    if (storedThumbnailPath == null) return null;
    return _photoFiles.resolvePhotoPathSync(storedThumbnailPath).path;
  }
}
