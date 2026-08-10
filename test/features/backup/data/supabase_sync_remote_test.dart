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

  /// Raw request bodies, for asserting what a non-GET call actually sent (the
  /// Storage delete carries its object paths in a `prefixes` body, not the URL).
  final List<String> bodies = [];

  /// Status for every response. Left at 200 by every test but the Storage ones,
  /// which need a genuine failure response to prove the production code catches
  /// `StorageException` rather than letting it out. The error body is a JSON
  /// OBJECT on purpose: storage_client's error handler casts the decoded body to
  /// a `Map`, so a bare array there raises a TypeError instead of the
  /// `StorageException` the code under test is written against.
  int status = 200;

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
    bodies.add(await utf8.decoder.bind(req).join());

    // Held open so genuinely-concurrent requests are in flight at the same
    // moment. Sequential code cannot overlap here no matter how long this is.
    await Future<void>.delayed(holdFor);

    if (status != 200) {
      req.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'message': 'denied', 'error': 'Unauthorized'}));
      await req.response.close();
      _inFlight--;
      return;
    }

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
        {..._validRow('routes', 'r1'), 'wallId': 'w1', 'photoId': 'p1'},
      ];
      fake.rows['sectors'] = [
        {..._validRow('sectors', 's1'), 'areaId': 'a1'},
      ];
      fake.rows['photos'] = [
        {..._validRow('photos', 'p1'), 'wallId': 'w1'},
      ];
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
      // Seeds the WHOLE consistent chain, then adds the broken ascent to it.
      // Seeding only walls+routes would exercise `consistentSharedAscentBatch`
      // (which drops a wall whose sector is absent, and everything under it)
      // instead of the required-field filter this test is about — and would
      // pass for entirely the wrong reason.
      seedSharedAscent();
      fake.rows['ascents'] = [
        {
          ..._validRow('ascents', 'ok'),
          'wallId': 'w1',
          'routeId': 'r1',
          'visibility': 'shared',
        },
        // No wallId/routeId: the `as String` casts downstream would throw.
        {'id': 'broken', 'visibility': 'shared'},
      ];

      final result = await remote.fetchSharedAscents();

      expect(result['ascents']!.map((r) => r['id']), ['ok']);
    });

    test(
      'an ascent whose ancestors were filtered out by RLS is DROPPED, not '
      'returned to defer. Live, 2026-08-08: the ascent policy checked only '
      '`visibility`, its route and wall needed `is_wall_public`, and the topo '
      'had been deleted — so the row could never be inserted and the user got '
      'a "Couldn\'t sync" banner that could never clear',
      () async {
        seedSharedAscent();
        // What RLS actually does to the follow-up queries: the ancestors of a
        // no-longer-public topo simply do not come back.
        fake.rows['walls'] = [];
        fake.rows['routes'] = [];

        final result = await remote.fetchSharedAscents();

        expect(result['ascents'], isEmpty);
        expect(result['walls'], isEmpty);
      },
    );
  });

  group('chunkSyncIds', () {
    test('splits into batches of at most chunkSize, every id in exactly one '
        'chunk', () async {
      final ids = [for (var i = 0; i < 361; i++) 'id-$i'];

      final chunks = chunkSyncIds(ids);

      expect(chunks, hasLength(3), reason: '361 ids / 150 per chunk');
      expect(chunks.map((c) => c.length), [150, 150, 61]);
      // The property callers actually depend on: a partition, not merely a
      // cover. A duplicated id would be imported twice; a dropped one would be
      // a comment the user never sees, which is the whole bug.
      final flat = chunks.expand((c) => c).toList();
      expect(flat, orderedEquals(ids));
      expect(flat.toSet(), hasLength(ids.length));
    });

    test('de-duplicates, preserving first-appearance order', () async {
      expect(
        chunkSyncIds(['b', 'a', 'b', 'c', 'a'], chunkSize: 10),
        [
          ['b', 'a', 'c'],
        ],
      );
    });

    test('an empty input is zero chunks, i.e. zero round trips', () async {
      expect(chunkSyncIds(const <String>[]), isEmpty);
    });
  });

  group('fetchEngagementByParentIds', () {
    test('returns comments and likes attached to the asked-about ids, keyed '
        'like every other fetch', () async {
      fake.rows['comments'] = [
        {..._validRow('comments', 'c1'), 'ascentId': 'as1', 'ownerId': 'other'},
      ];
      fake.rows['likes'] = [
        {..._validRow('likes', 'l1'), 'ascentId': 'as1', 'ownerId': 'other'},
      ];

      final result = await remote.fetchEngagementByParentIds(
        ascentIds: const ['as1'],
        wallIds: const ['w1'],
      );

      expect(result.keys, unorderedEquals(['comments', 'likes']));
      expect(result['comments']!.single['id'], 'c1');
      expect(result['likes']!.single['id'], 'l1');
      expect(
        result['comments']!.single['ownerId'],
        'other',
        reason: 'a foreign row keeps its ORIGINAL ownerId — that is what makes '
            'it a foreign row on import, and rewriting it would make the next '
            'push try to send somebody else\'s comment.',
      );
    });

    test('costs no round trip at all when there is nothing to ask about',
        () async {
      final result = await remote.fetchEngagementByParentIds(
        ascentIds: const [],
        wallIds: const [],
      );

      expect(fake.requested, isEmpty);
      expect(result['comments'], isEmpty);
      expect(result['likes'], isEmpty);
    });

    test('CHUNKS the by-id filter: more ids than the chunk size means more '
        'than one request, and every id appears in exactly one chunk',
        () async {
      // 2.4 chunks' worth, so the last chunk is a partial one.
      final ascentIds = [for (var i = 0; i < 360; i++) 'as-$i'];

      await remote.fetchEngagementByParentIds(
        ascentIds: ascentIds,
        wallIds: const [],
      );

      final commentQueries = [
        for (var i = 0; i < fake.requested.length; i++)
          if (fake.requested[i] == 'comments') fake.queries[i],
      ];
      expect(
        commentQueries,
        hasLength(3),
        reason: '360 ids at $kInboundEngagementChunkSize per request. A single '
            'unbounded inFilter would put all 360 ids in one URL, which is the '
            'failure mode this chunking exists to prevent.',
      );

      // Reconstruct the partition from the wire, not from the helper — this is
      // the assertion that the REQUESTS (not just `chunkSyncIds`) partition the
      // ids. `inFilter` shapes as `ascentId=in.("a","b")`.
      final onTheWire = <String>[];
      for (final q in commentQueries) {
        final decoded = Uri.decodeQueryComponent(q);
        final match = RegExp(r'ascentId=in\.\((.*?)\)').firstMatch(decoded);
        expect(match, isNotNull, reason: 'unexpected filter shape: $decoded');
        onTheWire.addAll(
          match!.group(1)!.split(',').map((s) => s.replaceAll('"', '')),
        );
      }
      expect(onTheWire, orderedEquals(ascentIds));
      expect(onTheWire.toSet(), hasLength(ascentIds.length));
    });

    test('asks both tables on both columns, and de-duplicates a row that '
        'matches twice', () async {
      // The only row shape that can come back from two of the four queries: a
      // comment carrying BOTH parents. No current writer produces one, but the
      // fetch must not import it twice if the backend ever holds one.
      fake.rows['comments'] = [
        {
          ..._validRow('comments', 'c1'),
          'ascentId': 'as1',
          'wallId': 'w1',
        },
      ];

      final result = await remote.fetchEngagementByParentIds(
        ascentIds: const ['as1'],
        wallIds: const ['w1'],
      );

      expect(fake.requested.where((t) => t == 'comments'), hasLength(2));
      expect(fake.requested.where((t) => t == 'likes'), hasLength(2));
      expect(result['comments'], hasLength(1));
    });

    test('drops a row missing a required NOT NULL field, keeping valid '
        'siblings', () async {
      fake.rows['comments'] = [
        {..._validRow('comments', 'good'), 'ascentId': 'as1'},
        // No `body`, which `Comment.fromJson` would throw on.
        {'id': 'bad', 'createdAt': 1, 'updatedAt': 1, 'ascentId': 'as1'},
      ];

      final result = await remote.fetchEngagementByParentIds(
        ascentIds: const ['as1'],
        wallIds: const [],
      );

      expect(result['comments']!.map((r) => r['id']), ['good']);
    });

    test('does NOT filter out tombstones — a deletion has to propagate too',
        () async {
      fake.rows['comments'] = [
        {..._validRow('comments', 'c1'), 'ascentId': 'as1', 'deletedAt': 999},
      ];

      final result = await remote.fetchEngagementByParentIds(
        ascentIds: const ['as1'],
        wallIds: const [],
      );

      expect(
        result['comments']!.single['deletedAt'],
        999,
        reason: 'a server-side `deletedAt IS NULL` filter here would mean a '
            'comment its author deleted stays visible on this device forever, '
            'because nothing else would ever tell this device it is gone. The '
            'READ path hides tombstones (CommentsRepository filters '
            'deletedAt.isNull()); the sync path must carry them.',
      );
    });
  });

  group('consistentInboundEngagement', () {
    test('keeps a row whose only parent is one we asked about', () async {
      final rows = [
        {'id': 'c1', 'ascentId': 'as1', 'wallId': null},
        {'id': 'c2', 'ascentId': null, 'wallId': 'w1'},
      ];

      expect(
        consistentInboundEngagement(
          rows,
          knownAscentIds: {'as1'},
          knownWallIds: {'w1'},
        ).map((r) => r['id']),
        ['c1', 'c2'],
      );
    });

    test('drops a row whose second parent is one this device does not hold',
        () async {
      // Would reach `importSnapshot` as an orphan, get DEFERRED, and surface as
      // the permanent "Couldn't sync — Retry" banner.
      expect(
        consistentInboundEngagement(
          [
            {'id': 'c1', 'ascentId': 'as1', 'wallId': 'w-elsewhere'},
          ],
          knownAscentIds: {'as1'},
          knownWallIds: {'w1'},
        ),
        isEmpty,
      );
    });

    test('keeps a parentless row — it has no FK to violate', () async {
      expect(
        consistentInboundEngagement(
          [
            {'id': 'c1', 'ascentId': null, 'wallId': null},
          ],
          knownAscentIds: const {},
          knownWallIds: const {},
        ),
        hasLength(1),
      );
    });
  });

  // The production half of the un-share observability fix. `sync_service_test`
  // proves the PUSH reports an un-share that removed nothing; this proves the
  // real `SupabaseSyncRemote` gives it the information to notice — because a
  // Storage delete that RLS filtered to nothing is an HTTP 200 with an empty
  // list, which is what made the whole failure mode invisible.
  group('removeSharedPhoto', () {
    test(
      'requests BOTH published objects in one call — the original and its '
      'shared/thumbs companion',
      () async {
        await remote.removeSharedPhoto(photoId: 'p1', ext: '.jpg');

        expect(fake.requested, ['topo-photos']);
        expect(fake.bodies.single, contains('shared/p1.jpg'));
        expect(
          fake.bodies.single,
          contains('shared/thumbs/p1.jpg'),
          reason:
              'a thumbnail outliving the original it was derived from is the '
              'same world-readable leak the un-share exists to close',
        );
      },
    );

    test('returns exactly the object paths Storage says it removed', () async {
      fake.rows['topo-photos'] = [
        {'name': 'shared/p1.jpg'},
        {'name': 'shared/thumbs/p1.jpg'},
      ];

      expect(await remote.removeSharedPhoto(photoId: 'p1', ext: '.jpg'), {
        'shared/p1.jpg',
        'shared/thumbs/p1.jpg',
      });
    });

    test(
      'a response listing only the ORIGINAL comes back as just that — a photo '
      'published before the thumbnail tier has no companion to remove',
      () async {
        fake.rows['topo-photos'] = [
          {'name': 'shared/p1.jpg'},
        ];

        expect(await remote.removeSharedPhoto(photoId: 'p1', ext: '.jpg'), {
          'shared/p1.jpg',
        });
      },
    );

    test(
      'an EMPTY 200 response — the shape a delete filtered by RLS returns — '
      'comes back as an empty set rather than a silent success',
      () async {
        // No `fake.rows['topo-photos']`, so the bucket answers `[]` with a 200.
        // Nothing throws, nothing is logged, and before this returned anything
        // the caller had no way to tell this apart from a real removal.
        expect(
          await remote.removeSharedPhoto(photoId: 'p1', ext: '.jpg'),
          isEmpty,
        );
      },
    );

    test(
      'a StorageException is still swallowed — best-effort, never throws out of '
      'the push — but reports having removed nothing',
      () async {
        fake.status = 403;

        expect(
          await remote.removeSharedPhoto(photoId: 'p1', ext: '.jpg'),
          isEmpty,
        );
      },
    );
  });
}
