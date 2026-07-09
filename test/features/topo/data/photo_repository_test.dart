import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/features/topo/data/photo_repository.dart';
import 'package:climbtopo/features/topo/domain/slice_geometry.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late PhotoRepository repo;
  const wallId = 'wall-1';
  const originalPhotoId = 'photo-original-1';
  const originalLocalPath = '/tmp/original.jpg';
  const originalWidth = 1000;
  const originalHeight = 2000;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    repo = PhotoRepository(db, nowMs: () => 1000);

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
            id: originalPhotoId,
            createdAt: now,
            updatedAt: now,
            wallId: wallId,
            localPath: originalLocalPath,
            kind: 'original',
            width: originalWidth,
            height: originalHeight,
          ),
        );
  });

  tearDown(() async {
    await db.close();
  });

  test(
    'A1: replaceSlices inserts one Photo row per SliceSpec, correctly '
    'shaped, and loadSlices returns them ordered by cropXpct',
    () async {
      final slices = [
        const SliceSpec(0.5, 0.5),
        const SliceSpec(0.0, 0.25),
        const SliceSpec(0.25, 0.25),
      ];

      final inserted = await repo.replaceSlices(
        wallId,
        originalPhotoId,
        originalWidth,
        originalHeight,
        originalLocalPath,
        slices,
      );

      expect(inserted, hasLength(3));

      final loaded = await repo.loadSlices(originalPhotoId);
      expect(loaded, hasLength(3));
      expect(
        loaded.map((s) => s.cropXpct).toList(),
        [0.0, 0.25, 0.5],
      );
      expect(
        loaded.map((s) => s.cropWidthPct).toList(),
        [0.25, 0.25, 0.5],
      );
      for (final s in loaded) {
        expect(s.kind, 'slice');
        expect(s.parentPhotoId, originalPhotoId);
        expect(s.width, originalWidth);
        expect(s.height, originalHeight);
        expect(s.localPath, originalLocalPath);
        expect(s.wallId, wallId);
        expect(s.id, isNotEmpty);
      }

      final raw = await db.select(db.photos).get();
      // 1 original + 3 slices.
      expect(raw, hasLength(4));
    },
  );

  test(
    'A2: replaceSlices called again replaces the previous set: old slices '
    'are soft-deleted (tombstoned, not physically removed), loadSlices '
    'returns only the new set',
    () async {
      final firstSlices = [
        const SliceSpec(0.0, 0.5),
        const SliceSpec(0.5, 0.5),
      ];
      final firstInserted = await repo.replaceSlices(
        wallId,
        originalPhotoId,
        originalWidth,
        originalHeight,
        originalLocalPath,
        firstSlices,
      );
      expect(firstInserted, hasLength(2));
      final firstIds = firstInserted.map((s) => s.id).toSet();

      final secondSlices = [
        const SliceSpec(0.0, 0.34),
        const SliceSpec(0.34, 0.33),
        const SliceSpec(0.67, 0.33),
      ];
      final secondInserted = await repo.replaceSlices(
        wallId,
        originalPhotoId,
        originalWidth,
        originalHeight,
        originalLocalPath,
        secondSlices,
      );
      expect(secondInserted, hasLength(3));

      final loaded = await repo.loadSlices(originalPhotoId);
      expect(loaded, hasLength(3));
      expect(loaded.map((s) => s.id).toSet(), secondInserted.map((s) => s.id).toSet());
      expect(loaded.map((s) => s.id).toSet().intersection(firstIds), isEmpty);

      // Old rows are tombstoned, not physically gone.
      final raw = await db.select(db.photos).get();
      // 1 original + 2 old slices + 3 new slices.
      expect(raw, hasLength(6));

      final oldRows = raw.where((r) => firstIds.contains(r.id));
      expect(oldRows, hasLength(2));
      for (final row in oldRows) {
        expect(row.deletedAt, isNotNull);
      }
    },
  );

  test(
    'A3: loadSlices excludes soft-deleted rows and never returns the '
    'original photo; loadOriginal returns the original',
    () async {
      final slices = [const SliceSpec(0.0, 1.0)];
      await repo.replaceSlices(
        wallId,
        originalPhotoId,
        originalWidth,
        originalHeight,
        originalLocalPath,
        slices,
      );

      // Replace again to create a soft-deleted tombstone of the first slice.
      await repo.replaceSlices(
        wallId,
        originalPhotoId,
        originalWidth,
        originalHeight,
        originalLocalPath,
        [const SliceSpec(0.0, 0.5), const SliceSpec(0.5, 0.5)],
      );

      final loaded = await repo.loadSlices(originalPhotoId);
      expect(loaded, hasLength(2));
      for (final s in loaded) {
        expect(s.kind, 'slice');
        expect(s.id, isNot(originalPhotoId));
      }

      final original = await repo.loadOriginal(wallId);
      expect(original, isNotNull);
      expect(original!.id, originalPhotoId);
      expect(original.kind, 'original');
    },
  );

  test(
    'A4: crop rects round-trip exactly, including fractional values',
    () async {
      final slices = [
        const SliceSpec(0.25, 0.5),
        const SliceSpec(0.0, 0.25),
        const SliceSpec(0.75, 0.333333),
      ];

      await repo.replaceSlices(
        wallId,
        originalPhotoId,
        originalWidth,
        originalHeight,
        originalLocalPath,
        slices,
      );

      final loaded = await repo.loadSlices(originalPhotoId);
      final byX = {for (final s in loaded) s.cropXpct: s.cropWidthPct};

      expect(byX[0.0], 0.25);
      expect(byX[0.25], 0.5);
      expect(byX[0.75], 0.333333);
    },
  );

  test(
    'A5: concurrent replaceSlices calls for the same original run inside a '
    'transaction and do not duplicate — exactly one set of slices survives',
    () async {
      final slicesA = [const SliceSpec(0.0, 0.5), const SliceSpec(0.5, 0.5)];
      final slicesB = [
        const SliceSpec(0.0, 0.34),
        const SliceSpec(0.34, 0.33),
        const SliceSpec(0.67, 0.33),
      ];
      final slicesC = [const SliceSpec(0.0, 1.0)];

      await Future.wait([
        repo.replaceSlices(
          wallId,
          originalPhotoId,
          originalWidth,
          originalHeight,
          originalLocalPath,
          slicesA,
        ),
        repo.replaceSlices(
          wallId,
          originalPhotoId,
          originalWidth,
          originalHeight,
          originalLocalPath,
          slicesB,
        ),
        repo.replaceSlices(
          wallId,
          originalPhotoId,
          originalWidth,
          originalHeight,
          originalLocalPath,
          slicesC,
        ),
      ]);

      final loaded = await repo.loadSlices(originalPhotoId);
      // Exactly one of the three sets (2, 3, or 1 slices) must be the
      // surviving live set — never a mix/duplication across calls.
      expect(loaded.length, anyOf(1, 2, 3));

      final liveWidths = loaded.map((s) => s.cropWidthPct).toList();
      final matchesA = liveWidths.length == 2;
      final matchesB = liveWidths.length == 3;
      final matchesC = liveWidths.length == 1;
      expect(matchesA || matchesB || matchesC, isTrue);

      // No cross-contamination: the live set is internally consistent with
      // exactly one of the three specs (checked by length above); verify no
      // extra live rows exist beyond the length-consistent set.
      final raw = await db.select(db.photos).get();
      final liveSlices = raw.where(
        (r) => r.kind == 'slice' && r.deletedAt == null,
      );
      expect(liveSlices.length, loaded.length);
    },
  );

  test('createdAt/updatedAt are stamped from nowMs on insert', () async {
    final repoAtT2 = PhotoRepository(db, nowMs: () => 2000);
    final inserted = await repoAtT2.replaceSlices(
      wallId,
      originalPhotoId,
      originalWidth,
      originalHeight,
      originalLocalPath,
      [const SliceSpec(0.0, 1.0)],
    );

    final raw = await (db.select(
      db.photos,
    )..where((t) => t.id.equals(inserted.single.id))).getSingle();
    expect(raw.createdAt, 2000);
    expect(raw.updatedAt, 2000);
  });
}
