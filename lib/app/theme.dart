import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'is_safari.dart';

/// Semantic color tokens for the MASI design language (see `DESIGN.md`).
///
/// Registered on [ThemeData.extensions] by [MasiTheme.light] / [.dark];
/// fetch it in widgets via [MasiColors.of] rather than hard-coding hex.
@immutable
class MasiColors extends ThemeExtension<MasiColors> {
  const MasiColors({
    required this.ground,
    required this.surface,
    required this.surface2,
    required this.chrome,
    required this.ink,
    required this.ink2,
    required this.ink3,
    required this.separator,
    required this.accent,
    required this.accentPress,
    required this.onAccent,
    required this.amethyst100,
    required this.amethyst200,
    required this.amethyst300,
    required this.amethyst400,
    required this.amethyst500,
    required this.gradeBeginner,
    required this.gradeIntermediate,
    required this.gradeAdvanced,
    required this.gradeHard,
    required this.gradeElite,
  });

  /// Scaffold background.
  final Color ground;

  /// Cards, rows.
  final Color surface;
  final Color surface2;

  /// Translucent chrome fill (pair with a `BackdropFilter` blur).
  final Color chrome;

  /// Primary label.
  final Color ink;

  /// Secondary label.
  final Color ink2;

  /// Tertiary / placeholder label.
  final Color ink3;

  final Color separator;

  /// Action-only accent — buttons, links, active tool, FAB.
  final Color accent;
  final Color accentPress;
  final Color onAccent;

  // Brand ramp (from the logo).
  final Color amethyst100;
  final Color amethyst200;
  final Color amethyst300;
  final Color amethyst400;
  final Color amethyst500;

  // Grade bands (semantic difficulty — never used as the accent).
  final Color gradeBeginner;
  final Color gradeIntermediate;
  final Color gradeAdvanced;
  final Color gradeHard;
  final Color gradeElite;

  static MasiColors of(BuildContext context) =>
      Theme.of(context).extension<MasiColors>()!;

  static const light = MasiColors(
    ground: Color(0xFFF3F1F9),
    surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFFBFAFE),
    chrome: Color(0x8AF9F8FD), // rgba(249,248,253,0.54) — thinner glass tint
    ink: Color(0xFF1B1725),
    ink2: Color(0xFF6A6380),
    ink3: Color(0xFFA29BB6),
    separator: Color(0x1E3C3060), // rgba(60,48,96,0.12)
    accent: Color(0xFF6E56C6),
    accentPress: Color(0xFF5B45AD),
    onAccent: Color(0xFFFFFFFF),
    amethyst100: Color(0xFFEFE9FA),
    amethyst200: Color(0xFFDCD0F2),
    amethyst300: Color(0xFFBDAEE4),
    amethyst400: Color(0xFF9A88CD),
    amethyst500: Color(0xFF8C78C4),
    gradeBeginner: Color(0xFF2F9E6B),
    gradeIntermediate: Color(0xFF3B82C4),
    gradeAdvanced: Color(0xFFE08A2B),
    gradeHard: Color(0xFFD6483B),
    gradeElite: Color(0xFF8A5CD1),
  );

  static const dark = MasiColors(
    ground: Color(0xFF100D17),
    surface: Color(0xFF1D1929),
    surface2: Color(0xFF251F34),
    chrome: Color(0x80171321), // rgba(23,19,33,0.50) — thinner glass tint
    ink: Color(0xFFF3F0FA),
    ink2: Color(0xFFABA4C0),
    ink3: Color(0xFF766F8C),
    separator: Color(0x24C8BEEB), // rgba(200,190,235,0.14)
    accent: Color(0xFFB7A2F0),
    accentPress: Color(0xFF5B45AD),
    onAccent: Color(0xFF1A1226),
    amethyst100: Color(0xFFEFE9FA),
    amethyst200: Color(0xFFDCD0F2),
    amethyst300: Color(0xFFBDAEE4),
    amethyst400: Color(0xFF9A88CD),
    amethyst500: Color(0xFF8C78C4),
    gradeBeginner: Color(0xFF2F9E6B),
    gradeIntermediate: Color(0xFF3B82C4),
    gradeAdvanced: Color(0xFFE08A2B),
    gradeHard: Color(0xFFD6483B),
    gradeElite: Color(0xFF8A5CD1),
  );

  @override
  MasiColors copyWith({
    Color? ground,
    Color? surface,
    Color? surface2,
    Color? chrome,
    Color? ink,
    Color? ink2,
    Color? ink3,
    Color? separator,
    Color? accent,
    Color? accentPress,
    Color? onAccent,
    Color? amethyst100,
    Color? amethyst200,
    Color? amethyst300,
    Color? amethyst400,
    Color? amethyst500,
    Color? gradeBeginner,
    Color? gradeIntermediate,
    Color? gradeAdvanced,
    Color? gradeHard,
    Color? gradeElite,
  }) {
    return MasiColors(
      ground: ground ?? this.ground,
      surface: surface ?? this.surface,
      surface2: surface2 ?? this.surface2,
      chrome: chrome ?? this.chrome,
      ink: ink ?? this.ink,
      ink2: ink2 ?? this.ink2,
      ink3: ink3 ?? this.ink3,
      separator: separator ?? this.separator,
      accent: accent ?? this.accent,
      accentPress: accentPress ?? this.accentPress,
      onAccent: onAccent ?? this.onAccent,
      amethyst100: amethyst100 ?? this.amethyst100,
      amethyst200: amethyst200 ?? this.amethyst200,
      amethyst300: amethyst300 ?? this.amethyst300,
      amethyst400: amethyst400 ?? this.amethyst400,
      amethyst500: amethyst500 ?? this.amethyst500,
      gradeBeginner: gradeBeginner ?? this.gradeBeginner,
      gradeIntermediate: gradeIntermediate ?? this.gradeIntermediate,
      gradeAdvanced: gradeAdvanced ?? this.gradeAdvanced,
      gradeHard: gradeHard ?? this.gradeHard,
      gradeElite: gradeElite ?? this.gradeElite,
    );
  }

  @override
  MasiColors lerp(ThemeExtension<MasiColors>? other, double t) {
    if (other is! MasiColors) return this;
    return MasiColors(
      ground: Color.lerp(ground, other.ground, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surface2: Color.lerp(surface2, other.surface2, t)!,
      chrome: Color.lerp(chrome, other.chrome, t)!,
      ink: Color.lerp(ink, other.ink, t)!,
      ink2: Color.lerp(ink2, other.ink2, t)!,
      ink3: Color.lerp(ink3, other.ink3, t)!,
      separator: Color.lerp(separator, other.separator, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentPress: Color.lerp(accentPress, other.accentPress, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      amethyst100: Color.lerp(amethyst100, other.amethyst100, t)!,
      amethyst200: Color.lerp(amethyst200, other.amethyst200, t)!,
      amethyst300: Color.lerp(amethyst300, other.amethyst300, t)!,
      amethyst400: Color.lerp(amethyst400, other.amethyst400, t)!,
      amethyst500: Color.lerp(amethyst500, other.amethyst500, t)!,
      gradeBeginner: Color.lerp(gradeBeginner, other.gradeBeginner, t)!,
      gradeIntermediate:
          Color.lerp(gradeIntermediate, other.gradeIntermediate, t)!,
      gradeAdvanced: Color.lerp(gradeAdvanced, other.gradeAdvanced, t)!,
      gradeHard: Color.lerp(gradeHard, other.gradeHard, t)!,
      gradeElite: Color.lerp(gradeElite, other.gradeElite, t)!,
    );
  }
}

/// Radius scale — see DESIGN.md "Form — spacing, radius, depth".
abstract final class MasiRadii {
  /// Controls (buttons, small chips).
  static const double control = 10;

  /// Cards / list rows.
  static const double card = 14;

  /// Large card / sheet.
  static const double large = 20;

  /// Hero / big card.
  static const double hero = 28;

  /// App-icon squircle.
  static const double icon = 33;
}

/// Spacing scale — 4 / 8 / 12 / 16 / 24 / 32 grid, see DESIGN.md.
abstract final class MasiSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

/// A [PageTransitionsBuilder] that performs NO transition — [child] is
/// returned untouched. Used on NON-Safari web (see [_webPageTransitions]).
///
/// On Chromium/other web engines the platform's own back gesture drives
/// browser history, so a gesture-less builder avoids doubling an animation on
/// top of it; and any Flutter transition is rendered LIVE on web (Flutter
/// disables its transition-snapshot cache there — `useSnapshot => !kIsWeb`),
/// so an unsynced replay after a browser-driven pop reads as a flash.
/// Returning [child] unchanged removes Flutter's contribution entirely.
/// (Safari is handled separately — see [_safariWebPageTransitionsTheme].)
class _InstantPageTransitionsBuilder extends PageTransitionsBuilder {
  const _InstantPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => child;
}

/// Non-Safari web (Chrome, Android, Edge, …): gesture-less instant transitions
/// so Flutter never adds a swipe-back gesture on top of the platform's own
/// browser-back, and never replays an unsynced (flashing) animation.
const PageTransitionsTheme _instantWebPageTransitionsTheme =
    PageTransitionsTheme(
  builders: {
    TargetPlatform.android: _InstantPageTransitionsBuilder(),
    TargetPlatform.iOS: _InstantPageTransitionsBuilder(),
    TargetPlatform.macOS: _InstantPageTransitionsBuilder(),
    TargetPlatform.windows: _InstantPageTransitionsBuilder(),
    TargetPlatform.linux: _InstantPageTransitionsBuilder(),
    TargetPlatform.fuchsia: _InstantPageTransitionsBuilder(),
  },
);

/// Safari web: the browser's native edge-swipe-back is suppressed by
/// `GoRouter.routerNeglect` (history stays at length 1, so iOS has nothing to
/// swipe back to — see [isSafariBrowser]). With the native gesture out of the
/// way, Flutter's OWN interactive Cupertino swipe-back becomes the sole
/// gesture: an animated in-app swipe-back, no double-gesture, and no
/// browser-compositor flash (#74/#76).
const PageTransitionsTheme _safariWebPageTransitionsTheme =
    PageTransitionsTheme(
  builders: {
    TargetPlatform.android: CupertinoPageTransitionsBuilder(),
    TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
    TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
    TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
    TargetPlatform.linux: CupertinoPageTransitionsBuilder(),
    TargetPlatform.fuchsia: CupertinoPageTransitionsBuilder(),
  },
);

/// Resolves the page-transition theme. Native returns `null` (Flutter's
/// per-platform defaults, unchanged). Safari web uses the interactive
/// Cupertino swipe-back (paired with `routerNeglect`); all other web uses
/// gesture-less instant transitions.
PageTransitionsTheme? _webPageTransitions() {
  if (!kIsWeb) return null;
  return isSafariBrowser()
      ? _safariWebPageTransitionsTheme
      : _instantWebPageTransitionsTheme;
}

/// Builds the light/dark [ThemeData] for the app, per DESIGN.md.
abstract final class MasiTheme {
  static ThemeData light = _build(MasiColors.light, Brightness.light);
  static ThemeData dark = _build(MasiColors.dark, Brightness.dark);

  static ThemeData _build(MasiColors colors, Brightness brightness) {
    final base = ColorScheme.fromSeed(
      seedColor: colors.accent,
      brightness: brightness,
    );
    final colorScheme = base.copyWith(
      primary: colors.accent,
      onPrimary: colors.onAccent,
      surface: colors.surface,
      onSurface: colors.ink,
      surfaceContainerHighest: colors.surface2,
      outline: colors.separator,
      error: colors.gradeHard,
    );

    final textTheme = _textTheme(colors.ink);

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: colors.ground,
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        // Opaque ground (not transparent): visually identical to a transparent
        // AppBar over the `ground` scaffold, kept as the explicit, robust
        // default (no accidental see-through). NOTE: this was tried to remove
        // the faint 2px WebKit compositor seam at the web PWA's
        // safe-area-inset-top boundary (#74) — it did NOT (device-confirmed),
        // because the seam is a WebKit canvas-layer artifact, not a
        // transparency boundary. #74 is accepted as a WebKit limitation: the
        // seam only shows on list screens, and the only "cover it" fix would
        // smear a line across the full-bleed photo/canvas + community-detail
        // screens, so it's not worth shipping. No effect on full-bleed screens
        // (topo canvas has no AppBar; community detail's SliverAppBar sets its
        // own backgroundColor).
        backgroundColor: colors.ground,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: textTheme.titleMedium?.copyWith(color: colors.ink),
        iconTheme: IconThemeData(color: colors.accent),
        actionsIconTheme: IconThemeData(color: colors.accent),
      ),
      pageTransitionsTheme: _webPageTransitions(),
      cardTheme: CardThemeData(
        color: colors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(MasiRadii.card),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: colors.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(MasiRadii.large),
        ),
        titleTextStyle: textTheme.titleLarge?.copyWith(color: colors.ink),
        contentTextStyle: textTheme.bodyMedium?.copyWith(color: colors.ink2),
      ),
      listTileTheme: ListTileThemeData(
        tileColor: colors.surface,
        textColor: colors.ink,
        iconColor: colors.ink2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(MasiRadii.card),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colors.surface2,
        hintStyle: textTheme.bodyLarge?.copyWith(color: colors.ink3),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(MasiRadii.control),
          borderSide: BorderSide(color: colors.separator),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(MasiRadii.control),
          borderSide: BorderSide(color: colors.separator),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(MasiRadii.control),
          borderSide: BorderSide(color: colors.accent, width: 1.5),
        ),
      ),
      dividerColor: colors.separator,
      extensions: [colors],
    );
  }

  static TextTheme _textTheme(Color ink) {
    return TextTheme(
      // Large Title 34/w700, tracking -0.5.
      displaySmall: TextStyle(
        fontSize: 34,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.5,
        color: ink,
      ),
      // Title 1 28/w700, tracking -0.4.
      headlineMedium: TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.4,
        color: ink,
      ),
      // Title 2 22/w600, tracking -0.3.
      titleLarge: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.3,
        color: ink,
      ),
      // Headline 17/w600.
      titleMedium: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: ink,
      ),
      // Body 17/w400.
      bodyLarge: TextStyle(fontSize: 17, fontWeight: FontWeight.w400, color: ink),
      bodyMedium: TextStyle(fontSize: 17, fontWeight: FontWeight.w400, color: ink),
      // Subhead 15/w400.
      titleSmall: TextStyle(fontSize: 15, fontWeight: FontWeight.w400, color: ink),
      bodySmall: TextStyle(fontSize: 15, fontWeight: FontWeight.w400, color: ink),
      // Footnote 13/w400.
      labelMedium: TextStyle(fontSize: 13, fontWeight: FontWeight.w400, color: ink),
      // Caption 12/w500, tracking +0.4, uppercase (apply the uppercase
      // transform where the text is rendered; the style only carries the
      // weight/tracking).
      labelSmall: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.4,
        color: ink,
      ),
      labelLarge: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: ink),
    );
  }
}
