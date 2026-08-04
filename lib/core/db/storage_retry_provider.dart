import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'database_provider.dart';
import 'storage_durability_provider.dart';

/// Whether a storage retry is currently in flight — the banner's button reads
/// this to show progress and to refuse a second concurrent attempt.
enum StorageRetryStatus { idle, retrying }

/// The user-driven "open the local database again" action (UF-4 follow-up).
///
/// `main.dart`'s two boot deadlines already guarantee the app RENDERS even when
/// the database never opens: at `kBootFirstFrameDeadline` the first frame goes
/// up anyway, and at `kBootStorageDeadline` the verdict is published as
/// [StorageDurability.unavailable] so the storage banner explains it and the
/// create-topo interlock stops writes into a store that may never land. What
/// none of that provided was a way BACK: the banner's only advice is "reload to
/// try again", and in an installed PWA there is no visible reload control — the
/// user's sole remedy was force-quitting the app, which is neither obvious nor
/// discoverable.
///
/// WHY THIS RE-OPENS RATHER THAN REBUILDING A WIDGET. The failure is cached in
/// two places at once: `appDatabaseProvider` holds an [AppDatabase] wrapped
/// around a connection that is wedged or dead, and `storageDurabilityProvider`
/// holds the verdict about it. A retry that only rebuilt the UI would re-read
/// the very same failed [AppDatabase] and re-derive the very same verdict —
/// visibly "doing something" and changing nothing, which is worse than no
/// button. [retry] invalidates `appDatabaseProvider` instead, which disposes
/// (and closes) the old database and makes the next read construct a NEW one
/// through `openConnection` — a genuinely fresh open, the same one boot
/// performs — and then re-runs boot's own probe against it.
class StorageRetryController extends Notifier<StorageRetryStatus> {
  @override
  StorageRetryStatus build() => StorageRetryStatus.idle;

  /// Re-opens the local database and re-publishes the verdict. Never throws
  /// (the probe it delegates to cannot), and is a no-op while an earlier retry
  /// is still running.
  Future<void> retry() async {
    if (state == StorageRetryStatus.retrying) return;
    state = StorageRetryStatus.retrying;

    final storage = ref.read(storageDurabilityProvider.notifier);
    // The verdict is deliberately LEFT STANDING for the duration of the
    // attempt, rather than reset to `probing` up front. Resetting would make
    // the banner — and with it the "Trying…" progress label and the create-topo
    // interlock — vanish the instant the button is tapped, so a slow web
    // re-open would look like it had succeeded and then fail again seconds
    // later. Nothing is claimed that is not known: the old verdict is still the
    // last thing this database actually did.
    //
    // Snapshotted so the success path below can tell "the connection layer
    // published a fresh verdict" (what always happens in production — native
    // reports synchronously, web once its feature probe resolves) from
    // "nothing new arrived", where the stale failure has to be cleared here or
    // it would outlive the database it describes.
    final stale = ref.read(storageDurabilityProvider);
    var failed = false;
    try {
      // The actual re-open. Disposing the provider closes the old database
      // (`appDatabaseProvider`'s `ref.onDispose`), and the rebuild on the next
      // read calls `openConnection` again from scratch. Every dependent
      // provider — repositories, the topos stream — rebuilds off the new
      // handle, which is exactly what a recovery has to mean.
      ref.invalidate(appDatabaseProvider);

      await probeDatabaseUsable(
        openDatabase: () => ref.read(appDatabaseProvider),
        report: (verdict) {
          failed = true;
          storage.report(verdict);
        },
      );

      if (!failed &&
          ref.mounted &&
          ref.read(storageDurabilityProvider) == stale) {
        storage.report(const StorageDurability.probing());
      }
    } finally {
      // `ref.mounted`-guarded: the container can be torn down mid-retry (a hot
      // restart, or the user navigating away on web while a wedged open is
      // still hanging), and assigning `state` after disposal throws.
      if (ref.mounted) state = StorageRetryStatus.idle;
    }
  }
}

final storageRetryProvider =
    NotifierProvider<StorageRetryController, StorageRetryStatus>(
      StorageRetryController.new,
    );
