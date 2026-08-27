// preflight_chromedriver.dart — fail EARLY and legibly when the browser
// automation stack cannot possibly work.
//
// WHY: `chromedriver` refuses to open a session unless its MAJOR version
// matches the Chrome it is driving. Without a preflight that mismatch surfaces
// from deep inside `flutter drive`, minutes in, as a WebDriver handshake error
// or — worse — as a run that simply hangs until the outer timeout. The two
// existing entry points both had a blind spot here:
//
//   * `tool/drive_web.sh` checked only that a chromedriver binary EXISTS;
//   * `tool/drive_e2e.sh` checked nothing at all — it assumes something is
//     already listening on 4444 and goes straight to `flutter drive`.
//
// This was not hypothetical when it was written: the Windows dev box had
// ChromeDriver 150 against Chrome 151, so every E2E run on that machine was
// going to fail in a way whose message said nothing about versions.
//
// Dart rather than bash so it is the SAME check on both dev machines and in
// CI — finding the Chrome binary is the platform-specific part, and doing that
// twice in two shells is how the two copies drift.
//
//   dart run tool/preflight_chromedriver.dart          # human-readable
//   dart run tool/preflight_chromedriver.dart --json
//
// Exit codes: 0 usable · 1 mismatch or missing · 2 could not determine.
import 'dart:convert';
import 'dart:io';

/// First `\d+.\d+.\d+.\d+`-ish version number in [text], or null.
String? _version(String text) =>
    RegExp(r'\b(\d+\.\d+\.\d+(?:\.\d+)?)\b').firstMatch(text)?.group(1);

int? _major(String? version) =>
    version == null ? null : int.tryParse(version.split('.').first);

/// `runInShell` on every call: on Windows the useful entry points are `.bat`/
/// `.cmd` shims that a bare `Process.run` will not resolve through PATHEXT.
Future<String?> _probe(String exe, List<String> args) async {
  try {
    final r = await Process.run(exe, args, runInShell: true);
    if (r.exitCode != 0) return null;
    return _version('${r.stdout}${r.stderr}');
  } on ProcessException {
    return null;
  }
}

/// Where Chrome might be, in the order worth trying.
///
/// `CHROME_EXECUTABLE` first because that is the variable `flutter drive`
/// itself honours — if it is set, that IS the browser the run will use, and
/// checking any other copy would validate the wrong binary.
Future<(String source, String version)?> _chromeVersion() async {
  final explicit = Platform.environment['CHROME_EXECUTABLE'];
  if (explicit != null && explicit.isNotEmpty && File(explicit).existsSync()) {
    final v = await _fileVersion(explicit) ?? await _probe(explicit, ['--version']);
    if (v != null) return ('CHROME_EXECUTABLE ($explicit)', v);
  }

  if (Platform.isWindows) {
    for (final path in [
      r'C:\Program Files\Google\Chrome\Application\chrome.exe',
      r'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
    ]) {
      if (!File(path).existsSync()) continue;
      final v = await _fileVersion(path);
      if (v != null) return (path, v);
    }
    return null;
  }

  for (final candidate in const [
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    'google-chrome',
    'google-chrome-stable',
    'chromium',
  ]) {
    final v = await _probe(candidate, ['--version']);
    if (v != null) return (candidate, v);
  }
  return null;
}

/// Chrome on Windows does NOT print a version to stdout for `--version` — it
/// launches the browser instead. The file's own version resource is the only
/// reliable answer there, so it is read via PowerShell.
Future<String?> _fileVersion(String path) async {
  if (!Platform.isWindows) return null;
  try {
    final r = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      '(Get-Item -LiteralPath "$path").VersionInfo.ProductVersion',
    ]);
    if (r.exitCode != 0) return null;
    return _version(r.stdout.toString());
  } on ProcessException {
    return null;
  }
}

Future<void> main(List<String> argv) async {
  final json = argv.contains('--json');

  final driverVersion = await _probe('chromedriver', ['--version']);
  final chrome = await _chromeVersion();

  final driverMajor = _major(driverVersion);
  final chromeMajor = _major(chrome?.$2);

  String verdict;
  int code;
  String advice = '';

  if (driverVersion == null) {
    verdict = 'chromedriver not found on PATH (or it would not report a '
        'version).';
    code = 1;
    advice = Platform.isWindows
        ? 'Install a chromedriver whose MAJOR matches Chrome from '
            'https://googlechromelabs.github.io/chrome-for-testing/ and put it '
            'on PATH (this machine keeps it at C:\\tools\\chromedriver.exe).'
        : 'Install via Chrome for Testing and place it on PATH '
            '(/opt/homebrew/bin on the macOS box).';
  } else if (chrome == null || chromeMajor == null) {
    // Not fatal on its own: a CI image may have a browser this cannot see.
    // Saying so beats asserting a match that was never checked.
    verdict = 'chromedriver $driverVersion found, but no Chrome could be '
        'located to compare it against.';
    code = 2;
    advice = 'Set CHROME_EXECUTABLE to the browser `flutter drive` will use.';
  } else if (driverMajor != chromeMajor) {
    verdict = 'VERSION MISMATCH: chromedriver $driverVersion (major '
        '$driverMajor) cannot drive Chrome ${chrome.$2} (major $chromeMajor).';
    code = 1;
    advice = 'chromedriver refuses a session across a major-version gap, and '
        '`flutter drive` reports that as a handshake failure or an unexplained '
        'hang — nothing that names the versions. Fix by installing '
        'chromedriver $chromeMajor from '
        'https://googlechromelabs.github.io/chrome-for-testing/, or by '
        'pinning a matching Chrome for Testing build and pointing '
        'CHROME_EXECUTABLE at it.';
  } else {
    verdict = 'ok: chromedriver $driverVersion matches Chrome ${chrome.$2} '
        '(major $chromeMajor), from ${chrome.$1}';
    code = 0;
  }

  if (json) {
    stdout.writeln(const JsonEncoder.withIndent('  ').convert({
      'ok': code == 0,
      'chromedriverVersion': driverVersion,
      'chromeVersion': chrome?.$2,
      'chromeSource': chrome?.$1,
      'verdict': verdict,
      'advice': advice,
    }));
    exit(code);
  }

  if (code == 0) {
    stdout.writeln('    $verdict');
    exit(0);
  }
  stderr.writeln('FAIL: $verdict');
  if (advice.isNotEmpty) stderr.writeln('      $advice');
  exit(code);
}
