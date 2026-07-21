part of 'topos_screen.dart';

/// Prompts for the new topo's name -- shown by `_handleNewTopo` after a
/// photo is picked/decoded and strictly BEFORE `createTopo` is ever called
/// (#25), prefilled with the `'Topo ${count + 1}'` default so accepting
/// without typing anything reproduces the old auto-numbered behavior.
///
/// Mirrors `crud_list_scaffold.dart`'s `_NameDialog` / this file's own
/// [_TopoNameDialog] (controller, disabled submit while empty/whitespace,
/// `onSubmitted`) but is a DISTINCT class with its OWN keys
/// (`topo-name-field` / `topo-name-submit`, per plan #25) rather than
/// reusing `crud-name-field` / `crud-name-submit`: unlike the rename
/// dialog (which only ever replaces this screen's own body), this one is
/// the tail end of the "New topo" flow, which pushes a route once it
/// resolves -- giving it distinct keys avoids any ambiguity for a test (or
/// future caller) that might end up with both a name prompt and a rename
/// dialog reachable in the same widget tree.
///
/// Cancelling/dismissing (Cancel button, barrier tap, back gesture) pops
/// `null` -- the default `showDialog` behavior for an unhandled dismissal
/// -- which `_handleNewTopo` treats as "abort the entire creation flow":
/// no wall, no photo, no orphan state of any kind.
class _NewTopoNameDialog extends StatefulWidget {
  const _NewTopoNameDialog({required this.initialValue});

  final String initialValue;

  @override
  State<_NewTopoNameDialog> createState() => _NewTopoNameDialogState();
}

class _NewTopoNameDialogState extends State<_NewTopoNameDialog> {
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
    final textTheme = Theme.of(context).textTheme;
    return AlertDialog(
      title: Text('Name this topo', style: textTheme.titleLarge),
      content: TextField(
        key: const Key('topo-name-field'),
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'Name'),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () {
            FocusManager.instance.primaryFocus?.unfocus();
            Navigator.of(context).pop();
          },
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const Key('topo-name-submit'),
          onPressed: _canSubmit ? _submit : null,
          child: const Text('Create'),
        ),
      ],
    );
  }
}

/// Mirrors `crud_list_scaffold.dart`'s `_NameDialog` (controller, disabled
/// submit while empty/whitespace, `onSubmitted`) for the rename flow. Not
/// reused directly: that class is library-private to `crud_list_scaffold.dart`.
/// Reuses its `crud-name-field` / `crud-name-submit` keys, which is safe
/// because only one such dialog is ever on screen at a time.
class _TopoNameDialog extends StatefulWidget {
  const _TopoNameDialog({required this.initialValue});

  final String initialValue;

  @override
  State<_TopoNameDialog> createState() => _TopoNameDialogState();
}

class _TopoNameDialogState extends State<_TopoNameDialog> {
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
    return AlertDialog(
      title: const Text('Rename topo'),
      content: TextField(
        key: const Key('crud-name-field'),
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'Name'),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () {
            FocusManager.instance.primaryFocus?.unfocus();
            Navigator.of(context).pop();
          },
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
