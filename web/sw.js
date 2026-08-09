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
//                         build it came from. A cache MISS with no network
//                         fails fast (see `cacheFirst`) instead of waiting on
//                         a fetch that cannot succeed.
//   renderer artifacts -> cached BEST-EFFORT at install by
//                         `rendererArtifacts()` — never via the atomic
//                         `addAll` — because the static manifest cannot name
//                         which of the two Dart bundles and which canvaskit
//                         variant this browser will use (the loader picks at
//                         runtime, and a browser runs exactly ONE of each).
//                         That install-time pick is a
//                         GUESS — a worker has no `document` and so cannot run
//                         the loader's WebGL probe — and it is CORRECTED by the
//                         `masi-observed` list the page posts from a
//                         `PerformanceObserver` before its first frame. Without
//                         both, an offline cold start hangs on the splash
//                         forever; see `rendererArtifacts()`.
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
// `tool/gen_sw_manifest.dart` rewrites EXACTLY these four lines in
// `build/web/sw.js` after `flutter build web`. Each must stay on one line and
// keep this exact shape; `test/web_shell_source_test.dart` pins that, because
// a reformat here would silently ship an empty precache and the app would
// still look fine online.
//
// `PRECACHE` is the ATOMIC set (`cache.addAll` at install — all or nothing).
// `PRECACHE_WASM` and `PRECACHE_JS` are the two renderer bundles a `--wasm`
// build emits, of which a given browser executes exactly ONE; they are
// deliberately NOT in `PRECACHE`, and are fetched best-effort by
// `rendererArtifacts()` below. See its doc for why, and
// `tool/gen_sw_manifest.dart`'s `isPrecacheExcluded` for what it cost to
// precache both.
//
// The committed values are the dev defaults. An unsubstituted worker — served
// by `flutter run -d chrome` or `flutter drive -d web-server`, neither of
// which runs the generator — precaches nothing and passes every request
// through, which is what those harnesses want.
const SHELL_VERSION = 'dev';
const PRECACHE = [];
const PRECACHE_WASM = [];
const PRECACHE_JS = [];
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
 * THE RENDERER, which the static precache manifest structurally cannot name.
 *
 * READ THIS FIRST: `rendererArtifacts()` below is a GUESS, not the loader's
 * decision, and it CANNOT be made into the loader's decision here. The loader's
 * real rule is `supportsWasmGC && webGLVersion > 0 && wasmAllowList[engine]`
 * (`flutter_web_sdk/flutter_js/src/loader.js:13-14`), and a ServiceWorker has
 * no `document`, so it can never run `detectWebGLVersion()` — that probe
 * creates a canvas. When WebGL is absent the loader falls back to
 * dart2js/canvaskit and `canvaskit_loader.js:15-22` then picks the *chromium*
 * canvaskit variant on blink. So on blink + WasmGC + NO WebGL (GPU blocklisted,
 * `--disable-gpu`, WebGL disabled by policy, some VM/RDP sessions, and this
 * repo's own headless harness) the guess below caches `skwasm.*` while the page
 * needs `main.dart.js` + `canvaskit/chromium/canvaskit.{js,wasm}`. No better
 * heuristic exists inside a worker.
 *
 * The guess is kept anyway because install is the ONLY chance to cache anything
 * before a message can arrive, and it is right for essentially all real Chrome.
 * THE AUTHORITY THAT CORRECTS IT is the page: `web/index.html`'s early
 * `PerformanceObserver` reports the URLs the loader ACTUALLY fetched — observed,
 * not inferred — and `masi-observed` below stores them through the very same
 * `cacheMissing()`. That reporter is deliberately not gated on
 * `flutter-first-frame`, so unlike the warm pass it also runs on a load that
 * never paints.
 *
 * `tool/gen_sw_manifest.dart` excludes BOTH renderer bundles (`main.dart.wasm`
 * + `main.dart.mjs`, and `main.dart.js`) and all of `canvaskit/` (37 MB across
 * six variants) because exactly ONE of each is used per browser and the loader
 * decides which at runtime. The dart2wasm pair used to be precached
 * unconditionally, which meant every iPhone Safari visitor atomically
 * downloaded ~4.2 MB — about 70% of the precache — that WebKit can never
 * execute, on the first visit and again after every deploy. The intent was to
 * warm the runtime-chosen ones from the page's resource timing after the first
 * frame — but that warm is a RACE, not a guarantee:
 *
 *   - it is posted from `flutter-first-frame`, so it never runs at all on a
 *     load that fails to paint (which is exactly the offline load we are
 *     trying to make work);
 *   - `activate` deletes the previous per-build cache, so EVERY deploy resets
 *     the renderer to "not cached". A user who opens the app online once after
 *     a deploy (installing the new worker, dropping the old cache) and goes
 *     offline before the warm finishes has a cache with no renderer in it, and
 *     the next cold start hangs on the splash forever;
 *   - `tool/verify_offline_shell.py` USED to wait for `__masiShellWarmed`
 *     before it killed the origin, so the harness masked this entire bug class.
 *     It now waits only for the worker to activate and for the early reporter
 *     to land, and kills the origin BEFORE the first frame can fire — so the
 *     warm provably cannot be what makes the offline assertion pass.
 *
 * So install precaches the renderer THIS scope will actually need, best-effort
 * and per-URL (below). Which one is decided the same way `flutter.js` decides
 * it, from `_flutter.buildConfig` (`useLocalCanvasKit: true`, two builds:
 * dart2wasm/skwasm and dart2js/canvaskit):
 *
 *   - skwasm requires WasmGC **and** an allow-listed browser engine. The
 *     loader's default `wasmAllowList` is `{blink: true, gecko: false,
 *     webkit: false, unknown: false}` — so Safari takes the dart2js/canvaskit
 *     build even on a WebKit that supports WasmGC, and needs `PRECACHE_JS`
 *     (`main.dart.js`) plus the FULL `canvaskit/canvaskit.{js,wasm}` (the
 *     smaller `chromium/` variant requires `ImageDecoder` +
 *     `Intl.v8BreakIterator`, both blink-only);
 *   - blink takes skwasm: `PRECACHE_WASM` (`main.dart.wasm` +
 *     `main.dart.mjs`) plus `canvaskit/skwasm.{js,wasm}`. skwasm's `.ww.js`
 *     worker is built from a Blob by the loader, never fetched, so it needs no
 *     entry.
 *
 * The two bundle lists are STAMPED, not hardcoded, so a `--js`-only build (see
 * `tool/build_web.sh --js`) simply stamps an empty `PRECACHE_WASM` and the
 * blink branch degrades to canvaskit-only rather than 404-ing on a file the
 * build never emitted.
 *
 * Cost, stated explicitly, because it is a product decision: ~+7.8 MB on
 * blink, ~+16 MB on everything else, on top of the ~1.3 MB atomic manifest —
 * i.e. the same total bytes as before per browser, minus the ~4.2 MB of dead
 * renderer every non-blink visitor used to be charged. Nothing cheaper exists;
 * these are the bytes the engine cannot boot without. Per-deploy download is
 * far smaller: `web/_headers` serves everything `Cache-Control: no-cache`, so
 * the (engine-revision-stable) canvaskit/skwasm wasm revalidates to a 304 and
 * only the Dart bundle is a real transfer. We deliberately do NOT
 * `cache: 'reload'` these, so that revalidation can happen.
 *
 * MOVING THE DART BUNDLE ONTO THIS BEST-EFFORT PATH IS THE POINT, not a
 * shortcut around it: promoting it back into `PRECACHE`'s `addAll` would make
 * a single failed renderer fetch abort the whole install, leaving the user on
 * the PREVIOUS build with every fix in the deploy undelivered. A renderer that
 * is merely missing costs one offline cold start, and the page's own
 * `masi-observed` reporter re-stores it on the very next online load. The
 * bundle is also in `PER_BUILD_SHELL`, so an online client gets it
 * network-first regardless of what install managed to cache.
 *
 * NOT covered on purpose: `skwasm_heavy` and `wimp`. Choosing between them
 * needs `ImageDecoder`, which is `[Exposed=(Window,DedicatedWorker)]` and so is
 * always undefined here — probing it in a service worker would confidently
 * cache the wrong 5 MB. A blink browser that ends up on one of those still
 * fetches it online and the warm pass still catches it, exactly as today.
 */
function supportsWasmGc() {
  try {
    // The same 15-byte module `flutter.js` validates: a type section declaring
    // one GC struct type. `validate` is false on an engine without WasmGC.
    return WebAssembly.validate(
      new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0, 1, 5, 1, 95, 1, 120, 0])
    );
  } catch (error) {
    return false;
  }
}

function isBlinkLike() {
  const ua = (self.navigator && self.navigator.userAgent) || '';
  // Every browser on iOS is WebKit whatever it calls itself, and those are
  // precisely the ones that advertise a Chrome-ish token while taking the
  // dart2js path. Check them first.
  if (/(CriOS|EdgiOS|FxiOS|OPiOS|GSA)\//.test(ua)) return false;
  return /(Chrome|Chromium|Edg)\/\d/.test(ua);
}

function rendererArtifacts() {
  if (supportsWasmGc() && isBlinkLike()) {
    return PRECACHE_WASM.concat([
      'canvaskit/skwasm.js',
      'canvaskit/skwasm.wasm',
    ]);
  }
  return PRECACHE_JS.concat([
    'canvaskit/canvaskit.js',
    'canvaskit/canvaskit.wasm',
  ]);
}

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
      // AFTER the all-or-nothing block, and deliberately best-effort: a
      // renderer download that fails must not abort the install, because an
      // aborted install strands the user on the previous build. A renderer
      // that is merely missing costs an offline cold start, which is what the
      // warm pass then retries; a failed update costs every fix in the deploy.
      //
      // This now carries the Dart bundle (`PRECACHE_WASM`/`PRECACHE_JS`) as
      // well as the canvaskit variant. That is the whole renderer fix: only
      // the bundle THIS browser can execute is fetched, instead of `addAll`
      // atomically downloading the dart2wasm pair onto every iPhone.
      await cacheMissing(cache, rendererArtifacts());
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

  // A miss with no network cannot be satisfied, so do not start a fetch that
  // can only stall. `fetch()` here is deliberately NOT wrapped in
  // `withTimeout` — `main.dart.wasm` is 4 MB and a slow-but-working link must
  // still be allowed to finish it — which is precisely why the offline case
  // needs its own answer: an unbounded fetch on a dead network is how the
  // engine ends up awaiting an asset forever with the HTML splash still up.
  // `Response.error()` is a network-error response, so the caller sees a
  // failed request immediately and runs its own degradation path.
  //
  // `navigator.onLine === false` is trusted in the NEGATIVE direction only.
  // `true` is the unreliable half (a captive portal reports connected), which
  // is why `reachabilityProvider` probes rather than reading this flag — but a
  // browser that says it has no network never secretly has one. Nothing is
  // deleted or downgraded on this path; the cache is only ever read.
  //
  // CORRECTING THE RECORD: commit c19dde5's message claimed this guard is what
  // fixes the offline splash hang. It is not, and it cannot be — MEASURED in
  // headless Chrome with the origin process killed, `navigator.onLine` stays
  // `true` (it reports interface state, not reachability, the same reason
  // `reachabilityProvider` exists). So this branch does not even run in the
  // scenario it was credited with. It is defence-in-depth for a genuinely
  // offline interface. What actually fixes the hang is having the bytes in the
  // cache: the install-time precache plus the page's observed-resource list.
  if (self.navigator.onLine === false) return Response.error();

  const response = await fetch(request);
  if (isCacheable(response)) {
    event.waitUntil(cache.put(request, response.clone()));
  }
  return response;
}

/**
 * Page-reported URL lists. TWO senders, one mechanism:
 *
 *   `masi-observed`  the EARLY reporter — `web/index.html`'s
 *                    `PerformanceObserver({type:'resource', buffered:true})`,
 *                    which posts what the loader actually fetched as it
 *                    happens, long before the first frame and (crucially) even
 *                    on a load that never paints. This is what corrects
 *                    `rendererArtifacts()`'s unavoidable guess; see its doc.
 *   `masi-warm`      the first-frame BACKSTOP sweep, kept for assets loaded
 *                    lazily after paint. It is a superset-in-principle and a
 *                    no-op in practice, because the early reporter got there
 *                    first.
 *
 * Both go through `cacheMissing()` so the semantics are identical by
 * construction: fetch only what is missing, tolerate per-URL failure, never
 * abandon the rest. The precache deliberately omits `canvaskit/**` (37 MB
 * across six variants, of which a browser uses exactly one) and `main.dart.js`
 * (4.2 MB, used only by browsers that do not take the skwasm path), so an
 * observed list is the only accurate source for those.
 *
 * Message shapes are untrusted: anything with a `postMessage` handle to this
 * worker can send anything. `normalisedUrls` reduces every hostile shape to an
 * empty list rather than letting it throw out of a `waitUntil`.
 */
self.addEventListener('message', (event) => {
  const data = event.data;
  if (!data || typeof data !== 'object') return;
  if (data.type === 'masi-observed') {
    event.waitUntil(
      reportUrls(normalisedUrls(data.urls), event.source, 'masi-observed-done')
    );
    return;
  }
  if (data.type === 'masi-warm') {
    event.waitUntil(
      reportUrls(normalisedUrls(data.urls), event.source, 'masi-warm-done')
    );
  }
});

/** Every non-string, and every non-array, becomes an empty list. */
function normalisedUrls(value) {
  if (!Array.isArray(value)) return [];
  return value.filter((entry) => typeof entry === 'string');
}

async function reportUrls(urls, client, doneType) {
  const cache = await caches.open(CACHE_NAME);
  const stored = [];
  const cached = await cacheMissing(cache, urls, stored);
  // The ack is diagnostics only (a console line, the Account screen's storage
  // row, and the harness's settle signal). A client that has already navigated
  // away throws here, and that must not turn a successful cache write into a
  // rejected `waitUntil`.
  try {
    if (client) {
      client.postMessage({
        type: doneType,
        version: SHELL_VERSION,
        cached: cached,
        total: urls.length,
        stored: stored,
      });
    }
  } catch (error) {
    // Ignored on purpose.
  }
}

/**
 * Stores any of [urls] not already in [cache], one at a time, tolerating
 * per-URL failure. Shared by the install-time renderer precache, the early
 * observed-resource reporter and the first-frame warm, which want identical
 * semantics: fetch only what is missing, never let one bad URL take the rest
 * down. Returns how many are now cached.
 *
 * Accepts scope-relative paths or absolute same-origin URLs — both page-driven
 * paths supply the latter (straight from resource-timing entry names).
 *
 * The URL parse is INSIDE the try: these lists arrive over `postMessage`, and
 * `new URL('%', SCOPE)` throws. Parsing outside would let one malformed entry
 * reject the whole `waitUntil` and abandon every URL after it.
 *
 * [storedOut], when supplied, collects the paths this call NEWLY stored — as
 * opposed to found already present. That distinction is the only way to
 * attribute a cache entry to one sender: a URL reported `stored` by
 * `masi-observed` was put there by the early reporter and by nothing else, which
 * is what `tool/verify_offline_shell.py` requires before it will call a run a
 * pass (otherwise the first-frame warm could have done the work and the run
 * would prove nothing).
 */
async function cacheMissing(cache, urls, storedOut) {
  let cached = 0;
  for (const url of urls) {
    try {
      const absolute = new URL(url, SCOPE).href;
      const path = scopedPath(absolute);
      if (path === null || NEVER_CACHE.has(path)) continue;
      if (await cache.match(absolute)) { cached++; continue; }
      // Same reasoning as `cacheFirst`: with no network there is nothing to
      // fetch, and this loop is awaited by `install` and by a `waitUntil`.
      if (self.navigator.onLine === false) continue;
      const response = await fetch(absolute);
      if (isCacheable(response)) {
        await cache.put(absolute, response.clone());
        cached++;
        // The absolute PATHNAME, not `path`: `scopedPath` strips the scope
        // prefix, so under scope `/` it yields `canvaskit/x.wasm` with no
        // leading slash and nothing comparing against `location.pathname`-style
        // values would ever match it.
        if (storedOut) storedOut.push(new URL(absolute).pathname);
      }
    } catch (error) {
      // Ignored on purpose — see the docs on both callers.
    }
  }
  return cached;
}

/* ---------------------------------------------------------------------------
 * Web Push.
 *
 * The notification centre and the Realtime channel both only work while the
 * app is OPEN. This is the half that reaches a phone with the app closed, and
 * it has to live in the worker because that is the only thing the browser will
 * wake up when the app is not running.
 *
 * The payload is written by the Edge Function that fans out on a
 * `public.notifications` insert. It is decrypted by the browser before it gets
 * here, so it is trustworthy in the sense that it came from our VAPID key —
 * but it is still JSON off the network, so every field is treated as absent
 * until proven otherwise. A push that throws here is a push the user never
 * sees, and on some browsers a worker that repeatedly throws in `push` gets
 * its subscription revoked.
 * ------------------------------------------------------------------------ */

/** Everything a malformed payload degrades to. */
const PUSH_FALLBACK = {
  title: 'Masi',
  body: 'Something happened on one of your topos.',
  url: '/notifications',
  tag: undefined,
};

self.addEventListener('push', (event) => {
  event.waitUntil(showPush(event.data));
});

async function showPush(data) {
  const payload = parsePushPayload(data);
  await self.registration.showNotification(payload.title, {
    body: payload.body,
    // The app icon, not a per-notification image: this is the one asset
    // guaranteed to be in the precache, so it renders offline and cannot
    // become a network fetch the browser cancels.
    icon: new URL('icons/Icon-192.png', SCOPE).href,
    badge: new URL('icons/Icon-192.png', SCOPE).href,
    // `tag` collapses repeats. The server sends one per subject (a topo, an
    // ascent), so ten comments on one topo replace each other on the lock
    // screen instead of burying everything else.
    tag: payload.tag,
    data: { url: payload.url },
  });
}

/**
 * Reduces an untrusted push payload to something showable.
 *
 * Returns the fallback for: no data at all, data that is not JSON, JSON that
 * is not an object, and an object whose fields are the wrong type. A
 * notification saying something vague is recoverable; a worker that throws
 * before `showNotification` shows nothing at all, and Chrome then displays its
 * own "This site has been updated in the background" instead — which is worse
 * than any wording we could pick.
 */
function parsePushPayload(data) {
  if (!data) return PUSH_FALLBACK;
  let raw;
  try {
    raw = data.json();
  } catch (error) {
    return PUSH_FALLBACK;
  }
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
    return PUSH_FALLBACK;
  }
  const text = (value, fallback) =>
    typeof value === 'string' && value.trim().length > 0 ? value : fallback;
  return {
    title: text(raw.title, PUSH_FALLBACK.title),
    body: text(raw.body, PUSH_FALLBACK.body),
    // Same-origin only. `new URL(untrusted, SCOPE)` happily produces
    // `https://evil.example/` for an absolute input, and this URL is handed
    // straight to `clients.openWindow` below — so a hostile payload could
    // otherwise open any site it liked from a tap on a Masi notification.
    url: sameOriginPath(raw.url) || PUSH_FALLBACK.url,
    tag: typeof raw.tag === 'string' && raw.tag.length > 0 ? raw.tag : undefined,
  };
}

/** The resolved href if [value] stays inside our scope, else null. */
function sameOriginPath(value) {
  if (typeof value !== 'string' || value.length === 0) return null;
  try {
    const resolved = new URL(value, SCOPE);
    // Origin AND path prefix, matching `scopedPath`'s two checks above: a
    // same-origin URL outside our registration scope is still not ours.
    if (resolved.origin !== SCOPE.origin) return null;
    if (!resolved.pathname.startsWith(SCOPE.pathname)) return null;
    return resolved.href;
  } catch (error) {
    return null;
  }
}

/**
 * Tapping a notification focuses the app if it is already open, and only opens
 * a new window if it is not.
 *
 * Focusing rather than always opening matters more than it looks: the app is a
 * local-first PWA holding an OPFS-backed database, and a second window on the
 * same origin is a second client contending for the same storage. Reusing the
 * existing client also means the user lands back where they were.
 */
self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const target = sameOriginPath(event.notification.data && event.notification.data.url)
    || new URL(PUSH_FALLBACK.url, SCOPE).href;
  event.waitUntil(focusOrOpen(target));
});

async function focusOrOpen(target) {
  const all = await self.clients.matchAll({
    type: 'window',
    includeUncontrolled: true,
  });
  for (const client of all) {
    // Any window on this origin will do — `navigate` moves it to the right
    // place. Matching on exact URL would open a duplicate window whenever the
    // user happened to be on a different screen, which is almost always.
    if ('focus' in client) {
      try {
        if ('navigate' in client) await client.navigate(target);
      } catch (error) {
        // A cross-origin or otherwise un-navigable client. Focusing it is
        // still better than opening a second window.
      }
      return client.focus();
    }
  }
  if (self.clients.openWindow) return self.clients.openWindow(target);
}
