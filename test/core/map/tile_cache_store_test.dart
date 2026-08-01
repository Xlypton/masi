// Exercises the REAL IdbTileCacheStore against idb_shim's in-memory factory
// (`newIdbFactoryMemory()`), which runs on the plain Dart VM — the same
// pattern `test/features/topo/data/photo_byte_store_test.dart` uses for
// `IdbPhotoByteStore`. Only the injected `IdbFactory` differs from the web
// build, so this genuinely covers the store's read/write/LRU logic.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:idb_shim/idb_client_memory.dart';
import 'package:masi/core/map/tile_cache_store.dart';

Uint8List _bytes(int n, [int fill = 7]) =>
    Uint8List.fromList(List<int>.filled(n, fill));

void main() {
  late IdbTileCacheStore store;
  var now = 1000;

  setUp(() {
    now = 1000;
    store = IdbTileCacheStore(factory: newIdbFactoryMemory(), nowMs: () => now);
  });

  test('write then read round-trips bytes and metadata', () async {
    await store.write(
      'https://tiles/1/2/3.png',
      bytes: _bytes(64),
      staleAtMs: 5000,
      etag: 'W/"abc"',
      lastModifiedMs: 900,
    );

    final record = await store.read('https://tiles/1/2/3.png');

    expect(record, isNotNull);
    expect(record!.bytes, equals(_bytes(64)));
    expect(record.staleAtMs, 5000);
    expect(record.etag, 'W/"abc"');
    expect(record.lastModifiedMs, 900);
    expect(record.sizeBytes, 64);
    expect(record.lastUsedMs, 1000);
  });

  test('read of an absent url returns null', () async {
    expect(await store.read('https://tiles/nope.png'), isNull);
  });

  test('totalBytes sums every stored tile and survives a reopen', () async {
    await store.write('a', bytes: _bytes(100), staleAtMs: 1);
    await store.write('b', bytes: _bytes(250), staleAtMs: 1);

    expect(await store.totalBytes(), 350);

    // A NEW store instance over the same factory models a page reload: the
    // running total must be recomputed from disk, not assumed to be zero.
    final reopened = IdbTileCacheStore(
      factory: store.debugFactory,
      nowMs: () => now,
    );
    expect(await reopened.totalBytes(), 350);
  });

  test('overwriting a url replaces its bytes and adjusts the total', () async {
    await store.write('a', bytes: _bytes(100), staleAtMs: 1);
    await store.write('a', bytes: _bytes(40), staleAtMs: 1);

    expect(await store.totalBytes(), 40);
    expect((await store.read('a'))!.sizeBytes, 40);
  });

  test('read touches lastUsed so the LRU order tracks reads, not writes', () async {
    now = 1000;
    await store.write('old', bytes: _bytes(10), staleAtMs: 1);
    now = 2000;
    await store.write('new', bytes: _bytes(10), staleAtMs: 1);

    now = 3000;
    await store.read('old'); // 'old' is now the MOST recently used.

    now = 4000;
    await store.evictLruUntilUnder(10);

    expect(await store.read('old'), isNotNull);
    expect(await store.read('new'), isNull);
  });

  test('touch() updates recency without re-reading the bytes', () async {
    now = 1000;
    await store.write('a', bytes: _bytes(10), staleAtMs: 1);
    now = 2000;
    await store.write('b', bytes: _bytes(10), staleAtMs: 1);

    now = 3000;
    await store.touch('a');
    now = 4000;
    await store.evictLruUntilUnder(10);

    expect(await store.read('a'), isNotNull);
    expect(await store.read('b'), isNull);
  });

  test(
    'evictLruUntilUnder removes least-recently-used entries until under '
    'the cap, and deletes BOTH the bytes and the metadata',
    () async {
      for (var i = 0; i < 5; i++) {
        now = 1000 + i;
        await store.write('t$i', bytes: _bytes(100), staleAtMs: 1);
      }
      expect(await store.totalBytes(), 500);

      await store.evictLruUntilUnder(250);

      expect(await store.totalBytes(), lessThanOrEqualTo(250));
      expect(await store.read('t0'), isNull);
      expect(await store.read('t1'), isNull);
      expect(await store.read('t4'), isNotNull);
      // No orphaned metadata: a re-scan agrees with the byte total.
      final reopened = IdbTileCacheStore(
        factory: store.debugFactory,
        nowMs: () => now,
      );
      expect(await reopened.totalBytes(), await store.totalBytes());
    },
  );

  test('evictLruUntilUnder(0) empties the store', () async {
    await store.write('a', bytes: _bytes(10), staleAtMs: 1);
    await store.write('b', bytes: _bytes(10), staleAtMs: 1);

    await store.evictLruUntilUnder(0);

    expect(await store.totalBytes(), 0);
    expect(await store.read('a'), isNull);
  });

  test('clear() empties both stores and resets the total', () async {
    await store.write('a', bytes: _bytes(10), staleAtMs: 1);
    await store.clear();

    expect(await store.totalBytes(), 0);
    expect(await store.read('a'), isNull);
  });

  test(
    'metadata orphaned by a torn write reads as a miss and is dropped, so the '
    'byte total cannot drift upwards forever',
    () async {
      await store.write('a', bytes: _bytes(100), staleAtMs: 1);
      // Simulate a partially-applied eviction / interrupted put: the bytes are
      // gone but the metadata record survives.
      await store.debugDeleteBytesOnly('a');

      expect(await store.read('a'), isNull);
      // The orphan has been reaped: a fresh scan sees nothing at all.
      final reopened = IdbTileCacheStore(
        factory: store.debugFactory,
        nowMs: () => now,
      );
      expect(await reopened.totalBytes(), 0);
    },
  );
}
