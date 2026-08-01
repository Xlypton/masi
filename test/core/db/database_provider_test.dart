import 'dart:io';

import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/core/db/storage_durability_provider.dart';
import 'package:masi/features/library/application/library_providers.dart';
import 'package:drift/drift.dart' show LazyDatabase;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// Stands in for the real `path_provider` platform channel plugin — see
/// `test/features/ar/presentation/ar_screen_test.dart`'s identical fake for
/// why this is needed (a plain `flutter test` host has no `path_provider`
/// platform implementation registered).
class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.docsPath);

  final String docsPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => docsPath;
}

/// An [AppDatabase] whose executor resolves fine and then fails the moment a
/// statement actually needs it — precisely drift-on-web's shape, where the
/// real sqlite open lives behind a `LazyDatabase` INSIDE the worker
/// (`drift-2.34.2/lib/src/web/wasm_setup/shared.dart:284`) and so cannot fail
/// until the first query.
///
/// A closed `NativeDatabase.memory()` does NOT work as a stand-in here: drift
/// simply opens a fresh in-memory database on the next statement, so every
/// query keeps succeeding.
AppDatabase _brokenDatabase() => AppDatabase(
  LazyDatabase(() async => throw StateError('no storage backend')),
);

/// Regression coverage for the cold-cache device bug: `photoRepositoryProvider`
/// and `libraryCrudRepositoryProvider` used to each construct their OWN
/// `PhotoFiles()` (`?? PhotoFiles()`), so warming one repository's docs-path
/// cache never helped the other, and neither was ever warmed at app startup
/// — leaving `Photos.localPath`'s bare relative form (`photos/<id>.jpg`)
/// unresolved on a device's first cold launch (`File(...)` then resolves
/// against the process CWD, not the app documents directory -> missing
/// images).
///
/// Both providers now read the single shared `photoFilesProvider` (see
/// `database_provider.dart`), and `main.dart` awaits that ONE instance's
/// `warmDocsPath()` before `runApp`. This file proves the sharing half of
/// the fix: warming `photoFilesProvider` directly — mirroring exactly what
/// `main.dart` does — is visible to BOTH repositories' photo-path
/// resolution, even though neither repository ever calls `warmDocsPath` on
/// its own.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late String mockedDocsPath;
  final originalPathProviderPlatform = PathProviderPlatform.instance;

  setUp(() {
    mockedDocsPath = Directory.systemTemp
        .createTempSync('database_provider_test_')
        .path;
    PathProviderPlatform.instance = _FakePathProviderPlatform(mockedDocsPath);
  });

  tearDown(() {
    PathProviderPlatform.instance = originalPathProviderPlatform;
    final dir = Directory(mockedDocsPath);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('container.read(photoFilesProvider) returns the same PhotoFiles '
      'instance on every read (a single shared cache, not a fresh instance '
      'per read)', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final first = container.read(photoFilesProvider);
    final second = container.read(photoFilesProvider);

    expect(identical(first, second), isTrue);
  });

  test('photoRepositoryProvider and libraryCrudRepositoryProvider are backed '
      'by the SAME photoFilesProvider instance: warming ONLY the shared '
      'PhotoFiles (as main.dart does before runApp) makes BOTH repositories '
      "resolve a stored relative localPath to an absolute path, proving "
      'neither one carries its own separate, unwarmed PhotoFiles()', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        nowMsProvider.overrideWithValue(() => 1000),
      ],
    );
    addTearDown(container.dispose);

    // Mirrors main.dart's startup sequence exactly: only the shared
    // photoFilesProvider instance is ever warmed, directly — neither
    // repository's own warmDocsPath is ever invoked below.
    await container.read(photoFilesProvider).warmDocsPath();

    final crud = container.read(libraryCrudRepositoryProvider);
    final area = await crud.createArea('Area');
    final sector = await crud.createSector(area.id, 'Sector');
    final wall = await crud.createWall(sector.id, 'Wall');
    // A missing source path -> PhotoFiles.importPhoto's best-effort
    // branch returns the relative destination form directly without
    // touching the docs dir, giving a clean "stored relative, never
    // resolved" row to resolve from below.
    final photoId = await crud.attachPhotoToWall(
      wall.id,
      XFile('/does/not/exist.jpg'),
      100,
      200,
    );
    final expectedAbsolute = p.join(mockedDocsPath, 'photos', '$photoId.jpg');

    // libraryCrudRepositoryProvider's own resolution.
    final crudResolved = await crud.photoLocalPath(photoId);
    expect(crudResolved, expectedAbsolute);

    // photoRepositoryProvider's resolution of the SAME row, via a
    // completely different repository instance — this only resolves to
    // an absolute path if it shares photoFilesProvider's already-warmed
    // cache instead of carrying its own cold PhotoFiles().
    final photoRepo = container.read(photoRepositoryProvider);
    final original = await photoRepo.loadOriginal(wall.id);

    expect(original, isNotNull);
    expect(original!.localPath, expectedAbsolute);
  });

  // `WasmDatabase.open`'s verdict is reported BEFORE the database has done any
  // real work: drift hands back a `resolvedExecutor` whose actual sqlite open
  // is itself deferred behind a `LazyDatabase` inside the worker
  // (`drift-2.34.2/lib/src/web/wasm_setup/shared.dart:284`), and native's
  // `openConnection` reports synchronously around an unopened `LazyDatabase`.
  // So a green `opfsShared`/`opfsLocks`/`nativeFile` verdict is NOT evidence
  // that storage works — only a completed query is. Without this probe a
  // worker that reports green and then dies on the first query leaves
  // `topos_screen` with creation ENABLED and no warning banner, which is
  // exactly the L1 silent-data-loss shape the storage verdict exists to end.
  group('verifyDatabaseUsable', () {
    test(
      'a database that cannot answer a query is reported as unavailable, even '
      'though the connection layer never complained',
      () async {
        final container = ProviderContainer(
          overrides: [appDatabaseProvider.overrideWithValue(_brokenDatabase())],
        );
        addTearDown(container.dispose);

        expect(container.read(storageDurabilityProvider).isProbing, isTrue);

        await verifyDatabaseUsable(container);

        final verdict = container.read(storageDurabilityProvider);
        expect(verdict.unavailable, isTrue);
        expect(verdict.isEphemeral, isTrue);
        expect(verdict.unavailableReason, isNotNull);
      },
    );

    test('never rethrows — boot must not be taken down by the probe', () async {
      final container = ProviderContainer(
        overrides: [appDatabaseProvider.overrideWithValue(_brokenDatabase())],
      );
      addTearDown(container.dispose);

      await expectLater(verifyDatabaseUsable(container), completes);
    });

    test('a healthy database leaves the verdict exactly as it was', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [appDatabaseProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      container.read(storageDurabilityProvider.notifier).report(
            const StorageDurability(backend: StorageBackend.opfsShared),
          );

      await verifyDatabaseUsable(container);

      expect(
        container.read(storageDurabilityProvider).backend,
        StorageBackend.opfsShared,
      );
      expect(container.read(storageDurabilityProvider).unavailable, isFalse);
    });
  });
}
