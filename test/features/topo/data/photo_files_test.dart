import 'dart:io';

import 'package:climbtopo/features/topo/data/photo_files.dart';
import 'package:flutter_test/flutter_test.dart';
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

/// Fix: absolute photo paths going stale across iOS container rotation.
///
/// [PhotoFiles.importPhoto]/[PhotoFiles.writePhotoBytes] now always return a
/// path RELATIVE to the app documents directory (`photos/<id><ext>`), never
/// an absolute one, so a `Photos.localPath` baked from either never goes
/// stale when the container UUID rotates (reinstall/redeploy/OS restore) —
/// see [PhotoFiles.resolvePhotoPath] (the read-side counterpart, re-joining
/// the relative form against whatever the CURRENT docs dir is, and
/// self-healing a legacy/stale absolute path when it can) and
/// [PhotoFiles.canonicalStoredPath] (the write-side counterpart, normalizing
/// an already-resolved absolute path back to relative before it's
/// persisted).
void main() {
  late Directory docsDir;
  late Directory srcDir;
  late PhotoFiles photoFiles;

  String photosDirPath() => p.join(docsDir.path, 'photos');

  File writeSource(String name, {Directory? into}) {
    final f = File(p.join((into ?? srcDir).path, name));
    f.writeAsBytesSync(List<int>.filled(16, 7));
    return f;
  }

  setUp(() {
    docsDir = Directory.systemTemp.createTempSync('photo_files_docs_');
    srcDir = Directory.systemTemp.createTempSync('photo_files_src_');
    photoFiles = PhotoFiles(docsDir: () async => docsDir);
  });

  tearDown(() {
    if (docsDir.existsSync()) docsDir.deleteSync(recursive: true);
    if (srcDir.existsSync()) srcDir.deleteSync(recursive: true);
  });

  group('importPhoto', () {
    test('copies the source into <docs>/photos/<id><ext> and returns the '
        'RELATIVE form photos/<id><ext>, not an absolute path', () async {
      final src = writeSource('picked.jpg');

      final result = await photoFiles.importPhoto(src.path, 'abc123');

      expect(result, 'photos/abc123.jpg');
      expect(p.isAbsolute(result), isFalse);
      final dest = p.join(photosDirPath(), 'abc123.jpg');
      expect(File(dest).existsSync(), isTrue);
      expect(File(dest).readAsBytesSync(), File(src.path).readAsBytesSync());
    });

    test('is idempotent: a second import of the same source/id returns the '
        'same relative path and does not duplicate the file', () async {
      final src = writeSource('picked.jpg');

      final first = await photoFiles.importPhoto(src.path, 'abc123');
      final second = await photoFiles.importPhoto(src.path, 'abc123');

      expect(second, first);
      expect(Directory(photosDirPath()).listSync(), hasLength(1));
    });

    test(
      'a missing source returns the relative destination form directly, '
      'WITHOUT ever resolving the docs dir (never creates the photos dir, '
      'never throws even when the injected docsDir callback itself throws)',
      () async {
        final throwingDocsDir = PhotoFiles(
          docsDir: () async => throw StateError('should never be called'),
        );
        final missing = p.join(srcDir.path, 'gone.jpg');

        final result = await throwingDocsDir.importPhoto(missing, 'id1');

        expect(result, 'photos/id1.jpg');
        expect(Directory(photosDirPath()).existsSync(), isFalse);
      },
    );

    test('a copy failure (destination path occupied by a directory) is '
        'swallowed and still returns the relative form, not the stale source '
        'path', () async {
      final src = writeSource('picked.jpg');
      // Force the destination to already exist as a DIRECTORY: File.exists
      // on a directory path is false, so importPhoto's "already there,
      // skip copy" fast path does NOT trigger, and source.copy(dest) then
      // throws because dest is occupied by a directory, not a file.
      Directory(
        p.join(photosDirPath(), 'abc123.jpg'),
      ).createSync(recursive: true);

      final result = await photoFiles.importPhoto(src.path, 'abc123');

      expect(result, 'photos/abc123.jpg');
    });
  });

  group('writePhotoBytes', () {
    test('writes bytes to <docs>/photos/<id><ext> and returns the RELATIVE '
        'form photos/<id><ext>', () async {
      final bytes = List<int>.filled(8, 42);

      final result = await photoFiles.writePhotoBytes('xyz', '.png', bytes);

      expect(result, 'photos/xyz.png');
      final dest = p.join(photosDirPath(), 'xyz.png');
      expect(File(dest).existsSync(), isTrue);
      expect(File(dest).readAsBytesSync(), bytes);
    });

    test('overwrites whatever was already at the destination', () async {
      await photoFiles.writePhotoBytes('xyz', '.png', List<int>.filled(8, 1));
      final result = await photoFiles.writePhotoBytes(
        'xyz',
        '.png',
        List<int>.filled(8, 2),
      );

      expect(result, 'photos/xyz.png');
      final dest = p.join(photosDirPath(), 'xyz.png');
      expect(File(dest).readAsBytesSync(), List<int>.filled(8, 2));
    });
  });

  group('resolvePhotoPath', () {
    // resolvePhotoPath resolves off PhotoFiles' MEMOIZED docs path and never
    // awaits path_provider on its hot path (so it can't hang a widget pump —
    // see its doc). Warm the cache up front so these await-driven unit tests
    // see full resolution/heal rather than the cold-cache passthrough. (The
    // dedicated cold-cache passthrough is covered by resolvePhotoPathSync's
    // tests and the exception-fallback tests below, which use their own
    // throwing PhotoFiles instance and are unaffected by this warm.)
    setUp(() async {
      await photoFiles.warmDocsPath();
    });

    test('a relative stored path resolves to <currentDocsDir>/<stored>, no '
        'heal', () async {
      final resolution = await photoFiles.resolvePhotoPath('photos/abc123.jpg');

      expect(resolution.path, p.join(docsDir.path, 'photos/abc123.jpg'));
      expect(resolution.healedRelativePath, isNull);
    });

    test('a legacy absolute path whose file still exists there is returned '
        'unchanged, no heal', () async {
      final legacyAbsolute = writeSource('legacy.jpg', into: docsDir).path;

      final resolution = await photoFiles.resolvePhotoPath(legacyAbsolute);

      expect(resolution.path, legacyAbsolute);
      expect(resolution.healedRelativePath, isNull);
    });

    test('a stale absolute path (container rotated) whose file has moved to '
        '<currentDocsDir>/photos/<basename> resolves to that new absolute '
        'path AND signals a heal to the re-derived relative form', () async {
      // Simulate the file having moved to the NEW container's photos dir
      // under the same basename the OLD absolute path used.
      Directory(photosDirPath()).createSync(recursive: true);
      writeSource('abc123.jpg', into: Directory(photosDirPath()));
      const staleAbsolute =
          '/private/var/mobile/Containers/Data/Application/'
          'OLD-UUID/Documents/photos/abc123.jpg';

      final resolution = await photoFiles.resolvePhotoPath(staleAbsolute);

      expect(resolution.path, p.join(photosDirPath(), 'abc123.jpg'));
      expect(resolution.healedRelativePath, 'photos/abc123.jpg');
    });

    test('a stale absolute path whose re-derived candidate ALSO does not '
        'exist (photo genuinely missing, not just moved) still returns the '
        'best-effort candidate absolute path, but signals NO heal', () async {
      const staleAbsolute =
          '/private/var/mobile/Containers/Data/Application/'
          'OLD-UUID/Documents/photos/never-existed.jpg';

      final resolution = await photoFiles.resolvePhotoPath(staleAbsolute);

      expect(resolution.path, p.join(photosDirPath(), 'never-existed.jpg'));
      expect(resolution.healedRelativePath, isNull);
    });

    test(
      'any exception resolving the docs dir (e.g. no path_provider platform '
      'implementation registered) falls back to returning the stored value '
      'unchanged, with no heal — this is what keeps every pre-existing test '
      'using a hardcoded absolute placeholder path passing unmodified',
      () async {
        final throwingDocsDir = PhotoFiles(
          docsDir: () async => throw StateError('no path_provider here'),
        );

        final resolution = await throwingDocsDir.resolvePhotoPath(
          '/tmp/original.jpg',
        );

        expect(resolution.path, '/tmp/original.jpg');
        expect(resolution.healedRelativePath, isNull);
      },
    );

    test('the exception fallback also applies to an already-relative stored '
        'value (returned unchanged, not joined against anything)', () async {
      final throwingDocsDir = PhotoFiles(
        docsDir: () async => throw StateError('no path_provider here'),
      );

      final resolution = await throwingDocsDir.resolvePhotoPath(
        'photos/abc123.jpg',
      );

      expect(resolution.path, 'photos/abc123.jpg');
      expect(resolution.healedRelativePath, isNull);
    });
  });

  group('canonicalStoredPath', () {
    test('a relative input is returned unchanged', () async {
      final result = await photoFiles.canonicalStoredPath('photos/abc123.jpg');

      expect(result, 'photos/abc123.jpg');
    });

    test('an absolute input within <currentDocsDir>/photos/ is stripped to '
        'the relative form', () async {
      final absolute = p.join(docsDir.path, 'photos', 'abc123.jpg');

      final result = await photoFiles.canonicalStoredPath(absolute);

      expect(result, p.join('photos', 'abc123.jpg'));
    });

    test('an absolute input OUTSIDE <currentDocsDir>/photos/ (a foreign path '
        'this app does not own) is left absolute, unchanged', () async {
      final foreignDir = Directory.systemTemp.createTempSync(
        'photo_files_foreign_',
      );
      addTearDown(() => foreignDir.deleteSync(recursive: true));
      final foreign = writeSource('foreign.jpg', into: foreignDir).path;

      final result = await photoFiles.canonicalStoredPath(foreign);

      expect(result, foreign);
    });

    test('any exception resolving the docs dir falls back to returning the '
        'input unchanged', () async {
      final throwingDocsDir = PhotoFiles(
        docsDir: () async => throw StateError('no path_provider here'),
      );

      final result = await throwingDocsDir.canonicalStoredPath(
        '/some/absolute/path.jpg',
      );

      expect(result, '/some/absolute/path.jpg');
    });
  });

  group('resolvePhotoPathSync + warmDocsPath', () {
    test('cold cache (never warmed) returns the stored value unchanged, no '
        'heal (the best-effort passthrough the sync watchTopos / canvas-load '
        'paths rely on to never hang)', () {
      final resolution = photoFiles.resolvePhotoPathSync('photos/abc123.jpg');
      expect(resolution.path, 'photos/abc123.jpg');
      expect(resolution.healedRelativePath, isNull);
    });

    test('after warmDocsPath, a relative path resolves to '
        '<currentDocsDir>/<stored>, no heal', () async {
      await photoFiles.warmDocsPath();

      final resolution = photoFiles.resolvePhotoPathSync('photos/abc123.jpg');
      expect(resolution.path, p.join(docsDir.path, 'photos/abc123.jpg'));
      expect(resolution.healedRelativePath, isNull);
    });

    test('after warmDocsPath, an absolute path whose file exists is returned '
        'unchanged; an absolute-and-missing path resolves best-effort to '
        '<currentDocsDir>/photos/<basename>', () async {
      await photoFiles.warmDocsPath();
      final legacyAbsolute = writeSource('legacy.jpg', into: docsDir).path;
      expect(
        photoFiles.resolvePhotoPathSync(legacyAbsolute).path,
        legacyAbsolute,
      );

      const staleAbsolute =
          '/private/var/mobile/Containers/Data/Application/'
          'OLD-UUID/Documents/photos/gone.jpg';
      final missing = photoFiles.resolvePhotoPathSync(staleAbsolute);
      expect(missing.path, p.join(photosDirPath(), 'gone.jpg'));
      expect(
        missing.healedRelativePath,
        isNull,
        reason: 'candidate file does not exist -> no heal signalled',
      );
    });

    test('after warmDocsPath, a stale absolute path whose file HAS moved into '
        'the current photos dir resolves to the new absolute path AND signals '
        'a heal to the relative form', () async {
      await photoFiles.warmDocsPath();
      Directory(photosDirPath()).createSync(recursive: true);
      writeSource('here.jpg', into: Directory(photosDirPath()));
      const staleAbsolute =
          '/private/var/mobile/Containers/Data/Application/'
          'OLD-UUID/Documents/photos/here.jpg';

      final resolution = photoFiles.resolvePhotoPathSync(staleAbsolute);
      expect(resolution.path, p.join(photosDirPath(), 'here.jpg'));
      expect(resolution.healedRelativePath, p.join('photos', 'here.jpg'));
    });

    test('warmDocsPath with no path_provider is a swallowed no-op', () async {
      final throwingDocsDir = PhotoFiles(
        docsDir: () async => throw StateError('no path_provider here'),
      );

      await throwingDocsDir.warmDocsPath(); // must not throw

      // Cache stays cold -> sync resolver still passes through.
      final resolution = throwingDocsDir.resolvePhotoPathSync('photos/x.jpg');
      expect(resolution.path, 'photos/x.jpg');
      expect(resolution.healedRelativePath, isNull);
    });
  });

  group(
    'default constructor (real path_provider seam) cold-cache startup fix',
    () {
      // Regression coverage for the cold-cache device bug: every group above
      // exercises PhotoFiles via the INJECTED docsDir seam, never the real
      // `getApplicationDocumentsDirectory()`-backed default constructor that
      // `photoFilesProvider` (database_provider.dart) actually uses in the
      // app. This proves the fix — `main.dart` awaiting
      // `photoFilesProvider`'s `warmDocsPath()` before `runApp` — genuinely
      // warms the cache that the DEFAULT constructor resolves through, not
      // just the test-only injected-callback path.
      late String mockedDocsPath;
      final originalPathProviderPlatform = PathProviderPlatform.instance;

      setUp(() {
        mockedDocsPath = Directory.systemTemp
            .createTempSync('photo_files_default_ctor_')
            .path;
        PathProviderPlatform.instance = _FakePathProviderPlatform(
          mockedDocsPath,
        );
      });

      tearDown(() {
        PathProviderPlatform.instance = originalPathProviderPlatform;
        final dir = Directory(mockedDocsPath);
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });

      test('cold cache: resolvePhotoPathSync passes the stored relative value '
          'through unchanged (the exact device-bug symptom — bare '
          '"photos/<id>.jpg" that would resolve against the process CWD)', () {
        final photoFiles = PhotoFiles();

        final resolution = photoFiles.resolvePhotoPathSync('photos/x.jpg');

        expect(resolution.path, 'photos/x.jpg');
      });

      test(
        'after awaiting warmDocsPath() through the real path_provider '
        'channel, resolvePhotoPathSync resolves the same relative value to '
        'an ABSOLUTE <mockedDocsPath>/photos/x.jpg — proving the startup '
        'pre-warm in main.dart makes the sync resolver work from the very '
        'first call, not just after some later, unrelated async resolve',
        () async {
          final photoFiles = PhotoFiles();

          await photoFiles.warmDocsPath();

          final resolution = photoFiles.resolvePhotoPathSync('photos/x.jpg');
          expect(resolution.path, p.join(mockedDocsPath, 'photos', 'x.jpg'));
          expect(p.isAbsolute(resolution.path), isTrue);
        },
      );
    },
  );
}
