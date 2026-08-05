import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/public_photo_prune_service.dart';

/// Progress of the manual, explicitly-consented "clear cached community
/// photos" action (#49 P3 / task #51) — the UI-facing twin of
/// `StorageRetryStatus`.
enum CommunityPhotoClearStatus {
  /// Nothing in flight; the default/rest state, including after a completed
  /// clear (see [CommunityPhotoClearController.lastOutcome] for the result of
  /// the most recent one).
  idle,

  /// A clear is currently running. The banner's button reads this to show
  /// progress and to refuse a second concurrent tap.
  clearing,

  /// The most recent clear completed (with or without anything to clear —
  /// see [CommunityPhotoClearController.lastOutcome]).
  succeeded,

  /// The most recent clear threw. [PublicPhotoPruneService
  /// .clearAllCachedForeignPhotos] is documented never to throw for an
  /// ordinary reason (per-key failures are counted, not rethrown), so this
  /// covers only a genuinely unexpected failure — e.g. the database query
  /// itself.
  failed,
}

/// Drives [PublicPhotoPruneService.clearAllCachedForeignPhotos] — the ONLY
/// caller of that method anywhere in the app, which is exactly what makes it
/// the consent gate: nothing reaches
/// [PublicPhotoPruneService.clearAllCachedForeignPhotos] except a button tap
/// this controller's caller has already put behind a confirmation dialog
/// (`storage_pressure_banner.dart`'s `StoragePressureBanner`).
///
/// Same shape as `StorageRetryController` (`lib/core/db/storage_retry_provider
/// .dart`): a plain progress enum plus a no-op guard against a second
/// concurrent attempt, so the calling banner's button can show "Clearing…"
/// and refuse a second tap the same way "Try again" does during a database
/// re-open.
class CommunityPhotoClearController extends Notifier<CommunityPhotoClearStatus> {
  @override
  CommunityPhotoClearStatus build() => CommunityPhotoClearStatus.idle;

  /// The most recent completed (or failed) clear's outcome, or `null` before
  /// the first one this app run. Read by the banner to compose its
  /// confirmation message ("Cleared N cached photos" / "Nothing to clear").
  /// Deliberately NOT part of [state] — [state] is a coarse enum the button
  /// switches its label on; this is the DATA behind a `succeeded` state, kept
  /// alongside it rather than inside it so a `failed` clear still leaves the
  /// PREVIOUS successful outcome's numbers readable rather than clobbering
  /// them with nothing.
  PublicPhotoManualClearOutcome? lastOutcome;

  /// Runs one clear pass. A no-op while an earlier attempt is still running —
  /// mirrors [StorageRetryController].
  Future<void> clear() async {
    if (state == CommunityPhotoClearStatus.clearing) return;
    state = CommunityPhotoClearStatus.clearing;
    try {
      final outcome = await ref
          .read(publicPhotoPruneServiceProvider)
          .clearAllCachedForeignPhotos();
      // `ref.mounted`-guarded: the container can be torn down mid-clear (the
      // user navigating away, a hot restart) and assigning `state`/fields
      // after disposal throws — mirrors `StorageRetryController.retry`'s
      // identical guard.
      if (!ref.mounted) return;
      lastOutcome = outcome;
      state = CommunityPhotoClearStatus.succeeded;
    } catch (_) {
      if (!ref.mounted) return;
      state = CommunityPhotoClearStatus.failed;
    }
  }
}

final communityPhotoClearProvider =
    NotifierProvider<CommunityPhotoClearController, CommunityPhotoClearStatus>(
      CommunityPhotoClearController.new,
    );
