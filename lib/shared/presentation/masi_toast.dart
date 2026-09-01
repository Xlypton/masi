import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../features/topo/presentation/canvas_chrome.dart'
    show kMasiAmbientShadow;
import 'masi_icon.dart';

/// What a toast is *about* — the one thing a call site has to decide.
///
/// Before this existed, all ~95 of the app's transient messages were
/// unstyled Material `SnackBar`s: the same flat dark bar for "Cover photo
/// updated" and for "Couldn't save your like". The words carried the entire
/// distinction, which means a user glancing at a bar mid-climb learned
/// nothing from its appearance and had to read it to find out whether
/// anything had gone wrong.
///
/// The kind decides the glyph and the tint, and nothing else — the card,
/// the type, the radius and the shadow are identical across all four, so a
/// toast still reads as one component rather than four. Colour is used the
/// way DESIGN.md uses it everywhere else: grade-band hues INFORM (this went
/// well / this did not), and `accent` stays reserved for things you can
/// touch, which is why the action button is the only accent-coloured thing
/// in the card.
enum MasiToastKind {
  /// Something the user asked for happened. "Location saved", "Ascent
  /// deleted".
  success,

  /// Something the user asked for did NOT happen, and there is no outbox
  /// behind it (decision D-4) — so the work is lost unless they retry.
  error,

  /// A caution that is not a failure: a partial result, a thing that will
  /// not do what they expect, a limit they just hit.
  warning,

  /// A neutral statement of fact — the default. "Installing…", "Route is
  /// still saving".
  info,
}

/// The glyph for [kind], from `assets/icons/masi/`.
///
/// `check` / `warning` / `info` are the only three glyphs in the set that
/// read as a *status* rather than as a specific noun; [MasiToastKind.error]
/// and [MasiToastKind.warning] deliberately share `warning` and are told
/// apart by tint, because there is no distinct error glyph drawn and
/// inventing one would mean shipping an asset the designer has not made.
String masiToastGlyph(MasiToastKind kind) => switch (kind) {
  MasiToastKind.success => 'check',
  MasiToastKind.error => 'warning',
  MasiToastKind.warning => 'warning',
  MasiToastKind.info => 'info',
};

/// The tint for [kind] — the glyph's colour and, at low opacity, its chip.
///
/// Grade-band tokens rather than new colours: the app already teaches
/// `gradeBeginner` green as "good" and `gradeHard` red as "hard/bad" on
/// every route pill, so a toast borrowing them is legible on first sight
/// and adds nothing to the palette. `info` uses [MasiColors.ink2] and not
/// [MasiColors.accent] — an informational toast is not an action, and
/// DESIGN.md principle 3 spends the accent on intent alone.
Color masiToastTint(MasiToastKind kind, MasiColors colors) => switch (kind) {
  MasiToastKind.success => colors.gradeBeginner,
  MasiToastKind.error => colors.gradeHard,
  MasiToastKind.warning => colors.gradeAdvanced,
  MasiToastKind.info => colors.ink2,
};

/// How long a toast of [kind] stays up.
///
/// An error gets longer than an acknowledgement because it is the only kind
/// that asks something of the reader: a failure they miss is work they will
/// believe was saved. A success is a receipt for something they just did
/// and already expect, so it can leave quickly.
Duration masiToastDuration(MasiToastKind kind) => switch (kind) {
  MasiToastKind.error => const Duration(seconds: 6),
  MasiToastKind.warning => const Duration(seconds: 5),
  _ => const Duration(seconds: 4),
};

/// Builds the app's one transient-message surface, as a [SnackBar] the
/// caller shows through an ordinary [ScaffoldMessenger].
///
/// **Why still a `SnackBar`.** The card below could have been an overlay
/// entry of its own, and that was rejected: `ScaffoldMessenger` already
/// solves queuing (two failures in a row show one after the other rather
/// than on top of each other), swipe-to-dismiss, route changes, and the
/// global safe-area fix in `MasiTheme.withSnackBarSafeArea` that keeps every
/// toast clear of the iOS home indicator. Re-implementing those to get a
/// nicer-looking box would trade a large amount of correct behaviour for
/// paint.
///
/// So the `SnackBar` is kept purely as the TRANSPORT and stripped of its own
/// appearance — transparent, elevation 0, zero padding — and everything
/// visible is [MasiToastCard], which is a normal MASI surface: `surface`
/// fill, `MasiRadii.card`, a hairline `separator` border and the shared
/// [kMasiAmbientShadow] the account cards and the install banner already
/// float on. That is what makes a toast look like it belongs to this app
/// rather than to Material.
///
/// [key] is forwarded to the `SnackBar` (several tests find toasts by key).
SnackBar masiToast(
  String message, {
  MasiToastKind kind = MasiToastKind.info,
  String? actionLabel,
  VoidCallback? onAction,
  Duration? duration,
  Key? key,
}) {
  return SnackBar(
    key: key,
    content: MasiToastCard(
      message: message,
      kind: kind,
      actionLabel: actionLabel,
      onAction: onAction,
    ),
    // The transport is invisible; see this function's doc.
    backgroundColor: Colors.transparent,
    elevation: 0,
    padding: EdgeInsets.zero,
    // Set explicitly rather than left to the theme: `MasiTheme` supplies
    // `floating` app-wide, but a toast shown under a bare `ThemeData` (a
    // widget test, a preview harness) would otherwise fall back to `fixed`
    // and render this rounded, shadowed card flush into the screen's bottom
    // corners, which looks like a bug rather than a fallback.
    behavior: SnackBarBehavior.floating,
    dismissDirection: DismissDirection.horizontal,
    duration: duration ?? masiToastDuration(kind),
  );
}

/// The visible half of [masiToast] — a MASI card carrying a status chip, the
/// message, and at most one action.
///
/// Public and separately constructible so it can be laid out in a golden or
/// a design harness without a `ScaffoldMessenger`; nothing in the app builds
/// one directly.
class MasiToastCard extends StatelessWidget {
  const MasiToastCard({
    super.key,
    required this.message,
    this.kind = MasiToastKind.info,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final MasiToastKind kind;

  /// The action's label, or null for a message with nothing to do about it.
  /// An action is only rendered when BOTH this and [onAction] are given —
  /// half a button is a button that does nothing.
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.resolve(context);
    final textTheme = Theme.of(context).textTheme;
    final tint = masiToastTint(kind, colors);
    final label = actionLabel;
    final action = onAction;

    return Semantics(
      // A transient message that never reaches a screen reader is a message
      // that was not delivered to everybody.
      liveRegion: true,
      container: true,
      child: Container(
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(MasiRadii.card),
          border: Border.all(color: colors.separator),
          boxShadow: kMasiAmbientShadow,
        ),
        padding: const EdgeInsets.fromLTRB(
          MasiSpacing.md,
          MasiSpacing.sm + 2,
          MasiSpacing.sm,
          MasiSpacing.sm + 2,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _KindChip(kind: kind, tint: tint),
            const SizedBox(width: MasiSpacing.md),
            Expanded(
              child: Text(
                message,
                style: textTheme.bodySmall?.copyWith(color: colors.ink),
                // Three lines, then ellipsis: long error text (several
                // messages interpolate an exception) must not grow a toast
                // into a wall that covers the thing it is reporting on.
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (label != null && action != null) ...[
              const SizedBox(width: MasiSpacing.sm),
              _ToastAction(label: label, onPressed: action, colors: colors),
            ] else
              const SizedBox(width: MasiSpacing.xs),
          ],
        ),
      ),
    );
  }
}

/// The leading status square: the kind's glyph on a faint wash of its own
/// tint.
///
/// A rounded square at `MasiRadii.control` rather than a circle, matching
/// the photo thumbnails and grade pills the rest of the app is built from —
/// a lone circle in a card of rounded rectangles reads as imported from
/// somewhere else.
class _KindChip extends StatelessWidget {
  const _KindChip({required this.kind, required this.tint});

  final MasiToastKind kind;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        // ~14% — enough to read as a tinted chip against both `surface`
        // values, faint enough that the glyph stays the loud part.
        color: tint.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(MasiRadii.control),
      ),
      child: Center(
        child: MasiIcon(masiToastGlyph(kind), size: 16, color: tint),
      ),
    );
  }
}

/// The one touchable thing in a toast, so it is the one accent-coloured
/// thing in a toast (DESIGN.md principle 3).
///
/// Dismisses the toast before running [onPressed]: every action in this app
/// either navigates or retries, and both leave a stale message sitting over
/// the result.
class _ToastAction extends StatelessWidget {
  const _ToastAction({
    required this.label,
    required this.onPressed,
    required this.colors,
  });

  final String label;
  final VoidCallback onPressed;
  final MasiColors colors;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      style: TextButton.styleFrom(
        foregroundColor: colors.accent,
        padding: const EdgeInsets.symmetric(horizontal: MasiSpacing.md),
        minimumSize: const Size(0, 36),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(MasiRadii.control),
        ),
        textStyle: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
      ),
      onPressed: () {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        onPressed();
      },
      child: Text(label),
    );
  }
}

/// Shows a [masiToast] — the call site's whole API.
///
/// An extension on [ScaffoldMessengerState] rather than a
/// `BuildContext`-taking free function because roughly a third of this app's
/// message sites capture `ScaffoldMessenger.of(context)` BEFORE an `await`
/// and show it after (the context is often gone by then — a deleted topo's
/// screen has popped). Those sites hold a `ScaffoldMessengerState?` and
/// call it with `?.`, which only works if the method hangs off the state.
extension MasiMessenger on ScaffoldMessengerState {
  /// Neutral by default: a call site that has not thought about the kind
  /// gets the same plain statement of fact the old unstyled bar gave it.
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showMasiToast(
    String message, {
    MasiToastKind kind = MasiToastKind.info,
    String? actionLabel,
    VoidCallback? onAction,
    Duration? duration,
    Key? key,
  }) {
    return showSnackBar(
      masiToast(
        message,
        kind: kind,
        actionLabel: actionLabel,
        onAction: onAction,
        duration: duration,
        key: key,
      ),
    );
  }

  /// "It worked."
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showMasiSuccess(
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
    Key? key,
  }) => showMasiToast(
    message,
    kind: MasiToastKind.success,
    actionLabel: actionLabel,
    onAction: onAction,
    key: key,
  );

  /// "It did not work, and nothing is retrying it for you."
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showMasiError(
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
    Key? key,
  }) => showMasiToast(
    message,
    kind: MasiToastKind.error,
    actionLabel: actionLabel,
    onAction: onAction,
    key: key,
  );

  /// "Careful" — not a failure, but not what you probably wanted either.
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showMasiWarning(
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
    Key? key,
  }) => showMasiToast(
    message,
    kind: MasiToastKind.warning,
    actionLabel: actionLabel,
    onAction: onAction,
    key: key,
  );
}
