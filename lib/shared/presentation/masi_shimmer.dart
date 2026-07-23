import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// A reusable animated "still loading" skeleton: a soft diagonal
/// [MasiColors.amethyst100] band sweeping across a [MasiColors.surface2]
/// base, filling its parent (`double.infinity` in both dimensions).
///
/// Built for [PhotoImage]'s new `loadingPlaceholder` slot (#56 — see that
/// class's doc): callers that already clip/round their box (every existing
/// 52px thumbnail wraps its [PhotoImage] in a `ClipRRect`) get a correctly
/// rounded shimmer for free, so this widget applies no radius of its own —
/// exactly like the pre-existing static `_GradientFallback` it sits
/// alongside.
///
/// Respects `MediaQuery.disableAnimations` (reduced-motion): the sweep
/// freezes at a fixed mid-point frame instead of animating, so a
/// reduced-motion user still sees the same visual (a photo is loading here)
/// without the motion.
///
/// **Widget-test footgun**: the sweep's `AnimationController..repeat()` never
/// completes -- that's the whole point, it animates for as long as the photo
/// is loading. A widget test that renders this (directly, or transitively via
/// a still-loading `PhotoImage`) must drive it with a bounded
/// `tester.pump(someDuration)` (or a fixed number of `pump()` calls), never
/// `tester.pumpAndSettle()` -- `pumpAndSettle()` waits for animations to stop
/// scheduling new frames, which this one never does, so it spins until it
/// times out. See `community_screen_test.dart`'s "Clear resets both
/// sub-filters" test for a worked example of the fix.
class MasiShimmer extends StatefulWidget {
  const MasiShimmer({super.key});

  @override
  State<MasiShimmer> createState() => _MasiShimmerState();
}

class _MasiShimmerState extends State<MasiShimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _checkedMotionPref = false;

  static const _period = Duration(milliseconds: 1400);

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _period)
      ..repeat();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // MediaQuery.of must be read from didChangeDependencies, not initState
    // (the InheritedWidget dependency isn't established yet there). Checked
    // once: reduced-motion is not expected to flip mid-lifetime, and the
    // controller's own repeat()/stop() calls are otherwise idempotent.
    if (_checkedMotionPref) return;
    _checkedMotionPref = true;
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) {
      _controller
        ..stop()
        ..value = 0.5; // A single static mid-sweep frame.
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final highlight = _highlightFor(context, colors);
    // RepaintBoundary around the AnimatedBuilder's output: this widget is
    // used per-thumbnail, so many instances can be ticking at once (e.g. a
    // grid/list of still-loading photos). Without a boundary here, each
    // controller tick's repaint bubbles up to the nearest ancestor
    // RepaintBoundary/layer -- often shared with sibling list tiles -- so one
    // shimmer's every-frame gradient sweep can force repaints of unrelated
    // content around it. Isolating the sweep to its own layer confines that
    // per-frame repaint cost to exactly this tile.
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          // Sweeps the highlight band from just off the top-left to just off
          // the bottom-right and back to the start on each repeat (a
          // continuous left-to-right pass, not a ping-pong), by translating a
          // fixed-stop gradient horizontally via `GradientTransform`.
          final slide = (_controller.value * 2) - 1; // -1.0 .. 1.0
          return DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [colors.surface2, highlight, colors.surface2],
                stops: const [0.35, 0.5, 0.65],
                transform: _SlidingGradientTransform(slide),
              ),
            ),
            child: const SizedBox.expand(),
          );
        },
      ),
    );
  }

  /// The sweep's highlight color: a subtle, theme-adaptive step lighter than
  /// [MasiColors.surface2] rather than the fixed [MasiColors.amethyst100]
  /// this used to paint unconditionally.
  ///
  /// [MasiColors.amethyst100] is THEME-INVARIANT (identical hex in light and
  /// dark, see `theme.dart`), while [MasiColors.surface2] flips (near-white
  /// in light, dark purple in dark) -- painting the same fixed light-lavender
  /// highlight over both looks like a subtle sheen in light mode (verified
  /// good, kept as-is here) but a jarring near-white flash in dark mode.
  /// There's no dedicated `surface3`/elevated-surface token to reach for
  /// instead, so dark mode blends `surface2` toward the brand ramp's
  /// `amethyst400` -- much closer in luminance to a dark surface than
  /// `amethyst100`'s near-white -- producing a moderate, on-brand sheen
  /// instead of a flash.
  Color _highlightFor(BuildContext context, MasiColors colors) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (!isDark) return colors.amethyst100;
    return Color.lerp(colors.surface2, colors.amethyst400, 0.55)!;
  }
}

/// Translates a [LinearGradient] horizontally by `slidePercent` of the
/// painted box's width, driving [MasiShimmer]'s sweep — the same technique
/// the well-known `shimmer` package uses, hand-rolled here so no new
/// dependency is needed for one small effect.
class _SlidingGradientTransform extends GradientTransform {
  const _SlidingGradientTransform(this.slidePercent);

  final double slidePercent;

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) {
    return Matrix4.translationValues(bounds.width * slidePercent, 0, 0);
  }
}
