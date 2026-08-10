import 'dart:async';
import 'dart:math';

import 'package:masi/features/backup/domain/shared_topo_scope.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/account/application/auth_providers.dart';
import 'package:masi/features/account/data/auth_repository.dart';
import 'package:masi/features/backup/application/backup_providers.dart';
import 'package:masi/features/backup/application/sync_orchestrator.dart';
import 'package:masi/features/backup/application/sync_providers.dart';
import 'package:masi/features/backup/application/sync_retry_schedule.dart';
import 'package:masi/features/backup/data/backup_repository.dart';
import 'package:masi/features/backup/data/connectivity_service.dart';
import 'package:masi/features/backup/data/sync_remote.dart';
import 'package:masi/core/storage/storage_persistence_service.dart';
import 'package:masi/features/backup/data/sync_service.dart';
import 'package:masi/features/topo/data/photo_files.dart';
import 'package:masi/features/topo/data/public_photo_prune_service.dart';
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
  Future<Map<String, List<Map<String, dynamic>>>> fetchSharedTopos({
    SharedTopoScope scope = const SharedTopoScope.unbounded(),
  }) async {
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
  Future<Map<String, List<Map<String, dynamic>>>> fetchEngagementByParentIds({
    required List<String> ascentIds,
    required List<String> wallIds,
  }) async {
    return {
      'comments': <Map<String, dynamic>>[],
      'likes': <Map<String, dynamic>>[],
    };
  }

  @override
  Future<List<Map<String, dynamic>>> fetchProfiles(Set<String> uids) async {
    return const [];
  }

  @override
  Future<List<String>> fetchVisibleWallIds(List<String> ids) async => const [];

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
  Future<Set<String>> removeSharedPhoto({
    required String photoId,
    required String ext,
  }) async => const {};
}

/// A [_CountingSyncRemote] whose [fetchSharedTopos] always throws --
/// exercises the #72 P1 fix's per-section pull isolation (see
/// `sync_service.dart`'s `pullOwnAndShared` doc): the OWN side (via
/// [_CountingSyncRemote.fetchOwnRows]) still succeeds and is counted, while
/// this ONE shared sub-fetch's failure is caught by `SyncService` and
/// surfaced in `PullResult.errors` rather than aborting the whole pull.
class _ThrowingSharedToposSyncRemote extends _CountingSyncRemote {
  @override
  Future<Map<String, List<Map<String, dynamic>>>> fetchSharedTopos({
    SharedTopoScope scope = const SharedTopoScope.unbounded(),
  }) async {
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

/// A [_CountingSyncRemote] that PERMANENTLY rejects one table while every
/// other table lands, and records how many rows each push handed it.
///
/// The shape of a row the server will never accept (a constraint the client
/// does not know about, a column the deployed schema is missing). The point
/// is that no amount of retrying fixes it, so anything gated on "retry until
/// fully landed" never converges.
class _OneTableRejectingSyncRemote extends _CountingSyncRemote {
  _OneTableRejectingSyncRemote(this.rejectedTable);

  final String rejectedTable;

  /// Total rows handed to `upsertOwnRows` per call, in order.
  final List<int> payloadSizes = [];

  @override
  Future<List<TablePushOutcome>> upsertOwnRows(
    String uid,
    Map<String, List<Map<String, dynamic>>> tablesToRows,
  ) async {
    pushCallCount++;
    payloadSizes.add(
      tablesToRows.values.fold<int>(0, (sum, rows) => sum + rows.length),
    );
    return [
      for (final entry in tablesToRows.entries)
        if (entry.value.isNotEmpty)
          if (entry.key == rejectedTable)
            TablePushOutcome.failed(
              table: entry.key,
              rowsFailed: entry.value.length,
              error: Exception('$rejectedTable permanently rejected'),
            )
          else
            TablePushOutcome.ok(
              table: entry.key,
              rowsUpserted: entry.value.length,
              rowsSkippedNewerRemote: 0,
            ),
    ];
  }
}

/// A [SyncService] that reports a push in which the ROW channel is entirely
/// clean but a photo's BYTES failed — the exact shape §1f's row-withholding
/// produces, and the one reconciliation D-2 is about.
///
/// Built as a `SyncService` subclass rather than a fake `SyncRemote` + real
/// photo fixtures because the contract under test is the ORCHESTRATOR's, not
/// the service's: given `fullyLanded == false` with `rowsFailed == 0` and
/// `errors` empty, `_runPush` must still refuse `idle`, must not stamp
/// `lastSyncedAt`, and must build `lastPushError` from the PHOTO channel — a
/// message assembled only from `errors` would render the useless
/// "Sync failed: 0 change(s) not uploaded — ".
/// A [PublicPhotoPruneService] that records its calls instead of touching
/// storage. Extends the real class so it can stand in for the provider without
/// widening the production type.
class _RecordingPruneService extends PublicPhotoPruneService {
  _RecordingPruneService({
    required super.db,
    this.reason = PublicPhotoPruneReason.belowHighWatermark,
    this.gate,
    this.throws = false,
    this.outcomeOverride,
  }) : super(
         photoFiles: PhotoFiles(),
         storage: const PlatformStoragePersistenceService(),
         currentUid: _noUid,
       );

  static String? _noUid() => null;

  int calls = 0;
  final PublicPhotoPruneReason reason;
  final bool throws;

  /// When set, the pass blocks on this before answering — so a test can prove
  /// the pull does NOT wait for it.
  final Future<void>? gate;

  /// When set, returned verbatim instead of the plain `reason`-only outcome —
  /// lets a test hand back a specific [PublicPhotoPruneOutcome] (e.g. one
  /// with non-empty `deletedKeys` alongside an unmoved fraction — #49's
  /// motivating contradiction).
  final PublicPhotoPruneOutcome? outcomeOverride;

  @override
  Future<PublicPhotoPruneOutcome> pruneIfUnderPressure() async {
    calls++;
    if (gate != null) await gate;
    // `pruneIfUnderPressure` never throws by contract; this models a future
    // regression that breaks that contract, which must still not fail a pull.
    if (throws) throw Exception('prune-boom');
    return outcomeOverride ?? PublicPhotoPruneOutcome(reason: reason);
  }
}

/// A [SyncService] whose pull succeeds having downloaded ZERO photo bytes
/// because the origin is already over the prune high watermark — the exact
/// state in which a `photosDownloaded > 0` prune gate would be inverted and
/// leave the device wedged over the watermark forever.
class _PressuredPullSyncService extends SyncService {
  _PressuredPullSyncService({
    required super.db,
    required super.backupRepository,
    required super.remote,
    required super.authRepository,
    required super.connectivity,
  });

  @override
  Future<PullResult> pullOwnAndShared() async => const PullResult.pulled(
    ownRowsPulled: 4,
    sharedRowsPulled: 9,
    photosDownloaded: 0,
    ownImported: true,
    sharedImported: true,
    errors: [],
    sharedPhotoBytesSkipped: 3,
    sharedPhotoBudgetReason: SharedPhotoBudgetReason.storagePressure,
  );
}

class _PhotoBytesFailedSyncService extends SyncService {
  _PhotoBytesFailedSyncService({
    required super.db,
    required super.backupRepository,
    required super.remote,
    required super.authRepository,
    required super.connectivity,
  });

  int pushCallCount = 0;

  @override
  Future<bool> hasPendingLocalChanges() async => true;

  @override
  Future<PushSyncResult> pushOwn({PushScope scope = PushScope.full}) async {
    pushCallCount++;
    return const PushSyncResult.pushed(
      rowsPushed: 4,
      photosUploaded: 0,
      photosFailed: 1,
      photoErrors: ['photo photo-1: byte upload failed: Exception: boom'],
    );
  }
}

/// A [SyncService] whose push lands COMPLETELY but reports a photo with no
/// local bytes — the non-retryable, permanent condition (L6: pixels and
/// metadata live in separate, non-transactional stores, so pixels can vanish
/// under a surviving row).
///
/// Flip [missingBytes] to 0 to make the NEXT push clean.
class _MissingPhotoBytesSyncService extends SyncService {
  _MissingPhotoBytesSyncService({
    required super.db,
    required super.backupRepository,
    required super.remote,
    required super.authRepository,
    required super.connectivity,
  });

  int missingBytes = 1;

  @override
  Future<bool> hasPendingLocalChanges() async => true;

  @override
  Future<PushSyncResult> pushOwn({PushScope scope = PushScope.full}) async {
    return PushSyncResult.pushed(
      rowsPushed: 5,
      photosUploaded: 0,
      photosMissingLocalBytes: missingBytes,
      photoErrors: [
        for (var i = 0; i < missingBytes; i++)
          'photo photo-$i: no local bytes at "photos/photo-$i.jpg"',
      ],
    );
  }
}

/// A [SyncRetrySchedule] that returns a FIXED delay and records the attempt
/// number it was asked for.
///
/// This is what makes the backoff assertions deterministic without a clock:
/// growth is asserted on [attempts] (`[1, 2, 3, ...]`, and back to `1` after a
/// success), NOT by measuring elapsed time — the actual GROWTH LAW is covered
/// clock-free in `sync_retry_schedule_test.dart`. No test in this file ever
/// waits out a production interval, and the tests that need N cycles drive
/// them with N explicit `await pushNow()` calls while [fixed] is set long
/// enough that the armed timer can never fire on its own.
class _RecordingRetrySchedule extends SyncRetrySchedule {
  _RecordingRetrySchedule(this.fixed)
    : super(base: fixed, ceiling: fixed, random: Random(1));

  final Duration fixed;
  final List<int> attempts = <int>[];

  @override
  Duration delayFor(int attempt) {
    attempts.add(attempt);
    return fixed;
  }
}

/// A [_CountingSyncRemote] whose ROW push fails while [offline] is `true`,
/// and records what actually landed once it isn't — the "remote unreachable,
/// then reachable" half of §1e's end-to-end assertion.
///
/// [pushCallCount] is bumped on every ATTEMPT (before the throw), so a test
/// can distinguish "tried and failed" from "never tried". The throw is NOT
/// what the orchestrator observes: §1d's `pushOwn` converts a whole-call
/// upsert throw into an all-tables-`failed` [PushSyncResult], so the
/// orchestrator sees `fullyLanded == false` and arms the retry from there.
class _OfflineToggleSyncRemote extends _CountingSyncRemote {
  bool offline = true;
  final Map<String, Map<String, dynamic>> pushedAreas = {};

  @override
  Future<List<TablePushOutcome>> upsertOwnRows(
    String uid,
    Map<String, List<Map<String, dynamic>>> tablesToRows,
  ) async {
    pushCallCount++;
    if (offline) throw Exception('network unreachable');
    for (final row in tablesToRows['areas'] ?? const <Map<String, dynamic>>[]) {
      pushedAreas[row['id'] as String] = Map<String, dynamic>.from(row);
    }
    return [
      for (final entry in tablesToRows.entries)
        if (entry.value.isNotEmpty)
          TablePushOutcome.ok(
            table: entry.key,
            rowsUpserted: entry.value.length,
          ),
    ];
  }
}

/// A [_CountingSyncRemote] whose own-row fetch returns one real Area row, so
/// `pullOwnAndShared()` actually WRITES to the local database (which is what
/// used to trigger the spurious re-push). The row omits `dirty`/`remoteId`
/// entirely — the shape a cloud row has now that the push strips them (see
/// `stripLocalOnlySyncColumns`).
class _SeededPullSyncRemote extends _CountingSyncRemote {
  @override
  Future<Map<String, List<Map<String, dynamic>>>> fetchOwnRows(
    String uid,
  ) async {
    pullCallCount++;
    return {
      for (final t in syncTableNames) t: <Map<String, dynamic>>[],
      'areas': <Map<String, dynamic>>[
        {
          'id': 'area-cloud',
          'createdAt': 100,
          'updatedAt': 100,
          'ownerId': uid,
          'name': 'Cloud Area',
        },
      ],
    };
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

  @override
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
    SyncRetrySchedule? retrySchedule,
    int Function()? nowMs,
    // Substitutes a pre-built service for the real one wired below. Used only
    // where the contract under test belongs to the ORCHESTRATOR and the push
    // RESULT has to be dictated exactly (see `_PhotoBytesFailedSyncService`).
    SyncService? syncService,
    PublicPhotoPruneService? pruneService,
  }) {
    final connectivityFake =
        connectivityService ?? _FakeConnectivityService(connectivity);
    addTearDown(connectivityFake.dispose);
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        syncDebounceDurationProvider.overrideWithValue(debounce),
        if (retrySchedule != null)
          syncRetryScheduleProvider.overrideWithValue(retrySchedule),
        if (nowMs != null) nowMsProvider.overrideWithValue(nowMs),
        authStateProvider.overrideWith(
          (ref) => authStream ?? Stream.value(const AuthSessionState.signedOut()),
        ),
        // §1d/S4: SyncOrchestrator probes real backend reachability to choose
        // between `error` and `offline` for a failed push. Without this
        // override the REAL SystemConnectivityService would be constructed
        // and would issue a live HTTP request from a unit test.
        connectivityServiceProvider.overrideWithValue(connectivityFake),
        if (pruneService != null)
          publicPhotoPruneServiceProvider.overrideWithValue(pruneService),
        syncServiceProvider.overrideWithValue(
          syncService ??
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

  /// Inserts one own-row Area, `dirty: true` — the shape EVERY repository
  /// write actually produces (see `LibraryCrudRepository._insertArea`). The
  /// flag matters now that the push is dirty-gated: a fixture row left clean
  /// would be correctly ignored by the orchestrator and every
  /// debounced-push assertion below would vacuously "pass".
  Future<void> insertArea(AppDatabase db, String id, {String? ownerId}) {
    return db.into(db.areas).insert(
      AreasCompanion.insert(
        id: id,
        createdAt: 100,
        updatedAt: 100,
        dirty: const Value(true),
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

  group('§1f (D-2): a push whose PHOTO BYTES failed never reports "synced"', () {
    test(
      'rowsFailed 0 + errors empty + photosFailed 1 must NOT read as idle, '
      'must NOT stamp lastSyncedAt, and lastPushError must carry the PHOTO '
      'channel — reading only `errors` would render '
      '"Sync failed: 0 change(s) not uploaded — " with an empty reason, and '
      'skipping the gate entirely would render "Synced • just now" for a push '
      'in which every photo failed (S1, through the photo path)',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final serviceConnectivity = _FakeConnectivityService(
          NetworkStatus.wifi,
        );
        addTearDown(serviceConnectivity.dispose);
        final service = _PhotoBytesFailedSyncService(
          db: db,
          backupRepository: BackupRepository(db),
          remote: _CountingSyncRemote(),
          authRepository: _FakeAuthRepository(
            const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
          ),
          connectivity: serviceConnectivity,
        );
        final container = makeContainer(
          db: db,
          remote: _CountingSyncRemote(),
          syncServiceAuth: _FakeAuthRepository(
            const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
          ),
          debounce: const Duration(milliseconds: 15),
          nowMs: () => 123456,
          syncService: service,
        );

        primeOrchestrator(container);
        await Future<void>.delayed(const Duration(milliseconds: 5));

        await insertArea(db, 'a1', ownerId: 'u1');
        await Future<void>.delayed(const Duration(milliseconds: 80));

        final state = container.read(syncOrchestratorProvider);
        expect(service.pushCallCount, greaterThanOrEqualTo(1),
            reason: 'the push did run');
        expect(
          state.status,
          isNot(SyncStatus.idle),
          reason:
              'a push whose photo bytes did not land must never read as idle '
              '— its Photos row was withheld, so the ROW channel is clean',
        );
        expect(
          state.lastSyncedAt,
          isNull,
          reason:
              'lastSyncedAt must not be stamped: the photo is not in the cloud',
        );
        expect(
          state.lastPushError,
          allOf(
            contains('Sync failed'),
            contains('1 photo(s) not uploaded'),
            contains('byte upload failed'),
          ),
          reason:
              'the message must be built from errors + photoErrors, not from '
              'errors alone',
        );
      },
    );
  });

  group('L6: a photo with no local bytes is TOLD to the user, never retried', () {
    ({ProviderContainer container, _MissingPhotoBytesSyncService service})
    makeMissingBytesContainer(AppDatabase db) {
      final serviceConnectivity = _FakeConnectivityService(NetworkStatus.wifi);
      addTearDown(serviceConnectivity.dispose);
      final service = _MissingPhotoBytesSyncService(
        db: db,
        backupRepository: BackupRepository(db),
        remote: _CountingSyncRemote(),
        authRepository: _FakeAuthRepository(
          const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
        ),
        connectivity: serviceConnectivity,
      );
      final container = makeContainer(
        db: db,
        remote: _CountingSyncRemote(),
        syncServiceAuth: _FakeAuthRepository(
          const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
        ),
        debounce: const Duration(milliseconds: 15),
        nowMs: () => 123456,
        syncService: service,
      );
      return (container: container, service: service);
    }

    test(
      'the push still reports idle + a fresh lastSyncedAt (it IS fully landed '
      '— nothing is retryable) but records a lastPushWarning naming the '
      'photo count, so the user learns the photo is not backed up instead of '
      'reading "Synced • just now" and believing everything is safe',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final m = makeMissingBytesContainer(db);

        primeOrchestrator(m.container);
        await Future<void>.delayed(const Duration(milliseconds: 5));
        await insertArea(db, 'a1', ownerId: 'u1');
        await Future<void>.delayed(const Duration(milliseconds: 80));

        final state = m.container.read(syncOrchestratorProvider);
        expect(
          state.status,
          SyncStatus.idle,
          reason:
              'nothing is retryable, so the app must NOT be pinned outside '
              'idle — that would stop the retry loop ever terminating',
        );
        expect(state.lastSyncedAt, isNotNull);
        expect(
          state.lastPushError,
          isNull,
          reason: 'this is not a failure and must not read as one',
        );
        expect(
          state.lastPushWarning,
          allOf(
            contains('1 photo has'),
            contains('could not be backed up'),
          ),
          reason:
              'counted-but-unsurfaced is the hole: photoErrors is only read on '
              'the NOT-fully-landed branch, so this push would say nothing',
        );
      },
    );

    test(
      'the advisory self-clears on the next push once the condition stops '
      'holding — it is re-derived every push, never latched',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final m = makeMissingBytesContainer(db);

        primeOrchestrator(m.container);
        await Future<void>.delayed(const Duration(milliseconds: 5));
        await insertArea(db, 'a1', ownerId: 'u1');
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(
          m.container.read(syncOrchestratorProvider).lastPushWarning,
          isNotNull,
        );

        m.service.missingBytes = 0;
        await m.container.read(syncOrchestratorProvider.notifier).pushNow();

        expect(
          m.container.read(syncOrchestratorProvider).lastPushWarning,
          isNull,
        );
      },
    );
  });

  group('S10: push in-flight guard', () {
    test(
      'two concurrent push triggers result in exactly ONE in-flight push '
      '(the second returns the SAME Future) -- before this, onAppPaused() '
      'firing mid-push ran a second concurrent full push, duplicating the '
      'LWW pre-check, the upserts and the photo uploads',
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
          // Long window so the coalesced follow-up cannot fire mid-test.
          debounce: const Duration(seconds: 30),
        );

        primeOrchestrator(container);
        await Future<void>.delayed(const Duration(milliseconds: 5));

        // Seed BEFORE the first push: the nothing-pending early-out applies
        // in every scope now, so a push against a clean database never
        // reaches the remote and there is no in-flight window to guard.
        await insertArea(db, 'a1', ownerId: 'u1');

        final notifier = container.read(syncOrchestratorProvider.notifier);
        final first = notifier.pushNow();
        final second = notifier.pushNow();
        expect(
          identical(first, second),
          isTrue,
          reason: 'an overlapping call must return the SAME in-flight Future',
        );

        await Future.wait([first, second]);
        expect(remote.pushCallCount, 1);

        // The guard must release once the push settles. The first push
        // confirmed and cleared a1, so seed a second dirty row for this one
        // to have something to send.
        await insertArea(db, 'a2', ownerId: 'u1');
        await notifier.pushNow();
        expect(remote.pushCallCount, 2);
      },
    );
  });

  group('S2: retry with backoff until clean', () {
    test(
      'a push that fails is retried on the injected backoff, with NO '
      'further user action and NO further local write, and the attempt '
      'number handed to the schedule grows 1, 2, 3',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final remote = _OfflineToggleSyncRemote();
        // An hour-long fixed delay: the armed retry timer can NEVER fire
        // inside this test, so each cycle below is exactly one explicit,
        // fully-awaited pushNow() and the recorded attempt numbers are exact
        // rather than "however many happened to complete in N ms".
        final schedule = _RecordingRetrySchedule(const Duration(hours: 1));
        final container = makeContainer(
          db: db,
          remote: remote,
          syncServiceAuth: _FakeAuthRepository(
            const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
          ),
          // Far longer than the test: no debounced push can interleave.
          debounce: const Duration(seconds: 30),
          retrySchedule: schedule,
        );

        primeOrchestrator(container);
        await Future<void>.delayed(const Duration(milliseconds: 5));

        final notifier = container.read(syncOrchestratorProvider.notifier);
        await insertArea(db, 'a1', ownerId: 'u1');

        // Three consecutive FAILED pushes. pushNow() cancels the armed
        // _retryTimer on entry, so an explicit call is one retry cycle.
        for (var i = 0; i < 3; i++) {
          await notifier.pushNow();
        }

        expect(
          remote.pushCallCount,
          3,
          reason: 'each retry must re-attempt without another local write',
        );
        expect(
          schedule.attempts,
          [1, 2, 3],
          reason: 'consecutive failures must escalate the attempt number',
        );
        expect(
          container.read(syncOrchestratorProvider).status,
          SyncStatus.error,
          reason:
              'the §1d probe reports reachable by default, so a failed '
              'push classifies as error rather than offline',
        );
      },
    );

    test(
      'the backoff RESETS after a success: a later failure starts again at '
      'attempt 1',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final remote = _OfflineToggleSyncRemote();
        final schedule = _RecordingRetrySchedule(const Duration(hours: 1));
        final container = makeContainer(
          db: db,
          remote: remote,
          syncServiceAuth: _FakeAuthRepository(
            const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
          ),
          debounce: const Duration(seconds: 30),
          retrySchedule: schedule,
        );

        primeOrchestrator(container);
        await Future<void>.delayed(const Duration(milliseconds: 5));

        final notifier = container.read(syncOrchestratorProvider.notifier);
        await insertArea(db, 'a1', ownerId: 'u1');

        await notifier.pushNow();
        expect(schedule.attempts, [1]);

        remote.offline = false;
        await notifier.pushNow();
        expect(container.read(syncOrchestratorProvider).status, SyncStatus.idle);

        schedule.attempts.clear();
        remote.offline = true;
        await insertArea(db, 'a2', ownerId: 'u1');
        await notifier.pushNow();

        expect(
          schedule.attempts,
          [1],
          reason: 'a confirmed push must reset the failure counter',
        );
      },
    );

    test(
      'the retry loop TERMINATES once nothing is dirty, in DIRTY-ONLY scope -- '
      'a clean database hits the nothing-pending early-out and never reaches '
      'the remote, so this is a loop with unbounded attempts, not an '
      'unbounded loop. The FULL-scope half of that guarantee is covered by '
      '"the loop still TERMINATES when nothing is dirty even in FULL scope"; '
      'this test alone never established it',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final remote = _CountingSyncRemote();
        final schedule = _RecordingRetrySchedule(const Duration(hours: 1));
        final container = makeContainer(
          db: db,
          remote: remote,
          syncServiceAuth: _FakeAuthRepository(
            const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
          ),
          debounce: const Duration(seconds: 30),
          retrySchedule: schedule,
        );

        primeOrchestrator(container);
        await Future<void>.delayed(const Duration(milliseconds: 5));

        final notifier = container.read(syncOrchestratorProvider.notifier);
        await insertArea(db, 'a1', ownerId: 'u1');

        await notifier.pushNow();
        final settled = remote.pushCallCount;
        expect(settled, 1, reason: 'the dirty row was pushed exactly once');

        // The confirmed push cleared `dirty`, which itself fires
        // tableUpdates(). A follow-up push must find nothing pending and
        // never touch the network.
        await notifier.pushNow();
        expect(
          remote.pushCallCount,
          settled,
          reason: 'a clean database must not keep re-pushing',
        );
        expect(schedule.attempts, isEmpty, reason: 'nothing ever failed');
      },
    );
  });

  group('S9: a pull does not trigger a re-push', () {
    test(
      'importing a pulled snapshot marks nothing dirty and reaches the '
      'remote with no push -- before this, every pull that wrote anything '
      "fired the same tableUpdates() the debounced push listens to",
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final remote = _SeededPullSyncRemote();
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

        final notifier = container.read(syncOrchestratorProvider.notifier);
        // Consume the app-start full-resync push so the assertion below is
        // about the PULL, not about that one-off safety net.
        await notifier.pushNow();
        final pushesBefore = remote.pushCallCount;

        await notifier.pullNow();
        await Future<void>.delayed(const Duration(milliseconds: 80));

        expect(
          remote.pushCallCount,
          pushesBefore,
          reason: "a pull's own writes must not schedule a push",
        );
        final imported = await (db.select(
          db.areas,
        )..where((t) => t.id.equals('area-cloud'))).getSingle();
        expect(imported.dirty, isFalse);
      },
    );
  });

  group('S3: connectivity regain', () {
    test(
      'a regain event triggers BOTH a push and a pull, well inside the '
      'debounce window and with no further local write -- before this, '
      'nothing in lib reacted to the network coming back at all',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final remote = _CountingSyncRemote();
        final connectivity = _FakeConnectivityService(NetworkStatus.none);
        final container = makeContainer(
          db: db,
          remote: remote,
          syncServiceAuth: _FakeAuthRepository(
            const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
          ),
          // Deliberately far longer than the test: only the regain event can
          // possibly produce the push asserted below.
          debounce: const Duration(seconds: 30),
          connectivityService: connectivity,
        );

        primeOrchestrator(container);
        await Future<void>.delayed(const Duration(milliseconds: 5));

        await insertArea(db, 'a1', ownerId: 'u1');
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(remote.pushCallCount, 0, reason: 'the 30s debounce is pending');
        expect(remote.pullCallCount, 0);

        connectivity.emit(NetworkStatus.wifi);
        await Future<void>.delayed(const Duration(milliseconds: 40));

        expect(remote.pushCallCount, 1);
        expect(remote.pullCallCount, 1);
        expect(container.read(syncOrchestratorProvider).status, SyncStatus.idle);
      },
    );

    test(
      'a transition to NetworkStatus.none triggers nothing -- losing the '
      'network is not a reason to attempt a sync',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final remote = _CountingSyncRemote();
        final connectivity = _FakeConnectivityService(NetworkStatus.wifi);
        final container = makeContainer(
          db: db,
          remote: remote,
          syncServiceAuth: _FakeAuthRepository(
            const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
          ),
          debounce: const Duration(seconds: 30),
          connectivityService: connectivity,
        );

        primeOrchestrator(container);
        await Future<void>.delayed(const Duration(milliseconds: 5));

        await insertArea(db, 'a1', ownerId: 'u1');
        connectivity.emit(NetworkStatus.none);
        await Future<void>.delayed(const Duration(milliseconds: 40));

        expect(remote.pushCallCount, 0);
        expect(remote.pullCallCount, 0);
      },
    );

    test(
      'a regain pushes IMMEDIATELY rather than waiting out the armed backoff, '
      'and re-arms the full-scope safety net — so a device that comes back '
      'after a long outage re-sends everything rather than trusting flags a '
      'swallowed failure may have cleared',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final remote = _OfflineToggleSyncRemote();
        // An hour, so an armed retry can never be mistaken for the
        // regain-triggered push asserted below.
        final schedule = _RecordingRetrySchedule(const Duration(hours: 1));
        final connectivity = _FakeConnectivityService(NetworkStatus.none);
        final container = makeContainer(
          db: db,
          remote: remote,
          syncServiceAuth: _FakeAuthRepository(
            const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
          ),
          debounce: const Duration(seconds: 30),
          retrySchedule: schedule,
          connectivityService: connectivity,
        );

        primeOrchestrator(container);
        await Future<void>.delayed(const Duration(milliseconds: 5));

        final notifier = container.read(syncOrchestratorProvider.notifier);
        await insertArea(db, 'a1', ownerId: 'u1');

        // Establish "mid-backoff" DETERMINISTICALLY rather than by waiting.
        await notifier.pushNow();
        expect(schedule.attempts, [1]);
        expect(remote.pushedAreas, isEmpty);

        schedule.attempts.clear();
        remote.offline = false;
        connectivity.emit(NetworkStatus.wifi);
        await Future<void>.delayed(const Duration(milliseconds: 60));

        expect(remote.pushedAreas.keys, contains('a1'));
        expect(
          schedule.attempts,
          isEmpty,
          reason: 'the regain push succeeded, so no retry was ever armed',
        );
      },
    );
  });

  group('S2: the retry loop CONVERGES — scope stops escalating', () {
    Future<void> insertSector(
      AppDatabase db,
      String id, {
      required String areaId,
    }) {
      return db
          .into(db.sectors)
          .insert(
            SectorsCompanion.insert(
              id: id,
              createdAt: 100,
              updatedAt: 100,
              dirty: const Value(true),
              ownerId: const Value('u1'),
              areaId: areaId,
              name: 'Sector $id',
              sortOrder: 0,
            ),
          );
    }

    test(
      'ONE permanently-rejected row must not make every future push re-send '
      'the WHOLE library: the full-scope safety net retires once a full push '
      'has RUN, not once one has fully landed — a row the server always '
      'rejects means fullyLanded is never true, so the scope never came back '
      'down and the payload never shrank',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final remote = _OneTableRejectingSyncRemote('sectors');
        final schedule = _RecordingRetrySchedule(const Duration(hours: 1));
        final container = makeContainer(
          db: db,
          remote: remote,
          syncServiceAuth: _FakeAuthRepository(
            const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
          ),
          debounce: const Duration(seconds: 30),
          retrySchedule: schedule,
        );

        primeOrchestrator(container);
        await Future<void>.delayed(const Duration(milliseconds: 5));

        await insertArea(db, 'a1', ownerId: 'u1');
        await insertArea(db, 'a2', ownerId: 'u1');
        await insertArea(db, 'a3', ownerId: 'u1');
        await insertSector(db, 's1', areaId: 'a1');
        await insertSector(db, 's2', areaId: 'a1');
        await insertSector(db, 's3', areaId: 'a1');

        final notifier = container.read(syncOrchestratorProvider.notifier);
        await notifier.pushNow();
        await notifier.pushNow();
        await notifier.pushNow();

        expect(
          remote.payloadSizes.first,
          6,
          reason: 'the first push is full scope by design (app start)',
        );
        expect(
          remote.payloadSizes.sublist(1),
          everyElement(3),
          reason:
              'the three areas LANDED and went clean, so only the three '
              'permanently-rejected sectors should still be sent; [6,6,6] '
              'means the whole library is re-sent forever',
        );
      },
    );

    test(
      'the loop still TERMINATES when nothing is dirty even in FULL scope — '
      'the nothing-pending early-out used to be gated on dirtyOnly, so a '
      'fully-synced device with _fullResyncDue armed (true on every app start '
      'and every connectivity regain) retried a failing push every 5 minutes '
      'forever with nothing whatsoever to send',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final remote = _FailingPushSyncRemote();
        final schedule = _RecordingRetrySchedule(const Duration(hours: 1));
        final container = makeContainer(
          db: db,
          remote: remote,
          syncServiceAuth: _FakeAuthRepository(
            const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
          ),
          debounce: const Duration(seconds: 30),
          retrySchedule: schedule,
        );

        primeOrchestrator(container);
        await Future<void>.delayed(const Duration(milliseconds: 5));

        // Nothing dirty at all, and _fullResyncDue is still armed from build.
        final notifier = container.read(syncOrchestratorProvider.notifier);
        await notifier.pushNow();

        expect(
          remote.pushCallCount,
          0,
          reason: 'there is nothing to push, whatever the scope says',
        );
        expect(
          schedule.attempts,
          isEmpty,
          reason: 'and therefore nothing to retry',
        );
      },
    );
  });

  group('signing out clears the push-side error', () {
    test(
      'a failed push followed by a sign-out leaves lastPushError null — it '
      'used to survive, so the Account screen read "Sync error" indefinitely '
      'with no way to clear it (a signed-out push can never succeed)',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final remote = _FailingPushSyncRemote();
        final auth = _FakeAuthRepository(
          const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
        );
        final container = makeContainer(
          db: db,
          remote: remote,
          syncServiceAuth: auth,
          debounce: const Duration(milliseconds: 15),
          retrySchedule: _RecordingRetrySchedule(const Duration(hours: 1)),
        );

        primeOrchestrator(container);
        await Future<void>.delayed(const Duration(milliseconds: 5));
        await insertArea(db, 'a1', ownerId: 'u1');
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(
          container.read(syncOrchestratorProvider).lastPushError,
          isNotNull,
          reason: 'precondition: the push really did fail',
        );

        auth.currentSession = const AuthSessionState.signedOut();
        await container.read(syncOrchestratorProvider.notifier).pushNow();

        expect(container.read(syncOrchestratorProvider).lastPushError, isNull);
        expect(container.read(syncOrchestratorProvider).status, SyncStatus.idle);
      },
    );
  });

  group('S3: a FLAPPING connection must not defeat the backoff', () {
    ({
      ProviderContainer container,
      _FailingPushSyncRemote remote,
      _RecordingRetrySchedule schedule,
      _FakeConnectivityService connectivity,
    })
    makeFlapContainer(AppDatabase db, int Function() nowMs) {
      final remote = _FailingPushSyncRemote();
      // An hour, so no armed retry can ever fire on its own and be mistaken
      // for a regain-triggered push.
      final schedule = _RecordingRetrySchedule(const Duration(hours: 1));
      final connectivity = _FakeConnectivityService(NetworkStatus.none);
      final container = makeContainer(
        db: db,
        remote: remote,
        syncServiceAuth: _FakeAuthRepository(
          const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
        ),
        debounce: const Duration(seconds: 30),
        retrySchedule: schedule,
        connectivityService: connectivity,
        nowMs: nowMs,
      );
      return (
        container: container,
        remote: remote,
        schedule: schedule,
        connectivity: connectivity,
      );
    }

    test(
      'four none->wifi oscillations inside the throttle window cost ONE push '
      'and ONE pull, not four of each — a phone oscillating between weak cell '
      'and none is a phone at a crag, which is the exact scenario this whole '
      'effort exists for, and it used to get a full-library push AND a full '
      'pull per oscillation',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        var clockMs = 1000;
        final f = makeFlapContainer(db, () => clockMs);

        primeOrchestrator(f.container);
        await Future<void>.delayed(const Duration(milliseconds: 5));
        await insertArea(db, 'a1', ownerId: 'u1');

        for (var i = 0; i < 4; i++) {
          f.connectivity.emit(NetworkStatus.none);
          f.connectivity.emit(NetworkStatus.wifi);
          clockMs += 20; // 80 ms total — far inside the throttle window
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
        await Future<void>.delayed(const Duration(milliseconds: 60));

        expect(
          f.remote.pushCallCount,
          1,
          reason: 'the oscillations after the first carry no new information',
        );
        expect(f.remote.pullCallCount, 1);
      },
    );

    test(
      'regains SPACED OUT past the throttle window each sync, but the attempt '
      'counter keeps GROWING across them — a connectivity event is not '
      'evidence the backend recovered (that is what the reachability probe is '
      'for), so resetting the failure count on one let a flapping network '
      'hold the backoff at attempt 1 forever',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        var clockMs = 1000;
        final f = makeFlapContainer(db, () => clockMs);

        primeOrchestrator(f.container);
        await Future<void>.delayed(const Duration(milliseconds: 5));
        await insertArea(db, 'a1', ownerId: 'u1');

        for (var i = 0; i < 3; i++) {
          f.connectivity.emit(NetworkStatus.none);
          f.connectivity.emit(NetworkStatus.wifi);
          clockMs += 60000; // a minute apart: each is a genuine regain
          await Future<void>.delayed(const Duration(milliseconds: 40));
        }
        await Future<void>.delayed(const Duration(milliseconds: 60));

        expect(
          f.remote.pushCallCount,
          3,
          reason: 'each spaced-out regain really is new information',
        );
        expect(
          f.schedule.attempts,
          [1, 2, 3],
          reason:
              'the backoff must widen while the backend keeps failing; [1,1,1] '
              'means a flapping network defeated it entirely',
        );
      },
    );

    test(
      'a usable->usable transition (wifi to cellular) is NOT a regain: '
      'nothing was ever lost, so there is nothing to catch up on',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        var clockMs = 1000;
        final f = makeFlapContainer(db, () => clockMs);

        primeOrchestrator(f.container);
        await Future<void>.delayed(const Duration(milliseconds: 5));
        await insertArea(db, 'a1', ownerId: 'u1');

        // Establish a known baseline: one genuine regain.
        f.connectivity.emit(NetworkStatus.wifi);
        await Future<void>.delayed(const Duration(milliseconds: 40));
        final afterRegain = f.remote.pushCallCount;

        clockMs += 60000;
        f.connectivity.emit(NetworkStatus.cellular);
        clockMs += 60000;
        f.connectivity.emit(NetworkStatus.wifi);
        await Future<void>.delayed(const Duration(milliseconds: 60));

        expect(
          f.remote.pushCallCount,
          afterRegain,
          reason:
              'the network never went away, so neither hop is a regain — '
              'these fire liberally on a phone moving between cells',
        );
      },
    );
  });

  group('§1e end-to-end: nothing recorded offline is ever stranded', () {
    test(
      'create a topo with the remote UNREACHABLE, then make the remote '
      'reachable WITHOUT any further local write and WITHOUT any user '
      'action -> the topo reaches the remote and the local row goes clean',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final remote = _OfflineToggleSyncRemote();
        // The ONLY test in this fragment that depends on a timer firing —
        // that is precisely its subject ("no user action"). A 10ms envelope
        // against a 250ms recovery window leaves ~25x headroom for one cycle.
        final schedule = _RecordingRetrySchedule(
          const Duration(milliseconds: 10),
        );
        final container = makeContainer(
          db: db,
          remote: remote,
          syncServiceAuth: _FakeAuthRepository(
            const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
          ),
          debounce: const Duration(milliseconds: 15),
          retrySchedule: schedule,
        );

        primeOrchestrator(container);
        await Future<void>.delayed(const Duration(milliseconds: 5));

        // ---- 1. The user creates a topo while the network is down. --------
        await insertArea(db, 'a-offline', ownerId: 'u1');
        await Future<void>.delayed(const Duration(milliseconds: 80));

        expect(
          remote.pushCallCount,
          greaterThanOrEqualTo(1),
          reason: 'the debounced push must at least have been ATTEMPTED',
        );
        expect(remote.pushedAreas, isEmpty, reason: 'nothing landed');
        // `isNot(idle)`, NOT `== error`: this is the one test whose retry loop
        // is genuinely running on a 10ms timer, so at any sampled instant the
        // status legitimately alternates between `syncing` (a retry cycle in
        // flight) and `error` (the cycle that just failed). Pinning `error`
        // here is a race — it flaked ~1 run in 8. The claim that matters is
        // stated in the reason and is race-free; `SyncStatus.error`
        // specifically is asserted deterministically by the S2 backoff group,
        // which drives its cycles with explicit awaited pushNow() calls.
        expect(
          container.read(syncOrchestratorProvider).status,
          isNot(SyncStatus.idle),
          reason: 'a push that did not land must not report success',
        );
        var row = await (db.select(
          db.areas,
        )..where((t) => t.id.equals('a-offline'))).getSingle();
        expect(
          row.dirty,
          isTrue,
          reason: 'a failed push must leave the row flagged for retry',
        );

        // ---- 2. The network comes back. No local write, no user action. ---
        remote.offline = false;
        await Future<void>.delayed(const Duration(milliseconds: 250));

        // ---- 3. The topo is in the cloud and the row is clean. ------------
        expect(remote.pushedAreas.keys, contains('a-offline'));
        expect(
          remote.pushedAreas['a-offline']!['name'],
          'Area a-offline',
          reason: 'the real row, not an empty placeholder, must have landed',
        );
        expect(
          remote.pushedAreas['a-offline']!.keys,
          isNot(contains('dirty')),
          reason: 'the payload must not carry local-only bookkeeping (S8)',
        );
        row = await (db.select(
          db.areas,
        )..where((t) => t.id.equals('a-offline'))).getSingle();
        expect(row.dirty, isFalse);
        expect(container.read(syncOrchestratorProvider).status, SyncStatus.idle);
        expect(
          schedule.attempts,
          isNotEmpty,
          reason:
              'the recovery must have come from the RETRY loop, not from a '
              'fresh trigger',
        );
      },
    );

    test(
      'the retry loop survives a long outage: many consecutive failures '
      'never exhaust it, and the row still lands when the remote returns',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final remote = _OfflineToggleSyncRemote();
        // An hour: the armed retry timer can never fire, so every cycle below
        // is one explicit awaited pushNow() and the attempt numbers are
        // EXACT. Asserting the requested attempt numbers is both stronger and
        // deterministic, unlike counting completions in a wall-clock budget.
        final schedule = _RecordingRetrySchedule(const Duration(hours: 1));
        final container = makeContainer(
          db: db,
          remote: remote,
          syncServiceAuth: _FakeAuthRepository(
            const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
          ),
          // Far longer than the test: no debounced push can interleave.
          debounce: const Duration(seconds: 30),
          retrySchedule: schedule,
        );

        primeOrchestrator(container);
        await Future<void>.delayed(const Duration(milliseconds: 5));

        final notifier = container.read(syncOrchestratorProvider.notifier);
        await insertArea(db, 'a-long-outage', ownerId: 'u1');

        const cycles = 8;
        for (var i = 0; i < cycles; i++) {
          await notifier.pushNow();
        }

        expect(
          schedule.attempts,
          [for (var a = 1; a <= cycles; a++) a],
          reason:
              'unbounded attempts -- no cap, no terminal give-up state, and '
              'the attempt number escalates by exactly one each time',
        );
        expect(remote.pushCallCount, cycles);
        expect(remote.pushedAreas, isEmpty);
        expect(
          (await (db.select(
            db.areas,
          )..where((t) => t.id.equals('a-long-outage'))).getSingle()).dirty,
          isTrue,
          reason: 'every failed attempt must leave the row flagged',
        );
        expect(
          container.read(syncOrchestratorProvider).status,
          SyncStatus.error,
        );

        remote.offline = false;
        await notifier.pushNow();

        expect(remote.pushedAreas.keys, contains('a-long-outage'));
        expect(
          schedule.attempts,
          hasLength(cycles),
          reason: 'the successful push armed no further retry',
        );
        expect(
          (await (db.select(
            db.areas,
          )..where((t) => t.id.equals('a-long-outage'))).getSingle()).dirty,
          isFalse,
        );
        expect(
          container.read(syncOrchestratorProvider).status,
          SyncStatus.idle,
        );
      },
    );
  });

  group('public-photo pruning is wired to a successful pull', () {
    test(
      'a successful pull runs exactly ONE prune pass — before this the service '
      'and its policy were fully built and tested but had NO production call '
      'site, so nothing ever evicted other climbers\' cached photo bytes under '
      'storage pressure',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final prune = _RecordingPruneService(db: db);
        final container = makeContainer(
          db: db,
          remote: _CountingSyncRemote(),
          syncServiceAuth: _FakeAuthRepository(
            const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
          ),
          pruneService: prune,
        );
        primeOrchestrator(container);

        await container.read(syncOrchestratorProvider.notifier).pullNow();
        await pumpEventQueue();

        expect(prune.calls, 1);
        expect(container.read(syncOrchestratorProvider).status, SyncStatus.idle);
      },
    );

    test(
      'a pull that downloaded ZERO photo bytes BECAUSE of storage pressure '
      'still prunes: gating on photosDownloaded > 0 would invert against the '
      'byte budget and leave a device that is over the watermark wedged there '
      'forever',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final prune = _RecordingPruneService(
          db: db,
          reason: PublicPhotoPruneReason.relieved,
        );
        final container = makeContainer(
          db: db,
          remote: _CountingSyncRemote(),
          syncServiceAuth: _FakeAuthRepository(
            const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
          ),
          pruneService: prune,
          syncService: _PressuredPullSyncService(
            db: db,
            backupRepository: BackupRepository(db),
            remote: _CountingSyncRemote(),
            authRepository: _FakeAuthRepository(
            const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
          ),
            connectivity: _FakeConnectivityService(NetworkStatus.wifi),
          ),
        );
        primeOrchestrator(container);

        await container.read(syncOrchestratorProvider.notifier).pullNow();
        await pumpEventQueue();

        expect(prune.calls, 1);
      },
    );

    test(
      'the prune does NOT delay the pull: pullNow completes, the state is '
      'already idle with a fresh lastSyncedAt, and the in-flight guard is '
      'released while the sweep is still running',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final gate = Completer<void>();
        addTearDown(() {
          if (!gate.isCompleted) gate.complete();
        });
        final prune = _RecordingPruneService(db: db, gate: gate.future);
        final container = makeContainer(
          db: db,
          remote: _CountingSyncRemote(),
          syncServiceAuth: _FakeAuthRepository(
            const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
          ),
          pruneService: prune,
        );
        primeOrchestrator(container);

        await container.read(syncOrchestratorProvider.notifier).pullNow();

        expect(prune.calls, 1, reason: 'the sweep started');
        expect(gate.isCompleted, isFalse, reason: 'and has NOT finished');
        final state = container.read(syncOrchestratorProvider);
        expect(state.status, SyncStatus.idle);
        expect(state.lastSyncedAt, isNotNull);
        expect(state.lastPullError, isNull);
      },
    );

    test(
      'a prune that THROWS cannot fail the pull — it is fire-and-forget, so an '
      'escaping error would be an unhandled async error, not a sync failure',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final prune = _RecordingPruneService(db: db, throws: true);
        final container = makeContainer(
          db: db,
          remote: _CountingSyncRemote(),
          syncServiceAuth: _FakeAuthRepository(
            const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
          ),
          pruneService: prune,
        );
        primeOrchestrator(container);

        await container.read(syncOrchestratorProvider.notifier).pullNow();
        await pumpEventQueue();

        expect(prune.calls, 1);
        final state = container.read(syncOrchestratorProvider);
        expect(state.status, SyncStatus.idle);
        expect(state.lastPullError, isNull);
      },
    );

    test(
      'a SIGNED-OUT pull does not prune: with no identity nothing can be '
      'proven foreign, so there is nothing to sweep and no reason to read the '
      'storage estimate',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final prune = _RecordingPruneService(db: db);
        final container = makeContainer(
          db: db,
          remote: _CountingSyncRemote(),
          syncServiceAuth: _FakeAuthRepository(const AuthSessionState.signedOut()),
          pruneService: prune,
        );
        primeOrchestrator(container);

        await container.read(syncOrchestratorProvider.notifier).pullNow();
        await pumpEventQueue();

        expect(prune.calls, 0);
      },
    );

    test(
      '#49 P1: the prune outcome reaches state, not just debugPrint — a '
      'caller (a UI, a debugger attached to a RELEASE build) can read what '
      'the last pass did without a dev console, which is silent for '
      'debugPrint in release (see CLAUDE.md)',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final prune = _RecordingPruneService(
          db: db,
          reason: PublicPhotoPruneReason.relieved,
        );
        final container = makeContainer(
          db: db,
          remote: _CountingSyncRemote(),
          syncServiceAuth: _FakeAuthRepository(
            const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
          ),
          pruneService: prune,
        );
        primeOrchestrator(container);

        await container.read(syncOrchestratorProvider.notifier).pullNow();
        await pumpEventQueue();

        final outcome = container
            .read(syncOrchestratorProvider)
            .lastPublicPhotoPruneOutcome;
        expect(outcome, isNotNull);
        expect(outcome!.reason, PublicPhotoPruneReason.relieved);
      },
    );

    test(
      '#49 P1: a pass that "deleted" keys without freeing any of the quota — '
      'the exact pre-fix bug (50 deletions, fraction 0.80 -> 0.80) — is '
      'visible in state as a self-evident contradiction: deletedKeys is '
      'non-empty but fractionFreed is (near) zero',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final contradictoryOutcome = PublicPhotoPruneOutcome(
          reason: PublicPhotoPruneReason.capReached,
          deletedKeys: List.generate(50, (i) => 'photos/foreign-$i.jpg'),
          usedFractionBefore: 0.80,
          usedFractionAfter: 0.80,
        );
        final prune = _RecordingPruneService(
          db: db,
          outcomeOverride: contradictoryOutcome,
        );
        final container = makeContainer(
          db: db,
          remote: _CountingSyncRemote(),
          syncServiceAuth: _FakeAuthRepository(
            const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
          ),
          pruneService: prune,
        );
        primeOrchestrator(container);

        await container.read(syncOrchestratorProvider.notifier).pullNow();
        await pumpEventQueue();

        final outcome = container
            .read(syncOrchestratorProvider)
            .lastPublicPhotoPruneOutcome!;
        expect(outcome.deletedKeys, hasLength(50));
        expect(
          outcome.fractionFreed,
          0.0,
          reason: '50 "deletions" that freed nothing must be readable as '
              'exactly that, not lost inside a deletedKeys count alone',
        );
      },
    );

    test(
      '#49 P1: an unrelated, fully-landed push does not clobber the last '
      'prune outcome — it describes on-device storage housekeeping, not the '
      'push/pull it happened to run alongside',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final prune = _RecordingPruneService(
          db: db,
          reason: PublicPhotoPruneReason.relieved,
        );
        final container = makeContainer(
          db: db,
          remote: _CountingSyncRemote(),
          syncServiceAuth: _FakeAuthRepository(
            const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
          ),
          pruneService: prune,
        );
        primeOrchestrator(container);

        await container.read(syncOrchestratorProvider.notifier).pullNow();
        await pumpEventQueue();
        final afterPull = container
            .read(syncOrchestratorProvider)
            .lastPublicPhotoPruneOutcome;
        expect(afterPull, isNotNull);

        // A real, fully-landed push (a dirty row present) — the branch that
        // actually writes a fresh state, and so the one most likely to
        // forget to carry an unrelated field forward.
        await insertArea(db, 'area-1', ownerId: 'u1');
        await container.read(syncOrchestratorProvider.notifier).pushNow();

        expect(
          container.read(syncOrchestratorProvider).status,
          SyncStatus.idle,
          reason: 'sanity: the push actually landed',
        );
        expect(
          container.read(syncOrchestratorProvider).lastPublicPhotoPruneOutcome,
          same(afterPull),
        );
      },
    );
  });

  group('#49 P2: shared photo budget advisory reaches state', () {
    test(
      'a pull that withheld shared photo bytes for storage pressure records '
      'BOTH the count and the reason on state — before this,  '
      'PullResult.sharedPhotoBytesSkipped/sharedPhotoBudgetReason were read '
      'by nothing outside sync_service.dart',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final container = makeContainer(
          db: db,
          remote: _CountingSyncRemote(),
          syncServiceAuth: _FakeAuthRepository(
            const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
          ),
          syncService: _PressuredPullSyncService(
            db: db,
            backupRepository: BackupRepository(db),
            remote: _CountingSyncRemote(),
            authRepository: _FakeAuthRepository(
              const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
            ),
            connectivity: _FakeConnectivityService(NetworkStatus.wifi),
          ),
        );
        primeOrchestrator(container);

        await container.read(syncOrchestratorProvider.notifier).pullNow();

        final state = container.read(syncOrchestratorProvider);
        expect(state.lastSharedPhotoBytesSkipped, 3);
        expect(
          state.lastSharedPhotoBudgetReason,
          SharedPhotoBudgetReason.storagePressure,
        );
        // Not an error: the pull still succeeded cleanly.
        expect(state.lastPullError, isNull);
        expect(state.status, SyncStatus.idle);
      },
    );

    test(
      'a later pull that is back within budget CLEARS the advisory — it must '
      'not linger once the condition that produced it stops holding',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final remote = _CountingSyncRemote();
        final auth = _FakeAuthRepository(
          const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
        );
        final connectivity = _FakeConnectivityService(NetworkStatus.wifi);
        final container = makeContainer(
          db: db,
          remote: remote,
          syncServiceAuth: auth,
          syncService: _PressuredPullSyncService(
            db: db,
            backupRepository: BackupRepository(db),
            remote: remote,
            authRepository: auth,
            connectivity: connectivity,
          ),
        );
        primeOrchestrator(container);
        await container.read(syncOrchestratorProvider.notifier).pullNow();
        expect(
          container.read(syncOrchestratorProvider).lastSharedPhotoBudgetReason,
          SharedPhotoBudgetReason.storagePressure,
        );

        // Swap in a plain, within-budget SyncService and pull again.
        final container2 = makeContainer(
          db: db,
          remote: remote,
          syncServiceAuth: auth,
        );
        primeOrchestrator(container2);
        await container2.read(syncOrchestratorProvider.notifier).pullNow();

        expect(
          container2.read(syncOrchestratorProvider).lastSharedPhotoBudgetReason,
          SharedPhotoBudgetReason.withinBudget,
        );
        expect(
          container2.read(syncOrchestratorProvider).lastSharedPhotoBytesSkipped,
          0,
        );
      },
    );
  });
}
