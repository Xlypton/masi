import 'dart:async';

import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/core/db/database_provider.dart';
import 'package:climbtopo/features/account/application/auth_providers.dart';
import 'package:climbtopo/features/account/data/auth_repository.dart';
import 'package:climbtopo/features/backup/application/sync_orchestrator.dart';
import 'package:climbtopo/features/backup/application/sync_providers.dart';
import 'package:climbtopo/features/backup/data/backup_repository.dart';
import 'package:climbtopo/features/backup/data/connectivity_service.dart';
import 'package:climbtopo/features/backup/data/sync_remote.dart';
import 'package:climbtopo/features/backup/data/sync_service.dart';
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
  Future<void> upsertOwnRows(
    String uid,
    Map<String, List<Map<String, dynamic>>> tablesToRows,
  ) async {
    pushCallCount++;
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
  Future<void> signOut() async {}
}

class _FakeConnectivityService implements ConnectivityService {
  _FakeConnectivityService(this.status);

  NetworkStatus status;

  @override
  Future<NetworkStatus> currentStatus() async => status;
}

/// Builds [syncOrchestratorProvider] AND keeps it actively watched, exactly
/// like `ClimbTopoApp`'s permanent `ref.watch(syncOrchestratorProvider)` does
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
  }) {
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        syncDebounceDurationProvider.overrideWithValue(debounce),
        authStateProvider.overrideWith(
          (ref) => authStream ?? Stream.value(const AuthSessionState.signedOut()),
        ),
        syncServiceProvider.overrideWithValue(
          SyncService(
            db: db,
            backupRepository: BackupRepository(db),
            remote: remote,
            authRepository: syncServiceAuth,
            connectivity: _FakeConnectivityService(connectivity),
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
}
