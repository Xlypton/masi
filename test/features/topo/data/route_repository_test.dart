import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/features/topo/data/route_repository.dart';
import 'package:climbtopo/features/topo/domain/topo_route.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late RouteRepository repo;
  const wallId = 'wall-1';
  const photoId = 'photo-1';

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    repo = RouteRepository(db, nowMs: () => 1000);

    const now = 1000;
    await db
        .into(db.areas)
        .insert(
          AreasCompanion.insert(
            id: 'area-1',
            createdAt: now,
            updatedAt: now,
            name: 'Test Area',
          ),
        );
    await db
        .into(db.sectors)
        .insert(
          SectorsCompanion.insert(
            id: 'sector-1',
            createdAt: now,
            updatedAt: now,
            areaId: 'area-1',
            name: 'Test Sector',
            sortOrder: 0,
          ),
        );
    await db
        .into(db.walls)
        .insert(
          WallsCompanion.insert(
            id: wallId,
            createdAt: now,
            updatedAt: now,
            sectorId: 'sector-1',
            name: 'Test Wall',
            sortOrder: 0,
          ),
        );
    await db
        .into(db.photos)
        .insert(
          PhotosCompanion.insert(
            id: photoId,
            createdAt: now,
            updatedAt: now,
            wallId: wallId,
            localPath: '/tmp/photo.jpg',
            kind: 'original',
            width: 100,
            height: 200,
          ),
        );
  });

  tearDown(() async {
    await db.close();
  });

  test(
    'A1: upsertRoute then loadRoutes round-trips points/symbols/number/colorIndex',
    () async {
      final route = TopoRoute(
        id: 1,
        number: 1,
        points: const [
          Offset(1.5, 2.5),
          Offset(10.25, 20.75),
        ],
        symbols: const [
          TopoSymbol(type: SymbolType.anchor, position: Offset(1.5, 2.5)),
          TopoSymbol(type: SymbolType.crux, position: Offset(3.0, 4.0)),
        ],
        colorIndex: 3,
      );

      await repo.upsertRoute(wallId, photoId, route);
      final loaded = await repo.loadRoutes(wallId);

      expect(loaded, hasLength(1));
      expect(loaded.single.number, 1);
      expect(loaded.single.colorIndex, 3);
      expect(loaded.single.points, route.points);
      expect(loaded.single.symbols, route.symbols);
      expect(loaded.single.visible, isTrue);
    },
  );

  test('upsertRoute persists visible:false and loadRoutes round-trips it',
      () async {
    final route = TopoRoute(
      id: 1,
      number: 1,
      points: const [Offset(0, 0)],
      visible: false,
    );

    await repo.upsertRoute(wallId, photoId, route);
    final loaded = await repo.loadRoutes(wallId);

    expect(loaded, hasLength(1));
    expect(loaded.single.visible, isFalse);
  });

  test('upsertRoute persists visible:true and loadRoutes round-trips it',
      () async {
    final route = TopoRoute(
      id: 1,
      number: 1,
      points: const [Offset(0, 0)],
      visible: true,
    );

    await repo.upsertRoute(wallId, photoId, route);
    final loaded = await repo.loadRoutes(wallId);

    expect(loaded, hasLength(1));
    expect(loaded.single.visible, isTrue);
  });

  test(
    'updating a route to visible:false is not filtered out by loadRoutes',
    () async {
      final v1 = TopoRoute(
        id: 1,
        number: 1,
        points: const [Offset(0, 0)],
        visible: true,
      );
      await repo.upsertRoute(wallId, photoId, v1);

      final v2 = TopoRoute(
        id: 1,
        number: 1,
        points: const [Offset(0, 0)],
        visible: false,
      );
      await repo.upsertRoute(wallId, photoId, v2);

      final loaded = await repo.loadRoutes(wallId);
      expect(loaded, hasLength(1));
      expect(loaded.single.visible, isFalse);
    },
  );

  test('upsertRoute updates the existing row for the same number', () async {
    final v1 = TopoRoute(
      id: 1,
      number: 1,
      points: const [Offset(0, 0)],
      colorIndex: 0,
    );
    await repo.upsertRoute(wallId, photoId, v1);

    final v2 = TopoRoute(
      id: 1,
      number: 1,
      points: const [Offset(9, 9), Offset(8, 8)],
      colorIndex: 5,
    );
    await repo.upsertRoute(wallId, photoId, v2);

    final rows = await db.select(db.routes).get();
    expect(rows, hasLength(1));

    final loaded = await repo.loadRoutes(wallId);
    expect(loaded, hasLength(1));
    expect(loaded.single.colorIndex, 5);
    expect(loaded.single.points, v2.points);
  });

  test(
    'A2: softDeleteRoute tombstones the row instead of removing it',
    () async {
      final route = TopoRoute(id: 1, number: 1, points: const [Offset(0, 0)]);
      await repo.upsertRoute(wallId, photoId, route);

      await repo.softDeleteRoute(wallId, 1);

      final loaded = await repo.loadRoutes(wallId);
      expect(loaded, isEmpty);

      final raw = await db.select(db.routes).get();
      expect(raw, hasLength(1));
      expect(raw.single.deletedAt, isNotNull);
      expect(raw.single.wallId, wallId);
      expect(raw.single.number, 1);
    },
  );

  test('A5: loadRoutes orders by number and assigns sequential ids', () async {
    await repo.upsertRoute(
      wallId,
      photoId,
      TopoRoute(id: 1, number: 3, points: const [Offset(0, 0)]),
    );
    await repo.upsertRoute(
      wallId,
      photoId,
      TopoRoute(id: 2, number: 1, points: const [Offset(0, 0)]),
    );
    await repo.upsertRoute(
      wallId,
      photoId,
      TopoRoute(id: 3, number: 2, points: const [Offset(0, 0)]),
    );

    final loaded = await repo.loadRoutes(wallId);

    expect(loaded.map((r) => r.number).toList(), [1, 2, 3]);
    expect(loaded.map((r) => r.id).toList(), [1, 2, 3]);
  });

  test(
    'fix (c): soft-deleting a route then upserting a new live route with '
    'the same (wallId, number) succeeds, and loadRoutes returns only the '
    'new one',
    () async {
      final v1 = TopoRoute(id: 1, number: 1, points: const [Offset(0, 0)]);
      await repo.upsertRoute(wallId, photoId, v1);
      await repo.softDeleteRoute(wallId, 1);

      final v2 = TopoRoute(
        id: 1,
        number: 1,
        points: const [Offset(9, 9)],
        colorIndex: 2,
      );
      await repo.upsertRoute(wallId, photoId, v2);

      final loaded = await repo.loadRoutes(wallId);
      expect(loaded, hasLength(1));
      expect(loaded.single.colorIndex, 2);
      expect(loaded.single.points, v2.points);

      final raw = await db.select(db.routes).get();
      expect(
        raw,
        hasLength(2),
        reason: 'the soft-deleted tombstone remains alongside the new row',
      );
    },
  );

  test(
    'fix (c): the partial unique index rejects two live rows for the same '
    '(wallId, number) inserted directly (bypassing the repository)',
    () async {
      final v1 = TopoRoute(id: 1, number: 1, points: const [Offset(0, 0)]);
      await repo.upsertRoute(wallId, photoId, v1);

      // Bypass RouteRepository.upsertRoute's own existing-row check to
      // exercise the DB-level constraint directly.
      final duplicateInsert = db
          .into(db.routes)
          .insert(
            RoutesCompanion.insert(
              id: 'route-duplicate',
              createdAt: 1000,
              updatedAt: 1000,
              wallId: wallId,
              photoId: photoId,
              number: 1,
              colorIndex: 0,
              pointsJson: '[]',
              symbolsJson: '[]',
              sortOrder: 1,
            ),
          );

      await expectLater(duplicateInsert, throwsA(anything));

      final raw = await db.select(db.routes).get();
      expect(raw, hasLength(1));
    },
  );

  test('updatedAt always refreshes; createdAt only set on insert', () async {
    final repoAtT1 = RouteRepository(db, nowMs: () => 1000);
    final repoAtT2 = RouteRepository(db, nowMs: () => 2000);

    await repoAtT1.upsertRoute(
      wallId,
      photoId,
      TopoRoute(id: 1, number: 1, points: const [Offset(0, 0)]),
    );
    final afterInsert = await db.select(db.routes).getSingle();
    expect(afterInsert.createdAt, 1000);
    expect(afterInsert.updatedAt, 1000);

    await repoAtT2.upsertRoute(
      wallId,
      photoId,
      TopoRoute(id: 1, number: 1, points: const [Offset(1, 1)]),
    );
    final afterUpdate = await db.select(db.routes).getSingle();
    expect(afterUpdate.createdAt, 1000);
    expect(afterUpdate.updatedAt, 2000);
  });
}
