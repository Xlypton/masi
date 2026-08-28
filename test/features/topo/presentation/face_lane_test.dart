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

/// [FaceDots] and [FaceMinimap] are what replaced the 52px photo strip: the
/// reader's way round a rock with several photos. They live in the dock's
/// pinned lane now (see `topo_dock_test.dart` for that composition); here they
/// are exercised on their own, which is what they are built for — both take
/// their data and read no provider.
///
/// The behaviour worth pinning is what the strip could not do — say WHERE each
/// photo was taken — and what it must not lose: switching photos, and the
/// management actions that used to hang off each tile.
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

  testWidgets('one dot per photo, and tapping one switches to it', (
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
          (context, photos, layout) => FaceDots(
            photos: photos,
            layout: layout,
            activePhotoId: 'photo-0',
            onSelect: (photo) => selected = photo,
            onManage: null,
            colors: MasiColors.of(context),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('face-pager-dots')), findsOneWidget);
    for (var i = 0; i < 3; i++) {
      expect(find.byKey(Key('face-dot-photo-$i')), findsOneWidget);
    }

    await tester.tap(find.byKey(const Key('face-dot-photo-2')));
    await tester.pumpAndSettle();
    expect(selected?.id, 'photo-2');
  });

  testWidgets('with every sensor absent the lane still navigates — an '
      'ordered filmstrip is the product, not a degraded state', (tester) async {
    await seedWall(photos: 3);
    final container = makeContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      wrap(
        container,
        laneProbe(
          (context, photos, layout) => FaceDots(
            photos: photos,
            layout: layout,
            activePhotoId: 'photo-0',
            onSelect: (_) {},
            onManage: null,
            colors: MasiColors.of(context),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('face-dot-photo-1')), findsOneWidget);

    // A minimap still has something to draw, because a synthesised
    // capture-order strip is a real baseline. What must NOT appear is a view
    // cone: a cone claims a direction, and with no heading anywhere there is
    // no direction to claim — only an order. Asserted through the placements
    // the engine reports, since the cones are painted rather than composed.
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

  testWidgets('the dots carry no pill of their own when the dock frames them',
      (tester) async {
    await seedWall(photos: 3);
    final container = makeContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      wrap(
        container,
        laneProbe(
          (context, photos, layout) => FaceDots(
            framed: false,
            photos: photos,
            layout: layout,
            activePhotoId: 'photo-0',
            onSelect: (_) {},
            onManage: null,
            colors: MasiColors.of(context),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final box = tester.widget<Container>(
      find.byKey(const Key('face-pager-dots')),
    );
    expect(
      box.decoration,
      isNull,
      reason: 'a bordered pill on top of the dock reads as a loose control',
    );
  });

  testWidgets('with real fixes the minimap renders and its marks select', (
    tester,
  ) async {
    await seedWall(photos: 4, withGps: true);
    final container = makeContainer();
    addTearDown(container.dispose);

    PhotoRef? selected;
    await tester.pumpWidget(
      wrap(
        container,
        laneProbe(
          (context, photos, layout) => FaceMinimap(
            layout: layout,
            photos: photos,
            activePhotoId: 'photo-0',
            onSelect: (photo) => selected = photo,
            onEditLayout: null,
            colors: MasiColors.of(context),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('face-pager-minimap')), findsOneWidget);
    expect(find.text('where each photo was taken'), findsOneWidget);

    await tester.tap(
      find.byKey(const Key('minimap-face-photo-2')),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    expect(selected?.id, 'photo-2');
  });

  testWidgets('the minimap carries a LABELLED button into the editor — the '
      'thing that shows a wrong arrangement is the thing that fixes it', (
    tester,
  ) async {
    await seedWall(photos: 4, withGps: true);
    final container = makeContainer();
    addTearDown(container.dispose);

    var opened = 0;
    await tester.pumpWidget(
      wrap(
        container,
        laneProbe(
          (context, photos, layout) => FaceMinimap(
            layout: layout,
            photos: photos,
            activePhotoId: 'photo-0',
            onSelect: (_) {},
            onEditLayout: () => opened++,
            colors: MasiColors.of(context),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // A button with a word on it, not a 10px caption that is secretly
    // tappable: the caption stays a caption and the control says 'Edit'.
    expect(find.text('where each photo was taken'), findsOneWidget);
    expect(find.text('Edit'), findsOneWidget);
    await tester.tap(find.byKey(const Key('face-pager-edit-layout')));
    await tester.pumpAndSettle();
    expect(opened, 1);
  });

  testWidgets('without an editor to open, no button is offered at all', (
    tester,
  ) async {
    await seedWall(photos: 4, withGps: true);
    final container = makeContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      wrap(
        container,
        laneProbe(
          (context, photos, layout) => FaceMinimap(
            layout: layout,
            photos: photos,
            activePhotoId: 'photo-0',
            onSelect: (_) {},
            onEditLayout: null,
            colors: MasiColors.of(context),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('where each photo was taken'), findsOneWidget);
    expect(find.text('Edit'), findsNothing);
    expect(find.byKey(const Key('face-pager-edit-layout')), findsNothing);
  });

  testWidgets('long-pressing a dot raises the manage actions the strip tiles '
      'used to carry', (tester) async {
    await seedWall(photos: 2);
    final container = makeContainer();
    addTearDown(container.dispose);

    PhotoRef? managed;
    await tester.pumpWidget(
      wrap(
        container,
        laneProbe(
          (context, photos, layout) => FaceDots(
            photos: photos,
            layout: layout,
            activePhotoId: 'photo-0',
            onSelect: (_) {},
            onManage: (photo) => managed = photo,
            colors: MasiColors.of(context),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.byKey(const Key('face-dot-photo-1')));
    await tester.pumpAndSettle();
    expect(managed?.id, 'photo-1');
  });
}
