// Ranking topos of the same place (community editing phase 8c / C-6.3, and
// the answer to Open Question 3).
//
// These tests assert ORDERING PROPERTIES, never numbers. The weights in
// `TopoRank` are a judgement call and will be tuned; the properties below are
// the argument §C-6.3 actually makes, and if one of them stops holding the
// tuning went wrong rather than the test going stale.
//
// The property that matters most: a POPULAR EMPTY topo must not beat a
// COMPLETE unpopular one. "Which of these two drawings of the same boulder
// should I look at first" has an obvious answer when one of them has no lines
// on it, however many people liked the photo.

import 'package:flutter_test/flutter_test.dart';
import 'package:masi/features/community/data/community_repository.dart';
import 'package:masi/features/community/domain/topo_rank.dart';

const _now = 1700000000000;
const _day = 86400000;

SharedTopo _topo(
  String id, {
  int routeCount = 0,
  List<double> gradeKeys = const [],
  int likeCount = 0,
  int commentCount = 0,
  int ascentCount = 0,
  double? latitude,
  double? longitude,
  int? lastVerifiedAt,
}) => SharedTopo(
  wallId: id,
  name: id,
  routeCount: routeCount,
  routeGradeKeys: gradeKeys,
  likeCount: likeCount,
  commentCount: commentCount,
  ascentCount: ascentCount,
  latitude: latitude,
  longitude: longitude,
  lastVerifiedAt: lastVerifiedAt,
);

TopoRank _rank(SharedTopo topo) => TopoRank.of(topo, nowMs: _now);

/// True when [a] sorts ahead of [b].
bool _beats(SharedTopo a, SharedTopo b) => _rank(a).compareTo(_rank(b)) < 0;

void main() {
  test(
    'a finished topo beats a popular empty one. This is the whole argument for '
    'ranking rather than rating: likes measure the photo, routes measure the '
    'topo, and only one of those is what a climber came for',
    () {
      final finished = _topo('finished', routeCount: 4, gradeKeys: [10, 12]);
      final popular = _topo('popular', likeCount: 500, commentCount: 200);
      expect(_beats(finished, popular), isTrue);
    },
  );

  test('having ANY routes outweighs having many of them', () {
    final one = _topo('one', routeCount: 1);
    final twenty = _topo('twenty', routeCount: 20);
    expect(_beats(twenty, one), isTrue, reason: 'more is still better');
    // But the gap between 1 and 20 routes must be smaller than the gap between
    // 0 and 1: a photo with one line drawn on it is a topo; a photo with none
    // is a photo.
    final none = _topo('none');
    final zeroToOne = _rank(one).score - _rank(none).score;
    final oneToTwenty = _rank(twenty).score - _rank(one).score;
    expect(zeroToOne, greaterThan(oneToTwenty));
  });

  test('an ascent counts for more than a like — it cost more to produce', () {
    final climbed = _topo('climbed', ascentCount: 3);
    final liked = _topo('liked', likeCount: 3);
    expect(_beats(climbed, liked), isTrue);
  });

  test(
    'no single signal can run away with it: engagement saturates, so a topo '
    'with 10000 likes and nothing else still loses to a complete one',
    () {
      final adored = _topo('adored', likeCount: 10000);
      final complete = _topo(
        'complete',
        routeCount: 3,
        gradeKeys: [10],
        latitude: 46,
        longitude: 11,
      );
      expect(_beats(complete, adored), isTrue);
    },
  );

  test('a negative or absurd count cannot produce a negative score', () {
    final weird = SharedTopo(
      wallId: 'weird',
      name: 'weird',
      routeCount: -5,
      likeCount: -100,
      commentCount: 0,
      ascentCount: -3,
    );
    expect(_rank(weird).score, greaterThanOrEqualTo(0));
  });

  group('verification decays', () {
    test('a fresh verification beats a year-old one', () {
      final fresh = _topo('fresh', lastVerifiedAt: _now - 7 * _day);
      final old = _topo('old', lastVerifiedAt: _now - 300 * _day);
      expect(_beats(fresh, old), isTrue);
    });

    test(
      'a verification older than the window is worth exactly nothing, not a '
      'lingering fraction — "somebody confirmed this in 2019" is not a claim '
      'about the rock today',
      () {
        final ancient = _topo('a', lastVerifiedAt: _now - 4000 * _day);
        final never = _topo('a');
        expect(_rank(ancient).score, _rank(never).score);
      },
    );

    test('a FUTURE timestamp does not score above a fresh one', () {
      final future = _topo('future', lastVerifiedAt: _now + 900 * _day);
      final now = _topo('now', lastVerifiedAt: _now);
      expect(_rank(future).freshness, lessThanOrEqualTo(_rank(now).freshness));
    });
  });

  test(
    'identical topos still have a stable total order. Without the id tiebreak '
    'the card heading a group of duplicates would flip on every rebuild',
    () {
      final a = _topo('aaa', routeCount: 2);
      final b = _topo('bbb', routeCount: 2);
      expect(_rank(a).score, _rank(b).score);
      expect(_beats(a, b), isTrue);
      expect(_beats(b, a), isFalse);
    },
  );

  test('coordinates count toward completeness — an unfindable crag is not', () {
    final located = _topo('located', latitude: 46, longitude: 11);
    final lost = _topo('lost');
    expect(_beats(located, lost), isTrue);
  });
}
