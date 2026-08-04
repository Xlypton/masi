// Unit tests for `proximity_topos_provider.dart`'s pure logic: `haversineKm`
// in isolation, then `mergeAndSortByProximity` (the merge/sort/de-dup core
// behind `sortedByProximityToposProvider`) directly against fake `TopoRef`/
// `SharedTopo` values — no `ProviderContainer`/database needed, per the
// provider's doc recommending this pure-function factoring over wiring a
// container (avoids flakiness around the underlying Drift/location streams).
import 'package:masi/features/community/data/community_repository.dart';
import 'package:masi/features/library/application/proximity_topos_provider.dart';
import 'package:masi/features/library/data/library_crud_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/features/community/application/community_providers.dart';
import 'package:masi/features/library/application/library_providers.dart';

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
    test('no fix: community still shown (null distance), after own, own topos '
        'in original order, all distances null', () {
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

      expect(result.map((e) => e.wallId).toList(), ['a', 'b', 'c', 'near']);
      expect(result.every((e) => e.distanceKm == null), isTrue);
      expect(
        result
            .where((e) => e.wallId != 'near')
            .every((e) => e.source == ProximityTopoSource.own),
        isTrue,
      );
      expect(
        result.firstWhere((e) => e.wallId == 'near').source,
        ProximityTopoSource.community,
      );
    });

    test('with a fix: own topos sort nearest-first, null-coordinate topos '
        'sort last in their original relative order', () {
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
    });

    test('community shown regardless of distance; still de-dups vs own; '
        'nearest-first', () {
      const fix = (latitude: 0.0, longitude: 0.0);
      final own = [_own('w1', latitude: 0.0, longitude: 0.0)];
      final community = [
        // Same wallId as an own topo -- must be de-duped away (own wins).
        _community('w1', latitude: 0.0, longitude: 0.0),
        // ~5559.75 km away -- far, but no cutoff any more, so included.
        _community('w2-far', latitude: 0.0, longitude: 50.0),
        // ~55.6 km away -- included, and sorts before the far one.
        _community('w3-near', latitude: 0.0, longitude: 0.5),
      ];

      final result = mergeAndSortByProximity(
        own: own,
        community: community,
        fix: fix,
      );

      expect(result.map((e) => e.wallId).toList(), ['w1', 'w3-near', 'w2-far']);
      expect(result[0].source, ProximityTopoSource.own);
      expect(result[1].source, ProximityTopoSource.community);
      expect(result[2].source, ProximityTopoSource.community);
      // haversineKm(0,0, 0,0.5) == 6371.0 * (0.5 * pi/180) exactly (equator
      // arc, dLat == 0) == 55.597463222279... km.
      expect(result[1].distanceKm, closeTo(55.5975, 0.01));
      // haversineKm(0,0, 0,50) == 6371.0 * (50 * pi/180) exactly ==
      // 5559.746322227937... km.
      expect(result[2].distanceKm, closeTo(5559.7463, 0.01));
    });

    test('community is capped at kMaxCommunityTopos, keeping the nearest when '
        'a fix is available', () {
      const fix = (latitude: 0.0, longitude: 0.0);
      // 25 community topos at increasing longitude (and thus increasing
      // distance from the fix at the equator): c1 nearest, c25 farthest.
      final community = [
        for (var i = 1; i <= 25; i++)
          _community('c$i', latitude: 0.0, longitude: i.toDouble()),
      ];

      final result = mergeAndSortByProximity(
        own: const [],
        community: community,
        fix: fix,
      );

      expect(result.length, 20);
      expect(
        result.every((e) => e.source == ProximityTopoSource.community),
        isTrue,
      );
      expect(result.map((e) => e.wallId).toList(), [
        for (var i = 1; i <= 20; i++) 'c$i',
      ]);
      expect(result.any((e) => e.wallId == 'c1'), isTrue);
      expect(result.any((e) => e.wallId == 'c25'), isFalse);
      for (var i = 1; i < result.length; i++) {
        expect(result[i].distanceKm! >= result[i - 1].distanceKm!, isTrue);
      }

      final capped = mergeAndSortByProximity(
        own: const [],
        community: community,
        fix: fix,
        maxCommunity: 2,
      );
      expect(capped.map((e) => e.wallId).toList(), ['c1', 'c2']);
    });

    test('no fix: community still shown, null distance, feed order preserved, '
        'capped at maxCommunity', () {
      final community = [
        _community('c1', latitude: 10.0, longitude: 10.0),
        _community('c2', latitude: 20.0, longitude: 20.0),
      ];

      final result = mergeAndSortByProximity(
        own: const [],
        community: community,
        fix: null,
      );

      expect(result.map((e) => e.wallId).toList(), ['c1', 'c2']);
      expect(
        result.every((e) => e.source == ProximityTopoSource.community),
        isTrue,
      );
      expect(result.every((e) => e.distanceKm == null), isTrue);
    });

    test('own topos are never capped, only the community subset is', () {
      const fix = (latitude: 0.0, longitude: 0.0);
      final own = [
        for (var i = 1; i <= 25; i++)
          _own('own$i', latitude: 0.0, longitude: i.toDouble()),
      ];
      final community = [
        for (var i = 1; i <= 25; i++)
          _community('comm$i', latitude: 0.0, longitude: (i + 100).toDouble()),
      ];

      final result = mergeAndSortByProximity(
        own: own,
        community: community,
        fix: fix,
      );

      expect(
        result.where((e) => e.source == ProximityTopoSource.own).length,
        25,
      );
      expect(
        result.where((e) => e.source == ProximityTopoSource.community).length,
        20,
      );
      expect(result.length, 45);
    });

    test('cap prefers located community topos over coordless ones when a fix '
        'exists', () {
      const fix = (latitude: 0.0, longitude: 0.0);
      final located = [
        for (var i = 1; i <= 21; i++)
          _community('loc$i', latitude: 0.0, longitude: i.toDouble()),
      ];
      final coordless = _community(
        'coordless',
        latitude: null,
        longitude: null,
      );
      final community = [...located, coordless];

      final result = mergeAndSortByProximity(
        own: const [],
        community: community,
        fix: fix,
      );

      expect(result.length, 20);
      expect(
        result.every((e) => e.source == ProximityTopoSource.community),
        isTrue,
      );
      expect(result.every((e) => e.distanceKm != null), isTrue);
      expect(result.any((e) => e.wallId == 'coordless'), isFalse);
    });
  });

  // The provider WIRING, not the pure merge above: `sortedByProximityToposProvider`
  // read its three sources with `.asData?.value`, and `asData` is null for an
  // AsyncLoading that RETAINS its value. `toposProvider` watches
  // effectiveUidProvider, so every auth emission puts it through exactly that
  // state — and the Topos home then rendered "No topos yet" (or "Couldn't sync")
  // over a library that was on screen and non-empty.
  //
  // A container is needed here (unlike the pure tests above) because the bug IS
  // the AsyncValue state, which cannot be synthesised: `copyWithPrevious` is
  // @internal, so the reloading state has to be produced by really rebuilding a
  // provider through a dependency change.
  group('sortedByProximityToposProvider wiring', () {
    test(
      'a DEPENDENCY-CHANGE reload of toposProvider keeps the list on screen',
      () async {
        final container = ProviderContainer(
          overrides: [
            // toposProvider's real body is `watch(effectiveUidProvider)` +
            // a drift stream; this override reproduces exactly that shape —
            // rebuilt by a dependency change — without a database.
            toposProvider.overrideWith((ref) {
              ref.watch(uidKnobProvider);
              return Stream.value([_own('w1'), _own('w2')]);
            }),
            sharedToposProvider.overrideWith(
              (ref) => Stream.value(const <SharedTopo>[]),
            ),
            myLocationProvider.overrideWith((ref) async => null),
          ],
        );
        addTearDown(container.dispose);

        // Keep the derived provider alive across the rebuild, the way a mounted
        // screen does.
        container.listen(sortedByProximityToposProvider, (_, _) {});
        await container.read(toposProvider.future);
        expect(container.read(sortedByProximityToposProvider), hasLength(2));

        // NOT `ref.invalidate(toposProvider)` — that yields an AsyncData whose
        // isLoading is true and whose asData is non-null, so it does not
        // reproduce this at all. A dependency change does.
        container.read(uidKnobProvider.notifier).set('someone-else');

        final reloading = container.read(toposProvider);
        expect(reloading.isLoading, isTrue, reason: 'not a reload at all');
        expect(reloading.hasValue, isTrue, reason: 'the value is not retained');
        expect(
          reloading.asData,
          isNull,
          reason: 'pins WHY asData is the wrong reader here',
        );

        expect(
          container.read(sortedByProximityToposProvider),
          hasLength(2),
          reason: '"No topos yet" over a library that is on screen and full',
        );
      },
    );

    test(
      'an ERRORED toposProvider that still holds a value keeps it',
      () async {
        final container = ProviderContainer(
          retry: (_, _) => null,
          overrides: [
            toposProvider.overrideWith((ref) {
              final uid = ref.watch(uidKnobProvider);
              if (uid == 'boom') {
                return Stream<List<TopoRef>>.error(StateError('boom'));
              }
              return Stream.value([_own('w1')]);
            }),
            sharedToposProvider.overrideWith(
              (ref) => Stream.value(const <SharedTopo>[]),
            ),
            myLocationProvider.overrideWith((ref) async => null),
          ],
        );
        addTearDown(container.dispose);

        container.listen(sortedByProximityToposProvider, (_, _) {});
        await container.read(toposProvider.future);
        expect(container.read(sortedByProximityToposProvider), hasLength(1));

        container.read(uidKnobProvider.notifier).set('boom');
        await Future<void>.delayed(Duration.zero);

        final errored = container.read(toposProvider);
        expect(errored.hasError, isTrue);
        expect(
          container.read(sortedByProximityToposProvider),
          hasLength(1),
          reason: 'a transient auth-stream error must not blank the library',
        );
      },
    );
  });
}

/// Stands in for `effectiveUidProvider` as `toposProvider`'s dependency: a
/// Notifier (never a StateProvider — Riverpod v3) whose change forces the
/// dependency-change rebuild the tests above are about.
class UidKnob extends Notifier<String?> {
  @override
  String? build() => 'me';

  void set(String? uid) => state = uid;
}

final uidKnobProvider = NotifierProvider<UidKnob, String?>(UidKnob.new);
