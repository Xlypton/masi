#!/usr/bin/env bash
# Prepare a Linux cloud/container session (Claude Code on the web, CI-like
# sandboxes) for Masi development. Idempotent: safe to re-run, and every step
# no-ops on a machine that already satisfies it.
#
# The macOS and Windows dev boxes documented in CLAUDE.md need NONE of this —
# this script only fixes gaps that are specific to the ephemeral Linux image:
#
#   1. Flutter is installed at /opt/flutter but is not on PATH.
#   2. The flutter_web_sdk artifact is not precached, which fails three
#      engine-source guard tests (test/web_font_source_test.dart, and the
#      viewport check in test/web_geometry_source_test.dart) with
#      "not found under the resolved SDK" rather than a real assertion.
#   3. chromedriver on PATH is a major version ahead of the bundled Chromium,
#      so `flutter drive` dies on an unexplained WebDriver handshake failure.
#   4. chromedriver cannot find a browser binary at all (Chromium lives under
#      /opt/pw-browsers with a non-standard name).
#   5. Chrome ignores HTTPS_PROXY, and this sandbox has no direct egress for
#      it, so the app boots OFFLINE in every driven test.
#   6. Chrome does not trust the egress proxy's MITM CA (ERR_CERT_AUTHORITY_
#      INVALID), and the proxy RESETS TLS 1.3 ClientHellos from Chrome.
#
# Run once per session:  bash tool/setup_cloud_session.sh
# Then, for driven web tests:  export CHROME_EXECUTABLE=/usr/local/bin/google-chrome

set -euo pipefail

FLUTTER_ROOT="${FLUTTER_ROOT:-/opt/flutter}"
PW_BROWSERS="${PLAYWRIGHT_BROWSERS_PATH:-/opt-pw-browsers-unset}"
CA_BUNDLE="${CCR_CA_BUNDLE:-/root/.ccr/ca-bundle.crt}"
NSSDB="${HOME}/.pki/nssdb"
BIN_DIR=/usr/local/bin
CHROME_SHIM="$BIN_DIR/google-chrome"

say() { printf '==> %s\n' "$*"; }
skip() { printf '    skip: %s\n' "$*"; }
ok()   { printf '    ok: %s\n' "$*"; }

# --- 1. Flutter on PATH -------------------------------------------------------
say "flutter on PATH"
if command -v flutter >/dev/null 2>&1; then
  ok "already on PATH ($(command -v flutter))"
elif [ -x "$FLUTTER_ROOT/bin/flutter" ]; then
  export PATH="$FLUTTER_ROOT/bin:$PATH"
  ok "added $FLUTTER_ROOT/bin to PATH for this script"
  echo "    NOTE: export PATH=\"$FLUTTER_ROOT/bin:\$PATH\" in your own shell too."
else
  echo "    FAIL: no flutter at $FLUTTER_ROOT/bin/flutter and none on PATH." >&2
  exit 1
fi

# --- 2. Web SDK artifact ------------------------------------------------------
say "flutter_web_sdk artifact"
if [ -d "$FLUTTER_ROOT/bin/cache/flutter_web_sdk/lib/_engine" ]; then
  ok "already precached"
else
  flutter precache --web >/dev/null
  ok "precached (unblocks the engine-source guard tests)"
fi

# --- 3/4. Chromium + a version-matched chromedriver ---------------------------
say "chromium + chromedriver"
CHROME_BIN=""
for cand in \
  "$PW_BROWSERS"/chromium-*/chrome-linux/chrome \
  /opt/pw-browsers/chromium-*/chrome-linux/chrome \
  /usr/bin/chromium /usr/bin/chromium-browser /usr/bin/google-chrome; do
  [ -x "$cand" ] && { CHROME_BIN="$cand"; break; }
done

if [ -z "$CHROME_BIN" ]; then
  skip "no chromium found — driven web tests (tool/drive_web.sh) unavailable"
else
  ok "chromium at $CHROME_BIN"
  CHROME_FULL="$("$CHROME_BIN" --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+){3}' | head -1)"
  CHROME_MAJOR="${CHROME_FULL%%.*}"

  DRIVER_MAJOR=""
  command -v chromedriver >/dev/null 2>&1 && \
    DRIVER_MAJOR="$(chromedriver --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+){3}' | head -1 | cut -d. -f1)"

  if [ "$DRIVER_MAJOR" = "$CHROME_MAJOR" ]; then
    ok "chromedriver $DRIVER_MAJOR already matches Chrome $CHROME_MAJOR"
  else
    say "  installing chromedriver $CHROME_MAJOR (have '${DRIVER_MAJOR:-none}')"
    TMP="$(mktemp -d)"
    URL="$(curl -sS --max-time 60 \
      https://googlechromelabs.github.io/chrome-for-testing/known-good-versions-with-downloads.json \
      | jq -r --arg maj "$CHROME_MAJOR" '
          [.versions[] | select(.version | startswith($maj + "."))]
          | last
          | .downloads.chromedriver[]? | select(.platform=="linux64") | .url')"
    if [ -z "$URL" ] || [ "$URL" = "null" ]; then
      echo "    FAIL: no chromedriver $CHROME_MAJOR published for linux64." >&2
      exit 1
    fi
    curl -sS --max-time 300 -o "$TMP/cd.zip" "$URL"
    unzip -oq "$TMP/cd.zip" -d "$TMP"
    # ~/.local/bin precedes the image's own chromedriver on PATH.
    mkdir -p "$HOME/.local/bin"
    install -m 0755 "$TMP/chromedriver-linux64/chromedriver" "$HOME/.local/bin/chromedriver"
    rm -rf "$TMP"
    ok "installed $($HOME/.local/bin/chromedriver --version | head -1)"
    case ":$PATH:" in
      *":$HOME/.local/bin:"*) ;;
      *) echo "    NOTE: put $HOME/.local/bin FIRST on PATH so this one wins." ;;
    esac
  fi

  # --- 5/6. The Chrome shim: findable, proxied, and CA-trusting ---------------
  say "chrome shim at $CHROME_SHIM"
  PROXY="${HTTPS_PROXY:-${https_proxy:-}}"
  PROXY_LINE=""
  if [ -n "$PROXY" ]; then
    PROXY_LINE="  --proxy-server=\"$PROXY\" \\
  --proxy-bypass-list=\"localhost;127.0.0.1;[::1]\" \\
  --ssl-version-max=tls1.2 \\"
  fi
  cat > "$CHROME_SHIM" <<EOF
#!/bin/sh
# Generated by tool/setup_cloud_session.sh — do not edit by hand.
#   --no-sandbox / --disable-dev-shm-usage : running as root in a container.
#   --proxy-server   : Chrome does NOT read HTTPS_PROXY, and this sandbox has
#                      no direct egress for it, so without this the app boots
#                      offline in every driven test.
#   --proxy-bypass-list : flutter drive serves the app from localhost.
#   --ssl-version-max=tls1.2 : the egress proxy RESETS TLS 1.3 ClientHellos
#                      from Chrome. Certificate verification stays fully ON —
#                      the proxy CA is imported into the NSS store below.
exec "$CHROME_BIN" \\
  --no-sandbox --disable-dev-shm-usage \\
$PROXY_LINE
  "\$@"
EOF
  chmod +x "$CHROME_SHIM"
  ln -sf "$CHROME_SHIM" "$BIN_DIR/chrome"
  ln -sf "$CHROME_SHIM" "$BIN_DIR/chromium"
  ok "shim written (chromedriver finds Chrome by name on PATH)"

  say "proxy CA in the chrome NSS store"
  if [ -z "$PROXY" ]; then
    skip "no HTTPS_PROXY set — nothing to trust"
  elif [ ! -r "$CA_BUNDLE" ]; then
    skip "no CA bundle at $CA_BUNDLE"
  elif ! command -v certutil >/dev/null 2>&1; then
    skip "certutil missing — install libnss3-tools, else Chrome fails with ERR_CERT_AUTHORITY_INVALID"
  else
    mkdir -p "$NSSDB"
    [ -f "$NSSDB/cert9.db" ] || certutil -d "sql:$NSSDB" -N --empty-password
    if certutil -d "sql:$NSSDB" -L 2>/dev/null | grep -q '^ccr-ca-0 '; then
      ok "already imported"
    else
      TMP="$(mktemp -d)"
      ( cd "$TMP" && csplit -z -f ccr-ca- -b '%03d.pem' "$CA_BUNDLE" '/BEGIN CERTIFICATE/' '{*}' >/dev/null )
      n=0
      for f in "$TMP"/ccr-ca-*.pem; do
        certutil -d "sql:$NSSDB" -A -t "C,," -n "ccr-ca-$n" -i "$f" 2>/dev/null && n=$((n+1))
      done
      rm -rf "$TMP"
      ok "imported $n certificates"
    fi
  fi
fi

cat <<'DONE'

==> ready. For driven web tests, in your shell:

      export PATH="/opt/flutter/bin:$HOME/.local/bin:$PATH"
      export CHROME_EXECUTABLE=/usr/local/bin/google-chrome
      dart run tool/gate.dart
      tool/drive_web.sh integration_test/web_smoke_test.dart
DONE
