import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/db/storage_retry_provider.dart';
import '../shared/presentation/masi_icon.dart';
import 'page_reload.dart';
import 'theme.dart';

/// Injects [reloadPage] behind a provider rather than letting the widget call
/// the seam directly, so a widget test can observe the escalated action being
/// invoked (override this, not `page_reload.dart`) without a real browser
/// reload tearing down the test runner mid-assertion.
///
/// Lives here rather than in `storage_retry_provider.dart`: `lib/core` has no
/// existing dependency on `lib/app` (the direction runs the other way — this
/// file already imports `core/db/storage_retry_provider.dart`), and this
/// provider has exactly one consumer, [StorageRetryBanner] itself.
final pageReloadProvider = Provider<void Function()>((ref) => reloadPage);

/// A compact, non-dismissible notice with a working "Try again" button, shown
/// at the top of the [NavShell] body whenever the local database could not be
/// opened and re-opening it might help ([storageRetryNotice]).
///
/// UF-4 follow-up: this is the way OUT that the boot deadlines never provided.
/// `main.dart` already ensures the app renders rather than hanging when the
/// database never answers, and `topos_storage_banner.dart`'s
/// `_StorageWarningBanner` already explains the condition at length — but its
/// only advice is "reload to try again", and in an installed PWA there is no
/// visible reload control at all. The user's remedy was force-quitting.
///
/// SPLIT OF RESPONSIBILITIES with that existing banner, which is why this one
/// is terse rather than a second full explanation:
///  - `_StorageWarningBanner` (Library screen only) is the EXPLANATION — title,
///    body, the verbatim reason for a field report — and it renders for every
///    [StorageDurability.isEphemeral] shape including the ones no retry can fix;
///  - this one is the ACTION, and it rides on the nav shell so it is present on
///    the Map and Feed tabs too, where nothing previously said a word.
///
/// Placed in the shell rather than on each screen for the same reason
/// [InstallBanner] is: it must not depend on which tab happens to be selected.
/// Not dismissible, deliberately — the condition is not cosmetic and dismissing
/// it would put the user back where they started.
class StorageRetryBanner extends ConsumerWidget {
  const StorageRetryBanner({super.key, required this.notice});

  /// The sentence to render — [storageRetryNotice]'s non-null result. Passed in
  /// rather than re-derived here so the caller's decision to show this banner
  /// and the text it shows cannot disagree (see `nav_shell.dart`'s
  /// `ShellNotices`, which also suppresses the install prompt on this path).
  final String notice;

  /// Same reasoning — and the same implementation — as
  /// `StoragePressureBanner._maxViewportShare`, `SyncBanner._maxViewportShare`
  /// and `_StorageWarningBanner._maxViewportShare`: a SHARE of the viewport,
  /// never an absolute pixel cap, because the invariant is "the tab content
  /// below this notice stays reachable", and that is a statement about the
  /// screen rather than about a fixed number of logical pixels. `0.4` is the
  /// value both storage notices already use (`SyncBanner` is deliberately
  /// quieter at `0.25`); this is their constant, not a new one.
  ///
  /// This was the ONE shell notice missing that bound, and its absence is what
  /// turned a legitimate growth — raising the actions below to the 44pt
  /// tap-target floor — into an 11px `RenderFlex` overflow at the 400x420
  /// surface `nav_shell_test.dart` pins (the same dimension
  /// `topos_storage_banner.dart` records a measured failure at). The right fix
  /// is bounding the banner, not shrinking the targets back.
  ///
  /// WHEN IT BINDS — MEASURED at `textScaler` 1.0, not assumed, because an
  /// assumed number is what put this batch in repair to begin with:
  ///  - at [StorageRetryStatus.idle]/`retrying` the banner is 170pt on every
  ///    viewport tried (375x667, 390x844, 430x932, 400x420) and the cap never
  ///    binds — the ordinary case is untouched;
  ///  - at [StorageRetryStatus.failed] the content grows to ~356pt (a second
  ///    paragraph AND a second 44pt action), so the cap DOES bind on ordinary
  ///    phones: ~89pt scrolls on a 375x667 SE and ~18pt on a 390x844, while
  ///    430x932 still fits outright.
  ///
  /// Content that does not fit SCROLLS rather than being truncated, exactly as
  /// in the siblings, so both actions stay reachable — but on a small phone in
  /// the failed state the "Reload page" button is genuinely below the fold of
  /// this banner until the user scrolls it. That is the accepted trade against
  /// the alternative (an unbounded notice that starves the tab beneath it, the
  /// #26/#30 bug shape), and it is a layout/UX judgement rather than a defect
  /// to code around here: reshaping the failed state to fit — pairing the two
  /// actions on one row, or splitting the escalation into a sheet — is a
  /// design decision, and the earlier claim in this comment that "nothing
  /// scrolls at any real phone height" was simply false.
  static const double _maxViewportShare = 0.4;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MasiColors.of(context);
    final textTheme = Theme.of(context).textTheme;
    final status = ref.watch(storageRetryProvider);
    final retrying = status == StorageRetryStatus.retrying;
    // Deliberately NOT shown at `idle`: a user whose database is merely slow
    // has not tried anything yet, and handing them "reload the app" as the
    // FIRST offer would be the nuclear option before the ordinary one has
    // even been attempted. It appears only once a retry has genuinely failed
    // — see `StorageRetryStatus.failed`'s doc.
    final failed = status == StorageRetryStatus.failed;

    return SafeArea(
      // Topmost widget in the shell body (there is no AppBar), so it owns
      // clearing the status-bar/notch inset — exactly like [InstallBanner],
      // which `ShellNotices` suppresses whenever this is on screen, so the two
      // can never both claim the inset.
      top: true,
      bottom: false,
      child: Padding(
        // `lg` sides, not `md`: the screen-level notices this can stack
        // directly above (`SyncBanner`, `_StorageWarningBanner`,
        // `MasiAsyncView`'s stale-error bar) all inset by
        // `fromLTRB(lg, md, lg, 0)`, and a 12px shell notice sitting on top of
        // a 16px screen notice showed visibly staggered left/right edges. Only
        // the horizontal inset moves — the `md` top keeps the vertical rhythm
        // between stacked notices identical to theirs.
        padding: const EdgeInsets.fromLTRB(
          MasiSpacing.lg,
          MasiSpacing.md,
          MasiSpacing.lg,
          0,
        ),
        child: Container(
          key: const Key('storage-retry-banner'),
          padding: const EdgeInsets.all(MasiSpacing.md),
          decoration: BoxDecoration(
            // `gradeHard` (the app's danger tone) is correct here, unlike on
            // the offline banner: the user's writes have nowhere to go.
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
                  // The button lives INSIDE this column rather than as a third
                  // Row child for the reason `SyncBanner` documents: as a Row
                  // sibling it keeps its intrinsic width at every text scale,
                  // and at 3.0x on a narrow phone that is enough to overflow
                  // the message.
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Semantics(
                          liveRegion: true,
                          child: Text(
                            notice,
                            key: const Key('storage-retry-banner-message'),
                            style: textTheme.bodyMedium?.copyWith(
                              color: colors.ink2,
                            ),
                          ),
                        ),
                        const SizedBox(height: MasiSpacing.xs),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton(
                            key: const Key('storage-retry-banner-action'),
                            // Disabled (null `onPressed`) while an attempt is
                            // in flight: re-opening a database is not instant
                            // on web, and a second tap would be a no-op the
                            // user reads as a dead button.
                            onPressed: retrying
                                ? null
                                : () => ref
                                      .read(storageRetryProvider.notifier)
                                      .retry(),
                            style: TextButton.styleFrom(
                              padding: EdgeInsets.zero,
                              // 44x44, not `Size.zero` — the iOS HIG minimum
                              // tap target (same recipe as
                              // `topo_canvas_screen.dart`'s
                              // `_topRowIconStyle`). At `Size.zero` this
                              // rendered ~20pt tall, and it is the app's ONLY
                              // way out of an unopenable database: the one
                              // control that must not be hard to hit is the
                              // one you reach for after something has already
                              // gone wrong. The extra height this costs is
                              // paid for by [_maxViewportShare] above, not by
                              // shrinking it back.
                              minimumSize: const Size(44, 44),
                              // Kept: `shrinkWrap` is what makes the footprint
                              // match `minimumSize` exactly rather than
                              // Material's own 48x48 padded default. The
                              // tap-target POLICY is unchanged here; only the
                              // minimum size is.
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: Text(
                              retrying ? 'Trying…' : 'Try again',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                        if (failed) ...[
                          const SizedBox(height: MasiSpacing.xs),
                          Semantics(
                            liveRegion: true,
                            child: Text(
                              "Reloading restarts the app. Nothing saved is "
                              "deleted, and nothing that hasn't saved yet can "
                              "be saved while storage isn't responding.",
                              key: const Key(
                                'storage-retry-banner-reload-message',
                              ),
                              style: textTheme.bodySmall?.copyWith(
                                color: colors.ink2,
                              ),
                            ),
                          ),
                          const SizedBox(height: MasiSpacing.xs),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton(
                              key: const Key('storage-retry-banner-reload'),
                              // Not gated on `retrying`: this button only
                              // exists at `failed`, and `retry()` cannot be
                              // mid-flight and `failed` at once (`retry()`
                              // always leaves `retrying` before it can settle
                              // into `failed`).
                              onPressed: () => ref.read(pageReloadProvider)(),
                              style: TextButton.styleFrom(
                                padding: EdgeInsets.zero,
                                // Same 44x44 floor as the "Try again" button
                                // above — see that style's comment.
                                minimumSize: const Size(44, 44),
                                tapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                              ),
                              child: const Text(
                                'Reload page',
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
              ),
            ),
          ),
        ),
      ),
    );
  }
}
