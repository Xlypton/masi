import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../shared/presentation/bottom_safe_inset.dart';
import '../../../shared/presentation/masi_icon.dart';
import '../../../shared/presentation/masi_toast.dart';
import '../../account/application/auth_providers.dart';
import '../application/community_facts_providers.dart';
import '../domain/community_facts.dart';

/// Shows every hazard reported on a topo, live and resolved.
///
/// Resolved reports stay in the list rather than disappearing. That is the
/// visible half of the resolve-don't-delete rule (C-12): a reader is entitled
/// to see that three things were reported and dealt with, which is a different
/// and more reassuring statement than nothing ever having been reported.
///
/// **There is no delete affordance here for the topo owner, and that is not an
/// omission.** They can mark a report resolved — recorded against their name —
/// but the report itself survives. The server enforces the same thing: the
/// `topo_hazards` DELETE policy names the report's author and admins, and
/// pointedly not the topo's owner.
Future<void> showHazardList(
  BuildContext context, {
  required String wallId,
  required String? wallOwnerId,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  backgroundColor: Colors.transparent,
  builder: (_) => HazardListSheet(wallId: wallId, wallOwnerId: wallOwnerId),
);

class HazardListSheet extends ConsumerWidget {
  const HazardListSheet({
    super.key,
    required this.wallId,
    required this.wallOwnerId,
  });

  final String wallId;
  final String? wallOwnerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MasiColors.of(context);
    final hazards = ref.watch(wallHazardsProvider(wallId)).asData?.value ?? [];
    final uid = ref.watch(effectiveUidProvider);

    // NOT "the measured bottom-bar height" (this sheet's only caller,
    // `CommunityTopoDetailScreen`, is a top-level route outside `NavShell` —
    // see `nav_shell.dart`'s class doc) — this is the standalone-PWA
    // home-indicator floor. Padding the SCROLL VIEW rather than wrapping the
    // sheet in a SafeArea keeps the surface colour running under the home
    // indicator instead of stopping short of it.
    final bottomInset = masiBottomInset(context, ref);

    return Container(
      key: const Key('hazard-list-sheet'),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(MasiRadii.large),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: MasiSpacing.sm),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: colors.ink3,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              MasiSpacing.lg,
              MasiSpacing.md,
              MasiSpacing.lg,
              MasiSpacing.sm,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Reported hazards',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
          ),
          Flexible(
            child: hazards.isEmpty
                ? Padding(
                    key: const Key('hazard-list-empty'),
                    padding: EdgeInsets.fromLTRB(
                      MasiSpacing.lg,
                      MasiSpacing.md,
                      MasiSpacing.lg,
                      MasiSpacing.lg + bottomInset,
                    ),
                    child: Text(
                      'Nothing reported here.',
                      style: Theme.of(
                        context,
                      ).textTheme.bodyMedium?.copyWith(color: colors.ink2),
                    ),
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    padding: EdgeInsets.fromLTRB(
                      MasiSpacing.lg,
                      0,
                      MasiSpacing.lg,
                      MasiSpacing.lg + bottomInset,
                    ),
                    itemCount: hazards.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: MasiSpacing.sm),
                    itemBuilder: (_, index) {
                      final hazard = hazards[index];
                      return _HazardTile(
                        hazard: hazard,
                        canResolve: hazard.canResolve(
                          uid: uid,
                          wallOwnerId: wallOwnerId,
                        ),
                        onResolve: () => _resolve(context, ref, hazard),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _resolve(
    BuildContext context,
    WidgetRef ref,
    HazardReport hazard,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await ref
          .read(communityFactsServiceProvider)
          .resolveHazard(
            hazardId: hazard.id,
            wallId: hazard.wallId,
            resolved: !hazard.isResolved,
          );
    } catch (error) {
      // Loud, not silent. There is no outbox behind this (decision D-4), so a
      // failure means nothing was recorded — saying so is the honest outcome.
      messenger?.showMasiToast(
        'Could not update that hazard. $error',
        kind: MasiToastKind.error,
      );
    }
  }
}

class _HazardTile extends StatelessWidget {
  const _HazardTile({
    required this.hazard,
    required this.canResolve,
    required this.onResolve,
  });

  final HazardReport hazard;
  final bool canResolve;
  final VoidCallback onResolve;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final resolved = hazard.isResolved;
    final tint = resolved
        ? colors.ink3
        : (hazard.severity.isUrgent ? colors.gradeHard : colors.accent);

    return Container(
      key: Key('hazard-row-${hazard.id}'),
      padding: const EdgeInsets.all(MasiSpacing.md),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: resolved ? 0.06 : 0.12),
        borderRadius: BorderRadius.circular(MasiRadii.card),
        border: Border.all(color: tint.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MasiIcon(
            resolved ? 'check' : 'warning',
            size: 18,
            color: tint,
          ),
          const SizedBox(width: MasiSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _label(hazard.severity, resolved),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: tint,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  hazard.body,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: resolved ? colors.ink2 : colors.ink,
                    // Struck through rather than hidden: the report is still
                    // the record, it just no longer applies.
                    decoration: resolved ? TextDecoration.lineThrough : null,
                  ),
                ),
              ],
            ),
          ),
          if (canResolve)
            TextButton(
              key: Key('hazard-resolve-${hazard.id}'),
              onPressed: onResolve,
              child: Text(resolved ? 'Reopen' : 'Resolve'),
            ),
        ],
      ),
    );
  }

  static String _label(HazardSeverity severity, bool resolved) {
    final name = switch (severity) {
      HazardSeverity.danger => 'DANGER',
      HazardSeverity.caution => 'CAUTION',
      HazardSeverity.note => 'NOTE',
    };
    return resolved ? '$name · resolved' : name;
  }
}
