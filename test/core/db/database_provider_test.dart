import 'dart:io';

import 'package:masi/core/db/app_database.dart';
import 'package:masi/core/db/database_provider.dart';
import 'package:masi/features/library/application/library_providers.dart';
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
}
