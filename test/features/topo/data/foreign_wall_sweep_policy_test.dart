// Pure policy test — no drift, no network, no clock. `ForeignWallSweepPolicy`
// decides which cached FOREIGN walls (and their now-childless foreign
// ancestors) are safe to hard-delete once the server has confirmed, via a
// per-id probe, that it no longer shows them. The property every group here
// ultimately serves: a wall that might be the signed-in user's own, or that
// the user has their own data attached to, must NEVER come back from
// `wallIdsToPurge`, under any input — including an empty/never-probed set,
// which must purge nothing rather than being read as "everything is gone".
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/features/topo/data/foreign_wall_sweep_policy.dart';

const _policy = ForeignWallSweepPolicy();
const _me = 'uid-me';
const _stranger = 'uid-stranger';

void main() {
  group('wallIdsToPurge — the safety net', () {
    test(
      'a foreign wall absent from the confirmed-visible set IS purged',
      () {
        final walls = [
          const LocalWallFact(id: 'w1', sectorId: 's1', ownerId: _stranger),
        ];

        final purge = _policy.wallIdsToPurge(
          localWalls: walls,
          ownUid: _me,
          probedWallIds: {'w1'},
          confirmedVisibleWallIds: {},
          ownDataWallIds: {},
        );

        expect(purge, {'w1'});
      },
    );

    test('a foreign wall PRESENT in the confirmed-visible set is not purged', () {
      final walls = [
        const LocalWallFact(id: 'w1', sectorId: 's1', ownerId: _stranger),
      ];

      final purge = _policy.wallIdsToPurge(
        localWalls: walls,
        ownUid: _me,
        probedWallIds: {'w1'},
        confirmedVisibleWallIds: {'w1'},
        ownDataWallIds: {},
      );

      expect(purge, isEmpty);
    });

    test(
      'an OWN wall (ownerId == ownUid) is NEVER purged, even if absent from '
      'the confirmed-visible set and validly probed — the single most '
      'safety-critical assertion in this file',
      () {
        final walls = [
          const LocalWallFact(id: 'w1', sectorId: 's1', ownerId: _me),
        ];

        final purge = _policy.wallIdsToPurge(
          localWalls: walls,
          ownUid: _me,
          probedWallIds: {'w1'},
          confirmedVisibleWallIds: {},
          ownDataWallIds: {},
        );

        expect(purge, isEmpty);
      },
    );

    test(
      'a wall with ownerId == null (unclaimed pre-sync data) is never '
      'purged, however it is probed',
      () {
        final walls = [
          const LocalWallFact(id: 'w1', sectorId: 's1', ownerId: null),
        ];

        final purge = _policy.wallIdsToPurge(
          localWalls: walls,
          ownUid: _me,
          probedWallIds: {'w1'},
          confirmedVisibleWallIds: {},
          ownDataWallIds: {},
        );

        expect(purge, isEmpty);
      },
    );

    test(
      'a foreign wall the user has an own ascent/comment/like on is never '
      'purged, even though the server confirmed it gone',
      () {
        final walls = [
          const LocalWallFact(id: 'w1', sectorId: 's1', ownerId: _stranger),
        ];

        final purge = _policy.wallIdsToPurge(
          localWalls: walls,
          ownUid: _me,
          probedWallIds: {'w1'},
          confirmedVisibleWallIds: {},
          ownDataWallIds: {'w1'},
        );

        expect(purge, isEmpty);
      },
    );

    test(
      'an EMPTY probed set purges NOTHING — every candidate fails the '
      '"validly probed" test and is kept, which is what makes "nothing was '
      'trustworthily asked" degrade to a no-op instead of a mass purge',
      () {
        final walls = [
          const LocalWallFact(id: 'w1', sectorId: 's1', ownerId: _stranger),
          const LocalWallFact(id: 'w2', sectorId: 's1', ownerId: _stranger),
        ];

        final purge = _policy.wallIdsToPurge(
          localWalls: walls,
          ownUid: _me,
          probedWallIds: {},
          confirmedVisibleWallIds: {},
          ownDataWallIds: {},
        );

        expect(purge, isEmpty);
      },
    );

    test(
      'a candidate never validly probed (e.g. its chunk was distrusted) is '
      'kept even though it is absent from the visible set',
      () {
        final walls = [
          const LocalWallFact(id: 'w1', sectorId: 's1', ownerId: _stranger),
          const LocalWallFact(id: 'w2', sectorId: 's1', ownerId: _stranger),
        ];

        // Only w1 was validly probed; w2's chunk was distrusted and never
        // added to `probedWallIds` by the caller.
        final purge = _policy.wallIdsToPurge(
          localWalls: walls,
          ownUid: _me,
          probedWallIds: {'w1'},
          confirmedVisibleWallIds: {},
          ownDataWallIds: {},
        );

        expect(purge, {'w1'});
      },
    );

    test('mixed set: only the genuinely-purgeable wall comes back', () {
      final walls = [
        const LocalWallFact(id: 'own', sectorId: 's1', ownerId: _me),
        const LocalWallFact(id: 'unclaimed', sectorId: 's1', ownerId: null),
        const LocalWallFact(id: 'still-visible', sectorId: 's1', ownerId: _stranger),
        const LocalWallFact(id: 'own-data', sectorId: 's1', ownerId: _stranger),
        const LocalWallFact(id: 'unprobed', sectorId: 's1', ownerId: _stranger),
        const LocalWallFact(id: 'gone', sectorId: 's1', ownerId: _stranger),
      ];

      final purge = _policy.wallIdsToPurge(
        localWalls: walls,
        ownUid: _me,
        probedWallIds: {'still-visible', 'own-data', 'gone'},
        confirmedVisibleWallIds: {'still-visible'},
        ownDataWallIds: {'own-data'},
      );

      expect(purge, {'gone'});
    });
  });

  group('isChunkResponseSuspicious', () {
    test('a non-empty response is never suspicious, however small the ask', () {
      expect(
        isChunkResponseSuspicious(askedCount: 1000, returnedCount: 1),
        isFalse,
      );
    });

    test('an empty response to a small (below-threshold) ask is trusted', () {
      expect(
        isChunkResponseSuspicious(
          askedCount: kChunkSuspicionMinAsked - 1,
          returnedCount: 0,
        ),
        isFalse,
      );
    });

    test(
      'an empty response to a non-trivial ask (at/above threshold) is '
      'suspicious — this is what protects against an auth/RLS blip reading '
      'as "everything is gone"',
      () {
        expect(
          isChunkResponseSuspicious(
            askedCount: kChunkSuspicionMinAsked,
            returnedCount: 0,
          ),
          isTrue,
        );
      },
    );
  });

  group('ownDataWallIds', () {
    test('an own ascent directly on the wall protects it', () {
      final protectedIds = _policy.ownDataWallIds(
        ownUid: _me,
        ascents: [(wallId: 'w1', ownerId: _me)],
        comments: const [],
        likes: const [],
        wallIdByAscentId: const {},
      );

      expect(protectedIds, {'w1'});
    });

    test('a foreign ascent on the wall does NOT protect it', () {
      final protectedIds = _policy.ownDataWallIds(
        ownUid: _me,
        ascents: [(wallId: 'w1', ownerId: _stranger)],
        comments: const [],
        likes: const [],
        wallIdByAscentId: const {},
      );

      expect(protectedIds, isEmpty);
    });

    test('an own wall-attached comment protects the wall', () {
      final protectedIds = _policy.ownDataWallIds(
        ownUid: _me,
        ascents: const [],
        comments: [(wallId: 'w1', ascentId: null, ownerId: _me)],
        likes: const [],
        wallIdByAscentId: const {},
      );

      expect(protectedIds, {'w1'});
    });

    test(
      'an own like on an ASCENT attached to the wall protects the wall, '
      'resolved via wallIdByAscentId',
      () {
        final protectedIds = _policy.ownDataWallIds(
          ownUid: _me,
          ascents: const [],
          comments: const [],
          likes: [(wallId: null, ascentId: 'a1', ownerId: _me)],
          wallIdByAscentId: const {'a1': 'w1'},
        );

        expect(protectedIds, {'w1'});
      },
    );

    test(
      'an ascent-attached like whose ascent id is unresolved protects '
      'nothing rather than throwing',
      () {
        final protectedIds = _policy.ownDataWallIds(
          ownUid: _me,
          ascents: const [],
          comments: const [],
          likes: [(wallId: null, ascentId: 'a1', ownerId: _me)],
          wallIdByAscentId: const {},
        );

        expect(protectedIds, isEmpty);
      },
    );

    test('a foreign comment/like is never counted, even wall-attached', () {
      final protectedIds = _policy.ownDataWallIds(
        ownUid: _me,
        ascents: const [],
        comments: [(wallId: 'w1', ascentId: null, ownerId: _stranger)],
        likes: [(wallId: 'w2', ascentId: null, ownerId: _stranger)],
        wallIdByAscentId: const {},
      );

      expect(protectedIds, isEmpty);
    });
  });

  group('childlessForeignSectorIds', () {
    test('a foreign sector with no surviving wall is collected', () {
      final sectors = [
        const LocalSectorFact(id: 's1', areaId: 'a1', ownerId: _stranger),
      ];
      final walls = [
        const LocalWallFact(id: 'w1', sectorId: 's1', ownerId: _stranger),
      ];

      final childless = _policy.childlessForeignSectorIds(
        localSectors: sectors,
        localWalls: walls,
        ownUid: _me,
        purgedWallIds: {'w1'},
      );

      expect(childless, {'s1'});
    });

    test('a sector still holding a surviving (non-purged) wall is NOT collected', () {
      final sectors = [
        const LocalSectorFact(id: 's1', areaId: 'a1', ownerId: _stranger),
      ];
      final walls = [
        const LocalWallFact(id: 'w1', sectorId: 's1', ownerId: _stranger),
        const LocalWallFact(id: 'w2', sectorId: 's1', ownerId: _stranger),
      ];

      final childless = _policy.childlessForeignSectorIds(
        localSectors: sectors,
        localWalls: walls,
        ownUid: _me,
        purgedWallIds: {'w1'}, // w2 survives.
      );

      expect(childless, isEmpty);
    });

    test('an OWN sector is never collected, even if childless', () {
      final sectors = [
        const LocalSectorFact(id: 's1', areaId: 'a1', ownerId: _me),
      ];
      final walls = [
        const LocalWallFact(id: 'w1', sectorId: 's1', ownerId: _stranger),
      ];

      final childless = _policy.childlessForeignSectorIds(
        localSectors: sectors,
        localWalls: walls,
        ownUid: _me,
        purgedWallIds: {'w1'},
      );

      expect(childless, isEmpty);
    });

    test('an unclaimed (ownerId == null) sector is never collected', () {
      final sectors = [
        const LocalSectorFact(id: 's1', areaId: 'a1', ownerId: null),
      ];
      final walls = [
        const LocalWallFact(id: 'w1', sectorId: 's1', ownerId: _stranger),
      ];

      final childless = _policy.childlessForeignSectorIds(
        localSectors: sectors,
        localWalls: walls,
        ownUid: _me,
        purgedWallIds: {'w1'},
      );

      expect(childless, isEmpty);
    });
  });

  group('childlessForeignAreaIds', () {
    test('a foreign area with no surviving sector is collected', () {
      final areas = [const LocalAreaFact(id: 'a1', ownerId: _stranger)];
      final sectors = [
        const LocalSectorFact(id: 's1', areaId: 'a1', ownerId: _stranger),
      ];

      final childless = _policy.childlessForeignAreaIds(
        localAreas: areas,
        localSectors: sectors,
        ownUid: _me,
        purgedSectorIds: {'s1'},
      );

      expect(childless, {'a1'});
    });

    test('an area still holding a surviving sector is NOT collected', () {
      final areas = [const LocalAreaFact(id: 'a1', ownerId: _stranger)];
      final sectors = [
        const LocalSectorFact(id: 's1', areaId: 'a1', ownerId: _stranger),
        const LocalSectorFact(id: 's2', areaId: 'a1', ownerId: _stranger),
      ];

      final childless = _policy.childlessForeignAreaIds(
        localAreas: areas,
        localSectors: sectors,
        ownUid: _me,
        purgedSectorIds: {'s1'}, // s2 survives.
      );

      expect(childless, isEmpty);
    });

    test('an OWN area is never collected, even if childless', () {
      final areas = [const LocalAreaFact(id: 'a1', ownerId: _me)];
      final sectors = [
        const LocalSectorFact(id: 's1', areaId: 'a1', ownerId: _stranger),
      ];

      final childless = _policy.childlessForeignAreaIds(
        localAreas: areas,
        localSectors: sectors,
        ownUid: _me,
        purgedSectorIds: {'s1'},
      );

      expect(childless, isEmpty);
    });
  });
}
