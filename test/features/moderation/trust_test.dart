// Trust levels, client side (community editing phase 8a / C-4).
//
// The server decides trust; this file covers the two places the client can
// still get it wrong, and both are about what happens BEFORE the answer
// arrives.
//
// The default matters more than it looks. Guessing "trusted" while the RPC is
// in flight would let the submit sheet promise instant publication to somebody
// whose topo is about to sit in a queue for three days — and a person told
// "this is live now" who then cannot find their own topo in the feed concludes
// the app is broken, not that they are waiting.

import 'package:flutter_test/flutter_test.dart';
import 'package:masi/features/moderation/application/trust_providers.dart';

void main() {
  group('the unknown standing', () {
    test(
      'fails CLOSED at level 0. Loading, signed out and failed all resolve '
      'here, and all three mean "assume nothing"',
      () {
        expect(TrustStanding.unknown.level, 0);
        expect(TrustStanding.unknown.isTrusted, isFalse);
      },
    );

    test('carries the real threshold, so a progress readout is not blank', () {
      expect(TrustStanding.unknown.needed, 3);
      expect(TrustStanding.unknown.approved, 0);
    });

    test('is not "blocked" — nothing is known, which is not the same as an '
        'upheld report standing against you', () {
      expect(TrustStanding.unknown.blocked, isFalse);
    });
  });

  group('parsing a standing', () {
    test('a trusted row reads as trusted', () {
      final t = TrustStanding.fromRow({
        'level': 1,
        'approved': 4,
        'needed': 3,
        'blocked': false,
      });
      expect(t.isTrusted, isTrue);
      expect(t.approved, 4);
    });

    test('level 0 with progress is untrusted but not blocked', () {
      final t = TrustStanding.fromRow({
        'level': 0,
        'approved': 2,
        'needed': 3,
        'blocked': false,
      });
      expect(t.isTrusted, isFalse);
      expect(t.blocked, isFalse);
      expect(t.approved, 2);
    });

    test(
      'blocked is carried separately from the count, because "two more to go" '
      'and "an upheld report is holding you here" are different situations '
      'that both read as level 0',
      () {
        final t = TrustStanding.fromRow({
          'level': 0,
          'approved': 9,
          'needed': 3,
          'blocked': true,
        });
        expect(t.isTrusted, isFalse);
        expect(t.blocked, isTrue);
        expect(
          t.approved,
          greaterThanOrEqualTo(t.needed),
          reason: 'past the threshold and still untrusted is exactly the case '
              'the flag exists to explain',
        );
      },
    );

    test('a numeric type the JSON layer widened still parses', () {
      final t = TrustStanding.fromRow({
        'level': 1.0,
        'approved': '5',
        'needed': 3,
      });
      expect(t.level, 1);
      expect(t.approved, 5);
    });

    test('a row missing everything degrades to untrusted rather than throwing', () {
      final t = TrustStanding.fromRow(const {});
      expect(t.level, 0);
      expect(t.isTrusted, isFalse);
      expect(t.needed, 3);
    });
  });
}
