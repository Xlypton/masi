import 'package:flutter/material.dart';

import '../../app/theme.dart';
import 'masi_icon.dart';

/// What a [SyncBanner] is telling the user, and therefore which sentence and
/// which tone it renders.
///
/// The three are deliberately NOT collapsed into one "something's wrong"
/// state: they call for different reactions. [offline] is reassurance — the
/// data is on the device, nothing is lost, keep climbing. [syncFailed] is a
/// fault report with a reason worth reading and an action worth taking.
/// [sharedPhotosWithheld] is neither — nothing failed and nothing needs a
/// retry, it just explains a blank spot the user would otherwise have no way
/// to account for.
enum SyncBannerKind {
  /// A reachability probe has completed and FAILED
  /// (`Reachability.isKnownOffline` — never `unknown`, see
  /// `reachability_providers.dart`). The list below is the on-device cache
  /// and will not refresh until the network returns.
  offline,

  /// The app can reach the backend, but the most recent pull reported a
  /// problem (`SyncOrchestratorState.lastPullError`). Carries the reason
  /// verbatim in [SyncBanner.detail].
  syncFailed,

  /// The most recent pull SUCCEEDED, but downloaded ZERO other climbers'
  /// photo bytes because this device is over the storage-pressure watermark
  /// (`SyncOrchestratorState.lastSharedPhotoBudgetReason ==
  /// SharedPhotoBudgetReason.storagePressure` — see `sync_service.dart`).
  ///
  /// #49 P2 fix: before this kind existed, that fact was computed on every
  /// pull and then read by nothing outside `sync_service.dart` — the user
  /// just saw the Community feed fill up with placeholders, with no banner,
  /// no empty state, and no explanation anywhere in the app.
  sharedPhotosWithheld,
}

/// The one sync/offline banner both feeds render — Library
/// (`topos_screen.dart`) and Community Feed (`community_feed_screen.dart`).
///
/// **Why this is public and lives in `shared/presentation/` rather than being
/// a `part of topos_screen.dart`:** the Community Feed is a separate library
/// that does not (and should not) import the Library screen, so a
/// library-private `_SyncBanner` could not be reached from it at all, and
/// reaching across features for one would invert this repo's layering. It
/// sits next to `masi_icon.dart`/`masi_shimmer.dart`, the other
/// cross-feature presentation primitives.
///
/// **Why it renders ABOVE the list rather than inside an empty state.** Both
/// feeds used to surface a sync problem only in their `isEmpty` branch
/// (`topos_screen.dart`'s `proximityEntries.isEmpty`,
/// `community_feed_screen.dart`'s `items.isEmpty && syncError != null`), so
/// the user who had the most to lose — the one WITH topos — got no signal
/// whatsoever. Offline at a crag, they would watch a list quietly fail to
/// refresh and conclude the app had eaten their work. This banner is what
/// prevents that conclusion, so it must render irrespective of how much is
/// in the list.
///
/// The copy is derived from [kind] here rather than passed in, so the two
/// call sites cannot drift into two subtly different sentences: there is
/// exactly one offline string in the app ([offlineMessage]) and one
/// sync-failure shape, both asserted in `sync_banner_test.dart`.
///
/// Visually a quieter sibling of `topos_storage_banner.dart`'s
/// `_StorageWarningBanner` — same margin/padding/radius/tinted-border recipe,
/// so a screen showing both reads as one stack of notices rather than two
/// unrelated designs.
class SyncBanner extends StatelessWidget {
  const SyncBanner({super.key, required this.kind, this.detail, this.onRetry});

  /// The single offline sentence used app-wide. Exposed as a constant so a
  /// consumer or a test can assert against the exact string instead of
  /// re-typing it (and so the em dash cannot be silently retyped as a
  /// hyphen at one of the two call sites).
  static const String offlineMessage =
      "You're offline — showing your saved topos.";

  /// The single [SyncBannerKind.sharedPhotosWithheld] sentence used app-wide
  /// — same "one agreed string, asserted verbatim" reasoning as
  /// [offlineMessage]. Deliberately does not name a byte count or a fraction:
  /// those numbers move every pull and would make this read like a progress
  /// readout rather than an explanation.
  static const String sharedPhotosWithheldMessage =
      "This device is low on storage, so other climbers' photos aren't "
      'downloading right now.';

  final SyncBannerKind kind;

  /// The failure reason for [SyncBannerKind.syncFailed] — in practice
  /// `SyncOrchestratorState.lastPullError` verbatim, which
  /// `SyncOrchestrator._runPull` has already formatted as
  /// `'Sync failed: <PullResult.errors text>'`, so the real fault is
  /// readable on-device without a debugger (#72).
  ///
  /// IGNORED for [SyncBannerKind.offline] and
  /// [SyncBannerKind.sharedPhotosWithheld]: a stale pull error from before
  /// the signal dropped is not what an offline user needs to read, and
  /// pasting a raw `SocketException` under "you're offline" turns
  /// reassurance back into alarm; [sharedPhotosWithheldMessage] is likewise a
  /// fixed sentence that does not take a detail.
  final String? detail;

  /// Optional action. `null` renders no button — correct for the offline
  /// case, where there is nothing useful to press and the honest advice is
  /// simply to wait for signal.
  final VoidCallback? onRetry;

  /// The most of the viewport this banner may ever occupy.
  ///
  /// Expressed as a SHARE of the viewport rather than a pixel ceiling for the
  /// same reason `topos_storage_banner.dart`'s `_StorageWarningBanner` is (see
  /// its `_maxViewportShare` doc, which this mirrors deliberately): the
  /// invariant that matters is "the list stays reachable", which is a statement
  /// about the screen, not about a number of logical pixels. Any absolute cap
  /// would be right on one device and wrong at the next text scale.
  ///
  /// [detail] is `SyncOrchestratorState.lastPullError` — an exception's
  /// `toString()`, which can be a paragraph. The `maxLines` cap below bounds it
  /// in LINES, and a line is not a fixed height: MEASURED, a real host-lookup
  /// failure at a 3.0x accessibility text scale on a 400x420 surface made this
  /// banner 407 px tall, leaving the list 13 px — and at 4.0x it overflowed the
  /// column outright. That is the same shape as the failure the storage banner
  /// already fixed. A share of the viewport is the only cap that holds in both
  /// directions.
  ///
  /// Content that does not fit SCROLLS inside the banner rather than being
  /// truncated, so the sentence's beginning — the part that says what happened
  /// — stays put and the reason is what leaves the visible area first.
  static const double _maxViewportShare = 0.4;

  /// How many lines of [messageFor]'s sentence are shown before it ellipsizes.
  static const int _detailMaxLines = 3;

  /// The exact sentence [kind]/[detail] renders, without building a widget.
  static String messageFor(SyncBannerKind kind, [String? detail]) =>
      switch (kind) {
        SyncBannerKind.offline => offlineMessage,
        SyncBannerKind.syncFailed =>
          detail == null ? "Couldn't sync." : "Couldn't sync — $detail.",
        SyncBannerKind.sharedPhotosWithheld => sharedPhotosWithheldMessage,
      };

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;

    // Never `gradeHard` for offline or sharedPhotosWithheld: red is the
    // app's "your data is in danger" tone. Being out of signal at a crag is
    // the one situation where that is emphatically not true (reassurance,
    // not alarm), and withheld shared photos is likewise not a fault — the
    // pull succeeded, the user's own data is untouched, and nothing here
    // needs a retry. Only [SyncBannerKind.syncFailed] is a genuine fault
    // report. `phone_off` is the closest glyph in `assets/icons/masi/` to "no
    // connection" (a device with a strike through it); the set carries no
    // wifi/cloud-off/storage variant, so `sharedPhotosWithheld` reuses
    // `warning` — advisory, not alarming, same as its tone.
    final tone = switch (kind) {
      SyncBannerKind.offline => colors.accent,
      SyncBannerKind.syncFailed => colors.gradeHard,
      SyncBannerKind.sharedPhotosWithheld => colors.accent,
    };
    final glyph = switch (kind) {
      SyncBannerKind.offline => 'phone_off',
      SyncBannerKind.syncFailed => 'warning',
      SyncBannerKind.sharedPhotosWithheld => 'warning',
    };

    return Container(
      key: const Key('sync-banner'),
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
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * _maxViewportShare,
        ),
        child: SingleChildScrollView(
          child: _body(colors, textTheme, tone, glyph),
        ),
      ),
    );
  }

  Widget _body(
    MasiColors colors,
    TextTheme textTheme,
    Color tone,
    String glyph,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MasiIcon(glyph, size: 22, color: tone),
        const SizedBox(width: MasiSpacing.md),
        // The retry button lives INSIDE this Expanded column rather than as
        // a third Row child: as a Row sibling it keeps its intrinsic width
        // at every text scale, and at 3.0x on a 320pt phone that is enough
        // to squeeze the message column into a horizontal overflow.
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                liveRegion: true,
                child: Text(
                  messageFor(kind, detail),
                  key: const Key('sync-banner-message'),
                  // A reason is an exception's `toString()` and can be a
                  // paragraph. Capped for the same reason
                  // `_StorageWarningBanner` caps its detail line: unbounded,
                  // it makes this banner tall enough to squeeze whatever the
                  // list area renders below it. The line cap is the first
                  // of two — see [_maxViewportShare] for why a line count
                  // alone is not a height bound.
                  maxLines: _detailMaxLines,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodyMedium?.copyWith(color: colors.ink2),
                ),
              ),
              if (onRetry != null) ...[
                const SizedBox(height: MasiSpacing.xs),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    key: const Key('sync-banner-retry'),
                    onPressed: onRetry,
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text(
                      'Retry',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
