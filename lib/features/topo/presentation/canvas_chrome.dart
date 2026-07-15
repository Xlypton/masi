import 'dart:ui';

import 'package:flutter/material.dart';

import 'package:climbtopo/app/theme.dart';

/// Deliberately conservative *upper bound* on the on-screen height of
/// [TopoCanvasScreen]'s floating bottom glass cluster (undo / redo /
/// cancel / commit) — NOT including the outer `SafeArea`/margin padding
/// the screen wraps it in.
///
/// Derived from [GlassChrome]'s own vertical padding (8px total: `4` top
/// + `4` bottom, from its default `EdgeInsets.symmetric(horizontal: 8,
/// vertical: 4)`) plus the inner `IconButton` row's real rendered height
/// (Material's `kMinInteractiveDimension` tap target, `48`px — the
/// cluster's `GlassIconButton`s don't override `minimumSize`), for a
/// baseline of `56`. That baseline was measured to fall `2`px short of
/// the cluster's *actual* rendered height (`58`px, observed via
/// `tester.getRect` in `canvas_mode_intent_test.dart`'s `A1e`) — small
/// Material-theme/rendering variance (icon metrics, ink-splash bounds,
/// etc.) that isn't worth chasing exactly. Rather than re-tune to another
/// knife's-edge estimate, this constant is set well above the measured
/// value with real safety margin, so it stays a true upper bound even if
/// that variance shifts slightly across Flutter/Material versions.
///
/// Exposed here (rather than hardcoded in the screen) so other widgets
/// sharing the same screen can reserve enough bottom clearance to avoid
/// being visually covered by the floating cluster — see DESIGN.md "Chrome
/// floats, content is king." Concretely, [TopoCanvasBody] adds this (plus
/// the safe-area inset, a margin, and an explicit breathing-room gap) as
/// bottom padding under [RouteLegend] so the legend's rows are never
/// hidden behind the floating chrome (bug fix: previously the cluster/FAB
/// rendered ON TOP of the legend's last row(s), since both sit at the
/// very bottom of the same [Stack]).
const double kBottomChromeClusterHeight = 64.0;

/// Upper-bound estimate of the top glass title-pill's rendered height
/// (the back button + title + trailing-actions Row inside its GlassChrome),
/// used to clear content rendered beneath the top chrome. Mirrors
/// [kBottomChromeClusterHeight]/[kSymbolPaletteBarHeight].
const double kTopChromeTitleHeight = 64.0;

/// Shared soft, purple-tinted ambient shadow pair — DESIGN.md "Form —
/// depth": `rgba(38,26,72,·)` rather than a neutral black drop shadow.
/// Factored out of [GlassChrome]'s decoration (below) so the topo canvas's
/// photo-viewport frame (see `TopoCanvas`'s screen-space frame, Fix 2 of the
/// canvas UI fixes) can reuse the EXACT same shadow pair — the floating
/// glass chrome and the floating photo panel are meant to read as the same
/// visual material, per DESIGN.md's "Chrome floats, content is king."
const List<BoxShadow> kMasiAmbientShadow = [
  BoxShadow(color: Color(0x0F261A48), blurRadius: 2, offset: Offset(0, 1)),
  BoxShadow(color: Color(0x14261A48), blurRadius: 24, offset: Offset(0, 8)),
];

/// A floating translucent-glass container for the topo canvas's chrome:
/// [BackdropFilter] blur over whatever's behind it (the photo) + the MASI
/// `chrome` token fill + a rounded, pill-like shape + a soft shadow + a
/// hairline `separator` border.
///
/// Per DESIGN.md's "Topo canvas" spec: chrome floats on translucent glass
/// over the photo rather than sitting in an opaque Material `AppBar`/
/// `BottomAppBar` — the image should be visible (blurred) behind every
/// control, never fully covered.
class GlassChrome extends StatelessWidget {
  const GlassChrome({
    super.key,
    required this.child,
    this.borderRadius = MasiRadii.large,
    this.padding = const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    this.blurSigma = 18,
    this.strong = false,
  });

  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry padding;
  final double blurSigma;

  /// When `true`, renders a heavier "strong" frosted variant: a higher
  /// blur sigma (~30, vs. the default [blurSigma]) plus a near-opaque
  /// neutral `surface` scrim composited BEHIND the usual tinted [chrome]
  /// fill (inside the same [ClipRRect] + [BackdropFilter], so it still
  /// clips to the pill shape and sits over the blurred backdrop).
  ///
  /// Without this, a strongly-saturated region behind the glass (e.g. a
  /// magenta patch of photo) can bleed through the semi-transparent
  /// [MasiColors.chrome] tint as a hard two-tone blob — the neutral scrim
  /// mutes whatever color is behind the card first, so the card's tint
  /// reads as nearly invariant to what's underneath. The default `false`
  /// path (used by the top pill, bottom cluster, and symbol palette bar)
  /// renders the SAME kind of scrim at a lighter alpha (0.78 vs. `strong`'s
  /// 0.92) — enough to kill saturated photo-color smears while staying
  /// visibly glassier than the `strong` variant, which is reserved for
  /// chrome that floats over the most uncontrolled photo content (e.g. the
  /// route legend).
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final radius = BorderRadius.circular(borderRadius);
    final sigma = strong ? 30.0 : blurSigma;
    // Content-invariant neutral scrim, rendered BEHIND the tinted `chrome`
    // fill in both paths — see [strong]'s doc for the motivating bug. Only
    // the alpha differs: `strong` uses a near-opaque 0.92 (unchanged look,
    // e.g. the route legend); the default path uses a lighter 0.78, just
    // enough to mute a saturated photo region before the semi-transparent
    // `chrome` tint reaches the surface, while staying visibly glassy.
    final scrimAlpha = strong ? 0.92 : 0.78;
    final tintedCard = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: colors.chrome,
        borderRadius: radius,
        border: Border.all(color: colors.separator),
        // DESIGN.md "Form — depth": soft, purple-tinted shadows
        // (rgba(38,26,72,·)) rather than a neutral black — matches the
        // rest of the app's shadow language instead of a generic
        // Material drop shadow. Shared with the topo canvas's photo
        // frame via [kMasiAmbientShadow].
        boxShadow: kMasiAmbientShadow,
      ),
      child: child,
    );
    return ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surface.withValues(alpha: scrimAlpha),
            borderRadius: radius,
          ),
          child: tintedCard,
        ),
      ),
    );
  }
}

/// A round glyph button for use inside a [GlassChrome] cluster (back
/// chevron, undo/redo/commit, mode toggles, ...). Per DESIGN.md
/// "Navigation": trailing actions are `accent` glyphs, never a filled
/// button in the bar — [active] adds only a faint accent-tinted wash
/// (`~16%`, matching the "Tinted" button spec) to mark the current tool/
/// mode, not a solid fill.
class GlassIconButton extends StatelessWidget {
  const GlassIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.active = false,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      icon: Icon(icon),
      color: onPressed == null ? colors.ink3 : colors.accent,
      style: IconButton.styleFrom(
        backgroundColor: active
            ? colors.accent.withValues(alpha: 0.16)
            : null,
        shape: const CircleBorder(),
      ),
    );
  }
}

/// The circular `accent` capture/add-photo FAB that floats over the canvas
/// alongside the bottom glass cluster (DESIGN.md "Topo canvas": "...+ the
/// accent capture/add FAB"), with an `onAccent`-colored glyph per the
/// "Filled" button spec.
class TopoCaptureFab extends StatelessWidget {
  const TopoCaptureFab({
    super.key,
    required this.onPressed,
    this.tooltip,
    this.icon = Icons.add_photo_alternate_outlined,
  });

  final VoidCallback onPressed;
  final String? tooltip;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    return Material(
      color: colors.accent,
      shape: const CircleBorder(),
      elevation: 0,
      shadowColor: colors.accent.withValues(alpha: 0.35),
      child: InkWell(
        onTap: onPressed,
        customBorder: const CircleBorder(),
        child: Tooltip(
          message: tooltip ?? '',
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Icon(icon, color: colors.onAccent),
          ),
        ),
      ),
    );
  }
}
