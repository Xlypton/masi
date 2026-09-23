#!/usr/bin/env bash
# Converge the live `shared/display/` tier NOW, instead of 3 objects per push.
#
#   tool/backfill_shared_display.sh [--dry-run]
#
# Does exactly what `SharedDerivativeBackfill` does inside the app, through the
# exact path the app uses: signed in as a REAL user (the E2E owner) via the anon
# key, so RLS decides every write — never `service_role`, which would bypass the
# policy this is also here to prove. Only originals that user can READ are
# listed (the SELECT policy filters the listing), which is the same set the
# in-app backfill could reach.
#
# Before touching anything it runs two NEGATIVE controls, because a run in which
# every upload succeeds is equally consistent with a correct policy and a
# wide-open one. Both are refused writes, so they store nothing.
#
# The derivative comes from `tool/derive_shared_display.dart`, i.e. the app's own
# resampler, so each object is what the app would have published. Cost: one
# download of each original, once, ever — the same price the in-app backfill
# would pay, just paid by one run instead of spread across users' pushes.
set -euo pipefail
cd "$(dirname "$0")/.."
source tool/e2e_common.sh

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

BUCKET="topo-photos"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

TOKEN="$(access_token_for "$E2E_OWNER_EMAIL")"
AUTH=(-H "apikey: ${SUPABASE_ANON_KEY}" -H "Authorization: Bearer ${TOKEN}")

list_names() { # $1 = prefix; prints object names directly under it
  local offset=0 page
  while :; do
    page="$(curl -sS -X POST "${SUPABASE_URL}/storage/v1/object/list/${BUCKET}" \
      "${AUTH[@]}" -H "Content-Type: application/json" \
      --data "$(jq -n --arg p "$1" --argjson o "$offset" \
        '{prefix:$p, limit:100, offset:$o, sortBy:{column:"name",order:"asc"}}')")"
    echo "$page" | jq -r '.[] | select(.id != null) | .name'
    [[ "$(echo "$page" | jq 'length')" -lt 100 ]] && break
    offset=$((offset + 100))
  done
}

# HTTP status of an upload of [file] to [path]. x-upsert:false, so this is an
# INSERT and nothing else — an existing object is never overwritten.
upload_status() {
  curl -sS -o "$WORK/resp" -w '%{http_code}' -X POST \
    "${SUPABASE_URL}/storage/v1/object/${BUCKET}/$1" "${AUTH[@]}" \
    -H "Content-Type: image/jpeg" -H "x-upsert: false" \
    -H "cache-control: max-age=31536000" --data-binary "@$2"
}

originals="$(list_names shared | grep -E '\.[^.]+$' || true)"
have="$(list_names shared/display || true)"
[[ -n "$originals" ]] || { echo "no readable shared originals"; exit 0; }
probe_id="$(echo "$originals" | head -1 | sed -E 's/\.[^.]+$//')"
printf 'x' > "$WORK/probe.jpg"

echo "== negative controls (each must be REFUSED)"
for path in "shared/bogus/${probe_id}.jpg" "shared/display/no-such-photo-$$.jpg"; do
  code="$(upload_status "$path" "$WORK/probe.jpg")"
  if [[ "$code" =~ ^2 ]]; then
    echo "   FAIL: $path was ADMITTED ($code) — the policy is too wide. Stopping." >&2
    exit 1
  fi
  echo "   ok: $path refused ($code)"
done

echo "== backfill"
done_n=0; skip_n=0; fail_n=0; before=0; after=0
while IFS= read -r name; do
  id="${name%.*}"
  if grep -qxF "${id}.jpg" <<<"$have"; then skip_n=$((skip_n + 1)); continue; fi
  if (( DRY_RUN )); then echo "   would derive $name"; continue; fi
  curl -sS -f -o "$WORK/orig" "${SUPABASE_URL}/storage/v1/object/authenticated/${BUCKET}/shared/${name}" "${AUTH[@]}" \
    || { echo "   download failed: $name"; fail_n=$((fail_n + 1)); continue; }
  dart run tool/derive_shared_display.dart "$WORK/orig" "$WORK/out.jpg" >/dev/null \
    || { echo "   derive failed: $name"; fail_n=$((fail_n + 1)); continue; }
  code="$(upload_status "shared/display/${id}.jpg" "$WORK/out.jpg")"
  if [[ "$code" =~ ^2 ]]; then
    b=$(stat -c%s "$WORK/orig"); a=$(stat -c%s "$WORK/out.jpg")
    before=$((before + b)); after=$((after + a)); done_n=$((done_n + 1))
    echo "   $name  $((b / 1024)) KB -> $((a / 1024)) KB"
  else
    echo "   upload $code for $name: $(cat "$WORK/resp")"; fail_n=$((fail_n + 1))
  fi
done <<<"$originals"

echo "== derived $done_n, already present $skip_n, failed $fail_n"
(( done_n > 0 )) && echo "   bytes: $((before / 1048576)) MB of originals -> $((after / 1048576)) MB of display variants"
(( fail_n == 0 ))
