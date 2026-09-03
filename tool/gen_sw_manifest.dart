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
// way no test could see. The things that must stay OUT of the atomic precache
// are large, enumerable and stable, so they are the ones spelled out.
//
// Four lines are stamped, not two: `SHELL_VERSION`, the atomic `PRECACHE`, and
// then `PRECACHE_WASM`/`PRECACHE_JS` — the two renderer bundles, of which a
// browser runs exactly one. Those two are named here but fetched best-effort
// by `sw.js` at install, never added atomically; see `isPrecacheExcluded`.
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
    required this.wasmRenderer,
    required this.jsRenderer,
    required this.rendererBytes,
  });

  /// 16 lowercase hex chars derived from every precached file's path AND
  /// bytes — plus both renderer bundles, which are NOT in [urls]. See
  /// [buildShellManifest] for why they still have to be hashed. Changing any
  /// of them changes this, which changes `sw.js`, which is what makes the
  /// browser treat the worker as updated.
  final String version;

  /// Scope-relative URLs, sorted, forward-slashed. The ATOMIC precache — what
  /// `sw.js`'s install handler passes to `cache.addAll`.
  final List<String> urls;

  final int totalBytes;

  /// The dart2wasm renderer artifacts this build emitted, sorted, or empty on
  /// a `--js` build. Stamped into `sw.js` as `PRECACHE_WASM`; fetched
  /// best-effort at install, by the clients that can actually run them.
  final List<String> wasmRenderer;

  /// The dart2js renderer artifacts, sorted. Stamped as `PRECACHE_JS`.
  final List<String> jsRenderer;

  /// Bytes of the LARGER of the two renderer bundles — the worst case a
  /// single client downloads at install time on top of [totalBytes]. Never
  /// their sum: no browser fetches both (see [isRendererArtifact]).
  final int rendererBytes;
}

/// The dart2wasm renderer bundle: the compiled Dart program plus the JS module
/// that instantiates it.
const wasmRendererArtifacts = <String>['main.dart.wasm', 'main.dart.mjs'];

/// The dart2js renderer bundle's ENTRYPOINT. A `--wasm` build emits this TOO,
/// as the fallback for browsers Flutter's loader will not hand WasmGC — which
/// is all of WebKit, i.e. every browser on iOS.
///
/// Deferred part files are matched separately by [isJsDeferredPart], not
/// listed here: their names are decided by dart2js and change with the
/// deferred-import graph, so an exact-name list cannot see them.
const jsRendererArtifacts = <String>['main.dart.js'];

/// Whether [relativePath] is a dart2js DEFERRED PART file — the chunks emitted
/// for each `deferred as` import (`main.dart.js_1.part.js` and friends).
///
/// These belong to the dart2js bundle exactly as much as `main.dart.js` does,
/// and the classification matters in a way that is easy to get backwards.
/// Renderer artifacts are excluded from the ATOMIC precache and fetched
/// best-effort per client instead (see [isPrecacheExcluded]). A part file that
/// is NOT recognised as one therefore falls through to the ordinary app-asset
/// branch and is precached ATOMICALLY, FOR EVERY CLIENT — including every
/// blink client, which runs dart2wasm and will never load a single byte of it.
/// That would hand the whole point of deferring these features back: a smaller
/// initial download for iOS, paid for by an install-time download of the same
/// code for everyone else, inside the one add that must not fail.
///
/// dart2wasm emits no part files at all, because Flutter's `build web` never
/// passes it `--enable-deferred-loading` — so this predicate is about the
/// dart2js half of a `--wasm` build, and matches nothing in a wasm-only one.
bool isJsDeferredPart(String relativePath) =>
    RegExp(r'^main\.dart\.js_[0-9]+\.part\.js$').hasMatch(relativePath);

/// Whether [relativePath] is part of a renderer bundle — an artifact only ONE
/// kind of browser can execute.
bool isRendererArtifact(String relativePath) =>
    wasmRendererArtifacts.contains(relativePath) ||
    jsRendererArtifacts.contains(relativePath) ||
    isJsDeferredPart(relativePath);

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

  // BOTH renderer bundles — not just the dart2js one. A `--wasm` build emits
  // dart2wasm (`main.dart.wasm` + `main.dart.mjs`, ~4.2 MB) AND the dart2js
  // fallback (`main.dart.js`, ~4.2 MB), and every browser executes exactly
  // ONE of them: blink takes dart2wasm, everything WebKit — i.e. every browser
  // on iOS, which is this app's primary target — takes dart2js.
  //
  // Only `main.dart.js` used to be excluded here, so the atomic precache still
  // carried the dart2wasm pair and every iPhone visitor downloaded ~4.2 MB it
  // can never run, on the first visit and again after every deploy: roughly
  // 70% of the precache, competing for bandwidth with the canvaskit bundle it
  // actually needs and for origin quota with the user's photos.
  //
  // They are not dropped, only MOVED: `stampServiceWorker` writes both sets
  // into `sw.js` as `PRECACHE_WASM`/`PRECACHE_JS`, and `rendererArtifacts()`
  // there feeds the one the client actually needs to the same best-effort
  // `cacheMissing()` path that already handles `canvaskit/`. Best-effort and
  // deliberately NOT `addAll`: an atomic add that fails aborts the install, and
  // an aborted install strands the user on the previous build — a far worse
  // outcome on a flaky link than one offline cold start.
  if (isRendererArtifact(relativePath)) return true;

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
  final wasmRenderer = <String>[];
  final jsRenderer = <String>[];
  var totalBytes = 0;
  var wasmRendererBytes = 0;
  var jsRendererBytes = 0;
  for (final entity in buildDir.listSync(recursive: true)) {
    if (entity is! File) continue;
    final relative =
        p.relative(entity.path, from: buildDir.path).replaceAll(r'\', '/');
    // The two renderer branches come BEFORE `isPrecacheExcluded`, which now
    // excludes them from the atomic set — they are collected here rather than
    // discarded, because `sw.js` still has to be told their names.
    if (wasmRendererArtifacts.contains(relative)) {
      wasmRenderer.add(relative);
      wasmRendererBytes += entity.lengthSync();
      continue;
    }
    // `main.dart.js` AND its deferred part files — see [isJsDeferredPart] for
    // why a part file that misses this branch is worse than one that is never
    // emitted at all.
    if (jsRendererArtifacts.contains(relative) || isJsDeferredPart(relative)) {
      jsRenderer.add(relative);
      jsRendererBytes += entity.lengthSync();
      continue;
    }
    if (isPrecacheExcluded(relative)) continue;
    urls.add(relative);
    totalBytes += entity.lengthSync();
  }
  urls.sort();
  wasmRenderer.sort();
  jsRenderer.sort();

  // The ceiling bounds what ONE CLIENT downloads at install time, which is the
  // atomic precache plus exactly one renderer bundle — never both. Counting
  // the larger of the two keeps that a worst case now that the renderer bytes
  // have left `urls`; without it, moving ~4.2 MB out of the atomic set would
  // have silently bought 4.2 MB of slack in a guard whose entire job is to
  // make a size regression loud.
  final rendererBytes =
      wasmRendererBytes > jsRendererBytes ? wasmRendererBytes : jsRendererBytes;
  final installBytes = totalBytes + rendererBytes;
  if (installBytes > precacheCeilingBytes) {
    throw StateError(
      'install download is $installBytes bytes ($totalBytes precache + '
      '$rendererBytes for the larger renderer bundle), over the '
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

  // The renderer artifacts are hashed even though they are NOT in `urls`, and
  // that is load-bearing rather than tidy: `SHELL_VERSION` names the cache and
  // is the only reason the browser sees a CHANGED worker at all, while
  // `main.dart.wasm`/`main.dart.js` are the files that change on every single
  // Dart edit. Hash `urls` alone and a pure-Dart change leaves `sw.js`
  // byte-identical — no worker update, no cache rollover, and last build's
  // renderer served out of the previous cache indefinitely.
  final hashed = <String>[...urls, ...wasmRenderer, ...jsRenderer]..sort();
  for (final url in hashed) {
    fold(utf8.encode(url));
    fold(const [0]);
    fold(File(p.join(buildDir.path, url)).readAsBytesSync());
    fold(const [0]);
  }

  return ShellManifest(
    version: formatShellVersion(hash),
    urls: urls,
    totalBytes: totalBytes,
    wasmRenderer: wasmRenderer,
    jsRenderer: jsRenderer,
    rendererBytes: rendererBytes,
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
// The three list stamps are matched by DISTINCT patterns rather than one
// parameterised `PRECACHE\w*` — `^const PRECACHE = ` cannot match
// `const PRECACHE_WASM = `, which is what keeps `_replaceExactlyOnce`'s
// "exactly one match" contract meaningful for each of them. The same property
// is what keeps `tool/verify_offline_shell.py`'s `^const PRECACHE = (\[.*\]);$`
// reader pointed at the atomic set and not at a renderer list.
final _precacheLine = RegExp(r'^const PRECACHE = \[[^\]]*\];$', multiLine: true);
final _precacheWasmLine =
    RegExp(r'^const PRECACHE_WASM = \[[^\]]*\];$', multiLine: true);
final _precacheJsLine =
    RegExp(r'^const PRECACHE_JS = \[[^\]]*\];$', multiLine: true);

/// Rewrites the four stamp lines in `<buildDir>/sw.js`, in place.
void stampServiceWorker(Directory buildDir, ShellManifest manifest) {
  final swFile = File(p.join(buildDir.path, 'sw.js'));
  var source = swFile.readAsStringSync();

  source = _replaceExactlyOnce(
    source,
    _versionLine,
    "const SHELL_VERSION = '${manifest.version}';",
    'SHELL_VERSION',
  );
  source = _replaceExactlyOnce(
    source,
    _precacheLine,
    'const PRECACHE = ${jsonEncode(manifest.urls)};',
    'PRECACHE',
  );
  source = _replaceExactlyOnce(
    source,
    _precacheWasmLine,
    'const PRECACHE_WASM = ${jsonEncode(manifest.wasmRenderer)};',
    'PRECACHE_WASM',
  );
  source = _replaceExactlyOnce(
    source,
    _precacheJsLine,
    'const PRECACHE_JS = ${jsonEncode(manifest.jsRenderer)};',
    'PRECACHE_JS',
  );

  swFile.writeAsStringSync(source);
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
    'files=${manifest.urls.length} bytes=${manifest.totalBytes} '
    'renderer=wasm${manifest.wasmRenderer.length}/js'
    '${manifest.jsRenderer.length} (+${manifest.rendererBytes} bytes '
    'best-effort, one bundle per client)',
  );
}
