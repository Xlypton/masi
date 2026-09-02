import 'dart:ui' show Offset;

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/db/app_database.dart' as db;
import '../../../core/routes/route_styles.dart';
import '../domain/topo_route.dart';
import 'route_mapper.dart';

/// Persists [TopoRoute] domain objects to the `Routes` table.
///
/// Identity choice: a route is identified for upsert/delete purposes by the
/// pair `(wallId, number)` rather than by a caller-managed uuid. The M2
/// domain model's [TopoRoute.id] is a small sequential int reassigned on
/// every [loadRoutes] call (1..n, in `number` order) — it is not a stable
/// identity — so `number` is the natural key.
///
/// ## A route is a climb, not a drawing (schema v16)
///
/// This used to be scoped per PHOTO: each photo on a wall had its own
/// independent set of overlays and its own numbering, so a wall with three
/// photos could hold three different "route 1"s. That model could not express
/// the thing the rock actually does. A line that wraps an arête is ONE climb
/// photographed twice, and per-photo routes made it two — two names, two
/// grades, two logbook entries, two sets of ascents, and no way for anybody
/// to say which of them they climbed.
///
/// So `number` is now unique per WALL, and a `routes` row is the CLIMB: the
/// name, the grade, the stars, and the thing `Ascents.routeId`,
/// `GradeOpinionRows.routeId` and `TopoHazardRows.routeId` have always
/// pointed at. Its geometry on its HOME photo lives on the row itself
/// (`photoId`/`pointsJson`); the same climb drawn on any OTHER photo lives in
/// `route_lines`, with its own points and symbols.
///
/// What that buys, concretely: drawing route 3 again on the south face does
/// not overwrite the arête drawing, editing its grade from either photo
/// changes one grade, and an ascent logged from either photo lands on one
/// climb.
///
/// [wallId] is still carried on every row (denormalized) for cheap wall-wide
/// aggregates (e.g. `LibraryCrudRepository.watchTopos`'s route count).
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

  /// Inserts a new climb, updates an existing one, or records the same climb
  /// as drawn on another photo — decided by where the climb already lives.
  ///
  /// Three cases, and the third is the whole point of the v16 split:
  ///
  ///  * no live route numbered `route.number` on this wall → insert one, with
  ///    [photoId] as its home photo.
  ///  * one exists and [photoId] IS its home photo → update it, geometry
  ///    included. The pre-v16 behaviour, unchanged.
  ///  * one exists and [photoId] is NOT its home photo → the contributor is
  ///    drawing the same climb on a second photo. The geometry goes to a
  ///    `route_lines` row for this photo, leaving the home drawing intact,
  ///    while the SHARED data (name, grade, stars, tags, description, beta
  ///    link, colour, visibility) is written to the climb, because editing a
  ///    grade from the south face and from the arête must change one grade.
  ///
  /// Sets `createdAt` only on insert; always refreshes `updatedAt` to
  /// `nowMs()`. Always sets `dirty: true` (§1e) so a route-only edit is
  /// visible to `SyncService.hasPendingLocalChanges`/`PushScope.dirtyOnly`
  /// immediately, instead of only reaching the cloud on the next
  /// `PushScope.full` push.
  Future<void> upsertRoute(
    String wallId,
    String photoId,
    TopoRoute route,
  ) async {
    final existing =
        await (_db.select(_db.routes)..where(
              (t) =>
                  t.wallId.equals(wallId) &
                  t.number.equals(route.number) &
                  t.deletedAt.isNull(),
            ))
            .getSingleOrNull();

    if (existing != null && existing.photoId != photoId) {
      await _upsertRouteLine(existing, photoId, route);
      return;
    }

    final now = nowMs();
    final pointsJson = encodePoints(route.points);
    final symbolsJson = encodeSymbols(route.symbols);
    // `null` (not the encoded `'[]'`) for an empty tag list, so a route
    // with no style tags stays indistinguishable from one that predates
    // this column — mirrors `styleTagsJson`'s own doc.
    final styleTagsJson = route.styleTags.isEmpty
        ? null
        : encodeStyleTags(route.styleTags);

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

  /// Records [route]'s geometry as [existing]'s line on [photoId], and folds
  /// the edit's SHARED fields back onto the climb.
  ///
  /// The split of which columns go where is the feature: points and symbols
  /// describe this photo, everything else describes the climb. Writing the
  /// shared fields here rather than ignoring them is what makes "edit the
  /// grade from whichever photo you happen to be looking at" work; writing
  /// them to the climb rather than to the line is what stops two drawings
  /// drifting into two different grades.
  ///
  /// Deliberately does NOT touch the climb's `photoId` or `pointsJson`.
  /// Drawing on a second photo must leave the first drawing exactly as it
  /// was — that is the difference between this feature and the overwrite it
  /// replaces.
  Future<void> _upsertRouteLine(
    db.Route existing,
    String photoId,
    TopoRoute route,
  ) async {
    final now = nowMs();
    final styleTagsJson = route.styleTags.isEmpty
        ? null
        : encodeStyleTags(route.styleTags);

    await _db.transaction(() async {
      final line =
          await (_db.select(_db.routeLines)..where(
                (t) =>
                    t.routeId.equals(existing.id) &
                    t.photoId.equals(photoId) &
                    t.deletedAt.isNull(),
              ))
              .getSingleOrNull();

      final pointsJson = encodePoints(route.points);
      final symbolsJson = encodeSymbols(route.symbols);

      if (line == null) {
        await _db
            .into(_db.routeLines)
            .insert(
              db.RouteLinesCompanion.insert(
                id: _uuid.v4(),
                createdAt: now,
                updatedAt: now,
                routeId: existing.id,
                photoId: photoId,
                pointsJson: pointsJson,
                symbolsJson: symbolsJson,
                // Stamped from the climb rather than from `currentUid()`: a
                // line is part of the climb's topo, and an owner mismatch
                // between the two would leave the line unpushable by the
                // person who owns the thing it belongs to.
                ownerId: Value(existing.ownerId ?? currentUid()),
                dirty: const Value(true),
              ),
            );
      } else {
        await (_db.update(
          _db.routeLines,
        )..where((t) => t.id.equals(line.id))).write(
          db.RouteLinesCompanion(
            updatedAt: Value(now),
            pointsJson: Value(pointsJson),
            symbolsJson: Value(symbolsJson),
            dirty: const Value(true),
          ),
        );
      }

      await (_db.update(
        _db.routes,
      )..where((t) => t.id.equals(existing.id))).write(
        db.RoutesCompanion(
          updatedAt: Value(now),
          name: Value(route.name),
          gradeSystem: Value(route.gradeSystem?.name),
          gradeRaw: Value(route.gradeRaw),
          gradeSortKey: Value(route.gradeSortKey),
          style: Value(route.style),
          description: Value(route.description),
          colorIndex: Value(route.colorIndex),
          visible: Value(route.visible),
          betaVideoUrl: Value(route.betaVideoUrl),
          styleTagsJson: Value(styleTagsJson),
          stars: Value(route.stars),
          dirty: const Value(true),
        ),
      );
    });
  }

  /// Loads every climb visible on [photoId] — the ones whose HOME photo it is
  /// plus the ones merely DRAWN on it — ordered by `number`, assigning
  /// sequential in-memory ids `1..n`. Callers must reseed their own "next id"
  /// / "next number" counters from the returned list.
  ///
  /// The union is the read half of the v16 split, and skipping either half
  /// makes a line silently vanish: a climb whose home photo is the arête is
  /// invisible on the south face if only home rows are read, and every climb
  /// disappears from its own home photo if only lines are.
  Future<List<TopoRoute>> loadRoutes(String wallId, String photoId) async {
    final homeRows =
        await (_db.select(_db.routes)..where(
              (t) =>
                  t.wallId.equals(wallId) &
                  t.photoId.equals(photoId) &
                  t.deletedAt.isNull(),
            ))
            .get();

    final lineQuery =
        _db.select(_db.routeLines).join([
          innerJoin(
            _db.routes,
            _db.routes.id.equalsExp(_db.routeLines.routeId),
          ),
        ])..where(
          _db.routeLines.photoId.equals(photoId) &
              _db.routeLines.deletedAt.isNull() &
              _db.routes.wallId.equals(wallId) &
              _db.routes.deletedAt.isNull(),
        );
    final lineRows = await lineQuery.get();

    final combined = <({db.Route route, db.RouteLine? line})>[
      for (final row in homeRows) (route: row, line: null),
      for (final row in lineRows)
        (route: row.readTable(_db.routes), line: row.readTable(_db.routeLines)),
    ]..sort((a, b) => a.route.number.compareTo(b.route.number));

    return [
      for (var i = 0; i < combined.length; i++)
        rowToDomain(combined[i].route, i + 1, lineOverride: combined[i].line),
    ];
  }

  /// The highest climb number live on [wallId], or 0 when it has none.
  ///
  /// Numbering is WALL-wide, not per-photo: since v16 a number identifies a
  /// climb across the whole rock, and [upsertRoute] keys on `(wallId,
  /// number)`. A caller that seeds its "next number" from the climbs it can
  /// SEE — i.e. from one photo — hands the next new line a number that
  /// already belongs to a climb on another face, and [upsertRoute] then
  /// correctly reads that as "the same climb, drawn from over here". The
  /// guidebook importer already numbers this way
  /// (`guidebook_import_applier.dart`); the interactive draw path did not,
  /// which is what turned an unrelated second climb into a second line of
  /// the first, and nulled the first one's name and grade on the way.
  Future<int> maxRouteNumber(String wallId) async {
    final highest = _db.routes.number.max();
    final row =
        await (_db.selectOnly(_db.routes)
              ..addColumns([highest])
              ..where(
                _db.routes.wallId.equals(wallId) &
                    _db.routes.deletedAt.isNull(),
              ))
            .getSingleOrNull();
    return row?.read(highest) ?? 0;
  }

  /// The wall's climbs that are NOT on [photoId] — neither at home there nor
  /// drawn there — ordered by number.
  ///
  /// This is the candidate list for "the line I just drew is that climb, seen
  /// from here". It is exactly the complement of [loadRoutes]: a climb
  /// already visible on this photo cannot be drawn on it again (the partial
  /// unique index on `route_lines` forbids a second line for one photo, and
  /// its home drawing is the first), so offering one would be offering a
  /// write the database is about to refuse.
  ///
  /// The in-memory ids are 1..n over THIS list and mean nothing outside it —
  /// they are a different numbering from the one [loadRoutes] hands the
  /// canvas, so a caller must re-id anything it carries across.
  Future<List<TopoRoute>> loadClimbsElsewhere(
    String wallId,
    String photoId,
  ) async {
    final rows =
        await (_db.select(_db.routes)..where(
              (t) =>
                  t.wallId.equals(wallId) &
                  t.deletedAt.isNull() &
                  t.photoId.equals(photoId).not(),
            ))
            .get();
    final lines = await (_db.select(
      _db.routeLines,
    )..where((t) => t.photoId.equals(photoId) & t.deletedAt.isNull())).get();
    final drawnHere = {for (final line in lines) line.routeId};

    final elsewhere = [
      for (final row in rows)
        if (!drawnHere.contains(row.id)) row,
    ]..sort((a, b) => a.number.compareTo(b.number));

    return [
      for (var i = 0; i < elsewhere.length; i++)
        rowToDomain(elsewhere[i], i + 1),
    ];
  }

  /// How many climbs are visible on each photo of [wallId], live.
  ///
  /// The face rail puts this number on every thumbnail, so a reader can see
  /// which side of the rock the climbing is on before opening it. Counted the
  /// same way [loadRoutes] reads a photo: the climbs whose HOME photo it is,
  /// plus the ones merely DRAWN on it. Those two sets are disjoint by
  /// construction — `route_lines` never holds a row for a climb's own home
  /// photo (see [RouteLines.photoId] and the partial unique index that
  /// enforces it) — so adding the two counts double-counts nothing.
  ///
  /// Photos with no climbs are simply absent from the map rather than present
  /// with a zero: the caller renders no badge at all for them, and an explicit
  /// zero would only invite one.
  ///
  /// Raw [customSelect] with an explicit `readsFrom`, in this repository's
  /// map-facing style, and mapped SYNCHRONOUSLY — an async mapper on a Drift
  /// stream wedges under `flutter_test`'s fake clock.
  Stream<Map<String, int>> watchRouteCountsByPhoto(String wallId) {
    const sql = '''
      SELECT photo_id, COUNT(*) AS n FROM (
        SELECT r.photo_id AS photo_id
          FROM routes r
         WHERE r.wall_id = ?1 AND r.deleted_at IS NULL
        UNION ALL
        SELECT l.photo_id AS photo_id
          FROM route_lines l
          JOIN routes lr ON lr.id = l.route_id
         WHERE lr.wall_id = ?1
           AND l.deleted_at IS NULL
           AND lr.deleted_at IS NULL
      )
      GROUP BY photo_id
    ''';
    return _db
        .customSelect(
          sql,
          variables: [Variable<String>(wallId)],
          readsFrom: {_db.routes, _db.routeLines},
        )
        .watch()
        .map(
          (rows) => {
            for (final row in rows)
              row.read<String>('photo_id'): row.read<int>('n'),
          },
        );
  }

  /// Maps each live climb's stable [TopoRoute.number] to its underlying DB row
  /// `id` (a UUID) for [wallId] — optionally narrowed to the climbs VISIBLE on
  /// a single [photoId] (home drawings plus lines).
  ///
  /// Unlike [TopoRoute.id] — a locally-reassigned sequential int, see class
  /// doc — a route's real `id` column is the only identity another table
  /// (e.g. `Ascents.routeId`) can reference. Exposed for callers (e.g. the
  /// community feature's "log ascent" action) that need to resolve a specific
  /// route's real id from the same `number` [loadRoutes] already exposes,
  /// without leaking the full DB row shape.
  ///
  /// The [photoId] narrowing used to exist to avoid a COLLISION: numbering was
  /// per-photo, so a wall with two photos held two routes numbered `1` and an
  /// unscoped map silently kept whichever the query returned last. Since v16
  /// numbering is wall-scoped and that collision cannot occur, so passing a
  /// photo is now about RELEVANCE — "the climbs on the photo in front of me" —
  /// rather than correctness, and every value in the map is the same climb id
  /// either way. That is exactly why an ascent logged from the arête and one
  /// logged from the south face now land on the same climb.
  Future<Map<int, String>> routeDbIdsByNumber(
    String wallId, [
    String? photoId,
  ]) async {
    if (photoId == null) {
      final rows = await (_db.select(
        _db.routes,
      )..where((t) => t.wallId.equals(wallId) & t.deletedAt.isNull())).get();
      return {for (final row in rows) row.number: row.id};
    }

    final visible = await loadRoutes(wallId, photoId);
    if (visible.isEmpty) return const {};

    final numbers = visible.map((r) => r.number).toSet();
    final rows =
        await (_db.select(_db.routes)..where(
              (t) =>
                  t.wallId.equals(wallId) &
                  t.number.isIn(numbers) &
                  t.deletedAt.isNull(),
            ))
            .get();
    return {for (final row in rows) row.number: row.id};
  }

  /// Soft-deletes what the contributor is actually looking at.
  ///
  /// On the climb's HOME photo that is the climb itself, tombstoned together
  /// with every line of it on other photos — deleting the drawing you called
  /// the climb by must not leave orphan lines of a climb that no longer
  /// exists. On any OTHER photo it is just that photo's line: the climb, its
  /// grade, its ascents and its home drawing all survive, which is what
  /// "remove this line from this photo" has to mean once one climb can be
  /// drawn several times.
  ///
  /// Rows stay physically present (tombstones) for future sync, and are
  /// marked `dirty: true` (§1e) so they push promptly — otherwise a route
  /// deleted locally would keep reappearing from a stale cloud copy until the
  /// next `PushScope.full` push.
  Future<void> softDeleteRoute(
    String wallId,
    String photoId,
    int number,
  ) async {
    final now = nowMs();
    await _db.transaction(() async {
      final route =
          await (_db.select(_db.routes)..where(
                (t) =>
                    t.wallId.equals(wallId) &
                    t.number.equals(number) &
                    t.deletedAt.isNull(),
              ))
              .getSingleOrNull();
      if (route == null) return;

      if (route.photoId != photoId) {
        await (_db.update(_db.routeLines)..where(
              (t) =>
                  t.routeId.equals(route.id) &
                  t.photoId.equals(photoId) &
                  t.deletedAt.isNull(),
            ))
            .write(
              db.RouteLinesCompanion(
                deletedAt: Value(now),
                updatedAt: Value(now),
                dirty: const Value(true),
              ),
            );
        return;
      }

      // The home photo, and the climb is drawn somewhere else too: this is
      // still "remove this line from this picture", not "delete the climb".
      // The home drawing is the only one that lives on the `routes` row, so
      // removing it means PROMOTING another photo's line into its place —
      // the row keeps its id, number, name, grade, stars, tags and every
      // ascent logged against it, and simply now calls a different photo
      // home. Deleting the row instead would take a climb's whole history
      // with a drawing the contributor only meant to redo.
      final successor =
          await (_db.select(_db.routeLines)
                ..where(
                  (t) => t.routeId.equals(route.id) & t.deletedAt.isNull(),
                )
                ..orderBy([(t) => OrderingTerm(expression: t.createdAt)])
                ..limit(1))
              .getSingleOrNull();
      if (successor != null) {
        await (_db.update(
          _db.routes,
        )..where((t) => t.id.equals(route.id))).write(
          db.RoutesCompanion(
            photoId: Value(successor.photoId),
            pointsJson: Value(successor.pointsJson),
            symbolsJson: Value(successor.symbolsJson),
            updatedAt: Value(now),
            dirty: const Value(true),
          ),
        );
        // The promoted line must not also survive as a `route_lines` row:
        // the partial unique index forbids a line on the climb's own home
        // photo, and a duplicate would render the same drawing twice.
        await (_db.update(
          _db.routeLines,
        )..where((t) => t.id.equals(successor.id))).write(
          db.RouteLinesCompanion(
            deletedAt: Value(now),
            updatedAt: Value(now),
            dirty: const Value(true),
          ),
        );
        return;
      }

      // The last picture this climb was on. Only now does deleting the
      // drawing delete the climb, together with any (already absent) lines.
      await (_db.update(
        _db.routeLines,
      )..where((t) => t.routeId.equals(route.id) & t.deletedAt.isNull())).write(
        db.RouteLinesCompanion(
          deletedAt: Value(now),
          updatedAt: Value(now),
          dirty: const Value(true),
        ),
      );
      await (_db.update(_db.routes)..where((t) => t.id.equals(route.id))).write(
        db.RoutesCompanion(
          deletedAt: Value(now),
          updatedAt: Value(now),
          dirty: const Value(true),
        ),
      );
    });
  }

  /// Renumbers every live climb on [wallId] 1..n in reading order — left to
  /// right across each photo, photos in strip order — and returns the
  /// `oldNumber -> newNumber` map of what moved (empty when nothing did).
  ///
  /// Numbers used to be handed out in the order lines were DRAWN, which is
  /// the one order a guidebook never uses: draw the left-hand line last and
  /// it is numbered 4 on a wall whose numbers otherwise read 3, 1, 2 from
  /// the path (user request, 2026-09-02: "renumber routes if needed, always
  /// show the route number from left to right"). A topo is read at the rock
  /// by walking along the base, so the numbers have to run the same way.
  ///
  /// **Ordering key**, in order: the photo's position in the rail
  /// ([db.Photos.sortOrder], which is capture order until somebody reorders
  /// it by hand), then whether the climb has a line at all (one that does not
  /// cannot be placed, and goes last), then the horizontal position of the
  /// line's BASE — the bottom-most point, i.e. where a climber starts, not
  /// where the line
  /// happens to end up on the topout — then the number the climb already had,
  /// and finally the row id. The last two are not decoration: this runs
  /// locally on each device and sync reconciles the results by
  /// last-writer-wins, with no notion of "these two disagree", so the order
  /// has to be a total one that every device computes the same way. Ordering
  /// ties by the existing number also means a wall where nothing has moved
  /// keeps every number it had.
  ///
  /// Only the climb's HOME line is consulted. A climb drawn on three photos
  /// still has exactly one number, and the photo it calls home is the one
  /// that places it.
  ///
  /// [db.Routes.colorIndex] is recomputed with the number, because it has
  /// always been a pure function of it ([routeColorIndexFor]) and every
  /// other writer derives it that way; leaving it behind would put two
  /// neighbours in one colour.
  ///
  /// Rows that move are marked `dirty` — unlike the v16 migration's
  /// renumber, which every device computed identically for itself. This one
  /// follows an edit, so the other devices have to be told.
  Future<Map<int, int>> renumberByPosition(String wallId) async {
    return _db.transaction(() async {
      final rows = await (_db.select(
        _db.routes,
      )..where((t) => t.wallId.equals(wallId) & t.deletedAt.isNull())).get();
      if (rows.isEmpty) return const <int, int>{};

      final photoOrder = <String, int>{
        for (final photo in await (_db.select(
          _db.photos,
        )..where((t) => t.wallId.equals(wallId) & t.deletedAt.isNull())).get())
          photo.id: photo.sortOrder,
      };

      final keyed =
          [
            for (final row in rows)
              (
                row: row,
                photoOrder: photoOrder[row.photoId] ?? 0,
                base: _base(row.pointsJson),
              ),
          ]..sort((a, b) {
            final byPhoto = a.photoOrder.compareTo(b.photoOrder);
            if (byPhoto != 0) return byPhoto;
            // A climb with no line yet has no position, so it cannot be
            // placed among the ones that do. It goes after them, keeping the
            // order it already had. Treating "no geometry" as x = 0 would put
            // it leftmost — and a guidebook import is a whole wall of exactly
            // that: named, graded, numbered climbs that are nobody's to draw
            // yet ('this route is yours to draw'). They would all jump the
            // queue and renumber the drawn ones behind them.
            final byPlaced = (a.base == null ? 1 : 0).compareTo(
              b.base == null ? 1 : 0,
            );
            if (byPlaced != 0) return byPlaced;
            final byX = (a.base ?? 0).compareTo(b.base ?? 0);
            if (byX != 0) return byX;
            // Two lines starting at the same x keep the order they already
            // had. Falling straight through to the row id (a uuid) would be
            // deterministic but arbitrary, and would reshuffle a wall whose
            // numbering nobody had any reason to disturb — including one
            // imported with placeholder geometry, where every line starts at
            // the same place.
            final byNumber = a.row.number.compareTo(b.row.number);
            if (byNumber != 0) return byNumber;
            return a.row.id.compareTo(b.row.id);
          });

      final moved = <int, int>{};
      for (var i = 0; i < keyed.length; i++) {
        final current = keyed[i].row.number;
        if (current != i + 1) moved[current] = i + 1;
      }
      if (moved.isEmpty) return const <int, int>{};

      final now = nowMs();
      // Two passes, because `idx_routes_wall_number_live` is a UNIQUE index
      // and swapping two climbs writes one of them onto a number the other
      // still holds. Negative numbers are the parking space: they are unique
      // among themselves, no other query on this table filters by sign, and
      // the whole thing is inside one transaction, so nothing outside ever
      // observes a climb numbered -2.
      for (var i = 0; i < keyed.length; i++) {
        if (!moved.containsKey(keyed[i].row.number)) continue;
        await (_db.update(_db.routes)
              ..where((t) => t.id.equals(keyed[i].row.id)))
            .write(db.RoutesCompanion(number: Value(-(i + 1))));
      }
      for (var i = 0; i < keyed.length; i++) {
        if (!moved.containsKey(keyed[i].row.number)) continue;
        await (_db.update(
          _db.routes,
        )..where((t) => t.id.equals(keyed[i].row.id))).write(
          db.RoutesCompanion(
            number: Value(i + 1),
            colorIndex: Value(routeColorIndexFor(i + 1)),
            sortOrder: Value(i + 1),
            updatedAt: Value(now),
            dirty: const Value(true),
          ),
        );
      }
      return moved;
    });
  }

  /// The x of the bottom-most point of an encoded line — where the climb
  /// starts — or null when there is no line to read one from.
  ///
  /// Null covers both the unplaced climb (an import that could not read a
  /// polyline leaves `[]`) and geometry that will not decode. Neither can be
  /// positioned, and the sort above puts both after everything it can place
  /// rather than guessing a coordinate for them.
  static double? _base(String pointsJson) {
    final List<Offset> points;
    try {
      points = decodePoints(pointsJson);
    } catch (_) {
      return null;
    }
    if (points.isEmpty) return null;
    // Percent space, y growing DOWNWARD (see CoordinateTransformer): the
    // base of the line is its largest y, not its smallest.
    var base = points.first;
    for (final p in points) {
      if (p.dy > base.dy) base = p;
    }
    return base.dx;
  }
}
