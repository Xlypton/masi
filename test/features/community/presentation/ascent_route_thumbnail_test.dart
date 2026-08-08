// Coverage for `AscentRouteThumbnail` — the ascent row's leading tile.
//
// No real image decode anywhere here (per CLAUDE.md, driving a codec under
// fake-async hangs): the seeded photo path never resolves to real bytes, so
// `PhotoImage` sits on its placeholder. That is fine, because what this suite
// is about is the GEOMETRY and the fallback chain, neither of which needs
// pixels.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/community/presentation/ascent_route_thumbnail.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/topo/data/route_repository.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
import 'package:masi/features/topo/presentation/topo_painter.dart';

void main() {
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        nowMsProvider.overrideWithValue(() => 1000),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  /// Area -> Sector -> Wall -> Photo -> one route, the same shape the other
  /// community suites seed.
  Future<String> seedWall(
    WidgetTester tester, {
    List<Offset> points = const [Offset(0.4, 0.3), Offset(0.5, 0.7)],
    bool visible = true,
  }) async {
    final crud = container.read(libraryCrudRepositoryProvider);
    final area = await crud.createArea('Area');
    final sector = await crud.createSector(area.id, 'Sector');
    final wall = await crud.createWall(sector.id, 'Wall');

    // Real file I/O inside runAsync — the same guard every sibling suite uses.
    late String photoId;
    await tester.runAsync(() async {
      photoId = await crud.attachPhotoToWall(
        wall.id,
        XFile('/tmp/ascent-thumb-test.jpg'),
        1000,
        2000,
      );
    });

    await RouteRepository(db, nowMs: () => 1000).upsertRoute(
      wall.id,
      photoId,
      TopoRoute(id: 1, number: 1, points: points, visible: visible),
    );
    return wall.id;
  }

  /// The tile's own painter.
  ///
  /// Scans for the CustomPaint whose painter IS a [TopoPainter] rather than
  /// taking `find.byType(CustomPaint).first`: Material's own chrome puts
  /// several painter-less CustomPaints in the tree ahead of this one, and
  /// `.first` picks one of those.
  TopoPainter topoPainter(WidgetTester tester) {
    for (final paint in tester.widgetList<CustomPaint>(
      find.byType(CustomPaint),
    )) {
      final painter = paint.painter;
      if (painter is TopoPainter) return painter;
    }
    fail('no TopoPainter was mounted');
  }

  Future<void> pump(
    WidgetTester tester, {
    required String wallId,
    required int? routeNumber,
  }) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: MasiTheme.light,
          home: Scaffold(
            body: AscentRouteThumbnail(
              wallId: wallId,
              routeNumber: routeNumber,
              size: 52,
              fallback: () => const SizedBox(
                key: Key('fallback'),
                width: 52,
                height: 52,
              ),
            ),
          ),
        ),
      ),
    );
    // Bounded pumps, NOT `pumpAndSettle`. Once the provider resolves, the tile
    // shows `MasiShimmer` under the photo while the bytes load, and a shimmer
    // animates forever — `pumpAndSettle` waits for a frame that never comes.
    // Eight 50 ms frames is far more than the DB read needs and terminates
    // regardless.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('draws the route over its photo, at the tile\'s size', (
    tester,
  ) async {
    final wallId = await seedWall(tester);
    await pump(tester, wallId: wallId, routeNumber: 1);

    expect(find.byKey(const Key('fallback')), findsNothing);
    expect(tester.getSize(find.byType(AscentRouteThumbnail)), const Size(52, 52));
  });

  testWidgets(
    'ONLY the climbed route is drawn — a topo carries a dozen lines, and '
    'drawing them all would put the viewer back to hunting for which one '
    'this ascent was about',
    (tester) async {
      final wallId = await seedWall(tester);
      // A second route on the same photo, which must NOT be painted.
      final photo = await container
          .read(photoRepositoryProvider)
          .loadOriginal(wallId);
      await RouteRepository(db, nowMs: () => 1000).upsertRoute(
        wallId,
        photo!.id,
        const TopoRoute(
          id: 2,
          number: 2,
          points: [Offset(0.1, 0.1), Offset(0.2, 0.2)],
        ),
      );

      await pump(tester, wallId: wallId, routeNumber: 1);

      final painter = topoPainter(tester);
      expect(painter.routes, hasLength(1));
      expect(painter.routes.single.number, 1);
    },
  );

  testWidgets(
    'a route the owner hid is still drawn — `visible` is the owner\'s editor '
    'toggle for decluttering their own canvas, not a vote on whether someone '
    'else\'s logged ascent gets a picture',
    (tester) async {
      final wallId = await seedWall(tester, visible: false);
      await pump(tester, wallId: wallId, routeNumber: 1);

      final painter = topoPainter(tester);
      expect(painter.routes.single.visible, isTrue);
      expect(find.byKey(const Key('fallback')), findsNothing);
    },
  );

  testWidgets(
    'the painted region has the PHOTO\'s aspect ratio, not the tile\'s — that '
    'is what keeps BoxFit.fill from stretching the rock',
    (tester) async {
      final wallId = await seedWall(tester);
      await pump(tester, wallId: wallId, routeNumber: 1);

      final painter = topoPainter(tester);
      // The seeded photo is 1000x2000.
      expect(
        painter.imageSize.width / painter.imageSize.height,
        moreOrLessEquals(0.5, epsilon: 0.001),
      );
    },
  );

  group('falls back rather than failing', () {
    testWidgets('when the ascent\'s route can no longer be joined', (
      tester,
    ) async {
      final wallId = await seedWall(tester);
      await pump(tester, wallId: wallId, routeNumber: null);

      expect(find.byKey(const Key('fallback')), findsOneWidget);
    });

    testWidgets('when that route number is not on the wall', (tester) async {
      final wallId = await seedWall(tester);
      await pump(tester, wallId: wallId, routeNumber: 99);

      expect(find.byKey(const Key('fallback')), findsOneWidget);
    });

    testWidgets('when the wall has no photo synced down yet', (tester) async {
      final crud = container.read(libraryCrudRepositoryProvider);
      final area = await crud.createArea('Area');
      final sector = await crud.createSector(area.id, 'Sector');
      final wall = await crud.createWall(sector.id, 'Wall');

      await pump(tester, wallId: wall.id, routeNumber: 1);

      expect(find.byKey(const Key('fallback')), findsOneWidget);
    });

    testWidgets('when the route has no points to frame', (tester) async {
      final wallId = await seedWall(tester, points: const []);
      await pump(tester, wallId: wallId, routeNumber: 1);

      expect(find.byKey(const Key('fallback')), findsOneWidget);
    });
  });
}
