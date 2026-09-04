#!/usr/bin/env bash
# Drive ONE rock-scan job end to end, across both machines, against live data.
#
# The rest of the scan test suite verifies one side of a seam at a time: the
# Dart parser reads a PLY, the Python worker writes one, and a contract test
# proves they agree about a file captured from a real COLMAP run. What none of
# them touch is the part with two computers in it — a video uploaded through
# RLS, a worker on somebody's Windows box claiming it, reconstructing, and
# writing back columns the client is forbidden to overwrite.
#
#   tool/rock_scan_e2e.sh render  [out.mp4]   # a reconstructable test capture
#   tool/rock_scan_e2e.sh enqueue <video.mp4> # upload + row, as the OWNER's JWT
#   tool/rock_scan_e2e.sh watch   [seconds]   # follow the job to a terminal state
#   tool/rock_scan_e2e.sh status              # one-shot row dump
#   tool/rock_scan_e2e.sh fetch   [dir]       # pull the worker's artifacts down
#
# WHAT THIS DOES TO THE LIVE DATABASE: it adds exactly one `rock_scans` row and
# one Storage object, both owned by the E2E owner uid and both named with the
# `e2e-` prefix, so `tool/e2e_reset.sh` removes them like any other fixture. It
# needs the fixture wall to exist already — run `tool/e2e_seed.sh` first.
#
# THE POINT OF USING THE OWNER'S JWT: a `service_role` insert would prove
# nothing. It bypasses RLS, which is precisely the thing under test — the
# bucket's owner-prefix policy and the `rock_scans_owner_all` policy both have
# to admit these exact calls, because they are the calls the app makes.
set -euo pipefail
cd "$(dirname "$0")/.."
source tool/e2e_common.sh

SCAN_ID="${SCAN_ID:-e2e-scan-0001}"
WALL_ID="${WALL_ID:-$E2E_WALL_FACES}"
BUCKET="rock-scans"

# `jq -r` on a missing key prints "null", which then gets compared as a string
# and quietly passes every equality test you write. Print a dash instead.
field() { jq -r --arg f "$1" '.[0][$f] // "-"'; }

row_json() {
  sql "SELECT to_jsonb(r) AS r FROM public.rock_scans r WHERE id = '$SCAN_ID';" \
    | jq '[.[].r]'
}

require_row() {
  local r; r="$(row_json)"
  [[ "$(echo "$r" | jq 'length')" == "1" ]] || {
    echo "rock_scan_e2e: no row '$SCAN_ID' — run 'enqueue' first" >&2; exit 1; }
  printf '%s' "$r"
}

cmd_render() {
  local out="${1:-build/rock_scan_e2e/capture.mp4}"
  mkdir -p "$(dirname "$out")"
  # The scene is the worker's own test helper. ffmpeg's built-in patterns
  # (testsrc2, smptebars) are useless here: they are flat, so there is no
  # parallax to triangulate and COLMAP recovers nothing. This renders three
  # textured planes meeting in a dihedral, shot from a camera on a real arc.
  python3 - "$out" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, "tool/rock_scan_worker/tests")
from synthetic_scene import render_video
out = Path(sys.argv[1])
render_video(out, count=360, fps=30, seed=7, width=1280, height=720, focal=1000.0)
print(f"rendered {out} ({out.stat().st_size} bytes)")
PY
}

cmd_enqueue() {
  local video="${1:?usage: rock_scan_e2e.sh enqueue <video.mp4>}"
  [[ -s "$video" ]] || { echo "rock_scan_e2e: no such video: $video" >&2; exit 1; }
  resolve_e2e_uids
  local uid token obj size dur now
  uid="$E2E_OWNER_UID"
  token="$(access_token_for "$E2E_OWNER_EMAIL")"
  obj="${uid}/${SCAN_ID}.mp4"
  size="$(wc -c < "$video" | tr -d ' ')"
  dur="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$video" \
         | awk '{printf "%d", $1 * 1000}')"

  # The wall has to exist: the client treats a scan as a property of a wall,
  # and a scan hanging off nothing would render in a screen you cannot reach.
  local walls
  walls="$(sql "SELECT count(*) n FROM public.walls WHERE id = '$WALL_ID';" | jq -r '.[0].n')"
  [[ "$walls" == "1" ]] || {
    echo "rock_scan_e2e: fixture wall '$WALL_ID' is missing — run tool/e2e_seed.sh" >&2
    exit 1; }

  echo "==> scan $SCAN_ID on wall $WALL_ID (owner $uid)"
  echo "    video $video — $size bytes, ${dur}ms"

  # The row goes in BEFORE the bytes, at uploadState='pending'. That ordering
  # is the whole queue protocol: `pending` is unclaimable, so a worker can
  # never pick up a job whose video is still half-uploaded, and a crash midway
  # leaves a visible, retriable row rather than an orphaned object.
  now="$(date +%s000)"
  echo "==> INSERT rock_scans as the owner's JWT (RLS enforced)"
  local ins
  ins="$(curl -sS -X POST "${SUPABASE_URL}/rest/v1/rock_scans" \
    -H "apikey: ${SUPABASE_ANON_KEY}" -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" -H "Prefer: return=representation,resolution=merge-duplicates" \
    --data "$(jq -n --arg id "$SCAN_ID" --arg w "$WALL_ID" --arg o "$uid" \
      --argjson t "$now" --argjson sz "$size" --argjson d "$dur" \
      '{id:$id, createdAt:$t, updatedAt:$t, ownerId:$o, wallId:$w,
        uploadState:"pending", durationMs:$d, sizeBytes:$sz, dirty:false}')")"
  echo "$ins" | jq -e 'type=="array" and length==1' >/dev/null || {
    echo "rock_scan_e2e: INSERT rejected: $(echo "$ins" | jq -c .)" >&2; exit 1; }
  echo "    ok"

  echo "==> UPLOAD ${BUCKET}/${obj} as the owner's JWT (owner-prefix policy enforced)"
  local code body
  body="$(mktemp)"
  code="$(curl -sS -o "$body" -w '%{http_code}' -X POST \
    "${SUPABASE_URL}/storage/v1/object/${BUCKET}/${obj}" \
    -H "apikey: ${SUPABASE_ANON_KEY}" -H "Authorization: Bearer ${token}" \
    -H "Content-Type: video/mp4" -H "x-upsert: true" \
    --data-binary "@${video}")"
  [[ "$code" == "200" ]] || {
    echo "rock_scan_e2e: upload failed HTTP $code: $(head -c 300 "$body")" >&2
    rm -f "$body"; exit 1; }
  rm -f "$body"
  echo "    ok"

  # Claimable only now. `uploadState` is a CLIENT-owned column, which is what
  # makes this safe without a trigger or a server-side state machine: the
  # worker's claim predicate reads a fact only the uploader can assert.
  echo "==> PATCH uploadState=uploaded — the job becomes claimable"
  curl -sS -X PATCH "${SUPABASE_URL}/rest/v1/rock_scans?id=eq.${SCAN_ID}" \
    -H "apikey: ${SUPABASE_ANON_KEY}" -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" -H "Prefer: return=representation" \
    --data "$(jq -n --arg p "$obj" --argjson t "$(date +%s000)" \
      '{uploadState:"uploaded", videoObjectPath:$p, updatedAt:$t}')" \
    | jq -c '.[0] | {id, uploadState, videoObjectPath, status}'
  echo "==> queued $(date -u +%H:%M:%SZ) — the worker takes it on its next poll."
}

cmd_status() {
  require_row | jq -c '.[0] | {uploadState, status, progressPct, cloudObjectPath,
                               failureReason, updatedAt}'
}

# Follows the job and prints every transition, so the report can quote real
# timings rather than "it worked". Exits non-zero on a failed reconstruction —
# a worker that reports failure is a working queue and a broken job, and those
# must not look the same to a caller.
cmd_watch() {
  local budget="${1:-1800}" last="" seen_claim=0
  local start; start="$(date +%s)"
  echo "==> watching $SCAN_ID for up to ${budget}s"
  while :; do
    local r st up pct fail now elapsed
    r="$(row_json)"
    [[ "$(echo "$r" | jq 'length')" == "1" ]] || { echo "row vanished"; exit 1; }
    st="$(echo "$r" | field status)"
    up="$(echo "$r" | field uploadState)"
    pct="$(echo "$r" | field progressPct)"
    fail="$(echo "$r" | field failureReason)"
    now="$(date +%s)"; elapsed=$(( now - start ))
    local line="upload=$up status=$st progress=$pct"
    if [[ "$line" != "$last" ]]; then
      printf '  [%4ds] %s\n' "$elapsed" "$line"
      last="$line"
    fi
    [[ "$st" == "processing" ]] && seen_claim=1
    case "$st" in
      ready)
        echo "==> READY after ${elapsed}s"
        [[ "$seen_claim" == "1" ]] || echo "    note: never observed 'processing' — the job finished between polls"
        echo "$r" | jq -c '.[0] | {cloudObjectPath, manifestJson: (.manifestJson | if . then (fromjson? // .) else null end)}'
        return 0 ;;
      failed)
        echo "==> FAILED after ${elapsed}s: $fail" >&2
        return 1 ;;
    esac
    if (( elapsed > budget )); then
      echo "==> TIMED OUT after ${elapsed}s still at status=$st" >&2
      [[ "$st" == "pending" ]] && echo "    the job was never claimed — is the worker running and polling?" >&2
      return 2
    fi
    sleep 5
  done
}

# Pulls the artifacts the worker produced. Uses the OWNER's JWT, not
# service_role: the app reads these bytes as the owner, so if the owner cannot
# read them the feature is broken however well the file was written.
cmd_fetch() {
  local dir="${1:-build/rock_scan_e2e}"
  mkdir -p "$dir"
  resolve_e2e_uids
  local r token cloud
  r="$(require_row)"
  cloud="$(echo "$r" | field cloudObjectPath)"
  [[ "$cloud" != "-" ]] || { echo "rock_scan_e2e: no cloudObjectPath on the row yet" >&2; exit 1; }
  token="$(access_token_for "$E2E_OWNER_EMAIL")"
  echo "$r" | jq -r '.[0].manifestJson // ""' > "$dir/manifest.json"
  local code
  code="$(curl -sS -o "$dir/cloud.ply" -w '%{http_code}' \
    "${SUPABASE_URL}/storage/v1/object/${BUCKET}/${cloud}" \
    -H "apikey: ${SUPABASE_ANON_KEY}" -H "Authorization: Bearer ${token}")"
  [[ "$code" == "200" ]] || {
    echo "rock_scan_e2e: cloud download failed HTTP $code (owner cannot read its own artifact)" >&2
    exit 1; }
  echo "==> $dir/cloud.ply ($(wc -c < "$dir/cloud.ply" | tr -d ' ') bytes, HTTP 200 as the OWNER)"
  echo "==> $dir/manifest.json"
}

case "${1:-}" in
  render)  shift; cmd_render "$@" ;;
  enqueue) shift; cmd_enqueue "$@" ;;
  watch)   shift; cmd_watch "$@" ;;
  status)  shift; cmd_status "$@" ;;
  fetch)   shift; cmd_fetch "$@" ;;
  *) sed -n '3,20p' "$0"; exit 2 ;;
esac
