import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/backup/application/sync_providers.dart';
import 'package:masi/features/backup/data/sync_remote.dart';
import 'package:masi/features/topo/data/missing_photo_byte_resolver.dart';
import 'package:masi/features/topo/data/photo_files.dart';
import 'package:path/path.dart' as p;

/// Minimal [SyncRemote] stand-in: only [downloadSharedPhoto] is reachable from
/// the resolver, so every other member is forwarded to `noSuchMethod` (which
/// throws) — reaching any of them would itself be the bug.
class _FakeRemote implements SyncRemote {
  _FakeRemote({this.bytes, this.throwOnDownload = false});

  List<int>? bytes;
  bool throwOnDownload;

  /// Every object path asked for, in order. Metered bytes, one entry each.
  final List<String> requests = [];

  /// Completer-style gate: when non-null, a download waits on it before
  /// answering, so a test can hold two concurrent calls open at once.
  Future<void>? gate;

  @override
  Future<List<int>?> downloadSharedPhoto(String objectPath) async {
    requests.add(objectPath);
    if (gate != null) await gate;
    if (throwOnDownload) throw Exception('offline');
    return bytes;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'the resolver must only ever call downloadSharedPhoto, not '
    '${invocation.memberName}',
  );
}

/// [PhotoFiles] whose docs dir resolution always fails, so `writePhotoBytes`
/// throws — the quota-exhaustion shape.
PhotoFiles _unwritablePhotoFiles() =>
    PhotoFiles(docsDir: () async => throw const FileSystemException('no space'));

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('missing_photo_bytes_test_');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  PhotoFiles photoFiles() => PhotoFiles(docsDir: () async => tmp);

  test(
    'fetches the ONE photo from the shared prefix, hands the bytes back, and '
    'caches them under the same key PhotoFiles would have written — which is '
    'what turns a budget-skipped or pruned photo from a permanent placeholder '
    'into a deferred one',
    () async {
      final remote = _FakeRemote(bytes: List<int>.filled(8, 3));
      final resolver = SharedMissingPhotoByteResolver(
        remote: remote,
        photoFiles: photoFiles(),
      );

      final bytes = await resolver.resolve(p.join('photos', 'photo-a.jpg'));

      expect(bytes, isNotNull);
      expect(bytes, hasLength(8));
      expect(remote.requests, ['shared/photo-a.jpg']);
      expect(
        File(p.join(tmp.path, 'photos', 'photo-a.jpg')).existsSync(),
        isTrue,
        reason: 'the next render must read it locally, not re-fetch it',
      );
    },
  );

  test(
    'de-duplicates CONCURRENT requests for the same photo: a photo strip, a '
    'canvas and a feed card mounting in one frame cause ONE download',
    () async {
      final gate = Completer<void>();
      final remote = _FakeRemote(bytes: List<int>.filled(8, 3))
        ..gate = gate.future;
      final resolver = SharedMissingPhotoByteResolver(
        remote: remote,
        photoFiles: photoFiles(),
      );

      final key = p.join('photos', 'photo-a.jpg');
      final futures = [
        resolver.resolve(key),
        resolver.resolve(key),
        resolver.resolve(key),
      ];
      gate.complete();
      final results = await Future.wait(futures);

      expect(remote.requests, hasLength(1));
      for (final r in results) {
        expect(r, hasLength(8), reason: 'all three callers get the bytes');
      }
    },
  );

  test(
    'a slice\'s localPath resolves its ORIGINAL\'s object — the only one '
    'Storage holds (photo_files.dart S1)',
    () async {
      final remote = _FakeRemote(bytes: List<int>.filled(4, 1));
      final resolver = SharedMissingPhotoByteResolver(
        remote: remote,
        photoFiles: photoFiles(),
      );

      await resolver.resolve(p.join('photos', 'photo-original.png'));

      expect(remote.requests, ['shared/photo-original.png']);
    },
  );

  group('never hammers a key that just failed', () {
    test(
      'an ABSENT remote object is fetched once, then remembered — a rebuilding '
      'widget cannot turn a deleted photo into a retry storm',
      () async {
        final remote = _FakeRemote(); // bytes == null -> no such object
        final resolver = SharedMissingPhotoByteResolver(
          remote: remote,
          photoFiles: photoFiles(),
        );

        final key = p.join('photos', 'photo-gone.jpg');
        expect(await resolver.resolve(key), isNull);
        expect(await resolver.resolve(key), isNull);
        expect(await resolver.resolve(key), isNull);

        expect(remote.requests, hasLength(1));
      },
    );

    test(
      'an EMPTY object counts as absent too (a zero-byte object renders '
      'nothing and would otherwise be re-fetched forever)',
      () async {
        final remote = _FakeRemote(bytes: const []);
        final resolver = SharedMissingPhotoByteResolver(
          remote: remote,
          photoFiles: photoFiles(),
        );

        final key = p.join('photos', 'photo-empty.jpg');
        expect(await resolver.resolve(key), isNull);
        expect(await resolver.resolve(key), isNull);

        expect(remote.requests, hasLength(1));
      },
    );

    test(
      'the negative memory is SHORT: once negativeTtl has elapsed the photo is '
      'attempted again, so a photo missed while offline is not written off for '
      'the rest of the session',
      () async {
        var now = DateTime(2026, 8, 4, 12);
        final remote = _FakeRemote();
        final resolver = SharedMissingPhotoByteResolver(
          remote: remote,
          photoFiles: photoFiles(),
          negativeTtl: const Duration(minutes: 1),
          now: () => now,
        );

        final key = p.join('photos', 'photo-gone.jpg');
        await resolver.resolve(key);
        now = now.add(const Duration(seconds: 59));
        await resolver.resolve(key);
        expect(remote.requests, hasLength(1), reason: 'still inside the window');

        now = now.add(const Duration(seconds: 2));
        remote.bytes = List<int>.filled(4, 9);
        expect(await resolver.resolve(key), hasLength(4));
        expect(remote.requests, hasLength(2));
      },
    );

    test(
      'the negative memory is per-PHOTO, not global: one missing photo does not '
      'block a different one',
      () async {
        final remote = _FakeRemote();
        final resolver = SharedMissingPhotoByteResolver(
          remote: remote,
          photoFiles: photoFiles(),
        );

        await resolver.resolve(p.join('photos', 'photo-a.jpg'));
        await resolver.resolve(p.join('photos', 'photo-b.jpg'));

        expect(remote.requests, ['shared/photo-a.jpg', 'shared/photo-b.jpg']);
      },
    );
  });

  test(
    'OFFLINE is a clean no-op, not an error spew: a throwing download returns '
    'null, never throws to the caller, and is not retried immediately',
    () async {
      final remote = _FakeRemote(throwOnDownload: true);
      final resolver = SharedMissingPhotoByteResolver(
        remote: remote,
        photoFiles: photoFiles(),
      );

      final key = p.join('photos', 'photo-a.jpg');
      expect(await resolver.resolve(key), isNull);
      expect(await resolver.resolve(key), isNull);

      expect(remote.requests, hasLength(1));
    },
  );

  test(
    'a failed CACHE write still returns the bytes — the photo renders this '
    'time, and a full local store is the pruner\'s problem, not a reason to '
    'blank the image',
    () async {
      final remote = _FakeRemote(bytes: List<int>.filled(8, 3));
      final resolver = SharedMissingPhotoByteResolver(
        remote: remote,
        photoFiles: _unwritablePhotoFiles(),
      );

      final bytes = await resolver.resolve(p.join('photos', 'photo-a.jpg'));

      expect(bytes, hasLength(8));
    },
  );

  test(
    'a fetch that SUCCEEDED is not negative-cached: asking again re-fetches '
    'rather than being wrongly written off (the positive cache is PhotoFiles, '
    'and its caller checks it first)',
    () async {
      final remote = _FakeRemote(bytes: List<int>.filled(8, 3));
      final resolver = SharedMissingPhotoByteResolver(
        remote: remote,
        photoFiles: photoFiles(),
      );

      final key = p.join('photos', 'photo-a.jpg');
      await resolver.resolve(key);
      await resolver.resolve(key);

      expect(remote.requests, hasLength(2));
    },
  );

  test(
    'a key with no addressable id or no extension asks for nothing at all',
    () async {
      final remote = _FakeRemote(bytes: List<int>.filled(8, 3));
      final resolver = SharedMissingPhotoByteResolver(
        remote: remote,
        photoFiles: photoFiles(),
      );

      expect(await resolver.resolve(''), isNull);
      expect(await resolver.resolve('photos/'), isNull);
      expect(await resolver.resolve('photos/no-extension'), isNull);

      expect(remote.requests, isEmpty);
    },
  );

  test('the no-op resolver answers null and touches nothing', () async {
    const resolver = NoopMissingPhotoByteResolver();
    expect(await resolver.resolve(p.join('photos', 'photo-a.jpg')), isNull);
  });

  group('missingPhotoByteResolverProvider', () {
    // These two are a PAIR, and the first one alone was worthless. A bare
    // `ProviderContainer` in a VM test can never read `syncRemoteProvider`, so
    // the degrade branch was the only reachable one and replacing the whole
    // provider body with `return const NoopMissingPhotoByteResolver();` left the
    // file green — the provider's actual job was untested. The second test is
    // what kills that mutation: with a remote available it must build the REAL
    // resolver, and that resolver must be the one talking to the remote the
    // provider was given.
    test(
      'degrades to the no-op when Supabase was never initialised, rather than '
      'throwing inside a render path',
      () {
        final container = ProviderContainer();
        addTearDown(container.dispose);

        expect(
          container.read(missingPhotoByteResolverProvider),
          isA<NoopMissingPhotoByteResolver>(),
        );
      },
    );

    test(
      'builds the real Supabase-backed resolver when a remote IS available, and '
      'wires it to that remote — a provider that always answered no-op would '
      'leave every budget-skipped public photo a permanent placeholder',
      () async {
        final remote = _FakeRemote(bytes: List<int>.filled(8, 3));
        final container = ProviderContainer(
          overrides: [
            syncRemoteProvider.overrideWithValue(remote),
            photoFilesProvider.overrideWithValue(
              PhotoFiles(docsDir: () async => tmp),
            ),
          ],
        );
        addTearDown(container.dispose);

        final resolver = container.read(missingPhotoByteResolverProvider);

        expect(resolver, isA<SharedMissingPhotoByteResolver>());
        expect(
          await resolver.resolve(p.join('photos', 'photo-a.jpg')),
          hasLength(8),
        );
        expect(
          remote.requests,
          ['shared/photo-a.jpg'],
          reason: 'the resolver must fetch through the injected SyncRemote',
        );
      },
    );

    test(
      'is a singleton across reads: the in-flight and negative maps ARE the '
      'de-duplication, and a fresh instance per read would de-dup nothing',
      () {
        final container = ProviderContainer(
          overrides: [syncRemoteProvider.overrideWithValue(_FakeRemote())],
        );
        addTearDown(container.dispose);

        expect(
          container.read(missingPhotoByteResolverProvider),
          same(container.read(missingPhotoByteResolverProvider)),
        );
      },
    );
  });
}
