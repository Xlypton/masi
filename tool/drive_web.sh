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
# Example (a real flow, once it compiles for web):
#   tool/drive_web.sh integration_test/web_smoke_test.dart
#
# Screenshots (via test_driver/integration_test.dart's onScreenshot) land in:
#   build/screenshots/<name>.png

set -uo pipefail

export PATH="/opt/homebrew/bin:$PATH"
cd "$(dirname "$0")/.."

TARGET="${1:-integration_test/web_harness_check_test.dart}"
DRIVER_PORT="${2:-4444}"
CHROMEDRIVER_LOG="$(mktemp -t chromedriver_log)"
DRIVE_TIMEOUT_SECS="${DRIVE_TIMEOUT_SECS:-300}"

if ! command -v chromedriver >/dev/null 2>&1; then
  echo "FAIL: chromedriver not found on PATH." >&2
  echo "      Install via Chrome for Testing (mac-arm64) and place it in /opt/homebrew/bin." >&2
  exit 2
fi

if [[ ! -f "$TARGET" ]]; then
  echo "FAIL: target test file not found: $TARGET" >&2
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

# Wait for chromedriver to report itself ready (it prints "ChromeDriver was
# started successfully" once its HTTP server is listening).
READY=0
for _ in $(seq 1 50); do
  if ! kill -0 "$CHROMEDRIVER_PID" 2>/dev/null; then
    echo "FAIL: chromedriver exited early. Log:" >&2
    cat "$CHROMEDRIVER_LOG" >&2
    exit 1
  fi
  if grep -q "started successfully" "$CHROMEDRIVER_LOG" 2>/dev/null; then
    READY=1
    break
  fi
  sleep 0.2
done
if [[ "$READY" != "1" ]]; then
  echo "FAIL: chromedriver did not report ready within timeout. Log:" >&2
  cat "$CHROMEDRIVER_LOG" >&2
  exit 1
fi
echo "    ok: chromedriver ready (pid $CHROMEDRIVER_PID)"

echo "==> flutter drive --target=$TARGET -d web-server (headless chrome)"
flutter drive \
  --driver=test_driver/integration_test.dart \
  --target="$TARGET" \
  -d web-server \
  --browser-name=chrome \
  --driver-port="$DRIVER_PORT" \
  --headless \
  --timeout="$DRIVE_TIMEOUT_SECS"
DRIVE_STATUS=$?

if [[ "$DRIVE_STATUS" -eq 0 ]]; then
  echo "==> flutter drive PASSED"
else
  echo "==> flutter drive FAILED (exit $DRIVE_STATUS)" >&2
fi

echo "==> screenshots (if any) written to: build/screenshots/"
ls -la build/screenshots/ 2>/dev/null || echo "    (no build/screenshots directory found)"

exit "$DRIVE_STATUS"
