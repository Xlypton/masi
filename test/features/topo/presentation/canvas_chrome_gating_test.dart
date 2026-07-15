// Intended-behavior tests for Subtask A (masi-canvas-look-rework.md)
// assertions A-f, A-g, and A-h — NOT derived from the pre-rework
// implementation. A failing test here is a real bug to fix in lib/, never a
// reason to weaken the assertion.
//
//  - A-f: the symbol palette renders on GlassChrome (not an opaque
//    ColoredBox(surfaceContainerHighest)); it no longer reserves a
//    permanent in-flow slot inside TopoCanvasBody (view mode reclaims that
//    height); and once floated as a screen overlay, it never overlaps the
//    title pill.
//  - A-g (Bug 8): in the no-photo empty state, topo-slice-mode-button and
//    topo-ar-button are both absent (both need a photo).
//  - A-h (Bug 9): a wall whose original photo has persisted slices shows
//    PhotoSelector once loaded, even when the slices DB read resolves LATE
//    (after several intervening rebuilds) — proving the
//    _resolveImageSize-vs-_loadSlicesForOriginal race this bug used to hit
//    can no longer wipe freshly-loaded slices.

import 'dart:async';

import 'package:climbtopo/app/theme.dart';
import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/core/db/database_provider.dart';
import 'package:climbtopo/features/library/application/library_providers.dart';
import 'package:climbtopo/features/topo/application/draw_controller.dart';
import 'package:climbtopo/features/topo/data/photo_repository.dart';
import 'package:climbtopo/features/topo/domain/slice_geometry.dart';
import 'package:climbtopo/features/topo/presentation/canvas_chrome.dart';
import 'package:climbtopo/features/topo/presentation/photo_selector.dart';
import 'package:climbtopo/features/topo/presentation/symbol_palette_bar.dart';
import 'package:climbtopo/features/topo/presentation/topo_canvas_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _viewerKey = Key('topo-interactive-viewer');

/// The canvas region `TopoCanvasBody` gives `TopoCanvas` — full-bleed canvas
/// rework: `TopoCanvas` now ALWAYS fills its `Flexible`/`LayoutBuilder`
/// region unconditionally via `Positioned.fill` (no more mode-dependent
/// `Expanded` ancestor), so the keyed `topo-interactive-viewer` itself IS
/// the canvas region.
Finder _canvasRegionFinder() => find.byKey(_viewerKey);

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

/// Creates a real in-memory DB + ProviderContainer (with [photoRepositoryProvider]
/// overridden to [gate] its `loadSlices` reads) + a persisted Area/Sector/Wall
/// — the A-h harness. Kept as its own function (rather than a parameter on
/// [_seedWall]) purely to avoid spelling out riverpod's internal `Override`
/// type, which isn't part of this project's `flutter_riverpod` public API
/// surface.
Future<({AppDatabase db, ProviderContainer container, String wallId})>
_seedWallWithGatedSlices(Future<void> Function() gate) async {
  final db = AppDatabase(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      nowMsProvider.overrideWithValue(() => 1000),
      photoRepositoryProvider.overrideWith(
        (ref) => _GatedSlicesRepository(
          ref.watch(appDatabaseProvider),
          nowMs: ref.watch(nowMsProvider),
          gate: gate,
        ),
      ),
    ],
  );
  final crud = container.read(libraryCrudRepositoryProvider);
  final area = await crud.createArea('Area');
  final sector = await crud.createSector(area.id, 'Sector');
  final wall = await crud.createWall(sector.id, 'Wall');
  return (db: db, container: container, wallId: wall.id);
}

/// A [PhotoRepository] whose [loadSlices] awaits [gate] before delegating
/// to the real implementation — lets a test hold the slice-load
/// deliberately open across several rebuild cycles, so it can simulate the
/// slices DB read resolving LATE (Bug 9's actual race window) without ever
/// needing a real, timing-dependent image decode.
class _GatedSlicesRepository extends PhotoRepository {
  _GatedSlicesRepository(super.db, {required super.nowMs, required this.gate});

  final Future<void> Function() gate;

  @override
  Future<List<PhotoRef>> loadSlices(String originalPhotoId) async {
    await gate();
    return super.loadSlices(originalPhotoId);
  }
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
              home: const Scaffold(body: SymbolPaletteBar()),
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

  group(
    'A-f: no reserved symbol-bar slot — the canvas region reclaims the '
    'full available height',
    () {
      testWidgets(
        'the canvas region (topo-interactive-viewer, full-bleed) fills the '
        'ENTIRE viewport with no slices attached, in BOTH view and draw '
        'mode — no permanent ~kSymbolPaletteBarHeight band, and (full-bleed '
        'canvas rework) no top clearance either',
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
                      final drawState = ref.watch(drawControllerProvider);
                      return TopoCanvasBody(
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
          // rounded, inset viewport frame, which is gone) — with no slices
          // attached (no PhotoSelector slot either), the canvas region must
          // reclaim the WHOLE viewport height, edge-to-edge.
          final viewRect = tester.getRect(_canvasRegionFinder());
          expect(
            viewRect.height,
            closeTo(viewportSize.height, 0.5),
            reason:
                'A-f: with no slices and in view mode, the canvas region '
                'must reclaim the FULL available height — previously a '
                'permanently-reserved, always-hidden symbol-bar slot (and, '
                'as of the full-bleed rework, a fixed top clearance) ate '
                'into this even when nothing needed it',
          );

          container.read(drawControllerProvider.notifier).setMode(
            DrawMode.draw,
          );
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
    },
  );

  group(
    'A-f: the floating palette is mode-gated and never overlaps the title '
    'pill',
    () {
      testWidgets(
        'absent in view mode; present in draw mode, sitting BELOW the '
        'title pill with no vertical overlap',
        (tester) async {
          final seeded = await _seedWall();
          addTearDown(seeded.db.close);
          addTearDown(seeded.container.dispose);
          final crud = seeded.container.read(libraryCrudRepositoryProvider);
          await tester.runAsync(() async {
            await crud.attachPhotoToWall(
              seeded.wallId,
              '/tmp/a-f-photo.jpg',
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
        },
      );
    },
  );

  group(
    'A-g (Bug 8): slice/AR entry points are gated on a photo actually '
    'being loaded',
    () {
      testWidgets(
        'in the no-photo empty state, topo-slice-mode-button and '
        'topo-ar-button are both absent',
        (tester) async {
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
            find.byKey(const Key('topo-slice-mode-button')),
            findsNothing,
            reason: 'A-g: the slice tool needs a photo to slice',
          );
          expect(
            find.byKey(const Key('topo-ar-button')),
            findsNothing,
            reason: 'A-g: AR needs a photo (and routes) to align against',
          );
        },
      );
    },
  );

  group(
    'A-h (Bug 9 regression): persisted slices survive a LATE-resolving '
    'slices DB read',
    () {
      testWidgets(
        'PhotoSelector appears once the (deliberately delayed) slices load '
        'resolves, even after several intervening rebuilds while it was '
        'still pending — the reset can no longer race/wipe it',
        (tester) async {
          final gate = Completer<void>();
          final seeded = await _seedWallWithGatedSlices(() => gate.future);
          addTearDown(seeded.db.close);
          addTearDown(seeded.container.dispose);

          final crud = seeded.container.read(libraryCrudRepositoryProvider);
          const path = '/tmp/a-h-photo.jpg';
          late String photoId;
          await tester.runAsync(() async {
            photoId = await crud.attachPhotoToWall(
              seeded.wallId,
              path,
              400,
              300,
            );
            // Persist real slices directly through the (gated) repository's
            // inherited replaceSlices — only loadSlices is delayed, so this
            // write itself is immediate.
            await seeded.container
                .read(photoRepositoryProvider)
                .replaceSlices(seeded.wallId, photoId, 400, 300, path, const [
                  SliceSpec(0.0, 0.5),
                  SliceSpec(0.5, 0.5),
                ]);
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

          // Several rebuild cycles while the slices load is deliberately
          // STUCK (the gate is not yet completed) — simulating the exact
          // race window Bug 9's fix must survive.
          for (var i = 0; i < 5; i++) {
            await tester.pump();
          }
          expect(
            find.byKey(const Key('photo-selector')),
            findsNothing,
            reason:
                'the slices load has not resolved yet, so nothing should '
                'show — this is NOT the bug being tested for, just a sanity '
                'check that the gate is genuinely blocking',
          );

          gate.complete();
          await tester.pumpAndSettle();

          expect(
            seeded.container.read(drawControllerProvider).activePhotoId,
            photoId,
          );
          expect(
            find.byKey(const Key('photo-selector')),
            findsOneWidget,
            reason:
                'A-h/Bug 9: persisted slices must survive the late-resolving '
                'load and PhotoSelector must appear — the old '
                '_resolveImageSize reset (now removed from that method, see '
                'its doc) used to be able to wipe _slices back to empty if '
                'it fired after this load, regardless of how late that load '
                'resolved',
          );
        },
      );
    },
  );

  group(
    'A-i (bug fix): a wall WITH slices is still full-bleed — PhotoSelector '
    'floats over the photo instead of reserving in-flow clearance',
    () {
      /// Mirrors `_seedWallWithGatedSlices` above, minus the deliberate
      /// gate: attaches a photo and persists two real slices for it via
      /// `PhotoRepository.replaceSlices`, so `PhotoSelector` renders once
      /// `TopoCanvasScreen` loads this wall.
      Future<({AppDatabase db, ProviderContainer container, String wallId})>
      seedWallWithSlices(WidgetTester tester) async {
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

        const path = '/tmp/a-i-slices-photo.jpg';
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

      /// The rendered rect of the back-button ROW itself (not the shared
      /// GlassChrome card around it) — used below to assert PhotoSelector/
      /// SymbolPaletteBar float strictly below the title row. Post-merge,
      /// the title row and PhotoSelector now share a SINGLE GlassChrome
      /// card (see topo_canvas_screen.dart's merged top-chrome build), so
      /// asserting against that shared card's own bottom edge would be
      /// circular (PhotoSelector is INSIDE it); the back-button row's
      /// bottom is the honest boundary between the two.
      Rect backButtonRowRect(WidgetTester tester) =>
          tester.getRect(find.byKey(const Key('topo-back-button')));

      testWidgets(
        'the canvas region fills the FULL viewport (top at y=0) exactly '
        'like a no-slices wall, and PhotoSelector floats in the top band '
        'without overlapping the title pill',
        (tester) async {
          const viewportSize = Size(400, 800);
          _setViewportSize(tester, viewportSize);
          final seeded = await seedWallWithSlices(tester);
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

          final canvasRect = tester.getRect(_canvasRegionFinder());
          expect(
            canvasRect.top,
            closeTo(0, 0.5),
            reason:
                'BUG FIX: a wall WITH slices must still reach the very top '
                'of the screen — no in-flow PhotoSelector bar may push it '
                'down anymore',
          );
          expect(
            canvasRect.height,
            closeTo(viewportSize.height, 0.5),
            reason:
                'BUG FIX: the canvas region must fill the FULL viewport '
                'height even when the wall has slices, exactly like a '
                'no-slices wall (see the "A-f: no reserved symbol-bar slot" '
                'group above)',
          );

          expect(
            find.byType(PhotoSelector),
            findsOneWidget,
            reason: 'sanity: persisted slices must show PhotoSelector',
          );
          final photoRect = tester.getRect(find.byType(PhotoSelector));
          expect(
            photoRect.top,
            greaterThanOrEqualTo(backButtonRowRect(tester).bottom - 0.5),
            reason:
                'post-merge, PhotoSelector shares a single GlassChrome card '
                'with the title row, but must still render BELOW the '
                'back-button row within that card, never overlapping it',
          );
        },
      );

      testWidgets(
        'the "blue sliver" fix: PhotoSelector and the back button share the '
        'SAME single GlassChrome ancestor (title row + slice-picker are '
        'merged into one card, so there is no transparent gap between them '
        'exposing the full-bleed photo behind)',
        (tester) async {
          _setViewportSize(tester, const Size(400, 800));
          final seeded = await seedWallWithSlices(tester);
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

          expect(find.byType(PhotoSelector), findsOneWidget);

          final photoSelectorGlassChrome = find
              .ancestor(
                of: find.byKey(const Key('photo-selector')),
                matching: find.byType(GlassChrome),
              )
              .evaluate()
              .first
              .widget;
          final backButtonGlassChrome = find
              .ancestor(
                of: find.byKey(const Key('topo-back-button')),
                matching: find.byType(GlassChrome),
              )
              .evaluate()
              .first
              .widget;

          expect(
            photoSelectorGlassChrome,
            same(backButtonGlassChrome),
            reason:
                'PhotoSelector and the back button must be descendants of '
                'the exact same GlassChrome instance — the merge fix for '
                'the stray blue sliver — not two separate GlassChrome '
                'pills stacked with a transparent gap between them',
          );
        },
      );

      testWidgets(
        'in DRAW mode, PhotoSelector and SymbolPaletteBar both float in the '
        'top band without overlapping each other or the title pill',
        (tester) async {
          _setViewportSize(tester, const Size(400, 800));
          final seeded = await seedWallWithSlices(tester);
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

          await tester.tap(find.byKey(const Key('topo-mode-toggle')));
          await tester.pumpAndSettle();

          expect(find.byType(PhotoSelector), findsOneWidget);
          expect(find.byType(SymbolPaletteBar), findsOneWidget);

          final photoRect = tester.getRect(find.byType(PhotoSelector));
          final paletteRect = tester.getRect(find.byType(SymbolPaletteBar));
          expect(
            photoRect.top,
            greaterThanOrEqualTo(backButtonRowRect(tester).bottom - 0.5),
            reason:
                'post-merge, PhotoSelector shares a single GlassChrome card '
                'with the title row, but must still render BELOW the '
                'back-button row within that card, never overlapping it',
          );
          expect(
            paletteRect.top,
            greaterThanOrEqualTo(photoRect.bottom - 0.5),
            reason:
                'SymbolPaletteBar must render BELOW PhotoSelector with no '
                'vertical overlap between the two floating glass elements',
          );
        },
      );

      testWidgets(
        'a wall WITHOUT slices is unchanged: still full-bleed, and '
        'PhotoSelector is absent',
        (tester) async {
          const viewportSize = Size(400, 800);
          _setViewportSize(tester, viewportSize);
          final seeded = await _seedWall();
          addTearDown(seeded.db.close);
          addTearDown(seeded.container.dispose);
          final crud = seeded.container.read(libraryCrudRepositoryProvider);
          await tester.runAsync(() async {
            await crud.attachPhotoToWall(
              seeded.wallId,
              '/tmp/a-i-no-slices-photo.jpg',
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
            find.byType(PhotoSelector),
            findsNothing,
            reason: 'a wall with no slices must never show PhotoSelector',
          );
          final canvasRect = tester.getRect(_canvasRegionFinder());
          expect(canvasRect.top, closeTo(0, 0.5));
          expect(canvasRect.height, closeTo(viewportSize.height, 0.5));
        },
      );
    },
  );
}
