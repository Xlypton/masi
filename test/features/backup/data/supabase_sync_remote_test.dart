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

    // Drain the body. GETs have none; an `upsert` POST does, and leaving it
    // unread can stall the client mid-write on a keep-alive connection.
    await req.drain<void>();

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
      // `photoId` is pinned to the seeded photo rather than left to
      // `_validRow`'s generated `photoId-of-r1`, which named a photo that was
      // never in the batch. `routes.photoId -> photos` is a NOT NULL FK, so
      // that fixture described a batch the importer could not actually write.
      fake.rows['routes'] = [
        {..._validRow('routes', 'r1'), 'wallId': 'w1', 'photoId': 'p1'},
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

    test(
      'drops a shared route whose photo row is absent, so a permanently '
      'orphaned route cannot wedge every pull on "parent row missing"',
      () async {
        // Observed live on 2026-08-26: four shared routes across two walls
        // referenced `photos` ids with no row at all — one of the walls had no
        // photos on the server whatsoever. `routes.photoId -> photos` is a
        // NOT NULL FK locally, so the importer deferred them and SyncService
        // reported `shared rows deferred (parent row missing)` on EVERY pull.
        // Unlike a fetch race, this never heals on its own: the same routes
        // come back and the same photo is still gone.
        seedSharedWall();
        fake.rows['routes'] = [
          {..._validRow('routes', 'r1'), 'wallId': 'w1', 'photoId': 'p1'},
          {
            ..._validRow('routes', 'orphan'),
            'wallId': 'w1',
            'photoId': 'photo-that-does-not-exist',
          },
        ];

        final result = await remote.fetchSharedTopos();

        expect(
          [for (final r in result['routes']!) r['id']],
          ['r1'],
          reason: 'the route with a resolvable photo survives; the orphan is '
              'dropped rather than handed to the importer, which could only '
              'defer it',
        );
        // The batch that comes back must be internally consistent — that is
        // what lets any REMAINING deferral still be treated as a real defect
        // rather than routine noise (#72).
        final photoIds = {for (final p in result['photos']!) p['id']};
        for (final route in result['routes']!) {
          expect(photoIds, contains(route['photoId']));
        }
      },
    );

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

  // ---------------------------------------------------------------------
  // The write-side referential guard.
  //
  // What it prevents, observed on the live dev project on 2026-08-27: four
  // live routes across two PUBLISHED walls pointing at two photo ids with no
  // row at all. One of those walls has zero photo rows and one route, so it
  // sits in the community feed and can never render. The Storage objects for
  // both photos exist — the bytes uploaded and only the metadata row never
  // landed — and with no outbox nothing revisits it.
  //
  // `syncTableNames` puts `photos` before `routes`, so a photo held back by
  // the S5 bytes-before-metadata rule was routinely followed by the routes
  // that point at it going up anyway.
  // ---------------------------------------------------------------------
  // ---------------------------------------------------------------------
  // `route_lines` is the only sync table with TWO parents, and it spent a
  // long time not being pushed at all: it was in `syncTableNames`, in
  // `syncRequiredFields`, in the backup snapshot and in the remote schema
  // with its own RLS — but had no key in `pushOwn`'s `tablesToRows`, and
  // `upsertOwnRows` skips a missing key with a bare `continue`. So a climb
  // drawn on a second photo was pulled, exported and rendered locally, and
  // never once uploaded. Silently, in both directions.
  // ---------------------------------------------------------------------
  group('routeLinesWithResolvableParents', () {
    Map<String, dynamic> line(String id, String routeId, String photoId) =>
        {'id': id, 'routeId': routeId, 'photoId': photoId};

    test('withholds a line whose PHOTO this push held back', () {
      final withheld = <String>[];
      final kept = routeLinesWithResolvableParents(
        routeLines: [line('l1', 'r1', 'p1'), line('l2', 'r1', 'p2')],
        withheldPhotoIds: {'p1'},
        withheldRouteIds: const {},
        onWithheld: (id, parent, parentId) =>
            withheld.add('$id->$parent:$parentId'),
      );

      expect(kept.map((l) => l['id']), ['l2']);
      expect(withheld, ['l1->photo:p1']);
    });

    test('withholds a line whose ROUTE this push held back — the second-order '
        'case the photo check alone cannot see', () {
      // This is the one that matters and the one a single-parent guard
      // misses. A route is itself withheld when ITS photo was held back, so
      // one photo whose bytes did not land can orphan a line drawn on a
      // completely different, perfectly healthy photo.
      final withheld = <String>[];
      final kept = routeLinesWithResolvableParents(
        routeLines: [line('l1', 'r1', 'p-healthy')],
        withheldPhotoIds: const {},
        withheldRouteIds: {'r1'},
        onWithheld: (id, parent, parentId) =>
            withheld.add('$id->$parent:$parentId'),
      );

      expect(kept, isEmpty);
      expect(withheld, ['l1->route:r1']);
    });

    test('the server will not catch what this misses', () {
      // Stated as a test because it is the reason this guard exists at all:
      // `public.route_lines` declares routeId/photoId as bare TEXT NOT NULL
      // with NO REFERENCES clause, so Postgres accepts an orphan line without
      // complaint. The local table DOES carry both FKs, so the failure lands
      // on whichever device pulls it next — far from the push that caused it.
      final kept = routeLinesWithResolvableParents(
        routeLines: [line('l1', 'r-gone', 'p-gone')],
        withheldPhotoIds: {'p-gone'},
        withheldRouteIds: {'r-gone'},
      );

      expect(kept, isEmpty,
          reason: 'withheld once, re-sent by the next full push (D-4)');
    });

    test('is a no-op when neither parent set holds anything back', () {
      final lines = [line('l1', 'r1', 'p1'), line('l2', 'r2', 'p2')];
      var called = 0;

      final kept = routeLinesWithResolvableParents(
        routeLines: lines,
        withheldPhotoIds: const {},
        withheldRouteIds: const {},
        onWithheld: (_, _, _) => called++,
      );

      expect(identical(kept, lines), isTrue,
          reason: 'the overwhelmingly common push returns the original list '
              'without copying it');
      expect(called, 0);
    });

    test('a parent merely ABSENT from the push is not a reason to withhold',
        () {
      // The dirtyOnly hazard, inherited from the sibling guard: a clean,
      // long-since-synced route and photo are both absent by design, and
      // treating absence as danger would stop a newly drawn second line —
      // the exact row this whole fix exists to deliver — from ever syncing.
      final kept = routeLinesWithResolvableParents(
        routeLines: [line('l1', 'route-synced-last-week', 'photo-ditto')],
        withheldPhotoIds: {'some-other-photo'},
        withheldRouteIds: {'some-other-route'},
      );

      expect(kept.map((l) => l['id']), ['l1']);
    });

    test('a line with a null or non-String parent id is kept, and left to the '
        'required-field guard', () {
      final kept = routeLinesWithResolvableParents(
        routeLines: [
          {'id': 'l1', 'routeId': null, 'photoId': null},
          {'id': 'l2'},
        ],
        withheldPhotoIds: {'p1'},
        withheldRouteIds: {'r1'},
      );

      expect(kept.map((l) => l['id']), ['l1', 'l2'],
          reason: 'one guard, one question — a malformed row is '
              'syncRequiredFields\' job.');
    });
  });

  group('routesWithResolvablePhoto', () {
    Map<String, dynamic> route(String id, String photoId) =>
        {'id': id, 'photoId': photoId, 'wallId': 'w1'};

    test('withholds exactly the routes whose photo this push held back', () {
      final withheld = <String>[];
      final kept = routesWithResolvablePhoto(
        routes: [route('r1', 'p1'), route('r2', 'p2'), route('r3', 'p1')],
        withheldPhotoIds: {'p1'},
        onWithheld: (routeId, photoId) => withheld.add('$routeId->$photoId'),
      );

      expect(kept.map((r) => r['id']), ['r2']);
      expect(withheld, ['r1->p1', 'r3->p1'],
          reason: 'every withheld route must be REPORTED, not dropped with a '
              'debugPrint — with no outbox, "excluded once" silently meant '
              '"excluded forever" (the L5 lesson).');
    });

    test('is a no-op when nothing was held back — the overwhelmingly common '
        'push must be untouched', () {
      final routes = [route('r1', 'p1'), route('r2', 'p2')];
      var called = 0;

      final kept = routesWithResolvablePhoto(
        routes: routes,
        withheldPhotoIds: const {},
        onWithheld: (_, _) => called++,
      );

      expect(identical(kept, routes), isTrue,
          reason: 'not merely equal — the empty case returns the original '
              'list without copying it');
      expect(called, 0);
    });

    test('a photo merely ABSENT from the push is not a reason to withhold', () {
      // The dirtyOnly hazard. A clean, long-since-synced photo is absent from
      // the push by design; treating absence as danger would stop ordinary
      // route edits from ever syncing.
      final kept = routesWithResolvablePhoto(
        routes: [route('r1', 'photo-synced-last-week')],
        withheldPhotoIds: {'some-other-photo'},
      );

      expect(kept.map((r) => r['id']), ['r1']);
    });

    test('a route with a null or non-String photoId is kept, and left to the '
        'required-field guard', () {
      final kept = routesWithResolvablePhoto(
        routes: [
          {'id': 'r1', 'photoId': null},
          {'id': 'r2'},
        ],
        withheldPhotoIds: {'p1'},
      );

      expect(kept.map((r) => r['id']), ['r1', 'r2'],
          reason: 'this guard answers one question — is the photo being held '
              'back. A malformed row is syncRequiredFields\' job, and having '
              'two guards silently cover for each other is how a gap opens '
              'when one of them moves.');
    });
  });

  // ---------------------------------------------------------------------
  // `IN`-filter chunking.
  //
  // The bug these pin: PostgREST puts an `IN` list in the QUERY STRING, so an
  // unbounded `inFilter` grows the request line ~39 bytes per uuid id and the
  // gateway rejects it as an opaque 414 somewhere past ~200 ids. Both reachable
  // call sites scale with the USER'S DATA — a full push sends one id per own
  // row, and `fetchSharedTopos` fans out over up to 550 wall ids — so this was
  // a failure that switched on as a library grew and then never healed.
  //
  // Asserted on the wire (`fake.queries`), not on an internal counter: the
  // guarantee that matters is the length of the request PostgREST actually
  // receives, and only the wire shows that.
  // ---------------------------------------------------------------------
  group('IN-filter chunking', () {
    /// Every `id=in.(…)` query string the fake saw, in arrival order.
    List<String> inQueries() =>
        fake.queries.where((q) => q.contains('in.')).toList();

    /// How many ids one `id=in.("a","b")` query string carries.
    ///
    /// Decoded first so the count is the same whether `Uri.query` handed back
    /// the percent-encoded or the decoded form — the assertion is about the
    /// number of ids on the wire, not about which escaping the client chose.
    int idsIn(String query) {
      final decoded = Uri.decodeComponent(query);
      final start = decoded.indexOf('in.(');
      expect(start, isNonNegative, reason: 'not an IN query: $query');
      final end = decoded.indexOf(')', start);
      final list = decoded.substring(
        start + 'in.('.length,
        end == -1 ? decoded.length : end,
      );
      return list.isEmpty ? 0 : list.split(',').length;
    }

    test('chunkForInFilter splits at the documented size and never emits an '
        'empty or oversized chunk', () {
      expect(chunkForInFilter(<String>[]), isEmpty,
          reason: 'an empty id list must issue NO request at all, not one '
              'request with an empty IN list (which PostgREST reads as '
              '"match nothing" — same result, wasted round trip).');
      expect(chunkForInFilter(['a']), [
        ['a']
      ]);

      final ids = [for (var i = 0; i < 250; i++) 'id-$i'];
      final chunks = chunkForInFilter(ids);

      expect(chunks, hasLength(3));
      expect(chunks.map((c) => c.length), [100, 100, 50]);
      expect(chunks.expand((c) => c), orderedEquals(ids),
          reason: 'chunking must partition — never drop, duplicate or '
              'reorder an id. A dropped id in the push pre-check silently '
              'clobbers a newer cloud row.');
      expect(
        chunks.every((c) => c.length <= kSyncInFilterChunkSize && c.isNotEmpty),
        isTrue,
      );
    });

    test('a push larger than one chunk splits BOTH the last-writer-wins '
        'pre-check and the upsert, instead of 414ing the whole table',
        () async {
      // 250 rows: comfortably past the ~200-id point where the request line
      // exceeds the gateway limit, and not a round multiple of the chunk size,
      // so an off-by-one in the tail would show.
      final rows = [
        for (var i = 0; i < 250; i++)
          {..._validRow('areas', 'a$i', ownerId: 'uid-1'), 'updatedAt': 5},
      ];

      final outcomes = await remote.upsertOwnRows('uid-1', {'areas': rows});

      final selects = inQueries();
      expect(selects, hasLength(3),
          reason: 'the LWW pre-check must be split into ceil(250/100) '
              'requests. One request means the unbounded form is back and '
              'this table 414s for any library past ~200 rows.');
      for (final q in selects) {
        expect(idsIn(q), lessThanOrEqualTo(kSyncInFilterChunkSize));
      }

      // The upsert is a POST with no URL limit, but a full push of a large
      // library is otherwise one multi-megabyte all-or-nothing body.
      expect(
        fake.requested.where((t) => t == 'areas'),
        hasLength(6),
        reason: '3 pre-check SELECTs + 3 upsert POSTs. A count of 4 means the '
            'upsert body was never split.',
      );

      expect(outcomes, hasLength(1));
      expect(outcomes.single.rowsUpserted, 250);
      expect(outcomes.single.rowsFailed, 0);
    });

    test('a push at or below one chunk issues exactly one pre-check request — '
        'chunking costs the common case nothing', () async {
      final rows = [
        for (var i = 0; i < kSyncInFilterChunkSize; i++)
          {..._validRow('areas', 'a$i', ownerId: 'uid-1'), 'updatedAt': 5},
      ];

      await remote.upsertOwnRows('uid-1', {'areas': rows});

      expect(inQueries(), hasLength(1));
    });

    test('a remote row with a null updatedAt is treated as absent, so ONE '
        'malformed cloud row cannot fail the whole table forever', () async {
      fake.rows['areas'] = [
        {'id': 'a0', 'updatedAt': null},
      ];
      final rows = [
        {..._validRow('areas', 'a0', ownerId: 'uid-1'), 'updatedAt': 5},
      ];

      final outcomes = await remote.upsertOwnRows('uid-1', {'areas': rows});

      expect(outcomes.single.rowsFailed, 0,
          reason: 'the pre-check used a bare `as int` cast, so a null '
              'updatedAt threw and the catch reported EVERY row of the table '
              'as failed — on every subsequent push too, since the bad row '
              'stays.');
      expect(outcomes.single.rowsUpserted, 1,
          reason: 'absent remote knowledge means shouldPushLww says push, '
              'which is the direction that cannot lose local work.');
    });

    test('fetchSharedTopos splits the wall-keyed fan-out — 550 walls is the '
        'scope the app actually ships (kSharedTopoLimit + uncoordinated)',
        () async {
      fake.rows['walls'] = [
        for (var i = 0; i < 550; i++)
          {
            ..._validRow('walls', 'w$i', ownerId: 'other'),
            'sectorId': 's$i',
            'visibility': 'shared',
          },
      ];

      await remote.fetchSharedTopos();

      final selects = inQueries();
      expect(selects, isNotEmpty);
      for (final q in selects) {
        expect(idsIn(q), lessThanOrEqualTo(kSyncInFilterChunkSize),
            reason: 'unchunked, 550 wall ids is ~21 KB of query string — over '
                'the gateway limit at the default scope, i.e. broken for '
                'everyone in a busy area, not an edge case.');
      }
      // photos/routes/comments/likes are all keyed on the 550 wall ids.
      for (final table in ['photos', 'routes', 'comments', 'likes']) {
        expect(fake.requested.where((t) => t == table), hasLength(6),
            reason: '$table must be fetched in ceil(550/100) chunks');
      }
    });
  });
}
