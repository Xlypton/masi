import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../application/ascents_providers.dart';
import '../data/ascents_repository.dart';

/// Modal sheet for logging an ascent of one route: an [AscentStyle] picker,
/// an optional notes field, and a save action that stamps `climbedAt` to
/// "now" (no date picker — matches the ticket's "date defaulting to now"
/// spec).
///
/// Extracted from `CommunityTopoDetailScreen`'s original private
/// `_LogAscentSheet` so it can be shared by BOTH that screen's per-route
/// "log ascent" button AND the user's own topo canvas legend
/// (`RouteLegend.onLogAscent` / `TopoCanvasScreen`) — previously logging an
/// ascent was only reachable from the community (published-topo) detail
/// view, with no discoverable way to log an ascent while viewing one's own
/// routes.
///
/// [keyPrefix] namespaces every [Key] this widget assigns (the outer sheet,
/// each style chip, the notes field, and the save button) so two different
/// call sites keep their own stable widget-test keys without colliding —
/// e.g. `'$keyPrefix-ascent-save'`. The community screen passes
/// `'community'`, preserving its pre-extraction keys
/// (`community-log-ascent-sheet` / `community-ascent-style-<name>` /
/// `community-ascent-notes` / `community-ascent-save`) exactly; the topo
/// canvas passes `'topo'`.
class LogAscentSheet extends ConsumerStatefulWidget {
  const LogAscentSheet({
    super.key,
    required this.routeId,
    required this.wallId,
    required this.keyPrefix,
  });

  /// The route's real, persisted DB row id — see
  /// `RouteRepository.routeDbIdsByNumber`'s doc for why this must NOT be
  /// `TopoRoute.id` (a locally-reassigned sequential int with no stable
  /// identity across a `loadRoutes` call). This is the only id
  /// [AscentsRepository.logAscent] (and `Ascents.routeId`) can reference.
  final String routeId;

  /// The wall the route belongs to, passed straight through to
  /// [AscentsRepository.logAscent].
  final String wallId;

  /// Namespaces this widget's own [Key]s — see class doc.
  final String keyPrefix;

  @override
  ConsumerState<LogAscentSheet> createState() => _LogAscentSheetState();
}

class _LogAscentSheetState extends ConsumerState<LogAscentSheet> {
  AscentStyle _style = AscentStyle.redpoint;
  final _notesController = TextEditingController();

  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final notes = _notesController.text.trim();
    await ref
        .read(ascentsRepositoryProvider)
        .logAscent(
          routeId: widget.routeId,
          wallId: widget.wallId,
          climbedAt: DateTime.now(),
          style: _style,
          notes: notes.isEmpty ? null : notes,
        );
    if (mounted) {
      FocusManager.instance.primaryFocus?.unfocus();
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: Key('${widget.keyPrefix}-log-ascent-sheet'),
      padding: EdgeInsets.only(
        left: MasiSpacing.lg,
        right: MasiSpacing.lg,
        top: MasiSpacing.lg,
        bottom: MediaQuery.viewInsetsOf(context).bottom + MasiSpacing.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Log ascent', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: MasiSpacing.md),
          Wrap(
            spacing: MasiSpacing.sm,
            children: [
              for (final style in AscentStyle.values)
                ChoiceChip(
                  key: Key('${widget.keyPrefix}-ascent-style-${style.name}'),
                  label: Text(style.name),
                  selected: _style == style,
                  onSelected: (_) => setState(() => _style = style),
                ),
            ],
          ),
          const SizedBox(height: MasiSpacing.md),
          TextField(
            key: Key('${widget.keyPrefix}-ascent-notes'),
            controller: _notesController,
            decoration: const InputDecoration(hintText: 'Notes (optional)'),
          ),
          const SizedBox(height: MasiSpacing.md),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              key: Key('${widget.keyPrefix}-ascent-save'),
              onPressed: _save,
              child: const Text('Save'),
            ),
          ),
        ],
      ),
    );
  }
}
