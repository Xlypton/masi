// Controller-level test for the manual, explicitly-consented "clear cached
// community photos" action (#49 P3 / task #51). `public_photo_prune_service_
// test.dart` already proves `clearAllCachedForeignPhotos`'s policy in
// isolation (own photos survive, the floor is widened, no cap); this file
// proves the THIN layer above it that the banner actually talks to: the
// progress enum, the in-flight guard, and — driven end-to-end through a real
// `PublicPhotoPruneService` over a real drift database — that calling
// `clear()` really does free bytes while leaving the signed-in user's own
// photos untouched.
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/storage/storage_persistence_service.dart';
import 'package:masi/core/storage/storage_persistence_types.dart';
import 'package:masi/features/topo/application/community_photo_clear_controller.dart';
import 'package:masi/features/topo/data/photo_files.dart';
import 'package:masi/features/topo/data/public_photo_prune_service.dart';

/// Minimal presence-tracking [PhotoFiles] double — same shape as
/// `public_photo_prune_service_test.dart`'s `_RecordingPhotoFiles`, kept
/// separate because that class is file-private.
class _RecordingPhotoFiles implements PhotoFiles {
  final List<String> deleted = <String>[];

  @override
  Future<bool> hasPhotoBytes(String stored) async => true;

  @override
  Future<void> deletePhotoBytes(String stored) async {
    deleted.add(stored);
  }

  @override
  Future<String> importPhoto(XFile xfile, String photoId) =>
      throw UnimplementedError();

  @override
  Future<String> writePhotoBytes(String photoId, String ext, List<int> bytes) =>
      throw UnimplementedError();

  @override
  Future<Uint8List?> readPhotoBytes(String stored) => throw UnimplementedError();

  @override
  Future<PhotoPathResolution> resolvePhotoPath(String stored) =>
      throw UnimplementedError();

  @override
  PhotoPathResolution resolvePhotoPathSync(String stored) =>
      throw UnimplementedError();

  @override
  Future<String> canonicalStoredPath(String maybePath) async => maybePath;

  @override
  Future<void> warmDocsPath() async {}
}

class _NoEstimateStorage implements StoragePersistenceService {
  @override
  Future<StorageEstimateSnapshot?> estimate() async => null;

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
        .insert(AreasCompanion.insert(id: 'area-1', createdAt: 0, updatedAt: 0, name: 'Area'));
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

  Future<void> seedWall({
    required String id,
    required String? ownerId,
    required List<String> keys,
  }) async {
    await db
        .into(db.walls)
        .insert(
          WallsCompanion.insert(
            id: id,
            createdAt: 0,
            updatedAt: 0,
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
              createdAt: 0,
              updatedAt: 0,
              wallId: id,
              localPath: keys[i],
              kind: 'original',
              width: 100,
              height: 100,
            ),
          );
    }
  }

  ProviderContainer makeContainer() {
    final service = PublicPhotoPruneService(
      db: db,
      photoFiles: photoFiles,
      storage: _NoEstimateStorage(),
      currentUid: () => 'me',
    );
    final container = ProviderContainer(
      overrides: [publicPhotoPruneServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('CommunityPhotoClearController', () {
    test('starts idle with no outcome yet', () {
      final container = makeContainer();
      expect(
        container.read(communityPhotoClearProvider),
        CommunityPhotoClearStatus.idle,
      );
      expect(
        container.read(communityPhotoClearProvider.notifier).lastOutcome,
        isNull,
      );
    });

    test(
      'clear() frees foreign bytes, leaves own bytes alone, and ends '
      'succeeded with the outcome attached',
      () async {
        await seedWall(id: 'w-own', ownerId: 'me', keys: ['photos/own.jpg']);
        await seedWall(
          id: 'w-foreign',
          ownerId: 'them',
          keys: ['photos/foreign.jpg'],
        );
        final container = makeContainer();
        final controller = container.read(communityPhotoClearProvider.notifier);

        await controller.clear();

        expect(
          container.read(communityPhotoClearProvider),
          CommunityPhotoClearStatus.succeeded,
        );
        expect(photoFiles.deleted, ['photos/foreign.jpg']);
        expect(photoFiles.deleted, isNot(contains('photos/own.jpg')));
        expect(controller.lastOutcome?.clearedKeys, ['photos/foreign.jpg']);
      },
    );

    test(
      'a clear with nothing foreign to free still ends succeeded, with an '
      'empty outcome — "nothing to clear" is not a failure',
      () async {
        await seedWall(id: 'w-own', ownerId: 'me', keys: ['photos/own.jpg']);
        final container = makeContainer();
        final controller = container.read(communityPhotoClearProvider.notifier);

        await controller.clear();

        expect(
          container.read(communityPhotoClearProvider),
          CommunityPhotoClearStatus.succeeded,
        );
        expect(controller.lastOutcome?.didClear, isFalse);
        expect(photoFiles.deleted, isEmpty);
      },
    );

    test(
      'a second clear() while one is in flight is a no-op — mirrors '
      'StorageRetryController, so the banner button cannot double-fire',
      () async {
        await seedWall(
          id: 'w-foreign',
          ownerId: 'them',
          keys: ['photos/foreign.jpg'],
        );
        final container = makeContainer();
        final controller = container.read(communityPhotoClearProvider.notifier);

        final first = controller.clear();
        expect(
          container.read(communityPhotoClearProvider),
          CommunityPhotoClearStatus.clearing,
          reason: 'the button reads this to disable itself mid-clear',
        );
        await controller.clear();
        await first;

        expect(
          photoFiles.deleted,
          hasLength(1),
          reason: 'one clear pass, not two',
        );
        expect(
          container.read(communityPhotoClearProvider),
          CommunityPhotoClearStatus.succeeded,
        );
      },
    );

    test(
      'a clear that throws (rather than merely counting a per-key failure) '
      'ends failed, never crashes the caller, and leaves the PREVIOUS '
      'successful outcome readable',
      () async {
        await seedWall(
          id: 'w-foreign',
          ownerId: 'them',
          keys: ['photos/foreign.jpg'],
        );
        final container = makeContainer();
        final controller = container.read(communityPhotoClearProvider.notifier);

        // First, a real successful clear.
        await controller.clear();
        final firstOutcome = controller.lastOutcome;
        expect(firstOutcome, isNotNull);

        // Now break the underlying query so the SECOND call throws before it
        // can produce a new outcome.
        await db.close();

        await expectLater(controller.clear(), completes);

        expect(
          container.read(communityPhotoClearProvider),
          CommunityPhotoClearStatus.failed,
        );
        expect(
          controller.lastOutcome,
          same(firstOutcome),
          reason: 'a failed attempt must not clobber the last GOOD result',
        );
      },
    );
  });
}
