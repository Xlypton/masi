// Coverage for `AscentRouteArtHeader` — the route-on-its-rock picture at the
// top of the ascent detail screen.
//
// No real image decode anywhere here (per CLAUDE.md, driving a codec under
// fake-async hangs): the seeded photo path never resolves to real bytes, so
// `PhotoImage` sits on its placeholder. That is fine, because what this suite
// is about is the GEOMETRY and the three states, none of which needs pixels.
//
// Harness copied from `ascent_route_thumbnail_test.dart` — same seeding, same
// `topoPainter` scan, same bounded pumps. The two widgets share
// `RouteArtPicture`, so they had better share the way they are exercised.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/community/presentation/ascent_route_art_header.dart';
import 'package:masi/features/community/presentation/route_art_picture.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/topo/data/route_repository.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
import 'package:masi/features/topo/presentation/topo_painter.dart';
import 'package:masi/shared/presentation/masi_skeleton.dart';

void main() {
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    // An OWNED container + `UncontrolledProviderScope`, never a bare
    // `ProviderScope`: that disposes during `finalizeTree`, which leaves
    // drift's zero-duration teardown timer pending and poisons the binding for
    // every test after it.
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
  /// community suites seed. The photo is 1000x2000.
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
        XFile('/tmp/ascent-art-header-test.jpg'),
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

  /// The header's own painter.
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

  /// A stand-in for the climber's name — the first thing the real screen puts
  /// under the picture. Its y position is how this suite measures what the
  /// header actually occupies, gap included.
  const nextKey = Key('next');

  /// Mounts the header the way the detail screen does — as the first child of
  /// a `ListView`, so it is handed a bounded width and an unbounded height,
  /// with [nextKey] standing in for the text that follows it.
  ///
  /// Stops after `pumpWidget`'s single frame when [settle] is false, which is
  /// the only moment the art provider is reliably still loading.
  Future<void> pump(
    WidgetTester tester, {
    required String wallId,
    required int? routeNumber,
    bool settle = true,
  }) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: MasiTheme.light,
          home: Scaffold(
            body: ListView(
              children: [
                AscentRouteArtHeader(
                  wallId: wallId,
                  routeNumber: routeNumber,
                ),
                const SizedBox(key: nextKey, height: 20),
              ],
            ),
          ),
        ),
      ),
    );
    if (!settle) return;
    // Bounded pumps, NOT `pumpAndSettle`. The loading slot is a `MasiSkeleton`,
    // which shimmers, and a shimmer animates forever — `pumpAndSettle` waits
    // for a frame that never comes. Eight 50 ms frames is far more than the DB
    // read needs and terminates regardless.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// The default flutter_test surface: 800x600 logical.
  const double viewportHeight = 600;

  testWidgets('draws the climbed route over its photo, large', (tester) async {
    final wallId = await seedWall(tester);
    await pump(tester, wallId: wallId, routeNumber: 1);

    expect(find.byType(RouteArtPicture), findsOneWidget);
    // Capped by the viewport's HEIGHT here, not its width: the surface is
    // 800x600, so 0.42 of the height is the binding constraint.
    expect(
      tester.getSize(find.byType(RouteArtPicture)),
      const Size(viewportHeight * 0.42, viewportHeight * 0.42),
    );
    // And it really is the whole square, not a strip: this is the subject of
    // the screen, so it must be big enough to recognise a line on a rock.
    expect(tester.getSize(find.byType(RouteArtPicture)).width, greaterThan(200));
    // The gap below the picture belongs to the header, not to the caller's
    // child list — that is what lets a collapsed header leave no trace.
    expect(
      tester.getTopLeft(find.byKey(nextKey)).dy,
      viewportHeight * 0.42 + MasiSpacing.md,
    );
  });

  testWidgets(
    'ONLY the climbed route is drawn — a topo carries a dozen lines, and '
    'drawing them all would put the viewer back to hunting for which one '
    'this ascent was about',
    (tester) async {
      final wallId = await seedWall(tester);
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

      expect(topoPainter(tester).routes.single.visible, isTrue);
      expect(find.byType(RouteArtPicture), findsOneWidget);
    },
  );

  testWidgets(
    'the painted region has the PHOTO\'s aspect ratio, not the frame\'s — that '
    'is what keeps BoxFit.fill from stretching the rock',
    (tester) async {
      final wallId = await seedWall(tester);
      await pump(tester, wallId: wallId, routeNumber: 1);

      // The seeded photo is 1000x2000.
      expect(
        topoPainter(tester).imageSize.width /
            topoPainter(tester).imageSize.height,
        moreOrLessEquals(0.5, epsilon: 0.001),
      );
    },
  );

  testWidgets(
    'reserves the picture\'s box while the art is still resolving, rather '
    'than letting the text below it jump',
    (tester) async {
      final wallId = await seedWall(tester);
      // The single frame `pumpWidget` itself pumps: the art provider is a
      // FutureProvider, so it cannot have answered yet.
      await pump(tester, wallId: wallId, routeNumber: 1, settle: false);

      expect(find.byType(MasiSkeleton), findsOneWidget);
      expect(find.byType(RouteArtPicture), findsNothing);
      // The same box the picture will occupy — a loading slot of a different
      // size is a layout jump with extra steps.
      expect(
        tester.getSize(find.byType(MasiSkeleton)),
        const Size(viewportHeight * 0.42, viewportHeight * 0.42),
      );
    },
  );

  group('shows nothing at all rather than an empty frame', () {
    /// The header must leave NO trace when there is no picture — not a box,
    /// not a gap. Anything else asserts a picture exists and then fails to
    /// produce one, and a bare gap above the climber's name is exactly the
    /// kind of unexplained space that reads as a rendering bug.
    void expectCollapsed(WidgetTester tester) {
      expect(find.byType(RouteArtPicture), findsNothing);
      expect(find.byType(MasiSkeleton), findsNothing);
      expect(tester.getTopLeft(find.byKey(nextKey)).dy, 0);
    }

    testWidgets('when the ascent\'s route can no longer be joined', (
      tester,
    ) async {
      final wallId = await seedWall(tester);
      await pump(tester, wallId: wallId, routeNumber: null);

      expectCollapsed(tester);
    });

    testWidgets('when that route number is not on the wall', (tester) async {
      final wallId = await seedWall(tester);
      await pump(tester, wallId: wallId, routeNumber: 99);

      expectCollapsed(tester);
    });

    testWidgets('when the wall has no photo synced down yet', (tester) async {
      final crud = container.read(libraryCrudRepositoryProvider);
      final area = await crud.createArea('Area');
      final sector = await crud.createSector(area.id, 'Sector');
      final wall = await crud.createWall(sector.id, 'Wall');

      await pump(tester, wallId: wall.id, routeNumber: 1);

      expectCollapsed(tester);
    });

    testWidgets('when the route has no points to frame', (tester) async {
      final wallId = await seedWall(tester, points: const []);
      await pump(tester, wallId: wallId, routeNumber: 1);

      expectCollapsed(tester);
    });
  });
}
