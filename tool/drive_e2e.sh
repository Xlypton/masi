#!/usr/bin/env bash
# Drive the signed-in E2E suite in headless Chrome, with a REAL Supabase session.
#
#   tool/drive_e2e.sh                 # both suites, real session, seeded first
#   tool/drive_e2e.sh signed-in       # integration_test/e2e_signed_in_test.dart
#   tool/drive_e2e.sh community       # integration_test/e2e_community_test.dart
#   tool/drive_e2e.sh --fake signed-in  # no dart-defines: FAKE identity, no JWT
#
# Needs `chromedriver` already listening on 4444:
#   chromedriver --port=4444 &
#
# Screenshots land in build/screenshots/ (see test_driver/integration_test.dart).
#
# WHAT THIS DOES TO THE LIVE DATABASE, so it is never a surprise: it seeds the
# E2E fixture before the run (`tool/e2e_seed.sh`, which itself resets first) and
# leaves it in place afterwards so failures can be inspected. Run
# `tool/e2e_reset.sh` to clear it. Everything created is owned by an E2E uid —
# see tool/e2e_common.sh for the invariant.
set -euo pipefail

cd "$(dirname "$0")/.."

FAKE=0
TARGETS=()
for arg in "$@"; do
  case "$arg" in
    --fake)     FAKE=1 ;;
    signed-in)  TARGETS+=("integration_test/e2e_signed_in_test.dart") ;;
    community)  TARGETS+=("integration_test/e2e_community_test.dart") ;;
    *) echo "usage: $0 [--fake] [signed-in|community]" >&2; exit 2 ;;
  esac
done
if [[ ${#TARGETS[@]} -eq 0 ]]; then
  TARGETS=("integration_test/e2e_signed_in_test.dart" \
           "integration_test/e2e_community_test.dart")
fi

DEFINES=()
if [[ "$FAKE" == "0" ]]; then
  # Only the PASSWORD is a define; the three account emails are ordinary
  # constants in lib/main_e2e.dart, which is what lets ONE build switch role at
  # runtime via `e2eSignInAs`. Read into an array so the value is never
  # word-split or glob-expanded.
  read -r -a DEFINES <<< "$("$(dirname "$0")/e2e_accounts.sh" env owner)"
  # A real run that quietly loses its password define is the WORST outcome this
  # harness can produce: `main_e2e.dart` falls back to the fake identity, every
  # server-gated screen comes back empty because `auth.uid()` is null, and the
  # suite still reports "All tests passed" — so the run looks like proof of RLS,
  # sync and moderation while having exercised none of them. That has actually
  # happened here (the accounts script is invoked through a command substitution
  # whose failure `set -e` does not reliably catch, and the scripts shipped
  # non-executable, so it produced no output at all).
  #
  # So assert the define actually landed. Failing loudly costs a re-run; passing
  # quietly costs a false verification that gets reported to the user as fact.
  if [[ ${#DEFINES[@]} -eq 0 ]] || \
     ! printf '%s\n' "${DEFINES[@]}" | grep -q 'E2E_PASSWORD='; then
    echo "FATAL: no E2E_PASSWORD dart-define — tool/e2e_accounts.sh produced" >&2
    echo "  nothing usable, so this run would silently use the FAKE identity" >&2
    echo "  and report success without touching the backend. Refusing." >&2
    echo "  Check: ~/.config/masi-e2e-password exists, and tool/e2e_*.sh are" >&2
    echo "  executable (git ls-files -s tool/e2e_accounts.sh -> 100755)." >&2
    exit 3
  fi
  echo "==> seeding the live fixture"
  "$(dirname "$0")/e2e_seed.sh" >/dev/null
  echo "    ok"
else
  echo "==> FAKE identity: no JWT, every server-gated call will 403/401,"
  echo "    and the community suite will SKIP rather than pretend to pass."
fi

# Preflight the browser stack BEFORE the expensive part. chromedriver refuses a
# session across a major-version gap with Chrome, and `flutter drive` surfaces
# that as a WebDriver handshake error or an unexplained hang minutes in —
# nothing that names the versions. This script had no chromedriver check of any
# kind; it simply assumed something usable was listening on 4444.
#
# Placed AFTER the seed on purpose. Seeding is idempotent and re-runnable, so
# the cost of having seeded before discovering a broken driver is one wasted
# round trip; putting the check first would instead mean a run that reports a
# browser problem while leaving the operator unsure whether the fixture is in
# place. `tool/e2e_reset.sh` cleans up either way.
echo "==> chromedriver/Chrome version preflight"
if ! dart run tool/preflight_chromedriver.dart; then
  echo "" >&2
  echo "Refusing to drive: the browser automation stack cannot open a session," >&2
  echo "so this run could only fail — slowly, and with a misleading message." >&2
  exit 4
fi

for target in "${TARGETS[@]}"; do
  echo "==> $target"
  flutter drive \
    --driver=test_driver/integration_test.dart \
    --target="$target" \
    -d web-server --browser-name=chrome --driver-port=4444 --headless \
    --no-web-resources-cdn --timeout=900 \
    "${DEFINES[@]}"
done

echo "==> screenshots"
ls build/screenshots/ 2>/dev/null || echo "    (none)"
