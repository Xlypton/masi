#!/usr/bin/env bash
#
# drive_web_photo_offline.sh — proves a photo attached OFFLINE survives a real
# browser restart, with pixels to look at.
#
# Usage:
#   tool/drive_web_photo_offline.sh [app_port] [driver_port]
#     app_port     host port for the `-d web-server` device (default 8791)
#     driver_port  chromedriver port (default 4546)
#
#   KEEP_PROFILE=1   don't delete the Chrome profile afterwards (it is large;
#                    only keep it when debugging)
#
# -------------------------------------------------------------------------
# WHY A SCRIPT AND NOT ONE TEST FILE
# -------------------------------------------------------------------------
# `integration_test` cannot reload the page: the test isolate dies with it.
# The strongest in-page substitute — calling `bootApp()` a second time — is
# what `web_offline_persistence_test.dart` does, and its own header names the
# gap it leaves: "a true reload-and-resume needs a driver-level harness (CDP,
# or two chained `flutter drive` runs sharing one Chrome profile) that does
# not exist yet".
#
# This is that harness. It runs two SEPARATE `flutter drive` invocations —
# separate Chrome processes, separate Dart isolates — and gives them exactly
# two things in common:
#
#   --web-port=<app_port>          one ORIGIN, so one set of browser databases
#   --user-data-dir=<profile>      one Chrome PROFILE on disk, so that origin's
#                                  storage outlives the first browser
#
# Everything else is cold in run 2: the JS heap, the wasm module, drift's
# SharedWorker, and `PhotoImageCache.instance` (the process-wide key -> blob:
# URL map that could otherwise render a photo without ever touching storage).
# That makes run 2 strictly stronger evidence than an F5.
#
# -------------------------------------------------------------------------
# AND WHY IT IS GENUINELY OFFLINE
# -------------------------------------------------------------------------
# Chrome is launched with `--host-resolver-rules=MAP * ~NOTFOUND,EXCLUDE
# localhost`: every hostname except the app's own origin fails to resolve, at
# the network stack, for the whole run. Not a `connectivityService` override
# that merely tells the app it is offline. Both test files then PROVE the
# severance by issuing real GETs (including one at this app's actual Supabase
# host) and asserting they fail — so removing the flag breaks the run instead
# of silently weakening it.

set -uo pipefail

export PATH="/opt/homebrew/bin:$PATH"
cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"

APP_PORT="${1:-8791}"
DRIVER_PORT="${2:-4546}"
STAMP="$(date +%s)"
# Seconds run 1 keeps the page alive after its last write. See
# `kSettleSeconds` in the fixture: the photo BYTES are durable the moment
# `IdbPhotoByteStore.writeBytes` returns, but the `Photos` ROW sits in
# drift's sqlite image, which the `sharedIndexedDb` backend persists lazily
# from a SharedWorker — so this window decides whether the row is on disk
# when the browser is killed. Override to measure the boundary.
SETTLE_SECONDS="${SETTLE_SECONDS:-15}"
PROFILE_DIR="$(mktemp -d -t masi_photo_profile)"
RESULTS="build/integration_response_data.json"
SEED_RESULTS="build/photo_offline_seed_report.json"

echo "==> chained offline-photo durability run"
echo "    stamp        $STAMP"
echo "    app origin   http://localhost:$APP_PORT"
echo "    chromedriver port $DRIVER_PORT"
echo "    chrome profile    $PROFILE_DIR"

# A Chrome profile plus two dev web builds is not small, and this machine runs
# close to full. Fail with a useful number rather than halfway through run 2.
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

# Newline-separated (drive_web.sh reads them with `read -r`), because a flag
# value may contain spaces.
#
# --------------------------------------------------------------------------
# WHY A DEAD PROXY AND NOT --host-resolver-rules
# --------------------------------------------------------------------------
# The obvious way to sever the network is
#     --host-resolver-rules=MAP * ~NOTFOUND,EXCLUDE localhost,EXCLUDE 127.0.0.1
# and measured directly against chromedriver that string is exactly right:
# localhost OK, 127.0.0.1 OK, example.com ERR_NAME_NOT_RESOLVED.
#
# It cannot be delivered through `flutter drive`. `--web-browser-flag` is an
# `addMultiOption` and package:args defaults `splitCommas` to true
# (flutter_command.dart:389), so flutter splits that one flag into three:
# `--host-resolver-rules=MAP * ~NOTFOUND`, `EXCLUDE localhost`,
# `EXCLUDE 127.0.0.1`. Chrome gets an unqualified "resolve nothing" rule and
# the run dies at the WebDriver navigate call with
# `net::ERR_NAME_NOT_RESOLVED` — which reads like a broken app, not a
# mangled flag. Semicolons are not an escape hatch either: measured,
# `MAP * ~NOTFOUND;EXCLUDE localhost` makes Chrome discard the whole rule set
# and the network comes back up, which is the dangerous failure — a run that
# passes while proving nothing.
#
# So: a proxy that does not exist. Chrome bypasses the proxy for loopback by
# default, so the app's own origin is untouched, while every other request
# fails at connect. Comma-free, one flag, and it severs at a lower layer than
# DNS (no name is even looked up). Measured:
#     --proxy-server=127.0.0.1:1
#       localhost OK | 127.0.0.1 OK | example.com ERR_PROXY_CONNECTION_FAILED
#
# `drive_web.sh` now rejects any browser flag containing a comma outright, so
# this trap cannot be walked into silently again.
BROWSER_FLAGS="--user-data-dir=$PROFILE_DIR
--proxy-server=127.0.0.1:1"

rm -f "$RESULTS" "$SEED_RESULTS"

# ---------------------------------------------------------------------------
# RUN 1 — seed
# ---------------------------------------------------------------------------
echo
echo "==> RUN 1/2: seeding a photo with the network severed"
WEB_PORT="$APP_PORT" \
WEB_BROWSER_FLAGS="$BROWSER_FLAGS" \
DART_DEFINES="MASI_PHOTO_RUN=$STAMP
MASI_PHOTO_SETTLE=$SETTLE_SECONDS" \
DRIVE_TIMEOUT_SECS="${DRIVE_TIMEOUT_SECS:-900}" \
  ./tool/drive_web.sh integration_test/web_photo_offline_seed_test.dart "$DRIVER_PORT"
SEED_STATUS=$?
if [[ "$SEED_STATUS" -ne 0 ]]; then
  echo "FAIL: run 1 (seed) failed with exit $SEED_STATUS — nothing to verify." >&2
  exit "$SEED_STATUS"
fi

if [[ ! -f "$RESULTS" ]]; then
  echo "FAIL: run 1 wrote no $RESULTS, so it cannot hand run 2 anything." >&2
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
PHOTO_KEY="$(read_field photo_key)" || { echo "FAIL: no photo_key in $SEED_RESULTS" >&2; exit 1; }
PHOTO_LEN="$(read_field photo_len)" || { echo "FAIL: no photo_len in $SEED_RESULTS" >&2; exit 1; }
PHOTO_HASH="$(read_field photo_hash)" || { echo "FAIL: no photo_hash in $SEED_RESULTS" >&2; exit 1; }

echo "    seeded wall  $WALL_ID"
echo "    photo key    $PHOTO_KEY"
echo "    photo bytes  $PHOTO_LEN (fnv1a64 $PHOTO_HASH)"

# ---------------------------------------------------------------------------
# The bytes are on the FILESYSTEM, independent of anything Dart claims.
#
# Chrome keeps a profile's IndexedDB under
# <profile>/Default/IndexedDB/<origin>.indexeddb.leveldb. If that directory
# does not exist after run 1, the "storage" the app wrote to never left RAM
# and run 2 would be testing nothing. This is deliberately checked from the
# shell, outside the browser, before run 2 is allowed to start.
# ---------------------------------------------------------------------------
IDB_DIR="$PROFILE_DIR/Default/IndexedDB"
echo
echo "==> filesystem check: $IDB_DIR"
if [[ ! -d "$IDB_DIR" ]]; then
  echo "FAIL: Chrome wrote no IndexedDB directory into the profile. Either" >&2
  echo "      --user-data-dir did not take effect, or the app's storage was" >&2
  echo "      in-memory. Either way run 2 would prove nothing." >&2
  exit 1
fi
ORIGIN_DIRS="$(find "$IDB_DIR" -maxdepth 1 -name "http_localhost_${APP_PORT}*" -print)"
if [[ -z "$ORIGIN_DIRS" ]]; then
  echo "FAIL: no IndexedDB storage for origin http://localhost:$APP_PORT." >&2
  echo "      Found instead:" >&2
  ls -la "$IDB_DIR" >&2
  exit 1
fi
IDB_BYTES="$(du -sk "$IDB_DIR" | awk '{print $1}')"
echo "    ok: $(echo "$ORIGIN_DIRS" | wc -l | tr -d ' ') origin store(s), ${IDB_BYTES} KB on disk"
# The photo alone is ~$PHOTO_LEN bytes; a leveldb holding only empty metadata
# is a few KB. Require room for the photo so an empty-but-present directory
# cannot satisfy this.
MIN_KB=$(( PHOTO_LEN / 1024 ))
if [[ "$IDB_BYTES" -lt "$MIN_KB" ]]; then
  echo "FAIL: IndexedDB on disk is ${IDB_BYTES} KB but the photo alone is" >&2
  echo "      ${MIN_KB} KB — the bytes are not in the profile." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Let run 1's Chrome finish exiting, then drop the HTTP caches.
#
# Two separate hazards, both caused by the profile being shared on purpose:
#
#  1. Chrome locks a profile directory. If run 1's browser is still shutting
#     down when run 2 starts, run 2 comes up crippled — `verify_offline_shell
#     .py` documents the same trap ("drift reports backend=inMemory ...
#     because the storage layer never initialises", which "looks exactly like
#     a real offline-shell failure and is not one").
#
#  2. THE CODE CACHES MUST NOT CROSS OVER, even though the storage must. The
#     two runs are DIFFERENT app bundles (different test entrypoints) served
#     at IDENTICAL URLs on the SAME origin, so anything of run 1's that
#     survives and answers for those URLs poisons run 2.
#
#     `Default/Service Worker` is the one that actually bites, and it is not
#     obvious: `web/index.html` registers masi's own `sw.js`, which precaches
#     the app shell. Run 1's worker therefore survives in the profile and
#     serves run 1's shell to run 2, whose page then asks for run 1's DDC
#     module. The server answers 404-as-HTML and Chrome logs
#         Refused to execute script from
#         '.../web_photo_offline_seed_test.dart.lib.js' because its MIME type
#         ('text/html') is not executable
#         Failed to load DDC scripts after 6 tries
#     — after which `main()` never runs, dwds never connects, and the run
#     hangs with the browser at 0% CPU and not one line of explanation on
#     stdout. Purging only `Cache`/`Code Cache` is NOT enough; that was tried
#     and failed identically. (Chrome's own `chrome_debug.log`, inside the
#     profile, is where that error is visible — nothing surfaces it otherwise.)
#
#     Deleting a service worker between runs is legitimate here and does not
#     weaken the claim: the worker caches the app's CODE, not the user's data.
#     A real user reloading the same build keeps it and it serves the right
#     shell; only this harness, which deliberately swaps the bundle under a
#     fixed origin, needs it gone.
#
# `Default/IndexedDB` — where both the drift database and the photo bytes
# live, and the only thing this proof actually wants to carry across — is
# deliberately left alone, and re-checked below.
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
rm -rf "$PROFILE_DIR/Default/Service Worker" \
       "$PROFILE_DIR/Default/Cache" \
       "$PROFILE_DIR/Default/Code Cache" \
       "$PROFILE_DIR/Default/GPUCache" \
       "$PROFILE_DIR/GrShaderCache" \
       "$PROFILE_DIR/ShaderCache"
echo "    ok: browser exited, code caches + service worker dropped"
if [[ -z "$(find "$IDB_DIR" -maxdepth 1 -name "http_localhost_${APP_PORT}*" -print 2>/dev/null)" ]]; then
  echo "FAIL: dropping the caches also removed the origin's IndexedDB — that" >&2
  echo "      is a bug in this script, not in the app. Run 2 would come up" >&2
  echo "      against empty storage and 'the photo is gone' would be this" >&2
  echo "      script's fault." >&2
  exit 1
fi
echo "    ok: IndexedDB for http://localhost:$APP_PORT still present"

# ---------------------------------------------------------------------------
# RUN 2 — verify, in a brand-new browser process
# ---------------------------------------------------------------------------
echo
echo "==> RUN 2/2: cold browser, same origin + profile, network still severed"
WEB_PORT="$APP_PORT" \
WEB_BROWSER_FLAGS="$BROWSER_FLAGS" \
DART_DEFINES="MASI_PHOTO_RUN=$STAMP
MASI_PHOTO_WALL=$WALL_ID
MASI_PHOTO_KEY=$PHOTO_KEY
MASI_PHOTO_LEN=$PHOTO_LEN
MASI_PHOTO_HASH=$PHOTO_HASH" \
DRIVE_TIMEOUT_SECS="${DRIVE_TIMEOUT_SECS:-900}" \
  ./tool/drive_web.sh integration_test/web_photo_offline_verify_test.dart "$DRIVER_PORT"
VERIFY_STATUS=$?

echo
if [[ "$VERIFY_STATUS" -eq 0 ]]; then
  echo "PASS: the photo survived a real browser restart with no network."
  echo "      Now LOOK AT THE PIXELS — a green tick here does not prove the"
  echo "      image rendered, only that its bytes came back:"
  echo "        build/screenshots/photo-04-verify-home-thumbnail.png"
  echo "        build/screenshots/photo-05-verify-canvas.png"
  echo "      Both must show the fixture: saturated corner blocks and the"
  echo "      stamp $STAMP drawn across the middle."
else
  echo "FAIL: run 2 failed with exit $VERIFY_STATUS" >&2
fi
echo "    run 1 report: $SEED_RESULTS"
echo "    run 2 report: $RESULTS"
exit "$VERIFY_STATUS"
