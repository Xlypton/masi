import 'package:flutter/material.dart';

import '../../app/theme.dart';
import 'masi_loading_gate.dart';

/// The app's ONE spinner — for the cases a skeleton genuinely cannot cover.
///
/// **Reach for a skeleton first.** A shaped placeholder (`MasiSkeleton` and
/// friends) tells the user what is coming; a spinner tells them only that
/// something is happening. Use this widget when the content's shape is
/// genuinely unknowable in advance:
///
///  - hardware/session start-up with no content shape at all — camera, AR
///    session init, a permission handshake;
///  - an image whose intrinsic dimensions are still being resolved, so no box
///    can be reserved yet;
///  - inside a control, as an action's pending cue — and there, prefer
///    `MasiPendingButton`, which wires this up for you including the
///    layout-stability part.
///
/// Timing is not optional and not the call site's problem: this widget is a
/// [MasiLoadingGate] plus a spinner, so it inherits the reveal delay
/// (nothing appears for [MasiMotion.loadingRevealDelay]) and the
/// minimum-visible hold ([MasiMotion.loadingMinVisible]) for free.
///
/// Two usage shapes:
///
/// ```dart
/// // 1. Mounted only while loading (the common conditional-mount case).
/// //    The reveal delay still applies, so a fast load paints nothing.
/// if (_starting) const MasiLoadingIndicator.standalone(label: 'Starting camera…')
///
/// // 2. Driven by a flag, with the loaded content as [child]. Only this shape
/// //    can honour the minimum-visible hold, because only it is still mounted
/// //    at the moment loading ends — prefer it whenever you have the content
/// //    to hand.
/// MasiLoadingIndicator.standalone(
///   isLoading: _starting,
///   child: CameraPreview(controller),
/// )
/// ```
///
/// Reduced motion: under `MediaQuery.disableAnimations` the arc renders as a
/// static determinate sweep instead of rotating — the same "freeze a
/// representative frame" approach `MasiShimmer` takes, so the user still sees
/// *something is loading here* with no motion. Note the side effect: with
/// reduced motion ON there is no repeating animation, so `pumpAndSettle()`
/// works; with it OFF (the default) the rotation never settles — see
/// **Testing** below.
///
/// **Testing.** The spinning arc is an endless animation, so a tree containing
/// a revealed [MasiLoadingIndicator] will hang `pumpAndSettle()` forever. Use
/// explicit `tester.pump(duration)` calls, and find the painted spinner by
/// [spinnerKey] (not `find.byType`, which matches this widget even while the
/// reveal delay is still holding it back):
///
/// ```dart
/// await tester.pump(const Duration(milliseconds: 250)); // past the delay
/// expect(find.byKey(MasiLoadingIndicator.spinnerKey), findsOneWidget);
/// ```
class MasiLoadingIndicator extends StatelessWidget {
  /// A ~20 px cue sized to sit inside a control (button, row trailing slot)
  /// without changing its height. Matches the 20×20 / `strokeWidth: 2` spinner
  /// the Log-Ascent sheet's Save button already used.
  const MasiLoadingIndicator.inline({
    super.key,
    this.isLoading = true,
    this.child,
    this.color,
    this.semanticLabel = 'Loading',
    this.revealDelay = MasiMotion.loadingRevealDelay,
    this.minVisible = MasiMotion.loadingMinVisible,
  }) : label = null,
       _standalone = false;

  /// A ~32 px spinner centred in the space it is given, with an optional
  /// [label] beneath it. For a screen-, sheet- or panel-sized wait.
  const MasiLoadingIndicator.standalone({
    super.key,
    this.isLoading = true,
    this.child,
    this.color,
    this.label,
    this.semanticLabel = 'Loading',
    this.revealDelay = MasiMotion.loadingRevealDelay,
    this.minVisible = MasiMotion.loadingMinVisible,
  }) : _standalone = true;

  /// Diameter of the `.inline` cue. Public so a caller can reserve exactly
  /// this much room and avoid a reflow when the cue appears.
  static const double inlineSize = 20;

  /// Diameter of the `.standalone` spinner.
  static const double standaloneSize = 32;

  /// Key on the actual painted spinner — present only once the gate has
  /// revealed it. The test/adoption handle; see **Testing** in the class doc.
  static const Key spinnerKey = Key('masi-loading-spinner');

  /// Whether the operation is in flight. Defaults to `true` for the
  /// conditional-mount shape (usage 1 above).
  final bool isLoading;

  /// What to render when not loading. Defaults to nothing
  /// ([SizedBox.shrink]), which is what the conditional-mount shape wants.
  final Widget? child;

  /// Arc colour. Defaults to [MasiColors.accent] — this is an activity cue,
  /// and `accent` is the app's single action colour.
  final Color? color;

  /// Optional sentence under a `.standalone` spinner ("Starting camera…").
  /// Say what is being waited on; never "Loading…", which the spinner already
  /// says.
  final String? label;

  /// Screen-reader announcement for the spinner itself.
  final String semanticLabel;

  /// See [MasiLoadingGate.revealDelay].
  final Duration revealDelay;

  /// See [MasiLoadingGate.minVisible].
  final Duration minVisible;

  final bool _standalone;

  @override
  Widget build(BuildContext context) {
    return MasiLoadingGate(
      isLoading: isLoading,
      revealDelay: revealDelay,
      minVisible: minVisible,
      builder: (context, showLoading) {
        if (!showLoading) return child ?? const SizedBox.shrink();
        return _standalone ? _standaloneBody(context) : _inlineBody(context);
      },
    );
  }

  Widget _inlineBody(BuildContext context) => SizedBox(
    width: inlineSize,
    height: inlineSize,
    child: _Arc(
      color: color,
      strokeWidth: 2,
      semanticLabel: semanticLabel,
    ),
  );

  Widget _standaloneBody(BuildContext context) {
    final colors = MasiColors.of(context);
    final labelText = label;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: standaloneSize,
            height: standaloneSize,
            child: _Arc(
              color: color,
              strokeWidth: 3,
              semanticLabel: semanticLabel,
            ),
          ),
          if (labelText != null) ...[
            const SizedBox(height: MasiSpacing.md),
            Text(
              labelText,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(color: colors.ink2),
            ),
          ],
        ],
      ),
    );
  }
}

/// The spinning arc itself: a [CircularProgressIndicator] that freezes into a
/// static determinate sweep under reduced motion, wrapped in its own
/// [RepaintBoundary] so its per-frame repaint cannot escape into whatever it
/// is sitting on (a list row, a photo, a map) — the same reasoning as
/// `MasiShimmer`'s boundary.
class _Arc extends StatelessWidget {
  const _Arc({
    required this.color,
    required this.strokeWidth,
    required this.semanticLabel,
  });

  final Color? color;
  final double strokeWidth;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return RepaintBoundary(
      key: MasiLoadingIndicator.spinnerKey,
      child: CircularProgressIndicator(
        // A fixed three-quarter sweep under reduced motion: recognisable as a
        // progress arc while standing perfectly still. `null` is the normal
        // indeterminate (rotating) case.
        value: reduceMotion ? 0.75 : null,
        strokeWidth: strokeWidth,
        color: color ?? colors.accent,
        semanticsLabel: semanticLabel,
      ),
    );
  }
}
