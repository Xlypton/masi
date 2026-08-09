import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../features/account/application/email_initials.dart';
import 'masi_icon.dart';

/// The app's one profile-picture surface: a circular avatar showing, in
/// order of preference, the user's picture ([avatarUrl]), their email
/// initials, or a generic person glyph.
///
/// [avatarUrl] accepts both shapes stored in `Profiles.avatarUrl` (see that
/// column's doc):
///  - `data:image/...;base64,...` — a picture the user picked in this app.
///    Decoded to bytes and drawn from memory, so it needs no network and
///    works offline.
///  - any `http(s)://` URL — an identity provider's avatar (Google's
///    `lh3.googleusercontent.com` links serve
///    `Cross-Origin-Resource-Policy: cross-origin` and
///    `Access-Control-Allow-Origin: *`, so they load fine under the web
///    build's `COEP: require-corp` — verified 2026-08-06).
///
/// EVERY failure path lands on the initials, never on a broken-image glyph
/// or an exception: a malformed data URL, base64 that will not decode, an
/// image that 404s, and an offline device with a network avatar all render
/// exactly what a user with no picture at all sees.
class MasiAvatar extends StatelessWidget {
  const MasiAvatar({
    super.key,
    required this.avatarUrl,
    required this.email,
    required this.radius,
    this.displayName,
  });

  /// The picture to draw, or `null` to go straight to the initials.
  final String? avatarUrl;

  /// The signed-in email, used for the initials fallback. `null`/empty falls
  /// back one further, to the generic person glyph.
  final String? email;

  /// A human display name to take the initials from INSTEAD of [email], for
  /// the surfaces that know who someone is without knowing their address —
  /// a comment thread resolves its authors through `profiles.displayName` and
  /// must never see their email.
  ///
  /// Wins over [email] whenever it yields initials at all; a name that is
  /// empty or all whitespace falls through to [email], and then to the person
  /// glyph, so passing this can only ever add information.
  final String? displayName;

  final double radius;

  /// Decodes a `data:...;base64,<payload>` URL to bytes, or returns `null`
  /// for anything that is not one — including a data URL that is not
  /// base64-encoded, or whose payload will not decode. Callers treat `null`
  /// as "not a data URL / unusable", never as an error.
  static Uint8List? decodeDataUrl(String value) {
    if (!value.startsWith('data:')) return null;
    final comma = value.indexOf(',');
    if (comma < 0) return null;
    if (!value.substring(0, comma).contains(';base64')) return null;
    try {
      return base64Decode(value.substring(comma + 1));
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final url = avatarUrl;

    ImageProvider? image;
    if (url != null && url.isNotEmpty) {
      final bytes = decodeDataUrl(url);
      if (bytes != null) {
        image = MemoryImage(bytes);
      } else if (url.startsWith('http://') || url.startsWith('https://')) {
        image = NetworkImage(url);
      }
      // Anything else (a stray relative path, a `file:` URL from some future
      // import) deliberately falls through to the initials rather than being
      // handed to an image loader that would throw.
    }

    return CircleAvatar(
      radius: radius,
      backgroundColor: colors.accent,
      foregroundColor: colors.onAccent,
      // `foregroundImage` (not `backgroundImage`): its `onForegroundImageError`
      // leaves the CircleAvatar's own `child` painted underneath, so a failed
      // load reveals the initials instead of an empty accent-coloured disc.
      foregroundImage: image,
      onForegroundImageError: image == null ? null : (_, _) {},
      child: _InitialsOrGlyph(
        email: email,
        displayName: displayName,
        radius: radius,
      ),
    );
  }
}

/// The fallback painted under [MasiAvatar]'s picture: 1-2 initials taken from
/// the display name if there is one and the email otherwise, or a person glyph
/// when neither yields any.
class _InitialsOrGlyph extends StatelessWidget {
  const _InitialsOrGlyph({
    required this.email,
    required this.displayName,
    required this.radius,
  });

  final String? email;
  final String? displayName;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final name = displayName;
    var initials = name == null ? '' : displayNameInitials(name);
    if (initials.isEmpty) initials = email == null ? '' : emailInitials(email!);
    if (initials.isEmpty) {
      // `radius * 0.9`, not a bare `radius`, because the two widgets measure
      // different things: `Icon(size:)` sized the Material `person` glyph's EM
      // BOX, and that glyph inked only ~16 of its 24-unit design grid, whereas
      // `MasiIcon(size:)` sizes the SVG's 24-unit VIEWBOX and `masi_person.svg`
      // inks ~19 of it (head cap at y=2.5 down to the shoulder stroke at
      // y=21.5). Handing the same number to both would render this fallback
      // ~10% larger than the one users already see, so the factor cancels the
      // difference in ink coverage rather than changing the intended size.
      return MasiIcon(
        'person',
        size: radius * 0.9,
        color: MasiColors.of(context).onAccent,
      );
    }
    return Text(
      initials,
      style: TextStyle(
        // Matches the two hand-rolled avatars this widget replaced: 18pt at
        // r=24 (Account) and 12pt at r=14 (Topos app bar).
        fontSize: radius * 0.75,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}
