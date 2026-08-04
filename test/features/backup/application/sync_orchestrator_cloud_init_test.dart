import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/core/config/supabase_init_provider.dart';
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

/// UF-6: a `Supabase.initialize` that FAILED must never present as a healthy,
/// synced app.
///
/// The failure shape this file pins down: with no Supabase client every cloud
/// provider degrades to a signed-out no-op that reports SUCCESS —
/// `SyncService.pushOwn`/`pullOwnAndShared` answer `skippedSignedOut` (their
/// `currentSession.uid == null` guard, satisfied by `syncServiceProvider`'s
/// `_SignedOutAuthRepository` fallback), `hasPendingLocalChanges()` answers
/// false for the same reason, and `SyncOrchestrator` translated all of that
/// into [SyncStatus.idle] with every error field CLEARED. The Account screen
/// then reads "Synced" over a library that exists on exactly one device.
///
/// Never touches the real `Supabase` singleton: [supabaseInitializerProvider]
/// is the seam, and [syncServiceProvider] is overridden with a scripted
/// service so the assertions are about the ORCHESTRATOR's translation of a
/// result, not about `SyncService` (which has its own suite).

/// Never called — [_ScriptedSyncService] overrides every method that would
/// reach a remote. `noSuchMethod` rather than 12 stub overrides, so a future
/// `SyncRemote` method cannot silently be answered with a wrong default.
class _UnusedSyncRemote implements SyncRemote {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'the scripted SyncService never touches a remote: '
    '${invocation.memberName}',
  );
}

/// A [SyncService] whose three orchestrator-facing entry points are scripted.
///
/// [signedIn] models the ONLY thing a successful `Supabase.initialize`
/// actually changes from the sync engine's point of view: whether there is an
/// auth session to sync as. While false, both directions answer
/// `skippedSignedOut` exactly like the real service does with no client —
/// which is precisely the "success" the old orchestrator believed.
class _ScriptedSyncService extends SyncService {
  _ScriptedSyncService(AppDatabase db)
    : super(
        db: db,
        backupRepository: BackupRepository(db),
        remote: _UnusedSyncRemote(),
        authRepository: _SignedOutAuth(),
        connectivity: _FakeConnectivity(),
      );

  bool signedIn = false;
  bool hasDirtyRows = true;
  int pushCalls = 0;
  int pullCalls = 0;

  @override
  Future<bool> hasPendingLocalChanges() async => signedIn && hasDirtyRows;

  @override
  Future<PushSyncResult> pushOwn({PushScope scope = PushScope.full}) async {
    pushCalls++;
    if (!signedIn) return const PushSyncResult.skippedSignedOut();
    return const PushSyncResult.pushed(rowsPushed: 1, photosUploaded: 0);
  }

  @override
  Future<PullResult> pullOwnAndShared() async {
    pullCalls++;
    if (!signedIn) return const PullResult.skippedSignedOut();
    return const PullResult.pulled(
      ownRowsPulled: 1,
      sharedRowsPulled: 0,
      photosDownloaded: 0,
      ownImported: true,
      sharedImported: true,
      errors: [],
    );
  }
}

class _SignedOutAuth implements AuthRepository {
  @override
  Stream<AuthSessionState> authStateChanges() => const Stream.empty();

  @override
  AuthSessionState get currentSession => const AuthSessionState.signedOut();

  @override
  Future<void> sendMagicLink(String email) async {}

  @override
  Future<void> signInWithGoogle() async {}

  @override
  Future<void> verifyEmailOtp(String email, String code) async {}

  @override
  Future<void> signOut() async {}
}

/// Reachable by default, so a failed sync classifies as [SyncStatus.error]
/// (the loud one) rather than [SyncStatus.offline] (the reassuring one). Also
/// keeps the real `SystemConnectivityService` — and its live HTTP probe — out
/// of a unit test.
class _FakeConnectivity implements ConnectivityService {
  _FakeConnectivity({this.reachable = true});

  final bool reachable;
  final _controller = StreamController<NetworkStatus>.broadcast();

  @override
  Future<NetworkStatus> currentStatus() async => NetworkStatus.wifi;

  @override
  Future<bool> isBackendReachable() async => reachable;

  @override
  Stream<NetworkStatus> statusChanges() => _controller.stream;

  void dispose() => _controller.close();
}

void main() {
  /// `initAttempts` is consumed one entry per `initialize()` call: an `Object`
  /// makes that attempt throw, `null` makes it succeed. `onInitSuccess` fires
  /// on a successful attempt — used to flip [_ScriptedSyncService.signedIn],
  /// modelling the auth session that only exists once there is a client.
  ({
    ProviderContainer container,
    _ScriptedSyncService service,
    int Function() initCalls,
  })
  makeContainer({
    required List<Object?> initAttempts,
    bool reachable = true,
  }) {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final service = _ScriptedSyncService(db);
    final connectivity = _FakeConnectivity(reachable: reachable);
    addTearDown(connectivity.dispose);

    var initCalls = 0;
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        syncServiceProvider.overrideWithValue(service),
        connectivityServiceProvider.overrideWithValue(connectivity),
        authStateProvider.overrideWith(
          (ref) => const Stream<AuthSessionState>.empty(),
        ),
        supabaseInitializerProvider.overrideWithValue(() async {
          final failure = initCalls < initAttempts.length
              ? initAttempts[initCalls]
              : null;
          initCalls++;
          if (failure != null) throw failure;
          service.signedIn = true;
        }),
      ],
    );
    addTearDown(container.dispose);
    return (
      container: container,
      service: service,
      initCalls: () => initCalls,
    );
  }

  /// Runs boot's init attempt, exactly as `main.dart`'s `_initSupabase` does,
  /// BEFORE the orchestrator is ever built — the real ordering, and the reason
  /// the orchestrator has to seed from the verdict rather than wait for a
  /// change notification.
  Future<void> bootInit(ProviderContainer container) =>
      container.read(cloudInitProvider.notifier).initialize();

  /// Mirrors `MasiApp`'s permanent `ref.watch(syncOrchestratorProvider)`.
  void primeOrchestrator(ProviderContainer container) {
    container.listen<SyncOrchestratorState>(syncOrchestratorProvider, (_, _) {});
  }

  group('a failed Supabase.initialize is visible from the first frame', () {
    test(
      'the orchestrator seeds a NON-idle state with the reason, and does NOT '
      'invent a lastSyncedAt',
      () async {
        final (container: container, service: service, initCalls: _) =
            makeContainer(initAttempts: [StateError('no-network-at-boot')]);
        await bootInit(container);
        primeOrchestrator(container);

        final state = container.read(syncOrchestratorProvider);
        expect(
          state.status,
          isNot(SyncStatus.idle),
          reason: 'idle is what the Account screen renders as "Synced"',
        );
        expect(
          state.lastSyncedAt,
          isNull,
          reason: 'nothing was pushed or pulled, so there is nothing to '
              'timestamp',
        );
        // Both channels, because the two surfaces read different fields: the
        // Library/Feed banner keys off lastPullError, the Account screen off
        // lastPushError.
        expect(state.lastPullError, contains("couldn't connect to the cloud"));
        expect(state.lastPushError, contains("couldn't connect to the cloud"));
        expect(state.lastPullError, contains('no-network-at-boot'));
        // Nothing was attempted — the seed is a statement about the client,
        // not the result of a sync.
        expect(service.pushCalls, 0);
        expect(service.pullCalls, 0);
      },
    );

    test(
      'a HEALTHY init seeds the ordinary idle state — the guard must not '
      'alarm the normal path',
      () async {
        final (container: container, service: _, initCalls: _) = makeContainer(
          initAttempts: const [],
        );
        await bootInit(container);
        primeOrchestrator(container);

        expect(
          container.read(syncOrchestratorProvider),
          const SyncOrchestratorState(),
        );
      },
    );

    test(
      'a never-initialized container (every unit/widget test) also seeds the '
      'ordinary idle state',
      () async {
        final (container: container, service: _, initCalls: _) = makeContainer(
          initAttempts: const [],
        );
        primeOrchestrator(container);

        expect(container.read(cloudInitProvider).status, CloudInitStatus.pending);
        expect(
          container.read(syncOrchestratorProvider),
          const SyncOrchestratorState(),
        );
      },
    );
  });

  group('a failed init never reports a push/pull that did not happen', () {
    test(
      'pushNow keeps the failure up — the nothing-pending early-out must not '
      'clear it on the way past',
      () async {
        final (container: container, service: service, initCalls: _) =
            makeContainer(initAttempts: [StateError('boot-outage'), 'still-down']);
        await bootInit(container);
        primeOrchestrator(container);

        await container.read(syncOrchestratorProvider.notifier).pushNow();

        final state = container.read(syncOrchestratorProvider);
        expect(state.status, SyncStatus.error);
        expect(state.lastPushError, contains("couldn't connect to the cloud"));
        expect(state.lastSyncedAt, isNull);
        expect(
          service.pushCalls,
          0,
          reason: 'there is no client to push through; the guard must return '
              'before the service is asked',
        );
      },
    );

    test('pullNow keeps the failure up and stamps no lastSyncedAt', () async {
      final (container: container, service: service, initCalls: _) =
          makeContainer(initAttempts: [StateError('boot-outage'), 'still-down']);
      await bootInit(container);
      primeOrchestrator(container);

      await container.read(syncOrchestratorProvider.notifier).pullNow();

      final state = container.read(syncOrchestratorProvider);
      expect(state.status, SyncStatus.error);
      expect(state.lastPullError, contains("couldn't connect to the cloud"));
      expect(state.lastSyncedAt, isNull);
      expect(service.pullCalls, 0);
    });

    test(
      'an unreachable backend degrades to offline rather than error — "cloud '
      'unavailable" and "cloud silently broken" are different news',
      () async {
        final (container: container, service: _, initCalls: _) = makeContainer(
          initAttempts: [StateError('boot-outage'), 'still-down'],
          reachable: false,
        );
        await bootInit(container);
        primeOrchestrator(container);

        await container.read(syncOrchestratorProvider.notifier).pullNow();

        expect(container.read(syncOrchestratorProvider).status, SyncStatus.offline);
      },
    );

    test(
      'local-first work keeps functioning: the database is fully usable with '
      'the cloud gone, and nothing threw',
      () async {
        final (container: container, service: _, initCalls: _) = makeContainer(
          initAttempts: [StateError('boot-outage'), 'still-down'],
        );
        await bootInit(container);
        primeOrchestrator(container);

        // A failed init must degrade, never crash — these two calls are the
        // ones a real app makes constantly.
        await container.read(syncOrchestratorProvider.notifier).pushNow();
        await container.read(syncOrchestratorProvider.notifier).pullNow();

        final db = container.read(appDatabaseProvider);
        await db.customStatement(
          "INSERT INTO areas (id, created_at, updated_at, dirty, name) "
          "VALUES ('a1', 1, 1, 1, 'Local area')",
        );
        expect(
          (await db.select(db.areas).get()).single.name,
          'Local area',
        );
      },
    );
  });

  group('retry: a transient boot-time outage recovers without a restart', () {
    test(
      'pullNow re-attempts the init, and once it succeeds the pull actually '
      'runs and every cloud-unavailable message is cleared',
      () async {
        // Attempt 1 (boot) fails; attempt 2 (the retry) succeeds.
        final (container: container, service: service, initCalls: initCalls) =
            makeContainer(initAttempts: [StateError('boot-outage')]);
        await bootInit(container);
        primeOrchestrator(container);
        expect(container.read(cloudInitProvider).isFailed, isTrue);

        // Exactly what the Library/Feed "Couldn't sync — Retry" button does.
        await container.read(syncOrchestratorProvider.notifier).pullNow();

        expect(
          initCalls(),
          2,
          reason: 'the retry must genuinely re-run Supabase.initialize',
        );
        expect(container.read(cloudInitProvider).status, CloudInitStatus.ready);
        expect(
          service.pullCalls,
          1,
          reason: 'once the client exists the pull must proceed in the same '
              'call, not merely arm a later one',
        );

        final state = container.read(syncOrchestratorProvider);
        expect(state.status, SyncStatus.idle);
        expect(state.lastSyncedAt, isNotNull);
        expect(
          state.lastPullError,
          isNull,
          reason: 'the reason no longer holds and must not linger',
        );
        expect(
          state.lastPushError,
          isNull,
          reason: "a successful PULL deliberately carries lastPushError "
              'through, so the recovery has to clear the cloud message itself '
              'or the Account screen reads "Sync error" forever',
        );
      },
    );

    test('pushNow recovers the same way', () async {
      final (container: container, service: service, initCalls: initCalls) =
          makeContainer(initAttempts: [StateError('boot-outage')]);
      await bootInit(container);
      primeOrchestrator(container);

      await container.read(syncOrchestratorProvider.notifier).pushNow();

      expect(initCalls(), 2);
      expect(service.pushCalls, 1);
      final state = container.read(syncOrchestratorProvider);
      expect(state.status, SyncStatus.idle);
      expect(state.lastSyncedAt, isNotNull);
      expect(state.lastPushError, isNull);
    });

    test(
      'a retry that fails again re-reports the CURRENT reason rather than the '
      'stale one',
      () async {
        final (container: container, service: _, initCalls: initCalls) =
            makeContainer(
              initAttempts: [
                StateError('boot-outage'),
                StateError('still-down'),
              ],
            );
        await bootInit(container);
        primeOrchestrator(container);

        await container.read(syncOrchestratorProvider.notifier).pullNow();

        expect(initCalls(), 2);
        final state = container.read(syncOrchestratorProvider);
        expect(state.lastPullError, contains('still-down'));
        expect(state.lastPullError, isNot(contains('boot-outage')));
        expect(state.lastSyncedAt, isNull);
      },
    );
  });
}
