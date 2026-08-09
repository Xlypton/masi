// `lib/features/moderation/data/moderation_remote.dart`'s pure enumeration
// and count-semantics helpers.
//
// Context (the bug this file guards against): a sibling branch added a
// cloud-thumbnail tier for shared photos — `uploadSharedPhoto` writes BOTH
// `shared/<id><ext>` (the original) and `shared/thumbs/<id>.jpg` (a derived
// downscaled JPEG) — but the admin takedown path enumerated only the
// original, so a takedown left the thumbnail world-readable forever. These
// tests prove: (1) a takedown's enumeration now requests BOTH objects for a
// qualifying photo, and (2) a legacy photo published before the thumbnail
// tier existed — original only, no thumbnail — is NOT reported as a failure.

import 'package:flutter_test/flutter_test.dart';
import 'package:masi/features/moderation/data/moderation_remote.dart';

void main() {
  group('publishedPhotoObjectPathsFor', () {
    test(
      'enumerates BOTH the original and its cloud-thumbnail companion for a '
      'qualifying photo row — a takedown must remove both objects',
      () {
        final paths = publishedPhotoObjectPathsFor([
          {
            'id': 'abc123',
            'localPath': '/data/photos/abc123.jpg',
            'parentPhotoId': null,
            'deletedAt': null,
          },
        ]);

        expect(paths, {'shared/abc123.jpg', 'shared/thumbs/abc123.jpg'});
      },
    );

    test('handles several qualifying rows, one pair of paths each', () {
      final paths = publishedPhotoObjectPathsFor([
        {
          'id': 'p1',
          'localPath': '/data/photos/p1.jpeg',
          'parentPhotoId': null,
          'deletedAt': null,
        },
        {
          'id': 'p2',
          'localPath': '/data/photos/p2.png',
          'parentPhotoId': null,
          'deletedAt': null,
        },
      ]);

      expect(paths, {
        'shared/p1.jpeg',
        'shared/thumbs/p1.jpg',
        'shared/p2.png',
        'shared/thumbs/p2.jpg',
      });
    });

    test(
      'excludes a slice (non-null parentPhotoId) — it shares its original\'s '
      'single Storage object, so listing it would duplicate a path already '
      'covered',
      () {
        final paths = publishedPhotoObjectPathsFor([
          {
            'id': 'slice1',
            'localPath': '/data/photos/original.jpg',
            'parentPhotoId': 'original',
            'deletedAt': null,
          },
        ]);

        expect(paths, isEmpty);
      },
    );

    test('excludes an already-tombstoned row (non-null deletedAt)', () {
      final paths = publishedPhotoObjectPathsFor([
        {
          'id': 'gone',
          'localPath': '/data/photos/gone.jpg',
          'parentPhotoId': null,
          'deletedAt': 1723000000000,
        },
      ]);

      expect(paths, isEmpty);
    });

    test(
      'skips a row whose localPath has no extension — guessing one would '
      'report a success that removed nothing',
      () {
        final paths = publishedPhotoObjectPathsFor([
          {
            'id': 'noext',
            'localPath': '/data/photos/noext',
            'parentPhotoId': null,
            'deletedAt': null,
          },
        ]);

        expect(paths, isEmpty);
      },
    );
  });

  group('isSharedThumbObjectPath', () {
    test('true for a path under shared/thumbs/', () {
      expect(isSharedThumbObjectPath('shared/thumbs/abc123.jpg'), isTrue);
    });

    test('false for an original path directly under shared/', () {
      expect(isSharedThumbObjectPath('shared/abc123.jpg'), isFalse);
    });
  });

  group('originalPhotoRequestCount', () {
    test(
      'a legacy photo — original only, no thumbnail requested — counts as '
      'ONE, not conflated with a missing companion object',
      () {
        expect(originalPhotoRequestCount(['shared/legacy123.jpg']), 1);
      },
    );

    test(
      'counts ORIGINALS only in a mixed set — the thumbnail must not double '
      'the reported "photos requested" count',
      () {
        final requested = {
          'shared/modern1.jpg',
          'shared/thumbs/modern1.jpg',
          'shared/legacy1.jpg', // no thumbnail companion — a legacy photo
        };

        // 2 photos were requested (one modern, one legacy), even though 3
        // Storage objects were requested in total.
        expect(originalPhotoRequestCount(requested), 2);
      },
    );

    test('empty input counts as zero', () {
      expect(originalPhotoRequestCount(const []), 0);
    });
  });
}
