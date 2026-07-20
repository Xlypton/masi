#!/usr/bin/env bash
#
# build_web.sh — build the ClimbTopo web bundle and enforce the web guardrails.
#
# This is the locally-runnable "definition of done" gate for the web port. It:
#   1. runs the dart:io grep gate (no dart:io outside *_native.dart)
#   2. checks the pinned drift/sqlite3 WASM assets are present and current (Phase 1+)
#   3. builds the web bundle (wasm by default; JS with --js)
#
# NOTE (during the port): the grep gate and the web build only go green once the
# photo/db pipeline is split behind conditional imports (Phases 1-2). Until then
# this script is expected to fail — that is the point, it defines "done".
#
# Usage:
#   tool/build_web.sh            # wasm build (default)
#   tool/build_web.sh --js       # legacy JS/canvaskit build
#   tool/build_web.sh --gate     # run only the grep gate, no build

set -euo pipefail

export PATH="/opt/homebrew/bin:$PATH"
cd "$(dirname "$0")/.."

RENDERER_ARGS=(--wasm)
GATE_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --js)   RENDERER_ARGS=() ;;
    --gate) GATE_ONLY=1 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

echo "==> dart:io grep gate (must be empty)"
# Any dart:io import outside a *_native.dart file would leak into the web bundle.
OFFENDERS="$(grep -rl "dart:io" lib --include="*.dart" | grep -v '_native.dart' || true)"
if [[ -n "$OFFENDERS" ]]; then
  echo "FAIL: dart:io found outside *_native.dart in:" >&2
  echo "$OFFENDERS" >&2
  exit 1
fi
echo "    ok: no dart:io outside *_native.dart"

echo "==> drift/sqlite3 WASM asset check"
# Phase 1 pins sqlite3.wasm + drift_worker.js into web/. Before Phase 1 they are
# absent and that is fine; once present, warn loudly if pubspec.lock moved but the
# committed assets did not (stale asset == silent data-layer breakage).
if [[ -f web/sqlite3.wasm && -f web/drift_worker.js ]]; then
  echo "    ok: web/sqlite3.wasm + web/drift_worker.js present"
  if [[ -f web/.drift_asset_versions && -f pubspec.lock ]]; then
    LOCK_DRIFT="$(awk '/^  drift:/{getline; getline; print}' pubspec.lock | tr -d ' ')"
    PINNED="$(cat web/.drift_asset_versions)"
    if [[ "$LOCK_DRIFT" != *"$PINNED"* && -n "$PINNED" ]]; then
      echo "WARN: pubspec.lock drift version changed but web/ WASM assets may be stale." >&2
      echo "      re-run: dart run drift_dev make-migrations && refresh web/sqlite3.wasm + web/drift_worker.js" >&2
    fi
  fi
else
  echo "    skip: WASM assets not pinned yet (pre-Phase 1)"
fi

if [[ "$GATE_ONLY" == "1" ]]; then
  echo "==> gate-only run complete"
  exit 0
fi

echo "==> flutter build web ${RENDERER_ARGS[*]:-(js/canvaskit)}"
flutter build web "${RENDERER_ARGS[@]}"
echo "==> build complete: build/web"
