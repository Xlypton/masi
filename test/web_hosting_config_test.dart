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

void main() {
  group('web/_headers', () {
    test('keeps cross-origin isolation on every response', () {
      final headers = _read('web/_headers');
      expect(headers, contains('Cross-Origin-Opener-Policy: same-origin'));
      expect(headers, contains('Cross-Origin-Embedder-Policy: require-corp'));
      expect(headers, contains('Cross-Origin-Resource-Policy: same-origin'));
    });

    test('sw.js has an explicit no-cache rule', () {
      final headers = _read('web/_headers');
      expect(headers, contains('/sw.js'));
      expect(
        RegExp(r'/sw\.js\s*\n\s*Cache-Control: no-cache').hasMatch(headers),
        isTrue,
        reason: 'a long-cached sw.js can never roll over, stranding a user on '
            'one shell version forever — the failure this whole stage exists '
            'to prevent',
      );
    });

    test('sw.js is never marked immutable', () {
      final headers = _read('web/_headers');
      final swBlock = headers.substring(headers.indexOf('/sw.js'));
      expect(
          swBlock.split('\n').take(3).join('\n'), isNot(contains('immutable')));
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
