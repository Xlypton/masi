import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

// Relative import on purpose: `tool/` is outside `lib/`, so it is not part of
// the `package:masi` library set and cannot be reached with a `package:` URI.
// Same package, so a relative import is legal Dart and analyzes cleanly. The
// generator imports the native file-system library, which is fine here — the
// wasm gate in `tool/build_web.sh` scans `lib/` only.
import '../../tool/gen_sw_manifest.dart';

/// Builds a directory shaped like a real `build/web`, with the sizes that
/// actually matter (a 37 MB canvaskit tree, a 4.2 MB dart2js fallback, a
/// 1.4 MB NOTICES blob and a 10 MB test fixture are the four things that must
/// stay OUT of a precache that has to fit on a phone).
Directory _fakeBuildDir({int wasmBytes = 1024}) {
  final dir = Directory.systemTemp.createTempSync('masi_sw_manifest');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  void write(String relativePath, {int bytes = 16}) {
    final file = File(p.join(dir.path, relativePath));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(List<int>.filled(bytes, 0x61));
  }

  write('index.html');
  write('flutter_bootstrap.js');
  write('main.dart.wasm', bytes: wasmBytes);
  write('main.dart.mjs');
  write('main.dart.js', bytes: 4 * 1024 * 1024);
  write('flutter.js');
  write('version.json');
  write('manifest.json');
  write('favicon.png');
  write('sqlite3.wasm', bytes: 2048);
  write('drift_worker.js', bytes: 2048);
  write('flutter_service_worker.js', bytes: 0);
  write('_headers');
  write('icons/Icon-192.png');
  write('icons/Icon-maskable-512.png');
  write('assets/AssetManifest.bin.json');
  write('assets/FontManifest.json');
  write('assets/NOTICES', bytes: 1400 * 1024);
  write('assets/fonts/MaterialIcons-Regular.otf');
  write('assets/shaders/ink_sparkle.frag');
  write('assets/packages/cupertino_icons/assets/CupertinoIcons.ttf');
  write('assets/assets/icons/masi/masi_add.svg');
  write('assets/assets/test/crag_sample.jpg', bytes: 10 * 1024 * 1024);
  write('canvaskit/skwasm.wasm', bytes: 3 * 1024 * 1024);
  write('canvaskit/skwasm.js');
  write('canvaskit/skwasm.js.symbols', bytes: 1024 * 1024);
  write('canvaskit/chromium/canvaskit.wasm', bytes: 6 * 1024 * 1024);

  // The committed dev stamp, byte-for-byte as web/sw.js carries it.
  File(p.join(dir.path, 'sw.js')).writeAsStringSync('''
'use strict';
const SHELL_VERSION = 'dev';
const PRECACHE = [];
const CACHE_NAME = `masi-shell-\${SHELL_VERSION}`;
''');

  return dir;
}

void main() {
  group('isPrecacheExcluded', () {
    test('excludes the four payloads that would blow the budget', () {
      expect(isPrecacheExcluded('canvaskit/skwasm.wasm'), isTrue);
      expect(isPrecacheExcluded('canvaskit/chromium/canvaskit.wasm'), isTrue);
      expect(isPrecacheExcluded('main.dart.js'), isTrue);
      expect(isPrecacheExcluded('assets/NOTICES'), isTrue);
      expect(isPrecacheExcluded('assets/assets/test/crag_sample.jpg'), isTrue);
    });

    test('excludes worker-visible and build-only files', () {
      expect(isPrecacheExcluded('sw.js'), isTrue);
      expect(isPrecacheExcluded('flutter_service_worker.js'), isTrue);
      expect(isPrecacheExcluded('_headers'), isTrue);
      expect(isPrecacheExcluded('_redirects'), isTrue);
      expect(isPrecacheExcluded('flutter.js'), isTrue);
      expect(isPrecacheExcluded('canvaskit/skwasm.js.symbols'), isTrue);
      expect(isPrecacheExcluded('main.dart.wasm.map'), isTrue);
    });

    test(
        'includes everything else — new Flutter output is precached by '
        'default rather than silently dropped', () {
      expect(isPrecacheExcluded('index.html'), isFalse);
      expect(isPrecacheExcluded('main.dart.wasm'), isFalse);
      expect(isPrecacheExcluded('sqlite3.wasm'), isFalse);
      expect(isPrecacheExcluded('drift_worker.js'), isFalse);
      expect(
          isPrecacheExcluded('assets/assets/icons/masi/masi_add.svg'), isFalse);
      expect(isPrecacheExcluded('assets/AssetManifest.bin.json'), isFalse);
      expect(isPrecacheExcluded('some/future/flutter/output.bin'), isFalse);
    });
  });

  group('formatShellVersion', () {
    // Regression: the obvious `hash.toRadixString(16).padLeft(16, '0')` is
    // WRONG for any hash with its top bit set, because Dart ints are 64-bit
    // SIGNED — such a hash is negative and renders as `-<magnitude>`, 17
    // chars. A real build hit this (`-208049a153bacd51`). The generic
    // "16 hex chars" test below cannot catch it: whether a given fixture
    // hashes positive or negative is luck, and that fixture happens to be
    // positive.
    test('renders a NEGATIVE hash as unsigned 16-char hex', () {
      final version = formatShellVersion(-0x208049a153bacd51);

      expect(version, hasLength(16));
      expect(version, isNot(contains('-')));
      expect(version, matches(RegExp(r'^[0-9a-f]{16}$')));
      // Two's complement of 0x208049a153bacd51.
      expect(version, 'df7fb65eac4532af');
    });

    test('renders a positive hash unchanged, zero-padded to 16', () {
      expect(formatShellVersion(0x1), '0000000000000001');
      expect(formatShellVersion(0x7fffffffffffffff), '7fffffffffffffff');
    });

    test('is injective across the sign boundary', () {
      expect(formatShellVersion(-1), 'ffffffffffffffff');
      expect(formatShellVersion(0), '0000000000000000');
      expect(formatShellVersion(-1), isNot(formatShellVersion(0)));
    });
  });

  group('buildShellManifest', () {
    test('precaches the shell core and nothing heavy', () {
      final manifest = buildShellManifest(_fakeBuildDir());

      expect(manifest.urls, contains('index.html'));
      expect(manifest.urls, contains('flutter_bootstrap.js'));
      expect(manifest.urls, contains('main.dart.wasm'));
      expect(manifest.urls, contains('main.dart.mjs'));
      expect(manifest.urls, contains('sqlite3.wasm'));
      expect(manifest.urls, contains('drift_worker.js'));
      expect(manifest.urls, contains('assets/assets/icons/masi/masi_add.svg'));

      expect(manifest.urls, isNot(contains('sw.js')));
      expect(manifest.urls, isNot(contains('main.dart.js')));
      expect(manifest.urls, isNot(contains('assets/NOTICES')));
      expect(manifest.urls, isNot(contains('canvaskit/skwasm.wasm')));
      expect(
        manifest.urls.where((u) => u.startsWith('canvaskit/')),
        isEmpty,
        reason: 'the renderer is warmed at runtime from the page\'s own '
            'resource timing, not precached — 37 MB of variants of which the '
            'browser uses exactly one',
      );
    });

    test('the list is sorted, so the version is reproducible', () {
      final manifest = buildShellManifest(_fakeBuildDir());
      final sorted = [...manifest.urls]..sort();
      expect(manifest.urls, sorted);
    });

    test('the version changes when a precached file changes', () {
      final a = buildShellManifest(_fakeBuildDir(wasmBytes: 1024));
      final b = buildShellManifest(_fakeBuildDir(wasmBytes: 1025));
      expect(a.version, isNot(b.version));
    });

    test('the version is stable for identical input', () {
      final a = buildShellManifest(_fakeBuildDir());
      final b = buildShellManifest(_fakeBuildDir());
      expect(a.version, b.version);
      expect(a.version, matches(RegExp(r'^[0-9a-f]{16}$')));
    });

    test('throws when the precache would exceed the ceiling', () {
      expect(
        () => buildShellManifest(
          _fakeBuildDir(wasmBytes: precacheCeilingBytes + 1),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('throws when the build directory has no sw.js to stamp', () {
      final dir = _fakeBuildDir();
      File(p.join(dir.path, 'sw.js')).deleteSync();
      expect(() => buildShellManifest(dir), throwsA(isA<StateError>()));
    });
  });

  group('stampServiceWorker', () {
    test('rewrites both stamp lines and leaves the rest untouched', () {
      final dir = _fakeBuildDir();
      final manifest = buildShellManifest(dir);
      stampServiceWorker(dir, manifest);

      final stamped = File(p.join(dir.path, 'sw.js')).readAsStringSync();
      expect(stamped, contains("const SHELL_VERSION = '${manifest.version}';"));
      expect(
        stamped,
        contains('const PRECACHE = ${jsonEncode(manifest.urls)};'),
      );
      expect(stamped, isNot(contains("const SHELL_VERSION = 'dev';")));
      expect(stamped, isNot(contains('const PRECACHE = [];')));
      expect(
        stamped,
        contains(r'const CACHE_NAME = `masi-shell-${SHELL_VERSION}`;'),
        reason: 'only the two stamp lines may be rewritten',
      );
    });

    test('is idempotent — stamping twice yields the same file', () {
      final dir = _fakeBuildDir();
      final manifest = buildShellManifest(dir);
      stampServiceWorker(dir, manifest);
      final once = File(p.join(dir.path, 'sw.js')).readAsStringSync();
      stampServiceWorker(dir, manifest);
      expect(File(p.join(dir.path, 'sw.js')).readAsStringSync(), once);
    });

    test('fails loudly if a stamp line is missing', () {
      final dir = _fakeBuildDir();
      final manifest = buildShellManifest(dir);
      File(p.join(dir.path, 'sw.js')).writeAsStringSync("'use strict';\n");
      expect(
        () => stampServiceWorker(dir, manifest),
        throwsA(isA<StateError>()),
      );
    });
  });
}
