import 'package:characters/characters.dart';

/// Derives 1-2 uppercase initials from an email address's local-part (the
/// part before `@`), for use as the Topos-home account button's avatar
/// content in place of a generic person icon once signed in (see
/// `topos_screen.dart`).
///
/// Rules:
///  - The local-part is split on `.`, `_`, `+`, `-` into non-empty segments
///    (e.g. `peter.keri` -> `['peter', 'keri']`, `someone+tag` ->
///    `['someone', 'tag']`).
///  - Two or more segments: the first character of the first TWO segments,
///    uppercased (e.g. `peter.keri@x.com` -> `PK`; extra segments beyond the
///    first two are ignored, e.g. `bob.smith.jones@x.com` -> `BS`).
///  - Exactly one segment: its first 1-2 characters, uppercased (e.g.
///    `alice@x` -> `AL`; a single-character local part -> that one letter).
///  - Empty or invalid input (no `@`, or nothing before it, or a local part
///    that is entirely separator characters) -> `''`, so callers can fall
///    back to the generic person icon rather than showing a blank avatar.
String emailInitials(String email) {
  final atIndex = email.indexOf('@');
  // atIndex <= 0 covers both "no '@' at all" (-1) and "'@' is the very
  // first character" (0, i.e. an empty local part) — both invalid.
  if (atIndex <= 0) return '';

  final localPart = email.substring(0, atIndex);
  final segments = localPart
      .split(RegExp(r'[._+-]'))
      .where((segment) => segment.isNotEmpty)
      .toList();
  if (segments.isEmpty) return '';

  if (segments.length == 1) {
    // `.characters` walks by user-perceived grapheme cluster, not UTF-16
    // code unit, so a leading emoji/surrogate-pair local part (e.g.
    // `😀.keri@x`) is taken whole instead of having `String[0]`/`substring`
    // tear its surrogate pair into a lone, unpaired code unit.
    final chars = segments.first.characters;
    final length = chars.length >= 2 ? 2 : 1;
    return chars.take(length).toString().toUpperCase();
  }

  final first = segments[0].characters.take(1).toString();
  final second = segments[1].characters.take(1).toString();
  return (first + second).toUpperCase();
}

/// Derives 1-2 uppercase initials from a human display name — the
/// [emailInitials] counterpart for every surface that knows WHO someone is
/// without knowing their email.
///
/// That distinction is the reason this exists rather than reusing
/// [emailInitials]: a comment thread resolves its authors through
/// `profiles.displayName`, and it must never see their address. Feeding a
/// display name to [emailInitials] returns `''` (it requires an `@`), so
/// every avatar in a thread would have collapsed to the generic person glyph.
///
/// Rules, mirroring [emailInitials] on the same shapes:
///  - Split on any whitespace run into non-empty words.
///  - Two or more words: the first character of the first TWO (`Peter Keri`
///    -> `PK`; extra words are ignored).
///  - Exactly one word: its first 1-2 characters (`bogi` -> `BO`; a
///    single-character name -> that one letter).
///  - Empty, or all whitespace -> `''`, so callers fall back to the person
///    glyph rather than drawing a blank disc.
///
/// Grapheme-cluster aware for the same reason [emailInitials] is: `String[0]`
/// on an emoji or a surrogate pair yields a lone unpaired code unit.
String displayNameInitials(String name) {
  final words = name
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .toList();
  if (words.isEmpty) return '';

  if (words.length == 1) {
    final chars = words.first.characters;
    final length = chars.length >= 2 ? 2 : 1;
    return chars.take(length).toString().toUpperCase();
  }

  final first = words[0].characters.take(1).toString();
  final second = words[1].characters.take(1).toString();
  return (first + second).toUpperCase();
}
