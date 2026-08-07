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
  echo "==> seeding the live fixture"
  "$(dirname "$0")/e2e_seed.sh" >/dev/null
  echo "    ok"
else
  echo "==> FAKE identity: no JWT, every server-gated call will 403/401,"
  echo "    and the community suite will SKIP rather than pretend to pass."
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
