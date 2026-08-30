import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/grades/grade_system.dart';
import 'package:masi/features/topo/data/route_repository.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
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
      final loaded = await repo.loadRoutes(wallId, photoId);

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
    final loaded = await repo.loadRoutes(wallId, photoId);

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
    final loaded = await repo.loadRoutes(wallId, photoId);

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

      final loaded = await repo.loadRoutes(wallId, photoId);
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

    final loaded = await repo.loadRoutes(wallId, photoId);
    expect(loaded, hasLength(1));
    expect(loaded.single.colorIndex, 5);
    expect(loaded.single.points, v2.points);
  });

  test(
    'A2: softDeleteRoute tombstones the row instead of removing it',
    () async {
      final route = TopoRoute(id: 1, number: 1, points: const [Offset(0, 0)]);
      await repo.upsertRoute(wallId, photoId, route);

      await repo.softDeleteRoute(wallId, photoId, 1);

      final loaded = await repo.loadRoutes(wallId, photoId);
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

    final loaded = await repo.loadRoutes(wallId, photoId);

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
      await repo.softDeleteRoute(wallId, photoId, 1);

      final v2 = TopoRoute(
        id: 1,
        number: 1,
        points: const [Offset(9, 9)],
        colorIndex: 2,
      );
      await repo.upsertRoute(wallId, photoId, v2);

      final loaded = await repo.loadRoutes(wallId, photoId);
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
    '(wallId, number) inserted directly (bypassing the repository). Since '
    'v16 it is wall+number that is enforced — see T-route-is-a-climb '
    'below, where redrawing the same number on another photo produces a '
    'LINE rather than a second row',
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

  test(
    'M4 A2: upsertRoute(insert path) then loadRoutes round-trips all '
    'metadata fields',
    () async {
      final route = TopoRoute(
        id: 1,
        number: 1,
        points: const [Offset(0, 0)],
        name: 'Le Toit',
        gradeSystem: GradeSystem.french,
        gradeRaw: '6a+',
        gradeSortKey: 8.0,
        style: 'sport',
        description: 'Great warm-up.',
      );

      await repo.upsertRoute(wallId, photoId, route);
      final loaded = await repo.loadRoutes(wallId, photoId);

      expect(loaded, hasLength(1));
      final result = loaded.single;
      expect(result.name, 'Le Toit');
      expect(result.gradeSystem, GradeSystem.french);
      expect(result.gradeRaw, '6a+');
      expect(result.gradeSortKey, 8.0);
      expect(result.style, 'sport');
      expect(result.description, 'Great warm-up.');
    },
  );

  test(
    'M4 A2: a route with no metadata round-trips as all-null',
    () async {
      final route = TopoRoute(
        id: 1,
        number: 1,
        points: const [Offset(0, 0)],
      );

      await repo.upsertRoute(wallId, photoId, route);
      final loaded = await repo.loadRoutes(wallId, photoId);

      expect(loaded, hasLength(1));
      final result = loaded.single;
      expect(result.name, isNull);
      expect(result.gradeSystem, isNull);
      expect(result.gradeRaw, isNull);
      expect(result.gradeSortKey, isNull);
      expect(result.style, isNull);
      expect(result.description, isNull);
    },
  );

  test(
    'M4 A3: upserting an existing (wallId,number) route with changed '
    'metadata updates it (proving the UPDATE branch writes all 6 fields)',
    () async {
      final v1 = TopoRoute(
        id: 1,
        number: 1,
        points: const [Offset(0, 0)],
        name: 'Old Name',
        gradeSystem: GradeSystem.french,
        gradeRaw: '5a',
        gradeSortKey: 4.0,
        style: 'sport',
        description: 'Old description.',
      );
      await repo.upsertRoute(wallId, photoId, v1);

      final v2 = TopoRoute(
        id: 1,
        number: 1,
        points: const [Offset(0, 0)],
        name: 'New Name',
        gradeSystem: GradeSystem.uiaa,
        gradeRaw: 'VI+',
        gradeSortKey: 8.0,
        style: 'trad',
        description: 'New description.',
      );
      await repo.upsertRoute(wallId, photoId, v2);

      final rows = await db.select(db.routes).get();
      expect(rows, hasLength(1));

      final loaded = await repo.loadRoutes(wallId, photoId);
      expect(loaded, hasLength(1));
      final result = loaded.single;
      expect(result.name, 'New Name');
      expect(result.gradeSystem, GradeSystem.uiaa);
      expect(result.gradeRaw, 'VI+');
      expect(result.gradeSortKey, 8.0);
      expect(result.style, 'trad');
      expect(result.description, 'New description.');
    },
  );

  test(
    'M4 A3: upserting an existing route WITHOUT metadata clears prior '
    'metadata via the standard TopoRoute (?? this.x) semantics is NOT '
    'expected — copyWith is domain-only; the repository always writes '
    'exactly what the route carries',
    () async {
      final v1 = TopoRoute(
        id: 1,
        number: 1,
        points: const [Offset(0, 0)],
        name: 'Has Metadata',
        gradeSystem: GradeSystem.french,
        gradeRaw: '5a',
        gradeSortKey: 4.0,
        style: 'sport',
        description: 'desc',
      );
      await repo.upsertRoute(wallId, photoId, v1);

      final v2 = TopoRoute(
        id: 1,
        number: 1,
        points: const [Offset(1, 1)],
      );
      await repo.upsertRoute(wallId, photoId, v2);

      final loaded = await repo.loadRoutes(wallId, photoId);
      expect(loaded, hasLength(1));
      final result = loaded.single;
      expect(result.name, isNull);
      expect(result.gradeSystem, isNull);
      expect(result.gradeRaw, isNull);
      expect(result.gradeSortKey, isNull);
      expect(result.style, isNull);
      expect(result.description, isNull);
    },
  );

  test(
    'M4 cleanup coverage: a fractional gradeSortKey (e.g. a UIAA grade '
    'landing between whole shared-scale indices) round-trips through '
    'upsertRoute/loadRoutes exactly, without integer truncation',
    () async {
      final route = TopoRoute(
        id: 1,
        number: 1,
        points: const [Offset(0, 0)],
        gradeSystem: GradeSystem.uiaa,
        gradeRaw: 'VII-',
        gradeSortKey: 8.5,
      );

      await repo.upsertRoute(wallId, photoId, route);
      final loaded = await repo.loadRoutes(wallId, photoId);

      expect(loaded, hasLength(1));
      expect(loaded.single.gradeSortKey, 8.5);
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

  group('per-route metadata (#41 beta-video URL, #42 style tags, #44 stars)', () {
    test(
      'upsertRoute(insert path) then loadRoutes round-trips betaVideoUrl, '
      'styleTags (incl. a custom tag), and stars',
      () async {
        final route = TopoRoute(
          id: 1,
          number: 1,
          points: const [Offset(0, 0)],
          betaVideoUrl: 'https://example.com/beta',
          styleTags: const ['dyno', 'my-custom-style'],
          stars: 3,
        );

        await repo.upsertRoute(wallId, photoId, route);
        final loaded = await repo.loadRoutes(wallId, photoId);

        expect(loaded, hasLength(1));
        final result = loaded.single;
        expect(result.betaVideoUrl, 'https://example.com/beta');
        expect(result.styleTags, ['dyno', 'my-custom-style']);
        expect(result.stars, 3);
      },
    );

    test(
      'an empty styleTags list round-trips as a null column (not the '
      'encoded empty array)',
      () async {
        final route = TopoRoute(
          id: 1,
          number: 1,
          points: const [Offset(0, 0)],
          styleTags: const [],
        );

        await repo.upsertRoute(wallId, photoId, route);

        final raw = await db.select(db.routes).getSingle();
        expect(raw.styleTagsJson, isNull);

        final loaded = await repo.loadRoutes(wallId, photoId);
        expect(loaded.single.styleTags, isEmpty);
      },
    );

    test(
      'a route with no betaVideoUrl/styleTags/stars round-trips as '
      'null/empty/null',
      () async {
        final route = TopoRoute(id: 1, number: 1, points: const [Offset(0, 0)]);

        await repo.upsertRoute(wallId, photoId, route);
        final loaded = await repo.loadRoutes(wallId, photoId);

        expect(loaded, hasLength(1));
        final result = loaded.single;
        expect(result.betaVideoUrl, isNull);
        expect(result.styleTags, isEmpty);
        expect(result.stars, isNull);
      },
    );

    test(
      'upsertRoute(update path) overwrites a previously-set betaVideoUrl/ '
      'styleTags/stars with new values',
      () async {
        final v1 = TopoRoute(
          id: 1,
          number: 1,
          points: const [Offset(0, 0)],
          betaVideoUrl: 'https://example.com/old',
          styleTags: const ['dyno'],
          stars: 1,
        );
        await repo.upsertRoute(wallId, photoId, v1);

        final v2 = TopoRoute(
          id: 1,
          number: 1,
          points: const [Offset(0, 0)],
          betaVideoUrl: 'https://example.com/new',
          styleTags: const ['crimpy', 'juggy'],
          stars: 3,
        );
        await repo.upsertRoute(wallId, photoId, v2);

        final rows = await db.select(db.routes).get();
        expect(rows, hasLength(1));

        final loaded = await repo.loadRoutes(wallId, photoId);
        final result = loaded.single;
        expect(result.betaVideoUrl, 'https://example.com/new');
        expect(result.styleTags, ['crimpy', 'juggy']);
        expect(result.stars, 3);
      },
    );

    test(
      'upsertRoute(update path) clears a previously-set betaVideoUrl/ '
      'styleTags/stars when the new route carries none',
      () async {
        final v1 = TopoRoute(
          id: 1,
          number: 1,
          points: const [Offset(0, 0)],
          betaVideoUrl: 'https://example.com/old',
          styleTags: const ['dyno'],
          stars: 2,
        );
        await repo.upsertRoute(wallId, photoId, v1);

        final v2 = TopoRoute(id: 1, number: 1, points: const [Offset(0, 0)]);
        await repo.upsertRoute(wallId, photoId, v2);

        final loaded = await repo.loadRoutes(wallId, photoId);
        final result = loaded.single;
        expect(result.betaVideoUrl, isNull);
        expect(result.styleTags, isEmpty);
        expect(result.stars, isNull);
      },
    );
  });

  group('P1-b: ownerId stamping on create', () {
    test(
      'upsertRoute(insert path) stamps ownerId with the injected '
      'currentUid',
      () async {
        final owned = RouteRepository(
          db,
          nowMs: () => 1000,
          currentUid: () => 'u1',
        );

        await owned.upsertRoute(
          wallId,
          photoId,
          TopoRoute(id: 1, number: 1, points: const [Offset(0, 0)]),
        );

        final raw = await db.select(db.routes).getSingle();
        expect(raw.ownerId, 'u1');
      },
    );

    test('default currentUid (signed-out) leaves ownerId null', () async {
      await repo.upsertRoute(
        wallId,
        photoId,
        TopoRoute(id: 1, number: 1, points: const [Offset(0, 0)]),
      );

      final raw = await db.select(db.routes).getSingle();
      expect(raw.ownerId, isNull);
    });

    test(
      'upsertRoute(update path) does not overwrite an existing ownerId',
      () async {
        final owned = RouteRepository(
          db,
          nowMs: () => 1000,
          currentUid: () => 'u1',
        );
        await owned.upsertRoute(
          wallId,
          photoId,
          TopoRoute(id: 1, number: 1, points: const [Offset(0, 0)]),
        );

        // A later update, even from a different (or signed-out) session,
        // must not touch the ownerId stamped at creation time.
        final laterSignedOut = RouteRepository(db, nowMs: () => 2000);
        await laterSignedOut.upsertRoute(
          wallId,
          photoId,
          TopoRoute(id: 1, number: 1, points: const [Offset(9, 9)]),
        );

        final raw = await db.select(db.routes).getSingle();
        expect(raw.ownerId, 'u1');
      },
    );
  });

  group('T-route-is-a-climb: numbering is wall-scoped, lines are per photo',
      () {
    const photoIdB = 'photo-2';

    setUp(() async {
      await db
          .into(db.photos)
          .insert(
            PhotosCompanion.insert(
              id: photoIdB,
              createdAt: 1000,
              updatedAt: 1000,
              wallId: wallId,
              localPath: '/tmp/photo-b.jpg',
              kind: 'original',
              width: 100,
              height: 200,
            ),
          );
    });

    test(
      'drawing the same number on a second photo records a LINE, leaving '
      'the home drawing untouched — one climb, two drawings',
      () async {
        await repo.upsertRoute(
          wallId,
          photoId,
          TopoRoute(
            id: 1,
            number: 1,
            points: const [Offset(0, 0)],
            name: 'Arete',
          ),
        );
        await repo.upsertRoute(
          wallId,
          photoIdB,
          TopoRoute(
            id: 1,
            number: 1,
            points: const [Offset(9, 9)],
            name: 'Arete',
          ),
        );

        final routeRows = await db.select(db.routes).get();
        expect(
          routeRows.where((r) => r.deletedAt == null).length,
          1,
          reason: 'a second drawing must not create a second climb',
        );
        expect(routeRows.single.photoId, photoId, reason: 'home is unchanged');

        final lines = await db.select(db.routeLines).get();
        expect(lines.length, 1);
        expect(lines.single.photoId, photoIdB);
        expect(lines.single.routeId, routeRows.single.id);

        // Each photo shows its own geometry...
        final onA = await repo.loadRoutes(wallId, photoId);
        final onB = await repo.loadRoutes(wallId, photoIdB);
        expect(onA.single.points, const [Offset(0, 0)]);
        expect(onB.single.points, const [Offset(9, 9)]);
        // ...and both are the same climb.
        expect(onA.single.number, onB.single.number);
        expect(onA.single.name, 'Arete');
        expect(onB.single.name, 'Arete');
      },
    );

    test(
      'editing shared data from the second photo changes the one climb, '
      'not a copy of it',
      () async {
        await repo.upsertRoute(
          wallId,
          photoId,
          TopoRoute(id: 1, number: 1, points: const [Offset(0, 0)]),
        );
        await repo.upsertRoute(
          wallId,
          photoIdB,
          TopoRoute(
            id: 1,
            number: 1,
            points: const [Offset(9, 9)],
            name: 'Renamed from the other photo',
            stars: 3,
          ),
        );

        final onA = await repo.loadRoutes(wallId, photoId);
        expect(onA.single.name, 'Renamed from the other photo');
        expect(onA.single.stars, 3);
        expect(
          onA.single.points,
          const [Offset(0, 0)],
          reason: 'shared data travels, geometry does not',
        );
      },
    );

    test(
      'an ascent logged from either photo resolves to the same climb id',
      () async {
        await repo.upsertRoute(
          wallId,
          photoId,
          TopoRoute(id: 1, number: 1, points: const [Offset(0, 0)]),
        );
        await repo.upsertRoute(
          wallId,
          photoIdB,
          TopoRoute(id: 1, number: 1, points: const [Offset(9, 9)]),
        );

        final fromA = await repo.routeDbIdsByNumber(wallId, photoId);
        final fromB = await repo.routeDbIdsByNumber(wallId, photoIdB);
        expect(fromA[1], isNotNull);
        expect(
          fromA[1],
          fromB[1],
          reason: 'this is the whole point of one climb, two drawings',
        );
      },
    );

    test(
      'deleting on a non-home photo removes only that line; the climb and '
      'its home drawing survive',
      () async {
        await repo.upsertRoute(
          wallId,
          photoId,
          TopoRoute(id: 1, number: 1, points: const [Offset(0, 0)]),
        );
        await repo.upsertRoute(
          wallId,
          photoIdB,
          TopoRoute(id: 1, number: 1, points: const [Offset(9, 9)]),
        );

        await repo.softDeleteRoute(wallId, photoIdB, 1);

        expect(await repo.loadRoutes(wallId, photoIdB), isEmpty);
        expect(await repo.loadRoutes(wallId, photoId), hasLength(1));
      },
    );

    test(
      'deleting on the home photo tombstones the climb AND its lines — no '
      'orphan drawing of a climb that no longer exists',
      () async {
        await repo.upsertRoute(
          wallId,
          photoId,
          TopoRoute(id: 1, number: 1, points: const [Offset(0, 0)]),
        );
        await repo.upsertRoute(
          wallId,
          photoIdB,
          TopoRoute(id: 1, number: 1, points: const [Offset(9, 9)]),
        );

        await repo.softDeleteRoute(wallId, photoId, 1);

        expect(await repo.loadRoutes(wallId, photoId), isEmpty);
        expect(await repo.loadRoutes(wallId, photoIdB), isEmpty);
        final lines = await db.select(db.routeLines).get();
        expect(lines.single.deletedAt, isNotNull);
      },
    );

    test(
      'a different number on another photo is a different climb, and both '
      'are visible on their own photo',
      () async {
        await repo.upsertRoute(
          wallId,
          photoId,
          TopoRoute(id: 1, number: 1, points: const [Offset(0, 0)]),
        );
        await repo.upsertRoute(
          wallId,
          photoIdB,
          TopoRoute(id: 1, number: 2, points: const [Offset(5, 5)]),
        );

        final routeRows = await db.select(db.routes).get();
        expect(routeRows.length, 2);
        expect(await db.select(db.routeLines).get(), isEmpty);
        expect((await repo.loadRoutes(wallId, photoId)).single.number, 1);
        expect((await repo.loadRoutes(wallId, photoIdB)).single.number, 2);
      },
    );
  });

  /// The face rail's badges: how many climbs each photo shows.
  ///
  /// It is the one thing the row of dots it replaced could never say. A dot
  /// told a reader there was a fourth face; the badge tells them whether the
  /// climbing is on it, which is what decides whether they walk round.
  group('watchRouteCountsByPhoto', () {
    const photoIdB = 'photo-2';

    setUp(() async {
      await db
          .into(db.photos)
          .insert(
            PhotosCompanion.insert(
              id: photoIdB,
              createdAt: 1000,
              updatedAt: 1000,
              wallId: wallId,
              localPath: '/tmp/photo-b.jpg',
              kind: 'original',
              width: 100,
              height: 200,
            ),
          );
    });

    test('counts a climb on every photo it is DRAWN on, and once on each',
        () async {
      // One climb, two drawings — the v16 split. It has to appear on both
      // photos (or the arete's badge lies about the south face) and exactly
      // once on each (or its home photo reads as having two climbs).
      await repo.upsertRoute(
        wallId,
        photoId,
        TopoRoute(id: 1, number: 1, points: const [Offset(0, 0)], name: 'Arete'),
      );
      await repo.upsertRoute(
        wallId,
        photoIdB,
        TopoRoute(id: 1, number: 1, points: const [Offset(9, 9)], name: 'Arete'),
      );
      // A second climb, on the second photo only.
      await repo.upsertRoute(
        wallId,
        photoIdB,
        TopoRoute(id: 2, number: 2, points: const [Offset(4, 4)]),
      );

      final counts = await repo.watchRouteCountsByPhoto(wallId).first;
      expect(counts, {photoId: 1, photoIdB: 2});
    });

    test('a photo with nothing drawn on it is ABSENT, not zero', () async {
      await repo.upsertRoute(
        wallId,
        photoId,
        TopoRoute(id: 1, number: 1, points: const [Offset(0, 0)]),
      );

      final counts = await repo.watchRouteCountsByPhoto(wallId).first;
      expect(counts.containsKey(photoIdB), isFalse);
      expect(counts[photoId], 1);
    });

    test('a deleted climb stops being counted', () async {
      await repo.upsertRoute(
        wallId,
        photoId,
        TopoRoute(id: 1, number: 1, points: const [Offset(0, 0)]),
      );
      await repo.upsertRoute(
        wallId,
        photoId,
        TopoRoute(id: 2, number: 2, points: const [Offset(1, 1)]),
      );
      await repo.softDeleteRoute(wallId, photoId, 2);

      final counts = await repo.watchRouteCountsByPhoto(wallId).first;
      expect(counts[photoId], 1);
    });
  });
}
