import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../shared/presentation/bottom_safe_inset.dart';
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

/// Motion scale — the app's single source of animation durations and curves.
///
/// Before this existed every duration in the app was a file-local
/// `const Duration(...)`, so nothing was consistent and nothing was tunable.
/// Declared the same way as [MasiRadii]/[MasiSpacing] (a plain
/// `abstract final class` of `static const`s, not a [ThemeExtension]): these
/// are design constants, not theme-varying values, and a `const` is usable in
/// a `const` constructor's default — which the loading widgets rely on.
///
/// The two `loading*` values are load-bearing behaviour, not decoration; see
/// their docs.
abstract final class MasiMotion {
  /// A control changing state in place — a chip selecting, a button pressing,
  /// an icon swapping.
  static const Duration micro = Duration(milliseconds: 120);

  /// A small element entering or leaving — an inline cue fading in, a banner
  /// appearing above a list.
  static const Duration short = Duration(milliseconds: 200);

  /// A content-sized change — a cross-fade between two bodies, an
  /// expand/collapse.
  static const Duration medium = Duration(milliseconds: 320);

  /// A full-surface change.
  static const Duration long = Duration(milliseconds: 480);

  /// ANTI-FLASH. How long an async operation is allowed to run before any
  /// loading affordance may appear at all.
  ///
  /// A spinner or skeleton that shows for 80 ms is worse than none: the eye
  /// registers the flicker, not the information, and the screen reads as
  /// broken rather than busy. Anything that completes inside this window
  /// should therefore render as an instant transition with no loading state
  /// ever painted.
  ///
  /// 180 ms is chosen just under the ~200 ms at which a delay stops feeling
  /// instantaneous: shorter and fast local reads (Drift queries, cached
  /// images — the majority of this app's loads) would still flicker; longer
  /// and a genuinely slow load would sit on unexplained blank space.
  static const Duration loadingRevealDelay = Duration(milliseconds: 180);

  /// ANTI-STROBE. Once a loading affordance IS on screen, the minimum time it
  /// stays there even if the data has already arrived.
  ///
  /// Without this floor, a load that resolves at 190 ms — one millisecond
  /// after [loadingRevealDelay] let the affordance in — paints a skeleton for
  /// a single frame and rips it away, which is the exact strobe the reveal
  /// delay exists to prevent, merely moved later.
  ///
  /// 450 ms is long enough to read as a deliberate state (roughly a third of
  /// `MasiShimmer`'s 1400 ms sweep, so a shimmer visibly moves rather than
  /// appearing frozen) and short enough that the worst case it can add —
  /// 180 ms + 450 ms = 630 ms, and only for operations that finish in the
  /// narrow window just past the reveal delay — stays under the ~1 s at which
  /// a user starts wondering whether the app is stuck.
  static const Duration loadingMinVisible = Duration(milliseconds: 450);

  /// Default curve for something arriving or settling.
  static const Curve standard = Curves.easeOutCubic;

  /// Curve for something leaving.
  static const Curve exit = Curves.easeInCubic;

  /// Curve for a change that both begins and ends on screen.
  static const Curve inOut = Curves.easeInOutCubic;
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

  /// Applies the app's one global `SnackBar` fix to [base] (`MasiTheme.light`
  /// / `.dark`): every toast clears the home indicator, on every route,
  /// including an installed iOS PWA where the device reports a zero bottom
  /// safe-area inset.
  ///
  /// ## The bug
  ///
  /// There is no `SnackBarThemeData` anywhere else in the app, so every
  /// `SnackBar` is unstyled Material default: `SnackBarBehavior.fixed`, which
  /// wraps itself in `SafeArea(top: false)` — bottom INCLUDED — reading
  /// `MediaQuery.paddingOf(context).bottom` at the SnackBar's own build
  /// context. In an installed iOS PWA that reads zero, so every toast sits
  /// flush on the home indicator.
  ///
  /// It cannot be fixed by theming `fixed` in place: `SnackBarThemeData` has
  /// no margin/inset field that applies to `fixed` mode — the only lever
  /// `fixed` exposes is the ambient `MediaQuery`, and overriding that
  /// globally (e.g. wrapping `MaterialApp.router`'s `child`) would change
  /// `MediaQuery.paddingOf` for every descendant — every `SafeArea`, every
  /// screen's own inset math — not just the SnackBar. That is a much bigger
  /// blast radius than "give the SnackBar clearance", and this app already
  /// has ~70 call sites individually reasoning about their own bottom inset
  /// (see `masiBottomInset`'s doc) that must not be double-adjusted.
  ///
  /// ## The fix: switch to `floating`
  ///
  /// `SnackBarBehavior.floating` does NOT read the ambient safe-area inset at
  /// all — it wraps itself in `SafeArea(top: false, bottom: false)` and
  /// relies entirely on `SnackBarThemeData.insetPadding` for its margin
  /// (verified against the Flutter SDK's `snack_bar.dart`). That makes it the
  /// one behavior where a THEME-level fix is possible: this computes
  /// `insetPadding` once, here, using the exact same `masiBottomInset` helper
  /// every other bottom-anchored element in the app already uses — so a
  /// SnackBar gets the same `max(deviceInset, floor)` treatment as the nav
  /// bar, the topo canvas's route panel, etc.
  ///
  /// **This is a visible restyle of every `SnackBar` in the app**, not just
  /// the ones near the bug: floating SnackBars are inset from all four edges
  /// and get Material 3's floating shape/elevation (a rounded, shadowed
  /// pill), instead of a full-width bar flush with the screen edges. That
  /// trade was made deliberately over the alternative (a global `MediaQuery`
  /// override) because it is the only option that touches SnackBars ONLY —
  /// see the module doc above.
  ///
  /// The `10.0` added to the floored inset is the M3 default floating
  /// `insetPadding`'s own bottom margin (`_SnackBarDefaultsM3.insetPadding`),
  /// preserved so the safe-area floor is additive breathing room on top of
  /// the existing default look, not a replacement for it.
  ///
  /// Needs a [BuildContext] (for the real device inset) and a [WidgetRef]
  /// (`pwaInstallStatusProvider`, read once at app boot — see its doc), so
  /// this is applied in `MasiApp.build`, the one place both are naturally
  /// available, rather than baked into the static [light]/[dark] fields.
  static ThemeData withSnackBarSafeArea(
    ThemeData base,
    BuildContext context,
    WidgetRef ref,
  ) {
    return base.copyWith(
      snackBarTheme: base.snackBarTheme.copyWith(
        behavior: SnackBarBehavior.floating,
        insetPadding: EdgeInsets.fromLTRB(
          15,
          5,
          15,
          10 + masiBottomInset(context, ref),
        ),
      ),
    );
  }

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
      // Form-sized modals (filters, the move picker, route metadata, log
      // ascent) stay Material bottom sheets — they are scrollable forms, not
      // action lists, so they are the one modal family `masi_dialogs.dart`
      // deliberately does NOT absorb. What they lacked was a shared skin:
      // three of them hand-rolled `colors.surface` + a `MasiRadii.large` top
      // radius in their own `BoxDecoration`, while the Logbook and Community
      // filter sheets had no decoration at all and so fell back to Material's
      // seed-generated `surfaceContainerLow` with the default 28px corner —
      // a visibly different sheet for the same job. This makes the
      // hand-rolled look the DEFAULT; those three are now merely redundant
      // with it rather than the only ones that got it right.
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colors.surface,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: colors.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(MasiRadii.large),
          ),
        ),
        clipBehavior: Clip.antiAlias,
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
