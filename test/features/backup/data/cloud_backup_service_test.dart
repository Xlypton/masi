import 'dart:io';

import 'package:climbtopo/core/db/app_database.dart';
import 'package:climbtopo/features/account/data/auth_repository.dart';
import 'package:climbtopo/features/backup/data/backup_remote.dart';
import 'package:climbtopo/features/backup/data/backup_repository.dart';
import 'package:climbtopo/features/backup/data/cloud_backup_service.dart';
import 'package:climbtopo/features/backup/data/connectivity_service.dart';
import 'package:climbtopo/features/topo/data/photo_files.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// In-memory [BackupRemote] test double: a `Map` standing in for the
/// `backups` table (keyed by uid) and a `Map<String, List<int>>` standing
/// in for the `topo-photos` Storage bucket (keyed by the FULL uid-prefixed
/// object path) — no [SupabaseClient], no network.
class FakeBackupRemote implements BackupRemote {
  final Map<String, RemoteSnapshot> backupsTable = {};
  final Map<String, List<int>> storage = {};

  /// Every object path ever passed to [uploadPhoto], in call order —
  /// separate from [storage] so a test can assert upload CALLS even if a
  /// later call overwrote/duplicated a path.
  final List<String> uploadedPaths = [];

  @override
  Future<void> upsertSnapshot({
    required String uid,
    required Map<String, dynamic> snapshot,
    required int schemaVersion,
  }) async {
    backupsTable[uid] = RemoteSnapshot(
      snapshot: snapshot,
      schemaVersion: schemaVersion,
      updatedAt: DateTime.now().toUtc(),
    );
  }

  @override
  Future<RemoteSnapshot?> fetchSnapshot(String uid) async => backupsTable[uid];

  @override
  Future<void> uploadPhoto({
    required String uid,
    required String photoId,
    required String ext,
    required List<int> bytes,
  }) async {
    final path = '$uid/$photoId$ext';
    storage[path] = bytes;
    uploadedPaths.add(path);
  }

  @override
  Future<List<int>?> downloadPhoto({
    required String uid,
    required String objectPath,
  }) async => storage[objectPath];

  @override
  Future<Set<String>> listPhotoObjectPaths(String uid) async {
    final prefix = '$uid/';
    return {
      for (final path in storage.keys)
        if (path.startsWith(prefix)) path,
    };
  }
}

/// In-memory [ConnectivityService] test double: reports whatever
/// [status] is currently set to (no `connectivity_plus` platform channel).
class FakeConnectivityService implements ConnectivityService {
  FakeConnectivityService(this.status);

  NetworkStatus status;

  @override
  Future<NetworkStatus> currentStatus() async => status;
}

/// Minimal [AuthRepository] test double for the backup engine: only
/// [currentSession] matters here (push/pull are one-shot, not
/// stream-driven), so [authStateChanges] is a stream that never fires.
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
const _uidA = 'user-aaa';
final _signedInA = AuthSessionState.signedIn('a@example.com', uid: _uidA);

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('cloud_backup_test_');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// One (db, docsDir, srcDir, service) bundle — a stand-in for "one
  /// device": its own local database and its own app-owned photos
  /// directory, wired to whatever [remote]/[auth]/[connectivity] are
  /// handed in so a test can share a [FakeBackupRemote] across two bundles
  /// to simulate push-from-A / pull-into-B.
  ({
    AppDatabase db,
    Directory docsDir,
    Directory srcDir,
    CloudBackupService service,
  })
  makeContainer({
    required BackupRemote remote,
    required AuthRepository auth,
    ConnectivityService? connectivity,
    bool Function()? wifiOnly,
  }) {
    final db = AppDatabase(NativeDatabase.memory());
    final docsDir = Directory(p.join(tmp.path, 'docs_${_counter++}'))
      ..createSync();
    final srcDir = Directory(p.join(tmp.path, 'src_${_counter++}'))
      ..createSync();
    final service = CloudBackupService(
      backupRepository: BackupRepository(db),
      authRepository: auth,
      remote: remote,
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

  /// Seeds Area -> Sector -> Wall -> (original Photo + slice Photo sharing
  /// [originalFile]'s path, per S1) -> Route, mirroring
  /// `backup_repository_test.dart`'s seed so the exported snapshot is a
  /// realistic non-trivial hierarchy.
  Future<void> seedHierarchy(
    AppDatabase db,
    File originalFile, {
    String areaId = 'area-1',
    String sectorId = 'sector-1',
    String wallId = 'wall-1',
    String originalPhotoId = 'photo-original',
    String slicePhotoId = 'photo-slice',
    String routeId = 'route-1',
  }) async {
    await db.into(db.areas).insert(
      AreasCompanion.insert(
        id: areaId,
        createdAt: 100,
        updatedAt: 100,
        name: 'Area One',
      ),
    );
    await db.into(db.sectors).insert(
      SectorsCompanion.insert(
        id: sectorId,
        createdAt: 100,
        updatedAt: 100,
        areaId: areaId,
        name: 'Sector One',
        sortOrder: 0,
      ),
    );
    await db.into(db.walls).insert(
      WallsCompanion.insert(
        id: wallId,
        createdAt: 100,
        updatedAt: 100,
        sectorId: sectorId,
        name: 'Wall One',
        sortOrder: 0,
      ),
    );
    await db.into(db.photos).insert(
      PhotosCompanion.insert(
        id: originalPhotoId,
        createdAt: 100,
        updatedAt: 100,
        wallId: wallId,
        localPath: originalFile.path,
        kind: 'original',
        width: 800,
        height: 600,
      ),
    );
    await db.into(db.photos).insert(
      PhotosCompanion.insert(
        id: slicePhotoId,
        createdAt: 100,
        updatedAt: 100,
        wallId: wallId,
        localPath: originalFile.path,
        kind: 'slice',
        width: 400,
        height: 300,
        parentPhotoId: Value(originalPhotoId),
      ),
    );
    await db.into(db.routes).insert(
      RoutesCompanion.insert(
        id: routeId,
        createdAt: 100,
        updatedAt: 100,
        wallId: wallId,
        photoId: originalPhotoId,
        number: 1,
        colorIndex: 0,
        pointsJson: '[]',
        symbolsJson: '[]',
        sortOrder: 0,
      ),
    );
  }

  group('S4-a: push writes the backups row + one storage object per '
      'distinct photo file', () {
    test(
      'after seeding + push, the fake remote has a backups row for the uid '
      'with the exported snapshot, and one object at '
      '<uid>/<originalPhotoId>.<ext> (shared by the original + its slice)',
      () async {
        final remote = FakeBackupRemote();
        final c = makeContainer(
          remote: remote,
          auth: FakeAuthRepository(_signedInA),
        );
        addTearDown(() => c.db.close());

        final originalFile = writeFile(c.srcDir, 'wall.jpg');
        await seedHierarchy(c.db, originalFile);
        final expectedSnapshot = await BackupRepository(c.db).exportSnapshot();

        final result = await c.service.pushBackup();

        expect(result.didPush, isTrue);
        expect(result.photosUploaded, 1, reason: 'one distinct file: the '
            'slice shares the original\'s localPath');

        expect(remote.backupsTable.containsKey(_uidA), isTrue);
        expect(remote.backupsTable[_uidA]!.snapshot, expectedSnapshot);

        final expectedPath = '$_uidA/photo-original.jpg';
        expect(remote.storage.containsKey(expectedPath), isTrue);
        expect(remote.storage[expectedPath], List<int>.filled(16, 7));
        // Only ONE object was written, not two (de-duped by localPath).
        expect(remote.storage.keys.where((k) => k.startsWith(_uidA)), [
          expectedPath,
        ]);
      },
    );

    test(
      'pushing again with nothing changed does not re-upload the '
      'already-present photo object',
      () async {
        final remote = FakeBackupRemote();
        final c = makeContainer(
          remote: remote,
          auth: FakeAuthRepository(_signedInA),
        );
        addTearDown(() => c.db.close());

        final originalFile = writeFile(c.srcDir, 'wall.jpg');
        await seedHierarchy(c.db, originalFile);

        final first = await c.service.pushBackup();
        expect(first.photosUploaded, 1);

        final second = await c.service.pushBackup();
        expect(
          second.photosUploaded,
          0,
          reason: 'the object is already present remotely, so it must be '
              'skipped, not re-uploaded',
        );
        expect(remote.uploadedPaths, hasLength(1));
      },
    );
  });

  group('S4-b: round trip push (container A) -> pull (fresh container B)', () {
    test(
      'pullBackup(replace) on a fresh empty DB + fresh docsDir restores '
      'every row, writes each distinct photo file into the NEW docsDir, '
      'and rewrites every restored Photos.localPath to point there',
      () async {
        final remote = FakeBackupRemote();
        final auth = FakeAuthRepository(_signedInA);

        final containerA = makeContainer(remote: remote, auth: auth);
        addTearDown(() => containerA.db.close());
        final originalFile = writeFile(containerA.srcDir, 'wall.jpg', 42);
        await seedHierarchy(containerA.db, originalFile);
        await containerA.service.pushBackup();

        // A FRESH, otherwise-unrelated database + docs dir: nothing seeded,
        // simulating a brand-new device/reinstall for the same account.
        final containerB = makeContainer(remote: remote, auth: auth);
        addTearDown(() => containerB.db.close());
        expect(await containerB.db.select(containerB.db.areas).get(), isEmpty);

        final result = await containerB.service.pullBackup(
          mode: ConflictMode.replace,
        );

        expect(result.didRestore, isTrue);
        expect(result.photosRestored, 1);

        final areas = await containerB.db.select(containerB.db.areas).get();
        final sectors = await containerB.db.select(containerB.db.sectors).get();
        final walls = await containerB.db.select(containerB.db.walls).get();
        final photos = await containerB.db.select(containerB.db.photos).get();
        final routes = await containerB.db.select(containerB.db.routes).get();

        expect(areas.map((a) => a.id), ['area-1']);
        expect(sectors.map((s) => s.id), ['sector-1']);
        expect(walls.map((w) => w.id), ['wall-1']);
        expect(routes.map((r) => r.id), ['route-1']);
        expect(photos, hasLength(2));

        for (final photo in photos) {
          // writePhotoBytes now returns (and stores) the RELATIVE
          // photos/<id><ext> form, never baking container B's docsDir path
          // into the row — the row itself must be re-joined against
          // whichever docs dir is current at read time (see
          // PhotoFiles.resolvePhotoPath), so it survives a future container
          // rotation too, not just this restore.
          expect(
            p.isRelative(photo.localPath),
            isTrue,
            reason: 'restored localPath (${photo.localPath}) must be stored '
                'as the relative photos/<id><ext> form, not an absolute path '
                "baked in against container B's current docsDir",
          );
          expect(
            photo.localPath,
            isNot(originalFile.path),
            reason: 'must not still point at the OLD (container A) path',
          );
          expect(
            photo.localPath.startsWith('http'),
            isFalse,
            reason: 'must be a real local path, not a remote URL',
          );
          final absolutePath = p.join(containerB.docsDir.path, photo.localPath);
          expect(File(absolutePath).existsSync(), isTrue);
          expect(
            File(absolutePath).readAsBytesSync(),
            List<int>.filled(16, 42),
          );
        }

        // Original + slice share the SAME restored file, matching the S1
        // on-disk-sharing invariant.
        final localPaths = photos.map((photo) => photo.localPath).toSet();
        expect(localPaths, hasLength(1));
      },
    );
  });

  group(
    'S4-e: a RELATIVE localPath (photos/<id>.jpg canonical form since #17) '
    'resolves correctly for upload',
    () {
      test(
        'push uploads a photo whose Photos.localPath is stored as the '
        'RELATIVE form, by resolving it against the docsDir before '
        'touching the filesystem (regression: a raw File(localPath) would '
        'resolve against the process CWD and silently skip every photo)',
        () async {
          final remote = FakeBackupRemote();
          final c = makeContainer(
            remote: remote,
            auth: FakeAuthRepository(_signedInA),
          );
          addTearDown(() => c.db.close());

          // Write the photo file directly under <docsDir>/photos/<id>.jpg
          // (the real app-owned location PhotoFiles.importPhoto would have
          // copied it to) and store ONLY the relative form in the DB row,
          // mirroring what the app actually persists post-#17.
          final photosDir = Directory(p.join(c.docsDir.path, 'photos'))
            ..createSync(recursive: true);
          File(
            p.join(photosDir.path, 'photo-rel.jpg'),
          ).writeAsBytesSync(List<int>.filled(16, 3));

          await c.db.into(c.db.areas).insert(
            AreasCompanion.insert(
              id: 'area-1',
              createdAt: 100,
              updatedAt: 100,
              name: 'Area One',
            ),
          );
          await c.db.into(c.db.sectors).insert(
            SectorsCompanion.insert(
              id: 'sector-1',
              createdAt: 100,
              updatedAt: 100,
              areaId: 'area-1',
              name: 'Sector One',
              sortOrder: 0,
            ),
          );
          await c.db.into(c.db.walls).insert(
            WallsCompanion.insert(
              id: 'wall-1',
              createdAt: 100,
              updatedAt: 100,
              sectorId: 'sector-1',
              name: 'Wall One',
              sortOrder: 0,
            ),
          );
          await c.db.into(c.db.photos).insert(
            PhotosCompanion.insert(
              id: 'photo-rel',
              createdAt: 100,
              updatedAt: 100,
              wallId: 'wall-1',
              localPath: 'photos/photo-rel.jpg',
              kind: 'original',
              width: 800,
              height: 600,
            ),
          );

          final result = await c.service.pushBackup();

          expect(result.didPush, isTrue);
          expect(result.photosUploaded, 1);
          final expectedPath = '$_uidA/photo-rel.jpg';
          expect(remote.storage.containsKey(expectedPath), isTrue);
          expect(remote.storage[expectedPath], List<int>.filled(16, 3));
        },
      );
    },
  );

  group('S4-c: every uploaded storage object path is uid-prefixed', () {
    test(
      'two distinct photo files across two walls both upload under '
      '<uid>/...',
      () async {
        final remote = FakeBackupRemote();
        final c = makeContainer(
          remote: remote,
          auth: FakeAuthRepository(_signedInA),
        );
        addTearDown(() => c.db.close());

        final fileOne = writeFile(c.srcDir, 'one.jpg', 1);
        await seedHierarchy(
          c.db,
          fileOne,
          areaId: 'area-1',
          sectorId: 'sector-1',
          wallId: 'wall-1',
          originalPhotoId: 'photo-one',
          slicePhotoId: 'photo-one-slice',
          routeId: 'route-1',
        );
        final fileTwo = writeFile(c.srcDir, 'two.jpg', 2);
        await seedHierarchy(
          c.db,
          fileTwo,
          areaId: 'area-2',
          sectorId: 'sector-2',
          wallId: 'wall-2',
          originalPhotoId: 'photo-two',
          slicePhotoId: 'photo-two-slice',
          routeId: 'route-2',
        );

        final result = await c.service.pushBackup();

        expect(result.photosUploaded, 2);
        expect(remote.uploadedPaths, hasLength(2));
        for (final path in remote.uploadedPaths) {
          expect(
            path.startsWith('$_uidA/'),
            isTrue,
            reason: 'object path "$path" must start with "$_uidA/"',
          );
        }
        expect(remote.uploadedPaths.toSet(), {
          '$_uidA/photo-one.jpg',
          '$_uidA/photo-two.jpg',
        });
      },
    );
  });

  group('S4-d: wifiOnly gating', () {
    Future<CloudBackupService> pushWith(
      FakeBackupRemote remote,
      NetworkStatus status, {
      required bool wifiOnly,
    }) async {
      final c = makeContainer(
        remote: remote,
        auth: FakeAuthRepository(_signedInA),
        connectivity: FakeConnectivityService(status),
        wifiOnly: () => wifiOnly,
      );
      addTearDown(() => c.db.close());
      final file = writeFile(c.srcDir, 'wall.jpg');
      await seedHierarchy(c.db, file);
      return c.service;
    }

    test(
      'wifiOnly=true + cellular does NOT upload; returns skippedNotWifi',
      () async {
        final remote = FakeBackupRemote();
        final service = await pushWith(
          remote,
          NetworkStatus.cellular,
          wifiOnly: true,
        );

        final result = await service.pushBackup();

        expect(result.outcome, PushOutcome.skippedNotWifi);
        expect(result.didPush, isFalse);
        expect(remote.backupsTable, isEmpty);
        expect(remote.storage, isEmpty);
      },
    );

    test(
      'wifiOnly=true + none does NOT upload; returns skippedNotWifi',
      () async {
        final remote = FakeBackupRemote();
        final service = await pushWith(
          remote,
          NetworkStatus.none,
          wifiOnly: true,
        );

        final result = await service.pushBackup();

        expect(result.outcome, PushOutcome.skippedNotWifi);
        expect(remote.backupsTable, isEmpty);
        expect(remote.storage, isEmpty);
      },
    );

    test('wifiOnly=true + wifi DOES upload', () async {
      final remote = FakeBackupRemote();
      final service = await pushWith(
        remote,
        NetworkStatus.wifi,
        wifiOnly: true,
      );

      final result = await service.pushBackup();

      expect(result.didPush, isTrue);
      expect(remote.backupsTable.containsKey(_uidA), isTrue);
      expect(remote.storage, isNotEmpty);
    });

    test(
      'wifiOnly=false pushes regardless of connectivity (cellular)',
      () async {
        final remote = FakeBackupRemote();
        final service = await pushWith(
          remote,
          NetworkStatus.cellular,
          wifiOnly: false,
        );

        final result = await service.pushBackup();

        expect(result.didPush, isTrue);
        expect(remote.backupsTable.containsKey(_uidA), isTrue);
      },
    );
  });

  group('signed-out is a safe no-op', () {
    test('pushBackup() signed out does not throw and leaves the remote '
        'untouched', () async {
      final remote = FakeBackupRemote();
      final c = makeContainer(remote: remote, auth: FakeAuthRepository(_signedOut));
      addTearDown(() => c.db.close());
      final file = writeFile(c.srcDir, 'wall.jpg');
      await seedHierarchy(c.db, file);

      final result = await c.service.pushBackup();

      expect(result.outcome, PushOutcome.skippedSignedOut);
      expect(remote.backupsTable, isEmpty);
      expect(remote.storage, isEmpty);
    });

    test('pullBackup() signed out does not throw and leaves the local DB '
        'untouched', () async {
      final remote = FakeBackupRemote();
      // Seed the remote via a signed-in push so there IS something to
      // pull, to prove the signed-out gate — not an empty remote — is what
      // stops it.
      final auth = FakeAuthRepository(_signedInA);
      final containerA = makeContainer(remote: remote, auth: auth);
      addTearDown(() => containerA.db.close());
      final file = writeFile(containerA.srcDir, 'wall.jpg');
      await seedHierarchy(containerA.db, file);
      await containerA.service.pushBackup();

      final signedOutAuth = FakeAuthRepository(_signedOut);
      final containerB = makeContainer(remote: remote, auth: signedOutAuth);
      addTearDown(() => containerB.db.close());

      final result = await containerB.service.pullBackup();

      expect(result.outcome, PullOutcome.skippedSignedOut);
      expect(await containerB.db.select(containerB.db.areas).get(), isEmpty);
    });

    test(
      'pullBackup() with no prior push returns nothingToRestore',
      () async {
        final remote = FakeBackupRemote();
        final c = makeContainer(
          remote: remote,
          auth: FakeAuthRepository(_signedInA),
        );
        addTearDown(() => c.db.close());

        final result = await c.service.pullBackup();

        expect(result.outcome, PullOutcome.nothingToRestore);
      },
    );
  });

  group('Bonus: lww pull keeps a newer local row, overwrites an older one', () {
    test(
      'a local row newer than the remote snapshot is preserved by the '
      'default lww pull; once the remote snapshot becomes newer, a '
      'subsequent lww pull DOES overwrite it',
      () async {
        final remote = FakeBackupRemote();
        final auth = FakeAuthRepository(_signedInA);

        // Container A pushes an Area at updatedAt=100.
        final containerA = makeContainer(remote: remote, auth: auth);
        addTearDown(() => containerA.db.close());
        await containerA.db.into(containerA.db.areas).insert(
          AreasCompanion.insert(
            id: 'area-1',
            createdAt: 100,
            updatedAt: 100,
            name: 'From cloud (older)',
          ),
        );
        await containerA.service.pushBackup();

        // Container B already has a LOCAL edit to the same row, newer
        // (updatedAt=500) than what's in the cloud.
        final containerB = makeContainer(remote: remote, auth: auth);
        addTearDown(() => containerB.db.close());
        await containerB.db.into(containerB.db.areas).insert(
          AreasCompanion.insert(
            id: 'area-1',
            createdAt: 100,
            updatedAt: 500,
            name: 'Local edit (newer)',
          ),
        );

        await containerB.service.pullBackup(); // default: lww

        var area = await (containerB.db.select(
          containerB.db.areas,
        )..where((t) => t.id.equals('area-1'))).getSingle();
        expect(
          area.name,
          'Local edit (newer)',
          reason: 'the newer local row must survive an lww pull',
        );

        // Now container A pushes a NEWER edit (updatedAt=900).
        await (containerA.db.update(
          containerA.db.areas,
        )..where((t) => t.id.equals('area-1'))).write(
          const AreasCompanion(
            updatedAt: Value(900),
            name: Value('From cloud (newer)'),
          ),
        );
        await containerA.service.pushBackup();

        await containerB.service.pullBackup(); // default: lww, again

        area = await (containerB.db.select(
          containerB.db.areas,
        )..where((t) => t.id.equals('area-1'))).getSingle();
        expect(
          area.name,
          'From cloud (newer)',
          reason: 'once the remote row is newer, a subsequent lww pull '
              'must overwrite the local row',
        );
      },
    );
  });
}

int _counter = 0;
