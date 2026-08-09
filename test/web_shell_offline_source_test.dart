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
///     never reaches a first frame. `tool/verify_offline_shell.py` waited for
///     `__masiShellWarmed` before killing the origin, so it could never have
///     caught this; it now waits only for `activated` plus the early reporter;
///  3. the install-time renderer pick being WRONG. A ServiceWorker has no
///     `document`, so it cannot run the loader's `detectWebGLVersion()` probe,
///     and the loader's real rule is
///     `supportsWasmGC && webGLVersion > 0 && wasmAllowList[engine]`. On blink
///     WITHOUT WebGL the loader takes dart2js/canvaskit and then the
///     `chromium/` canvaskit variant, so the worker's `skwasm.*` guess is the
///     wrong 3.6 MB. This is not fixable by a better heuristic inside the
///     worker; the pins below therefore require the PAGE to report what the
///     loader actually fetched, early and independently of paint.
///
/// EVERYTHING HERE IS A SOURCE-LEVEL PIN, NOT EXECUTION. `flutter test` runs no
/// JavaScript and no browser: these assertions prove the code that must exist
/// is present and shaped correctly, and nothing about its runtime behaviour. The
/// behavioural proof is `tool/verify_offline_shell.py`, which drives real
/// headless Chrome with the origin killed — and which is mutation-tested
/// (deleting the early reporter from the built `index.html` makes it fail).
/// Do not read a green run of this file as "the offline shell works".
String _read(String relativePath) {
  final file = File(p.join(Directory.current.path, relativePath));
  expect(file.existsSync(), isTrue, reason: 'expected $relativePath to exist');
  return file.readAsStringSync();
}

/// The slice of `web/index.html` that lies BEFORE the `flutter-first-frame`
/// listener which posts the warm.
///
/// Position is the pin. A listener's body always follows its
/// `addEventListener(...)` call, so anything found in this slice is provably
/// NOT inside that listener — which is the whole property the early reporter
/// needs: it must run on a load that never paints.
String _beforeWarmListener(String source) {
  final warmPost = source.indexOf("type: 'masi-warm'");
  expect(warmPost, isNot(-1), reason: 'expected the warm post to still exist');
  final listener =
      source.lastIndexOf("addEventListener('flutter-first-frame'", warmPost);
  expect(
    listener,
    isNot(-1),
    reason: 'expected the warm to be posted from a flutter-first-frame listener',
  );
  return source.substring(0, listener);
}

/// [source] with whole-line `//` comments dropped.
///
/// Needed for the NEGATIVE pins only: the prose in `web/index.html` explains at
/// length why the post must not use `navigator.serviceWorker.controller`, and a
/// naive `isNot(contains(...))` matches that explanation and fails. Whole-line
/// only, deliberately — stripping trailing `//` would corrupt any string holding
/// a `//`, and every comment that matters here is on its own line.
String _withoutFullLineComments(String source) => source
    .split('\n')
    .where((line) => !line.trimLeft().startsWith('//'))
    .join('\n');

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
      // The Dart bundle is no longer a literal `'main.dart.js'` in this
      // function: it comes from the STAMPED `PRECACHE_WASM`/`PRECACHE_JS`
      // lists (see the BUILD STAMP block), so a `--js`-only build degrades to
      // an empty `PRECACHE_WASM` instead of 404-ing on a file that was never
      // emitted. Pin the concat call, not a bundle filename that no longer
      // appears in this function's source.
      expect(body, contains('PRECACHE_WASM.concat('));
      expect(body, contains('PRECACHE_JS.concat('));
      expect(
        RegExp(r'PRECACHE_(WASM|JS)\.concat\(').allMatches(body),
        hasLength(2),
        reason: 'exactly one bundle-concat call per engine branch — a third '
            'would mean some branch mixes both renderer bundles into one '
            'returned list, which is the whole regression this function '
            'exists to avoid',
      );

      // Split at the fallback branch's own concat call, so each half can be
      // checked for containing ONLY its own bundle list — never the other
      // one, which is the "exactly one... per engine" property the test name
      // promises.
      final split = body.indexOf('return PRECACHE_JS');
      expect(split, isNot(-1), reason: 'expected the fallback return to exist');
      final blinkBranch = body.substring(0, split);
      final fallbackBranch = body.substring(split);

      expect(blinkBranch, contains('PRECACHE_WASM.concat('));
      expect(blinkBranch, isNot(contains('PRECACHE_JS.concat(')));
      expect(blinkBranch, contains("'canvaskit/skwasm.js'"));
      expect(blinkBranch, contains("'canvaskit/skwasm.wasm'"));

      expect(fallbackBranch, contains('PRECACHE_JS.concat('));
      expect(fallbackBranch, isNot(contains('PRECACHE_WASM.concat(')));
      expect(fallbackBranch, contains("'canvaskit/canvaskit.js'"));
      expect(fallbackBranch, contains("'canvaskit/canvaskit.wasm'"));

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

    test('the guess is documented as fallible, with the page as the authority',
        () {
      // Source-level pin, and a deliberately prose-shaped one: the ONLY defence
      // against someone "improving" `rendererArtifacts()` into a supposedly
      // correct WebGL-aware probe is the file saying, in the file, that a
      // worker cannot do that. `supportsWasmGc() && isBlinkLike()` is NOT the
      // loader's rule and cannot be made into it here.
      final source = _read('web/sw.js');
      expect(
        source,
        contains('detectWebGLVersion'),
        reason: 'the worker must name the probe it cannot run, or the next '
            'reader assumes the install-time pick is authoritative',
      );
      expect(
        source,
        contains('masi-observed'),
        reason: 'the page-observed list is what corrects the guess; without a '
            'handler for it the worker is back to guessing',
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

  // Source-level pins, again — see the file header. These say the reporter
  // EXISTS and is WIRED the only way that works; only
  // `tool/verify_offline_shell.py` can say it runs.
  group('web/index.html early observed-resource reporter', () {
    test('observes resource timing with buffered entries', () {
      final early = _beforeWarmListener(_read('web/index.html'));
      expect(
        early,
        contains('PerformanceObserver'),
        reason: 'the page is the only place that can know which renderer the '
            'loader chose — a worker has no document and so no WebGL probe',
      );
      expect(
        early,
        contains("type: 'resource'"),
        reason: 'must observe resource timing, which is the loader\'s real '
            'choice rather than a re-implementation of its logic',
      );
      expect(
        early,
        contains('buffered: true'),
        reason: 'without `buffered` the observer misses every resource that '
            'completed before it was constructed — which on a fast boot is '
            'the renderer itself, i.e. the entire point',
      );
    });

    test('is NOT gated on flutter-first-frame', () {
      final source = _read('web/index.html');
      final early = _beforeWarmListener(source);
      expect(
        early,
        contains("type: 'masi-observed'"),
        reason: 'the observed post must sit OUTSIDE the first-frame listener. '
            'Inside it, it inherits the warm\'s fatal property: it never runs '
            'on a load that fails to paint, which is the only load that needs '
            'it',
      );
      expect(
        source.indexOf("type: 'masi-observed'"),
        lessThan(source.indexOf("type: 'masi-warm'")),
        reason: 'the early reporter must post before the first-frame warm; the '
            'warm is a backstop, not the mechanism',
      );
    });

    test('posts to the REGISTRATION, never to the controller', () {
      final early = _beforeWarmListener(_read('web/index.html'));
      expect(
        early,
        contains('navigator.serviceWorker.ready'),
        reason: 'on a first visit there is no worker yet; `ready` is what '
            'yields the registration once install has activated one',
      );
      expect(
        early,
        contains('registration.active'),
        reason: 'the post target must come from the registration',
      );
      expect(
        _withoutFullLineComments(early),
        isNot(contains('navigator.serviceWorker.controller')),
        reason: 'a FIRST visit is uncontrolled, so `controller` is null and a '
            'controller-based post silently does nothing — and the first '
            'visit is the only load that can fill the cache before the user '
            'goes offline',
      );
    });

    test('degrades silently instead of throwing into boot', () {
      final early = _beforeWarmListener(_read('web/index.html'));
      expect(early, contains("if (!('serviceWorker' in navigator)) return;"));
      expect(
        early,
        contains("typeof PerformanceObserver !== 'function'"),
        reason: 'this code runs on EVERY page load; a browser without the API '
            'must lose the reporter, not the app',
      );
    });
  });

  group('web/sw.js page-reported url lists', () {
    test('the observed list and the warm share cacheMissing exactly', () {
      final source = _read('web/sw.js');
      final body = _functionBody(source, 'async function reportUrls(');
      expect(
        body,
        contains('cacheMissing(cache, urls'),
        reason: 'an observed list must be cached with IDENTICAL semantics to '
            'the warm and the install precache — fetch only what is missing, '
            'tolerate per-URL failure — or the two paths drift apart',
      );
      final handler = source.substring(
        source.indexOf("self.addEventListener('message'"),
        source.indexOf('function normalisedUrls('),
      );
      expect(handler, contains("data.type === 'masi-observed'"));
      expect(handler, contains("data.type === 'masi-warm'"));
      expect(
        RegExp(r'reportUrls\(').allMatches(handler),
        hasLength(2),
        reason: 'both message types must go through the one function',
      );
    });

    test('an unknown or hostile message shape cannot throw', () {
      final source = _read('web/sw.js');
      expect(
        _functionBody(source, 'function normalisedUrls('),
        contains('Array.isArray'),
        reason: 'a non-array `urls` would make `for...of` throw straight out '
            'of a waitUntil',
      );
      final missing = _functionBody(source, 'async function cacheMissing(');
      expect(
        missing.indexOf('try {'),
        lessThan(missing.indexOf('new URL(url, SCOPE)')),
        reason: 'these lists arrive over postMessage and `new URL(\'%\')` '
            'throws: parsing outside the try lets ONE malformed entry abandon '
            'every url after it',
      );
    });

    test('the ack distinguishes newly stored from already present', () {
      // This is what makes tool/verify_offline_shell.py able to attribute a
      // cache entry to the early reporter rather than to the warm. Without it
      // that harness passed with the reporter deleted — measured, in Chrome.
      final source = _read('web/sw.js');
      expect(_functionBody(source, 'async function reportUrls('),
          contains('stored: stored'));
      expect(
        _functionBody(source, 'async function cacheMissing('),
        contains('storedOut.push('),
      );
      expect(
        source,
        contains('await cacheMissing(cache, rendererArtifacts());'),
        reason: 'the install call must stay in its bare two-argument shape — '
            'install attributes nothing and wants no `stored` list',
      );
    });
  });
}
