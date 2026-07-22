// Intended-behavior tests for Subtask A (masi-canvas-look-rework.md)
// assertions A-f and A-g — NOT derived from the pre-rework implementation. A
// failing test here is a real bug to fix in lib/, never a reason to weaken
// the assertion.
//
//  - A-f: the symbol palette renders on GlassChrome (not an opaque
//    ColoredBox(surfaceContainerHighest)); it no longer reserves a
//    permanent in-flow slot inside TopoCanvasBody (view mode reclaims that
//    height); and once floated as a screen overlay, it never overlaps the
//    title pill.
//  - A-g (Bug 8): in the no-photo empty state, topo-ar-button is absent
//    (it needs a photo).
//
// Web-port Subtask A (WEB_PORT_BRIEF.md): the AR button must stay VISIBLE
// once a photo + a visible route exist, but become DISABLED
// (`onPressed: null`) wherever `isArSupported()` is false. VM tests run on
// macOS (not iOS), so `isArSupported()` is false in-process here — this is
// exactly the disabled branch this file exercises; the enabled/iOS branch
// is unchanged behavior verified on-device per CLAUDE.md.

import 'package:masi/app/theme.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/core/grades/grade_system.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:masi/features/topo/application/draw_controller.dart';
import 'package:masi/features/topo/data/route_repository.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
import 'package:masi/features/topo/presentation/canvas_chrome.dart';
import 'package:masi/features/topo/presentation/symbol_palette_bar.dart';
import 'package:masi/features/topo/presentation/topo_canvas_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

const _viewerKey = Key('topo-interactive-viewer');

/// The canvas region `TopoCanvasBody` gives `TopoCanvas` — full-bleed canvas
/// rework: `TopoCanvas` now ALWAYS fills its `Flexible`/`LayoutBuilder`
/// region unconditionally via `Positioned.fill` (no more mode-dependent
/// `Expanded` ancestor), so the keyed `topo-interactive-viewer` itself IS
/// the canvas region.
Finder _canvasRegionFinder() => find.byKey(_viewerKey);

/// FIX #6 (family-keyed `drawControllerProvider`): stand-in wallId for the
/// tests below that construct `SymbolPaletteBar`/`TopoCanvasBody` directly
/// without a seeded real wall (the seeded-wall tests use `seeded.wallId`
/// instead, consistently).
const _testWallId = 'test-wall';

void _setViewportSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Creates a real in-memory DB + ProviderContainer + a persisted
/// Area/Sector/Wall, mirroring the harness pattern used throughout
/// canvas_mode_intent_test.dart / test/widget_test.dart.
Future<({AppDatabase db, ProviderContainer container, String wallId})>
_seedWall() async {
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
  return (db: db, container: container, wallId: wall.id);
}

void main() {
  group('A-f: symbol palette bar material (GlassChrome, not opaque)', () {
    testWidgets(
      'SymbolPaletteBar renders on a GlassChrome descendant and carries NO '
      'ColoredBox of its own (the old opaque surfaceContainerHighest fill '
      'is gone)',
      (tester) async {
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: MasiTheme.light,
              home: const Scaffold(body: SymbolPaletteBar(wallId: _testWallId)),
            ),
          ),
        );
        await tester.pump();

        expect(
          find.descendant(
            of: find.byType(SymbolPaletteBar),
            matching: find.byType(GlassChrome),
          ),
          findsOneWidget,
          reason:
              'A-f: the palette must render on the same GlassChrome '
              'material as the rest of the floating chrome',
        );
        expect(
          find.descendant(
            of: find.byType(SymbolPaletteBar),
            matching: find.byType(ColoredBox),
          ),
          findsNothing,
          reason:
              'A-f: no opaque ColoredBox(surfaceContainerHighest) backing '
              'may remain',
        );
      },
    );
  });

  group('A-f: no reserved symbol-bar slot — the canvas region reclaims the '
      'full available height', () {
    testWidgets(
      'the canvas region (topo-interactive-viewer, full-bleed) fills the '
      'ENTIRE viewport in BOTH view and draw mode — no permanent '
      '~kSymbolPaletteBarHeight band, and (full-bleed canvas rework) no '
      'top clearance either',
      (tester) async {
        const imageSize = Size(400, 300);
        const viewportSize = Size(400, 800);
        _setViewportSize(tester, viewportSize);
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
                body: Consumer(
                  builder: (context, ref, _) {
                    final drawState = ref.watch(drawControllerProvider(_testWallId));
                    return TopoCanvasBody(
                      wallId: _testWallId,
                      imagePath: '/nonexistent/test-topo.jpg',
                      imageSize: imageSize,
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

        // Full-bleed canvas rework: TopoCanvasBody no longer reserves any
        // top clearance at all (that clearance used to exist for the
        // rounded, inset viewport frame, which is gone), so the canvas
        // region must reclaim the WHOLE viewport height, edge-to-edge.
        final viewRect = tester.getRect(_canvasRegionFinder());
        expect(
          viewRect.height,
          closeTo(viewportSize.height, 0.5),
          reason:
              'A-f: in view mode, the canvas region must reclaim the FULL '
              'available height — previously a permanently-reserved, '
              'always-hidden symbol-bar slot (and, as of the full-bleed '
              'rework, a fixed top clearance) ate into this even when '
              'nothing needed it',
        );

        container.read(drawControllerProvider(_testWallId).notifier).setMode(DrawMode.draw);
        await tester.pump();

        final drawRect = tester.getRect(_canvasRegionFinder());
        expect(
          drawRect,
          viewRect,
          reason:
              'BUG-3 still holds: toggling draw mode must not move/resize '
              'the canvas region — the palette now floats as a screen '
              'overlay in TopoCanvasScreen, not an in-flow TopoCanvasBody '
              'child, so it can never affect this Column\'s height '
              'either way',
        );
      },
    );
  });

  group('A-f: the floating palette is mode-gated and never overlaps the title '
      'pill', () {
    testWidgets('absent in view mode; present in draw mode, sitting BELOW the '
        'title pill with no vertical overlap', (tester) async {
      final seeded = await _seedWall();
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);
      final crud = seeded.container.read(libraryCrudRepositoryProvider);
      await tester.runAsync(() async {
        await crud.attachPhotoToWall(
          seeded.wallId,
          XFile('/tmp/a-f-photo.jpg'),
          400,
          300,
        );
      });

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
        find.byType(SymbolPaletteBar),
        findsNothing,
        reason: 'A-f: the palette must be absent in the default view mode',
      );

      await tester.tap(find.byKey(const Key('topo-mode-toggle')));
      await tester.pump();

      expect(
        find.byType(SymbolPaletteBar),
        findsOneWidget,
        reason: 'A-f: the palette must appear once draw mode is entered',
      );

      final titlePillRect = tester.getRect(
        find
            .ancestor(
              of: find.byKey(const Key('topo-back-button')),
              matching: find.byType(GlassChrome),
            )
            .first,
      );
      final paletteRect = tester.getRect(find.byType(SymbolPaletteBar));

      expect(
        paletteRect.top,
        greaterThanOrEqualTo(titlePillRect.bottom - 0.5),
        reason:
            'A-f: the palette must float BELOW the title pill with no '
            'vertical overlap between the two floating glass elements',
      );
    });
  });

  group('A-g (Bug 8): the AR entry point is gated on a photo actually '
      'being loaded', () {
    testWidgets('in the no-photo empty state, topo-ar-button is absent', (
      tester,
    ) async {
      final seeded = await _seedWall();
      addTearDown(seeded.db.close);
      addTearDown(seeded.container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: seeded.container,
          child: MaterialApp(
            theme: MasiTheme.light,
            home: TopoCanvasScreen(wallId: seeded.wallId),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('topo-empty-state')), findsOneWidget);
      expect(
        find.byKey(const Key('topo-ar-button')),
        findsNothing,
        reason: 'A-g: AR needs a photo (and routes) to align against',
      );
    });
  });

  group('Web-port Subtask A: AR button is AR-support-gated once visible', () {
    testWidgets(
      'with a photo and a visible route in view mode, topo-ar-button is '
      'present but DISABLED (onPressed null) when isArSupported() is false '
      '(the in-VM/non-iOS case)',
      (tester) async {
        final seeded = await _seedWall();
        addTearDown(seeded.db.close);
        addTearDown(seeded.container.dispose);
        final crud = seeded.container.read(libraryCrudRepositoryProvider);

        late String photoId;
        await tester.runAsync(() async {
          photoId = await crud.attachPhotoToWall(
            seeded.wallId,
            XFile('/tmp/ar-gate-photo.jpg'),
            400,
            300,
          );
        });

        final routeRepo = RouteRepository(seeded.db, nowMs: () => 1000);
        await routeRepo.upsertRoute(
          seeded.wallId,
          photoId,
          const TopoRoute(
            id: 1,
            number: 1,
            points: [Offset(0.1, 0.1), Offset(0.2, 0.2)],
            gradeSystem: GradeSystem.french,
            gradeRaw: '6a',
          ),
        );

        await seeded.container
            .read(drawControllerProvider(seeded.wallId).notifier)
            .loadForWall(seeded.wallId, photoId);

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

        final arButtonFinder = find.byKey(const Key('topo-ar-button'));
        expect(
          arButtonFinder,
          findsOneWidget,
          reason:
              'Web-port A: the AR button must stay VISIBLE once a photo + '
              'a visible route exist, even where AR is unsupported',
        );

        final arButton = tester.widget<IconButton>(arButtonFinder);
        expect(
          arButton.onPressed,
          isNull,
          reason:
              'Web-port A: with isArSupported() false (VM tests run on '
              'macOS, not iOS), the AR button must render disabled '
              '(onPressed: null), never navigate',
        );
        expect(
          arButton.tooltip,
          'AR is available on iOS only',
          reason:
              'Web-port A: the disabled tooltip must explain the iOS-only '
              'restriction rather than repeating the enabled "View in AR" '
              'copy',
        );
      },
    );
  });
}
