import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/supabase_init_provider.dart';
import '../../../core/db/database_provider.dart';
import '../../account/application/auth_providers.dart';
import '../../account/application/profile_providers.dart';
import '../../account/data/auth_repository.dart';
import '../../topo/data/foreign_wall_sweep_service.dart';
import '../../topo/data/public_photo_prune_service.dart';
import '../data/connectivity_service.dart';
import '../data/sync_service.dart';
import 'backup_providers.dart';
import 'sync_providers.dart';
import 'sync_retry_schedule.dart';

/// Coarse status the opportunistic auto-sync engine can be in at any
/// moment — surfaced by the Account screen's `sync-status` line.
enum SyncStatus {
  /// Nothing in flight. Covers "never attempted", "last attempt succeeded",
  /// AND "signed out" (there's nothing TO sync, which isn't an error).
  idle,

  /// A push or pull is currently awaiting the network.
  syncing,

  /// The most recent push/pull threw (network hiccup, Supabase error, …) —
  /// caught here, never rethrown past this class.
  error,

  /// The device could not reach the backend. Produced EITHER by a real
  /// reachability probe ([ConnectivityService.isBackendReachable]) coming
  /// back false after a push that didn't land, OR by the `wifiOnly` skip
  /// (see `wifiOnlySettingProvider`).
  ///
  /// S4 fix (§1d): the `wifiOnly` skip used to be the ONLY producer — and
  /// it is off by default with no UI, and `connectivity_plus` reports
  /// interface state only (wifi unconditionally on web), so this status was
  /// unreachable in production and the Account screen's "Offline" label
  /// could never render.
  offline,
}

/// Immutable snapshot of [SyncOrchestrator]'s state: the current [status]
/// plus the last time a push OR pull actually completed (outcome `pushed`/
/// `pulled`, not merely attempted).
@immutable
class SyncOrchestratorState {
  const SyncOrchestratorState({
    this.status = SyncStatus.idle,
    this.lastSyncedAt,
    this.lastPullError,
    this.lastPushError,
    this.lastPushWarning,
    this.lastPublicPhotoPruneOutcome,
    this.lastSharedPhotoBytesSkipped = 0,
    this.lastSharedPhotoBudgetReason = SharedPhotoBudgetReason.withinBudget,
  });

  final SyncStatus status;

  /// The last time a push or pull actually completed SUCCESSFULLY. S1 fix
  /// (§1d): a push is only "successful" when [PushSyncResult.fullyLanded] —
  /// a push where some or all rows never reached the cloud leaves this at
  /// its previous value rather than stamping a fresh, false "just now".
  final DateTime? lastSyncedAt;

  /// Human-readable description of why the MOST RECENT `pullOwnAndShared()`
  /// call (via [SyncOrchestrator.pullNow]) reported a problem — #72 P1 fix
  /// (see [SyncOrchestrator._runPull]): set whenever [PullResult.errors]
  /// came back non-empty (own or shared side partially/fully failed — see
  /// that class's doc for what "partial" means; a partial failure is
  /// surfaced here too, NOT discarded and NOT conflated with a total one)
  /// OR the call to `pullOwnAndShared()` itself threw. `null` once a pull
  /// completes with zero errors, or while signed out — this field is
  /// deliberately CLEARED, not left stale, in either of those cases. The
  /// Feed/Library empty states (`community_feed_screen.dart`'s
  /// `_SyncErrorEmptyState`, `topos_empty_states.dart`'s
  /// `_SyncErrorEmptyState`) key their "Couldn't sync — retry" affordance
  /// directly off this being non-null, so it must never linger past a pull
  /// that actually succeeded cleanly. A PUSH failure never touches this
  /// field ([_runPush] writes only [status]/[lastSyncedAt]/[lastPushError]/
  /// [lastPushWarning]) — it is pull-specific by design.
  final String? lastPullError;

  /// Human-readable description of why the MOST RECENT push did not fully
  /// land — S1 fix (§1d): set whenever [PushSyncResult.fullyLanded] came
  /// back false (one or more tables failed, and/or rows were excluded by the
  /// push-side required-field guard) OR the `pushOwn()` call itself threw.
  /// `null` once a push lands completely.
  ///
  /// Deliberately NOT cleared by a successful PULL, unlike [lastPullError]:
  /// a pull says nothing about whether local changes reached the cloud, and
  /// "Synced • just now" (which a successful pull legitimately produces:
  /// `idle` + a fresh [lastSyncedAt]) while the last push failed was exactly
  /// the S1 lie. `account_screen.dart`'s `_syncStatusLabel` keys off this.
  final String? lastPushError;

  /// A push-side ADVISORY: something is permanently not in the cloud, but
  /// nothing is wrong and nothing will be retried.
  ///
  /// Today this means exactly [PushSyncResult.photosMissingLocalBytes] — a
  /// photo whose pixels are gone from THIS device (evicted from the byte
  /// store, or a row predating the L3 fix), so `readPhotoBytes` returns null
  /// and there is nothing to upload. The metadata row still pushes: it is the
  /// only surviving record of the photo, and another device may well already
  /// hold the object.
  ///
  /// WHY THIS IS A SEPARATE FIELD from [lastPushError], rather than reusing
  /// it: the two need opposite handling, and conflating them breaks one of
  /// them.
  ///  - [lastPushError] means "retryable failure". It gates
  ///    [PushSyncResult.fullyLanded], keeps [status] off [SyncStatus.idle],
  ///    withholds a fresh [lastSyncedAt], and arms the backoff loop.
  ///  - This means "permanent, already-settled fact". It must NOT do any of
  ///    those things: `photosMissingLocalBytes` is deliberately excluded from
  ///    `fullyLanded` precisely because nothing will ever make those bytes
  ///    appear, so gating on it would pin the app outside `idle` forever and
  ///    stop the retry loop from ever terminating.
  ///
  /// But "not an error" must not collapse into "not mentioned". Before this
  /// field the condition was counted in [PushSyncResult.photoErrors] and then
  /// dropped on the floor: `_runPush` reads `photoErrors` only on the
  /// NOT-fully-landed branch, so a push that was otherwise clean stamped
  /// "Synced • just now" while a photo silently went nowhere. The user would
  /// never learn their photo is not backed up.
  ///
  /// Re-derived on EVERY push, so it self-clears the moment the condition
  /// stops holding (e.g. the photo is deleted, or a pull restores the bytes
  /// from another device's copy). Rendered by `account_screen.dart` as a
  /// plain line under the sync-status line — deliberately not an error style,
  /// not a SnackBar, and not a blocker.
  final String? lastPushWarning;

  /// What the most recent [SyncOrchestrator._prunePublicPhotosBestEffort]
  /// pass did — #49 P1 fix. `PublicPhotoPruneOutcome` was fully built,
  /// tested, and triggered on every successful pull, but only ever reached
  /// `debugPrint`, which is silent in a release build on device (see
  /// `CLAUDE.md`'s devicectl notes). That is exactly why a pass that
  /// "deleted" 50 keys while freeing zero bytes (`PublicPhotoPruneOutcome
  /// .fractionFreed`) went unnoticed until it caused a user's own-photo
  /// import to throw on quota. `null` until the first pull of the app run
  /// completes; carried forward by every unrelated state transition
  /// (push/pull error, cloud-availability) so it is never clobbered by news
  /// that has nothing to do with it.
  final PublicPhotoPruneOutcome? lastPublicPhotoPruneOutcome;

  /// [PullResult.sharedPhotoBytesSkipped] from the most recent completed
  /// pull — #49 P2 fix. `0` until the first pull, and whenever
  /// [lastSharedPhotoBudgetReason] is [SharedPhotoBudgetReason.withinBudget].
  final int lastSharedPhotoBytesSkipped;

  /// [PullResult.sharedPhotoBudgetReason] from the most recent completed
  /// pull. Before this field existed, nothing outside `sync_service.dart`
  /// could ever read it, so [SharedPhotoBudgetReason.storagePressure] — "this
  /// device is over the watermark, so this pull deliberately downloaded ZERO
  /// other climbers' photos" — reached the user only as a silent wall of
  /// placeholders in the Community feed, with no explanation anywhere.
  /// `sync_banner.dart`'s `SyncBannerKind.sharedPhotosWithheld` keys off this
  /// being [SharedPhotoBudgetReason.storagePressure].
  final SharedPhotoBudgetReason lastSharedPhotoBudgetReason;

  SyncOrchestratorState copyWith({SyncStatus? status, DateTime? lastSyncedAt}) =>
      SyncOrchestratorState(
        status: status ?? this.status,
        lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
        lastPullError: lastPullError,
        lastPushError: lastPushError,
        lastPushWarning: lastPushWarning,
        lastPublicPhotoPruneOutcome: lastPublicPhotoPruneOutcome,
        lastSharedPhotoBytesSkipped: lastSharedPhotoBytesSkipped,
        lastSharedPhotoBudgetReason: lastSharedPhotoBudgetReason,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncOrchestratorState &&
          other.status == status &&
          other.lastSyncedAt == lastSyncedAt &&
          other.lastPullError == lastPullError &&
          other.lastPushError == lastPushError &&
          other.lastPushWarning == lastPushWarning &&
          other.lastPublicPhotoPruneOutcome == lastPublicPhotoPruneOutcome &&
          other.lastSharedPhotoBytesSkipped == lastSharedPhotoBytesSkipped &&
          other.lastSharedPhotoBudgetReason == lastSharedPhotoBudgetReason);

  @override
  int get hashCode => Object.hash(
    status,
    lastSyncedAt,
    lastPullError,
    lastPushError,
    lastPushWarning,
    lastPublicPhotoPruneOutcome,
    lastSharedPhotoBytesSkipped,
    lastSharedPhotoBudgetReason,
  );

  @override
  String toString() =>
      'SyncOrchestratorState(status: $status, lastSyncedAt: $lastSyncedAt, '
      'lastPullError: $lastPullError, lastPushError: $lastPushError, '
      'lastPushWarning: $lastPushWarning, '
      'lastPublicPhotoPruneOutcome: $lastPublicPhotoPruneOutcome, '
      'lastSharedPhotoBytesSkipped: $lastSharedPhotoBytesSkipped, '
      'lastSharedPhotoBudgetReason: ${lastSharedPhotoBudgetReason.name})';
}

/// Debounce window [SyncOrchestrator] waits after the LAST local table write
/// before firing a single coalesced `pushOwn()` — injectable (default 2s in
/// production) so tests can shrink it to a few milliseconds instead of
/// waiting out the real default per assertion.
final syncDebounceDurationProvider = Provider<Duration>((ref) => const Duration(seconds: 2));

/// Opportunistic background-sync controller: debounced push-on-local-write,
/// pull-once-on-sign-in, push-on-app-background/resume, and — when a push
/// fails — an exponential-backoff retry that keeps going until nothing is
/// locally `dirty` (§1e; S2/S10). Every push trigger funnels through
/// [SyncOrchestrator.pushNow], every pull trigger through
/// [SyncOrchestrator.pullNow], so at most one of each can be in flight at a
/// time.
///
/// Constructed at the app root (`MasiApp` `ref.watch`es
/// [syncOrchestratorProvider] — NOT merely `ref.read`s it — for the widget's
/// entire lifetime, i.e. the whole app run). That active watch matters for a
/// non-obvious reason: [build]'s raw `db.tableUpdates().listen(...)`
/// subscription is a plain Dart [Stream] subscription and keeps delivering
/// regardless of whether anyone is watching this provider, BUT the
/// `ref.listen(authStateProvider, ...)` below is a Riverpod-internal
/// listener-graph edge — Riverpod only keeps flushing notifications along
/// that edge while [syncOrchestratorProvider] itself has at least one active
/// watcher/listener. A one-off `ref.read(syncOrchestratorProvider)` builds
/// this class (and its state persists — a non-`.autoDispose` `NotifierProvider`
/// is never torn down once created) but its `ref.listen(authStateProvider)`
/// subscription silently stops receiving events the moment nothing is left
/// actively watching it, which is why `MasiApp` must keep a live
/// `ref.watch` (or `ref.listen`) on this provider for as long as the app
/// runs, not just poke it once at startup. Tests must do the same — a bare
/// `container.read(syncOrchestratorProvider)` is NOT enough to observe
/// pull-on-sign-in; pair it with `container.listen(syncOrchestratorProvider,
/// (_, __) {})`.
///
/// Every actual I/O call goes through the already-gated [syncServiceProvider]
/// (see that file's doc comment for how a signed-out session or an
/// uninitialized Supabase client degrades to a no-op `skipped*` result rather
/// than a throw) — this class adds no NEW gating of its own; it only decides
/// WHEN to call `pushOwn()`/`pullOwnAndShared()` and translates the result
/// into a [SyncStatus].
class SyncOrchestrator extends Notifier<SyncOrchestratorState> {
  Timer? _debounceTimer;
  StreamSubscription<void>? _dbSubscription;

  /// The currently in-flight [pullNow] call's [Future], or `null` when no
  /// pull is running — [pullNow]'s own concurrency guard (see that method's
  /// doc). The sign-in-edge listener in [build] now ALSO funnels through
  /// [pullNow] (rather than calling `_runPull()` directly), so every pull
  /// trigger in this class — sign-in, resume, pull-to-refresh, the map
  /// refresh button, "Try again" — shares this single guard and no two of
  /// them can ever run [_runPull] concurrently.
  Future<void>? _pullInFlight;

  /// Window after a pull ACTUALLY STARTS during which a further
  /// `pullNow(throttled: true)` call is skipped as a no-op. Exists solely
  /// for the app-resume trigger in `app.dart`: on web, `AppLifecycleState
  /// .resumed` fires on every browser tab-focus (not just a genuine app
  /// relaunch), so an unconditional resume-pull would hammer Supabase every
  /// time the user merely alt-tabs back to the tab. Explicit user-initiated
  /// pulls (pull-to-refresh, the map refresh button, "Try again") always
  /// call [pullNow] with the default `throttled: false` and are NEVER
  /// subject to this window — the user asked for a refresh and must always
  /// get one.
  static const Duration _resumePullThrottle = Duration(seconds: 30);

  /// Wall-clock moment the most recent pull ACTUALLY STARTED (i.e. was
  /// neither skipped by [_resumePullThrottle] nor coalesced into an
  /// already-running [_pullInFlight]) — read via the same [nowMsProvider]
  /// clock seam [_now] uses for `lastSyncedAt` everywhere else in this
  /// class, so tests can control it exactly the same way. `null` until the
  /// first pull of the app run.
  DateTime? _lastPullStartedAt;

  /// The currently in-flight [pushNow] call's [Future], or `null` when no
  /// push is running — the push-side twin of [_pullInFlight].
  ///
  /// S10: there was NO push guard at all. `onAppPaused()` cancelled the
  /// debounce timer but not a running `_runPush`, so backgrounding the app
  /// mid-push ran a SECOND concurrent full push — duplicating the per-table
  /// LWW pre-check, the upserts and the photo uploads.
  Future<void>? _pushInFlight;

  /// Set when a push trigger arrives while [_pushInFlight] is non-null.
  ///
  /// The coalesced trigger is NOT simply dropped: it may be the only signal
  /// that a local write landed DURING the in-flight push (whose snapshot
  /// predates it). Instead it re-arms the debounce window once the push
  /// settles, so a follow-up push sees the newer `dirty` rows. When the
  /// trigger really was redundant the follow-up is free — [_runPush] finds
  /// nothing dirty and never touches the network.
  bool _pushRequestedWhileInFlight = false;

  /// Consecutive FAILED pushes since the last confirmed one — the attempt
  /// number handed to [SyncRetrySchedule.delayFor]. Deliberately uncapped
  /// (D-2: bounded interval, unbounded attempts, never give up). Reset by a
  /// confirmed push, by a push that found nothing pending, and by a
  /// connectivity regain.
  int _consecutivePushFailures = 0;

  /// The pending backoff retry armed by [_scheduleRetry], or `null`.
  Timer? _retryTimer;

  /// True while a [PushScope.full] push is still owed.
  ///
  /// Starts `true` so the FIRST push of every app run re-sends every own row:
  /// the D-4 loss-proof safety net that recovers any row whose `dirty` flag
  /// was cleared without the row actually landing. Set again on every
  /// connectivity regain; cleared only by a CONFIRMED full push
  /// ([PushSyncResult.fullyLanded]).
  bool _fullResyncDue = true;

  /// Minimum spacing between connectivity-REGAIN-triggered syncs.
  ///
  /// A flapping link emits none→wifi→none→wifi… and every rising edge is
  /// technically a regain, but consecutive ones carry no new information —
  /// while the backend is either reachable or not, and one attempt has
  /// already been made. Long enough to swallow a burst of flapping, short
  /// enough that a genuine "walked back into signal" still syncs promptly.
  static const Duration _connectivityResyncThrottle = Duration(seconds: 10);

  /// The most recent status [_onConnectivityChanged] observed, so it can tell
  /// a REGAIN (none → usable) from a usable → usable hop. `null` until the
  /// first transition of the app run.
  NetworkStatus? _lastConnectivityStatus;

  /// Wall-clock moment of the last regain-triggered sync, on the same
  /// [nowMsProvider] seam every other clock read in this class uses, so tests
  /// control it exactly the same way. `null` until the first regain.
  int? _lastConnectivityResyncAtMs;

  /// The connectivity-transition subscription installed in [build], or `null`.
  StreamSubscription<NetworkStatus>? _connectivitySubscription;

  @override
  SyncOrchestratorState build() {
    final db = ref.watch(appDatabaseProvider);
    _dbSubscription = db.tableUpdates().listen((_) => _scheduleDebouncedPush());

    // UF-6: seed from the cloud-init verdict, so a `Supabase.initialize` that
    // failed at boot is VISIBLE from the very first frame instead of only
    // when a sync happens to be attempted. That distinction matters because
    // with no client there is no auth stream either, so the pull-on-sign-in
    // edge below NEVER fires and a local write's debounced push finds nothing
    // dirty to send: without this seed, neither [_runPush] nor [_runPull]
    // would ever run, and the app would sit at `idle` — "everything is fine"
    // — forever.
    //
    // `ref.read`, deliberately NOT `ref.watch`: watching would tear this
    // notifier down and rebuild it (losing the debounce/retry timers) the
    // moment a retry flips the verdict — and worse, the retry is triggered
    // from INSIDE [_runPull]/[_runPush], which would then be left assigning
    // `state` on a disposed notifier. Recovery needs no listener anyway: the
    // retry lives in [_ensureCloudReady], and the push/pull that follows a
    // successful one writes its own honest state over this one.
    final cloudInit = ref.read(cloudInitProvider);

    // S3: react to the network coming back. `statusChanges()` is
    // contractually non-throwing and degrades to a never-emitting stream when
    // the platform signal is unavailable (see its doc), which is exactly what
    // makes this inert in every unit/widget test that doesn't override
    // `connectivityServiceProvider`; `onError` below is belt-and-braces on top
    // of that, never the primary defence.
    final connectivity = ref.watch(connectivityServiceProvider);
    _connectivitySubscription = connectivity.statusChanges().listen(
      _onConnectivityChanged,
      onError: (Object error) {
        debugPrint(
          'SyncOrchestrator: connectivity stream error (ignored): $error',
        );
      },
    );

    // Pull-on-sign-in: fire exactly once on the signed-out (or unknown,
    // e.g. still-loading/erroring) -> signed-in edge of the live auth
    // stream — mirrors `handleAuthStateForClaimOwnership`'s identical edge
    // detection in `claim_ownership_bootstrap.dart`. Every other transition
    // (already signed in re-emitting, signed-in -> signed-out, etc.) is a
    // no-op. See this class's doc comment above for why THIS PARTICULAR
    // listener (unlike the raw stream subscription above) requires
    // [syncOrchestratorProvider] to be actively watched by someone the whole
    // time to keep firing.
    ref.listen<AsyncValue<AuthSessionState>>(authStateProvider, (previous, next) {
      final previousUid = previous?.asData?.value.uid;
      final nextUid = next.asData?.value.uid;
      if (previousUid == null && nextUid != null) {
        unawaited(pullNow());
        // Publish the identity provider's picture into the user's own profile
        // row, so the rest of the community can actually see it — see
        // [ProfileRepository.adoptProviderAvatarUrl] for why a session-only
        // avatar is invisible to everyone else, and for the rules that keep
        // this from ever overwriting a picture the user chose in-app.
        //
        // Riding the existing sign-in edge rather than adding a second
        // listener: this class's doc explains that a `ref.listen` here only
        // keeps firing while `syncOrchestratorProvider` is actively watched,
        // and duplicating that subtlety is how a second hook ends up silently
        // never running.
        unawaited(_adoptProviderAvatar(next.asData?.value.providerAvatarUrl));
      }
    });

    ref.onDispose(() {
      _debounceTimer?.cancel();
      _retryTimer?.cancel();
      _dbSubscription?.cancel();
      _connectivitySubscription?.cancel();
    });

    if (cloudInit.isFailed) return _cloudUnavailableState(cloudInit);
    return const SyncOrchestratorState();
  }

  /// The state that says "the cloud is not there", built from [cloudInit].
  ///
  /// Three properties are the whole point, and each one is a lie the old code
  /// told:
  ///  - [SyncStatus] is never [SyncStatus.idle]. `idle` is what the Account
  ///    screen renders as "Synced";
  ///  - [SyncOrchestratorState.lastSyncedAt] is CARRIED, never stamped. No
  ///    push or pull happened, so there is nothing to timestamp;
  ///  - the reason lands in [SyncOrchestratorState.lastPullError], the field
  ///    the Library and Feed already key their "Couldn't sync — retry"
  ///    affordance off, so this reuses the #72 surface instead of inventing a
  ///    second one. `lastPushError` carries the same sentence because the
  ///    Account screen reads THAT one, and a cloud that cannot be reached has
  ///    failed both directions at once.
  ///
  /// [SyncStatus.error] rather than [SyncStatus.offline]: `offline` is the
  /// reassurance state ("your data is on the device, wait for signal") and the
  /// Library banner deliberately drops the detail for it. A push/pull that has
  /// actually been attempted refines this via [_failureStatus], which probes
  /// reachability; at build time nothing has been attempted, and defaulting to
  /// the louder of the two is correct for a fault we cannot yet classify.
  /// [lastSyncedAt]/[lastPushWarning] are passed in rather than read off
  /// `state`, because [build] calls this BEFORE returning the initial state,
  /// and `state` cannot be read until a `Notifier`'s build completes.
  static SyncOrchestratorState _cloudUnavailableState(
    CloudInitState cloudInit, {
    SyncStatus status = SyncStatus.error,
    DateTime? lastSyncedAt,
    String? lastPushWarning,
    PublicPhotoPruneOutcome? lastPublicPhotoPruneOutcome,
    int lastSharedPhotoBytesSkipped = 0,
    SharedPhotoBudgetReason lastSharedPhotoBudgetReason = SharedPhotoBudgetReason.withinBudget,
  }) {
    final message = cloudUnavailableMessage(cloudInit);
    return SyncOrchestratorState(
      status: status,
      lastSyncedAt: lastSyncedAt,
      lastPullError: message,
      lastPushError: message,
      lastPushWarning: lastPushWarning,
      lastPublicPhotoPruneOutcome: lastPublicPhotoPruneOutcome,
      lastSharedPhotoBytesSkipped: lastSharedPhotoBytesSkipped,
      lastSharedPhotoBudgetReason: lastSharedPhotoBudgetReason,
    );
  }

  /// Whether the cloud client exists — RE-ATTEMPTING `Supabase.initialize`
  /// first if a previous attempt failed, and writing the honest state either
  /// way. Called at the top of both [_runPush] and [_runPull]; a `false`
  /// return means "stop, the state has already been written".
  ///
  /// This IS the retry affordance for UF-6, and it deliberately lives on the
  /// path every existing trigger already takes rather than behind new UI: the
  /// Library/Feed "Couldn't sync — Retry" buttons, pull-to-refresh, the map
  /// refresh button, app-resume and the backoff timer all funnel through
  /// [pullNow]/[pushNow], so all of them now recover a boot-time outage.
  /// Before this, a `Supabase.initialize` that failed once stayed failed for
  /// the whole app run and the only way back was force-quitting the app —
  /// which on an installed PWA is not an obvious move.
  ///
  /// A successful late init also invalidates the providers that cached
  /// cloud-less fallbacks (see [CloudInitController.initialize]), which is why
  /// callers must read [syncServiceProvider] AFTER this returns, never before.
  ///
  /// Deliberately does NOT arm the backoff retry ([_scheduleRetry]) on
  /// failure, unlike a push that actually ran and did not land. That timer's
  /// termination condition is "nothing is dirty any more", which a missing
  /// cloud client can never satisfy — arming it here would recreate exactly
  /// the bug [_runPush]'s nothing-pending early-out was widened to fix: a
  /// device with nothing to send retrying forever. Automatic recovery instead
  /// rides on the EVENTS that could plausibly change the answer —
  /// [_onConnectivityChanged]'s regain push+pull and `app.dart`'s
  /// resume push+pull — both of which funnel through here.
  Future<bool> _prepareCloud() async {
    if (!ref.read(cloudInitProvider).isFailed) return true;

    if (await ref.read(cloudInitProvider.notifier).initialize()) {
      // Recovered. The "couldn't connect" sentence now describes a condition
      // that no longer holds, and it must be cleared HERE rather than left to
      // the run that follows: [_runPull]'s success branch deliberately carries
      // `lastPushError` through (a pull says nothing about whether local
      // changes reached the cloud — the S1 fix), so a stale cloud message
      // would survive an otherwise-perfect recovery and keep the Account
      // screen reading "Sync error" indefinitely.
      state = SyncOrchestratorState(
        status: state.status,
        lastSyncedAt: state.lastSyncedAt,
        lastPushWarning: state.lastPushWarning,
        lastPublicPhotoPruneOutcome: state.lastPublicPhotoPruneOutcome,
        lastSharedPhotoBytesSkipped: state.lastSharedPhotoBytesSkipped,
        lastSharedPhotoBudgetReason: state.lastSharedPhotoBudgetReason,
      );
      return true;
    }

    state = _cloudUnavailableState(
      ref.read(cloudInitProvider),
      status: await _failureStatus(),
      lastSyncedAt: state.lastSyncedAt,
      lastPushWarning: state.lastPushWarning,
      lastPublicPhotoPruneOutcome: state.lastPublicPhotoPruneOutcome,
      lastSharedPhotoBytesSkipped: state.lastSharedPhotoBytesSkipped,
      lastSharedPhotoBudgetReason: state.lastSharedPhotoBudgetReason,
    );
    return false;
  }

  /// (Re)schedules a single push [syncDebounceDurationProvider] from NOW —
  /// every call before the window elapses cancels and restarts the timer, so
  /// N rapid local writes coalesce into exactly one push.
  void _scheduleDebouncedPush() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(ref.read(syncDebounceDurationProvider), () {
      unawaited(pushNow());
    });
  }

  /// Pushes immediately, cancelling any still-pending debounced push —
  /// called when the app is about to leave the foreground and might get
  /// killed before a debounced push would otherwise have fired. Funnels
  /// through [pushNow], so it can no longer race a push already in flight
  /// (S10).
  void onAppPaused() {
    unawaited(pushNow());
  }

  /// Pushes NOW, cancelling any pending debounced push or armed retry — the
  /// push-side twin of [pullNow], and the SINGLE funnel every push trigger in
  /// this class goes through: the debounce timer, [onAppPaused], app-resume
  /// (`app.dart`), connectivity regain, and the backoff retry. Exactly one
  /// push can therefore be in flight at a time (S10).
  ///
  /// A call made while an earlier push is still in flight returns THAT SAME
  /// [Future] instead of starting a second one, and re-arms the debounce
  /// window once it settles so a write that landed mid-push is not dropped
  /// (see [_pushRequestedWhileInFlight]). A call made once the in-flight push
  /// has completed starts a fresh one.
  ///
  /// Never throws, and is a safe no-op when signed out, when nothing is
  /// locally dirty, or when Supabase is unavailable — [_runPush] catches
  /// everything and translates it into a [SyncStatus] plus, on failure, a
  /// scheduled retry.
  Future<void> pushNow() {
    final inFlight = _pushInFlight;
    if (inFlight != null) {
      _pushRequestedWhileInFlight = true;
      return inFlight;
    }
    _debounceTimer?.cancel();
    _retryTimer?.cancel();
    final future = _runPush();
    _pushInFlight = future;
    unawaited(
      future.whenComplete(() {
        if (identical(_pushInFlight, future)) {
          _pushInFlight = null;
        }
        if (_pushRequestedWhileInFlight) {
          _pushRequestedWhileInFlight = false;
          _scheduleDebouncedPush();
        }
      }),
    );
    return future;
  }

  /// S1 fix (§1d): only a push where EVERYTHING landed
  /// ([PushSyncResult.fullyLanded]) may report [SyncStatus.idle] and stamp a
  /// fresh `lastSyncedAt`. A partial or total failure keeps the previous
  /// timestamp and records [SyncOrchestratorState.lastPushError] — before
  /// this, `upsertOwnRows` swallowed every per-table error, so a totally
  /// failed offline push reported "Synced • just now".
  ///
  /// S2 fix (§1e), layered on top: the scope is chosen from [_fullResyncDue],
  /// a push with nothing pending is a no-op that never touches `state`, and
  /// EVERY failure path arms a backoff retry. Note a failed push does NOT
  /// throw for any NETWORK reason — §1d converts a whole-call upsert throw
  /// into an all-tables-failed RESULT, and §1f does the same for a Storage
  /// listing throw (which, once the photo phase moved ahead of the row
  /// upsert, would otherwise have aborted the whole push before any row was
  /// sent). So the `!fullyLanded` branch, not the `catch`, is the one that
  /// fires in practice; the `catch` is left for genuinely unexpected local
  /// failures such as the snapshot transaction itself.
  Future<void> _runPush() async {
    // FIRST, ahead of the nothing-pending early-out below (UF-6). That
    // early-out is the branch a cloud-less push actually takes —
    // `hasPendingLocalChanges()` reports false whenever `currentSession.uid`
    // is null, and with no Supabase client `syncServiceProvider` falls back to
    // `_SignedOutAuthRepository`, so the uid IS null — and it CLEARS
    // `lastPushError` and moves the status to `idle` on the way out. Checking
    // afterwards would therefore have the push quietly erase the very warning
    // this fix exists to raise.
    if (!await _prepareCloud()) return;

    // Read AFTER `_prepareCloud`: a successful late init invalidates
    // `syncServiceProvider`, and reading it first would hand this push the
    // stale, cloud-less `_UnavailableSyncRemote` fallback.
    final service = ref.read(syncServiceProvider);
    final scope = _fullResyncDue ? PushScope.full : PushScope.dirtyOnly;

    // S9: `BackupRepository.importSnapshot`'s writes fire the same
    // `tableUpdates()` this class debounces on, so before the `dirty` gate
    // every pull that wrote anything scheduled a full re-push ~2s later.
    // Imported rows are written `dirty: false`, so "nothing pending" is now a
    // cheap, correct no-op. It returns WITHOUT touching `state`, deliberately:
    // flipping to `syncing`/`idle` here would clobber a real `error` status or
    // a live `lastPullError`/`lastPushError` with the outcome of a push that
    // never happened.
    // NOT gated on `scope == dirtyOnly`. It used to be, which made the
    // termination guarantee far narrower than it sounded: `_fullResyncDue` is
    // armed on every app start AND every connectivity regain, so a
    // FULLY-SYNCED device with a failing backend — a phone on a plane —
    // retried every 5 minutes forever with nothing whatsoever to send.
    //
    // "Nothing is dirty" means "nothing to push" in EITHER scope, and that is
    // sound because `_clearDirty` only ever clears tables the remote
    // CONFIRMED (§1d/§1e, plus the fail-closed fix in `sync_service.dart`) and
    // every push-worthy writer sets the flag. `_fullResyncDue` is left ARMED
    // here on purpose: no full push actually ran, so the safety net has not
    // been spent, and the next push that does have something to send will
    // still be full scope.
    if (!await service.hasPendingLocalChanges()) {
      _consecutivePushFailures = 0;
      _retryTimer?.cancel();
      // "Nothing is pending" makes a live push error STALE BY DEFINITION: it
      // says "N change(s) not uploaded", and there are none. Leaving it up
      // was not merely untidy — nothing could ever clear it, because no
      // further push runs to succeed. That is how a failed push followed by
      // a sign-out left the Account screen reading "Sync error" forever
      // (`hasPendingLocalChanges` reports false when signed out, so this
      // early-out is the branch a signed-out push actually takes, not the
      // `skippedSignedOut` arm below).
      //
      // Guarded so the common case still touches nothing: an unconditional
      // write here would notify every listener on every no-op push. `status`
      // moves to idle only when no PULL error is live — a pull failure is a
      // separate channel and must not be cleared by push-side news.
      if (state.lastPushError != null || state.lastPushWarning != null) {
        state = SyncOrchestratorState(
          status: state.lastPullError != null ? state.status : SyncStatus.idle,
          lastSyncedAt: state.lastSyncedAt,
          lastPullError: state.lastPullError,
          lastPublicPhotoPruneOutcome: state.lastPublicPhotoPruneOutcome,
          lastSharedPhotoBytesSkipped: state.lastSharedPhotoBytesSkipped,
          lastSharedPhotoBudgetReason: state.lastSharedPhotoBudgetReason,
        );
      }
      return;
    }

    state = state.copyWith(status: SyncStatus.syncing);
    try {
      final result = await service.pushOwn(scope: scope);
      switch (result.outcome) {
        case SyncPushOutcome.pushed:
          // Re-derived on EVERY push so it self-clears the moment the
          // condition stops holding. Carried on BOTH branches: it describes
          // the photos, not the push's success.
          final pushWarning = _missingPhotoBytesWarning(result);

          // A full push that RAN retires the safety net, whether or not
          // everything landed. This used to require `fullyLanded`, which
          // never converged: one row the server permanently rejects (an
          // unknown constraint, a column the deployed schema is missing)
          // means `fullyLanded` is never true, so every subsequent retry
          // stayed full scope and re-sent the ENTIRE library, forever, to
          // re-deliver one row that will never be accepted.
          //
          // Retiring it is safe because the safety net's job is narrow: it
          // exists to distrust `dirty` flags that a SWALLOWED per-table
          // failure may have wrongly cleared. Post-§1d nothing is swallowed —
          // `upsertOwnRows` reports per-table outcomes and `_clearDirty`
          // clears only the tables that were confirmed — so once one full
          // push has completed, the flags are trustworthy again by
          // construction. The rejected rows keep `dirty: true` and so keep
          // riding along in every subsequent dirty-scoped push; nothing is
          // dropped, the payload just stops being the whole library.
          if (scope == PushScope.full) _fullResyncDue = false;

          if (result.fullyLanded) {
            _consecutivePushFailures = 0;
            _retryTimer?.cancel();
            state = SyncOrchestratorState(
              status: SyncStatus.idle,
              lastSyncedAt: _now(),
              lastPullError: state.lastPullError,
              lastPushWarning: pushWarning,
              lastPublicPhotoPruneOutcome: state.lastPublicPhotoPruneOutcome,
              lastSharedPhotoBytesSkipped: state.lastSharedPhotoBytesSkipped,
              lastSharedPhotoBudgetReason: state.lastSharedPhotoBudgetReason,
            );
          } else {
            state = SyncOrchestratorState(
              status: await _failureStatus(),
              lastSyncedAt: state.lastSyncedAt,
              lastPullError: state.lastPullError,
              lastPushWarning: pushWarning,
              // D-2, second half: a push can fail ENTIRELY in the photo
              // channel, with `rowsFailed == 0` and `errors` empty, because
              // the failed photo's row was withheld from `tablesToRows` and
              // so never had a chance to fail. Reading only `errors` would
              // render the useless "Sync failed: 0 change(s) not uploaded — "
              // with an empty reason.
              lastPushError:
                  'Sync failed: ${result.rowsFailed} change(s) and '
                  '${result.photosFailed} photo(s) not uploaded — '
                  '${[...result.errors, ...result.photoErrors].join('; ')}',
              lastPublicPhotoPruneOutcome: state.lastPublicPhotoPruneOutcome,
              lastSharedPhotoBytesSkipped: state.lastSharedPhotoBytesSkipped,
              lastSharedPhotoBudgetReason: state.lastSharedPhotoBudgetReason,
            );
            _scheduleRetry();
          }
        case SyncPushOutcome.skippedSignedOut:
          _consecutivePushFailures = 0;
          _retryTimer?.cancel();
          // Both push-derived fields are CLEARED, not carried: they describe
          // a push made as a user who is no longer signed in, so there is
          // nobody for them to be about. `copyWith` carried them, which left
          // the Account screen reading "Sync error" indefinitely after
          // signing out following a failure — with no way to clear it, since
          // a signed-out push can never succeed. Mirrors how `_runPull`
          // clears `lastPullError` on its own signed-out branch.
          state = SyncOrchestratorState(
            status: SyncStatus.idle,
            lastSyncedAt: state.lastSyncedAt,
            lastPullError: state.lastPullError,
            lastPublicPhotoPruneOutcome: state.lastPublicPhotoPruneOutcome,
            lastSharedPhotoBytesSkipped: state.lastSharedPhotoBytesSkipped,
            lastSharedPhotoBudgetReason: state.lastSharedPhotoBudgetReason,
          );
        case SyncPushOutcome.skippedNotWifi:
          // Not a failure, and deliberately NOT retried on a timer: this
          // condition only changes when the network changes, and
          // [_onConnectivityChanged] already pushes on every regain. Arming a
          // backoff here would spin a timer that can never succeed.
          state = state.copyWith(status: SyncStatus.offline);
      }
    } catch (e, st) {
      debugPrint('SyncOrchestrator: pushOwn failed: $e\n$st');
      state = SyncOrchestratorState(
        status: await _failureStatus(),
        lastSyncedAt: state.lastSyncedAt,
        lastPullError: state.lastPullError,
        lastPushError: 'Sync failed: $e',
        lastPushWarning: state.lastPushWarning,
        lastPublicPhotoPruneOutcome: state.lastPublicPhotoPruneOutcome,
        lastSharedPhotoBytesSkipped: state.lastSharedPhotoBytesSkipped,
        lastSharedPhotoBudgetReason: state.lastSharedPhotoBudgetReason,
      );
      _scheduleRetry();
    }
  }

  /// The user-facing sentence for [SyncOrchestratorState.lastPushWarning], or
  /// `null` when there is nothing to say.
  ///
  /// Names a COUNT and a consequence, not an error code: the climber's
  /// question is "is my stuff backed up?", and the honest answer for these
  /// photos is "no, and it won't be". It stays plain and non-alarming because
  /// nothing is broken and no retry is coming — the pixels are simply not on
  /// this device any more. The route/wall/topo metadata DID reach the cloud.
  String? _missingPhotoBytesWarning(PushSyncResult result) {
    final count = result.photosMissingLocalBytes;
    if (count == 0) return null;
    final subject = count == 1 ? '1 photo has' : '$count photos have';
    return
        '$subject no image data left on this device, so '
        '${count == 1 ? 'it' : 'they'} could not be backed up. The topo '
        'details were saved.';
  }

  /// Arms the next retry, [SyncRetrySchedule.delayFor] from now.
  ///
  /// Bounded interval (~2s doubling to a 5min ceiling, jittered), unbounded
  /// attempts: this NEVER gives up while anything is still `dirty` (D-2). The
  /// loop terminates by SUCCESS, not by exhaustion — a retry that finds a
  /// clean database hits [_runPush]'s nothing-pending early-out and simply
  /// returns without re-arming.
  void _scheduleRetry() {
    _consecutivePushFailures++;
    _retryTimer?.cancel();
    final delay = ref
        .read(syncRetryScheduleProvider)
        .delayFor(_consecutivePushFailures);
    _retryTimer = Timer(delay, () => unawaited(pushNow()));
  }

  /// A connectivity transition arrived.
  ///
  /// A REGAIN — and only a regain — is new information: the network was gone
  /// ([NetworkStatus.none]) and is now usable. When one happens:
  ///  - [_fullResyncDue] is re-armed, so the catch-up push re-sends EVERY own
  ///    row rather than trusting `dirty` flags that a swallowed per-table
  ///    failure during the outage may have cleared (D-4's loss-proofness);
  ///  - the armed retry timer is cancelled and BOTH a push and a pull fire
  ///    IMMEDIATELY — the push flushes whatever was edited offline, the pull
  ///    picks up what changed in the cloud meanwhile. §1e requires both;
  ///    pushing only would leave another user's newly-published topo
  ///    invisible until the next resume.
  ///
  /// THREE THINGS THIS DELIBERATELY DOES NOT DO, each of which it used to:
  ///
  /// 1. **It does not reset [_consecutivePushFailures].** That looks kind —
  ///    "don't make the user wait out a 5-minute ceiling after reconnecting"
  ///    — but it conflates two different mechanisms. Responsiveness comes
  ///    from the IMMEDIATE push below, which runs regardless of the counter;
  ///    the counter exists solely to stop hammering a backend that keeps
  ///    failing. Zeroing it here meant a phone oscillating between weak cell
  ///    and none held the backoff at attempt 1 indefinitely. And the premise
  ///    is wrong anyway: a connectivity event is NOT evidence the backend
  ///    recovered — that is exactly what [ConnectivityService.isBackendReachable]
  ///    exists for, because `connectivity_plus` answers "connected" behind a
  ///    captive portal. A push that genuinely succeeds still resets the
  ///    counter, in [_runPush], which is the only place that has actual
  ///    evidence of progress.
  ///
  /// 2. **It does not treat a usable→usable hop as a regain.** wifi→cellular
  ///    fires liberally on a moving phone and means nothing was ever lost.
  ///
  /// 3. **It does not act on every regain.** [_connectivityResyncThrottle]
  ///    coalesces a burst: a flapping link produces none→wifi→none→wifi… and
  ///    each edge is technically a regain, but they carry no new information
  ///    between them. Without this a flap cost a full-library push AND a full
  ///    pull per oscillation. The in-flight guards in [pushNow]/[pullNow] do
  ///    NOT cover this — they collapse only CONCURRENT runs, and sequential
  ///    flaps are not concurrent.
  ///
  /// Losing the network triggers nothing: there is nothing to attempt, and
  /// attempting anyway would just burn a retry attempt and flip the status to
  /// `error`.
  void _onConnectivityChanged(NetworkStatus status) {
    final previous = _lastConnectivityStatus;
    _lastConnectivityStatus = status;
    if (status == NetworkStatus.none) return;
    // Only a genuine none -> usable EDGE. `previous == null` (the very first
    // transition this run) counts, deliberately: we cannot know what came
    // before it, and the conservative reading is "we may have missed an
    // outage".
    if (previous != null && previous != NetworkStatus.none) return;

    final nowMs = ref.read(nowMsProvider)();
    final last = _lastConnectivityResyncAtMs;
    if (last != null &&
        nowMs - last < _connectivityResyncThrottle.inMilliseconds) {
      return;
    }
    _lastConnectivityResyncAtMs = nowMs;

    _retryTimer?.cancel();
    _fullResyncDue = true;
    unawaited(pushNow());
    unawaited(pullNow());
  }

  /// Whether a push that failed did so because THE BACKEND IS UNREACHABLE
  /// ([SyncStatus.offline]) or for some other reason ([SyncStatus.error]).
  ///
  /// S4 fix (§1d): `connectivity_plus` reports INTERFACE state only — it
  /// answers "connected" behind a captive portal and its web implementation
  /// returns wifi unconditionally — so `currentStatus()` can never be the
  /// signal here. [ConnectivityService.isBackendReachable] does a real round
  /// trip to the Supabase origin instead. Called ONLY on the failure path,
  /// so a healthy push costs no extra request.
  ///
  /// A probe that itself throws is treated as REACHABLE: a broken probe must
  /// never let a genuine backend error masquerade as "you're offline".
  Future<SyncStatus> _failureStatus() async {
    try {
      final reachable = await ref
          .read(connectivityServiceProvider)
          .isBackendReachable();
      return reachable ? SyncStatus.error : SyncStatus.offline;
    } catch (e) {
      debugPrint('SyncOrchestrator: reachability probe failed: $e');
      return SyncStatus.error;
    }
  }

  /// #57 fix — public re-entry point for the SAME pull path [build]'s
  /// sign-in-edge listener fires (which now calls THIS method too, rather
  /// than `_runPull()` directly), for every OTHER moment "other users'
  /// shared content may have changed" (app-resume — see `app.dart`'s
  /// `didChangeAppLifecycleState` — and the Community feed/map's manual
  /// pull-to-refresh / "Try again" retry). Before this, `pullOwnAndShared()`
  /// only ever ran once, on the signed-out -> signed-in edge, so another
  /// user's newly-published topo stayed invisible until the next full
  /// sign-in.
  ///
  /// [throttled]: pass `true` ONLY from the app-resume trigger. When `true`
  /// AND a pull last actually started less than [_resumePullThrottle] ago,
  /// this call is a no-op that resolves immediately without touching the
  /// network — see that field's doc for why (web's resume-on-tab-focus
  /// spam). Defaults to `false`, which ALWAYS pulls: the sign-in-edge
  /// listener, pull-to-refresh, the map refresh button, and "Try again" all
  /// rely on that — none of them may ever be silently throttled.
  ///
  /// Guarded against overlapping runs: a call made while an earlier
  /// [pullNow] is still in flight returns THAT SAME [Future] instead of
  /// starting a second, redundant pull — mirrors [_scheduleDebouncedPush]'s
  /// "N rapid triggers collapse into one call" shape, just without the
  /// debounce delay (a refresh gesture/resume wants to run immediately, not
  /// wait out a window). A call made once the in-flight pull has completed
  /// starts a fresh one. This guard and the throttle above are independent:
  /// the throttle can skip a call before it would even reach this guard.
  ///
  /// Never throws and is a safe no-op when signed out or Supabase is
  /// unavailable — it runs through the exact same [_runPull] (and, beneath
  /// that, the already-gated [syncServiceProvider]/[SyncService]) as the
  /// sign-in trigger; see that method's and this class's doc for how that
  /// degrades rather than crashes.
  Future<void> pullNow({bool throttled = false}) {
    if (throttled) {
      final lastStarted = _lastPullStartedAt;
      if (lastStarted != null &&
          _now().difference(lastStarted) < _resumePullThrottle) {
        return Future<void>.value();
      }
    }
    final inFlight = _pullInFlight;
    if (inFlight != null) return inFlight;
    _lastPullStartedAt = _now();
    final future = _runPull();
    _pullInFlight = future;
    unawaited(
      future.whenComplete(() {
        if (identical(_pullInFlight, future)) {
          _pullInFlight = null;
        }
      }),
    );
    return future;
  }

  /// Best-effort "publish my provider picture" on the sign-in edge — see
  /// [ProfileRepository.adoptProviderAvatarUrl] for the policy it applies.
  ///
  /// Swallows everything, deliberately and at BOTH layers. The write itself is
  /// a local Drift row that sync picks up later, but reaching
  /// [profileRepositoryProvider] can throw outright on a container whose
  /// database is unavailable — and an avatar is the least important thing this
  /// listener does. Sign-in must never fail because a picture could not be
  /// copied.
  Future<void> _adoptProviderAvatar(String? providerAvatarUrl) async {
    if (providerAvatarUrl == null) return;
    try {
      await ref
          .read(profileRepositoryProvider)
          .adoptProviderAvatarUrl(providerAvatarUrl);
    } catch (error) {
      debugPrint('masi/profile: could not adopt the provider avatar: $error');
    }
  }

  /// #72 P1 fix: this used to swallow every [PullResult] whole — only the
  /// coarse `outcome` (`pulled`/`skippedSignedOut`) was ever looked at, so a
  /// [PullResult.errors]-carrying partial failure (e.g. the shared side
  /// threw on a malformed cloud row while the own side imported fine, or
  /// vice versa — see that class's doc) was silently discarded, and a
  /// top-level throw only ever reached a `debugPrint` no one but a
  /// developer attached to a debugger would see. Both are now retained in
  /// [SyncOrchestratorState.lastPullError] as one human-readable message —
  /// a PARTIAL success (`outcome == pulled` but `errors` non-empty) is
  /// surfaced there WITHOUT flipping [SyncOrchestratorState.status] away
  /// from [SyncStatus.idle]/`lastSyncedAt` updating (some data DID come
  /// through — this isn't a total failure), while a genuine top-level throw
  /// still sets [SyncStatus.error] exactly as before. Every existing state
  /// transition below is therefore preserved, just augmented with the
  /// message.
  Future<void> _runPull() async {
    state = state.copyWith(status: SyncStatus.syncing);
    // UF-6, and the retry the Library/Feed "Try again" buttons already reach:
    // see [_prepareCloud]. A pull with no client would otherwise come back
    // `skippedSignedOut` — indistinguishable from a genuinely signed-out user
    // — and report `idle` with `lastPullError` CLEARED.
    if (!await _prepareCloud()) return;
    try {
      final result = await ref.read(syncServiceProvider).pullOwnAndShared();
      // `PullResult.skippedSignedOut()` always carries an empty `errors`
      // list (see its doc), so `pullError` naturally comes out `null` in
      // that branch too — clearing any stale message from an earlier
      // signed-in pull rather than leaving it to linger.
      final pullError = result.errors.isEmpty
          ? null
          : 'Sync failed: ${result.errors.join('; ')}';
      switch (result.outcome) {
        case SyncPullOutcome.pulled:
          state = SyncOrchestratorState(
            status: SyncStatus.idle,
            lastSyncedAt: _now(),
            lastPullError: pullError,
            // A pull says nothing about whether local changes reached the
            // cloud — carrying these through is what stops a successful pull
            // from relabelling an unpushed library as "Synced" (S1). The
            // advisory is push-derived for the same reason.
            lastPushError: state.lastPushError,
            lastPushWarning: state.lastPushWarning,
            // Carried, not re-derived here: the prune itself runs AFTER this
            // write (see below), so this write must not clobber whatever the
            // PREVIOUS pull's pass last reported.
            lastPublicPhotoPruneOutcome: state.lastPublicPhotoPruneOutcome,
            // #49 P2 fix: THIS pull's own advisory, straight off `result` —
            // the one place in the app that could read it before now was
            // `sync_service.dart` itself.
            lastSharedPhotoBytesSkipped: result.sharedPhotoBytesSkipped,
            lastSharedPhotoBudgetReason: result.sharedPhotoBudgetReason,
          );
          // AFTER the state write, and deliberately NOT awaited — see
          // [_prunePublicPhotosBestEffort].
          unawaited(_prunePublicPhotosBestEffort());
          // Independent of the prune above (different table, different
          // failure modes) — see [_sweepStaleForeignWallsBestEffort].
          unawaited(_sweepStaleForeignWallsBestEffort());
        case SyncPullOutcome.skippedSignedOut:
          state = SyncOrchestratorState(
            status: SyncStatus.idle,
            lastSyncedAt: state.lastSyncedAt,
            lastPullError: pullError,
            lastPushError: state.lastPushError,
            lastPushWarning: state.lastPushWarning,
            lastPublicPhotoPruneOutcome: state.lastPublicPhotoPruneOutcome,
            lastSharedPhotoBytesSkipped: state.lastSharedPhotoBytesSkipped,
            lastSharedPhotoBudgetReason: state.lastSharedPhotoBudgetReason,
          );
      }
    } catch (e, st) {
      debugPrint('SyncOrchestrator: pullOwnAndShared failed: $e\n$st');
      state = SyncOrchestratorState(
        status: SyncStatus.error,
        lastSyncedAt: state.lastSyncedAt,
        lastPullError: 'Sync failed: $e',
        lastPushError: state.lastPushError,
        lastPushWarning: state.lastPushWarning,
        lastPublicPhotoPruneOutcome: state.lastPublicPhotoPruneOutcome,
        lastSharedPhotoBytesSkipped: state.lastSharedPhotoBytesSkipped,
        lastSharedPhotoBudgetReason: state.lastSharedPhotoBudgetReason,
      );
    }
  }

  /// Gives `PublicPhotoPruneService` its one and only production trigger.
  ///
  /// The service and its policy were fully built and tested but never called,
  /// so nothing evicted other climbers' cached photo bytes under storage
  /// pressure — which is what eventually makes the user's OWN photo imports
  /// fail (`photo_files_web.dart`'s L3 write now throws rather than silently
  /// producing a pixel-less row).
  ///
  /// WHY AFTER A PULL. A pull is the only moment bytes are ADDED to the origin
  /// without the user doing anything, so it is the moment pressure can newly
  /// appear. It is also the moment a prune is cheapest to justify: whatever it
  /// evicts, the very next pull (or `MissingPhotoByteResolver`) can bring back.
  ///
  /// WHY ON *EVERY* SUCCESSFUL PULL, rather than only on a pull that downloaded
  /// something. The obvious gate — `result.photosDownloaded > 0` — is actively
  /// wrong now, because it inverts against the byte budget: a pull that is
  /// ALREADY over the high watermark deliberately downloads ZERO shared photo
  /// bytes ([SharedPhotoBudgetReason.storagePressure]), so gating on "bytes
  /// arrived" would skip the prune in precisely the state that needs it, and
  /// the device would stay wedged over the watermark forever. Running
  /// unconditionally is also genuinely cheap: in the overwhelmingly common case
  /// the pass is ONE `navigator.storage.estimate()` read that returns
  /// [PublicPhotoPruneReason.belowHighWatermark] before touching the database
  /// at all, and on native `estimate()` is always `null`, so the pass is a
  /// permanent no-op ([PublicPhotoPruneReason.noEstimate]) — never an iOS
  /// documents-directory eviction. The pull triggers are themselves already
  /// bounded (sign-in, explicit refresh, and a 30s-throttled resume), so this
  /// cannot become a hot loop. `pullNow`'s in-flight guard means at most one
  /// pull, and therefore at most one of these, is ever outstanding.
  ///
  /// NOT AWAITED, on purpose: the pull's state write has already happened by
  /// the time this starts, so the UI updates on the pull's own timing and a
  /// housekeeping sweep can never delay a refresh spinner or hold
  /// `_pullInFlight` open. `pruneIfUnderPressure` never throws by contract; the
  /// try/catch is belt-and-braces for a fire-and-forget future, where an
  /// escaping error would be unhandled.
  ///
  /// Observability: every pass's full [PublicPhotoPruneOutcome] — reason,
  /// count, and the used-fraction before/after — now lands on
  /// [SyncOrchestratorState.lastPublicPhotoPruneOutcome] (#49 P1 fix), so it
  /// is inspectable from `account_screen.dart` or a debugger attached to a
  /// RELEASE build, not just a `debugPrint` that is silent there (see
  /// `CLAUDE.md`'s devicectl notes on Dart logs vanishing in release). The
  /// `debugPrint` below is UNCHANGED and kept for the local dev-console case;
  /// the two boring reasons (no pressure signal, below the watermark) stay
  /// silent there because they are what every single pull reports and
  /// logging them would drown the console — but they still reach `state`,
  /// same as every other reason, so a caller can always tell "nothing to
  /// report" apart from "no pull has completed yet" (`null`).
  Future<void> _prunePublicPhotosBestEffort() async {
    try {
      final outcome = await ref
          .read(publicPhotoPruneServiceProvider)
          .pruneIfUnderPressure();
      state = SyncOrchestratorState(
        status: state.status,
        lastSyncedAt: state.lastSyncedAt,
        lastPullError: state.lastPullError,
        lastPushError: state.lastPushError,
        lastPushWarning: state.lastPushWarning,
        lastPublicPhotoPruneOutcome: outcome,
        lastSharedPhotoBytesSkipped: state.lastSharedPhotoBytesSkipped,
        lastSharedPhotoBudgetReason: state.lastSharedPhotoBudgetReason,
      );
      switch (outcome.reason) {
        case PublicPhotoPruneReason.noEstimate:
        case PublicPhotoPruneReason.belowHighWatermark:
          break;
        case PublicPhotoPruneReason.unknownSession:
        case PublicPhotoPruneReason.nothingPrunable:
        case PublicPhotoPruneReason.relieved:
        case PublicPhotoPruneReason.estimateLost:
        case PublicPhotoPruneReason.capReached:
        case PublicPhotoPruneReason.poolExhausted:
          debugPrint('SyncOrchestrator: public-photo prune: $outcome');
      }
    } catch (e, st) {
      debugPrint('SyncOrchestrator: public-photo prune threw: $e\n$st');
    }
  }

  /// Gives `ForeignWallSweepService` its one and only production trigger —
  /// same shape as [_prunePublicPhotosBestEffort] just above, for an
  /// unrelated failure mode: a foreign wall this device cached that the
  /// server HARD-deleted (no tombstone, so nothing else ever notices — see
  /// that service's library doc).
  ///
  /// WHY AFTER A PULL, NOT AWAITED, NEVER THROWS: identical reasoning to
  /// [_prunePublicPhotosBestEffort] — a pull is the natural moment to
  /// reconcile the cache, the UI has already rendered the pull's own result
  /// by the time this starts, and `sweepStaleForeignWalls` never throws by
  /// contract (the try/catch here is belt-and-braces for a fire-and-forget
  /// future).
  ///
  /// Deliberately does NOT gate on `result.errors.isEmpty`. The sweep's own
  /// soundness comes entirely from probing the EXACT ids this device holds
  /// (see `ForeignWallSweepService`'s doc) — it does not depend on this
  /// pull's shared-topos fetch having been complete or error-free, so a
  /// harmless error elsewhere in the pull (e.g. a profile fetch hiccup) has
  /// no bearing on whether the sweep's reasoning holds.
  ///
  /// Logged (not surfaced on [SyncOrchestratorState]) — a deliberately
  /// smaller footprint than the photo prune's, since this can only ever
  /// remove rows the server has already confirmed gone, one-way, with
  /// nothing for a user-facing banner to react to.
  Future<void> _sweepStaleForeignWallsBestEffort() async {
    try {
      final outcome = await ref
          .read(foreignWallSweepServiceProvider)
          .sweepStaleForeignWalls();
      switch (outcome.reason) {
        case ForeignWallSweepReason.notKnownOnline:
        case ForeignWallSweepReason.unknownSession:
        case ForeignWallSweepReason.nothingToSweep:
        case ForeignWallSweepReason.nothingToPurge:
          break;
        case ForeignWallSweepReason.probeFailed:
        case ForeignWallSweepReason.swept:
        case ForeignWallSweepReason.unexpectedError:
          debugPrint('SyncOrchestrator: foreign-wall sweep: $outcome');
      }
    } catch (e, st) {
      debugPrint('SyncOrchestrator: foreign-wall sweep threw: $e\n$st');
    }
  }

  DateTime _now() => DateTime.fromMillisecondsSinceEpoch(ref.read(nowMsProvider)());
}

final syncOrchestratorProvider = NotifierProvider<SyncOrchestrator, SyncOrchestratorState>(
  SyncOrchestrator.new,
);
