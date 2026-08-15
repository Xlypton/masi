import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:masi/core/db/database_provider.dart' show appDatabaseProvider;
import 'package:masi/features/account/application/auth_providers.dart'
    show effectiveUidProvider;

/// Whether a wall owned by [ownerId] may have its COMMITTED routes edited by
/// the identity [uid] — own-or-unowned, the same predicate every guarded
/// write in `LibraryCrudRepository` already uses (`_ownOrUnowned`, and the
/// `_GuardOutcome.writable` arm of `_classifyGuardTarget`).
///
/// The `ownerId == null` arm is the load-bearing half and it is NOT a
/// loophole: this app is local-first and fully usable signed out, so every
/// row created before a first sign-in carries a null `ownerId` until
/// `claimOwnership` stamps it. An unowned row is therefore the user's own
/// work in almost every case, and refusing it would lock people out of the
/// topos they drew — a far worse failure than the one this predicate exists
/// to prevent. When [uid] is null (no session has ever been known on this
/// device — see [effectiveUidProvider], which falls back to the last-known
/// uid, so signing OUT does not land here) this collapses to exactly
/// "unowned only", matching `_ownOrUnowned`'s null-uid collapse: a row
/// stamped with somebody's uid on a device that has never had an identity
/// can only have arrived by sync, and is genuinely foreign.
///
/// Pure and import-free so the policy can be asserted on its own, the way
/// `PublicPhotoPruner` splits policy from I/O.
bool mayEditWallRoutes({required String? ownerId, required String? uid}) {
  if (ownerId == null) return true;
  return uid != null && ownerId == uid;
}

/// Live answer to "may I edit the committed routes on this wall?", keyed by
/// wallId.
///
/// This exists because the canvas is reachable for walls that are NOT ours.
/// Foreign walls really do live in the local database — they arrive with a
/// sync pull of shared topos (see `ForeignWallSweepService`, whose whole job
/// is cleaning them up again) — and the Areas → Sectors → Walls path opens
/// any of them in the full editing canvas. `readOnly` on the canvas route is
/// a call-site convention, not an ownership check, so it does not answer
/// this; nothing did before this provider.
///
/// Scoped through [effectiveUidProvider], the single local-data uid door,
/// for the same reason `toposProvider` is: reading
/// `authStateProvider.asData?.value.uid` collapses to null on a transient
/// auth-stream error, and here that would turn every owned wall foreign for
/// as long as the error lasted.
///
/// A missing row answers `true` rather than `false`. "The wall is not in the
/// local database" is not evidence of foreign ownership, and edits to a
/// nonexistent wall have nowhere to land anyway; refusing would only produce
/// a false accusation. Consumers are expected to extend that same
/// keep-by-default posture to the unresolved and errored states — refuse
/// only what can be positively proven foreign (`PublicPhotoPruner`'s rule,
/// applied to writes instead of evictions).
///
/// ## A one-shot read, not a drift stream
///
/// The obvious shape is `watchSingleOrNull()`, so the answer tracks the row.
/// It is the wrong one here, for two reasons that both point the same way:
///
///  - **It broke widget tests wholesale.** Cancelling a drift stream calls
///    `StreamQueryStore.markAsClosed`, which schedules a zero-duration timer.
///    Under `fake_async` that timer is still pending when the tree is torn
///    down, so every test that merely PUMPS a canvas failed with "A Timer is
///    still pending even after the widget tree was disposed" — tests about
///    photo layout and bottom padding, which have nothing to do with
///    ownership. A provider that makes unrelated tests fail by existing is
///    paying too much.
///  - **The live-update case is already covered by the dependency.** The
///    realistic way a wall's `ownerId` changes under an open canvas is
///    `claimOwnership` stamping every row at first sign-in — and that is
///    exactly when [effectiveUidProvider] changes too, which re-runs this.
///
/// What is genuinely given up: an `ownerId` that changes with no uid change,
/// i.e. a sync pull re-stamping ownership while the canvas is open. The
/// consequence is a stale answer until the topo is reopened, and it fails in
/// the harmless direction — see the `mayEdit.hasValue` gate in `TopoCanvas`.
/// ## Not `autoDispose`, deliberately
///
/// This is the same "FIX #6 pending-timer gotcha" the canvas providers already
/// carry a note about. When the last watcher of an `autoDispose` provider
/// unmounts, Riverpod schedules its disposal on a zero-duration timer; under
/// `fake_async` that timer is still pending when the tree is torn down, so
/// every widget test that pumps a canvas fails with "A Timer is still pending
/// even after the widget tree was disposed" — including tests about photo
/// layout and bottom padding, which never mention ownership. The existing
/// workaround is a `container.listen` in each test to hold the provider open,
/// and requiring that of every future canvas test to keep one boolean tidy is
/// the wrong trade.
///
/// What is kept alive is one `bool` per wall visited, recomputed whenever
/// [effectiveUidProvider] changes. That is small enough that the caching is a
/// feature rather than a leak.
final canEditWallRoutesProvider = FutureProvider
    .family<bool, String>((ref, wallId) async {
      final uid = ref.watch(effectiveUidProvider);
      final db = ref.watch(appDatabaseProvider);
      // `selectOnly` + one column: ownership is a single indexed row read.
      final query = db.selectOnly(db.walls)
        ..addColumns([db.walls.ownerId])
        ..where(db.walls.id.equals(wallId))
        ..limit(1);
      try {
        final row = await query.getSingleOrNull();
        return mayEditWallRoutes(
          ownerId: row?.read(db.walls.ownerId),
          uid: uid,
        );
      } catch (_) {
        // A read that FAILED is not evidence of foreign ownership, so it gets
        // the same keep-by-default answer as a missing row: refuse only what
        // can be positively proven foreign. Swallowing it here also matters
        // mechanically — an errored `FutureProvider` makes Riverpod schedule a
        // retry on a 200ms backoff timer, which under `fake_async` is a
        // pending timer at teardown and fails every widget test that pumps a
        // canvas, whatever that test is actually about.
        return true;
      }
    });
