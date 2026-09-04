import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/features/scan/data/rock_scan_remote.dart';
import 'package:masi/features/scan/data/rock_scan_repository.dart';
import 'package:masi/features/scan/domain/rock_scan_status.dart';

void main() {
  late AppDatabase db;
  var clock = 1000;

  setUp(() async {
    clock = 1000;
    db = AppDatabase(NativeDatabase.memory());
    await db
        .into(db.areas)
        .insert(
          AreasCompanion.insert(
            id: 'area-1',
            createdAt: 1,
            updatedAt: 1,
            name: 'Area',
          ),
        );
    await db
        .into(db.sectors)
        .insert(
          SectorsCompanion.insert(
            id: 'sector-1',
            createdAt: 1,
            updatedAt: 1,
            areaId: 'area-1',
            name: 'Sector',
            sortOrder: 0,
          ),
        );
    for (final wallId in ['wall-1', 'wall-2']) {
      await db
          .into(db.walls)
          .insert(
            WallsCompanion.insert(
              id: wallId,
              createdAt: 1,
              updatedAt: 1,
              sectorId: 'sector-1',
              name: wallId,
              sortOrder: 0,
            ),
          );
    }
  });

  tearDown(() => db.close());

  RockScanRepository make({String? uid = 'uid-1'}) => RockScanRepository(
    db,
    nowMs: () => clock,
    currentUid: () => uid,
  );

  group('createScan', () {
    test('starts on the device, claimed by nobody, and dirty', () async {
      final id = await make().createScan(
        wallId: 'wall-1',
        durationMs: 45000,
        sizeBytes: 52428800,
      );

      final scan = await (db.select(
        db.rockScans,
      )..where((t) => t.id.equals(id))).getSingle();

      expect(scan.uploadState, RockScanUpload.pending.name);
      expect(
        scan.status,
        RockScanStatus.pending.name,
        reason: 'only the worker may ever move this off pending',
      );
      expect(scan.wallId, 'wall-1');
      expect(scan.durationMs, 45000);
      expect(scan.sizeBytes, 52428800);
      expect(scan.createdAt, 1000);
      expect(
        scan.dirty,
        isTrue,
        reason: 'an un-dirtied row never pushes, and with no outbox nothing '
            'would ever notice that it did not',
      );
      expect(
        scan.ownerId,
        'uid-1',
        reason: 'every RLS policy on this table keys on ownerId',
      );
      expect(scan.videoObjectPath, isNull);
      expect(scan.cloudObjectPath, isNull);
    });

    test('stamps a null owner when signed out rather than refusing', () async {
      // Local-first: recording a wall at a crag must work before anyone has
      // signed in. The row is simply unpushable until it has an owner.
      final id = await make(uid: null).createScan(wallId: 'wall-1');
      final scan = await (db.select(
        db.rockScans,
      )..where((t) => t.id.equals(id))).getSingle();
      expect(scan.ownerId, isNull);
    });

    test('ids are unique across scans of the same wall', () async {
      final repository = make();
      final a = await repository.createScan(wallId: 'wall-1');
      final b = await repository.createScan(wallId: 'wall-1');
      expect(a, isNot(b));
    });
  });

  group('setUploadState', () {
    test('records the object key, re-dirties, and moves updatedAt', () async {
      final repository = make();
      final id = await repository.createScan(wallId: 'wall-1');
      await (db.update(db.rockScans)..where((t) => t.id.equals(id))).write(
        const RockScansCompanion(dirty: Value(false)),
      );

      clock = 2000;
      await repository.setUploadState(
        id,
        RockScanUpload.uploaded,
        videoObjectPath: rockScanVideoObjectPath('uid-1', id),
      );

      final scan = await (db.select(
        db.rockScans,
      )..where((t) => t.id.equals(id))).getSingle();
      expect(scan.uploadState, 'uploaded');
      expect(scan.videoObjectPath, 'uid-1/$id.mp4');
      expect(scan.updatedAt, 2000);
      expect(scan.dirty, isTrue);
    });

    test('a later failure does not erase the key an earlier try recorded',
        () async {
      // The object may well be on the server already. Clearing the key would
      // orphan it and make a retry upload a second copy.
      final repository = make();
      final id = await repository.createScan(wallId: 'wall-1');
      await repository.setUploadState(
        id,
        RockScanUpload.uploaded,
        videoObjectPath: 'uid-1/$id.mp4',
      );

      await repository.setUploadState(id, RockScanUpload.failed);

      final scan = await (db.select(
        db.rockScans,
      )..where((t) => t.id.equals(id))).getSingle();
      expect(scan.uploadState, 'failed');
      expect(scan.videoObjectPath, 'uid-1/$id.mp4');
    });

    test('never touches a column the worker owns', () async {
      // The repository is the app's only writer for this table, so this is
      // where a stray write would come from. A local value here would look
      // authoritative on this device, contradict the server, and lose on the
      // next pull — silently, since it is stripped from every push.
      final repository = make();
      final id = await repository.createScan(wallId: 'wall-1');
      await (db.update(db.rockScans)..where((t) => t.id.equals(id))).write(
        const RockScansCompanion(
          status: Value('ready'),
          progressPct: Value(100),
          cloudObjectPath: Value('uid-1/cloud.ply'),
          manifestJson: Value('{"version":1}'),
          failureReason: Value('none'),
        ),
      );

      await repository.setUploadState(id, RockScanUpload.uploading);
      await repository.setUploadState(id, RockScanUpload.failed);
      await repository.deleteScan(id);

      final scan = await (db.select(
        db.rockScans,
      )..where((t) => t.id.equals(id))).getSingle();
      expect(scan.status, 'ready');
      expect(scan.progressPct, 100);
      expect(scan.cloudObjectPath, 'uid-1/cloud.ply');
      expect(scan.manifestJson, '{"version":1}');
      expect(scan.failureReason, 'none');
    });
  });

  group('deleteScan', () {
    test('tombstones rather than removing the row', () async {
      // A vanished row is indistinguishable from one that never synced, so
      // the deletion would never reach the user's other devices.
      final repository = make();
      final id = await repository.createScan(wallId: 'wall-1');

      clock = 3000;
      await repository.deleteScan(id);

      final scan = await (db.select(
        db.rockScans,
      )..where((t) => t.id.equals(id))).getSingle();
      expect(scan.deletedAt, 3000);
      expect(scan.updatedAt, 3000);
      expect(scan.dirty, isTrue);
    });
  });

  group('watchScansForWall', () {
    test('newest first, only this wall, and never a tombstone', () async {
      final repository = make();
      clock = 1000;
      final first = await repository.createScan(wallId: 'wall-1');
      clock = 2000;
      final second = await repository.createScan(wallId: 'wall-1');
      clock = 3000;
      final deleted = await repository.createScan(wallId: 'wall-1');
      clock = 4000;
      await repository.createScan(wallId: 'wall-2');
      await repository.deleteScan(deleted);

      final rows = await repository.watchScansForWall('wall-1').first;
      expect(rows.map((r) => r.id), [second, first]);
    });

    test('emits again when a pull lands the worker result', () async {
      // The viewer and the list both depend on this: the interesting
      // transition happens with no user action at all.
      final repository = make();
      final id = await repository.createScan(wallId: 'wall-1');

      final emissions = <String>[];
      final sub = repository.watchScan(id).listen((row) {
        if (row != null) emissions.add(row.status);
      });
      await Future<void>.delayed(Duration.zero);

      await (db.update(db.rockScans)..where((t) => t.id.equals(id))).write(
        const RockScansCompanion(status: Value('ready')),
      );
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(emissions, contains('ready'));
    });
  });

  group('object paths', () {
    test('put every object under the owner uid prefix RLS requires', () {
      // The bucket policy is `(storage.foldername(name))[1] = auth.uid()`, so
      // a key built any other way is rejected by the server rather than
      // landing somewhere odd.
      expect(rockScanVideoObjectPath('uid-1', 'scan-1'), 'uid-1/scan-1.mp4');
      expect(
        rockScanCloudObjectPath('uid-1', 'scan-1'),
        'uid-1/scan-1/cloud.ply',
      );
    });
  });
}
