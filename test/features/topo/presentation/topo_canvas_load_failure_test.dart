import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/topo/application/draw_controller.dart';
import 'package:masi/features/topo/data/route_repository.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
import 'package:masi/features/topo/presentation/topo_canvas_screen.dart';

/// UF-2, presentation half: **an unreadable topo must not look like an empty
/// one.**
///
/// `draw_controller_load_failure_test.dart` locks the state contract (the
/// switch is settled, the failure is recorded, persistence stays off). This
/// file locks the part the climber actually experiences, which is the reason
/// the whole fix matters: when [DrawController.loadForWall]'s read fails,
/// [DrawState.routes] is empty, and an empty canvas over a real photo says
/// "this topo has no routes yet — draw some". If the climber believes that,
/// they redraw work that is still sitting on disk, and the redraw lands on the
/// wrong photo (proved in the controller test's second-order group).
///
/// So the screen has three obligations here, one per test below: SAY what
/// happened, keep SAYING it, and refuse to let the climber draw over routes
/// nobody can currently see.
class _LoadFailingRouteRepository extends RouteRepository {
  _LoadFailingRouteRepository(super.db, {required super.nowMs});

  bool failLoads = false;

  @override
  Future<List<TopoRoute>> loadRoutes(String wallId, String photoId) async {
    if (!failLoads) return super.loadRoutes(wallId, photoId);
    throw StateError('database is unavailable');
  }
}

/// Deliberately WITHOUT a trailing `pumpAndSettle()` so the SnackBar is still
/// on screen when asserted (settling would run its 4s duration and exit
/// animation to completion). Mirrors `topo_canvas_photo_write_failure_test
/// .dart`'s `_drainNoSettle`.
Future<void> _drainNoSettle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 30));
  }
}

void main() {
  Future<
    ({
      AppDatabase db,
      ProviderContainer container,
      String wallId,
      _LoadFailingRouteRepository repo,
    })
  >
  seedWall(WidgetTester tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    final repo = _LoadFailingRouteRepository(db, nowMs: () => 1000);
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        nowMsProvider.overrideWithValue(() => 1000),
        routeRepositoryProvider.overrideWithValue(repo),
      ],
    );

    final crud = container.read(libraryCrudRepositoryProvider);
    final area = await crud.createArea('Area');
    final sector = await crud.createSector(area.id, 'Sector');
    final wall = await crud.createWall(sector.id, 'Wall');
    await tester.runAsync(() async {
      await crud.attachPhotoToWall(
        wall.id,
        XFile('/tmp/topo-canvas-load-failure-test-photo.jpg'),
        1000,
        2000,
      );
    });

    return (db: db, container: container, wallId: wall.id, repo: repo);
  }

  Future<void> pumpCanvas(
    WidgetTester tester,
    ProviderContainer container,
    String wallId,
  ) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: MasiTheme.light,
          home: TopoCanvasScreen(
            wallId: wallId,
            debugInitialImageSize: const Size(1000, 2000),
          ),
        ),
      ),
    );
    await _drainNoSettle(tester);
  }

  testWidgets(
    'UF-2: a failed route load tells the climber their routes are still '
    'saved, rather than silently showing an empty topo',
    (tester) async {
      final seeded = await seedWall(tester);
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);
      seeded.repo.failLoads = true;

      await pumpCanvas(tester, seeded.container, seeded.wallId);

      // Scoped to the SnackBar specifically, NOT just "this text is somewhere
      // on screen": the persistent banner carries the same words, so an
      // unscoped finder would stay green with the SnackBar listener deleted
      // and this test would have no teeth against it.
      final snackBar = find.byType(SnackBar);
      expect(
        snackBar,
        findsOneWidget,
        reason:
            'the failure must be spoken out loud the moment it happens — a '
            'debugPrint is invisible to the person who has to decide whether '
            'to redraw',
      );
      expect(
        find.descendant(
          of: snackBar,
          matching: find.textContaining('could not be loaded'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: snackBar,
          matching: find.textContaining('still saved'),
        ),
        findsOneWidget,
        reason:
            'THE sentence. Without it the climber reads a blank canvas as '
            '"my work is gone" and redraws it onto the wrong photo.',
      );
      expect(
        tester.takeException(),
        isNull,
        reason: 'loadForWall reports through state; it must not throw',
      );
      expect(
        seeded.container.read(drawControllerProvider(seeded.wallId))
            .isSwitchingPhoto,
        isFalse,
        reason: 'the switch the screen opened is settled even on this path',
      );
    },
  );

  testWidgets(
    'UF-2: the warning PERSISTS after the SnackBar goes away — "routes '
    'unknown" is a standing property of the canvas, not a passing event',
    (tester) async {
      final seeded = await seedWall(tester);
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);
      seeded.repo.failLoads = true;

      await pumpCanvas(tester, seeded.container, seeded.wallId);
      // Run the SnackBar out to its full duration and off screen.
      await tester.pumpAndSettle(const Duration(seconds: 10));

      expect(
        find.byKey(const Key('topo-routes-unavailable')),
        findsOneWidget,
        reason:
            'a SnackBar is gone in four seconds; the canvas is still showing '
            'an incomplete route set minutes later. The banner is what keeps '
            'the canvas honest for as long as that is true.',
      );
    },
  );

  testWidgets(
    'UF-2: drawing is blocked while the real routes are unknown, so the '
    'climber cannot unknowingly duplicate them',
    (tester) async {
      final seeded = await seedWall(tester);
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);
      seeded.repo.failLoads = true;

      await pumpCanvas(tester, seeded.container, seeded.wallId);
      await tester.pumpAndSettle(const Duration(seconds: 10));

      expect(
        find.byKey(const Key('topo-mode-toggle')),
        findsNothing,
        reason:
            'the mode toggle is the ONLY way into draw mode (see its readOnly '
            'gate). Hiding it while the route set is unknown is what makes '
            '"you cannot draw over routes you cannot see" actually hold.',
      );
      expect(
        seeded.container.read(drawControllerProvider(seeded.wallId)).mode,
        DrawMode.view,
        reason:
            'mode survives a photo switch by design, so a climber already in '
            'draw mode when the load failed must be put back into view mode '
            'rather than left holding a live pen over an unknown topo',
      );
    },
  );

  testWidgets(
    'UF-2 control: a topo that genuinely has no routes shows NO warning — '
    'empty and unknown must not look the same',
    (tester) async {
      final seeded = await seedWall(tester);
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);
      // failLoads stays false: the read succeeds and legitimately returns [].

      await pumpCanvas(tester, seeded.container, seeded.wallId);
      await tester.pumpAndSettle(const Duration(seconds: 10));

      expect(
        find.byKey(const Key('topo-routes-unavailable')),
        findsNothing,
        reason:
            'this is the other half of the distinction — warning on a real '
            'empty topo would train the climber to ignore the warning that '
            'matters',
      );
      expect(
        find.byKey(const Key('topo-mode-toggle')),
        findsOneWidget,
        reason: 'an empty topo is exactly where drawing SHOULD be available',
      );
      expect(
        seeded.container.read(drawControllerProvider(seeded.wallId))
            .lastLoadFailure,
        isNull,
      );
    },
  );
}
