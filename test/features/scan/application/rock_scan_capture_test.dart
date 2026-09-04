import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/account/application/auth_providers.dart';
import 'package:masi/features/scan/application/rock_scan_providers.dart';
import 'package:masi/features/scan/data/rock_scan_remote.dart';
import 'package:masi/features/scan/domain/rock_scan_status.dart';

/// Records what it was asked to upload, and fails on demand.
class _FakeRemote implements RockScanRemote {
  _FakeRemote({this.failWith});

  final Object? failWith;
  final List<({String uid, String scanId, int byteCount})> uploads = [];
  final Map<String, Uint8List> clouds = {};

  @override
  Future<String> uploadVideo({
    required String uid,
    required String scanId,
    required Uint8List bytes,
  }) async {
    if (failWith != null) throw failWith!;
    uploads.add((uid: uid, scanId: scanId, byteCount: bytes.length));
    return rockScanVideoObjectPath(uid, scanId);
  }

  @override
  Future<Uint8List?> downloadCloud(String objectPath) async =>
      clouds[objectPath];
}

void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await db.into(db.areas).insert(
          AreasCompanion.insert(
            id: 'area-1',
            createdAt: 1,
            updatedAt: 1,
            name: 'Area',
          ),
        );
    await db.into(db.sectors).insert(
          SectorsCompanion.insert(
            id: 'sector-1',
            createdAt: 1,
            updatedAt: 1,
            areaId: 'area-1',
            name: 'Sector',
            sortOrder: 0,
          ),
        );
    await db.into(db.walls).insert(
          WallsCompanion.insert(
            id: 'wall-1',
            createdAt: 1,
            updatedAt: 1,
            sectorId: 'sector-1',
            name: 'Wall',
            sortOrder: 0,
          ),
        );
  });

  tearDown(() => db.close());

  ProviderContainer makeContainer({
    required RockScanRemote remote,
    String? uid = 'uid-1',
  }) {
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        nowMsProvider.overrideWithValue(() => 1000),
        currentUidProvider.overrideWithValue(() => uid),
        rockScanRemoteProvider.overrideWithValue(remote),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Uint8List videoBytes([int length = 2048]) =>
      Uint8List.fromList(List<int>.filled(length, 7));

  group('capture', () {
    test('creates the row, uploads it, and records where it landed', () async {
      final remote = _FakeRemote();
      final container = makeContainer(remote: remote);

      final scanId = await container
          .read(rockScanCaptureProvider.notifier)
          .capture(wallId: 'wall-1', bytes: videoBytes(), durationMs: 45000);

      expect(remote.uploads, hasLength(1));
      expect(remote.uploads.single.uid, 'uid-1');
      expect(remote.uploads.single.scanId, scanId);
      expect(remote.uploads.single.byteCount, 2048);

      final scan = await (db.select(
        db.rockScans,
      )..where((t) => t.id.equals(scanId))).getSingle();
      expect(scan.uploadState, RockScanUpload.uploaded.name);
      expect(scan.videoObjectPath, 'uid-1/$scanId.mp4');
      expect(scan.sizeBytes, 2048);
      expect(scan.durationMs, 45000);
      expect(
        scan.status,
        RockScanStatus.pending.name,
        reason: 'uploading does not queue anything by itself — the worker '
            'derives the queue from uploadState, which is the column the '
            'client is allowed to own',
      );
      expect(
        container.read(rockScanCaptureProvider),
        isA<RockScanCaptureIdle>(),
      );
    });

    test('the row survives a failed upload, in a state that says so',
        () async {
      // The whole reason the row is created BEFORE the upload: a scan that
      // exists in a visible failed state can be retried and reasoned about,
      // where an upload attempted without one vanishes with nothing to show.
      final remote = _FakeRemote(failWith: StateError('connection reset'));
      final container = makeContainer(remote: remote);

      final scanId = await container
          .read(rockScanCaptureProvider.notifier)
          .capture(wallId: 'wall-1', bytes: videoBytes());

      final scan = await (db.select(
        db.rockScans,
      )..where((t) => t.id.equals(scanId))).getSingle();
      expect(scan.uploadState, RockScanUpload.failed.name);
      expect(scan.videoObjectPath, isNull);

      final state = container.read(rockScanCaptureProvider);
      expect(state, isA<RockScanCaptureFailed>());
      expect((state as RockScanCaptureFailed).scanId, scanId);
      expect(state.message, contains('connection'));
    });

    test('signed out: the row is kept on the device and nothing is sent',
        () async {
      // Not a failure. Recording at a crag before signing in is a normal
      // path, and marking it failed would imply the capture was bad.
      final remote = _FakeRemote();
      final container = makeContainer(remote: remote, uid: null);

      final scanId = await container
          .read(rockScanCaptureProvider.notifier)
          .capture(wallId: 'wall-1', bytes: videoBytes());

      expect(remote.uploads, isEmpty);
      final scan = await (db.select(
        db.rockScans,
      )..where((t) => t.id.equals(scanId))).getSingle();
      expect(scan.uploadState, RockScanUpload.pending.name);
      expect(
        container.read(rockScanCaptureProvider),
        isA<RockScanCaptureIdle>(),
      );
    });

    test('returns the scan id even when the upload failed', () async {
      // The caller navigates to the row that now exists, whatever happened.
      final container = makeContainer(
        remote: _FakeRemote(failWith: StateError('nope')),
      );
      final scanId = await container
          .read(rockScanCaptureProvider.notifier)
          .capture(wallId: 'wall-1', bytes: videoBytes());
      expect(scanId, isNotEmpty);
    });
  });

  group('retry', () {
    test('a second attempt can succeed and clears the error', () async {
      final failing = _FakeRemote(failWith: StateError('connection reset'));
      final container = makeContainer(remote: failing);
      final scanId = await container
          .read(rockScanCaptureProvider.notifier)
          .capture(wallId: 'wall-1', bytes: videoBytes());
      expect(container.read(rockScanCaptureProvider),
          isA<RockScanCaptureFailed>());

      // A fresh container standing in for a later attempt with a working
      // connection, over the SAME database row.
      final working = _FakeRemote();
      final retryContainer = makeContainer(remote: working);
      await retryContainer
          .read(rockScanCaptureProvider.notifier)
          .retry(scanId: scanId, bytes: videoBytes());

      final scan = await (db.select(
        db.rockScans,
      )..where((t) => t.id.equals(scanId))).getSingle();
      expect(scan.uploadState, RockScanUpload.uploaded.name);
      expect(working.uploads.single.scanId, scanId);
      expect(
        retryContainer.read(rockScanCaptureProvider),
        isA<RockScanCaptureIdle>(),
      );
    });

    test('dismissError clears a failure and leaves idle alone', () async {
      final container = makeContainer(
        remote: _FakeRemote(failWith: StateError('nope')),
      );
      await container
          .read(rockScanCaptureProvider.notifier)
          .capture(wallId: 'wall-1', bytes: videoBytes());

      container.read(rockScanCaptureProvider.notifier).dismissError();
      expect(
        container.read(rockScanCaptureProvider),
        isA<RockScanCaptureIdle>(),
      );
      container.read(rockScanCaptureProvider.notifier).dismissError();
      expect(
        container.read(rockScanCaptureProvider),
        isA<RockScanCaptureIdle>(),
      );
    });
  });

  group('describeScanUploadFailure', () {
    test('names the connection when that is what broke', () {
      for (final error in [
        'SocketException: failed host lookup',
        'Connection closed before full header',
        'NetworkException',
        'TimeoutException after 30s',
      ]) {
        expect(
          describeScanUploadFailure(StateError(error)),
          contains('connection'),
          reason: error,
        );
      }
    });

    test('names the file when the server rejected its size', () {
      expect(
        describeScanUploadFailure(StateError('413 payload too large')),
        contains('too large'),
      );
    });

    test('falls back to something a person can still act on', () {
      // No stack traces, no status codes: the fallback still tells the user
      // where their video is and what to do.
      final message = describeScanUploadFailure(StateError('weird'));
      expect(message, contains('still on your phone'));
      expect(message, isNot(contains('StateError')));
    });
  });
}
