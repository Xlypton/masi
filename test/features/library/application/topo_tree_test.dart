// Unit tests for `topo_tree.dart`'s `buildToposTree` — the pure tiering core
// behind the Topos home's distance-organized list (nearest topos expanded,
// the rest folded into their Sector, and everything past that folded again
// into their Area).
//
// Direct against fake `TopoRef`/`SharedTopo` values, no `ProviderContainer` or
// database, exactly like `proximity_topos_provider_test.dart` next door and for
// the same reason: the rules being tested are arithmetic over a list, and
// standing up Drift/location streams to check them only adds flakiness.
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/core/grades/grade_system.dart';
import 'package:masi/features/community/data/community_repository.dart';
import 'package:masi/features/library/application/proximity_topos_provider.dart';
import 'package:masi/features/library/application/topo_tree.dart';
import 'package:masi/features/library/data/library_crud_repository.dart';

/// An own-topo entry at [distanceKm], filed under [sectorId]/[areaId].
/// A null `sectorId` models a photo-first topo filed under the hidden
/// `__default__` sentinel — the "cannot be grouped" case.
ProximityTopoEntry _own(
  String wallId, {
  double? distanceKm,
  String? sectorId,
  String? areaId,
  int routeCount = 1,
  List<double> gradeKeys = const [],
  String? thumbnailPath,
}) {
  return ProximityTopoEntry.own(
    TopoRef(
      wallId: wallId,
      name: wallId,
      thumbnailPath: thumbnailPath,
      routeCount: routeCount,
      createdAt: 1000,
      sectorId: sectorId,
      sectorName: sectorId == null ? null : 'Sector $sectorId',
      areaId: areaId,
      areaName: areaId == null ? null : 'Area $areaId',
      routeGradeKeys: gradeKeys,
    ),
    distanceKm: distanceKm,
  );
}

ProximityTopoEntry _community(
  String wallId, {
  double? distanceKm,
  String? sectorId,
  String? areaId,
  int routeCount = 1,
}) {
  return ProximityTopoEntry.community(
    SharedTopo(
      wallId: wallId,
      name: wallId,
      routeCount: routeCount,
      likeCount: 0,
      commentCount: 0,
      sectorId: sectorId,
      sectorName: sectorId == null ? null : 'Sector $sectorId',
      areaId: areaId,
      areaName: areaId == null ? null : 'Area $areaId',
    ),
    distanceKm: distanceKm,
  );
}

/// The wall ids a node stands for, in order — the readable shape of a result.
List<String> _wallIds(ToposNode node) => [for (final t in node.topos) t.wallId];

void main() {
  group('buildToposTree — expanded head', () {
    test('empty input yields no nodes', () {
      expect(
        buildToposTree(entries: const []),
        isEmpty,
      );
    });

    test('keeps the nearest `expandedWalls` topos as individual rows', () {
      final entries = [
        for (var i = 0; i < 6; i++)
          _own('w$i', distanceKm: i.toDouble(), sectorId: 's', areaId: 'a'),
      ];

      final nodes = buildToposTree(
        entries: entries,
        expandedWalls: 3,
      );

      // First three are loose wall rows; the remaining three share a sector
      // and fold into one group row.
      expect(nodes.take(3).map(_wallIds), [
        ['w0'],
        ['w1'],
        ['w2'],
      ]);
      expect(nodes.length, 4);
      expect(nodes[3], isA<ToposGroupNode>());
      expect(_wallIds(nodes[3]), ['w3', 'w4', 'w5']);
    });

    test(
      'the head is kept even when NO entry has a distance — with no fix the '
      'list leads with the user\'s own topos, and burying those takes every '
      'per-topo action with them',
      () {
        // Regression guard. This function used to zero the head whenever no
        // location fix was available, which folded the user's entire own
        // library into a group — the signed-in E2E caught it as "timed out
        // waiting for the draft topo's overflow menu", because the menu only
        // exists on a rendered wall row. `mergeAndSortByProximity` puts own
        // entries first, so the head is meaningful with or without a fix.
        final entries = [
          for (var i = 0; i < 3; i++) _own('mine$i'),
          for (var i = 0; i < 6; i++)
            _community('theirs$i', sectorId: 's', areaId: 'a'),
        ];

        final nodes = buildToposTree(entries: entries, expandedWalls: 3);

        expect(_wallIds(nodes[0]), ['mine0']);
        expect(_wallIds(nodes[1]), ['mine1']);
        expect(_wallIds(nodes[2]), ['mine2']);
        expect(
          nodes.take(3).every((n) => n is ToposWallNode),
          isTrue,
          reason: 'the head must stay expanded with no distances at all',
        );
        // The community tail still tiers — that half is unchanged.
        expect(nodes[3], isA<ToposGroupNode>());
        expect(_wallIds(nodes[3]), hasLength(6));
      },
    );

    test(
      'a list that already fits is never tiered — grouping a three-topo '
      'library into one row is a screen of emptiness and an extra tap per '
      'topo, for nothing',
      () {
        final entries = [
          for (var i = 0; i < 3; i++) _own('w$i', sectorId: 's', areaId: 'a'),
        ];

        final nodes = buildToposTree(entries: entries, expandedWalls: 8);

        expect(nodes, hasLength(3));
        expect(nodes.every((n) => n is ToposWallNode), isTrue);
      },
    );

    test('tiers only what sits past the expanded head', () {
      final entries = [
        for (var i = 0; i < 12; i++) _own('w$i', sectorId: 's', areaId: 'a'),
      ];

      final nodes = buildToposTree(entries: entries, expandedWalls: 8);

      // 8 expanded wall rows, then the remaining 4 folded into one Sector.
      expect(nodes, hasLength(9));
      expect(nodes.take(8).every((n) => n is ToposWallNode), isTrue);
      expect(nodes[8], isA<ToposGroupNode>());
      expect(_wallIds(nodes[8]), ['w8', 'w9', 'w10', 'w11']);
    });

    test('an ungroupable topo still renders as its own row without a fix', () {
      // A fresh library filed entirely under the `__default__` sentinel has no
      // nameable ancestry at all, and must look exactly as it always did.
      final entries = [for (var i = 0; i < 4; i++) _own('w$i')];

      final nodes = buildToposTree(entries: entries);

      expect(nodes, hasLength(4));
      expect(nodes.every((n) => n is ToposWallNode), isTrue);
      expect(nodes.map(_wallIds), [
        ['w0'],
        ['w1'],
        ['w2'],
        ['w3'],
      ]);
    });
  });

  group('buildToposTree — sector tier', () {
    test('folds tail topos into their sector, nearest member first', () {
      final entries = [
        _own('near', distanceKm: 0.5, sectorId: 's1', areaId: 'a'),
        _own('b', distanceKm: 10, sectorId: 's2', areaId: 'a'),
        _own('a', distanceKm: 12, sectorId: 's2', areaId: 'a'),
        _own('c', distanceKm: 14, sectorId: 's2', areaId: 'a'),
      ];

      final nodes = buildToposTree(
        entries: entries,
        expandedWalls: 1,
      );

      expect(nodes, hasLength(2));
      final sector = nodes[1] as ToposGroupNode;
      expect(sector.kind, ToposGroupKind.sector);
      expect(sector.name, 'Sector s2');
      // Input order preserved inside the group, so the nearest topo in a
      // sector is the first one revealed when it is expanded.
      expect(_wallIds(sector), ['b', 'a', 'c']);
      expect(sector.distanceKm, 10);
    });

    test(
      'a single-topo sector dissolves back into a wall row (kMinGroupSize)',
      () {
        final entries = [
          _own('head', distanceKm: 1, sectorId: 's0', areaId: 'a'),
          _own('lonely', distanceKm: 20, sectorId: 'solo', areaId: 'a'),
        ];

        final nodes = buildToposTree(
          entries: entries,
          expandedWalls: 1,
        );

        expect(nodes, hasLength(2));
        expect(nodes[1], isA<ToposWallNode>());
        expect(_wallIds(nodes[1]), ['lonely']);
      },
    );

    test('a topo with no sector is never folded into a group', () {
      final entries = [
        _own('s1a', distanceKm: 10, sectorId: 's1', areaId: 'a'),
        _own('s1b', distanceKm: 11, sectorId: 's1', areaId: 'a'),
        _own('unfiled', distanceKm: 12),
      ];

      final nodes = buildToposTree(
        entries: entries,
        expandedWalls: 0,
      );

      expect(nodes, hasLength(2));
      expect(nodes[0], isA<ToposGroupNode>());
      expect(nodes[1], isA<ToposWallNode>());
      expect(_wallIds(nodes[1]), ['unfiled']);
    });
  });

  group('buildToposTree — area tier', () {
    test('folds sectors past `expandedSectors` into their area', () {
      final entries = <ProximityTopoEntry>[
        for (var s = 0; s < 4; s++) ...[
          _own('s${s}a', distanceKm: s * 10 + 1, sectorId: 's$s', areaId: 'far'),
          _own('s${s}b', distanceKm: s * 10 + 2, sectorId: 's$s', areaId: 'far'),
        ],
      ];

      final nodes = buildToposTree(
        entries: entries,
        expandedWalls: 0,
        expandedSectors: 2,
      );

      // Two nearest sectors stay as sector rows; the other two fold into one
      // area row carrying all four of their topos and both sectors as children.
      expect(nodes, hasLength(3));
      expect((nodes[0] as ToposGroupNode).kind, ToposGroupKind.sector);
      expect((nodes[1] as ToposGroupNode).kind, ToposGroupKind.sector);

      final area = nodes[2] as ToposGroupNode;
      expect(area.kind, ToposGroupKind.area);
      expect(area.name, 'Area far');
      expect(area.children, hasLength(2));
      expect(area.children.every((c) => c.kind == ToposGroupKind.sector), isTrue);
      expect(_wallIds(area), ['s2a', 's2b', 's3a', 's3b']);
    });

    test(
      'an area holding a single foldable sector stays a sector row',
      () {
        final entries = <ProximityTopoEntry>[
          _own('x1', distanceKm: 1, sectorId: 'sx', areaId: 'ax'),
          _own('x2', distanceKm: 2, sectorId: 'sx', areaId: 'ax'),
          _own('y1', distanceKm: 30, sectorId: 'sy', areaId: 'ay'),
          _own('y2', distanceKm: 31, sectorId: 'sy', areaId: 'ay'),
        ];

        final nodes = buildToposTree(
          entries: entries,
          expandedWalls: 0,
          expandedSectors: 1,
        );

        expect(nodes, hasLength(2));
        // 'sy' was foldable but is the only sector of area 'ay', so folding it
        // would add a tier that says nothing new.
        expect((nodes[1] as ToposGroupNode).kind, ToposGroupKind.sector);
        expect((nodes[1] as ToposGroupNode).name, 'Sector sy');
      },
    );

    test('a sector with no area stays a sector row', () {
      final entries = <ProximityTopoEntry>[
        _own('p1', distanceKm: 1, sectorId: 'sp', areaId: 'ap'),
        _own('p2', distanceKm: 2, sectorId: 'sp', areaId: 'ap'),
        _own('q1', distanceKm: 30, sectorId: 'sq'),
        _own('q2', distanceKm: 31, sectorId: 'sq'),
      ];

      final nodes = buildToposTree(
        entries: entries,
        expandedWalls: 0,
        expandedSectors: 1,
      );

      expect(nodes, hasLength(2));
      expect((nodes[1] as ToposGroupNode).kind, ToposGroupKind.sector);
    });
  });

  group('buildToposTree — ordering', () {
    test(
      'a nearby loose topo is never stranded below a far-away group',
      () {
        final entries = <ProximityTopoEntry>[
          // Two far sectors, then one much nearer unfiled topo LAST in input
          // order would be wrong — but input is distance-sorted, so the nearer
          // one comes first and must stay first after tiering.
          _own('close', distanceKm: 1),
          _own('far1', distanceKm: 50, sectorId: 'sf', areaId: 'af'),
          _own('far2', distanceKm: 51, sectorId: 'sf', areaId: 'af'),
        ];

        final nodes = buildToposTree(
          entries: entries,
          expandedWalls: 0,
        );

        expect(nodes, hasLength(2));
        expect(_wallIds(nodes[0]), ['close']);
        expect(nodes[1], isA<ToposGroupNode>());
      },
    );

    test('preserves input order when no distances are known', () {
      // Without a fix the input arrives newest-first rather than nearest-first;
      // rank-based sorting must preserve whichever of the two it was handed.
      final entries = [
        _own('newest', sectorId: 's1', areaId: 'a'),
        _own('mid', sectorId: 's2', areaId: 'a'),
        _own('mid2', sectorId: 's2', areaId: 'a'),
        _own('oldest', sectorId: 's1', areaId: 'a'),
      ];

      final nodes = buildToposTree(
        entries: entries,
        // Explicit, because four entries would otherwise fall under the
        // "already fits, do not tier" short-circuit and come back flat.
        expandedWalls: 0,
      );

      expect(nodes, hasLength(2));
      expect(_wallIds(nodes[0]), ['newest', 'oldest']);
      expect(_wallIds(nodes[1]), ['mid', 'mid2']);
    });
  });

  group('ToposGroupNode — row aggregates', () {
    test('sums routes and spans every difficulty band inside', () {
      final entries = [
        _own(
          'easy',
          distanceKm: 10,
          sectorId: 's',
          areaId: 'a',
          routeCount: 3,
          gradeKeys: const [1], // beginner
        ),
        _own(
          'hard',
          distanceKm: 11,
          sectorId: 's',
          areaId: 'a',
          routeCount: 4,
          gradeKeys: const [15], // hard
        ),
      ];

      final group =
          buildToposTree(entries: entries, expandedWalls: 0).single
              as ToposGroupNode;

      expect(group.topoCount, 2);
      expect(group.routeCount, 7);
      expect(group.bands, [GradeBand.beginner, GradeBand.hard]);
    });

    test('reports the NEAREST member distance, not a centroid', () {
      final entries = [
        _own('a', distanceKm: 4, sectorId: 's', areaId: 'ar'),
        _own('b', distanceKm: 40, sectorId: 's', areaId: 'ar'),
      ];

      final group =
          buildToposTree(entries: entries, expandedWalls: 0).single
              as ToposGroupNode;

      expect(group.distanceKm, 4);
    });

    test('distance is null when nothing inside has one', () {
      final entries = [
        _own('a', sectorId: 's', areaId: 'ar'),
        _own('b', sectorId: 's', areaId: 'ar'),
      ];

      final group =
          buildToposTree(entries: entries, expandedWalls: 0)
                  .single
              as ToposGroupNode;

      expect(group.distanceKm, isNull);
    });

    test('collects up to three readable thumbnails, skipping photoless topos', () {
      final entries = [
        _own('none', distanceKm: 1, sectorId: 's', areaId: 'ar'),
        _own('p1', distanceKm: 2, sectorId: 's', areaId: 'ar',
            thumbnailPath: '/one.jpg'),
        _own('p2', distanceKm: 3, sectorId: 's', areaId: 'ar',
            thumbnailPath: '/two.jpg'),
        _own('p3', distanceKm: 4, sectorId: 's', areaId: 'ar',
            thumbnailPath: '/three.jpg'),
        _own('p4', distanceKm: 5, sectorId: 's', areaId: 'ar',
            thumbnailPath: '/four.jpg'),
      ];

      final group =
          buildToposTree(entries: entries, expandedWalls: 0).single
              as ToposGroupNode;

      expect(group.thumbnailPaths(), ['/one.jpg', '/two.jpg', '/three.jpg']);
    });

    test('an area aggregates across all of its sectors', () {
      final entries = <ProximityTopoEntry>[
        for (var s = 0; s < 2; s++) ...[
          _own('s${s}a', distanceKm: s * 10 + 1, sectorId: 's$s',
              areaId: 'ar', routeCount: 2),
          _own('s${s}b', distanceKm: s * 10 + 2, sectorId: 's$s',
              areaId: 'ar', routeCount: 3),
        ],
      ];

      final area =
          buildToposTree(
                entries: entries,
                expandedWalls: 0,
                expandedSectors: 0,
              ).single
              as ToposGroupNode;

      expect(area.kind, ToposGroupKind.area);
      expect(area.topoCount, 4);
      expect(area.routeCount, 10);
    });
  });

  group('buildToposTree — community entries', () {
    test('groups own and community topos into the same sector', () {
      final entries = [
        _own('mine', distanceKm: 10, sectorId: 's', areaId: 'a'),
        _community('theirs', distanceKm: 11, sectorId: 's', areaId: 'a'),
      ];

      final group =
          buildToposTree(entries: entries, expandedWalls: 0).single
              as ToposGroupNode;

      expect(_wallIds(group), ['mine', 'theirs']);
    });
  });
}
