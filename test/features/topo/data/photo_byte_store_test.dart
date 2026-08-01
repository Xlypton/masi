// Exercises the REAL IdbPhotoByteStore (no fake) against idb_shim's
// in-memory factory (`newIdbFactoryMemory()`), which runs on the plain Dart
// VM. This is the same class the web build uses with the real browser
// factory (`idb.idbFactoryWeb`) — only the injected `IdbFactory` differs —
// so these tests genuinely cover the store's put/get/delete logic.
import 'dart:typed_data';

import 'package:masi/features/topo/data/photo_byte_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idb_shim/idb_client_memory.dart';

void main() {
  late PhotoByteStore store;

  setUp(() {
    // A fresh in-memory factory per test keeps state isolated even though
    // the store always opens the same fixed database name.
    store = IdbPhotoByteStore(factory: newIdbFactoryMemory());
  });

  test('write then read round-trips bytes', () async {
    final bytes = Uint8List.fromList([1, 2, 3, 4, 5]);
    await store.writeBytes('photos/abc.jpg', bytes);

    final read = await store.readBytes('photos/abc.jpg');

    expect(read, equals(bytes));
  });

  test('read of an absent key returns null', () async {
    final read = await store.readBytes('photos/does-not-exist.jpg');

    expect(read, isNull);
  });

  test('exists is false before write and true after', () async {
    expect(await store.exists('thumbs/xyz.jpg'), isFalse);

    await store.writeBytes('thumbs/xyz.jpg', Uint8List.fromList([9, 9]));

    expect(await store.exists('thumbs/xyz.jpg'), isTrue);
  });

  test('delete removes the record', () async {
    await store.writeBytes('photos/gone.jpg', Uint8List.fromList([1, 2, 3]));
    expect(await store.exists('photos/gone.jpg'), isTrue);

    await store.delete('photos/gone.jpg');

    expect(await store.exists('photos/gone.jpg'), isFalse);
    expect(await store.readBytes('photos/gone.jpg'), isNull);
  });

  test('delete is a no-op when the key is absent', () async {
    // Must not throw.
    await store.delete('photos/never-existed.jpg');

    expect(await store.exists('photos/never-existed.jpg'), isFalse);
  });

  test('overwrite replaces the stored bytes', () async {
    await store.writeBytes('photos/dup.jpg', Uint8List.fromList([1, 2]));
    await store.writeBytes('photos/dup.jpg', Uint8List.fromList([9, 9, 9]));

    final read = await store.readBytes('photos/dup.jpg');

    expect(read, equals(Uint8List.fromList([9, 9, 9])));
  });

  test('distinct keys do not collide', () async {
    await store.writeBytes('photos/one.jpg', Uint8List.fromList([1]));
    await store.writeBytes('thumbs/one.jpg', Uint8List.fromList([2]));

    expect(await store.readBytes('photos/one.jpg'), equals(Uint8List.fromList([1])));
    expect(await store.readBytes('thumbs/one.jpg'), equals(Uint8List.fromList([2])));
  });

  test(
    'writeBytes surfaces a store-side failure rather than resolving silently '
    '— this is the failure PhotoFiles.importPhoto now propagates as a '
    'PhotoWriteException instead of swallowing (L3)',
    () async {
      final factory = newIdbFactoryMemory();
      final store = IdbPhotoByteStore(factory: factory);
      // Force the write into a store that does not exist: a real IndexedDB
      // transaction against a missing object store rejects, exactly like a
      // quota rejection does from this method's point of view.
      final db = await factory.open(
        kPhotoByteStoreDbName,
        version: 1,
        onUpgradeNeeded: (event) {
          // Deliberately create NOTHING, so `kPhotoByteStoreName` is absent.
        },
      );
      addTearDown(db.close);

      await expectLater(
        store.writeBytes('photos/abc.jpg', Uint8List.fromList([1, 2, 3])),
        throwsA(anything),
      );
    },
  );
}
