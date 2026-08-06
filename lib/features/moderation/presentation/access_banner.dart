import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../shared/presentation/masi_icon.dart';
import '../application/moderation_providers.dart';
import '../domain/access_state.dart';

/// The access/closure notice for a topo (community editing phase 2 / R-2).
///
/// Renders nothing at all when nothing is stated, or when the crag is merely
/// confirmed open — a banner that is always present is a banner nobody reads,
/// and the one time it says "CLOSED" it has to land.
///
/// Deliberately shown on a topo the user can still open and read in full.
/// theCrag's reasoning (COMMUNITY_PLAN.md §3.6): a closed crag must stay
/// findable and prominently marked, because hiding it just sends climbers
/// exploring. Only `sensitive` removes a topo from view, and the SERVER does
/// that — by the time this widget could render, that content is already gone.
class AccessBanner extends ConsumerWidget {
  const AccessBanner({super.key, required this.wallId});

  final String wallId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final access = ref.watch(wallAccessProvider(wallId)).asData?.value;
    if (access == null || !access.warrantsNotice) {
      return const SizedBox.shrink();
    }
    return AccessNotice(access: access);
  }
}

/// The presentational half of [AccessBanner], taking a resolved value
/// directly — so it can be rendered from a list row that already has the
/// answer, and exercised in a widget test without a database.
class AccessNotice extends StatelessWidget {
  const AccessNotice({super.key, required this.access});

  final ResolvedAccess access;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final state = access.state;
    if (state == null || !state.warrantsNotice) {
      return const SizedBox.shrink();
    }

    // `closed` and `sensitive` use the hard-warning tint; `restricted` is a
    // softer advisory. Two tiers, not four: a climber scanning a page needs to
    // know "can I climb here or not", and a gradient of five ambers does not
    // answer that faster than two colours do.
    final isHard = state.severity >= AccessState.closed.severity;
    final tint = isHard ? colors.gradeHard : colors.accent;

    return Container(
      key: Key('access-notice-${state.wire}'),
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
          MasiIcon(isHard ? 'warning' : 'info', size: 18, color: tint),
          const SizedBox(width: MasiSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _headline(state),
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: tint,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (access.note != null && access.note!.trim().isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    access.note!,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: colors.ink),
                  ),
                ],
                // Names WHERE the restriction came from. Without this, a
                // closure inherited from the area reads as an unexplained
                // flag on a topo whose owner never set anything.
                if (access.sourceLabel != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    'Applies to ${access.sourceLabel}',
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
    );
  }

  static String _headline(AccessState state) => switch (state) {
    AccessState.closed => 'Closed to climbing',
    AccessState.sensitive => 'Sensitive location',
    AccessState.restricted => 'Access restrictions apply',
    AccessState.open => 'Open',
  };
}
