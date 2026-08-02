#!/usr/bin/env bash
#
# drive_web_write_order.sh — measures the SHAPE of the offline write loss.
#
# `tool/drive_web_photo_offline.sh` proved that a `Photos` row written last,
# offline, does not survive a real browser restart while the `Wall` row
# written seconds earlier does. It could not say whether the operative word
# was "photo" or "last". This script answers that: run 1 writes
#
#     wall -> photo -> route 1 -> route 2 -> ... -> route N
#
# and run 2 reports which members came back. See
# `integration_test/web_write_order_fixture.dart` for how each outcome reads.
#
# Usage:
#   tool/drive_web_write_order.sh [app_port] [driver_port]
#
#   SETTLE_SECONDS=15   seconds run 1 idles after its LAST write (the flush
#                       window; make it an axis, not a constant)
#   ROUTE_COUNT=10      how many route rows run 1 writes after the photo
#   KEEP_PROFILE=1      keep the Chrome profile for post-mortem inspection
#   TEARDOWN=kill       how run 1's page dies:
#                         kill   — flutter drive tears down the whole Chrome
#                                  process; no pagehide, no unload. A CRASH.
#                         unload — the page navigates itself to about:blank,
#                                  destroying the document the way closing the
#                                  tab does (pagehide + unload fire), with the
#                                  browser still alive and idle afterwards.
#                                  THE GRACEFUL CLOSE.
#   NO_FLUSH=1          run 1 boots with `AppDatabase(..., flushAfterCommit:
#                       false)`, i.e. WITHOUT the post-commit durability fix.
#                       Required to measure the original loss (and therefore
#                       the graceful-close question) on a tree that has
#                       already fixed it.
#
# The interesting matrix is 2x2:
#
#   NO_FLUSH  TEARDOWN  meaning
#   -         kill      regression guard: the fix holds under a hard crash
#   1         kill      the original bug, reproduced
#   1         unload    DOES AN ORDINARY TAB CLOSE SAVE THE ROW?
#   -         unload    the fix holds under a graceful close too
#
# Everything about the offline severance, the shared profile and the
# between-run cache purge is identical to `drive_web_photo_offline.sh` and is
# documented there at length; this script is deliberately the same shape so
# the two results are comparable.

set -uo pipefail

export PATH="/opt/homebrew/bin:$PATH"
cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"

APP_PORT="${1:-8793}"
DRIVER_PORT="${2:-4548}"
STAMP="$(date +%s)"
SETTLE_SECONDS="${SETTLE_SECONDS:-15}"
ROUTE_COUNT="${ROUTE_COUNT:-10}"
TEARDOWN="${TEARDOWN:-kill}"
NO_FLUSH="${NO_FLUSH:-0}"
if [[ "$TEARDOWN" != "kill" && "$TEARDOWN" != "unload" ]]; then
  echo "FAIL: TEARDOWN must be 'kill' or 'unload', got '$TEARDOWN'." >&2
  exit 2
fi
PROFILE_DIR="$(mktemp -d -t masi_order_profile)"
RESULTS="build/integration_response_data.json"
SEED_RESULTS="build/write_order_seed_report.json"
VERIFY_RESULTS="build/write_order_verify_report.json"

echo "==> chained write-order durability run"
echo "    stamp        $STAMP"
echo "    app origin   http://localhost:$APP_PORT"
echo "    routes       $ROUTE_COUNT"
echo "    settle       ${SETTLE_SECONDS}s"
echo "    chrome profile    $PROFILE_DIR"

AVAIL_MB="$(df -m "$REPO_ROOT" | awk 'NR==2 {print $4}')"
echo "    free disk    ${AVAIL_MB} MB"
if [[ "$AVAIL_MB" -lt 2048 ]]; then
  echo "FAIL: under 2 GB free — a Chrome profile plus two web builds will not fit." >&2
  exit 2
fi

cleanup() {
  if [[ "${KEEP_PROFILE:-0}" == "1" ]]; then
    echo "==> keeping chrome profile at $PROFILE_DIR (KEEP_PROFILE=1)"
  else
    rm -rf "$PROFILE_DIR"
  fi
}
trap cleanup EXIT INT TERM

# A proxy that does not exist: every non-loopback request fails at connect,
# while the app's own origin (which Chrome bypasses the proxy for) keeps
# working. Comma-free on purpose — `flutter drive --web-browser-flag` splits
# values on commas, and `drive_web.sh` now refuses any flag containing one.
BROWSER_FLAGS="--user-data-dir=$PROFILE_DIR
--proxy-server=127.0.0.1:1"

rm -f "$RESULTS" "$SEED_RESULTS" "$VERIFY_RESULTS"

echo
echo "==> RUN 1/2: writing wall -> photo -> $ROUTE_COUNT routes -> tail topo, offline"
echo "    teardown     $TEARDOWN"
echo "    commit flush $([[ "$NO_FLUSH" == "1" ]] && echo DISABLED || echo enabled)"
WEB_PORT="$APP_PORT" \
WEB_BROWSER_FLAGS="$BROWSER_FLAGS" \
DART_DEFINES="MASI_ORDER_RUN=$STAMP
MASI_ORDER_SETTLE=$SETTLE_SECONDS
MASI_ORDER_ROUTES=$ROUTE_COUNT
MASI_ORDER_TEARDOWN=$TEARDOWN
MASI_ORDER_NO_FLUSH=$([[ "$NO_FLUSH" == "1" ]] && echo true || echo false)" \
DRIVE_TIMEOUT_SECS="${DRIVE_TIMEOUT_SECS:-900}" \
  ./tool/drive_web.sh integration_test/web_write_order_seed_test.dart "$DRIVER_PORT"
SEED_STATUS=$?

WALL_ID=""
PHOTO_ID=""
if [[ "$TEARDOWN" == "unload" ]]; then
  # EXPECTED to fail: run 1's last act is to navigate its own page away, which
  # kills the Dart isolate mid-test. There is no report and there is no green
  # tick, by construction. Run 2 finds everything by NAME, so nothing is lost
  # except the exit code — which would otherwise abort the measurement we came
  # here to take.
  echo "    run 1 exit $SEED_STATUS (ignored: 'unload' kills the isolate on purpose)"
else
  if [[ "$SEED_STATUS" -ne 0 ]]; then
    echo "FAIL: run 1 (seed) failed with exit $SEED_STATUS — nothing to verify." >&2
    exit "$SEED_STATUS"
  fi
  if [[ ! -f "$RESULTS" ]]; then
    echo "FAIL: run 1 wrote no $RESULTS." >&2
    exit 1
  fi
  cp "$RESULTS" "$SEED_RESULTS"

  read_field() {
    python3 -c "
import json,sys
with open('$SEED_RESULTS') as f:
    data = json.load(f)
value = data.get('$1')
if value is None:
    sys.exit(1)
print(value)
"
  }

  WALL_ID="$(read_field wall_id)" || { echo "FAIL: no wall_id in $SEED_RESULTS" >&2; exit 1; }
  PHOTO_ID="$(read_field photo_id)" || { echo "FAIL: no photo_id in $SEED_RESULTS" >&2; exit 1; }
  echo "    seeded wall  $WALL_ID"
  echo "    photo        $PHOTO_ID"
fi

IDB_DIR="$PROFILE_DIR/Default/IndexedDB"
if [[ -z "$(find "$IDB_DIR" -maxdepth 1 -name "http_localhost_${APP_PORT}*" -print 2>/dev/null)" ]]; then
  echo "FAIL: no IndexedDB storage for origin http://localhost:$APP_PORT — run 2" >&2
  echo "      would prove nothing." >&2
  exit 1
fi

echo
echo "==> settling the profile between runs"
for _ in $(seq 1 60); do
  pgrep -f -- "--user-data-dir=$PROFILE_DIR" >/dev/null 2>&1 || break
  sleep 0.5
done
if pgrep -f -- "--user-data-dir=$PROFILE_DIR" >/dev/null 2>&1; then
  echo "    warning: a browser still holds the profile; killing it"
  pkill -f -- "--user-data-dir=$PROFILE_DIR"
  sleep 2
fi
# Code caches and the service worker must NOT cross over (the two runs are
# different bundles at identical URLs on one origin); IndexedDB must. See
# drive_web_photo_offline.sh for the full account of that trap.
rm -rf "$PROFILE_DIR/Default/Service Worker" \
       "$PROFILE_DIR/Default/Cache" \
       "$PROFILE_DIR/Default/Code Cache" \
       "$PROFILE_DIR/Default/GPUCache" \
       "$PROFILE_DIR/GrShaderCache" \
       "$PROFILE_DIR/ShaderCache"
if [[ -z "$(find "$IDB_DIR" -maxdepth 1 -name "http_localhost_${APP_PORT}*" -print 2>/dev/null)" ]]; then
  echo "FAIL: dropping the caches also removed the origin's IndexedDB." >&2
  exit 1
fi
echo "    ok: browser exited, code caches dropped, IndexedDB intact"

echo
echo "==> RUN 2/2: cold browser, same origin + profile, network still severed"
WEB_PORT="$APP_PORT" \
WEB_BROWSER_FLAGS="$BROWSER_FLAGS" \
DART_DEFINES="MASI_ORDER_RUN=$STAMP
MASI_ORDER_ROUTES=$ROUTE_COUNT
MASI_ORDER_WALL=$WALL_ID
MASI_ORDER_PHOTO=$PHOTO_ID" \
DRIVE_TIMEOUT_SECS="${DRIVE_TIMEOUT_SECS:-900}" \
  ./tool/drive_web.sh integration_test/web_write_order_verify_test.dart "$DRIVER_PORT"
VERIFY_STATUS=$?
[[ -f "$RESULTS" ]] && cp "$RESULTS" "$VERIFY_RESULTS"

echo
echo "==> THE MATRIX"
# `flutter drive` prints the report inline on failure but only writes
# $RESULTS on success, so parse whichever is available and never let a
# missing file hide the measurement.
python3 - "$VERIFY_RESULTS" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as handle:
        data = json.load(handle)
except Exception as error:
    print(f"    (no verify report on disk: {error})")
    print("    Read the `result {...}` line in the run 2 output above — the")
    print("    matrix is in its `data` field even when the test failed.")
    sys.exit(0)
final = data.get('final_sample', {})
print(f"    verdict         {data.get('verdict')}")
print(f"    wall on home    {final.get('wall_on_home')}")
print(f"    TAIL wall       {final.get('tail_wall_on_home')}  (transaction-wrapped, written last)")
print(f"    photo row       {final.get('photo_row')}")
print(f"    routes survived {final.get('routes_survived')}")
print(f"    routes missing  {final.get('routes_missing')}")
print(f"    first sample    {data.get('first_sample')}")
PY

if [[ "$VERIFY_STATUS" -eq 0 ]]; then
  echo "PASS: every row written offline survived the restart."
else
  echo "FAIL: run 2 failed with exit $VERIFY_STATUS" >&2
fi
echo "    run 1 report: $SEED_RESULTS"
echo "    run 2 report: $VERIFY_RESULTS"
exit "$VERIFY_STATUS"
