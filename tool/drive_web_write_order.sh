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
#   COI=1               serve the app origin with COOP/COEP/CORP, i.e. make it
#                       CROSS-ORIGIN ISOLATED, which is what PRODUCTION does
#                       (`web/_headers`) and what this harness did NOT do.
#                       This is not cosmetic: `crossOriginIsolated` is the
#                       input drift's feature probe uses to choose a storage
#                       implementation. Without it the measurement lands on
#                       `sharedIndexedDb`; with it, on `opfsLocks`/`opfsShared`
#                       — a VFS with entirely different write semantics
#                       (synchronous access handles, not a write-behind
#                       IndexedDB mirror). Every finding here is scoped to
#                       whichever backend actually ran, and both runs' reports
#                       carry `storage_backend` so that is never inferred.
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
COI="${COI:-0}"
# Passed to `tool/drive_web.sh` as `--web-header` values, i.e. added by the
# `-d web-server` dev server to every response. Same three headers as
# `web/_headers` ships to Cloudflare Pages.
COI_HEADERS=""
if [[ "$COI" == "1" ]]; then
  COI_HEADERS="Cross-Origin-Opener-Policy=same-origin
Cross-Origin-Embedder-Policy=require-corp
Cross-Origin-Resource-Policy=same-origin"
fi
if [[ "$TEARDOWN" != "kill" && "$TEARDOWN" != "unload" ]]; then
  echo "FAIL: TEARDOWN must be 'kill' or 'unload', got '$TEARDOWN'." >&2
  exit 2
fi
PROFILE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/masi_order_profile.XXXXXX")"
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

IDB_DIR="$PROFILE_DIR/Default/IndexedDB"

# The origin's IndexedDB directory, if Chrome wrote one.
origin_idb() {
  find "$IDB_DIR" -maxdepth 1 -name "http_localhost_${APP_PORT}*" -print \
    2>/dev/null | head -1
}

# The Origin Private File System database file, which is where drift's `opfs*`
# backends live — NOT in IndexedDB.
#
# Chrome puts it under `Default/File System/<bucket>/t/<dir>/<n>` (measured:
# `Default/File System/000/t/00/00000001`, 192 KB, after a seed run on
# `opfsLocks`). The size floor is the point of this guard: that directory tree
# ALSO holds leveldb bookkeeping (`Paths/*.log`, `MANIFEST-*`, `.usage`) which
# exists whether or not any origin ever stored a byte, so matching "any file"
# would make this a rubber stamp. A sqlite database with our schema in it
# cannot be under 16 KB, and the bookkeeping files measured under 10 KB.
origin_opfs() {
  find "$PROFILE_DIR/Default/File System" -type f -size +16k -print \
    2>/dev/null | head -1
}

# The whole point of run 2 is to read what run 1 left on disk, so "run 1 wrote
# no storage at all" must fail loudly rather than be reported as data loss.
# Which storage counts depends on the backend the run actually used: without
# COOP/COEP drift lands on `sharedIndexedDb` (IndexedDB), with it on
# `opfs*` (OPFS) — where the only IndexedDB left is the app's separate photo
# blob store, and even that only if a photo was attached.
assert_storage_present() {
  local idb opfs
  idb="$(origin_idb)"
  opfs="$(origin_opfs)"
  echo "    origin IndexedDB  ${idb:-<none>}"
  echo "    OPFS files        ${opfs:-<none>}"
  if [[ "$COI" == "1" ]]; then
    if [[ -z "$idb" && -z "$opfs" ]]; then
      echo "FAIL: $1" >&2
      return 1
    fi
  elif [[ -z "$idb" ]]; then
    echo "FAIL: $1" >&2
    return 1
  fi
  return 0
}

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
echo "    isolation    $([[ "$COI" == "1" ]] && echo "COOP/COEP (expect opfs*)" || echo "none (expect sharedIndexedDb)")"
WEB_PORT="$APP_PORT" \
WEB_BROWSER_FLAGS="$BROWSER_FLAGS" \
WEB_HEADERS="$COI_HEADERS" \
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

if ! assert_storage_present "no browser storage for origin http://localhost:$APP_PORT — run 2 would prove nothing."; then
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
if ! assert_storage_present "dropping the caches also removed the origin's database storage."; then
  exit 1
fi
echo "    ok: browser exited, code caches dropped, database storage intact"

echo
echo "==> RUN 2/2: cold browser, same origin + profile, network still severed"
# Drop run 1's report BEFORE run 2 starts.
#
# `flutter drive` writes $RESULTS only when the test PASSES, and run 2 failing
# is the normal shape of a positive finding (a lost row fails an assertion).
# Without this line the stale run-1 file was still on disk, got copied to
# $VERIFY_RESULTS, and THE MATRIX below printed run 1's fields as though they
# were run 2's — measured: a real `ONLY_TRAILING_TRANSACTION_LOST` run printed
# `verdict None` next to `backend sharedIndexedDb`, i.e. run 1's backend
# beside a missing verdict, which reads like "the harness measured nothing"
# when in fact it had measured the loss. The verdict was only in the inline
# `result {...}` line. A missing file makes the printer say so honestly.
rm -f "$RESULTS"
WEB_PORT="$APP_PORT" \
WEB_BROWSER_FLAGS="$BROWSER_FLAGS" \
WEB_HEADERS="$COI_HEADERS" \
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
# Which storage implementation run 2 actually opened. Printed BEFORE the
# survivor lists because it scopes them: an `ALL_SURVIVED` on
# `sharedIndexedDb` says nothing about the `opfs*` backend production uses,
# and vice versa. Never read the matrix without reading this line.
print(f"    backend         {data.get('storage_backend')} (durable={data.get('storage_is_durable')})")
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
