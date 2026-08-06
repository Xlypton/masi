import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../core/db/app_database.dart' as db;
import '../../../shared/presentation/masi_icon.dart';
import '../application/moderation_providers.dart';
import '../domain/moderation_state.dart';

/// The OWNER's view of where their topo stands in review (community editing
/// phase 3).
///
/// Renders nothing for a draft or a published topo — the two states where
/// there is nothing to say. Sharing a topo and then seeing no acknowledgement
/// anywhere is the failure this exists to prevent: without it, submitting
/// looks identical to publishing right up until the owner notices nobody can
/// see it.
///
/// Shown only to the owner, because [wallModerationRowProvider] can only
/// resolve a non-published row for them (RLS on `wall_moderation` returns a
/// pending row to its owner and to admins, nobody else).
class ModerationBanner extends ConsumerWidget {
  const ModerationBanner({super.key, required this.wallId});

  final String wallId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final row = ref.watch(wallModerationRowProvider(wallId)).asData?.value;
    if (row == null) return const SizedBox.shrink();
    return ModerationNotice(row: row);
  }
}

/// The presentational half of [ModerationBanner], taking the row directly so
/// it can be exercised without a database.
class ModerationNotice extends StatelessWidget {
  const ModerationNotice({super.key, required this.row});

  final db.WallModerationRow row;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final state = ModerationState.fromWire(row.state);
    final copy = _copyFor(state, row);
    if (copy == null) return const SizedBox.shrink();

    final tint = copy.isProblem ? colors.gradeHard : colors.accent;
    return Container(
      key: Key('moderation-notice-${state.wire}'),
      margin: const EdgeInsets.symmetric(
        horizontal: MasiSpacing.lg,
        vertical: MasiSpacing.sm,
      ),
      padding: const EdgeInsets.all(MasiSpacing.md),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(MasiRadii.card),
        border: Border.all(color: tint.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MasiIcon(copy.icon, size: 18, color: tint),
          const SizedBox(width: MasiSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  copy.headline,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: tint,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  copy.body,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: colors.ink),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static _NoticeCopy? _copyFor(ModerationState state, db.WallModerationRow row) {
    switch (state) {
      case ModerationState.pending:
        return const _NoticeCopy(
          icon: 'sync',
          headline: 'Waiting for review',
          body:
              'Only you can see this topo until a moderator approves it. '
              'You can keep editing in the meantime.',
          isProblem: false,
        );
      case ModerationState.rejected:
        final reason = row.rejectionReason?.trim();
        return _NoticeCopy(
          icon: 'warning',
          headline: 'Not approved',
          // The reason is the whole value of this state. Without it the owner
          // resubmits the same thing and nobody learns anything.
          body: reason == null || reason.isEmpty
              ? 'A moderator did not approve this topo.'
              : reason,
          isProblem: true,
        );
      case ModerationState.removed:
        return const _NoticeCopy(
          icon: 'warning',
          headline: 'Taken down',
          body:
              'A moderator removed this topo from the community. Your content '
              'is still here and nothing has been deleted.',
          isProblem: true,
        );
      case ModerationState.withdrawn:
        return const _NoticeCopy(
          icon: 'eye_off',
          headline: 'Withdrawn',
          body: 'This topo is no longer shared. You can submit it again.',
          isProblem: false,
        );
      case ModerationState.published:
        // A published topo with a withdrawal running gets a countdown, and
        // otherwise says nothing — "your topo is fine" is not news.
        final requestedAt = row.withdrawRequestedAt;
        if (requestedAt == null) return null;
        final goesAt = DateTime.fromMillisecondsSinceEpoch(
          requestedAt,
        ).add(kWithdrawalCooldown);
        final daysLeft = goesAt.difference(DateTime.now()).inDays;
        return _NoticeCopy(
          icon: 'warning',
          headline: 'Being withdrawn',
          body: daysLeft <= 0
              ? 'This topo stops being public today.'
              : 'This topo stops being public in $daysLeft '
                    'day${daysLeft == 1 ? '' : 's'}. You can cancel until then.',
          isProblem: true,
        );
      case ModerationState.draft:
        return null;
    }
  }
}

class _NoticeCopy {
  const _NoticeCopy({
    required this.icon,
    required this.headline,
    required this.body,
    required this.isProblem,
  });

  final String icon;
  final String headline;
  final String body;
  final bool isProblem;
}
