import '../../../core/db/app_database.dart' as db;
import '../../../core/grades/grade_system.dart';
import '../../../core/routes/route_styles.dart';
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
    this.routeStyleTags = const {},
    this.createdAt = 0,
    this.updatedAt = 0,
    this.ascentCount = 0,
    this.lastVerifiedAt,
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

  /// The distinct, decoded style-TAG keys (see `core/routes/route_styles.dart`
  /// -- e.g. `'dyno'`, `'crimpy'`) across every live (non-deleted) route on
  /// this wall, deduplicated -- parsed from the query's
  /// `route_style_tags_json` `group_concat` column, which carries each
  /// route's raw `styleTagsJson` (a JSON array) joined by a control-character
  /// separator (see [_kStyleTagsGroupSeparator]) and is flattened/decoded
  /// app-side via [decodeStyleTags] rather than unnested in SQL. Empty when
  /// the wall has no routes with style tags. Distinct from [routeStyles]
  /// (the older single-value sport/trad/boulder facet, stored in a separate
  /// column): this is the newer multi-tag facet (see
  /// `StyleTagFilterChips`/`CommunityFilter.styleTags`). Used to filter the
  /// Community feed/map: a topo matches an active style-tag selection iff
  /// ANY of its route style tags is selected.
  final Set<String> routeStyleTags;

  /// The wall's `created_at` ms-epoch timestamp — the same column
  /// [CommunityRepository.watchSharedTopos] already orders by (`ORDER BY
  /// w.created_at DESC`), just also projected here so a caller merging this
  /// feed with another newest-first source (e.g. the Community Feed's
  /// [FeedItem] union with [SharedAscentEntry]'s `climbedAt`) has a real
  /// timestamp to sort by instead of relying on this list's own order.
  /// Defaults to `0` for the few tests that construct a [SharedTopo]
  /// directly without a real wall row — those never exercise cross-source
  /// sorting.
  final int createdAt;

  /// The wall's `updated_at` — **when this topo entered the feed**, which is
  /// what the Feed tab's unseen dot compares against.
  ///
  /// Not [createdAt], and the difference is the whole reason this column is
  /// projected. A topo is created privately and published later, sometimes
  /// much later; `createdAt` is when the author started drawing it, so a topo
  /// drawn in January and published today would never register as new and the
  /// dot would miss the single event it exists for. Publishing flips
  /// `visibility`, which is a local write, which bumps `updated_at`.
  ///
  /// The cost, stated plainly: an ordinary EDIT to a published topo bumps this
  /// too, so fixing a typo can dot the tab. That is the right way round —
  /// a dot that occasionally means "this changed" is noise, while a dot that
  /// silently never fires on publication is a broken feature.
  final int updatedAt;

  /// Live ascents logged against this wall, as far as THIS DEVICE knows
  /// (community editing phase 8c / C-6.3).
  ///
  /// A floor, never a total: the local `ascents` table holds this account's own
  /// ascents plus other people's opt-in-`shared` ones, so the real number is
  /// always ≥ this. Good enough to ORDER by, since the undercount runs in the
  /// same direction for every topo — and deliberately not rendered anywhere as
  /// a count, because displaying it would be a claim it cannot support.
  final int ascentCount;

  /// When somebody last said this topo matches the rock (phase 4's
  /// `topo_verifications`), or null if nobody has. Only accurate=true
  /// verifications count: "this is wrong" is a useful signal but not a
  /// freshness one, and folding the two together would let a topo look
  /// recently-confirmed because somebody just disputed it.
  final int? lastVerifiedAt;

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
      _setEquals(other.routeStyles, routeStyles) &&
      _setEquals(other.routeStyleTags, routeStyleTags) &&
      other.createdAt == createdAt &&
      other.ascentCount == ascentCount &&
      other.lastVerifiedAt == lastVerifiedAt;

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
    Object.hashAllUnordered(routeStyleTags),
    createdAt,
    ascentCount,
    lastVerifiedAt,
  );

  @override
  String toString() =>
      'SharedTopo(wallId: $wallId, name: $name, thumbnailPath: $thumbnailPath, '
      'topGradeLabel: $topGradeLabel, topGradeBand: $topGradeBand, '
      'routeCount: $routeCount, likeCount: $likeCount, '
      'commentCount: $commentCount, ownerId: $ownerId, latitude: $latitude, '
      'longitude: $longitude, routeGradeKeys: $routeGradeKeys, '
      'routeStyles: $routeStyles, routeStyleTags: $routeStyleTags, '
      'createdAt: $createdAt, ascentCount: $ascentCount, '
      'lastVerifiedAt: $lastVerifiedAt)';
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

/// Separator used to join multiple routes' raw `styleTagsJson` values within
/// a single `group_concat` aggregate column (see `watchSharedTopos`'s
/// `route_style_tags_json` subquery). Deliberately an ASCII control
/// character (Record Separator, U+001E) rather than a printable delimiter
/// like `,` or `|`: `styleTagsJson` is itself a JSON array (which contains
/// commas), and a custom user-typed tag could in principle contain any
/// printable string, so a control character all but guarantees no collision
/// with real tag content -- unlike SQLite's own `group_concat` default
/// separator (`,`), which would corrupt the JSON on split.
const _kStyleTagsGroupSeparator = '\u001E';

/// Correlated subquery resolving a wall's PRIMARY live `kind: 'original'`
/// photo id, ordered `is_primary DESC, created_at DESC, id DESC` -- the same
/// ordering as `PhotoRepository._liveOriginalsQuery`/`loadOriginal`, which is
/// what the detail screen's canvas actually opens. Interpolated into each of
/// `watchSharedTopos`'s route aggregate subqueries (#13) so the feed's
/// route-count/top-grade badges are scoped to the SAME photo's routes the
/// detail screen's Routes list shows, rather than every live photo on the
/// wall. `null` (a wall with no live original) makes every `r.photo_id =
/// NULL` comparison downstream evaluate to unknown/false, so aggregates
/// correctly come back empty rather than falling back to all-photos.
const _kPrimaryPhotoIdSubquery = '''
          (SELECT p.id FROM photos p
             WHERE p.wall_id = w.id AND p.kind = 'original' AND p.deleted_at IS NULL
             ORDER BY p.is_primary DESC, p.created_at DESC, p.id DESC LIMIT 1)''';

/// Parses the `route_style_tags_json` column -- a
/// `group_concat(r.style_tags_json, U+001E)` of a wall's live routes' raw
/// (still JSON-encoded) style-tag lists -- into a flattened, deduplicated
/// set of decoded tag keys. Each joined segment is independently decoded via
/// [decodeStyleTags] (app-side, rather than unnesting the JSON in SQL via
/// `json_each`, which would need the SQLite JSON1 extension and a fragile
/// hand-rolled unnest query) and folded into one set. `null` (no matching
/// rows) or an empty string both yield an empty set.
Set<String> _parseStyleTags(String? raw) {
  if (raw == null || raw.isEmpty) return const {};
  final tags = <String>{};
  for (final segment in raw.split(_kStyleTagsGroupSeparator)) {
    for (final tag in decodeStyleTags(segment)) {
      final trimmed = tag.trim().toLowerCase();
      if (trimmed.isNotEmpty) tags.add(trimmed);
    }
  }
  return tags;
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
  ///
  /// #12/#13 fix: the thumbnail AND every route aggregate (`route_count`,
  /// `top_grade_*`, `route_grade_keys`, `route_styles`,
  /// `route_style_tags_json`) are scoped to the wall's PRIMARY live original
  /// photo (via [_kPrimaryPhotoIdSubquery]), matching what the detail
  /// screen's canvas opens and which photo's Routes list it shows. Before
  /// this fix, the thumbnail picked the newest live photo regardless of
  /// `is_primary`, and the route aggregates summed routes across ALL of the
  /// wall's live photos — either could disagree with the detail screen for
  /// any wall with more than one live original.
  Stream<List<SharedTopo>> watchSharedTopos() {
    const sql = '''
      SELECT
        w.id AS wall_id,
        w.name AS wall_name,
        w.owner_id AS owner_id,
        w.latitude AS latitude,
        w.longitude AS longitude,
        w.created_at AS created_at,
        w.updated_at AS updated_at,
        (SELECT p.local_path FROM photos p
           WHERE p.wall_id = w.id AND p.kind = 'original' AND p.deleted_at IS NULL
           ORDER BY p.is_primary DESC, p.created_at DESC, p.id DESC LIMIT 1) AS thumbnail_path,
        (SELECT COUNT(*) FROM routes r
           WHERE r.photo_id = $_kPrimaryPhotoIdSubquery
             AND r.deleted_at IS NULL) AS route_count,
        (SELECT r.grade_raw FROM routes r
           WHERE r.photo_id = $_kPrimaryPhotoIdSubquery
             AND r.deleted_at IS NULL
             AND r.grade_sort_key IS NOT NULL
           ORDER BY r.grade_sort_key DESC, r.id DESC LIMIT 1) AS top_grade_raw,
        (SELECT r.grade_sort_key FROM routes r
           WHERE r.photo_id = $_kPrimaryPhotoIdSubquery
             AND r.deleted_at IS NULL
             AND r.grade_sort_key IS NOT NULL
           ORDER BY r.grade_sort_key DESC, r.id DESC LIMIT 1) AS top_grade_sort_key,
        (SELECT COUNT(*) FROM likes l
           WHERE l.wall_id = w.id AND l.deleted_at IS NULL) AS like_count,
        (SELECT COUNT(*) FROM comments c
           WHERE c.wall_id = w.id AND c.deleted_at IS NULL) AS comment_count,
        (SELECT COUNT(*) FROM ascents asc_
           WHERE asc_.wall_id = w.id AND asc_.deleted_at IS NULL) AS ascent_count,
        (SELECT MAX(v.created_at) FROM topo_verification_rows v
           WHERE v.wall_id = w.id AND v.accurate = 1) AS last_verified_at,
        (SELECT group_concat(DISTINCT r.grade_sort_key) FROM routes r
           WHERE r.photo_id = $_kPrimaryPhotoIdSubquery
             AND r.deleted_at IS NULL
             AND r.grade_sort_key IS NOT NULL) AS route_grade_keys,
        (SELECT group_concat(DISTINCT r.style) FROM routes r
           WHERE r.photo_id = $_kPrimaryPhotoIdSubquery
             AND r.deleted_at IS NULL
             AND r.style IS NOT NULL AND r.style != '') AS route_styles,
        (SELECT group_concat(r.style_tags_json, '$_kStyleTagsGroupSeparator') FROM routes r
           WHERE r.photo_id = $_kPrimaryPhotoIdSubquery
             AND r.deleted_at IS NULL
             AND r.style_tags_json IS NOT NULL) AS route_style_tags_json
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
            // Phase 8c: both feed the rank, and both must re-emit — logging an
            // ascent or confirming a topo has to move it under `FeedSort.top`
            // without a restart.
            _db.ascents,
            _db.topoVerificationRows,
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
                routeStyleTags: _parseStyleTags(
                  row.readNullable<String>('route_style_tags_json'),
                ),
                createdAt: row.read<int>('created_at'),
                updatedAt: row.read<int>('updated_at'),
                ascentCount: row.read<int>('ascent_count'),
                lastVerifiedAt: row.readNullable<int>('last_verified_at'),
              ),
          ];
        });
  }

  /// Resolves a stored thumbnail `localPath` to an absolute display path for
  /// the feed's small tile, passing `null` through unchanged (walls with no
  /// photo). Mirrors `LibraryCrudRepository._resolveThumbnail` (#56 fix):
  /// [thumbKeyFor] derives the downscaled `thumbs/<id>.jpg` key BEFORE
  /// resolving via [PhotoFiles.resolvePhotoPathSync], so the Community feed
  /// decodes the small thumbnail rather than the full-resolution original.
  /// A photo that predates thumbnail generation resolves to a path that
  /// doesn't exist on disk, which degrades to [PhotoImage]'s `placeholder`
  /// gradient like any other unreadable photo — never a blank tile.
  String? _resolveThumbnail(String? storedThumbnailPath) {
    if (storedThumbnailPath == null) return null;
    return _photoFiles
        .resolvePhotoPathSync(thumbKeyFor(storedThumbnailPath))
        .path;
  }
}
