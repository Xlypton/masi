// Coverage for `routeCropRect` — the maths that decides which part of a topo
// photo an ascent row shows.
//
// The property that actually matters, and the one worth stating up front: the
// returned rect must be SQUARE IN PIXELS, not in normalized space. Normalized
// coordinates are per-axis, so a 0.3 x 0.3 normalized crop of a 1000x2000
// photo is 300x600 real pixels — drawing that into a square tile squashes the
// climber. Almost every test below is a way of pinning that.

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:masi/features/community/domain/route_crop.dart';

void main() {
  /// The crop's width and height in PIXELS, which is the space the squareness
  /// invariant lives in.
  ({double width, double height}) pixels(Rect crop, int w, int h) =>
      (width: crop.width * w, height: crop.height * h);

  group('framing', () {
    test('a crop is square in pixels even on a very tall photo', () {
      final crop = routeCropRect(
        points: const [Offset(0.4, 0.3), Offset(0.5, 0.7)],
        imageWidth: 1000,
        imageHeight: 2000,
      )!;

      final px = pixels(crop, 1000, 2000);
      expect(px.width, moreOrLessEquals(px.height, epsilon: 0.001));
      // And NOT square in normalized space — which is what a naive
      // implementation would produce, and what would look correct in a test
      // that only checked `crop.width == crop.height`.
      expect(crop.width, isNot(closeTo(crop.height, 0.001)));
    });

    test('a crop is square in pixels on a very wide photo too', () {
      final crop = routeCropRect(
        points: const [Offset(0.2, 0.45), Offset(0.6, 0.55)],
        imageWidth: 4000,
        imageHeight: 1000,
      )!;

      final px = pixels(crop, 4000, 1000);
      expect(px.width, moreOrLessEquals(px.height, epsilon: 0.001));
    });

    test('the crop is centred on the route it frames', () {
      final crop = routeCropRect(
        points: const [Offset(0.4, 0.4), Offset(0.6, 0.6)],
        imageWidth: 1000,
        imageHeight: 1000,
      )!;

      expect(crop.center.dx, moreOrLessEquals(0.5, epsilon: 0.001));
      expect(crop.center.dy, moreOrLessEquals(0.5, epsilon: 0.001));
    });

    test('padding leaves context around the line, not a tight bound', () {
      final crop = routeCropRect(
        points: const [Offset(0.3, 0.3), Offset(0.7, 0.7)],
        imageWidth: 1000,
        imageHeight: 1000,
        padFraction: 0.25,
        // Out of the way, so this test measures padding alone.
        minFraction: 0.0,
      )!;

      // Extent 0.4, plus 25% of it on each side.
      expect(crop.width, moreOrLessEquals(0.4 * 1.5, epsilon: 0.001));
    });
  });

  group('the resolution floor', () {
    test(
      'a single-point route does not collapse to nothing — a bouldering topo '
      'marked with one tap still gets a frame',
      () {
        final crop = routeCropRect(
          points: const [Offset(0.5, 0.5)],
          imageWidth: 1000,
          imageHeight: 1000,
        )!;

        expect(crop.width, greaterThan(0));
        expect(crop.width, moreOrLessEquals(kRouteCropMinFraction, epsilon: 0.001));
      },
    );

    test(
      'a very short route is not magnified past what the 512px thumbnail can '
      'support',
      () {
        final crop = routeCropRect(
          points: const [Offset(0.50, 0.50), Offset(0.51, 0.51)],
          imageWidth: 1000,
          imageHeight: 1000,
        )!;

        expect(
          crop.width,
          greaterThanOrEqualTo(kRouteCropMinFraction - 0.001),
        );
      },
    );
  });

  group('staying inside the photo', () {
    test('a route along the top-left corner yields an in-bounds frame', () {
      final crop = routeCropRect(
        points: const [Offset(0.0, 0.0), Offset(0.05, 0.05)],
        imageWidth: 1000,
        imageHeight: 1000,
      )!;

      expect(crop.left, greaterThanOrEqualTo(-0.0001));
      expect(crop.top, greaterThanOrEqualTo(-0.0001));
      expect(crop.right, lessThanOrEqualTo(1.0001));
      expect(crop.bottom, lessThanOrEqualTo(1.0001));
    });

    test('a route along the bottom-right corner does too', () {
      final crop = routeCropRect(
        points: const [Offset(0.98, 0.98), Offset(1.0, 1.0)],
        imageWidth: 1000,
        imageHeight: 1000,
      )!;

      expect(crop.left, greaterThanOrEqualTo(-0.0001));
      expect(crop.right, lessThanOrEqualTo(1.0001));
      expect(crop.bottom, lessThanOrEqualTo(1.0001));
    });

    test(
      'an edge route slides into bounds rather than shrinking — the frame '
      'keeps the size the resolution floor asked for, and only its position '
      'gives',
      () {
        final centred = routeCropRect(
          points: const [Offset(0.5, 0.5)],
          imageWidth: 1000,
          imageHeight: 1000,
        )!;
        final edge = routeCropRect(
          points: const [Offset(0.0, 0.5)],
          imageWidth: 1000,
          imageHeight: 1000,
        )!;

        expect(edge.width, moreOrLessEquals(centred.width, epsilon: 0.001));
        expect(edge.left, moreOrLessEquals(0.0, epsilon: 0.001));
      },
    );

    test(
      'a route spanning a whole tall photo cannot be framed square at full '
      'height, so the square is capped at the SHORTER side and stays inside',
      () {
        final crop = routeCropRect(
          points: const [Offset(0.5, 0.0), Offset(0.5, 1.0)],
          imageWidth: 1000,
          imageHeight: 3000,
        )!;

        final px = pixels(crop, 1000, 3000);
        expect(px.width, moreOrLessEquals(1000, epsilon: 0.001));
        expect(px.height, moreOrLessEquals(1000, epsilon: 0.001));
        expect(crop.left, moreOrLessEquals(0.0, epsilon: 0.001));
        expect(crop.right, moreOrLessEquals(1.0, epsilon: 0.001));
      },
    );

    test('out-of-range points are clamped rather than trusted', () {
      final crop = routeCropRect(
        points: const [Offset(-0.5, -2.0), Offset(1.5, 3.0)],
        imageWidth: 1000,
        imageHeight: 1000,
      )!;

      expect(crop.left, greaterThanOrEqualTo(-0.0001));
      expect(crop.top, greaterThanOrEqualTo(-0.0001));
      expect(crop.right, lessThanOrEqualTo(1.0001));
      expect(crop.bottom, lessThanOrEqualTo(1.0001));
    });
  });

  group('nothing to frame', () {
    test('no points yields null — the caller falls back, it does not throw', () {
      expect(
        routeCropRect(points: const [], imageWidth: 1000, imageHeight: 1000),
        isNull,
      );
    });

    test('a photo with no recorded dimensions yields null', () {
      const points = [Offset(0.5, 0.5)];
      expect(
        routeCropRect(points: points, imageWidth: 0, imageHeight: 1000),
        isNull,
      );
      expect(
        routeCropRect(points: points, imageWidth: 1000, imageHeight: 0),
        isNull,
      );
      expect(
        routeCropRect(points: points, imageWidth: -1, imageHeight: -1),
        isNull,
      );
    });
  });

  group('the property the widget depends on', () {
    test(
      'scaling the photo by 1/crop always reproduces the photo\'s own aspect '
      'ratio — this is what makes BoxFit.fill safe in AscentRouteThumbnail, '
      'and a non-square-in-pixels crop would break it silently',
      () {
        const cases = [
          (1000, 2000),
          (2000, 1000),
          (1000, 1000),
          (3024, 4032),
          (4032, 3024),
        ];
        for (final (w, h) in cases) {
          final crop = routeCropRect(
            points: const [Offset(0.35, 0.2), Offset(0.55, 0.8)],
            imageWidth: w,
            imageHeight: h,
          )!;
          const tile = 52.0;
          final scaledWidth = tile / crop.width;
          final scaledHeight = tile / crop.height;

          expect(
            scaledWidth / scaledHeight,
            moreOrLessEquals(w / h, epsilon: 0.001),
            reason: 'aspect must be preserved for a ${w}x$h photo',
          );
        }
      },
    );
  });
}
