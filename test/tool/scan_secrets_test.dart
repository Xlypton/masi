// Proves `tool/scan_secrets.dart` can actually FAIL.
//
// A gate nobody has watched reject anything is decoration: it runs green in CI
// for months and everyone assumes it is working, when a typo in one regex has
// quietly turned it into `exit 0`. So every rule is exercised against a planted
// credential in a throwaway git repository, and the two things a secret scanner
// must never do — flag the anon key that is committed ON PURPOSE, and echo the
// credential it caught — are pinned as hard as the detections are.
//
// A real `git init` rather than a mock: the scanner's file list comes from
// `git ls-files`, so a fake would test a code path that does not ship.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Absolute path to the scanner, resolved from the repo the test runs in.
String get _scanner => p.join(Directory.current.path, 'tool', 'scan_secrets.dart');

/// Runs the scanner over a scratch repo containing exactly [files].
///
/// Invoked as `dart <path>` rather than `dart run <path>`: the scanner imports
/// nothing outside `dart:` on purpose, so it needs no package config and can be
/// executed from a directory that is not a Dart package at all — which is what
/// lets a pre-commit hook or a foreign CI step call it.
Future<Map<String, dynamic>> _scan(Map<String, String> files) async {
  final dir = await Directory.systemTemp.createTemp('masi-secret-scan');
  addTearDown(() async {
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // Windows occasionally holds a handle on a just-deleted git index.
    }
  });

  for (final entry in files.entries) {
    final f = File(p.join(dir.path, entry.key.replaceAll('/', p.separator)));
    await f.parent.create(recursive: true);
    await f.writeAsString(entry.value);
  }

  Future<void> git(List<String> args) async {
    final r = await Process.run('git', args, workingDirectory: dir.path);
    expect(r.exitCode, 0, reason: 'git ${args.join(' ')} failed: ${r.stderr}');
  }

  await git(['init', '-q']);
  // `git ls-files` lists the INDEX, so the fixtures have to be added. No commit
  // is needed and none is made — user.name/email may not be configured here.
  await git(['add', '-A']);

  // `runInShell` is required, not stylistic: on Windows the Dart entry point on
  // PATH is `dart.bat`, and a bare `Process.run('dart', …)` does not apply
  // PATHEXT, so it fails with "The system cannot find the file specified" —
  // which would make this whole file red on the machine it is being written on.
  final result = await Process.run(
    'dart',
    [_scanner, '--all', '--json'],
    workingDirectory: dir.path,
    runInShell: true,
  );
  final out = result.stdout.toString();
  final start = out.indexOf('{');
  expect(start, isNonNegative,
      reason: 'scanner produced no JSON.\nstdout:\n$out\nstderr:\n${result.stderr}');
  return jsonDecode(out.substring(start)) as Map<String, dynamic>;
}

/// Joins a credential-shaped fixture from two halves that are each harmless.
///
/// Every fixture below goes through here so that THIS FILE contains no literal
/// its own scanner would flag — verified the hard way: the first version wrote
/// them inline and the pre-commit hook refused the commit, correctly.
///
/// The obvious alternative was to exempt this path inside `_isSkippable`. That
/// would punch a permanent, invisible hole in the gate at exactly the spot
/// where somebody would later be tempted to park a real value "just for a
/// test" — a file the scanner is contractually blind to. Splitting the
/// literals costs one indirection and leaves the gate total.
String _shaped(String prefix, String body) => '$prefix$body';

List<String> _rules(Map<String, dynamic> report) => [
      for (final f in report['findings'] as List<dynamic>)
        (f as Map<String, dynamic>)['rule'] as String,
    ];

void main() {
  group('tool/scan_secrets.dart', () {
    test('a clean tree passes', () async {
      final report = await _scan({
        'lib/main.dart': 'void main() {}\n',
        'README.md': '# nothing to see here\n',
      });

      expect(report['ok'], isTrue, reason: 'findings: ${report['findings']}');
      expect(_rules(report), isEmpty);
    });

    test('catches every credential SHAPE it claims to', () async {
      // Values are syntactically valid and semantically worthless — the point
      // is the shape, and no real credential may ever be committed to this
      // repo, including into a test fixture.
      final report = await _scan({
        'a.sh': 'TOKEN=${_shaped('sbp_', '0123456789abcdef0123456789abcdef01234567')}\n',
        'b.dart': "const k = '${_shaped('sb_sec', 'ret_0123456789abcdefghij')}';\n",
        'c.json': '{${_shaped('"role"', ': "service_role"')}, "iss": "supabase"}\n',
        'd.pem': '${_shaped('-----BEGIN RSA ', 'PRIVATE KEY-----')}\nAAAA\n',
        'e.yml': 'token: ${_shaped('ghp_', '0123456789abcdef0123456789abcdef0123')}\n',
        'f.tf': 'access_key = "${_shaped('AKIA', 'IOSFODNN7EXAMPLE')}"\n',
        'g.sh': 'export ${_shaped('CLOUDFLARE_API_TOKEN=', '0123456789abcdef0123456789abcdef01234567')}\n',
      });

      expect(report['ok'], isFalse);
      expect(
        _rules(report),
        containsAll(<String>[
          'supabase-management-token',
          'supabase-secret-key',
          'service-role-jwt',
          'private-key-block',
          'github-token',
          'aws-access-key',
          'cloudflare-api-token',
        ]),
        reason: 'a rule that no longer fires is a rule that has silently '
            'stopped protecting anything',
      );
    });

    test('does NOT flag the anon key, which is committed on purpose', () async {
      // The single most important false positive to avoid. If the scanner
      // rejects `supabase_config.dart`, the gate becomes something every agent
      // routes around, and then it protects nothing at all.
      final report = await _scan({
        'lib/core/config/supabase_config.dart': '''
const String supabaseAnonKey = String.fromEnvironment(
  'SUPABASE_ANON_KEY',
  defaultValue: 'sb_publishable_CjAxoGe0OSS0RrIK3nT6Ng_p0-uSPKC',
);
const String vapidPublicKey = String.fromEnvironment(
  'VAPID_PUBLIC_KEY',
  defaultValue: 'BFlwnCh7rbcN9w0Kw-D4KEcDkrvOjX42w248mql7VZckJbWDcus39QZ4x0kjVsQ_SlMreZpRdqVV2CUar6dItaw',
);
''',
      });

      expect(report['ok'], isTrue,
          reason: 'the publishable anon key and the VAPID PUBLIC key are safe '
              'to embed and are committed deliberately — see '
              'lib/core/config/supabase_config.dart. Findings: '
              '${report['findings']}');
    });

    test('refuses a credential FILE by name, whatever is inside it', () async {
      final report = await _scan({
        'secrets/climbtopo-mgmt-token': 'not-even-a-real-token\n',
        'deploy/.env': 'HELLO=world\n',
      });

      expect(_rules(report).where((r) => r == 'forbidden-path'), hasLength(2));
    });

    test('never prints the credential it caught', () async {
      final planted = _shaped('sbp_', '0123456789abcdefghijklmnopqrstuvwxyz01');
      final report = await _scan({'leak.sh': 'TOKEN=$planted\n'});

      final excerpts = [
        for (final f in report['findings'] as List<dynamic>)
          (f as Map<String, dynamic>)['excerpt'] as String,
      ];
      expect(excerpts, isNotEmpty);
      for (final e in excerpts) {
        expect(e, isNot(contains(planted)),
            reason: 'the excerpt reproduced the secret verbatim. A gate that '
                'echoes what it caught has published it a second way — into '
                'the CI log, which is often more widely readable than the '
                'branch would have been.');
        expect(e, contains('sbp_'.substring(0, 4)),
            reason: 'a fully-opaque excerpt is not actionable; the first four '
                'characters are what let a reader tell WHICH credential this '
                'is without exposing it');
      }
    });

    test('reports machine-readably, so a hook or CI step can consume it',
        () async {
      final report = await _scan({'x.sh': 'ok=1\n'});

      expect(report.keys,
          containsAll(<String>['mode', 'filesScanned', 'findings', 'ok']));
      expect(report['filesScanned'], greaterThan(0));
    });
  });
}
