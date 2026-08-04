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

/// How an action tells its button that the wait has become the APP's — as
/// opposed to the USER's, which is what it is for as long as a dialog, sheet or
/// OS picker that action opened is still on screen.
///
/// This is the seam that lets the `ask the user → then write` family use
/// [MasiPendingButton] and `PendingIconButton` at all. Their default pending
/// state necessarily spans the WHOLE future, so an action shaped like that
/// spins a cue on the one control still visible under the modal's barrier for
/// however long the user takes to type or browse, and only incidentally covers
/// the 30 ms write that is the actual wait. [MasiLoadingGate]'s anti-flash
/// cannot rescue it: that debounces waits which turn out to be short, and
/// "however long somebody reads a confirm sheet" is not short. (It also hangs
/// `pumpAndSettle()` in every test that opens the modal, since a revealed
/// spinner never settles — measured, not predicted.)
///
/// So the flow reports its own boundaries instead, via
/// [MasiPendingButton.onPressedArmed] / `PendingIconButton.onPressedArmed`:
///
/// ```dart
/// MasiPendingButton.filled(
///   onPressedArmed: (reportBusy) async {
///     final name = await showNameDialog(context);   // the user's turn
///     if (name == null) return;
///     reportBusy(true);                             // ours from here
///     await repo.createArea(name);
///   },
///   child: const Text('New area'),
/// )
/// ```
///
/// Reporting `false` again is only needed to hand a flow BACK to the user (a
/// move action that must read its candidate destinations from the database
/// before it can open its picker does exactly that); the button always clears
/// the cue itself when the action returns.
///
/// Note what does NOT change in armed mode: the tap is still single-shot from
/// the synchronous instant of the press, modal and all. Only the visible cue
/// waits to be armed.
typedef MasiBusyReporter = void Function(bool isBusy);

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
/// ## Modal-first actions
///
/// If the action opens a dialog, sheet or OS picker BEFORE it writes, use
/// [onPressedArmed] instead of [onPressed] — see [MasiBusyReporter] for why a
/// whole-future cue is wrong (and untestable) for that shape.
///
/// **Testing.** While pending, the button contains a live spinner, so
/// `pumpAndSettle()` hangs — pump explicit durations. The pending spinner is
/// [MasiLoadingIndicator.spinnerKey]; to prove taps are swallowed, complete
/// the future from a [Completer] you control and count invocations.
///
/// The widget's own `key` lands on the OUTERMOST widget it builds, which is a
/// [MasiLoadingGate] (or, with [expand], the [SizedBox] around it) — NOT the
/// Material button. `tester.tap(find.byKey(k))` works; a
/// `tester.widget<ElevatedButton>(find.byKey(k))` introspection throws a cast
/// error. Pass [buttonKey] when a test needs to read the button's resolved
/// `onPressed`/`ButtonStyle`.
class MasiPendingButton extends StatefulWidget {
  const MasiPendingButton.filled({
    super.key,
    this.buttonKey,
    this.onPressed,
    this.onPressedArmed,
    required this.child,
    this.style,
    this.expand = false,
    this.onError,
    this.spinnerColor,
    this.revealDelay = MasiMotion.loadingRevealDelay,
    this.minVisible = MasiMotion.loadingMinVisible,
  }) : variant = MasiPendingButtonVariant.filled,
       assert(
         onPressed == null || onPressedArmed == null,
         'Supply either onPressed or onPressedArmed, not both.',
       );

  const MasiPendingButton.text({
    super.key,
    this.buttonKey,
    this.onPressed,
    this.onPressedArmed,
    required this.child,
    this.style,
    this.expand = false,
    this.onError,
    this.spinnerColor,
    this.revealDelay = MasiMotion.loadingRevealDelay,
    this.minVisible = MasiMotion.loadingMinVisible,
  }) : variant = MasiPendingButtonVariant.text,
       assert(
         onPressed == null || onPressedArmed == null,
         'Supply either onPressed or onPressedArmed, not both.',
       );

  /// Key for the Material button this builds ([ElevatedButton] or
  /// [TextButton]) rather than for the wrapper — see the class doc's last
  /// paragraph. Use it wherever a test reads the button off the key instead of
  /// just tapping it.
  final Key? buttonKey;

  /// The action. `null` disables the button (same contract as any Material
  /// button) unless [onPressedArmed] is supplied instead. A non-`Future`
  /// callback does not belong here — use a plain button; there is nothing to be
  /// pending about.
  final Future<void> Function()? onPressed;

  /// The action, for the `ask the user → then write` shape: the pending cue
  /// stays OFF until the action calls the [MasiBusyReporter] it is handed. See
  /// that typedef — it is the whole reason this parameter exists.
  ///
  /// Mutually exclusive with [onPressed] (asserted). `null` in both disables
  /// the button.
  final Future<void> Function(MasiBusyReporter reportBusy)? onPressedArmed;

  /// The label. Kept laid out while pending — see "Stable size".
  final Widget child;

  /// Chrome.
  final MasiPendingButtonVariant variant;

  /// Optional overrides merged over the variant's own style.
  final ButtonStyle? style;

  /// Stretch to the available width (`width: double.infinity`), which is how
  /// the app's bottom-pinned primary actions are laid out.
  final bool expand;

  /// Called if the action's future fails. Without it the error goes to
  /// [FlutterError.reportError] — visible, never silent.
  final void Function(Object error, StackTrace stackTrace)? onError;

  /// Overrides the pending spinner's colour.
  ///
  /// Rarely needed: the default is the button's own RESOLVED foreground colour
  /// (see [_spinnerColor]), so a `style:` that repaints the button also repaints
  /// its cue without anyone having to think about it.
  final Color? spinnerColor;

  /// See [MasiLoadingGate.revealDelay]. Affects only when the SPINNER appears;
  /// the disable and the tap-swallow are always immediate.
  final Duration revealDelay;

  /// See [MasiLoadingGate.minVisible].
  final Duration minVisible;

  @override
  State<MasiPendingButton> createState() => _MasiPendingButtonState();
}

class _MasiPendingButtonState extends State<MasiPendingButton> {
  /// True from the synchronous instant of the tap until the action's future
  /// settles — modal and all. This — not the gate's `showLoading`, and not
  /// [_working] — is what makes the button single-shot.
  bool _locked = false;

  /// Whether the APP's own work is in flight right now: the visible half. With
  /// [MasiPendingButton.onPressed] it tracks [_locked] exactly; with
  /// [MasiPendingButton.onPressedArmed] it is false until the action reports
  /// busy (see [MasiBusyReporter]).
  bool _working = false;

  /// The reporter handed to an armed action. Tolerates being called late: the
  /// row/sheet a write belongs to is routinely gone before that write settles.
  void _report(bool isBusy) {
    if (!mounted) return;
    if (isBusy != _working) setState(() => _working = isBusy);
  }

  Future<void> _handleTap() async {
    // The double-tap swallow. Two taps in the same frame both reach here; the
    // second sees `_locked` already true and returns.
    if (_locked) return;
    final action = widget.onPressed;
    final armed = widget.onPressedArmed;
    if (action == null && armed == null) return;

    _locked = true;
    // The plain shape's wait IS the app's, start to finish, so it arms itself.
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
      _locked = false;
      // The whole reason this is a StatefulWidget with a mounted check: the
      // sheet/dialog this button lives in is very often popped by the action
      // itself, so by the time the future settles this State can be gone.
      if (mounted && _working) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final enabled =
        (widget.onPressed ?? widget.onPressedArmed) != null && !_working;
    final style = _withOverrides(
      switch (widget.variant) {
        MasiPendingButtonVariant.filled => _filledStyle(
          colors,
          pending: _working,
        ),
        MasiPendingButtonVariant.text => _textStyle(colors),
      },
    );
    final spinnerColor = _spinnerColor(style, colors);

    final button = MasiLoadingGate(
      isLoading: _working,
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
                color: spinnerColor,
                semanticLabel: 'Working',
              ),
          ],
        );

        return switch (widget.variant) {
          MasiPendingButtonVariant.filled => ElevatedButton(
            key: widget.buttonKey,
            onPressed: enabled ? _handleTap : null,
            style: style,
            child: label,
          ),
          MasiPendingButtonVariant.text => TextButton(
            key: widget.buttonKey,
            onPressed: enabled ? _handleTap : null,
            style: style,
            child: label,
          ),
        };
      },
    );

    return widget.expand
        ? SizedBox(width: double.infinity, child: button)
        : button;
  }

  /// Lets [MasiPendingButton.style] win over the variant's own recipe.
  ///
  /// The argument order matters and is easy to get backwards: `a.merge(b)`
  /// keeps `a`'s non-null fields and only lets `b` fill in `a`'s nulls. So the
  /// CALLER's style has to be the receiver, or passing `style:` would silently
  /// do nothing wherever the variant already sets that field.
  ButtonStyle _withOverrides(ButtonStyle base) =>
      widget.style?.merge(base) ?? base;

  /// The pending cue's colour, derived from the button's RESOLVED foreground
  /// rather than from its variant.
  ///
  /// Hardcoding it per variant (`onAccent` for filled, `accent` for text) is
  /// what made this widget unusable for any surface-filled button: a `style:`
  /// with `backgroundColor: colors.surface` painted `onAccent` on it, i.e.
  /// white on `#FBFAFE` in light and `#1A1226` on `#251F34` in dark — an
  /// invisible spinner. `account_screen.dart` worked around it by wearing
  /// `.text` and repainting the fill, giving up M3's elevation to do it.
  ///
  /// Resolved for the ENABLED state (`const {}`) deliberately, not for the
  /// disabled one the button is actually in while pending: the two variants set
  /// `disabledForegroundColor` to a muted grey (`ink3`) precisely because a
  /// caller-disabled button should look dead, and the cue must not. This keeps
  /// both variants' pre-existing colours exactly (`onAccent` / `accent`) while
  /// following any `style:` that repaints the label.
  Color _spinnerColor(ButtonStyle style, MasiColors colors) =>
      widget.spinnerColor ??
      style.foregroundColor?.resolve(const <WidgetState>{}) ??
      switch (widget.variant) {
        MasiPendingButtonVariant.filled => colors.onAccent,
        MasiPendingButtonVariant.text => colors.accent,
      };

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
