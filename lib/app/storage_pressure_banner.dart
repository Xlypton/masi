import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/topo/application/community_photo_clear_controller.dart';
import '../shared/presentation/masi_dialogs.dart';
import '../shared/presentation/masi_icon.dart';
import 'theme.dart';

/// Proactive "storage is nearly full" notice, shown BEFORE the failing
/// import it warns about — task #51 (deferred P3 of #49).
///
/// #49's P1/P2 fixes made `PublicPhotoPruneService`'s per-pull outcome
/// observable (`SyncOrchestratorState.lastPublicPhotoPruneOutcome`) and
/// explained a downloaded-nothing pull, but neither one told the user
/// anything BEFORE the moment their own next photo import throws
/// `PhotoWriteException(quotaExceeded)` — discovered at the worst possible
/// time, mid-import, with the topo they were trying to save on the line.
///
/// This banner closes that gap using the exact signal #49 P1 already wired
/// up: [PublicPhotoPruneOutcome.automaticReliefExhausted] is true precisely
/// when a pull's prune pass ended STILL over the high watermark with nothing
/// further it is automatically permitted to delete (see that getter's doc for
/// the two reasons, and `CLAUDE.md`'s #46 note for the confirmed cold-device
/// terminal case: `kSharedPhotoByteBudgetPerPull == kPruneKeepNewestForeign`
/// means the very FIRST pull can already land here). At that point the only
/// remaining lever is this banner's manual "Clear cached photos" action,
/// which — uniquely among everything in `public_photo_prune_service.dart` —
/// is allowed to evict the [kPruneKeepNewestForeign] floor of newest foreign
/// photos that automatic pruning always protects.
///
/// Lives in `lib/app/` and is wired into [ShellNotices]
/// (`nav_shell.dart`) rather than into `SyncBanner`
/// (`lib/shared/presentation/sync_banner.dart`), for two reasons: storage
/// pressure is not specific to the Topos/Feed screens `SyncBanner` serves,
/// and this feature's brief deliberately routes new shell-level notices
/// through the `StorageRetryBanner`/`ShellNotices` pattern instead of
/// growing a second `SyncBannerKind`. [ShellNotices] ranks this below
/// [StorageRetryBanner] (an unopenable database is the more urgent fault) and
/// above the install prompt — the same one-notice-at-a-time slot every other
/// shell notice already shares.
///
/// Visually a `gradeHard`-toned sibling of `StorageRetryBanner`, deliberately
/// NOT the quieter `accent` tone `SyncBanner` uses for `sharedPhotosWithheld`:
/// that condition is a harmless "some placeholders" cosmetic fact, while this
/// one is a real, near-term risk to the user's OWN unsaved work.
class StoragePressureBanner extends ConsumerWidget {
  const StoragePressureBanner({super.key});

  /// The one agreed sentence, exposed as a constant for the same reason
  /// `SyncBanner.offlineMessage` is: so a test can assert the exact string
  /// rather than re-typing it. Deliberately does not name a byte count or
  /// fraction — those move on every pull and would read as a progress
  /// readout, not an explanation (same reasoning as
  /// `SyncBanner.sharedPhotosWithheldMessage`).
  static const String message =
      "Storage is nearly full, and there's nothing left this app can free up "
      "on its own. You can clear other climbers' cached photos to make room "
      '— your own photos are never touched.';

  /// The confirmation dialog's body — spelled out in full here (rather than
  /// folded into [message]) because consent has to be INFORMED: what gets
  /// deleted, that it is recoverable (a re-download, not data loss), and the
  /// one guarantee that must survive the reader's worry — their own photos.
  static const String confirmBody =
      "This deletes other climbers' photos cached on this device to free up "
      "space. They'll simply re-download the next time you view them online "
      '— nothing is lost there. Your own photos are never touched.';

  /// Same reasoning as `SyncBanner._maxViewportShare` /
  /// `_StorageWarningBanner._maxViewportShare`: a SHARE of the viewport,
  /// never an absolute pixel cap, because the invariant is "the tab content
  /// stays reachable" and that is a statement about the screen, not a fixed
  /// number of logical pixels. #26/#30 were both exactly this shape of bug —
  /// an unbounded-height banner that starved the content beneath it — and
  /// `storage_pressure_banner_test.dart`'s "the height cap" group pins this
  /// cap so it cannot recur a third time.
  static const double _maxViewportShare = 0.4;

  /// Lines of [message] shown before it ellipsizes — [message] is fixed and
  /// short, but the cap is still asserted (see the layout test) because
  /// [_maxViewportShare] alone is not a height bound at a large accessibility
  /// text scale, exactly as `SyncBanner`/`_StorageWarningBanner` document.
  static const int _messageMaxLines = 4;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final clearing =
        ref.watch(communityPhotoClearProvider) ==
        CommunityPhotoClearStatus.clearing;

    return SafeArea(
      // Same "topmost widget in the shell body owns the inset" contract as
      // `StorageRetryBanner` — see that class's doc.
      top: true,
      bottom: false,
      child: Padding(
        // `lg` sides to match the screen-level notices (`SyncBanner`,
        // `_StorageWarningBanner`, `MasiAsyncView`'s stale-error bar), all of
        // which inset by `fromLTRB(lg, md, lg, 0)`. This banner is already
        // documented as a visual sibling of those, and at 12px it sat 4px
        // wider on each side than the notice it could be stacked directly
        // above. Horizontal only — the `md` top keeps the same vertical
        // rhythm.
        padding: const EdgeInsets.fromLTRB(
          MasiSpacing.lg,
          MasiSpacing.md,
          MasiSpacing.lg,
          0,
        ),
        child: Container(
          key: const Key('storage-pressure-banner'),
          padding: const EdgeInsets.all(MasiSpacing.md),
          decoration: BoxDecoration(
            // `gradeHard`, not `accent`: unlike `sharedPhotosWithheld` this is
            // a genuine near-term risk to the user's OWN unsaved work (their
            // next own-photo import is one write away from throwing).
            color: colors.gradeHard.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(MasiRadii.card),
            border: Border.all(color: colors.gradeHard),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * _maxViewportShare,
            ),
            child: SingleChildScrollView(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  MasiIcon('warning', size: 22, color: colors.gradeHard),
                  const SizedBox(width: MasiSpacing.md),
                  // The button lives INSIDE this column rather than as a
                  // third Row child — same reasoning as `SyncBanner`'s
                  // identical layout: as a Row sibling it keeps its
                  // intrinsic width at every text scale, and at a large
                  // accessibility scale on a narrow phone that is enough to
                  // squeeze the message column into a horizontal overflow.
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Semantics(
                          liveRegion: true,
                          child: Text(
                            message,
                            key: const Key('storage-pressure-banner-message'),
                            maxLines: _messageMaxLines,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.bodyMedium?.copyWith(
                              color: colors.ink2,
                            ),
                          ),
                        ),
                        const SizedBox(height: MasiSpacing.xs),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton(
                            key: const Key('storage-pressure-banner-clear'),
                            // Disabled while a clear is in flight, for the
                            // same reason `StorageRetryBanner`'s action is: a
                            // second tap mid-clear would be a no-op the user
                            // reads as a dead button.
                            onPressed: clearing
                                ? null
                                : () => _confirmAndClear(context, ref),
                            style: TextButton.styleFrom(
                              padding: EdgeInsets.zero,
                              // 44x44, not `Size.zero` — the iOS HIG minimum
                              // tap target (same recipe as
                              // `topo_canvas_screen.dart`'s
                              // `_topRowIconStyle`). `shrinkWrap` below opts
                              // OUT of Material's padded 48x48 hit area, so
                              // at `Size.zero` the tappable region really was
                              // the ~20pt label box and nothing more.
                              minimumSize: const Size(44, 44),
                              // Kept deliberately: the footprint should be
                              // exactly `minimumSize`, not Material's larger
                              // default. Only the minimum size changes here.
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: Text(
                              clearing ? 'Clearing…' : 'Clear cached photos',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The explicit-consent gate. NOTHING calls
  /// [CommunityPhotoClearController.clear] except the `onPressed` below the
  /// `true` return of this dialog — a cancelled or dismissed dialog (`false`
  /// or `null`, e.g. a barrier tap or the back gesture) returns without ever
  /// touching the controller, so no bytes are deleted.
  Future<void> _confirmAndClear(BuildContext context, WidgetRef ref) async {
    final confirmed = await showMasiConfirm(
      context,
      title: 'Clear cached community photos?',
      message: confirmBody,
      confirmLabel: 'Clear',
      confirmKey: const Key('storage-pressure-clear-confirm'),
      cancelKey: const Key('storage-pressure-clear-cancel'),
      sheetKey: const Key('storage-pressure-clear-dialog'),
    );
    if (!confirmed) return;

    final controller = ref.read(communityPhotoClearProvider.notifier);
    await controller.clear();
    if (!context.mounted) return;

    final status = ref.read(communityPhotoClearProvider);
    final outcome = controller.lastOutcome;
    final message = status == CommunityPhotoClearStatus.failed || outcome == null
        ? "Couldn't clear cached photos — try again."
        : outcome.clearedKeys.isEmpty
        ? 'Nothing to clear.'
        : 'Cleared ${outcome.clearedKeys.length} cached '
              '${outcome.clearedKeys.length == 1 ? 'photo' : 'photos'}.';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}
