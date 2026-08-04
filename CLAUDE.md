# Masi — Project Instructions

Flutter climbing-route documentation app (visual-first topo editor). Full spec: **`MASI.md`**.
iOS-primary. Local-first (Drift/SQLite). Riverpod **v3** (use `Notifier`, never `StateProvider`).
v1 (M0–M6) + v2 AR are code-complete on `main`. Supabase sync is implemented and live —
a debounced, dirty-scoped **full-state re-push** + pull, with tombstoned soft-delete, in
`lib/features/backup/` (`sync_service.dart`, `sync_orchestrator.dart`, `backup_repository.dart`),
verified end-to-end. **There is no outbox** — `grep -rin outbox lib` returns zero hits, and building
one is explicitly out of scope (decision D-4): the engine re-reads and re-sends own rows, which is
what makes it idempotent and loss-proof.

## Toolchain quirks (read first)

- **Homebrew Flutter.** PATH does NOT persist between shell calls. Prefix EVERY flutter/dart/pod/xcrun
  command with: `export PATH="/opt/homebrew/bin:$PATH" && `
- Flutter 3.44.2 · Dart 3.12.2 · Xcode 26.6.
- **iOS uses Swift Package Manager, not CocoaPods** — there is intentionally no `ios/Podfile`.
  Don't try to `pod install`; it will fail with "No Podfile found" and that is expected.
- Package name is `masi`; app entrypoint is `main()` in `lib/main.dart`. It builds a
  `ProviderContainer`, awaits `container.read(photoFilesProvider).warmDocsPath()` to pre-warm the
  photo-path cache before the first frame, then calls
  `runApp(UncontrolledProviderScope(container: container, child: const MasiApp()))` —
  not the plain `ProviderScope(child: ...)` pattern.

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
  for behavioral gates on web-capable plugins. **Grep gate (CI + build_web.sh):**
  `grep -r "dart:io" lib --include="*.dart" | grep -v _native.dart` must be empty (goes green at M2).
- **CI floor:** `.github/workflows/ci.yml` (analyze+test required; web build + grep gate `continue-on-error`
  until M2). Repo is local-first / not pushed; the workflow is the spec, `tool/build_web.sh` is the local gate.
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
  NOT prove persistence — a write→reload→assert test is still owed.
- Same native-picker gap as iOS: photo pick/camera is a native chooser `integration_test` can't drive →
  override the picker provider / seed state to reach photo flows (seam pending, post-2C).

## Fast checks (unit + widget)

```bash
export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter analyze   # must be 0 issues
export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test        # 1930+ tests, must be green
```
**Never drive a real image-codec decode in widget tests** — it hangs under fake-async. Use the injected
`imageSize` / `TopoCanvasBody` harness (see existing tests).

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

## Version control — commit automatically

Commit **without being asked**. The goal is a clean, granular history we can read and revert.

- **Commit after every verified unit of work** — as soon as a subtask/fix clears its verify gate
  (analyze 0 + tests green + independent verify where the orchestrate flow applies), commit it. Don't
  let changes pile up uncommitted.
- **One logical change per commit.** Small and single-purpose beats large and mixed — that's what makes
  `git revert`/`git reset` a safe undo. Don't bundle unrelated work into one commit.
- **Conventional messages**: `type(scope): summary` (e.g. `fix(topo): center canvas image vertically`,
  `feat(community): add likes on published topos`). Body only when the *why* isn't obvious.
- **Commit straight to `main`** (solo, local-first repo). **Never push to a remote** or open a PR without
  the user explicitly asking — automatic means *commit*, not publish.
- End every commit message with the trailer:
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
- Never commit secrets (the `~/.config/climbtopo-mgmt-token`, any `sb_secret_…`/`sbp_…` key). The client
  uses only the anon/publishable key.

## Supabase backend — auto-troubleshoot + schema edits (DEV env, standing approval)

The live Supabase project is a **dev environment**; the user has given standing approval (2026-07-23) to
**inspect and edit its schema directly** to troubleshoot sync/backend issues — no need to ask each time.
The REST/PostgREST API can't run DDL, so use the **Management API** `POST
https://api.supabase.com/v1/projects/{ref}/database/query` (the same endpoint the Dashboard SQL editor uses),
which executes arbitrary SQL and returns JSON (`[]` for DDL success, rows for SELECT).

- **Project ref:** `mnaipcqbkqzffgvxpato` (from `SUPABASE_URL` in `lib/core/config/supabase_config.dart`).
- **Admin token:** a `sbp_…` personal access token in `~/.config/climbtopo-mgmt-token` — read it into a var,
  **never print or commit it** (the app itself only ever uses the anon key; this token is admin-only, for
  this workflow). `TOKEN="$(tr -d '[:space:]' < ~/.config/climbtopo-mgmt-token)"`.
- **Recipe:**
  ```bash
  REF=mnaipcqbkqzffgvxpato
  TOKEN="$(tr -d '[:space:]' < ~/.config/climbtopo-mgmt-token)"
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
