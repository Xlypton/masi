import 'package:flutter/material.dart';

import '../../../shared/presentation/masi_dialogs.dart';
import '../domain/community_facts.dart';

/// What [showHazardReporter] resolved to.
class HazardDraft {
  const HazardDraft({required this.severity, required this.body});

  final HazardSeverity severity;
  final String body;
}

/// Lets anyone signed in report a hazard on a topo (community editing phase 4
/// / R-1).
///
/// Returns `null` if they backed out. Two steps rather than one form: pick how
/// serious it is, then describe it. The description is not optional and an
/// empty one abandons the report — "danger" with no explanation tells a
/// climber nothing they can act on, and would be indistinguishable from a
/// mis-tap.
///
/// Deliberately reachable by any signed-in user on any published topo, with no
/// approval step between filing and appearing. That asymmetry is the point of
/// the phase: the topo is the author's work, but whether there is a loose
/// block over the belay is not.
Future<HazardDraft?> showHazardReporter(
  BuildContext context, {
  required String targetLabel,
}) async {
  final picked = await showMasiActionSheet<String>(
    context,
    sheetKey: const Key('hazard-reporter-sheet'),
    title: 'Report a hazard — $targetLabel',
    message:
        'Visible to everyone straight away. The topo owner can mark it '
        'resolved but cannot delete it.',
    actions: const [
      MasiSheetAction(
        key: Key('hazard-danger'),
        label: 'Danger',
        value: 'danger',
        subtitle: 'Could hurt someone. Bad bolt, loose block over the belay.',
        isDestructive: true,
      ),
      MasiSheetAction(
        key: Key('hazard-caution'),
        label: 'Caution',
        value: 'caution',
        subtitle: 'Take care. Loose flake, rope drag onto an edge.',
      ),
      MasiSheetAction(
        key: Key('hazard-note'),
        label: 'Note',
        value: 'note',
        subtitle: 'Worth knowing, not dangerous. High first bolt.',
      ),
    ],
  );
  if (picked == null) return null;

  if (!context.mounted) return null;
  final body = await showMasiTextPrompt(
    context,
    title: 'What should people know?',
    submitLabel: 'Report',
    placeholder: 'Bolt 2 spins — do not fall on it',
    fieldKey: const Key('hazard-body-field'),
    submitKey: const Key('hazard-body-submit'),
  );

  // Backing out of the description abandons the whole report rather than
  // filing a bare severity nobody can act on.
  if (body == null || body.trim().isEmpty) return null;

  return HazardDraft(
    // Parsed back through fromWire rather than switched on here, so this and
    // the server agree on exactly one mapping.
    severity: HazardSeverity.fromWire(picked),
    body: body.trim(),
  );
}
