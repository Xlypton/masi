#!/usr/bin/env bash
# Seed the E2E fixture into the LIVE Supabase (DEV) project.
#
#   tool/e2e_seed.sh            # converge the fixture (idempotent: resets first)
#   tool/e2e_seed.sh --ids      # print the fixture ids and exit
#
# WHAT IT CREATES (all owned by the E2E owner uid, all with `e2e-` ids):
#   area -> sector -> two walls, each with a photo (real bytes in Storage) and
#   routes.
#     * e2e-wall-published-0001 — submitted AND approved, so it is live in the
#       community feed for the reader account to view, report and suggest edits
#       on. Approval goes through the REAL `review_topo` RPC with the ADMIN
#       account's JWT, not a superuser UPDATE — the moderation state and the
#       `moderation_log` entry are therefore genuine.
#     * e2e-wall-pending-0001 — submitted and left PENDING, so the admin
#       scripted run has something of its own to approve in the queue UI.
#     * e2e-wall-draft-0001 — never submitted, `visibility='private'`. It exists
#       for the trust test, which reads `myTrustProvider` through the publish
#       confirmation sheet. That sheet is only reachable from a topo that has
#       NOT been published, and by the time that test runs both of the walls
#       above are published — the admin test approves the pending one earlier in
#       the same run. Without this third wall the trust test times out waiting
#       for a sheet that cannot open, which is exactly what it did until
#       2026-08-08. Nothing may submit or publish this wall.
#
# WHY A PENDING ONE MATTERS: the live queue also contains the USER'S REAL
# pending topos. The scripted admin test must only ever tap
# `admin-queue-approve-<E2E_WALL_PENDING>` — never "the first row". Approving a
# real row would be a destructive edit to the user's own data.
#
# TEARDOWN is `tool/e2e_reset.sh`, and it goes through the Management API on
# purpose: phase 5's withdrawal cooldown means a PUBLISHED topo cannot be
# un-published from the client for ten days, so a client-driven cleanup is
# impossible by design. Superuser DELETE is the only path that returns the
# database to its original state today.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=tool/e2e_common.sh
source "$(dirname "$0")/e2e_common.sh"

if [[ "${1:-}" == "--ids" ]]; then
  cat <<EOF
area      $E2E_AREA_ID
sector    $E2E_SECTOR_ID
published $E2E_WALL_PUBLISHED
pending   $E2E_WALL_PENDING
draft     $E2E_WALL_DRAFT
photos    $E2E_PHOTO_PUBLISHED $E2E_PHOTO_PENDING $E2E_PHOTO_DRAFT
EOF
  exit 0
fi

resolve_e2e_uids
NOW="$(date +%s)000"

echo "==> real (non-E2E) row counts BEFORE"
e2e_real_row_counts

# Start from a clean fixture every time. Without this, a re-seed would hit the
# published wall's protection trigger and leave a half-updated fixture behind.
echo "==> clearing any previous fixture"
"$(dirname "$0")/e2e_reset.sh" --quiet

echo "==> inserting library rows"
sql "INSERT INTO public.areas (id, \"createdAt\", \"updatedAt\", \"ownerId\", name, description, latitude, longitude, dirty)
     VALUES ('$E2E_AREA_ID', $NOW, $NOW, '$E2E_OWNER_UID', 'E2E Test Area',
             'Fixture data for the automated harness. Safe to delete.',
             47.4979, 19.0402, false);" >/dev/null

sql "INSERT INTO public.sectors (id, \"createdAt\", \"updatedAt\", \"ownerId\", \"areaId\", name, \"sortOrder\", dirty)
     VALUES ('$E2E_SECTOR_ID', $NOW, $NOW, '$E2E_OWNER_UID', '$E2E_AREA_ID', 'E2E Test Sector', 0, false);" >/dev/null

# visibility='shared' straight on INSERT: `trg_ensure_wall_moderation` fires on
# INSERT OR UPDATE OF visibility, so both walls get a real `wall_moderation` row
# in the state the real trigger decides (pending, since trust_level is 0 for a
# brand-new account) rather than one this script asserts.
sql "INSERT INTO public.walls (id, \"createdAt\", \"updatedAt\", \"ownerId\", \"sectorId\", name, \"sortOrder\", visibility, latitude, longitude, dirty)
     VALUES ('$E2E_WALL_PUBLISHED', $NOW, $NOW, '$E2E_OWNER_UID', '$E2E_SECTOR_ID', 'E2E Published Wall', 0, 'shared', 47.4979, 19.0402, false),
            ('$E2E_WALL_PENDING',   $NOW, $NOW, '$E2E_OWNER_UID', '$E2E_SECTOR_ID', 'E2E Pending Wall',   1, 'shared', 47.4985, 19.0410, false),
            ('$E2E_WALL_DRAFT',     $NOW, $NOW, '$E2E_OWNER_UID', '$E2E_SECTOR_ID', 'E2E Draft Wall',     2, 'private', 47.4990, 19.0415, false);" >/dev/null

sql "INSERT INTO public.photos (id, \"createdAt\", \"updatedAt\", \"ownerId\", \"wallId\", \"localPath\", kind, width, height, \"sortOrder\", \"isPrimary\", dirty)
     VALUES ('$E2E_PHOTO_PUBLISHED', $NOW, $NOW, '$E2E_OWNER_UID', '$E2E_WALL_PUBLISHED', 'photos/$E2E_PHOTO_PUBLISHED.png', 'original', 96, 144, 0, true, false),
            ('$E2E_PHOTO_PENDING',   $NOW, $NOW, '$E2E_OWNER_UID', '$E2E_WALL_PENDING',   'photos/$E2E_PHOTO_PENDING.png',   'original', 96, 144, 0, true, false),
            ('$E2E_PHOTO_DRAFT',     $NOW, $NOW, '$E2E_OWNER_UID', '$E2E_WALL_DRAFT',     'photos/$E2E_PHOTO_DRAFT.png',     'original', 96, 144, 0, true, false);" >/dev/null

# Two routes on the published wall so the phase-7b propose-line screen has both
# a "New line" target and at least one "Fix line N" target to choose between,
# and so the suggestions inbox's visual diff has an existing line to diff
# against. Coordinates are 0..1 fractions of the photo, matching the app's own
# `pointsJson` convention.
#
# `gradeSortKey` is a LADDER INDEX, not the grade times 100. These literals used
# to read 600/660/540/620, which is the one thing in this file that cannot be
# eyeballed as wrong — and `bandForSortKey` (`grade_system.dart:169-175`) has no
# upper bound, so every one of them classified as `GradeBand.elite` (French 8a+)
# and rendered a single PURPLE dot next to a correctly-labelled "6a" badge in
# every screenshot this harness produced. It also made any assertion about the
# grade-range filter vacuous over the fixture. Live data confirms the real scale:
# 6a -> 7, 6b -> 9, 6c -> 11, 7a -> 13, 8a+ -> 20, 9c -> 29.
#
# Every seeder under `integration_test/` calls the real
# `gradeSortKey(GradeSystem.french, grade)` instead of hand-writing a literal;
# this file is the only one that hardcodes, which is why it drifted. Keep these
# two columns in step: `gradeRaw` is what the UI prints, `gradeSortKey` is what
# it colours and filters by, and nothing cross-checks them.
sql "INSERT INTO public.routes (id, \"createdAt\", \"updatedAt\", \"ownerId\", \"wallId\", \"photoId\", number, name, \"gradeSystem\", \"gradeRaw\", \"gradeSortKey\", \"colorIndex\", \"pointsJson\", \"symbolsJson\", \"sortOrder\", visible, dirty)
     VALUES ('e2e-route-pub-01', $NOW, $NOW, '$E2E_OWNER_UID', '$E2E_WALL_PUBLISHED', '$E2E_PHOTO_PUBLISHED', 1, 'E2E Left Line', 'french', '6a', 7, 0,
             '[{\"x\":0.30,\"y\":0.90},{\"x\":0.32,\"y\":0.60},{\"x\":0.28,\"y\":0.30},{\"x\":0.30,\"y\":0.10}]',
             '[{\"type\":\"top\",\"x\":0.30,\"y\":0.08}]', 0, true, false),
            ('e2e-route-pub-02', $NOW, $NOW, '$E2E_OWNER_UID', '$E2E_WALL_PUBLISHED', '$E2E_PHOTO_PUBLISHED', 2, 'E2E Right Line', 'french', '6c', 11, 1,
             '[{\"x\":0.70,\"y\":0.92},{\"x\":0.68,\"y\":0.55},{\"x\":0.72,\"y\":0.20}]',
             '[{\"type\":\"top\",\"x\":0.72,\"y\":0.10}]', 1, true, false),
            ('e2e-route-pend-01', $NOW, $NOW, '$E2E_OWNER_UID', '$E2E_WALL_PENDING', '$E2E_PHOTO_PENDING', 1, 'E2E Pending Line', 'french', '5c', 6, 0,
             '[{\"x\":0.50,\"y\":0.90},{\"x\":0.50,\"y\":0.20}]', '[]', 0, true, false),
            ('e2e-route-draft-01', $NOW, $NOW, '$E2E_OWNER_UID', '$E2E_WALL_DRAFT', '$E2E_PHOTO_DRAFT', 1, 'E2E Draft Line', 'french', '6b', 9, 0,
             '[{\"x\":0.45,\"y\":0.88},{\"x\":0.55,\"y\":0.25}]', '[]', 0, true, false);" >/dev/null

echo "==> uploading fixture photo bytes to Storage"
SERVICE_KEY="$(service_role_key)"
[[ -n "$SERVICE_KEY" && "$SERVICE_KEY" != "null" ]] || {
  echo "e2e_seed: could not read the service_role key" >&2; exit 1; }
PNG_B64="$(dart run tool/e2e_fixture_png.dart 2>/dev/null)"
[[ -n "$PNG_B64" ]] || { echo "e2e_seed: fixture PNG generator produced nothing" >&2; exit 1; }
PNG_TMP="$(mktemp)"
trap 'rm -f "$PNG_TMP"' EXIT
echo "$PNG_B64" | base64 -d > "$PNG_TMP"

upload_object() {
  local path="$1"
  curl -sS -X POST "${SUPABASE_URL}/storage/v1/object/${PHOTO_BUCKET}/${path}" \
    -H "Authorization: Bearer ${SERVICE_KEY}" \
    -H "Content-Type: image/png" \
    -H "x-upsert: true" \
    --data-binary "@${PNG_TMP}" | jq -c '.' >/dev/null
  echo "    uploaded ${PHOTO_BUCKET}/${path}"
}
# Both conventions, because the app reads two different ones: `<uid>/<id>.<ext>`
# for the owner's own pull, and `shared/<id>.<ext>` for everybody else's view of
# a published topo (see `sharedPhotoPath` in `sync_remote.dart`).
for pid in "$E2E_PHOTO_PUBLISHED" "$E2E_PHOTO_PENDING" "$E2E_PHOTO_DRAFT"; do
  upload_object "${E2E_OWNER_UID}/${pid}.png"
done
# Only the PUBLISHED wall gets a `shared/` copy. The draft has none by
# definition, and `e2e_reset.sh` deletes named objects from `shared/` rather
# than sweeping the prefix — so an object that should never exist there must
# never be uploaded there either.
upload_object "shared/${E2E_PHOTO_PUBLISHED}.png"

echo "==> approving the published wall through the REAL review_topo RPC"
ADMIN_TOKEN="$(access_token_for "$E2E_ADMIN_EMAIL")"
REVIEW="$(rpc_as "$ADMIN_TOKEN" review_topo \
  "$(jq -n --arg w "$E2E_WALL_PUBLISHED" '{wall_id:$w, approve:true, reason:null}')")"
echo "    review_topo -> $REVIEW"
if ! echo "$REVIEW" | grep -q 'published'; then
  echo "e2e_seed: review_topo did not report 'published' — fixture is not live" >&2
  exit 1
fi

echo "==> fixture moderation state"
sql "SELECT m.\"wallId\", m.state, m.\"reviewerId\" IS NOT NULL AS reviewed
     FROM public.wall_moderation m
     WHERE m.\"wallId\" IN ('$E2E_WALL_PUBLISHED','$E2E_WALL_PENDING')
     ORDER BY 1;" | jq -r '.[] | "  \(.wallId)\t\(.state)\treviewed=\(.reviewed)"'

echo "==> real (non-E2E) row counts AFTER"
e2e_real_row_counts
echo "==> seed complete"
