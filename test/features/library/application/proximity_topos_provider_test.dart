// Unit tests for `proximity_topos_provider.dart`'s pure logic: `haversineKm`
// in isolation, then `mergeAndSortByProximity` (the merge/sort/de-dup core
// behind `sortedByProximityToposProvider`) directly against fake `TopoRef`/
// `SharedTopo` values — no `ProviderContainer`/database needed, per the
// provider's doc recommending this pure-function factoring over wiring a
// container (avoids flakiness around the underlying Drift/location streams).
import 'package:climbtopo/features/community/data/community_repository.dart';
import 'package:climbtopo/features/library/application/proximity_topos_provider.dart';
import 'package:climbtopo/features/library/data/library_crud_repository.dart';
import 'package:flutter_test/flutter_test.dart';

TopoRef _own(
  String wallId, {
  String? name,
  double? latitude,
  double? longitude,
}) {
  return TopoRef(
    wallId: wallId,
    name: name ?? wallId,
    thumbnailPath: null,
    routeCount: 0,
    createdAt: 1000,
    latitude: latitude,
    longitude: longitude,
  );
}

SharedTopo _community(
  String wallId, {
  String? name,
  double? latitude,
  double? longitude,
}) {
  return SharedTopo(
    wallId: wallId,
    name: name ?? wallId,
    routeCount: 0,
    likeCount: 0,
    commentCount: 0,
    latitude: latitude,
    longitude: longitude,
  );
}

void main() {
  group('haversineKm', () {
    test('is ~0 for identical points', () {
      expect(haversineKm(40.0, -74.0, 40.0, -74.0), closeTo(0.0, 1e-6));
    });

    test('London to Paris is ~344 km', () {
      final km = haversineKm(51.5074, -0.1278, 48.8566, 2.3522);
      expect(km, closeTo(344.0, 15.0));
    });

    test('New York to Los Angeles is ~3936 km', () {
      final km = haversineKm(40.7128, -74.0060, 34.0522, -118.2437);
      expect(km, closeTo(3936.0, 100.0));
    });
  });

  group('mergeAndSortByProximity', () {
    test(
      'no location fix: falls back to own topos in original order, all '
      'distances null, community entirely omitted (even a coordinate match)',
      () {
        final own = [
          _own('a', latitude: null, longitude: null),
          _own('b', latitude: 10.0, longitude: 10.0),
          _own('c', latitude: null, longitude: null),
        ];
        final community = [_community('near', latitude: 10.0, longitude: 10.0)];

        final result = mergeAndSortByProximity(
          own: own,
          community: community,
          fix: null,
        );

        expect(result.map((e) => e.wallId).toList(), ['a', 'b', 'c']);
        expect(result.every((e) => e.distanceKm == null), isTrue);
        expect(
          result.every((e) => e.source == ProximityTopoSource.own),
          isTrue,
        );
      },
    );

    test(
      'with a fix: own topos sort nearest-first, null-coordinate topos '
      'sort last in their original relative order',
      () {
        const fix = (latitude: 0.0, longitude: 0.0);
        final own = [
          _own('far', latitude: 0.0, longitude: 5.0), // ~555 km
          _own('none1', latitude: null, longitude: null),
          _own('same', latitude: 0.0, longitude: 0.0), // 0 km
          _own('near', latitude: 0.0, longitude: 1.0), // ~111 km
          _own('none2', latitude: null, longitude: null),
        ];

        final result = mergeAndSortByProximity(
          own: own,
          community: const [],
          fix: fix,
        );

        expect(result.map((e) => e.wallId).toList(), [
          'same',
          'near',
          'far',
          'none1',
          'none2',
        ]);
        expect(result[0].distanceKm, closeTo(0.0, 1e-6));
        expect(result[1].distanceKm, closeTo(111.19, 1.0));
        expect(result[2].distanceKm, closeTo(555.97, 5.0));
        expect(result[3].distanceKm, isNull);
        expect(result[4].distanceKm, isNull);
      },
    );

    test(
      'community de-dup + radius: a far community topo is excluded, a '
      'near one is included, and one colliding with an own wallId is '
      'de-duped to the own entry',
      () {
        const fix = (latitude: 0.0, longitude: 0.0);
        final own = [_own('w1', latitude: 0.0, longitude: 0.0)];
        final community = [
          // Same wallId as an own topo -- must be de-duped away (own wins).
          _community('w1', latitude: 0.0, longitude: 0.0),
          // ~5560 km away -- outside the default 100 km radius, excluded.
          _community('w2-far', latitude: 0.0, longitude: 50.0),
          // ~55.6 km away -- inside the default radius, included.
          _community('w3-near', latitude: 0.0, longitude: 0.5),
        ];

        final result = mergeAndSortByProximity(
          own: own,
          community: community,
          fix: fix,
        );

        expect(result.map((e) => e.wallId).toList(), ['w1', 'w3-near']);
        expect(result[0].source, ProximityTopoSource.own);
        expect(result[1].source, ProximityTopoSource.community);
        expect(result[1].distanceKm, closeTo(55.66, 2.0));
      },
    );

    test('a custom radiusKm is honored', () {
      const fix = (latitude: 0.0, longitude: 0.0);
      final community = [_community('c1', latitude: 0.0, longitude: 1.0)]; // ~111 km

      final excluded = mergeAndSortByProximity(
        own: const [],
        community: community,
        fix: fix,
        radiusKm: 50.0,
      );
      expect(excluded, isEmpty);

      final included = mergeAndSortByProximity(
        own: const [],
        community: community,
        fix: fix,
        radiusKm: 200.0,
      );
      expect(included.map((e) => e.wallId).toList(), ['c1']);
    });
  });
}
