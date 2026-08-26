import 'dart:io';
import 'dart:typed_data' show Uint8List;

import 'package:masi/features/backup/domain/shared_topo_scope.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/account/data/auth_repository.dart';
import 'package:masi/features/backup/application/sync_providers.dart';
import 'package:masi/features/backup/data/backup_repository.dart';
import 'package:masi/features/backup/data/connectivity_service.dart';
import 'package:masi/features/backup/data/storage_pagination.dart';
import 'package:masi/features/backup/data/sync_remote.dart';
import 'package:masi/features/backup/data/sync_service.dart';
import 'package:masi/core/storage/storage_persistence_service.dart';
import 'package:masi/core/storage/storage_persistence_types.dart';
import 'package:masi/features/topo/data/photo_files.dart';
import 'package:masi/features/topo/data/public_photo_prune_service.dart';
import 'package:drift/drift.dart'
    show ApplyInterceptor, QueryExecutor, QueryInterceptor, Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../../support/fixture_photo.dart';

/// In-memory [SyncRemote] test double: a `Map` per table (row id -> row
/// json, camelCase keys per drift's `toJson()`) standing in for the
/// row-level cloud tables, plus two `Map<String, List<int>>`s standing in
/// for the private (`<uid>/...`) and shared (`shared/...`) prefixes of the
/// `topo-photos` Storage bucket — no [SupabaseClient], no network.
class FakeSyncRemote implements SyncRemote {
  final Map<String, Map<String, Map<String, dynamic>>> _rows = {
    for (final table in syncTableNames) table: <String, Map<String, dynamic>>{},
  };

  final Map<String, List<int>> privateStorage = {};
  final Map<String, List<int>> sharedStorage = {};
  final List<String> uploadedPrivatePaths = [];
  final List<String> uploadedSharedPaths = [];
  final List<String> removedPrivatePaths = [];
  final List<String> removedSharedPaths = [];

  /// Ordered log of every remote MUTATION this fake received, so a test can
  /// assert the push ORDER (bytes before metadata — S5) rather than only the
  /// end state. Entries are `'upload:<objectPath>'` and `'upsert:<table>'`.
  final List<String> callLog = [];

  /// Every object path [downloadPhoto]/[downloadSharedPhoto] was asked for,
  /// in order — so a test can prove a pull does NOT re-fetch bytes this
  /// device already holds. Metered cellular data and (on web) the same
  /// origin quota the user's own topos live in are both spent per entry.
  final List<String> downloadRequests = [];

  @override
  Future<List<TablePushOutcome>> upsertOwnRows(
    String uid,
    Map<String, List<Map<String, dynamic>>> tablesToRows,
  ) async {
    final outcomes = <TablePushOutcome>[];
    for (final tableName in syncTableNames) {
      final rows = tablesToRows[tableName];
      if (rows == null || rows.isEmpty) continue;
      callLog.add('upsert:$tableName');
      var upserted = 0;
      var skipped = 0;
      for (final row in rows) {
        assert(
          row['ownerId'] == uid,
          'upsertOwnRows($uid): row ${row['id']} in $tableName has ownerId '
          '${row['ownerId']}',
        );
        // Client-side LWW guard on push (#2), mirroring
        // SupabaseSyncRemote.upsertOwnRows: drop the row if a cloud row
        // already exists here with a strictly newer updatedAt.
        final remote = _rows[tableName]![row['id'] as String];
        if (!shouldPushLww(
          localUpdatedAt: row['updatedAt'] as int,
          remoteUpdatedAt: remote?['updatedAt'] as int?,
        )) {
          skipped++;
          continue;
        }
        _rows[tableName]![row['id'] as String] = Map<String, dynamic>.from(row);
        upserted++;
      }
      // Mirrors SupabaseSyncRemote's contract (§1d): one outcome per
      // ATTEMPTED table, LWW-skips counted as a success.
      outcomes.add(
        TablePushOutcome.ok(
          table: tableName,
          rowsUpserted: upserted,
          rowsSkippedNewerRemote: skipped,
        ),
      );
    }
    return outcomes;
  }

  @override
  Future<Map<String, List<Map<String, dynamic>>>> fetchOwnRows(String uid) async {
    return {
      for (final tableName in syncTableNames)
        tableName: filterValidSyncRows(
          [
            for (final row in _rows[tableName]!.values)
              if (row['ownerId'] == uid) Map<String, dynamic>.from(row),
          ],
          const ['id'],
          debugLabel: 'own $tableName',
        ),
    };
  }

  /// The scope the last [fetchSharedTopos] was called with, so a test can
  /// assert what the service ASKED for and not only what it got back.
  SharedTopoScope? lastSharedScope;

  /// Applies [scope] the way `SupabaseSyncRemote` does server-side (W-1): a
  /// bounding box on the coordinates, a cap, and a SEPARATE small budget for
  /// rows with no coordinates so they cannot silently vanish.
  ///
  /// Reproduced here rather than stubbed out because "the scope was passed" and
  /// "the scope did anything" are different claims, and a fake that ignores it
  /// can only ever prove the first.
  List<Map<String, dynamic>> _applyScope(
    List<Map<String, dynamic>> walls,
    SharedTopoScope scope,
  ) {
    if (scope.isUnbounded) return walls;
    int byNewest(Map<String, dynamic> a, Map<String, dynamic> b) =>
        ((b['updatedAt'] as int?) ?? 0).compareTo((a['updatedAt'] as int?) ?? 0);

    final box = scope.boundingBox;
    if (box == null) {
      final all = [...walls]..sort(byNewest);
      return scope.limit > 0 ? all.take(scope.limit).toList() : all;
    }

    final within = <Map<String, dynamic>>[];
    final uncoordinated = <Map<String, dynamic>>[];
    for (final wall in walls) {
      final lat = (wall['latitude'] as num?)?.toDouble();
      final lng = (wall['longitude'] as num?)?.toDouble();
      if (lat == null || lng == null) {
        uncoordinated.add(wall);
      } else if (lat >= box.minLatitude &&
          lat <= box.maxLatitude &&
          lng >= box.minLongitude &&
          lng <= box.maxLongitude) {
        within.add(wall);
      }
    }
    within.sort(byNewest);
    uncoordinated.sort(byNewest);
    return [
      ...(scope.limit > 0 ? within.take(scope.limit) : within),
      ...(scope.uncoordinatedLimit > 0
          ? uncoordinated.take(scope.uncoordinatedLimit)
          : uncoordinated),
    ];
  }

  @override
  Future<Map<String, List<Map<String, dynamic>>>> fetchSharedTopos({
    SharedTopoScope scope = const SharedTopoScope.unbounded(),
  }) async {
    lastSharedScope = scope;
    // Mirrors SupabaseSyncRemote.fetchSharedTopos's row-validity guard (P0
    // fix, #72): a malformed wall row (missing id/sectorId) is skipped
    // rather than throwing on the `as String` casts below, so a test can
    // seed one directly into `_rows['walls']` to exercise the fix.
    final sharedWalls = _applyScope(
      filterValidSyncRows(
        [
          for (final wall in _rows['walls']!.values)
            if (wall['visibility'] == 'shared') Map<String, dynamic>.from(wall),
        ],
        const ['id', 'sectorId'],
        debugLabel: 'shared wall',
      ),
      scope,
    );
    final wallIds = {for (final w in sharedWalls) w['id'] as String};
    final sectorIds = {for (final w in sharedWalls) w['sectorId'] as String};
    final sectors = [
      for (final sector in _rows['sectors']!.values)
        if (sectorIds.contains(sector['id'])) Map<String, dynamic>.from(sector),
    ];
    final areaIds = {for (final s in sectors) s['areaId'] as String};
    final areas = [
      for (final area in _rows['areas']!.values)
        if (areaIds.contains(area['id'])) Map<String, dynamic>.from(area),
    ];
    final photos = [
      for (final photo in _rows['photos']!.values)
        if (wallIds.contains(photo['wallId'])) Map<String, dynamic>.from(photo),
    ];
    final routes = [
      for (final route in _rows['routes']!.values)
        if (wallIds.contains(route['wallId'])) Map<String, dynamic>.from(route),
    ];
    final comments = [
      for (final comment in _rows['comments']!.values)
        if (wallIds.contains(comment['wallId'])) Map<String, dynamic>.from(comment),
    ];
    final likes = [
      for (final like in _rows['likes']!.values)
        if (wallIds.contains(like['wallId'])) Map<String, dynamic>.from(like),
    ];
    return {
      'areas': areas,
      'sectors': sectors,
      'walls': sharedWalls,
      'photos': photos,
      'routes': routes,
      'comments': comments,
      'likes': likes,
      // NOTE: deliberately no 'ascents' key — a shared wall does not imply
      // its ascents are public; see [fetchSharedAscents] for the separate,
      // ascent-level opt-in feed (Feature #12).
    };
  }

  @override
  Future<Map<String, List<Map<String, dynamic>>>> fetchSharedAscents() async {
    final ascents = [
      for (final row in _rows['ascents']!.values)
        if (row['visibility'] == 'shared') Map<String, dynamic>.from(row),
    ];
    if (ascents.isEmpty) {
      return {
        'areas': <Map<String, dynamic>>[],
        'sectors': <Map<String, dynamic>>[],
        'walls': <Map<String, dynamic>>[],
        'photos': <Map<String, dynamic>>[],
        'routes': <Map<String, dynamic>>[],
        'ascents': <Map<String, dynamic>>[],
      };
    }

    // Mirrors SupabaseSyncRemote.fetchSharedAscents: the minimal ancestor/
    // reference chain (NOT a wall's full context) so the FK-enforced
    // routeId/wallId (and a route's photoId, a wall's sectorId, a sector's
    // areaId) all resolve locally without leaking a private wall's other
    // routes/photos.
    final wallIds = {for (final a in ascents) a['wallId'] as String};
    final routeIds = {for (final a in ascents) a['routeId'] as String};

    final walls = [
      for (final wall in _rows['walls']!.values)
        if (wallIds.contains(wall['id'])) Map<String, dynamic>.from(wall),
    ];
    final sectorIds = {for (final w in walls) w['sectorId'] as String};
    final sectors = [
      for (final sector in _rows['sectors']!.values)
        if (sectorIds.contains(sector['id'])) Map<String, dynamic>.from(sector),
    ];
    final areaIds = {for (final s in sectors) s['areaId'] as String};
    final areas = [
      for (final area in _rows['areas']!.values)
        if (areaIds.contains(area['id'])) Map<String, dynamic>.from(area),
    ];
    final routes = [
      for (final route in _rows['routes']!.values)
        if (routeIds.contains(route['id'])) Map<String, dynamic>.from(route),
    ];
    final photoIds = {for (final r in routes) r['photoId'] as String};
    final photos = [
      for (final photo in _rows['photos']!.values)
        if (photoIds.contains(photo['id'])) Map<String, dynamic>.from(photo),
    ];

    return {
      'areas': areas,
      'sectors': sectors,
      'walls': walls,
      'photos': photos,
      'routes': routes,
      'ascents': ascents,
    };
  }

  @override
  Future<void> uploadPhoto({
    required String uid,
    required String photoId,
    required String ext,
    required List<int> bytes,
  }) async {
    final path = '$uid/$photoId$ext';
    privateStorage[path] = bytes;
    uploadedPrivatePaths.add(path);
    callLog.add('upload:$path');
  }

  @override
  Future<List<int>?> downloadPhoto({
    required String uid,
    required String objectPath,
  }) async {
    downloadRequests.add(objectPath);
    return privateStorage[objectPath];
  }

  /// Every `(limit, offset)` either listing was asked for, so a test can
  /// prove the CALLER paged rather than only that the fake returned
  /// everything.
  final List<({int limit, int offset})> listPageRequests = [];

  /// The page size this fake truncates at — the storage client's own
  /// `SearchOptions` default. Faithfulness here is what makes the 150-object
  /// test meaningful: a fake that returned all 150 in one page could never
  /// reproduce S6, and the test would be a false green.
  int get listPageLimit => kStoragePageSize;

  List<String> _listPage(Iterable<String> all, int limit, int offset) {
    final sorted = all.toList()..sort();
    if (offset >= sorted.length) return const [];
    final capped = limit > listPageLimit ? listPageLimit : limit;
    final end = offset + capped;
    return sorted.sublist(offset, end > sorted.length ? sorted.length : end);
  }

  Future<Set<String>> _listAll(Iterable<String> all) async {
    final collected = await collectPagedObjects<String>((limit, offset) async {
      listPageRequests.add((limit: limit, offset: offset));
      return _listPage(all, limit, offset);
    });
    return collected.toSet();
  }

  @override
  Future<Set<String>> listPhotoObjectPaths(String uid) async {
    final prefix = '$uid/';
    return _listAll(privateStorage.keys.where((p) => p.startsWith(prefix)));
  }

  @override
  Future<void> uploadSharedPhoto({
    required String photoId,
    required String ext,
    required List<int> bytes,
  }) async {
    final path = sharedPhotoPath(photoId, ext);
    sharedStorage[path] = bytes;
    uploadedSharedPaths.add(path);
    callLog.add('upload:$path');
  }

  @override
  Future<List<int>?> downloadSharedPhoto(String objectPath) async {
    downloadRequests.add(objectPath);
    return sharedStorage[objectPath];
  }

  @override
  Future<Set<String>> listSharedPhotoObjectPaths() async =>
      _listAll(sharedStorage.keys);

  @override
  Future<void> removePhoto({
    required String uid,
    required String photoId,
    required String ext,
  }) async {
    final path = '$uid/$photoId$ext';
    privateStorage.remove(path);
    removedPrivatePaths.add(path);
  }

  @override
  Future<void> removeSharedPhoto({
    required String photoId,
    required String ext,
  }) async {
    final path = sharedPhotoPath(photoId, ext);
    sharedStorage.remove(path);
    removedSharedPaths.add(path);
  }

  @override
  Future<List<Map<String, dynamic>>> fetchProfiles(Set<String> uids) async {
    return [
      for (final row in _rows['profiles']!.values)
        if (uids.contains(row['id'])) Map<String, dynamic>.from(row),
    ];
  }

  @override
  Future<List<String>> fetchVisibleWallIds(List<String> ids) async {
    return [
      for (final id in ids)
        if (_rows['walls']!.containsKey(id)) id,
    ];
  }
}

/// [FakeSyncRemote] variant whose [fetchSharedTopos] always throws — used
/// to prove the P0 fix (#72): a throw in the shared-topos fetch must not
/// prevent the signed-in user's OWN rows from being fetched+imported by the
/// SAME [SyncService.pullOwnAndShared] call (own is fetched+imported FIRST
/// and in total isolation from every shared sub-fetch).
class ThrowingFetchSharedToposRemote extends FakeSyncRemote {
  @override
  Future<Map<String, List<Map<String, dynamic>>>> fetchSharedTopos({
    SharedTopoScope scope = const SharedTopoScope.unbounded(),
  }) async {
    throw Exception('shared topos fetch failed: simulated cloud error');
  }
}

/// [FakeSyncRemote] variant that reports NO own rows while still reporting
/// every shared one.
///
/// Test-only isolation device for the shared-photo byte budget: the signed-in
/// user's own published walls come back from BOTH `fetchOwnRows` and
/// `fetchSharedTopos`, and the (unbudgeted) own pass runs first — so against
/// the ordinary fake their bytes are already local by the time the shared pass
/// classifies them, and "an own wall in the shared batch is exempt from the
/// budget" would be vacuously green. Blinding `fetchOwnRows` makes the shared
/// pass the only thing that can fetch them, so the classifier is genuinely
/// exercised.
class OwnRowsBlindRemote extends FakeSyncRemote {
  @override
  Future<Map<String, List<Map<String, dynamic>>>> fetchOwnRows(String uid) async => {
    for (final table in syncTableNames) table: <Map<String, dynamic>>[],
  };
}

/// [FakeSyncRemote] variant whose PRIVATE byte upload throws while
/// [failUploads] is set — used to prove §1f-3 (a byte-upload failure is
/// COUNTED and reported, never a silent `continue`) and §1f-2 (its `Photos`
/// row is held back from the metadata push). Toggleable so a single test can
/// also prove the retry HEALS: flip it off and push again.
class FailingUploadSyncRemote extends FakeSyncRemote {
  bool failUploads = true;

  @override
  Future<void> uploadPhoto({
    required String uid,
    required String photoId,
    required String ext,
    required List<int> bytes,
  }) async {
    if (failUploads) {
      throw Exception('uploadPhoto failed: simulated storage error');
    }
    await super.uploadPhoto(uid: uid, photoId: photoId, ext: ext, bytes: bytes);
  }
}

/// [FakeSyncRemote] variant whose "already uploaded" LISTING throws — the
/// shape a Storage outage (or simply being offline) produces, since
/// `SupabaseSyncRemote._listAllObjects` -> `collectPagedObjects` ->
/// `storage.list()` has no try/catch of its own.
///
/// This matters specifically because §1f moved the photo phase ABOVE the row
/// upsert: an unguarded throw there now aborts the WHOLE push before a single
/// row is sent, where previously it could only affect the photo phase.
/// [FakeSyncRemote] whose listings return only the FIRST page and stop — the
/// pre-S6 behaviour of an un-paged `list(path: …)`.
///
/// Exists purely to make the 150-object test non-vacuous: it proves that
/// test can actually FAIL, and that it is the paging (not the fake's
/// generosity) doing the work.
class SinglePageListingSyncRemote extends FakeSyncRemote {
  @override
  Future<Set<String>> listPhotoObjectPaths(String uid) async {
    final prefix = '$uid/';
    final all = privateStorage.keys.where((p) => p.startsWith(prefix)).toList()
      ..sort();
    return all.take(kStoragePageSize).toSet();
  }
}

/// [FakeSyncRemote] whose `upsertOwnRows` silently returns NO outcome for
/// [silentTable] — it neither confirms nor rejects it, and stores nothing.
///
/// Not reachable through today's `SupabaseSyncRemote`, which reports every
/// non-empty table. It exists to pin the DEFAULT, because the cost of the
/// default being wrong is silently discarding a climber's edit: an
/// unreported table must count as NOT CONFIRMED, never as confirmed.
class SilentTableSyncRemote extends FakeSyncRemote {
  SilentTableSyncRemote(this.silentTable);

  final String silentTable;

  @override
  Future<List<TablePushOutcome>> upsertOwnRows(
    String uid,
    Map<String, List<Map<String, dynamic>>> tablesToRows,
  ) async {
    final withoutSilent = {
      for (final entry in tablesToRows.entries)
        if (entry.key != silentTable) entry.key: entry.value,
    };
    return super.upsertOwnRows(uid, withoutSilent);
  }
}

class ThrowingListingSyncRemote extends FakeSyncRemote {
  @override
  Future<Set<String>> listPhotoObjectPaths(String uid) async {
    throw Exception('listPhotoObjectPaths failed: simulated storage outage');
  }
}

/// [FakeSyncRemote] variant whose [upsertOwnRows] reports EVERY attempted
/// table as failed — exactly the shape `SupabaseSyncRemote.upsertOwnRows`
/// returns when each table's round trip throws (offline, captive portal,
/// expired JWT, ...). Storage/photo methods are inherited and keep working,
/// so a test can isolate "the row phase failed" from "the photo phase
/// failed".
///
/// S1 regression guard: before §1d this class was unrepresentable —
/// `upsertOwnRows` returned `void` and swallowed per-table errors, so
/// `pushOwn` counted the rows it handed over as pushed and reported success.
class AllTablesFailingSyncRemote extends FakeSyncRemote {
  AllTablesFailingSyncRemote({this.message = 'simulated cloud error'});

  final String message;

  @override
  Future<List<TablePushOutcome>> upsertOwnRows(
    String uid,
    Map<String, List<Map<String, dynamic>>> tablesToRows,
  ) async => [
    for (final entry in tablesToRows.entries)
      if (entry.value.isNotEmpty)
        TablePushOutcome.failed(
          table: entry.key,
          rowsFailed: entry.value.length,
          error: Exception(message),
        ),
  ];
}

/// [FakeSyncRemote] variant whose [upsertOwnRows] THROWS outright rather
/// than reporting per-table failures — the "remote itself is unreachable"
/// shape. `pushOwn` must convert this into an all-tables-failed RESULT, not
/// propagate it, so the orchestrator sees a truthful push result either way.
class ThrowingUpsertSyncRemote extends FakeSyncRemote {
  @override
  Future<List<TablePushOutcome>> upsertOwnRows(
    String uid,
    Map<String, List<Map<String, dynamic>>> tablesToRows,
  ) async {
    throw Exception('upsertOwnRows boom');
  }
}

/// [FakeSyncRemote] variant where exactly ONE table fails and every other
/// table pushes normally — proves per-table isolation is preserved (the
/// other tables really do land) while the failure is now REPORTED.
class OneTableFailingSyncRemote extends FakeSyncRemote {
  OneTableFailingSyncRemote(this.failingTable);

  final String failingTable;

  @override
  Future<List<TablePushOutcome>> upsertOwnRows(
    String uid,
    Map<String, List<Map<String, dynamic>>> tablesToRows,
  ) async {
    final failingRows = tablesToRows[failingTable];
    final outcomes = await super.upsertOwnRows(uid, {
      for (final entry in tablesToRows.entries)
        if (entry.key != failingTable) entry.key: entry.value,
    });
    if (failingRows != null && failingRows.isNotEmpty) {
      outcomes.add(
        TablePushOutcome.failed(
          table: failingTable,
          rowsFailed: failingRows.length,
          error: Exception('$failingTable rejected'),
        ),
      );
    }
    return outcomes;
  }
}

/// [FakeSyncRemote] variant that runs [onPush] (a local DB write) in the
/// MIDDLE of the row push — i.e. after `SyncService.pushOwn` has taken its
/// snapshot but before it clears any `dirty` flag. This is the only way to
/// exercise the compare-and-swap window deterministically from a unit test.
///
/// The per-table outcomes from `super` are returned UNCHANGED: this double
/// simulates a successful push that races a local write, not a failure.
class _MidPushWriteRemote extends FakeSyncRemote {
  _MidPushWriteRemote(this.onPush);

  final Future<void> Function() onPush;

  @override
  Future<List<TablePushOutcome>> upsertOwnRows(
    String uid,
    Map<String, List<Map<String, dynamic>>> tablesToRows,
  ) async {
    final outcomes = await super.upsertOwnRows(uid, tablesToRows);
    await onPush();
    return outcomes;
  }
}

/// In-memory [ConnectivityService] test double: reports whatever [status]
/// is currently set to (no `connectivity_plus` platform channel), and
/// whatever [reachable] is set to for the §1d reachability probe (no real
/// HTTP request).
class FakeConnectivityService implements ConnectivityService {
  FakeConnectivityService(this.status, {this.reachable = true});

  NetworkStatus status;
  bool reachable;

  @override
  Future<NetworkStatus> currentStatus() async => status;

  @override
  Future<bool> isBackendReachable() async => reachable;

  /// §1e's second seam member. `SyncService` never subscribes to it (only
  /// `SyncOrchestrator` does), so an always-empty stream is exactly right.
  @override
  Stream<NetworkStatus> statusChanges() => const Stream<NetworkStatus>.empty();
}

/// Minimal [AuthRepository] test double: only [currentSession] matters
/// here (push/pull are one-shot, not stream-driven).
class FakeAuthRepository implements AuthRepository {
  FakeAuthRepository(this.currentSession);

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

/// [StoragePersistenceService] test double whose `estimate()` the test dictates.
///
/// `null` is the important default: it is what the real platform delegate
/// answers on native and under `flutter test` (the inert stub), i.e. "no
/// pressure signal", which the shared-photo byte budget must read as "apply the
/// plain count budget" — never as "download nothing".
class FakeStoragePersistenceService implements StoragePersistenceService {
  FakeStoragePersistenceService({this.snapshot, this.throwOnEstimate = false});

  StorageEstimateSnapshot? snapshot;
  bool throwOnEstimate;

  /// Number of `estimate()` calls, so a test can prove the pull consults the
  /// pressure signal exactly once rather than per photo.
  int estimateCalls = 0;

  @override
  Future<StorageEstimateSnapshot?> estimate() async {
    estimateCalls++;
    if (throwOnEstimate) throw StateError('estimate() unavailable');
    return snapshot;
  }

  @override
  Future<bool> isPersisted() async => false;

  @override
  Future<StoragePersistOutcome> requestPersist() async =>
      StoragePersistOutcome.notApplicable;
}

const _signedOut = AuthSessionState.signedOut();
const _uidU1 = 'user-u1';
const _uidU2 = 'user-u2';
final _signedInU1 = AuthSessionState.signedIn('u1@example.com', uid: _uidU1);
final _signedInU2 = AuthSessionState.signedIn('u2@example.com', uid: _uidU2);

int _counter = 0;

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sync_service_test_');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// One (db, docsDir, srcDir, service) bundle — a stand-in for "one
  /// device": its own local database and its own app-owned photos
  /// directory, wired to whatever [remote]/[auth]/[connectivity] are handed
  /// in so a test can share a [FakeSyncRemote] across two bundles to
  /// simulate push-from-A / pull-into-B (or push-from-u2 / pull-into-u1).
  ({AppDatabase db, Directory docsDir, Directory srcDir, SyncService service}) makeContainer({
    required SyncRemote remote,
    required AuthRepository auth,
    ConnectivityService? connectivity,
    bool Function()? wifiOnly,
    Map<String, List<String>>? pushRequiredFields,
    StoragePersistenceService? storage,
    int? sharedPhotoByteBudget,
    bool? isWeb,
  }) {
    final db = AppDatabase(NativeDatabase.memory());
    final docsDir = Directory(p.join(tmp.path, 'docs_${_counter++}'))..createSync();
    final srcDir = Directory(p.join(tmp.path, 'src_${_counter++}'))..createSync();
    final service = SyncService(
      db: db,
      backupRepository: BackupRepository(db),
      remote: remote,
      authRepository: auth,
      connectivity: connectivity ?? FakeConnectivityService(NetworkStatus.wifi),
      photoFiles: PhotoFiles(docsDir: () async => docsDir),
      wifiOnly: wifiOnly,
      pushRequiredFields: pushRequiredFields,
      storage: storage,
      sharedPhotoByteBudget: sharedPhotoByteBudget,
      isWeb: isWeb,
    );
    return (db: db, docsDir: docsDir, srcDir: srcDir, service: service);
  }

  /// Writes a real (non-empty) file the push step can read bytes from.
  ///
  /// These are VALID, metadata-free JPEG bytes rather than the 16 filler bytes
  /// they used to be, because publishing now refuses to upload a container it
  /// cannot parse (W-3 — see `published_photo_metadata.dart`). Sixteen bytes of
  /// `0x07` is not a photo, so the old fixture made every shared-upload test
  /// exercise the refusal path instead of the path it meant to test.
  ///
  /// Metadata-free is the load-bearing part: with nothing to strip, the
  /// publish-side rewrite is a no-op that returns the input unchanged, so every
  /// byte-identity assertion in this file still compares against exactly what
  /// was written. [fill] still varies the bytes, so two fixtures remain
  /// distinguishable.
  File writeFile(Directory dir, String name, [int fill = 7]) {
    final f = File(p.join(dir.path, name));
    f.writeAsBytesSync(fixtureJpegBytes(fill));
    return f;
  }

  /// Seeds one Area -> Sector -> Wall -> original Photo -> Route, all
  /// stamped with [ownerId], so a test can build a realistic non-trivial
  /// hierarchy owned by a given user with a given wall [visibility].
  Future<void> seedWallHierarchy(
    AppDatabase db, {
    required String ownerId,
    required String areaId,
    required String sectorId,
    required String wallId,
    required String photoId,
    required String routeId,
    String visibility = 'private',
    String localPath = '/tmp/placeholder.jpg',
    int updatedAt = 100,
  }) async {
    await db.into(db.areas).insert(
      AreasCompanion.insert(
        id: areaId,
        createdAt: 100,
        updatedAt: updatedAt,
        ownerId: Value(ownerId),
        name: 'Area $areaId',
      ),
    );
    await db.into(db.sectors).insert(
      SectorsCompanion.insert(
        id: sectorId,
        createdAt: 100,
        updatedAt: updatedAt,
        ownerId: Value(ownerId),
        areaId: areaId,
        name: 'Sector $sectorId',
        sortOrder: 0,
      ),
    );
    await db.into(db.walls).insert(
      WallsCompanion.insert(
        id: wallId,
        createdAt: 100,
        updatedAt: updatedAt,
        ownerId: Value(ownerId),
        sectorId: sectorId,
        name: 'Wall $wallId',
        sortOrder: 0,
        visibility: Value(visibility),
      ),
    );
    await db.into(db.photos).insert(
      PhotosCompanion.insert(
        id: photoId,
        createdAt: 100,
        updatedAt: updatedAt,
        ownerId: Value(ownerId),
        wallId: wallId,
        localPath: localPath,
        kind: 'original',
        width: 800,
        height: 600,
      ),
    );
    await db.into(db.routes).insert(
      RoutesCompanion.insert(
        id: routeId,
        createdAt: 100,
        updatedAt: updatedAt,
        ownerId: Value(ownerId),
        wallId: wallId,
        photoId: photoId,
        number: 1,
        colorIndex: 0,
        pointsJson: '[]',
        symbolsJson: '[]',
        sortOrder: 0,
      ),
    );
  }

  group('pushOwn', () {
    test(
      'pushes every u1-owned row (incl. a tombstone) into the fake remote '
      'and uploads the referenced photo file',
      () async {
        final remote = FakeSyncRemote();
        final c = makeContainer(remote: remote, auth: FakeAuthRepository(_signedInU1));
        addTearDown(() => c.db.close());

        final file = writeFile(c.srcDir, 'wall.jpg');
        await seedWallHierarchy(
          c.db,
          ownerId: _uidU1,
          areaId: 'area-1',
          sectorId: 'sector-1',
          wallId: 'wall-1',
          photoId: 'photo-1',
          routeId: 'route-1',
          localPath: file.path,
        );
        await c.db.into(c.db.areas).insert(
          AreasCompanion.insert(
            id: 'area-deleted',
            createdAt: 100,
            updatedAt: 200,
            deletedAt: const Value(300),
            ownerId: const Value(_uidU1),
            name: 'Deleted',
          ),
        );

        final result = await c.service.pushOwn();

        expect(result.didPush, isTrue);
        expect(result.photosUploaded, 1);
        expect(result.rowsPushed, 6);
        expect(result.rowsFailed, 0);
        expect(result.errors, isEmpty);
        expect(
          result.fullyLanded,
          isTrue,
          reason: 'a clean push is the ONLY thing allowed to read as a '
              'complete sync',
        );

        final ownRows = await remote.fetchOwnRows(_uidU1);
        expect(
          ownRows['areas']!.map((r) => r['id']).toSet(),
          {'area-1', 'area-deleted'},
        );
        final deletedRow = ownRows['areas']!.firstWhere((r) => r['id'] == 'area-deleted');
        expect(
          deletedRow['deletedAt'],
          300,
          reason: 'tombstones must be pushed too, not filtered out',
        );

        expect(remote.uploadedPrivatePaths, ['$_uidU1/photo-1.jpg']);
        expect(
          remote.uploadedSharedPaths,
          isEmpty,
          reason: 'wall-1 is private, so no shared copy should be uploaded',
        );
      },
    );

    test(
      'the pushed row payload carries neither dirty nor remoteId -- both are '
      'LOCAL-ONLY bookkeeping columns (S8) that used to ship inside every '
      "row's JSON",
      () async {
        final remote = FakeSyncRemote();
        final c = makeContainer(
          remote: remote,
          auth: FakeAuthRepository(_signedInU1),
        );
        addTearDown(() => c.db.close());

        await seedWallHierarchy(
          c.db,
          ownerId: _uidU1,
          areaId: 'area-1',
          sectorId: 'sector-1',
          wallId: 'wall-1',
          photoId: 'photo-1',
          routeId: 'route-1',
        );

        await c.service.pushOwn();

        final ownRows = await remote.fetchOwnRows(_uidU1);
        for (final tableName in syncTableNames) {
          for (final row in ownRows[tableName]!) {
            expect(
              row.keys,
              isNot(contains('dirty')),
              reason: '$tableName row ${row['id']} still ships dirty',
            );
            expect(
              row.keys,
              isNot(contains('remoteId')),
              reason: '$tableName row ${row['id']} still ships remoteId',
            );
          }
        }
        expect(
          ownRows['areas']!.single['id'],
          'area-1',
          reason: 'stripping must not drop the row itself',
        );
      },
    );

    test(
      'pushing again with nothing changed does not re-upload the '
      'already-present photo object',
      () async {
        final remote = FakeSyncRemote();
        final c = makeContainer(remote: remote, auth: FakeAuthRepository(_signedInU1));
        addTearDown(() => c.db.close());

        final file = writeFile(c.srcDir, 'wall.jpg');
        await seedWallHierarchy(
          c.db,
          ownerId: _uidU1,
          areaId: 'area-1',
          sectorId: 'sector-1',
          wallId: 'wall-1',
          photoId: 'photo-1',
          routeId: 'route-1',
          localPath: file.path,
        );

        final first = await c.service.pushOwn();
        expect(first.photosUploaded, 1);

        final second = await c.service.pushOwn();
        expect(second.photosUploaded, 0);
        expect(remote.uploadedPrivatePaths, hasLength(1));
      },
    );

    test('a photo on a SHARED wall is uploaded to both the private AND '
        'shared object paths', () async {
      final remote = FakeSyncRemote();
      final c = makeContainer(remote: remote, auth: FakeAuthRepository(_signedInU1));
      addTearDown(() => c.db.close());

      final file = writeFile(c.srcDir, 'wall.jpg');
      await seedWallHierarchy(
        c.db,
        ownerId: _uidU1,
        visibility: 'shared',
        areaId: 'area-1',
        sectorId: 'sector-1',
        wallId: 'wall-1',
        photoId: 'photo-1',
        routeId: 'route-1',
        localPath: file.path,
      );

      final result = await c.service.pushOwn();

      expect(result.photosUploaded, 1);
      expect(remote.uploadedPrivatePaths, ['$_uidU1/photo-1.jpg']);
      expect(remote.uploadedSharedPaths, ['shared/photo-1.jpg']);
    });

    test(
      'a RELATIVE localPath (photos/<id>.jpg canonical form since #17) is '
      'resolved against the docsDir before upload, not read as a raw path '
      'against the process CWD (regression: a raw File(photo.localPath) '
      'would silently skip every photo)',
      () async {
        final remote = FakeSyncRemote();
        final c = makeContainer(remote: remote, auth: FakeAuthRepository(_signedInU1));
        addTearDown(() => c.db.close());

        // Write the photo file directly under <docsDir>/photos/<id>.jpg
        // (the real app-owned location PhotoFiles.importPhoto would have
        // copied it to) and store ONLY the relative form in the DB row.
        final photosDir = Directory(p.join(c.docsDir.path, 'photos'))
          ..createSync(recursive: true);
        File(
          p.join(photosDir.path, 'photo-1.jpg'),
        ).writeAsBytesSync(List<int>.filled(16, 5));

        await seedWallHierarchy(
          c.db,
          ownerId: _uidU1,
          areaId: 'area-1',
          sectorId: 'sector-1',
          wallId: 'wall-1',
          photoId: 'photo-1',
          routeId: 'route-1',
          localPath: 'photos/photo-1.jpg',
        );

        final result = await c.service.pushOwn();

        expect(result.didPush, isTrue);
        expect(result.photosUploaded, 1);
        expect(remote.uploadedPrivatePaths, ['$_uidU1/photo-1.jpg']);
        expect(
          remote.privateStorage['$_uidU1/photo-1.jpg'],
          List<int>.filled(16, 5),
        );
      },
    );

    test('signed-out is a safe no-op; the remote is left untouched', () async {
      final remote = FakeSyncRemote();
      final c = makeContainer(remote: remote, auth: FakeAuthRepository(_signedOut));
      addTearDown(() => c.db.close());
      await seedWallHierarchy(
        c.db,
        ownerId: _uidU1,
        areaId: 'area-1',
        sectorId: 'sector-1',
        wallId: 'wall-1',
        photoId: 'photo-1',
        routeId: 'route-1',
      );

      final result = await c.service.pushOwn();

      expect(result.outcome, SyncPushOutcome.skippedSignedOut);
      expect(remote.privateStorage, isEmpty);
      final own = await remote.fetchOwnRows(_uidU1);
      expect(own['areas'], isEmpty);
    });

    test('wifiOnly=true + cellular is skipped; remote unchanged', () async {
      final remote = FakeSyncRemote();
      final c = makeContainer(
        remote: remote,
        auth: FakeAuthRepository(_signedInU1),
        connectivity: FakeConnectivityService(NetworkStatus.cellular),
        wifiOnly: () => true,
      );
      addTearDown(() => c.db.close());
      await seedWallHierarchy(
        c.db,
        ownerId: _uidU1,
        areaId: 'area-1',
        sectorId: 'sector-1',
        wallId: 'wall-1',
        photoId: 'photo-1',
        routeId: 'route-1',
      );

      final result = await c.service.pushOwn();

      expect(result.outcome, SyncPushOutcome.skippedNotWifi);
      final own = await remote.fetchOwnRows(_uidU1);
      expect(own['areas'], isEmpty);
      expect(remote.privateStorage, isEmpty);
    });

    test(
      'a tombstoned (deletedAt set) photo is skipped by the uploader and '
      'its already-uploaded private+shared cloud bytes are removed '
      '(E-A2/E-A3)',
      () async {
        final remote = FakeSyncRemote();
        final c = makeContainer(remote: remote, auth: FakeAuthRepository(_signedInU1));
        addTearDown(() => c.db.close());

        final file = writeFile(c.srcDir, 'wall.jpg');
        await seedWallHierarchy(
          c.db,
          ownerId: _uidU1,
          visibility: 'shared',
          areaId: 'area-1',
          sectorId: 'sector-1',
          wallId: 'wall-1',
          photoId: 'photo-1',
          routeId: 'route-1',
          localPath: file.path,
        );

        // First push uploads both the private AND shared copies (wall-1 is
        // shared).
        final first = await c.service.pushOwn();
        expect(first.photosUploaded, 1);
        expect(remote.privateStorage.containsKey('$_uidU1/photo-1.jpg'), isTrue);
        expect(remote.sharedStorage.containsKey('shared/photo-1.jpg'), isTrue);

        // Tombstone the photo row locally, mirroring what
        // PhotoRepository.deleteOriginalPhoto does (deletedAt/updatedAt/
        // dirty bumped, row otherwise unchanged).
        await (c.db.update(c.db.photos)..where((t) => t.id.equals('photo-1'))).write(
          const PhotosCompanion(
            deletedAt: Value(9999),
            updatedAt: Value(9999),
            dirty: Value(true),
          ),
        );

        final second = await c.service.pushOwn();

        expect(
          second.photosUploaded,
          0,
          reason: 'a tombstoned photo must never be (re-)uploaded (E-A2)',
        );
        expect(
          remote.privateStorage.containsKey('$_uidU1/photo-1.jpg'),
          isFalse,
          reason: 'the private cloud copy must be removed once tombstoned',
        );
        expect(
          remote.sharedStorage.containsKey('shared/photo-1.jpg'),
          isFalse,
          reason: 'the shared cloud copy must be removed once tombstoned',
        );
        expect(remote.removedPrivatePaths, ['$_uidU1/photo-1.jpg']);
        expect(remote.removedSharedPaths, ['shared/photo-1.jpg']);
        expect(
          remote.uploadedPrivatePaths,
          ['$_uidU1/photo-1.jpg'],
          reason: 'no additional upload call should have happened on the '
              'second (tombstoned) push',
        );
        expect(remote.uploadedSharedPaths, ['shared/photo-1.jpg']);

        // Idempotent: pushing again (already removed remotely) must not
        // throw, must not re-upload, and removePhoto/removeSharedPhoto are
        // simply called again against an already-absent object (E-A3).
        final third = await c.service.pushOwn();
        expect(third.photosUploaded, 0);
        expect(
          remote.removedPrivatePaths,
          ['$_uidU1/photo-1.jpg', '$_uidU1/photo-1.jpg'],
        );
        expect(
          remote.removedSharedPaths,
          ['shared/photo-1.jpg', 'shared/photo-1.jpg'],
        );
      },
    );

    // --- W-3: the published copy must not carry the climber's EXIF ---------
    //
    // The picker asks for full metadata because that is how a wall gets its
    // coordinates, and those same bytes were then uploaded to a world-readable
    // bucket. The edge is specific to this app: a climber can deliberately
    // publish an access-sensitive crag WITHOUT coordinates, and the EXIF GPS
    // IFD hands the location over anyway.

    test(
      'the PUBLISHED copy is stripped of EXIF while the PRIVATE copy stays '
      'byte-identical — the private one is the user\'s own photo coming back '
      'on a restore, and decision D-5 says that one is never degraded',
      () async {
        final remote = FakeSyncRemote();
        final c = makeContainer(remote: remote, auth: FakeAuthRepository(_signedInU1));
        addTearDown(() => c.db.close());

        final original = fixtureJpegWithExifBytes();
        final file = File(p.join(c.srcDir.path, 'wall.jpg'))
          ..writeAsBytesSync(original);
        await seedWallHierarchy(
          c.db,
          ownerId: _uidU1,
          visibility: 'shared',
          areaId: 'area-1',
          sectorId: 'sector-1',
          wallId: 'wall-1',
          photoId: 'photo-1',
          routeId: 'route-1',
          localPath: file.path,
        );

        final result = await c.service.pushOwn();
        expect(result.photosUploaded, 1);

        final private = remote.privateStorage['$_uidU1/photo-1.jpg']!;
        final shared = remote.sharedStorage['shared/photo-1.jpg']!;

        expect(private, original, reason: 'the private copy must not be touched');
        expect(
          shared.length,
          lessThan(private.length),
          reason: 'the published copy should have lost its metadata',
        );
        for (final marker in [kFixtureGpsTagBytes, kFixtureMakeBytes]) {
          expect(
            _indexOfBytes(shared, marker),
            -1,
            reason: 'published bytes still contain $marker',
          );
          expect(
            _indexOfBytes(private, marker),
            isNot(-1),
            reason: 'the fixture must actually carry $marker, or this test '
                'proves nothing',
          );
        }
      },
    );

    test(
      'a photo whose container cannot be parsed is REFUSED for publication '
      'rather than uploaded as-is — failing open here is precisely the leak',
      () async {
        final remote = FakeSyncRemote();
        final c = makeContainer(remote: remote, auth: FakeAuthRepository(_signedInU1));
        addTearDown(() => c.db.close());

        // Not a container the stripper understands, so it cannot prove the
        // bytes are clean.
        final file = File(p.join(c.srcDir.path, 'wall.jpg'))
          ..writeAsBytesSync(List<int>.filled(32, 3));
        await seedWallHierarchy(
          c.db,
          ownerId: _uidU1,
          visibility: 'shared',
          areaId: 'area-1',
          sectorId: 'sector-1',
          wallId: 'wall-1',
          photoId: 'photo-1',
          routeId: 'route-1',
          localPath: file.path,
        );

        final result = await c.service.pushOwn();

        expect(
          remote.sharedStorage.containsKey('shared/photo-1.jpg'),
          isFalse,
          reason: 'unstripped bytes must never reach the public bucket',
        );
        expect(
          remote.privateStorage.containsKey('$_uidU1/photo-1.jpg'),
          isFalse,
          reason: 'the refusal happens before either upload, so the private '
              'copy is not written either — the row is withheld and retried '
              'as a unit rather than left half-pushed',
        );
        expect(result.photosFailed, 1);
        expect(
          result.photoErrors.any((e) => e.contains('refusing to publish')),
          isTrue,
          reason: 'the refusal must be reported, not silent. Errors were: '
              '${result.photoErrors}',
        );
      },
    );

    test(
      'a PRIVATE wall with the same unparseable photo still pushes — the '
      'refusal is scoped to publication and must not break ordinary backup',
      () async {
        final remote = FakeSyncRemote();
        final c = makeContainer(remote: remote, auth: FakeAuthRepository(_signedInU1));
        addTearDown(() => c.db.close());

        final file = File(p.join(c.srcDir.path, 'wall.jpg'))
          ..writeAsBytesSync(List<int>.filled(32, 3));
        await seedWallHierarchy(
          c.db,
          ownerId: _uidU1,
          areaId: 'area-1',
          sectorId: 'sector-1',
          wallId: 'wall-1',
          photoId: 'photo-1',
          routeId: 'route-1',
          localPath: file.path,
        );

        final result = await c.service.pushOwn();

        expect(result.photosUploaded, 1);
        expect(result.photosFailed, 0);
        expect(
          remote.privateStorage['$_uidU1/photo-1.jpg'],
          List<int>.filled(32, 3),
          reason: 'a private backup keeps the original bytes exactly',
        );
        expect(remote.sharedStorage, isEmpty);
      },
    );

    test(
      'a photo tombstoned before ever being uploaded is skipped by the '
      'uploader without throwing — idempotent removal of an object that '
      'was never present remotely (E-A3)',
      () async {
        final remote = FakeSyncRemote();
        final c = makeContainer(remote: remote, auth: FakeAuthRepository(_signedInU1));
        addTearDown(() => c.db.close());

        final file = writeFile(c.srcDir, 'wall.jpg');
        await seedWallHierarchy(
          c.db,
          ownerId: _uidU1,
          areaId: 'area-1',
          sectorId: 'sector-1',
          wallId: 'wall-1',
          photoId: 'photo-1',
          routeId: 'route-1',
          localPath: file.path,
        );
        // Tombstone it BEFORE any push has ever uploaded it.
        await (c.db.update(c.db.photos)..where((t) => t.id.equals('photo-1'))).write(
          const PhotosCompanion(
            deletedAt: Value(9999),
            updatedAt: Value(9999),
            dirty: Value(true),
          ),
        );

        final result = await c.service.pushOwn();

        expect(result.didPush, isTrue);
        expect(result.photosUploaded, 0);
        expect(remote.uploadedPrivatePaths, isEmpty);
        expect(remote.uploadedSharedPaths, isEmpty);
        expect(remote.removedPrivatePaths, ['$_uidU1/photo-1.jpg']);
        expect(remote.privateStorage, isEmpty);
      },
    );

    test(
      'S1: upsertOwnRows reports ONE ok outcome per non-empty table — it can '
      'no longer return void and swallow what actually happened',
      () async {
        final remote = FakeSyncRemote();

        final outcomes = await remote.upsertOwnRows(_uidU1, {
          'areas': [
            {
              'id': 'area-1',
              'createdAt': 100,
              'updatedAt': 100,
              'deletedAt': null,
              'remoteId': null,
              'dirty': false,
              'ownerId': _uidU1,
              'name': 'Area 1',
            },
          ],
          'sectors': const <Map<String, dynamic>>[],
        });

        expect(
          outcomes,
          hasLength(1),
          reason: 'an empty table is not attempted, so it is not reported',
        );
        expect(outcomes.single.table, 'areas');
        expect(outcomes.single.ok, isTrue);
        expect(outcomes.single.rowsUpserted, 1);
        expect(outcomes.single.rowsSkippedNewerRemote, 0);
        expect(outcomes.single.rowsFailed, 0);
      },
    );

    test(
      'a row the client-side LWW pre-check drops is reported as '
      'rowsSkippedNewerRemote, NOT as a failure — the cloud already holds a '
      'strictly newer copy, so there is nothing left to push for it',
      () async {
        final remote = FakeSyncRemote();
        Map<String, dynamic> areaRow(int updatedAt, String name) => {
          'id': 'area-1',
          'createdAt': 100,
          'updatedAt': updatedAt,
          'deletedAt': null,
          'remoteId': null,
          'dirty': false,
          'ownerId': _uidU1,
          'name': name,
        };

        await remote.upsertOwnRows(_uidU1, {
          'areas': [areaRow(500, 'Cloud (newer)')],
        });
        final outcomes = await remote.upsertOwnRows(_uidU1, {
          'areas': [areaRow(100, 'Local (stale)')],
        });

        expect(outcomes.single.ok, isTrue);
        expect(outcomes.single.rowsUpserted, 0);
        expect(outcomes.single.rowsSkippedNewerRemote, 1);
      },
    );

    test(
      '1f-3: a byte-upload failure is COUNTED and reported, not a silent '
      'continue — photosFailed/photoErrors carry it (pre-fix sync_service.dart '
      'skipped the upload with no error and no counter)',
      () async {
        final remote = FailingUploadSyncRemote();
        final c = makeContainer(
          remote: remote,
          auth: FakeAuthRepository(_signedInU1),
        );
        addTearDown(() => c.db.close());

        final file = writeFile(c.srcDir, 'wall.jpg');
        await seedWallHierarchy(
          c.db,
          ownerId: _uidU1,
          areaId: 'area-1',
          sectorId: 'sector-1',
          wallId: 'wall-1',
          photoId: 'photo-1',
          routeId: 'route-1',
          localPath: file.path,
        );

        final result = await c.service.pushOwn();

        expect(result.didPush, isTrue);
        expect(result.photosUploaded, 0);
        expect(result.photosFailed, 1);
        expect(result.hasPhotoFailures, isTrue);
        expect(result.photosMissingLocalBytes, 0);
        expect(result.photoErrors, hasLength(1));
        expect(result.photoErrors.single, contains('photo-1'));
        expect(result.photoErrors.single, contains('byte upload failed'));
      },
    );

    test(
      '1f-3: a photo whose LOCAL bytes are gone is reported separately, in '
      'photosMissingLocalBytes — it is not retryable (nothing will ever make '
      'the bytes appear on this device), so it must not be conflated with a '
      'transient upload failure or the retry loop would never terminate',
      () async {
        final remote = FakeSyncRemote();
        final c = makeContainer(
          remote: remote,
          auth: FakeAuthRepository(_signedInU1),
        );
        addTearDown(() => c.db.close());

        await seedWallHierarchy(
          c.db,
          ownerId: _uidU1,
          areaId: 'area-1',
          sectorId: 'sector-1',
          wallId: 'wall-1',
          photoId: 'photo-1',
          routeId: 'route-1',
          localPath: 'photos/never-written.jpg',
        );

        final result = await c.service.pushOwn();

        expect(result.photosUploaded, 0);
        expect(result.photosFailed, 0);
        expect(result.hasPhotoFailures, isFalse);
        expect(result.photosMissingLocalBytes, 1);
        expect(result.photoErrors.single, contains('no local bytes'));
      },
    );

    test(
      'a tombstoned photo is neither a failure nor a missing-bytes case — its '
      'bytes are removed deliberately, so the counters stay clean',
      () async {
        final remote = FakeSyncRemote();
        final c = makeContainer(
          remote: remote,
          auth: FakeAuthRepository(_signedInU1),
        );
        addTearDown(() => c.db.close());

        await seedWallHierarchy(
          c.db,
          ownerId: _uidU1,
          areaId: 'area-1',
          sectorId: 'sector-1',
          wallId: 'wall-1',
          photoId: 'photo-1',
          routeId: 'route-1',
          localPath: 'photos/never-written.jpg',
        );
        await (c.db.update(c.db.photos)..where((t) => t.id.equals('photo-1')))
            .write(
              const PhotosCompanion(
                deletedAt: Value(9999),
                updatedAt: Value(9999),
                dirty: Value(true),
              ),
            );

        final result = await c.service.pushOwn();

        expect(result.photosFailed, 0);
        expect(result.photosMissingLocalBytes, 0);
        expect(result.photoErrors, isEmpty);
        expect(remote.removedPrivatePaths, ['$_uidU1/photo-1.jpg']);
      },
    );

    test(
      'D-2: a push in which every photo\'s BYTES failed is NOT fullyLanded — '
      'the withheld row keeps rowsFailed at 0 and errors empty, so without the '
      'photosFailed term the orchestrator would report idle + a fresh '
      'lastSyncedAt and the Account screen would render "Synced • just now" '
      '(S1, re-entering through the photo path)',
      () async {
        final remote = FailingUploadSyncRemote();
        final c = makeContainer(
          remote: remote,
          auth: FakeAuthRepository(_signedInU1),
        );
        addTearDown(() => c.db.close());

        final file = writeFile(c.srcDir, 'wall.jpg');
        await seedWallHierarchy(
          c.db,
          ownerId: _uidU1,
          areaId: 'area-1',
          sectorId: 'sector-1',
          wallId: 'wall-1',
          photoId: 'photo-1',
          routeId: 'route-1',
          localPath: file.path,
        );

        final result = await c.service.pushOwn();

        expect(
          result.rowsFailed,
          0,
          reason:
              'the ROW channel is genuinely clean — every row that was sent '
              'landed, and the photo row was never sent',
        );
        expect(result.errors, isEmpty, reason: 'and so is its error list');
        expect(result.photosFailed, 1);
        expect(
          result.fullyLanded,
          isFalse,
          reason:
              'photosFailed must gate fullyLanded (reconciliation D-2) — this '
              'expectation IS the S1-through-photos regression test',
        );
      },
    );

    test(
      'D-2: a photo with NO local bytes does NOT block fullyLanded — it is not '
      'retryable, so gating on it would stop the retry loop ever terminating '
      'and pin the app outside idle forever',
      () async {
        final remote = FakeSyncRemote();
        final c = makeContainer(
          remote: remote,
          auth: FakeAuthRepository(_signedInU1),
        );
        addTearDown(() => c.db.close());

        await seedWallHierarchy(
          c.db,
          ownerId: _uidU1,
          areaId: 'area-1',
          sectorId: 'sector-1',
          wallId: 'wall-1',
          photoId: 'photo-1',
          routeId: 'route-1',
          localPath: 'photos/never-written.jpg',
        );

        final result = await c.service.pushOwn();

        expect(result.photosMissingLocalBytes, 1);
        expect(result.photoErrors, hasLength(1));
        expect(
          result.fullyLanded,
          isTrue,
          reason: 'reported, but not treated as a failure to retry',
        );
      },
    );

    test(
      'a table the remote neither confirms NOR rejects is treated as NOT '
      'confirmed: its rows stay dirty, it is reported, and the push is not '
      'fullyLanded — the clear used to be fail-OPEN (everything not named in '
      'a failure outcome was cleared), so an unreported table meant '
      'fullyLanded true, nothing in the cloud, and dirty false: a silently '
      'discarded edit',
      () async {
        final remote = SilentTableSyncRemote('areas');
        final c = makeContainer(
          remote: remote,
          auth: FakeAuthRepository(_signedInU1),
        );
        addTearDown(() => c.db.close());

        await c.db
            .into(c.db.areas)
            .insert(
              AreasCompanion.insert(
                id: 'area-1',
                createdAt: 100,
                updatedAt: 100,
                dirty: const Value(true),
                ownerId: const Value(_uidU1),
                name: 'Area',
              ),
            );

        final result = await c.service.pushOwn();

        final ownRows = await remote.fetchOwnRows(_uidU1);
        expect(
          ownRows['areas'],
          isEmpty,
          reason: 'precondition: the silent table really did not land',
        );
        final area = await c.db.select(c.db.areas).getSingle();
        expect(
          area.dirty,
          isTrue,
          reason:
              'NOT CONFIRMED must mean NOT CLEARED — clearing it here strands '
              'the row forever, since the retry loop is gated on dirty',
        );
        expect(
          result.fullyLanded,
          isFalse,
          reason: 'and the push must not claim it landed everything',
        );
        expect(result.errors.join(' '), contains('areas'));
      },
    );

    test(
      'a Storage LISTING outage does not abort the whole push: the photo rows '
      'are withheld and reported, every OTHER table still lands, and pushOwn '
      'returns a result instead of throwing — moving the photo phase above '
      'the row upsert (S5) would otherwise have turned a photos-only outage '
      'into a total push failure that lands nothing at all',
      () async {
        final remote = ThrowingListingSyncRemote();
        final c = makeContainer(
          remote: remote,
          auth: FakeAuthRepository(_signedInU1),
        );
        addTearDown(() => c.db.close());

        final file = writeFile(c.srcDir, 'wall.jpg');
        await seedWallHierarchy(
          c.db,
          ownerId: _uidU1,
          areaId: 'area-1',
          sectorId: 'sector-1',
          wallId: 'wall-1',
          photoId: 'photo-1',
          routeId: 'route-1',
          localPath: file.path,
        );
        // The shape a real local write leaves behind — without this the
        // "stays dirty" assertion below would be vacuous, since
        // seedWallHierarchy inserts rows already clean.
        await (c.db.update(c.db.photos)..where((t) => t.id.equals('photo-1')))
            .write(const PhotosCompanion(dirty: Value(true)));

        final result = await c.service.pushOwn();

        expect(
          result.didPush,
          isTrue,
          reason: 'pushOwn must not propagate the listing throw',
        );
        expect(result.photosFailed, 1);
        expect(result.fullyLanded, isFalse);
        expect(result.photoErrors.join(' '), contains('simulated storage outage'));
        expect(
          result.rowsPushed,
          4,
          reason:
              'area + sector + wall + route still land — a Storage outage has '
              'nothing to do with them',
        );

        final ownRows = await remote.fetchOwnRows(_uidU1);
        expect(ownRows['areas']!.map((r) => r['id']), ['area-1']);
        expect(
          ownRows['photos'],
          isEmpty,
          reason: 'no orphan row: the bytes did not land, so neither does it',
        );

        final photo = await (c.db.select(
          c.db.photos,
        )..where((t) => t.id.equals('photo-1'))).getSingle();
        expect(
          photo.dirty,
          isTrue,
          reason: 'the withheld row stays dirty, so the retry re-sends it',
        );
      },
    );

    test(
      '1f-2: bytes go up BEFORE the metadata — the photo object is uploaded '
      'before the photos table is upserted, so no window exists in which the '
      'cloud holds a row whose object is missing (S5)',
      () async {
        final remote = FakeSyncRemote();
        final c = makeContainer(
          remote: remote,
          auth: FakeAuthRepository(_signedInU1),
        );
        addTearDown(() => c.db.close());

        final file = writeFile(c.srcDir, 'wall.jpg');
        await seedWallHierarchy(
          c.db,
          ownerId: _uidU1,
          areaId: 'area-1',
          sectorId: 'sector-1',
          wallId: 'wall-1',
          photoId: 'photo-1',
          routeId: 'route-1',
          localPath: file.path,
        );

        await c.service.pushOwn();

        final uploadIndex = remote.callLog.indexOf('upload:$_uidU1/photo-1.jpg');
        final upsertIndex = remote.callLog.indexOf('upsert:photos');
        expect(uploadIndex, greaterThanOrEqualTo(0));
        expect(upsertIndex, greaterThanOrEqualTo(0));
        expect(
          uploadIndex,
          lessThan(upsertIndex),
          reason: 'pre-fix the metadata upsert ran first',
        );
      },
    );

    test(
      '1f-2: a photo whose byte upload THROWS has its Photos row held back '
      'from the metadata push, while every other table still pushes — and the '
      'next push, once uploads succeed, heals it',
      () async {
        final remote = FailingUploadSyncRemote();
        final c = makeContainer(
          remote: remote,
          auth: FakeAuthRepository(_signedInU1),
        );
        addTearDown(() => c.db.close());

        final file = writeFile(c.srcDir, 'wall.jpg');
        await seedWallHierarchy(
          c.db,
          ownerId: _uidU1,
          areaId: 'area-1',
          sectorId: 'sector-1',
          wallId: 'wall-1',
          photoId: 'photo-1',
          routeId: 'route-1',
          localPath: file.path,
        );

        final first = await c.service.pushOwn();

        expect(first.didPush, isTrue);
        expect(first.photosFailed, 1);
        expect(
          first.rowsPushed,
          4,
          reason: 'area + sector + wall + route; the photo row is withheld',
        );

        final afterFailure = await remote.fetchOwnRows(_uidU1);
        expect(
          afterFailure['photos'],
          isEmpty,
          reason:
              'no cloud row may point at a Storage object that does not exist '
              "(S5) — another device would keep the ORIGINATING device's "
              'localPath forever, and on web resolvePhotoPath is an identity '
              'passthrough with no existence check',
        );
        expect(afterFailure['walls']!.map((r) => r['id']), ['wall-1']);
        expect(afterFailure['routes']!.map((r) => r['id']), ['route-1']);
        expect(afterFailure['areas']!.map((r) => r['id']), ['area-1']);

        // The retry §1e schedules: uploads now succeed, so both the bytes AND
        // the previously-withheld row land. Nothing was lost — pushOwn
        // re-reads a full own-row snapshot every time (decision D-4).
        remote.failUploads = false;
        final second = await c.service.pushOwn();

        expect(second.photosFailed, 0);
        expect(second.photosUploaded, 1);
        final healed = await remote.fetchOwnRows(_uidU1);
        expect(healed['photos']!.map((r) => r['id']), ['photo-1']);
        expect(remote.privateStorage.containsKey('$_uidU1/photo-1.jpg'), isTrue);
      },
    );

    test(
      '1f-2: a SLICE sharing a failed original\'s file is withheld too — its '
      'localPath points at the same object, so pushing it would reproduce the '
      'exact orphan-row problem',
      () async {
        final remote = FailingUploadSyncRemote();
        final c = makeContainer(
          remote: remote,
          auth: FakeAuthRepository(_signedInU1),
        );
        addTearDown(() => c.db.close());

        final file = writeFile(c.srcDir, 'wall.jpg');
        await seedWallHierarchy(
          c.db,
          ownerId: _uidU1,
          areaId: 'area-1',
          sectorId: 'sector-1',
          wallId: 'wall-1',
          photoId: 'photo-1',
          routeId: 'route-1',
          localPath: file.path,
        );
        await c.db
            .into(c.db.photos)
            .insert(
              PhotosCompanion.insert(
                id: 'slice-1',
                createdAt: 100,
                updatedAt: 100,
                ownerId: const Value(_uidU1),
                wallId: 'wall-1',
                localPath: file.path,
                kind: 'slice',
                width: 800,
                height: 600,
                parentPhotoId: const Value('photo-1'),
              ),
            );

        await c.service.pushOwn();

        final ownRows = await remote.fetchOwnRows(_uidU1);
        expect(
          ownRows['photos'],
          isEmpty,
          reason:
              'both the original AND its slice resolve to the same canonical '
              'file id, so both are withheld',
        );
      },
    );
  });

  group('dirty gating + confirmed-push clear (S2/S7/S8)', () {
    test('hasPendingLocalChanges is false when signed out', () async {
      final remote = FakeSyncRemote();
      final c = makeContainer(
        remote: remote,
        auth: FakeAuthRepository(_signedOut),
      );
      addTearDown(() => c.db.close());
      expect(await c.service.hasPendingLocalChanges(), isFalse);
    });

    test(
      'hasPendingLocalChanges tracks the dirty flag: true with a dirty own '
      'row, false once a confirmed push has cleared it',
      () async {
        final remote = FakeSyncRemote();
        final c = makeContainer(
          remote: remote,
          auth: FakeAuthRepository(_signedInU1),
        );
        addTearDown(() => c.db.close());

        await c.db
            .into(c.db.areas)
            .insert(
              AreasCompanion.insert(
                id: 'area-dirty',
                createdAt: 100,
                updatedAt: 100,
                dirty: const Value(true),
                ownerId: const Value(_uidU1),
                name: 'Dirty',
              ),
            );
        expect(await c.service.hasPendingLocalChanges(), isTrue);

        await c.service.pushOwn();

        expect(await c.service.hasPendingLocalChanges(), isFalse);
        final row = await (c.db.select(
          c.db.areas,
        )..where((t) => t.id.equals('area-dirty'))).getSingle();
        expect(row.dirty, isFalse);
      },
    );

    test(
      'a FAILED push leaves dirty set -- the flag is cleared only for the '
      'tables the push CONFIRMED, which is what makes "retry until clean" '
      'terminate. Note pushOwn does NOT throw here: §1d converts a '
      'whole-call upsert throw into an all-tables-failed RESULT, which is '
      'exactly why the clear must be narrowed to the landed tables.',
      () async {
        final remote = ThrowingUpsertSyncRemote();
        final c = makeContainer(
          remote: remote,
          auth: FakeAuthRepository(_signedInU1),
        );
        addTearDown(() => c.db.close());

        await c.db
            .into(c.db.areas)
            .insert(
              AreasCompanion.insert(
                id: 'area-dirty',
                createdAt: 100,
                updatedAt: 100,
                dirty: const Value(true),
                ownerId: const Value(_uidU1),
                name: 'Dirty',
              ),
            );

        final result = await c.service.pushOwn();

        expect(result.fullyLanded, isFalse);
        expect(result.rowsFailed, 1);
        expect(result.errors.join(' '), contains('upsertOwnRows boom'));

        final row = await (c.db.select(
          c.db.areas,
        )..where((t) => t.id.equals('area-dirty'))).getSingle();
        expect(row.dirty, isTrue);
        expect(await c.service.hasPendingLocalChanges(), isTrue);
      },
    );

    test(
      'a PARTIAL failure clears dirty ONLY for the tables that landed: the '
      'rejected table keeps its flag while its siblings go clean. This is '
      'the narrowing in its sharpest form -- an unconditional '
      '_clearDirty(tablesToRows) passes every other test in this group but '
      'fails here, and in production it would discard the offline edit.',
      () async {
        final remote = OneTableFailingSyncRemote('areas');
        final c = makeContainer(
          remote: remote,
          auth: FakeAuthRepository(_signedInU1),
        );
        addTearDown(() => c.db.close());

        await seedWallHierarchy(
          c.db,
          ownerId: _uidU1,
          areaId: 'area-1',
          sectorId: 'sector-1',
          wallId: 'wall-1',
          photoId: 'photo-1',
          routeId: 'route-1',
        );
        await c.db.customStatement('UPDATE areas SET dirty = 1');
        await c.db.customStatement('UPDATE sectors SET dirty = 1');

        final result = await c.service.pushOwn();

        expect(result.fullyLanded, isFalse);
        expect(
          (await (c.db.select(
            c.db.areas,
          )..where((t) => t.id.equals('area-1'))).getSingle()).dirty,
          isTrue,
          reason: 'the areas upsert was REJECTED — that row is not in the '
              'cloud, so it must stay queued for the retry loop',
        );
        expect(
          (await (c.db.select(
            c.db.sectors,
          )..where((t) => t.id.equals('sector-1'))).getSingle()).dirty,
          isFalse,
          reason: 'sectors landed, so its flag is correctly cleared — the '
              'narrowing must be per-table, not all-or-nothing',
        );
        expect(await c.service.hasPendingLocalChanges(), isTrue);
      },
    );

    test(
      'PushScope.dirtyOnly sends ONLY the dirty rows (S7), while the default '
      'PushScope.full still sends everything',
      () async {
        final remote = FakeSyncRemote();
        final c = makeContainer(
          remote: remote,
          auth: FakeAuthRepository(_signedInU1),
        );
        addTearDown(() => c.db.close());

        await seedWallHierarchy(
          c.db,
          ownerId: _uidU1,
          areaId: 'area-clean',
          sectorId: 'sector-clean',
          wallId: 'wall-clean',
          photoId: 'photo-clean',
          routeId: 'route-clean',
        );
        await c.db
            .into(c.db.areas)
            .insert(
              AreasCompanion.insert(
                id: 'area-dirty',
                createdAt: 100,
                updatedAt: 100,
                dirty: const Value(true),
                ownerId: const Value(_uidU1),
                name: 'Dirty',
              ),
            );

        final dirtyPush = await c.service.pushOwn(scope: PushScope.dirtyOnly);
        expect(dirtyPush.rowsPushed, 1);
        expect(
          (await remote.fetchOwnRows(_uidU1))['areas']!.map((r) => r['id']),
          ['area-dirty'],
          reason: 'the seeded clean hierarchy must not be re-sent',
        );

        final fullPush = await c.service.pushOwn();
        expect(fullPush.rowsPushed, 6);
      },
    );

    test(
      'a local write that lands DURING an in-flight push keeps its dirty '
      'flag -- the clear is an (id, updatedAt) compare-and-swap, so the '
      'newer edit is picked up by the next push instead of being lost',
      () async {
        late final AppDatabase raceDb;
        final remote = _MidPushWriteRemote(() async {
          // Simulates the user editing the same row while the push is
          // awaiting the network: a fresh updatedAt AND dirty re-set, exactly
          // what every repository write does.
          await (raceDb.update(
            raceDb.areas,
          )..where((t) => t.id.equals('area-dirty'))).write(
            const AreasCompanion(
              updatedAt: Value(999),
              dirty: Value(true),
              name: Value('Edited mid-push'),
            ),
          );
        });
        final c = makeContainer(
          remote: remote,
          auth: FakeAuthRepository(_signedInU1),
        );
        raceDb = c.db;
        addTearDown(() => c.db.close());

        await c.db
            .into(c.db.areas)
            .insert(
              AreasCompanion.insert(
                id: 'area-dirty',
                createdAt: 100,
                updatedAt: 100,
                dirty: const Value(true),
                ownerId: const Value(_uidU1),
                name: 'Original',
              ),
            );

        await c.service.pushOwn(scope: PushScope.dirtyOnly);

        final row = await (c.db.select(
          c.db.areas,
        )..where((t) => t.id.equals('area-dirty'))).getSingle();
        expect(
          row.dirty,
          isTrue,
          reason: 'the mid-push edit must NOT be marked as pushed',
        );
        expect(row.updatedAt, 999);
        expect(await c.service.hasPendingLocalChanges(), isTrue);
      },
    );
  });

  group('§1d (S1): pushOwn tells the truth about what landed', () {
    /// Two own rows and NO photo rows — the exact S1 precondition.
    Future<void> seedAreaAndSectorOnly(AppDatabase db) async {
      await db
          .into(db.areas)
          .insert(
            AreasCompanion.insert(
              id: 'area-1',
              createdAt: 100,
              updatedAt: 100,
              ownerId: const Value(_uidU1),
              name: 'Area 1',
            ),
          );
      await db
          .into(db.sectors)
          .insert(
            SectorsCompanion.insert(
              id: 'sector-1',
              createdAt: 100,
              updatedAt: 100,
              ownerId: const Value(_uidU1),
              areaId: 'area-1',
              name: 'Sector 1',
              sortOrder: 0,
            ),
          );
    }

    test(
      'S1 REGRESSION: an account with ZERO photo rows whose every table '
      'failed reports the failure. Pre-fix this exact case reported '
      'outcome=pushed with rowsPushed counting rows merely handed to the '
      'remote, because `_uploadOwnPhotos` short-circuits at '
      '`if (photos.isEmpty) return 0;` BEFORE the unguarded '
      'listPhotoObjectPaths call that was the only thing surfacing a failed '
      'push — so the Account screen rendered "Synced • just now"',
      () async {
        final remote = AllTablesFailingSyncRemote();
        final c = makeContainer(
          remote: remote,
          auth: FakeAuthRepository(_signedInU1),
        );
        addTearDown(() => c.db.close());

        await seedAreaAndSectorOnly(c.db);

        final result = await c.service.pushOwn();

        expect(
          await c.db.select(c.db.photos).get(),
          isEmpty,
          reason: 'the zero-photo precondition this regression depends on',
        );
        expect(result.rowsFailed, 2);
        expect(result.rowsPushed, 0);
        expect(result.errors, hasLength(2));
        expect(result.errors.join(' '), contains('simulated cloud error'));
        expect(
          result.fullyLanded,
          isFalse,
          reason:
              'nothing reached the cloud — this must never read as a '
              'complete sync',
        );
      },
    );

    test(
      'the same all-tables-failed push with photo rows PRESENT also reports '
      'the failure, and the photo phase still runs (per-phase isolation is '
      'preserved, just no longer silent)',
      () async {
        final remote = AllTablesFailingSyncRemote();
        final c = makeContainer(
          remote: remote,
          auth: FakeAuthRepository(_signedInU1),
        );
        addTearDown(() => c.db.close());

        final file = writeFile(c.srcDir, 'wall.jpg');
        await seedWallHierarchy(
          c.db,
          ownerId: _uidU1,
          areaId: 'area-1',
          sectorId: 'sector-1',
          wallId: 'wall-1',
          photoId: 'photo-1',
          routeId: 'route-1',
          localPath: file.path,
        );

        final result = await c.service.pushOwn();

        expect(result.rowsFailed, 5);
        expect(result.rowsPushed, 0);
        expect(result.fullyLanded, isFalse);
        expect(
          result.photosUploaded,
          1,
          reason: 'the byte phase is independent of the row phase and still ran',
        );
      },
    );

    test(
      'upsertOwnRows throwing outright is converted into an all-tables-failed '
      'RESULT, not propagated out of pushOwn',
      () async {
        final remote = ThrowingUpsertSyncRemote();
        final c = makeContainer(
          remote: remote,
          auth: FakeAuthRepository(_signedInU1),
        );
        addTearDown(() => c.db.close());

        await seedAreaAndSectorOnly(c.db);

        final result = await c.service.pushOwn();

        expect(result.didPush, isTrue);
        expect(result.fullyLanded, isFalse);
        expect(result.rowsFailed, 2);
        expect(result.errors.join(' '), contains('upsertOwnRows boom'));
      },
    );

    test(
      'ONE failing table is reported while every OTHER table genuinely lands '
      '— rowsPushed and rowsFailed split the batch, and the partial push is '
      'not fullyLanded',
      () async {
        final remote = OneTableFailingSyncRemote('photos');
        final c = makeContainer(
          remote: remote,
          auth: FakeAuthRepository(_signedInU1),
        );
        addTearDown(() => c.db.close());

        await seedWallHierarchy(
          c.db,
          ownerId: _uidU1,
          areaId: 'area-1',
          sectorId: 'sector-1',
          wallId: 'wall-1',
          photoId: 'photo-1',
          routeId: 'route-1',
        );

        final result = await c.service.pushOwn();

        expect(result.rowsPushed, 4, reason: 'area + sector + wall + route');
        expect(result.rowsFailed, 1, reason: 'the one photos row');
        expect(result.errors, hasLength(1));
        expect(result.errors.single, contains('photos'));
        expect(result.fullyLanded, isFalse);

        final ownRows = await remote.fetchOwnRows(_uidU1);
        expect(ownRows['areas']!.map((r) => r['id']), ['area-1']);
        expect(ownRows['routes']!.map((r) => r['id']), ['route-1']);
        expect(
          ownRows['photos'],
          isEmpty,
          reason: 'the failing table really did not land',
        );
      },
    );

    test(
      'L5: a local row excluded by the push-side required-field guard lands '
      'in the push result\'s failure channel (rowsFailed + errors) instead of '
      'being dropped from this and every future push with only a debugPrint '
      '— with no outbox, "excluded once" meant "excluded forever"',
      () async {
        final remote = FakeSyncRemote();
        final c = makeContainer(
          remote: remote,
          auth: FakeAuthRepository(_signedInU1),
          // Every column syncRequiredFields names is NOT NULL in Drift, so a
          // genuinely-missing required value is only reachable through local
          // data corruption. Requiring a column that cannot exist is the
          // faithful stand-in: it is exactly what a corrupted/absent
          // required value looks like TO THE GUARD. Only 'areas' is
          // overridden; every other table falls back to `const ['id']`,
          // which every real row satisfies.
          pushRequiredFields: const {
            'areas': [
              'id',
              'createdAt',
              'updatedAt',
              'name',
              'columnThatCannotExist',
            ],
          },
        );
        addTearDown(() => c.db.close());

        await seedWallHierarchy(
          c.db,
          ownerId: _uidU1,
          areaId: 'area-1',
          sectorId: 'sector-1',
          wallId: 'wall-1',
          photoId: 'photo-1',
          routeId: 'route-1',
        );

        final result = await c.service.pushOwn();

        expect(result.rowsFailed, 1);
        expect(result.errors, hasLength(1));
        expect(result.errors.single, contains('areas'));
        expect(
          result.errors.single,
          contains('area-1'),
          reason: 'the excluded row must be identifiable, not just counted',
        );
        expect(result.fullyLanded, isFalse);
        expect(
          result.rowsPushed,
          4,
          reason: 'sector + wall + photo + route still pushed — the guard is '
              'per-row, not per-batch',
        );

        final ownRows = await remote.fetchOwnRows(_uidU1);
        expect(
          ownRows['areas'],
          isEmpty,
          reason: 'the excluded row genuinely never reached the cloud',
        );
        expect(ownRows['sectors']!.map((r) => r['id']), ['sector-1']);
      },
    );
  });

  group('pullOwnAndShared: own-row round trip', () {
    test(
      'push from a populated DB, then pull into a FRESH empty DB + fresh '
      'docsDir restores u1\'s rows and writes the photo under the new docsDir',
      () async {
        final remote = FakeSyncRemote();
        final auth = FakeAuthRepository(_signedInU1);

        final containerA = makeContainer(remote: remote, auth: auth);
        addTearDown(() => containerA.db.close());
        final file = writeFile(containerA.srcDir, 'wall.jpg', 42);
        await seedWallHierarchy(
          containerA.db,
          ownerId: _uidU1,
          areaId: 'area-1',
          sectorId: 'sector-1',
          wallId: 'wall-1',
          photoId: 'photo-1',
          routeId: 'route-1',
          localPath: file.path,
        );
        await containerA.service.pushOwn();

        final containerB = makeContainer(remote: remote, auth: auth);
        addTearDown(() => containerB.db.close());
        expect(await containerB.db.select(containerB.db.areas).get(), isEmpty);

        final result = await containerB.service.pullOwnAndShared();

        expect(result.didPull, isTrue);
        expect(result.ownRowsPulled, 5);
        expect(result.sharedRowsPulled, 0);
        expect(result.photosDownloaded, 1);

        final areas = await containerB.db.select(containerB.db.areas).get();
        final sectors = await containerB.db.select(containerB.db.sectors).get();
        final walls = await containerB.db.select(containerB.db.walls).get();
        final photos = await containerB.db.select(containerB.db.photos).get();
        final routes = await containerB.db.select(containerB.db.routes).get();

        expect(areas.map((a) => a.id), ['area-1']);
        expect(sectors.map((s) => s.id), ['sector-1']);
        expect(walls.map((w) => w.id), ['wall-1']);
        expect(routes.map((r) => r.id), ['route-1']);
        expect(photos, hasLength(1));

        final photo = photos.single;
        expect(photo.ownerId, _uidU1);
        // writePhotoBytes now returns (and stores) the RELATIVE
        // photos/<id><ext> form, never an absolute path baked against
        // container B's current docsDir.
        expect(p.isRelative(photo.localPath), isTrue);
        expect(photo.localPath, isNot(file.path));
        final absolutePath = p.join(containerB.docsDir.path, photo.localPath);
        expect(File(absolutePath).existsSync(), isTrue);
        expect(File(absolutePath).readAsBytesSync(), fixtureJpegBytes(42));
      },
    );
  });

  /// The live sync failure, end to end:
  ///
  ///     Couldn't sync — Sync failed: own rows import failed: Bad state:
  ///     importSnapshot: 3 table(s) failed: ascents: SqliteException(787):
  ///     FOREIGN KEY constraint failed
  ///
  /// [SyncRemote.fetchOwnRows] is scoped `ownerId = uid`, so an Ascent/Comment/
  /// Like the signed-in user made on ANOTHER owner's shared topo arrives WITHOUT
  /// its parent Wall/Route — those belong to the other owner and come with the
  /// SHARED batch, which is imported after the own batch. Confirmed present in
  /// the live (dev) Supabase for all three tables.
  group('pullOwnAndShared: own rows whose FK parent belongs to another owner', () {
    test(
      "an ascent + comment + like the user made on someone else's shared topo "
      'come back in the SAME pull into a fresh install, with no errors and '
      'without taking their own-topo rows down with them',
      () async {
        final remote = FakeSyncRemote();

        // ---- u2 publishes a shared topo ---------------------------------
        final u2 = makeContainer(remote: remote, auth: FakeAuthRepository(_signedInU2));
        addTearDown(() => u2.db.close());
        await seedWallHierarchy(
          u2.db,
          ownerId: _uidU2,
          areaId: 'area-u2',
          sectorId: 'sector-u2',
          wallId: 'wall-u2',
          photoId: 'photo-u2',
          routeId: 'route-u2',
          visibility: 'shared',
          localPath: writeFile(u2.srcDir, 'wall-u2.jpg', 9).path,
        );
        await u2.service.pushOwn();

        // ---- u1 pulls it, keeps a topo of their own, and logs an ascent,
        //      a comment and a like on u2's shared topo -------------------
        final u1 = makeContainer(remote: remote, auth: FakeAuthRepository(_signedInU1));
        addTearDown(() => u1.db.close());
        await u1.service.pullOwnAndShared();
        await seedWallHierarchy(
          u1.db,
          ownerId: _uidU1,
          areaId: 'area-u1',
          sectorId: 'sector-u1',
          wallId: 'wall-u1',
          photoId: 'photo-u1',
          routeId: 'route-u1',
          localPath: writeFile(u1.srcDir, 'wall-u1.jpg', 4).path,
        );
        for (final (id, routeId, wallId) in const [
          ('ascent-own', 'route-u1', 'wall-u1'),
          ('ascent-on-u2', 'route-u2', 'wall-u2'),
        ]) {
          await u1.db.into(u1.db.ascents).insert(
            AscentsCompanion.insert(
              id: id,
              createdAt: 100,
              updatedAt: 100,
              ownerId: const Value(_uidU1),
              routeId: routeId,
              wallId: wallId,
              climbedAt: 100,
              style: 'redpoint',
            ),
          );
        }
        for (final (id, wallId) in const [
          ('comment-own', 'wall-u1'),
          ('comment-on-u2', 'wall-u2'),
        ]) {
          await u1.db.into(u1.db.comments).insert(
            CommentsCompanion.insert(
              id: id,
              createdAt: 100,
              updatedAt: 100,
              ownerId: const Value(_uidU1),
              wallId: Value(wallId),
              body: 'good line',
            ),
          );
        }
        for (final (id, wallId) in const [
          ('like-own', 'wall-u1'),
          ('like-on-u2', 'wall-u2'),
        ]) {
          await u1.db.into(u1.db.likes).insert(
            LikesCompanion.insert(
              id: id,
              createdAt: 100,
              updatedAt: 100,
              ownerId: const Value(_uidU1),
              wallId: Value(wallId),
            ),
          );
        }
        await u1.service.pushOwn();

        // ---- fresh install, same account: the failing pull --------------
        final fresh = makeContainer(remote: remote, auth: FakeAuthRepository(_signedInU1));
        addTearDown(() => fresh.db.close());
        expect(await fresh.db.select(fresh.db.ascents).get(), isEmpty);

        final result = await fresh.service.pullOwnAndShared();

        expect(
          result.errors,
          isEmpty,
          reason: 'pre-fix: ["own rows import failed: Bad state: '
              'importSnapshot: 3 table(s) failed: ascents/comments/likes ... '
              'FOREIGN KEY constraint failed"]',
        );
        expect(result.ownImported, isTrue);
        expect(
          (await fresh.db.select(fresh.db.ascents).get()).map((a) => a.id),
          unorderedEquals(['ascent-own', 'ascent-on-u2']),
          reason: "the own-topo ascent was collateral damage of the foreign "
              'one detonating the table',
        );
        expect(
          (await fresh.db.select(fresh.db.comments).get()).map((c) => c.id),
          unorderedEquals(['comment-own', 'comment-on-u2']),
        );
        expect(
          (await fresh.db.select(fresh.db.likes).get()).map((l) => l.id),
          unorderedEquals(['like-own', 'like-on-u2']),
        );
      },
    );

    test(
      'a TRUE orphan (the other owner un-shared the topo, so no batch can '
      'supply the parent) is COUNTED, not treated as a sync failure -- and the '
      'rest of the pull still lands',
      () async {
        final remote = FakeSyncRemote();

        final u2 = makeContainer(remote: remote, auth: FakeAuthRepository(_signedInU2));
        addTearDown(() => u2.db.close());
        await seedWallHierarchy(
          u2.db,
          ownerId: _uidU2,
          areaId: 'area-u2',
          sectorId: 'sector-u2',
          wallId: 'wall-u2',
          photoId: 'photo-u2',
          routeId: 'route-u2',
          visibility: 'shared',
          localPath: writeFile(u2.srcDir, 'wall-u2.jpg', 9).path,
        );
        await u2.service.pushOwn();

        final u1 = makeContainer(remote: remote, auth: FakeAuthRepository(_signedInU1));
        addTearDown(() => u1.db.close());
        await u1.service.pullOwnAndShared();
        await seedWallHierarchy(
          u1.db,
          ownerId: _uidU1,
          areaId: 'area-u1',
          sectorId: 'sector-u1',
          wallId: 'wall-u1',
          photoId: 'photo-u1',
          routeId: 'route-u1',
          localPath: writeFile(u1.srcDir, 'wall-u1.jpg', 4).path,
        );
        await u1.db.into(u1.db.likes).insert(
          LikesCompanion.insert(
            id: 'like-on-u2',
            createdAt: 100,
            updatedAt: 100,
            ownerId: const Value(_uidU1),
            wallId: const Value('wall-u2'),
          ),
        );
        await u1.db.into(u1.db.likes).insert(
          LikesCompanion.insert(
            id: 'like-own',
            createdAt: 100,
            updatedAt: 100,
            ownerId: const Value(_uidU1),
            wallId: const Value('wall-u1'),
          ),
        );
        await u1.service.pushOwn();

        // u2 un-shares the topo: it drops out of fetchSharedTopos entirely,
        // so u1's like on it can never resolve its wallId FK.
        await (u2.db.update(u2.db.walls)..where((t) => t.id.equals('wall-u2')))
            .write(
              const WallsCompanion(
                visibility: Value('private'),
                updatedAt: Value(500),
              ),
            );
        await u2.service.pushOwn();

        final fresh = makeContainer(remote: remote, auth: FakeAuthRepository(_signedInU1));
        addTearDown(() => fresh.db.close());
        final result = await fresh.service.pullOwnAndShared();

        // CHANGED 2026-08-08, deliberately, and against what this test used to
        // assert. It required the orphan on the "Couldn't sync ... Retry"
        // surface, citing #72 ("never vanish behind a debugPrint"). #72 is
        // still right about hidden FAILURES -- but this is not a failure. The
        // parent is gone because its owner un-shared, deleted, or a moderator
        // took down the topo, and a takedown hides content from everyone
        // (decided 2026-08-08). So the row can never resolve, retrying
        // re-fetches the same orphan, and the banner could never clear: it told
        // the user their sync was broken when nothing was broken and nothing
        // was lost.
        //
        // It stays VISIBLE -- as a count and a log line -- which is what #72
        // actually protects. What changed is only whether an expected,
        // unfixable state is dressed up as breakage.
        expect(
          result.errors.join(' | '),
          isNot(contains('own rows deferred')),
          reason: 'an orphan whose parent can never come back must not raise a '
              'sync error the user can do nothing about and that can never '
              'clear',
        );
        expect(
          result.ownRowsOrphaned,
          1,
          reason: 'still reported, just not as a failure',
        );
        expect(
          result.ownImported,
          isTrue,
          reason: 'every importable row landed -- the pull did its job',
        );
        // Everything importable still imported.
        expect(
          (await fresh.db.select(fresh.db.likes).get()).map((l) => l.id),
          ['like-own'],
        );
        expect(
          (await fresh.db.select(fresh.db.walls).get()).map((w) => w.id),
          ['wall-u1'],
        );
      },
    );
  });

  group('S6: the "already uploaded" skip-set is not truncated at 100', () {
    /// Seeds one wall carrying [count] photos, each with real bytes on disk —
    /// essential, since a photo with no local bytes would fall into the
    /// missing-bytes bucket and `photosUploaded` would stay 0, making the
    /// whole test a false green.
    Future<void> seedManyPhotos(
      ({AppDatabase db, Directory docsDir, Directory srcDir, SyncService service}) c,
      int count,
    ) async {
      await c.db
          .into(c.db.areas)
          .insert(
            AreasCompanion.insert(
              id: 'area-1',
              createdAt: 100,
              updatedAt: 100,
              ownerId: const Value(_uidU1),
              name: 'Area',
            ),
          );
      await c.db
          .into(c.db.sectors)
          .insert(
            SectorsCompanion.insert(
              id: 'sector-1',
              createdAt: 100,
              updatedAt: 100,
              ownerId: const Value(_uidU1),
              areaId: 'area-1',
              name: 'Sector',
              sortOrder: 0,
            ),
          );
      await c.db
          .into(c.db.walls)
          .insert(
            WallsCompanion.insert(
              id: 'wall-1',
              createdAt: 100,
              updatedAt: 100,
              ownerId: const Value(_uidU1),
              sectorId: 'sector-1',
              name: 'Wall',
              sortOrder: 0,
            ),
          );
      for (var i = 0; i < count; i++) {
        final id = 'photo-${i.toString().padLeft(3, '0')}';
        final file = writeFile(c.srcDir, '$id.jpg');
        await c.db
            .into(c.db.photos)
            .insert(
              PhotosCompanion.insert(
                id: id,
                createdAt: 100,
                updatedAt: 100,
                ownerId: const Value(_uidU1),
                wallId: 'wall-1',
                localPath: file.path,
                kind: 'original',
                width: 800,
                height: 600,
              ),
            );
      }
    }

    test(
      'with 150 objects already in the remote the skip-set contains all 150 '
      'and the next push re-uploads ZERO — un-paged, list() returned only the '
      'first 100, so every push past that cut re-read and re-uploaded the '
      'FULL-RESOLUTION bytes of 50 photos already in the cloud',
      () async {
        final remote = FakeSyncRemote();
        final c = makeContainer(
          remote: remote,
          auth: FakeAuthRepository(_signedInU1),
        );
        addTearDown(() => c.db.close());

        await seedManyPhotos(c, 150);

        final first = await c.service.pushOwn();
        expect(first.photosUploaded, 150, reason: 'all of them are new');
        expect(remote.privateStorage, hasLength(150));

        remote.uploadedPrivatePaths.clear();
        remote.listPageRequests.clear();
        final second = await c.service.pushOwn();

        expect(
          second.photosUploaded,
          0,
          reason: 'every object is already in the cloud',
        );
        expect(remote.uploadedPrivatePaths, isEmpty);
        expect(
          remote.listPageRequests.where((r) => r.offset == 100),
          isNotEmpty,
          reason:
              'the caller must actually have asked for the SECOND page — '
              'without that request the skip-set stops at 100',
        );
      },
    );

    test(
      'the 150-object test is not vacuous: against a listing that truncates '
      'at one page (the pre-S6 behaviour) the second push re-uploads the 50 '
      'objects past the cut',
      () async {
        final remote = SinglePageListingSyncRemote();
        final c = makeContainer(
          remote: remote,
          auth: FakeAuthRepository(_signedInU1),
        );
        addTearDown(() => c.db.close());

        await seedManyPhotos(c, 150);

        await c.service.pushOwn();
        remote.uploadedPrivatePaths.clear();
        final second = await c.service.pushOwn();

        expect(
          second.photosUploaded,
          50,
          reason: 'exactly the objects the truncated skip-set cannot see',
        );
      },
    );
  });

  group('pull photo bytes are not re-downloaded once this device holds them', () {
    /// Seeds a shared topo owned by u2 into [remote] and returns a fresh u1
    /// bundle pointed at the same remote.
    Future<
      ({AppDatabase db, Directory docsDir, Directory srcDir, SyncService service})
    >
    seedSharedTopoAndMakeU1(FakeSyncRemote remote) async {
      final containerU2 = makeContainer(
        remote: remote,
        auth: FakeAuthRepository(_signedInU2),
      );
      addTearDown(() => containerU2.db.close());
      final sharedFile = writeFile(containerU2.srcDir, 'shared.jpg', 7);
      await seedWallHierarchy(
        containerU2.db,
        ownerId: _uidU2,
        visibility: 'shared',
        areaId: 'area-shared',
        sectorId: 'sector-shared',
        wallId: 'wall-shared',
        photoId: 'photo-shared',
        routeId: 'route-shared',
        localPath: sharedFile.path,
      );
      await containerU2.service.pushOwn();

      final containerU1 = makeContainer(
        remote: remote,
        auth: FakeAuthRepository(_signedInU1),
      );
      addTearDown(() => containerU1.db.close());
      return containerU1;
    }

    test(
      'the SECOND pull re-downloads nothing: public photos are fetched at FULL '
      'RESOLUTION and, per pull, up to kSharedPhotoByteBudgetPerPull of them '
      '(the metadata fetch itself is still unbounded) — and every pull trigger '
      '(sign-in, app resume, and every connectivity regain — which at a crag '
      'with flaky signal fires repeatedly) used to re-download and re-write '
      'every public photo, spending metered cellular data and, on web, the '
      'same origin quota the user\'s OWN topos live in',
      () async {
        final remote = FakeSyncRemote();
        final c = await seedSharedTopoAndMakeU1(remote);

        final first = await c.service.pullOwnAndShared();
        expect(
          first.photosDownloaded,
          1,
          reason: 'the first pull genuinely has to fetch the bytes',
        );
        expect(remote.downloadRequests, hasLength(1));

        remote.downloadRequests.clear();
        final second = await c.service.pullOwnAndShared();

        expect(
          remote.downloadRequests,
          isEmpty,
          reason:
              'this device already holds those exact bytes — re-fetching them '
              'is pure waste on every axis: cellular data, memory, and the '
              'local storage write that competes for quota with the user\'s '
              'own topos',
        );
        expect(second.photosDownloaded, 0);
      },
    );

    test(
      'the skip is a real presence check, not a "row exists" shortcut: if the '
      'local bytes are gone, the next pull DOES re-download and heals the row '
      '— the self-heal this pass exists for must survive the optimisation',
      () async {
        final remote = FakeSyncRemote();
        final c = await seedSharedTopoAndMakeU1(remote);

        await c.service.pullOwnAndShared();
        final healedPath = (await (c.db.select(
          c.db.photos,
        )..where((t) => t.id.equals('photo-shared'))).getSingle()).localPath;

        // Evict the bytes, leaving the row pointing at an absent file — the
        // L6 shape (metadata and pixels are separate, non-transactional
        // stores, so pixels can vanish under a surviving row).
        File(p.join(c.docsDir.path, healedPath)).deleteSync();

        remote.downloadRequests.clear();
        final result = await c.service.pullOwnAndShared();

        expect(
          remote.downloadRequests,
          hasLength(1),
          reason: 'bytes are genuinely missing, so they must be re-fetched',
        );
        expect(result.photosDownloaded, 1);
        expect(
          File(p.join(c.docsDir.path, healedPath)).existsSync(),
          isTrue,
          reason: 'and the file is back',
        );
      },
    );
  });

  group('the local-presence probe must stay cheap', () {
    /// The reported field failure, and what it cost:
    ///
    ///   Couldn't sync — Sync failed: shared photo downloads failed:
    ///   TimeoutException after 0:00:30.000000: the local database did not
    ///   answer a read within 30s
    ///
    /// The photo pass asks, per photo, "do I already hold these bytes?". It
    /// used to answer that twice as expensively as it needed to: a
    /// `SELECT ... WHERE id = ?` per photo (each one individually bounded by
    /// `kDatabaseQueryTimeout`), and then a FULL read of the — potentially
    /// multi-megabyte — blob whose contents were immediately discarded. During
    /// a pull the executor is at its busiest (it is importing rows, and every
    /// `watch()`-backed provider re-runs behind each table update), so one of
    /// those reads losing the race aborted the entire shared photo pass.
    ///
    /// Both halves are pinned here because both are invisible to the
    /// behavioural tests above: those assert WHAT the pass decides, and this
    /// asserts what the decision COSTS. A regression in either reads as
    /// "correct, just occasionally times out on a real library" — which is
    /// exactly how this shipped.
    test(
      'a pull that already holds every photo reads ZERO blobs, and does not '
      'issue one database read per photo',
      () async {
        const photoCount = 6;
        final remote = FakeSyncRemote();

        // u2 publishes `photoCount` shared topos.
        final u2 = makeContainer(
          remote: remote,
          auth: FakeAuthRepository(_signedInU2),
        );
        addTearDown(() => u2.db.close());
        final u2Photos = Directory(p.join(u2.docsDir.path, 'photos'))
          ..createSync(recursive: true);
        for (var i = 0; i < photoCount; i++) {
          final photoId = 'photo-probe$i';
          writeFile(u2Photos, '$photoId.jpg', i + 1);
          await seedWallHierarchy(
            u2.db,
            ownerId: _uidU2,
            visibility: 'shared',
            areaId: 'area-probe$i',
            sectorId: 'sector-probe$i',
            wallId: 'wall-probe$i',
            photoId: photoId,
            routeId: 'route-probe$i',
            localPath: p.join('photos', '$photoId.jpg'),
            updatedAt: 1000 + i,
          );
        }
        await u2.service.pushOwn();

        // u1: a fresh device whose photo store and executor both count.
        final selects = _PhotoSelectCounter();
        final db = AppDatabase(NativeDatabase.memory().interceptWith(selects));
        addTearDown(db.close);
        final docsDir = Directory(p.join(tmp.path, 'docs_probe'))..createSync();
        final photoFiles = _CountingPhotoFiles(docsDir: () async => docsDir);
        final service = SyncService(
          db: db,
          backupRepository: BackupRepository(db),
          remote: remote,
          authRepository: FakeAuthRepository(_signedInU1),
          connectivity: FakeConnectivityService(NetworkStatus.wifi),
          photoFiles: photoFiles,
          // Native (unbounded) so the first pull really does fetch all of
          // them — the budget is not what is under test here.
          isWeb: false,
        );

        final first = await service.pullOwnAndShared();
        expect(
          first.photosDownloaded,
          photoCount,
          reason: 'the first pull genuinely has to fetch every photo',
        );

        photoFiles.reset();
        selects.reset();
        await service.pullOwnAndShared();

        expect(
          photoFiles.readPhotoBytesCalls,
          0,
          reason:
              'every photo is already on this device, so the pass only needs '
              'to know they EXIST. Loading each blob to answer that — and '
              'discarding it — is tens of megabytes of pointless IndexedDB '
              'reads per pull on web, competing for the main thread with the '
              'very database reads this pull is bounded on',
        );
        expect(
          photoFiles.hasPhotoBytesCalls,
          greaterThanOrEqualTo(photoCount),
          reason: 'the presence check must still actually happen, per photo',
        );
        expect(
          selects.photoTableSelects,
          lessThan(photoCount),
          reason:
              'the photos table must be read in BATCHES, not once per photo. '
              'One read per photo is an N+1 whose every round trip carries its '
              'own 30s bound, and a pull is when the executor is least able to '
              'answer promptly',
        );
      },
    );
  });

  group('S7: the first public-photo pull is BOUNDED (bytes only)', () {
    /// Seeds [count] independent shared wall hierarchies owned by [ownerId],
    /// each with its own photo file and its own wall `updatedAt` (ascending
    /// from [baseUpdatedAt], so `$prefix${count - 1}` is the NEWEST wall).
    ///
    /// Each photo's bytes are written where a real import would put them —
    /// `<docs>/photos/<photoId><ext>`, with the row's `localPath` holding the
    /// RELATIVE `photos/<photoId><ext>` form `PhotoFiles.writePhotoBytes`
    /// returns. That detail is load-bearing for the budget tests: the pushed
    /// cloud row carries that same relative path, so on the RECEIVING device it
    /// resolves against that device's own docs dir (and is genuinely absent
    /// until downloaded), instead of accidentally naming a file that still
    /// exists inside the publishing device's temp directory.
    Future<void> seedLibrary(
      ({AppDatabase db, Directory docsDir, Directory srcDir, SyncService service}) c, {
      required String ownerId,
      required int count,
      String prefix = 's',
      String visibility = 'shared',
      int baseUpdatedAt = 1000,
    }) async {
      final photosDir = Directory(p.join(c.docsDir.path, 'photos'))
        ..createSync(recursive: true);
      for (var i = 0; i < count; i++) {
        final photoId = 'photo-$prefix$i';
        writeFile(photosDir, '$photoId.jpg', i + 1);
        await seedWallHierarchy(
          c.db,
          ownerId: ownerId,
          visibility: visibility,
          areaId: 'area-$prefix$i',
          sectorId: 'sector-$prefix$i',
          wallId: 'wall-$prefix$i',
          photoId: photoId,
          routeId: 'route-$prefix$i',
          localPath: p.join('photos', '$photoId.jpg'),
          updatedAt: baseUpdatedAt + i,
        );
      }
    }

    /// Pushes [count] shared walls owned by u2 into [remote] (as if another
    /// climber had published them), then returns a FRESH u1 bundle — an empty
    /// device about to do its very first pull.
    ///
    /// [isWeb] defaults to `true`: this whole group is pinning the BUDGETED
    /// (web) behaviour — see [SyncService]'s `_isWeb` doc — so every test
    /// below that doesn't override it is proof the budget still applies
    /// unchanged on web. The native (unbounded) counterpart tests pass
    /// `isWeb: false` explicitly (task #48).
    Future<
      ({AppDatabase db, Directory docsDir, Directory srcDir, SyncService service})
    >
    publishAsU2AndMakeFreshU1(
      FakeSyncRemote remote, {
      required int count,
      StoragePersistenceService? storage,
      int? sharedPhotoByteBudget,
      bool isWeb = true,
    }) async {
      final u2 = makeContainer(remote: remote, auth: FakeAuthRepository(_signedInU2));
      addTearDown(() => u2.db.close());
      await seedLibrary(u2, ownerId: _uidU2, count: count);
      await u2.service.pushOwn();

      final u1 = makeContainer(
        remote: remote,
        auth: FakeAuthRepository(_signedInU1),
        storage: storage,
        sharedPhotoByteBudget: sharedPhotoByteBudget,
        isWeb: isWeb,
      );
      addTearDown(() => u1.db.close());
      return u1;
    }

    List<String> sharedRequests(FakeSyncRemote remote) =>
        [for (final r in remote.downloadRequests) if (r.startsWith('shared/')) r];

    test(
      'the per-pull budget IS kPruneKeepNewestForeign, not a coincidentally '
      'equal literal: the eviction policy floors the newest N foreign photos, '
      'so fetching more than N is work eviction is designed to discard first',
      () {
        expect(kSharedPhotoByteBudgetPerPull, kPruneKeepNewestForeign);
        expect(
          kSharedPhotoByteBudgetPerPull,
          20,
          reason:
              'if this changes, it must be because kPruneKeepNewestForeign did',
        );
      },
    );

    test(
      'ASSERTION (a): the budget actually caps — a 5-photo public library '
      'pulled with a budget of 2 downloads exactly 2 photo files, and the '
      'other 3 are reported as skipped-for-budget, not as errors',
      () async {
        final remote = FakeSyncRemote();
        final c = await publishAsU2AndMakeFreshU1(
          remote,
          count: 5,
          sharedPhotoByteBudget: 2,
        );

        final result = await c.service.pullOwnAndShared();

        expect(sharedRequests(remote), hasLength(2));
        expect(result.photosDownloaded, 2);
        expect(result.sharedPhotoBytesSkipped, 3);
        expect(
          result.sharedPhotoBudgetReason,
          SharedPhotoBudgetReason.budgetSpent,
        );
      },
    );

    test(
      'the METADATA is NOT bounded: all 5 public walls, their routes and their '
      'photo ROWS import even though only 2 photos\' bytes were fetched — '
      'dropping metadata would make public topos vanish from the feed, which '
      'is strictly worse than a topo that reads fine but shows a placeholder',
      () async {
        final remote = FakeSyncRemote();
        final c = await publishAsU2AndMakeFreshU1(
          remote,
          count: 5,
          sharedPhotoByteBudget: 2,
        );

        await c.service.pullOwnAndShared();

        expect(await c.db.select(c.db.walls).get(), hasLength(5));
        expect(await c.db.select(c.db.photos).get(), hasLength(5));
        expect(await c.db.select(c.db.routes).get(), hasLength(5));
      },
    );

    test(
      'ordering is the exact DUAL of eviction order: the budget is spent on '
      'the NEWEST walls first, which are precisely the ones eviction\'s '
      'keepNewest floor refuses to delete — reverse either and a pull '
      'downloads exactly what the next prune throws away, forever',
      () async {
        final remote = FakeSyncRemote();
        final c = await publishAsU2AndMakeFreshU1(
          remote,
          count: 5,
          sharedPhotoByteBudget: 2,
        );

        await c.service.pullOwnAndShared();

        expect(
          sharedRequests(remote),
          ['shared/photo-s4.jpg', 'shared/photo-s3.jpg'],
          reason: 'walls s0..s4 ascend in updatedAt, so s4 is the newest',
        );
      },
    );

    test(
      'ASSERTION (e): a budget-capped pull is a SUCCESSFUL pull — errors stay '
      'empty and both sides report imported, so the orchestrator cannot turn '
      'the bound into SyncStatus.error, a withheld lastSyncedAt, a backoff '
      'retry, or a "Couldn\'t sync" empty state',
      () async {
        final remote = FakeSyncRemote();
        final c = await publishAsU2AndMakeFreshU1(
          remote,
          count: 5,
          sharedPhotoByteBudget: 1,
        );

        final result = await c.service.pullOwnAndShared();

        expect(result.sharedPhotoBytesSkipped, greaterThan(0));
        expect(result.errors, isEmpty);
        expect(result.didPull, isTrue);
        expect(result.ownImported, isTrue);
        expect(result.sharedImported, isTrue);
      },
    );

    test(
      'ASSERTION (b): the signed-in user\'s OWN photos are never bounded — a '
      'budget of ZERO still restores every one of u1\'s own photos, because '
      'the own-photo pass is unbudgeted by construction (a fresh install after '
      'a lost phone is exactly this call)',
      () async {
        final remote = FakeSyncRemote();

        final deviceA = makeContainer(
          remote: remote,
          auth: FakeAuthRepository(_signedInU1),
        );
        addTearDown(() => deviceA.db.close());
        await seedLibrary(
          deviceA,
          ownerId: _uidU1,
          count: 5,
          prefix: 'own',
          visibility: 'private',
        );
        await deviceA.service.pushOwn();

        final deviceB = makeContainer(
          remote: remote,
          auth: FakeAuthRepository(_signedInU1),
          sharedPhotoByteBudget: 0,
          isWeb: true,
        );
        addTearDown(() => deviceB.db.close());

        final result = await deviceB.service.pullOwnAndShared();

        expect(result.photosDownloaded, 5);
        expect(result.sharedPhotoBytesSkipped, 0);
        for (var i = 0; i < 5; i++) {
          expect(
            File(p.join(deviceB.docsDir.path, 'photos', 'photo-own$i.jpg')).existsSync(),
            isTrue,
            reason: 'own photo $i must come back regardless of the budget',
          );
        }
      },
    );

    test(
      'ASSERTION (b, shared batch): a wall in the SHARED batch that the '
      'signed-in user OWNS is exempt from the budget too — fetchSharedTopos '
      'returns the user\'s own published walls alongside everyone else\'s, and '
      'those are own data, not community cache',
      () async {
        // fetchOwnRows is emptied so the shared pass is the ONLY thing that
        // could fetch these bytes — otherwise the own pass would download them
        // first and the budget classifier would never be consulted.
        final remote = OwnRowsBlindRemote();

        final u1DeviceA = makeContainer(
          remote: remote,
          auth: FakeAuthRepository(_signedInU1),
        );
        addTearDown(() => u1DeviceA.db.close());
        await seedLibrary(u1DeviceA, ownerId: _uidU1, count: 3, prefix: 'mine');
        await u1DeviceA.service.pushOwn();

        final u1DeviceB = makeContainer(
          remote: remote,
          auth: FakeAuthRepository(_signedInU1),
          sharedPhotoByteBudget: 0,
          isWeb: true,
        );
        addTearDown(() => u1DeviceB.db.close());

        final result = await u1DeviceB.service.pullOwnAndShared();

        expect(
          result.photosDownloaded,
          3,
          reason: 'u1 owns these walls, so a zero foreign budget cannot ration them',
        );
        expect(result.sharedPhotoBytesSkipped, 0);
      },
    );

    test(
      'ambiguous ownership leans the OPPOSITE way from eviction: a shared wall '
      'with a NULL ownerId ("created while signed out", or predating the '
      'column) is PULLED even at a zero budget — eviction\'s ambiguous case is '
      'KEEP, so a bound\'s ambiguous case must be FETCH',
      () async {
        final remote = FakeSyncRemote();
        final c = await publishAsU2AndMakeFreshU1(
          remote,
          count: 2,
          sharedPhotoByteBudget: 0,
        );
        // The WALL is the ownership source of truth (matching
        // PublicPhotoPruneService._candidateSql); blank one out in the cloud.
        remote._rows['walls']!['wall-s0']!['ownerId'] = null;

        final result = await c.service.pullOwnAndShared();

        expect(
          sharedRequests(remote),
          ['shared/photo-s0.jpg'],
          reason: 'only the unprovable-ownership wall escapes the zero budget',
        );
        expect(result.photosDownloaded, 1);
        expect(
          result.sharedPhotoBytesSkipped,
          1,
          reason: 'the definitely-foreign wall-s1 is the one that is withheld',
        );
      },
    );

    test(
      'ASSERTION (c): estimate() == null means "no pressure signal", NOT '
      '"under pressure" — native, flutter test, and any browser that refuses '
      'the Storage API all land there, and off-web behaviour must not silently '
      'become "never pull public photos"',
      () async {
        final remote = FakeSyncRemote();
        final storage = FakeStoragePersistenceService();
        final c = await publishAsU2AndMakeFreshU1(
          remote,
          count: 3,
          storage: storage,
        );

        final result = await c.service.pullOwnAndShared();

        expect(storage.estimateCalls, 1);
        expect(
          result.photosDownloaded,
          3,
          reason: 'the plain count budget (default 20) applies, not zero',
        );
        expect(result.sharedPhotoBytesSkipped, 0);
        expect(
          result.sharedPhotoBudgetReason,
          SharedPhotoBudgetReason.withinBudget,
        );
      },
    );

    test(
      'ASSERTION (c, default wiring): the DEFAULT storage delegate — the inert '
      'native/flutter-test stub, i.e. what production gets off-web — also '
      'pulls the public photos rather than zero of them',
      () async {
        final remote = FakeSyncRemote();
        final c = await publishAsU2AndMakeFreshU1(remote, count: 3);

        final result = await c.service.pullOwnAndShared();

        expect(result.photosDownloaded, 3);
        expect(result.sharedPhotoBytesSkipped, 0);
      },
    );

    test(
      'ASSERTION (c, throwing estimate): an estimate() that THROWS is also '
      '"no signal" and still applies the plain budget',
      () async {
        final remote = FakeSyncRemote();
        final c = await publishAsU2AndMakeFreshU1(
          remote,
          count: 3,
          storage: FakeStoragePersistenceService(throwOnEstimate: true),
        );

        final result = await c.service.pullOwnAndShared();

        expect(result.photosDownloaded, 3);
        expect(result.sharedPhotoBytesSkipped, 0);
      },
    );

    test(
      'ASSERTION (d): already ABOVE the prune high watermark, a pull takes '
      'ZERO foreign photo bytes rather than its usual budget — adding '
      'megabytes to a store the prune pass is about to sweep is pure churn — '
      'and reports storagePressure so a bug report can tell that apart from an '
      'ordinary budget cap',
      () async {
        final remote = FakeSyncRemote();
        final c = await publishAsU2AndMakeFreshU1(
          remote,
          count: 3,
          storage: FakeStoragePersistenceService(
            // 0.90 > kPrunePressureHighWatermark (0.75).
            snapshot: const StorageEstimateSnapshot(
              usageBytes: 900,
              quotaBytes: 1000,
            ),
          ),
        );

        final result = await c.service.pullOwnAndShared();

        expect(sharedRequests(remote), isEmpty);
        expect(result.photosDownloaded, 0);
        expect(result.sharedPhotoBytesSkipped, 3);
        expect(
          result.sharedPhotoBudgetReason,
          SharedPhotoBudgetReason.storagePressure,
        );
        expect(
          result.errors,
          isEmpty,
          reason: 'storage pressure is a settled fact, not a sync failure',
        );
      },
    );

    test(
      'exactly ON the high watermark is NOT pressure (strictly-above, matching '
      'PublicPhotoPruneService), so the plain budget still applies',
      () async {
        final remote = FakeSyncRemote();
        final c = await publishAsU2AndMakeFreshU1(
          remote,
          count: 2,
          storage: FakeStoragePersistenceService(
            snapshot: const StorageEstimateSnapshot(
              usageBytes: 75,
              quotaBytes: 100,
            ),
          ),
        );

        final result = await c.service.pullOwnAndShared();

        expect(result.photosDownloaded, 2);
        expect(result.sharedPhotoBytesSkipped, 0);
      },
    );

    test(
      'photos this device ALREADY holds do not consume budget: after a first '
      'pull warms 2 of 4 public photos, a second pull with a budget of 2 '
      'fetches the OTHER 2 rather than spending the allowance on no-ops',
      () async {
        final remote = FakeSyncRemote();
        final c = await publishAsU2AndMakeFreshU1(
          remote,
          count: 4,
          sharedPhotoByteBudget: 2,
        );

        final first = await c.service.pullOwnAndShared();
        expect(first.photosDownloaded, 2);

        remote.downloadRequests.clear();
        final second = await c.service.pullOwnAndShared();

        expect(
          sharedRequests(remote),
          ['shared/photo-s1.jpg', 'shared/photo-s0.jpg'],
          reason:
              'the two warm ones cost nothing, so the full budget goes to the '
              'two still-missing (and now newest-missing) photos',
        );
        expect(second.photosDownloaded, 2);
        expect(second.sharedPhotoBytesSkipped, 0);
      },
    );

    test(
      'a budget-skipped photo keeps the localPath its cloud row carried, so '
      'the row still names the key its bytes WILL live under — that is what '
      'makes on-demand healing (MissingPhotoByteResolver) and a later pull '
      'both able to fill it in',
      () async {
        final remote = FakeSyncRemote();
        final c = await publishAsU2AndMakeFreshU1(
          remote,
          count: 2,
          sharedPhotoByteBudget: 1,
        );

        await c.service.pullOwnAndShared();

        final skipped = await (c.db.select(
          c.db.photos,
        )..where((t) => t.id.equals('photo-s0'))).getSingle();
        expect(
          p.basename(skipped.localPath),
          'photo-s0.jpg',
          reason: 'the canonical id + ext survive, which is all healing needs',
        );
      },
    );

    // ---- task #48: no origin quota to protect on native --------------------
    // Every test above pins the budget's BEHAVIOUR (proven with `isWeb: true`,
    // now the default `publishAsU2AndMakeFreshU1` passes). These pin the
    // opposite: with `isWeb: false` (native), `SyncService.pullOwnAndShared`
    // must NOT apply `sharedPhotoByteBudget` at all — the budget exists only
    // to protect a BROWSER origin's storage quota (`photo_files_web.dart`'s L3
    // write throws on quota), and an iOS/Android documents directory has no
    // such quota — the exact reason `PublicPhotoPruneService` is already a
    // permanent no-op there.

    test(
      'task #48 (a): on native, a budget that would otherwise cap a 5-photo '
      'public library instead downloads ALL 5 — the budget buys nothing off-web '
      'and must not cost function',
      () async {
        final remote = FakeSyncRemote();
        final c = await publishAsU2AndMakeFreshU1(
          remote,
          count: 5,
          sharedPhotoByteBudget: 2,
          isWeb: false,
        );

        final result = await c.service.pullOwnAndShared();

        expect(sharedRequests(remote), hasLength(5));
        expect(result.photosDownloaded, 5);
        expect(result.sharedPhotoBytesSkipped, 0);
        expect(
          result.sharedPhotoBudgetReason,
          SharedPhotoBudgetReason.withinBudget,
        );
      },
    );

    test(
      'task #48 (b): on native, even a ZERO budget downloads every foreign '
      'photo — proves the gate is "does not apply", not "applies a looser '
      'number"',
      () async {
        final remote = FakeSyncRemote();
        final c = await publishAsU2AndMakeFreshU1(
          remote,
          count: 3,
          sharedPhotoByteBudget: 0,
          isWeb: false,
        );

        final result = await c.service.pullOwnAndShared();

        expect(result.photosDownloaded, 3);
        expect(result.sharedPhotoBytesSkipped, 0);
      },
    );

    test(
      'task #48 (c): on native, storage pressure ALSO has no effect — even an '
      'origin reading 90% usage (well past the prune high watermark) still '
      'downloads every foreign photo, because native reads no pressure signal '
      'from a real `navigator.storage` in the first place',
      () async {
        final remote = FakeSyncRemote();
        final c = await publishAsU2AndMakeFreshU1(
          remote,
          count: 3,
          isWeb: false,
          storage: FakeStoragePersistenceService(
            // 0.90 > kPrunePressureHighWatermark (0.75) — would zero the web
            // budget outright (ASSERTION (d) above); must not matter here.
            snapshot: const StorageEstimateSnapshot(
              usageBytes: 900,
              quotaBytes: 1000,
            ),
          ),
        );

        final result = await c.service.pullOwnAndShared();

        expect(result.photosDownloaded, 3);
        expect(result.sharedPhotoBytesSkipped, 0);
        expect(
          result.sharedPhotoBudgetReason,
          SharedPhotoBudgetReason.withinBudget,
        );
      },
    );

    test(
      'task #48 (d): the METADATA/errors/imported contract is unchanged on '
      'native — an unbounded pull is still a clean, successful one',
      () async {
        final remote = FakeSyncRemote();
        final c = await publishAsU2AndMakeFreshU1(
          remote,
          count: 5,
          sharedPhotoByteBudget: 2,
          isWeb: false,
        );

        final result = await c.service.pullOwnAndShared();

        expect(result.errors, isEmpty);
        expect(result.didPull, isTrue);
        expect(result.ownImported, isTrue);
        expect(result.sharedImported, isTrue);
        expect(await c.db.select(c.db.walls).get(), hasLength(5));
        expect(await c.db.select(c.db.photos).get(), hasLength(5));
      },
    );
  });

  group('pullOwnAndShared: shared topo (headline feature)', () {
    test(
      'a shared wall owned by u2 is pulled into u1\'s local DB with its '
      'FOREIGN ownerId intact; a PRIVATE wall also owned by u2 is NOT '
      'pulled; u1\'s own pre-existing rows are unaffected',
      () async {
        final remote = FakeSyncRemote();

        // u2 pushes a SHARED wall + an unrelated PRIVATE wall.
        final containerU2 = makeContainer(remote: remote, auth: FakeAuthRepository(_signedInU2));
        addTearDown(() => containerU2.db.close());
        final sharedFile = writeFile(containerU2.srcDir, 'shared.jpg', 7);
        await seedWallHierarchy(
          containerU2.db,
          ownerId: _uidU2,
          visibility: 'shared',
          areaId: 'area-shared',
          sectorId: 'sector-shared',
          wallId: 'wall-shared',
          photoId: 'photo-shared',
          routeId: 'route-shared',
          localPath: sharedFile.path,
        );
        final privateFile = writeFile(containerU2.srcDir, 'private.jpg', 9);
        await seedWallHierarchy(
          containerU2.db,
          ownerId: _uidU2,
          visibility: 'private',
          areaId: 'area-private',
          sectorId: 'sector-private',
          wallId: 'wall-private',
          photoId: 'photo-private',
          routeId: 'route-private',
          localPath: privateFile.path,
        );
        await containerU2.service.pushOwn();

        // u1's local DB already has an unrelated own row before pulling.
        final containerU1 = makeContainer(remote: remote, auth: FakeAuthRepository(_signedInU1));
        addTearDown(() => containerU1.db.close());
        await containerU1.db.into(containerU1.db.areas).insert(
          AreasCompanion.insert(
            id: 'area-u1-own',
            createdAt: 100,
            updatedAt: 100,
            ownerId: const Value(_uidU1),
            name: 'u1 own area',
          ),
        );

        final result = await containerU1.service.pullOwnAndShared();

        expect(result.didPull, isTrue);
        expect(
          result.sharedRowsPulled,
          5,
          reason: 'the shared subtree is exactly 1 area + 1 sector + 1 wall '
              '+ 1 photo + 1 route',
        );

        final wall = await (containerU1.db.select(
          containerU1.db.walls,
        )..where((t) => t.id.equals('wall-shared'))).getSingleOrNull();
        expect(wall, isNotNull);
        expect(
          wall!.ownerId,
          _uidU2,
          reason: 'a shared row keeps the FOREIGN ownerId, not rewritten to '
              'the pulling user',
        );

        final sector = await (containerU1.db.select(
          containerU1.db.sectors,
        )..where((t) => t.id.equals('sector-shared'))).getSingleOrNull();
        expect(sector, isNotNull);
        expect(sector!.ownerId, _uidU2);

        final area = await (containerU1.db.select(
          containerU1.db.areas,
        )..where((t) => t.id.equals('area-shared'))).getSingleOrNull();
        expect(area, isNotNull);
        expect(area!.ownerId, _uidU2);

        final photo = await (containerU1.db.select(
          containerU1.db.photos,
        )..where((t) => t.id.equals('photo-shared'))).getSingleOrNull();
        expect(photo, isNotNull);
        expect(photo!.ownerId, _uidU2);
        expect(p.isRelative(photo.localPath), isTrue);
        final absolutePath = p.join(containerU1.docsDir.path, photo.localPath);
        expect(File(absolutePath).readAsBytesSync(), fixtureJpegBytes(7));

        final route = await (containerU1.db.select(
          containerU1.db.routes,
        )..where((t) => t.id.equals('route-shared'))).getSingleOrNull();
        expect(route, isNotNull);
        expect(route!.ownerId, _uidU2);

        // The PRIVATE wall (also owned by u2) must NOT have been pulled.
        final privateWall = await (containerU1.db.select(
          containerU1.db.walls,
        )..where((t) => t.id.equals('wall-private'))).getSingleOrNull();
        expect(privateWall, isNull);
        final privateArea = await (containerU1.db.select(
          containerU1.db.areas,
        )..where((t) => t.id.equals('area-private'))).getSingleOrNull();
        expect(privateArea, isNull);

        // u1's own pre-existing row is untouched.
        final ownArea = await (containerU1.db.select(
          containerU1.db.areas,
        )..where((t) => t.id.equals('area-u1-own'))).getSingle();
        expect(ownArea.name, 'u1 own area');
      },
    );
  });

  group('LWW safety', () {
    test(
      'a local own-row newer than the cloud copy is preserved by pull; once '
      'the cloud copy becomes newer, a subsequent pull DOES overwrite it',
      () async {
        final remote = FakeSyncRemote();
        final auth = FakeAuthRepository(_signedInU1);

        // Container A pushes an Area at updatedAt=100.
        final containerA = makeContainer(remote: remote, auth: auth);
        addTearDown(() => containerA.db.close());
        await containerA.db.into(containerA.db.areas).insert(
          AreasCompanion.insert(
            id: 'area-1',
            createdAt: 100,
            updatedAt: 100,
            ownerId: const Value(_uidU1),
            name: 'From cloud (older)',
          ),
        );
        await containerA.service.pushOwn();

        // Container B already has a LOCAL edit to the same row, newer
        // (updatedAt=500) than what's in the cloud.
        final containerB = makeContainer(remote: remote, auth: auth);
        addTearDown(() => containerB.db.close());
        await containerB.db.into(containerB.db.areas).insert(
          AreasCompanion.insert(
            id: 'area-1',
            createdAt: 100,
            updatedAt: 500,
            ownerId: const Value(_uidU1),
            name: 'Local edit (newer)',
          ),
        );

        await containerB.service.pullOwnAndShared();

        var area = await (containerB.db.select(
          containerB.db.areas,
        )..where((t) => t.id.equals('area-1'))).getSingle();
        expect(
          area.name,
          'Local edit (newer)',
          reason: 'the newer local row must survive a pull',
        );

        // Now container A pushes a NEWER edit (updatedAt=900).
        await (containerA.db.update(
          containerA.db.areas,
        )..where((t) => t.id.equals('area-1'))).write(
          const AreasCompanion(updatedAt: Value(900), name: Value('From cloud (newer)')),
        );
        await containerA.service.pushOwn();

        await containerB.service.pullOwnAndShared();

        area = await (containerB.db.select(
          containerB.db.areas,
        )..where((t) => t.id.equals('area-1'))).getSingle();
        expect(
          area.name,
          'From cloud (newer)',
          reason: 'once the cloud row is newer, a subsequent pull must '
              'overwrite the local row',
        );
      },
    );
  });

  group('push LWW safety (#2)', () {
    test(
      'a local row strictly OLDER than the cloud row is dropped on push '
      '(cloud keeps its newer value); a newer, equal, or brand-new local '
      'row IS pushed',
      () async {
        final remote = FakeSyncRemote();
        final auth = FakeAuthRepository(_signedInU1);

        // Container A seeds the cloud with a row at updatedAt=500.
        final containerA = makeContainer(remote: remote, auth: auth);
        addTearDown(() => containerA.db.close());
        await containerA.db.into(containerA.db.areas).insert(
          AreasCompanion.insert(
            id: 'area-1',
            createdAt: 100,
            updatedAt: 500,
            ownerId: const Value(_uidU1),
            name: 'Cloud (newer)',
          ),
        );
        await containerA.service.pushOwn();

        // Container B has a STALE local copy of the same row (older
        // updatedAt=100) and pushes it.
        final containerB = makeContainer(remote: remote, auth: auth);
        addTearDown(() => containerB.db.close());
        await containerB.db.into(containerB.db.areas).insert(
          AreasCompanion.insert(
            id: 'area-1',
            createdAt: 100,
            updatedAt: 100,
            ownerId: const Value(_uidU1),
            name: 'Local (stale)',
          ),
        );
        await containerB.service.pushOwn();

        var cloudRows = await remote.fetchOwnRows(_uidU1);
        var cloudArea = cloudRows['areas']!.firstWhere((r) => r['id'] == 'area-1');
        expect(
          cloudArea['name'],
          'Cloud (newer)',
          reason: 'a strictly older local row must not overwrite a newer cloud row',
        );

        // Bump the local row to be EQUAL to the cloud's updatedAt: ties go
        // to the pusher, so it IS pushed.
        await (containerB.db.update(
          containerB.db.areas,
        )..where((t) => t.id.equals('area-1'))).write(
          const AreasCompanion(updatedAt: Value(500), name: Value('Local (equal)')),
        );
        await containerB.service.pushOwn();

        cloudRows = await remote.fetchOwnRows(_uidU1);
        cloudArea = cloudRows['areas']!.firstWhere((r) => r['id'] == 'area-1');
        expect(
          cloudArea['name'],
          'Local (equal)',
          reason: 'a local row equal in updatedAt to the cloud row must still be pushed',
        );

        // Bump the local row to be strictly NEWER: pushed.
        await (containerB.db.update(
          containerB.db.areas,
        )..where((t) => t.id.equals('area-1'))).write(
          const AreasCompanion(updatedAt: Value(900), name: Value('Local (newer)')),
        );
        await containerB.service.pushOwn();

        cloudRows = await remote.fetchOwnRows(_uidU1);
        cloudArea = cloudRows['areas']!.firstWhere((r) => r['id'] == 'area-1');
        expect(
          cloudArea['name'],
          'Local (newer)',
          reason: 'a strictly newer local row must overwrite the cloud row',
        );

        // A brand-new row (absent from the cloud) is always pushed.
        await containerB.db.into(containerB.db.areas).insert(
          AreasCompanion.insert(
            id: 'area-2',
            createdAt: 1,
            updatedAt: 1,
            ownerId: const Value(_uidU1),
            name: 'Brand new',
          ),
        );
        await containerB.service.pushOwn();

        cloudRows = await remote.fetchOwnRows(_uidU1);
        expect(
          cloudRows['areas']!.any((r) => r['id'] == 'area-2'),
          isTrue,
          reason: 'a row absent from the cloud must always be pushed',
        );
      },
    );
  });

  group('community tables sync (comments/likes/ascents)', () {
    test(
      'C1a: a full push -> fetch-own round trip over the fake carries '
      'comments, likes, AND ascents for the owner',
      () async {
        final remote = FakeSyncRemote();
        final c = makeContainer(remote: remote, auth: FakeAuthRepository(_signedInU1));
        addTearDown(() => c.db.close());

        await seedWallHierarchy(
          c.db,
          ownerId: _uidU1,
          areaId: 'area-1',
          sectorId: 'sector-1',
          wallId: 'wall-1',
          photoId: 'photo-1',
          routeId: 'route-1',
        );
        await c.db.into(c.db.comments).insert(
          CommentsCompanion.insert(
            id: 'comment-1',
            createdAt: 100,
            updatedAt: 100,
            ownerId: const Value(_uidU1),
            wallId: const Value('wall-1'),
            body: 'Nice line!',
            authorName: const Value('u1'),
          ),
        );
        await c.db.into(c.db.likes).insert(
          LikesCompanion.insert(
            id: 'like-1',
            createdAt: 100,
            updatedAt: 100,
            ownerId: const Value(_uidU1),
            wallId: const Value('wall-1'),
          ),
        );
        await c.db.into(c.db.ascents).insert(
          AscentsCompanion.insert(
            id: 'ascent-1',
            createdAt: 100,
            updatedAt: 100,
            ownerId: const Value(_uidU1),
            routeId: 'route-1',
            wallId: 'wall-1',
            climbedAt: 12345,
            style: 'onsight',
            notes: const Value('Felt great'),
            gradeOpinion: const Value('soft'),
          ),
        );

        final result = await c.service.pushOwn();
        expect(result.didPush, isTrue);
        // 5 hierarchy rows (area/sector/wall/photo/route) + comment + like +
        // ascent.
        expect(result.rowsPushed, 8);

        final ownRows = await remote.fetchOwnRows(_uidU1);

        expect(ownRows['comments']!.map((r) => r['id']), ['comment-1']);
        final comment = ownRows['comments']!.single;
        expect(comment['ownerId'], _uidU1);
        expect(comment['wallId'], 'wall-1');
        expect(comment['body'], 'Nice line!');
        expect(comment['authorName'], 'u1');

        expect(ownRows['likes']!.map((r) => r['id']), ['like-1']);
        expect(ownRows['likes']!.single['ownerId'], _uidU1);
        expect(ownRows['likes']!.single['wallId'], 'wall-1');

        expect(ownRows['ascents']!.map((r) => r['id']), ['ascent-1']);
        final ascent = ownRows['ascents']!.single;
        expect(ascent['ownerId'], _uidU1);
        expect(ascent['routeId'], 'route-1');
        expect(ascent['wallId'], 'wall-1');
        expect(ascent['climbedAt'], 12345);
        expect(ascent['style'], 'onsight');
        expect(ascent['notes'], 'Felt great');
        expect(ascent['gradeOpinion'], 'soft');
      },
    );

    test(
      'C1b: SupabaseSyncRemote-shaped own-push/own-fetch includes comments/'
      'likes/ascents (via syncTableNames), and the fake asserts ownerId on '
      'upsert for these tables exactly like the original five',
      () async {
        final remote = FakeSyncRemote();

        expect(
          syncTableNames,
          containsAll(<String>['comments', 'likes', 'ascents']),
          reason: 'SupabaseSyncRemote.upsertOwnRows/fetchOwnRows both loop '
              'over syncTableNames, so adding the 3 names here is what '
              'makes the real remote push/fetch them too.',
        );

        expect(
          () => remote.upsertOwnRows(_uidU1, {
            'comments': [
              {
                'id': 'comment-bad',
                'createdAt': 100,
                'updatedAt': 100,
                'deletedAt': null,
                'remoteId': null,
                'dirty': false,
                'ownerId': _uidU2, // mismatched on purpose
                'wallId': 'wall-1',
                'body': 'x',
                'authorName': null,
              },
            ],
          }),
          throwsA(isA<AssertionError>()),
        );
      },
    );

    test(
      'C1c: pushOwn\'s Ascent payload carries visibility and authorName '
      '(Feature #12, public opt-in ascent logs)',
      () async {
        final remote = FakeSyncRemote();
        final c = makeContainer(remote: remote, auth: FakeAuthRepository(_signedInU1));
        addTearDown(() => c.db.close());

        await seedWallHierarchy(
          c.db,
          ownerId: _uidU1,
          areaId: 'area-vis',
          sectorId: 'sector-vis',
          wallId: 'wall-vis',
          photoId: 'photo-vis',
          routeId: 'route-vis',
        );
        await c.db.into(c.db.ascents).insert(
          AscentsCompanion.insert(
            id: 'ascent-vis',
            createdAt: 100,
            updatedAt: 100,
            ownerId: const Value(_uidU1),
            routeId: 'route-vis',
            wallId: 'wall-vis',
            climbedAt: 12345,
            style: 'redpoint',
            visibility: const Value('shared'),
            authorName: const Value('Alex Honnold'),
          ),
        );

        await c.service.pushOwn();

        final ownRows = await remote.fetchOwnRows(_uidU1);
        final ascent = ownRows['ascents']!.single;
        expect(ascent['visibility'], 'shared');
        expect(ascent['authorName'], 'Alex Honnold');
      },
    );

    test(
      'C1d: syncTableNames orders Ascents BEFORE Comments and Likes '
      '(Feature #12 FK: Comments.ascentId/Likes.ascentId -> Ascents.id — a '
      'row referencing an ascent must never push/import before that ascent '
      'exists remotely/locally)',
      () {
        final ascentsIndex = syncTableNames.indexOf('ascents');
        final commentsIndex = syncTableNames.indexOf('comments');
        final likesIndex = syncTableNames.indexOf('likes');

        expect(ascentsIndex, greaterThanOrEqualTo(0));
        expect(ascentsIndex, lessThan(commentsIndex));
        expect(ascentsIndex, lessThan(likesIndex));
      },
    );

    test(
      'C2a: after ownerA (u2) publishes a wall (visibility=shared) and '
      'pushes its comments+likes, a pull as ownerB (u1) imports them for '
      'that shared wall',
      () async {
        final remote = FakeSyncRemote();

        final containerU2 = makeContainer(remote: remote, auth: FakeAuthRepository(_signedInU2));
        addTearDown(() => containerU2.db.close());
        await seedWallHierarchy(
          containerU2.db,
          ownerId: _uidU2,
          visibility: 'shared',
          areaId: 'area-shared',
          sectorId: 'sector-shared',
          wallId: 'wall-shared',
          photoId: 'photo-shared',
          routeId: 'route-shared',
        );
        await containerU2.db.into(containerU2.db.comments).insert(
          CommentsCompanion.insert(
            id: 'comment-shared',
            createdAt: 100,
            updatedAt: 100,
            ownerId: const Value(_uidU2),
            wallId: const Value('wall-shared'),
            body: 'Great topo!',
          ),
        );
        await containerU2.db.into(containerU2.db.likes).insert(
          LikesCompanion.insert(
            id: 'like-shared',
            createdAt: 100,
            updatedAt: 100,
            ownerId: const Value(_uidU2),
            wallId: const Value('wall-shared'),
          ),
        );
        await containerU2.service.pushOwn();

        final containerU1 = makeContainer(remote: remote, auth: FakeAuthRepository(_signedInU1));
        addTearDown(() => containerU1.db.close());

        final result = await containerU1.service.pullOwnAndShared();
        expect(result.didPull, isTrue);

        final comment = await (containerU1.db.select(
          containerU1.db.comments,
        )..where((t) => t.id.equals('comment-shared'))).getSingleOrNull();
        expect(comment, isNotNull);
        expect(comment!.ownerId, _uidU2);
        expect(comment.body, 'Great topo!');

        final like = await (containerU1.db.select(
          containerU1.db.likes,
        )..where((t) => t.id.equals('like-shared'))).getSingleOrNull();
        expect(like, isNotNull);
        expect(like!.ownerId, _uidU2);
      },
    );

    test(
      'C2b: LWW for a Comment — a local comment newer than the cloud copy '
      'is preserved by pull; once the cloud copy becomes newer, a '
      'subsequent pull DOES overwrite it',
      () async {
        final remote = FakeSyncRemote();
        final auth = FakeAuthRepository(_signedInU1);

        final containerA = makeContainer(remote: remote, auth: auth);
        addTearDown(() => containerA.db.close());
        await seedWallHierarchy(
          containerA.db,
          ownerId: _uidU1,
          areaId: 'area-1',
          sectorId: 'sector-1',
          wallId: 'wall-1',
          photoId: 'photo-1',
          routeId: 'route-1',
        );
        await containerA.db.into(containerA.db.comments).insert(
          CommentsCompanion.insert(
            id: 'comment-1',
            createdAt: 100,
            updatedAt: 100,
            ownerId: const Value(_uidU1),
            wallId: const Value('wall-1'),
            body: 'From cloud (older)',
          ),
        );
        await containerA.service.pushOwn();

        final containerB = makeContainer(remote: remote, auth: auth);
        addTearDown(() => containerB.db.close());
        await seedWallHierarchy(
          containerB.db,
          ownerId: _uidU1,
          areaId: 'area-1',
          sectorId: 'sector-1',
          wallId: 'wall-1',
          photoId: 'photo-1',
          routeId: 'route-1',
        );
        await containerB.db.into(containerB.db.comments).insert(
          CommentsCompanion.insert(
            id: 'comment-1',
            createdAt: 100,
            updatedAt: 500,
            ownerId: const Value(_uidU1),
            wallId: const Value('wall-1'),
            body: 'Local edit (newer)',
          ),
        );

        await containerB.service.pullOwnAndShared();

        var comment = await (containerB.db.select(
          containerB.db.comments,
        )..where((t) => t.id.equals('comment-1'))).getSingle();
        expect(
          comment.body,
          'Local edit (newer)',
          reason: 'the newer local row must survive a pull',
        );

        await (containerA.db.update(
          containerA.db.comments,
        )..where((t) => t.id.equals('comment-1'))).write(
          const CommentsCompanion(
            updatedAt: Value(900),
            body: Value('From cloud (newer)'),
          ),
        );
        await containerA.service.pushOwn();

        await containerB.service.pullOwnAndShared();

        comment = await (containerB.db.select(
          containerB.db.comments,
        )..where((t) => t.id.equals('comment-1'))).getSingle();
        expect(
          comment.body,
          'From cloud (newer)',
          reason: 'once the cloud row is newer, a subsequent pull must '
              'overwrite the local row',
        );
      },
    );

    test(
      'C2c: ownerB\'s pull does NOT import ownerA\'s PRIVATE ascent — a '
      'default-visibility ascent stays untouched by a pull even though the '
      'ascent\'s wall is shared (contrast C2d: a SHARED ascent DOES pull, '
      'via the separate fetchSharedAscents path)',
      () async {
        final remote = FakeSyncRemote();

        final containerU2 = makeContainer(remote: remote, auth: FakeAuthRepository(_signedInU2));
        addTearDown(() => containerU2.db.close());
        await seedWallHierarchy(
          containerU2.db,
          ownerId: _uidU2,
          visibility: 'shared',
          areaId: 'area-shared2',
          sectorId: 'sector-shared2',
          wallId: 'wall-shared2',
          photoId: 'photo-shared2',
          routeId: 'route-shared2',
        );
        await containerU2.db.into(containerU2.db.ascents).insert(
          AscentsCompanion.insert(
            id: 'ascent-u2',
            createdAt: 100,
            updatedAt: 100,
            ownerId: const Value(_uidU2),
            routeId: 'route-shared2',
            wallId: 'wall-shared2',
            climbedAt: 100,
            style: 'onsight',
          ),
        );
        await containerU2.service.pushOwn();

        // Sanity: the ascent DID reach the remote via the owner's own push.
        final u2Own = await remote.fetchOwnRows(_uidU2);
        expect(u2Own['ascents']!.map((r) => r['id']), contains('ascent-u2'));

        final containerU1 = makeContainer(remote: remote, auth: FakeAuthRepository(_signedInU1));
        addTearDown(() => containerU1.db.close());

        final result = await containerU1.service.pullOwnAndShared();
        expect(result.didPull, isTrue);

        // Sanity: the pull DID run the shared path (the wall itself is
        // pulled) — so an empty ascents table below isn't just because
        // nothing was shared at all.
        final wall = await (containerU1.db.select(
          containerU1.db.walls,
        )..where((t) => t.id.equals('wall-shared2'))).getSingleOrNull();
        expect(wall, isNotNull);

        final u1Ascents = await containerU1.db.select(containerU1.db.ascents).get();
        expect(
          u1Ascents,
          isEmpty,
          reason: 'ascents are a private per-user logbook and must never be '
              'pulled as part of a shared topo, even though the ascent\'s '
              'wall is shared',
        );
      },
    );

    test(
      'C2d: ownerB\'s pull DOES import ownerA\'s SHARED ascent (Feature '
      '#12) via the separate fetchSharedAscents path, preserving its '
      'original ownerId, EVEN THOUGH the ascent\'s wall is private '
      '(contrast C2c, where a PRIVATE ascent does not pull) — the wall/'
      'route/sector/area ancestor chain comes along too (required to '
      'satisfy the local FK on Ascents.wallId/routeId), staying `private` '
      'itself and WITHOUT leaking the wall\'s other, unrelated routes',
      () async {
        final remote = FakeSyncRemote();

        final containerU2 = makeContainer(remote: remote, auth: FakeAuthRepository(_signedInU2));
        addTearDown(() => containerU2.db.close());
        await seedWallHierarchy(
          containerU2.db,
          ownerId: _uidU2,
          areaId: 'area-shared-ascent',
          sectorId: 'sector-shared-ascent',
          wallId: 'wall-shared-ascent',
          photoId: 'photo-shared-ascent',
          routeId: 'route-shared-ascent',
        );
        // A second, unrelated route on the SAME (private) wall — not
        // referenced by any shared ascent, so it must NOT leak to U1.
        await containerU2.db.into(containerU2.db.routes).insert(
          RoutesCompanion.insert(
            id: 'route-unrelated',
            createdAt: 100,
            updatedAt: 100,
            ownerId: const Value(_uidU2),
            wallId: 'wall-shared-ascent',
            photoId: 'photo-shared-ascent',
            number: 2,
            colorIndex: 1,
            pointsJson: '[]',
            symbolsJson: '[]',
            sortOrder: 1,
          ),
        );
        await containerU2.db.into(containerU2.db.ascents).insert(
          AscentsCompanion.insert(
            id: 'ascent-shared',
            createdAt: 100,
            updatedAt: 100,
            ownerId: const Value(_uidU2),
            routeId: 'route-shared-ascent',
            wallId: 'wall-shared-ascent',
            climbedAt: 100,
            style: 'redpoint',
            visibility: const Value('shared'),
            authorName: const Value('u2'),
          ),
        );
        await containerU2.service.pushOwn();

        final containerU1 = makeContainer(remote: remote, auth: FakeAuthRepository(_signedInU1));
        addTearDown(() => containerU1.db.close());

        final result = await containerU1.service.pullOwnAndShared();
        expect(result.didPull, isTrue);

        final ascent = await (containerU1.db.select(
          containerU1.db.ascents,
        )..where((t) => t.id.equals('ascent-shared'))).getSingleOrNull();
        expect(ascent, isNotNull);
        expect(
          ascent!.ownerId,
          _uidU2,
          reason: 'a pulled shared ascent keeps its ORIGINAL owner, never '
              'rewritten to the pulling user\'s own uid',
        );
        expect(ascent.visibility, 'shared');
        expect(ascent.authorName, 'u2');

        final wall = await (containerU1.db.select(
          containerU1.db.walls,
        )..where((t) => t.id.equals('wall-shared-ascent'))).getSingleOrNull();
        expect(
          wall,
          isNotNull,
          reason: 'the wall must come along too, to satisfy the local FK '
              'on Ascents.wallId — this device has never seen this owner\'s '
              'other data',
        );
        expect(
          wall!.visibility,
          'private',
          reason: 'pulling the ascent must not flip the wall itself into '
              'looking like a shared topo',
        );

        final referencedRoute = await (containerU1.db.select(
          containerU1.db.routes,
        )..where((t) => t.id.equals('route-shared-ascent'))).getSingleOrNull();
        expect(referencedRoute, isNotNull);

        final unrelatedRoute = await (containerU1.db.select(
          containerU1.db.routes,
        )..where((t) => t.id.equals('route-unrelated'))).getSingleOrNull();
        expect(
          unrelatedRoute,
          isNull,
          reason: 'fetchSharedAscents must only bring the SPECIFIC route(s) '
              'a shared ascent references, never the wall\'s other routes — '
              'that would leak a private topo just because one ascent on '
              'it opted in',
        );
      },
    );

    test(
      'C2e: a user\'s own pull (fresh device) restores their OWN ascent AND '
      'a comment/like attached to it (via ascentId, not wallId) without an '
      'FK violation, proving Ascents import BEFORE Comments/Likes within '
      'the own-row import batch too (Feature #12 FK: Comments.ascentId/'
      'Likes.ascentId -> Ascents.id)',
      () async {
        final remote = FakeSyncRemote();
        final auth = FakeAuthRepository(_signedInU1);

        final containerA = makeContainer(remote: remote, auth: auth);
        addTearDown(() => containerA.db.close());
        await seedWallHierarchy(
          containerA.db,
          ownerId: _uidU1,
          areaId: 'area-own-ascent',
          sectorId: 'sector-own-ascent',
          wallId: 'wall-own-ascent',
          photoId: 'photo-own-ascent',
          routeId: 'route-own-ascent',
        );
        await containerA.db.into(containerA.db.ascents).insert(
          AscentsCompanion.insert(
            id: 'ascent-own',
            createdAt: 100,
            updatedAt: 100,
            ownerId: const Value(_uidU1),
            routeId: 'route-own-ascent',
            wallId: 'wall-own-ascent',
            climbedAt: 100,
            style: 'flash',
          ),
        );
        await containerA.db.into(containerA.db.comments).insert(
          CommentsCompanion.insert(
            id: 'comment-on-own-ascent',
            createdAt: 100,
            updatedAt: 100,
            ownerId: const Value(_uidU1),
            ascentId: const Value('ascent-own'),
            body: 'Self note',
          ),
        );
        await containerA.db.into(containerA.db.likes).insert(
          LikesCompanion.insert(
            id: 'like-on-own-ascent',
            createdAt: 100,
            updatedAt: 100,
            ownerId: const Value(_uidU1),
            ascentId: const Value('ascent-own'),
          ),
        );
        await containerA.service.pushOwn();

        final containerB = makeContainer(remote: remote, auth: auth);
        addTearDown(() => containerB.db.close());

        // Would throw a Sqlite FK-constraint exception (this local db runs
        // under real `PRAGMA foreign_keys = ON`) if Comments/Likes were
        // imported before Ascents.
        final result = await containerB.service.pullOwnAndShared();
        expect(result.didPull, isTrue);

        final comment = await (containerB.db.select(
          containerB.db.comments,
        )..where((t) => t.id.equals('comment-on-own-ascent'))).getSingleOrNull();
        expect(comment, isNotNull);
        expect(comment!.ascentId, 'ascent-own');

        final like = await (containerB.db.select(
          containerB.db.likes,
        )..where((t) => t.id.equals('like-on-own-ascent'))).getSingleOrNull();
        expect(like, isNotNull);
        expect(like!.ascentId, 'ascent-own');
      },
    );
  });

  group('profiles sync (#18: editable synced display name)', () {
    test(
      'D1: pushOwn pushes the signed-in user\'s own profile row',
      () async {
        final remote = FakeSyncRemote();
        final c = makeContainer(remote: remote, auth: FakeAuthRepository(_signedInU1));
        addTearDown(() => c.db.close());

        await c.db.into(c.db.profiles).insert(
          ProfilesCompanion.insert(
            id: _uidU1,
            createdAt: 100,
            updatedAt: 100,
            ownerId: const Value(_uidU1),
            displayName: const Value('u1 display name'),
          ),
        );

        final result = await c.service.pushOwn();
        expect(result.didPush, isTrue);

        final ownRows = await remote.fetchOwnRows(_uidU1);
        expect(ownRows['profiles']!.map((r) => r['id']), [_uidU1]);
        expect(ownRows['profiles']!.single['displayName'], 'u1 display name');
      },
    );

    test(
      'D2: pullOwnAndShared restores the signed-in user\'s own profile '
      'into a fresh DB',
      () async {
        final remote = FakeSyncRemote();
        final auth = FakeAuthRepository(_signedInU1);

        final containerA = makeContainer(remote: remote, auth: auth);
        addTearDown(() => containerA.db.close());
        await containerA.db.into(containerA.db.profiles).insert(
          ProfilesCompanion.insert(
            id: _uidU1,
            createdAt: 100,
            updatedAt: 100,
            ownerId: const Value(_uidU1),
            displayName: const Value('Alex'),
          ),
        );
        await containerA.service.pushOwn();

        final containerB = makeContainer(remote: remote, auth: auth);
        addTearDown(() => containerB.db.close());
        expect(await containerB.db.select(containerB.db.profiles).get(), isEmpty);

        await containerB.service.pullOwnAndShared();

        final profile = await (containerB.db.select(
          containerB.db.profiles,
        )..where((t) => t.id.equals(_uidU1))).getSingle();
        expect(profile.displayName, 'Alex');
      },
    );

    test(
      'D3: pulling a shared topo also resolves its OWNER\'s display name '
      'via fetchProfiles, even though fetchSharedTopos itself has no FK to '
      'a profile',
      () async {
        final remote = FakeSyncRemote();

        final containerU2 = makeContainer(remote: remote, auth: FakeAuthRepository(_signedInU2));
        addTearDown(() => containerU2.db.close());
        await seedWallHierarchy(
          containerU2.db,
          ownerId: _uidU2,
          visibility: 'shared',
          areaId: 'area-shared3',
          sectorId: 'sector-shared3',
          wallId: 'wall-shared3',
          photoId: 'photo-shared3',
          routeId: 'route-shared3',
        );
        await containerU2.db.into(containerU2.db.profiles).insert(
          ProfilesCompanion.insert(
            id: _uidU2,
            createdAt: 100,
            updatedAt: 100,
            ownerId: const Value(_uidU2),
            displayName: const Value('u2 display name'),
          ),
        );
        await containerU2.service.pushOwn();

        final containerU1 = makeContainer(remote: remote, auth: FakeAuthRepository(_signedInU1));
        addTearDown(() => containerU1.db.close());

        final result = await containerU1.service.pullOwnAndShared();
        expect(result.didPull, isTrue);

        final u2Profile = await (containerU1.db.select(
          containerU1.db.profiles,
        )..where((t) => t.id.equals(_uidU2))).getSingleOrNull();
        expect(u2Profile, isNotNull);
        expect(u2Profile!.displayName, 'u2 display name');
      },
    );
  });

  group('P0 fix (#72): per-section pull isolation', () {
    test(
      'a throw in fetchSharedTopos does not prevent the signed-in user\'s '
      'OWN rows from being imported — PullResult.ownImported stays true '
      'while sharedImported is false and the shared-topos failure is '
      'recorded in errors (before this fix, ANY fetch throwing aborted the '
      'WHOLE pull, own rows included — the root cause of a fresh install '
      'ending up with neither own nor public topos)',
      () async {
        final workingRemote = FakeSyncRemote();
        final auth = FakeAuthRepository(_signedInU1);

        // Push u1's own data through a NORMAL (non-throwing) fake first, as
        // if it had already synced from another device.
        final containerA = makeContainer(remote: workingRemote, auth: auth);
        addTearDown(() => containerA.db.close());
        await seedWallHierarchy(
          containerA.db,
          ownerId: _uidU1,
          areaId: 'area-own',
          sectorId: 'sector-own',
          wallId: 'wall-own',
          photoId: 'photo-own',
          routeId: 'route-own',
        );
        await containerA.service.pushOwn();

        // Copy that same own-row data into a remote whose fetchSharedTopos
        // is rigged to throw, so a pull against it exercises the isolation.
        final throwingRemote = ThrowingFetchSharedToposRemote();
        await throwingRemote.upsertOwnRows(_uidU1, await workingRemote.fetchOwnRows(_uidU1));

        final containerB = makeContainer(remote: throwingRemote, auth: auth);
        addTearDown(() => containerB.db.close());

        final result = await containerB.service.pullOwnAndShared();

        expect(result.didPull, isTrue);
        expect(
          result.ownImported,
          isTrue,
          reason: 'own rows must still import despite the shared-topos throw',
        );
        expect(result.sharedImported, isFalse);
        expect(result.ownRowsPulled, greaterThan(0));
        expect(
          result.errors.any((e) => e.contains('shared topos fetch failed')),
          isTrue,
          reason: 'the shared-topos failure must be reported, not swallowed silently',
        );

        final area = await (containerB.db.select(
          containerB.db.areas,
        )..where((t) => t.id.equals('area-own'))).getSingleOrNull();
        expect(
          area,
          isNotNull,
          reason: 'own rows must be imported even though the shared fetch threw',
        );
        final wall = await (containerB.db.select(
          containerB.db.walls,
        )..where((t) => t.id.equals('wall-own'))).getSingleOrNull();
        expect(wall, isNotNull);
      },
    );

    test(
      'a shared-topos batch containing one malformed wall row (null '
      'required id) imports the OTHER valid shared wall and silently skips '
      'the bad one, instead of throwing and losing the whole shared batch '
      '(the real #72 trigger: a null field in one cloud row hit a non-null '
      '`as String` cast)',
      () async {
        final remote = FakeSyncRemote();

        final containerU2 = makeContainer(remote: remote, auth: FakeAuthRepository(_signedInU2));
        addTearDown(() => containerU2.db.close());
        await seedWallHierarchy(
          containerU2.db,
          ownerId: _uidU2,
          visibility: 'shared',
          areaId: 'area-good',
          sectorId: 'sector-good',
          wallId: 'wall-good',
          photoId: 'photo-good',
          routeId: 'route-good',
        );
        await containerU2.service.pushOwn();

        // Directly inject a malformed SECOND shared wall row (null id)
        // bypassing normal push — simulates a real cloud row with an
        // unexpectedly-null required column, the actual #72 trigger.
        remote._rows['walls']!['malformed-wall-key'] = {
          'id': null,
          'createdAt': 100,
          'updatedAt': 100,
          'deletedAt': null,
          'remoteId': null,
          'dirty': false,
          'ownerId': _uidU2,
          'sectorId': 'sector-good',
          'name': 'Malformed wall',
          'sortOrder': 0,
          'visibility': 'shared',
        };

        final containerU1 = makeContainer(remote: remote, auth: FakeAuthRepository(_signedInU1));
        addTearDown(() => containerU1.db.close());

        final result = await containerU1.service.pullOwnAndShared();

        expect(result.didPull, isTrue);
        expect(
          result.sharedImported,
          isTrue,
          reason: 'the malformed row must be SKIPPED, not fatal to the whole batch',
        );
        expect(result.errors, isEmpty);

        final goodWall = await (containerU1.db.select(
          containerU1.db.walls,
        )..where((t) => t.id.equals('wall-good'))).getSingleOrNull();
        expect(
          goodWall,
          isNotNull,
          reason: 'the valid shared wall must still import alongside the skipped bad row',
        );
      },
    );
  });

  group('syncServiceProvider guard', () {
    test(
      'constructs without throwing even though Supabase was never '
      'initialized in this test',
      () {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(() => db.close());
        final container = ProviderContainer(
          overrides: [appDatabaseProvider.overrideWithValue(db)],
        );
        addTearDown(container.dispose);

        expect(() => container.read(syncServiceProvider), returnsNormally);
        expect(container.read(syncServiceProvider), isA<SyncService>());
      },
    );

    test(
      'degrades to signed-out behavior end-to-end when Supabase is '
      'unavailable (never touches the remote, which would also be '
      'unavailable)',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(() => db.close());
        final container = ProviderContainer(
          overrides: [appDatabaseProvider.overrideWithValue(db)],
        );
        addTearDown(container.dispose);

        final service = container.read(syncServiceProvider);

        final pushResult = await service.pushOwn();
        expect(pushResult.outcome, SyncPushOutcome.skippedSignedOut);

        final pullResult = await service.pullOwnAndShared();
        expect(pullResult.outcome, SyncPullOutcome.skippedSignedOut);
      },
    );
  });

  // --- W-1: the shared pull must be bounded ------------------------------
  //
  // `.eq('visibility','shared')` with no limit, no geo scope and no paging,
  // then every row imported locally. The fix is a scope the SERVICE computes
  // (only it knows where the user climbs) and the REMOTE applies.

  group('W-1: scoping the shared pull', () {
    /// Gives the signed-in user one own wall at [lat]/[lng] — the thing that
    /// anchors the pull.
    Future<void> ownWallAt(
      AppDatabase db,
      double lat,
      double lng, {
      String suffix = '',
      int updatedAt = 100,
    }) async {
      await seedWallHierarchy(
        db,
        ownerId: _uidU1,
        areaId: 'own-area$suffix',
        sectorId: 'own-sector$suffix',
        wallId: 'own-wall$suffix',
        photoId: 'own-photo$suffix',
        routeId: 'own-route$suffix',
        updatedAt: updatedAt,
      );
      await (db.update(db.walls)
            ..where((w) => w.id.equals('own-wall$suffix')))
          .write(
            WallsCompanion(
              latitude: Value(lat),
              longitude: Value(lng),
              updatedAt: Value(updatedAt),
            ),
          );
    }

    /// A shared wall owned by somebody ELSE, at [lat]/[lng] or nowhere.
    ///
    /// Seeded the way every other cross-owner test in this file does it — by
    /// pushing from a SECOND container signed in as u2 — so the rows land in
    /// the fake remote through the same code path a real second device would
    /// use, rather than being hand-written into its maps.
    Future<void> foreignWall(
      FakeSyncRemote remote,
      String id, {
      double? lat,
      double? lng,
      int updatedAt = 100,
    }) async {
      final u2 = makeContainer(
        remote: remote,
        auth: FakeAuthRepository(_signedInU2),
      );
      addTearDown(() => u2.db.close());
      await seedWallHierarchy(
        u2.db,
        ownerId: _uidU2,
        visibility: 'shared',
        areaId: 'area-$id',
        sectorId: 'sector-$id',
        wallId: id,
        photoId: 'photo-$id',
        routeId: 'route-$id',
        localPath: writeFile(u2.srcDir, '$id.jpg').path,
        updatedAt: updatedAt,
      );
      if (lat != null && lng != null) {
        await (u2.db.update(u2.db.walls)..where((w) => w.id.equals(id))).write(
          WallsCompanion(
            latitude: Value(lat),
            longitude: Value(lng),
            updatedAt: Value(updatedAt),
          ),
        );
      }
      await u2.service.pushOwn();
    }

    test(
      'a user with a placed topo pulls the shared topos NEAR it and not the '
      'ones on another continent — this is the whole of W-1',
      () async {
        final remote = FakeSyncRemote();
        final c = makeContainer(
          remote: remote,
          auth: FakeAuthRepository(_signedInU1),
        );
        addTearDown(() => c.db.close());

        await ownWallAt(c.db, 45.92, 6.87); // Chamonix
        await foreignWall(remote, 'near', lat: 45.6, lng: 7.1);
        await foreignWall(remote, 'far', lat: -33.9, lng: 151.2); // Sydney

        await c.service.pullOwnAndShared();

        final ids = {for (final w in await c.db.select(c.db.walls).get()) w.id};
        expect(ids, contains('near'));
        expect(
          ids,
          isNot(contains('far')),
          reason: 'Sydney is not within 250 km of Chamonix',
        );
      },
    );

    test(
      'a shared topo with NO coordinates is still pulled. It cannot satisfy a '
      'coordinate filter, so without its own budget it would be invisible '
      'forever — a worse bug than the unbounded fetch',
      () async {
        final remote = FakeSyncRemote();
        final c = makeContainer(
          remote: remote,
          auth: FakeAuthRepository(_signedInU1),
        );
        addTearDown(() => c.db.close());

        await ownWallAt(c.db, 45.92, 6.87);
        await foreignWall(remote, 'nowhere');

        await c.service.pullOwnAndShared();

        final ids = {for (final w in await c.db.select(c.db.walls).get()) w.id};
        expect(ids, contains('nowhere'));
      },
    );

    test(
      'a user who has placed NOTHING gets no anchor but is still CAPPED — the '
      'ceiling is what protects the device, and it applies with or without '
      'geography',
      () async {
        final remote = FakeSyncRemote();
        final c = makeContainer(
          remote: remote,
          auth: FakeAuthRepository(_signedInU1),
        );
        addTearDown(() => c.db.close());

        await foreignWall(remote, 'anywhere', lat: -33.9, lng: 151.2);

        await c.service.pullOwnAndShared();

        final scope = remote.lastSharedScope!;
        expect(scope.anchor, isNull);
        expect(scope.limit, kSharedTopoLimit);
        expect(scope.isUnbounded, isFalse);
        // No anchor means no geography, so the far one legitimately arrives.
        final ids = {for (final w in await c.db.select(c.db.walls).get()) w.id};
        expect(ids, contains('anywhere'));
      },
    );

    test(
      'the anchor FOLLOWS the user: placing a topo in a new region re-aims the '
      'next pull, because the scope is recomputed from local rows every time',
      () async {
        final remote = FakeSyncRemote();
        final c = makeContainer(
          remote: remote,
          auth: FakeAuthRepository(_signedInU1),
        );
        addTearDown(() => c.db.close());

        await ownWallAt(c.db, 45.92, 6.87);
        await c.service.pullOwnAndShared();
        expect(remote.lastSharedScope!.anchor!.latitude, closeTo(45.92, 0.001));

        await ownWallAt(c.db, -33.9, 151.2, suffix: '-2', updatedAt: 900);
        await c.service.pullOwnAndShared();
        expect(remote.lastSharedScope!.anchor!.latitude, closeTo(-33.9, 0.001));
      },
    );

    test(
      'a topo pulled under an earlier, WIDER scope stays on the device. The '
      'pull is an idempotent upsert that never deletes (D-4), so narrowing the '
      'scope must not look like losing data',
      () async {
        final remote = FakeSyncRemote();
        final c = makeContainer(
          remote: remote,
          auth: FakeAuthRepository(_signedInU1),
        );
        addTearDown(() => c.db.close());

        // No own topos yet, so no anchor: the far one arrives.
        await foreignWall(remote, 'far', lat: -33.9, lng: 151.2);
        await c.service.pullOwnAndShared();
        expect(
          {for (final w in await c.db.select(c.db.walls).get()) w.id},
          contains('far'),
        );

        // Placing a topo in the Alps narrows every later pull.
        await ownWallAt(c.db, 45.92, 6.87);
        await c.service.pullOwnAndShared();

        expect(
          {for (final w in await c.db.select(c.db.walls).get()) w.id},
          contains('far'),
          reason: 'the earlier row must survive a narrower scope',
        );
      },
    );

    test('signed out asks for nothing at all', () async {
      final remote = FakeSyncRemote();
      final c = makeContainer(
        remote: remote,
        auth: FakeAuthRepository(_signedOut),
      );
      addTearDown(() => c.db.close());

      await c.service.pullOwnAndShared();
      expect(remote.lastSharedScope, isNull);
    });
  });
}

/// Index of [needle] in [haystack], or -1. Local to this file because the only
/// use is asserting a byte pattern is absent from published photo bytes.
int _indexOfBytes(List<int> haystack, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

/// Counts `SELECT`s against the `photos` table, so a test can assert that the
/// photo pass reads it in batches rather than once per photo.
///
/// Matches on the quoted table name drift emits (`FROM "photos"`), not a bare
/// substring: `"photos"` also appears inside column aliases and inside other
/// tables' foreign-key clauses, and counting those would make the assertion
/// pass or fail for reasons unrelated to what it is pinning.
class _PhotoSelectCounter extends QueryInterceptor {
  int photoTableSelects = 0;

  void reset() => photoTableSelects = 0;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (statement.contains('FROM "photos"')) photoTableSelects++;
    return executor.runSelect(statement, args);
  }
}

/// A real [PhotoFiles] (so the on-disk behaviour under test is genuine) that
/// records how its two presence-related entry points were used.
///
/// `extends`, not `implements`: [PhotoFiles] is concrete and its unoverridden
/// methods are exactly the behaviour these tests want — only the counting is
/// added.
class _CountingPhotoFiles extends PhotoFiles {
  _CountingPhotoFiles({required super.docsDir});

  int readPhotoBytesCalls = 0;
  int hasPhotoBytesCalls = 0;

  void reset() {
    readPhotoBytesCalls = 0;
    hasPhotoBytesCalls = 0;
  }

  @override
  Future<Uint8List?> readPhotoBytes(String stored) {
    readPhotoBytesCalls++;
    return super.readPhotoBytes(stored);
  }

  @override
  Future<bool> hasPhotoBytes(String stored) {
    hasPhotoBytesCalls++;
    return super.hasPhotoBytes(stored);
  }
}
