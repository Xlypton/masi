import 'package:flutter_test/flutter_test.dart';
import 'package:masi/features/community/domain/feed_freshness.dart';

void main() {
  group('newestForeignArrival', () {
    test('returns the newest arrival', () {
      expect(
        newestForeignArrival(const [
          (at: 100, ownerId: 'a'),
          (at: 300, ownerId: 'b'),
          (at: 200, ownerId: 'c'),
        ], 'me'),
        300,
      );
    });

    test('an empty feed has no arrival at all', () {
      expect(newestForeignArrival(const [], 'me'), isNull);
    });

    test(
      'the user\'s OWN items are skipped — publishing is something they did '
      'seconds ago in this app, and dotting the tab to tell them about it '
      'would fire on the single most common path through the feature',
      () {
        expect(
          newestForeignArrival(const [
            (at: 100, ownerId: 'other'),
            (at: 900, ownerId: 'me'),
          ], 'me'),
          100,
        );
      },
    );

    test('a feed containing only the user\'s own items has no arrival', () {
      expect(
        newestForeignArrival(const [
          (at: 100, ownerId: 'me'),
          (at: 200, ownerId: 'me'),
        ], 'me'),
        isNull,
      );
    });

    test(
      'an unowned row counts as foreign — it cannot be PROVEN to be theirs, '
      'and a spurious dot is far cheaper here than a missing one',
      () {
        expect(
          newestForeignArrival(const [(at: 500, ownerId: null)], 'me'),
          500,
        );
      },
    );

    test('signed out, nothing is own, so everything counts', () {
      expect(
        newestForeignArrival(const [
          (at: 100, ownerId: 'a'),
          (at: 700, ownerId: 'b'),
        ], null),
        700,
      );
    });
  });

  group('feedHasUnseen', () {
    test('something newer than the baseline shows the dot', () {
      expect(feedHasUnseen(newestForeignAt: 200, lastSeenAt: 100), isTrue);
    });

    test('nothing newer than the baseline does not', () {
      expect(feedHasUnseen(newestForeignAt: 100, lastSeenAt: 200), isFalse);
    });

    test(
      'an arrival in the SAME millisecond as the baseline does not re-dot — '
      'the baseline is stamped to `now` the instant the Feed is opened, and a '
      '>= comparison would immediately re-dot the tab being looked at',
      () {
        expect(feedHasUnseen(newestForeignAt: 100, lastSeenAt: 100), isFalse);
      },
    );

    test('an empty feed never shows the dot', () {
      expect(feedHasUnseen(newestForeignAt: null, lastSeenAt: 100), isFalse);
    });

    test(
      'a device that has NEVER opened the feed shows no dot — a brand-new '
      'install has an entire feed it has not seen, and a dot meaning '
      '"everything is new" says nothing and trains the user to ignore it',
      () {
        expect(feedHasUnseen(newestForeignAt: 999, lastSeenAt: null), isFalse);
      },
    );
  });
}
