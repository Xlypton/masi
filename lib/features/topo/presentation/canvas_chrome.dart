import 'dart:ui';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'package:masi/app/theme.dart';

/// Deliberately conservative *upper bound* on the on-screen height of
/// [TopoCanvasScreen]'s floating bottom glass cluster (undo / redo /
/// cancel / commit) — NOT including the outer `SafeArea`/margin padding
/// the screen wraps it in.
///
/// Derived from [GlassChrome]'s own vertical padding (8px total: `4` top
/// + `4` bottom, from its default `EdgeInsets.symmetric(horizontal: 8,
/// vertical: 4)`) plus the inner `IconButton` row's real rendered height
/// (Material's `kMinInteractiveDimension` tap target, `48`px — the
/// cluster's `IconButton`s don't override `minimumSize`), for a
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
/// depth": `rgba(38,26,72,·)` rather than a neutral black drop shadow. Used
/// by several of this app's other floating card surfaces (e.g.
/// `AccountScreen`, `CommunityTopoDetailScreen`, `InstallBanner`) so the
/// floating glass chrome and those cards read as the same visual material,
/// per DESIGN.md's "Chrome floats, content is king."
///
/// NOT applied by [GlassChrome] itself (below) despite living in this same
/// file: it used to be, but that box sat INSIDE the `ClipRRect` bounding
/// [GlassChrome]'s blur, which clipped every pixel of the shadow away
/// before it ever reached the screen — see [GlassChrome.build]'s "dead
/// shadow" doc for the full story. Left defined here (rather than moved)
/// since every other consumer above still imports it from this file.
const List<BoxShadow> kMasiAmbientShadow = [
  BoxShadow(color: Color(0x0F261A48), blurRadius: 2, offset: Offset(0, 1)),
  BoxShadow(color: Color(0x14261A48), blurRadius: 24, offset: Offset(0, 8)),
];

/// A floating translucent-glass container for the topo canvas's chrome:
/// [BackdropFilter] blur over whatever's behind it (the photo) + the MASI
/// `chrome` token fill + a rounded, pill-like shape + a hairline `separator`
/// border. (No drop shadow — see [build]'s "dead shadow" doc for why.)
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
    this.blur = true,
  });

  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry padding;
  final double blurSigma;

  /// Web-perf opt-out: when `false`, this instance renders as a SOLID
  /// `chrome`-tinted panel (same shape/padding/border) with no
  /// [BackdropFilter] at all — for callers that would otherwise stack
  /// several simultaneous [GlassChrome] blurs on web (e.g. the topo canvas's
  /// route legend, which frequently coincides with the bottom action
  /// cluster + title pill while drawing).
  ///
  /// Only takes effect on web (`kIsWeb`) — **iOS always gets the real blur**
  /// regardless of this flag: the simultaneous-BackdropFilter compositing
  /// cost this solves is web-specific (`BackdropFilter` is comparatively
  /// cheap on Skia/Impeller on-device, and iOS never stacks this many at
  /// once), so there's no reason to give up the frosted-glass look there.
  /// Defaults to `true` (real blur everywhere), preserving every existing
  /// call site's appearance exactly.
  final bool blur;

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
    // Web-perf fix: a high-sigma Gaussian blur is one of the more expensive
    // compositing operations on web (CanvasKit/Skia — and every simultaneous
    // BackdropFilter on screen adds up), so web gets a noticeably lower
    // sigma (18→10 default, 30→16 strong) than [strong]/[blurSigma]'s
    // iOS-tuned values, which are kept EXACTLY as before there.
    final sigma = kIsWeb
        ? (strong ? 16.0 : 10.0)
        : (strong ? 30.0 : blurSigma);
    // Content-invariant neutral scrim, rendered BEHIND the tinted `chrome`
    // fill in both paths — see [strong]'s doc for the motivating bug. Only
    // the alpha differs. On native, BackdropFilter blur (sigma 18–30) carries
    // most of the visual separation, so a lower scrim alpha keeps the glass
    // feel. On web there is no blur (`blur: !kIsWeb`), so the scrim ALONE
    // must guarantee legibility over a busy photo — hence the higher web
    // values. `strong` (route legend, a content panel) stays more opaque than
    // the floating pills in both modes.
    final scrimAlpha = kIsWeb
        ? (strong ? 0.88 : 0.60)
        : (strong ? 0.68 : 0.45);
    final tintedCard = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: colors.chrome,
        borderRadius: radius,
        border: Border.all(color: colors.separator),
        // Dead-shadow fix: `kMasiAmbientShadow` (blurRadius 24) used to live
        // right here — but this `Container` sits INSIDE the `ClipRRect`
        // below that bounds the blur, and a `BoxShadow` only ever paints
        // OUTSIDE its own box's bounds. Since `ClipRRect`'s clip rect
        // exactly matches this box's size (nothing between them adds size),
        // every one of the shadow's pixels — and the 24px `blurRadius`
        // compute behind them — was being clipped away before ever reaching
        // the screen, on EVERY paint of EVERY `GlassChrome` instance: pure
        // wasted work, and (confirmed by tracing the tree) truly invisible
        // today. Dropped rather than relocated outside the clip: relocating
        // would make it newly VISIBLE — a real, currently-unintended
        // appearance change — and would add a new per-frame compositing
        // cost instead of removing one, the opposite of this pass's goal.
        // Dropping matches today's actual (accidentally shadow-less)
        // rendering exactly, on both platforms, while also skipping the
        // wasted blur computation entirely.
      ),
      child: child,
    );

    // Web opt-out: skip the expensive `BackdropFilter` blur, but STILL render
    // the same neutral `surface @ scrimAlpha` scrim BEHIND the tinted card as
    // the real-blur path below. Without that scrim the panel is only the
    // semi-transparent `chrome` tint (~54%/50% alpha) over bare content, so a
    // busy photo (topo canvas route legend) bleeds straight through and the
    // text is unreadable. Blur normally boosts perceived coverage; with no
    // blur on web the scrim alone must carry legibility, so we keep it.
    // Wrapped in the same `ClipRRect` so content clips to the identical
    // rounded shape either way. See [blur]'s doc: this only triggers on web,
    // and only when a caller explicitly asks for it; iOS always blurs below.
    if (kIsWeb && !blur) {
      return ClipRRect(
        borderRadius: radius,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surface.withValues(alpha: scrimAlpha),
            borderRadius: radius,
          ),
          child: tintedCard,
        ),
      );
    }

    return ClipRRect(
      borderRadius: radius,
      // Isolates the blur into its own compositing layer so its frequent
      // repaints (or a repaint of whatever's behind it) don't force a
      // re-composite of unrelated siblings/ancestors — e.g. the topo
      // canvas's photo layer next to it. Harmless on iOS; a real saving on
      // web, where several `GlassChrome`s can be on screen at once.
      child: RepaintBoundary(
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
      ),
    );
  }
}
