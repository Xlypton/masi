// The on-demand resolver fetching the signed-in user's OWN photos.
//
// On web a fresh sign-in now imports the user's own rows BEFORE their photo
// bytes (`SyncService.pullOwnAndShared`), so the photo a row on screen needs is
// fetched here, ahead of the pull's bulk pass. Two rules carry the weight:
// visible photos come first, and nothing below may ever leave a downscaled copy
// where the user's full-resolution original belongs (decision D-5).
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:masi/features/backup/data/sync_remote.dart';
import 'package:masi/features/topo/data/missing_photo_byte_resolver.dart';
import 'package:masi/features/topo/data/photo_files.dart';
import 'package:path/path.dart' as p;

const _uid = 'user-1';

/// Serves a private bucket and a shared bucket from two maps, and logs every
/// object path asked for.
class _Remote implements SyncRemote {
  final Map<String, List<int>> private = {};
  final Map<String, List<int>> shared = {};
  final List<String> requests = [];
  bool offline = false;
  Future<void>? gate;

  @override
  Future<List<int>?> downloadPhoto({
    required String uid,
    required String objectPath,
  }) async {
    requests.add(objectPath);
    if (gate != null) await gate;
    if (offline) throw Exception('offline');
    return private[objectPath];
  }

  @override
  Future<List<int>?> downloadSharedPhoto(String objectPath) async {
    requests.add(objectPath);
    if (offline) throw Exception('offline');
    return shared[objectPath];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unexpected call: ${invocation.memberName}');
}

void main() {
  late Directory tmp;
  late _Remote remote;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('own_photo_resolver_test_');
    remote = _Remote();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  SharedMissingPhotoByteResolver resolver({Set<String> own = const {'mine'}}) =>
      SharedMissingPhotoByteResolver(
        remote: remote,
        photoFiles: PhotoFiles(docsDir: () async => tmp),
        ownerUidIfOwn: (photoId) async => own.contains(photoId) ? _uid : null,
        originalExtFor: (photoId) async => '.jpeg',
      );

  File stored(String key) => File(p.join(tmp.path, key));

  test(
    "the canvas gets the owner's full-resolution ORIGINAL, never the display "
    'variant — even for a published photo that has one',
    () async {
      final original = List<int>.filled(64, 1);
      remote.private['$_uid/mine.jpeg'] = original;
      remote.shared['shared/display/mine.jpg'] = List<int>.filled(8, 2);

      final bytes = await resolver().resolve('photos/mine.jpeg');

      expect(bytes, original);
      expect(remote.requests, ['$_uid/mine.jpeg']);
      expect(
        stored('photos/mine.jpeg').readAsBytesSync(),
        original,
        reason: 'whatever lands under this key is what the pull later treats '
            'as already downloaded, so it must be the original',
      );
    },
  );

  test(
    'a list thumbnail of a PUBLISHED own photo costs only the small cloud '
    'thumbnail, and writes nothing under the original key',
    () async {
      final thumb = List<int>.filled(4, 7);
      remote.shared['shared/thumbs/mine.jpg'] = thumb;
      remote.private['$_uid/mine.jpeg'] = List<int>.filled(64, 1);

      final bytes = await resolver().resolve(thumbKeyFor('photos/mine.jpeg'));

      expect(bytes, thumb);
      expect(remote.requests, ['shared/thumbs/mine.jpg']);
      expect(stored('photos/mine.jpeg').existsSync(), isFalse);
    },
  );

  test(
    'a list thumbnail of an UNPUBLISHED own photo falls back to the owner\'s '
    'private original — the only place that photo exists',
    () async {
      final original = List<int>.filled(64, 1);
      remote.private['$_uid/mine.jpeg'] = original;

      final bytes = await resolver().resolve(thumbKeyFor('photos/mine.jpeg'));

      expect(bytes, isNotNull);
      expect(remote.requests, ['shared/thumbs/mine.jpg', '$_uid/mine.jpeg']);
      expect(stored('photos/mine.jpeg').readAsBytesSync(), original);
    },
  );

  test(
    'a thumbnail and the canvas asking at once download the original ONCE',
    () async {
      final gate = Completer<void>();
      remote
        ..private['$_uid/mine.jpeg'] = List<int>.filled(64, 1)
        ..gate = gate.future;
      final r = resolver();

      final thumb = r.resolve(thumbKeyFor('photos/mine.jpeg'));
      final canvas = r.resolve('photos/mine.jpeg');
      await Future<void>.delayed(Duration.zero);
      gate.complete();
      await Future.wait([thumb, canvas]);

      expect(
        remote.requests.where((r) => r == '$_uid/mine.jpeg'),
        hasLength(1),
      );
    },
  );

  test("another climber's photo never touches a private bucket", () async {
    remote.shared['shared/display/theirs.jpg'] = List<int>.filled(8, 2);

    final bytes = await resolver().resolve('photos/theirs.jpg');

    expect(bytes, isNotNull);
    expect(remote.requests, ['shared/display/theirs.jpg']);
  });

  test('offline, an own photo answers null and is not re-asked at once', () async {
    remote.offline = true;
    final r = resolver();

    expect(await r.resolve('photos/mine.jpeg'), isNull);
    expect(await r.resolve('photos/mine.jpeg'), isNull);

    expect(remote.requests, ['$_uid/mine.jpeg']);
  });
}
