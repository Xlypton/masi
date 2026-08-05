// Tests for the REAL [SupabaseSyncRemote] — the class that actually talks to
// PostgREST — rather than the `FakeSyncRemote` every other sync test uses.
//
// Why this file exists: before it, `SupabaseSyncRemote` was never instantiated
// by any test in the suite. `sync_service_test.dart` (4k+ lines) and
// `sync_orchestrator_test.dart` both exercise fakes whose doc comments say they
// "mirror SupabaseSyncRemote's contract" — so the whole network layer of the
// sync engine could be rewritten and the suite would stay green. That is
// exactly what happened when the pull fetchers were reshaped from one-query-at-
// a-time into dependency waves: nothing failed, because nothing looked.
//
// The seam is [SupabaseClient]'s URL: it is just a base address, so pointing it
// at a local [HttpServer] that speaks enough PostgREST (a JSON array per table,
// `inFilter` arriving as `id=in.(a,b)`) gives real end-to-end coverage of
// request shaping, row mapping and the `filterValidSyncRows` guards — with no
// network and no backend.
//
// Concurrency is asserted structurally, not by timing: `_FakePostgrest` counts
// how many requests are in flight at once. Sequential `await`s can only ever
// reach 1, because the next query is not even ISSUED until the previous
// response has been consumed. So `maxInFlight` is a deterministic witness of
// which shape the code has, not a flaky stopwatch.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:masi/features/backup/data/sync_remote.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// A minimal PostgREST stand-in.
///
/// Serves one JSON array per table from [rows], and records both the order
/// requests arrived in and the high-water mark of concurrent in-flight
/// requests. The [_holdFor] delay is what gives concurrent requests a window to
/// actually overlap in; it does not make the assertion timing-dependent (see
/// the file header).
class _FakePostgrest {
  _FakePostgrest(this._server) {
    _server.listen(_handle);
  }

  static Future<_FakePostgrest> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return _FakePostgrest(server);
  }

  final HttpServer _server;

  /// Table name -> rows that table's SELECT should return.
  final Map<String, List<Map<String, dynamic>>> rows = {};

  /// Every table name requested, in arrival order.
  final List<String> requested = [];

  /// Raw query strings, for asserting filter shaping.
  final List<String> queries = [];

  int _inFlight = 0;

  /// Highest number of requests simultaneously in flight. 1 proves sequential
  /// awaits; >1 proves the queries were issued together.
  int maxInFlight = 0;

  Duration holdFor = const Duration(milliseconds: 30);

  String get url => 'http://127.0.0.1:${_server.port}';

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest req) async {
    _inFlight++;
    maxInFlight = math.max(maxInFlight, _inFlight);

    // `/rest/v1/<table>` — take the last path segment.
    final table = req.uri.pathSegments.isEmpty ? '' : req.uri.pathSegments.last;
    requested.add(table);
    queries.add(req.uri.query);

    // Held open so genuinely-concurrent requests are in flight at the same
    // moment. Sequential code cannot overlap here no matter how long this is.
    await Future<void>.delayed(holdFor);

    final body = jsonEncode(rows[table] ?? const <Map<String, dynamic>>[]);
    req.response
      ..statusCode = 200
      ..headers.contentType = ContentType.json
      ..headers.set('Content-Range', '0-0/*')
      ..write(body);
    await req.response.close();

    _inFlight--;
  }
}

/// A row that satisfies [syncRequiredFields] for [table].
///
/// Built from the authoritative map rather than hand-written per table, so a
/// new NOT NULL column added to `syncRequiredFields` cannot silently make these
/// fixtures invalid and turn the assertions into vacuous "0 rows == 0 rows".
Map<String, dynamic> _validRow(String table, String id, {String? ownerId}) {
  final row = <String, dynamic>{'id': id};
  for (final field in syncRequiredFields[table] ?? const ['id']) {
    row.putIfAbsent(field, () => '$field-of-$id');
  }
  if (ownerId != null) row['ownerId'] = ownerId;
  return row;
}

void main() {
  late _FakePostgrest fake;
  late SupabaseSyncRemote remote;

  setUp(() async {
    fake = await _FakePostgrest.start();
    remote = SupabaseSyncRemote(
      SupabaseClient(fake.url, 'test-anon-key'),
    );
  });

  tearDown(() async {
    await fake.close();
  });

  group('fetchOwnRows', () {
    test('returns one entry per sync table, keyed and ordered by '
        'syncTableNames', () async {
      for (final t in syncTableNames) {
        fake.rows[t] = [_validRow(t, '$t-1', ownerId: 'uid-1')];
      }

      final result = await remote.fetchOwnRows('uid-1');

      expect(result.keys, orderedEquals(syncTableNames),
          reason: 'insertion order is load-bearing — BackupRepository.'
              'importSnapshot applies tables in the order it iterates them, '
              'which is FK dependency order. Rebuilding this map from '
              'completion order instead of syncTableNames would import a '
              'child before its parent.');
      for (final t in syncTableNames) {
        expect(result[t], hasLength(1), reason: 'table $t');
      }
    });

    test('issues every table SELECT concurrently, not one at a time', () async {
      for (final t in syncTableNames) {
        fake.rows[t] = [_validRow(t, '$t-1', ownerId: 'uid-1')];
      }

      await remote.fetchOwnRows('uid-1');

      expect(fake.requested, hasLength(syncTableNames.length));
      expect(
        fake.maxInFlight,
        syncTableNames.length,
        reason: 'all ${syncTableNames.length} own-row SELECTs are mutually '
            'independent (each is ownerId = uid against a different table), so '
            'they must go out together. maxInFlight == 1 means they were '
            'awaited in sequence, spending ${syncTableNames.length} round '
            'trips of latency to do one round trip of work.',
      );
    });

    test('scopes every SELECT to the owner', () async {
      await remote.fetchOwnRows('uid-42');

      expect(fake.queries, isNotEmpty);
      for (final q in fake.queries) {
        expect(q, contains('ownerId=eq.uid-42'));
      }
    });

    test('drops rows missing a required NOT NULL field, keeping valid '
        'siblings', () async {
      // `areas` requires more than just `id`; omit one required field.
      final required = syncRequiredFields['areas']!;
      final incomplete = <String, dynamic>{'id': 'bad', 'ownerId': 'uid-1'};
      for (final f in required.where((f) => f != required.last)) {
        incomplete.putIfAbsent(f, () => 'x');
      }
      fake.rows['areas'] = [
        _validRow('areas', 'good', ownerId: 'uid-1'),
        incomplete,
      ];

      final result = await remote.fetchOwnRows('uid-1');

      expect(
        result['areas']!.map((r) => r['id']),
        ['good'],
        reason: 'one malformed row must not abort the whole fetch (#72) — it '
            'is skipped, its siblings survive.',
      );
    });
  });

  group('fetchSharedTopos', () {
    void seedSharedWall() {
      fake.rows['walls'] = [
        {..._validRow('walls', 'w1'), 'sectorId': 's1', 'visibility': 'shared'},
      ];
      fake.rows['sectors'] = [
        {..._validRow('sectors', 's1'), 'areaId': 'a1'},
      ];
      fake.rows['areas'] = [_validRow('areas', 'a1')];
      fake.rows['photos'] = [
        {..._validRow('photos', 'p1'), 'wallId': 'w1'},
      ];
      fake.rows['routes'] = [
        {..._validRow('routes', 'r1'), 'wallId': 'w1'},
      ];
      fake.rows['comments'] = [
        {..._validRow('comments', 'c1'), 'wallId': 'w1'},
      ];
      fake.rows['likes'] = [
        {..._validRow('likes', 'l1'), 'wallId': 'w1'},
      ];
    }

    test('resolves the wall -> sector -> area chain and the wall-keyed '
        'children', () async {
      seedSharedWall();

      final result = await remote.fetchSharedTopos();

      expect(result['walls'], hasLength(1));
      expect(result['sectors'], hasLength(1));
      expect(result['areas'], hasLength(1));
      expect(result['photos'], hasLength(1));
      expect(result['routes'], hasLength(1));
      expect(result['comments'], hasLength(1));
      expect(result['likes'], hasLength(1));
      expect(
        result.containsKey('ascents'),
        isFalse,
        reason: 'fetchSharedTopos deliberately never returns ascents — a '
            'private ascent on a shared topo must not leak through the topo '
            'feed. fetchSharedAscents is the separate, opt-in path.',
      );
    });

    test('collapses the wall-derived queries into one wave', () async {
      seedSharedWall();

      await remote.fetchSharedTopos();

      // walls | {sectors, photos, routes, comments, likes} | areas
      expect(
        fake.maxInFlight,
        5,
        reason: 'sectors/photos/routes/comments/likes all key off the wall '
            'rows and off nothing else, so they belong in one wave. Only '
            'areas genuinely depends on a wave-2 result (its ids come from '
            'the sector rows).',
      );
      expect(fake.requested.first, 'walls');
      expect(fake.requested.last, 'areas');
    });

    test('short-circuits with no round trips past walls when nothing is '
        'shared', () async {
      fake.rows['walls'] = [];

      final result = await remote.fetchSharedTopos();

      expect(fake.requested, ['walls']);
      for (final entry in result.entries) {
        expect(entry.value, isEmpty, reason: entry.key);
      }
    });
  });

  group('fetchSharedAscents', () {
    void seedSharedAscent() {
      fake.rows['ascents'] = [
        {
          ..._validRow('ascents', 'as1'),
          'wallId': 'w1',
          'routeId': 'r1',
          'visibility': 'shared',
        },
      ];
      fake.rows['walls'] = [
        {..._validRow('walls', 'w1'), 'sectorId': 's1'},
      ];
      fake.rows['routes'] = [
        {..._validRow('routes', 'r1'), 'photoId': 'p1'},
      ];
      fake.rows['sectors'] = [
        {..._validRow('sectors', 's1'), 'areaId': 'a1'},
      ];
      fake.rows['photos'] = [_validRow('photos', 'p1')];
      fake.rows['areas'] = [_validRow('areas', 'a1')];
    }

    test('resolves the minimal ancestor chain for each shared ascent',
        () async {
      seedSharedAscent();

      final result = await remote.fetchSharedAscents();

      expect(result['ascents'], hasLength(1));
      expect(result['walls'], hasLength(1));
      expect(result['routes'], hasLength(1));
      expect(result['sectors'], hasLength(1));
      expect(result['photos'], hasLength(1));
      expect(result['areas'], hasLength(1));
    });

    test('walks the ancestor DAG in 4 waves, not 6 serial steps', () async {
      seedSharedAscent();

      await remote.fetchSharedAscents();

      // ascents | {walls, routes} | {sectors, photos} | areas
      expect(
        fake.maxInFlight,
        2,
        reason: 'walls and routes both key off the ascent rows; sectors needs '
            'walls and photos needs routes, but not each other. Only areas '
            'needs sectors. That is a 4-deep DAG, so a depth-first walk spent '
            '6 round trips to resolve 4 levels.',
      );
      expect(fake.requested.first, 'ascents');
      expect(fake.requested.last, 'areas');
    });

    test('short-circuits when nothing is shared', () async {
      fake.rows['ascents'] = [];

      final result = await remote.fetchSharedAscents();

      expect(fake.requested, ['ascents']);
      expect(result['ascents'], isEmpty);
      expect(result['walls'], isEmpty);
    });

    test('skips an ascent missing the FKs its ancestor chain is derived from',
        () async {
      fake.rows['ascents'] = [
        {..._validRow('ascents', 'ok'), 'wallId': 'w1', 'routeId': 'r1'},
        // No wallId/routeId: the `as String` casts downstream would throw.
        {'id': 'broken', 'visibility': 'shared'},
      ];
      fake.rows['walls'] = [
        {..._validRow('walls', 'w1'), 'sectorId': 's1'},
      ];
      fake.rows['routes'] = [
        {..._validRow('routes', 'r1'), 'photoId': 'p1'},
      ];

      final result = await remote.fetchSharedAscents();

      expect(result['ascents']!.map((r) => r['id']), ['ok']);
    });
  });
}
