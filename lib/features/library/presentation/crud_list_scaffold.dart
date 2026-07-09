import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Generic AppBar + body scaffold for a "list of named entities" CRUD screen
/// (Areas / Sectors / Walls), driven by an [AsyncValue] the caller already
/// obtained from `ref.watch(...)`.
///
/// This widget is intentionally NOT a [ConsumerWidget]: it knows nothing
/// about Riverpod. The three screens (AreasScreen / SectorsScreen /
/// WallsScreen) each watch their own scoped provider and pass the resulting
/// [AsyncValue] plus a handful of callbacks (create/rename/delete/retry/tap)
/// in, which keeps this widget trivially testable and reusable.
///
/// Widget keys, so screens stay tappable in widget tests:
///  - `<entityKey>-add-fab`: the FloatingActionButton that opens the "create"
///    dialog.
///  - `<entityKey>-item-<id>`: each row's [ListTile].
///  - `<entityKey>-rename-<id>`: the rename icon button on a row.
///  - `<entityKey>-delete-<id>`: the delete icon button on a row; tapping it
///    opens a confirm [AlertDialog] (does NOT delete immediately).
///  - `<entityKey>-delete-confirm-<id>`: the "Delete" button inside that
///    confirm dialog — tapping IT calls [onDelete].
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: asyncItems.when(
        data: (items) {
          if (items.isEmpty) {
            return Center(child: Text(emptyMessage));
          }
          return ListView.builder(
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              final id = idOf(item);
              final subtitleText = subtitleOf?.call(item);
              return ListTile(
                key: Key('$entityKey-item-$id'),
                title: Text(nameOf(item)),
                subtitle: subtitleText != null ? Text(subtitleText) : null,
                onTap: () => onTap(item),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      key: Key('$entityKey-rename-$id'),
                      icon: const Icon(Icons.edit),
                      tooltip: 'Rename',
                      onPressed: () => _handleRename(context, item),
                    ),
                    IconButton(
                      key: Key('$entityKey-delete-$id'),
                      icon: const Icon(Icons.delete),
                      tooltip: 'Delete',
                      onPressed: () => _handleDelete(context, item),
                    ),
                  ],
                ),
              );
            },
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Something went wrong: $error'),
              const SizedBox(height: 8),
              ElevatedButton(
                key: Key('$entityKey-retry'),
                onPressed: onRetry,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        key: Key('$entityKey-add-fab'),
        onPressed: () => _handleCreate(context),
        child: const Icon(Icons.add),
      ),
    );
  }

  Future<void> _handleCreate(BuildContext context) async {
    final name = await _showNameDialog(context, title: addDialogTitle);
    if (name == null) return;
    await onCreate(name);
  }

  Future<void> _handleRename(BuildContext context, T item) async {
    final name = await _showNameDialog(
      context,
      title: renameDialogTitle,
      initialValue: nameOf(item),
    );
    if (name == null) return;
    await onRename(item, name);
  }

  Future<void> _handleDelete(BuildContext context, T item) async {
    final id = idOf(item);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete?'),
        content: Text('Delete "${nameOf(item)}"? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: Key('$entityKey-delete-confirm-$id'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await onDelete(item);
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
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        key: const Key('crud-name-field'),
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'Name'),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const Key('crud-name-submit'),
          onPressed: _canSubmit ? _submit : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
