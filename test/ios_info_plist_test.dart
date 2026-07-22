import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// A5 (masi-photo-first-home.md, Subtask 1): the camera/library photo
/// source sheet relies on iOS's runtime permission prompts, which only fire
/// if `Info.plist` carries non-empty usage-description strings. This test
/// guards against that copy ever being deleted/emptied, without re-deriving
/// or re-asserting *what* the copy says (recon confirmed both keys already
/// exist with valid, non-empty descriptions).
void main() {
  test(
    'A5: Info.plist has non-empty NSCameraUsageDescription and '
    'NSPhotoLibraryUsageDescription',
    () {
      final plistFile = File(
        p.join(Directory.current.path, 'ios', 'Runner', 'Info.plist'),
      );

      expect(
        plistFile.existsSync(),
        isTrue,
        reason: 'Expected ${plistFile.path} to exist',
      );

      final contents = plistFile.readAsStringSync();

      for (final key in [
        'NSCameraUsageDescription',
        'NSPhotoLibraryUsageDescription',
      ]) {
        final match = RegExp(
          '<key>$key</key>\\s*<string>(.*?)</string>',
          dotAll: true,
        ).firstMatch(contents);

        expect(
          match,
          isNotNull,
          reason: 'Expected <key>$key</key> followed by a <string> value',
        );
        expect(
          match!.group(1)!.trim(),
          isNotEmpty,
          reason: '$key must have a non-empty description',
        );
      }
    },
  );

  // S2 (magic-link email auth): the Supabase magic-link redirect
  // (`io.supabase.climbtopo://login-callback/`, see
  // `SupabaseAuthRepository.magicLinkRedirect`) only resolves back into the
  // app if this URL scheme is registered in `CFBundleURLTypes`. A loose
  // substring check (just `contents.contains(...)` for the key and the
  // scheme string anywhere in the file) would also pass if the scheme were
  // nested under some unrelated key, or if `CFBundleURLTypes` existed but its
  // array were empty — so this assertion is structural: it scopes the check
  // to the substring between the `CFBundleURLTypes` key and the matching
  // close of its `<array>` (correctly balancing any array nested inside,
  // e.g. `CFBundleURLSchemes`'s own array), and only then asserts that BOTH
  // `CFBundleURLSchemes` and the scheme string appear inside that region.
  test('S2-c: Info.plist registers the io.supabase.climbtopo URL scheme', () {
    final plistFile = File(
      p.join(Directory.current.path, 'ios', 'Runner', 'Info.plist'),
    );

    final contents = plistFile.readAsStringSync();

    const urlTypesKey = '<key>CFBundleURLTypes</key>';
    final keyIndex = contents.indexOf(urlTypesKey);
    expect(
      keyIndex,
      isNot(-1),
      reason: 'Expected a CFBundleURLTypes entry in Info.plist',
    );

    final arrayOpenIndex = contents.indexOf('<array>', keyIndex);
    expect(
      arrayOpenIndex,
      isNot(-1),
      reason: 'Expected an <array> for the CFBundleURLTypes entry',
    );

    final arrayCloseEnd = _matchingArrayCloseEnd(contents, arrayOpenIndex);
    final urlTypesBlock = contents.substring(keyIndex, arrayCloseEnd);

    expect(
      urlTypesBlock.contains('<key>CFBundleURLSchemes</key>'),
      isTrue,
      reason:
          'Expected CFBundleURLSchemes nested inside the CFBundleURLTypes '
          'array, not just present somewhere else in the file',
    );
    expect(
      urlTypesBlock.contains('<string>io.supabase.climbtopo</string>'),
      isTrue,
      reason:
          'Expected the io.supabase.climbtopo scheme string nested inside '
          'CFBundleURLTypes -> dict -> CFBundleURLSchemes -> array, not '
          'just present somewhere else in the file',
    );
  });
}

/// Returns the index just past the `</array>` that matches the `<array>` tag
/// starting at [arrayOpenIndex] in [contents], correctly balancing any
/// `<array>`/`</array>` pairs nested inside it (e.g. `CFBundleURLSchemes`'s
/// own array under the `CFBundleURLTypes` dict) rather than naively grabbing
/// the first `</array>` found, which would truncate the region before the
/// nested content it needs to cover.
int _matchingArrayCloseEnd(String contents, int arrayOpenIndex) {
  const open = '<array>';
  const close = '</array>';
  var depth = 0;
  var pos = arrayOpenIndex;
  while (true) {
    final nextOpen = contents.indexOf(open, pos);
    final nextClose = contents.indexOf(close, pos);
    if (nextClose == -1) {
      throw StateError('Unbalanced <array> tags in Info.plist');
    }
    if (nextOpen != -1 && nextOpen <= nextClose) {
      depth++;
      pos = nextOpen + open.length;
    } else {
      depth--;
      pos = nextClose + close.length;
      if (depth == 0) {
        return pos;
      }
    }
  }
}
