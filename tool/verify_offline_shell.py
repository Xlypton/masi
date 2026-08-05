#!/usr/bin/env python3
"""Automated proof that the Masi PWA boots with NO network.

This is Stage 2's headline claim and the one thing `tool/drive_web.sh` cannot
check: `flutter drive -d web-server` serves a freshly-compiled dev bundle, so
`build/web/sw.js` (the only copy `tool/gen_sw_manifest.dart` ever stamps) is
never involved, and the drive device has no `--web-header` flag so it cannot
send COOP/COEP either.

What this does instead:

  1. serves the REAL `build/web` with the same COOP/COEP headers Cloudflare
     Pages sets from `web/_headers`, via `tool/serve_web_isolated.py`;
  2. drives headless Chrome through chromedriver over plain HTTP (no
     websocket, no CDP, no third-party client — chromedriver is already a
     hard requirement of tool/drive_web.sh);
  3. PRIMES: loads the app once and waits ONLY for the service worker to
     reach `activated` and for the page's early observed-resource reporter
     to have got the renderer into the cache;
  4. asserts the worker is active, the cache is named for this build, the
     precache holds every stamped URL, every renderer artifact the loader
     ACTUALLY fetched is cached, and `crossOriginIsolated` is true;
  5. KILLS THE SERVER — not a CDP offline emulation, an actually dead
     origin — destroys the primed page, and loads the app cold;
  6. asserts the app reaches its first frame anyway and is STILL
     cross-origin isolated, which is what proves the cached responses kept
     their COOP/COEP headers (and therefore that drift can still reach OPFS).

WHAT CHANGED, AND WHY IT MATTERS: this script used to wait for
`__masiShellWarmed` — the first-frame warm pass — before killing the origin.
That structurally masked an entire bug class, and did mask a real one. The warm
is posted from `flutter-first-frame`, so it only exists on a load that PAINTED;
by waiting for it, the harness guaranteed the cache was already correct before
it ever tested anything, and a wrong install-time renderer guess could never
show up. It now waits only for `activated` plus a bounded settle, and — this is
the part that makes it able to fail — it REQUIRES that the renderer entries were
NEWLY STORED BY THE EARLY REPORTER, read from the `stored` list in the
`masi-observed` ack. Merely finding them in the cache is not enough, because the
warm caches the same URLs from the same source: with the reporter deleted and
only "is it cached" asserted, this harness passed. Measured, on this machine.
The warm is still checked — separately, at the end, and never as a precondition.

The browser flags are load-bearing, `--disable-gpu` above all. It makes
`detectWebGLVersion()` return 0, so the loader takes dart2js/canvaskit and
`canvaskit_loader.js` picks the `chromium/` variant — i.e. this harness runs as
the exact population `web/sw.js`'s install-time guess gets WRONG (blink +
WasmGC + no WebGL). That is the point of it, not a limitation.

Usage:

    # must run first; stamps build/web/sw.js
    tool/build_web.sh
    #   ...or, without the gate:
    #   flutter build web --wasm --no-web-resources-cdn --pwa-strategy=none
    #   dart run tool/gen_sw_manifest.dart build/web
    python3 tool/verify_offline_shell.py [port]

Exit code 0 means every assertion held. Anything else prints the failing
assertion and the browser console log.

Deliberately stdlib-only (urllib + json + subprocess). Adding a WebDriver
client library to this repo for one script is not worth the dependency.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

REPO_ROOT = os.path.normpath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
)
BUILD_DIR = os.path.join(REPO_ROOT, "build", "web")
CHROMEDRIVER_PORT = 9515


class Failure(Exception):
    """An assertion that did not hold."""


# --------------------------------------------------------------------------
# Minimal W3C WebDriver client
# --------------------------------------------------------------------------

def _request(method, url, payload=None, timeout=120):
    data = json.dumps(payload).encode() if payload is not None else None
    request = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json; charset=utf-8"},
        method=method,
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.loads(response.read().decode())
    except urllib.error.HTTPError as error:
        body = error.read().decode(errors="replace")
        raise Failure(f"{method} {url} -> HTTP {error.code}: {body}") from None


class Browser:
    def __init__(self, driver_url, profile_dir):
        self.base = driver_url
        caps = {
            "capabilities": {
                "alwaysMatch": {
                    "goog:chromeOptions": {
                        "args": [
                            "--headless=new",
                            "--disable-gpu",
                            "--no-sandbox",
                            "--window-size=1200,900",
                            # A hermetic, single-use profile.
                            #
                            # Without this, a Chrome left behind by a previous
                            # run keeps the default profile's lock, and the
                            # NEXT run comes up crippled: service-worker
                            # registration fails with
                            # `AbortError: Operation has been aborted` and
                            # drift reports
                            # `backend=inMemory ... missingFeatures=...,indexedDb`,
                            # because the storage layer never initialises. That
                            # looks exactly like a real offline-shell failure
                            # and is not one — it cost a wrong diagnosis once
                            # already. A per-run directory makes the runs
                            # independent no matter how the previous one died.
                            f"--user-data-dir={profile_dir}",
                        ]
                    },
                    # Chrome's own /se/log channel; this is how the
                    # `masi/storage:` and `masi/sw:` release log lines are
                    # read back.
                    "goog:loggingPrefs": {"browser": "ALL"},
                }
            }
        }
        result = _request("POST", f"{self.base}/session", caps)
        self.sid = result["value"]["sessionId"]
        _request(
            "POST",
            f"{self.base}/session/{self.sid}/timeouts",
            {"script": 60000, "pageLoad": 60000},
        )

    def quit(self):
        try:
            _request("DELETE", f"{self.base}/session/{self.sid}", timeout=20)
        except Exception:
            pass

    def navigate(self, url):
        _request("POST", f"{self.base}/session/{self.sid}/url", {"url": url})

    def execute_async(self, script, args=None):
        """Runs `script` with a trailing `done` callback (W3C async script)."""
        result = _request(
            "POST",
            f"{self.base}/session/{self.sid}/execute/async",
            {"script": script, "args": args or []},
        )
        return result["value"]

    def console(self):
        try:
            result = _request(
                "POST",
                f"{self.base}/session/{self.sid}/se/log",
                {"type": "browser"},
            )
        except Failure:
            return []
        return [entry.get("message", "") for entry in result.get("value", [])]


# --------------------------------------------------------------------------
# Browser-side probes
# --------------------------------------------------------------------------

# Resolves once the Flutter app has painted, or rejects after `ms`.
WAIT_FIRST_FRAME = """
const done = arguments[arguments.length - 1];
const deadline = Date.now() + arguments[0];
(function poll() {
  if (window.__masiFirstFrame === true) { done({ok: true}); return; }
  if (Date.now() > deadline) { done({ok: false, reason: 'no first frame'}); return; }
  setTimeout(poll, 100);
})();
"""

WAIT_WARMED = """
const done = arguments[arguments.length - 1];
const deadline = Date.now() + arguments[0];
(function poll() {
  if (window.__masiShellWarmed === true) { done({ok: true}); return; }
  if (Date.now() > deadline) { done({ok: false, reason: 'shell never warmed'}); return; }
  setTimeout(poll, 100);
})();
"""

# Resolves once the service worker OWNS this scope, which is all the priming
# phase is allowed to wait for on the page's behalf. `activated` implies install
# finished, which implies the precache and the install-time renderer guess are
# both written.
WAIT_SW_ACTIVATED = """
const done = arguments[arguments.length - 1];
const deadline = Date.now() + arguments[0];
(async function poll() {
  if (!('serviceWorker' in navigator)) {
    done({ok: false, reason: 'no serviceWorker in this browser'});
    return;
  }
  try {
    const reg = await navigator.serviceWorker.getRegistration();
    if (reg && reg.active && reg.active.state === 'activated') {
      done({ok: true, script: new URL(reg.active.scriptURL).pathname});
      return;
    }
  } catch (error) {
    done({ok: false, reason: String(error)});
    return;
  }
  if (Date.now() > deadline) {
    done({ok: false, reason: 'the worker never reached activated'});
    return;
  }
  setTimeout(poll, 100);
})();
"""

# THE BOUNDED SETTLE, and the reason this harness can now fail.
#
# It resolves when every renderer artifact THIS PAGE actually fetched is in the
# per-build cache AND the EARLY REPORTER is the thing that put it there. Both
# halves are necessary:
#
#   - the set comes from resource timing, so it is the loader's real choice, not
#     a guess. Under `--disable-gpu` it is `/main.dart.js` +
#     `/canvaskit/chromium/canvaskit.{js,wasm}` — exactly what `web/sw.js`'s
#     install-time `rendererArtifacts()` does NOT precache;
#   - attribution comes from `__masiObservedStored`, the `stored` list in the
#     `masi-observed` ack, which the worker fills only with entries it NEWLY put
#     (a URL already present is reported as merely `cached`). Without this the
#     harness could not tell the early reporter from the first-frame warm and
#     would pass with the reporter deleted — MEASURED, not hypothetical: the
#     warm won the race in that exact experiment.
#
# `firstFrame`/`warmed` are still reported, as diagnostics. They are NOT the
# gate, because on a FIRST visit both page-side reporters are queued behind
# `navigator.serviceWorker.ready` (install has ~9.6 MB to download first), so
# the first frame can legitimately land before the reporter is even able to
# post. `stored` is immune to that ordering.
WAIT_RENDERER_CACHED = """
const done = arguments[arguments.length - 1];
const deadline = Date.now() + arguments[0];
const prefix = location.origin + '/';
function rendererPaths() {
  const out = [];
  for (const entry of performance.getEntriesByType('resource')) {
    const name = entry && entry.name;
    if (typeof name !== 'string' || name.indexOf(prefix) !== 0) continue;
    const path = new URL(name).pathname;
    if (path.indexOf('/canvaskit/') === 0 || path === '/main.dart.js') {
      if (out.indexOf(path) === -1) out.push(path);
    }
  }
  return out;
}
(async function poll() {
  const state = {
    acks: window.__masiObservedAcks || 0,
    posted: window.__masiObservedPosted || 0,
    observedCached: window.__masiObservedCached || 0,
    observedStored: (window.__masiObservedStored || []).slice(),
    firstFrame: window.__masiFirstFrame === true,
    warmed: window.__masiShellWarmed === true,
    renderer: rendererPaths(),
    rendererCached: [],
    rendererStoredByReporter: [],
  };
  try {
    const names = (await caches.keys())
      .filter((n) => n.indexOf('masi-shell-') === 0);
    if (names.length === 1) {
      const cache = await caches.open(names[0]);
      const keys = await cache.keys();
      const cached = keys.map((r) => new URL(r.url).pathname);
      state.rendererCached =
        state.renderer.filter((p) => cached.indexOf(p) !== -1);
    }
  } catch (error) {
    state.error = String(error);
  }
  state.rendererStoredByReporter =
    state.renderer.filter((p) => state.observedStored.indexOf(p) !== -1);
  if (state.renderer.length > 0 &&
      state.rendererCached.length === state.renderer.length &&
      state.rendererStoredByReporter.length === state.renderer.length) {
    state.ok = true;
    done(state);
    return;
  }
  if (Date.now() > deadline) {
    state.ok = false;
    state.reason = 'the early reporter did not store the renderer (cached ' +
      state.rendererCached.length + '/' + state.renderer.length +
      ', stored by the reporter ' + state.rendererStoredByReporter.length +
      '/' + state.renderer.length + ')';
    done(state);
    return;
  }
  setTimeout(poll, 100);
})();
"""

# Everything the assertions need, in one round trip.
READ_STATE = """
const done = arguments[arguments.length - 1];
(async () => {
  const state = {
    crossOriginIsolated: window.crossOriginIsolated === true,
    firstFrame: window.__masiFirstFrame === true,
    warmed: window.__masiShellWarmed === true,
    cacheNames: [],
    cachedUrls: [],
    swState: 'unsupported',
    swScript: null,
    controlled: false,
  };
  try {
    state.cacheNames = await caches.keys();
    const shell = state.cacheNames.filter((n) => n.indexOf('masi-shell-') === 0);
    if (shell.length === 1) {
      const cache = await caches.open(shell[0]);
      const keys = await cache.keys();
      state.cachedUrls = keys.map((r) => new URL(r.url).pathname);
    }
    if ('serviceWorker' in navigator) {
      state.controlled = !!navigator.serviceWorker.controller;
      const reg = await navigator.serviceWorker.getRegistration();
      if (!reg) {
        state.swState = 'none';
      } else {
        const worker = reg.active || reg.waiting || reg.installing;
        state.swState = worker ? worker.state : 'none';
        state.swScript = worker ? new URL(worker.scriptURL).pathname : null;
      }
    }
  } catch (error) {
    state.error = String(error);
  }
  done(state);
})();
"""


# --------------------------------------------------------------------------
# Assertions
# --------------------------------------------------------------------------

def require(condition, message):
    if not condition:
        raise Failure(message)


def await_first_frame(browser, budget_ms, on_failure):
    """`WAIT_FIRST_FRAME`, with the two ways it can fail folded into one.

    The polling script resolves `{ok: false}` when the page LOADED but never
    painted. But when the page could not load at all — exactly what a dead
    origin plus a broken shell produces — the script never runs, and
    chromedriver answers the `execute/async` call with an HTTP 500
    `script timeout` instead. Left unhandled that surfaces as a wall of
    chromedriver stack frames, burying the one line that matters. Both paths
    mean the same thing here, so both raise `on_failure`.
    """
    try:
        result = browser.execute_async(WAIT_FIRST_FRAME, [budget_ms])
    except Failure as error:
        if "script timeout" in str(error):
            raise Failure(on_failure) from None
        raise
    if not result.get("ok"):
        raise Failure(f"{on_failure} ({result.get('reason')})")
    return result


def stamped_precache():
    """The URL list `tool/gen_sw_manifest.dart` wrote into build/web/sw.js."""
    sw_path = os.path.join(BUILD_DIR, "sw.js")
    if not os.path.isfile(sw_path):
        raise Failure(f"{sw_path} not found — run tool/build_web.sh first")
    with open(sw_path, encoding="utf-8") as handle:
        source = handle.read()
    version_match = re.search(r"^const SHELL_VERSION = '([^']*)';$", source, re.M)
    precache_match = re.search(r"^const PRECACHE = (\[.*\]);$", source, re.M)
    if not version_match or not precache_match:
        raise Failure("build/web/sw.js has no readable BUILD STAMP")
    version = version_match.group(1)
    if version == "dev":
        raise Failure(
            "build/web/sw.js still carries the dev stamp — tool/build_web.sh "
            "did not run tool/gen_sw_manifest.dart"
        )
    precache = json.loads(precache_match.group(1))
    if not precache:
        # Without this, `missing = [p for p in precache if ...]` is empty and
        # the online "precache complete" assertion passes VACUOUSLY — the run
        # would sail through the online phase and only fall over offline, with
        # a confusing timeout instead of a diagnosis.
        raise Failure(
            "build/web/sw.js has an EMPTY precache. Nothing would be cached "
            "at install time, so there is no offline shell to verify. Run "
            "tool/build_web.sh."
        )
    return version, precache


SETTLE_BUDGET_MS = 20000


def prime(browser, url):
    """Load the app once, online, and wait for the LEAST possible.

    Only two things: the worker reaching `activated`, and the bounded settle
    above. Deliberately NOT the first frame and NOT `__masiShellWarmed` — both
    would let the first-frame warm write the cache and make the offline
    assertion vacuous, which is the flaw this replaces.
    """
    browser.navigate(url)

    sw = browser.execute_async(WAIT_SW_ACTIVATED, [60000])
    require(sw.get("ok"), f"the worker never activated: {sw.get('reason')}")
    require(
        sw.get("script", "").endswith("/sw.js"),
        f"the active worker is {sw.get('script')}, not our /sw.js — if this "
        f"is flutter_service_worker.js then --pwa-strategy=none is missing "
        f"and the loader clobbered our registration",
    )

    return browser.execute_async(WAIT_RENDERER_CACHED, [SETTLE_BUDGET_MS])


def check_primed_cache(browser, version, precache, settle):
    """Everything the cache must hold, read AFTER the origin is already dead.

    Reading it late is intentional: nothing here can be satisfied by a fetch,
    so it describes only what the install precache and the page's early
    reporter managed to store while the origin was alive.
    """
    state = browser.execute_async(READ_STATE)
    require("error" not in state, f"probe threw: {state.get('error')}")

    require(
        state["swState"] == "activated",
        f"service worker is '{state['swState']}', expected 'activated'",
    )
    require(state["controlled"], "the page is not controlled by the worker")
    require(
        state["crossOriginIsolated"],
        "crossOriginIsolated is FALSE on the primed load — COOP/COEP did not "
        "arrive, so drift cannot reach OPFS (design doc open question 2)",
    )

    expected_cache = f"masi-shell-{version}"
    require(
        expected_cache in state["cacheNames"],
        f"no {expected_cache} cache; found {state['cacheNames']}",
    )
    require(
        len([n for n in state["cacheNames"] if n.startswith("masi-shell-")]) == 1,
        f"more than one masi-shell cache survived activate: {state['cacheNames']}",
    )

    cached = set(state["cachedUrls"])
    missing = [p for p in precache if "/" + p not in cached]
    require(
        not missing,
        f"{len(missing)} precached url(s) missing from the cache: {missing[:8]}",
    )

    # THE renderer assertion, and it is deliberately about the artifacts the
    # loader REALLY fetched rather than "some canvaskit/ file is present".
    # `web/sw.js`'s install-time guess always caches *a* canvaskit/ pair, so the
    # old shape of this check passed even when the pair was the wrong one.
    observed = settle.get("renderer") or []
    require(
        observed,
        "the page fetched no renderer artifact at all, which cannot happen — "
        "resource timing is empty, so this run proves nothing",
    )
    absent = [p for p in observed if p not in cached]
    if absent:
        # Reported, not raised: the verdict on this belongs to the offline load
        # below, which is the actual claim. Raising here would hide the real
        # symptom (a splash that never goes away) behind a cache inventory.
        print(
            f"    the renderer the loader ACTUALLY chose is NOT cached: "
            f"{absent}\n"
            f"    cached canvaskit paths: "
            f"{sorted(u for u in cached if u.startswith('/canvaskit/'))}\n"
            f"    (web/sw.js's install-time guess is wrong for this engine and "
            f"nothing corrected it)",
            file=sys.stderr,
        )
    return state


def check_offline(browser):
    await_first_frame(
        browser,
        60000,
        "THE ASSERTION: the app did not paint with the origin dead. The "
        "offline shell does not work.",
    )
    state = browser.execute_async(READ_STATE)
    require(
        state["crossOriginIsolated"],
        "crossOriginIsolated is FALSE on the OFFLINE load — the cached "
        "responses lost their COOP/COEP headers, which silently downgrades "
        "drift's storage backend (audit L8's lock-in). Check that web/sw.js "
        "returns cached Response objects verbatim and never rebuilds one.",
    )
    require(state["controlled"], "the offline page is not worker-controlled")
    return state


# --------------------------------------------------------------------------

def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].isdigit() else 8099
    url = f"http://localhost:{port}/"

    if not shutil.which("chromedriver"):
        print("FAIL: chromedriver not found on PATH.", file=sys.stderr)
        print(
            "      Install via Chrome for Testing (mac-arm64) and place it "
            "in /opt/homebrew/bin.",
            file=sys.stderr,
        )
        return 2
    if not os.path.isdir(BUILD_DIR):
        print(
            "FAIL: build/web not found — run tool/build_web.sh first",
            file=sys.stderr,
        )
        return 2

    # A preflight, like the two checks above: report it as a plain FAIL line
    # rather than a traceback, since it means "the build is not ready to be
    # verified", not "the offline shell is broken".
    try:
        version, precache = stamped_precache()
    except Failure as failure:
        print(f"FAIL: {failure}", file=sys.stderr)
        return 2
    print(f"==> shell version {version}, {len(precache)} precached urls")

    server = subprocess.Popen(
        [
            sys.executable,
            os.path.join(REPO_ROOT, "tool", "serve_web_isolated.py"),
            str(port),
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    driver = subprocess.Popen(
        ["chromedriver", f"--port={CHROMEDRIVER_PORT}"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    profile_dir = tempfile.mkdtemp(prefix="masi_offline_profile_")
    browser = None
    status = 0
    try:
        _wait_for(url, "static server")
        _wait_for(f"http://127.0.0.1:{CHROMEDRIVER_PORT}/status", "chromedriver")

        browser = Browser(f"http://127.0.0.1:{CHROMEDRIVER_PORT}", profile_dir)

        print("==> priming load (worker + early reporter only, NO warm)")
        settle = prime(browser, url)

        # KILL FIRST, ASK QUESTIONS AFTER. Every millisecond between the settle
        # resolving and the origin dying is a millisecond in which the
        # first-frame warm could still write the cache and make everything
        # below vacuous. So the origin goes down before anything is read back.
        print("==> killing the origin")
        server.terminate()
        server.wait(timeout=15)
        server = None
        # Prove it is really dead before claiming anything about offline.
        try:
            urllib.request.urlopen(url, timeout=3)
            raise Failure(
                "the static server is still answering; the offline "
                "assertion would be meaningless"
            )
        except Failure:
            raise
        except Exception:
            pass
        print("    ok: origin is unreachable")

        print(
            f"    reporter: {settle.get('acks')} ack(s), "
            f"{settle.get('posted')} url(s) posted, "
            f"{settle.get('observedCached')} cached by the observed path"
        )
        print(
            f"    loader actually fetched: {settle.get('renderer')}\n"
            f"      cached:                {settle.get('rendererCached')}\n"
            f"      STORED BY THE EARLY REPORTER: "
            f"{settle.get('rendererStoredByReporter')}"
        )
        print(
            f"    at kill time: firstFrame={settle.get('firstFrame')} "
            f"warmed={settle.get('warmed')}  (diagnostics only — attribution "
            f"is the STORED list above)"
        )
        settle_failed = not settle.get("ok")
        if settle_failed:
            print(
                f"    WARNING: settle did not complete: {settle.get('reason')}",
                file=sys.stderr,
            )

        check_primed_cache(browser, version, precache, settle)
        print("    ok: precache complete, crossOriginIsolated")

        print("==> offline cold start")
        # `about:blank` first: destroying the primed page is what guarantees no
        # late `flutter-first-frame` handler on it can post anything else.
        browser.navigate("about:blank")
        browser.navigate(url)
        check_offline(browser)
        print("    ok: the app painted with no network, still isolated")

        # ADDITIONAL, and clearly separate: the warm pass is still wired up. It
        # is NOT a precondition of anything above — it runs here for the first
        # time in this whole run, on the offline load, and every URL it reports
        # is already cached.
        print("==> warm pass (additional, not a precondition)")
        warm = browser.execute_async(WAIT_WARMED, [30000])
        require(
            warm.get("ok"),
            f"the first-frame warm pass never completed: {warm.get('reason')}",
        )
        print("    ok: the warm backstop still runs")

        require(
            not settle_failed,
            f"the app booted offline, but the EARLY REPORTER is not what put "
            f"the renderer in the cache ({settle.get('reason')}) — the "
            f"first-frame warm got there instead, so this run proves nothing "
            f"about the load that never paints. Inconclusive, not a pass.",
        )

        print("PASS: offline shell verified")
    except Failure as failure:
        print(f"FAIL: {failure}", file=sys.stderr)
        if browser:
            print("--- browser console ---", file=sys.stderr)
            for line in browser.console():
                print(line, file=sys.stderr)
        status = 1
    finally:
        # Order matters: end the WebDriver session FIRST so chromedriver gets
        # the chance to shut its Chrome down cleanly, and only then stop
        # chromedriver itself. Killing the driver first orphans Chrome.
        if browser:
            browser.quit()
        for process in (server, driver):
            if process and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
        shutil.rmtree(profile_dir, ignore_errors=True)
    return status


def _wait_for(url, label, attempts=100):
    for _ in range(attempts):
        try:
            urllib.request.urlopen(url, timeout=2)
            return
        except Exception:
            time.sleep(0.2)
    raise Failure(f"{label} did not come up at {url}")


if __name__ == "__main__":
    sys.exit(main())
