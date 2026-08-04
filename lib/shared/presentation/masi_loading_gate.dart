import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../app/theme.dart';

/// The app's anti-flash / anti-strobe timing engine: turns a raw
/// "is something loading right now" boolean into "should a loading affordance
/// be on screen right now", so no call site has to own timers.
///
/// Two rules, both from [MasiMotion] (see those tokens for the reasoning):
///
///  1. **Reveal delay** — [isLoading] going true does NOT show anything for
///     [MasiMotion.loadingRevealDelay]. An operation that finishes inside that
///     window paints no loading state at all, ever. This is what stops a fast
///     Drift read from flickering a skeleton.
///  2. **Minimum visible** — once the affordance has been revealed it stays
///     for at least [MasiMotion.loadingMinVisible], even if [isLoading] has
///     already gone false. This is what stops the affordance from strobing
///     when a load lands just past the reveal delay.
///
/// [builder] is called with `showLoading`; render the affordance when it is
/// true and the real content when it is false. The gate itself paints nothing,
/// so it composes with anything — a skeleton, a spinner, a dimmed button
/// label, a progress bar.
///
/// ```dart
/// MasiLoadingGate(
///   isLoading: _saving,
///   builder: (context, showLoading) =>
///       showLoading ? const MasiLoadingIndicator.inline() : const Text('Save'),
/// )
/// ```
///
/// **Important — the gate is a VISUAL debounce, not a lock.** It must never be
/// what decides whether an action may run: during the reveal delay
/// `showLoading` is false while the operation is very much in flight. Guard
/// re-entrancy with your own in-flight flag (this is exactly what
/// `MasiPendingButton` does: it disables itself the instant it is tapped, and
/// only the *spinner* waits on this gate).
///
/// **[isLoading] must be reachable-false.** The gate has no way to time out: it
/// reveals after the delay and then waits, forever if need be, for a `false`.
/// Two expressions that never deliver one, both of which have shipped:
///
///  - a literal `isLoading: true`, which asks for a permanent affordance and
///    gets one (plus a `pumpAndSettle()` that hangs in every test that mounts
///    it);
///  - a bare `!asyncValue.hasValue`. On an `AsyncError` `hasValue` is false and
///    `isLoading` is false, and a `FutureProvider` does not re-emit on its own,
///    so this is true for the life of the screen. Write
///    `asyncValue.isLoading && !asyncValue.hasValue` and render the error state
///    separately — or just use `MasiAsyncView`, which owns all four states.
///
/// If a permanent affordance really is what you want, say so with a widget that
/// paints one; do not express it as a load that never finishes.
///
/// **Testing.** Timing is driven by [Timer], so it advances under
/// `tester.pump(duration)` — no `pumpAndSettle()` needed for the gate itself
/// (though whatever the builder renders may forbid `pumpAndSettle()` on its
/// own account; `MasiShimmer` does). A worked sequence:
///
/// ```dart
/// await tester.pumpWidget(gate(isLoading: true));
/// // Nothing yet — inside the reveal delay.
/// await tester.pump(const Duration(milliseconds: 100));
/// expect(find.byKey(loadingKey), findsNothing);
/// // Past it — revealed.
/// await tester.pump(const Duration(milliseconds: 120));
/// expect(find.byKey(loadingKey), findsOneWidget);
/// ```
class MasiLoadingGate extends StatefulWidget {
  const MasiLoadingGate({
    super.key,
    required this.isLoading,
    required this.builder,
    this.revealDelay = MasiMotion.loadingRevealDelay,
    this.minVisible = MasiMotion.loadingMinVisible,
  });

  /// Whether the underlying operation is in flight *right now*. The gate
  /// converts this into the delayed/held `showLoading` it hands [builder].
  final bool isLoading;

  /// Builds the subtree. `showLoading` is the gated verdict — NOT [isLoading].
  final Widget Function(BuildContext context, bool showLoading) builder;

  /// Overridable for the rare case that needs different timing (and for
  /// tests). [Duration.zero] reveals synchronously on the first build, with no
  /// timer and no intermediate frame — useful when a caller has already
  /// debounced upstream.
  final Duration revealDelay;

  /// Overridable minimum-visible hold. [Duration.zero] hides the moment
  /// [isLoading] goes false.
  final Duration minVisible;

  @override
  State<MasiLoadingGate> createState() => _MasiLoadingGateState();
}

class _MasiLoadingGateState extends State<MasiLoadingGate> {
  /// The gated verdict handed to `builder`.
  bool _showLoading = false;

  /// Counting down [MasiLoadingGate.revealDelay]. Non-null means "loading, but
  /// not yet allowed on screen".
  Timer? _revealTimer;

  /// Counting down [MasiLoadingGate.minVisible]. Non-null means "on screen and
  /// pinned there, whatever `isLoading` says".
  Timer? _holdTimer;

  @override
  void initState() {
    super.initState();
    // A zero reveal delay is resolved inline rather than via a zero-duration
    // Timer: a Timer would still cost one frame of not-yet-showing, which is
    // precisely what a caller asking for zero delay is asking to avoid.
    if (widget.isLoading && widget.revealDelay == Duration.zero) {
      _showLoading = true;
      _startHold();
    } else {
      _sync();
    }
  }

  @override
  void didUpdateWidget(MasiLoadingGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isLoading != widget.isLoading) _sync();
  }

  @override
  void dispose() {
    // Both timers capture `this` and call setState. Cancelling here is what
    // makes a widget disposed mid-delay safe: without it, a screen popped
    // 100 ms into a load fires setState on an unmounted State ~80 ms later.
    _revealTimer?.cancel();
    _holdTimer?.cancel();
    super.dispose();
  }

  /// Drives the state machine from the current [MasiLoadingGate.isLoading].
  void _sync() {
    if (widget.isLoading) {
      if (_showLoading) return; // Already up; the hold (if any) governs.
      _revealTimer ??= Timer(widget.revealDelay, _reveal);
      return;
    }

    // Not loading any more.
    // Cancel a pending reveal: this is the whole anti-flash win — a load that
    // finished inside the reveal window never shows anything at all.
    _revealTimer?.cancel();
    _revealTimer = null;
    if (!_showLoading) return;
    // Revealed already: the hold timer, if still running, owns the hide (see
    // _startHold). Otherwise hide now.
    if (_holdTimer == null) _hide();
  }

  void _reveal() {
    _revealTimer = null;
    if (!mounted) return;
    setState(() => _showLoading = true);
    _startHold();
  }

  void _startHold() {
    if (widget.minVisible == Duration.zero) return;
    _holdTimer = Timer(widget.minVisible, () {
      _holdTimer = null;
      if (!mounted) return;
      // The load may have finished during the hold — in which case this is the
      // hide that was deferred by _sync — or may still be running, in which
      // case the affordance simply stays up unpinned.
      if (!widget.isLoading) _hide();
    });
  }

  void _hide() {
    if (_showLoading) setState(() => _showLoading = false);
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _showLoading);
}
