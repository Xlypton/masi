// Exercises the WEB `PhotoFiles` backend directly, on the plain Dart VM.
//
// `photo_files_web.dart` is VM-importable even though it is the web branch of
// the `photo_files.dart` conditional-export facade: its only
// platform-specific dependency is `image_ops/image_ops.dart`, itself a
// conditional export that resolves to the pure-Dart `image_ops_native.dart`
// here, plus `photo_byte_store.dart` (already VM-tested in
// `photo_byte_store_test.dart` — its `idb.idbFactoryWeb` default is only ever
// evaluated when no factory is supplied). Importing the BRANCH file directly
// rather than the facade — which the VM would resolve to the NATIVE backend —
// is what makes the L3 fix testable with no browser test runner.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
// `DatabaseError` comes through `idb_client_memory.dart`, which re-exports the
// core `idb.dart` API — importing both would trip `unnecessary_import`.
import 'package:idb_shim/idb_client_memory.dart';
import 'package:image_picker/image_picker.dart';
import 'package:masi/features/topo/data/photo_byte_store.dart';
import 'package:masi/features/topo/data/photo_files_web.dart';
import 'package:masi/features/topo/data/photo_write_exception.dart';

/// [PhotoByteStore] whose writes under [failPrefix] always throw [error], while
/// every other operation behaves like a plain in-memory map.
///
/// The prefix seam is what lets a test separate the two write sites
/// `importPhoto` performs: the ORIGINAL (`photos/…`, which must now FAIL the
/// call) and the THUMBNAIL (`thumbs/…`, which must still be swallowed).
class _FailingWriteStore implements PhotoByteStore {
  _FailingWriteStore(this.error, {this.failPrefix = 'photos/'});

  final Object error;
  final String failPrefix;
  final Map<String, Uint8List> written = {};

  @override
  Future<void> writeBytes(String key, Uint8List bytes) async {
    if (key.startsWith(failPrefix)) throw error;
    written[key] = bytes;
  }

  @override
  Future<Uint8List?> readBytes(String key) async => written[key];

  @override
  Future<void> delete(String key) async {
    written.remove(key);
  }

  @override
  Future<bool> exists(String key) async => written.containsKey(key);
}

/// A picked photo whose bytes live in memory — `XFile.fromData` short-circuits
/// `readAsBytes()` to exactly these bytes (no filesystem), and its `name` is
/// the basename of `path`, which is what `importPhoto` reads the extension
/// from.
XFile _pickedJpeg([List<int> bytes = const [1, 2, 3, 4]]) =>
    XFile.fromData(Uint8List.fromList(bytes), path: '/picked/wall.jpg');

void main() {
  group('importPhoto propagates a byte-write failure (L3)', () {
    test('a QuotaExceededError-shaped failure throws a PhotoWriteException '
        'classified as quotaExceeded, and nothing is left in the store',
        () async {
      final store = _FailingWriteStore(
        DatabaseError('QuotaExceededError: The quota has been exceeded.'),
      );
      final files = PhotoFiles(byteStore: store);

      await expectLater(
        files.importPhoto(_pickedJpeg(), 'abc123'),
        throwsA(
          isA<PhotoWriteException>()
              .having(
                (e) => e.failure,
                'failure',
                PhotoWriteFailure.quotaExceeded,
              )
              .having((e) => e.key, 'key', 'photos/abc123.jpg'),
        ),
      );
      expect(store.written, isEmpty);
    });

    test('any other store failure throws a PhotoWriteException classified as '
        'unknown', () async {
      final files = PhotoFiles(
        byteStore: _FailingWriteStore(
          DatabaseError('InvalidStateError: database is closed'),
        ),
      );

      await expectLater(
        files.importPhoto(_pickedJpeg(), 'abc123'),
        throwsA(
          isA<PhotoWriteException>()
              .having((e) => e.failure, 'failure', PhotoWriteFailure.unknown),
        ),
      );
    });

    test('a THUMBNAIL write failure is still swallowed — the original landed, '
        'so importPhoto succeeds and returns the key', () async {
      final store = _FailingWriteStore(
        DatabaseError('QuotaExceededError'),
        failPrefix: 'thumbs/',
      );
      final files = PhotoFiles(byteStore: store);

      final key = await files.importPhoto(_pickedJpeg(), 'abc123');

      expect(key, 'photos/abc123.jpg');
      expect(store.written.keys, ['photos/abc123.jpg']);
    });

    test('the happy path is unchanged: original AND thumbnail both stored '
        'under their logical keys', () async {
      final store = IdbPhotoByteStore(factory: newIdbFactoryMemory());
      final files = PhotoFiles(byteStore: store);

      final key = await files.importPhoto(_pickedJpeg(), 'abc123');

      expect(key, 'photos/abc123.jpg');
      expect(
        await store.readBytes('photos/abc123.jpg'),
        Uint8List.fromList([1, 2, 3, 4]),
      );
      // 4 undecodable bytes: generateThumbnail returns the SOURCE unchanged
      // rather than throwing (image_ops_native.dart:19-34), so a thumbnail
      // record still exists.
      expect(await store.exists('thumbs/abc123.jpg'), isTrue);
    });

    test('an extensionless picked file still lands under .jpg', () async {
      final store = IdbPhotoByteStore(factory: newIdbFactoryMemory());
      final files = PhotoFiles(byteStore: store);

      final key = await files.importPhoto(
        XFile.fromData(Uint8List.fromList([9]), path: '/picked/noext'),
        'abc123',
      );

      expect(key, 'photos/abc123.jpg');
    });
  });

  group('writePhotoBytes propagates a byte-write failure (cloud restore)', () {
    test('throws a classified PhotoWriteException instead of an opaque store '
        'error', () async {
      final files = PhotoFiles(
        byteStore: _FailingWriteStore(
          DatabaseError('QuotaExceededError: The quota has been exceeded.'),
        ),
      );

      await expectLater(
        files.writePhotoBytes('abc123', '.jpg', const [1, 2, 3]),
        throwsA(
          isA<PhotoWriteException>().having(
            (e) => e.failure,
            'failure',
            PhotoWriteFailure.quotaExceeded,
          ),
        ),
      );
    });

    test('the happy path still returns the key and writes the thumbnail',
        () async {
      final store = IdbPhotoByteStore(factory: newIdbFactoryMemory());
      final files = PhotoFiles(byteStore: store);

      final key = await files.writePhotoBytes('abc123', '.jpg', const [1, 2]);

      expect(key, 'photos/abc123.jpg');
      expect(await store.exists('thumbs/abc123.jpg'), isTrue);
    });
  });

  // `PublicPhotoPruneService` decides what to delete off this answer, and a
  // wrong `true` is what made a whole prune pass "delete" 50 keys and free
  // nothing (see that service's "A ROW is not BYTES").
  group('hasPhotoBytes tells a stored key from a merely-named one', () {
    test('true only while the bytes are actually there — a written key becomes '
        'false again the moment it is deleted, which is the state a pruned or '
        'budget-skipped public photo is permanently in', () async {
      final store = IdbPhotoByteStore(factory: newIdbFactoryMemory());
      final files = PhotoFiles(byteStore: store);

      expect(
        await files.hasPhotoBytes('photos/abc123.jpg'),
        isFalse,
        reason: 'a key nothing ever wrote holds nothing',
      );

      await files.writePhotoBytes('abc123', '.jpg', const [1, 2]);
      expect(await files.hasPhotoBytes('photos/abc123.jpg'), isTrue);

      await files.deletePhotoBytes('photos/abc123.jpg');
      expect(await files.hasPhotoBytes('photos/abc123.jpg'), isFalse);
    });

    test('a store that cannot answer reports FALSE rather than throwing — '
        '"cannot tell" must never authorise a deletion', () async {
      final files = PhotoFiles(byteStore: _UnansweringStore());

      expect(await files.hasPhotoBytes('photos/abc123.jpg'), isFalse);
    });
  });
}

/// [PhotoByteStore] whose presence probe always throws — a closed connection,
/// a blocked upgrade, private-browsing limits.
class _UnansweringStore implements PhotoByteStore {
  @override
  Future<bool> exists(String key) async =>
      throw DatabaseError('InvalidStateError: database is closed');

  @override
  Future<void> writeBytes(String key, Uint8List bytes) async {}

  @override
  Future<Uint8List?> readBytes(String key) async => null;

  @override
  Future<void> delete(String key) async {}
}
