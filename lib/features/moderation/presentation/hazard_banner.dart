import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../shared/presentation/masi_icon.dart';
import '../application/community_facts_providers.dart';
import '../domain/community_facts.dart';

/// The safety notice for a topo (community editing phase 4 / R-1).
///
/// Renders nothing when there is no OUTSTANDING hazard — a banner that is
/// always present is a banner nobody reads, and the one time it says "bolt 2
/// spins" it has to land. Resolved reports are still reachable through the
/// list behind it, because "reported and dealt with" is a different and more
/// reassuring statement than "nothing ever reported".
///
/// Note what this is not gated on: the topo owner's approval. A hazard is a
/// fact about the world rather than the author's creative work (R-1), and it
/// appears the moment it is filed.
class HazardBanner extends ConsumerWidget {
  const HazardBanner({super.key, required this.wallId, this.onTap});

  final String wallId;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(wallHazardSummaryProvider(wallId)).asData?.value;
    if (summary == null || !summary.hasUnresolved) {
      return const SizedBox.shrink();
    }
    return HazardNotice(summary: summary, onTap: onTap);
  }
}

/// The presentational half of [HazardBanner], taking a resolved value
/// directly — so it can be rendered from a row that already has the answer,
/// and exercised in a widget test without a database.
class HazardNotice extends StatelessWidget {
  const HazardNotice({super.key, required this.summary, this.onTap});

  final HazardSummary summary;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final worst = summary.worst;
    if (worst == null) return const SizedBox.shrink();

    // Two tiers, matching AccessNotice: `danger` is a hard warning, everything
    // milder is a soft advisory. A climber scanning a page needs "is this
    // going to hurt me or not", and a gradient of three ambers does not answer
    // that faster than two colours do.
    final tint = worst.isUrgent ? colors.gradeHard : colors.accent;
    final count = summary.unresolvedCount;

    return Semantics(
      button: onTap != null,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          key: Key('hazard-notice-${worst.wire}'),
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
              MasiIcon('warning', size: 18, color: tint),
              const SizedBox(width: MasiSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _headline(worst, count),
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: tint,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (onTap != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        count == 1 ? 'Tap to read it' : 'Tap to read them',
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: colors.ink2),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _headline(HazardSeverity worst, int count) {
    final noun = count == 1 ? 'hazard' : 'hazards';
    return switch (worst) {
      HazardSeverity.danger => count == 1
          ? 'Danger reported'
          : '$count hazards reported, one dangerous',
      HazardSeverity.caution => '$count $noun reported — take care',
      HazardSeverity.note => '$count $noun reported',
    };
  }
}
