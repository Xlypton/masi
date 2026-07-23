// Ship 1 of the route-derived rock box (#68): `RockHighlightController` is
// now a plain per-photo on/off toggle -- no async native `segmentPreview`
// call, no decoded-mask cache. See `rock_mask_painter.dart`'s
// `RockBoxPainter` / `topo_canvas.dart` for how the toggle drives painting
// a route-derived box instead.
import 'package:masi/features/topo/application/rock_highlight_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('starts OFF for a photo that has never been toggled', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(rockHighlightControllerProvider('photo-1')), isFalse);
  });

  test('toggle() flips the state on, then off again', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final notifier =
        container.read(rockHighlightControllerProvider('photo-1').notifier);

    notifier.toggle();
    expect(container.read(rockHighlightControllerProvider('photo-1')), isTrue);

    notifier.toggle();
    expect(container.read(rockHighlightControllerProvider('photo-1')), isFalse);
  });

  test(
    'is family-keyed by photoId -- toggling one photo does not affect '
    'another photo\'s state',
    () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(rockHighlightControllerProvider('photo-1').notifier).toggle();

      expect(container.read(rockHighlightControllerProvider('photo-1')), isTrue);
      expect(container.read(rockHighlightControllerProvider('photo-2')), isFalse);
    },
  );
}
