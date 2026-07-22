// Intended-behavior tests for the full-bleed canvas rework: RouteLegend is
// now PERMANENTLY a floating, translucent overlay
// (`topo-route-legend-overlay`) whenever routes exist — regardless of zoom
// level — and never reflows/resizes with it. See:
//  - `TopoCanvasBody.build` in topo_canvas_screen.dart for the permanent
//    overlay `Stack` layout (the old zoom-driven `Column`<->`Stack` swap and
//    its `zoomedIn`/`onZoomedChanged` plumbing are gone entirely).
//  - `TopoCanvas.build` in topo_canvas.dart for the full-bleed viewport (no
//    more rounded/clipped inset frame, no more `computeZoomedIn` hysteresis
//    or `onZoomedChanged` listener — see topo_canvas_fit_test.dart's
//    (now-removed) viewport-frame group for the prior rounded-frame
//    coverage).
//
// A1 drives the REAL `TopoCanvasScreen` end-to-end (seeded wall + attached
// photo + a committed route, `debugInitialImageSize` to bypass the
// undriveable real image decode — mirrors `canvas_chrome_gating_test.dart`'s
// "A-f"/"slices DB read" groups) and manipulates the shared
// `TransformationController` exactly the way a real pinch-zoom gesture
// would, to prove the overlay legend and full-bleed canvas hold at the
// initial fit transform AND after a zoom — there is no swap to look for
// anymore, only an invariant to hold across both states.
//
// A2 drives `TopoCanvasBody` directly (mirroring `canvas_viewport_intent_
// test.dart`'s `_buildBody` harness) for a fast, structural check of the
// permanent-overlay layout, independent of a real TransformationController.
import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/topo/application/draw_controller.dart';
import 'package:masi/features/topo/presentation/topo_canvas.dart';
import 'package:masi/features/topo/presentation/topo_canvas_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

const _viewerKey = Key('topo-interactive-viewer');
const _overlayLegendKey = Key('topo-route-legend-overlay');
const _legendKey = Key('topo-route-legend');
const _chipKey = Key('topo-route-legend-chip');

/// FIX #6 (family-keyed `drawControllerProvider`): stand-in wallId for A2's
/// standalone-container group (A1's seeded-wall group uses `seeded.wallId`
/// instead, consistently).
const _testWallId = 'test-wall';

Finder _canvasExpandedAncestorFinder() =>
    find.ancestor(of: find.byKey(_viewerKey), matching: find.byType(Expanded));

Future<({AppDatabase db, ProviderContainer container, String wallId})>
_seedWallWithPhotoAndRoute(WidgetTester tester) async {
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
  late String photoId;
  await tester.runAsync(() async {
    photoId = await crud.attachPhotoToWall(
      wall.id,
      XFile('/tmp/zoom-overlay-test-photo.jpg'),
      400,
      300,
    );
  });

  final notifier = container.read(drawControllerProvider(wall.id).notifier);
  await notifier.loadForWall(wall.id, photoId);
  notifier.addPoint(const Offset(0.1, 0.1));
  notifier.addPoint(const Offset(0.2, 0.2));
  await notifier.commitRoute();

  return (db: db, container: container, wallId: wall.id);
}

void main() {
  group(
    'A1: TopoCanvasScreen end-to-end — RouteLegend is a permanent overlay',
    () {
      testWidgets(
        'RouteLegend floats as the overlay at the initial fit transform AND '
        'after zooming past it AND after zooming back — it never becomes '
        'in-flow, and the canvas never gains an Expanded ancestor',
        (tester) async {
          final seeded = await _seedWallWithPhotoAndRoute(tester);
          addTearDown(seeded.db.close);
          addTearDown(seeded.container.dispose);

          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: seeded.container,
              child: MaterialApp(
                theme: MasiTheme.light,
                home: TopoCanvasScreen(
                  wallId: seeded.wallId,
                  debugInitialImageSize: const Size(400, 300),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          // At the initial fit transform (no zoom at all yet), the legend
          // is ALREADY the floating overlay — never in-flow.
          expect(
            find.byKey(_overlayLegendKey),
            findsOneWidget,
            reason:
                'RouteLegend must be a permanent floating overlay, even '
                'before any zoom',
          );
          expect(
            find.descendant(
              of: find.byKey(_overlayLegendKey),
              matching: find.byKey(_legendKey),
            ),
            findsOneWidget,
            reason:
                "RouteLegend's own key must be preserved inside the "
                'floating overlay',
          );
          expect(
            _canvasExpandedAncestorFinder(),
            findsNothing,
            reason:
                'the canvas fills the body via Positioned.fill, never an '
                'Expanded row shared with the legend',
          );

          final controller = tester
              .widget<InteractiveViewer>(find.byKey(_viewerKey))
              .transformationController!;
          final fitMatrix = Matrix4.copy(controller.value);

          // Zoom well past the fit scale — mirrors a real pinch-zoom
          // updating the SAME shared TransformationController the screen
          // renders against.
          controller.value = Matrix4.copy(fitMatrix)
            ..setEntry(0, 0, fitMatrix.entry(0, 0) * 3.0)
            ..setEntry(1, 1, fitMatrix.entry(1, 1) * 3.0)
            ..setEntry(2, 2, fitMatrix.entry(2, 2) * 3.0);
          await tester.pump();

          expect(
            find.byKey(_overlayLegendKey),
            findsOneWidget,
            reason:
                'zooming in must NOT change anything about the '
                'permanent overlay legend',
          );
          expect(_canvasExpandedAncestorFinder(), findsNothing);

          // Zoom back down to EXACTLY the fit matrix.
          controller.value = fitMatrix;
          await tester.pump();

          expect(
            find.byKey(_overlayLegendKey),
            findsOneWidget,
            reason:
                'zooming back out must NOT change anything about the '
                'permanent overlay legend either',
          );
          expect(_canvasExpandedAncestorFinder(), findsNothing);
        },
      );
    },
  );

  group(
    'A2: TopoCanvasBody — RouteLegend is a permanent overlay (structural)',
    () {
      Widget buildBody({
        required ProviderContainer container,
        required TransformationController controller,
        Size imageSize = const Size(400, 300),
        Key? canvasKey,
      }) {
        return UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: MasiTheme.light,
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) {
                  final drawState = ref.watch(drawControllerProvider(_testWallId));
                  return TopoCanvasBody(
                    wallId: _testWallId,
                    imagePath: '/nonexistent/test-topo.jpg',
                    imageSize: imageSize,
                    drawState: drawState,
                    transformationController: controller,
                    canvasKey: canvasKey,
                  );
                },
              ),
            ),
          ),
        );
      }

      void seedRoutes(ProviderContainer container, int count) {
        // FIX #6 (autoDispose pending-timer gotcha): keep this family
        // member alive for the whole test -- see route_legend_gap_test.dart's
        // `_seedRoutes` for the full explanation.
        container.listen(drawControllerProvider(_testWallId), (_, _) {});
        final notifier = container.read(drawControllerProvider(_testWallId).notifier);
        for (var i = 0; i < count; i++) {
          final y = 0.1 + i * 0.05;
          notifier.addPoint(Offset(0.1, y));
          notifier.addPoint(Offset(0.2, y + 0.02));
          notifier.commitRoute();
        }
      }

      testWidgets(
        'RouteLegend floats as the overlay whenever routes exist — no '
        'in-flow legend, and no Expanded reserves a legend row anywhere '
        'in the tree',
        (tester) async {
          final container = ProviderContainer();
          addTearDown(container.dispose);
          final controller = TransformationController();
          addTearDown(controller.dispose);
          seedRoutes(container, 1);

          await tester.pumpWidget(
            buildBody(container: container, controller: controller),
          );
          await tester.pump();

          expect(find.byKey(_overlayLegendKey), findsOneWidget);
          expect(
            find.descendant(
              of: find.byKey(_overlayLegendKey),
              matching: find.byKey(_legendKey),
            ),
            findsOneWidget,
            reason:
                "RouteLegend's own key must be preserved inside the "
                'floating overlay',
          );
          expect(
            _canvasExpandedAncestorFinder(),
            findsNothing,
            reason:
                'the canvas must never share an Expanded row with an '
                'in-flow legend — it always fills its region via '
                'Positioned.fill',
          );
        },
      );

      testWidgets(
        'RouteLegend still floats as the overlay after a manual zoom on '
        'the shared TransformationController — the layout never swaps or '
        'reflows regardless of scale',
        (tester) async {
          final container = ProviderContainer();
          addTearDown(container.dispose);
          final controller = TransformationController();
          addTearDown(controller.dispose);
          seedRoutes(container, 1);

          await tester.pumpWidget(
            buildBody(container: container, controller: controller),
          );
          await tester.pump();
          final rectBefore = tester.getRect(find.byKey(_viewerKey));

          controller.value = Matrix4.identity()
            ..setEntry(0, 0, 3.0)
            ..setEntry(1, 1, 3.0)
            ..setEntry(2, 2, 3.0);
          await tester.pump();

          expect(find.byKey(_overlayLegendKey), findsOneWidget);
          final rectAfter = tester.getRect(find.byKey(_viewerKey));
          expect(
            rectAfter,
            rectBefore,
            reason:
                'the canvas viewport itself must not resize/move just '
                'because the user zoomed — only the content inside '
                'InteractiveViewer moves',
          );
        },
      );

      testWidgets(
        'with ZERO routes: no overlay chip floats uselessly (an empty '
        'wall renders no legend at all, in-flow or floating)',
        (tester) async {
          final container = ProviderContainer();
          addTearDown(container.dispose);
          final controller = TransformationController();
          addTearDown(controller.dispose);

          await tester.pumpWidget(
            buildBody(container: container, controller: controller),
          );
          await tester.pump();

          expect(find.byKey(_overlayLegendKey), findsNothing);
          expect(find.byKey(_legendKey), findsNothing);
          expect(
            find.byKey(_chipKey),
            findsNothing,
            reason:
                'the collapsed chip (Fix 1/3) must also be absent with '
                'zero routes — it is gated on hasRoutes exactly like the '
                'overlay card',
          );
        },
      );

      testWidgets(
        'a stable canvasKey preserves TopoCanvas\'s own Element/State '
        'across an ordinary rebuild (e.g. a new route committing) — this '
        'is the same GlobalKey wiring that used to guard the now-removed '
        'zoomedIn Column<->Stack toggle; kept as a cheap regression guard '
        'even though TopoCanvas no longer restructures at all',
        (tester) async {
          final container = ProviderContainer();
          addTearDown(container.dispose);
          final controller = TransformationController();
          addTearDown(controller.dispose);
          final canvasKey = GlobalKey();

          await tester.pumpWidget(
            buildBody(
              container: container,
              controller: controller,
              canvasKey: canvasKey,
            ),
          );
          await tester.pump();
          final stateBefore = tester.state(find.byType(TopoCanvas));

          seedRoutes(container, 1);
          await tester.pump();
          final stateAfter = tester.state(find.byType(TopoCanvas));

          expect(
            identical(stateAfter, stateBefore),
            isTrue,
            reason:
                'the SAME _TopoCanvasState instance must survive a normal '
                'rebuild of TopoCanvasBody',
          );
        },
      );
    },
  );
}
