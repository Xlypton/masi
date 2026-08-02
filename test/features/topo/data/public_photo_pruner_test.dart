// Pure policy test — no drift, no IndexedDB, no clock. `PublicPhotoPruner`
// decides which cached PUBLIC photo bytes are safe to evict under storage
// pressure. The one property every group here ultimately serves: a photo
// that might be the signed-in user's own must NEVER come back from
// `selectForEviction`, under any input, including malformed, ambiguous, or
// adversarial ones. Losing a re-downloadable public photo costs a download;
// losing the user's own costs their work — the two are not symmetric, and
// every ambiguous case below must resolve to "keep", never "evict".
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/features/topo/data/public_photo_pruner.dart';

const _pruner = PublicPhotoPruner();

DateTime _t(int day) => DateTime.utc(2026, 1, day);

void main() {
  group('ownership safety net — must never break', () {
    test(
      'own photos (ownerId == ownUid) are never evicted, even with '
      'keepNewest: 0 — this is the assertion that protects item 1',
      () {
        final photos = [
          PrunablePhoto(key: 'own-1', wallUpdatedAt: _t(1), ownerId: 'me'),
          PrunablePhoto(key: 'own-2', wallUpdatedAt: _t(2), ownerId: 'me'),
        ];

        final evicted = _pruner.selectForEviction(
          photos: photos,
          ownUid: 'me',
          keepNewest: 0,
        );

        expect(evicted, isEmpty);
      },
    );

    test(
      'unowned photos (ownerId == null — the pre-claimOwnership shape) are '
      'treated as own and never evicted, even under maximum pressure',
      () {
        final photos = [
          PrunablePhoto(key: 'unowned-1', wallUpdatedAt: _t(1), ownerId: null),
          PrunablePhoto(key: 'unowned-2', wallUpdatedAt: _t(2), ownerId: null),
        ];

        final evicted = _pruner.selectForEviction(
          photos: photos,
          ownUid: 'me',
          keepNewest: 0,
        );

        expect(evicted, isEmpty);
      },
    );

    test(
      'NAMED BEHAVIOUR: when the signed-in uid itself is unknown (null — no '
      'known local session), ownership cannot be determined for ANY photo, '
      'so nothing is ever evicted — even a pile of distinct, confidently '
      '"foreign-looking" owner ids, at maximum pressure',
      () {
        final photos = [
          PrunablePhoto(key: 'foreign-1', wallUpdatedAt: _t(1), ownerId: 'stranger-a'),
          PrunablePhoto(key: 'foreign-2', wallUpdatedAt: _t(2), ownerId: 'stranger-b'),
          PrunablePhoto(key: 'unowned', wallUpdatedAt: _t(3), ownerId: null),
        ];

        final evicted = _pruner.selectForEviction(
          photos: photos,
          ownUid: null,
          keepNewest: 0,
        );

        expect(evicted, isEmpty);
      },
    );

    test(
      'an owner id that does not match anything on this device is still a '
      'POSITIVE assertion of someone else\'s ownership, not confused with '
      '"unknown" (only a null ownerId is unknown) — it is correctly foreign '
      'and prunable',
      () {
        final photos = [
          PrunablePhoto(
            key: 'orphaned-owner',
            wallUpdatedAt: _t(1),
            ownerId: 'nobody-recognises-this-uid',
          ),
        ];

        final evicted = _pruner.selectForEviction(
          photos: photos,
          ownUid: 'me',
          keepNewest: 0,
        );

        expect(evicted, ['orphaned-owner']);
      },
    );

    test(
      'a mix of own and foreign photos never lets an own key slip through, '
      'even when foreign supply is scarce and keepNewest is 0',
      () {
        final photos = [
          PrunablePhoto(key: 'own-old', wallUpdatedAt: _t(1), ownerId: 'me'),
          PrunablePhoto(key: 'foreign-old', wallUpdatedAt: _t(2), ownerId: 'them'),
          PrunablePhoto(key: 'own-new', wallUpdatedAt: _t(3), ownerId: 'me'),
        ];

        final evicted = _pruner.selectForEviction(
          photos: photos,
          ownUid: 'me',
          keepNewest: 0,
        );

        expect(evicted, ['foreign-old']);
      },
    );

    test('empty input returns no eviction candidates', () {
      final evicted = _pruner.selectForEviction(
        photos: const [],
        ownUid: 'me',
        keepNewest: 0,
      );

      expect(evicted, isEmpty);
    });

    test(
      'a negative keepNewest is clamped to zero rather than throwing or '
      'protecting a phantom floor — all foreign photos are then evictable',
      () {
        final photos = [
          PrunablePhoto(key: 'foreign-1', wallUpdatedAt: _t(1), ownerId: 'them'),
          PrunablePhoto(key: 'foreign-2', wallUpdatedAt: _t(2), ownerId: 'them'),
        ];

        final evicted = _pruner.selectForEviction(
          photos: photos,
          ownUid: 'me',
          keepNewest: -5,
        );

        expect(evicted, ['foreign-1', 'foreign-2']);
      },
    );
  });

  group('foreign-photo eviction ordering', () {
    test('foreign photos come back oldest-wallUpdatedAt-first', () {
      final photos = [
        PrunablePhoto(key: 'newest', wallUpdatedAt: _t(3), ownerId: 'them'),
        PrunablePhoto(key: 'oldest', wallUpdatedAt: _t(1), ownerId: 'them'),
        PrunablePhoto(key: 'middle', wallUpdatedAt: _t(2), ownerId: 'them'),
      ];

      final evicted = _pruner.selectForEviction(
        photos: photos,
        ownUid: 'me',
        keepNewest: 0,
      );

      expect(evicted, ['oldest', 'middle', 'newest']);
    });

    test(
      'exactly photos.length - keepNewest foreign photos are evicted when '
      'the foreign count exceeds keepNewest',
      () {
        final photos = List.generate(
          5,
          (i) => PrunablePhoto(
            key: 'foreign-$i',
            wallUpdatedAt: _t(i + 1),
            ownerId: 'them',
          ),
        );

        final evicted = _pruner.selectForEviction(
          photos: photos,
          ownUid: 'me',
          keepNewest: 2,
        );

        expect(evicted.length, 5 - 2);
        expect(evicted, ['foreign-0', 'foreign-1', 'foreign-2']);
      },
    );

    test('keepNewest larger than the foreign count returns []', () {
      final photos = [
        PrunablePhoto(key: 'foreign-1', wallUpdatedAt: _t(1), ownerId: 'them'),
      ];

      final evicted = _pruner.selectForEviction(
        photos: photos,
        ownUid: 'me',
        keepNewest: 10,
      );

      expect(evicted, isEmpty);
    });

    test('keepNewest exactly equal to the foreign count returns []', () {
      final photos = [
        PrunablePhoto(key: 'foreign-1', wallUpdatedAt: _t(1), ownerId: 'them'),
        PrunablePhoto(key: 'foreign-2', wallUpdatedAt: _t(2), ownerId: 'them'),
      ];

      final evicted = _pruner.selectForEviction(
        photos: photos,
        ownUid: 'me',
        keepNewest: 2,
      );

      expect(evicted, isEmpty);
    });

    test(
      'ties on wallUpdatedAt are broken deterministically by key, so the '
      'result is stable across runs regardless of input order',
      () {
        // Deliberately NOT presented in key order, to prove the sort — not
        // incoming list order — decides the outcome.
        final photosA = [
          PrunablePhoto(key: 'c', wallUpdatedAt: _t(1), ownerId: 'them'),
          PrunablePhoto(key: 'a', wallUpdatedAt: _t(1), ownerId: 'them'),
          PrunablePhoto(key: 'b', wallUpdatedAt: _t(1), ownerId: 'them'),
        ];
        final photosB = [
          PrunablePhoto(key: 'b', wallUpdatedAt: _t(1), ownerId: 'them'),
          PrunablePhoto(key: 'a', wallUpdatedAt: _t(1), ownerId: 'them'),
          PrunablePhoto(key: 'c', wallUpdatedAt: _t(1), ownerId: 'them'),
        ];

        final evictedA = _pruner.selectForEviction(
          photos: photosA,
          ownUid: 'me',
          keepNewest: 1,
        );
        final evictedB = _pruner.selectForEviction(
          photos: photosB,
          ownUid: 'me',
          keepNewest: 1,
        );

        // Sorted ascending by key when tied on age: a, b, c — keepNewest: 1
        // protects 'c', so 'a' and 'b' are evicted, oldest-key-first.
        expect(evictedA, ['a', 'b']);
        expect(evictedA, evictedB);
      },
    );

    test(
      'everything the same age, entirely foreign: still evicts down to '
      'keepNewest deterministically rather than refusing to choose',
      () {
        final photos = List.generate(
          4,
          (i) => PrunablePhoto(
            key: 'same-age-$i',
            wallUpdatedAt: _t(1),
            ownerId: 'them',
          ),
        );

        final evicted = _pruner.selectForEviction(
          photos: photos,
          ownUid: 'me',
          keepNewest: 1,
        );

        expect(evicted, ['same-age-0', 'same-age-1', 'same-age-2']);
      },
    );
  });
}
