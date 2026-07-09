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
/// [size] is the on-screen size of the image area this overlay is stacked
/// over, in the same local coordinate space as the tap events it receives —
/// so a cut fraction `x` maps directly to the screen position
/// `x * size.width`, and a tapped screen position `dx` maps back to the
/// fraction `dx / size.width`.
///
/// This widget deliberately captures every tap within [size] via an opaque
/// [GestureDetector] so that, while slice mode is showing, no tap reaches
/// whatever draw/view gesture handling sits underneath (see
/// `TopoCanvasScreen`'s slice-mode wiring) — this is what keeps slice mode
/// and draw/view mode mutually exclusive.
class SliceTool extends ConsumerWidget {
  const SliceTool({super.key, required this.size});

  final Size size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cuts = ref.watch(sliceControllerProvider);

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
              left: cuts[i] * size.width - 1,
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
    if (size.width <= 0) return;

    final notifier = ref.read(sliceControllerProvider.notifier);
    final cuts = ref.read(sliceControllerProvider);

    double? nearestDistancePx;
    for (final cut in cuts) {
      final distance = (cut * size.width - localPosition.dx).abs();
      if (nearestDistancePx == null || distance < nearestDistancePx) {
        nearestDistancePx = distance;
      }
    }

    final fraction = localPosition.dx / size.width;
    if (nearestDistancePx != null && nearestDistancePx <= _cutHitRadiusPx) {
      notifier.removeNearestCut(fraction);
    } else {
      notifier.addCut(fraction);
    }
  }
}
