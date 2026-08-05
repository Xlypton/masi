import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'database_provider.dart';
import 'storage_durability_provider.dart';

/// Whether a storage retry is currently in flight — the banner's button reads
/// this to show progress and to refuse a second concurrent attempt — or has
/// already failed once.
///
/// [failed] is purely additive (added for the escalated-reload follow-up in
/// `storage_retry_banner.dart`): every existing caller only ever compared
/// against `== retrying`, so adding a third value changes nothing for them.
/// [StorageRetryController.retry] sets it in the two failure branches it
/// already computes — a timeout and a reported probe failure — rather than
/// falling back to [idle], because "Try again" genuinely cannot fix a wedged
/// web storage worker (see the class doc below): once it has failed, the
/// banner should say so and offer the one recovery that can, a page reload,
/// not silently reset to looking exactly like it did before anyone tried.
enum StorageRetryStatus { idle, retrying, failed }

/// How long [StorageRetryController.retry] waits for the re-opened database to
/// answer before calling the attempt failed.
///
/// 30 seconds — deliberately the same allowance as `main.dart`'s
/// `kBootStorageDeadline`, because the retry does exactly the work boot does: a
/// fresh `openConnection` plus one `SELECT 1`, which on web means
/// `WasmDatabase.open` (bounded at `kStorageOpenTimeout`, 20s) AND the
/// first-query work that open defers into the worker — `WasmSqlite3.loadFromUrl`
/// and VFS setup, and on a first run the v1->v9 migration's few hundred
/// statements. A tighter bound would call "broken" on a cold low-end Android
/// that boot would have called merely slow, which is the one thing these
/// timeouts must never do.
///
/// The ONLY thing that makes 30s the right number rather than 25 or 40 is the
/// alternative: unbounded. Without a bound the `await` below never returns, the
/// `finally` never runs, and the button stays disabled at "Trying…" forever —
/// the one documented way out of a hang, itself hanging unrecoverably, with no
/// reload control in an installed PWA.
const Duration kStorageRetryTimeout = Duration(seconds: 30);

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
  ///
  /// ALWAYS RESOLVES, bounded by [timeout]. It did not: the probe below is a
  /// real query against a freshly-opened database, and neither drift 2.34.2 nor
  /// the sqlite3 OPFS VFS has a timeout anywhere on that path. If the re-open
  /// wedged the same way the original open did — which is the LIKELY case, since
  /// the user only taps this because something is already wedged — the `await`
  /// never returned, the `finally` never ran, and the button stayed disabled at
  /// "Trying…" for the rest of the run. The single documented way out of a hang
  /// could hang, unrecoverably, on an installed PWA with no reload control.
  Future<void> retry({Duration timeout = kStorageRetryTimeout}) async {
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
      ).timeout(
        timeout,
        onTimeout: () {
          failed = true;
          // Logged unconditionally, like `logStorageDurability`: on a release
          // web build this line is the only record that the user tried.
          debugPrint(
            'masi/storage: retry gave up after ${timeout.inSeconds}s — the '
            're-opened database never answered. The old database was disposed '
            'and its worker may still be wedged; only a page reload can clear '
            'that.',
          );
          if (!ref.mounted) return;
          // `unavailableOver`, so the backend and missing-feature set the
          // connection layer measured survive the retry rather than being
          // zeroed out of the field report (see `StorageDurability`).
          storage.report(
            StorageDurability.unavailableOver(
              ref.read(storageDurabilityProvider),
              're-opening the local database did not answer within '
              '${timeout.inSeconds}s',
            ),
          );
        },
      );

      if (!failed &&
          ref.mounted &&
          ref.read(storageDurabilityProvider) == stale) {
        storage.report(const StorageDurability.probing());
      }
    } finally {
      // Reached even when the probe never answered, which is the whole point of
      // the bound above: the button goes back to being TAPPABLE instead of
      // sitting on "Trying…" forever — but tappable at [StorageRetryStatus.failed]
      // now, not silently back at [StorageRetryStatus.idle], when the attempt
      // genuinely failed. `failed` is exactly the local bool already set by the
      // timeout branch above and by the `report:` callback into
      // [probeDatabaseUsable] — this does not add a new way to fail, it just
      // stops discarding the fact that one happened.
      //
      // Be honest about what that does NOT fix. The abandoned probe future is
      // still out there, and a web worker wedged on the sqlite3 OPFS VFS's
      // `Atomics.wait(int32View, _responseIndex, -1)` (no timeout) cannot be
      // unblocked from Dart at all — it cannot even process a `close()`. So a
      // second tap will very likely wedge and time out again; what the user gets
      // back is an accurate verdict and a live control, not a repaired
      // database. Only a page reload discards the wedged worker — which is why
      // [StorageRetryBanner] offers that as a second, escalated action exactly
      // when `state == StorageRetryStatus.failed`. (If the abandoned probe DOES
      // eventually resolve with a real error, its report lands then and
      // replaces this timeout verdict, which is strictly more accurate — a
      // later verdict is a newer fact.)
      if (ref.mounted) {
        state = failed ? StorageRetryStatus.failed : StorageRetryStatus.idle;
      }
    }
  }
}

final storageRetryProvider =
    NotifierProvider<StorageRetryController, StorageRetryStatus>(
      StorageRetryController.new,
    );
