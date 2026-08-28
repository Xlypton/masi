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
import 'package:masi/features/topo/presentation/face_pager.dart';

/// [FacePager] is what replaced the 52px photo strip: the reader's way round a
/// rock with several photos.
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

  testWidgets('a single-photo topo renders no pager at all — there is '
      'nothing to navigate', (tester) async {
    await seedWall(photos: 1);
    final container = makeContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      wrap(
        container,
        FacePager(wallId: wallId, activePhotoId: 'photo-0', onSelect: (_) {}),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('face-pager-dots')), findsNothing);
    expect(find.byKey(const Key('face-pager-minimap')), findsNothing);
  });

  testWidgets('one dot per photo, and tapping one switches to it',
      (tester) async {
    await seedWall(photos: 3);
    final container = makeContainer();
    addTearDown(container.dispose);

    PhotoRef? selected;
    await tester.pumpWidget(
      wrap(
        container,
        FacePager(
          wallId: wallId,
          activePhotoId: 'photo-0',
          onSelect: (photo) => selected = photo,
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

  testWidgets('with every sensor absent the pager still navigates — an '
      'ordered filmstrip is the product, not a degraded state', (tester) async {
    await seedWall(photos: 3);
    final container = makeContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      wrap(
        container,
        FacePager(wallId: wallId, activePhotoId: 'photo-0', onSelect: (_) {}),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('face-pager-dots')), findsOneWidget);
    expect(find.byKey(const Key('face-dot-photo-1')), findsOneWidget);

    // A minimap still renders, because a synthesised capture-order strip is
    // a real baseline. What must NOT appear is a view cone: a cone claims a
    // direction, and with no heading anywhere there is no direction to
    // claim — only an order. Asserted through the placements the engine
    // reports, since the cones are painted rather than composed.
    final layout = container.read(wallLayoutProvider(wallId)).value!;
    expect(
      layout.faces.every((f) => f.placement == FacePlacement.captureOrder),
      isTrue,
      reason: 'nothing may claim a sensor placed it when no sensor spoke',
    );
  });

  testWidgets('with real fixes the minimap renders and its marks select',
      (tester) async {
    await seedWall(photos: 4, withGps: true);
    final container = makeContainer();
    addTearDown(container.dispose);

    PhotoRef? selected;
    await tester.pumpWidget(
      wrap(
        container,
        FacePager(
          wallId: wallId,
          activePhotoId: 'photo-0',
          onSelect: (photo) => selected = photo,
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

  testWidgets('the minimap caption opens the layout editor — the thing that '
      'shows a wrong arrangement is the thing that fixes it', (tester) async {
    await seedWall(photos: 4, withGps: true);
    final container = makeContainer();
    addTearDown(container.dispose);

    var opened = 0;
    await tester.pumpWidget(
      wrap(
        container,
        FacePager(
          wallId: wallId,
          activePhotoId: 'photo-0',
          onSelect: (_) {},
          onEditLayout: () => opened++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('edit'), findsOneWidget);
    await tester.tap(find.byKey(const Key('face-pager-edit-layout')));
    await tester.pumpAndSettle();
    expect(opened, 1);
  });

  testWidgets('without an editor to open, the caption makes no offer',
      (tester) async {
    await seedWall(photos: 4, withGps: true);
    final container = makeContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      wrap(
        container,
        FacePager(wallId: wallId, activePhotoId: 'photo-0', onSelect: (_) {}),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('where each photo was taken'), findsOneWidget);
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
        FacePager(
          wallId: wallId,
          activePhotoId: 'photo-0',
          onSelect: (_) {},
          onManage: (photo) => managed = photo,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.byKey(const Key('face-dot-photo-1')));
    await tester.pumpAndSettle();
    expect(managed?.id, 'photo-1');
  });
}
