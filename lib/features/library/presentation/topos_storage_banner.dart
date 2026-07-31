part of 'topos_screen.dart';

/// Unmissable, non-dismissible warning pinned to the very top of the Topos
/// home whenever the connection layer reported a storage backend that cannot
/// keep data across a page load ([StorageDurability.isEphemeral] — in
/// practice [StorageBackend.inMemory], which drift documents as "doesn't
/// store anything").
///
/// This is the visible half of the L1 interlock (design doc
/// `docs/superpowers/specs/2026-07-30-web-offline-reliability-design.md`
/// §1a). The invisible half is `canCreate` in [ToposScreen.build] plus the
/// third guard in `_handleNewTopo`, which together disable BOTH create
/// affordances (`topos-new-topo` and the empty state's
/// `topos-empty-new-topo`) so nothing can be written into a store that will
/// drop it.
///
/// Deliberately NOT dismissible and deliberately NOT a [SnackBar]: the
/// condition is permanent for the lifetime of the page, and a transient toast
/// is exactly how the old `kDebugMode`-only `debugPrint` managed to hide
/// TOTAL data loss in production. Rendered above `_ToposFilterBar` rather
/// than inside an empty state so it is present in every list state, not just
/// the empty one.
///
/// The quieter third line names the backend and the missing browser features
/// verbatim so a "my data vanished" report is answerable from a screenshot
/// alone — the same values the release log line (`masi/storage: …`) carries.
class _StorageWarningBanner extends StatelessWidget {
  const _StorageWarningBanner({required this.durability});

  final StorageDurability durability;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final missing = durability.missingFeatures.map((f) => f.name).toList()
      ..sort();

    return Container(
      key: const Key('topos-storage-warning'),
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(
        MasiSpacing.lg,
        MasiSpacing.md,
        MasiSpacing.lg,
        0,
      ),
      padding: const EdgeInsets.all(MasiSpacing.md),
      decoration: BoxDecoration(
        color: colors.gradeHard.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(MasiRadii.card),
        border: Border.all(color: colors.gradeHard),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MasiIcon('warning', size: 22, color: colors.gradeHard),
          const SizedBox(width: MasiSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "This browser can't save your topos",
                  style: textTheme.titleMedium?.copyWith(
                    color: colors.ink,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: MasiSpacing.xs),
                Text(
                  'Storage is blocked here, so anything you create would be '
                  'lost the moment this page reloads. Creating topos is '
                  'turned off until storage works. Private browsing and '
                  'blocked site data are the usual causes — try a normal '
                  'window, or install the app to your home screen.',
                  style: textTheme.bodyMedium?.copyWith(color: colors.ink2),
                ),
                const SizedBox(height: MasiSpacing.sm),
                Text(
                  'Storage: ${durability.backend?.name ?? 'unknown'}'
                  '${missing.isEmpty ? '' : ' · missing: ${missing.join(', ')}'}',
                  key: const Key('topos-storage-warning-detail'),
                  style: textTheme.labelSmall?.copyWith(color: colors.ink3),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
