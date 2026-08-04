// Masi's offline shell service worker.
//
// Flutter 3.44 removed its caching service worker; what it ships now is a
// 31-line deprecation shim that unregisters itself. `tool/build_web.sh`
// therefore builds with `--pwa-strategy=none` (so Flutter's loader never
// registers anything) and `web/index.html` registers THIS worker explicitly.
//
// Strategy, per design doc §2b — but see `shellStrategy()` below, which is the
// single place the freshness-vs-consistency trade-off is decided:
//
//   navigations        -> app shell. The precached/network index.html is
//                         returned for EVERY in-scope navigation, so
//                         `/community/topo/<id>` resolves both offline and
//                         online without a hosting rewrite reaching us.
//   per-build shell    -> network-first with a 4s timeout, cache fallback.
//                         Preserves the #55 fix (an online user always gets
//                         the fresh shell; `web/_headers` keeps `no-cache`,
//                         so the "network" leg is normally a cheap 304) while
//                         an offline user gets a working one.
//   everything else    -> cache-first. Safe because the cache name is
//                         per-build and every other cache is deleted on
//                         activate, so a cached asset can never outlive the
//                         build it came from.
//   cross-origin       -> not intercepted at all. Supabase, Google auth and
//                         OSM tiles go straight to the network. (Stage 3 adds
//                         a separate `masi-runtime-*` tile cache; the prune
//                         below already spares that namespace.)
//
// Cross-origin isolation survives all of this because a Response served from
// the Cache API retains the headers it was stored with — including COOP/COEP
// from `web/_headers`. That is why every path below returns the cached
// Response OBJECT and never reconstructs one, which would drop the headers and
// silently kill `crossOriginIsolated` (and with it drift's OPFS backend).
// `tool/verify_offline_shell.py` asserts `crossOriginIsolated === true` on the
// OFFLINE load for exactly this reason.
'use strict';

// --- BEGIN MASI BUILD STAMP -------------------------------------------------
// `tool/gen_sw_manifest.dart` rewrites EXACTLY these two lines in
// `build/web/sw.js` after `flutter build web`. Each must stay on one line and
// keep this exact shape; `test/web_shell_source_test.dart` pins that, because
// a reformat here would silently ship an empty precache and the app would
// still look fine online.
//
// The committed values are the dev defaults. An unsubstituted worker — served
// by `flutter run -d chrome` or `flutter drive -d web-server`, neither of
// which runs the generator — precaches nothing and passes every request
// through, which is what those harnesses want.
const SHELL_VERSION = 'dev';
const PRECACHE = [];
// --- END MASI BUILD STAMP ---------------------------------------------------

const CACHE_NAME = `masi-shell-${SHELL_VERSION}`;

// Cache namespaces this worker must NOT delete on activate. Everything else
// — including `flutter-app-cache` / `flutter-temp-cache` left behind by a
// pre-3.44 Flutter service worker — is swept, which is what makes registering
// this worker the cleanup for those, too.
const KEEP_CACHE_PREFIX = 'masi-runtime-';

// Network leg budget for the network-first paths. A captive portal that
// accepts the connection and then never answers must not hold up boot.
const NETWORK_TIMEOUT_MS = 4000;

const SCOPE = new URL(self.registration.scope);

// Files whose CONTENT changes every build while their URL does not.
const PER_BUILD_SHELL = new Set([
  '',
  'index.html',
  'flutter_bootstrap.js',
  'main.dart.wasm',
  'main.dart.mjs',
  'main.dart.js',
  'version.json',
  'manifest.json',
]);

// Never cached and never served from cache.
const NEVER_CACHE = new Set([
  'sw.js',
  'flutter_service_worker.js',
  '_headers',
  '_redirects',
  '_routes.json',
]);

// `web/_headers` serves these two `public, max-age=31536000, immutable` on an
// URL that is NOT content-hashed, so an ordinary fetch may be answered from a
// year-old browser cache entry. Precaching them with `cache: 'reload'`
// bypasses the HTTP cache so the precache is genuinely this build's copy.
const RELOAD_ON_PRECACHE = new Set(['sqlite3.wasm', 'drift_worker.js']);

/**
 * THE ONE PLACE THE UPDATE TRADE-OFF IS DECIDED. Changing this function body
 * is the complete edit — nothing below reads the policy from anywhere else.
 *
 * Current choice — FRESHNESS FIRST (network-first + immediate takeover).
 * This is the design doc's §2b strategy and the user's approved decision
 * (open question 5). An online user is never a deploy behind, which is what
 * preserves the #55 fix, and a new worker takes over the moment it installs.
 *
 * The cost, stated plainly, is a MIXED SHELL. Two ways it can happen:
 *   - the network dies mid-load, so a fresh `index.html` pairs with cached
 *     older sub-resources;
 *   - a worker swaps mid-session, so a build-N page late-loads a build-N+1
 *     deferred asset.
 *
 * Why that is not merely cosmetic here: a mixed shell can pair OLD Dart code
 * with a local drift database that NEWER code has already migrated. drift
 * dispatches `onUpgrade` for any version CHANGE, downgrades included, and
 * every branch in `AppDatabase`'s migration is `if (from < N)` — so the older
 * shell runs no branch, returns normally, and drift then stamps the OLDER
 * number into `PRAGMA user_version`. The database now claims a schema version
 * it does not have, and the next current-shell load throws with the user's
 * topos behind an unopenable file. That is audit item L7, and the `from > to`
 * migration guard is what makes this failure loud and non-destructive instead
 * of silent and terminal. This strategy is only safe WITH that guard in place.
 *
 * The alternative — ALWAYS SELF-CONSISTENT, one-load-behind: serve everything
 * from the atomic per-build precache and let a new build apply on the next
 * load. Both mixed-shell windows close completely, at the cost of an installed
 * PWA staying one build behind until it is fully closed and relaunched. To
 * switch, return:
 *
 *     { takeOverImmediately: false, networkFirstPaths: new Set() }
 *
 * (`clients.claim()` on activate is correct either way: without
 * `skipWaiting`, activate only happens once the old clients are gone.)
 */
function shellStrategy() {
  return {
    takeOverImmediately: true,
    networkFirstPaths: PER_BUILD_SHELL,
  };
}

const SHELL_STRATEGY = shellStrategy();

/**
 * Path of `url` relative to this worker's scope, or `null` when it is
 * cross-origin or out of scope.
 */
function scopedPath(url) {
  const u = new URL(url);
  if (u.origin !== SCOPE.origin) return null;
  if (!u.pathname.startsWith(SCOPE.pathname)) return null;
  return u.pathname.slice(SCOPE.pathname.length);
}

function withTimeout(promise, ms) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error('masi/sw: network timeout')),
      ms
    );
    promise.then(
      (value) => { clearTimeout(timer); resolve(value); },
      (error) => { clearTimeout(timer); reject(error); }
    );
  });
}

/**
 * Only same-origin, non-opaque, complete responses are ever stored. A 206, a
 * redirect, or an opaque cross-origin response in the cache would be served
 * back verbatim later and break in ways that are very hard to diagnose.
 */
function isCacheable(response) {
  return !!response && response.status === 200 && response.type === 'basic';
}

self.addEventListener('install', (event) => {
  event.waitUntil((async () => {
    // An unsubstituted dev stamp has nothing to precache. Still activate, so
    // the fetch handler's pass-through behaviour is exercised in dev too.
    if (PRECACHE.length > 0) {
      const cache = await caches.open(CACHE_NAME);
      // `addAll` is all-or-nothing: if any request fails the install rejects,
      // this worker never activates, and the PREVIOUS one keeps serving. That
      // is the property that stops a half-updated shell existing at all.
      //
      // `index.html` is handled separately and NOT via `addAll`, because
      // `addAll` derives the cache key from the URL it fetches and those must
      // differ here: Cloudflare Pages 308s `/index.html` to `/`, so fetching
      // the listed path would store a response carrying `redirected === true`,
      // and serving that to a navigation is what WebKit refuses outright (see
      // `navigationFirst`). Fetch the root, store it under the `index.html`
      // key. Without this the OFFLINE navigation would fail in Safari even
      // once the online path was fixed.
      const shellPath = 'index.html';
      await cache.addAll(
        PRECACHE.filter((path) => path !== shellPath).map((path) => new Request(
          new URL(path, SCOPE),
          RELOAD_ON_PRECACHE.has(path) ? { cache: 'reload' } : undefined
        ))
      );
      if (PRECACHE.includes(shellPath)) {
        const shell = await fetch(new Request(SHELL_NETWORK_URL()));
        // Rethrow-equivalent: keep install all-or-nothing, exactly as `addAll`
        // would have, so a bad shell fetch never yields a half-populated cache.
        if (!isCacheable(shell)) {
          throw new Error(
            `masi/sw: shell precache failed (status ${shell && shell.status})`
          );
        }
        await cache.put(SHELL_CACHE_KEY(), shell);
      }
    }
    if (SHELL_STRATEGY.takeOverImmediately) {
      await self.skipWaiting();
    }
  })());
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    const names = await caches.keys();
    await Promise.all(names.map((name) => {
      if (name === CACHE_NAME) return undefined;
      if (name.startsWith(KEEP_CACHE_PREFIX)) return undefined;
      return caches.delete(name);
    }));
    await self.clients.claim();
  })());
});

self.addEventListener('fetch', (event) => {
  const request = event.request;
  if (request.method !== 'GET') return;

  const path = scopedPath(request.url);
  if (path === null) return;              // cross-origin: not ours
  if (NEVER_CACHE.has(path)) return;      // always straight to the network

  if (request.mode === 'navigate') {
    event.respondWith(navigationFirst(event));
    return;
  }
  if (SHELL_STRATEGY.networkFirstPaths.has(path)) {
    event.respondWith(networkFirst(event, request));
    return;
  }
  event.respondWith(cacheFirst(event, request));
});

/**
 * The shell URLs, which are deliberately NOT the same URL.
 *
 * Cloudflare Pages answers `/index.html` with a **308 to `/`**. That single
 * fact breaks Safari completely, and it is worth spelling out because nothing
 * about the symptom points at it:
 *
 *   - `fetch('/index.html')` follows the 308, so the response it resolves to
 *     has `redirected === true`.
 *   - Returning a response with that flag set from a service worker, *for a
 *     navigation request*, is forbidden. WebKit enforces it and fails the
 *     entire load with `Response served by service worker has redirections`
 *     (WebKitInternal:0) — a blank error page, no app at all.
 *   - Chromium is lenient here, so this is invisible in headless Chrome. It is
 *     also invisible on any FIRST visit in any browser, because no worker
 *     controls that navigation yet. It appears only once the worker is
 *     installed — i.e. exactly for returning users and installed PWAs.
 *
 * So: fetch the SCOPE ROOT (served 200 directly, no redirect), but keep
 * reading and writing the cache under the `index.html` key, because that is
 * the path `PRECACHE` lists and therefore the key the precache populates.
 * Splitting the two is the whole fix; using one URL for both cannot work.
 */
const SHELL_CACHE_KEY = () => new Request(new URL('index.html', SCOPE));
const SHELL_NETWORK_URL = () => new URL('./', SCOPE);

/**
 * A redirected response cannot be repaired here, only avoided.
 *
 * The obvious defence would be to strip the flag by rebuilding the response.
 * That is deliberately NOT done: rebuilding risks dropping COOP/COEP, which
 * kills `crossOriginIsolated` and silently downgrades drift off OPFS. Trading a
 * loud, instantly-reported Safari error for a silent data-layer downgrade is a
 * bad trade, so the invariant in `test/web_shell_source_test.dart` ("never
 * rebuilds a Response") stands, and the redirect is prevented at its source by
 * requesting a URL that does not redirect. That same test also pins that the
 * navigation path never fetches `index.html`, which is the mistake that caused
 * this outage.
 */

/**
 * Network-first app shell for every in-scope navigation, so
 * `/community/topo/<id>` resolves online and offline without a hosting rewrite
 * reaching us.
 *
 * Identical in shape to `networkFirst`, and deliberately kept separate rather
 * than parameterised: this is the one path where the fetched URL and the cache
 * key differ, and collapsing them back into one argument is exactly the change
 * that reintroduces the redirect bug.
 */
async function navigationFirst(event) {
  const cache = await caches.open(CACHE_NAME);
  const cacheKey = SHELL_CACHE_KEY();
  try {
    const response = await withTimeout(
      fetch(new Request(SHELL_NETWORK_URL())),
      NETWORK_TIMEOUT_MS
    );
    if (isCacheable(response)) {
      event.waitUntil(cache.put(cacheKey, response.clone()));
      return response;
    }
    const cached = await cache.match(cacheKey);
    return cached || response;
  } catch (error) {
    const cached = await cache.match(cacheKey);
    if (cached) return cached;
    throw error;   // genuinely nothing to serve: let the browser say so
  }
}

async function networkFirst(event, request) {
  const cache = await caches.open(CACHE_NAME);
  try {
    const response = await withTimeout(fetch(request), NETWORK_TIMEOUT_MS);
    if (isCacheable(response)) {
      // `waitUntil` so the write is not cancelled when the page finishes
      // with the response.
      event.waitUntil(cache.put(request, response.clone()));
      return response;
    }
    // A non-200 (404 after a bad deploy, a captive portal's 511) must not
    // shadow a shell we already know is good.
    const cached = await cache.match(request);
    return cached || response;
  } catch (error) {
    const cached = await cache.match(request);
    if (cached) return cached;
    throw error;   // genuinely nothing to serve: let the browser say so
  }
}

async function cacheFirst(event, request) {
  const cache = await caches.open(CACHE_NAME);
  const cached = await cache.match(request);
  if (cached) return cached;
  const response = await fetch(request);
  if (isCacheable(response)) {
    event.waitUntil(cache.put(request, response.clone()));
  }
  return response;
}

/**
 * Warm pass.
 *
 * The precache deliberately omits `canvaskit/**` (37 MB across four renderer
 * variants, of which a browser uses exactly one) and `main.dart.js` (4.2 MB,
 * used only by browsers without WasmGC). Which of those a given browser needs
 * is decided at runtime by the loader's feature probe, so the only accurate
 * source is what the page actually fetched. After its first frame,
 * `web/index.html` posts its own `performance.getEntriesByType('resource')`
 * list here and we cache whatever is same-origin and not already stored.
 *
 * Deliberately per-URL fault-tolerant, unlike the precache: one asset failing
 * must never abandon the rest.
 */
self.addEventListener('message', (event) => {
  const data = event.data;
  if (!data || data.type !== 'masi-warm') return;
  event.waitUntil(warmShell(data.urls || [], event.source));
});

async function warmShell(urls, client) {
  const cache = await caches.open(CACHE_NAME);
  let cached = 0;
  for (const url of urls) {
    const path = scopedPath(url);
    if (path === null || NEVER_CACHE.has(path)) continue;
    try {
      if (await cache.match(url)) { cached++; continue; }
      const response = await fetch(url);
      if (isCacheable(response)) {
        await cache.put(url, response.clone());
        cached++;
      }
    } catch (error) {
      // Ignored on purpose — see the doc above.
    }
  }
  if (client) {
    client.postMessage({
      type: 'masi-warm-done',
      version: SHELL_VERSION,
      cached: cached,
      total: urls.length,
    });
  }
}
