// A shared-ascent batch must be internally consistent before it reaches the
// importer.
//
// The bug this closes was found on live on 2026-08-08, and it is worth stating
// precisely because the shape recurs. `ascents_shared_select` was
// `visibility = 'shared'` with no wall check, while `routes` and `walls` are
// gated on `is_wall_public(...)`. `fetchSharedAscents` fetches the ascents
// first and their ancestors afterwards, in separate RLS-filtered queries — so
// an ascent on a topo that had since been deleted came back with no route and
// no wall. The local FKs are enforced and NOT NULL, so the importer deferred
// it and reported `shared rows deferred (parent row missing)`, which the user
// saw as a red "Couldn't sync — Retry" banner that could never heal: the parent
// was soft-deleted server-side and would never be returned.
//
// The server policy is fixed separately. This half matters on its own, because
// the two queries hit a LIVE database: a topo withdrawn between them produces
// the same orphan with no bug at either end.

import 'package:flutter_test/flutter_test.dart';
import 'package:masi/features/backup/data/sync_remote.dart';

Map<String, dynamic> _area(String id) => {'id': id};
Map<String, dynamic> _sector(String id, String areaId) => {
  'id': id,
  'areaId': areaId,
};
Map<String, dynamic> _wall(String id, String sectorId) => {
  'id': id,
  'sectorId': sectorId,
};
Map<String, dynamic> _photo(String id, String wallId, {String? parent}) => {
  'id': id,
  'wallId': wallId,
  'parentPhotoId': parent,
};
Map<String, dynamic> _route(String id, String wallId, String photoId) => {
  'id': id,
  'wallId': wallId,
  'photoId': photoId,
};
Map<String, dynamic> _ascent(String id, String wallId, String routeId) => {
  'id': id,
  'wallId': wallId,
  'routeId': routeId,
};

/// A batch with everything present and linked.
Map<String, List<Map<String, dynamic>>> _whole() => {
  'areas': [_area('a1')],
  'sectors': [_sector('s1', 'a1')],
  'walls': [_wall('w1', 's1')],
  'photos': [_photo('p1', 'w1')],
  'routes': [_route('r1', 'w1', 'p1')],
  'ascents': [_ascent('asc1', 'w1', 'r1')],
};

List<String> _ids(Map<String, List<Map<String, dynamic>>> b, String key) => [
  for (final row in b[key] ?? const []) row['id'] as String,
];

void main() {
  group('a complete batch survives untouched', () {
    test('nothing is dropped when every parent is present', () {
      final out = consistentSharedAscentBatch(_whole());
      expect(_ids(out, 'ascents'), ['asc1']);
      expect(_ids(out, 'routes'), ['r1']);
      expect(_ids(out, 'walls'), ['w1']);
      expect(_ids(out, 'photos'), ['p1']);
      expect(_ids(out, 'sectors'), ['s1']);
      expect(_ids(out, 'areas'), ['a1']);
    });

    test('a slice photo pointing at an original in the batch is kept', () {
      final batch = _whole()
        ..['photos'] = [_photo('p1', 'w1'), _photo('p2', 'w1', parent: 'p1')];
      expect(_ids(consistentSharedAscentBatch(batch), 'photos'), ['p1', 'p2']);
    });

    test('keys the caller did not set are passed through untouched', () {
      final batch = _whole()..['profiles'] = [
        {'id': 'u1'},
      ];
      expect(_ids(consistentSharedAscentBatch(batch), 'profiles'), ['u1']);
    });
  });

  group('the live failure: RLS hid the ancestors', () {
    test(
      'an ascent whose wall and route were filtered out is DROPPED, not passed '
      'on to defer. This is the whole bug: the parent was soft-deleted '
      'server-side, so the deferral could never heal and the user saw a '
      'permanent sync error',
      () {
        final batch = _whole()
          ..['walls'] = []
          ..['routes'] = []
          ..['photos'] = []
          ..['sectors'] = []
          ..['areas'] = [];
        expect(consistentSharedAscentBatch(batch)['ascents'], isEmpty);
      },
    );

    test('a HEALTHY ascent in the same batch still comes through', () {
      // The pruning is per-row, not all-or-nothing. One user's deleted topo
      // must not cost everybody else their shared ascents.
      final batch = {
        'areas': [_area('a1')],
        'sectors': [_sector('s1', 'a1')],
        'walls': [_wall('w1', 's1')],
        'photos': [_photo('p1', 'w1')],
        'routes': [_route('r1', 'w1', 'p1')],
        'ascents': [
          _ascent('good', 'w1', 'r1'),
          _ascent('orphan', 'w-gone', 'r-gone'),
        ],
      };
      expect(_ids(consistentSharedAscentBatch(batch), 'ascents'), ['good']);
    });
  });

  group('a hole at any depth propagates in ONE pass', () {
    test('a missing area takes its sector, wall, route and ascent with it', () {
      final batch = _whole()..['areas'] = [];
      final out = consistentSharedAscentBatch(batch);
      expect(_ids(out, 'sectors'), isEmpty);
      expect(_ids(out, 'walls'), isEmpty, reason: 'walls.sectorId is enforced');
      expect(_ids(out, 'routes'), isEmpty);
      expect(_ids(out, 'ascents'), isEmpty);
    });

    test('a missing sector takes the wall and everything under it', () {
      final out = consistentSharedAscentBatch(_whole()..['sectors'] = []);
      expect(_ids(out, 'walls'), isEmpty);
      expect(_ids(out, 'ascents'), isEmpty);
    });

    test('a missing photo takes the route, and the route takes the ascent', () {
      final out = consistentSharedAscentBatch(_whole()..['photos'] = []);
      expect(_ids(out, 'walls'), ['w1'], reason: 'the wall is still intact');
      expect(_ids(out, 'routes'), isEmpty, reason: 'routes.photoId is enforced');
      expect(_ids(out, 'ascents'), isEmpty);
    });

    test('a slice whose original is absent is dropped', () {
      final batch = _whole()..['photos'] = [_photo('p2', 'w1', parent: 'gone')];
      expect(consistentSharedAscentBatch(batch)['photos'], isEmpty);
    });

    test('a route on a wall outside the batch is dropped', () {
      final batch = _whole()..['routes'] = [_route('r1', 'w-other', 'p1')];
      final out = consistentSharedAscentBatch(batch);
      expect(_ids(out, 'routes'), isEmpty);
      expect(_ids(out, 'ascents'), isEmpty);
    });

    test('an ascent naming a route on a DIFFERENT wall is dropped', () {
      // Both parents exist, but the ascent's own wallId does not match any wall
      // in the batch — still an unsatisfiable FK.
      final batch = _whole()..['ascents'] = [_ascent('a', 'w-other', 'r1')];
      expect(consistentSharedAscentBatch(batch)['ascents'], isEmpty);
    });
  });

  group('malformed input degrades rather than throwing', () {
    test('missing table keys are treated as empty', () {
      expect(consistentSharedAscentBatch(const {})['ascents'], isEmpty);
    });

    test('a row with a non-string id cannot satisfy anything', () {
      final batch = _whole()..['walls'] = [
        {'id': 42, 'sectorId': 's1'},
      ];
      expect(consistentSharedAscentBatch(batch)['ascents'], isEmpty);
    });

    test('a row with a missing FK field is dropped, not crashed on', () {
      final batch = _whole()..['routes'] = [
        {'id': 'r1', 'photoId': 'p1'},
      ];
      expect(consistentSharedAscentBatch(batch)['routes'], isEmpty);
    });
  });
}
