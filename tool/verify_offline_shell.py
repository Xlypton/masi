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
  3. loads the app, waits for its first frame AND for the service worker's
     warm pass to finish;
  4. asserts the worker is active, the cache is named for this build, the
     precache holds every stamped URL, and `crossOriginIsolated` is true;
  5. KILLS THE SERVER — not a CDP offline emulation, an actually dead
     origin — and reloads;
  6. asserts the app reaches its first frame anyway and is STILL
     cross-origin isolated, which is what proves the cached responses kept
     their COOP/COEP headers (and therefore that drift can still reach OPFS).

Usage:

    tool/build_web.sh                 # must run first; stamps build/web/sw.js
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


def check_online(browser, url, version, precache):
    browser.navigate(url)

    await_first_frame(browser, 45000, "the online load never painted")

    warm = browser.execute_async(WAIT_WARMED, [45000])
    require(warm.get("ok"), f"warm pass never completed: {warm.get('reason')}")

    state = browser.execute_async(READ_STATE)
    require("error" not in state, f"probe threw: {state.get('error')}")

    require(
        state["swState"] == "activated",
        f"service worker is '{state['swState']}', expected 'activated'",
    )
    require(
        state["swScript"] and state["swScript"].endswith("/sw.js"),
        f"the active worker is {state['swScript']}, not our /sw.js — if this "
        f"is flutter_service_worker.js then --pwa-strategy=none is missing "
        f"and the loader clobbered our registration",
    )
    require(state["controlled"], "the page is not controlled by the worker")
    require(
        state["crossOriginIsolated"],
        "crossOriginIsolated is FALSE on the online load — COOP/COEP did not "
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

    # The warm pass must have picked up the renderer, which is deliberately
    # NOT precached. Without this the offline reload below would be the first
    # place we found out.
    renderer = [u for u in cached if u.startswith("/canvaskit/")]
    require(
        renderer,
        "no canvaskit/ asset was warmed — the renderer would be missing "
        "offline. Check web/index.html's flutter-first-frame warm hook.",
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

        print("==> online load")
        check_online(browser, url, version, precache)
        print(
            "    ok: worker active, precache complete, renderer warmed, "
            "crossOriginIsolated"
        )

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

        print("==> offline cold start")
        browser.navigate("about:blank")
        browser.navigate(url)
        check_offline(browser)
        print("    ok: the app painted with no network, still isolated")

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
