#!/usr/bin/env bash
# Shared constants and helpers for the E2E live-verification tooling.
#
# Sourced by tool/e2e_accounts.sh, tool/e2e_seed.sh and tool/e2e_reset.sh so
# the three can never disagree about which accounts and which fixture rows the
# harness owns — and, more importantly, so the TEARDOWN FILTER is written once.
#
# THE SAFETY INVARIANT, stated once, here:
#   The live Supabase project holds the user's REAL topos. Every row this
#   tooling creates is owned by an E2E uid and carries an `e2e-` id prefix.
#   Every delete is filtered on BOTH — see `e2e_owner_filter`. Nothing in this
#   tooling may ever delete or update a row it did not itself create.
#
# Not executable on its own.

REF="${SUPABASE_PROJECT_REF:-mnaipcqbkqzffgvxpato}"
MGMT_TOKEN_FILE="${SUPABASE_MGMT_TOKEN_FILE:-$HOME/.config/climbtopo-mgmt-token}"
PASSWORD_FILE="${MASI_E2E_PASSWORD_FILE:-$HOME/.config/masi-e2e-password}"
SUPABASE_URL="${SUPABASE_URL:-https://${REF}.supabase.co}"
# The publishable/anon key — the same one the app ships with. Safe to have here.
SUPABASE_ANON_KEY="${SUPABASE_ANON_KEY:-sb_publishable_CjAxoGe0OSS0RrIK3nT6Ng_p0-uSPKC}"
PHOTO_BUCKET="topo-photos"

E2E_OWNER_EMAIL="e2e-owner@masi.test"
E2E_READER_EMAIL="e2e-reader@masi.test"
E2E_ADMIN_EMAIL="e2e-admin@masi.test"

# Deterministic fixture ids. Deterministic on purpose: the scripted suite
# targets widgets by key (`admin-queue-approve-<wallId>`), so the wall id has to
# be knowable from the test source — and a stable id is also what lets a re-seed
# converge instead of piling up a new fixture every run.
E2E_AREA_ID="e2e-area-0001"
E2E_SECTOR_ID="e2e-sector-0001"
E2E_WALL_PUBLISHED="e2e-wall-published-0001"
E2E_WALL_PENDING="e2e-wall-pending-0001"
E2E_PHOTO_PUBLISHED="e2e-photo-published-0001"
E2E_PHOTO_PENDING="e2e-photo-pending-0001"

command -v jq >/dev/null 2>&1 || { echo "e2e: jq is required" >&2; exit 1; }
[[ -f "$MGMT_TOKEN_FILE" ]] || { echo "e2e: token file not found: $MGMT_TOKEN_FILE" >&2; exit 1; }
MGMT_TOKEN="$(tr -d '[:space:]' < "$MGMT_TOKEN_FILE")"

# Runs SQL as the project superuser via the Management API (the same endpoint
# the Dashboard SQL editor uses). Returns JSON: `[]` for DDL/DML, rows for
# SELECT. Fails loudly on a Postgres error rather than returning silently.
sql() {
  local out
  out="$(curl -sS -X POST "https://api.supabase.com/v1/projects/${REF}/database/query" \
    -H "Authorization: Bearer ${MGMT_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "$(jq -n --arg q "$1" '{query:$q}')")"
  if echo "$out" | jq -e 'type == "object" and (has("message") or has("error"))' >/dev/null 2>&1; then
    echo "e2e: SQL failed: $(echo "$out" | jq -c .)" >&2
    return 1
  fi
  printf '%s' "$out"
}

# The `service_role` key, fetched fresh from the Management API each run so this
# repo never stores it. SHELL-SIDE ONLY — it must never reach a Flutter build.
service_role_key() {
  curl -sS "https://api.supabase.com/v1/projects/${REF}/api-keys?reveal=true" \
    -H "Authorization: Bearer ${MGMT_TOKEN}" \
    | jq -r '.[] | select(.name=="service_role") | .api_key'
}

uid_for() {
  sql "SELECT id::text AS id FROM auth.users WHERE email = '$1';" | jq -r '.[0].id // empty'
}

e2e_password() {
  [[ -s "$PASSWORD_FILE" ]] || {
    echo "e2e: no password at $PASSWORD_FILE — run tool/e2e_accounts.sh ensure" >&2
    exit 1
  }
  tr -d '\r\n' < "$PASSWORD_FILE"
}

# A real user access token (JWT) for one E2E role, obtained through the ordinary
# password grant against the ANON key — i.e. exactly the credential the app
# itself carries. Used where the fixture must go through a REAL, RLS-enforced
# path (`review_topo`) rather than a superuser INSERT that would prove nothing.
access_token_for() {
  local email="$1" pw out
  pw="$(e2e_password)"
  out="$(curl -sS -X POST "${SUPABASE_URL}/auth/v1/token?grant_type=password" \
    -H "apikey: ${SUPABASE_ANON_KEY}" -H "Content-Type: application/json" \
    --data "$(jq -n --arg e "$email" --arg p "$pw" '{email:$e,password:$p}')")"
  local token
  token="$(echo "$out" | jq -r '.access_token // empty')"
  [[ -n "$token" ]] || {
    echo "e2e: could not sign in as $email: $(echo "$out" | jq -c '{error_code,msg,error_description}')" >&2
    exit 1
  }
  printf '%s' "$token"
}

# Calls a PostgREST RPC as a real signed-in user. This is what makes a seeded
# fixture's moderation state REAL: `review_topo` is SECURITY DEFINER and checks
# `is_admin()` against `auth.uid()`, so it can only be driven with a JWT.
rpc_as() {
  local token="$1" fn="$2" body="$3"
  curl -sS -X POST "${SUPABASE_URL}/rest/v1/rpc/${fn}" \
    -H "apikey: ${SUPABASE_ANON_KEY}" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    --data "$body"
}

# Resolves the three uids into E2E_OWNER_UID / E2E_READER_UID / E2E_ADMIN_UID,
# and exits if any is missing. Everything destructive depends on these being
# real, so this is deliberately fatal rather than degrading to an empty filter —
# an empty uid in a delete's WHERE clause is how you delete somebody else's rows.
resolve_e2e_uids() {
  E2E_OWNER_UID="$(uid_for "$E2E_OWNER_EMAIL")"
  E2E_READER_UID="$(uid_for "$E2E_READER_EMAIL")"
  E2E_ADMIN_UID="$(uid_for "$E2E_ADMIN_EMAIL")"
  for pair in "owner:$E2E_OWNER_UID" "reader:$E2E_READER_UID" "admin:$E2E_ADMIN_UID"; do
    [[ -n "${pair#*:}" ]] || {
      echo "e2e: the ${pair%%:*} account does not exist — run tool/e2e_accounts.sh ensure" >&2
      exit 1
    }
  done
}

# THE teardown filter, as a SQL fragment: `"ownerId" IN (<the three E2E uids>)`.
# Written once and reused, because a delete whose filter is retyped per call
# site is a delete whose filter will eventually be retyped wrong.
e2e_owner_filter() {
  printf '"ownerId" IN (%s)' \
    "'$E2E_OWNER_UID','$E2E_READER_UID','$E2E_ADMIN_UID'"
}

# The user's real data, counted. Printed before and after every destructive run
# so "the database was returned to its original state" is a measurement rather
# than a claim.
e2e_real_row_counts() {
  # `ownerId IS NULL OR NOT IN (…)` rather than `NOT IN (…)` alone: `ownerId` is
  # nullable, and `NULL NOT IN (…)` is NULL, so a bare NOT IN would silently
  # drop every unowned legacy row from the "real data" count — exactly the rows
  # a mistake would be most likely to destroy.
  local not_e2e="(\"ownerId\" IS NULL OR \"ownerId\" NOT IN ('$E2E_OWNER_UID','$E2E_READER_UID','$E2E_ADMIN_UID'))"
  sql "SELECT 'areas' t, count(*) n FROM areas WHERE $not_e2e
       UNION ALL SELECT 'sectors', count(*) FROM sectors WHERE $not_e2e
       UNION ALL SELECT 'walls', count(*) FROM walls WHERE $not_e2e
       UNION ALL SELECT 'routes', count(*) FROM routes WHERE $not_e2e
       UNION ALL SELECT 'photos', count(*) FROM photos WHERE $not_e2e
       UNION ALL SELECT 'ascents', count(*) FROM ascents WHERE $not_e2e
       UNION ALL SELECT 'comments', count(*) FROM comments WHERE $not_e2e
       UNION ALL SELECT 'likes', count(*) FROM likes WHERE $not_e2e
       UNION ALL SELECT 'profiles', count(*) FROM profiles WHERE id NOT IN ('$E2E_OWNER_UID','$E2E_READER_UID','$E2E_ADMIN_UID')
       UNION ALL SELECT 'wall_moderation', count(*) FROM wall_moderation m WHERE NOT EXISTS (SELECT 1 FROM walls w WHERE w.id = m.\"wallId\" AND w.\"ownerId\" IN ('$E2E_OWNER_UID','$E2E_READER_UID','$E2E_ADMIN_UID'))
       UNION ALL SELECT 'content_reports', count(*) FROM content_reports WHERE \"reporterId\" NOT IN ('$E2E_OWNER_UID','$E2E_READER_UID','$E2E_ADMIN_UID')
       UNION ALL SELECT 'topo_edit_suggestions', count(*) FROM topo_edit_suggestions WHERE \"authorId\" NOT IN ('$E2E_OWNER_UID','$E2E_READER_UID','$E2E_ADMIN_UID')
       UNION ALL SELECT 'topo_versions', count(*) FROM topo_versions v WHERE NOT EXISTS (SELECT 1 FROM walls w WHERE w.id = v.\"wallId\" AND w.\"ownerId\" IN ('$E2E_OWNER_UID','$E2E_READER_UID','$E2E_ADMIN_UID'))
       UNION ALL SELECT 'moderation_log', count(*) FROM moderation_log WHERE \"actorId\" NOT IN ('$E2E_OWNER_UID','$E2E_READER_UID','$E2E_ADMIN_UID')
       ORDER BY 1;" | jq -r '.[] | "  \(.t)\t\(.n)"'
}
