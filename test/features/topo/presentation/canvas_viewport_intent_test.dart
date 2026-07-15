// Intended-behavior tests for Subtask A3 of
// /Users/kerip/.claude/plans/masi-intended-behavior-ui-tests.md — the topo
// canvas's photo-viewport (BUG-4) and its centering/layout STABILITY
// (BUG-3). These assertions are derived from the SPEC (the "Behavior
// contract" in that plan, and DESIGN.md's "Chrome floats, content is king" /
// "Form — depth"), NOT from reading topo_canvas.dart's current
// implementation — a failing assertion here is a real bug to fix in lib/,
// never a reason to weaken the assertion.
//
// Full-bleed canvas rework (2026-07-14): the "floating photo-viewport
// frame" BUG-4 originally fixed (a rounded, screen-space `DecoratedBox`
// wrapping the viewport) is gone entirely — the user asked for the image/
// canvas to fill the whole screen edge-to-edge instead, under the floating
// chrome and status bar (see topo_canvas_fit_test.dart's "TopoCanvas is
// full-bleed" group for the dedicated coverage). A3a/A3b below are updated
// to assert THAT intent (no frame, no rounding) rather than the old rounded
// panel's decoration.
//
// A3a/A3b drive bare `TopoCanvas` directly (mirroring the `buildCanvas`
// harness in test/widget_test.dart's top-level 'TopoCanvas' group, ~L314-347)
// since the viewport is owned by that widget. A3c/A3d drive
// `TopoCanvasBody` (mirroring the two `buildBody` harnesses in
// test/widget_test.dart, ~L834-862 and ~L935-964) since the centering-
// stability contract is about the layout `TopoCanvasBody` owns around
// `TopoCanvas` — that canvas region is now ALWAYS the same
// `topo-interactive-viewer` rect (no more Column<->Stack/Expanded
// restructuring across any mode toggle), so `_canvasRegionFinder` below
// locates the viewer directly rather than hunting for an `Expanded`
// ancestor that no longer exists.

import 'package:climbtopo/app/theme.dart';
import 'package:climbtopo/features/topo/application/draw_controller.dart';
import 'package:climbtopo/features/topo/data/photo_repository.dart';
import 'package:climbtopo/features/topo/presentation/topo_canvas.dart';
import 'package:climbtopo/features/topo/presentation/topo_canvas_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _frameKey = Key('topo-canvas-viewport-frame');
const _viewerKey = Key('topo-interactive-viewer');

void _setViewportSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Mirrors `buildCanvas` in test/widget_test.dart's top-level 'TopoCanvas'
/// group (~L314-337): pumps bare `TopoCanvas` with an injected `imageSize`
/// and an identity `TransformationController`, no real decodable image file
/// needed (imagePath points nowhere real; `Image.file`'s errorBuilder
/// swallows the decode failure).
Widget _buildCanvas({
  required ProviderContainer container,
  required TransformationController controller,
  Size imageSize = const Size(400, 300),
}) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: MasiTheme.light,
      home: Scaffold(
        body: TopoCanvas(
          imagePath: '/nonexistent/test-topo.jpg',
          imageSize: imageSize,
          transformationController: controller,
        ),
      ),
    ),
  );
}

/// Mirrors the `buildBody` harness in test/widget_test.dart's 'TopoCanvasBody:
/// symbol bar mode visibility (Fix 2)' group (~L834-862): pumps
/// `TopoCanvasBody` with a live-watched `drawState`, an injected `imageSize`,
/// and an identity `TransformationController`.
Widget _buildBody({
  required ProviderContainer container,
  required TransformationController controller,
  Size imageSize = const Size(400, 300),
  bool sliceMode = false,
  String? originalPhotoId,
  List<PhotoRef> slices = const [],
}) {
  return UncontrolledProviderScope(
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
              sliceMode: sliceMode,
              originalPhotoId: originalPhotoId,
              slices: slices,
            );
          },
        ),
      ),
    ),
  );
}

/// The canvas region `TopoCanvasBody` gives `TopoCanvas` — full-bleed canvas
/// rework: `TopoCanvas` now ALWAYS fills its `Flexible`/`LayoutBuilder`
/// region unconditionally via `Positioned.fill` (no more `Expanded` ancestor
/// that only exists in a non-zoomed branch), so the keyed
/// `topo-interactive-viewer` itself IS the canvas region — `InteractiveViewer`
/// sizes to its own incoming (ambient) constraints regardless of its
/// `constrained: false` child, so this rect reflects the real reserved
/// region, not the (potentially oversized) image content inside it.
Finder _canvasRegionFinder() => find.byKey(_viewerKey);

void main() {
  group(
    'A3a: viewport is full-bleed — no floating frame/rounding of any kind '
    '(BUG-4a superseded by the 2026-07-14 full-bleed rework), and no '
    'edge-fade vignette either (removed 2026-07-13 — the user found it '
    'ugly)',
    () {
      testWidgets(
        'no topo-canvas-viewport-frame DecoratedBox, no ClipRRect rounding '
        'the viewport, and no edge-fade vignette exist ANYWHERE in the '
        'tree — the photo fills the screen edge-to-edge with clean, sharp '
        'edges',
        (tester) async {
          _setViewportSize(tester, const Size(400, 800));
          final container = ProviderContainer();
          addTearDown(container.dispose);
          final controller = TransformationController();
          addTearDown(controller.dispose);

          await tester.pumpWidget(
            _buildCanvas(container: container, controller: controller),
          );
          await tester.pump();

          // BUG-4 superseded: the rounded, screen-space letterbox frame the
          // user originally asked for is gone — full-bleed edge-to-edge is
          // the new intent, so no such frame (and nothing rounding the
          // viewport) should exist at all.
          expect(
            find.byKey(_frameKey),
            findsNothing,
            reason:
                'the floating photo panel is gone — the canvas is '
                'full-bleed now, not an inset rounded panel',
          );
          expect(
            find.byType(ClipRRect),
            findsNothing,
            reason:
                'nothing clips the viewport to rounded corners anymore — '
                'the canvas fills the screen with sharp, hard edges',
          );

          // Edge-feather reversal (2026-07-13): the soft IgnorePointer
          // vignette that used to fade the photo's edges to
          // MasiColors.ground is gone entirely — not merely relocated. No
          // element keyed 'topo-canvas-edge-vignette' exists anywhere in
          // the tree.
          expect(
            find.byKey(const Key('topo-canvas-edge-vignette')),
            findsNothing,
            reason:
                'the edge-fade vignette was removed 2026-07-13 (the user '
                'found it ugly) — the photo now has clean, sharp edges',
          );
        },
      );
    },
  );

  group(
    'A3b: viewport lives in SCREEN space — invariant under pan/zoom of the '
    'image inside it (BUG-4d)',
    () {
      // Full-bleed rework disposition: KEPT, not dropped, even though the
      // dedicated screen-space `DecoratedBox` frame this test used to
      // measure is gone. This test's point was always "the fixed viewport
      // around the photo does not move when the photo does" — that is now
      // asserted directly against `topo-interactive-viewer` itself (see
      // `_canvasRegionFinder`'s doc for why that key IS the canvas region
      // now), which sizes to its own incoming constraints regardless of the
      // (potentially oversized, `constrained: false`) image content
      // transformed inside it.
      testWidgets(
        'the viewport rect is unchanged after the image transform is '
        'zoomed and panned',
        (tester) async {
          _setViewportSize(tester, const Size(400, 800));
          final container = ProviderContainer();
          addTearDown(container.dispose);
          final controller = TransformationController();
          addTearDown(controller.dispose);

          await tester.pumpWidget(
            _buildCanvas(container: container, controller: controller),
          );
          await tester.pump();

          final rectBefore = tester.getRect(find.byKey(_viewerKey));

          // Mirrors the setEntry-based zoom+pan construction used elsewhere
          // in this suite (e.g. topo_canvas_fit_test.dart's "genuine user
          // pan/zoom is NOT stomped by a resize" case) rather than the
          // deprecated Matrix4.scale/translate instance methods.
          controller.value = Matrix4.identity()
            ..setEntry(0, 0, 2.0)
            ..setEntry(1, 1, 2.0)
            ..setEntry(2, 2, 2.0)
            ..setEntry(0, 3, -50.0)
            ..setEntry(1, 3, 35.0);
          await tester.pump();

          final rectAfter = tester.getRect(find.byKey(_viewerKey));

          expect(
            rectAfter,
            rectBefore,
            reason:
                'BUG-4d: the viewport is a fixed SCREEN-space region — '
                'zooming/panning the photo inside InteractiveViewer must '
                'never move, grow, or shrink the viewport itself',
          );
        },
      );
    },
  );

  group(
    'A3c: canvas region does not jump/resize when the symbol bar appears/'
    'disappears (BUG-3)',
    () {
      testWidgets(
        'the canvas region (Expanded ancestor of topo-interactive-viewer) '
        'keeps the same rect switching view mode -> draw mode',
        (tester) async {
          _setViewportSize(tester, const Size(400, 800));
          final container = ProviderContainer();
          addTearDown(container.dispose);
          final controller = TransformationController();
          addTearDown(controller.dispose);
          final notifier = container.read(drawControllerProvider.notifier);

          await tester.pumpWidget(
            _buildBody(container: container, controller: controller),
          );
          await tester.pump();

          expect(container.read(drawControllerProvider).mode, DrawMode.view);
          final rectBefore = tester.getRect(_canvasRegionFinder());

          notifier.setMode(DrawMode.draw);
          await tester.pump();

          final rectAfter = tester.getRect(_canvasRegionFinder());

          expect(
            rectAfter,
            rectBefore,
            reason:
                'BUG-3: the symbol-bar slot must be reserved unconditionally '
                "so toggling draw mode's Visibility never resizes/moves the "
                'canvas region beneath it (which would re-center/re-scale '
                'the photo on every mode toggle)',
          );
        },
      );
    },
  );

  group(
    'A3d: canvas region does not jump/resize when the slice-mode photo '
    'selector appears/disappears (BUG-3)',
    () {
      const slices = [
        PhotoRef(
          id: 'slice-1',
          wallId: 'wall-1',
          kind: 'slice',
          localPath: '/nonexistent/slice-1.jpg',
          width: 200,
          height: 300,
          parentPhotoId: 'original-1',
          cropXpct: 0.0,
          cropWidthPct: 0.5,
        ),
      ];

      testWidgets(
        'the canvas region keeps the same rect toggling sliceMode true <-> '
        'false with slices non-empty',
        (tester) async {
          _setViewportSize(tester, const Size(400, 800));
          final container = ProviderContainer();
          addTearDown(container.dispose);
          final controller = TransformationController();
          addTearDown(controller.dispose);

          await tester.pumpWidget(
            _buildBody(
              container: container,
              controller: controller,
              sliceMode: false,
              originalPhotoId: 'original-1',
              slices: slices,
            ),
          );
          await tester.pump();

          final rectBefore = tester.getRect(_canvasRegionFinder());

          await tester.pumpWidget(
            _buildBody(
              container: container,
              controller: controller,
              sliceMode: true,
              originalPhotoId: 'original-1',
              slices: slices,
            ),
          );
          await tester.pump();

          final rectDuringSlice = tester.getRect(_canvasRegionFinder());
          expect(
            rectDuringSlice,
            rectBefore,
            reason:
                'BUG-3: entering slice mode (hiding the PhotoSelector via '
                'Visibility) must not resize/move the canvas region',
          );

          await tester.pumpWidget(
            _buildBody(
              container: container,
              controller: controller,
              sliceMode: false,
              originalPhotoId: 'original-1',
              slices: slices,
            ),
          );
          await tester.pump();

          final rectAfter = tester.getRect(_canvasRegionFinder());
          expect(
            rectAfter,
            rectBefore,
            reason:
                'BUG-3: leaving slice mode (showing the PhotoSelector again) '
                'must not resize/move the canvas region either — the slot is '
                'reserved unconditionally, only its visibility toggles',
          );
        },
      );
    },
  );
}
