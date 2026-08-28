import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:masi/features/topo/presentation/thumbnail_arrangement.dart';

/// The one property the layout screen lives or dies by: **no two thumbnails
/// overlap**. It shipped without this and the four photos of a boulder landed
/// in a single unreadable pile at the centre of the ring.
void main() {
  const canvas = Size(360, 240);
  const thumbnail = Size(64, 48);

  void expectNoOverlap(List<ThumbnailSlot> slots) {
    for (var i = 0; i < slots.length; i++) {
      for (var j = i + 1; j < slots.length; j++) {
        final a = slots[i].rect;
        final b = slots[j].rect;
        expect(
          a.overlaps(b),
          isFalse,
          reason: 'slot ${slots[i].id} at $a overlaps ${slots[j].id} at $b',
        );
      }
    }
  }

  void expectInBounds(List<ThumbnailSlot> slots) {
    for (final slot in slots) {
      expect(slot.rect.left, greaterThanOrEqualTo(-0.001));
      expect(slot.rect.top, greaterThanOrEqualTo(-0.001));
      expect(slot.rect.right, lessThanOrEqualTo(canvas.width + 0.001));
      expect(slot.rect.bottom, lessThanOrEqualTo(canvas.height + 0.001));
    }
  }

  group('arrangeThumbnails', () {
    test('separates four faces whose normals all converge on one point', () {
      // A ring traced the "wrong" way: every normal points at the centre, so
      // the naive placement puts all four thumbnails within a few pixels of
      // each other. This is the exact shape of the reported bug.
      const centre = Offset(180, 120);
      final anchors = <ThumbnailAnchor>[
        for (final direction in const [
          Offset(0, -1),
          Offset(1, 0),
          Offset(0, 1),
          Offset(-1, 0),
        ])
          ThumbnailAnchor(
            id: '${direction.dx},${direction.dy}',
            base: centre - direction * 70,
            direction: direction,
          ),
      ];

      final slots = arrangeThumbnails(
        anchors: anchors,
        canvas: canvas,
        thumbnail: thumbnail,
      );

      expect(slots.length, 4);
      expectNoOverlap(slots);
      expectInBounds(slots);
    });

    test('separates a dense strip whose normals are all parallel', () {
      // Six photos on a 300px line sit 60px apart — closer than a thumbnail
      // is wide, so every neighbour collides before anything is resolved.
      final anchors = <ThumbnailAnchor>[
        for (var i = 0; i < 6; i++)
          ThumbnailAnchor(
            id: 'face-$i',
            base: Offset(30 + i * 60.0, 180),
            direction: const Offset(0, -1),
          ),
      ];

      final slots = arrangeThumbnails(
        anchors: anchors,
        canvas: canvas,
        thumbnail: thumbnail,
      );

      expectNoOverlap(slots);
      expectInBounds(slots);
    });

    test('separates thumbnails whose anchors are exactly coincident', () {
      // Degenerate on purpose: identical bases AND identical directions give
      // the solver a zero delta to separate along, which is where a naive
      // implementation divides by zero or loops forever.
      final anchors = <ThumbnailAnchor>[
        for (var i = 0; i < 3; i++)
          ThumbnailAnchor(
            id: 'same-$i',
            base: const Offset(180, 200),
            direction: const Offset(0, -1),
          ),
      ];

      final slots = arrangeThumbnails(
        anchors: anchors,
        canvas: canvas,
        thumbnail: thumbnail,
      );

      expectNoOverlap(slots);
      expectInBounds(slots);
    });

    test('treats a zero direction as straight up rather than as nowhere', () {
      final slots = arrangeThumbnails(
        anchors: const [
          ThumbnailAnchor(
            id: 'a',
            base: Offset(180, 200),
            direction: Offset.zero,
          ),
        ],
        canvas: canvas,
        thumbnail: thumbnail,
        stem: 52,
      );

      expect(slots.single.centre.dx, closeTo(180, 0.001));
      expect(slots.single.centre.dy, lessThan(200));
    });

    test('keeps each thumbnail near the face it belongs to', () {
      // Separation must not turn into a reshuffle: a thumbnail dragged across
      // the canvas to avoid a collision would be attached to the wrong dot as
      // far as the reader is concerned.
      final anchors = <ThumbnailAnchor>[
        for (var i = 0; i < 4; i++)
          ThumbnailAnchor(
            id: 'face-$i',
            base: Offset(40 + i * 90.0, 200),
            direction: const Offset(0, -1),
          ),
      ];

      final slots = arrangeThumbnails(
        anchors: anchors,
        canvas: canvas,
        thumbnail: thumbnail,
      );

      for (final slot in slots) {
        expect((slot.centre - slot.base).distance, lessThan(140));
      }
      // Wide enough apart to need no shuffling at all — order is preserved.
      final xs = [for (final s in slots) s.centre.dx];
      expect(xs, orderedEquals(<Object>[...xs]..sort()));
    });

    test('is deterministic', () {
      List<ThumbnailSlot> run() => arrangeThumbnails(
        anchors: <ThumbnailAnchor>[
          for (var i = 0; i < 5; i++)
            ThumbnailAnchor(
              id: 'f$i',
              base: Offset(50 + i * 20.0, 150),
              direction: const Offset(0, -1),
            ),
        ],
        canvas: canvas,
        thumbnail: thumbnail,
      );

      final a = run();
      final b = run();
      for (var i = 0; i < a.length; i++) {
        expect(a[i].centre, b[i].centre);
      }
    });

    test('returns nothing for no faces', () {
      expect(
        arrangeThumbnails(anchors: const [], canvas: canvas),
        isEmpty,
      );
    });
  });

  group('leaderEnd', () {
    test('stops at the edge of the thumbnail, not at its centre', () {
      final rect = Rect.fromCenter(
        center: const Offset(100, 100),
        width: 64,
        height: 48,
      );
      final end = leaderEnd(const Offset(100, 200), rect)!;
      expect(end.dx, closeTo(100, 0.001));
      expect(end.dy, closeTo(rect.bottom, 0.001));
    });

    test('draws nothing when the dot is already under the thumbnail', () {
      final rect = Rect.fromCenter(
        center: const Offset(100, 100),
        width: 64,
        height: 48,
      );
      expect(leaderEnd(const Offset(105, 98), rect), isNull);
    });
  });
}
