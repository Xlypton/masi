import 'package:flutter_test/flutter_test.dart';

import 'package:climbtopo/core/routes/route_styles.dart';

// Contract under test (see lib/core/routes/route_styles.dart doc comments
// for the full derivation):
//
// A1: kCuratedRouteStyles entries all have a unique key + non-empty label;
//     any non-null iconName is one we explicitly vetted here (currently:
//     none — all iconName are null, since no matching MasiIcon assets
//     exist yet for these style names).
// A2: encodeStyleTags/decodeStyleTags round-trip a mix of curated +
//     custom + duplicate + whitespace-padded + empty tags; decodeStyleTags
//     never throws on null/malformed input.
// A3: curatedStyleForKey finds curated keys, returns null for
//     unknown/custom keys.
// A4: resolveStyleTag pairs a curated tag with its RouteStyle and a custom
//     tag with a null style, in both cases preserving the raw string.

/// Mirrors encodeStyleTags' cleaning rules (trim, lowercase, drop empty,
/// case-insensitive de-dup keeping first) so tests can compute the
/// expected decoded output independently of the implementation.
List<String> _cleaned(List<String> tags) {
  final seen = <String>{};
  final out = <String>[];
  for (final raw in tags) {
    final normalized = raw.trim().toLowerCase();
    if (normalized.isEmpty) continue;
    if (!seen.add(normalized)) continue;
    out.add(normalized);
  }
  return out;
}

void main() {
  group('A1: kCuratedRouteStyles entries are well-formed', () {
    test('every key is unique', () {
      final keys = kCuratedRouteStyles.map((s) => s.key).toList();
      expect(keys.toSet().length, keys.length);
    });

    test('every key and label is non-empty', () {
      for (final style in kCuratedRouteStyles) {
        expect(style.key, isNotEmpty);
        expect(style.label, isNotEmpty);
      }
    });

    test('every key is already lowercase (stable storage identifier)', () {
      for (final style in kCuratedRouteStyles) {
        expect(style.key, equals(style.key.toLowerCase()));
      }
    });

    test(
      'no curated entry currently has a confirmed iconName '
      '(none of these style names have a matching MasiIcon asset yet)',
      () {
        for (final style in kCuratedRouteStyles) {
          expect(
            style.iconName,
            isNull,
            reason:
                '${style.key} has a non-null iconName but no MasiIcon '
                'asset was verified for it',
          );
        }
      },
    );

    test('curated set contains the expected climbing style keys', () {
      final keys = kCuratedRouteStyles.map((s) => s.key).toSet();
      expect(
        keys,
        equals({
          'dyno',
          'crimpy',
          'juggy',
          'slabby',
          'overhang',
          'technical',
          'powerful',
          'sloper',
          'pinchy',
          'mantle',
          'dihedral',
          'dynamic',
          'static',
          'endurance',
          'balancey',
          'compression',
          'heel-hook',
          'toe-hook',
        }),
      );
    });
  });

  group('A2: encodeStyleTags / decodeStyleTags round-trip', () {
    test('mix of curated + custom + duplicates + whitespace', () {
      final input = [
        'dyno',
        ' Crimpy ',
        'my-custom-tag',
        'DYNO',
        '  ',
        'juggy',
        'My-Custom-Tag',
        '',
      ];
      final encoded = encodeStyleTags(input);
      final decoded = decodeStyleTags(encoded);
      expect(decoded, equals(_cleaned(input)));
      expect(decoded, equals(['dyno', 'crimpy', 'my-custom-tag', 'juggy']));
    });

    test('empty list encodes/decodes to empty list', () {
      final encoded = encodeStyleTags(const []);
      expect(decodeStyleTags(encoded), equals(const []));
    });

    test('list of only whitespace/empty strings decodes to empty list', () {
      final encoded = encodeStyleTags(['', '   ', '\t']);
      expect(decodeStyleTags(encoded), equals(const []));
    });

    test('order is preserved (first occurrence wins on duplicates)', () {
      final encoded = encodeStyleTags(['b', 'a', 'B', 'c', 'A']);
      expect(decodeStyleTags(encoded), equals(['b', 'a', 'c']));
    });

    test('decodeStyleTags(null) returns const empty list without throwing', () {
      expect(decodeStyleTags(null), equals(const []));
    });

    test('decodeStyleTags("") returns const empty list without throwing', () {
      expect(decodeStyleTags(''), equals(const []));
    });

    test(
      'decodeStyleTags("not json") returns const empty list without throwing',
      () {
        expect(decodeStyleTags('not json'), equals(const []));
      },
    );

    test(
      'decodeStyleTags on malformed/foreign JSON shapes never throws',
      () {
        expect(decodeStyleTags('{"a": 1}'), equals(const []));
        expect(decodeStyleTags('[1, 2, 3]'), equals(const []));
        expect(decodeStyleTags('["ok", 5, null, "fine"]'),
            equals(['ok', 'fine']));
        expect(decodeStyleTags('[[1,2]]'), equals(const []));
      },
    );
  });

  group('A3: curatedStyleForKey lookup', () {
    test('finds a known curated key', () {
      final style = curatedStyleForKey('dyno');
      expect(style, isNotNull);
      expect(style!.label, equals('Dyno'));
    });

    test('returns null for an unknown/custom key', () {
      expect(curatedStyleForKey('my-custom-tag'), isNull);
      expect(curatedStyleForKey('not-a-real-style'), isNull);
    });

    test('is case-sensitive against the stored (lowercase) key', () {
      expect(curatedStyleForKey('DYNO'), isNull);
    });
  });

  group('A4: resolveStyleTag', () {
    test('curated tag resolves to its RouteStyle and preserves raw', () {
      final resolved = resolveStyleTag('juggy');
      expect(resolved.isCurated, isTrue);
      expect(resolved.style, isNotNull);
      expect(resolved.style!.key, equals('juggy'));
      expect(resolved.raw, equals('juggy'));
      expect(resolved.displayLabel, equals('Juggy'));
    });

    test('custom tag resolves with a null style but keeps raw for display', () {
      final resolved = resolveStyleTag('my-custom-tag');
      expect(resolved.isCurated, isFalse);
      expect(resolved.style, isNull);
      expect(resolved.raw, equals('my-custom-tag'));
      expect(resolved.displayLabel, equals('my-custom-tag'));
    });
  });
}
