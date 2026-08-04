import 'package:flutter/material.dart';

import '../../app/theme.dart';
import 'masi_loading_gate.dart';
import 'masi_loading_indicator.dart';

/// Which button chrome [MasiPendingButton] wears. The pending behaviour is
/// identical in both; only the paint differs.
enum MasiPendingButtonVariant {
  /// A filled accent button — a primary action (Save, Publish, Sign in).
  filled,

  /// A borderless accent label — a secondary or destructive-confirm action.
  text,
}

/// A button whose action is a [Future], with the pending state handled
/// properly: the tap is consumed once, the control disables itself
/// immediately, the cue lands ON the button the user actually touched, and the
/// button does not change size while it waits.
///
/// This exists because "async button" was a whole class of bug in this app:
/// nine buttons ran an `await` from `onPressed` with nothing stopping a second
/// tap, so an impatient double-tap could publish twice, log two ascents, or
/// fire two writes at one row.
///
/// ```dart
/// MasiPendingButton.filled(
///   key: const Key('log-ascent-save'),
///   expand: true,
///   onPressed: () => _save(),      // Future<void> Function()
///   child: const Text('Save'),
/// )
/// ```
///
/// ## What it guarantees
///
///  - **One tap.** Taps arriving while the future is in flight are dropped.
///    The guard is a plain in-flight flag set synchronously inside the tap
///    handler, NOT the visual gate below — during the reveal delay the button
///    looks idle but is emphatically not.
///  - **Immediate disable.** `onPressed` goes null the moment work starts, so
///    the press ripple/disabled colour is instant feedback even before any
///    spinner is allowed to show.
///  - **Stable size.** The label stays laid out (a [Visibility] with
///    `maintainSize`) and the spinner is drawn *over* it, so the button cannot
///    change width when a label is replaced by a cue. Swapping the child for a
///    spinner — the usual way this is done — makes a "Publish topo" button
///    snap to 20 px wide and shove the rest of the row sideways.
///  - **No flash.** The spinner itself goes through [MasiLoadingGate]
///    ([MasiMotion.loadingRevealDelay] / [MasiMotion.loadingMinVisible]), so a
///    fast save shows no spinner at all rather than a 60 ms blip.
///  - **No setState after dispose.** A sheet dismissed while its save is in
///    flight is normal here, not a crash.
///
/// Failures: [onPressed]'s future is awaited in a `try`/`finally`, so the
/// pending state always clears. If it throws, [onError] is called when
/// supplied; otherwise the error is reported to [FlutterError.reportError]
/// rather than swallowed. Prefer handling it — a failed write the user is
/// never told about is the worse bug.
///
/// **Testing.** While pending, the button contains a live spinner, so
/// `pumpAndSettle()` hangs — pump explicit durations. The pending spinner is
/// [MasiLoadingIndicator.spinnerKey]; to prove taps are swallowed, complete
/// the future from a [Completer] you control and count invocations.
class MasiPendingButton extends StatefulWidget {
  const MasiPendingButton.filled({
    super.key,
    required this.onPressed,
    required this.child,
    this.style,
    this.expand = false,
    this.onError,
    this.revealDelay = MasiMotion.loadingRevealDelay,
    this.minVisible = MasiMotion.loadingMinVisible,
  }) : variant = MasiPendingButtonVariant.filled;

  const MasiPendingButton.text({
    super.key,
    required this.onPressed,
    required this.child,
    this.style,
    this.expand = false,
    this.onError,
    this.revealDelay = MasiMotion.loadingRevealDelay,
    this.minVisible = MasiMotion.loadingMinVisible,
  }) : variant = MasiPendingButtonVariant.text;

  /// The action. `null` disables the button (same contract as any Material
  /// button). A non-`Future` callback does not belong here — use a plain
  /// button; there is nothing to be pending about.
  final Future<void> Function()? onPressed;

  /// The label. Kept laid out while pending — see "Stable size".
  final Widget child;

  /// Chrome.
  final MasiPendingButtonVariant variant;

  /// Optional overrides merged over the variant's own style.
  final ButtonStyle? style;

  /// Stretch to the available width (`width: double.infinity`), which is how
  /// the app's bottom-pinned primary actions are laid out.
  final bool expand;

  /// Called if [onPressed]'s future fails. Without it the error goes to
  /// [FlutterError.reportError] — visible, never silent.
  final void Function(Object error, StackTrace stackTrace)? onError;

  /// See [MasiLoadingGate.revealDelay]. Affects only when the SPINNER appears;
  /// the disable and the tap-swallow are always immediate.
  final Duration revealDelay;

  /// See [MasiLoadingGate.minVisible].
  final Duration minVisible;

  @override
  State<MasiPendingButton> createState() => _MasiPendingButtonState();
}

class _MasiPendingButtonState extends State<MasiPendingButton> {
  /// True from the synchronous instant of the tap until the future settles.
  /// This — not the gate's `showLoading` — is what makes the button
  /// single-shot.
  bool _inFlight = false;

  Future<void> _handleTap() async {
    // The double-tap swallow. Two taps in the same frame both reach here; the
    // second sees `_inFlight` already true and returns.
    if (_inFlight) return;
    final action = widget.onPressed;
    if (action == null) return;

    setState(() => _inFlight = true);
    try {
      await action();
    } catch (error, stackTrace) {
      final onError = widget.onError;
      if (onError != null) {
        onError(error, stackTrace);
      } else {
        // Reported rather than rethrown: rethrowing out of a gesture callback
        // becomes an uncaught async error with no context, and swallowing it
        // hides a failed write from the user AND from the logs.
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'masi',
            context: ErrorDescription('while running a MasiPendingButton action'),
          ),
        );
      }
    } finally {
      // The whole reason this is a StatefulWidget with a mounted check: the
      // sheet/dialog this button lives in is very often popped by the action
      // itself, so by the time the future settles this State can be gone.
      if (mounted) setState(() => _inFlight = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final enabled = widget.onPressed != null && !_inFlight;

    final button = MasiLoadingGate(
      isLoading: _inFlight,
      revealDelay: widget.revealDelay,
      minVisible: widget.minVisible,
      builder: (context, showSpinner) {
        final label = Stack(
          alignment: Alignment.center,
          children: [
            // `maintainSize` keeps the label's box (and therefore the
            // button's width) exactly as it was; `maintainSemantics` stays
            // false so a screen reader is not told about a label that is not
            // currently being shown.
            Visibility(
              visible: !showSpinner,
              maintainSize: true,
              maintainAnimation: true,
              maintainState: true,
              child: widget.child,
            ),
            if (showSpinner)
              MasiLoadingIndicator.inline(
                // The gate above already applied the reveal delay and owns the
                // minimum-visible hold, so the indicator must not re-apply
                // either: nested delays would stack into ~360 ms.
                revealDelay: Duration.zero,
                minVisible: Duration.zero,
                color: widget.variant == MasiPendingButtonVariant.filled
                    ? colors.onAccent
                    : colors.accent,
                semanticLabel: 'Working',
              ),
          ],
        );

        return switch (widget.variant) {
          MasiPendingButtonVariant.filled => ElevatedButton(
            onPressed: enabled ? _handleTap : null,
            style: _filledStyle(colors, pending: _inFlight).merge(widget.style),
            child: label,
          ),
          MasiPendingButtonVariant.text => TextButton(
            onPressed: enabled ? _handleTap : null,
            style: _textStyle(colors).merge(widget.style),
            child: label,
          ),
        };
      },
    );

    return widget.expand
        ? SizedBox(width: double.infinity, child: button)
        : button;
  }

  /// Matches the app's existing primary-action recipe (`accent` fill,
  /// `onAccent` label, 14 px vertical padding, 13 px radius) — the same one
  /// `crud_list_scaffold.dart`'s bottom-pinned create button paints by hand.
  ///
  /// [pending] distinguishes the two ways this button can be disabled, which
  /// must NOT look the same: a caller-disabled button (`onPressed: null`) keeps
  /// Material's greyed-out disabled colours, because it means "you cannot do
  /// this"; a button disabled because its own action is running keeps the
  /// accent fill at reduced opacity, because it means "this is happening".
  ButtonStyle _filledStyle(MasiColors colors, {required bool pending}) =>
      ElevatedButton.styleFrom(
        backgroundColor: colors.accent,
        foregroundColor: colors.onAccent,
        disabledBackgroundColor: pending
            ? colors.accent.withValues(alpha: 0.6)
            : null,
        disabledForegroundColor: pending ? colors.onAccent : null,
        padding: const EdgeInsets.symmetric(vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
      );

  ButtonStyle _textStyle(MasiColors colors) => TextButton.styleFrom(
    foregroundColor: colors.accent,
    disabledForegroundColor: colors.ink3,
  );
}
