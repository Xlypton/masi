// Intended-behavior tests for legend expand/collapse (Fix 1/3).
//
//  - `LegendExpandedController`/`legendExpandedProvider` (route_legend.dart):
//    `build()` defaults to expanded (`true`); `toggle()` flips it;
//    `setForMode(DrawMode)` resets to the mode-appropriate default (expanded
//    in view, collapsed in draw).
//  - `TopoCanvasBody.build` (topo_canvas_screen.dart): whenever
//    `drawState.routes` is non-empty, exactly one of the expanded overlay
//    card (`topo-route-legend-overlay`, containing `topo-route-legend`) or
//    the collapsed chip (`topo-route-legend-chip`) renders, mutually
//    exclusive, driven by `legendExpandedProvider`. With zero routes,
//    neither renders.
//  - `_TopoCanvasScreenState.build`'s `ref.listen<DrawMode>(...)` — present
//    ONLY on the real `TopoCanvasScreen`, not the raw `TopoCanvasBody`
//    harness — calls `setForMode` whenever `DrawState.mode` actually
//    changes, so entering draw mode collapses the legend to the chip and
//    returning to view mode re-expands it.
//
// `_seedWallWithPhotoAndRoute` mirrors topo_canvas_zoom_overlay_test.dart's
// helper of the same name (real DB + a committed route via
// `DrawController`).
import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/topo/application/draw_controller.dart';
import 'package:masi/features/topo/presentation/route_legend.dart';
import 'package:masi/features/topo/presentation/topo_canvas_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

const _overlayKey = Key('topo-route-legend-overlay');
const _chipKey = Key('topo-route-legend-chip');
const _legendKey = Key('topo-route-legend');

/// FIX #6 (family-keyed `drawControllerProvider`/`legendExpandedProvider`):
/// stand-in wallId for the tests below that don't seed a real wall (the
/// seeded-wall tests use `seeded.wallId` instead, consistently).
const _testWallId = 'test-wall';

/// Creates a real in-memory DB + ProviderContainer + a persisted
/// Area/Sector/Wall, attaches a photo, and commits one route via
/// [DrawController] — mirrors
/// `topo_canvas_zoom_overlay_test.dart:_seedWallWithPhotoAndRoute`.
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
      XFile('/tmp/legend-expand-collapse-photo.jpg'),
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
  group('legendExpandedProvider (unit)', () {
    test('build() defaults to expanded (true)', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(legendExpandedProvider(_testWallId)), isTrue);
    });

    test('toggle() flips the state', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(legendExpandedProvider(_testWallId).notifier);

      expect(container.read(legendExpandedProvider(_testWallId)), isTrue);
      notifier.toggle();
      expect(container.read(legendExpandedProvider(_testWallId)), isFalse);
      notifier.toggle();
      expect(container.read(legendExpandedProvider(_testWallId)), isTrue);
    });

    test('setForMode(DrawMode.draw) collapses (false); '
        'setForMode(DrawMode.view) expands (true)', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(legendExpandedProvider(_testWallId).notifier);

      notifier.setForMode(DrawMode.draw);
      expect(container.read(legendExpandedProvider(_testWallId)), isFalse);

      notifier.setForMode(DrawMode.view);
      expect(container.read(legendExpandedProvider(_testWallId)), isTrue);
    });
  });

  group('(a) VIEW mode with routes: overlay present, chip absent', () {
    testWidgets(
      'default DrawState.mode (view) + default legendExpandedProvider '
      '(expanded) render the overlay card, never the collapsed chip',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final controller = TransformationController();
        addTearDown(controller.dispose);

        // FIX #6 (autoDispose pending-timer gotcha): keep this family
        // member alive for the whole test -- see route_legend_gap_test.dart's
        // `_seedRoutes` for the full explanation.
        container.listen(drawControllerProvider(_testWallId), (_, _) {});
        final notifier = container.read(drawControllerProvider(_testWallId).notifier);
        notifier.addPoint(const Offset(0.1, 0.1));
        notifier.addPoint(const Offset(0.2, 0.2));
        await notifier.commitRoute();
        expect(
          container.read(drawControllerProvider(_testWallId)).mode,
          DrawMode.view,
          reason: 'sanity: DrawState.mode defaults to view',
        );

        await tester.pumpWidget(
          UncontrolledProviderScope(
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
                      imageSize: const Size(400, 300),
                      drawState: drawState,
                      transformationController: controller,
                    );
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        expect(
          find.byKey(_overlayKey),
          findsOneWidget,
          reason: 'view mode + expanded default must show the overlay card',
        );
        expect(
          find.descendant(
            of: find.byKey(_overlayKey),
            matching: find.byKey(_legendKey),
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(_chipKey),
          findsNothing,
          reason: 'the collapsed chip must not coexist with the overlay',
        );
      },
    );
  });

  group('(b) DRAW mode collapses the legend to a chip; tapping the chip '
      're-expands it', () {
    testWidgets(
      'on the real TopoCanvasScreen: entering draw mode shows the chip '
      'and hides the overlay; tapping the chip shows the overlay and '
      'hides the chip',
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

        expect(
          find.byKey(_overlayKey),
          findsOneWidget,
          reason: 'sanity: the real screen opens in view mode, expanded',
        );
        expect(find.byKey(_chipKey), findsNothing);

        await tester.tap(find.byKey(const Key('topo-mode-toggle')));
        await tester.pumpAndSettle();

        expect(
          find.byKey(_chipKey),
          findsOneWidget,
          reason:
              'entering draw mode must collapse the legend to the chip '
              '(the mode-change listener calls setForMode(DrawMode.draw))',
        );
        expect(find.byKey(_overlayKey), findsNothing);

        await tester.tap(find.byKey(_chipKey));
        await tester.pumpAndSettle();

        expect(
          find.byKey(_overlayKey),
          findsOneWidget,
          reason: 'tapping the chip must toggle the legend back open',
        );
        expect(find.byKey(_chipKey), findsNothing);
      },
    );
  });

}
