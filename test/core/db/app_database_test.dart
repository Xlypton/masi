import 'package:masi/core/db/app_database.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  test('schemaVersion is 15', () {
    expect(
      db.schemaVersion,
      15,
      reason: 'bumping this is only correct alongside a matching `if (from < '
          'N)` branch in AppDatabase.migration and a v(N-1) -> vN group in '
          'app_database_migration_test.dart — the version alone migrates '
          'nothing.',
    );
  });

  test('insert and read back one row per table, satisfying FKs', () async {
    final now = DateTime.now().millisecondsSinceEpoch;

    const areaId = 'area-1';
    const sectorId = 'sector-1';
    const wallId = 'wall-1';
    const photoId = 'photo-1';
    const routeId = 'route-1';

    await db
        .into(db.areas)
        .insert(
          AreasCompanion.insert(
            id: areaId,
            createdAt: now,
            updatedAt: now,
            name: 'Test Area',
          ),
        );

    await db
        .into(db.sectors)
        .insert(
          SectorsCompanion.insert(
            id: sectorId,
            createdAt: now,
            updatedAt: now,
            areaId: areaId,
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
            sectorId: sectorId,
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
            width: 1024,
            height: 768,
          ),
        );

    await db
        .into(db.routes)
        .insert(
          RoutesCompanion.insert(
            id: routeId,
            createdAt: now,
            updatedAt: now,
            wallId: wallId,
            photoId: photoId,
            number: 1,
            colorIndex: 0,
            pointsJson: '[]',
            symbolsJson: '[]',
            sortOrder: 0,
          ),
        );

    final area = await (db.select(
      db.areas,
    )..where((t) => t.id.equals(areaId))).getSingle();
    expect(area.name, 'Test Area');
    expect(area.dirty, false);
    expect(area.deletedAt, isNull);

    final sector = await (db.select(
      db.sectors,
    )..where((t) => t.id.equals(sectorId))).getSingle();
    expect(sector.areaId, areaId);
    expect(sector.name, 'Test Sector');

    final wall = await (db.select(
      db.walls,
    )..where((t) => t.id.equals(wallId))).getSingle();
    expect(wall.sectorId, sectorId);
    expect(wall.name, 'Test Wall');

    final photo = await (db.select(
      db.photos,
    )..where((t) => t.id.equals(photoId))).getSingle();
    expect(photo.wallId, wallId);
    expect(photo.kind, 'original');
    expect(photo.width, 1024);
    expect(photo.height, 768);

    final route = await (db.select(
      db.routes,
    )..where((t) => t.id.equals(routeId))).getSingle();
    expect(route.wallId, wallId);
    expect(route.photoId, photoId);
    expect(route.number, 1);
    expect(route.colorIndex, 0);
    expect(route.pointsJson, '[]');
    expect(route.symbolsJson, '[]');
  });
}
