import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/db/app_database.dart' as db;
import '../../../core/routes/route_styles.dart';
import '../domain/topo_route.dart';
import 'route_mapper.dart';

/// Persists [TopoRoute] domain objects to the `Routes` table.
///
/// Identity choice: a route is identified for upsert/delete purposes by the
/// pair `(photoId, number)` rather than by a caller-managed uuid. The M2
/// domain model's [TopoRoute.id] is a small sequential int reassigned on
/// every [loadRoutes] call (1..n, in `number` order) — it is not a stable
/// identity — so `number` (which the controller treats as stable per
/// PHOTO — see the multi-photo-per-topo feature doc on `Routes`'
/// `@TableIndex.sql` in `tables.dart`) is the natural key. Each route still
/// gets its own uuid `id` column in the database; callers of this
/// repository never need to see it.
///
/// Per-photo scoping: each photo on a wall has its OWN independent set of
/// route overlays/numbering (a wall with 3 photos can have 3 different
/// "route 1"s, one per photo) — [loadRoutes]/[upsertRoute]'s existing-row
/// lookup/[softDeleteRoute] are all scoped by `photoId`, not just `wallId`.
/// [wallId] is still carried on every row (denormalized) for cheap
/// wall-wide aggregates (e.g. `LibraryCrudRepository.watchTopos`'s route
/// count) that don't care which photo a route lives on.
class RouteRepository {
  RouteRepository(this._db, {required this.nowMs, this.currentUid = _noUid});

  final db.AppDatabase _db;
  final int Function() nowMs;

  /// The Supabase Auth uid of the signed-in user (or `null` if signed out),
  /// read lazily at INSERT time to stamp a new route's `ownerId`. Defaults
  /// to always-`null` so existing constructors/tests keep their
  /// pre-sync-pivot signed-out behavior unchanged.
  final String? Function() currentUid;

  static String? _noUid() => null;

  static const _uuid = Uuid();

  /// Inserts a new route row, or updates the existing non-deleted row for
  /// `(photoId, route.number)` if one exists. Sets `createdAt` only on
  /// insert; always refreshes `updatedAt` to `nowMs()`. Always sets
  /// `dirty: true` (§1e) so a route-only edit is visible to
  /// `SyncService.hasPendingLocalChanges`/`PushScope.dirtyOnly` immediately,
  /// instead of only reaching the cloud on the next `PushScope.full` push.
  Future<void> upsertRoute(
    String wallId,
    String photoId,
    TopoRoute route,
  ) async {
    final existing = await (_db.select(_db.routes)..where(
          (t) =>
              t.photoId.equals(photoId) &
              t.number.equals(route.number) &
              t.deletedAt.isNull(),
        ))
        .getSingleOrNull();

    final now = nowMs();
    final pointsJson = encodePoints(route.points);
    final symbolsJson = encodeSymbols(route.symbols);
    // `null` (not the encoded `'[]'`) for an empty tag list, so a route
    // with no style tags stays indistinguishable from one that predates
    // this column — mirrors `styleTagsJson`'s own doc.
    final styleTagsJson =
        route.styleTags.isEmpty ? null : encodeStyleTags(route.styleTags);

    if (existing == null) {
      await _db
          .into(_db.routes)
          .insert(
            db.RoutesCompanion.insert(
              id: _uuid.v4(),
              createdAt: now,
              updatedAt: now,
              wallId: wallId,
              photoId: photoId,
              number: route.number,
              name: Value(route.name),
              gradeSystem: Value(route.gradeSystem?.name),
              gradeRaw: Value(route.gradeRaw),
              gradeSortKey: Value(route.gradeSortKey),
              style: Value(route.style),
              description: Value(route.description),
              colorIndex: route.colorIndex,
              pointsJson: pointsJson,
              symbolsJson: symbolsJson,
              sortOrder: route.number,
              visible: Value(route.visible),
              ownerId: Value(currentUid()),
              betaVideoUrl: Value(route.betaVideoUrl),
              styleTagsJson: Value(styleTagsJson),
              stars: Value(route.stars),
              dirty: const Value(true),
            ),
          );
    } else {
      await (_db.update(
        _db.routes,
      )..where((t) => t.id.equals(existing.id))).write(
        db.RoutesCompanion(
          updatedAt: Value(now),
          photoId: Value(photoId),
          name: Value(route.name),
          gradeSystem: Value(route.gradeSystem?.name),
          gradeRaw: Value(route.gradeRaw),
          gradeSortKey: Value(route.gradeSortKey),
          style: Value(route.style),
          description: Value(route.description),
          colorIndex: Value(route.colorIndex),
          pointsJson: Value(pointsJson),
          symbolsJson: Value(symbolsJson),
          sortOrder: Value(route.number),
          visible: Value(route.visible),
          betaVideoUrl: Value(route.betaVideoUrl),
          styleTagsJson: Value(styleTagsJson),
          stars: Value(route.stars),
          dirty: const Value(true),
        ),
      );
    }
  }

  /// Loads every non-soft-deleted route for [wallId]'s [photoId] (a route
  /// belongs to the photo it's overlaid on — see this class's doc), ordered
  /// by `number`, assigning sequential in-memory ids `1..n`. Callers must
  /// reseed their own "next id" / "next number" counters from the returned
  /// list.
  Future<List<TopoRoute>> loadRoutes(String wallId, String photoId) async {
    final rows = await (_db.select(_db.routes)
          ..where(
            (t) =>
                t.wallId.equals(wallId) &
                t.photoId.equals(photoId) &
                t.deletedAt.isNull(),
          )
          ..orderBy([(t) => OrderingTerm(expression: t.number)]))
        .get();

    return [
      for (var i = 0; i < rows.length; i++) rowToDomain(rows[i], i + 1),
    ];
  }

  /// Maps each non-deleted route's stable [TopoRoute.number] to its
  /// underlying DB row `id` (a UUID) for [wallId] — optionally narrowed to
  /// a single [photoId].
  ///
  /// Unlike [TopoRoute.id] — a locally-reassigned sequential int, see class
  /// doc — a route's real `id` column is the only identity another table
  /// (e.g. `Ascents.routeId`) can reference. Exposed for callers (e.g. the
  /// community feature's "log ascent" action) that need to resolve a
  /// specific route's real id from the same `number` [loadRoutes] already
  /// exposes, without leaking the full DB row shape.
  ///
  /// Multi-photo-per-topo fix: route `number` is only stable PER PHOTO (see
  /// this class's doc) — a wall with 2+ photos can have several routes each
  /// numbered `1`, one per photo. A [wallId]-only map (the original,
  /// unscoped shape of this method) silently collides those into a single
  /// entry, keyed by whichever row the query happened to return last. Pass
  /// the CURRENTLY ACTIVE photo's id (e.g. `DrawState.activePhotoId`) here
  /// to scope the map to just that photo's routes and avoid the collision.
  ///
  /// [photoId] is optional (and defaults to `null`, meaning "every photo on
  /// this wall" — the original, pre-multi-photo behavior) purely so
  /// existing callers that only ever dealt with a single-photo wall (e.g.
  /// the community detail screen's own log-ascent resolution) keep
  /// compiling and behaving exactly as before, without every call site
  /// needing to thread a photo id through immediately.
  Future<Map<int, String>> routeDbIdsByNumber(
    String wallId, [
    String? photoId,
  ]) async {
    final rows = await (_db.select(_db.routes)..where((t) {
          final predicate = t.wallId.equals(wallId) & t.deletedAt.isNull();
          return photoId == null
              ? predicate
              : predicate & t.photoId.equals(photoId);
        }))
        .get();
    return {for (final row in rows) row.number: row.id};
  }

  /// Soft-deletes the non-deleted route identified by `(photoId, number)`
  /// by setting `deletedAt`/`updatedAt` to `nowMs()`. The row remains
  /// physically present (tombstone) for future sync. Also sets
  /// `dirty: true` (§1e) so the tombstone pushes promptly — otherwise a
  /// route deleted locally would keep reappearing from a stale cloud copy
  /// until the next `PushScope.full` push.
  ///
  /// Scoped by [photoId] (not just [wallId]): since route numbers are now
  /// per-photo (see this class's doc), a `wallId`-only scope would soft-
  /// delete every photo's route sharing that `number` on the wall instead
  /// of just the one the caller meant.
  Future<void> softDeleteRoute(
    String wallId,
    String photoId,
    int number,
  ) async {
    final now = nowMs();
    await (_db.update(_db.routes)..where(
          (t) =>
              t.wallId.equals(wallId) &
              t.photoId.equals(photoId) &
              t.number.equals(number) &
              t.deletedAt.isNull(),
        ))
        .write(
          db.RoutesCompanion(
            deletedAt: Value(now),
            updatedAt: Value(now),
            dirty: const Value(true),
          ),
        );
  }
}
