import 'package:climbtopo/features/account/application/email_initials.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('emailInitials', () {
    test('a dotted local-part takes the first letter of the first two '
        'segments', () {
      expect(emailInitials('peter.keri@x.com'), 'PK');
    });

    test('extra segments beyond the first two are ignored', () {
      expect(emailInitials('bob.smith.jones@x.com'), 'BS');
    });

    test('a "+"-tagged local-part is split on the "+" too', () {
      expect(emailInitials('someone+tag@x.com'), 'ST');
    });

    test('a "_"-separated local-part is split on the "_" too', () {
      expect(emailInitials('jane_doe@x.com'), 'JD');
    });

    test('a "-"-separated local-part is split on the "-" too', () {
      expect(emailInitials('anne-marie@x.com'), 'AM');
    });

    test('a single-segment local-part takes its first two characters', () {
      expect(emailInitials('alice@x'), 'AL');
    });

    test('a single-character local-part takes just that one character', () {
      expect(emailInitials('a@x.com'), 'A');
    });

    test('an empty string is invalid -> empty result', () {
      expect(emailInitials(''), '');
    });

    test('no "@" at all is invalid -> empty result', () {
      expect(emailInitials('notanemail'), '');
    });

    test('an empty local-part ("@" as the first character) is invalid -> '
        'empty result', () {
      expect(emailInitials('@x.com'), '');
    });

    test('a local-part that is entirely separator characters is invalid -> '
        'empty result', () {
      expect(emailInitials('...@x.com'), '');
    });

    test(
      'an emoji-leading single-segment local-part takes the first TWO '
      'grapheme clusters intact, not a torn UTF-16 surrogate pair',
      () {
        // 😀 is a non-BMP code point (a surrogate pair in UTF-16). Naive
        // `String[0]`/`substring(0, n)` indexing by code unit would tear the
        // pair and produce a lone, unpaired surrogate; `.characters`-based
        // slicing must keep 😀 whole as the first grapheme, then take "k" as
        // the second.
        expect(emailInitials('😀keri@x.com'), '😀K');
      },
    );

    test(
      'an emoji-leading two-segment local-part takes the first grapheme '
      'cluster of EACH segment intact',
      () {
        expect(emailInitials('😀.keri@x.com'), '😀K');
      },
    );
  });
}
