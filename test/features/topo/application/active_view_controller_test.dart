import 'package:climbtopo/features/topo/application/active_view_controller.dart';
import 'package:climbtopo/features/topo/data/photo_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ActiveView', () {
    test('isOriginal is true iff cropXpct is null', () {
      const original = ActiveView(photoId: 'p1');
      const slice = ActiveView(photoId: 'p2', cropXpct: 0.25, cropWidthPct: 0.5);

      expect(original.isOriginal, isTrue);
      expect(slice.isOriginal, isFalse);
    });

    test('equality/hashCode are value-based', () {
      const a = ActiveView(photoId: 'p2', cropXpct: 0.25, cropWidthPct: 0.5);
      const b = ActiveView(photoId: 'p2', cropXpct: 0.25, cropWidthPct: 0.5);
      const c = ActiveView(photoId: 'p2', cropXpct: 0.3, cropWidthPct: 0.5);

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });

  group('ActiveViewController', () {
    test('build() starts at null (nothing loaded yet)', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(activeViewProvider), isNull);
    });

    test(
      'A1: showOriginal sets an ActiveView with isOriginal true and no crop',
      () {
        final container = ProviderContainer();
        addTearDown(container.dispose);

        container.read(activeViewProvider.notifier).showOriginal('orig-1');

        final view = container.read(activeViewProvider);
        expect(view, isNotNull);
        expect(view!.photoId, 'orig-1');
        expect(view.isOriginal, isTrue);
        expect(view.cropXpct, isNull);
        expect(view.cropWidthPct, isNull);
      },
    );

    test(
      'A1: showSlice sets an ActiveView carrying the slice\'s id and crop',
      () {
        final container = ProviderContainer();
        addTearDown(container.dispose);

        const slice = PhotoRef(
          id: 'slice-1',
          wallId: 'wall-1',
          kind: 'slice',
          localPath: '/tmp/original.jpg',
          width: 1000,
          height: 2000,
          parentPhotoId: 'orig-1',
          cropXpct: 0.25,
          cropWidthPct: 0.5,
        );

        container.read(activeViewProvider.notifier).showSlice(slice);

        final view = container.read(activeViewProvider);
        expect(view, isNotNull);
        expect(view!.photoId, 'slice-1');
        expect(view.isOriginal, isFalse);
        expect(view.cropXpct, 0.25);
        expect(view.cropWidthPct, 0.5);
      },
    );

    test('clear resets to null', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(activeViewProvider.notifier).showOriginal('orig-1');
      expect(container.read(activeViewProvider), isNotNull);

      container.read(activeViewProvider.notifier).clear();
      expect(container.read(activeViewProvider), isNull);
    });

    test(
      'switching from a slice back to Original clears the crop (isOriginal '
      'true)',
      () {
        final container = ProviderContainer();
        addTearDown(container.dispose);

        const slice = PhotoRef(
          id: 'slice-1',
          wallId: 'wall-1',
          kind: 'slice',
          localPath: '/tmp/original.jpg',
          width: 1000,
          height: 2000,
          parentPhotoId: 'orig-1',
          cropXpct: 0.25,
          cropWidthPct: 0.5,
        );
        final notifier = container.read(activeViewProvider.notifier);
        notifier.showSlice(slice);
        expect(container.read(activeViewProvider)!.isOriginal, isFalse);

        notifier.showOriginal('orig-1');
        expect(container.read(activeViewProvider)!.isOriginal, isTrue);
      },
    );
  });
}
