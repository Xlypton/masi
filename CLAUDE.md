# Masi — Project Instructions

Flutter climbing-route documentation app (visual-first topo editor). Full spec: **`MASI.md`**.
iOS-primary. Local-first (Drift/SQLite). Riverpod **v3** (use `Notifier`, never `StateProvider`).
v1 (M0–M6) + v2 AR are code-complete on `main`. Supabase sync is implemented and live —
a debounced, dirty-scoped **full-state re-push** + pull, with tombstoned soft-delete, in
`lib/features/backup/` (`sync_service.dart`, `sync_orchestrator.dart`, `backup_repository.dart`),
verified end-to-end. **There is no outbox**, and building one is explicitly out of scope (decision
D-4): the engine re-reads and re-sends own rows, which is what makes it idempotent and loss-proof.

> This used to say "`grep -rin outbox lib` returns zero hits". It does not, and has not for a long
> time — it returns **28 hits across 18 files**, every one of them a doc comment explaining why
> there is no outbox. An agent that runs the stated command and sees 28 concludes either that the
> doc lies or that an outbox exists; both are worse than no command at all. What actually returns
> zero, and proves the thing:
> ```bash
> grep -rniE "class [A-Za-z]*Outbox|[A-Za-z]*Outbox\(|outbox_" lib
> ```

## Toolchain quirks (read first)

**THREE environments work this repo, and most of this file was written for the first one.** Check
which you are on before copying a command out of here — `uname`/`$PATH` answers it in one call, and
the macOS-shaped commands below fail on the others in ways that read like a broken toolchain rather
than a wrong platform. The third is the **Linux cloud container** (Claude Code on the web): it is
ephemeral, rebuilt per session, and needs a one-time setup command — see the section right below the
table.

| | macOS dev box | Windows dev box | Linux cloud container |
|---|---|---|---|
| repo | `/Users/kerip/Projects/masi` | `C:\Projects\masi` | `/home/user/masi`, cloned fresh per session |
| flutter/dart | Homebrew; **prefix every command** with `export PATH="/opt/homebrew/bin:$PATH" && ` | `C:\flutter\bin\flutter.bat` — already on PATH, **no prefix needed** | `/opt/flutter/bin` — installed but **NOT on PATH**, prefix with `export PATH="/opt/flutter/bin:$PATH" && ` |
| shell | bash | PowerShell **and** Git Bash (MINGW64). `tool/*.sh` run fine under Git Bash | bash, as root |
| chromedriver | `/opt/homebrew/bin/chromedriver` | `C:\tools\chromedriver.exe` (on PATH) | the one on PATH is the **wrong major version**; the setup script installs a matching one to `~/.local/bin` |
| jq / curl | Homebrew | `C:\tools\jq.exe`, `C:\Windows\System32\curl.exe` | `/usr/bin/jq`, `/usr/bin/curl` |
| node / npx | Homebrew | portable at `C:\tools\nodejs`, **NOT on PATH** — `export PATH="/c/tools/nodejs:$PATH"` | `/opt/node22/bin`, on PATH |
| iOS sim / device / AR | yes | **no** — anything `xcrun`/`devicectl` is macOS-only | **no** |
| headless-Chrome screenshots | real pixels | **flat theme background, ~4 KB every time** — CanvasKit does not composite here. Use `read_console_messages` / `javascript_tool` for evidence instead | real pixels (verified 2026-08-27), once the setup script has run |

- Flutter 3.44.2 · Dart 3.12.2 · Xcode 26.6 (macOS only).

### Linux cloud container — run this FIRST, once per session

```bash
bash tool/setup_cloud_session.sh
export PATH="/opt/flutter/bin:$HOME/.local/bin:$PATH"
export CHROME_EXECUTABLE=/usr/local/bin/google-chrome
```

The script is idempotent and no-ops on macOS/Windows-shaped machines. It exists because the image
has six gaps that each fail as something other than what they are — the reason the script explains
every one inline rather than just fixing it:

- **Flutter is at `/opt/flutter` but not on PATH** — reads as "no Flutter installed".
- **`flutter_web_sdk` is not precached.** Three guard tests read Flutter's own engine sources and
  **fail rather than skip** when they can't find them (that is deliberate — see the reasons in
  `test/web_font_source_test.dart`). Un-precached, `flutter test` reports **3 failures that are not
  repo bugs**. `flutter precache --web` clears them.
- **chromedriver on PATH is a major version ahead of the bundled Chromium**, which `flutter drive`
  reports as an unexplained WebDriver handshake failure. `dart run tool/preflight_chromedriver.dart`
  names it properly — run that first whenever a driven web test dies early.
- **chromedriver can't find a browser at all**: Chromium lives at
  `/opt/pw-browsers/chromium-*/chrome-linux/chrome`, which is not a name it searches. The script
  writes a `/usr/local/bin/google-chrome` shim so it is found by name.
- **Chrome does not read `HTTPS_PROXY`, and this sandbox gives it no direct egress.** Without
  `--proxy-server` every driven test boots the app **offline** — you get a real screenshot of the
  offline banner and can easily read it as an app bug. The shim passes the proxy.
- **Chrome does not trust the egress proxy's MITM CA**, and the proxy **resets TLS 1.3
  ClientHellos** from Chrome. Both surface identically as `ERR_CONNECTION_RESET`; only a net-log
  (`--log-net-log=…`, then look for `net_error:-202`) separates them. The script imports the CA into
  the NSS store and the shim caps at `--ssl-version-max=tls1.2`. **Certificate verification stays
  fully on** — do not "fix" this with `--ignore-certificate-errors`.

Two more things that are true here and nowhere else:

- **`$SUPABASE_MGMT_TOKEN` may be present but revoked.** Check it before trusting any schema plan:
  `tool/supabase_query.sh -q 'select 1;'` — a `401 Unauthorized` means the Management-API workflow
  documented below is unavailable this session, even though the variable is set. The anon key and
  the `.test` E2E accounts are on a different credential and can be fine while it is dead.
- **The container is ephemeral.** Everything the setup script does lives outside the repo
  (`/usr/local/bin`, `~/.local/bin`, the NSS store) and is gone next session — which is exactly why
  it is a committed script and not a list of commands in this file.
- **Prefer `dart run tool/<x>.dart` over `tool/<x>.sh` when both exist.** The Dart tools run
  unchanged on both machines and in CI; the shell ones need bash and, on Windows, Git Bash.
- **iOS uses Swift Package Manager, not CocoaPods** — there is intentionally no `ios/Podfile`.
  Don't try to `pod install`; it will fail with "No Podfile found" and that is expected.
- Package name is `masi`; app entrypoint is `main()` in `lib/main.dart`. It builds a
  `ProviderContainer`, awaits `container.read(photoFilesProvider).warmDocsPath()` to pre-warm the
  photo-path cache before the first frame, then calls
  `runApp(UncontrolledProviderScope(container: container, child: const MasiApp()))` —
  not the plain `ProviderScope(child: ...)` pattern.

## Cloud vs local: how secrets arrive

**Both paths are supported and every credential-consuming script checks them in this order: env var
first, then the `~/.config` file.** A local dev box keeps the secrets as plain files under
`~/.config` (see the Management-API and E2E sections below). A **cloud / dispatched Claude Code
session** has no such files — the same secrets are injected as environment variables instead. This
is additive: setting nothing new keeps the local file workflow working exactly as before.

| env var (cloud) | `~/.config` file (local) | consumed by |
|---|---|---|
| `SUPABASE_MGMT_TOKEN` | `climbtopo-mgmt-token` | `tool/supabase_query.sh`, `tool/e2e_common.sh`, `tool/e2e_accounts.sh` |
| `MASI_E2E_PASSWORD` | `masi-e2e-password` | `tool/e2e_common.sh`, `tool/e2e_accounts.sh`, `tool/drive_e2e.sh` |
| `CLOUDFLARE_API_TOKEN` | `cf-pages-token` | `wrangler` reads it natively — no script wraps it |
| `CLOUDFLARE_ACCOUNT_ID` | `cf-account-id` | `wrangler` reads it natively — no script wraps it |
| `MASI_PUSH_HOOK_SECRET` | `masi-push-hook-secret` | Supabase Edge Function secrets only — no repo script |
| `MASI_VAPID_PRIVATE` | `masi-vapid-private` | Supabase Edge Function secrets only — no repo script |
| `MASI_VAPID_PUBLIC` | `masi-vapid-public` | public; committed in `supabase_config.dart` |

`tool/scan_secrets.dart` layer 2 reads whichever form is present, so the secret gate still catches an
accidental commit in a cloud session with no `~/.config` files. Overrides for the file *locations*
(`SUPABASE_MGMT_TOKEN_FILE`, `MASI_E2E_PASSWORD_FILE`) still work and still lose to a set env var.

## Web port (in progress — v2 plan)

Porting to Flutter **web/PWA**, mobile-first (phone browsers + installed PWA are the primary target;
desktop is secondary/post-release). Plan: Obsidian `Masi Project/Flutter Web Port Implementation Plan (v2)`;
file/line brief: `WEB_PORT_BRIEF.md`.

- **Build:** `tool/build_web.sh` (wasm default) · `tool/build_web.sh --js` (legacy) · `--gate` (grep gate only).
- **wasm decision (Phase 0):** **wasm is the intended default build.** All plugins are on wasm-ready
  releases (`package:web`, no `dart:html` legacy): supabase_flutter 2.16, flutter_map 8.3, image_picker(_for_web)
  1.2/3.1, connectivity_plus 7.2, geolocator 14, url_launcher 6.3, flutter_svg 2.3, drift 2.34, image 4.9.
  The definitive `flutter build web --wasm` audit runs at the first fully-compilable point (end of Phase 2);
  JS fallback is a one-flag flip (`--js`) and the code stays wasm-clean regardless. COOP/COEP headers are a
  hard hosting requirement (wasm + drift OPFS worker).
- **First build-failure inventory:** top blocker is `dart:ffi` (sqlite3 FFI via `drift/native.dart` in
  `database_provider.dart`) → fixed by the Phase 1 connection split; then `dart:io` in 11 files → Phases 1–2.
- **Convention — conditional imports, never `kIsWeb`, for anything touching `dart:io`:**
  ```dart
  import 'x_stub.dart' if (dart.library.io) 'x_native.dart' if (dart.library.js_interop) 'x_web.dart';
  ```
  `_native.dart` files hold existing code verbatim (iOS/Android stays bit-identical). `kIsWeb` is reserved
  for behavioral gates on web-capable plugins. **Grep gate (CI + build_web.sh) — DIRECTIVES ONLY:**
  ```bash
  grep -rlE "^[[:space:]]*(import|export)[[:space:]]+['\"]dart:io['\"]" lib --include="*.dart" | grep -v '_native.dart'
  ```
  must be empty. Do **not** use a raw substring `grep -r "dart:io" lib` — it returns ~43 hits on clean code,
  because the seam files' doc comments legitimately name `dart:io` while explaining the conditional-import
  split. That false-positive form is what used to keep this gate red on code that was already correct. Keep
  the regex byte-identical across `tool/build_web.sh:40` and `.github/workflows/ci.yml`.
- **CI floor:** `.github/workflows/ci.yml` — analyze, test, **and the `dart:io` gate** are required jobs; only
  `web-build` is still `continue-on-error`. Repo is local-first; the workflow is the spec, `tool/build_web.sh`
  is the local gate.
- **`dart:io` on web COMPILES (it's stubbed), it does not fail the build.** `flutter build web` and
  `flutter build web --wasm` both succeed even with `import 'dart:io'` present — Dart 3.12 stubs the library
  and throws at *runtime*. So the grep gate is a **runtime-correctness guardrail, not a compile gate**: a
  screen importing dart:io builds and boots on web fine, but `File(...)` calls throw when actually reached
  (e.g. rendering a photo). Corollary: non-photo flows already run on web; photo rendering needs the display
  sites conditional-split (Phase 2C) before it works at runtime.

### Web verification loop (agent-autonomous — PROVEN)
Real app in **headless Chrome** via chromedriver + `integration_test`, screenshots read as images. This is
the web analogue of the iOS-sim loop and needs no human.
```bash
export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && \
  tool/drive_web.sh integration_test/web_smoke_test.dart   # boots app in headless Chrome, dumps PNGs
ls build/screenshots/ && # then Read each PNG to inspect
```
- Requires `chromedriver` on PATH matching Chrome major version (installed: ChromeDriver 150, Chrome for
  Testing). `flutter drive -d web-server --browser-name=chrome` is headless by default.
- `integration_test/web_harness_check_test.dart` = trivial-widget pipeline check; `web_smoke_test.dart` =
  real app boot → Area→Sector→Wall against drift-on-WASM/IndexedDB — **both green**. Note what that
  proves: the app boots and the flow does not throw. It contains **zero `expect()` calls**, so it does
  NOT prove persistence. `integration_test/e2e_signed_in_test.dart` (see the signed-in E2E section below)
  is the assertion-bearing replacement; a write→**full page reload**→assert was verified BY HAND on
  2026-08-05 (created an Area, reloaded the browser, it was still there) but is **not yet automated** —
  one `integration_test` page can't easily re-boot the browser.
- Same native-picker gap as iOS: photo pick/camera is a native chooser `integration_test` can't drive →
  override the picker provider / seed state to reach photo flows (seam pending, post-2C).

## Signed-in E2E in Chrome — DO THIS AFTER ANY BIG CHANGE

**Standing instruction: after any non-trivial change to app behavior, UI, routing, or the data layer,
exercise the app signed-in in a real browser before calling the work done.** Analyze + unit tests do not
catch layout breakage, dead buttons, broken navigation, or a screen that renders empty because a provider
threw. Looking at the running app does.

> **Use the `e2e-verify` skill.** It is the third gate — after `flutter analyze` and `flutter test`,
> before declaring done and before any deploy — and it carries the whole runbook: live-data safety,
> the seeded fixture, the scripted and interactive loops, the traps, what the harness structurally
> cannot prove, and the current known-red baseline. The rest of this section is background on *why*
> the harness is shaped the way it is; the skill is the procedure.

### Why a seam is needed at all
Web sign-in is a hard wall (`webAuthGateEnabledProvider` defaults to `kIsWeb` → `_webAuthGateRedirect`
bounces every route to `/account`), and **the three sign-in routes the app OFFERS** — magic link, emailed
OTP, Google OAuth — all need a mailbox or a consent screen no agent can drive. So the signed-in surface
is unreachable to automation without a seam.

The seam is `bootApp(overrides:)` in `lib/main.dart` (it exists for exactly this). `lib/main_e2e.dart`
uses it to boot the **real** app — real router, real widgets, real drift-on-OPFS, real photo pipeline —
turning off only the auth wall. It has **two identity modes**, and the difference decides what a run may
claim:

- **Real session (the default, and what `tool/drive_e2e.sh` uses).** Three dedicated accounts under
  `.test` sign in through the ordinary **password grant** against the anon key — the same credential the
  app itself carries. `auth.uid()` is real, so RLS, the review RPCs, trust and live push/pull are all
  genuinely exercised. Provisioned by `tool/e2e_accounts.sh ensure`.
- **Fake session (`--fake`).** A stub `AuthRepository` with uid `00000000-0000-4000-8000-000000000e2e`.
  No JWT, so `auth.uid()` is null and **every server-gated call is rejected** — repeated `401`s are
  expected, and are also what makes this mode unable to touch the backend. The fixed uid is an ownership
  key (`effectiveUidProvider` feeds every owner-scoped query and `PhotoFiles`' path prefix), so it must
  stay fixed or each run orphans the last one's library. **Never report RLS, sync, or moderation as
  verified from a `--fake` run.**

Procedure for both — setup, seeding, the scripted and interactive loops, teardown, and the traps — lives
in the **`e2e-verify` skill**. Don't duplicate it here.

### Traps that WILL cost you an hour (all hit for real on 2026-08-05)
- **A stale service worker serves the PREVIOUS build and you will debug a ghost.** The SW from an earlier
  build stays registered on the origin and answers from its precache, so a freshly-built bundle never
  loads — the app looks unchanged and you conclude your code did nothing. Symptom: the console still
  prints the OLD `masi/sw: warmed … (version <hash>)` and `caches.keys()` shows `masi-shell-<old hash>`.
  **Before trusting any fresh build, run this in the page and reload:**
  ```js
  (async () => { for (const r of await navigator.serviceWorker.getRegistrations()) await r.unregister();
                 for (const k of await caches.keys()) await caches.delete(k); })()
  ```
  Then confirm you are on the new bundle:
  `await (await fetch('/main.dart.js', {cache:'reload'})).text().then(t => t.includes('e2e@masi.test'))`.
- **`dart.bat` is a wrapper — killing its PID does NOT free the port.** It spawns a `dartvm` child that
  keeps the listen socket, so the next server dies with `SocketException … errno = 10048` and the OLD
  server keeps answering on the same port. A 200 from the port is therefore NOT proof your new server is
  the one serving. Kill by port owner, not by the PID you started:
  ```powershell
  Get-Process -Id (Get-NetTCPConnection -LocalPort 8099 -State Listen).OwningProcess | Stop-Process -Force
  ```
  Then confirm the new server actually bound — it prints `serving <dir> on http://localhost:<port>`; an
  empty stdout means it died.
- **`New topo` opens the native photo picker, which no agent can drive** (same gap as iOS). Reach the
  library via the **folder icon → Areas → Sectors → Walls** path instead, which needs no photo.
- **Repeated `401`s in the console are EXPECTED here** and are not a bug: the fake session carries no real
  JWT, so Supabase rejects every sync call. That is also what makes this harness safe — it cannot write to
  the live dev backend.

### The one hard rule
`lib/main_e2e.dart` **bypasses authentication and must never be deployed.** It is reachable only via an
explicit `-t`, and `tool/build_web.sh` greps the emitted bundle for `e2e@masi.test` and fails the build if
it appears. Build it to `-o build/web_e2e`, never over `build/web` (what the deploy skill ships). If you
ever touch that gate, keep it.

## Rock scans — 3D capture (added 2026-09-04)

A climber records a slow pass across a face; a worker reconstructs a point cloud; the app draws it.
`lib/features/scan/` (Dart) + `tool/rock_scan_worker/` (Python, ffmpeg + COLMAP). Live table
`public.rock_scans` and Storage bucket `rock-scans` are applied and verified.

**Nothing here is load-bearing for the topo.** A wall with no scan, a scan still processing and a
scan that failed are all ordinary states; `Walls.baselineJson` and the face layout are computed with
no reference to this table. Deleting every row changes nothing a climber can read. Keep it that way —
the point of the separation is that the topo works when reconstruction does not.

**One row, TWO writers — the thing to get right.** The app owns `wallId`, `uploadState`,
`videoObjectPath`, `durationMs`, `sizeBytes`; the worker (service_role, so RLS does not apply to it)
owns `status`, `progressPct`, `cloudObjectPath`, `manifestJson`, `failureReason`. The push is a
full-state re-push under LWW with local winning ties, so a phone that has not pulled since a job
finished would otherwise send its stale `status: 'pending'` over the worker's `'ready'` — and with no
outbox (D-4), lose it permanently. The push therefore STRIPS the worker's columns, centrally, inside
`SyncService.pushOwn`'s `guard()` closure, driven by `serverOwnedSyncColumns` in `sync_remote.dart`.

- **Adding a worker-written column means adding it to `serverOwnedSyncColumns` too.** Nothing fails
  loudly if you forget: the client just clobbers the value on its next push. A Python test parses
  that map out of `sync_remote.dart` and fails if the two sides diverge; keep it working.
- Omitting a column is safe both ways — INSERT takes the Postgres default, `ON CONFLICT DO UPDATE`
  leaves the stored value untouched. That is the same property `localOnlySyncColumns` relies on.

**The queue needs no trigger and no server state machine.** A scan is claimable exactly when
`uploadState = 'uploaded' AND status = 'pending'` — derived from the column the CLIENT owns, so a
half-uploaded video can never be picked up. Claiming is a conditional UPDATE; zero rows affected
means another worker won.

**Never invent a number.** No upload percentage (the Supabase Dart client exposes no progress
callback), no reconstruction ETA (nothing on the device knows the worker's queue), and **no
measurement at all unless `manifest.metresPerUnit` is non-null** — structure-from-motion recovers
geometry only up to a similarity transform, so an arbitrary-scale cloud genuinely does not know how
big the rock is. `test/features/scan/domain/colmap_contract_test.dart` pins this against real worker
output.

**The worker runs on the user's Windows box** (`C:\Projects\masi`, NVIDIA GPU), started by hand.
It POLLS — no inbound port, no public IP, no firewall change — so a home machine behind NAT is a
perfectly good host. `tool/rock_scan_worker/README.md` is the setup. Reconstruction sits behind one
replaceable interface so the SIFT front-end can later be swapped for learned features (hloc/glomap)
without touching the queue, storage, schema or CLI.

**Verified in this container:** COLMAP 3.9.1 + ffmpeg reconstruct a synthetic scene end to end, and
the Dart parser reads that real PLY and agrees with the worker's own Python-computed bounds.
**Not verified anywhere:** the CUDA path, dense MVS, and the Dockerfile.

**The cross-machine run (2026-09-04) — what it proved, and the two bugs it found.**
`tool/rock_scan_e2e.sh` drives one job across both machines against live data: render a
reconstructable capture, upload it and insert the row **as the E2E owner's own JWT** (never
`service_role` — a superuser insert would bypass the very RLS under test), then follow the row.
`integration_test/e2e_scan_test.dart` is the app half, run on its own **after** a job is ready and
**without re-seeding**, since `e2e_seed.sh` resets first and would delete the row under test.

Proven live: the owner-prefix Storage policy and `rock_scans_owner_all` both admit the app's exact
calls; the worker claims an uploaded job within seconds; and — the load-bearing one — **a stripped
client upsert carrying a much newer `updatedAt` leaves all five worker-owned columns byte-identical**.
That last was measured, not assumed: `ON CONFLICT DO UPDATE` really does leave an omitted column
alone, which is the single premise the whole two-writer split rests on.

- **The worker retried one job forever.** A non-zero exit from the reconstruction engine is classed
  `TransientError` (fair — the same frames may work on a healthy box), which RELEASED the row; the
  loop then re-claimed it within milliseconds and failed identically, about every 13 seconds,
  indefinitely. Nothing was written to `failureReason`, so the phone said "Building the 3D model"
  forever and the database showed a job that looked merely un-started. Fixed with
  `Config.max_release_attempts` (default 3, counted per worker PROCESS so a restart is a fresh
  decision and no column is needed) plus a poll-interval wait before re-claiming. `release()` still
  deliberately writes NO `failureReason` — that column is a sentence rendered next to a scan on a
  phone (`reasons.py`), not a place for engine wording — so a repeatedly-failing job is diagnosable
  only from the worker's console until the bound converts it into a real failure.
- **Teardown could not delete a reconstruction.** A source video is flat (`<uid>/<scanId>.mp4`) but a
  cloud is nested (`<uid>/<scanId>/cloud.ply`), and Supabase lists a nested path as a pseudo-folder
  whose `id` is null. The sweep kept those entries and asked to delete `<uid>/<scanId>`, which is not
  an object — so the delete silently did nothing and every PLY would have stayed in the bucket
  forever. Invisible, because the survivor check counts DATABASE rows and those were genuinely gone.
  `e2e_reset.sh` now descends one level, which is the whole of the layout the worker writes.

**Known gap:** capture needs a connection. The video is not persisted locally, so recording at a crag
with no signal leaves the scan on the device with nothing to retry from. Offline capture needs a
video store with a web/native seam and an eviction policy — deliberately deferred, not overlooked.

## Web offline stack

The web build has a full offline story now, not just a wasm-compilable one — this is easy to miss because
none of it shows up in a `grep -i dart:io`. Read this before touching sync, the map, or photo storage on web.

- **`reachabilityProvider`** (`lib/features/backup/application/reachability_providers.dart`) — three states
  (`unknown`/`online`/`offline`), **probe-on-demand**, not `ConnectivityService.statusChanges()`. Two reasons:
  `navigator.onLine`/interface state reports "connected" behind a captive portal, and a transition-only stream
  never gives a first answer to a page that loaded already-offline. Callers `ref.read(...notifier).refresh()`
  at the moment the answer is about to render (screen mount, an empty-looking read, pull-to-refresh) — nothing
  here polls in the background. Read `isKnownOffline`/`isKnownOnline`, never `!= online` (that silently treats
  `unknown` as offline for one frame on every cold start).
- **`SyncBanner` / `SyncBannerKind`** (`lib/shared/presentation/sync_banner.dart`) — public (Community Feed is
  a separate library from Library and can't reach a library-private widget), and rendered **unconditionally
  above the list** on both the Library and Community Feed screens — not gated on the list being empty. That
  used to be the bug: the user WITH topos, offline at a crag, saw a list quietly fail to refresh with zero
  signal and no way to tell "stale cache" from "your work is gone."
- **The basemap is VECTOR** (`flutter_map_vector_tiles`, CARTO Positron), and there is **no `TileLayer`
  anywhere in `lib`** — a raster one reappearing is the regression `basemap_test.dart` and
  `community_screen_test.dart` both watch for. One widget, `BasemapLayer` (`lib/core/map/basemap_layer.dart`),
  is what both map surfaces drop into `FlutterMap.children`; `basemapStyleProvider`
  (`lib/core/map/basemap_style.dart`) loads the style once per app run (NOT autoDispose — disposing a `Style`
  disposes the tile providers a live layer is using).
  - **Its placeholder is `SizedBox.expand()`, and that is load-bearing.** `FlutterMap` sizes itself from its
    children under loose constraints, which is what both call sites give it, so a `shrink()` placeholder
    collapses the whole map to 0x0 while the style is in flight — permanently, offline with nothing cached.
    `test/core/map/basemap_layer_test.dart` pins it.
  - **Web cache** (`lib/core/map/vector_tile_cache.dart`) — the package has no persistent tile cache on web,
    so `CachingVectorTileProvider` (the `.mvt` tiles) and `CachingStyleClient` (style, TileJSON, sprites,
    glyphs — no glyphs means no labels) both write through one `TileCacheStore`. Budget
    `kVectorTileCacheMaxBytes` = **4 MB, down from the raster cache's 40**: a vector source tops out at z14 and
    overzooms, so one ~8 KB tile serves every zoom a climber uses, where raster needed ~341 PNGs (~2.7 MB) for
    the same ground. Stale bytes are **served, not evicted**, when the network fails — flutter_map's own
    contract threw them away and drew blank. A quota-shaped write failure clears the store once and disables
    caching for the session (tiles are redownloadable; they hand space back to photos).
  - **The old raster bytes need no migration**: the vector cache reuses the same IndexedDB store, so the
    leftover PNGs are its LRU tail and the first vector write under the smaller budget evicts them.
  - Still a **separate IndexedDB database** from photos — `masi-map-tiles` (`tile_cache_store.dart`) vs
    `climbtopo-photos` (`photo_byte_store.dart`) — so tiles can never starve photo bytes.
  - **Widget tests**: there is no `tileProvider` constructor seam any more. A test that mounts a map screen
    spreads `fakeBasemapOverrides()` (`test/support/fake_basemap.dart`) into its `ProviderScope`/
    `ProviderContainer` overrides — one override instead of a parameter threaded through four widgets.
- **`PublicPhotoPruner`** (`lib/features/topo/data/public_photo_pruner.dart`) — pure, import-free eviction
  *policy* for cached PUBLIC photo bytes. Keep-by-default: an unknown owner, an unknown signed-in identity
  (`ownUid == null`), or any ambiguous input all resolve to "keep." Evicts **only** rows it can positively
  prove foreign.
- **`PublicPhotoPruneService`** (`lib/features/topo/data/public_photo_prune_service.dart`) — the I/O half.
  Triggers only strictly above a 0.75 origin-quota watermark, sweeps down to 0.60 (hysteresis, so a device
  parked at the line doesn't churn one delete per pull), batches of 10, capped at 50 deletions per pass, and
  always protects the 20 newest foreign photos (`kPruneKeepNewestForeign`) so the feed the user is actively
  browsing doesn't go blank underneath them. Never throws — a housekeeping sweep must never be able to fail a
  sync pull. **Known terminal case:** immediately after one pull from cold, the evictable set is provably
  empty, because `kSharedPhotoByteBudgetPerPull == kPruneKeepNewestForeign` (`sync_service.dart:35`) — the pull
  only ever fetches as many foreign photos as the floor already protects. The pruner correctly reports
  `PublicPhotoPruneReason.nothingPrunable` in that state; that is a correct "nothing to do," not a bug.
- **Geocoding degrades gracefully offline**: `lib/core/location/geocoding_service.dart:73-118` — 8s timeout, a
  blanket `catch`, returns `const []`. A dead Nominatim lookup shows an empty result list, never an error.

**Standing decisions (load-bearing, don't re-litigate):**
- **Own photos are NEVER evicted.** They stay at **full resolution** and a quota failure **fails loudly**
  (`PhotoWriteException`/`PhotoWriteFailure.quotaExceeded`, `photo_write_exception.dart`) rather than silently
  downscaling the user's photo — decision D-5. This does not extend to *cached copies of other people's*
  photos, which the pruner above is free to evict; only the user's own data gets the full-resolution/never-lose
  guarantee.
- **Conflict policy on push is client-side last-writer-wins, local winning ties** (`shouldPushLww`,
  the top-level `shouldPushLww` in `sync_remote.dart` — named, not line-numbered, because the line
  moved the first time anyone edited that file): a local row is skipped only when a remote row
  exists AND is *strictly* newer.
  Local wins on a tie because local is the side being pushed.
- **No outbox** (decision D-4, already stated at the top of this file) is why the sections above can all be
  "best-effort, never throws, heals on the next pull" — the engine re-reading and re-sending its own rows on
  every pull is what makes a lossy prune/quota/offline event self-correcting instead of something that needs
  its own retry queue.

## Fast checks — ONE command, both machines

```bash
dart run tool/gate.dart
```

That is gates 1 and 2 plus the guardrails, in dependency-free Dart — no bash, no `grep`, no PATH
ritual, identical on macOS, Windows and CI. It runs, cheapest-first so a broken tree reports in
seconds instead of after the test run:

| check | what it proves |
|---|---|
| `dart-io` | no `dart:io` import/export outside `*_native.dart` (see the web-port section) |
| `web-assets` | `web/sqlite3.wasm` + `drift_worker.js` present and matching `pubspec.lock`'s drift |
| `secrets` | no credential in any tracked file — see below |
| `analyze` | `flutter analyze` at 0 issues |
| `test` | `flutter test --exclude-tags golden` green |

```bash
dart run tool/gate.dart --skip-tests    # the fast guards only, ~15s
dart run tool/gate.dart --json          # machine-readable verdict
```

It deliberately does **not** run the signed-in E2E suite: that is gate 3, it mutates the live dev
database, and it needs a decision first — see the `e2e-verify` skill. The runner prints a reminder
rather than doing it for you.

The individual commands still work (`flutter analyze`, `flutter test --exclude-tags golden`) — the
runner is a convenience over them, not a replacement.

**Never drive a real image-codec decode in widget tests** — it hangs under fake-async. Use the injected
`imageSize` / `TopoCanvasBody` harness (see existing tests).

### The secret gate — install the hook once per clone

```bash
git config core.hooksPath tool/githooks
```

`git push` is the default here (see Version control below) and **pushing publishes**: a credential
that reaches a commit is on GitHub the moment the branch goes up, and rewriting history does not
un-publish it — it has to be rotated. `tool/scan_secrets.dart` closes that window with three layers:
known credential SHAPES (`sbp_…`, `sb_secret_…`, service-role JWTs, PEM blocks, `ghp_…`, AWS, an
inline Cloudflare token), the VERBATIM contents of the five real credential files under `~/.config`
(which no regex could recognise — the E2E password is just a random string), and forbidden
FILENAMES. It never prints what it caught: excerpts are redacted to the first four characters.

`sb_publishable_…` (the anon key in `supabase_config.dart`) and the VAPID **public** key are
committed on purpose and are pinned as non-findings in `test/tool/scan_secrets_test.dart`.

The hook blocks a commit on a finding, and warns-but-allows when there is no Dart SDK on PATH — the
required CI job is the backstop for that case. If something is a false positive, narrow the rule;
do not `--no-verify`.

## Running the app on a real screen so I can SEE and VERIFY it

This is how I verify my own work autonomously — spin up the iOS Simulator, drive the UI with a scripted
`integration_test`, capture screenshots to disk, then **read the PNGs as images**. Proven working.

### One-time-per-session: boot the iOS Simulator
```bash
export PATH="/opt/homebrew/bin:$PATH"
# Find the iPhone 17 (iOS 26.5) UDID:
xcrun simctl list devices available | grep "iPhone 17"
# Boot it (known UDID on this machine — re-check if it changed):
xcrun simctl boot C8D8B6F4-1D77-46EF-80BA-2CBD746AC69C
open -a Simulator
xcrun simctl list devices | grep Booted    # confirm
```

### The verification loop (write flow → run → read screenshots)
Screenshots are persisted by `test_driver/integration_test.dart` (an `integrationDriver` with an
`onScreenshot` callback) into **`build/screenshots/<name>.png>`**. Flows live in `integration_test/`.

1. Write/extend a flow in `integration_test/<name>_test.dart`. It launches the real app
   (`import 'package:masi/main.dart' as app; ... app.main();`), drives taps via
   `find.byKey(...)`, and calls `await binding.takeScreenshot('NN-label')` at each state worth seeing.
   Target widgets by **Key** (e.g. `area-add-fab`, `area-item-<id>`) — never pixel coordinates.
   (On iOS no `convertFlutterSurfaceToImage()` is needed; on Android it is, before each screenshot.)
2. Run it (first build ~3–10 min, incremental ~20s):
   ```bash
   export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && \
   flutter drive --driver=test_driver/integration_test.dart \
     --target=integration_test/<name>_test.dart -d C8D8B6F4-1D77-46EF-80BA-2CBD746AC69C
   ```
3. `ls build/screenshots/` then **Read each PNG** to visually inspect the result.

Quick one-off shot of whatever is on the booted sim (no scripted flow):
`export PATH="/opt/homebrew/bin:$PATH" && xcrun simctl io booted screenshot /tmp/shot.png` → Read it.

`integration_test/smoke_test.dart` is the reference flow (boots → Areas empty state → taps add-FAB → dialog).

### Reaching the topo canvas in tests (the native-picker gap)
The photo picker (`image_picker`) is a **native OS dialog outside Flutter** — `integration_test` CANNOT
tap it. Pure-Flutter flows (Area→Sector→Wall CRUD, dialogs, lists, navigation) drive fine as-is. To reach
the **topo canvas / draw / slice / AR-overlay** screens without the picker, seed the state instead:
override the picker provider or seed the Drift DB (Area→Sector→Wall→Photo pointing at a bundled test
asset) before `app.main()`. Wire this seam when we start testing canvas fixes — it's not built yet.

### Hard limits
- **AR / camera / ARKit cannot run in any simulator** — no camera, no VIO tracking. AR is verified ONLY
  on the physical iPhone (`PetiTeló ☄️`, `flutter build ios --release` then `flutter install --release -d <id>`),
  human-in-the-loop. Everything else is simulator-verifiable.
- **CoreSimulator flakiness**: if `flutter drive` hangs on install with `IXErrorDomain code=2 / "Failed to
  create promise"`, kill the process, quit Simulator.app, `killall -9 com.apple.CoreSimulator.CoreSimulatorService`,
  reboot the sim, `xcrun simctl uninstall booted com.xlypton.masi`, and retry.

### On-device debugging (physical iPhone, iOS 27) — hard-won facts
The AR/camera path can ONLY be verified on the physical device, and the usual `flutter run` loop is broken there. What actually works:

- **`flutter run --debug` does NOT attach on this device** (free profile, iOS 27). The Xcode build + install succeed, then the launched process gets `SIGKILL` and you get *"The Dart VM Service was not discovered after 60 seconds."* A manually-tapped debug build just shows a **white screen** (it can't run its Dart standalone). Don't fight it — use a **release** build instead.
- **ALWAYS UPDATE IN PLACE — never uninstall (the user is tired of logging in again).** `flutter install --release` prints *"Uninstalling old version…"* first, which **wipes the app container → destroys the Supabase login session** and forces a fresh login. To update the app while PRESERVING app data + the login session, build then install with `devicectl` (which updates over the existing install, no uninstall) — do NOT use `flutter install`, and NEVER `xcrun simctl/devicectl ... uninstall` this app on the phone:
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && \
  flutter build ios --release -t lib/main.dart && \
  xcrun devicectl device install app --device <deviceid> build/ios/iphoneos/Runner.app
  ```
  In-place update preserves the login session **within the 7-day provisioning window**; only a profile expiry/re-sign (free-team limitation) forces a wipe — paid team ($99/yr) removes even that. If `devicectl install` ever fails on a signing mismatch, rebuild first; do not fall back to `flutter install` (it uninstalls).
- **`flutter logs -d <id>` is dead on iOS 27** — it prints the "Showing … logs:" header and then nothing (the old syslog relay is gone).
- **Capture device console via `devicectl`** (launches the app fresh AND streams its console; run in background, then grep):
  ```bash
  xcrun devicectl device process launch --console --terminate-existing \
    --device <deviceid> com.xlypton.masi > /tmp/console.log 2>&1
  ```
  `--terminate-existing` relaunches without reinstalling, so app data (your seeded topo) survives.
- **CRITICAL — what devicectl `--console` captures:** native **`NSLog` (os_log) YES, Dart `print`/`debugPrint` NO** (in a release build). So for on-device diagnosis, put diagnostic logging in **native Swift `NSLog`** (with a greppable prefix, e.g. `AR_DBG`). Dart-side logs will NOT surface in release + devicectl. (Debug/attach would show Dart logs, but attach is broken here — see above.)
- **Flutter PlatformView channel gotcha (root-caused a black-AR bug):** the `masi/ar` `MethodChannel` handler is registered **lazily inside `ArPlatformView.init`, which runs only when the `UiKitView` MOUNTS**. Any channel call fired before mount (e.g. from `initState`/`_load`, right after `setState`) is sent before the native handler exists and is silently dropped (`MissingPluginException`). **Gate platform-view channel calls on `UiKitView.onPlatformViewCreated`, never on `initState`/data-load timing.**
- **Device facts:** `PetiTeló ☄️`, device id via `flutter devices` (was `00008140-0011585936EB001C`), bundle id `com.xlypton.masi`, dev team `8773L4RF2P` (free personal → 7-day profiles). **Uninstall — or a 7-day profile expiry — wipes app data + the login session; a plain in-place `devicectl device install app` does NOT (see the in-place-update rule above).**

### Fallbacks (not set up, document-only)
- `idb` (`brew install idb-companion && pip install fb-idb`) → `idb ui describe-all` (accessibility tree),
  `idb ui tap/swipe/text`, `idb screenshot` — for ad-hoc iOS poking incl. some native dialogs.
- Android emulator + `adb` runs the SAME integration_test flows unmodified (faster iteration if ever needed).

## Working discipline

- **Delegate.** Reading ≥2 files → Explore agent. Search → Explore agent. Test runs / known-path edits /
  mechanical multi-step → Sonnet subagent. Keep Opus for judgment only.
- **Orchestrate** (`orchestrate` skill) for feature work or bug fixes spanning ≥2 files / ≥3 steps:
  plan-with-assertions → implementer subagents → **independent clean-context verify gate**. The agent that
  wrote code never verifies it; verification re-runs assertions + the integration-test loop above.
- Keep whole-project `flutter analyze` at 0 and `flutter test` green on every change.
- **Three gates, not two.** `dart run tool/gate.dart` (gates 1+2, plus the dart:io / web-asset /
  secret guardrails) → the **`e2e-verify` skill**, signed in against a real session. The third is
  required before declaring done and before any deploy whenever the change touched app behaviour, UI,
  routing, the data layer, or anything server-gated; skip it only for pure refactors, docs, or
  tooling — and say which case you decided.
- **Deploy at the end of every feature, without being asked** (standing instruction, 2026-08-29).
  A finished feature is a DEPLOYED feature: run the `deploy-web` skill as the last step of any
  change that reaches the user, immediately after gate 3 passes, and report the live URL and the
  verified `SHELL_VERSION` alongside the work. Do not stop at "pushed" and ask whether to ship.
  The three gates above are the gate on that, not a reason to defer it — deploy is what happens
  when they pass, and a red gate is a reason to FIX, not to ship or to ask.
  Three things still stop a deploy, and each is reported rather than worked around: a failing
  gate, a change whose blast radius the user has not seen yet (a schema migration is already live
  the moment it is applied — say so), and an explicit "don't deploy". Docs-only, tooling-only and
  test-only changes are not features and need no deploy; say that is why you skipped it.
- **A skipped test is not a passed test.** `flutter test` reports skips as `~N`, and several exist by
  design (goldens off-macOS, the POSIX-only `drive_web.sh` cases off-Linux/macOS). When reporting a
  green run, say what was skipped and why — "tests green" means something weaker on Windows than on
  the machine that ships, and the difference has to be visible rather than inferred.

## Version control — branch, commit, and push automatically

Commit **without being asked**. The goal is a clean, granular history we can read and revert.

**More than one agent works this repo now (changed 2026-08-08), so `main` is a shared base, not a
scratchpad.** That reverses the two rules this section used to carry — it said commit straight to
`main` and never push. Both are now the opposite:

- **Work on a branch, never directly on `main`.** Cut it from an up-to-date `main`
  (`git checkout main && git pull && git checkout -b <type>/<subject>`). Name it for the work, not
  the agent: `fix/shared-ascent-visibility`, `feat/community-ranking`. Two agents on one branch is
  the thing the branching is there to avoid — if you do not know what the other agent is doing, that
  is a reason for a separate branch, not a shared one.
- **Push by default**, and set upstream on the first push (`git push -u origin <branch>`). Push after
  each verified unit of work rather than saving it up: an unpushed branch is invisible to the other
  agent, which is most of the point.
- **Opening a PR still needs an explicit ask.** Push is how work becomes visible; a PR is a request
  for a decision, and that stays the user's call. Same for merging into `main` and for `--force`
  anything.
- **Commit after every verified unit of work** — as soon as a subtask/fix clears its verify gate
  (analyze 0 + tests green + independent verify where the orchestrate flow applies), commit it. Don't
  let changes pile up uncommitted.
- **One logical change per commit.** Small and single-purpose beats large and mixed — that's what makes
  `git revert`/`git reset` a safe undo. Don't bundle unrelated work into one commit.
- **Conventional messages**: `type(scope): summary` (e.g. `fix(topo): center canvas image vertically`,
  `feat(community): add likes on published topos`). Body only when the *why* isn't obvious.
- End every commit message with the trailer:
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
- Never commit secrets (the `~/.config/climbtopo-mgmt-token`, any `sb_secret_…`/`sbp_…` key, the E2E
  password at `~/.config/masi-e2e-password`, the Cloudflare token at `~/.config/cf-pages-token`). The
  client uses only the anon/publishable key. **Pushing publishes** — this matters more now that push
  is the default, because a secret committed to a branch is on GitHub the moment that branch goes up,
  and rewriting history does not un-publish it.

**The live Supabase project is shared too, and it is NOT branched.** A migration applied from one
branch is live for every agent and for the user's real data immediately — there is no per-branch
database. So a schema change is effectively merged the moment it is applied, whatever branch its
`.sql` file sits on. Apply migrations that are additive and verified (the recipe below), and say in
the commit that they are already live.

## Supabase backend — auto-troubleshoot + schema edits (DEV env, standing approval)

The live Supabase project is a **dev environment**; the user has given standing approval (2026-07-23) to
**inspect and edit its schema directly** to troubleshoot sync/backend issues — no need to ask each time.
The REST/PostgREST API can't run DDL, so use the **Management API** `POST
https://api.supabase.com/v1/projects/{ref}/database/query` (the same endpoint the Dashboard SQL editor uses),
which executes arbitrary SQL and returns JSON (`[]` for DDL success, rows for SELECT).

- **Project ref:** `mnaipcqbkqzffgvxpato` (from `SUPABASE_URL` in `lib/core/config/supabase_config.dart`).
- **Admin token:** a `sbp_…` personal access token — **never print or commit it** (the app itself only
  ever uses the anon key; this token is admin-only, for this workflow). In a cloud session it is
  `$SUPABASE_MGMT_TOKEN`; on a local box it is `~/.config/climbtopo-mgmt-token`. **Prefer
  `tool/supabase_query.sh`** (`-q "SELECT …"` or a `.sql` file path) — it resolves either form for you.
  Raw: `TOKEN="${SUPABASE_MGMT_TOKEN:-$(tr -d '[:space:]' < ~/.config/climbtopo-mgmt-token)}"`.
- **Recipe:**
  ```bash
  REF=mnaipcqbkqzffgvxpato
  TOKEN="${SUPABASE_MGMT_TOKEN:-$(tr -d '[:space:]' < ~/.config/climbtopo-mgmt-token)}"
  API="https://api.supabase.com/v1/projects/$REF/database/query"
  # inspect (SELECT):
  curl -sS -X POST "$API" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    --data "$(jq -n --arg q 'SELECT ...;' '{query:$q}')" | jq .
  # apply a whole .sql file (DDL):
  curl -sS -X POST "$API" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    --data "$(jq -Rs '{query: .}' path/to/migration.sql)"
  ```
- **Schema-drift is the recurring bug class here** (#64/#65/#72): local Drift schema runs ahead of live.
  Delta migrations that must be hand-applied to live live in `supabase/migrations/*.sql` (+ the walls
  lat/long ALTER documented in `supabase/schema.sql`). Keep every migration **idempotent** (`ADD COLUMN IF
  NOT EXISTS`, `DROP POLICY IF EXISTS`+`CREATE`) and keep `schema.sql` in sync for fresh-run correctness.
- **Run it yourself — do NOT hand the user SQL to paste.** A settings allow rule is in place, so the
  token-reading curl above executes automatically (verified 2026-08-04: inspected the live schema and applied
  DDL with no prompt). The user has said explicitly he does not want to run these commands manually. So on
  any schema/backend question: query live, decide, apply, verify — then report what you did. Never end a turn
  with "here's a migration for you to run".
- **Inspect live BEFORE writing DDL — never infer the shape from Dart alone.** Column *names* are derivable
  from the client code; types, nullability and RLS style are not, and guessing them has produced wrong
  migrations. Cheap first queries:
  ```bash
  # what tables exist:
  ... --data "$(jq -n --arg q "SELECT table_name FROM information_schema.tables WHERE table_schema='public' ORDER BY 1;" '{query:$q}')"
  # a table's real shape:
  ... "SELECT column_name, data_type, is_nullable FROM information_schema.columns
       WHERE table_schema='public' AND table_name='X' ORDER BY ordinal_position;"
  # existing RLS conventions to copy:
  ... "SELECT tablename, policyname, cmd, qual, with_check FROM pg_policies WHERE schemaname='public';"
  ```
- **Live conventions (verified 2026-08-04 — match these in new DDL):** every table uses **quoted camelCase**
  identifiers and **`text`** ids — `areas.id text`, `areas."ownerId" text`, plus `createdAt`/`updatedAt`/
  `deletedAt` as `bigint` and `dirty boolean`. Every owner policy is
  `USING ("ownerId" = (auth.uid())::text)` with the same `WITH CHECK` — i.e. **`text` compared to a cast
  `auth.uid()`, never a bare `uuid`**. Live tables as of that date: `areas`, `ascents`, `comments`, `likes`,
  `photos`, `profiles`, `routes`, `sectors`, `walls`, `backups`. (`public.backups` is the one snake_case
  outlier, because `backup_remote.dart` sends `user_id`/`snapshot`/`schema_version`/`updated_at`; it was
  created 2026-08-04 and is currently unreachable from the app — nothing calls `pushBackup`/`pullBackup`.)
- **After applying, verify and reconcile.** Re-`SELECT` the columns, `pg_class.relrowsecurity`, and
  `pg_policies` to confirm what actually landed, then update `supabase/schema.sql` (and the
  `supabase/migrations/*.sql` delta) to the shape that is *really* live — and fix any comment in those files
  claiming an apply state that turns out to be false.

## MCP servers + agent skills (added 2026-08-06)

`.mcp.json` (project root, committed) registers **six remote MCP servers** — `supabase` (scoped to
project_ref `mnaipcqbkqzffgvxpato`) plus Cloudflare's `cloudflare` / `cloudflare-docs` /
`cloudflare-bindings` / `cloudflare-builds` / `cloudflare-observability`. Agent skills live in
`.agents/skills/` (gitignored) and are symlinked into `.claude/skills/`: 11 Cloudflare skills
(`cloudflare`, `wrangler`, `workers-best-practices`, `web-perf`, `durable-objects`, …) + 2 Supabase
(`supabase`, `supabase-postgres-best-practices`).

- **They require an app RESTART to load, then an interactive OAuth per server** (`/mcp` → select the
  server → Authenticate). `cloudflare-docs` is the only one that needs no auth. Until that is done the
  servers are configured but unusable — every endpoint answers `401`, which is "alive, awaiting auth",
  not a misconfiguration.
- **`claude mcp add` / `claude plugin install` do NOT work on this machine.** There is no standalone
  `claude` CLI here (desktop app, nothing on PATH), so both vendors' documented install commands fail.
  Writing `.mcp.json` by hand is the equivalent and is what was actually done.
- **`npx skills add --global` fails for every skill** (`PromptScript does not support global skill
  installation`), Cloudflare's docs notwithstanding. Install project-scoped, without `--global`.
- Deliberately NOT added to the global `~/.claude.json`: that file is ~37 KB and holds `oauthAccount`
  and app state, so round-tripping it through a JSON serializer to add five lines risks corrupting the
  Claude Code install. Project scope gets the same result with none of that risk.

### Supabase access — the Management API remains the working path
The `~/.config/climbtopo-mgmt-token` + `POST /v1/projects/{ref}/database/query` recipe documented above
is still the ONLY verified way to inspect/edit the live schema, and it needs no MCP, no OAuth and no
restart. **Re-verified 2026-08-06:** returned all 10 live tables (`areas`, `ascents`, `backups`,
`comments`, `likes`, `photos`, `profiles`, `routes`, `sectors`, `walls`) with `relrowsecurity` true on
all 10. Prefer it over the MCP server for schema work — it is proven, scriptable, and already covered
by a settings allow rule.

### Cloudflare access — token, and the account-ID trap
- **Node is a portable install at `C:\tools\nodejs`** and is NOT on PATH (`winget install` hangs forever
  on an invisible UAC elevation prompt; the official zip works). Prefix commands with
  `export PATH="/c/tools/nodejs:$PATH"`, or call `C:\tools\nodejs\npx.cmd` directly.
- **The Pages-scoped API token** is `$CLOUDFLARE_API_TOKEN` directly in a cloud session, or
  `~/.config/cf-pages-token` locally (read it into `CLOUDFLARE_API_TOKEN`) — never print it. `wrangler`
  reads `CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ACCOUNT_ID` from the env natively, so no wrapper script is
  needed either way. This replaces `wrangler login`, whose OAuth flow times out in well under the time
  it takes to reach a remote-controlled desktop (it failed twice that way).
- **A `Pages:Edit`-only token cannot resolve its own account.** `wrangler whoami` fails with "Failed to
  automatically retrieve account IDs", and `/accounts`, `/memberships`, `/user` all come back empty or
  unauthorized — the token is valid, it just cannot enumerate. So **`CLOUDFLARE_ACCOUNT_ID` must be set
  explicitly** for any `wrangler pages deploy`. Either store the account ID alongside the token or add
  `account:read` to the token. This is the single thing that blocks an otherwise-headless deploy.
