#!/usr/bin/env bash
# Return the LIVE Supabase (DEV) project to its pre-E2E state.
#
#   tool/e2e_reset.sh              # delete every E2E-owned row + Storage object
#   tool/e2e_reset.sh --quiet      # same, without the before/after count report
#   tool/e2e_reset.sh --accounts   # ALSO delete the three auth users
#
# WHY THIS GOES THROUGH THE MANAGEMENT API AND NOT THE APP
#   Phase 5's withdrawal cooldown means a PUBLISHED topo cannot be un-published
#   from the client for ten days (`protect_published_wall` reverts the
#   visibility flip and the soft-delete). That is correct product behavior and
#   is not being worked around — it simply means a client-driven teardown is
#   impossible by construction, so teardown is a superuser DELETE.
#
# THE SAFETY RULE
#   Every statement below is filtered on an E2E uid or on an E2E wall id, and
#   `resolve_e2e_uids` makes a missing uid FATAL rather than an empty string
#   that would widen the filter. The filter is written first, the delete second.
#   Read `e2e_owner_filter` in tool/e2e_common.sh before editing anything here.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=tool/e2e_common.sh
source "$(dirname "$0")/e2e_common.sh"

QUIET=0
PURGE_ACCOUNTS=0
for arg in "$@"; do
  case "$arg" in
    --quiet)    QUIET=1 ;;
    --accounts) PURGE_ACCOUNTS=1 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

resolve_e2e_uids
UIDS="'$E2E_OWNER_UID','$E2E_READER_UID','$E2E_ADMIN_UID'"
# Every wall the E2E accounts own, resolved as a subquery rather than a literal
# list, so a wall created THROUGH THE APP during a run (not just the seeded
# fixture) is cleaned up too.
E2E_WALLS="SELECT id FROM public.walls WHERE \"ownerId\" IN ($UIDS)"
E2E_ROUTES="SELECT id FROM public.routes WHERE \"ownerId\" IN ($UIDS)"
E2E_PHOTOS="SELECT id FROM public.photos WHERE \"ownerId\" IN ($UIDS) OR \"wallId\" IN ($E2E_WALLS)"

if [[ "$QUIET" == "0" ]]; then
  echo "==> real (non-E2E) row counts BEFORE"
  e2e_real_row_counts
fi

# Deleted leaf-first so no foreign key is ever left dangling mid-run. Each
# statement carries its own E2E filter — none of them relies on an earlier
# statement having already narrowed the set.
echo "==> deleting E2E rows"
sql "
BEGIN;
-- Community facts. Filtered by author OR by the E2E wall/route they hang off,
-- so both 'an E2E account said something about a real topo' and 'a real
-- account said something about an E2E topo' are cleared.
DELETE FROM public.route_grade_opinions WHERE \"authorId\" IN ($UIDS) OR \"routeId\" IN ($E2E_ROUTES);
DELETE FROM public.topo_verifications   WHERE \"authorId\" IN ($UIDS) OR \"wallId\"  IN ($E2E_WALLS);
DELETE FROM public.topo_hazards         WHERE \"authorId\" IN ($UIDS) OR \"wallId\"  IN ($E2E_WALLS);

-- Moderation artefacts.
DELETE FROM public.topo_edit_suggestions WHERE \"authorId\"   IN ($UIDS) OR \"wallId\" IN ($E2E_WALLS);
DELETE FROM public.content_reports       WHERE \"reporterId\" IN ($UIDS) OR \"wallId\" IN ($E2E_WALLS);
DELETE FROM public.topo_versions         WHERE \"actorId\"    IN ($UIDS) OR \"wallId\" IN ($E2E_WALLS);
DELETE FROM public.moderation_log        WHERE \"actorId\"    IN ($UIDS) OR \"targetId\" IN ($E2E_WALLS);

-- Social rows.
DELETE FROM public.likes    WHERE \"ownerId\" IN ($UIDS) OR \"wallId\" IN ($E2E_WALLS);
DELETE FROM public.comments WHERE \"ownerId\" IN ($UIDS) OR \"wallId\" IN ($E2E_WALLS);
DELETE FROM public.ascents  WHERE \"ownerId\" IN ($UIDS) OR \"wallId\" IN ($E2E_WALLS);

-- The library itself. wall_moderation before walls: it is keyed on wallId.
-- route_lines before routes and photos: it points at BOTH. It carries no
-- wallId of its own, so it is filtered on its own ownerId plus the routes and
-- photos about to go — a line drawn THROUGH THE APP during a run is owned by
-- the climb it belongs to, which is not necessarily the account that drew it.
-- This table held zero rows until the push gap was fixed, which is why the
-- sweep predates it; a run now genuinely writes here.
DELETE FROM public.route_lines     WHERE \"ownerId\" IN ($UIDS) OR \"routeId\" IN ($E2E_ROUTES) OR \"photoId\" IN ($E2E_PHOTOS);
DELETE FROM public.routes          WHERE \"ownerId\" IN ($UIDS) OR \"wallId\" IN ($E2E_WALLS);
DELETE FROM public.photos          WHERE \"ownerId\" IN ($UIDS) OR \"wallId\" IN ($E2E_WALLS);
DELETE FROM public.wall_moderation WHERE \"wallId\"  IN ($E2E_WALLS);
DELETE FROM public.walls           WHERE \"ownerId\" IN ($UIDS);
DELETE FROM public.sectors         WHERE \"ownerId\" IN ($UIDS);
DELETE FROM public.areas           WHERE \"ownerId\" IN ($UIDS);
COMMIT;
" >/dev/null
echo "    ok"

echo "==> deleting E2E Storage objects"
SERVICE_KEY="$(service_role_key)"
if [[ -n "$SERVICE_KEY" && "$SERVICE_KEY" != "null" ]]; then
  # The owner-scoped prefixes are wholly ours, so everything under them goes.
  # The `shared/` prefix is NOT ours — it holds every published topo's photo,
  # including the user's — so only the two known fixture object names are
  # removed from it, never a prefix sweep.
  list_prefix() {
    curl -sS -X POST "${SUPABASE_URL}/storage/v1/object/list/${PHOTO_BUCKET}" \
      -H "Authorization: Bearer ${SERVICE_KEY}" -H "Content-Type: application/json" \
      --data "$(jq -n --arg p "$1" '{prefix:$p, limit:1000, offset:0}')" \
      | jq -r --arg p "$1" '.[]? | select(.name != null) | "\($p)/\(.name)"'
  }
  TO_DELETE=()
  for u in "$E2E_OWNER_UID" "$E2E_READER_UID" "$E2E_ADMIN_UID"; do
    while IFS= read -r obj; do [[ -n "$obj" ]] && TO_DELETE+=("$obj"); done < <(list_prefix "$u")
  done
  TO_DELETE+=("shared/${E2E_PHOTO_PUBLISHED}.png" "shared/${E2E_PHOTO_PENDING}.png")
  if [[ ${#TO_DELETE[@]} -gt 0 ]]; then
    REMOVED="$(curl -sS -X DELETE "${SUPABASE_URL}/storage/v1/object/${PHOTO_BUCKET}" \
      -H "Authorization: Bearer ${SERVICE_KEY}" -H "Content-Type: application/json" \
      --data "$(printf '%s\n' "${TO_DELETE[@]}" | jq -R . | jq -sc '{prefixes: .}')" \
      | jq -r 'if type=="array" then length else 0 end')"
    echo "    removed $REMOVED object(s)"
  fi
else
  echo "    WARN: no service_role key; Storage objects left in place" >&2
fi

if [[ "$PURGE_ACCOUNTS" == "1" ]]; then
  echo "==> deleting the E2E auth users"
  sql "DELETE FROM public.admins WHERE \"userId\" IN ($UIDS);" >/dev/null
  sql "DELETE FROM public.profiles WHERE id IN ($UIDS);" >/dev/null
  for u in "$E2E_OWNER_UID" "$E2E_READER_UID" "$E2E_ADMIN_UID"; do
    curl -sS -X DELETE "${SUPABASE_URL}/auth/v1/admin/users/${u}" \
      -H "apikey: ${SERVICE_KEY}" -H "Authorization: Bearer ${SERVICE_KEY}" >/dev/null
  done
  echo "    ok"
fi

# The proof, not the claim: what is left under an E2E owner must be nothing.
LEFTOVER="$(sql "SELECT
  (SELECT count(*) FROM public.areas   WHERE \"ownerId\" IN ($UIDS))
+ (SELECT count(*) FROM public.sectors WHERE \"ownerId\" IN ($UIDS))
+ (SELECT count(*) FROM public.walls   WHERE \"ownerId\" IN ($UIDS))
+ (SELECT count(*) FROM public.routes  WHERE \"ownerId\" IN ($UIDS))
+ (SELECT count(*) FROM public.route_lines WHERE \"ownerId\" IN ($UIDS))
+ (SELECT count(*) FROM public.photos  WHERE \"ownerId\" IN ($UIDS))
+ (SELECT count(*) FROM public.content_reports WHERE \"reporterId\" IN ($UIDS))
+ (SELECT count(*) FROM public.topo_edit_suggestions WHERE \"authorId\" IN ($UIDS)) AS n;" \
  | jq -r '.[0].n')"
if [[ "$LEFTOVER" != "0" ]]; then
  echo "e2e_reset: $LEFTOVER E2E-owned row(s) survived the reset" >&2
  exit 1
fi

if [[ "$QUIET" == "0" ]]; then
  echo "==> real (non-E2E) row counts AFTER"
  e2e_real_row_counts
  echo "==> reset complete: 0 E2E-owned rows remain"
fi
