import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../app/web_back_button.dart';
import '../../../shared/presentation/bottom_safe_inset.dart';
import '../../../shared/presentation/masi_async_view.dart';
import '../../../shared/presentation/masi_dialogs.dart';
import '../../../shared/presentation/masi_icon.dart';
import '../../../shared/presentation/masi_pending_button.dart';
import '../../../shared/presentation/masi_pending_icon_button.dart';
import '../../../shared/presentation/masi_skeleton.dart';

/// Generic AppBar + body scaffold for a "list of named entities" CRUD screen
/// (Areas / Sectors / Walls), driven by an [AsyncValue] the caller already
/// obtained from `ref.watch(...)`.
///
/// A [ConsumerWidget] only for [masiBottomInset] (the standalone-PWA
/// bottom-safe-area floor on the pinned create button below) — the three
/// screens (AreasScreen / SectorsScreen / WallsScreen) still each watch
/// their own scoped provider and pass the resulting [AsyncValue] plus a
/// handful of callbacks (create/rename/delete/retry/tap) in, which keeps
/// this widget otherwise trivially testable and reusable. (The [AsyncValue]
/// *type* itself comes from Riverpod, same as before this restyle.)
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
///  - the error state's retry button is [MasiAsyncView.retryKey] now, not a
///    per-entity `<entityKey>-retry`: the whole failure state (icon, sentence,
///    retry) comes from [MasiAsyncView], which owns one key for it app-wide.
///  - `crud-name-field` / `crud-name-submit`: the text field and submit
///    button inside the shared add/rename name dialog (only one such dialog
///    is ever on screen at a time, so this key is reused across entities).
class CrudListScaffold<T> extends ConsumerWidget {
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
    this.isWeb,
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
  ///
  /// The third argument is [MasiBusyReporter] — see its doc. A move
  /// implementation has to resolve its candidate destinations from the
  /// database before it can open a sheet, and that read is a wait the user is
  /// sitting through with the row still looking idle, so it is the one action
  /// here that needs to report busy twice: for the read, and again for the
  /// write after a destination is picked.
  final Future<void> Function(
    BuildContext context,
    T item,
    MasiBusyReporter reportBusy,
  )?
  onMove;

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

  /// Forces [webBackLeading]'s web branch in a widget test — see that
  /// function's doc. `null` (the default, used by every real screen) keeps
  /// the real compile-time `kIsWeb`.
  final bool? isWeb;

  /// What the failure state says, per the app's "name what failed, never
  /// print 'Error'" rule. Derived from [entityKey] rather than taken as a
  /// parameter because all three entity keys ("area", "sector", "wall")
  /// pluralize regularly, and one more per-screen string to keep in sync is
  /// one more chance for the three screens to disagree.
  String get _loadFailedMessage => "Couldn't load your ${entityKey}s";

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
                  'until it works. Tap Try again above.'
            : null);

    return Scaffold(
      appBar: AppBar(
        leading: webBackLeading(context, isWeb: isWeb),
        title: Text(
          title,
          style: textTheme.displaySmall,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        centerTitle: false,
      ),
      body: SafeArea(
        // Keyed so tests can target THIS SafeArea unambiguously (the
        // Material/Cupertino widgets underneath add their own).
        key: const Key('crud-scaffold-safe-area'),
        // A standalone iOS PWA reports safe-area-inset-bottom = 0, so this
        // SafeArea's own device read is zero and the pinned "New …" button
        // below would land flush on the home indicator. `minimum` takes
        // `max(deviceInset, floor)` per-edge, so it is a no-op everywhere
        // else (the device inset already wins) and only applies the floor
        // in the one world that needs it.
        minimum: EdgeInsets.only(bottom: standaloneBottomFloorOf(ref)),
        child: Column(
          children: [
            Expanded(
              child: MasiAsyncView<List<T>>(
                value: asyncItems,
                onRetry: onRetry,
                errorMessage: _loadFailedMessage,
                // Opted in for the same reason as the Topos home: these
                // lists come out of the local database, and the raw failure
                // text is the only diagnosis available on a phone (#72).
                showErrorDetail: true,
                // The row shape this list is about to render, so nothing
                // jumps when the data lands. `showSubtitle` tracks the caller
                // rather than being hardcoded: Areas pass a `subtitleOf`
                // (the area description) and so render two text lines,
                // Sectors and Walls pass none and render one.
                skeleton: (context) =>
                    MasiSkeletonList.listRows(showSubtitle: subtitleOf != null),
                // Only ever reached with a real (possibly empty) list now, so
                // "you have nothing yet" can no longer be shown to somebody
                // whose data is merely still on its way.
                data: (context, items) {
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
                  // Before this the dialog closed instantly and the insert ran
                  // with no busy state anywhere, so a slow write looked like a
                  // tap that did nothing — and a second tap ran a second
                  // insert.
                  //
                  // `onPressedArmed`, not `onPressed`: this action is `open a
                  // name dialog → write`, so a whole-future cue would spin on
                  // the one control still visible under the dialog's barrier
                  // for as long as the user types (see [MasiBusyReporter]).
                  // `buttonKey` keeps `<entityKey>-add-fab` resolving to the
                  // ElevatedButton itself for the several tests that read its
                  // `onPressed`/`ButtonStyle` off that key.
                  MasiPendingButton.filled(
                    buttonKey: Key('$entityKey-add-fab'),
                    expand: true,
                    onPressedArmed: blockedReason == null
                        ? (reportBusy) => _handleCreate(context, reportBusy)
                        : null,
                    child: Text(addDialogTitle),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// A single grouped-inset row card — see [_CrudRow], which owns the layout
  /// and the per-row in-flight state.
  ///
  /// Every action closure handed down is already wrapped in [_runGuarded], so
  /// none of them can throw out of an icon-button callback. That was previously
  /// only true of rename/delete: [onMove] ran raw, and `sectors_screen.dart`'s
  /// implementation reads the destination-area list from the database BEFORE
  /// opening its sheet — a read that can fail, and used to fail silently.
  Widget _buildRow(BuildContext context, T item) {
    final id = idOf(item);
    final move = onMove;

    return _CrudRow(
      // Element identity, so a list that reorders/filters cannot carry one
      // row's in-flight state over to a different item. The test-facing
      // `<entityKey>-item-<id>` key stays exactly where it was, on the
      // `Material` inside.
      key: ValueKey(id),
      entityKey: entityKey,
      id: id,
      name: nameOf(item),
      subtitle: subtitleOf?.call(item),
      onTap: () => onTap(item),
      onRename: (rowContext, reportBusy) =>
          _handleRename(rowContext, item, reportBusy),
      onDelete: (rowContext, reportBusy) =>
          _handleDelete(rowContext, item, reportBusy),
      onMove: move == null
          ? null
          : (rowContext, reportBusy) => _runGuarded(
              rowContext,
              "Couldn't move — please try again",
              () => move(rowContext, item, reportBusy),
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

  Future<void> _handleCreate(
    BuildContext context,
    MasiBusyReporter reportBusy,
  ) async {
    final name = await _showNameDialog(context, title: addDialogTitle);
    if (name == null) return;
    if (!context.mounted) return;
    // The dialog is gone; the insert behind it is ours to explain.
    reportBusy(true);
    await _runGuarded(
      context,
      "Couldn't save — please try again",
      () => onCreate(name),
    );
  }

  Future<void> _handleRename(
    BuildContext context,
    T item,
    MasiBusyReporter reportBusy,
  ) async {
    final name = await _showNameDialog(
      context,
      title: renameDialogTitle,
      initialValue: nameOf(item),
    );
    if (name == null) return;
    if (!context.mounted) return;
    // The dialog is gone; from here the user is waiting on us.
    reportBusy(true);
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
  Future<void> _handleDelete(
    BuildContext context,
    T item,
    MasiBusyReporter reportBusy,
  ) async {
    final id = idOf(item);
    final confirmed = await showMasiConfirm(
      context,
      title: 'Delete "${nameOf(item)}"?',
      message: 'This cannot be undone.',
      confirmLabel: 'Delete',
      confirmKey: Key('$entityKey-delete-confirm-$id'),
    );
    if (confirmed) {
      if (!context.mounted) return;
      // The sheet is dismissed; the cascade behind it is ours to explain.
      reportBusy(true);
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
    return showMasiTextPrompt(
      context,
      title: title,
      submitLabel: 'Save',
      initialValue: initialValue ?? '',
      fieldKey: const Key('crud-name-field'),
      submitKey: const Key('crud-name-submit'),
    );
  }
}

/// Which of a row's three writes is in flight. Also supplies the middle
/// segment of each button's existing widget key, so the enum and the keys
/// cannot drift apart.
enum _CrudRowAction {
  rename,
  move,
  delete;

  String get keyPart => name;
}

/// A single grouped-inset row card: title/subtitle, rename/move/delete
/// triggers, and a trailing chevron — mirrors `topos_screen.dart`'s `_TopoRow`
/// (`Material` + `InkWell`, same radius, same padding rhythm).
///
/// Stateful for one reason: in-flight state. Every one of these three actions
/// is a database write behind a dialog or a sheet, and the row had none of it —
/// the confirm sheet dismissed, the write ran unannounced, and nothing stopped
/// a second tap (or a rename tapped on top of a delete) from firing a second,
/// concurrent write at the same row. It is tracked per ROW, not per button,
/// because those three writes race each other, not just themselves.
///
/// Two pieces of state, not one, and the split matters:
/// [_CrudRowState._locked] is the re-entrancy lock and covers the whole flow
/// including the modal the user is still reading; [_CrudRowState._working] is
/// the visible cue and covers only the part the app is doing (see
/// [MasiBusyReporter]).
class _CrudRow extends StatefulWidget {
  const _CrudRow({
    super.key,
    required this.entityKey,
    required this.id,
    required this.name,
    required this.subtitle,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
    required this.onMove,
  });

  final String entityKey;
  final String id;
  final String name;
  final String? subtitle;
  final VoidCallback onTap;

  /// The three actions. Each takes the ROW's own [BuildContext] — the dialogs,
  /// sheets and SnackBars they open belong to this row, not to a context
  /// captured further up — plus the [MasiBusyReporter] it uses to say when the
  /// waiting stops being the user's and starts being ours. Each is already
  /// failure-guarded by [CrudListScaffold._runGuarded], so none of them throws.
  final Future<void> Function(BuildContext context, MasiBusyReporter reportBusy)
  onRename;
  final Future<void> Function(BuildContext context, MasiBusyReporter reportBusy)
  onDelete;
  final Future<void> Function(
    BuildContext context,
    MasiBusyReporter reportBusy,
  )?
  onMove;

  @override
  State<_CrudRow> createState() => _CrudRowState();
}

/// [AutomaticKeepAliveClientMixin] is load-bearing, not an optimisation.
///
/// Both flags live in this State, and the list around it is a lazy
/// [ListView.separated] with no keep-alive of its own: scroll a row past the
/// ~250 px cache extent while its delete cascade is in flight and this State is
/// DISPOSED, so `reportBusy(false)` and `_run`'s `finally` both no-op. Scroll
/// back and the row is rebuilt fresh with both flags clear — an idle-looking
/// glyph over a write that is still running, a navigable row, and a second tap
/// that starts a second concurrent write on the same row. (Measured: the cue was
/// gone on the way back, before this mixin.)
///
/// So the row asks to be kept alive for exactly as long as it is [_locked] —
/// which is precisely "I have work in flight", the condition this mixin exists
/// for. Every write of [_locked] therefore goes through [_setLocked], because
/// [wantKeepAlive] is only re-read when [updateKeepAlive] is called.
class _CrudRowState extends State<_CrudRow>
    with AutomaticKeepAliveClientMixin {
  /// True from the synchronous instant of a tap until that action returns —
  /// modal-and-all. Invisible on purpose: it exists to swallow a second tap,
  /// not to paint anything, so it must not be confused with [_working].
  bool _locked = false;

  @override
  bool get wantKeepAlive => _locked;

  void _setLocked(bool value) {
    if (_locked == value) return;
    _locked = value;
    updateKeepAlive();
  }

  /// Which action's own work is in flight RIGHT NOW: where the cue goes, and
  /// why the rest of the row is inert. `null` whenever the flow is merely
  /// waiting on the user (see [MasiBusyReporter]).
  _CrudRowAction? _working;

  /// Runs one action, forwarding every busy report to BOTH the button that was
  /// pressed (which paints the cue) and this row (which makes the other two
  /// actions inert).
  ///
  /// [reportButton] comes from [PendingIconButton.onPressedArmed]. Reporting to
  /// the button rather than rendering the cue here is what let the hand-rolled
  /// glyph/spinner swap this row used to carry go away.
  Future<void> _run(
    _CrudRowAction action,
    Future<void> Function(BuildContext context, MasiBusyReporter reportBusy)
    body,
    MasiBusyReporter reportButton,
  ) async {
    if (_locked) return;
    _setLocked(true);
    try {
      await body(context, (isBusy) {
        reportButton(isBusy);
        // The row is routinely gone before its own delete settles, so every
        // report has to tolerate being late.
        if (!mounted) return;
        final next = isBusy ? action : null;
        if (next != _working) setState(() => _working = next);
      });
    } finally {
      _setLocked(false);
      // The button clears its own cue in its own `finally`; this only has to
      // put the row's other two actions back.
      if (mounted && _working != null) setState(() => _working = null);
    }
  }

  /// One row action's button. Keeps its pre-existing
  /// `<entityKey>-<action>-<id>` key on the [IconButton] itself (via
  /// [PendingIconButton.buttonKey]) and its 48×48 slot in every state — the cue
  /// replaces the GLYPH, not the button, so the row cannot change height and
  /// `find.byKey` still resolves mid-write.
  ///
  /// `onPressedArmed`, not `onPressed`: all three actions are `open a dialog or
  /// confirm sheet → write`, and a cue spanning the whole future would sit
  /// behind the modal the user is still reading (see [MasiBusyReporter]).
  Widget _actionButton({
    required _CrudRowAction action,
    required String icon,
    required String tooltip,
    required Future<void> Function(BuildContext context, MasiBusyReporter)
    body,
  }) {
    final colors = MasiColors.of(context);
    final busy = _working != null;
    return PendingIconButton(
      buttonKey: Key('${widget.entityKey}-${action.keyPart}-${widget.id}'),
      tooltip: tooltip,
      // The two actions that are NOT running go visibly inert rather than
      // merely unresponsive: `MasiIcon` is handed an explicit colour, so
      // `IconButton`'s own disabled tint would never reach it.
      icon: MasiIcon(icon, color: busy ? colors.ink3 : colors.ink2),
      // Nulled for the running action too — the cue is driven by the button's
      // own armed state, not by this callback, so it stays on screen.
      onPressedArmed: busy
          ? null
          : (reportBusy) => _run(action, body, reportBusy),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Required by AutomaticKeepAliveClientMixin.
    super.build(context);
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final subtitleText = widget.subtitle;
    final busy = _working != null;
    final move = widget.onMove;

    return Material(
      key: Key('${widget.entityKey}-item-${widget.id}'),
      color: colors.surface,
      borderRadius: BorderRadius.circular(MasiRadii.card),
      child: InkWell(
        borderRadius: BorderRadius.circular(MasiRadii.card),
        // Not navigable while one of this row's own writes is in flight:
        // drilling into a sector that is halfway through being deleted is a
        // race with a guaranteed loser.
        onTap: busy ? null : widget.onTap,
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
                      widget.name,
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
              _actionButton(
                action: _CrudRowAction.rename,
                icon: 'edit',
                tooltip: 'Rename',
                body: widget.onRename,
              ),
              if (move != null)
                _actionButton(
                  action: _CrudRowAction.move,
                  icon: 'folder_move',
                  tooltip: 'Move',
                  body: move,
                ),
              _actionButton(
                action: _CrudRowAction.delete,
                icon: 'delete',
                tooltip: 'Delete',
                body: widget.onDelete,
              ),
              MasiIcon('chevron_right', color: colors.ink3),
            ],
          ),
        ),
      ),
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
