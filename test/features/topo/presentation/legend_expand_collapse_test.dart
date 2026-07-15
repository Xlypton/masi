// Intended-behavior tests for legend expand/collapse (Fix 1/3) and the
// floating top-chrome stacking order of PhotoSelector vs. SymbolPaletteBar
// (FIX 5, updated for the slice-picker relocation bug fix).
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
//  - FIX 5 (slice-picker relocation bug fix): `PhotoSelector` no longer
//    lives in-flow inside `TopoCanvasBody`'s Column — it floats in
//    `_TopoCanvasScreenState.build`'s own top glass chrome Column, stacked
//    title pill -> PhotoSelector (when the wall has slices) ->
//    SymbolPaletteBar (draw mode only), each separated by a fixed
//    `MasiSpacing.sm` gap the Column itself provides, so entering draw mode
//    (which makes SymbolPaletteBar appear) can never make it overlap
//    PhotoSelector: it always renders BELOW it.
//
// Seeding helpers mirror the existing patterns in this directory:
// `_seedWallWithPhotoAndRoute` mirrors topo_canvas_zoom_overlay_test.dart's
// helper of the same name (real DB + a committed route via
// `DrawController`); `_seedWallWithSlicesAndPhoto` mirrors
// canvas_chrome_gating_test.dart's "A-h" harness (attach a photo, then
// persist real slices via `PhotoRepository.replaceSlices`) minus the
// deliberate late-resolving gate, which isn't needed here.
import 'package:climbtopo/app/theme.dart';
import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/core/db/database_provider.dart';
import 'package:climbtopo/features/library/application/library_providers.dart';
import 'package:climbtopo/features/topo/application/draw_controller.dart';
import 'package:climbtopo/features/topo/data/photo_repository.dart';
import 'package:climbtopo/features/topo/domain/slice_geometry.dart';
import 'package:climbtopo/features/topo/presentation/photo_selector.dart';
import 'package:climbtopo/features/topo/presentation/route_legend.dart';
import 'package:climbtopo/features/topo/presentation/symbol_palette_bar.dart';
import 'package:climbtopo/features/topo/presentation/topo_canvas_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _overlayKey = Key('topo-route-legend-overlay');
const _chipKey = Key('topo-route-legend-chip');
const _legendKey = Key('topo-route-legend');

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
      '/tmp/legend-expand-collapse-photo.jpg',
      400,
      300,
    );
  });

  final notifier = container.read(drawControllerProvider.notifier);
  await notifier.loadForWall(wall.id, photoId);
  notifier.addPoint(const Offset(0.1, 0.1));
  notifier.addPoint(const Offset(0.2, 0.2));
  await notifier.commitRoute();

  return (db: db, container: container, wallId: wall.id);
}

/// Creates a real in-memory DB + ProviderContainer + a persisted
/// Area/Sector/Wall, attaches an original photo, and persists real slices
/// for it via [PhotoRepository.replaceSlices] — mirrors
/// `canvas_chrome_gating_test.dart`'s "A-h" harness (minus its deliberate
/// late-resolving gate, which this doesn't need) so [PhotoSelector] renders
/// once the real [TopoCanvasScreen] loads this wall.
Future<({AppDatabase db, ProviderContainer container, String wallId})>
_seedWallWithSlicesAndPhoto(WidgetTester tester) async {
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

  const path = '/tmp/legend-expand-collapse-slices-photo.jpg';
  await tester.runAsync(() async {
    final photoId = await crud.attachPhotoToWall(wall.id, path, 400, 300);
    await container.read(photoRepositoryProvider).replaceSlices(
      wall.id,
      photoId,
      400,
      300,
      path,
      const [SliceSpec(0.0, 0.5), SliceSpec(0.5, 0.5)],
    );
  });

  return (db: db, container: container, wallId: wall.id);
}

void main() {
  group('legendExpandedProvider (unit)', () {
    test('build() defaults to expanded (true)', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(legendExpandedProvider), isTrue);
    });

    test('toggle() flips the state', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(legendExpandedProvider.notifier);

      expect(container.read(legendExpandedProvider), isTrue);
      notifier.toggle();
      expect(container.read(legendExpandedProvider), isFalse);
      notifier.toggle();
      expect(container.read(legendExpandedProvider), isTrue);
    });

    test(
      'setForMode(DrawMode.draw) collapses (false); '
      'setForMode(DrawMode.view) expands (true)',
      () {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final notifier = container.read(legendExpandedProvider.notifier);

        notifier.setForMode(DrawMode.draw);
        expect(container.read(legendExpandedProvider), isFalse);

        notifier.setForMode(DrawMode.view);
        expect(container.read(legendExpandedProvider), isTrue);
      },
    );
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

        final notifier = container.read(drawControllerProvider.notifier);
        notifier.addPoint(const Offset(0.1, 0.1));
        notifier.addPoint(const Offset(0.2, 0.2));
        await notifier.commitRoute();
        expect(
          container.read(drawControllerProvider).mode,
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
                    final drawState = ref.watch(drawControllerProvider);
                    return TopoCanvasBody(
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

  group(
    '(b) DRAW mode collapses the legend to a chip; tapping the chip '
    're-expands it',
    () {
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
    },
  );

  group(
    '(c) FIX 5: sliced wall in DRAW mode — PhotoSelector never overlaps '
    'SymbolPaletteBar',
    () {
      testWidgets(
        'PhotoSelector floats ABOVE SymbolPaletteBar in the top chrome '
        'Column once draw mode makes the palette appear, so the two never '
        'overlap',
        (tester) async {
          final seeded = await _seedWallWithSlicesAndPhoto(tester);
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
            find.byType(PhotoSelector),
            findsOneWidget,
            reason:
                'sanity: persisted slices must show PhotoSelector once '
                'loaded, in the default view mode',
          );
          expect(
            find.byType(SymbolPaletteBar),
            findsNothing,
            reason: 'sanity: the palette is draw-mode only',
          );

          await tester.tap(find.byKey(const Key('topo-mode-toggle')));
          await tester.pumpAndSettle();

          expect(find.byType(PhotoSelector), findsOneWidget);
          expect(find.byType(SymbolPaletteBar), findsOneWidget);

          final photoRect = tester.getRect(find.byType(PhotoSelector));
          final paletteRect = tester.getRect(find.byType(SymbolPaletteBar));
          expect(
            paletteRect.top,
            greaterThanOrEqualTo(photoRect.bottom - 0.5),
            reason:
                'FIX 5 (slice-picker relocation): the top chrome Column '
                'stacks PhotoSelector directly above SymbolPaletteBar, so '
                'SymbolPaletteBar must always render AT OR BELOW '
                "PhotoSelector's bottom edge once draw mode makes it appear "
                '— the two floating glass elements must never overlap',
          );
        },
      );
    },
  );
}
