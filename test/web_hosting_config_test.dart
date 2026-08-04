import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Hosting config is the one part of this app that no test can execute and no
/// build can validate: a mistake in `web/_headers` is invisible until a real
/// browser on the real origin behaves oddly, and the symptom (drift silently
/// choosing a weaker storage backend, then being PINNED to it — audit L8) is
/// exactly the kind of thing nobody attributes to a header.
///
/// So this pins the invariants by scanning the files. It cannot prove
/// Cloudflare applies them — `tool/verify_offline_shell.py` proves the same
/// headers work when they ARE applied, and confirming the deployed origin is
/// a named manual check.
String _read(String relativePath) {
  final file = File(p.join(Directory.current.path, relativePath));
  expect(file.existsSync(), isTrue, reason: 'expected $relativePath to exist');
  return file.readAsStringSync();
}

/// One `path-pattern` block of a Cloudflare Pages `_headers` file.
typedef _HeaderRule = ({String pattern, Map<String, String> headers});

/// Parses `web/_headers`: a line starting with `/` opens a rule, and the
/// indented `Name: value` lines under it belong to that rule. Blank lines and
/// `#` comments are ignored.
List<_HeaderRule> _parseRules(String source) {
  final rules = <_HeaderRule>[];
  var current = <String, String>{};
  var pattern = '';
  for (final raw in source.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    if (raw.startsWith('/')) {
      if (pattern.isNotEmpty) rules.add((pattern: pattern, headers: current));
      pattern = line;
      current = <String, String>{};
    } else {
      final colon = line.indexOf(':');
      if (colon > 0) {
        current[line.substring(0, colon).trim()] =
            line.substring(colon + 1).trim();
      }
    }
  }
  if (pattern.isNotEmpty) rules.add((pattern: pattern, headers: current));
  return rules;
}

/// Whether a Pages path pattern matches [path].
///
/// `*` spans path separators — this is the detail that made the original bug
/// possible, because it means `/*.wasm` already matches
/// `/canvaskit/skwasm.wasm` and a second `/canvaskit/*.wasm` block is a
/// duplicate rather than an override.
bool _patternMatches(String pattern, String path) {
  final escaped =
      RegExp.escape(pattern).replaceAll(RegExp(r'\\\*'), '[\\s\\S]*');
  return RegExp('^$escaped\$').hasMatch(path);
}

/// The header values a request for [path] actually receives.
///
/// Cloudflare Pages does NOT pick the most specific matching rule — it
/// **appends** every matching rule's value into one comma-joined header. So a
/// header name reached by two matching rules yields two entries here, which is
/// precisely the defect being guarded against.
Map<String, List<String>> _effectiveHeaders(
  List<_HeaderRule> rules,
  String path,
) {
  final out = <String, List<String>>{};
  for (final rule in rules) {
    if (!_patternMatches(rule.pattern, path)) continue;
    rule.headers.forEach((name, value) => out.putIfAbsent(name, () => []).add(value));
  }
  return out;
}

/// Real paths this build actually emits, spanning every rule in the file.
const _buildPaths = <String>[
  '/index.html',
  '/flutter_bootstrap.js',
  '/main.dart.wasm',
  '/main.dart.js',
  '/sw.js',
  '/manifest.json',
  '/sqlite3.wasm',
  '/drift_worker.js',
  '/canvaskit/skwasm.wasm',
  '/canvaskit/canvaskit.wasm',
  '/assets/AssetManifest.bin.json',
];

void main() {
  group('web/_headers', () {
    // Asserted as a PROPERTY of what every actual build path resolves to, not
    // as bare presence of the three header lines anywhere in the file — a
    // literal-substring check stays green even if the lines are scoped to a
    // single narrow block (e.g. `/index.html` only) while every other path
    // loses them. That regression is silent: `crossOriginIsolated` goes false
    // for those responses and drift picks a weaker storage backend, then is
    // PINNED to it.
    test('keeps cross-origin isolation on every response', () {
      final rules = _parseRules(_read('web/_headers'));
      const required = {
        'Cross-Origin-Opener-Policy': 'same-origin',
        'Cross-Origin-Embedder-Policy': 'require-corp',
        'Cross-Origin-Resource-Policy': 'same-origin',
      };
      for (final path in _buildPaths) {
        final headers = _effectiveHeaders(rules, path);
        required.forEach((name, value) {
          expect(
            headers[name],
            equals(<String>[value]),
            reason: '$path must resolve $name to exactly [$value] — got '
                '${headers[name]}. Losing any of these on any path makes '
                '`crossOriginIsolated` false for that response, and drift '
                'silently downgrades off OPFS and is then pinned to the '
                'weaker backend.',
          );
        });
      }
    });

    // THE REGRESSION GUARD. Cloudflare Pages appends the values of every
    // matching rule instead of letting the most specific one win, so any
    // header name reachable by two rules ships a comma-joined value. That
    // shipped two live bugs at once: /canvaskit/skwasm.wasm was served
    // `Content-Type: application/wasm, application/wasm` (not a valid MIME
    // type, and Pages sets `nosniff`, so the browser cannot recover), and
    // /sqlite3.wasm was served
    // `Cache-Control: no-cache, public, max-age=31536000, immutable` (flatly
    // self-contradictory). Both were invisible to every other test here,
    // because each individual rule read perfectly well on its own.
    test('no header is set by more than one matching rule', () {
      final rules = _parseRules(_read('web/_headers'));
      for (final path in _buildPaths) {
        _effectiveHeaders(rules, path).forEach((name, values) {
          expect(
            values,
            hasLength(1),
            reason: '$path receives $name from ${values.length} rules '
                '(${values.join(' | ')}). Cloudflare Pages appends these into '
                'one comma-joined header rather than picking the most specific '
                'rule, so the result is a malformed value, not an override. '
                'Restructure so exactly one rule sets $name for this path.',
          );
        });
      }
    });

    test('every .wasm asset gets exactly one application/wasm content-type',
        () {
      final rules = _parseRules(_read('web/_headers'));
      for (final path in _buildPaths.where((p) => p.endsWith('.wasm'))) {
        expect(
          _effectiveHeaders(rules, path)['Content-Type'],
          equals(<String>['application/wasm']),
          reason: 'WebAssembly.instantiateStreaming() MIME-checks its '
              'response, and a doubled value fails that check',
        );
      }
    });

    // Asserted as a PROPERTY of what sw.js actually receives, not as the
    // presence of a literal `/sw.js` block. The blanket `/*` rule already
    // delivers no-cache; adding a dedicated block to say so again would append
    // to it (`no-cache, no-cache`) rather than override it, per the rule above.
    test('sw.js resolves to no-cache and is never immutable', () {
      final rules = _parseRules(_read('web/_headers'));
      final cacheControl = _effectiveHeaders(rules, '/sw.js')['Cache-Control'];
      expect(
        cacheControl,
        equals(<String>['no-cache']),
        reason: 'a long-cached sw.js can never roll over, stranding a user on '
            'one shell version forever — the failure this whole stage exists '
            'to prevent',
      );
      expect(cacheControl!.join(','), isNot(contains('immutable')));
    });

    test('the unversioned app shell is never long-cached', () {
      final rules = _parseRules(_read('web/_headers'));
      // Flutter does not content-hash these filenames per build, so caching
      // any of them immutably would pin stale code forever (bug #55).
      for (final path in const [
        '/index.html',
        '/flutter_bootstrap.js',
        '/main.dart.wasm',
        '/main.dart.js',
      ]) {
        final value =
            (_effectiveHeaders(rules, path)['Cache-Control'] ?? const [])
                .join(',');
        expect(value, isNot(contains('immutable')), reason: path);
        expect(value, isNot(contains('max-age=31536000')), reason: path);
      }
    });
  });

  group('web/_redirects', () {
    test('SPA-falls-back to index.html', () {
      // Whitespace-tolerant on purpose: the `_redirects` format separates
      // columns by arbitrary runs of spaces, and the file aligns them for
      // readability. Pinning a single-spaced literal would be pinning the
      // formatting, not the rule.
      expect(
        _read('web/_redirects'),
        matches(RegExp(r'^/\*\s+/index\.html\s+200\s*$', multiLine: true)),
        reason: 'the app uses usePathUrlStrategy(), so /community/topo/<id> '
            'is a real path; without this, the FIRST load of a shared link — '
            'before any service worker exists — 404s on Cloudflare Pages',
      );
    });
  });

  group('firebase.json parity', () {
    test('mirrors the COOP/COEP policy', () {
      final firebase = _read('firebase.json');
      expect(firebase, contains('Cross-Origin-Opener-Policy'));
      expect(firebase, contains('Cross-Origin-Embedder-Policy'));
    });

    test('mirrors the sw.js no-cache rule', () {
      expect(_read('firebase.json'), contains('sw.js'));
    });
  });
}
