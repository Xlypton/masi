import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:climbtopo/features/topo/application/slice_controller.dart';

/// Logical-pixel threshold within which a tap is considered "near" an
/// existing cut line, so it removes that cut (via [SliceController
/// .removeNearestCut]) instead of adding a brand new one at the tapped
/// position.
const double _cutHitRadiusPx = 24.0;

/// Overlay shown over the topo image area while the screen is in slice mode:
/// renders a vertical line at each pending cut from [sliceControllerProvider]
/// and lets the user tap to add a new cut, or tap near an existing line to
/// remove it.
///
/// ## Why cut fractions map through the DISPLAYED image rect, not the viewport
///
/// [size] is the on-screen size of the viewport this overlay is stacked over
/// (the same region [TopoCanvas] fills). A cut is stored as a fraction of the
/// ORIGINAL IMAGE width, so a tap has to be mapped into image space — and the
/// image does NOT necessarily fill the viewport. Under the contain-fit
/// [TopoCanvas] applies, a tall/portrait photo (or any photo in a wide
/// viewport) is HORIZONTALLY LETTERBOXED: it's scaled to fit the height and
/// centered, leaving empty margins left and right. Mapping a tap as the old
/// `dx / size.width` would then treat those margins as part of the image, so
/// the cut lines wouldn't line up with where the user tapped on the photo and
/// the persisted crop rects would be skewed.
///
/// Instead, [_displayedImageRect] runs the image's corners through the live
/// [transformationController] value (the exact same matrix that positions the
/// photo on screen), yielding the photo's actual on-screen rectangle. Taps and
/// cut markers are mapped relative to THAT rect: `(dx - rect.left) /
/// rect.width`. In the common landscape-photo-in-portrait-viewport case the
/// photo fills the viewport width, so `rect.left == 0` and `rect.width ==
/// size.width` and this reduces to the old behavior exactly. (Slice mode also
/// forces the view back to Original at a stable fit — see
/// `TopoCanvasScreen._toggleSliceMode` — so this rect is stable while slicing.)
///
/// A tap that lands in the letterbox margin maps outside `0..1` and is dropped
/// by [SliceController.addCut]'s own boundary guard.
///
/// This widget deliberately captures every tap within [size] via an opaque
/// [GestureDetector] so that, while slice mode is showing, no tap reaches
/// whatever draw/view gesture handling sits underneath (see
/// `TopoCanvasScreen`'s slice-mode wiring) — this is what keeps slice mode
/// and draw/view mode mutually exclusive.
class SliceTool extends ConsumerWidget {
  const SliceTool({
    super.key,
    required this.size,
    required this.imageSize,
    required this.transformationController,
  });

  /// On-screen size of the viewport this overlay covers.
  final Size size;

  /// Natural (decoded) size of the ORIGINAL image, in pixels — used with
  /// [transformationController] to recover the photo's on-screen rectangle.
  final Size imageSize;

  /// The live pan/zoom transform [TopoCanvas] renders the photo through.
  /// Read (not listened) here: slice mode pins the view to a stable fit, so
  /// the derived image rect doesn't move while slicing.
  final TransformationController transformationController;

  /// The photo's actual on-screen rectangle, in this overlay's local
  /// coordinate space, by mapping the image's corners through the live
  /// [transformationController]. See the class doc for why this matters.
  Rect _displayedImageRect() {
    final matrix = transformationController.value;
    final topLeft = MatrixUtils.transformPoint(matrix, Offset.zero);
    final bottomRight = MatrixUtils.transformPoint(
      matrix,
      Offset(imageSize.width, imageSize.height),
    );
    return Rect.fromPoints(topLeft, bottomRight);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cuts = ref.watch(sliceControllerProvider);
    final imageRect = _displayedImageRect();

    return SizedBox(
      width: size.width,
      height: size.height,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              key: const Key('slice-tool-gesture-detector'),
              behavior: HitTestBehavior.opaque,
              onTapUp: (details) => _handleTap(ref, details.localPosition),
            ),
          ),
          for (var i = 0; i < cuts.length; i++)
            // IgnorePointer so the marker itself never intercepts the tap
            // meant for the GestureDetector above (Stack hit-tests in
            // reverse paint order, i.e. this marker would otherwise win).
            Positioned(
              left: imageRect.left + cuts[i] * imageRect.width - 1,
              top: 0,
              bottom: 0,
              child: IgnorePointer(
                child: Container(
                  key: Key('slice-cut-$i'),
                  width: 2,
                  color: Colors.orangeAccent,
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _handleTap(WidgetRef ref, Offset localPosition) {
    final imageRect = _displayedImageRect();
    if (imageRect.width <= 0) return;

    final notifier = ref.read(sliceControllerProvider.notifier);
    final cuts = ref.read(sliceControllerProvider);

    double? nearestDistancePx;
    for (final cut in cuts) {
      final cutX = imageRect.left + cut * imageRect.width;
      final distance = (cutX - localPosition.dx).abs();
      if (nearestDistancePx == null || distance < nearestDistancePx) {
        nearestDistancePx = distance;
      }
    }

    final fraction = (localPosition.dx - imageRect.left) / imageRect.width;
    if (nearestDistancePx != null && nearestDistancePx <= _cutHitRadiusPx) {
      notifier.removeNearestCut(fraction);
    } else {
      // Out-of-image taps (letterbox margins) map outside 0..1 and are
      // dropped by SliceController.addCut's own boundary guard.
      notifier.addCut(fraction);
    }
  }
}
