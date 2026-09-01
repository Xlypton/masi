import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../shared/presentation/bottom_safe_inset.dart';
import '../../../shared/presentation/masi_pending_button.dart';
import '../../account/application/profile_providers.dart';
import '../application/ascents_providers.dart';
import '../data/ascents_repository.dart';
import 'logbook_screen.dart' show styleLabel;
import '../../../shared/presentation/masi_toast.dart';

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
  /// Defaults to [AscentStyle.send] — "I climbed it", asserting nothing about
  /// how. It used to default to [AscentStyle.redpoint], which claims "sent
  /// after previous attempts": a specific, frequently-wrong statement that a
  /// climber got simply by not choosing. A neutral default cannot be wrong in
  /// that way, and the five specific styles are all still one tap away.
  AscentStyle _style = AscentStyle.send;
  final _notesController = TextEditingController();

  /// Whether this ascent is visible on the public community feed
  /// (`Ascent.visibility == 'shared'`).
  ///
  /// **Defaults to `true`** (user request, 2026-08-25). This reverses feature
  /// #12's original "sharing is opt-in, never on by default": logging a send
  /// is the social act this app is for, and the toggle sits in plain sight
  /// directly above Save with its consequence spelled out, so a climber who
  /// wants an entry kept private sees and flips it in the same glance.
  ///
  /// The reversal is deliberately scoped to THIS sheet, where a person is
  /// looking at the switch. `log_ascent` in the MCP connector still writes
  /// `visibility: 'private'` unconditionally, and should: there the actor is a
  /// model acting on a sentence, nobody is looking at a toggle, and publishing
  /// to the feed because a phrase was ambiguous would be a genuinely bad
  /// surprise.
  bool _shared = true;

  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  /// The re-entrancy guard that used to live here as a `_saving` bool — without
  /// which a double-tap on Save logged a duplicate ascent — is now
  /// [MasiPendingButton]'s: it swallows a second tap in the same frame and
  /// stays disabled for the whole flight.
  Future<void> _save() async {
    final notes = _notesController.text.trim();
    final authorName = ref.read(myDisplayNameProvider).asData?.value;
    await ref
        .read(ascentsRepositoryProvider)
        .logAscent(
          routeId: widget.routeId,
          wallId: widget.wallId,
          climbedAt: DateTime.now(),
          style: _style,
          notes: notes.isEmpty ? null : notes,
          shared: _shared,
          authorName: authorName,
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
        // max, not +: the keyboard inset and the standalone-PWA home-
        // indicator floor are two different reasons for bottom clearance,
        // never both at once. Summing them would jump the sheet 32px the
        // moment the keyboard opens.
        bottom:
            math.max(
              MediaQuery.viewInsetsOf(context).bottom,
              masiBottomInset(context, ref),
            ) +
            MasiSpacing.lg,
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
                  label: Text(styleLabel(style)),
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
          SwitchListTile(
            key: const Key('log-ascent-share-toggle'),
            contentPadding: EdgeInsets.zero,
            value: _shared,
            onChanged: (value) => setState(() => _shared = value),
            title: const Text('Share to community feed'),
            subtitle: const Text(
              'Others can see, like & comment on this ascent',
            ),
          ),
          const SizedBox(height: MasiSpacing.md),
          MasiPendingButton.filled(
            key: Key('${widget.keyPrefix}-ascent-save'),
            expand: true,
            onPressed: _save,
            onError: (error, stackTrace) => ScaffoldMessenger.of(context).showMasiToast(
              "Couldn't log this ascent — please try again",
              kind: MasiToastKind.error,
            ),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}
