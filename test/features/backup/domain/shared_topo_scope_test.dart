// W-1: the shared feed used to be unbounded and global — `.eq('visibility',
// 'shared')` with no limit, no geo scope, no pagination, then every row
// imported into local SQLite. Fine at a hundred topos; at ten thousand it
// downloads the world onto a phone at a crag.
//
// The tests that matter most are the ones about what must NOT be dropped.
// Bounding a fetch is easy; bounding it without making a whole class of topos
// permanently invisible is the actual job.

import 'package:flutter_test/flutter_test.dart';
import 'package:masi/features/backup/domain/shared_topo_scope.dart';

const _chamonix = (latitude: 45.92, longitude: 6.87);

void main() {
  group('bounding box', () {
    test('no anchor means no box — a capped fetch, not an empty one', () {
      expect(const SharedTopoScope().boundingBox, isNull);
    });

    test('the box contains the anchor', () {
      final box = const SharedTopoScope(anchor: _chamonix).boundingBox!;
      expect(box.minLatitude, lessThan(_chamonix.latitude));
      expect(box.maxLatitude, greaterThan(_chamonix.latitude));
      expect(box.minLongitude, lessThan(_chamonix.longitude));
      expect(box.maxLongitude, greaterThan(_chamonix.longitude));
    });

    test('a 250 km radius spans roughly 4.5 degrees of latitude', () {
      final box = const SharedTopoScope(anchor: _chamonix).boundingBox!;
      expect(box.maxLatitude - box.minLatitude, closeTo(4.49, 0.05));
    });

    test(
      'the longitude window is WIDER than the latitude one away from the '
      'equator — a degree of longitude is shorter there, so an equal-degree '
      'box would reach less far east/west than north/south',
      () {
        final box = const SharedTopoScope(anchor: _chamonix).boundingBox!;
        final latSpan = box.maxLatitude - box.minLatitude;
        final lngSpan = box.maxLongitude - box.minLongitude;
        expect(lngSpan, greaterThan(latSpan));
      },
    );

    test('latitude CLAMPS at the poles rather than running past them', () {
      final box = const SharedTopoScope(
        anchor: (latitude: 89.0, longitude: 0.0),
        radiusKm: 500,
      ).boundingBox;
      // Near the pole the longitude window blows past 180 and the box is
      // dropped entirely (see the wrap test) — which is the correct, safe
      // outcome. What must never happen is a latitude above 90.
      if (box != null) {
        expect(box.maxLatitude, lessThanOrEqualTo(90.0));
        expect(box.minLatitude, greaterThanOrEqualTo(-90.0));
      }
    });

    test(
      'a window that WRAPS the antimeridian yields no box at all. It cannot be '
      'written as one min<=x<=max pair, and an unsplit wrapped box would '
      'silently return NOTHING for anyone near the dateline',
      () {
        final box = const SharedTopoScope(
          anchor: (latitude: -17.6, longitude: 179.9), // Fiji
        ).boundingBox;
        expect(box, isNull);
      },
    );

    test('an unbounded scope has no box and no caps', () {
      const scope = SharedTopoScope.unbounded();
      expect(scope.boundingBox, isNull);
      expect(scope.isUnbounded, isTrue);
      expect(scope.limit, 0);
    });

    test('a zero or negative radius yields no box rather than a degenerate one', () {
      expect(
        const SharedTopoScope(anchor: _chamonix, radiusKm: 0).boundingBox,
        isNull,
      );
      expect(
        const SharedTopoScope(anchor: _chamonix, radiusKm: -5).boundingBox,
        isNull,
      );
    });

    test('the default cap is in force even with an anchor', () {
      expect(const SharedTopoScope(anchor: _chamonix).limit, kSharedTopoLimit);
      expect(
        const SharedTopoScope(anchor: _chamonix).uncoordinatedLimit,
        kSharedTopoUncoordinatedLimit,
      );
    });

    test(
      'topos WITHOUT coordinates get their own budget. Without one they are '
      'either dropped forever — a worse bug than the unbounded fetch — or free '
      'to consume the whole limit. 1 published wall in 10 has no coordinates',
      () {
        expect(kSharedTopoUncoordinatedLimit, greaterThan(0));
        expect(kSharedTopoUncoordinatedLimit, lessThan(kSharedTopoLimit));
      },
    );
  });

  group('choosing an anchor', () {
    test('no candidates means no anchor', () {
      expect(anchorFromOwnWalls(const []), isNull);
    });

    test('walls without coordinates are ignored', () {
      expect(
        anchorFromOwnWalls(const [
          (updatedAt: 5, latitude: null, longitude: null),
          (updatedAt: 4, latitude: 45.0, longitude: null),
        ]),
        isNull,
      );
    });

    test(
      'the MOST RECENTLY UPDATED wall wins, not the centroid. A climber with '
      'crags in Italy and Norway has a centroid in Germany, and a radius '
      'around it reaches neither place they actually climb',
      () {
        final anchor = anchorFromOwnWalls(const [
          (updatedAt: 100, latitude: 45.4, longitude: 9.2), // Italy, older
          (updatedAt: 900, latitude: 59.9, longitude: 10.7), // Norway, newer
        ]);
        expect(anchor, isNotNull);
        expect(anchor!.latitude, 59.9);
        expect(anchor.longitude, 10.7);
      },
    );

    test('an out-of-range or NaN coordinate is skipped, not anchored on', () {
      final anchor = anchorFromOwnWalls(const [
        (updatedAt: 900, latitude: 91.0, longitude: 10.0),
        (updatedAt: 800, latitude: double.nan, longitude: 10.0),
        (updatedAt: 700, latitude: 45.0, longitude: 7.0),
      ]);
      expect(anchor!.latitude, 45.0);
    });

    test('a single valid wall anchors on itself', () {
      final anchor = anchorFromOwnWalls(const [
        (updatedAt: 1, latitude: 45.92, longitude: 6.87),
      ]);
      expect(anchor, _chamonix);
    });
  });
}
