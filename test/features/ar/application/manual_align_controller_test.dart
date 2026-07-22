import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:masi/features/ar/application/manual_align_controller.dart';

void main() {
  group('ManualAlignController', () {
    test('A1: initial state is identity (warp is a no-op)', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final state = container.read(manualAlignProvider);
      final result = state.warp(const Offset(5, 9));

      expect(result.dx, closeTo(5, 1e-9));
      expect(result.dy, closeTo(9, 1e-9));
    });

    test('A2: pan composes a translation in screen space', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(manualAlignProvider.notifier).pan(const Offset(10, -4));
      final state = container.read(manualAlignProvider);
      final result = state.warp(const Offset(2, 2));

      expect(result.dx, closeTo(12, 1e-9));
      expect(result.dy, closeTo(-2, 1e-9));
    });

    test('A3: scale about a focal point fixes the focal and scales '
        'distances from it', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      const focal = Offset(100, 100);

      container.read(manualAlignProvider.notifier).scale(2.0, focal);
      final state = container.read(manualAlignProvider);

      final focalResult = state.warp(focal);
      expect(focalResult.dx, closeTo(100, 1e-9));
      expect(focalResult.dy, closeTo(100, 1e-9));

      final pointResult = state.warp(const Offset(110, 100));
      expect(pointResult.dx, closeTo(120, 1e-9));
      expect(pointResult.dy, closeTo(100, 1e-9));
    });

    test('A4: rotate about a focal point fixes the focal and rotates '
        '(1,0) to (0,1) for +pi/2, per the documented R matrix convention', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      const focal = Offset(0, 0);

      container.read(manualAlignProvider.notifier).rotate(pi / 2, focal);
      final state = container.read(manualAlignProvider);

      final focalResult = state.warp(focal);
      expect(focalResult.dx, closeTo(0, 1e-9));
      expect(focalResult.dy, closeTo(0, 1e-9));

      final pointResult = state.warp(const Offset(1, 0));
      expect(pointResult.dx, closeTo(0, 1e-9));
      expect(pointResult.dy, closeTo(1, 1e-9));
    });

    test('A5a: reset() returns to identity (warp no-op)', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(manualAlignProvider.notifier);
      notifier.pan(const Offset(10, -4));
      notifier.scale(2.0, const Offset(100, 100));
      notifier.reset();

      final state = container.read(manualAlignProvider);
      final result = state.warp(const Offset(7, -3));

      expect(result.dx, closeTo(7, 1e-9));
      expect(result.dy, closeTo(-3, 1e-9));
    });

    test('A5b: a combined pan-then-scale sequence composes without losing '
        'the earlier pan', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(manualAlignProvider.notifier);
      // Pan by (10, -4): p -> p + (10, -4).
      notifier.pan(const Offset(10, -4));
      // Then scale by 2 about (100, 100), applied on top of the pan.
      notifier.scale(2.0, const Offset(100, 100));

      final state = container.read(manualAlignProvider);

      // Hand-verified: point (2, 2).
      // Step 1 (pan): (2, 2) -> (12, -2).
      // Step 2 (scale by 2 about (100, 100)):
      //   (12, -2) - (100, 100) = (-88, -102)
      //   * 2 = (-176, -204)
      //   + (100, 100) = (-76, -104)
      final result = state.warp(const Offset(2, 2));

      expect(result.dx, closeTo(-76, 1e-9));
      expect(result.dy, closeTo(-104, 1e-9));
    });

    test('A6: no material import (pure Dart / ui only) is enforced by '
        'analyzer, not runtime — this test just exercises the public API '
        'via ProviderContainer', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(manualAlignProvider.notifier);
      notifier.pan(const Offset(1, 1));
      notifier.rotate(pi / 4, const Offset(0, 0));
      notifier.scale(1.5, const Offset(0, 0));
      notifier.reset();

      expect(container.read(manualAlignProvider).warp(const Offset(3, 3)).dx,
          closeTo(3, 1e-9));
    });
  });
}
