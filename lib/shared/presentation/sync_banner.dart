import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import 'bottom_safe_inset.dart';
import 'masi_icon.dart';
import 'masi_pending_button.dart';

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
/// **Why it renders irrespective of what the list contains.** Both feeds used
/// to surface a sync problem only in their `isEmpty` branch
/// (`topos_screen.dart`'s `proximityEntries.isEmpty`,
/// `community_feed_screen.dart`'s `items.isEmpty && syncError != null`), so
/// the user who had the most to lose — the one WITH topos — got no signal
/// whatsoever. Offline at a crag, they would watch a list quietly fail to
/// refresh and conclude the app had eaten their work. This banner is what
/// prevents that conclusion.
///
/// **It is rendered as the FIRST SLIVER of each feed's scroll view, never as
/// item 0 of the data list.** Those are not the same thing and the difference
/// is the whole bug above: a header baked into the list disappears the moment
/// the list is empty, which is exactly the offline-at-a-crag case. Both call
/// sites therefore put it in a scroll view that also hosts their empty states
/// (`community_feed_screen.dart`'s `CustomScrollView`, `topos_screen.dart`'s
/// `NestedScrollView` header), so it survives every empty state AND scrolls
/// out of the way once read — which is what stopped it from permanently
/// costing 1.4 topo rows of a 390x844 phone (MEASURED: with it, the first row
/// started 31% down the screen instead of 14.7%; at 1.8x text scale, 42.9%).
///
/// **One collapsed line, plus a details disclosure.** The line says what
/// happened; the ⓘ opens a sheet with the FULL text and a copy action. Two
/// problems, one fix: the height, and the fact that [detail] is an exception's
/// `toString()` — the truncated `…uri=https://mnaipcqbkqzffgvx…` a climber saw
/// was useless to them AND useless in a bug report, whereas the whole string
/// is genuinely worth having. The disclosure is offered for EVERY kind, not
/// just the failure one: at a large accessibility text scale a one-line
/// sentence ellipsizes hard, and the sheet is then the only way to read it.
///
/// The copy is derived from [kind] here rather than passed in, so the two
/// call sites cannot drift into two subtly different sentences: there is
/// exactly one offline string in the app ([offlineMessage]) and one
/// sync-failure shape, both asserted in `sync_banner_test.dart`.
///
/// Visually a quieter sibling of `topos_storage_banner.dart`'s
/// `_StorageWarningBanner` — same margin/radius/tinted-border recipe, so a
/// screen showing both reads as one stack of notices rather than two unrelated
/// designs.
class SyncBanner extends StatelessWidget {
  const SyncBanner({
    super.key,
    required this.kind,
    this.detail,
    this.onRetry,
    this.onDismiss,
  });

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

  /// The [SyncBannerKind.syncFailed] headline, WITHOUT the reason.
  ///
  /// The reason lives in the details sheet ([messageFor]) instead of on the
  /// banner: it is an exception `toString()` that ran to three lines and
  /// ~122 px on a real phone, and the part of it that fit was a half-printed
  /// backend URL.
  static const String syncFailedHeadline = "Couldn't sync";

  final SyncBannerKind kind;

  /// The failure reason for [SyncBannerKind.syncFailed] — in practice
  /// `SyncOrchestratorState.lastPullError` verbatim, which
  /// `SyncOrchestrator._runPull` has already formatted as
  /// `'Sync failed: <PullResult.errors text>'`, so the real fault is
  /// readable on-device without a debugger (#72).
  ///
  /// Reachable through the details disclosure rather than printed on the
  /// banner — see the class doc.
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
  ///
  /// A `Future`, and rendered as a [MasiPendingButton], because the round trip
  /// it starts is a real one. As a plain `VoidCallback` on a bare [TextButton]
  /// — which is what this was — both call sites discarded the returned future
  /// and this widget read only [detail], so NOTHING on screen changed for the
  /// entire pull and the button read as dead. (The user's own report that
  /// Retry "usually" works is what an invisible retry feels like.) Same
  /// reasoning, same widget, as `topos_empty_states.dart`'s retry.
  final Future<void> Function()? onRetry;

  /// Optional "close this" action, rendered as a trailing close button.
  ///
  /// **HONOURED FOR EVERY [SyncBannerKind].** That is a deliberate reversal of
  /// this widget's previous rule, which made the close button structurally
  /// impossible for [SyncBannerKind.syncFailed] and
  /// [SyncBannerKind.sharedPhotosWithheld] on the grounds that "a closable
  /// version of it is how silent data loss becomes invisible". Do not restore
  /// that: it was the user's explicit decision to reverse it, and the old
  /// justification did not survive checking, on three counts.
  ///
  ///  1. **It was factually wrong about what this banner reports.** The
  ///     [detail] both call sites pass is `lastPullError`, which is PULL-only.
  ///     A failed PUSH — the case where the user's own work may genuinely not
  ///     have reached the cloud — never sets it (`sync_orchestrator.dart` says
  ///     so explicitly); push failures surface on the Account screen. So this
  ///     banner was never the "only signal that your work may be lost" it
  ///     claimed to be.
  ///  2. **Undismissable is not the same as noticed.** A notice that cannot be
  ///     closed and cannot be scrolled away is one the user learns to read
  ///     past, at the cost of 1.4 topo rows on every frame.
  ///  3. **Nothing is actually forgotten.** The dismissal is scoped to the
  ///     CURRENT error identity (see `offline_banner_dismissal.dart`), so a
  ///     different failure — or the same condition after a genuine state
  ///     change — re-arms the banner and shows it again. Acknowledging today's
  ///     deferred-rows message cannot suppress tomorrow's real one.
  ///
  /// The caller (both feeds) resolves this against
  /// `syncBannerDismissalProvider`; see that provider's doc for why the
  /// re-arming reset is not optional.
  ///
  /// `null` renders no close button at all.
  final VoidCallback? onDismiss;

  /// The most of the viewport this banner may ever occupy.
  ///
  /// Expressed as a SHARE of the viewport rather than a pixel ceiling for the
  /// same reason `topos_storage_banner.dart`'s `_StorageWarningBanner` is (see
  /// its `_maxViewportShare` doc, which this mirrors deliberately): the
  /// invariant that matters is "the list stays reachable", which is a statement
  /// about the screen, not about a number of logical pixels. Any absolute cap
  /// would be right on one device and wrong at the next text scale.
  ///
  /// Tightened from 0.4 to 0.25 when the body collapsed to a single line. The
  /// old number was sized for a three-line block that could legitimately need
  /// that much room; one line cannot, and 0.4 stopped being a cap and became
  /// permission. What it now guards is the case this screen actually has: a
  /// shell-level notice (`storage_retry_banner.dart`) stacked above this one.
  /// At 0.4 apiece those two could between them claim 80% of the viewport and
  /// leave the list a sliver; at 0.25 the pair is bounded well below that.
  ///
  /// Content that does not fit SCROLLS inside the banner rather than being
  /// truncated, so the sentence's beginning — the part that says what happened
  /// — stays put. [ClampingScrollPhysics] specifically: with nothing to scroll
  /// (the normal case) it declines the drag, so the banner cannot swallow the
  /// gesture that is trying to scroll the FEED it sits in.
  static const double _maxViewportShare = 0.25;

  /// The text scale above which [onRetry]'s button drops to its own line
  /// beneath the message, instead of riding beside it.
  ///
  /// A LABELLED button keeps its intrinsic width at every text scale, and on a
  /// narrow phone that width alone is enough to squeeze the message into a
  /// horizontal overflow even though the message is [Expanded] and already
  /// ellipsizing — MEASURED, not predicted: `RenderFlex overflowed by 78
  /// pixels` at 3.0x on a 320 px phone. `storage_pressure_banner.dart` solves
  /// exactly this by putting its action UNDER its message unconditionally
  /// (its own comment names this banner while doing so); the difference here
  /// is that being one line is this banner's entire purpose, so it pays that
  /// second line only once one line has genuinely stopped fitting.
  ///
  /// The icon-only controls (the ⓘ and the close button) never move, at any
  /// scale: they are sized in logical pixels, do not text-scale, and so cannot
  /// cause this. Only the word "Retry" can.
  static const double _stackedRetryTextScale = 1.5;

  /// The exact sentence [kind]/[detail] renders IN FULL — headline and reason
  /// both. This is what the details sheet shows and what its copy action puts
  /// on the clipboard; the banner itself shows [collapsedMessageFor].
  static String messageFor(SyncBannerKind kind, [String? detail]) =>
      switch (kind) {
        SyncBannerKind.offline => offlineMessage,
        SyncBannerKind.syncFailed =>
          detail == null
              ? '$syncFailedHeadline.'
              : '$syncFailedHeadline — $detail.',
        SyncBannerKind.sharedPhotosWithheld => sharedPhotosWithheldMessage,
      };

  /// The ONE line the banner itself renders.
  ///
  /// Identical to [messageFor] for the two fixed-sentence kinds — there is
  /// nothing to collapse, they carry no exception text — and the reason-free
  /// headline for [SyncBannerKind.syncFailed], whose reason is exactly the
  /// unbounded part.
  static String collapsedMessageFor(SyncBannerKind kind) => switch (kind) {
    SyncBannerKind.offline => offlineMessage,
    SyncBannerKind.syncFailed => syncFailedHeadline,
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
      // Vertical padding is `sm`, not the old uniform `md`: the body is one
      // line of text beside icon-sized controls now, and 2 x 12 px of padding
      // around it is most of the box.
      padding: const EdgeInsets.symmetric(
        horizontal: MasiSpacing.md,
        vertical: MasiSpacing.sm,
      ),
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
          physics: const ClampingScrollPhysics(),
          child: _body(context, colors, textTheme, tone, glyph),
        ),
      ),
    );
  }

  Widget _body(
    BuildContext context,
    MasiColors colors,
    TextTheme textTheme,
    Color tone,
    String glyph,
  ) {
    // See [_stackedRetryTextScale]: one line as long as one line fits, the
    // house two-line shape once it does not.
    final stackRetry =
        onRetry != null &&
        MediaQuery.textScalerOf(context).scale(1) > _stackedRetryTextScale;

    // The VISIBLE text is the collapsed line; the SPOKEN text is the full one.
    // A screen-reader user has no ⓘ-sized affordance for "read the rest", so
    // handing them the truncated headline would be the one place this redesign
    // actually lost information.
    final message = Semantics(
      liveRegion: true,
      label: messageFor(kind, detail),
      child: ExcludeSemantics(
        child: Text(
          collapsedMessageFor(kind),
          key: const Key('sync-banner-message'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: textTheme.bodyMedium?.copyWith(color: colors.ink2),
        ),
      ),
    );

    final retry = onRetry == null
        ? null
        : MasiPendingButton.text(
            key: const Key('sync-banner-retry'),
            onPressed: onRetry,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: MasiSpacing.xs),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text(
              'Retry',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          );

    return Row(
      // Centred while everything is on one line; top-aligned once the message
      // column is two lines tall, so the icon-sized controls sit beside the
      // SENTENCE rather than floating halfway down beside the Retry button.
      crossAxisAlignment: stackRetry
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.center,
      children: [
        MasiIcon(glyph, size: 20, color: tone),
        const SizedBox(width: MasiSpacing.sm),
        Expanded(
          child: stackRetry
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    message,
                    const SizedBox(height: MasiSpacing.xs),
                    Align(alignment: Alignment.centerLeft, child: retry!),
                  ],
                )
              : message,
        ),
        if (retry != null && !stackRetry) ...[
          const SizedBox(width: MasiSpacing.xs),
          retry,
        ],
        const SizedBox(width: MasiSpacing.xs),
        IconButton(
          key: const Key('sync-banner-details'),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
          visualDensity: VisualDensity.compact,
          tooltip: 'Details',
          onPressed: () =>
              showSyncBannerDetails(context, kind: kind, detail: detail),
          icon: MasiIcon('info', size: 18, color: colors.ink3),
        ),
        // Every kind, now — see [onDismiss] for why the old offline-only
        // restriction is gone and must not be restored. Sized/styled exactly
        // like `install_banner.dart`'s dismiss button so the app has one close
        // affordance, not two.
        if (onDismiss != null) ...[
          const SizedBox(width: MasiSpacing.xs),
          IconButton(
            key: const Key('sync-banner-dismiss'),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            visualDensity: VisualDensity.compact,
            tooltip: 'Dismiss',
            onPressed: onDismiss,
            icon: MasiIcon('close', size: 18, color: colors.ink3),
          ),
        ],
      ],
    );
  }
}

/// Opens the [SyncBanner] details sheet: the FULL message for [kind]/[detail],
/// selectable, with a copy action.
///
/// Public so a test can open it without hunting for the ⓘ button, and so a
/// future surface that wants the same disclosure (the Account screen's sync
/// row is the obvious candidate) does not grow a second copy of it.
Future<void> showSyncBannerDetails(
  BuildContext context, {
  required SyncBannerKind kind,
  String? detail,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) =>
        _SyncBannerDetailsSheet(text: SyncBanner.messageFor(kind, detail)),
  );
}

/// The sheet behind the banner's ⓘ.
///
/// [SelectableText], not [Text]: copy is offered as a button, but a user who
/// wants only the URL out of a 400-character exception should be able to take
/// that much — and it is the honest fallback if the clipboard write fails,
/// which is the one thing the button cannot recover from itself.
class _SyncBannerDetailsSheet extends ConsumerStatefulWidget {
  const _SyncBannerDetailsSheet({required this.text});

  final String text;

  @override
  ConsumerState<_SyncBannerDetailsSheet> createState() =>
      _SyncBannerDetailsSheetState();
}

class _SyncBannerDetailsSheetState
    extends ConsumerState<_SyncBannerDetailsSheet> {
  /// Latched, never un-latched on a timer. A `Future.delayed` that put the
  /// label back would leave a pending timer in every widget test that touches
  /// this sheet, and "Copied" going stale is not a problem anyone has.
  bool _copied = false;
  bool _copyFailed = false;

  Future<void> _copy() async {
    try {
      await Clipboard.setData(ClipboardData(text: widget.text));
    } catch (_) {
      // Never rethrown: a clipboard that refuses (a browser without
      // permission, above all) must not become an unhandled async error out of
      // a button press. The text above is selectable, so there is a real
      // fallback to point at.
      if (mounted) setState(() => _copyFailed = true);
      return;
    }
    if (mounted) setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;

    return SafeArea(
      key: const Key('sync-banner-details-sheet'),
      // The floor alone, handed to `minimum:` — `SafeArea` already maxes it
      // per-edge against the real device inset, which is zero on the bottom
      // in an installed iOS PWA (the platform never reports a home-indicator
      // inset there).
      minimum: EdgeInsets.only(bottom: standaloneBottomFloorOf(ref)),
      child: Padding(
        padding: const EdgeInsets.all(MasiSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Sync details', style: textTheme.titleLarge),
            const SizedBox(height: MasiSpacing.md),
            Flexible(
              child: SingleChildScrollView(
                child: SelectableText(
                  widget.text,
                  key: const Key('sync-banner-details-text'),
                  style: textTheme.bodyMedium?.copyWith(color: colors.ink2),
                ),
              ),
            ),
            if (_copyFailed) ...[
              const SizedBox(height: MasiSpacing.sm),
              Text(
                "Couldn't copy — select the text above to copy it by hand.",
                style: textTheme.bodySmall?.copyWith(color: colors.ink3),
              ),
            ],
            const SizedBox(height: MasiSpacing.sm),
            Align(
              alignment: Alignment.centerRight,
              child: MasiPendingButton.text(
                key: const Key('sync-banner-details-copy'),
                onPressed: _copy,
                child: Text(_copied ? 'Copied' : 'Copy'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
