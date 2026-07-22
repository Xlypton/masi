import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/database_provider.dart';
import '../../account/application/auth_providers.dart';
import '../../account/data/auth_repository.dart';
import '../data/sync_service.dart';
import 'sync_providers.dart';

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

  /// The most recent push was skipped because `wifiOnly` is on and the
  /// device isn't currently on wifi (see [ConnectivityService] /
  /// `wifiOnlySettingProvider`).
  offline,
}

/// Immutable snapshot of [SyncOrchestrator]'s state: the current [status]
/// plus the last time a push OR pull actually completed (outcome `pushed`/
/// `pulled`, not merely attempted).
@immutable
class SyncOrchestratorState {
  const SyncOrchestratorState({this.status = SyncStatus.idle, this.lastSyncedAt});

  final SyncStatus status;
  final DateTime? lastSyncedAt;

  SyncOrchestratorState copyWith({SyncStatus? status, DateTime? lastSyncedAt}) =>
      SyncOrchestratorState(
        status: status ?? this.status,
        lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncOrchestratorState &&
          other.status == status &&
          other.lastSyncedAt == lastSyncedAt);

  @override
  int get hashCode => Object.hash(status, lastSyncedAt);

  @override
  String toString() => 'SyncOrchestratorState(status: $status, lastSyncedAt: $lastSyncedAt)';
}

/// Debounce window [SyncOrchestrator] waits after the LAST local table write
/// before firing a single coalesced `pushOwn()` — injectable (default 2s in
/// production) so tests can shrink it to a few milliseconds instead of
/// waiting out the real default per assertion.
final syncDebounceDurationProvider = Provider<Duration>((ref) => const Duration(seconds: 2));

/// Opportunistic background-sync controller: debounced push-on-local-write,
/// pull-once-on-sign-in, and immediate push-on-app-background.
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

  @override
  SyncOrchestratorState build() {
    final db = ref.watch(appDatabaseProvider);
    _dbSubscription = db.tableUpdates().listen((_) => _scheduleDebouncedPush());

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
      }
    });

    ref.onDispose(() {
      _debounceTimer?.cancel();
      _dbSubscription?.cancel();
    });

    return const SyncOrchestratorState();
  }

  /// (Re)schedules a single `pushOwn()` [syncDebounceDurationProvider] from
  /// NOW — every call before the window elapses cancels and restarts the
  /// timer, so N rapid local writes coalesce into exactly one push.
  void _scheduleDebouncedPush() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(ref.read(syncDebounceDurationProvider), () {
      unawaited(_runPush());
    });
  }

  /// Pushes immediately, cancelling any still-pending debounced push —
  /// called when the app is about to leave the foreground and might get
  /// killed before a debounced push would otherwise have fired.
  void onAppPaused() {
    _debounceTimer?.cancel();
    unawaited(_runPush());
  }

  Future<void> _runPush() async {
    state = state.copyWith(status: SyncStatus.syncing);
    try {
      final result = await ref.read(syncServiceProvider).pushOwn();
      switch (result.outcome) {
        case SyncPushOutcome.pushed:
          state = state.copyWith(status: SyncStatus.idle, lastSyncedAt: _now());
        case SyncPushOutcome.skippedSignedOut:
          state = state.copyWith(status: SyncStatus.idle);
        case SyncPushOutcome.skippedNotWifi:
          state = state.copyWith(status: SyncStatus.offline);
      }
    } catch (e, st) {
      debugPrint('SyncOrchestrator: pushOwn failed: $e\n$st');
      state = state.copyWith(status: SyncStatus.error);
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

  Future<void> _runPull() async {
    state = state.copyWith(status: SyncStatus.syncing);
    try {
      final result = await ref.read(syncServiceProvider).pullOwnAndShared();
      switch (result.outcome) {
        case SyncPullOutcome.pulled:
          state = state.copyWith(status: SyncStatus.idle, lastSyncedAt: _now());
        case SyncPullOutcome.skippedSignedOut:
          state = state.copyWith(status: SyncStatus.idle);
      }
    } catch (e, st) {
      debugPrint('SyncOrchestrator: pullOwnAndShared failed: $e\n$st');
      state = state.copyWith(status: SyncStatus.error);
    }
  }

  DateTime _now() => DateTime.fromMillisecondsSinceEpoch(ref.read(nowMsProvider)());
}

final syncOrchestratorProvider = NotifierProvider<SyncOrchestrator, SyncOrchestratorState>(
  SyncOrchestrator.new,
);
