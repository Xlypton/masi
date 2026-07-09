import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/features/topo/application/slice_controller.dart';
import 'package:climbtopo/features/topo/data/photo_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SliceController: cut list management', () {
    test(
      'A1: addCut appends & re-sorts ascending; out-of-range values '
      '(<=0 or >=1) are ignored',
      () {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final notifier = container.read(sliceControllerProvider.notifier);

        notifier.addCut(0.6);
        notifier.addCut(0.2);
        notifier.addCut(0.9);
        expect(container.read(sliceControllerProvider), [0.2, 0.6, 0.9]);

        // Out-of-range: boundary and beyond, both directions.
        notifier.addCut(0.0);
        notifier.addCut(1.0);
        notifier.addCut(-0.5);
        notifier.addCut(1.5);
        expect(container.read(sliceControllerProvider), [0.2, 0.6, 0.9]);
      },
    );

    test(
      'A1: removeNearestCut removes whichever cut is closest to the given '
      'x; no-op when the list is empty',
      () {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final notifier = container.read(sliceControllerProvider.notifier);

        // No-op on an empty list.
        notifier.removeNearestCut(0.5);
        expect(container.read(sliceControllerProvider), isEmpty);

        notifier.addCut(0.2);
        notifier.addCut(0.5);
        notifier.addCut(0.8);

        // 0.55 is closest to 0.5.
        notifier.removeNearestCut(0.55);
        expect(container.read(sliceControllerProvider), [0.2, 0.8]);

        // 0.99 is closest to 0.8.
        notifier.removeNearestCut(0.99);
        expect(container.read(sliceControllerProvider), [0.2]);
      },
    );

    test('A1: clear empties the list', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(sliceControllerProvider.notifier);

      notifier.addCut(0.3);
      notifier.addCut(0.6);
      expect(container.read(sliceControllerProvider), isNotEmpty);

      notifier.clear();
      expect(container.read(sliceControllerProvider), isEmpty);
    });

    test('mutations always produce a new list instance (immutability)', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(sliceControllerProvider.notifier);

      final before = container.read(sliceControllerProvider);
      notifier.addCut(0.4);
      final after = container.read(sliceControllerProvider);
      expect(identical(before, after), isFalse);
    });
  });

  group('SliceController.commit', () {
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
      'A3: committing cuts [0.33, 0.66] persists 3 slices via '
      'replaceSlices (matching slicesFromCuts) and clears the cut list',
      () async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final notifier = container.read(sliceControllerProvider.notifier);
        notifier.addCut(0.33);
        notifier.addCut(0.66);

        final committed = await notifier.commit(
          repo,
          wallId: wallId,
          originalPhotoId: originalPhotoId,
          originalWidth: originalWidth,
          originalHeight: originalHeight,
          originalLocalPath: originalLocalPath,
        );

        expect(committed, isTrue);
        expect(
          container.read(sliceControllerProvider),
          isEmpty,
          reason: 'a successful commit must clear the pending cuts',
        );

        final loaded = await repo.loadSlices(originalPhotoId);
        expect(loaded, hasLength(3));
        expect(loaded.map((s) => s.cropXpct).toList(), [0.0, 0.33, 0.66]);
        expect(loaded[0].cropWidthPct, closeTo(0.33, 1e-9));
        expect(loaded[1].cropWidthPct, closeTo(0.33, 1e-9));
        expect(loaded[2].cropWidthPct, closeTo(0.34, 1e-9));
      },
    );

    test(
      'A4: committing with NO cuts is a no-op — replaceSlices is never '
      'invoked, no slices are persisted, and commit returns false',
      () async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final notifier = container.read(sliceControllerProvider.notifier);

        final committed = await notifier.commit(
          repo,
          wallId: wallId,
          originalPhotoId: originalPhotoId,
          originalWidth: originalWidth,
          originalHeight: originalHeight,
          originalLocalPath: originalLocalPath,
        );

        expect(committed, isFalse);

        final loaded = await repo.loadSlices(originalPhotoId);
        expect(loaded, isEmpty);

        // Only the original photo row exists — replaceSlices never ran.
        final raw = await db.select(db.photos).get();
        expect(raw, hasLength(1));
      },
    );
  });
}
