import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../shared/presentation/masi_icon.dart';
import '../../logbook/application/ascents_providers.dart';
import '../application/community_providers.dart';

/// Friendly themed error state for [CommunityMapScreen]/[CommunityFeedScreen]
/// when [sharedToposProvider] fails — replaces the earlier bare
/// `Text('Something went wrong: $error')`, which leaked the raw exception
/// string straight to the user, with a short screen-specific message plus a
/// "Try again" affordance that invalidates [sharedToposProvider] to retry
/// the fetch. Mirrors `topo_canvas_screen.dart`'s `_buildImageErrorState`
/// (icon + message + "Tinted" button per DESIGN.md "Buttons").
class CommunityErrorState extends ConsumerWidget {
  const CommunityErrorState({
    super.key,
    required this.stateKey,
    required this.retryKey,
    required this.message,
  });

  final Key stateKey;
  final Key retryKey;
  final String message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MasiColors.of(context);
    return Center(
      child: Column(
        key: stateKey,
        mainAxisSize: MainAxisSize.min,
        children: [
          MasiIcon('warning', size: 56, color: colors.gradeHard),
          const SizedBox(height: MasiSpacing.lg),
          Text(
            message,
            style: Theme.of(
              context,
            ).textTheme.bodyLarge?.copyWith(color: colors.gradeHard),
          ),
          const SizedBox(height: MasiSpacing.lg),
          // "Tinted" secondary button per DESIGN.md "Buttons": accent text
          // on a faint accent wash, matching `_buildImageErrorState`'s
          // "Choose another photo" button.
          Material(
            color: colors.accent.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(MasiRadii.control),
            child: InkWell(
              key: retryKey,
              onTap: () {
                ref.invalidate(sharedToposProvider);
                // Also invalidate the ascent half of the Feed's union (#12
                // Wave 3, ST5) — harmless no-op for `CommunityMapScreen`
                // (which never watches `sharedAscentsProvider` at all), and
                // means the Feed's "Try again" recovers BOTH halves of
                // `feedItemsProvider`, not just the topo one.
                ref.invalidate(sharedAscentsProvider);
              },
              borderRadius: BorderRadius.circular(MasiRadii.control),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: MasiSpacing.lg,
                  vertical: MasiSpacing.md,
                ),
                child: Text(
                  'Try again',
                  style: TextStyle(
                    color: colors.accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
