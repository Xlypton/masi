import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../../../shared/presentation/masi_dialogs.dart';
import '../domain/access_state.dart';

/// What [showAccessEditor] resolved to: a state (or `null` for "nothing
/// stated") plus its reason.
class AccessEdit {
  const AccessEdit({required this.state, required this.note});

  final AccessState? state;
  final String? note;
}

/// Lets the user state the access/closure of a crag, sector or topo
/// (community editing phase 2 / R-2).
///
/// Returns `null` if they backed out without deciding — distinct from an
/// [AccessEdit] carrying a null `state`, which means "explicitly clear this
/// back to nothing stated". Conflating the two would make "cancel" silently
/// erase an existing closure.
///
/// Two steps rather than one form: pick the state from an action sheet, then
/// — for anything that restricts — type the reason. The reason is what makes
/// the restriction credible and obeyed; a bare "closed" with no explanation
/// gets ignored, which is why theCrag pairs a `Closed` tag with an `Access`
/// field rather than offering a lone flag.
Future<AccessEdit?> showAccessEditor(
  BuildContext context, {
  required String targetLabel,
  AccessState? current,
  String? currentNote,
}) async {
  final picked = await showMasiActionSheet<String>(
    context,
    sheetKey: const Key('access-editor-sheet'),
    title: 'Access — $targetLabel',
    message:
        'Applies to everything inside it. Closed crags stay listed and '
        'searchable, clearly marked — only "not listed" hides them.',
    actions: [
      const MasiSheetAction(
        key: Key('access-open'),
        label: 'Open',
        value: 'open',
        subtitle: 'Confirmed open',
      ),
      const MasiSheetAction(
        key: Key('access-restricted'),
        label: 'Restricted',
        value: 'restricted',
        subtitle: 'Seasonal, permit, private approach…',
      ),
      const MasiSheetAction(
        key: Key('access-closed'),
        label: 'Closed',
        value: 'closed',
        subtitle: 'Still listed, clearly marked closed',
        isDestructive: true,
      ),
      const MasiSheetAction(
        key: Key('access-sensitive'),
        label: 'Not listed',
        value: 'sensitive',
        subtitle: 'Removed from public view entirely',
        isDestructive: true,
      ),
      if (current != null)
        const MasiSheetAction(
          key: Key('access-clear'),
          label: 'Clear',
          value: 'clear',
          subtitle: 'Say nothing about access',
        ),
    ],
  );
  if (picked == null) return null;
  if (picked == 'clear') return const AccessEdit(state: null, note: null);

  final state = AccessState.fromWire(picked);
  // "Open" needs no justification; every restriction does.
  if (state == AccessState.open) {
    return AccessEdit(state: state, note: null);
  }

  if (!context.mounted) return null;
  final note = await showMasiTextPrompt(
    context,
    title: 'Why?',
    submitLabel: 'Save',
    placeholder: 'Peregrine nesting until 31 Jul',
    initialValue: currentNote ?? '',
    fieldKey: const Key('access-note-field'),
    submitKey: const Key('access-note-submit'),
  );
  // Backing out of the reason abandons the whole edit rather than recording a
  // restriction nobody explained.
  if (note == null) return null;
  return AccessEdit(state: state, note: note.trim().isEmpty ? null : note.trim());
}

/// A compact, tappable summary of the current access state, for a row or a
/// detail screen. Reads "Access: not stated" when there is nothing, so the
/// affordance is discoverable rather than only appearing once something is
/// already wrong.
class AccessSummaryTile extends StatelessWidget {
  const AccessSummaryTile({
    super.key,
    required this.state,
    required this.note,
    required this.onTap,
  });

  final AccessState? state;
  final String? note;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final label = switch (state) {
      null => 'Not stated',
      AccessState.open => 'Open',
      AccessState.restricted => 'Restricted',
      AccessState.closed => 'Closed',
      AccessState.sensitive => 'Not listed',
    };
    final tint = (state?.warrantsNotice ?? false) ? colors.gradeHard : colors.ink2;

    return CupertinoButton(
      key: const Key('access-summary-tile'),
      padding: EdgeInsets.zero,
      onPressed: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Access: $label',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: tint),
          ),
          if (note != null && note!.isNotEmpty) ...[
            const SizedBox(width: MasiSpacing.xs),
            Flexible(
              child: Text(
                '· $note',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.ink3),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
