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
/// Constructed at the app root (`ClimbTopoApp` `ref.watch`es
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
/// actively watching it, which is why `ClimbTopoApp` must keep a live
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
        unawaited(_runPull());
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
