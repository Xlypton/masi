import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/db/app_database.dart' as db;
import '../domain/topo_route.dart';
import 'route_mapper.dart';

/// Persists [TopoRoute] domain objects to the `Routes` table.
///
/// Identity choice: a route is identified for upsert/delete purposes by the
/// pair `(wallId, number)` rather than by a caller-managed uuid. The M2
/// domain model's [TopoRoute.id] is a small sequential int reassigned on
/// every [loadRoutes] call (1..n, in `number` order) — it is not a stable
/// identity — so `number` (which the controller treats as stable per wall)
/// is the natural key. Each route still gets its own uuid `id` column in
/// the database; callers of this repository never need to see it.
class RouteRepository {
  RouteRepository(this._db, {required this.nowMs});

  final db.AppDatabase _db;
  final int Function() nowMs;

  static const _uuid = Uuid();

  /// Inserts a new route row, or updates the existing non-deleted row for
  /// `(wallId, route.number)` if one exists. Sets `createdAt` only on
  /// insert; always refreshes `updatedAt` to `nowMs()`.
  Future<void> upsertRoute(
    String wallId,
    String photoId,
    TopoRoute route,
  ) async {
    final existing = await (_db.select(_db.routes)..where(
          (t) =>
              t.wallId.equals(wallId) &
              t.number.equals(route.number) &
              t.deletedAt.isNull(),
        ))
        .getSingleOrNull();

    final now = nowMs();
    final pointsJson = encodePoints(route.points);
    final symbolsJson = encodeSymbols(route.symbols);

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
        ),
      );
    }
  }

  /// Loads every non-soft-deleted route for [wallId], ordered by `number`,
  /// assigning sequential in-memory ids `1..n`. Callers must reseed their
  /// own "next id" / "next number" counters from the returned list.
  Future<List<TopoRoute>> loadRoutes(String wallId) async {
    final rows = await (_db.select(_db.routes)
          ..where((t) => t.wallId.equals(wallId) & t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm(expression: t.number)]))
        .get();

    return [
      for (var i = 0; i < rows.length; i++) rowToDomain(rows[i], i + 1),
    ];
  }

  /// Soft-deletes the non-deleted route identified by `(wallId, number)` by
  /// setting `deletedAt`/`updatedAt` to `nowMs()`. The row remains
  /// physically present (tombstone) for future sync.
  Future<void> softDeleteRoute(String wallId, int number) async {
    final now = nowMs();
    await (_db.update(_db.routes)..where(
          (t) =>
              t.wallId.equals(wallId) &
              t.number.equals(number) &
              t.deletedAt.isNull(),
        ))
        .write(
          db.RoutesCompanion(
            deletedAt: Value(now),
            updatedAt: Value(now),
          ),
        );
  }
}
