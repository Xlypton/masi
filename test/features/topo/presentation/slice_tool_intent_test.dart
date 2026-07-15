import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:climbtopo/app/theme.dart';
import 'package:climbtopo/features/topo/application/slice_controller.dart';
import 'package:climbtopo/features/topo/domain/slice_geometry.dart';
import 'package:climbtopo/features/topo/presentation/slice_tool.dart';
import 'package:climbtopo/features/topo/presentation/topo_canvas.dart';

/// Intended-behavior UI tests for [SliceTool] — the letterbox regression
/// coverage the prior slice_tool.dart crop fix shipped WITHOUT.
///
/// These assertions encode the SPEC (BUG-5 / L2 in the plan). A tap must map
/// to a cut fraction relative to the DISPLAYED image rectangle (whatever
/// rect [transformationController]'s live matrix currently maps [imageSize]
/// to), so that a tall/pillarboxed photo maps correctly and the common
/// landscape case is unchanged. A failing assertion here reveals a real bug
/// — never weaken it.
///
/// [SliceTool] itself does not compute any particular fit — it derives the
/// displayed image rect purely by mapping the image's corners through
/// `transformationController.value` (see `_displayedImageRect()`), entirely
/// agnostic to whether that matrix happens to be a CONTAIN or COVER fit, a
/// crop-band framing, or a manual pan/zoom. `TopoCanvas` (the production
/// caller sharing this same controller) now frames its OWN initial/reframe
/// transform to COVER ([TopoCanvas.computeFitTransform], the soft-edge-fade/
/// fill-viewport change — see `topo_canvas.dart`), which never actually
/// produces a letterbox/pillarbox MARGIN (COVER always crops the looser
/// axis rather than margining it — see [computeFitScale] vs
/// [computeFitTransform]'s doc). So the letterbox-margin-specific cases
/// below (A4b / A4b-margin / A4c) seed the controller with an independently
/// -built CONTAIN matrix via [containMatrix] (mirroring the math
/// [SliceTool] used to be exercised against pre-fill-viewport, and matching
/// [TopoCanvas.computeFitScale]/`computeCropTransform`'s own CONTAIN family)
/// rather than [TopoCanvas.computeFitTransform], so [SliceTool]'s own
/// generic margin-exclusion/tap-mapping logic keeps direct, deterministic
/// coverage independent of whichever fit TopoCanvas itself currently opens
/// with. A4a/A4d use the shared, same-aspect image/viewport pair for which
/// CONTAIN and COVER coincide (no margin either way), so they're unaffected
/// and keep seeding via the default (now COVER) [TopoCanvas
/// .computeFitTransform] to also exercise that real production wiring.
void main() {
  const tol = 0.02;

  /// Geometrically-correct contain-fit of [image] into [viewport], centered —
  /// the SPEC displayed image rectangle for an identity transform.
  Rect containFit(Size image, Size viewport) {
    final scale = math.min(
      viewport.width / image.width,
      viewport.height / image.height,
    );
    final w = image.width * scale;
    final h = image.height * scale;
    return Rect.fromLTWH(
      (viewport.width - w) / 2,
      (viewport.height - h) / 2,
      w,
      h,
    );
  }

  /// An independently-built CONTAIN-fit [Matrix4] for [image] into
  /// [viewport] — the same scale/centering math as [containFit], expressed
  /// as a transform so it can seed [TransformationController] directly.
  /// Deliberately NOT delegating to [TopoCanvas.computeFitTransform] (which
  /// now builds a COVER transform) so the letterbox-margin tests below stay
  /// meaningful regardless of which fit TopoCanvas itself currently opens
  /// with — see this file's top doc comment.
  Matrix4 containMatrix(Size image, Size viewport) {
    final fit = containFit(image, viewport);
    final scale = image.width > 0 ? fit.width / image.width : 1.0;
    return Matrix4.identity()
      ..setEntry(0, 0, scale)
      ..setEntry(1, 1, scale)
      ..setEntry(2, 2, scale)
      ..setEntry(0, 3, fit.left)
      ..setEntry(1, 3, fit.top);
  }

  Future<void> pumpSliceTool(
    WidgetTester tester, {
    required ProviderContainer container,
    required Size size,
    required Size imageSize,
    required TransformationController controller,
    Matrix4? matrix,
  }) async {
    // Seed the controller with either the caller-supplied matrix, or (by
    // default) the SAME transform production's TopoCanvas installs before
    // SliceTool reads it, so _displayedImageRect() reflects real wiring
    // instead of a bare identity matrix.
    controller.value =
        matrix ??
        TopoCanvas.computeFitTransform(imageSize: imageSize, viewportSize: size);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: MasiTheme.light,
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SliceTool(
                size: size,
                imageSize: imageSize,
                transformationController: controller,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// The SliceTool's global rectangle (its full-bleed gesture detector).
  Rect toolRect(WidgetTester tester) =>
      tester.getRect(find.byKey(const Key('slice-tool-gesture-detector')));

  /// Tap at a point given in the tool's LOCAL coordinate space.
  Future<void> tapLocal(WidgetTester tester, Offset local) async {
    await tester.tapAt(toolRect(tester).topLeft + local);
    await tester.pump();
  }

  group('SliceTool crop math — letterbox correctness (BUG-5 / L2)', () {
    testWidgets(
      'A4a: landscape same-aspect (fills width, no letterbox) — '
      'tap at widget x-fraction f maps to cut ~= f',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final controller = TransformationController();
        addTearDown(controller.dispose);

        const size = Size(400, 300);
        const imageSize = Size(800, 600); // same 4:3 aspect -> fills widget
        await pumpSliceTool(
          tester,
          container: container,
          size: size,
          imageSize: imageSize,
          controller: controller,
        );

        // Contain-fit of an equal-aspect image fills the whole viewport:
        // rect == (0, 0, 400, 300). So a tap at fractional x should map 1:1.
        final fit = containFit(imageSize, size);
        expect(fit, const Rect.fromLTWH(0, 0, 400, 300));

        const f = 0.7;
        await tapLocal(tester, Offset(fit.left + f * fit.width, fit.center.dy));

        final cuts = container.read(sliceControllerProvider);
        expect(cuts, hasLength(1));
        expect(cuts.single, closeTo(f, tol));
      },
    );

    testWidgets(
      'A4b: tall/pillarboxed image — LEFT visible edge maps to cut ~= 0.0, '
      'RIGHT visible edge maps to cut ~= 1.0 (imageRect-relative, KEY SIGNAL)',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final controller = TransformationController();
        addTearDown(controller.dispose);

        const size = Size(400, 300);
        const imageSize = Size(300, 600); // taller than viewport aspect
        await pumpSliceTool(
          tester,
          container: container,
          size: size,
          imageSize: imageSize,
          controller: controller,
          // CONTAIN, not TopoCanvas's current (COVER) default — see this
          // file's top doc comment: COVER never produces a margin, so the
          // pillarbox-margin case this test targets needs an explicit
          // CONTAIN seed.
          matrix: containMatrix(imageSize, size),
        );

        // Contain-fit: scale = min(400/300, 300/600) = 0.5 -> 150x300 image,
        // centered -> horizontal margins of 125px each side.
        final fit = containFit(imageSize, size);
        expect(fit, const Rect.fromLTWH(125, 0, 150, 300));

        // Tap 1px inside the LEFT visible image edge -> fraction ~= 0.0.
        await tapLocal(tester, Offset(fit.left + 1, fit.center.dy));
        // Tap 1px inside the RIGHT visible image edge -> fraction ~= 1.0.
        await tapLocal(tester, Offset(fit.right - 1, fit.center.dy));

        final cuts = container.read(sliceControllerProvider);
        expect(cuts, hasLength(2));
        expect(cuts.first, closeTo(0.0, tol),
            reason: 'left visible edge must map to ~0.0, not a margin-relative '
                'or widget-size-relative value');
        expect(cuts.last, closeTo(1.0, tol),
            reason: 'right visible edge must map to ~1.0, not a margin-relative '
                'or widget-size-relative value');
      },
    );

    testWidgets(
      'A4b (margin): tap in the letterbox margin maps outside [0,1] and is '
      'dropped (no cut added)',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final controller = TransformationController();
        addTearDown(controller.dispose);

        const size = Size(400, 300);
        const imageSize = Size(300, 600);
        await pumpSliceTool(
          tester,
          container: container,
          size: size,
          imageSize: imageSize,
          controller: controller,
          // CONTAIN seed — see the A4b test above / this file's top doc
          // comment for why COVER (TopoCanvas's current default) can't
          // exercise a margin-drop case.
          matrix: containMatrix(imageSize, size),
        );

        final fit = containFit(imageSize, size); // (125, 0, 150, 300)
        // Tap well inside the LEFT margin (local x = 50, left of the image).
        await tapLocal(tester, Offset(50, fit.center.dy));

        final cuts = container.read(sliceControllerProvider);
        expect(cuts, isEmpty,
            reason: 'a tap in the pillarbox margin maps outside 0..1 and must '
                'not add a cut');
      },
    );

    testWidgets(
      'A4c: a cut at fraction 0.5 renders its marker at the horizontal center '
      'of the DISPLAYED image rect (letterboxed -> centered on the image)',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final controller = TransformationController();
        addTearDown(controller.dispose);

        const size = Size(400, 300);
        const imageSize = Size(300, 600); // letterboxed under CONTAIN
        await pumpSliceTool(
          tester,
          container: container,
          size: size,
          imageSize: imageSize,
          controller: controller,
          // CONTAIN seed — see the A4b test above / this file's top doc
          // comment; this test specifically checks marker placement against
          // a letterboxed (CONTAIN) displayed-image rect.
          matrix: containMatrix(imageSize, size),
        );

        // Add a cut at exactly fraction 0.5 (interior -> not dropped). Done via
        // the controller (not a tap) so this checks marker RENDERING against
        // the spec fit rect, independent of the tap-mapping under test above.
        container.read(sliceControllerProvider.notifier).addCut(0.5);
        await tester.pump();

        final fit = containFit(imageSize, size); // (125, 0, 150, 300)
        // Displayed image center is the horizontal centre of the fit rect
        // (== 200 here); for a centered contain-fit this also equals the
        // widget centre, but the marker must track the IMAGE rect, so under a
        // buggy raw-imageSize mapping it would sit at 150, not 200.
        final markerRect =
            tester.getRect(find.byKey(const Key('slice-cut-0')));
        final markerLocalCenterX = markerRect.center.dx - toolRect(tester).left;

        expect(markerLocalCenterX, closeTo(fit.center.dx, 2.0),
            reason: 'cut marker for fraction 0.5 must sit at the displayed '
                'image rect center (${fit.center.dx}), not the raw-image '
                'or widget-relative position');
      },
    );

    testWidgets(
      'A4d: round-trip — tapped fraction f is stored, then slice_geometry '
      'splits at f into correct cropXpct/cropWidthPct',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final controller = TransformationController();
        addTearDown(controller.dispose);

        const size = Size(400, 300);
        const imageSize = Size(800, 600); // same aspect -> fills widget
        await pumpSliceTool(
          tester,
          container: container,
          size: size,
          imageSize: imageSize,
          controller: controller,
        );

        final fit = containFit(imageSize, size); // (0, 0, 400, 300)
        const f = 0.5;
        await tapLocal(tester, Offset(fit.left + f * fit.width, fit.center.dy));

        final cuts = container.read(sliceControllerProvider);
        expect(cuts, hasLength(1));
        expect(cuts.single, closeTo(f, tol),
            reason: 'tapped fraction must round-trip into sliceControllerProvider');

        // Feed the stored cut through the real slice geometry.
        final slices = slicesFromCuts(cuts);
        expect(slices, hasLength(2));
        expect(slices[0].cropXpct, closeTo(0.0, 1e-9));
        expect(slices[0].cropWidthPct, closeTo(0.5, tol));
        expect(slices[1].cropXpct, closeTo(0.5, tol));
        expect(slices[1].cropWidthPct, closeTo(0.5, tol));
      },
    );
  });
}
