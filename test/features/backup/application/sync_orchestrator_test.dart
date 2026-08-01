import 'dart:async';

import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/account/application/auth_providers.dart';
import 'package:masi/features/account/data/auth_repository.dart';
import 'package:masi/features/backup/application/backup_providers.dart';
import 'package:masi/features/backup/application/sync_orchestrator.dart';
import 'package:masi/features/backup/application/sync_providers.dart';
import 'package:masi/features/backup/data/backup_repository.dart';
import 'package:masi/features/backup/data/connectivity_service.dart';
import 'package:masi/features/backup/data/sync_remote.dart';
import 'package:masi/features/backup/data/sync_service.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A [SyncRemote] that does no real work but counts how many times the
/// push-side (`upsertOwnRows`) and pull-side (`fetchOwnRows`) entry points
/// were called — every `pushOwn()` call that gets past `SyncService`'s
/// signed-out/wifi-only guards calls `upsertOwnRows` exactly once, and every
/// `pullOwnAndShared()` call that gets past its signed-out guard calls
/// `fetchOwnRows` exactly once (alongside `fetchSharedTopos`, always
/// together) — so these two counters are a reliable proxy for "how many
/// times did SyncOrchestrator actually invoke pushOwn()/pullOwnAndShared()".
class _CountingSyncRemote implements SyncRemote {
  int pushCallCount = 0;
  int pullCallCount = 0;

  @override
  Future<List<TablePushOutcome>> upsertOwnRows(
    String uid,
    Map<String, List<Map<String, dynamic>>> tablesToRows,
  ) async {
    pushCallCount++;
    // A clean, fully-landed push: one ok outcome per non-empty table, the
    // shape `SupabaseSyncRemote` returns when every round trip succeeds.
    return [
      for (final entry in tablesToRows.entries)
        if (entry.value.isNotEmpty)
          TablePushOutcome.ok(
            table: entry.key,
            rowsUpserted: entry.value.length,
          ),
    ];
  }

  @override
  Future<Map<String, List<Map<String, dynamic>>>> fetchOwnRows(String uid) async {
    pullCallCount++;
    return {for (final t in syncTableNames) t: <Map<String, dynamic>>[]};
  }

  @override
  Future<Map<String, List<Map<String, dynamic>>>> fetchSharedTopos() async {
    return {
      for (final t in syncTableNames)
        if (t != 'ascents') t: <Map<String, dynamic>>[],
    };
  }

  @override
  Future<Map<String, List<Map<String, dynamic>>>> fetchSharedAscents() async {
    return {'ascents': <Map<String, dynamic>>[]};
  }

  @override
  Future<List<Map<String, dynamic>>> fetchProfiles(Set<String> uids) async {
    return const [];
  }

  @override
  Future<void> uploadPhoto({
    required String uid,
    required String photoId,
    required String ext,
    required List<int> bytes,
  }) async {}

  @override
  Future<List<int>?> downloadPhoto({required String uid, required String objectPath}) async =>
      null;

  @override
  Future<Set<String>> listPhotoObjectPaths(String uid) async => {};

  @override
  Future<void> uploadSharedPhoto({
    required String photoId,
    required String ext,
    required List<int> bytes,
  }) async {}

  @override
  Future<List<int>?> downloadSharedPhoto(String objectPath) async => null;

  @override
  Future<Set<String>> listSharedPhotoObjectPaths() async => {};

  @override
  Future<void> removePhoto({
    required String uid,
    required String photoId,
    required String ext,
  }) async {}

  @override
  Future<void> removeSharedPhoto({
    required String photoId,
    required String ext,
  }) async {}
}

/// A [_CountingSyncRemote] whose [fetchSharedTopos] always throws --
/// exercises the #72 P1 fix's per-section pull isolation (see
/// `sync_service.dart`'s `pullOwnAndShared` doc): the OWN side (via
/// [_CountingSyncRemote.fetchOwnRows]) still succeeds and is counted, while
/// this ONE shared sub-fetch's failure is caught by `SyncService` and
/// surfaced in `PullResult.errors` rather than aborting the whole pull.
class _ThrowingSharedToposSyncRemote extends _CountingSyncRemote {
  @override
  Future<Map<String, List<Map<String, dynamic>>>> fetchSharedTopos() async {
    throw Exception('shared-topos-boom');
  }
}

/// A [_CountingSyncRemote] whose `upsertOwnRows` reports EVERY attempted
/// table as failed — the shape `SupabaseSyncRemote.upsertOwnRows` returns
/// when each table's round trip throws (offline / captive portal / expired
/// JWT). The push still RUNS (so `pushCallCount` increments) but nothing
/// lands, so `PushSyncResult.fullyLanded` is false.
///
/// Flip [failPush] to `false` mid-test to make the NEXT push land cleanly.
class _FailingPushSyncRemote extends _CountingSyncRemote {
  bool failPush = true;

  @override
  Future<List<TablePushOutcome>> upsertOwnRows(
    String uid,
    Map<String, List<Map<String, dynamic>>> tablesToRows,
  ) async {
    if (!failPush) return super.upsertOwnRows(uid, tablesToRows);
    pushCallCount++;
    return [
      for (final entry in tablesToRows.entries)
        if (entry.value.isNotEmpty)
          TablePushOutcome.failed(
            table: entry.key,
            rowsFailed: entry.value.length,
            error: Exception('push-boom'),
          ),
    ];
  }
}

/// Minimal [AuthRepository] test double standing in for the auth session
/// [SyncService] itself reads (`currentSession.uid`) to gate push/pull —
/// deliberately separate from `authStateProvider`'s stream, which is only
/// what [SyncOrchestrator] watches for its pull-on-sign-in edge detection.
class _FakeAuthRepository implements AuthRepository {
  _FakeAuthRepository(this.currentSession);

  @override
  AuthSessionState currentSession;

  @override
  Stream<AuthSessionState> authStateChanges() => const Stream.empty();

  @override
  Future<void> sendMagicLink(String email) async {}

  @override
  Future<void> signInWithGoogle() async {}

  @override
  Future<void> verifyEmailOtp(String email, String code) async {}

  @override
  Future<void> signOut() async {}
}

class _FakeConnectivityService implements ConnectivityService {
  _FakeConnectivityService(
    this.status, {
    this.reachable = true,
    this.probeThrows = false,
  });

  NetworkStatus status;

  /// What [isBackendReachable] reports — the ONLY signal allowed to produce
  /// `SyncStatus.offline` for a failed push (S4).
  bool reachable;

  /// When true, [isBackendReachable] throws instead of answering: a broken
  /// probe must degrade to "reachable" and never masquerade as offline.
  bool probeThrows;

  int probeCallCount = 0;

  /// §1e's connectivity-change seam, written here as part of the ONE merged
  /// rewrite of this class (reconciliation decision #4). Broadcast so more
  /// than one subscriber (orchestrator + assertion) can listen.
  final _statusController = StreamController<NetworkStatus>.broadcast();

  @override
  Future<NetworkStatus> currentStatus() async => status;

  @override
  Future<bool> isBackendReachable() async {
    probeCallCount++;
    if (probeThrows) throw Exception('probe-boom');
    return reachable;
  }

  /// No `@override` yet: `ConnectivityService` does not declare
  /// `statusChanges()` until §1e T7, and annotating a non-overriding member
  /// is an analyzer error. §1e T7 adds the annotation and nothing else.
  Stream<NetworkStatus> statusChanges() => _statusController.stream;

  /// Drives a connectivity transition from a test (§1e).
  void emit(NetworkStatus next) {
    status = next;
    _statusController.add(next);
  }

  void dispose() => _statusController.close();
}

/// Builds [syncOrchestratorProvider] AND keeps it actively watched, exactly
/// like `MasiApp`'s permanent `ref.watch(syncOrchestratorProvider)` does
/// in production (see that widget's doc comment, and `sync_orchestrator.dart`'s
/// class doc comment, for why this matters): `SyncOrchestrator`'s internal
/// `ref.listen(authStateProvider, ...)` only keeps receiving auth-state
/// transitions while THIS provider itself has at least one active
/// watcher/listener — a bare `container.read(syncOrchestratorProvider)`
/// builds it once, but its auth listener silently goes dead the instant
/// nothing is left watching it, so every test that needs pull-on-sign-in (or
/// any other `ref.listen`-based wiring added to this class later) must prime
/// it via this helper instead of a plain `read`.
void primeOrchestrator(ProviderContainer container) {
  container.listen<SyncOrchestratorState>(syncOrchestratorProvider, (_, _) {});
}

void main() {
  /// Wires a fresh in-memory [AppDatabase] + [SyncOrchestrator] behind a
  /// [ProviderContainer], with [syncServiceProvider] overridden to a real
  /// [SyncService] pointed at [remote]/[syncServiceAuth]/[connectivity] (so
  /// push/pull actually run their real gating logic, just against fakes
  /// instead of the network) and [authStateProvider] overridden to
  /// [authStream] (the stream [SyncOrchestrator] watches for the
  /// pull-on-sign-in edge).
  ProviderContainer makeContainer({
    required AppDatabase db,
    required SyncRemote remote,
    required AuthRepository syncServiceAuth,
    Stream<AuthSessionState>? authStream,
    Duration debounce = const Duration(milliseconds: 25),
    bool wifiOnly = false,
    NetworkStatus connectivity = NetworkStatus.wifi,
    _FakeConnectivityService? connectivityService,
    int Function()? nowMs,
  }) {
    final connectivityFake =
        connectivityService ?? _FakeConnectivityService(connectivity);
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        syncDebounceDurationProvider.overrideWithValue(debounce),
        if (nowMs != null) nowMsProvider.overrideWithValue(nowMs),
        authStateProvider.overrideWith(
          (ref) => authStream ?? Stream.value(const AuthSessionState.signedOut()),
        ),
        // §1d/S4: SyncOrchestrator probes real backend reachability to choose
        // between `error` and `offline` for a failed push. Without this
        // override the REAL SystemConnectivityService would be constructed
        // and would issue a live HTTP request from a unit test.
        connectivityServiceProvider.overrideWithValue(connectivityFake),
        syncServiceProvider.overrideWithValue(
          SyncService(
            db: db,
            backupRepository: BackupRepository(db),
            remote: remote,
            authRepository: syncServiceAuth,
            connectivity: connectivityFake,
            wifiOnly: wifiOnly ? () => true : null,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<void> insertArea(AppDatabase db, String id, {String? ownerId}) {
    return db.into(db.areas).insert(
      AreasCompanion.insert(
        id: id,
        createdAt: 100,
        updatedAt: 100,
        ownerId: Value(ownerId),
        name: 'Area $id',
      ),
    );
  }

  group('E1a: debounced push coalescing', () {
    test(
      'several table writes within the debounce window trigger exactly ONE '
      'pushOwn(), and a later write after the window triggers another',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final remote = _CountingSyncRemote();
        final container = makeContainer(
          db: db,
          remote: remote,
          syncServiceAuth: _FakeAuthRepository(
            const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
          ),
          debounce: const Duration(milliseconds: 30),
        );

        // Force-construct the orchestrator so its `tableUpdates()`
        // subscription is live before any writes happen.
        primeOrchestrator(container);
        await Future<void>.delayed(const Duration(milliseconds: 5));

        // Three rapid writes, each well inside the 30ms debounce window.
        await insertArea(db, 'a1', ownerId: 'u1');
        await Future<void>.delayed(const Duration(milliseconds: 8));
        await insertArea(db, 'a2', ownerId: 'u1');
        await Future<void>.delayed(const Duration(milliseconds: 8));
        await insertArea(db, 'a3', ownerId: 'u1');

        // Wait comfortably past the debounce window.
        await Future<void>.delayed(const Duration(milliseconds: 120));

        expect(
          remote.pushCallCount,
          1,
          reason: '3 rapid writes inside the debounce window must coalesce '
              'into exactly one pushOwn() call',
        );

        // A later write, well after the window settled, must trigger a
        // SECOND push rather than being folded into the first.
        await insertArea(db, 'a4', ownerId: 'u1');
        await Future<void>.delayed(const Duration(milliseconds: 120));

        expect(remote.pushCallCount, 2);
      },
    );
  });

  group('E1b: pull-on-sign-in', () {
    test(
      'an auth transition to signed-in triggers exactly one '
      'pullOwnAndShared(); staying signed in on a later re-emission does '
      'NOT trigger another',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final remote = _CountingSyncRemote();
        final authController = StreamController<AuthSessionState>();
        addTearDown(authController.close);
        authController.add(const AuthSessionState.signedOut());

        final container = makeContainer(
          db: db,
          remote: remote,
          syncServiceAuth: _FakeAuthRepository(
            const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
          ),
          authStream: authController.stream,
        );

        primeOrchestrator(container);
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(
          remote.pullCallCount,
          0,
          reason: 'still signed out at startup: no pull yet',
        );

        authController.add(
          const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(remote.pullCallCount, 1);

        // A second emission of the SAME signed-in session (e.g. a token
        // refresh) must not re-trigger another pull.
        authController.add(
          const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(
          remote.pullCallCount,
          1,
          reason: 'already-signed-in re-emitting must not re-pull',
        );
      },
    );
  });

  group('E1c: offline / signed-out is a safe no-op', () {
    test(
      "SyncService's own auth is signed out: a debounced push never "
      'reaches the remote and never throws; status is not `error`',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final remote = _CountingSyncRemote();
        final container = makeContainer(
          db: db,
          remote: remote,
          syncServiceAuth: _FakeAuthRepository(const AuthSessionState.signedOut()),
          debounce: const Duration(milliseconds: 20),
        );

        primeOrchestrator(container);
        await Future<void>.delayed(const Duration(milliseconds: 5));

        await insertArea(db, 'a1');
        await Future<void>.delayed(const Duration(milliseconds: 80));

        expect(
          remote.pushCallCount,
          0,
          reason: 'signed out: pushOwn must never reach the remote',
        );
        expect(
          container.read(syncOrchestratorProvider).status,
          isNot(SyncStatus.error),
        );
      },
    );

    test(
      'wifiOnly=true + cellular: a debounced push is skipped (status '
      '`offline`), the remote is never touched, and nothing throws',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final remote = _CountingSyncRemote();
        final container = makeContainer(
          db: db,
          remote: remote,
          syncServiceAuth: _FakeAuthRepository(
            const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
          ),
          wifiOnly: true,
          connectivity: NetworkStatus.cellular,
          debounce: const Duration(milliseconds: 20),
        );

        primeOrchestrator(container);
        await Future<void>.delayed(const Duration(milliseconds: 5));

        await insertArea(db, 'a1', ownerId: 'u1');
        await Future<void>.delayed(const Duration(milliseconds: 80));

        expect(remote.pushCallCount, 0);
        expect(
          container.read(syncOrchestratorProvider).status,
          SyncStatus.offline,
        );
      },
    );
  });

  group('onAppPaused', () {
    test(
      'pushes immediately, without waiting for the debounce window, and '
      'cancels any still-pending debounced push',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final remote = _CountingSyncRemote();
        final container = makeContainer(
          db: db,
          remote: remote,
          syncServiceAuth: _FakeAuthRepository(
            const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
          ),
          // A long debounce window — if onAppPaused() didn't push
          // immediately, nothing would happen for the lifetime of this test.
          debounce: const Duration(seconds: 30),
        );

        primeOrchestrator(container);
        await Future<void>.delayed(const Duration(milliseconds: 5));

        await insertArea(db, 'a1', ownerId: 'u1');
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(remote.pushCallCount, 0, reason: 'debounce has not elapsed yet');

        container.read(syncOrchestratorProvider.notifier).onAppPaused();
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(remote.pushCallCount, 1);

        // The debounced timer from the earlier write must have been
        // cancelled by onAppPaused(), not left pending to fire a SECOND
        // push once the (long) debounce window eventually elapses.
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(remote.pushCallCount, 1);
      },
    );
  });

  group('#57: pullNow() (manual/resume refresh trigger)', () {
    test(
      'pullNow() invokes pullOwnAndShared() through the SAME path as '
      'pull-on-sign-in, exactly once per call',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final remote = _CountingSyncRemote();
        final container = makeContainer(
          db: db,
          remote: remote,
          syncServiceAuth: _FakeAuthRepository(
            const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
          ),
        );

        primeOrchestrator(container);
        await Future<void>.delayed(const Duration(milliseconds: 5));

        await container.read(syncOrchestratorProvider.notifier).pullNow();

        expect(remote.pullCallCount, 1);
      },
    );

    test(
      'pullNow() is a safe no-op (never throws, never reaches the remote, '
      'status never becomes error) when signed out',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final remote = _CountingSyncRemote();
        final container = makeContainer(
          db: db,
          remote: remote,
          syncServiceAuth: _FakeAuthRepository(const AuthSessionState.signedOut()),
        );

        primeOrchestrator(container);
        await Future<void>.delayed(const Duration(milliseconds: 5));

        await container.read(syncOrchestratorProvider.notifier).pullNow();

        expect(remote.pullCallCount, 0);
        expect(
          container.read(syncOrchestratorProvider).status,
          isNot(SyncStatus.error),
        );
      },
    );

    test(
      'two overlapping pullNow() calls collapse into exactly ONE '
      'pullOwnAndShared() call (the second returns the SAME in-flight '
      'Future rather than starting a redundant pull); a later call made '
      'once that pull has completed starts a fresh one',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final remote = _CountingSyncRemote();
        final container = makeContainer(
          db: db,
          remote: remote,
          syncServiceAuth: _FakeAuthRepository(
            const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
          ),
        );

        primeOrchestrator(container);
        await Future<void>.delayed(const Duration(milliseconds: 5));

        final notifier = container.read(syncOrchestratorProvider.notifier);

        // Two calls fired back-to-back, BEFORE either has had a chance to
        // complete, must be coalesced into one underlying pull.
        final first = notifier.pullNow();
        final second = notifier.pullNow();
        expect(
          identical(first, second),
          isTrue,
          reason: 'an overlapping call must return the SAME in-flight '
              'Future, not a second independent one',
        );

        await Future.wait([first, second]);
        expect(
          remote.pullCallCount,
          1,
          reason: '2 overlapping pullNow() calls must trigger exactly one '
              'pullOwnAndShared() call',
        );

        // The guard must release once the in-flight pull settles — a call
        // made afterward starts a genuinely NEW pull rather than replaying
        // the stale, already-completed Future.
        await notifier.pullNow();
        expect(remote.pullCallCount, 2);
      },
    );
  });

  group('#57 follow-up: pullNow(throttled: true) resume throttle', () {
    test(
      'two throttled pullNow() calls within the throttle window collapse '
      'into ONE pullOwnAndShared() call; a call made once the injected '
      'clock has advanced past the window pulls again',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final remote = _CountingSyncRemote();
        var nowMs = 1000;
        final container = makeContainer(
          db: db,
          remote: remote,
          syncServiceAuth: _FakeAuthRepository(
            const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
          ),
          nowMs: () => nowMs,
        );

        primeOrchestrator(container);
        await Future<void>.delayed(const Duration(milliseconds: 5));

        final notifier = container.read(syncOrchestratorProvider.notifier);

        await notifier.pullNow(throttled: true);
        expect(remote.pullCallCount, 1);

        // A second throttled call, clock unchanged (well inside the 30s
        // window), must be skipped as a no-op rather than pulling again.
        await notifier.pullNow(throttled: true);
        expect(
          remote.pullCallCount,
          1,
          reason: 'a throttled call inside the resume-throttle window must '
              'be a no-op',
        );

        // Advance the injected clock past the throttle window — the next
        // throttled call must pull again.
        nowMs += const Duration(seconds: 31).inMilliseconds;
        await notifier.pullNow(throttled: true);
        expect(remote.pullCallCount, 2);
      },
    );

    test(
      'pullNow() (unthrottled, the default) always pulls regardless of how '
      'recently the last pull started — two sequential unthrottled calls, '
      'each awaited to completion, each pull even though the injected '
      'clock never advances',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final remote = _CountingSyncRemote();
        final container = makeContainer(
          db: db,
          remote: remote,
          syncServiceAuth: _FakeAuthRepository(
            const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
          ),
          nowMs: () => 1000,
        );

        primeOrchestrator(container);
        await Future<void>.delayed(const Duration(milliseconds: 5));

        final notifier = container.read(syncOrchestratorProvider.notifier);

        await notifier.pullNow();
        expect(remote.pullCallCount, 1);

        await notifier.pullNow();
        expect(
          remote.pullCallCount,
          2,
          reason: 'unthrottled callers (pull-to-refresh, the map refresh '
              'button, "Try again", the sign-in-edge listener) must never '
              'be silently skipped, no matter how recently the last pull '
              'started',
        );
      },
    );
  });

  group('#72 P1: _runPull no longer swallows PullResult.errors', () {
    test(
      'a shared-side fetch failure surfaces in lastPullError as a human-'
      'readable "Sync failed: ..." message, WITHOUT flipping status away '
      'from idle -- the own side still succeeded (partial success, not a '
      'total failure)',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final remote = _ThrowingSharedToposSyncRemote();
        final container = makeContainer(
          db: db,
          remote: remote,
          syncServiceAuth: _FakeAuthRepository(
            const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
          ),
          nowMs: () => 123456,
        );

        primeOrchestrator(container);
        await Future<void>.delayed(const Duration(milliseconds: 5));

        await container.read(syncOrchestratorProvider.notifier).pullNow();

        final state = container.read(syncOrchestratorProvider);
        expect(
          state.lastPullError,
          allOf(contains('Sync failed:'), contains('shared-topos-boom')),
          reason: 'the actual PullResult.errors text must be retained, not '
              'discarded by a bare debugPrint',
        );
        expect(
          state.status,
          SyncStatus.idle,
          reason: 'a PARTIAL pull failure (own succeeded, shared threw) '
              'must not be treated as a total failure',
        );
        expect(remote.pullCallCount, 1, reason: 'the own side still ran');
      },
    );

    test(
      'a fully successful pull clears any earlier lastPullError back to '
      'null',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final remote = _CountingSyncRemote();
        final container = makeContainer(
          db: db,
          remote: remote,
          syncServiceAuth: _FakeAuthRepository(
            const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
          ),
        );

        primeOrchestrator(container);
        await Future<void>.delayed(const Duration(milliseconds: 5));

        await container.read(syncOrchestratorProvider.notifier).pullNow();

        expect(container.read(syncOrchestratorProvider).lastPullError, isNull);
      },
    );
  });

  group('status transitions', () {
    test(
      'a successful push sets status idle and stamps lastSyncedAt from '
      'nowMsProvider',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final remote = _CountingSyncRemote();
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            nowMsProvider.overrideWithValue(() => 123456),
            syncDebounceDurationProvider.overrideWithValue(
              const Duration(milliseconds: 15),
            ),
            authStateProvider.overrideWith(
              (ref) => Stream.value(const AuthSessionState.signedOut()),
            ),
            connectivityServiceProvider.overrideWithValue(
              _FakeConnectivityService(NetworkStatus.wifi),
            ),
            syncServiceProvider.overrideWithValue(
              SyncService(
                db: db,
                backupRepository: BackupRepository(db),
                remote: remote,
                authRepository: _FakeAuthRepository(
                  const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
                ),
                connectivity: _FakeConnectivityService(NetworkStatus.wifi),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        primeOrchestrator(container);
        await Future<void>.delayed(const Duration(milliseconds: 5));

        await insertArea(db, 'a1', ownerId: 'u1');
        await Future<void>.delayed(const Duration(milliseconds: 60));

        final state = container.read(syncOrchestratorProvider);
        expect(state.status, SyncStatus.idle);
        expect(state.lastSyncedAt, DateTime.fromMillisecondsSinceEpoch(123456));
      },
    );
  });

  group('§1d (S1): a push that did not land never reports "synced"', () {
    test(
      'a push whose every table failed leaves status NOT idle, leaves '
      'lastSyncedAt untouched, and records lastPushError — pre-fix this set '
      'status: idle + lastSyncedAt: now, which the Account screen rendered '
      'as "Synced • just now"',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final remote = _FailingPushSyncRemote();
        final container = makeContainer(
          db: db,
          remote: remote,
          syncServiceAuth: _FakeAuthRepository(
            const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
          ),
          debounce: const Duration(milliseconds: 15),
          nowMs: () => 123456,
        );

        primeOrchestrator(container);
        await Future<void>.delayed(const Duration(milliseconds: 5));

        await insertArea(db, 'a1', ownerId: 'u1');
        await Future<void>.delayed(const Duration(milliseconds: 80));

        final state = container.read(syncOrchestratorProvider);
        expect(remote.pushCallCount, 1, reason: 'the push did run');
        expect(
          state.status,
          isNot(SyncStatus.idle),
          reason: 'a push where nothing landed must never read as idle',
        );
        expect(
          state.lastSyncedAt,
          isNull,
          reason: 'lastSyncedAt must not be stamped by a push that failed',
        );
        expect(
          state.lastPushError,
          allOf(contains('Sync failed'), contains('push-boom')),
        );
      },
    );

    test(
      'a later FULLY-LANDED push clears lastPushError, flips status back to '
      'idle, and stamps lastSyncedAt',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final remote = _FailingPushSyncRemote();
        final container = makeContainer(
          db: db,
          remote: remote,
          syncServiceAuth: _FakeAuthRepository(
            const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
          ),
          debounce: const Duration(milliseconds: 15),
          nowMs: () => 123456,
        );

        primeOrchestrator(container);
        await Future<void>.delayed(const Duration(milliseconds: 5));

        await insertArea(db, 'a1', ownerId: 'u1');
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(container.read(syncOrchestratorProvider).lastPushError, isNotNull);

        remote.failPush = false;
        await insertArea(db, 'a2', ownerId: 'u1');
        await Future<void>.delayed(const Duration(milliseconds: 80));

        final state = container.read(syncOrchestratorProvider);
        expect(state.status, SyncStatus.idle);
        expect(state.lastSyncedAt, DateTime.fromMillisecondsSinceEpoch(123456));
        expect(state.lastPushError, isNull);
      },
    );

    test(
      'a failed push does NOT touch lastPullError — the two channels stay '
      'independent (a pull-side retry affordance must not light up because a '
      'push failed, and vice versa)',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final remote = _FailingPushSyncRemote();
        final container = makeContainer(
          db: db,
          remote: remote,
          syncServiceAuth: _FakeAuthRepository(
            const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
          ),
          debounce: const Duration(milliseconds: 15),
        );

        primeOrchestrator(container);
        await Future<void>.delayed(const Duration(milliseconds: 5));

        await insertArea(db, 'a1', ownerId: 'u1');
        await Future<void>.delayed(const Duration(milliseconds: 80));

        expect(container.read(syncOrchestratorProvider).lastPullError, isNull);
        expect(container.read(syncOrchestratorProvider).lastPushError, isNotNull);
      },
    );
  });

  group('§1d (S4): SyncStatus.offline comes from a real reachability probe', () {
    /// One failed-push run, returning the state it settled on plus the
    /// connectivity fake so the probe can be inspected.
    Future<({SyncOrchestratorState state, _FakeConnectivityService connectivity})>
    runFailedPush({
      bool reachable = true,
      bool probeThrows = false,
      SyncRemote? remote,
    }) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final connectivity = _FakeConnectivityService(
        // Deliberately wifi: connectivity_plus says "connected" behind a
        // captive portal and reports wifi unconditionally on web, so the
        // interface state must NOT be what decides this.
        NetworkStatus.wifi,
        reachable: reachable,
        probeThrows: probeThrows,
      );
      final container = makeContainer(
        db: db,
        remote: remote ?? _FailingPushSyncRemote(),
        syncServiceAuth: _FakeAuthRepository(
          const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
        ),
        connectivityService: connectivity,
        debounce: const Duration(milliseconds: 15),
      );

      primeOrchestrator(container);
      await Future<void>.delayed(const Duration(milliseconds: 5));

      await insertArea(db, 'a1', ownerId: 'u1');
      await Future<void>.delayed(const Duration(milliseconds: 80));

      return (
        state: container.read(syncOrchestratorProvider),
        connectivity: connectivity,
      );
    }

    test(
      'a failed push with the backend UNREACHABLE reports offline — even '
      'though connectivity_plus reports wifi, which is exactly the captive-'
      'portal / web case that made SyncStatus.offline unreachable before',
      () async {
        final result = await runFailedPush(reachable: false);

        expect(result.state.status, SyncStatus.offline);
        expect(result.state.lastPushError, isNotNull);
        expect(result.state.lastSyncedAt, isNull);
        expect(result.connectivity.probeCallCount, 1);
      },
    );

    test(
      'the SAME failed push with the backend REACHABLE (reachable-but-not-'
      'authenticated, e.g. an expired JWT) reports error, NOT offline — the '
      'two conditions are distinguishable',
      () async {
        final result = await runFailedPush(reachable: true);

        expect(result.state.status, SyncStatus.error);
        expect(result.connectivity.probeCallCount, 1);
      },
    );

    test(
      'a probe that itself throws degrades to error — a broken probe must '
      'never let a genuine backend error masquerade as "you are offline"',
      () async {
        final result = await runFailedPush(probeThrows: true);

        expect(result.state.status, SyncStatus.error);
      },
    );

    test(
      'a SUCCESSFUL push never probes at all — no extra round trip on the '
      'happy path',
      () async {
        final result = await runFailedPush(remote: _CountingSyncRemote());

        expect(result.state.status, SyncStatus.idle);
        expect(result.state.lastPushError, isNull);
        expect(result.connectivity.probeCallCount, 0);
      },
    );
  });
}
