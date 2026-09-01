import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../shared/presentation/masi_icon.dart';
import '../../../shared/presentation/masi_toast.dart';
import '../application/community_facts_providers.dart';

/// "Does this topo match the rock?" — the community's confidence in a topo,
/// plus the control to add to it (community editing phase 4 / R-1).
///
/// Ungated like every other community fact: whether the drawn line is on the
/// right crack is an observation about the world, not an edit to the author's
/// work, so it needs nobody's approval and appears immediately.
///
/// Always rendered, unlike the hazard and access banners. Those two are
/// exceptions that must earn attention by staying quiet; this is a standing
/// affordance, and a topo with no verifications at all is exactly the one
/// where the prompt is most useful.
class VerificationTile extends ConsumerWidget {
  const VerificationTile({super.key, required this.wallId});

  final String wallId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MasiColors.of(context);
    final summary = ref
        .watch(wallVerificationSummaryProvider(wallId))
        .asData
        ?.value;

    final accurate = summary?.accurateCount ?? 0;
    final disputed = summary?.isDisputed ?? false;

    return Column(
      key: Key('verification-tile-$wallId'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            MasiIcon(
              disputed ? 'warning' : 'check',
              size: 16,
              color: disputed ? colors.gradeHard : colors.ink2,
            ),
            const SizedBox(width: MasiSpacing.xs),
            Expanded(
              child: Text(
                _summaryLabel(accurate, summary?.inaccurateCount ?? 0),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: disputed ? colors.gradeHard : colors.ink2,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: MasiSpacing.xs),
        // A Wrap, not a Row: two text buttons at a large text scale overflow a
        // narrow phone outright (a Row here overflowed by 172px in test), and
        // silently clipping half of "Doesn't match" would leave the control
        // unreadable rather than merely cramped.
        Wrap(
          spacing: MasiSpacing.sm,
          children: [
            TextButton(
              key: Key('verify-accurate-$wallId'),
              onPressed: () => _verify(context, ref, accurate: true),
              child: const Text('Matches the rock'),
            ),
            TextButton(
              key: Key('verify-inaccurate-$wallId'),
              onPressed: () => _verify(context, ref, accurate: false),
              child: const Text("Doesn't match"),
            ),
          ],
        ),
      ],
    );
  }

  /// Reads as a fact, not a score. "3 climbers confirmed this" is checkable;
  /// a percentage invites reading a 2/3 as a failing grade when it is really
  /// one person disagreeing.
  static String _summaryLabel(int accurate, int inaccurate) {
    if (accurate == 0 && inaccurate == 0) {
      return 'Nobody has confirmed this topo yet.';
    }
    final confirmed = accurate == 1
        ? '1 climber confirms this topo'
        : '$accurate climbers confirm this topo';
    if (inaccurate == 0) return '$confirmed.';
    final dispute = inaccurate == 1
        ? '1 says it does not match'
        : '$inaccurate say it does not match';
    return '$confirmed · $dispute.';
  }

  Future<void> _verify(
    BuildContext context,
    WidgetRef ref, {
    required bool accurate,
  }) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await ref
          .read(communityFactsServiceProvider)
          .verify(wallId: wallId, accurate: accurate);
      messenger?.showMasiToast(
        'Thanks — that helps.',
        kind: MasiToastKind.success,
      );
    } catch (error) {
      // Loud, not silent: there is no outbox behind this (D-4), so a failure
      // means nothing was recorded.
      messenger?.showMasiToast(
        'Could not record that. $error',
        kind: MasiToastKind.error,
      );
    }
  }
}
