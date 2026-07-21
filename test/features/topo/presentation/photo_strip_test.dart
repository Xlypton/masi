// Widget tests for PhotoStrip (masi "multiple photos per topo" canvas UI):
// U1 (renders one thumbnail per live original + a primary badge), U2
// (tapping a thumbnail switches the canvas to that photo's image AND
// routes), U3 (the '+' add tile, hidden when readOnly), and U4 (the
// long-press manage menu: set cover / delete, with delete removing the
// strip item and — when the deleted photo was active — landing the canvas
// on the wall's new primary).
//
// Seeding mirrors `topo_canvas_log_ascent_test.dart`'s pattern: real photos
// are attached via `LibraryCrudRepository.attachPhotoToWall` (inside
// `tester.runAsync`, since that copies a file — best-effort no-ops for
// these nonexistent fixture paths, same as every other test in this
// directory that uses a `/tmp/...` fixture path that never actually
// exists on disk), and `TopoCanvasScreen` is pumped with
// `debugInitialImageSize` to bypass the real (undriveable-under-fake-time)
// image decode.
import 'package:climbtopo/app/theme.dart';
import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/core/db/database_provider.dart';
import 'package:climbtopo/features/library/application/library_providers.dart';
import 'package:climbtopo/features/topo/application/draw_controller.dart';
import 'package:climbtopo/features/topo/data/photo_repository.dart';
import 'package:climbtopo/features/topo/data/route_repository.dart';
import 'package:climbtopo/features/topo/domain/topo_route.dart';
import 'package:climbtopo/features/topo/presentation/topo_canvas_screen.dart';
import 'package:climbtopo/shared/presentation/masi_icon.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

void main() {
  /// Seeds a wall with TWO attached original photos (`photo1` attached
  /// first — and therefore primary, per `attachPhotoToWall`'s "first
  /// photo becomes primary" doc — `photo2` second), each carrying its OWN
  /// persisted route (distinguishable by `gradeRaw`) so switching between
  /// them is independently verifiable.
  Future<
    ({
      AppDatabase db,
      ProviderContainer container,
      String wallId,
      String photo1Id,
      String photo2Id,
    })
  >
  seedWallWithTwoPhotos(WidgetTester tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        nowMsProvider.overrideWithValue(() => 1000),
      ],
    );

    final crud = container.read(libraryCrudRepositoryProvider);
    final area = await crud.createArea('Area');
    final sector = await crud.createSector(area.id, 'Sector');
    final wall = await crud.createWall(sector.id, 'Wall');

    late String photo1Id;
    late String photo2Id;
    await tester.runAsync(() async {
      photo1Id = await crud.attachPhotoToWall(
        wall.id,
        XFile('/tmp/photo-strip-test-photo-1.jpg'),
        1000,
        2000,
      );
      photo2Id = await crud.attachPhotoToWall(
        wall.id,
        XFile('/tmp/photo-strip-test-photo-2.jpg'),
        1000,
        2000,
      );
    });

    final routeRepo = RouteRepository(db, nowMs: () => 1000);
    await routeRepo.upsertRoute(
      wall.id,
      photo1Id,
      const TopoRoute(
        id: 1,
        number: 1,
        points: [Offset(0.1, 0.1), Offset(0.2, 0.2)],
        gradeRaw: 'photo1-route',
      ),
    );
    await routeRepo.upsertRoute(
      wall.id,
      photo2Id,
      const TopoRoute(
        id: 1,
        number: 1,
        points: [Offset(0.3, 0.3), Offset(0.4, 0.4)],
        gradeRaw: 'photo2-route',
      ),
    );

    return (
      db: db,
      container: container,
      wallId: wall.id,
      photo1Id: photo1Id,
      photo2Id: photo2Id,
    );
  }

  Widget wrap(
    ProviderContainer container,
    String wallId, {
    bool readOnly = false,
  }) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: MasiTheme.light,
        home: TopoCanvasScreen(
          wallId: wallId,
          readOnly: readOnly,
          debugInitialImageSize: const Size(1000, 2000),
        ),
      ),
    );
  }

  testWidgets(
    'U1: a wall with 2 photos shows 2 photo-strip items, and the primary '
    "(first-attached) photo's item carries the cover badge",
    (tester) async {
      final seeded = await seedWallWithTwoPhotos(tester);
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);

      await tester.pumpWidget(wrap(seeded.container, seeded.wallId));
      await tester.pumpAndSettle();

      expect(
        find.byKey(Key('photo-strip-item-${seeded.photo1Id}')),
        findsOneWidget,
      );
      expect(
        find.byKey(Key('photo-strip-item-${seeded.photo2Id}')),
        findsOneWidget,
      );

      bool hasCoverBadge(String photoId) => find
          .descendant(
            of: find.byKey(Key('photo-strip-item-$photoId')),
            matching: find.byWidgetPredicate(
              (w) => w is MasiIcon && w.name == 'star_fill',
            ),
          )
          .evaluate()
          .isNotEmpty;

      expect(
        hasCoverBadge(seeded.photo1Id),
        isTrue,
        reason: 'photo1 was attached first, so it is the wall\'s primary',
      );
      expect(
        hasCoverBadge(seeded.photo2Id),
        isFalse,
        reason: 'only the primary photo shows the cover badge',
      );
    },
  );

  testWidgets(
    'U2: tapping the 2nd photo\'s strip item switches the selected image '
    "AND loads that photo's own routes (not photo1's)",
    (tester) async {
      final seeded = await seedWallWithTwoPhotos(tester);
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);

      await tester.pumpWidget(wrap(seeded.container, seeded.wallId));
      await tester.pumpAndSettle();

      // Sanity: opens on photo1 (the primary) with photo1's route.
      expect(
        seeded.container.read(drawControllerProvider(seeded.wallId)).activePhotoId,
        seeded.photo1Id,
      );
      expect(
        seeded.container.read(drawControllerProvider(seeded.wallId)).routes.single.gradeRaw,
        'photo1-route',
      );

      await tester.tap(find.byKey(Key('photo-strip-item-${seeded.photo2Id}')));
      await tester.pumpAndSettle();

      // attachPhotoToWall imports the picked file into app storage under an
      // app-owned `photos/<uuid>.jpg` path (via PhotoFiles.importPhoto) —
      // NOT the raw `/tmp/...` source path passed to attachPhotoToWall — so
      // the selected image after a switch must match photo2's actual OWNED
      // localPath, not the seed source path.
      late final List<PhotoRef> originals;
      await tester.runAsync(() async {
        originals = await seeded.container
            .read(photoRepositoryProvider)
            .loadOriginals(seeded.wallId);
      });
      final photo2 = originals.firstWhere((p) => p.id == seeded.photo2Id);

      expect(
        seeded.container.read(selectedImageProvider),
        photo2.localPath,
        reason:
            'the selected image path must switch to photo2\'s own '
            'owned localPath',
      );
      expect(
        seeded.container.read(drawControllerProvider(seeded.wallId)).activePhotoId,
        seeded.photo2Id,
        reason: 'loadForWall must have been called for photo2',
      );
      expect(
        seeded.container.read(drawControllerProvider(seeded.wallId)).routes.single.gradeRaw,
        'photo2-route',
        reason:
            'ONLY photo2\'s own route must show — not a stale mix with '
            "photo1's",
      );
    },
  );

  testWidgets(
    'U3: the add-photo (+) tile is present when editable and absent when '
    'readOnly',
    (tester) async {
      final editable = await seedWallWithTwoPhotos(tester);
      addTearDown(editable.db.close);
      addTearDown(editable.container.dispose);

      await tester.pumpWidget(wrap(editable.container, editable.wallId));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('photo-strip-add')), findsOneWidget);
    },
  );

  testWidgets('U3: readOnly hides the add-photo (+) tile', (tester) async {
    final seeded = await seedWallWithTwoPhotos(tester);
    addTearDown(seeded.db.close);
    addTearDown(seeded.container.dispose);

    await tester.pumpWidget(
      wrap(seeded.container, seeded.wallId, readOnly: true),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('photo-strip-add')), findsNothing);
    // Switching must still work read-only (viewing a shared topo's other
    // photos) — only the mutating affordances (add/manage) disappear.
    expect(
      find.byKey(Key('photo-strip-item-${seeded.photo2Id}')),
      findsOneWidget,
    );
  });

  testWidgets(
    'U4: long-press -> delete removes a (non-active) photo\'s strip item',
    (tester) async {
      final seeded = await seedWallWithTwoPhotos(tester);
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);

      await tester.pumpWidget(wrap(seeded.container, seeded.wallId));
      await tester.pumpAndSettle();

      await tester.longPress(
        find.byKey(Key('photo-strip-item-${seeded.photo2Id}')),
      );
      await tester.pumpAndSettle();

      final deleteEntry = find.byKey(
        Key('photo-manage-delete-${seeded.photo2Id}'),
      );
      expect(deleteEntry, findsOneWidget);
      await tester.tap(deleteEntry);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('photo-manage-delete-confirm')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(Key('photo-strip-item-${seeded.photo2Id}')),
        findsNothing,
      );
      expect(
        find.byKey(Key('photo-strip-item-${seeded.photo1Id}')),
        findsOneWidget,
        reason: 'deleting photo2 must not disturb photo1\'s item',
      );
      // The canvas was never showing photo2 (photo1 is the active/primary
      // one) so deleting it must not have touched the active selection.
      expect(
        seeded.container.read(drawControllerProvider(seeded.wallId)).activePhotoId,
        seeded.photo1Id,
      );
    },
  );

  testWidgets('U4: deleting the ACTIVE (primary) photo lands the canvas on the '
      "wall's new primary rather than crashing/going blank", (tester) async {
    final seeded = await seedWallWithTwoPhotos(tester);
    addTearDown(seeded.db.close);
    addTearDown(seeded.container.dispose);

    await tester.pumpWidget(wrap(seeded.container, seeded.wallId));
    await tester.pumpAndSettle();

    // Sanity: opens on photo1 (the primary/active one).
    expect(
      seeded.container.read(drawControllerProvider(seeded.wallId)).activePhotoId,
      seeded.photo1Id,
    );

    await tester.longPress(
      find.byKey(Key('photo-strip-item-${seeded.photo1Id}')),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(Key('photo-manage-delete-${seeded.photo1Id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('photo-manage-delete-confirm')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(Key('photo-strip-item-${seeded.photo1Id}')),
      findsNothing,
    );
    expect(
      seeded.container.read(drawControllerProvider(seeded.wallId)).activePhotoId,
      seeded.photo2Id,
      reason:
          'photo2 is the only photo left, so it must be promoted to '
          'primary and become the active canvas photo',
    );

    // As in U2: the selected image must be photo2's own OWNED localPath
    // (attachPhotoToWall imports into app storage as `photos/<uuid>.jpg`),
    // not the raw `/tmp/...` seed source path.
    late final List<PhotoRef> originals;
    await tester.runAsync(() async {
      originals = await seeded.container
          .read(photoRepositoryProvider)
          .loadOriginals(seeded.wallId);
    });
    final photo2 = originals.firstWhere((p) => p.id == seeded.photo2Id);
    expect(seeded.container.read(selectedImageProvider), photo2.localPath);
  });

  testWidgets(
    'U4: "Set as cover" moves the primary badge without switching the '
    'active canvas photo',
    (tester) async {
      final seeded = await seedWallWithTwoPhotos(tester);
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);

      await tester.pumpWidget(wrap(seeded.container, seeded.wallId));
      await tester.pumpAndSettle();

      await tester.longPress(
        find.byKey(Key('photo-strip-item-${seeded.photo2Id}')),
      );
      await tester.pumpAndSettle();

      final setCoverEntry = find.byKey(
        Key('photo-manage-setcover-${seeded.photo2Id}'),
      );
      expect(setCoverEntry, findsOneWidget);
      await tester.tap(setCoverEntry);
      await tester.pumpAndSettle();

      final originals = await seeded.container
          .read(photoRepositoryProvider)
          .loadOriginals(seeded.wallId);
      final photo2 = originals.firstWhere((p) => p.id == seeded.photo2Id);
      expect(photo2.isPrimary, isTrue);

      // Purely a bookkeeping flag: the canvas must still be showing photo1
      // (the photo the user had open), unaffected by which photo is "cover".
      expect(
        seeded.container.read(drawControllerProvider(seeded.wallId)).activePhotoId,
        seeded.photo1Id,
      );
    },
  );

  testWidgets(
    'existing single-photo path is unaffected: a wall with exactly 1 photo '
    'still opens cleanly (regression guard for the additive strip)',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          nowMsProvider.overrideWithValue(() => 1000),
        ],
      );
      addTearDown(db.close);
      addTearDown(container.dispose);

      final crud = container.read(libraryCrudRepositoryProvider);
      final area = await crud.createArea('Area');
      final sector = await crud.createSector(area.id, 'Sector');
      final wall = await crud.createWall(sector.id, 'Wall');
      await tester.runAsync(() async {
        await crud.attachPhotoToWall(
          wall.id,
          XFile('/tmp/photo-strip-single-photo-test.jpg'),
          1000,
          2000,
        );
      });

      await tester.pumpWidget(wrap(container, wall.id));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('topo-empty-state')), findsNothing);
      expect(find.byType(TopoCanvasScreen), findsOneWidget);
    },
  );
}
