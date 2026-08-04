import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// `web/sw.js` is JavaScript, so `flutter test` can neither execute nor
/// type-check it. Its behaviour is proven in a real browser by
/// `tool/verify_offline_shell.py`. What THIS file pins are the invariants a
/// browser test would not obviously catch if they regressed — the ones where
/// the failure mode is silent, or catastrophic, or both:
///
///  - the two stamp lines keep the exact one-line shape
///    `tool/gen_sw_manifest.dart` rewrites (a reformat would make every build
///    ship an EMPTY precache, and the app would still work online);
///  - the committed stamp stays inert, so `flutter run -d chrome` and
///    `flutter drive -d web-server` — neither of which runs the generator —
///    serve a pass-through worker instead of a broken one;
///  - the worker never caches a cross-origin response (COEP `require-corp`
///    plus opaque responses is a silent corruption waiting to happen, and
///    Supabase/OSM responses must never be served from a stale cache);
///  - `index.html` registers OUR worker and never references Flutter's;
///  - the two `window.__masi*` globals the diagnostics row and the browser
///    harness both read are actually set;
///  - the freshness/consistency trade-off stays isolated in ONE function, so
///    reversing it later remains a one-function edit.
String _read(String relativePath) {
  final file = File(p.join(Directory.current.path, relativePath));
  expect(file.existsSync(), isTrue, reason: 'expected $relativePath to exist');
  return file.readAsStringSync();
}

void main() {
  group('web/sw.js build stamp', () {
    test('carries exactly one SHELL_VERSION stamp line, in generator shape',
        () {
      final matches =
          RegExp(r"^const SHELL_VERSION = '[^']*';$", multiLine: true)
              .allMatches(_read('web/sw.js'));
      expect(matches, hasLength(1));
    });

    test('carries exactly one PRECACHE stamp line, in generator shape', () {
      final matches = RegExp(r'^const PRECACHE = \[[^\]]*\];$', multiLine: true)
          .allMatches(_read('web/sw.js'));
      expect(matches, hasLength(1));
    });

    test('the COMMITTED stamp is inert', () {
      final source = _read('web/sw.js');
      expect(
        source,
        contains("const SHELL_VERSION = 'dev';"),
        reason: 'a real version must never be committed — only '
            'build/web/sw.js is ever stamped',
      );
      expect(source, contains('const PRECACHE = [];'));
    });
  });

  group('web/sw.js safety invariants', () {
    test('never intercepts a cross-origin request', () {
      expect(
        _read('web/sw.js'),
        contains('u.origin !== SCOPE.origin'),
        reason: 'Supabase, Google auth and OSM tiles must go straight to the '
            'network; caching an opaque cross-origin response under COEP '
            'require-corp corrupts silently',
      );
    });

    test('only ever caches a basic (same-origin, non-opaque) 200', () {
      final source = _read('web/sw.js');
      expect(source, contains("response.type === 'basic'"));
      expect(source, contains('response.status === 200'));
    });

    test('excludes itself and the legacy Flutter worker from caching', () {
      final source = _read('web/sw.js');
      expect(source, contains("'sw.js'"));
      expect(source, contains("'flutter_service_worker.js'"));
    });

    // Asserted as TWO structural facts, not bare presence of the string
    // `masi-runtime-` — that string also appears in the header comment
    // describing Stage 3, so a substring check stays green even if the
    // constant AND the activate-handler guard that reads it are both deleted.
    // That regression is silent and severe: `activate` would then delete
    // every cache it doesn't own by exact name, including Stage 3's map-tile
    // cache, wiping offline map tiles on every single deploy.
    test('preserves Stage 3\'s runtime cache namespace when pruning', () {
      final source = _read('web/sw.js');
      expect(
        source,
        contains("const KEEP_CACHE_PREFIX = 'masi-runtime-';"),
        reason: 'the prefix must stay a declared constant, not merely a '
            'string mentioned somewhere in the file',
      );
      expect(
        RegExp(
          r'if\s*\(name\.startsWith\(KEEP_CACHE_PREFIX\)\)\s*return undefined;',
        ).hasMatch(source),
        isTrue,
        reason: 'activate must actually consult KEEP_CACHE_PREFIX before '
            'deleting a cache, or the constant is declared but unused and '
            "Stage 3's runtime tile cache is swept on every deploy",
      );
    });

    test('force-revalidates the two immutable drift assets when precaching',
        () {
      final source = _read('web/sw.js');
      expect(source, contains("'sqlite3.wasm'"));
      expect(source, contains("'drift_worker.js'"));
      expect(
        source,
        contains("cache: 'reload'"),
        reason: 'web/_headers serves those two `immutable` on an UNVERSIONED '
            'url, so a year-old browser copy would otherwise be precached',
      );
    });

    test('never rebuilds a Response, so COOP/COEP survive the Cache API', () {
      expect(
        _read('web/sw.js'),
        isNot(contains('new Response(')),
        reason: 'a Response served from the Cache API retains the headers it '
            'was stored with. Reconstructing one drops COOP/COEP, which kills '
            'crossOriginIsolated and silently downgrades drift off OPFS',
      );
    });

    // A real outage, and one this file could have prevented. Cloudflare Pages
    // answers `/index.html` with a 308 to `/`. `fetch()` follows it, so the
    // response carries `redirected === true`, and serving such a response to a
    // NAVIGATION is forbidden: WebKit fails the whole load with "Response
    // served by service worker has redirections" and Safari cannot open the app
    // at all. Chromium is lenient, and no browser hits it on a first visit
    // (nothing controls that navigation yet), so it is invisible to headless
    // Chrome and to every fresh-profile smoke check — it strikes only returning
    // users and installed PWAs. The fix is to fetch a URL that does not
    // redirect, which is why the shell's fetch URL and its cache key are now
    // deliberately different values.
    test('the shell is never FETCHED from index.html, only cached under it', () {
      final source = _read('web/sw.js');
      expect(
        source,
        contains('const SHELL_NETWORK_URL'),
        reason: 'the navigation fetch URL must stay a single named constant',
      );
      expect(
        RegExp(r'SHELL_NETWORK_URL\s*=\s*\(\)\s*=>\s*new URL\('
                r"\s*'\./'\s*,\s*SCOPE\s*\)")
            .hasMatch(source),
        isTrue,
        reason: 'the navigation fetch must target the scope ROOT. Pointing it '
            "at 'index.html' reintroduces Cloudflare's 308 and takes Safari "
            'down completely',
      );
      expect(
        RegExp(r"SHELL_CACHE_KEY\s*=\s*\(\)\s*=>\s*new Request\("
                r"\s*new URL\(\s*'index\.html'\s*,\s*SCOPE\s*\)")
            .hasMatch(source),
        isTrue,
        reason: "the cache key must stay 'index.html' — that is the path "
            'PRECACHE lists, so changing it silently empties the offline shell',
      );
    });

    test('the precache fetches the shell from the root, not index.html', () {
      final source = _read('web/sw.js');
      // `addAll` derives the cache key from the fetched URL, so it cannot
      // express "fetch / but store under index.html". The shell therefore has
      // to be excluded from addAll and put explicitly, or the CACHED copy
      // carries the redirect and offline navigation breaks in Safari too.
      expect(
        source,
        contains("PRECACHE.filter((path) => path !== shellPath)"),
        reason: 'index.html must be excluded from addAll and stored explicitly',
      );
      expect(
        RegExp(r'cache\.put\(\s*SHELL_CACHE_KEY\(\)\s*,\s*shell\s*\)')
            .hasMatch(source),
        isTrue,
        reason: 'the precached shell must be stored under the index.html key',
      );
    });
  });

  group('web/sw.js strategy isolation', () {
    // The freshness-vs-consistency trade-off was an explicit product decision
    // (design doc open question 5). Reversing it must stay a ONE-FUNCTION
    // edit, so pin that the policy lives in exactly one named place and that
    // both of its knobs are read from there rather than hardcoded at the use
    // sites.
    test('the policy lives in a single named function', () {
      final source = _read('web/sw.js');
      expect(source, contains('function shellStrategy()'));
      expect(
        RegExp(r'function shellStrategy\(\)').allMatches(source),
        hasLength(1),
      );
    });

    test('both knobs are read from the policy, never hardcoded at use sites',
        () {
      final source = _read('web/sw.js');
      expect(source, contains('SHELL_STRATEGY.takeOverImmediately'));
      expect(source, contains('SHELL_STRATEGY.networkFirstPaths'));
      expect(
        RegExp(r'self\.skipWaiting\(\)').allMatches(source),
        hasLength(1),
        reason: 'exactly one skipWaiting call, gated on the policy',
      );
    });

    test('documents the trade-off and names the alternative', () {
      final source = _read('web/sw.js');
      expect(
        source,
        contains('schema'),
        reason: 'the mixed-shell risk interacts with the local database '
            'schema version — that must be stated, not implied',
      );
      expect(source, contains('one-load-behind'));
    });
  });

  group('web/index.html service-worker wiring', () {
    test('registers our worker', () {
      expect(_read('web/index.html'), contains("register('sw.js')"));
    });

    test('never references Flutter\'s deprecated worker', () {
      expect(
        _read('web/index.html'),
        isNot(contains('flutter_service_worker')),
        reason: 'registering it at the same scope replaces ours with a shim '
            'that unregisters itself and reloads every client',
      );
    });

    test('sets the two globals the diagnostics row and the harness read', () {
      final source = _read('web/index.html');
      expect(source, contains('__masiFirstFrame'));
      expect(source, contains('__masiShellWarmed'));
    });

    test('warms the cache from the page\'s own resource timing', () {
      final source = _read('web/index.html');
      expect(source, contains("getEntriesByType('resource')"));
      expect(source, contains("type: 'masi-warm'"));
    });
  });
}
