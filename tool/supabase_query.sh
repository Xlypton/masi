#!/usr/bin/env bash
# Run SQL against the live Supabase (DEV) project via the Management API.
#
# Usage:
#   tool/supabase_query.sh path/to/file.sql        # run a whole .sql file (DDL/migration)
#   tool/supabase_query.sh -q "SELECT 1;"          # run an inline query
#
# The admin token is NEVER printed. The app itself uses only the anon key; this
# token is admin-only, for schema work. DDL success prints [].
# See CLAUDE.md "Supabase backend — auto-troubleshoot" and "Cloud vs local:
# how secrets arrive".
#
# Token resolution: $SUPABASE_MGMT_TOKEN (cloud/dispatched sessions) wins; the
# ~/.config/climbtopo-mgmt-token file is the local-dev fallback.
set -euo pipefail

REF="${SUPABASE_PROJECT_REF:-mnaipcqbkqzffgvxpato}"
TOKEN_FILE="${SUPABASE_MGMT_TOKEN_FILE:-$HOME/.config/climbtopo-mgmt-token}"
API="https://api.supabase.com/v1/projects/${REF}/database/query"

if ! command -v jq >/dev/null 2>&1; then
  echo "supabase_query: jq is required (brew install jq)" >&2
  exit 1
fi

if [[ -n "${SUPABASE_MGMT_TOKEN:-}" ]]; then
  TOKEN="$(printf '%s' "$SUPABASE_MGMT_TOKEN" | tr -d '[:space:]')"
elif [[ -f "$TOKEN_FILE" ]]; then
  TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
else
  echo "supabase_query: no management token — set \$SUPABASE_MGMT_TOKEN or create $TOKEN_FILE" >&2
  exit 1
fi

if [[ "${1:-}" == "-q" ]]; then
  [[ -n "${2:-}" ]] || { echo "usage: $0 -q \"SQL\"" >&2; exit 2; }
  BODY="$(jq -n --arg q "$2" '{query:$q}')"
elif [[ -n "${1:-}" && -f "$1" ]]; then
  BODY="$(jq -Rs '{query: .}' "$1")"
else
  echo "usage: $0 <file.sql> | -q \"SQL\"" >&2
  exit 2
fi

curl -sS -X POST "$API" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  --data "$BODY"
echo
