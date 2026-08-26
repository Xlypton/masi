// scan_secrets.dart — refuse to let a credential leave this machine.
//
// WHY THIS EXISTS, and why it is a gate rather than a guideline.
//
// CLAUDE.md makes `git push` the DEFAULT for every agent working this repo,
// and it lists five real credentials that live in plain files on the dev box
// (`~/.config/climbtopo-mgmt-token`, `cf-pages-token`, `masi-e2e-password`,
// `masi-push-hook-secret`, `masi-vapid-private`). Those two facts multiply:
// pushing PUBLISHES, so a secret that reaches a commit is on GitHub the moment
// the branch goes up, and rewriting history does not un-publish it. The window
// between "staged by mistake" and "public" used to be a single command with
// nothing watching it.
//
// A rule in a doc does not close that window, because the failure is never a
// decision — it is `git add -A` sweeping up a debug file someone pasted a token
// into. Only something that runs unattended, on every commit and in CI, does.
//
// WHAT IT CHECKS — three layers, because each catches what the others cannot:
//
//   1. SHAPES. Regexes for credential formats this project and its vendors
//      actually issue. Catches a secret from any source, including one this
//      machine has never seen.
//   2. THIS MACHINE'S ACTUAL SECRET VALUES. The five files above are read and
//      their contents searched for literally. Catches a leak whose SHAPE is
//      unremarkable — the E2E password is just a random string, and no regex
//      can distinguish it from a test fixture. This is the layer that matters
//      most here, and it is only possible because the scanner runs on the
//      machine that holds the secrets.
//   3. PATHS. A file whose NAME says it is a credential store, regardless of
//      what is inside it.
//
// The scanner never prints a secret, not even the one it just caught: output
// names the rule and the location, and any excerpt is redacted. A gate that
// echoes the credential into CI logs has published it a second way.
//
// USAGE
//   dart run tool/scan_secrets.dart                 # staged changes (pre-commit)
//   dart run tool/scan_secrets.dart --range a..b    # a commit range (CI)
//   dart run tool/scan_secrets.dart --all           # every tracked file
//   dart run tool/scan_secrets.dart --json          # machine-readable findings
//
// Exit codes: 0 clean · 1 findings · 2 could not run (not a repo, git missing).
import 'dart:convert';
import 'dart:io';

/// A credential format worth refusing on sight.
class _Shape {
  const _Shape(this.name, this.pattern, this.why);

  final String name;
  final RegExp pattern;
  final String why;
}

final List<_Shape> _shapes = [
  _Shape(
    'supabase-management-token',
    RegExp(r'\bsbp_[A-Za-z0-9]{20,}\b'),
    'Supabase personal access token — full admin over the live project, '
        'including DDL and every user row.',
  ),
  _Shape(
    'supabase-secret-key',
    // `sb_publishable_…` is the anon key and is COMMITTED ON PURPOSE (see
    // lib/core/config/supabase_config.dart). Only its privileged sibling is
    // matched, so this rule cannot fire on the legitimate one.
    RegExp(r'\bsb_secret_[A-Za-z0-9_\-]{16,}\b'),
    'Supabase secret key — bypasses RLS entirely.',
  ),
  _Shape(
    'service-role-jwt',
    RegExp(r'"role"\s*:\s*"service_role"'),
    'A decoded service_role JWT payload. This key ignores every RLS policy.',
  ),
  _Shape(
    'private-key-block',
    RegExp(r'-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----'),
    'A PEM private key block.',
  ),
  _Shape(
    'github-token',
    RegExp(r'\b(?:ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})\b'),
    'A GitHub personal access token.',
  ),
  _Shape(
    'aws-access-key',
    RegExp(r'\bAKIA[0-9A-Z]{16}\b'),
    'An AWS access key id.',
  ),
  _Shape(
    'cloudflare-api-token',
    // Cloudflare tokens are 40 chars of base64url with no fixed prefix, so this
    // is anchored on an ASSIGNMENT to a Cloudflare-named variable rather than
    // on the value alone — matching the bare shape would flag every hash in the
    // repo. Layer 2 catches this machine's actual token regardless.
    RegExp(
      r'''\bCLOUDFLARE_API_TOKEN\b\s*[=:]\s*['"]?[A-Za-z0-9_\-]{30,}''',
      caseSensitive: false,
    ),
    'A Cloudflare API token assigned inline instead of read from '
        '~/.config/cf-pages-token.',
  ),
];

/// Files whose NAME alone means they must never be committed.
final List<RegExp> _forbiddenPaths = [
  RegExp(r'(^|/)\.env(\.|$)'),
  RegExp(r'(^|/)climbtopo-mgmt-token$'),
  RegExp(r'(^|/)cf-pages-token$'),
  RegExp(r'(^|/)masi-e2e-password$'),
  RegExp(r'(^|/)masi-push-hook-secret$'),
  RegExp(r'(^|/)masi-vapid-private$'),
  RegExp(r'(^|/)id_(rsa|dsa|ecdsa|ed25519)$'),
  RegExp(r'\.(pem|p12|pfx|keystore|jks)$'),
];

/// The credential files CLAUDE.md says live on a Masi dev machine, relative to
/// the user's home directory.
///
/// Layer 2 reads these and searches for their contents verbatim. Absent files
/// are skipped silently — a CI runner has none of them, and that is not a
/// failure, it just means CI runs with layers 1 and 3 only.
const List<String> _localSecretFiles = [
  '.config/climbtopo-mgmt-token',
  '.config/cf-pages-token',
  '.config/masi-e2e-password',
  '.config/masi-push-hook-secret',
  '.config/masi-vapid-private',
];

/// Paths the scanner will not read. Generated/vendored bulk only — never a
/// source directory, and never anything that could hold a hand-written value.
bool _isSkippable(String path) {
  const skip = [
    'build/',
    '.dart_tool/',
    '.claude/worktrees/',
    'ios/Runner.xcodeproj/',
    'pubspec.lock',
    // The scanner's own rule table contains every pattern it looks for.
    'tool/scan_secrets.dart',
  ];
  return skip.any(path.startsWith) || path.endsWith('.g.dart');
}

class _Finding {
  _Finding({
    required this.path,
    required this.line,
    required this.rule,
    required this.why,
    required this.excerpt,
  });

  final String path;
  final int line;
  final String rule;
  final String why;
  final String excerpt;

  Map<String, dynamic> toJson() => {
        'path': path,
        'line': line,
        'rule': rule,
        'why': why,
        'excerpt': excerpt,
      };
}

/// Replaces everything but the first 4 characters of [match] with `*`.
///
/// Enough to recognise which credential fired the rule, never enough to use it.
/// A gate that prints the secret it caught has leaked it into the CI log.
String _redact(String line, String match) {
  if (match.isEmpty) return line.trim();
  final head = match.length <= 4 ? match : match.substring(0, 4);
  final masked = '$head${'*' * (match.length - head.length)}';
  final out = line.replaceAll(match, masked).trim();
  return out.length <= 200 ? out : '${out.substring(0, 200)}…';
}

List<String> _run(String exe, List<String> args, {required String cwd}) {
  final r = Process.runSync(exe, args, workingDirectory: cwd);
  if (r.exitCode != 0) {
    stderr.writeln('scan_secrets: `$exe ${args.join(' ')}` failed: ${r.stderr}');
    exit(2);
  }
  return r.stdout
      .toString()
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();
}

void main(List<String> argv) {
  final json = argv.contains('--json');
  final all = argv.contains('--all');
  final rangeArg = argv.indexOf('--range');
  final range = rangeArg >= 0 && rangeArg + 1 < argv.length
      ? argv[rangeArg + 1]
      : null;

  final root = Directory.current.path;
  if (!Directory('$root/.git').existsSync() &&
      !File('$root/.git').existsSync()) {
    stderr.writeln('scan_secrets: not a git repository: $root');
    exit(2);
  }

  final List<String> paths;
  final String mode;
  if (all) {
    mode = 'all tracked files';
    paths = _run('git', ['ls-files'], cwd: root);
  } else if (range != null) {
    mode = 'commit range $range';
    paths = _run(
      'git',
      ['diff', '--name-only', '--diff-filter=ACMR', range],
      cwd: root,
    );
  } else {
    mode = 'staged changes';
    paths = _run(
      'git',
      ['diff', '--cached', '--name-only', '--diff-filter=ACMR'],
      cwd: root,
    );
  }

  // Layer 2: this machine's real secret values, read once.
  //
  // Short values are dropped rather than searched: a 6-character secret would
  // match somewhere in any large repo by chance, and a scanner that cries wolf
  // is a scanner people learn to `--no-verify` past.
  final home = Platform.environment['USERPROFILE'] ??
      Platform.environment['HOME'] ??
      '';
  final localSecrets = <String, String>{};
  if (home.isNotEmpty) {
    for (final rel in _localSecretFiles) {
      final f = File('$home${Platform.pathSeparator}'
          '${rel.replaceAll('/', Platform.pathSeparator)}');
      if (!f.existsSync()) continue;
      try {
        final value = f.readAsStringSync().trim();
        if (value.length >= 12) localSecrets[rel] = value;
      } on FileSystemException {
        // Unreadable is the same as absent for our purposes.
      }
    }
  }

  final findings = <_Finding>[];

  for (final path in paths) {
    for (final forbidden in _forbiddenPaths) {
      if (forbidden.hasMatch(path)) {
        findings.add(_Finding(
          path: path,
          line: 0,
          rule: 'forbidden-path',
          why: 'This filename is a credential store. It must never be tracked.',
          excerpt: '(path match; file contents not read)',
        ));
      }
    }

    if (_isSkippable(path)) continue;

    final file = File('$root${Platform.pathSeparator}'
        '${path.replaceAll('/', Platform.pathSeparator)}');
    if (!file.existsSync()) continue;
    // Skip anything implausibly large or binary rather than loading it.
    if (file.lengthSync() > 2 * 1024 * 1024) continue;

    final String text;
    try {
      text = file.readAsStringSync();
    } on FileSystemException {
      continue;
    } on FormatException {
      continue; // binary
    }

    final lines = text.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.length > 4000) continue;

      for (final shape in _shapes) {
        final m = shape.pattern.firstMatch(line);
        if (m == null) continue;
        findings.add(_Finding(
          path: path,
          line: i + 1,
          rule: shape.name,
          why: shape.why,
          excerpt: _redact(line, m.group(0) ?? ''),
        ));
      }

      for (final entry in localSecrets.entries) {
        if (!line.contains(entry.value)) continue;
        findings.add(_Finding(
          path: path,
          line: i + 1,
          rule: 'local-secret-verbatim',
          why: 'This line contains the literal contents of ~/${entry.key}. '
              'Its shape may look harmless; the value is a live credential.',
          excerpt: _redact(line, entry.value),
        ));
      }
    }
  }

  if (json) {
    stdout.writeln(const JsonEncoder.withIndent('  ').convert({
      'mode': mode,
      'filesScanned': paths.length,
      'localSecretFilesLoaded': localSecrets.length,
      'findings': [for (final f in findings) f.toJson()],
      'ok': findings.isEmpty,
    }));
    exit(findings.isEmpty ? 0 : 1);
  }

  stdout.writeln('==> secret scan ($mode, ${paths.length} file(s))');
  if (localSecrets.isEmpty) {
    stdout.writeln('    note: no local credential files found — shape and path '
        'rules only (expected on CI).');
  } else {
    stdout.writeln('    ${localSecrets.length} local credential file(s) loaded '
        'for verbatim matching (values never printed).');
  }

  if (findings.isEmpty) {
    stdout.writeln('    ok: no credentials found');
    exit(0);
  }

  stderr.writeln('');
  stderr.writeln('FAIL: ${findings.length} possible credential(s). '
      'Pushing publishes — a secret in a commit is public the moment the '
      'branch goes up, and rewriting history does not un-publish it.');
  for (final f in findings) {
    stderr.writeln('');
    stderr.writeln('  ${f.path}${f.line > 0 ? ':${f.line}' : ''}  [${f.rule}]');
    stderr.writeln('    ${f.why}');
    stderr.writeln('    ${f.excerpt}');
  }
  stderr.writeln('');
  stderr.writeln('If a finding is a false positive, narrow the rule in '
      'tool/scan_secrets.dart — do not bypass the gate.');
  exit(1);
}
