#!/usr/bin/env bash
#
# build_web.sh — build the Masi web bundle and enforce the web guardrails.
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
# Match real import/export DIRECTIVES only (a line that starts with import/export
# 'dart:io'), never prose: doc comments legitimately mention `dart:io` when they
# explain the wasm conditional-import split, and a raw substring grep flags those
# as false positives (which is what used to make this gate fail on clean code).
OFFENDERS="$(grep -rlE "^[[:space:]]*(import|export)[[:space:]]+['\"]dart:io['\"]" lib --include="*.dart" | grep -v '_native.dart' || true)"
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
    # Resolve the drift version from pubspec.lock (version: is a few lines under `  drift:`).
    LOCK_DRIFT="$(awk '/^  drift:/{f=1} f&&/^    version:/{gsub(/[" ]/,"",$2); print $2; exit}' pubspec.lock)"
    PINNED_VER="$(sed 's/^drift //' web/.drift_asset_versions | tr -d ' ')"
    if [[ -n "$PINNED_VER" && -n "$LOCK_DRIFT" && "$LOCK_DRIFT" != "$PINNED_VER" ]]; then
      echo "WARN: pubspec.lock has drift $LOCK_DRIFT but web/ assets are pinned to $PINNED_VER." >&2
      echo "      refresh: cp \$(find ~/.pub-cache -path '*drift-$LOCK_DRIFT/drift_worker.js') web/ &&" >&2
      echo "               cp \$(find ~/.pub-cache -path '*drift-$LOCK_DRIFT/extension/devtools/build/sqlite3.wasm') web/ &&" >&2
      echo "               echo 'drift $LOCK_DRIFT' > web/.drift_asset_versions" >&2
    else
      echo "    ok: assets match drift $LOCK_DRIFT"
    fi
  fi
else
  echo "    skip: WASM assets not pinned yet (pre-Phase 1)"
fi

if [[ "$GATE_ONLY" == "1" ]]; then
  echo "==> gate-only run complete"
  exit 0
fi

echo "==> flutter build web ${RENDERER_ARGS[*]:-(js/canvaskit)} --no-web-resources-cdn --pwa-strategy=none"
# --no-web-resources-cdn: self-host the renderer. Without it, flutter_bootstrap.js
# resolves skwasm.js/skwasm.wasm (and canvaskit.js/wasm for the dart2js fallback
# build) against https://www.gstatic.com/flutter-canvaskit/<engineRevision>/, so an
# offline first paint dies on a cross-origin fetch and the local canvaskit/ payload
# is dead weight. With it, buildConfig gains "useLocalCanvasKit":true and every
# renderer asset is served from canvaskit/ on this origin.
#
# --pwa-strategy=none: do NOT emit Flutter's deprecated cleanup service worker or
# the loader settings that register it. The default (offline-first) makes the
# bootstrap end in `_flutter.loader.load({serviceWorkerSettings: {...}})`, and that
# loader path does `navigator.serviceWorker.getRegistration().then(r => r ? … : …)`
# — so the MOMENT web/index.html registers web/sw.js, Flutter registers
# flutter_service_worker.js at the same scope, REPLACING ours with a 31-line shim
# whose activate handler calls self.registration.unregister() and
# client.navigate(client.url). That is bug #55's reload dance, permanently, plus no
# offline shell at all. With `none`, generateServiceWorker() returns '' and
# generateDefaultFlutterBootstrapScript() emits a bare `_flutter.loader.load();`.
flutter build web "${RENDERER_ARGS[@]}" --no-web-resources-cdn --pwa-strategy=none

echo "==> emitted-bootstrap gate"
BOOTSTRAP="build/web/flutter_bootstrap.js"
if [[ ! -f "$BOOTSTRAP" ]]; then
  echo "FAIL: $BOOTSTRAP was not emitted" >&2
  exit 1
fi
# Deliberately NOT `grep gstatic` — that can never be 0. flutter_bootstrap.js
# inlines the minified flutter.js loader, which always contains the literal
# "https://www.gstatic.com/flutter-canvaskit" as the FALLBACK branch of
#   e.engineRevision && !e.useLocalCanvasKit ? <gstatic url> : "canvaskit"
# The flag does not delete that string, it flips the boolean that selects it.
# So the real signal is the buildConfig key.
if ! grep -q '"useLocalCanvasKit":true' "$BOOTSTRAP"; then
  echo "FAIL: $BOOTSTRAP has no \"useLocalCanvasKit\":true — the renderer is" >&2
  echo "      still resolved against gstatic.com and the app cannot boot offline." >&2
  echo "      Did --no-web-resources-cdn get dropped from the build line above?" >&2
  exit 1
fi
echo "    ok: buildConfig sets useLocalCanvasKit"

# Gate on the loader CALL SITE, not on the identifier `serviceWorkerSettings`.
#
# A bare `grep -q serviceWorkerSettings` can never be 0, for exactly the same
# reason a `grep gstatic` can never be 0: flutter_bootstrap.js inlines the
# MINIFIED flutter.js loader, whose own `load()` signature is
#   async load({serviceWorkerSettings:e,onEntrypointLoaded:n,...}={})
# and whose registration helper destructures `{serviceWorkerVersion:r,...}`.
# Both identifiers are unconditionally present in the loader source regardless
# of the build flag. (Measured on this build: 1 occurrence each, both inside
# the minified loader.)
#
# What --pwa-strategy actually controls is the ARGUMENT the generated tail
# passes. From flutter_tools/lib/src/web/bootstrap.dart:674-688:
#   includeServiceWorkerSettings == true  -> `_flutter.loader.load({ serviceWorkerSettings: {...} });`
#   includeServiceWorkerSettings == false -> `_flutter.loader.load();`
# So the bare call is the positive signal, and an argument object is the
# negative one. Both are checked.
if ! grep -qE '^_flutter\.loader\.load\(\);$' "$BOOTSTRAP"; then
  echo "FAIL: $BOOTSTRAP does not end in a bare \`_flutter.loader.load();\`." >&2
  echo "      Flutter will register flutter_service_worker.js OVER web/sw.js," >&2
  echo "      unregister it, and reload every client (bug #55). Did" >&2
  echo "      --pwa-strategy=none get dropped from the build line above?" >&2
  exit 1
fi
if grep -q '_flutter\.loader\.load({' "$BOOTSTRAP"; then
  echo "FAIL: $BOOTSTRAP calls _flutter.loader.load() WITH a settings object," >&2
  echo "      which means serviceWorkerSettings is being passed and Flutter's" >&2
  echo "      deprecated worker will clobber web/sw.js (bug #55)." >&2
  exit 1
fi
echo "    ok: bootstrap does not register Flutter's deprecated service worker"

# `--pwa-strategy=none` makes generateServiceWorker() return '', so the tool
# still WRITES build/web/flutter_service_worker.js but writes it empty. A
# non-empty file here means the strategy did not take effect.
LEGACY_SW="build/web/flutter_service_worker.js"
if [[ -s "$LEGACY_SW" ]]; then
  echo "FAIL: $LEGACY_SW is non-empty; --pwa-strategy=none did not take effect." >&2
  exit 1
fi
echo "    ok: no legacy Flutter service worker emitted"

echo "==> build complete: build/web"
