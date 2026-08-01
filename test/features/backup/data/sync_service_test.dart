import 'dart:io';

import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/account/data/auth_repository.dart';
import 'package:masi/features/backup/application/sync_providers.dart';
import 'package:masi/features/backup/data/backup_repository.dart';
import 'package:masi/features/backup/data/connectivity_service.dart';
import 'package:masi/features/backup/data/sync_remote.dart';
import 'package:masi/features/backup/data/sync_service.dart';
import 'package:masi/features/topo/data/photo_files.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

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

  @override
  Future<List<TablePushOutcome>> upsertOwnRows(
    String uid,
    Map<String, List<Map<String, dynamic>>> tablesToRows,
  ) async {
    final outcomes = <TablePushOutcome>[];
    for (final tableName in syncTableNames) {
      final rows = tablesToRows[tableName];
      if (rows == null || rows.isEmpty) continue;
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

  @override
  Future<Map<String, List<Map<String, dynamic>>>> fetchSharedTopos() async {
    // Mirrors SupabaseSyncRemote.fetchSharedTopos's row-validity guard (P0
    // fix, #72): a malformed wall row (missing id/sectorId) is skipped
    // rather than throwing on the `as String` casts below, so a test can
    // seed one directly into `_rows['walls']` to exercise the fix.
    final sharedWalls = filterValidSyncRows(
      [
        for (final wall in _rows['walls']!.values)
          if (wall['visibility'] == 'shared') Map<String, dynamic>.from(wall),
      ],
      const ['id', 'sectorId'],
      debugLabel: 'shared wall',
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
  }

  @override
  Future<List<int>?> downloadPhoto({
    required String uid,
    required String objectPath,
  }) async => privateStorage[objectPath];

  @override
  Future<Set<String>> listPhotoObjectPaths(String uid) async {
    final prefix = '$uid/';
    return {for (final path in privateStorage.keys) if (path.startsWith(prefix)) path};
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
  }

  @override
  Future<List<int>?> downloadSharedPhoto(String objectPath) async => sharedStorage[objectPath];

  @override
  Future<Set<String>> listSharedPhotoObjectPaths() async => sharedStorage.keys.toSet();

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
}

/// [FakeSyncRemote] variant whose [fetchSharedTopos] always throws — used
/// to prove the P0 fix (#72): a throw in the shared-topos fetch must not
/// prevent the signed-in user's OWN rows from being fetched+imported by the
/// SAME [SyncService.pullOwnAndShared] call (own is fetched+imported FIRST
/// and in total isolation from every shared sub-fetch).
class ThrowingFetchSharedToposRemote extends FakeSyncRemote {
  @override
  Future<Map<String, List<Map<String, dynamic>>>> fetchSharedTopos() async {
    throw Exception('shared topos fetch failed: simulated cloud error');
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

  /// §1e's second seam member, written here as part of the ONE merged
  /// rewrite of this class (reconciliation decision #5). No `@override`
  /// yet: `ConnectivityService` does not declare `statusChanges()` until
  /// §1e T7, and annotating a non-overriding member is an analyzer error.
  /// §1e T7's only remaining job on this class is to add that annotation.
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
    );
    return (db: db, docsDir: docsDir, srcDir: srcDir, service: service);
  }

  /// Writes a real (non-empty) file the push step can read bytes from.
  File writeFile(Directory dir, String name, [int fill = 7]) {
    final f = File(p.join(dir.path, name));
    f.writeAsBytesSync(List<int>.filled(16, fill));
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
        expect(File(absolutePath).readAsBytesSync(), List<int>.filled(16, 42));
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
        expect(File(absolutePath).readAsBytesSync(), List<int>.filled(16, 7));

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
}
