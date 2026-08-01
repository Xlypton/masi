// Stamps `<buildDir>/sw.js` with this build's precache manifest and a
// content-derived shell version. Run by `tool/build_web.sh` immediately after
// `flutter build web`; never run against `web/sw.js` itself, which stays
// committed with its inert dev stamp.
//
//   dart run tool/gen_sw_manifest.dart [buildDir]     # default: build/web
//
// Why a deny-list rather than an allow-list: a Flutter upgrade that starts
// emitting a new required asset must be precached AUTOMATICALLY. An
// allow-list would silently drop it and the offline shell would break in a
// way no test could see. The four things that must never be precached are
// large, enumerable and stable, so they are the ones spelled out.
//
// Why FNV-1a rather than SHA-256: `package:crypto` is a TRANSITIVE dependency
// (pubspec.lock, `dependency: transitive`), so importing it would trip
// `depend_on_referenced_packages`, and this stage adds no dependencies. The
// hash only needs "different content => different value"; it is not a
// security boundary.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Hard ceiling on the total precache. `cache.addAll` at install time is a
/// real download on a real phone; blowing past this is a product decision,
/// not something to discover in production.
const int precacheCeilingBytes = 8 * 1024 * 1024;

/// The shell version + the URLs it covers.
class ShellManifest {
  const ShellManifest({
    required this.version,
    required this.urls,
    required this.totalBytes,
  });

  /// 16 lowercase hex chars derived from every precached file's path AND
  /// bytes. Changing any of them changes this, which changes `sw.js`, which
  /// is what makes the browser treat the worker as updated.
  final String version;

  /// Scope-relative URLs, sorted, forward-slashed.
  final List<String> urls;

  final int totalBytes;
}

/// Files that must never enter the precache.
bool isPrecacheExcluded(String relativePath) {
  // The worker itself, and anything that is a hosting directive rather than
  // an app asset. `sw.js` in its own precache would pin a worker generation
  // forever.
  if (relativePath == 'sw.js') return true;
  if (relativePath == 'flutter_service_worker.js') return true;
  if (relativePath == '_headers') return true;
  if (relativePath == '_redirects') return true;
  if (relativePath == '_routes.json') return true;

  // `flutter.js` is emitted for backwards compatibility but is already
  // inlined verbatim at the top of `flutter_bootstrap.js`; nothing fetches it.
  if (relativePath == 'flutter.js') return true;

  // The dart2js/canvaskit fallback build (4.2 MB), used only by browsers
  // without WasmGC. Warmed at runtime on exactly those browsers instead of
  // being paid for by every visitor.
  if (relativePath == 'main.dart.js') return true;

  // 1.4 MB of licence text, reachable only from the licences page.
  if (relativePath == 'assets/NOTICES') return true;

  // 37 MB across four renderer variants (skwasm, skwasm_heavy, wimp,
  // canvaskit) plus chromium/ and experimental_webparagraph/. Exactly ONE is
  // used per browser, and which one is a runtime decision made by the
  // loader's feature probe — so the page's own resource timing is the only
  // accurate source. See `web/sw.js`'s warm handler.
  if (relativePath.startsWith('canvaskit/')) return true;

  // 10 MB AR test fixture that pubspec bundles into the production build.
  // (Separately worth removing from the bundle; out of scope here.)
  if (relativePath.startsWith('assets/assets/test/')) return true;

  // Debug artefacts, never fetched by the app.
  if (relativePath.endsWith('.symbols')) return true;
  if (relativePath.endsWith('.map')) return true;

  return false;
}

/// Classifies every file under [buildDir] and hashes the included ones.
///
/// Throws a [StateError] when `sw.js` is missing (the build did not copy
/// `web/sw.js`, so nothing downstream would work) or when the precache would
/// exceed [precacheCeilingBytes].
ShellManifest buildShellManifest(Directory buildDir) {
  if (!buildDir.existsSync()) {
    throw StateError('build directory not found: ${buildDir.path}');
  }
  final swFile = File(p.join(buildDir.path, 'sw.js'));
  if (!swFile.existsSync()) {
    throw StateError(
      'no sw.js in ${buildDir.path} — `flutter build web` copies web/sw.js '
      'verbatim, so this means web/sw.js is missing from the repo.',
    );
  }

  final urls = <String>[];
  var totalBytes = 0;
  for (final entity in buildDir.listSync(recursive: true)) {
    if (entity is! File) continue;
    final relative =
        p.relative(entity.path, from: buildDir.path).replaceAll(r'\', '/');
    if (isPrecacheExcluded(relative)) continue;
    urls.add(relative);
    totalBytes += entity.lengthSync();
  }
  urls.sort();

  if (totalBytes > precacheCeilingBytes) {
    throw StateError(
      'precache is $totalBytes bytes, over the '
      '$precacheCeilingBytes-byte ceiling. Either something large started '
      'being emitted (check `du -sh ${buildDir.path}/*`) or the ceiling '
      'needs a deliberate, reviewed increase — do not raise it silently.',
    );
  }

  // FNV-1a 64, folded over path bytes and file bytes in sorted order.
  var hash = 0xcbf29ce484222325;
  const prime = 0x100000001b3;
  void fold(List<int> bytes) {
    for (final byte in bytes) {
      hash ^= byte;
      // Dart ints are 64-bit two's complement, so the multiply already wraps
      // mod 2^64 — exactly FNV's defined behaviour. No mask is applied here:
      // `& 0xFFFFFFFFFFFFFFFF` would be a no-op anyway, because that literal
      // IS -1 as a signed 64-bit int.
      hash = hash * prime;
    }
  }

  for (final url in urls) {
    fold(utf8.encode(url));
    fold(const [0]);
    fold(File(p.join(buildDir.path, url)).readAsBytesSync());
    fold(const [0]);
  }

  return ShellManifest(
    version: formatShellVersion(hash),
    urls: urls,
    totalBytes: totalBytes,
  );
}

/// Renders a 64-bit FNV hash as exactly 16 lowercase hex characters.
///
/// NOT `hash.toRadixString(16).padLeft(16, '0')`. Dart ints are 64-bit
/// SIGNED, so a hash with its top bit set is a negative int, and
/// `toRadixString` renders that as a MINUS SIGN followed by the magnitude —
/// `-208049a153bacd51`, 17 characters. `padLeft` then does nothing because the
/// string is already too long. Roughly half of all builds would ship a version
/// like that: it still round-trips through the stamp regexes and still rolls
/// over correctly, but it is not the documented 16-hex value, it leaks a `-`
/// into the `masi-shell-<version>` cache name, and it is exactly the kind of
/// detail that later gets "tidied up" into a real bug.
///
/// `int.toUnsigned(64)` does not help either — it is defined as
/// `this & ((1 << 64) - 1)`, and `(1 << 64) - 1` is itself -1 here, so it
/// returns the value unchanged. Splitting into two 32-bit halves is the
/// reliable way to get the unsigned rendering.
String formatShellVersion(int hash) {
  final high = (hash >> 32) & 0xFFFFFFFF;
  final low = hash & 0xFFFFFFFF;
  return high.toRadixString(16).padLeft(8, '0') +
      low.toRadixString(16).padLeft(8, '0');
}

final _versionLine =
    RegExp(r"^const SHELL_VERSION = '[^']*';$", multiLine: true);
final _precacheLine = RegExp(r'^const PRECACHE = \[[^\]]*\];$', multiLine: true);

/// Rewrites the two stamp lines in `<buildDir>/sw.js`, in place.
void stampServiceWorker(Directory buildDir, ShellManifest manifest) {
  final swFile = File(p.join(buildDir.path, 'sw.js'));
  final source = swFile.readAsStringSync();

  final withVersion = _replaceExactlyOnce(
    source,
    _versionLine,
    "const SHELL_VERSION = '${manifest.version}';",
    'SHELL_VERSION',
  );
  final stamped = _replaceExactlyOnce(
    withVersion,
    _precacheLine,
    'const PRECACHE = ${jsonEncode(manifest.urls)};',
    'PRECACHE',
  );

  swFile.writeAsStringSync(stamped);
}

String _replaceExactlyOnce(
  String source,
  RegExp pattern,
  String replacement,
  String label,
) {
  final matches = pattern.allMatches(source).toList();
  if (matches.length != 1) {
    throw StateError(
      'expected exactly one $label stamp line in sw.js, found '
      '${matches.length}. The stamp lines must stay on one line each and '
      'keep their exact shape — see the BUILD STAMP block in web/sw.js.',
    );
  }
  return source.replaceRange(
    matches.single.start,
    matches.single.end,
    replacement,
  );
}

void main(List<String> args) {
  final buildDir = Directory(args.isEmpty ? 'build/web' : args.first);
  final ShellManifest manifest;
  try {
    manifest = buildShellManifest(buildDir);
  } on StateError catch (error) {
    stderr.writeln('FAIL: ${error.message}');
    exitCode = 1;
    return;
  }
  try {
    stampServiceWorker(buildDir, manifest);
  } on StateError catch (error) {
    stderr.writeln('FAIL: ${error.message}');
    exitCode = 1;
    return;
  }
  stdout.writeln(
    '    ok: sw.js stamped — version=${manifest.version} '
    'files=${manifest.urls.length} bytes=${manifest.totalBytes}',
  );
}
