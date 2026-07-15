// Subtask 1 (ClimbTopo UX fixes plan): the wall photo was rendering as a
// tiny ~110x70 thumbnail pinned to the top-left of the canvas instead of
// filling/centering the viewport, with drawn route points landing off the
// image. Root cause: TopoCanvas's fit-to-viewport matrix was computed once
// on the first frame `_hasFramed` flipped true; if that first
// `LayoutBuilder` viewport was transient/degenerate (small, before the
// AppBar/BottomAppBar settle) the tiny scale stuck permanently and was never
// recomputed once the viewport settled to its real, larger size.
//
// This file covers the fix directly:
//  - A1/A2: `TopoCanvas.computeFitScale`/`computeFitTransform` (the pure,
//    directly-testable math extracted from the former private
//    `_fitScale`/`_fitMatrix` instance methods) compute the correct
//    contain-fit scale and centering translate.
//  - A3: pumping TopoCanvas through a transient small viewport and then a
//    settled larger one re-frames to the LATER viewport's fit rather than
//    sticking on the stale small one (the actual bug fix), and a truly
//    degenerate (near-zero) viewport is never framed at all.
//  - A4: a point at percent (0.5, 0.5) maps to the viewport center under the
//    settled fit transform, and a real tap at the viewport center round-
//    trips back to ~(0.5, 0.5) — proving taps land on the image.
//
// A5 (existing `TopoCanvas.computeCropTransform` slice tests still pass) and
// A6 (`flutter analyze` 0 / `flutter test` green) are verified by running
// the existing suite in test/widget_test.dart alongside this file, not by
// duplicating assertions here.
//
// Canvas look rework (Subtask A, masi-canvas-look-rework.md): the DEFAULT
// (no-crop) open framing switched from COVER/fill (`computeFillScale` via
// `computeFitTransform`) to CONTAIN (`computeFitScale` via the new
// `computeContainTransform`) — "show the whole wall" rather than opening
// pre-cropped to fill the viewport. `computeFitTransform`/`computeFillScale`
// themselves are UNCHANGED pure functions (kept for their own sake, per that
// rework's plan), so the A1/A2 group below asserting their COVER math is
// still correct and is left as-is; what changed is which transform
// `_TopoCanvasState._fitMatrix` actually APPLIES for the default case — the
// A3/A4/elongated-image groups below (which assert the APPLIED widget
// behavior, not the pure functions in isolation) are updated accordingly,
// and a new "computeContainTransform (A-c)" group covers the new function
// directly.
//
// Default framing revision (2026-07-14, fill-width/top-aligned): the DEFAULT
// open framing changed AGAIN, this time from CONTAIN/centered to fill-WIDTH,
// top-aligned (`TopoCanvas.computeFillWidthTransform`, applied by
// `_TopoCanvasState._fitMatrix`): a portrait photo now spans the full
// viewport WIDTH with its top at the viewport's top, the remainder (if any)
// falling below, reachable by panning — rather than opening letterboxed and
// vertically centered. `computeContainTransform` is UNCHANGED and REMAINS in
// production use, just no longer as the default: it's now purely the
// "whole wall" reference `_scaleRangeFor` derives `minScale` from, so the
// user can always pinch OUT past the fill-width default to see the entire
// photo. The "computeContainTransform (A-c)" group below is retitled to
// reflect that (it no longer claims to test "the default"); a new
// "computeFillWidthTransform" group covers the new default transform
// directly; and the A3/A4/elongated-image groups (which assert APPLIED
// widget behavior) are repointed from `computeContainTransform` to
// `computeFillWidthTransform` accordingly.
//
// Vertical-centering revision (2026-07-15): `computeFillWidthTransform`
// (renamed from `computeFillWidthTopTransform`) now vertically CENTERS the
// image within any leftover slack instead of always top-anchoring it — a
// short/landscape photo's slack is split evenly above and below, rather than
// dumped entirely below the image. A TALL photo (scaled height > viewport
// height) is unaffected: the centering translate is clamped at 0, so it
// stays top-anchored with its remainder reachable by panning, exactly as
// before. The three tests in the "computeFillWidthTransform" group below,
// plus the A4 percent-mapping test, are updated to assert centering (not
// top-alignment) for the has-slack cases; the applied-scale-only assertions
// elsewhere (A3 reframe-on-resize, the elongated-image InteractiveViewer
// scale-range group) are unaffected by this since they only ever compare
// `getMaxScaleOnAxis()`, never a hardcoded translation value.
//
// Full-bleed canvas rework (2026-07-14): the viewport used to be wrapped in
// a rounded (MasiRadii.large), transparent, screen-space `DecoratedBox`
// frame (keyed 'topo-canvas-viewport-frame') and clipped to those same
// rounded corners via a `ClipRRect` — the group that used to live here
// ("TopoCanvas viewport frame (Fix 2...)") asserted that decoration/clip.
// The user asked for the image/canvas to fill the whole screen edge-to-edge
// instead, going UNDER the floating chrome and status bar, so that frame
// and its rounding are gone entirely — see the "TopoCanvas is full-bleed
// (no viewport frame/rounding)" group below, which replaces it.

import 'package:climbtopo/app/theme.dart';
import 'package:climbtopo/core/coordinates/coordinate_transformer.dart';
import 'package:climbtopo/features/topo/application/draw_controller.dart';
import 'package:climbtopo/features/topo/presentation/topo_canvas.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TopoCanvas.computeFitScale / computeFitTransform (A1/A2)', () {
    const imageSize = Size(1600, 1200);
    const viewportSize = Size(400, 800);
    const epsilon = 1e-9;

    test('A1: computeFitScale for a 1600x1200 image in a 400x800 viewport is '
        '400/1600 = 0.25 (the width axis is tighter: 400/1600=0.25 < '
        '800/1200=0.667)', () {
      final scale = TopoCanvas.computeFitScale(
        imageSize: imageSize,
        viewportSize: viewportSize,
      );
      expect(scale, closeTo(0.25, epsilon));
    });

    test('computeFillScale for a 1600x1200 image in a 400x800 viewport is '
        '800/1200 = 0.6667 (the height axis is looser and wins under COVER: '
        '400/1600=0.25 < 800/1200=0.667)', () {
      final scale = TopoCanvas.computeFillScale(
        imageSize: imageSize,
        viewportSize: viewportSize,
      );
      expect(scale, closeTo(800 / 1200, epsilon));
    });

    test('A2: computeFitTransform now COVERS the viewport via the fill '
        'scale (max of the two axis scales): scale entry ≈ 0.6667, '
        'translate dx = (400 - 1600*0.6667)/2 ≈ -333.33, '
        'dy = (800 - 1200*0.6667)/2 = 0', () {
      final matrix = TopoCanvas.computeFitTransform(
        imageSize: imageSize,
        viewportSize: viewportSize,
      );
      final fillScale = 800 / 1200;

      expect(matrix.getMaxScaleOnAxis(), closeTo(fillScale, epsilon));

      // MatrixUtils.transformPoint(matrix, Offset.zero) reads off the
      // translate directly, since scale * 0 + translate == translate.
      final origin = MatrixUtils.transformPoint(matrix, Offset.zero);
      expect(origin.dx, closeTo((400 - 1600 * fillScale) / 2, epsilon));
      expect(origin.dy, closeTo(0.0, epsilon));
    });

    test('computeFillScale/computeFitTransform agree with each other: the '
        'scaled image (1600*0.6667 x 1200*0.6667 ≈ 1066.67x800) COVERS the '
        '400x800 viewport — filling the height exactly and overflowing '
        '~333.33px horizontally on each side (cropped by the viewport\'s '
        'own bounds/ClipRRect, not by the transform itself)', () {
      final scale = TopoCanvas.computeFillScale(
        imageSize: imageSize,
        viewportSize: viewportSize,
      );
      final matrix = TopoCanvas.computeFitTransform(
        imageSize: imageSize,
        viewportSize: viewportSize,
      );

      final topLeft = MatrixUtils.transformPoint(matrix, Offset.zero);
      final bottomRight = MatrixUtils.transformPoint(
        matrix,
        Offset(imageSize.width, imageSize.height),
      );

      expect(topLeft.dy, closeTo(0.0, epsilon));
      expect(bottomRight.dy, closeTo(viewportSize.height, epsilon));
      expect(bottomRight.dy - topLeft.dy, closeTo(1200 * scale, epsilon));
      expect(topLeft.dx, closeTo((400 - 1600 * scale) / 2, epsilon));
      expect(bottomRight.dx, closeTo((400 + 1600 * scale) / 2, epsilon));

      // computeFitScale (still CONTAIN, unchanged) must remain STRICTLY
      // smaller than the fill/cover scale here — B4: minScale still lets
      // the user zoom back out to the whole (uncropped) wall.
      final containScale = TopoCanvas.computeFitScale(
        imageSize: imageSize,
        viewportSize: viewportSize,
      );
      expect(containScale, lessThan(scale));
      expect(containScale, closeTo(0.25, epsilon));
    });
  });

  group(
    'TopoCanvas.computeContainTransform (canvas look rework, A-c): the '
    'CONTAIN reference transform (whole image visible, centered) that '
    '_scaleRangeFor derives minScale from — NOT the open-framing default '
    '(see computeFillWidthTransform below for that)',
    () {
      const epsilon = 1e-9;

      test(
        'a landscape image in a portrait viewport: the WHOLE image fits '
        '(scale == min of the two axis ratios, i.e. the CONTAIN scale — '
        'matching computeFitScale), fully inside the viewport, centered',
        () {
          const imageSize = Size(1600, 1200); // landscape
          const viewportSize = Size(400, 800); // portrait

          final matrix = TopoCanvas.computeContainTransform(
            imageSize: imageSize,
            viewportSize: viewportSize,
          );
          final containScale = TopoCanvas.computeFitScale(
            imageSize: imageSize,
            viewportSize: viewportSize,
          );

          // Scale equals the CONTAIN scale (min of the two axis ratios: the
          // width axis is tighter here, 400/1600=0.25 < 800/1200=0.667), NOT
          // computeFillScale's COVER scale (0.667).
          expect(matrix.getMaxScaleOnAxis(), closeTo(containScale, epsilon));
          expect(containScale, closeTo(0.25, epsilon));

          final topLeft = MatrixUtils.transformPoint(matrix, Offset.zero);
          final bottomRight = MatrixUtils.transformPoint(
            matrix,
            Offset(imageSize.width, imageSize.height),
          );

          // The WHOLE image fits entirely inside the viewport on both axes
          // (this is the actual "contain, not cover" contract) — top-left is
          // inside/at the viewport's own bounds, bottom-right likewise, with
          // slack (letterboxing) on the axis that ISN'T the binding
          // constraint. Width is the tighter/binding axis here (0.25 <
          // 0.667), so width fills exactly and height gets the letterbox
          // slack.
          expect(topLeft.dx, greaterThanOrEqualTo(-epsilon));
          expect(topLeft.dy, greaterThanOrEqualTo(-epsilon));
          expect(bottomRight.dx, lessThanOrEqualTo(viewportSize.width + epsilon));
          expect(
            bottomRight.dy,
            lessThanOrEqualTo(viewportSize.height + epsilon),
          );

          // Fully covers the BINDING axis (width) exactly.
          expect(topLeft.dx, closeTo(0.0, epsilon));
          expect(bottomRight.dx, closeTo(viewportSize.width, epsilon));
          // Centered on the letterboxed (height) axis: equal slack top/
          // bottom.
          expect(
            topLeft.dy,
            closeTo(viewportSize.height - bottomRight.dy, epsilon),
          );
        },
      );

      test(
        'agrees with computeFitScale/computeFitTransform: STRICTLY smaller '
        'scale than the COVER/fill transform for the same elongated-vs-'
        'viewport pair, proving this is genuinely CONTAIN not COVER',
        () {
          const imageSize = Size(1600, 1200);
          const viewportSize = Size(400, 800);

          final containMatrix = TopoCanvas.computeContainTransform(
            imageSize: imageSize,
            viewportSize: viewportSize,
          );
          final coverMatrix = TopoCanvas.computeFitTransform(
            imageSize: imageSize,
            viewportSize: viewportSize,
          );

          expect(
            containMatrix.getMaxScaleOnAxis(),
            lessThan(coverMatrix.getMaxScaleOnAxis()),
            reason:
                'CONTAIN must scale down MORE than COVER for an image whose '
                'aspect ratio does not match the viewport — that is exactly '
                'what "whole photo visible, with letterbox margins" means',
          );
        },
      );

      test('a square image in a square viewport: contain == cover (no '
          'letterboxing needed either way), scale == 1, no translate', () {
        const imageSize = Size(500, 500);
        const viewportSize = Size(500, 500);

        final matrix = TopoCanvas.computeContainTransform(
          imageSize: imageSize,
          viewportSize: viewportSize,
        );

        expect(matrix.getMaxScaleOnAxis(), closeTo(1.0, epsilon));
        final origin = MatrixUtils.transformPoint(matrix, Offset.zero);
        expect(origin.dx, closeTo(0.0, epsilon));
        expect(origin.dy, closeTo(0.0, epsilon));
      });
    },
  );

  group(
    'TopoCanvas.computeFillWidthTransform: the DEFAULT open-framing '
    'transform (2026-07-15 revision) — fill-width, VERTICALLY CENTERED '
    'within any slack (not contain/centered-on-both-axes, and not '
    'top-anchored-always)',
    () {
      const epsilon = 1e-9;

      test(
        'landscape 1600x1200 in a 400x800 viewport: scale == 400/1600 == '
        '0.25 (width-bound, same magnitude as the CONTAIN scale here since '
        'width IS the tighter axis), rendered 400x300, the 500px of '
        'vertical slack is split evenly top/bottom (translation.dy == '
        '250.0), not dumped entirely below the image',
        () {
          const imageSize = Size(1600, 1200);
          const viewportSize = Size(400, 800);

          final matrix = TopoCanvas.computeFillWidthTransform(
            imageSize: imageSize,
            viewportSize: viewportSize,
          );

          expect(matrix.getMaxScaleOnAxis(), closeTo(0.25, epsilon));

          final topLeft = MatrixUtils.transformPoint(matrix, Offset.zero);
          final bottomRight = MatrixUtils.transformPoint(
            matrix,
            Offset(imageSize.width, imageSize.height),
          );

          expect(topLeft.dx, closeTo(0.0, epsilon));
          expect(topLeft.dy, closeTo(250.0, epsilon));
          expect(bottomRight.dx, closeTo(viewportSize.width, epsilon));
          expect(bottomRight.dy, closeTo(550.0, epsilon));
          expect(
            topLeft.dy,
            closeTo(viewportSize.height - bottomRight.dy, epsilon),
            reason: 'slack is split evenly above and below the image',
          );
        },
      );

      test(
        'TALL 400x1200 in a 400x800 viewport: scale == 1.0 (width-bound: '
        '400/400 == 1.0), rendered 400x1200 OVERFLOWS the 800px-tall '
        'viewport vertically (pannable), translation.dy == 0 (CLAMPED — '
        'stays top-anchored rather than centering negative, since there is '
        'no slack to split), and the CONTAIN scale (computeFitScale, '
        '800/1200 ≈ 0.6667) is STRICTLY LESS than this fill-width scale — '
        'proving the two now diverge for a portrait image',
        () {
          const imageSize = Size(400, 1200);
          const viewportSize = Size(400, 800);

          final matrix = TopoCanvas.computeFillWidthTransform(
            imageSize: imageSize,
            viewportSize: viewportSize,
          );
          final containScale = TopoCanvas.computeFitScale(
            imageSize: imageSize,
            viewportSize: viewportSize,
          );

          expect(matrix.getMaxScaleOnAxis(), closeTo(1.0, epsilon));

          final topLeft = MatrixUtils.transformPoint(matrix, Offset.zero);
          final bottomRight = MatrixUtils.transformPoint(
            matrix,
            Offset(imageSize.width, imageSize.height),
          );

          expect(topLeft.dx, closeTo(0.0, epsilon));
          expect(
            topLeft.dy,
            closeTo(0.0, epsilon),
            reason:
                'no slack to center (scaled image is taller than the '
                'viewport), so the clamp keeps this at 0 — top-anchored',
          );
          expect(bottomRight.dx, closeTo(viewportSize.width, epsilon));
          expect(
            bottomRight.dy,
            greaterThan(viewportSize.height),
            reason:
                'rendered height (1200) overflows the 800px viewport — the '
                'remainder is pannable, not shrunk to fit',
          );
          expect(bottomRight.dy, closeTo(1200.0, epsilon));

          expect(containScale, closeTo(800 / 1200, epsilon));
          expect(
            containScale,
            lessThan(matrix.getMaxScaleOnAxis()),
            reason:
                'the CONTAIN/zoom-out scale must stay strictly below the '
                'fill-width default so the user can still pinch OUT to see '
                'the whole (now-overflowing) photo',
          );
        },
      );

      test(
        '3:4 image 600x800 in a 400x800 viewport: scale == 400/600 ≈ '
        '0.6667, rendered 400x533.3, ≈266.7px of vertical slack is split '
        'evenly top/bottom (translation.dy ≈ 133.35), not dumped entirely '
        'below the image',
        () {
          const imageSize = Size(600, 800);
          const viewportSize = Size(400, 800);

          final matrix = TopoCanvas.computeFillWidthTransform(
            imageSize: imageSize,
            viewportSize: viewportSize,
          );

          expect(matrix.getMaxScaleOnAxis(), closeTo(400 / 600, epsilon));

          final topLeft = MatrixUtils.transformPoint(matrix, Offset.zero);
          final bottomRight = MatrixUtils.transformPoint(
            matrix,
            Offset(imageSize.width, imageSize.height),
          );

          expect(topLeft.dx, closeTo(0.0, epsilon));
          expect(bottomRight.dx, closeTo(viewportSize.width, epsilon));

          final renderedHeight = 800 * (400 / 600);
          final bottomSlack = viewportSize.height - renderedHeight;
          expect(bottomSlack, greaterThan(0));
          expect(bottomSlack, closeTo(266.7, 0.1));

          // CENTERED: the slack is split evenly top/bottom — topLeft.dy is
          // half the total slack, not 0 (that would be the old, now-fixed
          // top-anchored-always behavior).
          expect(topLeft.dy, closeTo(bottomSlack / 2, 0.1));
          expect(
            bottomRight.dy,
            closeTo(topLeft.dy + renderedHeight, epsilon),
          );
        },
      );
    },
  );

  group(
    'TopoCanvas.computeFillWidthTransform: vertical-centering fix '
    '(concrete SHORT/TALL cases, read via matrix.getTranslation())',
    () {
      const epsilon = 1e-9;

      test(
        'SHORT image (400x300) in a 400x900 viewport: width-bound scale == '
        '1.0, scaledHeight == 300, so translationY == (900-300)/2 == 300.0 '
        '— centered, not top-anchored',
        () {
          const imageSize = Size(400, 300);
          const viewportSize = Size(400, 900);

          final matrix = TopoCanvas.computeFillWidthTransform(
            imageSize: imageSize,
            viewportSize: viewportSize,
          );

          expect(matrix.entry(0, 0), closeTo(1.0, epsilon));
          expect(matrix.entry(1, 1), closeTo(1.0, epsilon));
          expect(matrix.entry(2, 2), closeTo(1.0, epsilon));
          expect(matrix.getMaxScaleOnAxis(), closeTo(1.0, epsilon));

          final translation = matrix.getTranslation();
          expect(translation.x, closeTo(0.0, epsilon));
          expect(translation.y, closeTo(300.0, epsilon));
        },
      );

      test(
        'TALL image (400x1200) in a 400x900 viewport: width-bound scale == '
        '1.0, scaledHeight == 1200 > 900, so translationY is CLAMPED to '
        '0.0 rather than going negative',
        () {
          const imageSize = Size(400, 1200);
          const viewportSize = Size(400, 900);

          final matrix = TopoCanvas.computeFillWidthTransform(
            imageSize: imageSize,
            viewportSize: viewportSize,
          );

          expect(matrix.entry(0, 0), closeTo(1.0, epsilon));
          expect(matrix.entry(1, 1), closeTo(1.0, epsilon));
          expect(matrix.entry(2, 2), closeTo(1.0, epsilon));
          expect(matrix.getMaxScaleOnAxis(), closeTo(1.0, epsilon));

          final translation = matrix.getTranslation();
          expect(translation.x, closeTo(0.0, epsilon));
          expect(translation.y, closeTo(0.0, epsilon));
        },
      );
    },
  );

  group('TopoCanvas reframe-on-resize (A3)', () {
    // Mirrors the identity-controller + injected-imageSize harness used
    // throughout test/widget_test.dart's 'TopoCanvas' groups: TopoCanvas is
    // pumped directly (not via the full screen) with a fixed imageSize and
    // an identity TransformationController, and imagePath points nowhere
    // real (Image.file's errorBuilder swallows the decode failure), so no
    // real image file is required.
    void setViewportSize(WidgetTester tester, Size size) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    Widget buildCanvas({
      required ProviderContainer container,
      required TransformationController controller,
      required Size imageSize,
    }) {
      return UncontrolledProviderScope(
        container: container,
        // Fix 2 (canvas UI fixes) needs `theme: MasiTheme.light`: TopoCanvas
        // now reads `MasiColors.of(context)` (for its viewport frame's
        // hairline border) on every build, which null-check-throws without
        // a MASI-themed ancestor — a bare `MaterialApp()` has no
        // `MasiColors` extension registered.
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

    testWidgets('a later, larger (settled) viewport replaces a stale small '
        'auto-frame from an earlier, transient viewport — reproducing the '
        "bug's literal symptom (a ~110x70 first LayoutBuilder pass before "
        'the AppBar/BottomAppBar settle)', (tester) async {
      const imageSize = Size(1600, 1200);
      const transientViewport = Size(110, 70);
      const settledViewport = Size(400, 800);

      setViewportSize(tester, transientViewport);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = TransformationController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        buildCanvas(
          container: container,
          controller: controller,
          imageSize: imageSize,
        ),
      );
      await tester.pump();

      // Sanity: the widget did commit to the transient viewport's (wrong,
      // tiny) fit — confirming this test actually exercises the stale-
      // auto-frame scenario rather than trivially passing. TopoCanvas frames
      // to the fill-width scale (computeFillWidthTransform) — the
      // 2026-07-14 default open-framing, "span the viewport width, top-
      // aligned" — not the CONTAIN scale (computeFitScale) or the COVER/fill
      // scale (computeFillScale). For this transient 110x70 viewport the
      // fill-width scale (110/1600 ≈ 0.06875, width-bound by definition) and
      // the CONTAIN scale (min(110/1600, 70/1200) = 70/1200 ≈ 0.0583, height-
      // bound here) genuinely diverge, so this also proves the APPLIED
      // transform is fill-width, not contain.
      final transientFitScale = TopoCanvas.computeFillWidthTransform(
        imageSize: imageSize,
        viewportSize: transientViewport,
      ).getMaxScaleOnAxis();
      expect(
        controller.value.getMaxScaleOnAxis(),
        closeTo(transientFitScale, 0.001),
        reason: 'first (transient) layout must have committed its own fit',
      );

      // The viewport settles to its real, larger size.
      setViewportSize(tester, settledViewport);
      await tester.pump();

      final settledFitScale = TopoCanvas.computeFillWidthTransform(
        imageSize: imageSize,
        viewportSize: settledViewport,
      ).getMaxScaleOnAxis();
      final expectedMatrix = TopoCanvas.computeFillWidthTransform(
        imageSize: imageSize,
        viewportSize: settledViewport,
      );
      final expectedOrigin = MatrixUtils.transformPoint(
        expectedMatrix,
        Offset.zero,
      );

      expect(
        controller.value.getMaxScaleOnAxis(),
        closeTo(settledFitScale, 0.001),
        reason:
            'must reframe to the LATER, larger viewport rather than '
            'sticking on the stale transient fit — this is the actual '
            'bug fix',
      );
      final appliedOrigin = MatrixUtils.transformPoint(
        controller.value,
        Offset.zero,
      );
      expect(appliedOrigin.dx, closeTo(expectedOrigin.dx, 0.001));
      expect(appliedOrigin.dy, closeTo(expectedOrigin.dy, 0.001));
    });

    testWidgets(
      'a genuinely degenerate (near-zero) first viewport is never framed '
      'at all — the settled viewport that follows is treated as the '
      'first real frame',
      (tester) async {
        const imageSize = Size(1600, 1200);
        const degenerateViewport = Size(2, 2);
        const settledViewport = Size(400, 800);

        setViewportSize(tester, degenerateViewport);
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final controller = TransformationController();
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          buildCanvas(
            container: container,
            controller: controller,
            imageSize: imageSize,
          ),
        );
        await tester.pump();

        expect(
          controller.value,
          Matrix4.identity(),
          reason:
              'a degenerate viewport must not be framed at all (the '
              'controller is left untouched)',
        );

        setViewportSize(tester, settledViewport);
        await tester.pump();

        // TopoCanvas frames to the fill-width scale
        // (computeFillWidthTransform) — the 2026-07-14 default
        // open-framing — not the CONTAIN scale (computeFitScale) or the
        // COVER/fill scale (computeFillScale).
        final settledFitScale = TopoCanvas.computeFillWidthTransform(
          imageSize: imageSize,
          viewportSize: settledViewport,
        ).getMaxScaleOnAxis();
        expect(
          controller.value.getMaxScaleOnAxis(),
          closeTo(settledFitScale, 0.001),
        );
      },
    );

    testWidgets(
      'a genuine user pan/zoom is NOT stomped by a subsequent resize',
      (tester) async {
        const imageSize = Size(1600, 1200);
        const firstViewport = Size(400, 800);
        const resizedViewport = Size(500, 900);

        setViewportSize(tester, firstViewport);
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final controller = TransformationController();
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          buildCanvas(
            container: container,
            controller: controller,
            imageSize: imageSize,
          ),
        );
        await tester.pump();

        // The user manually zooms/pans, diverging the controller's value
        // away from whatever TopoCanvas itself last auto-framed.
        final userMatrix = Matrix4.identity()
          ..setEntry(0, 0, 1.5)
          ..setEntry(1, 1, 1.5)
          ..setEntry(2, 2, 1.5)
          ..setEntry(0, 3, -37.0)
          ..setEntry(1, 3, -42.0);
        controller.value = userMatrix;
        await tester.pump();

        setViewportSize(tester, resizedViewport);
        await tester.pump();

        expect(
          controller.value,
          userMatrix,
          reason:
              'a resize must never overwrite a transform the user has '
              'manually adjusted since the last auto-frame',
        );
      },
    );
  });

  group('TopoCanvas taps land on the image under the settled fit (A4)', () {
    const imageSize = Size(1600, 1200);
    const viewportSize = Size(400, 800);

    test(
      'percent (0.5, 0.5) maps to BOTH the horizontal AND vertical viewport '
      'center, under the settled fill-width/vertically-centered default '
      'transform (round-trip through percentToScene + '
      'computeFillWidthTransform) — proving the framing is centered, not '
      'top-anchored, whenever there is vertical slack to split',
      () {
        final matrix = TopoCanvas.computeFillWidthTransform(
          imageSize: imageSize,
          viewportSize: viewportSize,
        );
        final scenePoint = CoordinateTransformer.percentToScene(
          const Offset(0.5, 0.5),
          imageSize,
        );
        final screenPoint = MatrixUtils.transformPoint(matrix, scenePoint);

        // Width fills the viewport exactly, so the image's horizontal
        // center still lands at the viewport's horizontal center.
        expect(screenPoint.dx, closeTo(viewportSize.width / 2, 0.001));
        // Vertically, this landscape image (scale 0.25, scaled height 300)
        // has slack (300 < 800) that is now split evenly top/bottom, so the
        // image's OWN center coincides exactly with the viewport's true
        // vertical center too — this is the direct consequence of centering
        // rather than top-anchoring the leftover slack.
        expect(screenPoint.dy, closeTo(viewportSize.height / 2, 0.001));
      },
    );

    testWidgets(
        'a real tap at the screen point where the image CENTER lands (per '
        'the applied fill-width/vertically-centered transform) round-trips '
        'to ~(0.5, 0.5), proving drawn points land on the image rather than '
        'off it', (
      tester,
    ) async {
      tester.view.physicalSize = viewportSize;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = TransformationController();
      addTearDown(controller.dispose);
      container.read(drawControllerProvider.notifier).setMode(DrawMode.draw);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          // Fix 2 (canvas UI fixes) needs `theme: MasiTheme.light` — see
          // buildCanvas above for why.
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
        ),
      );
      await tester.pump();

      // Sanity: the fit transform settled before the tap — the fill-width
      // scale (computeFillWidthTransform), the 2026-07-14 default, not
      // the CONTAIN scale (computeFitScale) or the COVER/fill scale
      // (computeFillScale).
      final fillWidthScale = TopoCanvas.computeFillWidthTransform(
        imageSize: imageSize,
        viewportSize: viewportSize,
      ).getMaxScaleOnAxis();
      expect(
        controller.value.getMaxScaleOnAxis(),
        closeTo(fillWidthScale, 0.001),
      );

      // Tap wherever the applied transform actually places the image's own
      // center, computed straight from the LIVE controller matrix (not a
      // fresh pure-function call) so this test exercises the real applied
      // transform, not just the pure math. (Under the current
      // vertically-centered framing this happens to coincide with the
      // viewport's own center — see the percent-mapping test above — but
      // deriving it from the live matrix keeps this test robust to that
      // detail either way.)
      final imageCenterScene = Offset(
        imageSize.width / 2,
        imageSize.height / 2,
      );
      final tapPoint = MatrixUtils.transformPoint(
        controller.value,
        imageCenterScene,
      );

      await tester.tapAt(tapPoint);
      await tester.pump();

      final points = container.read(drawControllerProvider).currentPoints;
      expect(points, hasLength(1));
      expect(points.first.dx, closeTo(0.5, 0.01));
      expect(points.first.dy, closeTo(0.5, 0.01));
    });
  });

  group(
    'TopoCanvas InteractiveViewer sizing (regression: tiny top-left '
    'thumbnail)',
    () {
      // Regression coverage for a second, distinct bug behind the same
      // symptom as the reframe-on-resize fix above: even with a correct
      // fit matrix/scale committed to the transformationController, the
      // wall photo still rendered as a tiny thumbnail pinned to the
      // top-left of the canvas on a real device. Root cause: the
      // InteractiveViewer here drives an OVERSIZED child (a
      // `SizedBox(width: imageSize.width, height: imageSize.height)`, e.g.
      // a 1600x1200 photo) entirely via a manual fit transform written to
      // `transformationController` — but InteractiveViewer's default
      // `constrained: true` does NOT give that child an unbounded box
      // (no `OverflowBox`); the child is laid out directly under the fit
      // `Transform`, so it receives the AMBIENT viewport constraints and
      // gets clamped down to the viewport's own (much smaller, wrong-
      // aspect-ratio) size *before* the fit matrix is applied on top —
      // compounding into a roughly `fitScale²` visual scale anchored at
      // the `Transform`'s default top-left origin.
      //
      // The earlier A1-A4 tests above don't catch this: they either check
      // the fit matrix in isolation (A1/A2, A4's first case) or pump
      // TopoCanvas with a viewport SMALLER than the "settled" size but
      // never actually inspect the rendered Image's own layout size versus
      // its true natural (imageSize) extent — so a regression back to
      // `constrained: true` would still make A3/A4 pass (the controller's
      // matrix is correct) while the on-screen result is still broken.
      testWidgets(
        'the InteractiveViewer is built with constrained: false',
        (tester) async {
          const imageSize = Size(1600, 1200);
          const viewportSize = Size(400, 800);

          tester.view.physicalSize = viewportSize;
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          final container = ProviderContainer();
          addTearDown(container.dispose);
          final controller = TransformationController();
          addTearDown(controller.dispose);

          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              // Fix 2 (canvas UI fixes) needs `theme: MasiTheme.light` —
              // see buildCanvas above for why.
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
            ),
          );
          await tester.pump();

          final viewer = tester.widget<InteractiveViewer>(
            find.byKey(const Key('topo-interactive-viewer')),
          );
          expect(
            viewer.constrained,
            isFalse,
            reason:
                'with the default constrained:true, InteractiveViewer '
                'clamps the oversized SizedBox(imageSize) child down to '
                'the ambient viewport constraints BEFORE applying the fit '
                'Transform on top, double-shrinking the image into a tiny '
                'top-left thumbnail even though the fit matrix itself is '
                'computed correctly',
          );
        },
      );

      testWidgets(
        'the rendered image lays out at its true natural imageSize, not '
        "clamped to the (smaller) viewport's size",
        (tester) async {
          const imageSize = Size(1600, 1200);
          const viewportSize = Size(400, 800);

          tester.view.physicalSize = viewportSize;
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          final container = ProviderContainer();
          addTearDown(container.dispose);
          final controller = TransformationController();
          addTearDown(controller.dispose);

          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              // Fix 2 (canvas UI fixes) needs `theme: MasiTheme.light` —
              // see buildCanvas above for why.
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
            ),
          );
          await tester.pump();

          // The child's PRE-transform layout size must be the image's true
          // natural size. With the `constrained: true` bug, this would
          // instead measure ~(400, 800) — the viewport it was wrongly
          // clamped to — rather than (1600, 1200).
          final renderedSize = tester.getSize(find.byType(Image));
          expect(renderedSize.width, closeTo(imageSize.width, 0.5));
          expect(renderedSize.height, closeTo(imageSize.height, 0.5));
        },
      );
    },
  );

  group(
    'TopoCanvas InteractiveViewer scale range for elongated images '
    '(default framing is fill-width/vertically-centered; minScale is '
    'kMinZoomOutFactor of the CONTAIN scale)',
    () {
      // Historical context (Fix 1, pre-canvas-look-rework): `_scaleRangeFor`'s
      // no-crop branch derived `maxScale` purely from the CONTAIN scale
      // (`_fitScale`/`computeFitScale`), but `_reframeIfNeeded` used to apply
      // the COVER/fill scale (`computeFillScale`, via the old
      // `_fitMatrix`/`computeFitTransform` wiring) as the initial transform.
      // For an elongated image relative to the viewport, fill could exceed
      // that contain-derived maxScale, so `_scaleRangeFor` had to widen
      // `maxScale` to cover it.
      //
      // Canvas look rework (2026-07-13) then made the default (no-crop) open
      // framing apply the CONTAIN scale itself (`computeContainTransform`),
      // making the applied initial scale trivially in-range by construction.
      //
      // 2026-07-14 revision: the default open framing changed AGAIN, to
      // fill-WIDTH/top-aligned (`computeFillWidthTransform`, via
      // `_fitMatrix`) — `minScale` was set directly to the full-image
      // CONTAIN [_fitScale], which the fill-width default scale is always
      // `>=` (fill-width is exactly the WIDTH-axis scale; contain is the
      // `min` of the two axis scales, so it can only be smaller or equal).
      // The WIDE 2000x100 case below is width-bound, so fill-width and
      // contain happen to COINCIDE numerically (both 0.2). A second, TALL
      // case is added where they genuinely diverge (mirroring the new
      // `computeFillWidthTransform` pure-fn test group), proving the
      // applied initial scale can be STRICTLY ABOVE `minScale` while still
      // being `<= maxScale`.
      //
      // Pinch-zoom-out-below-screen-width fix (2026-07-14, later same day):
      // `minScale` being EXACTLY the CONTAIN scale meant that for a typical
      // 3:4 portrait photo — where contain and fill-width COINCIDE, exactly
      // like the WIDE case's numeric coincidence below — the user was
      // floored at precisely the fill-width default with no room to pinch
      // out below screen width at all. `_scaleRangeFor` now derives
      // `minScale` as `containScale * kMinZoomOutFactor` (HALF the contain
      // scale, see the `kMinZoomOutFactor` doc), so the user can always
      // pinch out PAST "whole wall visible" to an overview-with-margins.
      // Both cases below assert `minScale == containScale *
      // kMinZoomOutFactor` and `minScale < fillWidthScale`; a third, 3:4
      // case is added below matching the bug report's exact scenario.
      void setViewportSize(WidgetTester tester, Size size) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
      }

      testWidgets(
        'WIDE: a 2000x100 image in a 400x800 viewport is width-bound, so '
        'the fill-width default scale COINCIDES with the CONTAIN scale '
        '(both 0.2, neither the COVER/fill scale), and is trivially within '
        '[minScale, maxScale]',
        (tester) async {
          const imageSize = Size(2000, 100);
          const viewportSize = Size(400, 800);
          setViewportSize(tester, viewportSize);

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
                  body: TopoCanvas(
                    imagePath: '/nonexistent/test-topo.jpg',
                    imageSize: imageSize,
                    transformationController: controller,
                  ),
                ),
              ),
            ),
          );
          await tester.pump();

          final containScale = TopoCanvas.computeFitScale(
            imageSize: imageSize,
            viewportSize: viewportSize,
          );
          final fillScale = TopoCanvas.computeFillScale(
            imageSize: imageSize,
            viewportSize: viewportSize,
          );
          // Sanity: this image/viewport pair is still a genuinely elongated
          // scenario where fill and contain diverge sharply (fill=8.0,
          // contain=0.2) — otherwise this test would trivially pass without
          // exercising anything.
          expect(fillScale, greaterThan(containScale * 10));

          final viewer = tester.widget<InteractiveViewer>(
            find.byKey(const Key('topo-interactive-viewer')),
          );

          expect(
            viewer.minScale,
            closeTo(containScale * kMinZoomOutFactor, 1e-9),
            reason:
                'minScale must be kMinZoomOutFactor of the CONTAIN scale so '
                'the user can pinch out PAST the whole wall to an '
                'overview-with-margins',
          );

          final fillWidthScale = TopoCanvas.computeFillWidthTransform(
            imageSize: imageSize,
            viewportSize: viewportSize,
          ).getMaxScaleOnAxis();
          // Width-bound image: fill-width (the default framing) and contain
          // coincide numerically here.
          expect(fillWidthScale, closeTo(containScale, 1e-9));
          expect(
            viewer.minScale,
            lessThan(fillWidthScale),
            reason:
                'the user must be able to pinch the image SMALLER than the '
                'fill-width/screen-width default, not just down to it',
          );

          final appliedScale = controller.value.getMaxScaleOnAxis();
          expect(
            appliedScale,
            closeTo(fillWidthScale, 0.001),
            reason:
                'the initial transform commits the fill-width default '
                'scale, not the COVER/fill scale — for this WIDE image it '
                'happens to equal the CONTAIN scale too',
          );
          expect(
            appliedScale,
            inInclusiveRange(viewer.minScale, viewer.maxScale),
            reason:
                'the initial fill-width scale must be in-range — no '
                'first-touch snap-jump — which holds here since minScale '
                'is strictly below the applied (fill-width) scale for this '
                'width-bound image',
          );
        },
      );

      testWidgets(
        'TALL: a 400x1200 image in a 400x800 viewport diverges: minScale '
        'is HALF the CONTAIN scale (≈0.3333) but the initial applied scale is '
        'the STRICTLY LARGER fill-width default (1.0) — still within '
        '[minScale, maxScale]',
        (tester) async {
          const imageSize = Size(400, 1200);
          const viewportSize = Size(400, 800);
          setViewportSize(tester, viewportSize);

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
                  body: TopoCanvas(
                    imagePath: '/nonexistent/test-topo.jpg',
                    imageSize: imageSize,
                    transformationController: controller,
                  ),
                ),
              ),
            ),
          );
          await tester.pump();

          final containScale = TopoCanvas.computeFitScale(
            imageSize: imageSize,
            viewportSize: viewportSize,
          );
          final fillWidthScale = TopoCanvas.computeFillWidthTransform(
            imageSize: imageSize,
            viewportSize: viewportSize,
          ).getMaxScaleOnAxis();
          // Sanity: this image/viewport pair genuinely diverges (contain
          // ≈0.6667, fill-width 1.0) — otherwise this test would trivially
          // pass without exercising the new divergent-scale path.
          expect(containScale, closeTo(800 / 1200, 1e-9));
          expect(fillWidthScale, closeTo(1.0, 1e-9));
          expect(containScale, lessThan(fillWidthScale));

          final viewer = tester.widget<InteractiveViewer>(
            find.byKey(const Key('topo-interactive-viewer')),
          );
          expect(
            viewer.minScale,
            closeTo(containScale * kMinZoomOutFactor, 1e-9),
            reason:
                'minScale must be kMinZoomOutFactor of the CONTAIN scale so '
                'the user can pinch out PAST the whole (overflowing) wall '
                'to an overview-with-margins',
          );
          expect(
            viewer.minScale,
            lessThan(fillWidthScale),
            reason:
                'the user must be able to pinch the image SMALLER than the '
                'fill-width/screen-width default, not just down to the '
                'CONTAIN scale',
          );

          final appliedScale = controller.value.getMaxScaleOnAxis();
          expect(
            appliedScale,
            closeTo(fillWidthScale, 0.001),
            reason:
                'the initial transform commits the fill-width default '
                'scale (1.0), STRICTLY greater than minScale (half-contain, '
                '≈0.3333) for this portrait image',
          );
          expect(
            appliedScale,
            inInclusiveRange(viewer.minScale, viewer.maxScale),
            reason:
                'the initial fill-width scale must still be in-range — no '
                'first-touch snap-jump',
          );
        },
      );

      testWidgets(
        '3:4 PORTRAIT (the exact on-device bug report scenario): a 1200x1600 '
        'image (3:4) in a 400x800 viewport is width-bound, so CONTAIN and '
        'fill-width COINCIDE exactly like the WIDE case above — proving '
        'minScale (half-contain) now lets the user pinch STRICTLY below '
        'the fill-width/screen-width default, where before it was floored '
        'exactly at it',
        (tester) async {
          const imageSize = Size(1200, 1600); // 3:4 portrait
          const viewportSize = Size(400, 800);
          setViewportSize(tester, viewportSize);

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
                  body: TopoCanvas(
                    imagePath: '/nonexistent/test-topo.jpg',
                    imageSize: imageSize,
                    transformationController: controller,
                  ),
                ),
              ),
            ),
          );
          await tester.pump();

          final containScale = TopoCanvas.computeFitScale(
            imageSize: imageSize,
            viewportSize: viewportSize,
          );
          final fillWidthScale = TopoCanvas.computeFillWidthTransform(
            imageSize: imageSize,
            viewportSize: viewportSize,
          ).getMaxScaleOnAxis();
          // Sanity: this is exactly the bug report's scenario — a typical
          // 3:4 photo where the contain scale equals the fill-width scale
          // (both width-bound: 400/1200 = 0.3333), so pre-fix the user was
          // floored at precisely the fill-width default with no room to
          // zoom out below screen width at all.
          expect(containScale, closeTo(400 / 1200, 1e-9));
          expect(fillWidthScale, closeTo(containScale, 1e-9));

          final viewer = tester.widget<InteractiveViewer>(
            find.byKey(const Key('topo-interactive-viewer')),
          );
          final appliedScale = controller.value.getMaxScaleOnAxis();

          expect(
            viewer.minScale,
            closeTo(containScale * kMinZoomOutFactor, 1e-9),
            reason:
                'minScale must be HALF the contain scale for this 3:4 photo',
          );
          expect(
            appliedScale,
            closeTo(fillWidthScale, 0.001),
            reason:
                'the applied/default scale is still the fill-width scale — '
                'unchanged default framing',
          );
          expect(
            viewer.minScale,
            lessThan(appliedScale),
            reason:
                'BUG FIX: the user must be able to pinch-zoom this 3:4 '
                'photo SMALLER than the applied/default fill-width (screen-'
                'width) scale, not be floored at it',
          );
          expect(
            appliedScale,
            inInclusiveRange(viewer.minScale, viewer.maxScale),
            reason: 'the applied initial scale must still be in-range',
          );
        },
      );
    },
  );

  group('TopoCanvas is full-bleed (no viewport frame/rounding)', () {
    // Full-bleed canvas rework (2026-07-14): TopoCanvas used to wrap its
    // viewport in a fixed, SCREEN-SPACE `DecoratedBox` (keyed
    // 'topo-canvas-viewport-frame') with rounded corners (MasiRadii.large),
    // and clipped its InteractiveViewer to those same rounded corners via a
    // `ClipRRect`. The user asked for the image/canvas to fill the whole
    // screen edge-to-edge instead — going UNDER the floating chrome and
    // status bar — so BOTH are gone entirely: no more 'topo-canvas-viewport-
    // frame' key/DecoratedBox anywhere in the tree, and no more `ClipRRect`
    // rounding the viewport. `topo-interactive-viewer` itself now fills
    // whatever this widget is given, unclipped, at every corner.
    void setViewportSize(WidgetTester tester, Size size) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    Widget buildCanvas({
      required ProviderContainer container,
      required TransformationController controller,
      required Size imageSize,
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

    testWidgets(
      'no topo-canvas-viewport-frame DecoratedBox and no ClipRRect exist '
      'anywhere in the tree — the viewport is unclipped and un-rounded',
      (tester) async {
        const imageSize = Size(1600, 1200);
        const viewportSize = Size(400, 800);
        setViewportSize(tester, viewportSize);

        final container = ProviderContainer();
        addTearDown(container.dispose);
        final controller = TransformationController();
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          buildCanvas(
            container: container,
            controller: controller,
            imageSize: imageSize,
          ),
        );
        await tester.pump();

        expect(
          find.byKey(const Key('topo-canvas-viewport-frame')),
          findsNothing,
          reason:
              'the rounded, screen-space letterbox frame is gone — the '
              'canvas is full-bleed edge-to-edge now',
        );
        expect(
          find.byType(ClipRRect),
          findsNothing,
          reason:
              'nothing clips the viewport to rounded corners anymore — no '
              'rounding at all',
        );
        expect(
          find.byKey(const Key('topo-canvas-edge-vignette')),
          findsNothing,
          reason:
              'the edge-fade vignette was removed 2026-07-13 (the user '
              'found it ugly) and stays removed — the photo now has clean, '
              'sharp edges',
        );
      },
    );

    testWidgets(
      'the viewport fills exactly the space TopoCanvas is given, in both '
      'light and dark theme',
      (tester) async {
        const imageSize = Size(1600, 1200);
        const viewportSize = Size(400, 800);
        setViewportSize(tester, viewportSize);

        final container = ProviderContainer();
        addTearDown(container.dispose);
        final controller = TransformationController();
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: MasiTheme.dark,
              home: Scaffold(
                body: TopoCanvas(
                  imagePath: '/nonexistent/test-topo.jpg',
                  imageSize: imageSize,
                  transformationController: controller,
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        expect(
          tester.getSize(find.byKey(const Key('topo-interactive-viewer'))),
          viewportSize,
        );
        expect(
          find.byKey(const Key('topo-canvas-edge-vignette')),
          findsNothing,
        );
      },
    );

    testWidgets(
      "the viewport's own screen-space rect stays fixed while the user "
      'pans/zooms the image inside it — zooming/panning only moves the '
      'CONTENT under InteractiveViewer, never the viewport bounds '
      'themselves',
      (tester) async {
        const imageSize = Size(1600, 1200);
        const viewportSize = Size(400, 800);
        setViewportSize(tester, viewportSize);

        final container = ProviderContainer();
        addTearDown(container.dispose);
        final controller = TransformationController();
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          buildCanvas(
            container: container,
            controller: controller,
            imageSize: imageSize,
          ),
        );
        await tester.pump();

        final viewerFinder = find.byKey(const Key('topo-interactive-viewer'));
        final rectBefore = tester.getRect(viewerFinder);

        // A manual zoom+pan well past the settled fit transform — mirrors
        // the "genuine user pan/zoom is NOT stomped by a resize" harness
        // in the reframe-on-resize group above.
        final userMatrix = Matrix4.identity()
          ..setEntry(0, 0, 2.5)
          ..setEntry(1, 1, 2.5)
          ..setEntry(2, 2, 2.5)
          ..setEntry(0, 3, -300.0)
          ..setEntry(1, 3, -450.0);
        controller.value = userMatrix;
        await tester.pump();

        final rectAfter = tester.getRect(viewerFinder);

        expect(
          rectAfter,
          rectBefore,
          reason:
              'the viewport is sized to the fixed LayoutBuilder constraints, '
              "not to the image's transformed extent — it must not grow/"
              'shrink or move as the user zooms',
        );
        expect(
          find.byKey(const Key('topo-canvas-edge-vignette')),
          findsNothing,
        );
      },
    );
  });
}
