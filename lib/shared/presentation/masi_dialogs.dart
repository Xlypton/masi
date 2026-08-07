/// The app's four modal surfaces, in one place.
///
/// DESIGN.md's platform stance is explicit — "iOS-first / Cupertino-flavored
/// … Keep it consistent — do not mix stock Material dialogs with Cupertino
/// sheets" — but before this file existed the codebase mixed FOUR idioms for
/// what is really only two jobs (pick an action / answer a question):
/// `CupertinoActionSheet` (5 sites), Material `showModalBottomSheet` +
/// `ListTile` (the photo-strip manage menu), Material `AlertDialog` (5 sites)
/// and `CupertinoAlertDialog` (the logbook delete confirm). A user deleting a
/// topo, a photo and an ascent — three instances of the same decision — got
/// three different-looking modals.
///
/// The rule this file encodes:
///
///  - **Choosing an action** → [showMasiActionSheet]. Thumb-reachable, which
///    matters for a one-handed app used at a crag.
///  - **Confirming a destructive action** → [showMasiConfirm] (an action
///    sheet with one destructive action). NOT a centered dialog: a Material
///    `AlertDialog` puts "Delete" in the top-right corner, the single worst
///    spot to reach and an easy mis-tap next to a barrier tap.
///  - **Typing a short value** → [showMasiTextPrompt]. Centered, because it
///    is keyboard-driven and must not sit under the keyboard.
///  - **Acknowledging a message** → [showMasiAlert].
///
/// Form-sized modals (filters, the move picker, route metadata, log ascent)
/// deliberately stay Material `showModalBottomSheet`s — they are scrollable
/// forms, not action lists, and `theme.dart`'s `bottomSheetTheme` is what
/// keeps those on-brand.
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// A single row in a [showMasiActionSheet], carrying the [value] that the
/// sheet resolves to when tapped.
///
/// [enabled] is `false` for an action that must stay VISIBLE but inert (the
/// topo menu's "Show on map" with no coordinates, which explains itself via
/// [subtitle] rather than vanishing and leaving the user wondering where it
/// went). `CupertinoActionSheetAction.onPressed` is non-nullable and the
/// widget has no built-in disabled state, so this is recreated with a muted
/// label plus a no-op tap — the same trick the old `PopupMenuItem`'s
/// `enabled: false` performed.
class MasiSheetAction<T> {
  const MasiSheetAction({
    required this.label,
    required this.value,
    this.key,
    this.isDestructive = false,
    this.enabled = true,
    this.subtitle,
  });

  final String label;

  /// What [showMasiActionSheet] returns when this row is tapped.
  final T value;

  final Key? key;

  /// Renders the label in `MasiColors.gradeHard`, per DESIGN.md's Buttons
  /// spec for destructive actions.
  final bool isDestructive;

  final bool enabled;

  /// Optional second line, used to explain why a disabled action is inert.
  final String? subtitle;
}

/// The barrier tint for every popup surface here.
///
/// Cupertino's default `kCupertinoModalBarrierColor` is only ~20% black in
/// light mode, which is too weak to obscure what sits behind the sheet: an
/// action sheet renders its action group and its Cancel button as two
/// separate rounded groups with a TRANSPARENT gap between them, and a
/// bottom-pinned accent-filled button (the library screens' "New …") bleeds
/// straight through that gap. A materially darker barrier hides it.
const Color _barrierColor = Colors.black45;

/// Presents the app's standard iOS action sheet and resolves to the tapped
/// action's value, or `null` if the user cancels or dismisses it.
///
/// Deliberately has no icon slot: iOS action sheets are text-only, and the
/// one menu that used icons (the photo strip's) was the same menu that was
/// off-idiom in every other respect too.
Future<T?> showMasiActionSheet<T>(
  BuildContext context, {
  required List<MasiSheetAction<T>> actions,
  String? title,
  String? message,
  String cancelLabel = 'Cancel',
  Key? cancelKey,
  Key? sheetKey,
}) {
  final colors = MasiColors.of(context);
  final textTheme = Theme.of(context).textTheme;

  return showCupertinoModalPopup<T>(
    context: context,
    barrierColor: _barrierColor,
    builder: (sheetContext) => CupertinoActionSheet(
      key: sheetKey,
      title: title == null ? null : Text(title),
      message: message == null ? null : Text(message),
      actions: [
        for (final action in actions)
          CupertinoActionSheetAction(
            key: action.key,
            isDestructiveAction: action.isDestructive,
            // A disabled action still needs a tap target that does nothing —
            // see [MasiSheetAction.enabled].
            onPressed: action.enabled
                ? () => Navigator.of(sheetContext).pop(action.value)
                : () {},
            child: action.subtitle == null
                ? Text(
                    action.label,
                    style: _actionLabelStyle(action, colors),
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        action.label,
                        style: _actionLabelStyle(action, colors),
                      ),
                      Text(
                        action.subtitle!,
                        style: textTheme.labelSmall?.copyWith(
                          color: colors.ink3,
                        ),
                      ),
                    ],
                  ),
          ),
      ],
      cancelButton: CupertinoActionSheetAction(
        key: cancelKey,
        onPressed: () => Navigator.of(sheetContext).pop(),
        child: Text(cancelLabel),
      ),
    ),
  );
}

/// Destructive actions are tinted explicitly rather than left to
/// `isDestructiveAction`'s stock Cupertino red, so they land on the app's own
/// `gradeHard` (#D6483B); a disabled action mutes to `ink3`.
TextStyle? _actionLabelStyle(MasiSheetAction<Object?> action, MasiColors colors) {
  if (!action.enabled) return TextStyle(color: colors.ink3);
  if (action.isDestructive) return TextStyle(color: colors.gradeHard);
  return null;
}

/// Asks the user to confirm a single (by default destructive) action, and
/// resolves to `true` ONLY on an explicit confirm tap.
///
/// Cancelling, tapping the barrier and the back gesture all resolve to
/// `false` rather than `null`, so callers can write `if (await …)` without
/// having to remember that a dismissed sheet is not a confirmation.
Future<bool> showMasiConfirm(
  BuildContext context, {
  required String title,
  required String confirmLabel,
  String? message,
  Key? confirmKey,
  Key? cancelKey,
  Key? sheetKey,
  bool isDestructive = true,
}) async {
  final confirmed = await showMasiActionSheet<bool>(
    context,
    title: title,
    message: message,
    cancelKey: cancelKey,
    sheetKey: sheetKey,
    actions: [
      MasiSheetAction(
        key: confirmKey,
        label: confirmLabel,
        value: true,
        isDestructive: isDestructive,
      ),
    ],
  );
  return confirmed ?? false;
}

/// Prompts for a short single-line value (a name), resolving to the trimmed
/// text on submit or `null` on cancel/dismiss.
///
/// Submit is disabled while the field is empty or whitespace-only, and the
/// keyboard's own return key submits too. Every caller previously reproduced
/// that controller + `_canSubmit` + `onSubmitted` dance by hand — there were
/// three near-identical private copies of this widget.
Future<String?> showMasiTextPrompt(
  BuildContext context, {
  required String title,
  required String submitLabel,
  String initialValue = '',
  String placeholder = 'Name',
  Key? fieldKey,
  Key? submitKey,
  Key? dialogKey,
  bool allowEmpty = false,
}) {
  return showCupertinoDialog<String>(
    context: context,
    barrierDismissible: true,
    builder: (dialogContext) => _MasiTextPromptDialog(
      key: dialogKey,
      title: title,
      submitLabel: submitLabel,
      initialValue: initialValue,
      placeholder: placeholder,
      fieldKey: fieldKey,
      submitKey: submitKey,
      allowEmpty: allowEmpty,
    ),
  );
}

/// Shows a message with a single acknowledging button.
Future<void> showMasiAlert(
  BuildContext context, {
  required String title,
  String? message,
  String buttonLabel = 'OK',
  Key? dialogKey,
  Key? buttonKey,
}) {
  return showCupertinoDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (dialogContext) => CupertinoAlertDialog(
      key: dialogKey,
      title: Text(title),
      content: message == null
          ? null
          : Padding(
              padding: const EdgeInsets.only(top: MasiSpacing.sm),
              child: Text(message),
            ),
      actions: [
        CupertinoDialogAction(
          key: buttonKey,
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(buttonLabel),
        ),
      ],
    ),
  );
}

class _MasiTextPromptDialog extends StatefulWidget {
  const _MasiTextPromptDialog({
    super.key,
    required this.title,
    required this.submitLabel,
    required this.initialValue,
    required this.placeholder,
    this.fieldKey,
    this.submitKey,
    this.allowEmpty = false,
  });

  final String title;
  final String submitLabel;
  final String initialValue;
  final String placeholder;
  final Key? fieldKey;
  final Key? submitKey;

  /// Whether submitting with nothing typed is allowed, resolving to `''`.
  ///
  /// Off by default, and that is right for every naming prompt in the app: a
  /// wall called "" is not a thing anyone meant. It is ON for the two prompts
  /// whose text is genuinely optional — the note on a report and on a
  /// suggestion — where the caller's own doc says so and the disabled button
  /// was quietly contradicting it, forcing people to type a word to file a
  /// complaint that a picked category already described.
  final bool allowEmpty;

  @override
  State<_MasiTextPromptDialog> createState() => _MasiTextPromptDialogState();
}

class _MasiTextPromptDialogState extends State<_MasiTextPromptDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialValue,
  );
  late bool _canSubmit =
      widget.allowEmpty || _controller.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
  }

  void _onChanged() {
    final canSubmit =
        widget.allowEmpty || _controller.text.trim().isNotEmpty;
    if (canSubmit != _canSubmit) setState(() => _canSubmit = canSubmit);
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    super.dispose();
  }

  /// Unfocuses BEFORE popping, on every exit path: popping the route while
  /// the field still holds focus strands the keyboard on screen (#20a).
  void _close(String? result) {
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).pop(result);
  }

  void _submit() {
    final name = _controller.text.trim();
    if (name.isEmpty && !widget.allowEmpty) return;
    _close(name);
  }

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    return CupertinoAlertDialog(
      title: Text(widget.title),
      // `CupertinoTextField` carries none of the ambient Material
      // `InputDecorationTheme`, so the MASI control tokens are applied here
      // directly rather than inherited.
      content: Padding(
        padding: const EdgeInsets.only(top: MasiSpacing.md),
        child: CupertinoTextField(
          key: widget.fieldKey,
          controller: _controller,
          autofocus: true,
          placeholder: widget.placeholder,
          placeholderStyle: TextStyle(color: colors.ink3),
          style: TextStyle(color: colors.ink),
          cursorColor: colors.accent,
          padding: const EdgeInsets.symmetric(
            horizontal: MasiSpacing.md,
            vertical: MasiSpacing.sm + 2,
          ),
          decoration: BoxDecoration(
            color: colors.surface2,
            border: Border.all(color: colors.separator),
            borderRadius: BorderRadius.circular(MasiRadii.control),
          ),
          onSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        CupertinoDialogAction(
          onPressed: () => _close(null),
          child: const Text('Cancel'),
        ),
        CupertinoDialogAction(
          key: widget.submitKey,
          onPressed: _canSubmit ? _submit : null,
          child: Text(widget.submitLabel),
        ),
      ],
    );
  }
}
