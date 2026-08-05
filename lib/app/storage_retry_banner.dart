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
        padding: const EdgeInsets.fromLTRB(
          MasiSpacing.md,
          MasiSpacing.md,
          MasiSpacing.md,
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
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MasiIcon('warning', size: 22, color: colors.gradeHard),
              const SizedBox(width: MasiSpacing.md),
              // The button lives INSIDE this column rather than as a third Row
              // child for the reason `SyncBanner` documents: as a Row sibling
              // it keeps its intrinsic width at every text scale, and at 3.0x
              // on a narrow phone that is enough to overflow the message.
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
                        // Disabled (null `onPressed`) while an attempt is in
                        // flight: re-opening a database is not instant on web,
                        // and a second tap would be a no-op the user reads as
                        // a dead button.
                        onPressed: retrying
                            ? null
                            : () => ref
                                  .read(storageRetryProvider.notifier)
                                  .retry(),
                        style: TextButton.styleFrom(
                          padding: EdgeInsets.zero,
                          minimumSize: Size.zero,
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
                          "deleted, and nothing that hasn't saved yet can be "
                          "saved while storage isn't responding.",
                          key: const Key('storage-retry-banner-reload-message'),
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
                          // Not gated on `retrying`: this button only exists
                          // at `failed`, and `retry()` cannot be mid-flight
                          // and `failed` at once (`retry()` always leaves
                          // `retrying` before it can settle into `failed`).
                          onPressed: () => ref.read(pageReloadProvider)(),
                          style: TextButton.styleFrom(
                            padding: EdgeInsets.zero,
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
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
    );
  }
}
