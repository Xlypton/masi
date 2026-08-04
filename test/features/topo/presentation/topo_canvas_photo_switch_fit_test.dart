// Regression coverage for the reported bug: "images when a topo is loaded
// sometimes open zoomed in to the top left corner of the image and not
// properly fitted and centered as it normally does and should."
//
// Root cause (two distinct holes in `_TopoCanvasState._reframeIfNeeded`,
// both covered here):
//
//  1. CONTENT IDENTITY WAS THE IMAGE *SIZE*, NOT THE IMAGE.
//     `TopoCanvasScreen` hands ONE long-lived `_TopoCanvasState` (pinned by
//     its `_canvasKey` GlobalKey) and ONE long-lived
//     `TransformationController` every photo it ever shows, and — on every
//     photo switch — synchronously resets that controller to
//     `Matrix4.identity()` (see `TopoCanvasScreen.build`'s
//     `selectedImageProvider` listener, added so the pre-seeded-controller
//     escape hatch can't latch the previous photo's matrix).
//     `_reframeIfNeeded` decided "is this new content?" purely by comparing
//     `widget.imageSize` — so switching to a DIFFERENT photo that happens to
//     have the SAME pixel dimensions (two shots from the same camera in the
//     same orientation; two equal slices of one photo; a wall whose photos
//     were all imported at one resolution) took the "truly unchanged: never
//     stomp a manual pan/zoom" early return. No reframe ever ran, so the
//     controller stayed at the identity the screen had just written — and
//     with `constrained: false` plus the natural-size (oversized) child,
//     identity paints the photo's TOP-LEFT CORNER AT 1:1, permanently. That
//     is the reported symptom exactly, and "sometimes" is just "when the two
//     photos' dimensions happen to match".
//
//  2. A DEGENERATE `imageSize` WAS STILL FRAMED.
//     The viewport had a degenerate-size guard
//     (`_minFrameableViewportDimensionPx`); `imageSize` had none. A zero/
//     non-positive image size falls through `computeFillWidthTransform`'s
//     `imageSize.width > 0 ? ... : 1.0` fallback to scale 1.0 — i.e. it
//     COMMITS a scale-1 transform, the same top-left-at-1:1 framing, and
//     reveals the photo through it. The canvas must instead paint nothing
//     until it has a size it can actually fit against.
//
// Both are asserted through the applied `TransformationController` value and
// through the photo layer's own `Opacity` gate (bug #78's `_autoFrameApplied`),
// never by driving a real image decode — `imagePath` points nowhere real, so
// no codec ever runs (which would hang under fake_async).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/app/theme.dart';
import 'package:masi/features/topo/presentation/topo_canvas.dart';

/// Stand-in wallId for the family-keyed `drawControllerProvider`, paired
/// consistently with every `TopoCanvas(wallId: ...)` pumped in this file.
const _testWallId = 'test-wall';

void main() {
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
    required String imagePath,
  }) {
    return UncontrolledProviderScope(
      container: container,
      // `theme: MasiTheme.light` is required: TopoCanvas reads
      // `MasiColors.of(context)` on every build, which null-check-throws
      // without a MASI-themed ancestor.
      child: MaterialApp(
        theme: MasiTheme.light,
        home: Scaffold(
          body: TopoCanvas(
            wallId: _testWallId,
            imagePath: imagePath,
            imageSize: imageSize,
            transformationController: controller,
          ),
        ),
      ),
    );
  }

  /// The opacity of the photo/overlay layer — bug #78's `_autoFrameApplied`
  /// gate, which must be 0 for any frame whose transform is not yet a real
  /// fit for the current content.
  double photoLayerOpacity(WidgetTester tester) {
    final opacity = tester.widget<Opacity>(
      find.ancestor(
        of: find.byKey(const Key('topo-interactive-viewer')),
        matching: find.byType(Opacity),
      ).first,
    );
    return opacity.opacity;
  }

  group(
    'TopoCanvas reframes on a PHOTO switch, not merely on an imageSize '
    'change (top-left-at-1:1 bug)',
    () {
      testWidgets(
        'switching to a different photo with the SAME pixel dimensions — '
        "after the owning screen reset the shared controller to identity — "
        're-fits to the new photo instead of leaving it at identity (i.e. '
        "the photo's top-left corner at 1:1)",
        (tester) async {
          const viewportSize = Size(400, 800);
          // A tall 3:4 photo: the fill-width fit scale is 400/1200 == 1/3,
          // unmistakably different from identity's 1.0.
          const imageSize = Size(1200, 1600);
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
              imagePath: '/nonexistent/photo-a.jpg',
            ),
          );
          await tester.pump();

          final expectedFit = TopoCanvas.computeFillWidthTransform(
            imageSize: imageSize,
            viewportSize: viewportSize,
          );
          expect(
            controller.value.getMaxScaleOnAxis(),
            closeTo(expectedFit.getMaxScaleOnAxis(), 0.001),
            reason: 'sanity: photo A was framed on open',
          );
          expect(
            expectedFit.getMaxScaleOnAxis(),
            isNot(closeTo(1.0, 0.05)),
            reason:
                'sanity: the correct fit scale is clearly not 1.0, so a '
                'left-at-identity transform is unambiguously detectable',
          );

          // Exactly what TopoCanvasScreen does on a photo switch (its
          // `selectedImageProvider` listener), synchronously, before the
          // rebuild that hands this same widget position the new photo.
          controller.value = Matrix4.identity();

          // The SAME widget position / State / controller, a DIFFERENT
          // photo — with identical pixel dimensions.
          await tester.pumpWidget(
            buildCanvas(
              container: container,
              controller: controller,
              imageSize: imageSize,
              imagePath: '/nonexistent/photo-b.jpg',
            ),
          );
          await tester.pump();

          expect(
            controller.value,
            isNot(Matrix4.identity()),
            reason:
                'the new photo must never be left at the identity transform: '
                'with constrained:false and a natural-size child, identity '
                "paints the photo's top-left corner at 1:1 — the reported "
                'bug',
          );
          expect(
            controller.value.getMaxScaleOnAxis(),
            closeTo(expectedFit.getMaxScaleOnAxis(), 0.001),
            reason: 'photo B must be re-fitted for the current viewport',
          );
          final appliedOrigin = MatrixUtils.transformPoint(
            controller.value,
            Offset.zero,
          );
          final expectedOrigin = MatrixUtils.transformPoint(
            expectedFit,
            Offset.zero,
          );
          expect(appliedOrigin.dx, closeTo(expectedOrigin.dx, 0.001));
          expect(appliedOrigin.dy, closeTo(expectedOrigin.dy, 0.001));
        },
      );

      testWidgets(
        'a photo switch to the same dimensions also drops the previous '
        "photo's manual pan/zoom (a switch is new content, not a resize)",
        (tester) async {
          const viewportSize = Size(400, 800);
          const imageSize = Size(1200, 1600);
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
              imagePath: '/nonexistent/photo-a.jpg',
            ),
          );
          await tester.pump();

          // The user zooms deep into photo A's top-left.
          final zoomedIntoTopLeft = Matrix4.identity()
            ..setEntry(0, 0, 3.0)
            ..setEntry(1, 1, 3.0)
            ..setEntry(2, 2, 3.0);
          controller.value = zoomedIntoTopLeft;
          await tester.pump();

          await tester.pumpWidget(
            buildCanvas(
              container: container,
              controller: controller,
              imageSize: imageSize,
              imagePath: '/nonexistent/photo-b.jpg',
            ),
          );
          await tester.pump();

          expect(
            controller.value,
            isNot(zoomedIntoTopLeft),
            reason:
                "switching photos must not carry the previous photo's "
                'transform — even when the screen did not reset the shared '
                'controller first',
          );
          expect(
            controller.value.getMaxScaleOnAxis(),
            closeTo(
              TopoCanvas.computeFillWidthTransform(
                imageSize: imageSize,
                viewportSize: viewportSize,
              ).getMaxScaleOnAxis(),
              0.001,
            ),
          );
        },
      );

      testWidgets(
        'a same-photo viewport resize still does NOT stomp a manual '
        'pan/zoom (the photo-switch fix must not widen into a resize '
        'reframe)',
        (tester) async {
          const imageSize = Size(1200, 1600);
          setViewportSize(tester, const Size(400, 800));

          final container = ProviderContainer();
          addTearDown(container.dispose);
          final controller = TransformationController();
          addTearDown(controller.dispose);

          await tester.pumpWidget(
            buildCanvas(
              container: container,
              controller: controller,
              imageSize: imageSize,
              imagePath: '/nonexistent/photo-a.jpg',
            ),
          );
          await tester.pump();

          final userMatrix = Matrix4.identity()
            ..setEntry(0, 0, 1.5)
            ..setEntry(1, 1, 1.5)
            ..setEntry(2, 2, 1.5)
            ..setEntry(0, 3, -37.0)
            ..setEntry(1, 3, -42.0);
          controller.value = userMatrix;
          await tester.pump();

          setViewportSize(tester, const Size(500, 900));
          await tester.pump();

          expect(controller.value, userMatrix);
        },
      );
    },
  );

  group('TopoCanvas never frames against a degenerate imageSize', () {
    testWidgets(
      'a zero imageSize is not framed at all and the photo layer stays '
      'hidden; the real size that follows is framed as the first real '
      'content',
      (tester) async {
        const viewportSize = Size(400, 800);
        const realImageSize = Size(1200, 1600);
        setViewportSize(tester, viewportSize);

        final container = ProviderContainer();
        addTearDown(container.dispose);
        final controller = TransformationController();
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          buildCanvas(
            container: container,
            controller: controller,
            imageSize: Size.zero,
            imagePath: '/nonexistent/photo-a.jpg',
          ),
        );
        await tester.pump();

        expect(
          controller.value,
          Matrix4.identity(),
          reason:
              'there is no size to fit against, so nothing may be committed '
              'to the controller',
        );
        expect(
          photoLayerOpacity(tester),
          0.0,
          reason:
              'a transform that is not a fit for real content must never be '
              'painted — scale 1 at the origin is exactly the reported '
              'top-left-at-1:1 symptom',
        );

        // The real dimensions arrive (e.g. the PhotoRef row lands).
        await tester.pumpWidget(
          buildCanvas(
            container: container,
            controller: controller,
            imageSize: realImageSize,
            imagePath: '/nonexistent/photo-a.jpg',
          ),
        );
        await tester.pump();

        expect(
          controller.value.getMaxScaleOnAxis(),
          closeTo(
            TopoCanvas.computeFillWidthTransform(
              imageSize: realImageSize,
              viewportSize: viewportSize,
            ).getMaxScaleOnAxis(),
            0.001,
          ),
          reason:
              'the first VALID size must be treated as the first real frame '
              'and fitted',
        );
        expect(photoLayerOpacity(tester), 1.0);
      },
    );

    testWidgets(
      'an imageSize that goes degenerate AFTER a valid one hides the photo '
      'again rather than painting it through the previous size\'s fit',
      (tester) async {
        const viewportSize = Size(400, 800);
        const realImageSize = Size(1200, 1600);
        setViewportSize(tester, viewportSize);

        final container = ProviderContainer();
        addTearDown(container.dispose);
        final controller = TransformationController();
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          buildCanvas(
            container: container,
            controller: controller,
            imageSize: realImageSize,
            imagePath: '/nonexistent/photo-a.jpg',
          ),
        );
        await tester.pump();
        expect(
          photoLayerOpacity(tester),
          1.0,
          reason: 'sanity: framed and revealed for the valid size',
        );

        // The size becomes unusable while the canvas stays mounted. The fit
        // in the controller is now a fit for a size this content no longer
        // claims to have, so it must not be painted through.
        await tester.pumpWidget(
          buildCanvas(
            container: container,
            controller: controller,
            imageSize: Size.zero,
            imagePath: '/nonexistent/photo-a.jpg',
          ),
        );
        await tester.pump();

        expect(
          photoLayerOpacity(tester),
          0.0,
          reason:
              'the canvas must never paint content through a transform that '
              'is not a fit for the size it currently has',
        );
      },
    );

    testWidgets(
      'a zero-HEIGHT (but non-zero-width) imageSize is not framed either',
      (tester) async {
        setViewportSize(tester, const Size(400, 800));

        final container = ProviderContainer();
        addTearDown(container.dispose);
        final controller = TransformationController();
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          buildCanvas(
            container: container,
            controller: controller,
            imageSize: const Size(1200, 0),
            imagePath: '/nonexistent/photo-a.jpg',
          ),
        );
        await tester.pump();

        expect(controller.value, Matrix4.identity());
        expect(photoLayerOpacity(tester), 0.0);
      },
    );
  });
}
