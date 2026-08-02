// Service-level test for quota-triggered pruning of cached PUBLIC photo
// bytes. Where `public_photo_pruner_test.dart` proves the pure *policy*, this
// proves the *machinery* around it: when pruning triggers, what it reads out
// of drift, how deep one pass goes, and — the property that outranks every
// other assertion in this file — that the signed-in user's own photo bytes are
// never deleted, under any pressure, ownership shape, or malformed row.
//
// The asymmetry is the whole point: a wrongly-kept public photo costs a
// re-download; a wrongly-deleted own photo destroys work that exists nowhere
// else. Every ambiguous input below must resolve to "keep".
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/storage/storage_persistence_service.dart';
import 'package:masi/core/storage/storage_persistence_types.dart';
import 'package:masi/features/topo/data/photo_files.dart';
import 'package:masi/features/topo/data/public_photo_prune_service.dart';

/// Fake [PhotoFiles] that records every byte-delete it is asked to perform.
///
/// `implements PhotoFiles` on purpose: [PhotoFiles] is a CONCRETE,
/// conditionally-exported class (native under `flutter test`), not an
/// interface, so every public member has to be stubbed here. Extracting an
/// abstract interface instead would take ownership of four platform files for
/// the sake of one test double — not worth it.
class _RecordingPhotoFiles implements PhotoFiles {
  /// Every key `deletePhotoBytes` was called with, in call order.
  final List<String> deleted = <String>[];

  /// Keys whose delete should throw, simulating a backend that is not as
  /// best-effort as the two real ones.
  final Set<String> throwOn = <String>{};

  @override
  Future<void> deletePhotoBytes(String stored) async {
    deleted.add(stored);
    if (throwOn.contains(stored)) {
      throw StateError('byte store refused to delete $stored');
    }
  }

  // ---- Everything below is unreachable from the prune path. ----

  @override
  Future<String> importPhoto(XFile xfile, String photoId) =>
      throw UnimplementedError('the pruner never imports');

  @override
  Future<String> writePhotoBytes(String photoId, String ext, List<int> bytes) =>
      throw UnimplementedError('the pruner never writes');

  @override
  Future<Uint8List?> readPhotoBytes(String stored) =>
      throw UnimplementedError('the pruner never reads pixels');

  @override
  Future<PhotoPathResolution> resolvePhotoPath(String stored) =>
      throw UnimplementedError('the pruner deletes by stored key');

  @override
  PhotoPathResolution resolvePhotoPathSync(String stored) =>
      throw UnimplementedError('the pruner deletes by stored key');

  @override
  Future<String> canonicalStoredPath(String maybePath) async => maybePath;

  @override
  Future<void> warmDocsPath() async {}
}

/// [StoragePersistenceService] whose `estimate()` answers are scripted, one
/// per call, with the final entry repeating forever. Counts calls so a test
/// can prove the sweep re-measures between batches rather than deleting blind.
class _ScriptedStorage implements StoragePersistenceService {
  _ScriptedStorage(this._fractions);

  /// Successive `usedFraction` answers; `null` means "the browser did not
  /// report an estimate".
  final List<double?> _fractions;

  int estimateCalls = 0;

  @override
  Future<StorageEstimateSnapshot?> estimate() async {
    final index = estimateCalls < _fractions.length
        ? estimateCalls
        : _fractions.length - 1;
    estimateCalls++;
    final fraction = _fractions[index];
    if (fraction == null) return null;
    // Exact in binary64 for every fraction used below: n/1000000 with an
    // integral numerator round-trips to the same double as the literal.
    return StorageEstimateSnapshot(
      usageBytes: (fraction * 1000000).round(),
      quotaBytes: 1000000,
    );
  }

  @override
  Future<StoragePersistOutcome> requestPersist() async =>
      StoragePersistOutcome.notApplicable;

  @override
  Future<bool> isPersisted() async => false;
}

/// A storage service that reports usage/quota the browser could not turn into
/// a fraction (quota omitted) — distinct from `estimate()` returning `null`.
class _UnusableEstimateStorage implements StoragePersistenceService {
  @override
  Future<StorageEstimateSnapshot?> estimate() async =>
      const StorageEstimateSnapshot(usageBytes: 900000);

  @override
  Future<StoragePersistOutcome> requestPersist() async =>
      StoragePersistOutcome.notApplicable;

  @override
  Future<bool> isPersisted() async => false;
}

void main() {
  late AppDatabase db;
  late _RecordingPhotoFiles photoFiles;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    photoFiles = _RecordingPhotoFiles();
    await db
        .into(db.areas)
        .insert(
          AreasCompanion.insert(
            id: 'area-1',
            createdAt: 0,
            updatedAt: 0,
            name: 'Area',
          ),
        );
    await db
        .into(db.sectors)
        .insert(
          SectorsCompanion.insert(
            id: 'sector-1',
            createdAt: 0,
            updatedAt: 0,
            areaId: 'area-1',
            name: 'Sector',
            sortOrder: 0,
          ),
        );
  });

  tearDown(() async {
    await db.close();
  });

  /// Inserts a wall owned by [ownerId] (`null` = unowned/pre-claim) whose
  /// `updatedAt` is [updatedAt] ms, plus one photo row per entry in [keys].
  Future<void> seedWall({
    required String id,
    required String? ownerId,
    required int updatedAt,
    required List<String> keys,
  }) async {
    await db
        .into(db.walls)
        .insert(
          WallsCompanion.insert(
            id: id,
            createdAt: updatedAt,
            updatedAt: updatedAt,
            sectorId: 'sector-1',
            name: id,
            sortOrder: 0,
            ownerId: Value(ownerId),
          ),
        );
    for (var i = 0; i < keys.length; i++) {
      await db
          .into(db.photos)
          .insert(
            PhotosCompanion.insert(
              id: '$id-photo-$i',
              createdAt: updatedAt,
              updatedAt: updatedAt,
              wallId: id,
              localPath: keys[i],
              kind: 'original',
              width: 100,
              height: 100,
            ),
          );
    }
  }

  PublicPhotoPruneService makeService({
    required StoragePersistenceService storage,
    String? ownUid = 'me',
    int keepNewestForeign = 0,
    int batchSize = 10,
    int maxDeletionsPerPass = 1000,
  }) {
    return PublicPhotoPruneService(
      db: db,
      photoFiles: photoFiles,
      storage: storage,
      currentUid: () => ownUid,
      keepNewestForeign: keepNewestForeign,
      batchSize: batchSize,
      maxDeletionsPerPass: maxDeletionsPerPass,
    );
  }

  group('trigger policy — pruning is the exception, not the routine', () {
    test('an estimate the browser will not give us prunes NOTHING', () async {
      await seedWall(
        id: 'w-foreign',
        ownerId: 'them',
        updatedAt: 1,
        keys: ['photos/a.jpg'],
      );

      final outcome = await makeService(
        storage: _ScriptedStorage(const [null]),
      ).pruneIfUnderPressure();

      expect(photoFiles.deleted, isEmpty);
      expect(outcome.deletedKeys, isEmpty);
      expect(outcome.reason, PublicPhotoPruneReason.noEstimate);
    });

    test(
      'usage without a quota is not a pressure signal — prunes NOTHING '
      'rather than guessing',
      () async {
        await seedWall(
          id: 'w-foreign',
          ownerId: 'them',
          updatedAt: 1,
          keys: ['photos/a.jpg'],
        );

        final outcome = await makeService(
          storage: _UnusableEstimateStorage(),
        ).pruneIfUnderPressure();

        expect(photoFiles.deleted, isEmpty);
        expect(outcome.reason, PublicPhotoPruneReason.noEstimate);
      },
    );

    test('comfortably below the high watermark prunes NOTHING', () async {
      await seedWall(
        id: 'w-foreign',
        ownerId: 'them',
        updatedAt: 1,
        keys: ['photos/a.jpg'],
      );

      final storage = _ScriptedStorage(const [0.5]);
      final outcome = await makeService(
        storage: storage,
      ).pruneIfUnderPressure();

      expect(photoFiles.deleted, isEmpty);
      expect(outcome.reason, PublicPhotoPruneReason.belowHighWatermark);
      // One read, and no sweep behind it.
      expect(storage.estimateCalls, 1);
    });

    test(
      'exactly AT the high watermark still prunes nothing — the trigger is a '
      'strict crossing, so a steady state parked on the line does not churn '
      'IndexedDB on every pull',
      () async {
        await seedWall(
          id: 'w-foreign',
          ownerId: 'them',
          updatedAt: 1,
          keys: ['photos/a.jpg'],
        );

        final outcome = await makeService(
          storage: _ScriptedStorage(const [kPrunePressureHighWatermark]),
        ).pruneIfUnderPressure();

        expect(photoFiles.deleted, isEmpty);
        expect(outcome.reason, PublicPhotoPruneReason.belowHighWatermark);
      },
    );
  });

  group('OWN PHOTOS ARE NEVER DELETED — the one unacceptable outcome', () {
    test(
      'no known session: at 99% full, with a library that is entirely '
      'foreign-looking, NOTHING is deleted — ownership cannot be established '
      'without a uid, and a device between sessions must not guess',
      () async {
        await seedWall(
          id: 'w-1',
          ownerId: 'them',
          updatedAt: 1,
          keys: ['photos/a.jpg'],
        );
        await seedWall(
          id: 'w-2',
          ownerId: 'other',
          updatedAt: 2,
          keys: ['photos/b.jpg'],
        );

        final outcome = await makeService(
          storage: _ScriptedStorage(const [0.99]),
          ownUid: null,
        ).pruneIfUnderPressure();

        expect(photoFiles.deleted, isEmpty);
        expect(outcome.reason, PublicPhotoPruneReason.unknownSession);
      },
    );

    test('a 100% own library at 99% full loses nothing', () async {
      await seedWall(
        id: 'w-1',
        ownerId: 'me',
        updatedAt: 1,
        keys: ['photos/own-a.jpg', 'photos/own-b.jpg'],
      );
      await seedWall(
        id: 'w-2',
        ownerId: 'me',
        updatedAt: 2,
        keys: ['photos/own-c.jpg'],
      );

      final outcome = await makeService(
        storage: _ScriptedStorage(const [0.99]),
      ).pruneIfUnderPressure();

      expect(photoFiles.deleted, isEmpty);
      expect(outcome.reason, PublicPhotoPruneReason.nothingPrunable);
    });

    test(
      'an unowned (pre-claimOwnership) library at 99% full loses nothing — '
      'a null ownerId means "not yet known", never "a stranger\'s"',
      () async {
        await seedWall(
          id: 'w-1',
          ownerId: null,
          updatedAt: 1,
          keys: ['photos/unowned-a.jpg'],
        );

        final outcome = await makeService(
          storage: _ScriptedStorage(const [0.99]),
        ).pruneIfUnderPressure();

        expect(photoFiles.deleted, isEmpty);
        expect(outcome.reason, PublicPhotoPruneReason.nothingPrunable);
      },
    );

    test(
      'mixed ownership at maximum pressure deletes ONLY the foreign keys — '
      'own and unowned survive intact',
      () async {
        await seedWall(
          id: 'w-own',
          ownerId: 'me',
          updatedAt: 1,
          keys: ['photos/own.jpg'],
        );
        await seedWall(
          id: 'w-unowned',
          ownerId: null,
          updatedAt: 2,
          keys: ['photos/unowned.jpg'],
        );
        await seedWall(
          id: 'w-foreign',
          ownerId: 'them',
          updatedAt: 3,
          keys: ['photos/foreign.jpg'],
        );

        await makeService(
          storage: _ScriptedStorage(const [0.99]),
        ).pruneIfUnderPressure();

        expect(photoFiles.deleted, ['photos/foreign.jpg']);
        expect(photoFiles.deleted, isNot(contains('photos/own.jpg')));
        expect(photoFiles.deleted, isNot(contains('photos/unowned.jpg')));
      },
    );

    test(
      'a photo whose wall row is MISSING ENTIRELY is never deleted — the join '
      'cannot establish ownership, so the row is kept',
      () async {
        await seedWall(
          id: 'w-orphan',
          ownerId: 'them',
          updatedAt: 1,
          keys: ['photos/orphan.jpg'],
        );
        await seedWall(
          id: 'w-foreign',
          ownerId: 'them',
          updatedAt: 2,
          keys: ['photos/foreign.jpg'],
        );
        // Rip the wall row out from under the photo, the way a partial sync
        // or a hand-edited database can. FKs are ON (app_database.dart:232),
        // so this needs an explicit pragma toggle.
        await db.customStatement('PRAGMA foreign_keys = OFF');
        await db.customStatement("DELETE FROM walls WHERE id = 'w-orphan'");
        await db.customStatement('PRAGMA foreign_keys = ON');

        await makeService(
          storage: _ScriptedStorage(const [0.99]),
        ).pruneIfUnderPressure();

        expect(photoFiles.deleted, isNot(contains('photos/orphan.jpg')));
        expect(photoFiles.deleted, ['photos/foreign.jpg']);
      },
    );

    test(
      'a blank localPath is skipped, never handed to the byte store as an '
      'empty delete key',
      () async {
        await seedWall(
          id: 'w-blank',
          ownerId: 'them',
          updatedAt: 1,
          keys: [''],
        );
        await seedWall(
          id: 'w-foreign',
          ownerId: 'them',
          updatedAt: 2,
          keys: ['photos/foreign.jpg'],
        );

        await makeService(
          storage: _ScriptedStorage(const [0.99]),
        ).pruneIfUnderPressure();

        expect(photoFiles.deleted, ['photos/foreign.jpg']);
      },
    );

    test(
      'a key shared by an OWN row and a foreign row is never deleted — the '
      'bytes are one object, and one of its referents is irreplaceable',
      () async {
        await seedWall(
          id: 'w-own',
          ownerId: 'me',
          updatedAt: 1,
          keys: ['photos/shared.jpg'],
        );
        await seedWall(
          id: 'w-foreign',
          ownerId: 'them',
          updatedAt: 2,
          keys: ['photos/shared.jpg'],
        );
        await seedWall(
          id: 'w-foreign-2',
          ownerId: 'them',
          updatedAt: 3,
          keys: ['photos/solo.jpg'],
        );

        await makeService(
          storage: _ScriptedStorage(const [0.99]),
        ).pruneIfUnderPressure();

        expect(photoFiles.deleted, isNot(contains('photos/shared.jpg')));
        expect(photoFiles.deleted, ['photos/solo.jpg']);
      },
    );

    test(
      'everything the same age, mixed ownership, maximum pressure: still only '
      'the foreign keys go, and the order is deterministic',
      () async {
        await seedWall(
          id: 'w-own',
          ownerId: 'me',
          updatedAt: 500,
          keys: ['photos/own-1.jpg', 'photos/own-2.jpg'],
        );
        await seedWall(
          id: 'w-f1',
          ownerId: 'them',
          updatedAt: 500,
          keys: ['photos/f-b.jpg'],
        );
        await seedWall(
          id: 'w-f2',
          ownerId: 'them',
          updatedAt: 500,
          keys: ['photos/f-a.jpg'],
        );

        await makeService(
          storage: _ScriptedStorage(const [0.99]),
        ).pruneIfUnderPressure();

        // Tie broken by key, ascending — stable across runs.
        expect(photoFiles.deleted, ['photos/f-a.jpg', 'photos/f-b.jpg']);
      },
    );

    test(
      'the keepNewest floor protects the most-recently-touched foreign '
      'photos even at 99% — the feed the user is browsing does not go blank',
      () async {
        for (var i = 0; i < 5; i++) {
          await seedWall(
            id: 'w-$i',
            ownerId: 'them',
            updatedAt: i + 1,
            keys: ['photos/f-$i.jpg'],
          );
        }

        await makeService(
          storage: _ScriptedStorage(const [0.99]),
          keepNewestForeign: 2,
        ).pruneIfUnderPressure();

        // Oldest three go; the two newest are floored off-limits.
        expect(photoFiles.deleted, [
          'photos/f-0.jpg',
          'photos/f-1.jpg',
          'photos/f-2.jpg',
        ]);
      },
    );
  });

  group('sweep behaviour — bounded work, re-measured as it goes', () {
    test(
      'foreign photos go oldest-first and the sweep stops the moment the '
      'estimate drops under the LOW watermark, re-reading between batches',
      () async {
        for (var i = 0; i < 25; i++) {
          await seedWall(
            id: 'w-${i.toString().padLeft(2, '0')}',
            ownerId: 'them',
            updatedAt: i + 1,
            keys: ['photos/f-${i.toString().padLeft(2, '0')}.jpg'],
          );
        }

        final storage = _ScriptedStorage(const [0.9, 0.9, 0.5]);
        final outcome = await makeService(
          storage: storage,
          batchSize: 10,
        ).pruneIfUnderPressure();

        expect(outcome.reason, PublicPhotoPruneReason.relieved);
        expect(photoFiles.deleted.length, 20);
        // Oldest first.
        expect(photoFiles.deleted.first, 'photos/f-00.jpg');
        expect(photoFiles.deleted.last, 'photos/f-19.jpg');
        // The five newest were never reached.
        expect(photoFiles.deleted, isNot(contains('photos/f-24.jpg')));
        // One read to trigger + one after each of the two batches.
        expect(storage.estimateCalls, 3);
        expect(outcome.usedFractionAfter, 0.5);
      },
    );

    test(
      'an estimate that never budges is capped — one pass frees a bounded '
      'amount instead of nuking the whole public cache on a stale reading',
      () async {
        for (var i = 0; i < 30; i++) {
          await seedWall(
            id: 'w-${i.toString().padLeft(2, '0')}',
            ownerId: 'them',
            updatedAt: i + 1,
            keys: ['photos/f-${i.toString().padLeft(2, '0')}.jpg'],
          );
        }

        final outcome = await makeService(
          storage: _ScriptedStorage(const [0.9]),
          batchSize: 10,
          maxDeletionsPerPass: 25,
        ).pruneIfUnderPressure();

        expect(outcome.reason, PublicPhotoPruneReason.capReached);
        expect(photoFiles.deleted.length, 25);
      },
    );

    test(
      'running out of prunable photos while still over the watermark ends the '
      'pass cleanly — there is nothing else it is allowed to delete',
      () async {
        for (var i = 0; i < 8; i++) {
          await seedWall(
            id: 'w-$i',
            ownerId: 'them',
            updatedAt: i + 1,
            keys: ['photos/f-$i.jpg'],
          );
        }

        final outcome = await makeService(
          storage: _ScriptedStorage(const [0.9]),
          batchSize: 10,
        ).pruneIfUnderPressure();

        expect(outcome.reason, PublicPhotoPruneReason.poolExhausted);
        expect(photoFiles.deleted.length, 8);
      },
    );

    test(
      'losing the estimate mid-sweep stops it — deleting on a signal that '
      'just went dark is exactly the guess this service refuses to make',
      () async {
        for (var i = 0; i < 25; i++) {
          await seedWall(
            id: 'w-${i.toString().padLeft(2, '0')}',
            ownerId: 'them',
            updatedAt: i + 1,
            keys: ['photos/f-${i.toString().padLeft(2, '0')}.jpg'],
          );
        }

        final outcome = await makeService(
          storage: _ScriptedStorage(const [0.9, null]),
          batchSize: 10,
        ).pruneIfUnderPressure();

        expect(outcome.reason, PublicPhotoPruneReason.estimateLost);
        expect(photoFiles.deleted.length, 10);
      },
    );

    test(
      'a byte-store delete that throws does not abort the sweep — the '
      'remaining photos are still freed and the failure is reported',
      () async {
        for (var i = 0; i < 5; i++) {
          await seedWall(
            id: 'w-$i',
            ownerId: 'them',
            updatedAt: i + 1,
            keys: ['photos/f-$i.jpg'],
          );
        }
        photoFiles.throwOn.add('photos/f-2.jpg');

        final outcome = await makeService(
          storage: _ScriptedStorage(const [0.9]),
        ).pruneIfUnderPressure();

        expect(photoFiles.deleted.length, 5);
        expect(outcome.failedDeleteCount, 1);
        // The thrower is not reported as freed.
        expect(outcome.deletedKeys, isNot(contains('photos/f-2.jpg')));
        expect(outcome.deletedKeys.length, 4);
      },
    );

    test(
      'pruning drops pixels, never rows — every photo and wall row survives '
      'the sweep so the topo keeps its name, grade and comments offline',
      () async {
        await seedWall(
          id: 'w-foreign',
          ownerId: 'them',
          updatedAt: 1,
          keys: ['photos/f-a.jpg', 'photos/f-b.jpg'],
        );

        await makeService(
          storage: _ScriptedStorage(const [0.99]),
        ).pruneIfUnderPressure();

        expect(photoFiles.deleted.length, 2);
        final photoRows = await db.select(db.photos).get();
        final wallRows = await db.select(db.walls).get();
        expect(photoRows.length, 2);
        expect(wallRows.length, 1);
        // The rows still point at the (now absent) bytes — see the service's
        // library doc: a pruned cache IS a row whose localPath has no bytes.
        expect(
          photoRows.map((r) => r.localPath).toList()..sort(),
          ['photos/f-a.jpg', 'photos/f-b.jpg'],
        );
      },
    );

    test('an empty database at maximum pressure is a clean no-op', () async {
      final outcome = await makeService(
        storage: _ScriptedStorage(const [0.99]),
      ).pruneIfUnderPressure();

      expect(photoFiles.deleted, isEmpty);
      expect(outcome.reason, PublicPhotoPruneReason.nothingPrunable);
    });
  });

  group('shipped defaults', () {
    test('the watermarks form a hysteresis band, not a single line', () {
      expect(kPrunePressureLowWatermark, lessThan(kPrunePressureHighWatermark));
      expect(kPrunePressureHighWatermark, lessThan(1.0));
      expect(kPrunePressureLowWatermark, greaterThan(0.0));
    });

    test(
      'the default pass is bounded and batched — never one-at-a-time (a '
      'busy-loop) and never unbounded (a cache wipe over cell data)',
      () {
        expect(kPruneBatchSize, greaterThan(1));
        expect(kPruneMaxDeletionsPerPass, greaterThan(kPruneBatchSize));
        expect(kPruneKeepNewestForeign, greaterThan(0));
      },
    );
  });
}
