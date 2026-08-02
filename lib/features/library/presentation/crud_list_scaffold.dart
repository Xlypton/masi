import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../shared/presentation/masi_icon.dart';

/// Generic AppBar + body scaffold for a "list of named entities" CRUD screen
/// (Areas / Sectors / Walls), driven by an [AsyncValue] the caller already
/// obtained from `ref.watch(...)`.
///
/// This widget is intentionally NOT a [ConsumerWidget]: it knows nothing
/// about Riverpod's `ref`. The three screens (AreasScreen / SectorsScreen /
/// WallsScreen) each watch their own scoped provider and pass the resulting
/// [AsyncValue] plus a handful of callbacks (create/rename/delete/retry/tap)
/// in, which keeps this widget trivially testable and reusable. (The
/// [AsyncValue] *type* itself comes from Riverpod, same as before this
/// restyle — only `ref`/`ConsumerWidget` are off-limits here.)
///
/// Visually this mirrors `topos_screen.dart`'s "Topos home" patterns (large
/// title nav, grouped-inset card rows, bottom-pinned filled create button,
/// iOS-style confirm surfaces) rather than plain Material widgets, per
/// DESIGN.md.
///
/// Widget keys, so screens stay tappable in widget tests:
///  - `<entityKey>-add-fab`: the bottom-pinned "create" button (a full-width
///    filled button now, not a literal `FloatingActionButton` — key name
///    kept verbatim for test stability).
///  - `<entityKey>-item-<id>`: each row's card ([Material]).
///  - `<entityKey>-rename-<id>`: the rename icon button on a row; opens the
///    shared name-entry dialog.
///  - `<entityKey>-move-<id>`: OPTIONAL move icon button on a row, rendered
///    only when [onMove] is supplied (currently wired only in
///    `sectors_screen.dart` — Areas are top-level and a Walls-list move is
///    out of scope). Tapping it calls [onMove] with the row's own
///    [BuildContext] and item; the caller (not this generic scaffold) owns
///    picking a destination and invoking the actual move.
///  - `<entityKey>-delete-<id>`: the delete icon button on a row; tapping it
///    opens an iOS-style [CupertinoActionSheet] confirm surface (does NOT
///    delete immediately).
///  - `<entityKey>-delete-confirm-<id>`: the destructive "Delete" action
///    inside that confirm sheet — tapping IT calls [onDelete].
///  - `<entityKey>-retry`: the retry button shown in the error state.
///  - `crud-name-field` / `crud-name-submit`: the text field and submit
///    button inside the shared add/rename name dialog (only one such dialog
///    is ever on screen at a time, so this key is reused across entities).
class CrudListScaffold<T> extends StatelessWidget {
  const CrudListScaffold({
    super.key,
    required this.title,
    required this.entityKey,
    required this.asyncItems,
    required this.idOf,
    required this.nameOf,
    required this.emptyMessage,
    required this.addDialogTitle,
    required this.renameDialogTitle,
    required this.onRetry,
    required this.onTap,
    required this.onCreate,
    required this.onRename,
    required this.onDelete,
    this.subtitleOf,
    this.onMove,
    this.createBlockedReason,
  });

  final String title;
  final String entityKey;
  final AsyncValue<List<T>> asyncItems;
  final String Function(T item) idOf;
  final String Function(T item) nameOf;
  final String? Function(T item)? subtitleOf;
  final String emptyMessage;
  final String addDialogTitle;
  final String renameDialogTitle;
  final VoidCallback onRetry;
  final void Function(T item) onTap;
  final Future<void> Function(String name) onCreate;
  final Future<void> Function(T item, String newName) onRename;
  final Future<void> Function(T item) onDelete;

  /// Optional move trigger — see the `<entityKey>-move-<id>` key doc above.
  /// `null` (the default) omits the move button entirely, which is how
  /// `AreasScreen`/`WallsScreen` keep their existing row layout unchanged.
  final Future<void> Function(BuildContext context, T item)? onMove;

  /// Why creating is unavailable right now, or `null` when it is available.
  ///
  /// Supplied by the caller rather than read from a provider here, because
  /// this widget deliberately knows nothing about `ref` (see the class doc).
  /// The three screens each pass
  /// `storageBlockedNotice(ref.watch(storageDurabilityProvider))`, so the
  /// wording is shared with the topos-home banner and the topo canvas instead
  /// of being invented three times.
  ///
  /// Non-null disables the add button AND renders the sentence directly above
  /// it. Both halves matter: a create button that is merely greyed out, with
  /// nothing saying why, is the "dead tap" failure in a quieter costume.
  final String? createBlockedReason;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;

    // Two independent reasons creating cannot be offered, resolved to one
    // sentence so the button has a single enabled/disabled rule.
    //
    // The error case is the one this widget could always see and never acted
    // on: the add button lives OUTSIDE `asyncItems.when`, so when the list
    // fails to load it renders "Something went wrong" over an empty body with
    // a fully live "New area" button beside it. That button opens a name
    // dialog and writes into the same database that just refused to be read.
    //
    // Order matters: a storage verdict explains the error rather than being
    // explained by it (an unopenable database is WHY the list failed), so it
    // wins when both are present.
    final blockedReason =
        createBlockedReason ??
        (asyncItems.hasError
            ? "This list couldn't be loaded, so nothing new can be added "
                  'until it works. Try Retry above.'
            : null);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          title,
          style: textTheme.displaySmall,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        centerTitle: false,
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: asyncItems.when(
                data: (items) {
                  if (items.isEmpty) {
                    return _EmptyState(message: emptyMessage);
                  }
                  return ListView.separated(
                    padding: const EdgeInsets.symmetric(
                      horizontal: MasiSpacing.lg,
                      vertical: MasiSpacing.md,
                    ),
                    itemCount: items.length,
                    separatorBuilder: (context, index) =>
                        const SizedBox(height: MasiSpacing.sm),
                    itemBuilder: (context, index) =>
                        _buildRow(context, items[index]),
                  );
                },
                loading: () =>
                    const Center(child: CircularProgressIndicator()),
                error: (error, stackTrace) => Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Something went wrong: $error',
                        style: textTheme.bodyMedium?.copyWith(
                          color: colors.ink2,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: MasiSpacing.sm),
                      ElevatedButton(
                        key: Key('$entityKey-retry'),
                        onPressed: onRetry,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                MasiSpacing.lg,
                MasiSpacing.md,
                MasiSpacing.lg,
                MasiSpacing.lg,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // A control that is unavailable without saying why is its
                  // own bug — the same point `topo_canvas_screen.dart`'s
                  // `topo-routes-unavailable` doc makes about the draw
                  // toggle. Rendered above the button, not as a tooltip:
                  // this is a touch UI, and a tooltip nobody can long-press
                  // for is not an explanation.
                  if (blockedReason != null) ...[
                    Text(
                      blockedReason,
                      key: Key('$entityKey-add-blocked-reason'),
                      style: textTheme.bodySmall?.copyWith(color: colors.ink2),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: MasiSpacing.sm),
                  ],
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      key: Key('$entityKey-add-fab'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: colors.accent,
                        foregroundColor: colors.onAccent,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(13),
                        ),
                      ),
                      onPressed: blockedReason == null
                          ? () => _handleCreate(context)
                          : null,
                      child: Text(addDialogTitle),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// A single grouped-inset row card: title/subtitle, rename/delete
  /// triggers, and a trailing chevron — mirrors `topos_screen.dart`'s
  /// `_TopoRow` (`Material` + `InkWell`, same radius, same padding rhythm).
  Widget _buildRow(BuildContext context, T item) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final id = idOf(item);
    final subtitleText = subtitleOf?.call(item);

    return Material(
      key: Key('$entityKey-item-$id'),
      color: colors.surface,
      borderRadius: BorderRadius.circular(MasiRadii.card),
      child: InkWell(
        borderRadius: BorderRadius.circular(MasiRadii.card),
        onTap: () => onTap(item),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: MasiSpacing.md,
            vertical: MasiSpacing.sm,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      nameOf(item),
                      style: textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (subtitleText != null && subtitleText.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitleText,
                        style: textTheme.titleSmall?.copyWith(
                          color: colors.ink2,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              IconButton(
                key: Key('$entityKey-rename-$id'),
                icon: MasiIcon('edit', color: colors.ink2),
                tooltip: 'Rename',
                onPressed: () => _handleRename(context, item),
              ),
              if (onMove != null)
                IconButton(
                  key: Key('$entityKey-move-$id'),
                  icon: MasiIcon('folder_move', color: colors.ink2),
                  tooltip: 'Move',
                  onPressed: () => onMove!(context, item),
                ),
              IconButton(
                key: Key('$entityKey-delete-$id'),
                icon: MasiIcon('delete', color: colors.ink2),
                tooltip: 'Delete',
                onPressed: () => _handleDelete(context, item),
              ),
              MasiIcon('chevron_right', color: colors.ink3),
            ],
          ),
        ),
      ),
    );
  }

  /// Runs [action] and turns a failure into a user-visible [SnackBar] instead
  /// of an unhandled exception escaping a button callback.
  ///
  /// The repository's guarded mutations now VERIFY their affected row count
  /// (see `LibraryWriteLostException`) rather than reporting success on a
  /// 0-row update, so "the write did not land" reaches this widget as a
  /// throw — and the whole point of that fix is that the user hears about it.
  /// Catches [Object], not just that one type: a drift/IO failure is just as
  /// much a lost write from the user's point of view.
  Future<void> _runGuarded(
    BuildContext context,
    String failureMessage,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (e, st) {
      debugPrint('$entityKey write failed: $e\n$st');
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(failureMessage)));
    }
  }

  Future<void> _handleCreate(BuildContext context) async {
    final name = await _showNameDialog(context, title: addDialogTitle);
    if (name == null) return;
    if (!context.mounted) return;
    await _runGuarded(
      context,
      "Couldn't save — please try again",
      () => onCreate(name),
    );
  }

  Future<void> _handleRename(BuildContext context, T item) async {
    final name = await _showNameDialog(
      context,
      title: renameDialogTitle,
      initialValue: nameOf(item),
    );
    if (name == null) return;
    if (!context.mounted) return;
    await _runGuarded(
      context,
      "Couldn't rename — please try again",
      () => onRename(item, name),
    );
  }

  /// iOS-style delete confirmation: a [CupertinoActionSheet] with a single
  /// destructive action (rendered in `MasiColors.gradeHard`, per DESIGN.md's
  /// Buttons spec) and a Cancel button. Selecting "Delete" is the required
  /// separate confirm step — [onDelete] only fires after that tap, never on
  /// the initial `<entityKey>-delete-<id>` tap that opens this sheet.
  Future<void> _handleDelete(BuildContext context, T item) async {
    final id = idOf(item);
    final colors = MasiColors.of(context);
    final confirmed = await showCupertinoModalPopup<bool>(
      context: context,
      // The default `kCupertinoModalBarrierColor` is only ~20% black in
      // light mode, which is too weak to fully obscure whatever is behind
      // the sheet: the action-sheet group and the cancel button render as
      // two separate rounded groups with a transparent gap between them,
      // and the bottom-pinned filled "New X" button (`colors.accent`,
      // built above in `build()`) bleeds through that gap. A materially
      // darker (>=45%) barrier hides it.
      barrierColor: Colors.black45,
      builder: (sheetContext) => CupertinoActionSheet(
        title: Text('Delete "${nameOf(item)}"?'),
        message: const Text('This cannot be undone.'),
        actions: [
          CupertinoActionSheetAction(
            key: Key('$entityKey-delete-confirm-$id'),
            isDestructiveAction: true,
            onPressed: () => Navigator.of(sheetContext).pop(true),
            child: Text(
              'Delete',
              style: TextStyle(color: colors.gradeHard),
            ),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheetContext).pop(false),
          child: const Text('Cancel'),
        ),
      ),
    );
    if (confirmed == true) {
      if (!context.mounted) return;
      await _runGuarded(
        context,
        "Couldn't delete — please try again",
        () => onDelete(item),
      );
    }
  }

  Future<String?> _showNameDialog(
    BuildContext context, {
    required String title,
    String? initialValue,
  }) {
    return showDialog<String>(
      context: context,
      builder: (dialogContext) =>
          _NameDialog(title: title, initialValue: initialValue ?? ''),
    );
  }
}

/// Themed empty state — mirrors `topos_screen.dart`'s `_EmptyState`
/// (centered, `titleMedium` text tinted `colors.ink2`).
class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    return Center(
      child: Text(
        message,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          color: colors.ink2,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }
}

class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.title, required this.initialValue});

  final String title;
  final String initialValue;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  // The controller is owned by this State and disposed in [dispose], which
  // Flutter only calls once this element is actually unmounted (i.e. after
  // the dialog route's exit transition finishes). Disposing it any earlier
  // (e.g. via `showDialog(...).whenComplete(controller.dispose)`, which
  // fires as soon as `Navigator.pop()` runs) races the still-animating
  // dialog, which keeps rendering frames that reference the now-disposed
  // controller and throws "A TextEditingController was used after being
  // disposed" — corrupting the widget tree for the rest of the test run.
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialValue,
  );
  late bool _canSubmit = _controller.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
  }

  void _onChanged() {
    final canSubmit = _controller.text.trim().isNotEmpty;
    if (canSubmit != _canSubmit) {
      setState(() => _canSubmit = canSubmit);
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    // The dialog's chrome (background, corner radius, title/content text
    // style) already comes from `theme.dart`'s `DialogThemeData`
    // (`MasiRadii.large`, `colors.surface`) and the ambient
    // `InputDecorationTheme` (`MasiRadii.control`, `colors.surface2`) — no
    // need to fight those with hardcoded decoration here. Only the actions
    // get an explicit MASI tint, since bare `TextButton`s would otherwise
    // just take Material's default styling.
    return AlertDialog(
      title: Text(widget.title, style: textTheme.titleLarge),
      content: TextField(
        key: const Key('crud-name-field'),
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'Name'),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(foregroundColor: colors.accent),
          onPressed: () {
            FocusManager.instance.primaryFocus?.unfocus();
            Navigator.of(context).pop();
          },
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const Key('crud-name-submit'),
          style: TextButton.styleFrom(
            foregroundColor: colors.accent,
            disabledForegroundColor: colors.ink3,
          ),
          onPressed: _canSubmit ? _submit : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
