// Regression tests for a TopoCanvas defect (2026-08-05 audit): a stale
// auto-fit could stick forever after a same-frame double layout pass.
//
// The auto-fit matrix is decided SYNCHRONOUSLY during `build`
// (`_lastAutoFrameMatrix`) but only actually WRITTEN into
// `transformationController` a full frame later, in a post-frame callback.
// If `LayoutBuilder` is laid out twice with different constraints before
// that write lands, the second pass's `stillAutoFramed` check used to read
// "our own pending write hasn't landed yet" as "the user panned away from
// it" and bail out, permanently committing the FIRST (stale) viewport's fit
// while the real viewport had already moved on. Fixed via
// `_autoFrameWritePending`, which lets `_reframeIfNeeded` tell those two
// cases apart — see that field's doc in `topo_canvas.dart`.
//
// The first test below deliberately avoids the round-trip-tautology shape
// the audit flagged in `topo_canvas_fit_test.dart` (computing a tap point as
// `M · p` and then asserting `toScene(M · p) == p`, which holds for ANY
// invertible `M` and proves nothing about which `M` is actually in play):
// every expected value here is derived by hand, from the viewport size, the
// image size, and the fill-width fit rule written out as plain arithmetic —
// never by calling `TopoCanvas.computeFillWidthTransform`.
import 'package:masi/app/theme.dart';
import 'package:masi/features/topo/presentation/topo_canvas.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _testWallId = 'pending-autofit-wall';

void _setViewportSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  group('a pending (not-yet-written) auto-fit is not mistaken for a manual '
      'user pan', () {
    const imageSize = Size(800, 400);
    const transientViewport = Size(300, 600);
    const settledViewport = Size(400, 800);

    testWidgets(
      "LayoutBuilder laid out TWICE (transient then settled) within a "
      'SINGLE frame settles on the LATER viewport\'s fit, not the stale '
      'first one — even though the first pass\'s post-frame write had not '
      'landed when the second pass ran',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final controller = TransformationController();
        addTearDown(controller.dispose);

        // Deliberately asserts on the state right after `pumpWidget` alone
        // — i.e. after EXACTLY the one frame in which `_DoubleLayoutProbe`
        // forces the double layout pass — and NOT after any additional
        // `tester.pump()`. `_DoubleLayoutProbe` forces the SAME double pass
        // on every frame it lays out, including any later, ordinary frame a
        // `setState` might schedule; a second frame's own second pass would
        // "naturally" pick up a since-landed pending write and mask this
        // exact bug (its self-healing looks identical to the real fix from
        // frame two onward). The bug — and the fix — are both about frame
        // ONE alone, so that is the only frame this assertion may look at.
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: MasiTheme.light,
              home: Scaffold(
                body: _DoubleLayoutProbe(
                  first: transientViewport,
                  second: settledViewport,
                  child: TopoCanvas(
                    wallId: _testWallId,
                    imagePath: '/nonexistent/pending-autofit.jpg',
                    imageSize: imageSize,
                    transformationController: controller,
                  ),
                ),
              ),
            ),
          ),
        );

        // Hand-computed fill-width fit for the SETTLED (second, later)
        // viewport: scale = 400/800 = 0.5, scaledHeight = 400*0.5 = 200,
        // dy = (800-200)/2 = 300.
        final expectedScale = settledViewport.width / imageSize.width; // 0.5
        final expectedScaledHeight = imageSize.height * expectedScale; // 200
        final expectedDy =
            (settledViewport.height - expectedScaledHeight) / 2; // 300

        expect(
          controller.value.getMaxScaleOnAxis(),
          closeTo(expectedScale, 0.001),
          reason:
              'must settle on the SECOND (later, settled) viewport\'s fit — '
              'pre-fix, the pending first-pass write was mistaken for a '
              'manual pan and the FIRST (stale, transient) viewport\'s fit '
              'stuck instead',
        );
        final origin = MatrixUtils.transformPoint(controller.value, Offset.zero);
        expect(origin.dx, closeTo(0.0, 0.001));
        expect(origin.dy, closeTo(expectedDy, 0.001));

        // Negative control, computed by hand the same way: the STALE
        // (first, transient) viewport's fit is a DIFFERENT, distinguishable
        // scale — proving the assertion above isn't vacuously satisfied by
        // both viewports implying the same fit.
        final staleScale = transientViewport.width / imageSize.width; // 0.375
        expect(staleScale, isNot(closeTo(expectedScale, 0.001)));
        expect(
          controller.value.getMaxScaleOnAxis(),
          isNot(closeTo(staleScale, 0.001)),
        );
      },
    );

    testWidgets(
      'a genuine user pan/zoom is still NOT stomped by a later resize — the '
      'pending-write fix does not weaken this existing guarantee',
      (tester) async {
        _setViewportSize(tester, settledViewport);
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
                  wallId: _testWallId,
                  imagePath: '/nonexistent/pending-autofit-b.jpg',
                  imageSize: imageSize,
                  transformationController: controller,
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        final userMatrix = Matrix4.identity()
          ..setEntry(0, 0, 1.7)
          ..setEntry(1, 1, 1.7)
          ..setEntry(2, 2, 1.7)
          ..setEntry(0, 3, -11.0)
          ..setEntry(1, 3, -19.0);
        controller.value = userMatrix;
        await tester.pump();

        _setViewportSize(tester, transientViewport);
        await tester.pump();

        expect(
          controller.value,
          userMatrix,
          reason:
              'a resize after a real manual pan/zoom must still leave the '
              "user's transform alone — this is the check the fix must not "
              'have broken while fixing the pending-write false positive',
        );
      },
    );
  });
}

/// Test-only harness (repro): forces [child] to be laid out TWICE, with two
/// different tight [BoxConstraints] ([first] then [second]), within a
/// SINGLE frame — before ANY of that frame's `addPostFrameCallback`s run.
/// This deterministically reproduces the exact precondition
/// `_TopoCanvasState._reframeIfNeeded`'s stale-auto-fit bug depends on ("the
/// LayoutBuilder is laid out twice with different constraints before [the
/// auto-fit] write lands") through the public widget API, rather than
/// needing to coax a real Flutter relayout quirk into firing on cue.
///
/// Legal per the `RenderObject.layout` contract: calling `child.layout(...)`
/// twice with DIFFERENT constraints in one `performLayout` always re-runs
/// the child's own `performLayout` (Flutter's same-constraints/not-dirty
/// fast path only skips a repeat call when the constraints are `==` to the
/// previous call, which they deliberately are not here) — so a
/// `LayoutBuilder` descendant genuinely has its `builder` invoked twice,
/// once per constraint, in build/layout order, before this frame's
/// post-frame callbacks fire (those only run after the WHOLE frame's
/// layout+paint has finished).
class _DoubleLayoutProbe extends SingleChildRenderObjectWidget {
  const _DoubleLayoutProbe({
    required this.first,
    required this.second,
    required Widget child,
  }) : super(child: child);

  final Size first;
  final Size second;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderDoubleLayoutProbe(initialFirst: first, initialSecond: second);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderDoubleLayoutProbe renderObject,
  ) {
    renderObject
      ..first = first
      ..second = second;
  }
}

class _RenderDoubleLayoutProbe extends RenderProxyBox {
  _RenderDoubleLayoutProbe({
    required Size initialFirst,
    required Size initialSecond,
  }) : _first = initialFirst,
       _second = initialSecond;

  Size _first;
  Size get first => _first;
  set first(Size value) {
    if (_first == value) return;
    _first = value;
    markNeedsLayout();
  }

  Size _second;
  Size get second => _second;
  set second(Size value) {
    if (_second == value) return;
    _second = value;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    // Pass 1 ("transient"): the descendant `LayoutBuilder` sees `_first` as
    // its own incoming constraints and runs its builder — i.e.
    // `_reframeIfNeeded(_first)` — synchronously, right here.
    child.layout(BoxConstraints.tight(_first), parentUsesSize: true);
    // Pass 2 ("settled"), same frame, before any post-frame callback either
    // pass scheduled has had a chance to run: the SAME `LayoutBuilder` runs
    // its builder again with `_second` — i.e. `_reframeIfNeeded(_second)`.
    child.layout(BoxConstraints.tight(_second), parentUsesSize: true);
    size = constraints.constrain(_second);
  }
}
