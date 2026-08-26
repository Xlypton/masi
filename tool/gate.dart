// gate.dart — ONE command that runs everything that must be green, anywhere.
//
// WHY THIS EXISTS.
//
// The gates were real and well-designed, but they were spread across four
// invocations documented in three places (CLAUDE.md, the `e2e-verify` skill,
// the `deploy-web` skill), several of them written as macOS shell with a
// `export PATH="/opt/homebrew/bin:$PATH"` prefix. An agent picking this repo up
// on a different machine had to reconstruct the checklist from prose before it
// could find out whether it had broken anything — and a checklist you have to
// reconstruct is one you eventually run only part of.
//
// So: one entry point, pure Dart, no bash, no `grep`, no PATH ritual. It runs
// on every platform a Flutter SDK runs on, which is the property that matters
// for a project worked by agents on machines nobody chose in advance.
//
//   dart run tool/gate.dart              # everything (analyze + test + guards)
//   dart run tool/gate.dart --skip-tests # the fast guards only (~15s)
//   dart run tool/gate.dart --json       # machine-readable verdict
//   dart run tool/gate.dart --only=secrets,dart-io
//
// Exit code is 0 only if every check that RAN passed.
//
// WHAT IT DOES NOT DO, on purpose: the signed-in E2E suite. That one seeds and
// mutates the live dev database, needs chromedriver, and takes 5–15 minutes —
// it is the third gate and it has its own skill (`e2e-verify`) precisely
// because it needs a human-or-agent decision about live data first. Folding it
// in here would make the cheap gate expensive and the dangerous gate automatic,
// which is exactly backwards. This prints a reminder instead.
import 'dart:convert';
import 'dart:io';

/// The result of one check.
class _Result {
  _Result(this.name, this.ok, this.detail, this.elapsed, {this.skipped = false});

  final String name;
  final bool ok;
  final String detail;
  final Duration elapsed;
  final bool skipped;

  Map<String, dynamic> toJson() => {
        'check': name,
        'status': skipped
            ? 'skipped'
            : ok
                ? 'pass'
                : 'fail',
        'detail': detail,
        'seconds': elapsed.inMilliseconds / 1000,
      };
}

/// Runs an external command, streaming nothing, returning (exitCode, output).
///
/// `runInShell` is not optional on Windows: the Flutter and Dart entry points
/// on PATH there are `flutter.bat` / `dart.bat`, and a bare `Process.run` does
/// not apply PATHEXT — it fails with "The system cannot find the file
/// specified", which reads exactly like "Flutter is not installed" and sends
/// the reader off debugging their toolchain instead of their code.
Future<(int, String)> _exec(String exe, List<String> args) async {
  final r = await Process.run(exe, args, runInShell: true);
  return (r.exitCode, '${r.stdout}${r.stderr}');
}

// ---------------------------------------------------------------------------
// Check: no `dart:io` outside *_native.dart
// ---------------------------------------------------------------------------

/// Matches an `import`/`export` DIRECTIVE for `dart:io`, and nothing else.
///
/// Deliberately NOT a substring search for `dart:io`. That form returns ~43
/// hits on a clean tree, because the conditional-import seam files' own doc
/// comments name `dart:io` while explaining the split — and that false-positive
/// shape is what used to keep this gate red on code that was already correct,
/// which is the fastest way to teach everyone to ignore a gate.
///
/// Kept semantically identical to the POSIX ERE in `tool/build_web.sh` and
/// `.github/workflows/ci.yml`; `test/tool/dart_io_gate_test.dart` pins all
/// three against the same fixtures so they cannot drift apart.
final RegExp dartIoDirective = RegExp(
  r'''^[ \t]*(import|export)[ \t]+['"]dart:io['"]''',
  multiLine: true,
);

/// Files under [libDir] that import or export `dart:io` without being a
/// `_native.dart` seam file.
///
/// `dart:io` on web COMPILES — Dart 3.12 stubs the library and throws at
/// RUNTIME — so this is a runtime-correctness guardrail, not a compile gate.
/// A screen importing it builds and boots on web fine and then throws the
/// moment a `File(...)` call is actually reached, e.g. while rendering a photo.
List<String> dartIoOffenders(Directory libDir) {
  if (!libDir.existsSync()) return const [];
  final offenders = <String>[];
  for (final entity in libDir.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    if (entity.path.endsWith('_native.dart')) continue;
    final String text;
    try {
      text = entity.readAsStringSync();
    } on FileSystemException {
      continue;
    }
    if (dartIoDirective.hasMatch(text)) {
      offenders.add(entity.path.replaceAll(r'\', '/'));
    }
  }
  offenders.sort();
  return offenders;
}

Future<_Result> _checkDartIo() async {
  final sw = Stopwatch()..start();
  final offenders = dartIoOffenders(Directory('lib'));
  sw.stop();
  return _Result(
    'dart-io',
    offenders.isEmpty,
    offenders.isEmpty
        ? 'no dart:io import/export outside *_native.dart'
        : 'dart:io outside *_native.dart:\n      ${offenders.join('\n      ')}',
    sw.elapsed,
  );
}

// ---------------------------------------------------------------------------
// Check: drift/sqlite3 WASM assets present and matching the lockfile
// ---------------------------------------------------------------------------

/// A stale `sqlite3.wasm` is silent data-layer breakage on web: the build
/// succeeds, the app boots, and drift talks to a worker built against a
/// different version of itself.
Future<_Result> _checkWebAssets() async {
  final sw = Stopwatch()..start();
  final wasm = File('web/sqlite3.wasm');
  final worker = File('web/drift_worker.js');
  if (!wasm.existsSync() || !worker.existsSync()) {
    sw.stop();
    return _Result('web-assets', false,
        'web/sqlite3.wasm and/or web/drift_worker.js is missing', sw.elapsed);
  }

  final pinFile = File('web/.drift_asset_versions');
  final lock = File('pubspec.lock');
  if (!pinFile.existsSync() || !lock.existsSync()) {
    sw.stop();
    return _Result('web-assets', true,
        'assets present (no version pin to compare against)', sw.elapsed);
  }

  final pinned = pinFile.readAsStringSync().replaceFirst('drift', '').trim();
  // `  drift:` … `    version: "2.34.2"` a few lines below it.
  final lockText = lock.readAsStringSync();
  final idx = lockText.indexOf('\n  drift:');
  String lockVersion = 'unknown';
  if (idx >= 0) {
    final m = RegExp(r'version:\s*"?([^"\s]+)"?')
        .firstMatch(lockText.substring(idx, idx + 400));
    if (m != null) lockVersion = m.group(1)!;
  }
  sw.stop();
  final ok = pinned.isEmpty || lockVersion == 'unknown' || pinned == lockVersion;
  return _Result(
    'web-assets',
    ok,
    ok
        ? 'assets match drift $lockVersion'
        : 'pubspec.lock has drift $lockVersion but web/ assets are pinned to '
            '$pinned — refresh them (see tool/build_web.sh)',
    sw.elapsed,
  );
}

// ---------------------------------------------------------------------------
// Check: no credentials in the tree
// ---------------------------------------------------------------------------

Future<_Result> _checkSecrets() async {
  final sw = Stopwatch()..start();
  final (code, out) = await _exec('dart', ['tool/scan_secrets.dart', '--all']);
  sw.stop();
  return _Result(
    'secrets',
    code == 0,
    code == 0
        ? 'no credentials in any tracked file'
        : out.trim().split('\n').take(30).join('\n      '),
    sw.elapsed,
  );
}

// ---------------------------------------------------------------------------
// Checks: analyze + test
// ---------------------------------------------------------------------------

Future<_Result> _checkAnalyze() async {
  final sw = Stopwatch()..start();
  final (code, out) = await _exec('flutter', ['analyze']);
  sw.stop();
  return _Result(
    'analyze',
    code == 0,
    code == 0
        ? 'no issues'
        : out.trim().split('\n').take(40).join('\n      '),
    sw.elapsed,
  );
}

Future<_Result> _checkTests() async {
  final sw = Stopwatch()..start();
  // Goldens are excluded for the same reason CI excludes them: their masters
  // were rendered on macOS and `matchesGoldenFile` compares byte-exactly, so
  // font rasterization on any other host fails them. See dart_test.yaml.
  final (code, out) = await _exec(
    'flutter',
    ['test', '--exclude-tags', 'golden'],
  );
  sw.stop();

  final lines = out.trim().split('\n');
  final summary = lines.lastWhere(
    (l) => l.contains('All tests passed') || l.contains('Some tests failed'),
    orElse: () => lines.isEmpty ? '' : lines.last,
  );
  final failing = [
    for (final l in lines)
      if (l.trimLeft().startsWith('C:/') ||
          (l.contains('_test.dart:') && l.trimLeft().startsWith('/')))
        l.trim(),
  ];

  return _Result(
    'test',
    code == 0,
    code == 0
        ? summary.trim()
        : '${summary.trim()}\n      '
            '${failing.take(20).join('\n      ')}',
    sw.elapsed,
  );
}

// ---------------------------------------------------------------------------

Future<void> main(List<String> argv) async {
  final json = argv.contains('--json');
  final skipTests = argv.contains('--skip-tests');
  final onlyArg = argv.firstWhere(
    (a) => a.startsWith('--only='),
    orElse: () => '',
  );
  final only = onlyArg.isEmpty
      ? const <String>{}
      : onlyArg.substring('--only='.length).split(',').toSet();

  if (!Directory('lib').existsSync() || !File('pubspec.yaml').existsSync()) {
    stderr.writeln('gate: run me from the repo root (no lib/ or pubspec.yaml '
        'in ${Directory.current.path})');
    exit(2);
  }

  // Ordered cheapest-first so a broken tree reports in seconds rather than
  // after a five-minute test run. Each is independent — nothing here depends on
  // an earlier check having passed — so a failure never hides a later one.
  final checks = <String, Future<_Result> Function()>{
    'dart-io': _checkDartIo,
    'web-assets': _checkWebAssets,
    'secrets': _checkSecrets,
    'analyze': _checkAnalyze,
    'test': _checkTests,
  };

  final results = <_Result>[];
  for (final entry in checks.entries) {
    final selected = only.isEmpty || only.contains(entry.key);
    final skipped = !selected || (entry.key == 'test' && skipTests);
    if (skipped) {
      results.add(_Result(
        entry.key,
        true,
        !selected ? 'not selected by --only' : 'skipped by --skip-tests',
        Duration.zero,
        skipped: true,
      ));
      continue;
    }
    if (!json) stdout.writeln('==> ${entry.key}');
    final result = await entry.value();
    results.add(result);
    if (!json) {
      stdout.writeln('    ${result.ok ? 'ok' : 'FAIL'}: ${result.detail}');
    }
  }

  final failed = results.where((r) => !r.skipped && !r.ok).toList();

  if (json) {
    stdout.writeln(const JsonEncoder.withIndent('  ').convert({
      'ok': failed.isEmpty,
      'checks': [for (final r in results) r.toJson()],
      'note': 'the signed-in E2E suite is NOT part of this gate — see the '
          'e2e-verify skill. It mutates the live dev database.',
    }));
    exit(failed.isEmpty ? 0 : 1);
  }

  stdout.writeln('');
  for (final r in results) {
    final status = r.skipped
        ? 'skip'
        : r.ok
            ? 'pass'
            : 'FAIL';
    stdout.writeln('  ${status.padRight(5)} ${r.name.padRight(12)} '
        '${r.skipped ? '' : '${(r.elapsed.inMilliseconds / 1000).toStringAsFixed(1)}s'}');
  }
  stdout.writeln('');

  if (failed.isEmpty) {
    stdout.writeln('GATE PASS (gates 1 and 2).');
    stdout.writeln('');
    stdout.writeln('Gate 3 is NOT covered here: if this change touched app '
        'behaviour, UI, routing,');
    stdout.writeln('the data layer, or anything server-gated, run the '
        '`e2e-verify` skill before');
    stdout.writeln('calling it done. It seeds and mutates the LIVE dev '
        'database, which is why it');
    stdout.writeln('is a deliberate decision and not an automatic step.');
    exit(0);
  }

  stdout.writeln('GATE FAIL: ${failed.map((f) => f.name).join(', ')}');
  exit(1);
}
