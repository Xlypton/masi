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

/// Fake [PhotoFiles] that models a real byte store closely enough to tell a
/// deletion that FREES something from one that does not: it tracks which keys
/// actually hold bytes, and records every delete it is asked to perform.
///
/// Modelling presence is not incidental — it is the gap that let the "the pass
/// deletes 50 keys and frees zero bytes" bug ship. The old fake had no notion of
/// byte presence, so every seeded `Photos` row implicitly held bytes, which is
/// exactly the assumption the production code was wrong about (a pruned or
/// budget-skipped public photo IS a row whose bytes are absent). Tests below
/// therefore assert on [freed] — bytes that actually went away — wherever the
/// point is that something was reclaimed, and use [absent] to seed the rows that
/// name a key holding nothing.
///
/// `implements PhotoFiles` on purpose: [PhotoFiles] is a CONCRETE,
/// conditionally-exported class (native under `flutter test`), not an
/// interface, so every public member has to be stubbed here. Extracting an
/// abstract interface instead would take ownership of four platform files for
/// the sake of one test double — not worth it.
class _RecordingPhotoFiles implements PhotoFiles {
  /// Every key `deletePhotoBytes` was called with, in call order.
  final List<String> deleted = <String>[];

  /// Keys the store has NO bytes for — a pruned photo, one the pull's byte
  /// budget skipped, or one whose remote object was missing. Any key seeded into
  /// the database and not listed here is assumed to hold bytes.
  final Set<String> absent = <String>{};

  /// Keys whose bytes this fake genuinely removed, i.e. the ones a delete freed
  /// something for. A delete of an [absent] key is a no-op and never appears
  /// here, which is precisely the distinction the production code missed.
  final List<String> freed = <String>[];

  /// Keys whose delete should throw, simulating a backend that is not as
  /// best-effort as the two real ones.
  final Set<String> throwOn = <String>{};

  /// Keys whose presence probe should throw, simulating a backend that is not
  /// as defensive as the two real ones.
  final Set<String> throwOnProbe = <String>{};

  /// Presence probes performed, in call order — a cheap key lookup in both real
  /// backends, so a test can prove the pass never probes more than it could
  /// possibly delete.
  final List<String> probed = <String>[];

  @override
  Future<bool> hasPhotoBytes(String stored) async {
    probed.add(stored);
    if (throwOnProbe.contains(stored)) {
      throw StateError('byte store could not answer for $stored');
    }
    return !absent.contains(stored);
  }

  @override
  Future<void> deletePhotoBytes(String stored) async {
    deleted.add(stored);
    if (throwOn.contains(stored)) {
      throw StateError('byte store refused to delete $stored');
    }
    if (absent.add(stored)) freed.add(stored);
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
      'when the ONLY bytes on the device are the user\'s own, the pass frees '
      'nothing rather than reaching for the one thing that would move the '
      'number — the never-evict-own guarantee does not bend under pressure',
      () async {
        await seedWall(
          id: 'w-own',
          ownerId: 'me',
          updatedAt: 1,
          keys: ['photos/own-a.jpg', 'photos/own-b.jpg'],
        );
        // Foreign rows exist, but their bytes were never fetched (the pull's
        // byte budget) — so the only pixels here are irreplaceable.
        await seedWall(
          id: 'w-foreign',
          ownerId: 'them',
          updatedAt: 2,
          keys: ['photos/f-a.jpg', 'photos/f-b.jpg'],
        );
        photoFiles.absent.addAll(['photos/f-a.jpg', 'photos/f-b.jpg']);

        final outcome = await makeService(
          storage: _ScriptedStorage(const [0.99]),
        ).pruneIfUnderPressure();

        expect(photoFiles.deleted, isEmpty);
        expect(photoFiles.freed, isEmpty);
        expect(outcome.reason, PublicPhotoPruneReason.nothingPrunable);
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

  group('a ROW is not BYTES — the cap is only spent on keys that hold pixels', () {
    /// Seeds [count] foreign walls, one photo each, oldest first: `photos/f-000`
    /// (wall `updatedAt: 1`) through `photos/f-<count-1>` (the newest). Every
    /// key EXCEPT the newest [withBytes] of them is marked as holding no bytes —
    /// which is exactly the shape a bounded, newest-first shared pull leaves
    /// behind (a row for every public photo; bytes for only the newest few).
    Future<void> seedForeignLibrary({
      required int count,
      required int withBytes,
    }) async {
      for (var i = 0; i < count; i++) {
        final key = 'photos/f-${i.toString().padLeft(3, '0')}.jpg';
        await seedWall(
          id: 'w-${i.toString().padLeft(3, '0')}',
          ownerId: 'them',
          updatedAt: i + 1,
          keys: [key],
        );
        if (i < count - withBytes) photoFiles.absent.add(key);
      }
    }

    test(
      'THE CONFIRMED DEFECT: 100 foreign rows of which only the newest 20 were '
      'ever fetched — i.e. exactly the protected floor — frees nothing and says '
      'so, instead of "deleting" 50 keys that hold nothing while the fraction '
      'never moves and the user\'s next own import fails on quota',
      () async {
        await seedForeignLibrary(count: 100, withBytes: 20);

        final outcome = await makeService(
          storage: _ScriptedStorage(const [0.80]),
          keepNewestForeign: 20,
          maxDeletionsPerPass: 50,
        ).pruneIfUnderPressure();

        // The pass is honest about having had nothing to free...
        expect(outcome.reason, PublicPhotoPruneReason.nothingPrunable);
        expect(outcome.deletedKeys, isEmpty);
        // ...and, the part that actually matters, it did not burn its whole
        // deletion budget on no-ops.
        expect(photoFiles.deleted, isEmpty);
        expect(photoFiles.freed, isEmpty);
        // The 20 keys that DO hold bytes are the floor, and the floor was never
        // even offered — so they were never probed either.
        expect(photoFiles.probed, isNot(contains('photos/f-099.jpg')));
      },
    );

    test(
      'the deletion cap is spent ONLY on keys that hold bytes: byte-less rows '
      'interleaved through the eviction order are skipped free of charge, so a '
      'pass still frees a full cap\'s worth of real pixels',
      () async {
        // 60 foreign rows, the oldest 40 byte-less. Oldest-first eviction walks
        // straight through those 40 before reaching anything real.
        await seedForeignLibrary(count: 60, withBytes: 20);

        final outcome = await makeService(
          storage: _ScriptedStorage(const [0.9]),
          keepNewestForeign: 5,
          maxDeletionsPerPass: 10,
          batchSize: 10,
        ).pruneIfUnderPressure();

        expect(outcome.reason, PublicPhotoPruneReason.capReached);
        // A full cap of REAL frees, not 10 no-ops.
        expect(photoFiles.freed, hasLength(10));
        expect(outcome.deletedKeys, hasLength(10));
        // Oldest-first is preserved among the keys that hold bytes: rows 0..39
        // hold nothing, rows 40..54 are offered and hold bytes (55..59 are the
        // keepNewest floor), so the ten oldest of those are f-040..f-049.
        expect(outcome.deletedKeys.first, 'photos/f-040.jpg');
        expect(outcome.deletedKeys.last, 'photos/f-049.jpg');
        // Not one byte-less key was handed to the store.
        expect(
          photoFiles.deleted.where((k) => k.compareTo('photos/f-040.jpg') < 0),
          isEmpty,
        );
      },
    );

    test(
      'freeing every cached key it was allowed to still reports poolExhausted, '
      'even though 30 byte-less rows were also on offer — filtering must not '
      'turn "nothing left to free" into "the cap stopped me"',
      () async {
        await seedForeignLibrary(count: 40, withBytes: 10);

        final outcome = await makeService(
          storage: _ScriptedStorage(const [0.9]),
          keepNewestForeign: 0,
          maxDeletionsPerPass: 10,
        ).pruneIfUnderPressure();

        expect(outcome.reason, PublicPhotoPruneReason.poolExhausted);
        expect(photoFiles.freed, hasLength(10));
      },
    );

    test(
      'one cached key more than the cap allows still reports capReached — the '
      'other stopping reason survives filtering too',
      () async {
        await seedForeignLibrary(count: 11, withBytes: 11);

        final outcome = await makeService(
          storage: _ScriptedStorage(const [0.9]),
          keepNewestForeign: 0,
          maxDeletionsPerPass: 10,
        ).pruneIfUnderPressure();

        expect(outcome.reason, PublicPhotoPruneReason.capReached);
        expect(photoFiles.freed, hasLength(10));
      },
    );

    test(
      'probing stops as soon as it has more keys than the pass could possibly '
      'delete — a 500-photo cache is not 500 lookups',
      () async {
        await seedForeignLibrary(count: 200, withBytes: 200);

        await makeService(
          storage: _ScriptedStorage(const [0.9]),
          keepNewestForeign: 0,
          maxDeletionsPerPass: 20,
          batchSize: 10,
        ).pruneIfUnderPressure();

        // maxDeletionsPerPass + 1: the extra one is what lets the sweep tell
        // capReached from poolExhausted.
        expect(photoFiles.probed, hasLength(21));
      },
    );

    test(
      'a presence probe that THROWS counts as "no bytes" — cannot-tell must '
      'never spend a deletion, and it must not abort the pass either',
      () async {
        await seedForeignLibrary(count: 5, withBytes: 5);
        photoFiles.throwOnProbe.add('photos/f-000.jpg');

        final outcome = await makeService(
          storage: _ScriptedStorage(const [0.9]),
          keepNewestForeign: 0,
        ).pruneIfUnderPressure();

        expect(photoFiles.deleted, isNot(contains('photos/f-000.jpg')));
        expect(outcome.deletedKeys, hasLength(4));
        expect(photoFiles.freed, hasLength(4));
      },
    );
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

  group('PublicPhotoPruneOutcome.fractionFreed (#49)', () {
    test(
      'reports the drop when both readings are known — the field that would '
      'have caught the pre-fix bug outright',
      () {
        const outcome = PublicPhotoPruneOutcome(
          reason: PublicPhotoPruneReason.relieved,
          usedFractionBefore: 0.80,
          usedFractionAfter: 0.60,
        );
        expect(outcome.fractionFreed, closeTo(0.20, 1e-9));
      },
    );

    test(
      'is exactly zero for the confirmed pre-fix shape — 50 "deletions" that '
      'moved the fraction not at all, as opposed to reading null or being '
      'skipped for lack of a getter at all',
      () {
        final outcome = PublicPhotoPruneOutcome(
          reason: PublicPhotoPruneReason.capReached,
          deletedKeys: List.generate(50, (i) => 'photos/f-$i.jpg'),
          usedFractionBefore: 0.80,
          usedFractionAfter: 0.80,
        );
        expect(outcome.fractionFreed, 0.0);
        expect(
          outcome.deletedKeys.length,
          greaterThan(0),
          reason: 'the contradiction only reads as one if deletedKeys is '
              'non-empty alongside a zero fractionFreed',
        );
      },
    );

    test('is null when either reading is missing — e.g. noEstimate', () {
      const outcome = PublicPhotoPruneOutcome(
        reason: PublicPhotoPruneReason.noEstimate,
      );
      expect(outcome.fractionFreed, isNull);
    });
  });
}
