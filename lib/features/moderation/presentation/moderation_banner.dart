import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../core/db/app_database.dart' as db;
import '../../../shared/presentation/masi_icon.dart';
import '../application/moderation_providers.dart';
import '../domain/moderation_state.dart';

/// Where a topo stands in review, and whether it is on its way out
/// (community editing phases 3 and 5).
///
/// Renders nothing for a draft or a healthy published topo — the two states
/// where there is nothing to say. Sharing a topo and then seeing no
/// acknowledgement anywhere is the failure this exists to prevent: without it,
/// submitting looks identical to publishing right up until the owner notices
/// nobody can see it.
///
/// [isOwner] switches audience, not just wording. Every non-published state is
/// the owner's business alone, and RLS enforces that — `wall_moderation`
/// returns a pending or rejected row to its owner and to admins, nobody else.
/// The one thing a READER is entitled to know is that a topo they may be
/// planning around is being withdrawn (C-3): that notice is the reason the
/// ten days exist at all, so it renders for everyone, and says nothing about
/// cancelling because a reader cannot.
class ModerationBanner extends ConsumerWidget {
  const ModerationBanner({
    super.key,
    required this.wallId,
    this.isOwner = true,
  });

  final String wallId;
  final bool isOwner;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final row = ref.watch(wallModerationRowProvider(wallId)).asData?.value;
    if (row == null) return const SizedBox.shrink();
    return ModerationNotice(row: row, isOwner: isOwner);
  }
}

/// The presentational half of [ModerationBanner], taking the row directly so
/// it can be exercised without a database.
class ModerationNotice extends StatelessWidget {
  const ModerationNotice({
    super.key,
    required this.row,
    this.isOwner = true,
    this.now,
  });

  final db.WallModerationRow row;
  final bool isOwner;

  /// Injected so the countdown's boundary cases are testable without waiting
  /// ten days. Defaults to the wall clock.
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final view = ModerationView.fromRow(
      state: row.state,
      withdrawRequestedAt: row.withdrawRequestedAt,
      rejectionReason: row.rejectionReason,
      now: now,
    );
    final copy = _copyFor(view, isOwner: isOwner);
    if (copy == null) return const SizedBox.shrink();

    // `withdrawing` is its own key rather than `published`: it is stored as
    // published, but a test (or a reader) asking "is the withdrawal notice up"
    // must not have to match the state of a perfectly healthy topo.
    final slug = view.isWithdrawing ? 'withdrawing' : view.effectiveState.wire;
    final tint = copy.isProblem ? colors.gradeHard : colors.accent;
    return Container(
      key: Key('moderation-notice-$slug'),
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

  static _NoticeCopy? _copyFor(ModerationView view, {required bool isOwner}) {
    // The withdrawal notice comes FIRST and is the only thing a non-owner ever
    // sees. It is checked ahead of the state switch because a withdrawing topo
    // is still stored as `published`, which the switch below correctly treats
    // as "nothing to say".
    if (view.isWithdrawing) {
      // Always at least 1: `daysRemaining` rounds UP and `isWithdrawing` is
      // false once the deadline passes, so the final partial day reads "in 1
      // day" and there is deliberately no "today" branch — it would be
      // unreachable, and unreachable copy is copy nobody ever proofreads.
      final days = view.daysRemaining ?? 1;
      final when = 'in $days day${days == 1 ? '' : 's'}';
      return _NoticeCopy(
        icon: 'warning',
        headline: 'Being withdrawn',
        body: isOwner
            ? 'This topo stops being public $when. You can cancel until then.'
            : 'The owner is withdrawing this topo. It stops being public '
                  '$when.',
        isProblem: true,
      );
    }

    // Everything below is between the owner and the moderators.
    if (!isOwner) return null;

    switch (view.effectiveState) {
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
        final reason = view.rejectionReason?.trim();
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
          body:
              'This topo is no longer public. You can submit it again, and it '
              'goes back through review.',
          isProblem: false,
        );
      // A healthy published topo says nothing — "your topo is fine" is not
      // news. The withdrawing case never reaches here; it is handled above,
      // before this switch, precisely because it is still stored as
      // `published`.
      case ModerationState.published:
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
