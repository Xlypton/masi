// The cloud thumbnail tier's SAFETY property, and the side channel that makes
// it converge.
//
// The tier publishes a second, small object per shared photo so a 52-pixel list
// tile stops downloading a multi-megabyte original. Backfilling the objects
// published BEFORE it existed is the whole difficulty, and the first attempt got
// it wrong in a way that is worth pinning permanently: it redefined
// `listSharedPhotoObjectPaths` so an original counted as published only once its
// thumbnail existed too, and let the ordinary push do the migration.
//
// That coupling is a retry loop. `SyncService._uploadOwnPhotos` derives
// `needsShared` from exactly that set, and a photo with `needsShared` runs the
// ENTIRE publish pipeline again — including the fail-closed EXIF-strip gate,
// which landed on 2026-08-08, months after every one of the 21 objects in the
// live bucket was published. So the whole existing corpus met that gate for the
// first time, on bytes nothing had ever validated. A refusal there is not a
// skipped upload: it withholds the photo's row, drops `fullyLanded`, and re-arms
// the retry — forever, because a refused photo never gets a thumbnail and so
// never enters the skip-set that would end the loop.
//
// These tests pin the fix from both ends:
//
//  * PUBLISH STATE (the `SyncService` group) — an already-published original is
//    untouchable. Its thumbnail may be missing, its bytes may be unstrippable,
//    its bytes may be GONE, and none of it may reach `failedCanonicalIds`,
//    `missingLocalBytes` or `fullyLanded`. Each assertion has a negative control
//    in the same group: the identical fixture with the original NOT yet in the
//    cloud, which must still fail, or the assertions would be vacuous.
//  * CONVERGENCE (the `SharedThumbBackfill` group) — the legacy objects still do
//    get their thumbnail, through a channel that reports nothing to anyone and
//    never re-uploads an original.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/features/account/data/auth_repository.dart';
import 'package:masi/features/backup/data/backup_repository.dart';
import 'package:masi/features/backup/data/connectivity_service.dart';
import 'package:masi/features/backup/data/published_photo_metadata.dart';
import 'package:masi/features/backup/data/sync_remote.dart';
import 'package:masi/features/backup/data/sync_service.dart';
import 'package:masi/features/backup/domain/shared_topo_scope.dart';
import 'package:masi/features/topo/data/photo_files.dart';
import 'package:path/path.dart' as p;

import '../../../support/fixture_photo.dart';

const String _uid = 'user-u1';
final AuthSessionState _signedIn = AuthSessionState.signedIn(
  'u1@example.com',
  uid: _uid,
);

/// Bytes the publish-side strip gate REFUSES: no JPEG and no PNG magic, so
/// `strippedForPublishing` reports `unsupportedFormat` and `isSafeToPublish` is
/// false.
///
/// This is not a contrived fixture — it is the shape of the whole problem. The
/// gate landed after every object now in the bucket was published, so "bytes
/// this gate has never seen and might refuse" describes 100% of the legacy
/// corpus. Anything routing an already-published photo back through that gate
/// gets exactly this.
Uint8List _unstrippableBytes() => Uint8List.fromList(List<int>.filled(64, 7));

/// In-memory [SyncRemote] whose shared-bucket bookkeeping MIRRORS PRODUCTION
/// rather than approximating it.
///
/// [listSharedPhotoObjectPaths] is delegated to [publishedSharedOriginals] — the
/// same pure function `SupabaseSyncRemote` uses — so these tests cannot pass
/// against a fake that is merely kinder than the real thing. That mattered here:
/// the defect being fixed lived entirely in what that method reported.
class _FakeRemote implements SyncRemote {
  /// object path -> bytes, for both `shared/<id><ext>` and
  /// `shared/thumbs/<id>.jpg`.
  final Map<String, List<int>> shared = {};

  /// object path -> bytes, under `<uid>/`.
  final Map<String, List<int>> private = {};

  final List<String> uploadedSharedOriginals = [];
  final List<String> uploadedSharedThumbs = [];
  final List<String> uploadedPrivate = [];
  final List<String> removedShared = [];

  /// Table -> ids that reached the remote, so a test can prove a row was
  /// PUSHED rather than only that the push reported success.
  final Map<String, List<String>> upsertedIds = {};

  /// When set, [uploadSharedPhoto] throws — the transient-blip shape.
  bool failSharedUpload = false;

  @override
  Future<List<TablePushOutcome>> upsertOwnRows(
    String uid,
    Map<String, List<Map<String, dynamic>>> tablesToRows,
  ) async {
    final outcomes = <TablePushOutcome>[];
    for (final table in syncTableNames) {
      final rows = tablesToRows[table];
      if (rows == null || rows.isEmpty) continue;
      (upsertedIds[table] ??= []).addAll([
        for (final row in rows) row['id'] as String,
      ]);
      outcomes.add(
        TablePushOutcome.ok(table: table, rowsUpserted: rows.length),
      );
    }
    return outcomes;
  }

  @override
  Future<void> uploadPhoto({
    required String uid,
    required String photoId,
    required String ext,
    required List<int> bytes,
  }) async {
    final path = '$uid/$photoId$ext';
    private[path] = bytes;
    uploadedPrivate.add(path);
  }

  @override
  Future<Set<String>> listPhotoObjectPaths(String uid) async =>
      private.keys.where((path) => path.startsWith('$uid/')).toSet();

  @override
  Future<void> uploadSharedPhoto({
    required String photoId,
    required String ext,
    required List<int> bytes,
  }) async {
    if (failSharedUpload) {
      throw Exception('uploadSharedPhoto failed: simulated storage error');
    }
    // Mirrors `SupabaseSyncRemote`: the original is the publication and its
    // failure propagates; the thumbnail follows and is best-effort.
    final originalPath = sharedPhotoPath(photoId, ext);
    shared[originalPath] = bytes;
    uploadedSharedOriginals.add(originalPath);
    shared[sharedThumbPath(photoId)] = List<int>.filled(8, 1);
    uploadedSharedThumbs.add(sharedThumbPath(photoId));
  }

  @override
  Future<Set<String>> listSharedPhotoObjectPaths() async =>
      publishedSharedOriginals([
        for (final path in shared.keys)
          if (p.dirname(path) == 'shared') p.basename(path),
      ]);

  @override
  Future<void> removeSharedPhoto({
    required String photoId,
    required String ext,
  }) async {
    removedShared.addAll([sharedPhotoPath(photoId, ext), sharedThumbPath(photoId)]);
    shared.remove(sharedPhotoPath(photoId, ext));
    shared.remove(sharedThumbPath(photoId));
  }

  @override
  Future<void> removePhoto({
    required String uid,
    required String photoId,
    required String ext,
  }) async {
    private.remove('$uid/$photoId$ext');
  }

  @override
  Future<List<int>?> downloadPhoto({
    required String uid,
    required String objectPath,
  }) async => private[objectPath];

  @override
  Future<List<int>?> downloadSharedPhoto(String objectPath) async =>
      shared[objectPath];

  @override
  Future<Map<String, List<Map<String, dynamic>>>> fetchOwnRows(String uid) async => {
    for (final table in syncTableNames) table: <Map<String, dynamic>>[],
  };

  @override
  Future<Map<String, List<Map<String, dynamic>>>> fetchSharedTopos({
    SharedTopoScope scope = const SharedTopoScope.unbounded(),
  }) async => {};

  @override
  Future<Map<String, List<Map<String, dynamic>>>> fetchSharedAscents() async => {};

  @override
  Future<List<Map<String, dynamic>>> fetchProfiles(Set<String> uids) async =>
      const [];

  @override
  Future<List<String>> fetchVisibleWallIds(List<String> ids) async =>
      const [];
}

/// [_FakeRemote] with the PRE-FIX listing semantics: an original counts as
/// published only once its thumbnail exists too.
///
/// This is the defect, kept executable. Without it the assertions above could
/// all pass for the wrong reason — a fake that never reported anything as
/// unpublished would make them vacuous — and a future change that re-couples
/// the two would look green. Here it looks like what it is: a photo that is
/// already in the cloud, reported as failed, on every push, forever.
class _ThumbCoupledRemote extends _FakeRemote {
  @override
  Future<Set<String>> listSharedPhotoObjectPaths() async {
    final thumbNames = {
      for (final path in shared.keys)
        if (p.dirname(path) == 'shared/thumbs') p.basename(path),
    };
    return {
      for (final path in shared.keys)
        if (p.dirname(path) == 'shared' &&
            thumbNames.contains(
              '${p.basenameWithoutExtension(path)}$kSharedThumbExt',
            ))
          path,
    };
  }
}

class _FakeAuth implements AuthRepository {
  @override
  AuthSessionState currentSession = _signedIn;

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

class _FakeConnectivity implements ConnectivityService {
  @override
  Future<NetworkStatus> currentStatus() async => NetworkStatus.wifi;

  @override
  Future<bool> isBackendReachable() async => true;

  @override
  Stream<NetworkStatus> statusChanges() => const Stream<NetworkStatus>.empty();
}

void main() {
  group('publish state is independent of the thumbnail (SyncService)', () {
    late Directory tmp;
    late AppDatabase db;
    late _FakeRemote remote;
    late SyncService service;

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('shared_thumb_publish_');
      db = AppDatabase(NativeDatabase.memory());
      remote = _FakeRemote();
      service = SyncService(
        db: db,
        backupRepository: BackupRepository(db),
        remote: remote,
        authRepository: _FakeAuth(),
        connectivity: _FakeConnectivity(),
        photoFiles: PhotoFiles(docsDir: () async => tmp),
      );
    });

    tearDown(() async {
      await db.close();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    /// One shared Area -> Sector -> Wall -> Photo owned by [_uid], whose photo
    /// is stored at the canonical relative key `photos/<id>.jpg`.
    Future<void> seedSharedWall({String photoId = 'photo-1'}) async {
      await db.into(db.areas).insert(
        AreasCompanion.insert(
          id: 'area-1',
          createdAt: 100,
          updatedAt: 100,
          ownerId: const Value(_uid),
          name: 'Area',
        ),
      );
      await db.into(db.sectors).insert(
        SectorsCompanion.insert(
          id: 'sector-1',
          createdAt: 100,
          updatedAt: 100,
          ownerId: const Value(_uid),
          areaId: 'area-1',
          name: 'Sector',
          sortOrder: 0,
        ),
      );
      await db.into(db.walls).insert(
        WallsCompanion.insert(
          id: 'wall-1',
          createdAt: 100,
          updatedAt: 100,
          ownerId: const Value(_uid),
          sectorId: 'sector-1',
          name: 'Wall',
          sortOrder: 0,
          visibility: const Value('shared'),
        ),
      );
      await db.into(db.photos).insert(
        PhotosCompanion.insert(
          id: photoId,
          createdAt: 100,
          updatedAt: 100,
          ownerId: const Value(_uid),
          wallId: 'wall-1',
          localPath: 'photos/$photoId.jpg',
          kind: 'original',
          width: 800,
          height: 600,
        ),
      );
    }

    /// Writes [bytes] at the local key `photos/<photoId>.jpg`.
    void seedLocalBytes(String photoId, List<int> bytes) {
      final file = File(p.join(tmp.path, 'photos', '$photoId.jpg'));
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(bytes);
    }

    /// Puts the photo's ORIGINAL in the cloud with NO `shared/thumbs/`
    /// companion — a publish that predates the thumbnail tier, which is the
    /// state all 21 live objects were in.
    void seedLegacyPublish(String photoId) {
      remote.shared[sharedPhotoPath(photoId, '.jpg')] = fixtureJpegBytes();
      remote.private['$_uid/$photoId.jpg'] = fixtureJpegBytes();
    }

    test(
      'the fixture really is refused by the strip gate — without this the '
      'assertions below prove nothing',
      () {
        expect(
          strippedForPublishing(_unstrippableBytes()).isSafeToPublish,
          isFalse,
        );
        expect(
          strippedForPublishing(_unstrippableBytes()).outcome,
          PhotoStripOutcome.unsupportedFormat,
        );
      },
    );

    test(
      'ASSERTION 1 — an already-published photo whose bytes the strip gate '
      'REFUSES is not failed, not withheld and does not clear fullyLanded, '
      'merely because its thumbnail is missing',
      () async {
        await seedSharedWall();
        seedLocalBytes('photo-1', _unstrippableBytes());
        seedLegacyPublish('photo-1');

        final result = await service.pushOwn();

        expect(
          result.photosFailed,
          0,
          reason:
              'THE RETRY LOOP: reporting a thumbnail-less original as '
              'unpublished routes it back through the fail-closed strip gate, '
              'and a refusal there fails a photo that is already in the cloud',
        );
        expect(result.photoErrors, isEmpty);
        expect(
          result.fullyLanded,
          isTrue,
          reason:
              'fullyLanded is what SyncOrchestrator retries on — false here is '
              'the loop that never terminates',
        );
        expect(
          remote.upsertedIds['photos'],
          contains('photo-1'),
          reason: 'the row must not be withheld (S5 applies to bytes that are '
              'NOT in the cloud; these are)',
        );
        expect(
          remote.uploadedSharedOriginals,
          isEmpty,
          reason: 'nothing about a missing thumbnail justifies re-uploading a '
              'multi-megabyte original',
        );
      },
    );

    test(
      'NEGATIVE CONTROL for assertion 1 — the identical fixture with the '
      'original NOT yet in the cloud DOES fail, so the assertion above is not '
      'vacuous',
      () async {
        await seedSharedWall();
        seedLocalBytes('photo-1', _unstrippableBytes());
        // Deliberately no seedLegacyPublish: a genuinely unpublished photo.

        final result = await service.pushOwn();

        expect(
          result.photosFailed,
          1,
          reason: 'a first publish must still fail closed on unstrippable bytes',
        );
        expect(result.fullyLanded, isFalse);
        expect(
          remote.upsertedIds['photos'] ?? const <String>[],
          isNot(contains('photo-1')),
          reason: 'and its row must still be withheld',
        );
      },
    );

    test(
      'ASSERTION 1 — an already-published photo whose LOCAL BYTES ARE GONE is '
      'not counted as missing-local-bytes either: no permanent user-facing '
      'warning for a photo that is safely in the cloud',
      () async {
        await seedSharedWall();
        // No local file at all — evicted, or a row that predates the L3 fix.
        seedLegacyPublish('photo-1');

        final result = await service.pushOwn();

        expect(
          result.photosMissingLocalBytes,
          0,
          reason:
              'SyncOrchestrator turns this into lastPushWarning on the Account '
              'screen; a cloud-resident photo must not raise it',
        );
        expect(result.photosFailed, 0);
        expect(result.photoErrors, isEmpty);
        expect(result.fullyLanded, isTrue);
      },
    );

    test(
      'NEGATIVE CONTROL — a photo with no local bytes AND no cloud copy is '
      'still reported as missing-local-bytes',
      () async {
        await seedSharedWall();

        final result = await service.pushOwn();

        expect(result.photosMissingLocalBytes, 1);
        expect(result.photoErrors, hasLength(1));
      },
    );

    test(
      'ASSERTION 2 — the push is IDEMPOTENT across repeats: a legacy publish '
      'never accumulates failures and never re-uploads, so the loop has a '
      'fixed point',
      () async {
        await seedSharedWall();
        seedLocalBytes('photo-1', _unstrippableBytes());
        seedLegacyPublish('photo-1');

        for (var attempt = 1; attempt <= 3; attempt++) {
          final result = await service.pushOwn();
          expect(result.photosFailed, 0, reason: 'attempt $attempt');
          expect(result.fullyLanded, isTrue, reason: 'attempt $attempt');
        }
        expect(remote.uploadedSharedOriginals, isEmpty);
        expect(
          remote.shared.containsKey(sharedThumbPath('photo-1')),
          isFalse,
          reason:
              'and the push has NOT quietly produced the thumbnail either — '
              'that is the side channel\'s job, not the publish pipeline\'s',
        );
      },
    );

    test(
      'WITNESS — with the PRE-FIX coupling restored, the very same fixture '
      'produces the retry loop this repair exists to remove',
      () async {
        // Everything identical to the assertion-1 test except the remote's
        // definition of "already published". If this ever goes green, the
        // assertion above has stopped testing anything.
        final coupled = _ThumbCoupledRemote();
        final coupledService = SyncService(
          db: db,
          backupRepository: BackupRepository(db),
          remote: coupled,
          authRepository: _FakeAuth(),
          connectivity: _FakeConnectivity(),
          photoFiles: PhotoFiles(docsDir: () async => tmp),
        );
        await seedSharedWall();
        seedLocalBytes('photo-1', _unstrippableBytes());
        coupled.shared[sharedPhotoPath('photo-1', '.jpg')] = fixtureJpegBytes();
        coupled.private['$_uid/photo-1.jpg'] = fixtureJpegBytes();

        for (var attempt = 1; attempt <= 2; attempt++) {
          final result = await coupledService.pushOwn();
          expect(
            result.photosFailed,
            1,
            reason:
                'attempt $attempt: an already-published photo is failed by the '
                'strip gate it has never met before',
          );
          expect(result.fullyLanded, isFalse, reason: 'attempt $attempt');
          expect(
            coupled.upsertedIds['photos'] ?? const <String>[],
            isNot(contains('photo-1')),
            reason: 'attempt $attempt: and its row is withheld',
          );
        }
        expect(
          coupled.shared.containsKey(sharedThumbPath('photo-1')),
          isFalse,
          reason:
              'AND IT CANNOT HEAL: no thumbnail is ever produced for a photo '
              'that was refused, so it never enters the skip-set and the loop '
              'has no fixed point',
        );
      },
    );

    test(
      'a photo that is genuinely NOT published still publishes normally, with '
      'both objects — the tier is not disabled by any of this',
      () async {
        await seedSharedWall();
        seedLocalBytes('photo-1', fixtureJpegBytes());

        final result = await service.pushOwn();

        expect(result.photosUploaded, 1);
        expect(result.photosFailed, 0);
        expect(result.fullyLanded, isTrue);
        expect(remote.uploadedSharedOriginals, [sharedPhotoPath('photo-1', '.jpg')]);
        expect(remote.uploadedSharedThumbs, [sharedThumbPath('photo-1')]);
      },
    );

    test(
      'a TRANSIENT shared-upload failure on a genuinely unpublished photo is '
      'still a retryable failure that heals — the decoupling did not weaken '
      'bytes-before-metadata (S5)',
      () async {
        await seedSharedWall();
        seedLocalBytes('photo-1', fixtureJpegBytes());
        remote.failSharedUpload = true;

        final first = await service.pushOwn();
        expect(first.photosFailed, 1);
        expect(first.fullyLanded, isFalse);
        expect(
          remote.upsertedIds['photos'] ?? const <String>[],
          isNot(contains('photo-1')),
        );

        remote.failSharedUpload = false;
        final second = await service.pushOwn();
        expect(second.photosFailed, 0);
        expect(second.fullyLanded, isTrue);
        expect(remote.upsertedIds['photos'], contains('photo-1'));
      },
    );

    test(
      'ASSERTION 4 — a takedown removes BOTH objects, so no world-readable '
      'thumbnail orphan survives its original',
      () async {
        await seedSharedWall();
        seedLegacyPublish('photo-1');
        remote.shared[sharedThumbPath('photo-1')] = List<int>.filled(8, 1);
        await (db.update(db.photos)..where((t) => t.id.equals('photo-1'))).write(
          const PhotosCompanion(deletedAt: Value(300), updatedAt: Value(300)),
        );

        await service.pushOwn();

        expect(remote.removedShared, [
          sharedPhotoPath('photo-1', '.jpg'),
          sharedThumbPath('photo-1'),
        ]);
        expect(remote.shared, isEmpty);
      },
    );

    test(
      'ASSERTION 7 — the private <uid>/ copy is byte-identical to the local '
      'file: decision D-5 is untouched by the tier',
      () async {
        await seedSharedWall();
        final original = fixtureJpegBytes(3);
        seedLocalBytes('photo-1', original);

        await service.pushOwn();

        expect(remote.private['$_uid/photo-1.jpg'], original);
        expect(
          remote.shared[sharedPhotoPath('photo-1', '.jpg')],
          original,
          reason:
              'the fixture is metadata-free, so the published original is the '
              'same bytes at the same full resolution — the thumbnail is an '
              'ADDITIONAL object, never a replacement',
        );
      },
    );
  });

  group('SharedThumbBackfill (the side channel)', () {
    /// A backfill wired to an in-memory bucket. [thumbnail] defaults to a
    /// deterministic 8-byte stand-in — driving a real image codec here would
    /// test `generateThumbnail`, which has its own tests, and would be the one
    /// thing in this file that could hang.
    ({
      SharedThumbBackfill backfill,
      Map<String, List<int>> bucket,
      List<String> downloads,
      List<String> uploads,
    })
    makeBackfill({
      int maxPerPass = 3,
      Future<Uint8List> Function(Uint8List)? thumbnail,
      Future<List<int>?> Function(String)? download,
      Future<void> Function(String, Uint8List)? upload,
    }) {
      final bucket = <String, List<int>>{};
      final downloads = <String>[];
      final uploads = <String>[];
      final backfill = SharedThumbBackfill(
        maxPerPass: maxPerPass,
        download:
            download ??
            (objectPath) async {
              downloads.add(objectPath);
              return bucket[objectPath];
            },
        upload:
            upload ??
            (objectPath, bytes) async {
              uploads.add(objectPath);
              bucket[objectPath] = bytes;
            },
        thumbnail:
            thumbnail ?? (original) async => Uint8List.fromList([1, 2, 3, 4]),
      );
      return (
        backfill: backfill,
        bucket: bucket,
        downloads: downloads,
        uploads: uploads,
      );
    }

    test(
      'ASSERTION 3 — a legacy original gets its thumbnail WITHOUT its '
      'multi-megabyte original being re-uploaded',
      () async {
        final h = makeBackfill();
        h.bucket['shared/legacy.jpeg'] = List<int>.filled(4096, 9);

        h.backfill.schedule(const ['legacy.jpeg']);
        await h.backfill.pending;

        expect(h.downloads, ['shared/legacy.jpeg']);
        expect(
          h.uploads,
          ['shared/thumbs/legacy.jpg'],
          reason:
              'exactly one upload, and it is the ~30KB derivative — the 94MB '
              'of legacy originals must never go back over the wire',
        );
        expect(h.bucket['shared/thumbs/legacy.jpg'], [1, 2, 3, 4]);
        expect(
          h.bucket['shared/legacy.jpeg'],
          hasLength(4096),
          reason: 'the original is untouched',
        );
      },
    );

    test(
      'ASSERTION 3 — the tier CONVERGES: successive passes walk the shrinking '
      'worklist until nothing is left to do, and then cost nothing',
      () async {
        final h = makeBackfill(maxPerPass: 2);
        final originals = ['a.jpg', 'b.jpeg', 'c.png', 'd.JPG', 'e.jpg'];
        for (final name in originals) {
          h.bucket['shared/$name'] = List<int>.filled(64, 1);
        }

        var passes = 0;
        while (true) {
          final worklist = sharedOriginalsNeedingThumbs(
            originalNames: originals,
            thumbNames: {
              for (final path in h.bucket.keys)
                if (p.dirname(path) == 'shared/thumbs') p.basename(path),
            },
          );
          if (worklist.isEmpty) break;
          expect(++passes, lessThan(10), reason: 'must terminate');
          h.backfill.schedule(worklist);
          await h.backfill.pending;
        }

        expect(passes, 3, reason: '5 originals at 2 per pass');
        for (final name in originals) {
          expect(
            h.bucket['shared/thumbs/${p.basenameWithoutExtension(name)}.jpg'],
            isNotNull,
            reason: '$name never got its thumbnail',
          );
        }

        // Converged: a further listing worklists nothing, so a further pass
        // downloads nothing.
        final downloadsAfter = h.downloads.length;
        h.backfill.schedule(
          sharedOriginalsNeedingThumbs(
            originalNames: originals,
            thumbNames: {
              for (final path in h.bucket.keys)
                if (p.dirname(path) == 'shared/thumbs') p.basename(path),
            },
          ),
        );
        await h.backfill.pending;
        expect(h.downloads, hasLength(downloadsAfter));
      },
    );

    test('one pass at a time: scheduling while a pass runs is a no-op', () async {
      final gate = Completer<void>();
      final h = makeBackfill(
        download: (objectPath) async {
          await gate.future;
          return List<int>.filled(16, 1);
        },
      );

      h.backfill.schedule(const ['a.jpg']);
      h.backfill.schedule(const ['b.jpg', 'c.jpg']);
      gate.complete();
      await h.backfill.pending;

      expect(
        h.uploads,
        ['shared/thumbs/a.jpg'],
        reason: 'a push every 30 seconds must not stack overlapping passes',
      );
    });

    test(
      'ASSERTION 1/2 — the backfill reports NOTHING: a download failure, an '
      'upload failure and an undecodable photo all leave it silent and '
      'non-throwing',
      () async {
        final h = makeBackfill(
          download: (objectPath) async {
            if (objectPath.endsWith('boom.jpg')) throw StateError('offline');
            return List<int>.filled(16, 1);
          },
          upload: (objectPath, bytes) async => throw StateError('storage down'),
        );

        h.backfill.schedule(const ['boom.jpg', 'other.jpg']);
        // The property is that awaiting the pass completes normally. A throw
        // anywhere inside would surface here (and, in production, as an
        // unhandled async error from a fire-and-forget future).
        await h.backfill.pending;

        expect(h.backfill.givenUp, isEmpty);
      },
    );

    test(
      'a photo whose thumbnail cannot be DERIVED is given up on for the '
      'session — never retried every pass, and never published as a fake '
      'thumbnail',
      () async {
        final h = makeBackfill(
          thumbnail: (original) async => throw StateError('undecodable'),
        );
        h.bucket['shared/broken.jpg'] = List<int>.filled(4096, 9);

        h.backfill.schedule(const ['broken.jpg']);
        await h.backfill.pending;

        expect(h.uploads, isEmpty, reason: 'no thumbnail is better than a '
            'multi-megabyte object at the path every tile fetches');
        expect(h.backfill.givenUp, {'broken.jpg'});

        h.backfill.schedule(const ['broken.jpg']);
        await h.backfill.pending;
        expect(
          h.downloads,
          hasLength(1),
          reason: 'retrying it costs a full download per pass and cannot start '
              'succeeding',
        );
      },
    );

    test(
      'a TRANSIENT failure is NOT given up on: the next pass retries it, which '
      'is what makes the no-outbox design (D-4) self-healing here too',
      () async {
        var attempts = 0;
        final bucket = <String, List<int>>{'shared/a.jpg': List<int>.filled(16, 1)};
        final uploads = <String>[];
        final backfill = SharedThumbBackfill(
          download: (objectPath) async {
            if (++attempts == 1) throw StateError('offline');
            return bucket[objectPath];
          },
          upload: (objectPath, bytes) async => uploads.add(objectPath),
          thumbnail: (original) async => Uint8List.fromList([1]),
        );

        backfill.schedule(const ['a.jpg']);
        await backfill.pending;
        expect(uploads, isEmpty);
        expect(backfill.givenUp, isEmpty);

        backfill.schedule(const ['a.jpg']);
        await backfill.pending;
        expect(uploads, ['shared/thumbs/a.jpg']);
      },
    );

    test(
      'a STALLED download cannot latch the single-pass gate for the session',
      () async {
        final wedge = Completer<void>();
        final uploads = <String>[];
        var downloads = 0;
        final backfill = SharedThumbBackfill(
          // Real time, scaled down from the production 45s: the property is
          // that the latch is released at all, not how long that takes.
          perStepTimeout: const Duration(milliseconds: 50),
          download: (objectPath) async {
            downloads++;
            await wedge.future;
            return List<int>.filled(16, 1);
          },
          upload: (objectPath, bytes) async => uploads.add(objectPath),
          thumbnail: (original) async => Uint8List.fromList([1]),
        );

        backfill.schedule(const ['stuck.jpg']);
        await pumpEventQueue();
        expect(downloads, 1);

        // Still latched while the stuck step is inside its budget.
        backfill.schedule(const ['other.jpg']);
        await pumpEventQueue();
        expect(downloads, 1);

        await backfill.pending;

        backfill.schedule(const ['other.jpg']);
        await backfill.pending;
        expect(
          downloads,
          2,
          reason: 'a dead socket must not stop every later push from ever '
              'backfilling again',
        );

        wedge.complete();
      },
    );
  });
}
