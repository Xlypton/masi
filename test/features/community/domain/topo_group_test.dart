// Collapsing duplicate topos into one card per place (community editing
// phase 8b / C-6.2).
//
// The failure this guards against is not "grouping is wrong". It is grouping
// LOSING something. §C-6 rules out resolving duplicates by deletion, so a
// grouping pass that drops a topo off the feed would achieve by rendering
// exactly what the plan forbids doing to the database. Several tests below
// exist only to assert that every input topo comes out somewhere.

import 'package:flutter_test/flutter_test.dart';
import 'package:masi/features/community/data/community_repository.dart';
import 'package:masi/features/community/domain/topo_group.dart';

const _now = 1700000000000;

SharedTopo _topo(String id, {int routeCount = 0, int createdAt = 0}) =>
    SharedTopo(
      wallId: id,
      name: id,
      routeCount: routeCount,
      likeCount: 0,
      commentCount: 0,
      createdAt: createdAt,
    );

AlternateGroups _links(Map<String, String> pairs) => AlternateGroups({...pairs});

List<TopoGroup> _group(List<SharedTopo> topos, AlternateGroups links) =>
    groupTopos(topos, links, nowMs: _now);

Set<String> _allIds(List<TopoGroup> groups) => {
  for (final group in groups)
    for (final topo in group.all) topo.wallId,
};

void main() {
  test('no links at all leaves the feed exactly as it was', () {
    final topos = [_topo('a'), _topo('b'), _topo('c')];
    final groups = _group(topos, const AlternateGroups.empty());
    expect(groups.map((g) => g.head.wallId), ['a', 'b', 'c']);
    expect(groups.every((g) => !g.isGrouped), isTrue);
  });

  test('two linked topos become one card standing for two', () {
    final groups = _group([_topo('a'), _topo('b')], _links({'b': 'a'}));
    expect(groups, hasLength(1));
    expect(groups.single.count, 2);
  });

  test(
    'NOTHING is dropped by grouping. A pass that renders three topos as two '
    'cards and loses the third would achieve by rendering exactly what §C-6 '
    'forbids doing to the database',
    () {
      final topos = [_topo('a'), _topo('b'), _topo('c'), _topo('d')];
      final groups = _group(topos, _links({'b': 'a', 'c': 'a'}));
      expect(_allIds(groups), {'a', 'b', 'c', 'd'});
    },
  );

  test(
    'the BEST member heads the card, not the canonical one. An admin linking '
    'two topos recorded that they are the same boulder — not which drawing of '
    'it is better, which they were never asked',
    () {
      // 'a' is the canonical, but 'b' is the one with routes on it.
      final groups = _group(
        [_topo('a'), _topo('b', routeCount: 6)],
        _links({'b': 'a'}),
      );
      expect(groups.single.head.wallId, 'b');
      expect(groups.single.alternates.single.wallId, 'a');
    },
  );

  test(
    'the card sits where its FIRST member sat. Linking two topos must not be '
    'able to move a place up a newest-first feed — an admin resolving a '
    'duplicate report is not deciding what people see first',
    () {
      // Feed order is newest-first; 'c' is oldest and is the canonical.
      final topos = [_topo('a'), _topo('b', routeCount: 9), _topo('c')];
      final groups = _group(topos, _links({'b': 'c'}));
      expect(groups.map((g) => g.head.wallId), ['a', 'b']);
    },
  );

  test(
    'a group whose canonical is absent still coheres. A grade filter, an '
    'un-pulled mirror or an access restriction can all remove the head, and '
    'scattering the rest into unrelated cards would undo the grouping exactly '
    'when the reader is looking at a filtered view',
    () {
      final groups = _group(
        [_topo('b'), _topo('c')],
        _links({'b': 'a', 'c': 'a'}),
      );
      expect(groups, hasLength(1));
      expect(groups.single.count, 2);
    },
  );

  test('an alternate whose partners are all absent renders as a plain card', () {
    final groups = _group([_topo('b')], _links({'b': 'a'}));
    expect(groups, hasLength(1));
    expect(groups.single.isGrouped, isFalse);
  });

  group('AlternateGroups', () {
    test('a wall with no link is its own head', () {
      expect(const AlternateGroups.empty().canonicalFor('x'), 'x');
    });

    test('malformed rows are skipped rather than throwing', () {
      final links = AlternateGroups.fromRows([
        {'wallId': 'b', 'canonicalId': 'a'},
        {'wallId': 'c'},
        {'canonicalId': 'a'},
        {'wallId': 'd', 'canonicalId': 'd'},
        {'wallId': 42, 'canonicalId': 'a'},
      ]);
      expect(links.canonicalFor('b'), 'a');
      expect(links.canonicalFor('c'), 'c');
      expect(links.canonicalFor('d'), 'd');
    });

    test(
      'a chain the server should never produce is collapsed rather than '
      'looped on. Grouping slightly wrong beats hanging the feed',
      () {
        final links = _links({'c': 'b', 'b': 'a'});
        expect(links.canonicalFor('c'), 'a');
      },
    );

    test('a two-cycle terminates', () {
      final links = _links({'a': 'b', 'b': 'a'});
      expect(links.canonicalFor('a'), 'b');
      expect(links.canonicalFor('b'), 'a');
    });
  });
}
