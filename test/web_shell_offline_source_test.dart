import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Source-level pins for the OFFLINE COLD START of `web/sw.js`.
///
/// `flutter test` cannot execute JavaScript, so — exactly like
/// `test/web_shell_source_test.dart`, whose invariants this file extends rather
/// than repeats — these are string/structure assertions over the worker
/// source. They exist because the behaviours below have no cheap browser test
/// and fail in the worst possible way: the installed PWA sits on the HTML
/// splash forever, with no error, no text and no way for the user to tell
/// "still loading" from "broken".
///
/// The two failures pinned here are:
///
///  1. a `cacheFirst` MISS on a dead network issuing an unbounded `fetch()`.
///     Nothing resolves that promise, so `respondWith` never settles and the
///     engine waits on the asset forever;
///  2. the renderer (`main.dart.js` + `canvaskit/canvaskit.*` on WebKit/Gecko,
///     `canvaskit/skwasm.*` on blink) not being in the per-build cache at all.
///     The static manifest excludes them by design and `activate` drops the
///     previous cache on every deploy, so the only thing that used to put them
///     back was the first-frame warm pass — which cannot run on a load that
///     never reaches a first frame. `tool/verify_offline_shell.py` waits for
///     `__masiShellWarmed` before killing the origin, so it could never have
///     caught this.
String _read(String relativePath) {
  final file = File(p.join(Directory.current.path, relativePath));
  expect(file.existsSync(), isTrue, reason: 'expected $relativePath to exist');
  return file.readAsStringSync();
}

/// The body of a top-level function in `web/sw.js`, from its signature to the
/// first closing brace in column 0. Used to assert things about ONE path
/// without a doc comment elsewhere in the file satisfying the check.
String _functionBody(String source, String signature) {
  final start = source.indexOf(signature);
  expect(start, isNot(-1), reason: 'expected to find `$signature`');
  final end = source.indexOf('\n}', start);
  expect(end, isNot(-1), reason: 'unterminated function for `$signature`');
  return source.substring(start, end);
}

void main() {
  group('web/sw.js offline cache-first behaviour', () {
    test('a cache-first MISS fails fast when the browser reports no network',
        () {
      final body = _functionBody(
        _read('web/sw.js'),
        'async function cacheFirst(',
      );
      expect(
        body,
        contains('self.navigator.onLine === false'),
        reason: 'an offline miss must not start a fetch that cannot succeed — '
            'that is what leaves the HTML splash up forever',
      );
      expect(
        body,
        contains('return Response.error()'),
        reason: 'the fast failure must be a network-error response so the '
            "caller's own degradation path runs. `Response.error()` (not "
            '`new Response(...)`, which test/web_shell_source_test.dart '
            'forbids, because a rebuilt response drops COOP/COEP)',
      );
      // Ordering matters: the guard is only correct AFTER the cache lookup. A
      // guard placed before it would refuse to serve assets that ARE cached,
      // turning the offline shell off completely.
      expect(
        body.indexOf('cache.match(request)'),
        lessThan(body.indexOf('self.navigator.onLine === false')),
        reason: 'the offline guard must come after the cache lookup, or an '
            'offline user is denied the very assets the precache holds',
      );
    });

    test('cache-first NEVER puts a timeout on its network leg', () {
      final body = _functionBody(
        _read('web/sw.js'),
        'async function cacheFirst(',
      );
      expect(
        body,
        // The call, not the word: the body's comment names `withTimeout` to
        // explain why it is absent.
        isNot(contains('withTimeout(')),
        reason: 'main.dart.wasm is 4 MB: a slow-but-working connection must '
            'still be able to finish it. The offline case is handled by the '
            'onLine guard, NOT by a blanket deadline',
      );
    });

    test('the shell paths that already had a deadline still have it', () {
      final source = _read('web/sw.js');
      expect(
        _functionBody(source, 'async function navigationFirst('),
        contains('NETWORK_TIMEOUT_MS'),
      );
      expect(
        _functionBody(source, 'async function networkFirst('),
        contains('NETWORK_TIMEOUT_MS'),
      );
      expect(source, contains('const NETWORK_TIMEOUT_MS = 4000;'));
    });

    test('nothing but activate is allowed to delete a cache', () {
      // The offline work only ever READS the cache. Own photo bytes live in
      // IndexedDB and are never touched here, and a stray `caches.delete` in a
      // fetch path would be a data-loss bug wearing a performance costume.
      expect(
        RegExp(r'caches\.delete\(').allMatches(_read('web/sw.js')),
        hasLength(1),
        reason: 'exactly one caches.delete call, the per-deploy prune in '
            'activate that already spares KEEP_CACHE_PREFIX',
      );
    });
  });

  group('web/sw.js renderer precache', () {
    test('install precaches the renderer, after the all-or-nothing block', () {
      final source = _read('web/sw.js');
      expect(
        source,
        contains('await cacheMissing(cache, rendererArtifacts());'),
        reason: 'the renderer must be cached at INSTALL time, not left to the '
            'first-frame warm pass, which cannot run on a load that never '
            'paints — i.e. exactly the offline cold start',
      );
      expect(
        source.indexOf('await cache.addAll('),
        lessThan(source.indexOf('await cacheMissing(cache, rendererArtifacts')),
        reason: 'the required manifest must be stored first: the renderer step '
            'is best-effort and must never be able to abort the update',
      );
    });

    test('picks exactly one minimal renderer set per engine', () {
      final body = _functionBody(_read('web/sw.js'), 'function rendererArtifacts(');
      expect(body, contains("'main.dart.js'"));
      expect(body, contains("'canvaskit/canvaskit.js'"));
      expect(body, contains("'canvaskit/canvaskit.wasm'"));
      expect(body, contains("'canvaskit/skwasm.js'"));
      expect(body, contains("'canvaskit/skwasm.wasm'"));
      // The size discipline. canvaskit/ is 37 MB across six variants; blanket
      // precaching it is not acceptable, and the two variants below cannot be
      // chosen correctly from a service worker anyway (ImageDecoder is
      // [Exposed=(Window,DedicatedWorker)], so it is always undefined here).
      expect(body, isNot(contains('skwasm_heavy')));
      expect(body, isNot(contains('wimp')));
      expect(body, isNot(contains('chromium/')));
      expect(body, isNot(contains('experimental_webparagraph')));
    });

    test('skwasm is gated on WasmGC AND an allow-listed engine', () {
      final body = _functionBody(_read('web/sw.js'), 'function rendererArtifacts(');
      expect(
        body,
        contains('supportsWasmGc() && isBlinkLike()'),
        reason: "flutter.js's default wasmAllowList is blink-only, so a WebKit "
            'that supports WasmGC still takes the dart2js/canvaskit build. '
            'Probing WasmGC alone would cache the wrong renderer for Safari',
      );
    });

    test('WebKit-backed browsers wearing a Chrome token are not blink', () {
      final body = _functionBody(_read('web/sw.js'), 'function isBlinkLike(');
      for (final token in ['CriOS', 'EdgiOS', 'FxiOS']) {
        expect(
          body,
          contains(token),
          reason: 'every browser on iOS is WebKit and takes the dart2js path; '
              'reading $token as blink would precache skwasm and leave the '
              'iOS PWA with no renderer offline',
        );
      }
    });
  });
}
