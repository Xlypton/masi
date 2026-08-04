import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../../../shared/presentation/masi_loading_indicator.dart';

/// An [IconButton] whose action is a [Future] — the icon-shaped sibling of
/// `MasiPendingButton`.
///
/// That widget is the app's answer to "a button whose `onPressed` awaits", but
/// it only comes in filled/text chrome: wearing it would turn this feature's
/// 48 px round glyph controls (post-a-comment, the map's refresh/find-me) into
/// labelled buttons. This keeps the glyph and copies the three guarantees that
/// actually matter, for the same reasons — see `MasiPendingButton`'s doc:
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
class PendingIconButton extends StatefulWidget {
  const PendingIconButton({
    super.key,
    this.buttonKey,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.onError,
    this.spinnerColor,
    this.visualDensity,
  });

  /// Key for the inner [IconButton] — see the class doc. Omit it where the
  /// tappable surface is already keyed by an ancestor (the map's controls key
  /// their wrapping [Material]).
  final Key? buttonKey;

  /// The glyph. Kept as-is while idle; swapped for the 20 px cue while the
  /// spinner is revealed.
  final Widget icon;

  final String tooltip;

  /// The action. `null` disables the button, same contract as [IconButton].
  final Future<void> Function()? onPressed;

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
  /// True from the synchronous instant of the tap until the future settles —
  /// this, never the indicator's visual gate, is what makes the control
  /// single-shot (during the reveal delay it looks idle but is not).
  bool _inFlight = false;

  Future<void> _handleTap() async {
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
      // The sheet/screen this button lives on can be gone by the time the
      // future settles.
      if (mounted) setState(() => _inFlight = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null && !_inFlight;
    return IconButton(
      key: widget.buttonKey,
      tooltip: widget.tooltip,
      visualDensity: widget.visualDensity,
      onPressed: enabled ? _handleTap : null,
      icon: MasiLoadingIndicator.inline(
        isLoading: _inFlight,
        color: widget.spinnerColor,
        semanticLabel: 'Working',
        child: widget.icon,
      ),
    );
  }
}

