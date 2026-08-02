// S6: every Supabase Storage listing must page. `list()`'s SearchOptions
// default is `limit: 100, offset: 0`
// (storage_client-2.6.0/lib/src/types.dart:217-222) and the endpoint returns at
// most `limit` objects with NO total count and no "there is more" flag — so a
// single un-paged call silently truncated the sync push's "already uploaded"
// skip-set at 100, making every push re-read and re-upload the
// FULL-RESOLUTION bytes of every photo past that cut.
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/features/backup/data/storage_pagination.dart';

void main() {
  /// A page fetcher faithful to the Storage `list()` contract — at most [limit]
  /// items starting at [offset], stable order — that records every request it
  /// received so a test can prove the loop actually PAGED.
  ({
    Future<List<int>> Function(int limit, int offset) fetch,
    List<({int limit, int offset})> requests,
  })
  fetcherOver(int total) {
    final requests = <({int limit, int offset})>[];
    Future<List<int>> fetch(int limit, int offset) async {
      requests.add((limit: limit, offset: offset));
      if (offset >= total) return const [];
      final end = offset + limit;
      final stop = end > total ? total : end;
      return [for (var i = offset; i < stop; i++) i];
    }

    return (fetch: fetch, requests: requests);
  }

  test('kStoragePageSize matches the storage client SearchOptions default', () {
    expect(kStoragePageSize, 100);
  });

  test('150 objects are ALL collected, across two pages at offsets 0 and 100', () async {
    final f = fetcherOver(150);

    final all = await collectPagedObjects<int>(f.fetch);

    expect(all, hasLength(150));
    expect(all.first, 0);
    expect(all.last, 149);
    expect(f.requests, [(limit: 100, offset: 0), (limit: 100, offset: 100)]);
  });

  test(
    'an exactly-full final page costs one more request, which comes back '
    'empty — the only way to tell "one page" from "the first of several"',
    () async {
      final f = fetcherOver(100);

      final all = await collectPagedObjects<int>(f.fetch);

      expect(all, hasLength(100));
      expect(f.requests, [(limit: 100, offset: 0), (limit: 100, offset: 100)]);
    },
  );

  test('an empty prefix costs exactly one request', () async {
    final f = fetcherOver(0);

    expect(await collectPagedObjects<int>(f.fetch), isEmpty);
    expect(f.requests, [(limit: 100, offset: 0)]);
  });

  test('a short first page terminates immediately', () async {
    final f = fetcherOver(7);

    expect(await collectPagedObjects<int>(f.fetch), hasLength(7));
    expect(f.requests, [(limit: 100, offset: 0)]);
  });

  test('pageSize is injectable so fixtures stay small', () async {
    final f = fetcherOver(7);

    final all = await collectPagedObjects<int>(f.fetch, pageSize: 3);

    expect(all, [0, 1, 2, 3, 4, 5, 6]);
    expect(f.requests.map((r) => r.offset), [0, 3, 6]);
  });

  test('a non-positive pageSize is rejected rather than looping forever', () async {
    await expectLater(
      collectPagedObjects<int>((limit, offset) async => const [], pageSize: 0),
      throwsA(isA<ArgumentError>()),
    );
  });
}
