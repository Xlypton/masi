import 'package:flutter/material.dart';

import '../../../app/theme.dart';

/// A single labelled candidate destination in [showMoveTargetPicker]'s list:
/// an [id] (returned to the caller on tap) paired with a display [label].
///
/// Kept deliberately generic (just id + label) rather than typed on
/// [AreaRef]/[SectorRef] directly, so this one widget serves both
/// `topos_screen.dart`'s topo->sector picker and `sectors_screen.dart`'s
/// sector->area picker — each caller builds its own labels (e.g. a sector
/// option labelled `"AreaName › SectorName"`) before handing them in.
class MoveTargetOption {
  const MoveTargetOption({required this.id, required this.label});

  final String id;
  final String label;
}

/// Shows a modal bottom sheet listing [options] as tappable rows (each keyed
/// `<keyPrefix>-<option.id>`, per DESIGN.md's grouped-inset list styling),
/// returning the tapped option's id, or `null` if dismissed without a
/// selection (tap outside / swipe down).
///
/// When [options] is empty, renders [emptyMessage] instead of a list — e.g.
/// every candidate destination has been filtered out (foreign ownership, or
/// the entity's own current parent) — rather than an unexplained blank
/// sheet.
Future<String?> showMoveTargetPicker(
  BuildContext context, {
  required String title,
  required List<MoveTargetOption> options,
  required String keyPrefix,
  required String emptyMessage,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _MoveTargetPickerSheet(
      title: title,
      options: options,
      keyPrefix: keyPrefix,
      emptyMessage: emptyMessage,
    ),
  );
}

class _MoveTargetPickerSheet extends StatelessWidget {
  const _MoveTargetPickerSheet({
    required this.title,
    required this.options,
    required this.keyPrefix,
    required this.emptyMessage,
  });

  final String title;
  final List<MoveTargetOption> options;
  final String keyPrefix;
  final String emptyMessage;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;

    return SafeArea(
      child: Container(
        padding: const EdgeInsets.all(MasiSpacing.lg),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(MasiRadii.card),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: textTheme.titleLarge,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: MasiSpacing.md),
            if (options.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: MasiSpacing.lg),
                child: Text(
                  emptyMessage,
                  style: textTheme.bodyMedium?.copyWith(color: colors.ink2),
                  textAlign: TextAlign.center,
                ),
              )
            else
              Flexible(
                child: ListView.separated(
                  key: Key('$keyPrefix-list'),
                  shrinkWrap: true,
                  itemCount: options.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: MasiSpacing.xs),
                  itemBuilder: (context, index) {
                    final option = options[index];
                    return Material(
                      color: colors.surface2,
                      borderRadius: BorderRadius.circular(MasiRadii.control),
                      child: InkWell(
                        key: Key('$keyPrefix-${option.id}'),
                        borderRadius: BorderRadius.circular(
                          MasiRadii.control,
                        ),
                        onTap: () => Navigator.of(context).pop(option.id),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: MasiSpacing.md,
                            vertical: MasiSpacing.md,
                          ),
                          child: Text(
                            option.label,
                            style: textTheme.bodyLarge,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            const SizedBox(height: MasiSpacing.sm),
          ],
        ),
      ),
    );
  }
}
