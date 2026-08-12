// Regression tests for a TopoCanvas defect (2026-08-05 audit): overlay/
// hit-test geometry used to track a STALE persisted size instead of the
// REAL decoded photo.
//
// `_TopoCanvasState` used to build its paint box (`SizedBox`/`PhotoImage`),
// its route overlay (`TopoPainter`'s `CustomPaint`), and every hit test
// entirely from `widget.imageSize` — a value RECORDED ONCE AT IMPORT TIME
// (the wall's persisted `PhotoRef.width`/`height`) that can disagree with
// what actually decodes for THIS render (an EXIF-orientation disagreement
// between the import-time prober and the display-time decoder, or a
// substituted public-photo variant). `PhotoImage` paints via
// `BoxFit.contain`, so a mismatched aspect ratio just letterboxes the real
// photo inside that box — but the overlay and every tap kept treating the
// WHOLE box as the image, so they landed on the wrong on-screen pixels
// whenever the two disagreed. Fixed by having `_TopoCanvasState` probe the
// REAL decoded size (via the existing `PhotoImageProvider` dimension
// resolver — the same cross-platform decode `PhotoImage` itself uses) and,
// once known, switching EVERY size-dependent computation in this state over
// to it (`_effectiveImageSize`) — see that getter's doc in `topo_canvas.dart`
// for the full rationale, including why a failed/pending probe safely falls
// back to `widget.imageSize` (never a latched error state, unlike the
// pre-F-A2 architecture `topo_canvas_missing_bytes_test.dart` guards against
// reintroducing).
//
// The primary test below deliberately avoids the round-trip-tautology shape
// the audit flagged in `topo_canvas_fit_test.dart` (computing a tap point as
// `M · p` and then asserting `toScene(M · p) == p`, which holds for ANY
// invertible `M` and proves nothing about which `M` is actually in play):
// every expected screen/scene position here is derived by hand, from the
// viewport size, the REAL image size, and the fill-width fit rule
// (`scale = viewport.width / imageWidth`, then vertical centering) written
// out as plain arithmetic — never by calling
// `TopoCanvas.computeFillWidthTransform` or reading `controller.value` to
// produce the "expected" value.
import 'dart:io';

import 'package:masi/app/theme.dart';
import 'package:masi/features/topo/application/draw_controller.dart';
import 'package:masi/features/topo/presentation/photo_image.dart';
import 'package:masi/features/topo/presentation/topo_canvas.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../../../support/async_drain.dart';

const _testWallId = 'decoded-size-mismatch-wall';

void _setViewportSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  group('overlay/hit-test track the REAL decoded photo, not a stale '
      'persisted size', () {
    // The declared (persisted `PhotoRef`) size is a 90-degree SWAP of the
    // real decoded bytes below — the exact shape of the worked example in
    // the bug report (PhotoRef says 3000x4000, bytes decode 4000x3000).
    const declaredImageSize = Size(100, 200); // portrait, aspect 0.5
    const realImageSize = Size(200, 100); // landscape, aspect 2.0 — decoded
    const viewportSize = Size(400, 800);

    late Directory tempDir;
    late File realPhoto;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync(
        'topo_canvas_decoded_size_mismatch',
      );
      realPhoto = File(p.join(tempDir.path, 'real.png'));
      final image = img.Image(
        width: realImageSize.width.toInt(),
        height: realImageSize.height.toInt(),
      );
      realPhoto.writeAsBytesSync(img.encodePng(image));
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    testWidgets(
      'once the real decode lands, the paint box, the route-overlay '
      'CustomPaint, the applied fit transform, AND a tap all agree on the '
      'REAL decoded size — not the stale declared one',
      (tester) async {
        _setViewportSize(tester, viewportSize);
        final container = ProviderContainer();
        addTearDown(container.dispose);
        container.listen(drawControllerProvider(_testWallId), (_, _) {});
        container
            .read(drawControllerProvider(_testWallId).notifier)
            .setMode(DrawMode.draw);
        final controller = TransformationController();
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: MasiTheme.light,
              home: Scaffold(
                body: TopoCanvas(
                  wallId: _testWallId,
                  imagePath: realPhoto.path,
                  imageSize: declaredImageSize,
                  transformationController: controller,
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        // Sanity: before the real decode has had a chance to land, this
        // widget is still operating on the STALE declared size — proving
        // this test actually exercises the correction rather than starting
        // from it. Fill-width fit against the declared (portrait) size:
        // scale = viewport.width / declared.width = 400 / 100 = 4.0.
        expect(
          controller.value.getMaxScaleOnAxis(),
          closeTo(4.0, 0.001),
          reason:
              'first frame must still be using the stale declared size — '
              'otherwise this test would not be exercising the correction '
              'at all',
        );

        // Let the real `PhotoImageProvider` decode (dart:io read +
        // `instantiateImageCodec`) actually complete under the REAL event
        // loop — `tester.pump()` alone never advances real async work (see
        // `photo_image_test.dart`'s identical rationale) — and wait
        // specifically for the OBSERVABLE effect of the correction: the
        // `PhotoImage` widget's own `width` being handed the REAL decoded
        // width instead of the stale declared one.
        //
        // Keyed to the full-resolution layer (`topo-canvas-photo`): the
        // canvas now paints the photo's thumbnail beneath it as a
        // progressive placeholder, so `find.byType(PhotoImage)` matches two.
        // The claim under test is about the size BOTH are laid out at, and
        // naming the one that carries the decoded size keeps this reading
        // the value it means to.
        await pumpUntil(
          tester,
          () =>
              tester.widget<PhotoImage>(find.byKey(const Key('topo-canvas-photo'))).width ==
              realImageSize.width,
        );
        await drainAsync(tester, settle: false);

        // (a) The paint box itself now uses the REAL decoded size.
        final photoImage = tester.widget<PhotoImage>(find.byKey(const Key('topo-canvas-photo')));
        expect(photoImage.width, realImageSize.width);
        expect(photoImage.height, realImageSize.height);

        // (b) The route-overlay CustomPaint (TopoPainter) shares that SAME
        // size — proving there is exactly one size in play, not the paint
        // box using one value and the overlay another.
        final overlayPaint = tester.widgetList<CustomPaint>(
          find.byType(CustomPaint),
        ).firstWhere((cp) => cp.size == realImageSize);
        expect(overlayPaint.size, realImageSize);

        // (c) The applied fit transform is recomputed for the REAL size —
        // hand-derived (fill-width: scale = viewport.width / realWidth,
        // then vertical centering), NOT by calling
        // `TopoCanvas.computeFillWidthTransform` (that would make this
        // assertion circular against the very code it's meant to check).
        final expectedScale = viewportSize.width / realImageSize.width; // 2.0
        final expectedScaledHeight = realImageSize.height * expectedScale; // 200
        final expectedDy =
            (viewportSize.height - expectedScaledHeight) / 2; // 300
        expect(
          controller.value.getMaxScaleOnAxis(),
          closeTo(expectedScale, 0.001),
        );
        final origin = MatrixUtils.transformPoint(controller.value, Offset.zero);
        expect(origin.dx, closeTo(0.0, 0.001));
        expect(origin.dy, closeTo(expectedDy, 0.001));

        // (d) A real tap at a HAND-COMPUTED screen point — using only the
        // viewport size, the REAL image size, and the fill-width fit rule
        // written out as arithmetic, never `controller.value` or
        // `computeFillWidthTransform` — lands at the percent it targets.
        // Percent (0.5, 0.1) is deliberately OFF-center on the y axis: for
        // a fill-width fit the x mapping is scale-invariant (percent.dx *
        // viewport.width, always), so only y actually distinguishes
        // "fit against the real size" from "fit against the stale
        // declared size" — matching the bug report's own "paints ~115px
        // LOWER" (a y-axis-only symptom).
        const targetPercent = Offset(0.5, 0.1);
        final expectedSceneX = targetPercent.dx * realImageSize.width; // 100
        final expectedSceneY = targetPercent.dy * realImageSize.height; // 10
        final tapPoint = Offset(
          expectedSceneX * expectedScale, // dx is 0, so no offset needed
          expectedDy + expectedSceneY * expectedScale,
        );
        // Sanity on the hand computation itself (400/... not needed here,
        // just pins the literal expected value so a future edit to this
        // test can't silently drift): (200, 320).
        expect(tapPoint, const Offset(200.0, 320.0));

        await tester.tapAt(tapPoint);
        await tester.pump();

        final points = container
            .read(drawControllerProvider(_testWallId))
            .currentPoints;
        expect(points, hasLength(1));
        expect(points.first.dx, closeTo(targetPercent.dx, 0.02));
        expect(points.first.dy, closeTo(targetPercent.dy, 0.02));
      },
    );

    test(
      'the SAME hand-computed point, if the stale declared size were still '
      'in effect, would land at a DIFFERENT (wrong) percent — proving the '
      "fix's tap point isn't just accidentally correct for any size",
      () {
        // Fill-width fit against the STALE declared (portrait) size:
        // scale = 400/100 = 4.0, scaledHeight = 200*4 = 800 == viewport
        // height exactly, so dy = 0 (no vertical slack at all).
        const staleScale = 4.0;
        const staleDy = 0.0;
        const targetPercent = Offset(0.5, 0.1);
        // Same hand-computed tap point as the primary test above — (200, 320).
        const tapPoint = Offset(200.0, 320.0);

        // What that SAME screen point would resolve to under the stale fit
        // (inverting it by hand, not via `toScene`/`controller.value`):
        // scene = ((tap.dx - 0) / staleScale, (tap.dy - staleDy) / staleScale)
        // percent = scene / declaredImageSize.
        final staleSceneX = tapPoint.dx / staleScale; // 50
        final staleSceneY = (tapPoint.dy - staleDy) / staleScale; // 80
        final stalePercent = Offset(
          staleSceneX / declaredImageSize.width, // 0.5
          staleSceneY / declaredImageSize.height, // 0.4
        );
        expect(
          stalePercent.dy,
          isNot(closeTo(targetPercent.dy, 0.02)),
          reason:
              'this is the bug itself: the SAME screen tap resolves to a '
              'materially different (wrong) percent under the stale '
              'declared size than under the real decoded size — confirming '
              'the primary test above is not vacuously true for any size',
        );
      },
    );
  });
}
