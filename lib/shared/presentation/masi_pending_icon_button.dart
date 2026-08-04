import 'package:flutter/material.dart';

import '../../app/theme.dart';
import 'masi_loading_indicator.dart';
import 'masi_pending_button.dart';

/// An [IconButton] whose action is a [Future] — the icon-shaped sibling of
/// [MasiPendingButton].
///
/// That widget is the app's answer to "a button whose `onPressed` awaits", but
/// it only comes in filled/text chrome: wearing it would turn a 48 px round
/// glyph control (post-a-comment, the map's refresh/find-me, a list row's
/// rename/delete) into a labelled button. This keeps the glyph and copies the
/// three guarantees that actually matter, for the same reasons — see
/// [MasiPendingButton]'s doc:
///
///  - **One tap.** A synchronous in-flight flag drops taps arriving while the
///    future runs. That is the whole point here: before this, a double-tapped
///    Post wrote two comments and a double-tapped like double-toggled.
///  - **Immediate disable.** `onPressed` goes null the instant work starts, so
///    the disabled colour is feedback even before any spinner may appear.
///  - **No flash, no reflow.** The cue is [MasiLoadingIndicator.inline], so it
///    inherits the reveal delay (a fast local write shows no spinner at all)
///    and the minimum-visible hold, and at 20 px it sits inside the same 48 px
///    button box the glyph did.
///
/// [buttonKey] rather than this widget's own `key` lands on the inner
/// [IconButton] — the widget a test taps and reads `onPressed` off — mirroring
/// `community_map_screen.dart`'s existing `_MapControlButton.mapControlKey`
/// convention.
///
/// Pass [onError] wherever a failure should be user-visible; without it the
/// error goes to [FlutterError.reportError] (which fails a widget test by
/// design) rather than being swallowed.
///
/// If the action opens a dialog or confirm sheet BEFORE it writes — a row's
/// rename/delete glyph, say — use [onPressedArmed] instead of [onPressed]; see
/// [MasiBusyReporter].
class PendingIconButton extends StatefulWidget {
  const PendingIconButton({
    super.key,
    this.buttonKey,
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.onPressedArmed,
    this.onError,
    this.spinnerColor,
    this.visualDensity,
  }) : assert(
         onPressed == null || onPressedArmed == null,
         'Supply either onPressed or onPressedArmed, not both.',
       );

  /// Key for the inner [IconButton] — see the class doc. Omit it where the
  /// tappable surface is already keyed by an ancestor (the map's controls key
  /// their wrapping [Material]).
  final Key? buttonKey;

  /// The glyph. Kept as-is while idle; swapped for the 20 px cue while the
  /// spinner is revealed.
  final Widget icon;

  final String tooltip;

  /// The action. `null` disables the button, same contract as [IconButton] —
  /// unless [onPressedArmed] is supplied instead.
  final Future<void> Function()? onPressed;

  /// The action, for the `ask the user → then write` shape: the cue stays OFF
  /// until the action calls the [MasiBusyReporter] it is handed. Mutually
  /// exclusive with [onPressed] (asserted).
  final Future<void> Function(MasiBusyReporter reportBusy)? onPressedArmed;

  /// Called if the action's future fails.
  final void Function(Object error, StackTrace stackTrace)? onError;

  /// Spinner colour; defaults to [MasiColors.accent] via
  /// [MasiLoadingIndicator].
  final Color? spinnerColor;

  final VisualDensity? visualDensity;

  @override
  State<PendingIconButton> createState() => _PendingIconButtonState();
}

class _PendingIconButtonState extends State<PendingIconButton> {
  /// True from the synchronous instant of the tap until the future settles,
  /// modal and all — this, never the indicator's visual gate and never
  /// [_working], is what makes the control single-shot (during the reveal delay
  /// it looks idle but is not).
  bool _locked = false;

  /// Whether the APP's own work is in flight: the visible half. Tracks [_locked]
  /// for [PendingIconButton.onPressed]; armed by the action itself for
  /// [PendingIconButton.onPressedArmed].
  bool _working = false;

  void _report(bool isBusy) {
    if (!mounted) return;
    if (isBusy != _working) setState(() => _working = isBusy);
  }

  Future<void> _handleTap() async {
    if (_locked) return;
    final action = widget.onPressed;
    final armed = widget.onPressedArmed;
    if (action == null && armed == null) return;
    _locked = true;
    if (action != null) setState(() => _working = true);
    try {
      if (action != null) {
        await action();
      } else {
        await armed!(_report);
      }
    } catch (error, stackTrace) {
      final onError = widget.onError;
      if (onError != null) {
        onError(error, stackTrace);
      } else {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'masi',
            context: ErrorDescription('while running a PendingIconButton action'),
          ),
        );
      }
    } finally {
      _locked = false;
      // The sheet/screen this button lives on can be gone by the time the
      // future settles.
      if (mounted && _working) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled =
        (widget.onPressed ?? widget.onPressedArmed) != null && !_working;
    return IconButton(
      key: widget.buttonKey,
      tooltip: widget.tooltip,
      visualDensity: widget.visualDensity,
      onPressed: enabled ? _handleTap : null,
      icon: MasiLoadingIndicator.inline(
        isLoading: _working,
        color: widget.spinnerColor,
        semanticLabel: 'Working',
        child: widget.icon,
      ),
    );
  }
}
