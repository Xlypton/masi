// Intended-behavior tests for
// ~/.claude/plans/masi-canvas-bottom-reclaim.md — reclaiming the dead bottom
// band the topo canvas used to waste in VIEW mode. The add-photo action
// moves from a floating bottom-right FAB into the top chrome's trailing
// action cluster, the bottom chrome renders nothing at all outside DRAW
// mode, and the floating routes legend's bottom clearance becomes
// mode-aware: it only reserves room for the undo/redo/clear/commit cluster
// while actually in DRAW mode, so in VIEW mode it sits flush near the
// bottom safe area instead.
//
// These assertions are derived from the plan's contract (A1-A7), not from
// the pre-fix implementation — a failing test here is a real bug to fix in
// lib/, never a reason to weaken the assertion.

import 'package:climbtopo/app/theme.dart';
import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/core/db/database_provider.dart';
import 'package:climbtopo/features/library/application/library_providers.dart';
import 'package:climbtopo/features/topo/application/draw_controller.dart';
import 'package:climbtopo/features/topo/data/route_repository.dart';
import 'package:climbtopo/features/topo/domain/topo_route.dart';
import 'package:climbtopo/features/topo/presentation/canvas_chrome.dart';
import 'package:climbtopo/features/topo/presentation/topo_canvas_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// Seeds a real Area -> Sector -> Wall, attaches a photo, and persists a
  /// single 2-point route — the harness shape shared by
  /// canvas_mode_intent_test.dart's A1e and canvas_chrome_gating_test.dart's
  /// A-i group, so both the legend AND the mode-toggle/slice-mode entry
  /// points are reachable.
  Future<
    ({AppDatabase db, ProviderContainer container, String wallId})
  > seedWallWithPhotoAndRoute(WidgetTester tester) async {
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

    await tester.runAsync(() async {
      final photoId = await crud.attachPhotoToWall(
        wall.id,
        '/tmp/bottom-reclaim-photo.jpg',
        1000,
        2000,
      );
      final routeRepo = RouteRepository(db, nowMs: () => 1000);
      await routeRepo.upsertRoute(
        wall.id,
        photoId,
        const TopoRoute(
          id: 1,
          number: 1,
          points: [Offset(0.1, 0.1), Offset(0.2, 0.2)],
        ),
      );
    });

    return (db: db, container: container, wallId: wall.id);
  }

  Widget wrap(ProviderContainer container, Widget child) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: MasiTheme.light, home: child),
    );
  }

  testWidgets(
    'A1: view mode renders no bottom-right add-photo affordance — the '
    'ONLY "Pick a photo" control anywhere on screen is the top-bar button',
    (tester) async {
      final seeded = await seedWallWithPhotoAndRoute(tester);
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);

      await tester.pumpWidget(
        wrap(
          seeded.container,
          TopoCanvasScreen(
            wallId: seeded.wallId,
            debugInitialImageSize: const Size(1000, 2000),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        seeded.container.read(drawControllerProvider).mode,
        DrawMode.view,
      );
      expect(
        find.byTooltip('Pick a photo'),
        findsOneWidget,
        reason:
            'the old floating bottom-right FAB must be gone — exactly one '
            '"Pick a photo" control (the top-bar button) may remain',
      );
      expect(find.byKey(const Key('topo-add-photo-button')), findsOneWidget);
    },
  );

  testWidgets(
    'A2: topo-add-photo-button shows in view AND draw mode, is absent in '
    'slice mode, and tapping it invokes the same _pickImage handler the old '
    'FAB used (opens the photo-source action sheet)',
    (tester) async {
      final seeded = await seedWallWithPhotoAndRoute(tester);
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);

      await tester.pumpWidget(
        wrap(
          seeded.container,
          TopoCanvasScreen(
            wallId: seeded.wallId,
            debugInitialImageSize: const Size(1000, 2000),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // View mode.
      expect(find.byKey(const Key('topo-add-photo-button')), findsOneWidget);

      // Draw mode.
      await tester.tap(find.byKey(const Key('topo-mode-toggle')));
      await tester.pumpAndSettle();
      expect(
        seeded.container.read(drawControllerProvider).mode,
        DrawMode.draw,
      );
      expect(
        find.byKey(const Key('topo-add-photo-button')),
        findsOneWidget,
        reason: 'add-photo must still be reachable while drawing',
      );

      // Back to view, then into slice mode.
      await tester.tap(find.byKey(const Key('topo-mode-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('topo-slice-mode-button')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('topo-add-photo-button')),
        findsNothing,
        reason:
            'slice mode swaps the trailing cluster for clear/commit/exit — '
            'add-photo must not appear there',
      );

      // Exit slice mode (same key toggles it off) and confirm the button
      // reappears and actually invokes _pickImage.
      await tester.tap(find.byKey(const Key('topo-slice-mode-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('topo-add-photo-button')));
      await tester.pumpAndSettle();

      expect(
        find.byType(CupertinoActionSheet),
        findsOneWidget,
        reason:
            'tapping topo-add-photo-button must invoke the same _pickImage '
            'handler the old FAB used (showPhotoSourceSheet)',
      );

      // Dismiss so the sheet doesn't leak into a later assertion/teardown.
      await tester.tap(find.byKey(const Key('photo-source-cancel')));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'A3: legendBottomPadding is mode-aware — draw mode reserves exactly '
    'kBottomChromeClusterHeight + MasiSpacing.sm more clearance than view '
    'mode',
    (tester) async {
      const viewportSize = Size(400, 800);
      tester.view.physicalSize = viewportSize;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const route = TopoRoute(
        id: 1,
        number: 1,
        points: [Offset(0.1, 0.1), Offset(0.2, 0.2)],
      );

      Future<double> legendBottomOffsetFor(DrawMode mode) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final controller = TransformationController();
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: MasiTheme.light,
              home: Scaffold(
                body: TopoCanvasBody(
                  imagePath: '/nonexistent/test-topo.jpg',
                  imageSize: const Size(400, 300),
                  drawState: DrawState(mode: mode, routes: const [route]),
                  transformationController: controller,
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        final overlayRect = tester.getRect(
          find.byKey(const Key('topo-route-legend-overlay')),
        );
        return viewportSize.height - overlayRect.bottom;
      }

      final viewOffset = await legendBottomOffsetFor(DrawMode.view);
      final drawOffset = await legendBottomOffsetFor(DrawMode.draw);

      expect(
        drawOffset - viewOffset,
        closeTo(kBottomChromeClusterHeight + MasiSpacing.sm, 0.5),
        reason:
            'view=$viewOffset draw=$drawOffset — draw mode must reserve '
            'exactly kBottomChromeClusterHeight + sm more bottom clearance '
            'than view mode, so the legend sits flush in view mode without '
            'ever being covered by the draw-mode cluster',
      );
    },
  );

  testWidgets(
    'A4: draw mode still shows the undo/redo/clear/commit cluster, with no '
    'bottom-right add-photo FAB alongside it',
    (tester) async {
      final seeded = await seedWallWithPhotoAndRoute(tester);
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);

      await tester.pumpWidget(
        wrap(
          seeded.container,
          TopoCanvasScreen(
            wallId: seeded.wallId,
            debugInitialImageSize: const Size(1000, 2000),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('topo-mode-toggle')));
      await tester.pumpAndSettle();
      expect(
        seeded.container.read(drawControllerProvider).mode,
        DrawMode.draw,
      );

      expect(find.byKey(const Key('topo-undo-button')), findsOneWidget);
      expect(find.byKey(const Key('topo-redo-button')), findsOneWidget);
      expect(find.byKey(const Key('topo-clear-button')), findsOneWidget);
      expect(find.byKey(const Key('topo-commit-button')), findsOneWidget);

      // The add-photo control lives in the TOP bar now (still reachable
      // while drawing) — exactly one 'Pick a photo' control exists anywhere,
      // and it's the top-bar key, never a second bottom-right floating FAB
      // alongside the cluster.
      expect(find.byKey(const Key('topo-add-photo-button')), findsOneWidget);
      expect(find.byTooltip('Pick a photo'), findsOneWidget);
    },
  );

  testWidgets(
    'A5: with no photo yet, the empty state still offers a working '
    'add-photo affordance (top-bar button) — the user is never stranded',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          nowMsProvider.overrideWithValue(() => 1000),
        ],
      );
      addTearDown(container.dispose);
      final crud = container.read(libraryCrudRepositoryProvider);
      final area = await crud.createArea('Area');
      final sector = await crud.createSector(area.id, 'Sector');
      final wall = await crud.createWall(sector.id, 'Wall');

      await tester.pumpWidget(wrap(container, TopoCanvasScreen(wallId: wall.id)));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('topo-empty-state')), findsOneWidget);
      expect(
        find.byKey(const Key('topo-add-photo-button')),
        findsOneWidget,
        reason:
            'the user must never be stranded with no way to add a first '
            'photo once the bottom-right FAB is gone',
      );

      await tester.tap(find.byKey(const Key('topo-add-photo-button')));
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoActionSheet), findsOneWidget);

      await tester.tap(find.byKey(const Key('photo-source-cancel')));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'A7: readOnly hides the add-photo affordance everywhere — neither the '
    'top-bar button nor any bottom control renders',
    (tester) async {
      final seeded = await seedWallWithPhotoAndRoute(tester);
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);

      await tester.pumpWidget(
        wrap(
          seeded.container,
          TopoCanvasScreen(
            wallId: seeded.wallId,
            readOnly: true,
            debugInitialImageSize: const Size(1000, 2000),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('topo-add-photo-button')), findsNothing);
      expect(find.byTooltip('Pick a photo'), findsNothing);
    },
  );

  testWidgets(
    'top pill with route selected (5 trailing actions) does not overflow '
    'at 375px width',
    (tester) async {
      // 375px is this project's supported minimum width (see CLAUDE.md /
      // DESIGN.md). 320px (older, narrower iPhones) is intentionally out
      // of scope for this regression test.
      const viewportSize = Size(375, 812);
      tester.view.physicalSize = viewportSize;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final seeded = await seedWallWithPhotoAndRoute(tester);
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);

      await tester.pumpWidget(
        wrap(
          seeded.container,
          TopoCanvasScreen(
            wallId: seeded.wallId,
            debugInitialImageSize: const Size(1000, 2000),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        seeded.container.read(drawControllerProvider).mode,
        DrawMode.view,
      );
      expect(
        seeded.container.read(drawControllerProvider).routes,
        hasLength(1),
      );

      // Select the seeded route directly through the same provider
      // `_topTrailingActions` reads (`drawControllerProvider`) — this is
      // the gate the edit-metadata glyph needs (`selectedRouteId != null`),
      // and is far less fiddly than hit-testing the canvas's route-tap
      // detection to select it via a real tap.
      seeded.container.read(drawControllerProvider.notifier).selectRoute(1);
      await tester.pumpAndSettle();

      // All 5 trailing glyphs are now simultaneously present: edit-metadata
      // (route selected) + AR (photo + a visible route) + mode-toggle +
      // slice-mode-entry + add-photo — the worst case for the top pill's
      // trailing action row in view mode.
      expect(
        find.byKey(const Key('topo-edit-metadata-button')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('topo-ar-button')), findsOneWidget);
      expect(find.byKey(const Key('topo-mode-toggle')), findsOneWidget);
      expect(find.byKey(const Key('topo-slice-mode-button')), findsOneWidget);
      expect(find.byKey(const Key('topo-add-photo-button')), findsOneWidget);

      // No RenderFlex overflow (or any other exception) from cramming the
      // back chevron + title + 5 icons into the top pill at the supported
      // minimum width.
      expect(tester.takeException(), isNull);

      // The title still renders (ellipsized is fine at this width).
      expect(find.text('Wall'), findsOneWidget);
    },
  );
}
