import 'dart:io';

import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/core/db/database_provider.dart';
import 'package:climbtopo/features/account/data/auth_repository.dart';
import 'package:climbtopo/features/backup/application/sync_providers.dart';
import 'package:climbtopo/features/backup/data/backup_repository.dart';
import 'package:climbtopo/features/backup/data/connectivity_service.dart';
import 'package:climbtopo/features/backup/data/sync_remote.dart';
import 'package:climbtopo/features/backup/data/sync_service.dart';
import 'package:climbtopo/features/topo/data/photo_files.dart';
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

  @override
  Future<void> upsertOwnRows(
    String uid,
    Map<String, List<Map<String, dynamic>>> tablesToRows,
  ) async {
    for (final tableName in syncTableNames) {
      for (final row in tablesToRows[tableName] ?? const []) {
        assert(
          row['ownerId'] == uid,
          'upsertOwnRows($uid): row ${row['id']} in $tableName has ownerId '
          '${row['ownerId']}',
        );
        _rows[tableName]![row['id'] as String] = Map<String, dynamic>.from(row);
      }
    }
  }

  @override
  Future<Map<String, List<Map<String, dynamic>>>> fetchOwnRows(String uid) async {
    return {
      for (final tableName in syncTableNames)
        tableName: [
          for (final row in _rows[tableName]!.values)
            if (row['ownerId'] == uid) Map<String, dynamic>.from(row),
        ],
    };
  }

  @override
  Future<Map<String, List<Map<String, dynamic>>>> fetchSharedTopos() async {
    final sharedWalls = [
      for (final wall in _rows['walls']!.values)
        if (wall['visibility'] == 'shared') Map<String, dynamic>.from(wall),
    ];
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
      // NOTE: deliberately no 'ascents' key — Ascents are a private
      // per-user logbook and must never be visible via a shared-topo pull,
      // even when the ascent's wall is itself shared (see C2c).
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
}

/// In-memory [ConnectivityService] test double: reports whatever [status]
/// is currently set to (no `connectivity_plus` platform channel).
class FakeConnectivityService implements ConnectivityService {
  FakeConnectivityService(this.status);

  NetworkStatus status;

  @override
  Future<NetworkStatus> currentStatus() async => status;
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
      'C2c: ownerB\'s pull does NOT import ownerA\'s ascents (privacy) — '
      'the ascents table is untouched by a shared pull even though the '
      'ascent\'s wall is shared',
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
