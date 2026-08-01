#!/usr/bin/env bash
#
# drive_ar_seg.sh — runs the AR rock-segmentation integration test with its
# 9.9 MB photo fixture temporarily bundled, then un-bundles it again.
#
# WHY THIS EXISTS
# ---------------
# `integration_test/ar_seg_channel_test.dart` needs a real crag photo INSIDE
# the app bundle: it reads the fixture with `rootBundle.load()` and hands the
# resulting file path to native Core ML over the `masi/arSegmentation` channel.
# The fixture is 9.9 MB, and while it was listed in `pubspec.yaml`'s `assets:`
# it shipped in EVERY production build on EVERY platform — 9.9 MB of dead
# weight in every user's download, and on web it also ate the offline
# service-worker precache budget. (Measured: it was copied verbatim to
# `build/web/assets/assets/test/crag_sample.jpg`.)
#
# Nothing under `lib/` has ever referenced it — it is purely a test fixture.
#
# None of Flutter's tidier "test-only asset" mechanisms work for this test:
#   - A `dev_dependencies` path package would not help: assets from exclusive
#     dev dependencies are bundled only when `includeAssetsFromDevDependencies`
#     is true, which is set ONLY by `flutter test`
#     (`flutter_tools/lib/src/commands/test.dart:794`), never by `flutter drive`
#     or `flutter build`.
#   - Asset *flavors* (`assets: - path: … flavors: [dev]`) would be the ideal
#     fit, but a flavor on iOS requires a matching Xcode scheme/configuration,
#     and this test runs on iOS.
#   - Reading the host checkout directly is not reliable from a sandboxed app
#     process, and `flutter drive` wipes the app container around each run, so
#     pre-seeding the documents directory does not survive either.
#
# So the fixture lives un-bundled in `test_fixtures/`, and this script stages it
# into the git-ignored `assets/test/` (plus a temporary `pubspec.yaml` asset
# entry) for exactly the length of one drive, restoring both on exit — including
# on Ctrl-C or failure.
#
# Usage:
#   tool/drive_ar_seg.sh <device-id> [target_test_path]
#
#   device-id         iOS Simulator UDID or physical-device id (`flutter devices`)
#   target_test_path  defaults to integration_test/ar_seg_channel_test.dart
#
# Example:
#   tool/drive_ar_seg.sh C8D8B6F4-1D77-46EF-80BA-2CBD746AC69C
#
# Note: Core ML returns an all-zeros tensor on the iOS Simulator, so the mask
# assertions self-skip there; a physical device is required to actually
# validate the mask (see the test's own header).

set -uo pipefail

export PATH="/opt/homebrew/bin:$PATH"
cd "$(dirname "$0")/.."

DEVICE="${1:-}"
TARGET="${2:-integration_test/ar_seg_channel_test.dart}"

FIXTURE_SRC="test_fixtures/crag_sample.jpg"
STAGE_DIR="assets/test"
STAGE_DEST="$STAGE_DIR/crag_sample.jpg"
PUBSPEC="pubspec.yaml"
ANCHOR="    - assets/icons/masi/"
ASSET_LINE="    - assets/test/"

if [[ -z "$DEVICE" ]]; then
  echo "FAIL: no device id given." >&2
  echo "      Usage: tool/drive_ar_seg.sh <device-id> [target_test_path]" >&2
  echo "      List devices with: flutter devices" >&2
  exit 2
fi

if [[ ! -f "$FIXTURE_SRC" ]]; then
  echo "FAIL: fixture not found: $FIXTURE_SRC" >&2
  exit 2
fi

if [[ ! -f "$TARGET" ]]; then
  echo "FAIL: target test file not found: $TARGET" >&2
  exit 2
fi

if grep -qF "$ASSET_LINE" "$PUBSPEC"; then
  echo "FAIL: $PUBSPEC already declares '$ASSET_LINE'." >&2
  echo "      That entry must stay out of version control — a previous run may" >&2
  echo "      have been interrupted. Restore pubspec.yaml before retrying." >&2
  exit 2
fi

PUBSPEC_BACKUP="$(mktemp -t masi_pubspec)"
cp "$PUBSPEC" "$PUBSPEC_BACKUP"

restore() {
  local status=$?
  echo "==> restoring un-bundled state"
  if [[ -f "$PUBSPEC_BACKUP" ]]; then
    cp "$PUBSPEC_BACKUP" "$PUBSPEC"
    rm -f "$PUBSPEC_BACKUP"
  fi
  rm -f "$STAGE_DEST"
  rmdir "$STAGE_DIR" 2>/dev/null
  exit "$status"
}
trap restore EXIT INT TERM

echo "==> staging $FIXTURE_SRC -> $STAGE_DEST ($(du -h "$FIXTURE_SRC" | cut -f1))"
mkdir -p "$STAGE_DIR"
cp "$FIXTURE_SRC" "$STAGE_DEST"

echo "==> adding a temporary '$ASSET_LINE' entry to $PUBSPEC"
STAGED_PUBSPEC="$(mktemp -t masi_pubspec_staged)"
awk -v anchor="$ANCHOR" -v line="$ASSET_LINE" '
  { print }
  $0 == anchor && !done { print line; done = 1 }
' "$PUBSPEC" >"$STAGED_PUBSPEC"

if ! grep -qF "$ASSET_LINE" "$STAGED_PUBSPEC"; then
  rm -f "$STAGED_PUBSPEC"
  echo "FAIL: could not find the anchor line '$ANCHOR' in $PUBSPEC." >&2
  echo "      The assets: block changed shape — update ANCHOR in this script." >&2
  exit 1
fi
cp "$STAGED_PUBSPEC" "$PUBSPEC"
rm -f "$STAGED_PUBSPEC"

echo "==> flutter drive --target=$TARGET -d $DEVICE"
flutter drive \
  --driver=test_driver/integration_test.dart \
  --target="$TARGET" \
  -d "$DEVICE"
DRIVE_STATUS=$?

if [[ "$DRIVE_STATUS" -eq 0 ]]; then
  echo "==> flutter drive PASSED"
else
  echo "==> flutter drive FAILED (exit $DRIVE_STATUS)" >&2
fi

exit "$DRIVE_STATUS"
