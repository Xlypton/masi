# Windows Developer Setup — Masi

> **Honesty note, read first.** This guide was written and verified on **macOS**
> (Apple Silicon, Homebrew toolchain) by an agent that has no Windows machine to
> test on. Every command below that is Windows-specific is marked **[UNVERIFIED
> on Windows]** and is a best-effort translation of a command that *was* run and
> confirmed on this Mac. Where a `tool/*.sh` script depends on Unix-only
> binaries, that is stated plainly and a raw, platform-neutral `flutter`/`dart`
> command is given as the fallback instead of guessing how the script behaves
> under Git Bash. Do not trust a "should work" in this document more than a
> "confirmed on macOS" — verify each gate yourself on the first run and fix
> forward.
>
> This guide targets an **AI coding agent cloning fresh on Windows**, getting to
> a green build fast. The project's current focus is the **web/PWA** target
> (`README`/`CLAUDE.md`: "only the web/PWA matters now"); native iOS is
> deprioritized and, on Windows, impossible outright — see §7.

For what a fresh clone does and does not give you (machine-local vs. committed
state, and the open-work ledger), see **`docs/MIGRATION.md`** — this guide does
not duplicate it, only links to it where relevant.

## Contents

1. [Prerequisites](#1-prerequisites)
2. [Clone + first build](#2-clone--first-build)
3. [Git line endings](#3-git-line-endings)
4. [The gates](#4-the-gates)
5. [Web build and the browser verification loop](#5-web-build-and-the-browser-verification-loop)
6. [Tool script audit — what runs on Windows](#6-tool-script-audit--what-runs-on-windows)
7. [What is impossible on Windows](#7-what-is-impossible-on-windows)
8. [Supabase admin workflow](#8-supabase-admin-workflow)
9. [Deploying the web app](#9-deploying-the-web-app)
10. [Project conventions](#10-project-conventions)
11. [Golden tests](#11-golden-tests)
12. [Troubleshooting](#12-troubleshooting)

---

## 1. Prerequisites

Versions below are the **exact versions verified on the reference (macOS)
machine** as of 2026-08-05 (`flutter --version`, `node --version`, `npx
wrangler --version`, `chromedriver --version`). Pin to these; do not float to
"latest" — this repo's `pubspec.lock` and CI both assume Flutter 3.44.2.

| Tool | Verified version | Windows install route **[UNVERIFIED on Windows]** |
|---|---|---|
| Flutter | 3.44.2 (stable channel), engine `04efd7c093` | `winget install --id Google.Flutter -e` or `choco install flutter`, or manual: download the stable-channel Windows zip from flutter.dev and add `<sdk>\bin` to `PATH`. Then `flutter channel stable && flutter upgrade` if the packaged version drifts from 3.44.2. |
| Dart | 3.12.2 | Bundled with the Flutter SDK above — do not install separately. |
| Git | any recent | `winget install --id Git.Git -e` (this also provides **Git Bash**, which is what lets the `tool/*.sh` scripts run at all — see §6). |
| Node.js | v23.11.0 | `winget install OpenJS.NodeJS` or `choco install nodejs`. Needed only for `npx wrangler` (deploy). |
| wrangler (Cloudflare Pages CLI) | 4.119.0 | Not installed separately — invoked via `npx wrangler@latest` (or pin `npx wrangler@4.119.0`) once Node is present. |
| Google Chrome | matching the ChromeDriver major version below | `winget install Google.Chrome`. |
| ChromeDriver | 150.0.7871.124 | Download from **Chrome for Testing** (`googlechromelabs.github.io/chrome-for-testing`) — pick the `win64` build whose **major version matches your installed Chrome's major version exactly** (e.g. Chrome 150.x needs ChromeDriver 150.x). Put `chromedriver.exe` on `PATH`. |
| jq | any recent | `winget install jqlang.jq` or `choco install jq` — needed only for the Supabase admin workflow (§8). |
| curl | any recent | Ships with modern Windows 10/11 (`curl.exe` is in the box). Verify with `curl --version`. |

**Why the version match matters:** `tool/drive_web.sh`'s whole job is
launching `chromedriver` and pointing `flutter drive` at headless Chrome. A
ChromeDriver whose major version doesn't match the installed Chrome refuses
the session handshake — the browser verification loop (§5) fails outright,
not flakily. Re-check both versions any time either Chrome or ChromeDriver
auto-updates.

There is **no `.env` file and no dart-define required** to build this project
— see §2.

## 2. Clone + first build

```
git clone <repo-url> masi
cd masi
flutter pub get
```

`lib/core/config/supabase_config.dart` carries **committed `defaultValue`s**
for both `SUPABASE_URL` and `SUPABASE_ANON_KEY` (an RLS-protected
`sb_publishable_…` anon key — safe to embed, verified by reading the file).
That means:

- **No `.env` file** is read by this app.
- **No `--dart-define` is required** to build, run, or reach the live
  Supabase backend (project ref `mnaipcqbkqzffgvxpato`).
- No secret needs to exist on disk for a build to succeed or for the app to
  sync against the real backend.

First-time cross-platform sanity check (native desktop target, no Chrome/web
toolchain needed for this one):

```
flutter analyze
flutter test
```

See §4 for exact expected results. To build the actual product target (web),
skip ahead to §5 — do not try `flutter build ios` or `flutter build apk` here;
this repo's platform folders are `ios/`, `android/`, `web/`, `windows/`,
`macos/`, `linux/` (whatever `flutter create` left behind), but the project's
supported/maintained targets are **iOS (deprioritized) and web (current
focus)**. A Windows-desktop build was not part of this task and is unverified
in either direction — if you need it, budget time to make sure `windows/` is
current, since the last few months of work were mac + web only.

## 3. Git line endings

The repo contains **executable bash scripts** under `tool/*.sh`, each starting
with a `#!/usr/bin/env bash` shebang. Git on Windows, by default
(`core.autocrlf=true`, the typical Windows Git-for-Windows default), rewrites
committed `LF` line endings to `CRLF` on checkout. A `CRLF`-terminated
shebang line becomes `#!/usr/bin/env bash\r`, which the kernel's `#!`
interpreter-line parser reads as a request for an interpreter literally named
`bash\r` — which does not exist — and every one of those scripts fails to
execute with a cryptic `bad interpreter` error, even though the file looks
fine in an editor.

This repo has **no `.gitattributes`** (verified — `git check-attr` finds
nothing) enforcing line endings itself, so nothing prevents this trap by
default. Before cloning, or immediately after:

```
git config --global core.autocrlf input
```

`input` means "convert CRLF to LF on commit, do not touch LF on checkout" —
it keeps the working tree byte-identical to what's in the repo (LF) while
still protecting you if you ever edit a file in a CRLF-native Windows editor.
Do **not** use `core.autocrlf true`, which converts on checkout and
reintroduces exactly this bug. If scripts still fail after setting this,
check `git diff --stat` for unexpected whole-file rewrites, or re-clone after
setting the config (a config change doesn't retroactively fix files already
checked out).

## 4. The gates

These are the same gates CI (`.github/workflows/ci.yml`) enforces. Run them
in this order.

### `flutter analyze` — must be 0 issues

```
flutter analyze
```
Verified on macOS just now: **"No issues found!"** (ran in ~49s). This
command is platform-neutral Dart tooling — expect the same result on Windows.

### `flutter test` — the real, observed count

```
flutter test
```
**Verified on macOS just now: 2324 passed, 4 failed**, all 4 failures in
`test/features/topo/presentation/route_legend_log_ascent_test.dart`. Re-running
that single file in isolation immediately afterward: **all 4 pass**
(`flutter test test/features/topo/presentation/route_legend_log_ascent_test.dart`
→ "All tests passed!"). This matches a documented, known trap (§12): this
suite is unreliable under concurrent system load and produces different
transient failures on different runs above roughly 150 load average. **Do
not** treat one flaky full-suite run as a real regression — rerun the specific
failing file(s) alone before concluding anything is actually broken.
`docs/MIGRATION.md` recorded 2330 passing at its last clean handoff; the small
drift from 2324/4-flaky here is expected run-to-run variance, not a
Windows-specific number — you have no baseline to compare a Windows count
against yet, so treat "0 analyze issues, full suite green (rerunning any
isolated flake)" as the bar, not a specific integer.

**Never drive a real image-codec decode in a widget test** — it hangs under
fake-async. Existing tests already avoid this via injected `imageSize` /
`TopoCanvasBody` harnesses; follow the same pattern in new tests.

### The `dart:io` grep gate

Enforced two places — `tool/build_web.sh` and
`.github/workflows/ci.yml`'s `dart-io-gate` job — with **byte-identical**
regexes on purpose (a divergence either lets a real leak through or turns
red on doc-comment prose). The real gate matches import/export *directives*
only, not any substring occurrence of `dart:io`:

```bash
grep -rlE "^[[:space:]]*(import|export)[[:space:]]+['\"]dart:io['\"]" lib --include="*.dart" | grep -v '_native.dart'
```
Must print nothing. (The simpler substring form quoted in `CLAUDE.md`,
`grep -r "dart:io" lib --include="*.dart" | grep -v _native.dart`, is close
enough for a quick manual check but will false-positive on doc comments that
*talk about* the conditional-import seam — prefer the directive-anchored
regex above, which is what actually gates CI.)

**PowerShell equivalent [UNVERIFIED on Windows]:**
```powershell
Get-ChildItem -Path lib -Recurse -Filter *.dart |
  Where-Object { $_.Name -notlike '*_native.dart' } |
  Select-String -Pattern '^\s*(import|export)\s+[''"]dart:io[''"]' |
  Select-Object Path, LineNumber
```
This should print nothing on a clean tree. If PowerShell's regex quoting
around the mixed single/double quotes misbehaves, fall back to running the
exact bash one-liner above inside Git Bash — it needs no Windows-only binary,
only `grep`, which Git Bash ships.

### `tool/build_web.sh --gate`

Runs just the `dart:io` gate plus a drift/sqlite3 WASM-asset staleness check,
no build. See §6 for whether this script runs as-is on Windows; the gate
logic itself uses only `grep`, `awk`, `sed`, all present in Git Bash.

## 5. Web build and the browser verification loop

### Building

```
flutter build web --wasm                 # wasm — the intended default target
flutter build web --wasm --no-web-resources-cdn --pwa-strategy=none  # what tool/build_web.sh actually invokes
flutter build web                        # --js / legacy dart2js+canvaskit fallback
```
`tool/build_web.sh` (see §6 for its Windows verdict) wraps the second form
plus several post-build guardrails: an `emitted-bootstrap` check that the
renderer is self-hosted (not fetched from `gstatic.com`, which would break
offline boot), a check that Flutter's own deprecated service-worker
registration was suppressed (`--pwa-strategy=none` — otherwise it clobbers
`web/sw.js` and forces a reload loop, bug #55 in the project history), and a
`dart run tool/gen_sw_manifest.dart build/web` step that stamps the
service-worker precache manifest. If you cannot run the shell script on
Windows, run the equivalent commands directly:
```
flutter build web --wasm --no-web-resources-cdn --pwa-strategy=none
dart run tool/gen_sw_manifest.dart build/web
```
`gen_sw_manifest.dart` is pure Dart (uses only `dart:io` and `dart:convert`
plus `package:path`) — it runs identically on Windows via `dart run`.

### Browser verification loop (headless Chrome via `flutter drive`)

The canonical invocation, independent of any wrapper script:
```
flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/web_smoke_test.dart \
  -d web-server \
  --browser-name=chrome \
  --driver-port=4444 \
  --headless \
  --no-web-resources-cdn \
  --timeout=300
```
This requires a `chromedriver` already listening on the port you pass to
`--driver-port` (4444 above) — `flutter drive` connects to it, it does not
launch it for you. Start it first, in its own terminal or backgrounded:
```
chromedriver --port=4444
```
Two integration tests are the reference points, per `CLAUDE.md`:
`integration_test/web_harness_check_test.dart` (trivial pipeline proof, no
`expect()` calls) and `integration_test/web_smoke_test.dart` (boots the real
app, drives Area→Sector→Wall against drift-on-WASM/IndexedDB). Screenshots
land in `build/screenshots/<name>.png` via `test_driver/integration_test.dart`
— read them as images to verify visually; the app renders to a `<canvas>`, so
there is no DOM to assert against for most of what matters.

`tool/drive_web.sh` (see §6) automates the chromedriver start/stop, a
port-hygiene preflight, and a hard wall-clock watchdog around the exact
command above — use it if your shell can run it, fall back to the raw
command block above if not.

## 6. Tool script audit — what runs on Windows

Every script under `tool/` was read end-to-end for macOS-only assumptions
(`xcrun`/`devicectl`/`simctl`, `osascript`, `open -a`, `killall`, BSD-only
flags, hardcoded `/opt/homebrew/bin`, `lsof`, BSD `mktemp`/`sed -i ''`
syntax). Verdicts below are **[UNVERIFIED on Windows]** — inferred from
reading each script's actual commands, not from running them on Windows.

| Script | Shebang | macOS-only content found | Windows verdict |
|---|---|---|---|
| `build_web.sh` | `#!/usr/bin/env bash` | `export PATH="/opt/homebrew/bin:$PATH"` — harmless no-op if that path doesn't exist. All other commands (`grep -rlE`, `awk`, `sed`, `flutter build`, `dart run`) are GNU-compatible and Git Bash ships GNU coreutils. | **Should run under Git Bash** as-is. No binary it calls is macOS-exclusive. |
| `drive_web.sh` | `#!/usr/bin/env bash` | Port-hygiene logic (`port_listener_pids`, `pid_command`) calls **`lsof`** and `ps -o comm=`; also `kill -0` / `kill -9` against arbitrary PIDs. `lsof` does not ship with Windows or Git Bash. | **Broken as-is on Windows** — the stuck-port preflight will fail with `lsof: command not found` before it starts chromedriver. Use the raw `flutter drive` command in §5 instead, with `chromedriver` started manually; if a prior run left port 4444 stuck, find and kill it with `netstat -ano \| findstr :4444` (PowerShell: `Get-NetTCPConnection -LocalPort 4444`) and `taskkill /PID <pid> /F` **[UNVERIFIED on Windows]**. |
| `drive_web_photo_offline.sh` | `#!/usr/bin/env bash` | Calls `drive_web.sh` twice (inherits its `lsof` dependency) as a chained two-run harness; also uses `mktemp -d -t masi_photo_profile` — **BSD `mktemp` syntax** (`-t prefix`). GNU `mktemp` (what Git Bash ships) interprets `-t` differently and may error on a bare prefix without an `XXXXXX` template. `df -m` for a free-disk check is GNU-compatible. | **Likely broken on Windows** on two independent counts (the inherited `lsof` dependency, and the BSD/GNU `mktemp` divergence). No safe raw-command substitute is given here — this script measures a specific durability property (photo survives a real browser restart) that needs a two-process chained Chrome-profile harness; treat this as **Mac-only for now** and re-derive a Windows equivalent only if that specific measurement is needed there. |
| `drive_web_write_order.sh` | `#!/usr/bin/env bash` | Same shape and same two issues as `drive_web_photo_offline.sh` (chains `drive_web.sh`, plus its own `mktemp -d -t` call). | Same verdict: **likely broken on Windows**, Mac-only for now. |
| `drive_ar_seg.sh` | `#!/usr/bin/env bash` | Explicitly targets an iOS Simulator/device id (`flutter devices`) and Core ML over a native channel. | **N/A on Windows regardless of shell issues** — this is the AR/iOS integration test; see §7. Do not attempt. |
| `supabase_query.sh` | `#!/usr/bin/env bash` | `curl`, `jq`, `tr -d '[:space:]'`, `$HOME`. No macOS-exclusive binary. | **Should run under Git Bash** once `curl` and `jq` are on `PATH`. `$HOME` resolves under Git Bash to the Windows user profile. See §8 for the token-path translation. |
| `gen_sw_manifest.dart` | (Dart, no shebang — run via `dart run`) | None — pure Dart (`dart:io`, `dart:convert`, `package:path`). | **Runs identically on Windows.** |
| `serve_web_isolated.py` | `#!/usr/bin/env python3` | None found — stdlib-only (`http.server`, `mimetypes`, `os`, `sys`). | **Should run on Windows** via `python tool/serve_web_isolated.py <port> [--no-coop]`, given Python 3 installed. |
| `verify_offline_shell.py` | `#!/usr/bin/env python3` | Spawns `serve_web_isolated.py` (via `sys.executable`, portable) and `chromedriver` directly via `subprocess.Popen` — no shell wrapper, no `lsof`. One cosmetic string hardcodes a macOS install hint (`"in /opt/homebrew/bin."`) that is simply wrong advice on Windows, not a functional break. | **Likely runs on Windows** given Python 3 + `chromedriver` + whatever browser-automation library it imports (not audited line-by-line here) on `PATH`. The macOS-specific error message is misleading but not blocking. |
| `verify_pointer_geometry.py` | `#!/usr/bin/env python3` | Calls **`lsof -nP -tiTCP:<port> -sTCP:LISTEN`** via `subprocess.run` for its own port-hygiene check, reserving port 4444 for `drive_web.sh`. | **Its port-hygiene check is broken on Windows** (no `lsof`); the rest of the script may still work if that check is bypassed or ported to `netstat`/`Get-NetTCPConnection` **[UNVERIFIED on Windows]** — not attempted here. |
| `ml/convert_rock_seg_coreml.py` | (Python, Core ML conversion) | Targets Apple's Core ML format for the on-device AR rock-segmentation model. | **N/A on Windows** — output is only consumed by the iOS AR pipeline; see §7. |

**Bottom line:** the two gate-critical scripts split down the middle —
`tool/build_web.sh` should just work under Git Bash; `tool/drive_web.sh`
does not, because of its `lsof`-based port-hygiene preflight, but the
`flutter drive` command it wraps (given in §5) is completely usable on its
own once you start `chromedriver` by hand. The three chained-durability
harnesses (`drive_web_photo_offline.sh`, `drive_web_write_order.sh`,
`drive_ar_seg.sh`) are Mac-only for now; nothing in the day-to-day analyze
→ test → build → drive loop depends on them.

## 7. What is impossible on Windows

Defer all of the following to a Mac. Do not attempt them, do not simulate
them, and do not mark associated work "done" from a Windows session:

- Anything under `ios/` — the Xcode project, `Runner.xcodeproj`, Swift
  Package Manager setup (this repo deliberately has **no `ios/Podfile`** —
  that is not a Windows gap, it's a project convention, but it underlines
  that the iOS build is Xcode-only regardless of host OS).
- `flutter build ios`, `flutter run -d <ios-device>` — no Xcode toolchain
  exists on Windows.
- The iOS Simulator loop entirely (`xcrun simctl ...`, `open -a Simulator`) —
  the Simulator is a macOS-only application.
- `xcrun devicectl` — physical-device install/update/console-log workflow,
  macOS-only tooling.
- **AR / ARKit verification** — per `CLAUDE.md`, this cannot even run in the
  iOS Simulator; it requires the physical iPhone, human-in-the-loop. There is
  no Windows path to this at all, simulated or otherwise.
- iOS-Safari-specific web bugs (e.g. the historical PWA hit-test-offset and
  standalone-mode issues documented in `docs/MIGRATION.md`) — these need a
  real iPhone (or at minimum a Mac running Safari) to reproduce or confirm;
  headless Chrome on Windows cannot exercise WebKit-specific code paths.

`docs/MIGRATION.md`'s "Blocked on a physical device" section lists two
specific open items (a PWA hit-test-offset fix awaiting on-device
confirmation, and a post-commit-flush fix awaiting the same) — **both are
explicitly device-blocked and cannot be closed from Windows.** If you are
asked to make progress on either, the honest answer is that the code-side
fix may already be done (check `docs/MIGRATION.md` for current status) and
what remains is a human tapping a real iPhone.

## 8. Supabase admin workflow

The live Supabase project is a **dev environment** with standing approval (per
`CLAUDE.md`) to inspect and edit its schema directly via the Management API —
`POST https://api.supabase.com/v1/projects/{ref}/database/query`, the same
endpoint the Supabase Dashboard's SQL editor uses. Project ref:
`mnaipcqbkqzffgvxpato`.

**Token.** A personal access token (`sbp_…`), admin-only — the app itself
only ever uses the anon key baked into `supabase_config.dart` (§2).

- **Cloud / dispatched session:** it is already in the environment as
  `$SUPABASE_MGMT_TOKEN`. Nothing to set up; `tool/supabase_query.sh` uses it
  automatically.
- **Local dev box:** it lives at `~/.config/climbtopo-mgmt-token`. On Windows
  that is `%USERPROFILE%\.config\climbtopo-mgmt-token`, or from Git Bash
  `$HOME/.config/climbtopo-mgmt-token` (Git Bash maps `$HOME` to the same user
  profile directory). This file does not exist on a fresh clone or a fresh
  machine (per `docs/MIGRATION.md`, it is explicitly machine-local) — issue a
  new one from the Supabase dashboard if the workflow is needed, or export it as
  `SUPABASE_MGMT_TOKEN` for the session instead.

Every script checks `$SUPABASE_MGMT_TOKEN` first, then the file (see `CLAUDE.md`
"Cloud vs local: how secrets arrive"). **Never print, log, echo, or commit this
token's contents** — read it straight into a variable and use it only as an
`Authorization: Bearer` header value, exactly as `tool/supabase_query.sh` does.

**Recipe** (`tool/supabase_query.sh` — see §6, this one should run under Git
Bash given `curl` and `jq` on `PATH`):
```bash
tool/supabase_query.sh -q "SELECT 1;"          # inline query
tool/supabase_query.sh path/to/migration.sql   # whole-file DDL
```
Raw form, if you need it inline instead of the script (bash, incl. Git Bash):
```bash
REF=mnaipcqbkqzffgvxpato
TOKEN="${SUPABASE_MGMT_TOKEN:-$(tr -d '[:space:]' < "$HOME/.config/climbtopo-mgmt-token")}"
API="https://api.supabase.com/v1/projects/$REF/database/query"
curl -sS -X POST "$API" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  --data "$(jq -n --arg q 'SELECT 1;' '{query:$q}')"
```

**PowerShell equivalent of the `jq -n --arg q ... '{query:$q}'` body-building
step [UNVERIFIED on Windows]** — PowerShell's native JSON handling can build
the same request body without `jq` at all:
```powershell
$token = (Get-Content "$env:USERPROFILE\.config\climbtopo-mgmt-token" -Raw).Trim()
$ref = "mnaipcqbkqzffgvxpato"
$api = "https://api.supabase.com/v1/projects/$ref/database/query"
$body = @{ query = "SELECT 1;" } | ConvertTo-Json
Invoke-RestMethod -Uri $api -Method Post -Headers @{ Authorization = "Bearer $token" } `
  -ContentType "application/json" -Body $body
```
If `jq` is preferred for parity with the Mac recipe, install it per §1 and
the bash form above works unchanged in Git Bash.

**Inspect before you write DDL.** Per `CLAUDE.md`'s hard-won convention:
column *types*, nullability, and RLS policy shape are not reliably inferable
from the Dart client code — query `information_schema.columns` and
`pg_policies` live before writing any migration, on any OS.

## 9. Deploying the web app

The live site is `https://climb-masi.pages.dev`, a Cloudflare Pages project
named **`climb-masi`**. Deploy flow (per the `deploy-web` skill and
`docs/MIGRATION.md`):
```
npx wrangler login                          # first time only, per machine
flutter build web --wasm                    # or tool/build_web.sh, see §5/§6
npx wrangler pages deploy build/web --project-name=climb-masi
```
Cloudflare Wrangler auth is machine-local (stored under a user config
directory — `~/Library/Preferences/.wrangler` on the reference Mac; on
Windows this is `%APPDATA%\xdg.config\.wrangler` or similar
**[UNVERIFIED on Windows — `wrangler login` will report the actual path it
uses on first run]**). It does not come with the clone; `wrangler login`
must be re-run on every new machine.

**COOP/COEP headers are a hard hosting requirement**, not an optimization.
`web/_headers` sets:
```
/*
  Cross-Origin-Opener-Policy: same-origin
  Cross-Origin-Embedder-Policy: require-corp
  Cross-Origin-Resource-Policy: same-origin
```
because the wasm build plus drift's OPFS (Origin Private File System) worker
require the page to be **cross-origin isolated**; without these headers the
browser never exposes `SharedArrayBuffer`, drift's storage-backend probe
never offers `opfsLocks`, and the app silently falls back to a weaker
IndexedDB storage backend with different (worse) write-durability semantics.
If you ever stand up your own hosting for this app (not Cloudflare Pages),
these three headers must be reproduced on the top-level document response.

**Read `web/_headers`'s own comment block before editing it.** Cloudflare
Pages **appends** same-named headers across every matching rule block rather
than resolving by path specificity — a documented, already-shipped-twice
footgun (doubled `Content-Type: application/wasm` broke wasm instantiation;
doubled `Cache-Control` values were self-contradictory). The rule the file
states explicitly: for any given header name, exactly one block in this file
may set it for a given path.

## 10. Project conventions a new agent will otherwise violate

- **Riverpod v3.** Use `Notifier`/`AsyncNotifier`/`NotifierProvider` (v3
  APIs). **Never `StateProvider`** — it's the pre-v3 pattern and is banned
  project-wide (`flutter_riverpod: ^3.3.2` in `pubspec.yaml`, confirmed).
- **Icons.** All icons go through the `MasiIcon` widget
  (`lib/shared/presentation/masi_icon.dart`), backed by ~80 SVGs at
  `assets/icons/masi/`. **Never introduce `Icons.X` or `CupertinoIcons.X`** —
  this is a standing user mandate, not a style suggestion.
- **`dart:io` conditional-import seam.** Anything that touches `dart:io` must
  be split behind a conditional import:
  ```dart
  import 'x_stub.dart' if (dart.library.io) 'x_native.dart' if (dart.library.js_interop) 'x_web.dart';
  ```
  `_native.dart` files hold the existing native-platform code verbatim.
  **Never use `kIsWeb` to gate `dart:io` usage** — reserve `kIsWeb` for
  behavioral differences on already-web-capable plugins. Also: **`kIsWeb` is
  permanently `false` under `flutter test`** (there's no way to make a unit
  test see itself as "web"), so any test that needs to exercise the web
  branch of a conditional-import seam must inject the web implementation
  directly, not flip `kIsWeb`.
- **No real image-codec decode in widget tests** — hangs under fake-async.
  Use the injected `imageSize` / `TopoCanvasBody` test harness pattern already
  present in the test suite.
- **`MasiShimmer` / any repeating animation defeats `pumpAndSettle()`** — a
  widget with a perpetual animation never reaches a settled frame, so
  `pumpAndSettle()` hangs (or times out) against any screen using it. Pump a
  fixed number of frames / a fixed duration instead in tests that touch such
  screens.
- **Commit conventions.** `type(scope): summary` messages (e.g.
  `fix(topo): center canvas image vertically`). Every commit this guide's
  own authoring convention requires ends with the trailer:
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  ```
  (Confirm the exact trailer text expected in your own task instructions —
  it has changed between model versions in this project's history; use
  whatever your current instructions specify.)

## 11. Golden tests

This suite includes golden-image (pixel-snapshot) tests. Golden tests are
inherently **platform- and font-sensitive** — font hinting/rasterization,
subpixel rendering, and even Skia/Impeller build differences between macOS
and other host OSes can shift pixels without any real regression in the
code under test. **A golden failure observed for the first time on a Windows
host may be a platform difference, not a regression introduced by your
change.** Do not "fix" it by blindly regenerating (`--update-goldens`) —
that has a real risk of baking a Windows-only baseline into the repo that
then fails for every macOS/CI run afterward. Cross-check: does the same test
fail on a clean `main` checkout with no changes of yours? If yes, it's a
platform artifact of running goldens on Windows for the first time, worth
flagging rather than silently re-blessing.

## 12. Troubleshooting

Failure modes actually observed on this project (not hypothetical):

- **Chromedriver holds port 4444 (or whatever port you used) after a failed
  launch.** A crashed or wedged `chromedriver` leaves its listen socket open;
  the next `flutter drive` run connects to the dead process and hangs until
  its own timeout, with no useful error. On macOS the fix is
  `lsof -nP -tiTCP:4444 -sTCP:LISTEN` then `kill -9 <pid>` (this is exactly
  what `tool/drive_web.sh`'s port-hygiene preflight automates — see §6 for
  why that automation doesn't carry over to Windows as-is). **On Windows
  [UNVERIFIED]**: `netstat -ano | findstr :4444` to find the PID, then
  `taskkill /PID <pid> /F`; PowerShell equivalent:
  `Get-Process -Id (Get-NetTCPConnection -LocalPort 4444).OwningProcess | Stop-Process -Force`.
- **A fresh browser profile is structurally blind to the service-worker
  path.** The very first load of a brand-new Chrome profile against this app
  cannot exercise the offline service-worker registration/precache flow —
  load the page **twice** before trusting any offline-shell verification.
  This applies to headless Chrome on Windows exactly as it does on macOS; it
  is a Chrome behavior, not an OS one.
- **Cloudflare `_headers` appends, it does not override, duplicate rules.**
  See §9 — this has already caused two real production outages (doubled
  wasm `Content-Type`, self-contradictory `Cache-Control`). Read the comment
  block at the top of `web/_headers` in full before adding any new block to
  that file, on any OS.
- **The full `flutter test` suite is unreliable above roughly 150 system load
  average** — different tests fail on different runs under heavy concurrent
  load (e.g. several parallel test/build processes on the same machine). This
  was observed and documented on the reference Mac; it is plausible the same
  ceiling (or a different one) applies on Windows given enough concurrent
  agents/processes, but that has not been measured. If `flutter test` reports
  failures that don't reproduce when the specific failing file is re-run
  alone, suspect load-induced flakiness before suspecting your change — see
  §4's worked example (`route_legend_log_ascent_test.dart`: failed under full
  suite, passed 4/4 in isolation, same tree).
