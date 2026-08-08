// The SHARED THUMBNAIL tier, from both ends.
//
// Before it, the cloud held exactly one object per published photo — the
// EXIF-stripped but full-resolution original — so a 52-pixel list tile for a
// foreign photo whose bytes are absent locally (the normal state: the pull
// budgets foreign photos and the pruner evicts them) downloaded multiple
// megabytes to paint it. Worse, `thumbKeyFor` hard-codes `.jpg`, so for a
// `.jpeg` photo the tile asked for an object that could not exist, and the
// resulting negative-cache entry — keyed on the bare photo id — then blocked
// the canvas's CORRECT `.jpeg` request for the whole TTL. A hard stall, not
// slow loading.
//
// These tests pin the four properties that fix depends on: a thumbnail key
// addresses the thumbnail OBJECT, the failure/in-flight bookkeeping is per
// object path, a successful resolve prefers whatever is stored under the key
// that was actually asked for, and only a bounded number of fetches run at
// once.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:masi/features/backup/data/sync_remote.dart';
import 'package:masi/features/topo/data/missing_photo_byte_resolver.dart';
import 'package:masi/features/topo/data/photo_files.dart';
import 'package:path/path.dart' as p;

/// A [SyncRemote] backed by an in-memory shared bucket.
///
/// Everything except [downloadSharedPhoto] is `noSuchMethod` — reaching any
/// other member from a render path would itself be the bug.
class _FakeSharedBucket implements SyncRemote {
  /// object path -> bytes.
  final Map<String, List<int>> objects = {};

  /// Every object path asked for, in order. Metered bytes, one entry each.
  final List<String> requests = [];

  /// When non-null, every download registers its request and then WAITS —
  /// which is what makes "how many are in flight at once" observable.
  Completer<void>? gate;

  @override
  Future<List<int>?> downloadSharedPhoto(String objectPath) async {
    requests.add(objectPath);
    final held = gate;
    if (held != null) await held.future;
    return objects[objectPath];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'the resolver must only ever call downloadSharedPhoto, not '
    '${invocation.memberName}',
  );
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('shared_thumb_test_');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  PhotoFiles photoFiles() => PhotoFiles(docsDir: () async => tmp);

  /// Writes [bytes] to `<tmp>/<relative>`, creating parents.
  void seedLocal(String relative, List<int> bytes) {
    final file = File(p.join(tmp.path, p.joinAll(p.split(relative))));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
  }

  group('key -> object path', () {
    test(
      'a THUMBNAIL key resolves the small shared/thumbs object, never the '
      'full-resolution original — the whole point of the tier',
      () async {
        final remote = _FakeSharedBucket()
          ..objects['shared/thumbs/photo-a.jpg'] = List<int>.filled(12, 7)
          ..objects['shared/photo-a.jpeg'] = List<int>.filled(4096, 1);
        final resolver = SharedMissingPhotoByteResolver(
          remote: remote,
          photoFiles: photoFiles(),
        );

        final bytes = await resolver.resolve(thumbKeyFor('photos/photo-a.jpeg'));

        expect(
          bytes,
          hasLength(12),
          reason: 'the tile must get the thumbnail, not the 4KB original',
        );
        expect(remote.requests, ['shared/thumbs/photo-a.jpg']);
      },
    );

    test(
      'the thumbnail is ALWAYS .jpg while the original keeps its own '
      'extension — .jpeg/.png/.JPG all address one thumbnail object',
      () async {
        for (final ext in ['.jpeg', '.png', '.JPG', '.jpg']) {
          final remote = _FakeSharedBucket()
            ..objects['shared/thumbs/photo-a.jpg'] = List<int>.filled(9, 2);
          final resolver = SharedMissingPhotoByteResolver(
            remote: remote,
            photoFiles: photoFiles(),
          );

          expect(
            await resolver.resolve(thumbKeyFor('photos/photo-a$ext')),
            hasLength(9),
            reason: 'original extension $ext',
          );
          expect(remote.requests, ['shared/thumbs/photo-a.jpg']);
        }
      },
    );

    test(
      'an ORIGINAL key still resolves the original, extension intact',
      () async {
        final remote = _FakeSharedBucket()
          ..objects['shared/photo-a.jpeg'] = List<int>.filled(20, 3);
        final resolver = SharedMissingPhotoByteResolver(
          remote: remote,
          photoFiles: photoFiles(),
        );

        expect(await resolver.resolve('photos/photo-a.jpeg'), hasLength(20));
        expect(remote.requests, ['shared/photo-a.jpeg']);
        expect(
          File(p.join(tmp.path, 'photos', 'photo-a.jpeg')).existsSync(),
          isTrue,
          reason: 'the next render must read it locally, not re-fetch it',
        );
      },
    );
  });

  test(
    'a FAILED thumbnail probe does not suppress the same photo\'s ORIGINAL — '
    'the negative memory is per OBJECT PATH, not per photo id',
    () async {
      final remote = _FakeSharedBucket()
        // No thumbnail object at all: a publish that predates the tier.
        ..objects['shared/photo-a.jpeg'] = List<int>.filled(20, 3);
      final resolver = SharedMissingPhotoByteResolver(
        remote: remote,
        photoFiles: photoFiles(),
      );

      expect(
        await resolver.resolve(thumbKeyFor('photos/photo-a.jpeg')),
        isNull,
        reason: 'no thumbnail object, and no extension lookup wired in',
      );
      expect(
        await resolver.resolve('photos/photo-a.jpeg'),
        hasLength(20),
        reason:
            'THE REGRESSION: the dead thumbnail probe used to poison the bare '
            'photo id for the whole negativeTtl, stalling the canvas',
      );

      expect(remote.requests, [
        'shared/thumbs/photo-a.jpg',
        'shared/photo-a.jpeg',
      ]);
    },
  );

  test(
    'a thumbnail probe that MISSES is still remembered for its own path: a '
    'rebuilding tile does not re-probe an object that predates the tier',
    () async {
      final remote = _FakeSharedBucket();
      final resolver = SharedMissingPhotoByteResolver(
        remote: remote,
        photoFiles: photoFiles(),
      );

      final key = thumbKeyFor('photos/photo-a.jpeg');
      expect(await resolver.resolve(key), isNull);
      expect(await resolver.resolve(key), isNull);
      expect(await resolver.resolve(key), isNull);

      expect(remote.requests, hasLength(1));
    },
  );

  group('backwards compatibility: a publish with no thumbnail object', () {
    test(
      'falls back to the ORIGINAL, addressed with the extension recovered from '
      'the local row — not the .jpg the thumbnail key hard-codes',
      () async {
        final remote = _FakeSharedBucket()
          ..objects['shared/photo-a.jpeg'] = List<int>.filled(400, 1);
        final resolver = SharedMissingPhotoByteResolver(
          remote: remote,
          photoFiles: photoFiles(),
          originalExtFor: (photoId) async => '.jpeg',
        );

        final bytes = await resolver.resolve(thumbKeyFor('photos/photo-a.jpeg'));

        expect(
          bytes,
          hasLength(400),
          reason:
              'a legacy publish must still render, exactly as it did before '
              'the tier existed — never a permanent placeholder',
        );
        expect(remote.requests, [
          'shared/thumbs/photo-a.jpg',
          'shared/photo-a.jpeg',
        ]);
        expect(
          File(p.join(tmp.path, 'photos', 'photo-a.jpeg')).existsSync(),
          isTrue,
        );
      },
    );

    test(
      'after that fallback the INTENDED key is re-read, so what lands in the '
      'image cache under a thumbnail key is thumbnail-sized',
      () async {
        // The web backend regenerates the local thumbnail as part of writing
        // the original; here it is pre-seeded, which pins the same property
        // without driving an image codec.
        seedLocal('thumbs/photo-a.jpg', List<int>.filled(5, 9));

        final remote = _FakeSharedBucket()
          ..objects['shared/photo-a.jpeg'] = List<int>.filled(400, 1);
        final resolver = SharedMissingPhotoByteResolver(
          remote: remote,
          photoFiles: photoFiles(),
          originalExtFor: (photoId) async => '.jpeg',
        );

        final bytes = await resolver.resolve(thumbKeyFor('photos/photo-a.jpeg'));

        expect(
          bytes,
          hasLength(5),
          reason:
              'booking the 400-byte original under a thumbnail key would spend '
              'a budget sized for tiles on full-resolution bytes',
        );
      },
    );

    test(
      'declines the fallback when the original extension cannot be '
      'established, rather than guessing an object path',
      () async {
        final remote = _FakeSharedBucket()
          ..objects['shared/photo-a.jpeg'] = List<int>.filled(400, 1);
        final resolver = SharedMissingPhotoByteResolver(
          remote: remote,
          photoFiles: photoFiles(),
          originalExtFor: (photoId) async => null,
        );

        expect(
          await resolver.resolve(thumbKeyFor('photos/photo-a.jpeg')),
          isNull,
        );
        expect(remote.requests, ['shared/thumbs/photo-a.jpg']);
      },
    );

    test('a throwing extension lookup is a clean no-op, never a crash', () async {
      final remote = _FakeSharedBucket();
      final resolver = SharedMissingPhotoByteResolver(
        remote: remote,
        photoFiles: photoFiles(),
        originalExtFor: (photoId) async => throw StateError('database gone'),
      );

      expect(
        await resolver.resolve(thumbKeyFor('photos/photo-a.jpeg')),
        isNull,
      );
    });
  });

  test(
    'concurrent fetches are CAPPED: a screenful of shared rows queues instead '
    'of opening one download per row',
    () async {
      final gate = Completer<void>();
      final remote = _FakeSharedBucket()..gate = gate;
      for (var i = 0; i < 6; i++) {
        remote.objects['shared/photo-$i.jpg'] = List<int>.filled(4, 1);
      }
      final resolver = SharedMissingPhotoByteResolver(
        remote: remote,
        photoFiles: photoFiles(),
      );

      final futures = [
        for (var i = 0; i < 6; i++) resolver.resolve('photos/photo-$i.jpg'),
      ];
      await pumpEventQueue();

      expect(
        remote.requests,
        hasLength(SharedMissingPhotoByteResolver.maxConcurrentFetches),
        reason: 'six rows mounted in one frame; three downloads may run',
      );

      gate.complete();
      final results = await Future.wait(futures);

      expect(
        remote.requests,
        hasLength(6),
        reason: 'the queue drains — capping must defer, never drop',
      );
      for (final bytes in results) {
        expect(bytes, hasLength(4));
      }
    },
  );

  test(
    'a STALLED download cannot wedge photo loading for the session: the slot '
    'is released on timeout and the queue behind it drains',
    () async {
      // Never completed — a socket that is accepted and then never answers,
      // which is what a captive portal actually does.
      final wedge = Completer<void>();
      final remote = _FakeSharedBucket()..gate = wedge;
      for (var i = 0; i < 6; i++) {
        remote.objects['shared/photo-$i.jpg'] = List<int>.filled(4, 1);
      }
      final resolver = SharedMissingPhotoByteResolver(
        remote: remote,
        photoFiles: photoFiles(),
        // Real time, scaled down — the production values are 30s/45s and the
        // property under test is the ORDERING of the two guards, not their
        // magnitude. The slot wait stays the longer of the two, so this proves
        // the slots were handed back properly rather than that the waiters
        // gave up and over-ran the cap.
        fetchTimeout: const Duration(milliseconds: 50),
        slotWaitTimeout: const Duration(seconds: 5),
      );

      final results = await Future.wait([
        for (var i = 0; i < 6; i++) resolver.resolve('photos/photo-$i.jpg'),
      ]);

      expect(
        remote.requests,
        hasLength(6),
        reason:
            'THE WEDGE: with no bound on how long a fetch may hold a slot, '
            'three stuck sockets stop every other photo in the app from ever '
            'being requested — for the rest of the session',
      );
      expect(
        results.every((bytes) => bytes == null),
        isTrue,
        reason: 'a timeout reads exactly like being offline: null, no throw',
      );

      wedge.complete();
    },
  );

  group('publishedSharedOriginals', () {
    test(
      'an original is published as soon as the ORIGINAL exists — a missing '
      'thumbnail must never make an already-published photo look unpublished',
      () {
        expect(publishedSharedOriginals(['done.jpeg', 'legacy.jpeg']), {
          'shared/done.jpeg',
          'shared/legacy.jpeg',
        });
      },
    );

    test(
      'the folder pseudo-entry Supabase returns for `thumbs` is not mistaken '
      'for a photo',
      () {
        expect(publishedSharedOriginals(['thumbs', 'a.jpg']), {'shared/a.jpg'});
      },
    );
  });

  group('sharedOriginalsNeedingThumbs', () {
    test(
      'lists exactly the originals published before the tier existed — the '
      'backfill worklist, and nothing that feeds publish state',
      () {
        expect(
          sharedOriginalsNeedingThumbs(
            originalNames: ['done.jpeg', 'legacy.jpeg'],
            thumbNames: {'done.jpg'},
          ),
          ['legacy.jpeg'],
        );
      },
    );

    test(
      'the join is on the ID, not the full name: originals keep .jpeg/.png/'
      '.JPG while every thumbnail is .jpg',
      () {
        expect(
          sharedOriginalsNeedingThumbs(
            originalNames: ['a.jpeg', 'b.png', 'c.JPG', 'd.jpg'],
            thumbNames: {'a.jpg', 'b.jpg', 'c.jpg', 'd.jpg'},
          ),
          isEmpty,
          reason:
              'matching on the full name would re-list every non-.jpg photo '
              'forever',
        );
      },
    );

    test(
      'the `thumbs` folder pseudo-entry is never worklisted — nothing can ever '
      'produce a thumbs.jpg for it, so it would be retried every pass forever',
      () {
        expect(
          sharedOriginalsNeedingThumbs(
            originalNames: ['thumbs', 'a.jpg'],
            thumbNames: const {},
          ),
          ['a.jpg'],
        );
      },
    );

    test('an orphan thumbnail with no original worklists nothing', () {
      expect(
        sharedOriginalsNeedingThumbs(
          originalNames: const [],
          thumbNames: {'orphan.jpg'},
        ),
        isEmpty,
      );
    });
  });

  group('shared object paths', () {
    test('the thumbnail path mirrors thumbKeyFor one level under shared/', () {
      expect(sharedThumbPath('photo-a'), 'shared/thumbs/photo-a.jpg');
      expect(thumbKeyFor('photos/photo-a.jpeg'), 'thumbs/photo-a.jpg');
    });

    test('isThumbKey discriminates on the directory, not the extension', () {
      expect(isThumbKey('thumbs/photo-a.jpg'), isTrue);
      expect(isThumbKey('/var/docs/thumbs/photo-a.jpg'), isTrue);
      expect(isThumbKey('photos/photo-a.jpg'), isFalse);
      expect(isThumbKey('photos/photo-a.jpeg'), isFalse);
      expect(isThumbKey(''), isFalse);
    });
  });
}
