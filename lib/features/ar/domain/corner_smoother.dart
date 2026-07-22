import 'dart:ui';

/// Default smoothing factor for [CornerSmoother]'s exponential moving
/// average (EMA) low-pass filter, applied to the 4 (8-double) screen corners
/// ARKit reports for the tracked anchor each frame, before they're used to
/// solve a per-frame [Homography] (see `ar_screen.dart`'s
/// `ArAlignmentStage`).
///
/// `0.35` gives roughly 65% weight to the filter's running state and 35% to
/// each new raw sample — enough to visibly damp frame-to-frame VIO jitter
/// without introducing so much lag that the overlay noticeably trails real
/// camera motion. Tunable: pass a different `alpha` to [CornerSmoother]'s
/// constructor if this needs adjusting later.
const double kCornerSmoothingAlpha = 0.35;

/// Applies a simple exponential-moving-average (EMA) low-pass filter,
/// independently per x/y coordinate, to a sequence of 4-point corner quads
/// (the 8 raw doubles ARKit reports for a tracked anchor's screen corners
/// each frame).
///
/// Pure Dart only (mirrors `homography.dart`'s own constraint): this file
/// must not depend on `package:flutter/material.dart` or
/// `package:flutter/widgets.dart`, so it stays usable/testable without the
/// full Flutter widget stack.
///
/// ## Why this exists
///
/// Feeding ARKit's raw per-frame corners directly into
/// `Homography.fromQuad` (as the pre-A1 code did) renders every frame's raw
/// VIO jitter verbatim — the route overlay visibly shakes even when the
/// camera and the tracked wall are both essentially stationary. Blending
/// each new raw sample with the filter's running state damps that jitter
/// while still tracking genuine camera motion (just with a small amount of
/// lag).
///
/// ## Reset discipline
///
/// [CornerSmoother] instances are meant to be held across many frames (e.g.
/// one instance per [ArController] --  see `ar_controller.dart`), NOT
/// recreated every frame. But blending across a genuine discontinuity (a
/// fresh manual lock, an AR mode switch, or a tracking-loss/re-acquisition
/// gap) would smear the overlay between two unrelated poses for several
/// frames. Callers MUST call [reset] at each such discontinuity so the next
/// [smooth] call is treated as a fresh first sample (pure passthrough)
/// rather than blended against stale state.
class CornerSmoother {
  CornerSmoother({this.alpha = kCornerSmoothingAlpha})
    : assert(alpha > 0 && alpha <= 1, 'alpha must be in (0, 1]');

  /// Weight given to each NEW raw sample, in `(0, 1]`. Lower = smoother
  /// output with more lag; higher = more responsive with less smoothing.
  /// `1.0` disables smoothing entirely (every call returns its input
  /// unchanged).
  final double alpha;

  /// The filter's running (previously-smoothed) state, or `null` immediately
  /// after construction / [reset] (no state to blend against yet).
  List<Offset>? _previous;

  /// Feeds [corners] (must be exactly 4 points: TL, TR, BR, BL) through the
  /// filter and returns the smoothed result.
  ///
  /// On the first call after construction (or after [reset]), there is no
  /// prior state to blend with, so [corners] is returned UNCHANGED and
  /// seeded as the filter's new baseline. Every subsequent call blends the
  /// new raw sample with the running state independently per coordinate:
  /// `smoothed = alpha * raw + (1 - alpha) * previousSmoothed`.
  List<Offset> smooth(List<Offset> corners) {
    assert(corners.length == 4, 'CornerSmoother.smooth requires exactly 4 points');
    final List<Offset>? previous = _previous;
    if (previous == null) {
      final seeded = List<Offset>.unmodifiable(corners);
      _previous = seeded;
      return seeded;
    }

    final List<Offset> result = <Offset>[
      for (int i = 0; i < corners.length; i++)
        Offset(
          alpha * corners[i].dx + (1 - alpha) * previous[i].dx,
          alpha * corners[i].dy + (1 - alpha) * previous[i].dy,
        ),
    ];
    _previous = result;
    return result;
  }

  /// Clears the filter's running state so the NEXT [smooth] call is treated
  /// as a fresh first sample (pure passthrough, no blending against
  /// whatever came before). Call this at every discontinuity: a fresh
  /// manual lock, an AR mode change, or tracking loss — see the class doc.
  void reset() {
    _previous = null;
  }
}
