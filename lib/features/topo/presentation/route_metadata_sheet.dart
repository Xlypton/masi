import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:climbtopo/core/grades/grade_system.dart';
import 'package:climbtopo/features/topo/application/draw_controller.dart';
import 'package:climbtopo/features/topo/domain/topo_route.dart';

/// Free-form climbing style options offered by [RouteMetadataSheet], by
/// convention one of `'sport'`, `'trad'`, `'boulder'` (see
/// [TopoRoute.style]).
const List<(String value, String label)> _styleOptions = [
  ('sport', 'Sport'),
  ('trad', 'Trad'),
  ('boulder', 'Boulder'),
];

/// A standalone, directly-testable form for editing a [TopoRoute]'s
/// free-form/grade metadata (name, grade system + grade, style,
/// description).
///
/// Deliberately built as a plain (non-modal-aware) widget rather than
/// something that reaches into `Navigator`/route-arguments machinery, so it
/// can be pumped directly inside a `ProviderScope`/`MaterialApp` in widget
/// tests — with [drawControllerProvider] seeded via a
/// [ProviderContainer]/[UncontrolledProviderScope] — without ever touching
/// the real image-decode/canvas path that only [TopoCanvasScreen] drives.
/// Callers that want it presented as a sheet (e.g. [TopoCanvasScreen]) wrap
/// it in `showModalBottomSheet` themselves; this widget only needs a
/// [Navigator] ancestor to pop itself on Save/Cancel.
class RouteMetadataSheet extends ConsumerStatefulWidget {
  const RouteMetadataSheet({super.key, required this.routeId, this.initial});

  /// The id of the [TopoRoute] (in [DrawState.routes]) this sheet edits.
  final int routeId;

  /// The route's current metadata, used to pre-fill the form fields when
  /// editing an already-graded/named route. Null for a brand new route
  /// (all fields start empty/unset).
  final TopoRoute? initial;

  @override
  ConsumerState<RouteMetadataSheet> createState() =>
      _RouteMetadataSheetState();
}

class _RouteMetadataSheetState extends ConsumerState<RouteMetadataSheet> {
  late final TextEditingController _nameController;
  late final TextEditingController _descriptionController;
  late GradeSystem _gradeSystem;
  String? _grade;
  String? _style;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _nameController = TextEditingController(text: initial?.name ?? '');
    _descriptionController = TextEditingController(
      text: initial?.description ?? '',
    );
    _gradeSystem = initial?.gradeSystem ?? GradeSystem.french;
    _grade = initial?.gradeRaw;
    _style = initial?.style;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  /// Switches the active grading ladder. If the previously-selected grade
  /// isn't a member of the new ladder, the selection resets to unset
  /// (rather than silently keeping a token from the wrong system).
  void _onGradeSystemChanged(GradeSystem system) {
    if (_gradeSystem == system) return;
    setState(() {
      _gradeSystem = system;
      final grade = _grade;
      if (grade != null && !gradeOptions(system).contains(grade)) {
        _grade = null;
      }
    });
  }

  void _save() {
    ref
        .read(drawControllerProvider.notifier)
        .setRouteMetadata(
          widget.routeId,
          name: _nameController.text.trim().isEmpty
              ? null
              : _nameController.text.trim(),
          gradeSystem: _grade == null ? null : _gradeSystem,
          gradeRaw: _grade,
          style: _style,
          description: _descriptionController.text.trim().isEmpty
              ? null
              : _descriptionController.text.trim(),
        );
    _pop();
  }

  void _cancel() {
    _pop();
  }

  /// Pops this sheet off its enclosing [Navigator] if it's actually part of
  /// one that can pop (the real usage — pushed by `showModalBottomSheet`).
  /// Uses `maybePop` rather than a bare `pop()` so this widget stays
  /// pumpable as the sole route in a test `MaterialApp` (see class doc):
  /// a bare `pop()` there would try to pop the app's only route, which
  /// Flutter disallows.
  void _pop() {
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final options = gradeOptions(_gradeSystem);
    final gradeValue = (_grade != null && options.contains(_grade))
        ? _grade
        : null;

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Route metadata',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('topo-meta-name'),
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _ToggleButton(
                    key: const Key('topo-meta-gradesystem-french'),
                    label: 'French',
                    selected: _gradeSystem == GradeSystem.french,
                    onPressed: () =>
                        _onGradeSystemChanged(GradeSystem.french),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _ToggleButton(
                    key: const Key('topo-meta-gradesystem-uiaa'),
                    label: 'UIAA',
                    selected: _gradeSystem == GradeSystem.uiaa,
                    onPressed: () => _onGradeSystemChanged(GradeSystem.uiaa),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            DropdownButton<String>(
              key: const Key('topo-meta-grade'),
              isExpanded: true,
              hint: const Text('Grade'),
              value: gradeValue,
              items: [
                for (final option in options)
                  DropdownMenuItem(value: option, child: Text(option)),
              ],
              onChanged: (value) => setState(() => _grade = value),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                for (final (value, label) in _styleOptions) ...[
                  Expanded(
                    child: _ToggleButton(
                      key: Key('topo-meta-style-$value'),
                      label: label,
                      selected: _style == value,
                      onPressed: () => setState(() => _style = value),
                    ),
                  ),
                  if (value != _styleOptions.last.$1) const SizedBox(width: 8),
                ],
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('topo-meta-description'),
              controller: _descriptionController,
              decoration: const InputDecoration(labelText: 'Description'),
              minLines: 2,
              maxLines: 4,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    key: const Key('topo-meta-cancel'),
                    onPressed: _cancel,
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    key: const Key('topo-meta-save'),
                    onPressed: _save,
                    child: const Text('Save'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A simple selectable toggle button used for the grade-system and style
/// pickers: an [OutlinedButton] whose fill reflects [selected].
class _ToggleButton extends StatelessWidget {
  const _ToggleButton({
    super.key,
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        backgroundColor: selected ? colorScheme.primaryContainer : null,
        foregroundColor: selected ? colorScheme.onPrimaryContainer : null,
      ),
      onPressed: onPressed,
      child: Text(label),
    );
  }
}
