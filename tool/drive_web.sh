#!/usr/bin/env bash
#
# drive_web.sh — headless-Chrome `flutter drive` runner for web integration tests.
#
# Starts chromedriver, runs `flutter drive` against the `-d web-server` device
# with Chrome in headless mode, then tears chromedriver down again. Reuses the
# existing `test_driver/integration_test.dart` driver (the same one the iOS
# integration_test loop uses) so screenshots land in `build/screenshots/` via
# its `onScreenshot` callback, exactly like the iOS simulator flow.
#
# Requirements (see CLAUDE.md / WEB_PORT_BRIEF.md):
#   - Google Chrome installed.
#   - `chromedriver` on PATH, matching the installed Chrome's major version
#     (installed here via Chrome for Testing: /opt/homebrew/bin/chromedriver).
#
# Usage:
#   tool/drive_web.sh [target_test_path] [driver_port]
#
#   target_test_path  defaults to integration_test/web_harness_check_test.dart
#   driver_port       defaults to 4444
#
# Example (the trivial pipeline-proof test):
#   tool/drive_web.sh
#
# Example (a real flow):
#   tool/drive_web.sh integration_test/web_smoke_test.dart
#
# Environment knobs (used by tool/drive_web_photo_offline.sh):
#   WEB_PORT              pin the `-d web-server` host port so two SEPARATE
#                         runs share one origin, and therefore one set of
#                         browser-side databases. Unset = random free port.
#   WEB_BROWSER_FLAGS     extra Chrome flags, newline-separated, each
#                         forwarded as `--web-browser-flag=<flag>`. Newline
#                         (not space) separated because a single flag may
#                         contain spaces — --host-resolver-rules does.
#   DART_DEFINES          extra `--dart-define` values, newline-separated
#                         `KEY=VALUE` pairs.
#   WEB_HEADERS           extra `--web-header` values, newline-separated
#                         `Header-Name=value` pairs, added by the dev server to
#                         EVERY response. This is the only way to make the
#                         `-d web-server` origin CROSS-ORIGIN ISOLATED, which
#                         is what decides whether drift picks OPFS or
#                         IndexedDB: without COOP/COEP the harness measures
#                         `sharedIndexedDb` while PRODUCTION (which sets both
#                         headers in `web/_headers`) runs `opfsLocks`. Commas
#                         are safe here — flutter declares `--web-header` with
#                         `splitCommas: false` (flutter_command.dart:274-283),
#                         unlike `--web-browser-flag` below.
#                         See `tool/drive_web_write_order.sh`'s `COI=1`.
#   DRIVE_TIMEOUT_SECS    `flutter drive --timeout` (default 300).
#   DRIVE_WEB_PREFLIGHT_ONLY=1
#                         run the chromedriver port hygiene + readiness check,
#                         print the verdict, then exit WITHOUT building or
#                         driving anything. `test/tool/drive_web_port_test.dart`
#                         drives this, so the stuck-port handling below is
#                         covered by a real test rather than an assumption.
#
# Screenshots (via test_driver/integration_test.dart's onScreenshot) land in:
#   build/screenshots/<name>.png
#
# -------------------------------------------------------------------------
# THE STUCK-PORT HAZARD (why the preflight below exists)
# -------------------------------------------------------------------------
# Under load, chromedriver sometimes fails to launch Chrome and is left
# running with its port still bound. The previous version of this script then
# started a SECOND chromedriver, which died instantly with "Address already in
# use" — but that message went to a temp log only printed if the readiness
# loop timed out, and the readiness loop grepped the log of the DEAD process
# while `flutter drive` connected to the WEDGED first one and hung until the
# outer timeout. Every subsequent run looked like an inexplicable hang with no
# useful error.
#
# So: before starting anything, find out who owns the port. A leftover
# chromedriver is ours by convention and gets reclaimed. Anything else is a
# stranger's process — we refuse to kill it, and fail fast saying exactly what
# to do instead.

set -uo pipefail

export PATH="/opt/homebrew/bin:$PATH"
cd "$(dirname "$0")/.."

TARGET="${1:-integration_test/web_harness_check_test.dart}"
DRIVER_PORT="${2:-4444}"
# Full template rather than `mktemp -t PREFIX`: the -t shorthand treats its
# argument as a prefix on BSD/macOS, but GNU coreutils (Git Bash on Windows)
# reads it as a template and refuses anything with fewer than three X's —
# "too few X's in template", which killed every one of these scripts there.
CHROMEDRIVER_LOG="$(mktemp "${TMPDIR:-/tmp}/chromedriver_log.XXXXXX")"
DRIVE_TIMEOUT_SECS="${DRIVE_TIMEOUT_SECS:-300}"
PREFLIGHT_ONLY="${DRIVE_WEB_PREFLIGHT_ONLY:-0}"

if ! command -v chromedriver >/dev/null 2>&1; then
  echo "FAIL: chromedriver not found on PATH." >&2
  echo "      Install via Chrome for Testing (mac-arm64) and place it in /opt/homebrew/bin." >&2
  exit 2
fi

if [[ "$PREFLIGHT_ONLY" != "1" && ! -f "$TARGET" ]]; then
  echo "FAIL: target test file not found: $TARGET" >&2
  exit 2
fi

# --------------------------------------------------------------------------
# Port hygiene
# --------------------------------------------------------------------------

# PIDs currently LISTENing on $DRIVER_PORT (empty when the port is free).
port_listener_pids() {
  lsof -nP -tiTCP:"$DRIVER_PORT" -sTCP:LISTEN 2>/dev/null | sort -u
}

# Executable name for a pid, e.g. "chromedriver".
pid_command() {
  ps -o comm= -p "$1" 2>/dev/null | sed 's:.*/::' | tr -d ' '
}

# Reclaims a leftover chromedriver holding $DRIVER_PORT, or fails fast.
#
# 0 = the port is free (it already was, or we cleared it).
# 1 = held by something we must not kill, or a chromedriver that refused to
#     die. Both are actionable and both print the manual fix.
ensure_port_free() {
  local pids
  pids="$(port_listener_pids)"
  [[ -z "$pids" ]] && return 0

  echo "==> port $DRIVER_PORT is already in use — inspecting"
  local pid name foreign=0
  for pid in $pids; do
    name="$(pid_command "$pid")"
    echo "    pid $pid ($name)"
    if [[ "$name" != "chromedriver" ]]; then
      foreign=1
    fi
  done

  if [[ "$foreign" == "1" ]]; then
    echo "FAIL: port $DRIVER_PORT is held by a process that is NOT chromedriver." >&2
    echo "      Refusing to kill it. Stop it yourself, or use another port:" >&2
    echo "        tool/drive_web.sh $TARGET 4545" >&2
    return 1
  fi

  # A stale chromedriver: THE documented hazard. It still owns the port but
  # can no longer launch a browser, so a `flutter drive` that connects to it
  # hangs forever. Reclaim it.
  echo "    stale chromedriver detected — reclaiming port $DRIVER_PORT"
  for pid in $pids; do
    kill "$pid" 2>/dev/null
  done
  for _ in $(seq 1 25); do
    [[ -z "$(port_listener_pids)" ]] && break
    sleep 0.2
  done
  if [[ -n "$(port_listener_pids)" ]]; then
    echo "    still bound after SIGTERM — sending SIGKILL"
    for pid in $(port_listener_pids); do
      kill -9 "$pid" 2>/dev/null
    done
    for _ in $(seq 1 25); do
      [[ -z "$(port_listener_pids)" ]] && break
      sleep 0.2
    done
  fi

  if [[ -n "$(port_listener_pids)" ]]; then
    echo "FAIL: could not free port $DRIVER_PORT (pids: $(port_listener_pids))." >&2
    echo "      Kill it by hand and retry:  kill -9 $(port_listener_pids)" >&2
    return 1
  fi
  echo "    ok: port $DRIVER_PORT reclaimed"
  return 0
}

if ! ensure_port_free; then
  exit 2
fi

CHROMEDRIVER_PID=""

cleanup() {
  local status=$?
  if [[ -n "$CHROMEDRIVER_PID" ]] && kill -0 "$CHROMEDRIVER_PID" 2>/dev/null; then
    echo "==> stopping chromedriver (pid $CHROMEDRIVER_PID)"
    kill "$CHROMEDRIVER_PID" 2>/dev/null
    wait "$CHROMEDRIVER_PID" 2>/dev/null
  fi
  rm -f "$CHROMEDRIVER_LOG"
  exit "$status"
}
trap cleanup EXIT INT TERM

echo "==> starting chromedriver on port $DRIVER_PORT"
chromedriver "--port=$DRIVER_PORT" >"$CHROMEDRIVER_LOG" 2>&1 &
CHROMEDRIVER_PID=$!

# Readiness is an answered HTTP /status, not a log line.
#
# The log grep alone was unreliable in exactly the failure this script now
# guards against: a chromedriver that loses a port race writes its error and
# exits, while a merely-slow one writes nothing for a while. /status asks the
# only question that matters — "can a WebDriver client talk to it?" — and the
# `kill -0` check still catches an early exit immediately instead of waiting
# out the whole loop.
READY=0
for _ in $(seq 1 100); do
  if ! kill -0 "$CHROMEDRIVER_PID" 2>/dev/null; then
    echo "FAIL: chromedriver exited early. Log:" >&2
    cat "$CHROMEDRIVER_LOG" >&2
    exit 1
  fi
  if curl -sf --max-time 2 "http://127.0.0.1:$DRIVER_PORT/status" >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 0.2
done
if [[ "$READY" != "1" ]]; then
  echo "FAIL: chromedriver did not answer /status on port $DRIVER_PORT in time. Log:" >&2
  cat "$CHROMEDRIVER_LOG" >&2
  exit 1
fi
echo "    ok: chromedriver ready (pid $CHROMEDRIVER_PID)"

if [[ "$PREFLIGHT_ONLY" == "1" ]]; then
  echo "PREFLIGHT OK: chromedriver reachable on port $DRIVER_PORT"
  exit 0
fi

# --------------------------------------------------------------------------
# Optional pass-through flags
# --------------------------------------------------------------------------
EXTRA_ARGS=()
if [[ -n "${WEB_PORT:-}" ]]; then
  EXTRA_ARGS+=(--web-hostname=localhost "--web-port=$WEB_PORT")
fi
if [[ -n "${WEB_BROWSER_FLAGS:-}" ]]; then
  while IFS= read -r flag; do
    [[ -z "$flag" ]] && continue
    # `--web-browser-flag` is declared with `argParser.addMultiOption(...)`
    # and package:args defaults `splitCommas` to TRUE
    # (flutter_command.dart:389). So flutter SILENTLY SHREDS any value
    # containing a comma: passing
    #     --host-resolver-rules=MAP * ~NOTFOUND,EXCLUDE localhost
    # hands Chrome three separate flags —
    #     --host-resolver-rules=MAP * ~NOTFOUND
    #     EXCLUDE localhost
    #     EXCLUDE 127.0.0.1
    # — i.e. exactly the opposite of what was asked for, with no warning.
    # That cost two full chained runs, which failed at the WebDriver navigate
    # call with `net::ERR_NAME_NOT_RESOLVED` and looked like a broken app.
    # Refuse rather than let it happen quietly again.
    if [[ "$flag" == *,* ]]; then
      echo "FAIL: browser flag contains a comma:" >&2
      echo "        $flag" >&2
      echo "      flutter's --web-browser-flag is an addMultiOption with" >&2
      echo "      splitCommas=true, so it would be split into separate flags" >&2
      echo "      and silently mean something else. Use a comma-free" >&2
      echo "      formulation (e.g. --proxy-server=127.0.0.1:1 instead of" >&2
      echo "      --host-resolver-rules=MAP...,EXCLUDE...)." >&2
      exit 2
    fi
    EXTRA_ARGS+=("--web-browser-flag=$flag")
  done <<<"$WEB_BROWSER_FLAGS"
fi
if [[ -n "${DART_DEFINES:-}" ]]; then
  while IFS= read -r define; do
    [[ -z "$define" ]] && continue
    EXTRA_ARGS+=("--dart-define=$define")
  done <<<"$DART_DEFINES"
fi
if [[ -n "${WEB_HEADERS:-}" ]]; then
  while IFS= read -r header; do
    [[ -z "$header" ]] && continue
    EXTRA_ARGS+=("--web-header=$header")
  done <<<"$WEB_HEADERS"
fi

echo "==> flutter drive --target=$TARGET -d web-server (headless chrome)"
if [[ ${#EXTRA_ARGS[@]} -gt 0 ]]; then
  printf '    extra: %s\n' "${EXTRA_ARGS[@]}"
fi
# --no-web-resources-cdn: serve the renderer from THIS origin.
#
# Without it, `flutter_bootstrap.js` fetches canvaskit from
# https://www.gstatic.com/flutter-canvaskit/<rev>/ — so every web
# integration test silently depends on the public internet, and an OFFLINE
# test is impossible: the app cannot paint its first frame, the run hangs
# with the browser idle (it is waiting on a fetch, not computing), and
# nothing in the output says why. That cost a full debugging cycle here.
#
# `tool/build_web.sh` already passes this flag for the same reason, and
# `test/tool/build_web_flags_test.dart` pins it there ("without it the
# renderer is fetched from gstatic.com and the app cannot paint its first
# frame offline"). The drive path had simply never been aligned with it.
# A HARD wall-clock ceiling on the whole invocation.
#
# `flutter drive --timeout` only bounds the TEST. It does nothing about the
# phase before the test starts — page load, DDC module fetch, driver
# handshake — and that is precisely where the observed hangs live: the
# browser sits at 0% CPU, `main()` never runs, and the run waits forever with
# no output. Seen twice here (once for a renderer fetched from a severed
# CDN, once for a stale HTTP cache), each time costing ~20 minutes before
# anyone noticed it was not simply slow.
#
# So the script enforces its own deadline, generously past the test timeout,
# and says plainly what happened when it fires.
HARD_LIMIT=$(( DRIVE_TIMEOUT_SECS + 180 ))
flutter drive \
  --driver=test_driver/integration_test.dart \
  --target="$TARGET" \
  -d web-server \
  --browser-name=chrome \
  --driver-port="$DRIVER_PORT" \
  --headless \
  --no-web-resources-cdn \
  --timeout="$DRIVE_TIMEOUT_SECS" \
  "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}" &
DRIVE_PID=$!
(
  sleep "$HARD_LIMIT"
  if kill -0 "$DRIVE_PID" 2>/dev/null; then
    echo "" >&2
    echo "FAIL: hard timeout — 'flutter drive' produced no verdict in ${HARD_LIMIT}s." >&2
    echo "      This is the SILENT HANG, not a slow test. Usual causes:" >&2
    echo "        * the page never ran main() (stale HTTP cache in a reused" >&2
    echo "          --user-data-dir, or an asset the browser could not fetch);" >&2
    echo "        * the renderer was fetched from a CDN the browser cannot" >&2
    echo "          reach (this script passes --no-web-resources-cdn to stop" >&2
    echo "          that, so suspect it only if that flag was removed)." >&2
    echo "      Check which build/screenshots/*.png exist to see how far the" >&2
    echo "      test body got." >&2
    kill -9 "$DRIVE_PID" 2>/dev/null
  fi
) &
WATCHDOG_PID=$!
wait "$DRIVE_PID"
DRIVE_STATUS=$?
kill "$WATCHDOG_PID" 2>/dev/null
wait "$WATCHDOG_PID" 2>/dev/null

if [[ "$DRIVE_STATUS" -eq 0 ]]; then
  echo "==> flutter drive PASSED"
else
  echo "==> flutter drive FAILED (exit $DRIVE_STATUS)" >&2
fi

echo "==> screenshots (if any) written to: build/screenshots/"
ls -la build/screenshots/ 2>/dev/null || echo "    (no build/screenshots directory found)"

exit "$DRIVE_STATUS"
