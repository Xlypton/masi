#!/usr/bin/env python3
"""verify_pointer_geometry.py — real-coordinate regression guard for the
2026-08-05 iOS-PWA touch-offset bug.

WHY THIS EXISTS
----------------
Every existing integration test drives the app via `find.byKey(...)`, which
looks the widget up in Flutter's own widget tree and dispatches the tap
straight into its gesture arena. That bypasses hit-test GEOMETRY entirely, so
none of the 2307 existing tests could ever have caught the real bug: a
`web/index.html` tweak shipped for a cosmetic 1px hairline (#74) — an
unconditional alias of `document.documentElement.clientHeight/clientWidth`
to `window.innerHeight/innerWidth`, plus a `top: -2px` CSS rule on
`<flutter-view>` — corrupted the geometry Flutter's web engine treats as
ground truth for BOTH painting and native-pointer-event hit-testing on iOS.
"Continue with Google" looked dead on the installed iOS PWA because taps on
it never reached it.

Proven from the Flutter 3.44.2 engine sources (see
test/web_geometry_source_test.dart's doc comment for exact file:line):
`FullPageDimensionsProvider.computePhysicalSize()` reads
`document.documentElement.clientWidth/clientHeight` on iOS specifically (a
deliberate workaround for a WebKit `visualViewport` rotation bug), and that
same value sizes `<flutter-view>`'s CSS box — the exact element
`computeEventOffsetToTarget` measures every native pointer event against.

WHAT THIS SCRIPT PROVES, FOR REAL, IN A REAL BROWSER
-----------------------------------------------------
It cannot run an installed iOS standalone PWA (no automation can, on any
machine, per CLAUDE.md) or reproduce iOS Safari's actual boot-time
clientHeight/innerHeight settling race. What it CAN do, and does, is drive
REAL Chrome — spoofed to iOS (`navigator.platform` = 'iPhone', which is the
exact signal `ui_web.browser.operatingSystem` keys off) via CDP — with an
INJECTED, deterministic `window.innerHeight` lie (real `clientHeight` stays
untouched), and then measure, via genuine `getBoundingClientRect()` and a
genuine WebDriver Actions pointer tap (not a synthetic JS-dispatched event),
whether `<flutter-view>` — the element Flutter paints into and hit-tests
against — sizes itself from the TRUE `clientHeight` (correct) or from the
LYING `innerHeight` (exactly what a reintroduced override would cause).

This is a mechanical proxy for the real bug, not a literal repro of it: the
SOURCE of the clientHeight/innerHeight divergence differs (an injected lie
here vs. WebKit's safe-area-inset settling race on a real device), but the
ENGINE-LEVEL MECHANISM being exercised — Flutter sizing its hit-test surface
from a metric that can diverge from the visible viewport — is identical.
Proven by mutation: see the mutation table in the task report. What remains
INFERRED, pending the physical iPhone: the exact on-device symptom (a
translation vs. a clipped/oversized canvas) and the precise pixel magnitude.

USAGE
-----
    tool/build_web.sh                          # build build/web first
    tool/verify_pointer_geometry.py            # run the check
    tool/verify_pointer_geometry.py --driver-port 9522 --server-port 8099

Starts its own static server (build/web, COOP/COEP headers, matching
production) and its own chromedriver, on ports that do NOT collide with
tool/drive_web.sh's default (4444) so both can coexist. Tears both down,
including on failure, and prints which PIDs (if any) it could not reclaim.
"""
from __future__ import annotations

import argparse
import functools
import http.server
import json
import mimetypes
import os
import signal
import socket
import subprocess
import sys
import threading
import time
from contextlib import closing

import requests

REPO_ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
BUILD_WEB = os.path.join(REPO_ROOT, "build", "web")

mimetypes.add_type("application/wasm", ".wasm")
mimetypes.add_type("application/javascript", ".js")

IOS_USER_AGENT = (
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) "
    "Version/17.5 Mobile/15E148 Safari/604.1"
)

# The exact discrepancy this script injects between the two DOM size
# metrics. Must be large enough to not be lost to sub-pixel/DPR rounding.
INJECTED_DELTA_PX = 56  # ~ a Dynamic Island / status-bar-sized gap.

DEVICE_WIDTH = 390
DEVICE_HEIGHT = 844
DEVICE_DPR = 3


class _Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cross-Origin-Resource-Policy", "same-origin")
        self.send_header("Cache-Control", "no-cache")
        super().end_headers()

    def log_message(self, fmt, *args):  # noqa: A003 - quiet the server
        pass


def _free_port() -> int:
    with closing(socket.socket(socket.AF_INET, socket.SOCK_STREAM)) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _wait_http_ok(url: str, timeout_s: float) -> bool:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        try:
            if requests.get(url, timeout=2).status_code < 500:
                return True
        except requests.RequestException:
            pass
        time.sleep(0.2)
    return False


class ChromeDriverSession:
    """Thin wrapper over chromedriver's plain HTTP/JSON WebDriver + CDP API.

    Deliberately raw (no `selenium` dependency) so the exact requests being
    made — and therefore exactly what is/isn't proven — stay legible.
    """

    def __init__(self, driver_port: int):
        self.base = f"http://127.0.0.1:{driver_port}"
        self.session_id: str | None = None

    def start_session(self) -> None:
        body = {
            "capabilities": {
                "alwaysMatch": {
                    "browserName": "chrome",
                    "goog:chromeOptions": {
                        "args": [
                            "--headless=new",
                            "--disable-gpu",
                            "--no-sandbox",
                            "--disable-dev-shm-usage",
                            # Real Chrome-for-Testing renderer, no network dep.
                            "--disable-features=RendererCodeIntegrity",
                        ]
                    },
                }
            }
        }
        r = requests.post(f"{self.base}/session", json=body, timeout=30)
        r.raise_for_status()
        self.session_id = r.json()["value"]["sessionId"]

    def cdp(self, cmd: str, params: dict | None = None) -> dict:
        r = requests.post(
            f"{self.base}/session/{self.session_id}/chromium/send_command_and_get_result",
            json={"cmd": cmd, "params": params or {}},
            timeout=30,
        )
        r.raise_for_status()
        return r.json().get("value", {})

    def navigate(self, url: str) -> None:
        r = requests.post(
            f"{self.base}/session/{self.session_id}/url", json={"url": url}, timeout=30
        )
        r.raise_for_status()

    def execute(self, script: str, args: list | None = None):
        r = requests.post(
            f"{self.base}/session/{self.session_id}/execute/sync",
            json={"script": script, "args": args or []},
            timeout=30,
        )
        r.raise_for_status()
        payload = r.json()
        if "value" in payload and isinstance(payload["value"], dict) and payload["value"].get(
            "error"
        ):
            raise RuntimeError(f"execute/sync error: {payload['value']}")
        return payload["value"]

    def perform_pointer_tap(self, x: float, y: float) -> None:
        body = {
            "actions": [
                {
                    "type": "pointer",
                    "id": "finger1",
                    "parameters": {"pointerType": "touch"},
                    "actions": [
                        {"type": "pointerMove", "x": round(x), "y": round(y), "duration": 0},
                        {"type": "pointerDown", "button": 0},
                        {"type": "pause", "duration": 60},
                        {"type": "pointerUp", "button": 0},
                    ],
                }
            ]
        }
        r = requests.post(
            f"{self.base}/session/{self.session_id}/actions", json=body, timeout=30
        )
        r.raise_for_status()

    def screenshot_png_bytes(self) -> bytes:
        import base64

        r = requests.get(f"{self.base}/session/{self.session_id}/screenshot", timeout=30)
        r.raise_for_status()
        return base64.b64decode(r.json()["value"])

    def quit(self) -> None:
        if self.session_id:
            try:
                requests.delete(f"{self.base}/session/{self.session_id}", timeout=10)
            except requests.RequestException:
                pass
            self.session_id = None


def run(driver_port: int, server_port: int, screenshot_path: str | None) -> int:
    if not os.path.isdir(BUILD_WEB):
        print("FAIL: build/web not found — run tool/build_web.sh first", file=sys.stderr)
        return 2

    # --- static server -----------------------------------------------
    handler = functools.partial(_Handler, directory=BUILD_WEB)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", server_port), handler)
    server_thread = threading.Thread(target=server.serve_forever, daemon=True)
    server_thread.start()
    print(f"==> serving {BUILD_WEB} on http://127.0.0.1:{server_port}")

    # --- chromedriver ---------------------------------------------------
    log_path = f"/tmp/chromedriver_pointer_geom_{driver_port}.log"
    log_file = open(log_path, "wb")
    proc = subprocess.Popen(
        ["chromedriver", f"--port={driver_port}"],
        stdout=log_file,
        stderr=subprocess.STDOUT,
    )
    print(f"==> chromedriver pid={proc.pid} port={driver_port} log={log_path}")

    session = ChromeDriverSession(driver_port)
    exit_code = 1
    try:
        if not _wait_http_ok(f"http://127.0.0.1:{driver_port}/status", 15):
            print("FAIL: chromedriver did not come up", file=sys.stderr)
            return 1

        session.start_session()

        # Spoof iOS: `ui_web.browser.operatingSystem` keys off
        # navigator.platform starting with 'iPhone'/'iPad'/'iPod'
        # (browser_detection.dart:162-165) — this is what makes
        # FullPageDimensionsProvider.computePhysicalSize() take the
        # clientHeight/clientWidth branch instead of visualViewport.
        session.cdp(
            "Emulation.setUserAgentOverride",
            {"userAgent": IOS_USER_AGENT, "platform": "iPhone"},
        )
        session.cdp(
            "Emulation.setDeviceMetricsOverride",
            {
                "width": DEVICE_WIDTH,
                "height": DEVICE_HEIGHT,
                "deviceScaleFactor": DEVICE_DPR,
                "mobile": True,
            },
        )
        session.cdp("Emulation.setTouchEmulationEnabled", {"enabled": True})

        # Inject the deterministic clientHeight/innerHeight divergence
        # BEFORE any page script runs. `document.documentElement.clientHeight`
        # is left alone — it stays the TRUE, live-layout value, exactly the
        # role the real safe-area-affected metric plays on an actual iOS
        # device. `window.innerHeight` is the one made to lie, mirroring
        # which of the two the removed override aliased FROM.
        injected = (
            "(function(){"
            f"var real = window.innerHeight; var delta = {INJECTED_DELTA_PX};"
            "Object.defineProperty(window, 'innerHeight', "
            "{get: function(){ return real + delta; }, configurable: true});"
            "window.__verifyInjectedDelta = delta;"
            "window.__verifyRealInnerHeight = real;"
            "})();"
        )
        session.cdp("Page.addScriptToEvaluateOnNewDocument", {"source": injected})

        session.navigate(f"http://127.0.0.1:{server_port}/")

        booted = False
        deadline = time.time() + 60
        while time.time() < deadline:
            try:
                if session.execute("return window.__masiFirstFrame === true;"):
                    booted = True
                    break
            except RuntimeError:
                pass
            time.sleep(0.3)
        if not booted:
            print("FAIL: app did not reach __masiFirstFrame within 60s", file=sys.stderr)
            return 1
        print("==> app booted (__masiFirstFrame)")

        metrics = session.execute(
            """
            var view = document.querySelector('flutter-view');
            if (!view) { return {error: 'flutter-view not found'}; }
            var vr = view.getBoundingClientRect();
            return {
              clientHeight: document.documentElement.clientHeight,
              clientWidth: document.documentElement.clientWidth,
              innerHeight: window.innerHeight,
              innerWidth: window.innerWidth,
              realInnerHeight: window.__verifyRealInnerHeight,
              injectedDelta: window.__verifyInjectedDelta,
              viewRect: {top: vr.top, left: vr.left, width: vr.width, height: vr.height}
            };
            """
        )
        if "error" in metrics:
            print(f"FAIL: {metrics['error']}", file=sys.stderr)
            return 1

        print("==> measured geometry:")
        print(json.dumps(metrics, indent=2))

        # `<flutter-view>` (`DomManager.rootElement`) is BOTH the box the web
        # engine paints into and the box `computeEventOffsetToTarget`
        # measures every native pointer event against — see
        # test/web_geometry_source_test.dart's doc comment for the exact
        # file:line proof. This is the one assertion that would have caught
        # the real bug: does that box track the TRUE document metric, or the
        # metric that can lie?
        view_h = metrics["viewRect"]["height"]
        # Ground truth is the height WE TOLD CDP to emulate — a value fixed
        # outside the page, never read from any DOM property. Deliberately
        # NOT `document.documentElement.clientHeight`: that property is
        # exactly what a reintroduced override corrupts, so comparing
        # against a DOM read of it would be circular — in a mutated build,
        # `clientHeight` reports the SAME lied-to value `<flutter-view>`
        # does, and the assertion would trivially "pass" for the wrong
        # reason. Measured empirically: this headless+CDP setup has genuine,
        # NATURAL clientHeight/innerHeight divergence on top of the
        # deliberately injected one (`window.innerHeight` reads ~2121 CSS px
        # here before any injection, vs. the requested DEVICE_HEIGHT=844 —
        # a big desktop-vs-mobile-viewport gap that is itself a decent proxy
        # for the real iOS safe-area gap, and the reason this test needed no
        # exotic setup to find a real discrepancy to react to).
        true_h = DEVICE_HEIGHT
        lied_h = metrics["innerHeight"]  # window.innerHeight, made to lie by the injected script
        eps = 2.0  # CSS px tolerance for sub-pixel/DPR rounding

        matches_true = abs(view_h - true_h) <= eps
        matches_lie = abs(view_h - lied_h) <= eps

        if not matches_true:
            print(
                f"FAIL: <flutter-view> height ({view_h}) does not match the TRUE "
                f"document height ({true_h}). "
                + (
                    f"It matches the INJECTED window.innerHeight LIE ({lied_h}) instead — "
                    "this is exactly what the removed clientHeight/clientWidth override "
                    "would cause: Flutter's paint+hit-test surface sized from a metric "
                    "that can diverge from the true viewport."
                    if matches_lie
                    else "It matches neither — investigate before trusting this result."
                ),
                file=sys.stderr,
            )
            exit_code = 1
        else:
            print(
                f"PASS: <flutter-view> height ({view_h}) matches the TRUE document "
                f"height ({true_h}), correctly ignoring the injected "
                f"window.innerHeight lie ({lied_h})."
            )
            exit_code = 0

        # --- real coordinate tap, via WebDriver Actions -------------------
        # Dispatch at the CENTRE of <flutter-view>'s own live rect (the exact
        # ground truth the engine itself would use), then check the native
        # event landed where the engine's own formula
        # (event_position_helper.dart:52-58, the "isTargetOutsideOfShadowDOM"
        # branch every real tap on the canvas takes, since the actual
        # `event.target` is always a descendant inside the shadow DOM, never
        # `<flutter-view>` itself) would place it:
        #   offset = (event.clientX - viewRect.left, event.clientY - viewRect.top)
        # Native `event.offsetX/offsetY` are NOT used here on purpose — they
        # are relative to `event.target` (whichever descendant was actually
        # hit), not to `<flutter-view>`, and would silently test the wrong
        # thing.
        view = metrics["viewRect"]
        cx = view["left"] + view["width"] / 2
        cy = view["top"] + view["height"] / 2

        session.execute(
            """
            window.__tapProbe = null;
            document.addEventListener('pointerdown', function(e) {
              window.__tapProbe = {
                clientX: e.clientX, clientY: e.clientY,
                targetTag: e.target && e.target.tagName
              };
            }, {once: true, capture: true});
            """
        )
        session.perform_pointer_tap(cx, cy)
        time.sleep(0.2)
        probe = session.execute("return window.__tapProbe;")
        print("==> tap probe (real WebDriver Actions pointer tap at <flutter-view> centre):")
        print(json.dumps(probe, indent=2))

        if probe is None:
            print(
                "FAIL: no native pointerdown reached the app at all at the "
                "computed centre of <flutter-view> — the coordinate WebDriver "
                "actually clicked and the coordinate JS believes is the "
                "view's centre have desynced.",
                file=sys.stderr,
            )
            exit_code = 1
        else:
            engine_offset_x = probe["clientX"] - view["left"]
            engine_offset_y = probe["clientY"] - view["top"]
            in_bounds = 0 <= engine_offset_x <= view["width"] and 0 <= engine_offset_y <= view[
                "height"
            ]
            # The other half of "the app reacted": the native event's actual
            # target must be inside the app (a descendant of <flutter-view>,
            # never <html>/<body> themselves). This is the literal, blunt
            # form of the reported bug — measured live in the mutated build
            # below, a tap at the DOM-reported centre of <flutter-view>
            # landed on <html> instead, i.e. missed the app ENTIRELY.
            reached_app = probe["targetTag"] not in ("HTML", "BODY", None)
            if not in_bounds or not reached_app:
                print(
                    f"FAIL: pointerdown landed on {probe['targetTag']} "
                    + (
                        "— which is OUTSIDE the app (a dead tap: the same "
                        "symptom as \"Continue with Google\" doing nothing). "
                        if not reached_app
                        else ""
                    )
                    + f"The engine's own offset formula (clientX/Y - viewRect "
                    f"origin) gives ({engine_offset_x}, {engine_offset_y}), "
                    + (
                        "outside "
                        if not in_bounds
                        else "inside "
                    )
                    + f"<flutter-view>'s own reported size ({view['width']} x "
                    f"{view['height']}).",
                    file=sys.stderr,
                )
                exit_code = 1
            else:
                print(
                    f"PASS: real pointer tap at the computed centre landed on "
                    f"{probe['targetTag']}, with the engine's own offset formula "
                    f"placing it in-bounds at ({engine_offset_x:.1f}, "
                    f"{engine_offset_y:.1f}) of {view['width']} x {view['height']}."
                )

        if screenshot_path:
            try:
                png = session.screenshot_png_bytes()
                with open(screenshot_path, "wb") as f:
                    f.write(png)
                print(f"==> screenshot saved: {screenshot_path}")
            except Exception as e:  # noqa: BLE001 - best-effort evidence only
                print(f"    (screenshot failed, non-fatal: {e})")

        return exit_code
    finally:
        session.quit()
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=10)
        still_listening = subprocess.run(
            ["lsof", "-nP", f"-tiTCP:{driver_port}", "-sTCP:LISTEN"],
            capture_output=True,
            text=True,
        ).stdout.strip()
        if still_listening:
            print(
                f"WARNING: port {driver_port} still held by pid(s): {still_listening} "
                "— kill manually if this recurs.",
                file=sys.stderr,
            )
        else:
            print(f"==> chromedriver port {driver_port} confirmed free")
        server.shutdown()
        log_file.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--driver-port", type=int, default=None)
    parser.add_argument("--server-port", type=int, default=None)
    parser.add_argument("--screenshot", type=str, default=None)
    args = parser.parse_args()

    driver_port = args.driver_port or _free_port()
    server_port = args.server_port or _free_port()
    if driver_port == 4444:
        print("FAIL: refusing port 4444 — reserved for tool/drive_web.sh", file=sys.stderr)
        return 2
    return run(driver_port, server_port, args.screenshot)


if __name__ == "__main__":
    sys.exit(main())
