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
/// The quieter third line names the backend, the missing browser features and
/// — when the open itself failed — the reason verbatim, so a "my data
/// vanished" report is answerable from a screenshot alone. Those are the same
/// values the release log line (`masi/storage: …`) carries.
///
/// **Three cases, because [StorageDurability.isEphemeral] covers situations
/// that mean opposite things to the user** (see [StorageUnavailableCause]):
///
///  1. [StorageUnavailableCause.schemaDowngrade] — an older shell refused a
///     newer database (L7). The data is provably INTACT; the guard throws
///     before drift can renumber or migrate anything. Telling this user their
///     topos can't be saved would be a false alarm about their climbing
///     records, so this case leads with "safe" and asks for an app update.
///     It is also the only case that is not the browser's fault, so it gets
///     the action accent and the `restart` glyph rather than danger red.
///  2. [StorageUnavailableCause.failed] — the open or first query threw for an
///     unclassified reason. Nothing was deliberately deleted, but nothing is
///     promised either; the reason string carries the detail.
///  3. A chosen-but-non-durable backend (in practice
///     [StorageBackend.inMemory]). The ORIGINAL §1a copy, kept verbatim — it
///     is correct for exactly this case, where private browsing and blocked
///     site data really are the usual causes.
///
/// All three keep the same interlock: the banner is only rendered when
/// creation is already disabled.
class _StorageWarningBanner extends StatelessWidget {
  const _StorageWarningBanner({required this.durability});

  final StorageDurability durability;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final missing = durability.missingFeatures.map((f) => f.name).toList()
      ..sort();

    final isDowngrade =
        durability.unavailableCause == StorageUnavailableCause.schemaDowngrade;

    final String title;
    final String body;
    final String glyph;
    final Color tone;
    if (isDowngrade) {
      glyph = 'restart';
      // Not `gradeHard`: red reads as "your data is in danger", which is the
      // one thing that is NOT true here.
      tone = colors.accent;
      title = 'Your topos are safe — this app needs updating';
      body =
          'This copy of the app is older than the data saved on this device, '
          "so it won't open your library rather than risk damaging it. "
          'Nothing has been lost. Reload to pick up the current version — if '
          "you're offline, reconnect first, because the reload has to fetch "
          'it.';
    } else if (durability.unavailable) {
      glyph = 'warning';
      tone = colors.gradeHard;
      title = "Can't open your saved topos";
      body =
          "The app couldn't open this device's local storage, so your library "
          "can't be shown and creating topos is turned off until it works. "
          'Your saved topos have not been deleted — reload to try again, and '
          'if it keeps happening the detail below is what to report.';
    } else {
      glyph = 'warning';
      tone = colors.gradeHard;
      title = "This browser can't save your topos";
      body =
          'Storage is blocked here, so anything you create would be lost the '
          'moment this page reloads. Creating topos is turned off until '
          'storage works. Private browsing and blocked site data are the '
          'usual causes — try a normal window, or install the app to your '
          'home screen.';
    }

    // `unavailable` means no backend was ever chosen, so `backend?.name` is
    // null — but "unknown" was a lie while we were holding a real reason
    // string. Name the state the way the release log line does, and append
    // the reason, which is the single most useful line in a field report.
    final detail = StringBuffer(
      'Storage: '
      '${durability.backend?.name ?? (durability.unavailable ? 'unavailable' : 'probing')}',
    );
    if (missing.isNotEmpty) {
      detail.write(' · missing: ${missing.join(', ')}');
    }
    if (durability.unavailableReason != null) {
      detail.write(' · ${durability.unavailableReason}');
    }

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
        color: tone.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(MasiRadii.card),
        border: Border.all(color: tone),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MasiIcon(glyph, size: 22, color: tone),
          const SizedBox(width: MasiSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  key: const Key('topos-storage-warning-title'),
                  style: textTheme.titleMedium?.copyWith(
                    color: colors.ink,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: MasiSpacing.xs),
                Text(
                  body,
                  key: const Key('topos-storage-warning-body'),
                  style: textTheme.bodyMedium?.copyWith(color: colors.ink2),
                ),
                const SizedBox(height: MasiSpacing.sm),
                Text(
                  detail.toString(),
                  key: const Key('topos-storage-warning-detail'),
                  // An `unavailableReason` is an exception's `toString()` and
                  // can be a paragraph (the L7 one is). Unbounded, it makes
                  // this banner tall enough to squeeze whatever the list area
                  // renders below it. Capped here rather than shortened at the
                  // source: the release log line (`masi/storage: …`) still
                  // carries the value in full, and for the downgrade case the
                  // body copy above already says the same thing in plain
                  // language.
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
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
