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

import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/topo/application/draw_controller.dart';
import 'package:masi/features/topo/data/route_repository.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
import 'package:masi/features/topo/presentation/canvas_chrome.dart';
import 'package:masi/features/topo/presentation/route_legend.dart';
import 'package:masi/features/topo/presentation/topo_canvas_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

void main() {
  /// Seeds a real Area -> Sector -> Wall, attaches a photo, and persists a
  /// single 2-point route — the harness shape shared by
  /// canvas_mode_intent_test.dart's A1e, so both the legend AND the
  /// mode-toggle entry point are reachable.
  Future<({AppDatabase db, ProviderContainer container, String wallId})>
  seedWallWithPhotoAndRoute(WidgetTester tester) async {
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
        XFile('/tmp/bottom-reclaim-photo.jpg'),
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

  // A1/A2 note: the claim these tests defend has never changed — there is
  // exactly ONE add-photo affordance on a canvas that has a photo. Only its
  // identity has moved, four times now: a bottom-right FAB, then the photo
  // strip's '+' tile, then a top-row glyph while the strip was a row of 7px
  // dots (a dot row has nothing you can append a '+' to and still have it
  // read as "add a photo"), then the dock's face rail once that put real
  // thumbnails back.
  //
  // It is the top-row glyph again, and now in EDIT mode rather than view
  // (user request, 2026-09-02: "the plus icon at the end of the image roll
  // should only be there in edit mode"). The rail is what a reader pages
  // through — every other tile on it selects a face — so a tile that opens
  // the camera was the odd one out at exactly the moment a thumb was flicking
  // past. The rule now: read mode navigates faces, edit mode changes them.
  // So these tests are inverted relative to how they were written, and the
  // MODE is what they check, not the photo count.

  testWidgets(
    'A1: EDIT mode offers EXACTLY ONE add-photo affordance, in the top bar, '
    'and no bottom-right FAB competing with the route legend',
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
        seeded.container.read(drawControllerProvider(seeded.wallId)).mode,
        DrawMode.view,
      );
      expect(
        find.byKey(const Key('topo-add-photo-button')),
        findsNothing,
        reason: 'reading a topo is not the moment to add a photo to it',
      );

      await tester.tap(find.byKey(const Key('topo-mode-toggle')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('topo-add-photo-button')), findsOneWidget);
      expect(
        find.byType(FloatingActionButton),
        findsNothing,
        reason:
            'a bottom-right FAB sits over the route legend and swallows '
            'its per-route menu taps — painted, findable, unreachable',
      );
      expect(find.byTooltip('Pick a photo'), findsNothing);
    },
  );

  testWidgets(
    'A2: the add-photo glyph shows in edit mode, is withheld while reading, '
    'and tapping it invokes the same _pickImage handler (opens the '
    'photo-source action sheet)',
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

      // View mode: withheld.
      expect(find.byKey(const Key('topo-add-photo-button')), findsNothing);

      // Draw mode: there, and it is the same handler as ever.
      await tester.tap(find.byKey(const Key('topo-mode-toggle')));
      await tester.pumpAndSettle();
      expect(
        seeded.container.read(drawControllerProvider(seeded.wallId)).mode,
        DrawMode.draw,
      );
      expect(find.byKey(const Key('topo-add-photo-button')), findsOneWidget);

      await tester.tap(find.byKey(const Key('topo-add-photo-button')));
      await tester.pumpAndSettle();

      expect(
        find.byType(CupertinoActionSheet),
        findsOneWidget,
        reason:
            'tapping the add-photo glyph must invoke the same _pickImage '
            'handler (showPhotoSourceSheet)',
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
        // FIX #6 (autoDispose pending-timer gotcha): keep this family
        // member alive via a permanent listener so its EVENTUAL widget
        // unmount (mid-test, when the next call's `pumpWidget` replaces
        // this tree; or at the framework's own final teardown, for the
        // last call) never drops the ref count to zero and so never
        // schedules an autoDispose teardown `Timer(Duration.zero, ...)` --
        // that Timer only gets fired by a duration-based
        // `tester.pump`/`pumpAndSettle`, and the final-teardown unmount
        // happens AFTER this test body returns, too late for any pump we
        // could still call. See route_legend_gap_test.dart's `_seedRoutes`
        // for the fuller explanation.
        container.listen(drawControllerProvider('test-wall'), (_, _) {});
        container.listen(legendExpandedProvider('test-wall'), (_, _) {});
        final controller = TransformationController();
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: MasiTheme.light,
              home: Scaffold(
                body: TopoCanvasBody(
                  wallId: 'test-wall',
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
    'A4: draw mode still shows the undo/redo/clear/commit cluster, and the '
    'add-photo glyph sits in the TOP row, nowhere near it',
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
        seeded.container.read(drawControllerProvider(seeded.wallId)).mode,
        DrawMode.draw,
      );

      expect(find.byKey(const Key('topo-undo-button')), findsOneWidget);
      expect(find.byKey(const Key('topo-redo-button')), findsOneWidget);
      expect(find.byKey(const Key('topo-clear-button')), findsOneWidget);
      expect(find.byKey(const Key('topo-commit-button')), findsOneWidget);

      // The add-photo glyph belongs to edit mode now, so it IS on screen —
      // but in the top row, which is the whole reason it is allowed to be:
      // nothing competes with the cluster for the bottom of the screen.
      final addPhoto = find.byKey(const Key('topo-add-photo-button'));
      expect(addPhoto, findsOneWidget);
      expect(
        tester.getBottomLeft(addPhoto).dy,
        lessThan(
          tester.getTopLeft(find.byKey(const Key('topo-undo-button'))).dy,
        ),
      );
      expect(find.byType(FloatingActionButton), findsNothing);
    },
  );

  testWidgets('A5: with no photo yet, the empty state still offers a working '
      'add-photo affordance — the user is never stranded.', (tester) async {
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
    expect(find.byKey(const Key('photo-strip-add')), findsNothing);
    expect(
      find.byKey(const Key('topo-empty-state-add-photo')),
      findsOneWidget,
      reason:
          'the user must never be stranded with no way to add a first '
          'photo once the bottom-right FAB is gone',
    );

    await tester.tap(find.byKey(const Key('topo-empty-state-add-photo')));
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoActionSheet), findsOneWidget);

    await tester.tap(find.byKey(const Key('photo-source-cancel')));
    await tester.pumpAndSettle();
  });

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
      expect(find.byKey(const Key('photo-strip-add')), findsNothing);
      expect(find.byTooltip('Pick a photo'), findsNothing);
    },
  );

  testWidgets('top pill with route selected does not overflow at 375px width', (
    tester,
  ) async {
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
      seeded.container.read(drawControllerProvider(seeded.wallId)).mode,
      DrawMode.view,
    );
    expect(
      seeded.container.read(drawControllerProvider(seeded.wallId)).routes,
      hasLength(1),
    );

    // Select the seeded route directly through the same provider
    // `_topTrailingActions` reads (`drawControllerProvider`) — this is
    // the gate the edit-metadata glyph needs (`selectedRouteId != null`),
    // and is far less fiddly than hit-testing the canvas's route-tap
    // detection to select it via a real tap.
    seeded.container
        .read(drawControllerProvider(seeded.wallId).notifier)
        .selectRoute(1);
    await tester.pumpAndSettle();

    // View mode's full trailing set: AR (photo + a visible route) +
    // mode-toggle + locate-on-map. Three glyphs lighter than it once was —
    // edit-metadata and, since 2026-09-02, add-photo are both edit-mode
    // actions — so this is the SMALLER of the two modes; draw mode's
    // Cancel/Save pair is the width worst case, covered by
    // topo_canvas_edit_location_test.dart and re-checked below.
    expect(find.byKey(const Key('topo-ar-button')), findsOneWidget);
    expect(find.byKey(const Key('topo-mode-toggle')), findsOneWidget);
    expect(find.byKey(const Key('topo-locate-on-map-button')), findsOneWidget);
    expect(
      find.byKey(const Key('topo-edit-metadata-button')),
      findsNothing,
      reason: 'editing a route\'s details is an edit-mode action now',
    );
    expect(
      find.byKey(const Key('topo-add-photo-button')),
      findsNothing,
      reason: 'so is adding a photo of the rock',
    );

    // No RenderFlex overflow (or any other exception) from cramming the
    // back chevron + title + 5 icons into the top pill at the supported
    // minimum width, with every tap target at the iOS HIG's 44x44
    // minimum (see `_topRowIconStyle`'s doc) — the accessibility
    // regression this test guards against is a tap target shrunk BELOW
    // 44x44 to buy overflow margin, not the overflow itself.
    expect(tester.takeException(), isNull);

    // The title still renders (ellipsized is fine at this width).
    expect(find.text('Wall'), findsOneWidget);

    // And the mode that gained a glyph still fits. Draw mode is where
    // add-photo lives now, so the width worst case moved with it and has to
    // be measured here rather than assumed.
    await tester.tap(find.byKey(const Key('topo-mode-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('topo-add-photo-button')), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(find.text('Wall'), findsOneWidget);
  });

  testWidgets(
    'top pill with route selected does not overflow at 375px width even at '
    'a 3x text scale — MasiIcons are fixed-size, so only the row\'s height '
    'should grow, never its width',
    (tester) async {
      const viewportSize = Size(375, 812);
      tester.view.physicalSize = viewportSize;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final seeded = await seedWallWithPhotoAndRoute(tester);
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: seeded.container,
          child: MaterialApp(
            theme: MasiTheme.light,
            // Wraps the whole app in a forced 3x textScaler — a MediaQuery
            // override closer to the root than TopoCanvasScreen itself, so
            // both the title Text and every tooltip/label in the top pill
            // observe it, mirroring how a real device-wide "Larger Text"
            // accessibility setting reaches this screen.
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(3.0)),
              child: child!,
            ),
            home: TopoCanvasScreen(
              wallId: seeded.wallId,
              debugInitialImageSize: const Size(1000, 2000),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        seeded.container.read(drawControllerProvider(seeded.wallId)).mode,
        DrawMode.view,
      );
      seeded.container
          .read(drawControllerProvider(seeded.wallId).notifier)
          .selectRoute(1);
      await tester.pumpAndSettle();

      // Same trailing set as the 1x test above, all still present under the
      // 3x scale.
      expect(find.byKey(const Key('topo-ar-button')), findsOneWidget);
      expect(find.byKey(const Key('topo-mode-toggle')), findsOneWidget);
      expect(
        find.byKey(const Key('topo-locate-on-map-button')),
        findsOneWidget,
      );

      // Selecting a route (needed so the AR/edit-metadata glyphs above are
      // both present, the worst case this test targets) also surfaces the
      // floating RouteLegend overlay — a SEPARATE widget from the top
      // chrome this test exercises. `_LegendHeader` and `_LegendChip` used
      // to RenderFlex-overflow at extreme text scales (their route-count
      // `Text` had no `Flexible`/ellipsis), which this test used to drain
      // rather than assert away, so that pre-existing, separate bug didn't
      // spuriously fail this test's real claim about the top chrome. Now
      // that both widgets wrap their count `Text` in a `Flexible` with
      // `overflow: TextOverflow.ellipsis` (see topo_canvas_screen.dart),
      // the legend no longer overflows either, so this asserts zero
      // exceptions outright instead of draining them.
      expect(tester.takeException(), isNull);

      // Direct proof the legend header itself fits the viewport at 3x (not
      // just "no exception anywhere") — the expanded `_LegendHeader` form,
      // since selecting a route above doesn't touch `legendExpandedProvider`
      // and the screen starts in DrawMode.view (which defaults it expanded).
      final legendRect = tester.getRect(
        find.byKey(const Key('topo-route-legend-overlay')),
      );
      expect(
        legendRect.right,
        lessThanOrEqualTo(viewportSize.width),
        reason:
            'the expanded route-legend header (rect=$legendRect) must not '
            'overflow the $viewportSize viewport at 3x text scale',
      );
      expect(
        legendRect.left,
        greaterThanOrEqualTo(0),
        reason: 'topo-route-legend-overlay must not be laid out off-screen',
      );

      // The real proof: every glyph in the top chrome row — the back
      // button plus all 5 trailing actions — is laid out entirely within
      // the 375px viewport. If this row itself had overflowed (the
      // regression this test guards against), the trailing button(s) that
      // don't fit would be positioned with `rect.right` beyond the
      // viewport's width. MasiIcon glyphs are fixed-size SVGs, unaffected
      // by textScaler, so this must hold at 3x exactly as it does at 1x
      // (see the sibling test above) — only the title's rendered text
      // (already in an ellipsizing `Expanded` slot) and the row's height
      // are expected to respond to text scale at all.
      for (final key in const [
        'topo-back-button',
        'topo-ar-button',
        'topo-mode-toggle',
        'topo-locate-on-map-button',
      ]) {
        final rect = tester.getRect(find.byKey(Key(key)));
        expect(
          rect.left,
          greaterThanOrEqualTo(0),
          reason: '$key must not be laid out off-screen to the left',
        );
        expect(
          rect.right,
          lessThanOrEqualTo(viewportSize.width),
          reason:
              '$key (rect=$rect) must not overflow the $viewportSize '
              'viewport at 3x text scale',
        );
      }
    },
  );

  testWidgets(
    'collapsed route-legend chip (_LegendChip) does not overflow at 375px '
    'width even at a 3x text scale — companion to the expanded-header '
    'coverage above, since the chip is a structurally different Row '
    '(mainAxisSize.min, no Spacer) that needed its own Flexible+ellipsis '
    'fix on the route-count Text',
    (tester) async {
      const viewportSize = Size(375, 812);
      tester.view.physicalSize = viewportSize;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final seeded = await seedWallWithPhotoAndRoute(tester);
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: seeded.container,
          child: MaterialApp(
            theme: MasiTheme.light,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(3.0)),
              child: child!,
            ),
            home: TopoCanvasScreen(
              wallId: seeded.wallId,
              debugInitialImageSize: const Size(1000, 2000),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        seeded.container.read(drawControllerProvider(seeded.wallId)).mode,
        DrawMode.view,
      );

      // The screen starts with the legend expanded (view mode's default —
      // see LegendExpandedController.build()); force it into the collapsed
      // `_LegendChip` form directly via the provider, the same seam
      // legend_reset_on_remount_test.dart uses, rather than hunting for a
      // tappable chevron.
      seeded.container
          .read(legendExpandedProvider(seeded.wallId).notifier)
          .toggle();
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('topo-route-legend-chip')),
        findsOneWidget,
        reason: 'legend must be in its collapsed chip form for this test',
      );
      expect(find.byKey(const Key('topo-route-legend-overlay')), findsNothing);

      // No RenderFlex overflow (or any other exception) from the chip's
      // route-count Text growing at 3x scale.
      expect(tester.takeException(), isNull);

      // Direct proof the chip itself fits the viewport at 3x, not just "no
      // exception anywhere".
      final chipRect = tester.getRect(
        find.byKey(const Key('topo-route-legend-chip')),
      );
      expect(
        chipRect.right,
        lessThanOrEqualTo(viewportSize.width),
        reason:
            'the collapsed route-legend chip (rect=$chipRect) must not '
            'overflow the $viewportSize viewport at 3x text scale',
      );
      expect(
        chipRect.left,
        greaterThanOrEqualTo(0),
        reason: 'topo-route-legend-chip must not be laid out off-screen',
      );
    },
  );
}
