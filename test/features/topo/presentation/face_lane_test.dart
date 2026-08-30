import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/topo/data/photo_repository.dart';
import 'package:masi/features/topo/application/face_layout_providers.dart';
import 'package:masi/features/topo/domain/face_layout/layout_resolver.dart';
import 'package:masi/features/topo/presentation/face_lane.dart';

/// [FaceRail] is the reader's way round a rock with several photos, and
/// [FaceMapPlan] is the plan view it opens. The rail lives in the dock's
/// pinned lane (see `topo_dock_test.dart` for that composition); here both are
/// exercised on their own, which is what they are built for — each takes its
/// data and reads no provider.
///
/// What is worth pinning is the difference from the row of 7px dots this
/// replaced. A dot said there was a fourth face; a tile says what is on it,
/// which side has the climbing, and — through the plan tile — where it stands
/// on the rock. So the assertions here are about the tiles being real,
/// distinguishable and countable, not merely present.
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  const wallId = 'wall-1';

  Future<void> seedWall({required int photos, bool withGps = false}) async {
    await db.into(db.areas).insert(
      AreasCompanion.insert(
        id: 'area-1',
        createdAt: 1000,
        updatedAt: 1000,
        name: 'Area',
      ),
    );
    await db.into(db.sectors).insert(
      SectorsCompanion.insert(
        id: 'sector-1',
        createdAt: 1000,
        updatedAt: 1000,
        areaId: 'area-1',
        name: 'Sector',
        sortOrder: 0,
      ),
    );
    await db.into(db.walls).insert(
      WallsCompanion.insert(
        id: wallId,
        createdAt: 1000,
        updatedAt: 1000,
        sectorId: 'sector-1',
        name: 'Wall',
        sortOrder: 0,
      ),
    );
    for (var i = 0; i < photos; i++) {
      await db.into(db.photos).insert(
        PhotosCompanion.insert(
          id: 'photo-$i',
          createdAt: 1000 + i,
          updatedAt: 1000 + i,
          wallId: wallId,
          localPath: '/tmp/photo-$i.jpg',
          kind: 'original',
          width: 100,
          height: 200,
          sortOrder: Value(i),
          isPrimary: Value(i == 0),
          // Spread far enough apart to beat the noise radius, so the engine
          // traces a real track rather than refusing to.
          captureLatitude: Value(withGps ? 47.0 + i * 0.0005 : null),
          captureLongitude: Value(withGps ? 12.0 + i * 0.0005 : null),
          captureAccuracyMeters: Value(withGps ? 4 : null),
          captureBearingDegrees: Value(withGps ? i * 90.0 : null),
        ),
      );
    }
  }

  ProviderContainer makeContainer() => ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      nowMsProvider.overrideWithValue(() => 1000),
    ],
  );


  Widget wrap(ProviderContainer container, Widget child) =>
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: MasiTheme.light,
          home: Scaffold(body: Align(child: child)),
        ),
      );

  /// Feeds the dumb lane widgets from the same two providers the dock reads,
  /// in the same tree — rather than resolving them out of band first, which
  /// hangs: `wallOriginalsProvider`'s drift stream only advances while
  /// something in a pumped tree is listening to it.
  Widget laneProbe(
    Widget Function(BuildContext, List<PhotoRef>, LayoutResult) build,
  ) => Consumer(
    builder: (context, ref, _) {
      final photos = ref.watch(wallOriginalsProvider(wallId)).value;
      final layout = ref.watch(wallLayoutProvider(wallId)).value;
      if (photos == null || layout == null) return const SizedBox.shrink();
      return build(context, photos, layout);
    },
  );

  testWidgets('one tile per photo, and tapping one switches to it', (
    tester,
  ) async {
    await seedWall(photos: 3);
    final container = makeContainer();
    addTearDown(container.dispose);

    PhotoRef? selected;
    await tester.pumpWidget(
      wrap(
        container,
        laneProbe(
          (context, photos, layout) => FaceRail(
            photos: photos,
            layout: layout,
            activePhotoId: 'photo-0',
            routeCounts: const {},
            onSelect: (photo) => selected = photo,
            onManage: null,
            onOpenMap: null,
            onAddPhoto: null,
            colors: MasiColors.of(context),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('face-rail')), findsOneWidget);
    for (var i = 0; i < 3; i++) {
      expect(find.byKey(Key('face-rail-tile-photo-$i')), findsOneWidget);
    }

    await tester.tap(find.byKey(const Key('face-rail-tile-photo-2')));
    await tester.pumpAndSettle();
    expect(selected?.id, 'photo-2');
  });

  testWidgets('the tile you are on is WIDER, not merely ringed', (
    tester,
  ) async {
    // A 2px accent ring is one thin line of colour to find, and it is drawn
    // on top of a photograph that may itself be purple rock. Shape survives
    // that; colour alone does not.
    await seedWall(photos: 3);
    final container = makeContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      wrap(
        container,
        laneProbe(
          (context, photos, layout) => FaceRail(
            photos: photos,
            layout: layout,
            activePhotoId: 'photo-1',
            routeCounts: const {},
            onSelect: (_) {},
            onManage: null,
            onOpenMap: null,
            onAddPhoto: null,
            colors: MasiColors.of(context),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final active = tester.getRect(find.byKey(const Key('face-rail-tile-photo-1')));
    final other = tester.getRect(find.byKey(const Key('face-rail-tile-photo-0')));
    expect(active.width, greaterThan(other.width));
  });

  testWidgets('the badge says which side the climbing is on, and a face with '
      'none carries no badge at all', (tester) async {
    await seedWall(photos: 3);
    final container = makeContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      wrap(
        container,
        laneProbe(
          (context, photos, layout) => FaceRail(
            photos: photos,
            layout: layout,
            activePhotoId: 'photo-0',
            routeCounts: const {'photo-0': 7, 'photo-2': 1},
            onSelect: (_) {},
            onManage: null,
            onOpenMap: null,
            onAddPhoto: null,
            colors: MasiColors.of(context),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('face-rail-count-photo-0')), findsOneWidget);
    expect(find.text('7'), findsOneWidget);
    expect(find.byKey(const Key('face-rail-count-photo-2')), findsOneWidget);
    // Absent, not a zero: a zero is a number a reader has to read and then
    // discard, and it invites the question of what an unlabelled tile means.
    expect(find.byKey(const Key('face-rail-count-photo-1')), findsNothing);
  });

  testWidgets('with every sensor absent the rail still navigates — an '
      'ordered filmstrip is the product, not a degraded state', (tester) async {
    await seedWall(photos: 3);
    final container = makeContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      wrap(
        container,
        laneProbe(
          (context, photos, layout) => FaceRail(
            photos: photos,
            layout: layout,
            activePhotoId: 'photo-0',
            routeCounts: const {},
            onSelect: (_) {},
            onManage: null,
            onOpenMap: null,
            onAddPhoto: null,
            colors: MasiColors.of(context),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('face-rail-tile-photo-1')), findsOneWidget);

    // A plan still has something to draw, because a synthesised capture-order
    // strip is a real baseline. What must NOT appear is a view cone: a cone
    // claims a direction, and with no heading anywhere there is no direction
    // to claim — only an order. Asserted through the placements the engine
    // reports, since the cones are painted rather than composed.
    expect(
      container
          .read(wallLayoutProvider(wallId))
          .value!
          .faces
          .every((f) => f.placement == FacePlacement.captureOrder),
      isTrue,
      reason: 'nothing may claim a sensor placed it when no sensor spoke',
    );
  });

  testWidgets('the plan tile and the + tile appear only when there is '
      'something behind them', (tester) async {
    await seedWall(photos: 3);
    final container = makeContainer();
    addTearDown(container.dispose);

    var mapOpened = 0;
    await tester.pumpWidget(
      wrap(
        container,
        laneProbe(
          (context, photos, layout) => FaceRail(
            photos: photos,
            layout: layout,
            activePhotoId: 'photo-0',
            routeCounts: const {},
            onSelect: (_) {},
            onManage: null,
            onOpenMap: () => mapOpened++,
            onAddPhoto: null,
            colors: MasiColors.of(context),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('face-rail-map')), findsOneWidget);
    // Read-only: no way to add a photo, so no tile offering to.
    expect(find.byKey(const Key('face-rail-add')), findsNothing);

    await tester.tap(find.byKey(const Key('face-rail-map')));
    await tester.pumpAndSettle();
    expect(mapOpened, 1);
  });

  testWidgets('no plan to open means no plan tile — a tile that opens an '
      'empty screen is worse than none', (tester) async {
    await seedWall(photos: 3);
    final container = makeContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      wrap(
        container,
        laneProbe(
          (context, photos, layout) => FaceRail(
            photos: photos,
            layout: layout,
            activePhotoId: 'photo-0',
            routeCounts: const {},
            onSelect: (_) {},
            onManage: null,
            onOpenMap: null,
            onAddPhoto: () {},
            colors: MasiColors.of(context),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('face-rail-map')), findsNothing);
    expect(find.byKey(const Key('face-rail-add')), findsOneWidget);
  });

  testWidgets('long-pressing a tile raises the manage actions the strip tiles '
      'used to carry', (tester) async {
    await seedWall(photos: 2);
    final container = makeContainer();
    addTearDown(container.dispose);

    PhotoRef? managed;
    await tester.pumpWidget(
      wrap(
        container,
        laneProbe(
          (context, photos, layout) => FaceRail(
            photos: photos,
            layout: layout,
            activePhotoId: 'photo-0',
            routeCounts: const {},
            onSelect: (_) {},
            onManage: (photo) => managed = photo,
            onOpenMap: null,
            onAddPhoto: null,
            colors: MasiColors.of(context),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.byKey(const Key('face-rail-tile-photo-1')));
    await tester.pumpAndSettle();
    expect(managed?.id, 'photo-1');
  });

  testWidgets('the plan draws one real thumbnail per face, none covering '
      'another, and tapping one selects it', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await seedWall(photos: 4, withGps: true);
    final container = makeContainer();
    addTearDown(container.dispose);

    PhotoRef? selected;
    await tester.pumpWidget(
      wrap(
        container,
        laneProbe(
          (context, photos, layout) => SizedBox(
            width: 374,
            height: 520,
            child: FaceMapPlan(
              layout: layout,
              photos: photos,
              activePhotoId: 'photo-0',
              routeCounts: const {'photo-1': 3},
              onSelect: (photo) => selected = photo,
              colors: MasiColors.of(context),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('face-map-plan')), findsOneWidget);
    final boxes = <Rect>[];
    for (var i = 0; i < 4; i++) {
      final finder = find.byKey(Key('face-map-face-photo-$i'));
      expect(finder, findsOneWidget);
      boxes.add(tester.getRect(finder));
    }
    for (var i = 0; i < boxes.length; i++) {
      for (var j = i + 1; j < boxes.length; j++) {
        expect(
          boxes[i].overlaps(boxes[j]),
          isFalse,
          reason: 'a face hidden under another is a face the reader lost',
        );
      }
    }

    await tester.tap(find.byKey(const Key('face-map-face-photo-2')));
    await tester.pumpAndSettle();
    expect(selected?.id, 'photo-2');
  });
}
