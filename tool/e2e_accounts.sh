#!/usr/bin/env bash
# Provision the dedicated E2E accounts on the LIVE Supabase (DEV) project.
#
# Usage:
#   tool/e2e_accounts.sh ensure   # create-or-converge the three E2E users (idempotent)
#   tool/e2e_accounts.sh show     # print the uids (uids are not secrets)
#   tool/e2e_accounts.sh env      # emit `--dart-define` flags for the OWNER account
#   tool/e2e_accounts.sh env reader|admin|owner
#
# WHY THESE ACCOUNTS EXIST
#   `lib/main_e2e.dart`'s FAKE identity carries no JWT, so `auth.uid()` is null
#   and every server-gated flow (RLS, the review queue, reports, suggestions,
#   trust, sync push/pull) is unverifiable. These are REAL confirmed accounts,
#   so a run through them exercises the real policies.
#
# WHY THE EXISTING PROJECT AND NOT A SECOND ONE
#   The org is on the free plan: a second project would auto-pause after 7 days
#   of inactivity — i.e. exactly when the harness reaches for it — and schema
#   drift between two projects is this repo's worst recurring bug class
#   (#64/#65/#72). Isolation is by OWNERSHIP (a dedicated uid per role), not by
#   database. See tool/e2e_common.sh for the invariant that makes that safe.
#
# SAFETY
#   - Addresses are under `.test` (RFC 2606): they can never be a real mailbox,
#     and `email_confirm: true` means no mail is ever sent.
#   - The shared password comes from $MASI_E2E_PASSWORD (cloud/dispatched
#     sessions) or ~/.config/masi-e2e-password (0600) locally, and is NEVER
#     printed by `ensure`/`show`. See CLAUDE.md "Cloud vs local: how secrets
#     arrive".
#   - The `service_role` key is fetched at runtime and used SHELL-SIDE ONLY.
#   - This script creates users, one `public.admins` row, and three `profiles`
#     rows. It never touches a row it did not create.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=tool/e2e_common.sh
source "$(dirname "$0")/e2e_common.sh"

# --- password ---------------------------------------------------------------
# Generated once, then reused forever. Re-running must not rotate it: a
# `--dart-define`d value in any running build would stop working mid-session.
# When $MASI_E2E_PASSWORD is set (cloud/dispatched sessions) it is authoritative
# and no file is written — e2e_password() already prefers the env var.
ensure_password() {
  if [[ -z "${MASI_E2E_PASSWORD:-}" && ! -s "$PASSWORD_FILE" ]]; then
    mkdir -p "$(dirname "$PASSWORD_FILE")"
    if command -v openssl >/dev/null 2>&1; then
      openssl rand -base64 24 | tr -d '\n=+/' > "$PASSWORD_FILE"
    else
      head -c 32 /dev/urandom | base64 | tr -d '\n=+/' > "$PASSWORD_FILE"
    fi
    # Suffix guarantees the mixed-class minimum every Supabase password policy
    # setting accepts, whatever the random body happened to be.
    printf 'A9!' >> "$PASSWORD_FILE"
    chmod 600 "$PASSWORD_FILE" 2>/dev/null || true
    echo "e2e_accounts: generated a new password at $PASSWORD_FILE (not printed)" >&2
  fi
  E2E_PASSWORD="$(e2e_password)"
}

# Create-or-converge one account. Idempotent by construction: an existing user
# has its password reset to the current file value and is re-confirmed, so a
# second run is a no-op in observable state and never errors.
ensure_user() {
  local email="$1" uid
  uid="$(uid_for "$email")"
  if [[ -z "$uid" ]]; then
    local created
    created="$(curl -sS -X POST "${SUPABASE_URL}/auth/v1/admin/users" \
      -H "apikey: ${SERVICE_KEY}" \
      -H "Authorization: Bearer ${SERVICE_KEY}" \
      -H "Content-Type: application/json" \
      --data "$(jq -n --arg e "$email" --arg p "$E2E_PASSWORD" \
        '{email:$e, password:$p, email_confirm:true, user_metadata:{masi_e2e:true}}')")"
    uid="$(echo "$created" | jq -r '.id // empty')"
    if [[ -z "$uid" ]]; then
      echo "e2e_accounts: failed to create $email: $(echo "$created" | jq -c '{code,msg,error,error_description}')" >&2
      exit 1
    fi
    echo "e2e_accounts: created $email -> $uid" >&2
  else
    curl -sS -X PUT "${SUPABASE_URL}/auth/v1/admin/users/${uid}" \
      -H "apikey: ${SERVICE_KEY}" \
      -H "Authorization: Bearer ${SERVICE_KEY}" \
      -H "Content-Type: application/json" \
      --data "$(jq -n --arg p "$E2E_PASSWORD" '{password:$p, email_confirm:true}')" >/dev/null
    echo "e2e_accounts: converged $email -> $uid" >&2
  fi
  printf '%s' "$uid"
}

cmd_ensure() {
  ensure_password
  SERVICE_KEY="$(service_role_key)"
  [[ -n "$SERVICE_KEY" && "$SERVICE_KEY" != "null" ]] || {
    echo "e2e_accounts: could not read the service_role key" >&2; exit 1; }

  local owner reader admin now
  owner="$(ensure_user "$E2E_OWNER_EMAIL")"
  reader="$(ensure_user "$E2E_READER_EMAIL")"
  admin="$(ensure_user "$E2E_ADMIN_EMAIL")"
  now="$(date +%s)000"

  # The admin role lives in `public.admins`, which is what `is_admin()` and
  # every SECURITY DEFINER review RPC consult. ON CONFLICT keeps this idempotent.
  sql "INSERT INTO public.admins (\"userId\", role, \"createdAt\")
       VALUES ('$admin', 'admin', $now)
       ON CONFLICT (\"userId\") DO NOTHING;" >/dev/null

  # Profiles make the accounts render with a name instead of a bare uid in the
  # feed/comments. Owner-scoped rows, so they are covered by the reset filter.
  local pair id name
  for pair in "$owner:E2E Owner" "$reader:E2E Reader" "$admin:E2E Admin"; do
    id="${pair%%:*}"; name="${pair#*:}"
    sql "INSERT INTO public.profiles (id, \"createdAt\", \"updatedAt\", \"ownerId\", \"displayName\", dirty)
         VALUES ('$id', $now, $now, '$id', '$name', false)
         ON CONFLICT (id) DO UPDATE SET \"displayName\" = EXCLUDED.\"displayName\";" >/dev/null
  done

  cmd_show
}

cmd_show() {
  resolve_e2e_uids
  cat <<EOF
owner   $E2E_OWNER_EMAIL   $E2E_OWNER_UID
reader  $E2E_READER_EMAIL  $E2E_READER_UID
admin   $E2E_ADMIN_EMAIL   $E2E_ADMIN_UID
password file: $PASSWORD_FILE (contents never printed)
EOF
}

# Emits the two --dart-define flags for one role, for pasting into a build.
# The password IS in this output by necessity — it is the only way to hand it
# to `flutter build`. Never redirect it into a file inside the repo.
cmd_env() {
  ensure_password
  local role="${1:-owner}" email
  case "$role" in
    owner)  email="$E2E_OWNER_EMAIL" ;;
    reader) email="$E2E_READER_EMAIL" ;;
    admin)  email="$E2E_ADMIN_EMAIL" ;;
    *) echo "e2e_accounts: unknown role '$role' (owner|reader|admin)" >&2; exit 2 ;;
  esac
  printf -- '--dart-define=E2E_EMAIL=%s --dart-define=E2E_PASSWORD=%s\n' "$email" "$E2E_PASSWORD"
}

case "${1:-ensure}" in
  ensure) cmd_ensure ;;
  show)   cmd_show ;;
  env)    cmd_env "${2:-owner}" ;;
  *) echo "usage: $0 {ensure|show|env [owner|reader|admin]}" >&2; exit 2 ;;
esac
