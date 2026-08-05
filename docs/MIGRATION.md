# Machine migration handoff

Written 2026-08-05, when the work moved to a new computer. Two jobs: list what a
fresh clone does **not** give you, and record the open work — the in-session task
list does not survive a machine change, so this file is its durable replacement.

## 1. Nothing is stranded on the old machine

Verified at handoff time:

- Working tree clean; `main` fully pushed.
- **All 14 local branches exist on `origin`** — including `park/anon-shareable-landing`
  (the built-then-parked #15 anon landing), `m1`–`m6`, `v2-ar-viewer`,
  `feature/pwa-otp-login`, `stage1-integration`, `phase2-ar-placement-engines`.
  Checked with `git rev-list --count <branch> --not --remotes` = 0 for every one.
- The in-tree iOS AR work is preserved on **`wip/ar-placement-device`** (`7eca5e7`).
  It was uncommitted and is **not** a duplicate of `phase2-ar-placement-engines`
  (`ArPlatformView.swift` differs by 428 lines, `RockRegistrationEngine.swift` by 259,
  `VisionRegistrationEngine.swift` by 169). It is an **unverified snapshot** — the iOS
  build was never run against it, which is exactly why it is not on `main`.
- Two extra worktrees existed and were both clean, fully pushed, and safe to abandon:
  `../masi-phase2` (branch `phase2-ar-placement-engines`) and `.claude/worktrees/*`.
  A worktree lives outside the repo directory, so it will not come with a clone —
  recreate with `git worktree add` if wanted; no content is lost either way.

## 2. What a fresh clone does not give you

### Builds out of the box
`lib/core/config/supabase_config.dart` carries committed `defaultValue`s for both
`SUPABASE_URL` (`mnaipcqbkqzffgvxpato`) and `SUPABASE_ANON_KEY` (a
`sb_publishable_…` key — RLS-protected, safe to embed). **No dart-defines and no
`.env` are needed** to build or to reach the live backend.

### Machine-local, must be recreated
| Thing | Where it was | How to restore |
|---|---|---|
| Supabase admin token | `~/.config/climbtopo-mgmt-token` | New personal access token from the Supabase dashboard. A `sbp_…` value — **never commit or print it**. Only used for the Management API schema workflow in `CLAUDE.md`; the app itself never touches it. |
| Cloudflare Wrangler auth | `~/Library/Preferences/.wrangler` | `npx wrangler login`. Pages project is **`climb-masi`**. |
| Claude settings / allow rules | `~/.claude/settings.json`, `.claude/settings.local.json` (both untracked) | Re-add the Bash allow rule for the Supabase Management API curl, or the token-reading command will prompt on every call. |
| Obsidian vault | `~/Documents/ObsidianVault/Work` | Synced separately from this repo. `Masi Project/Bugs and User Stories.md` holds the hard-won platform traps; `Daily/Journal.md` is the rolling log. |
| iOS signing | Free personal team `8773L4RF2P` | Re-sign on the new machine. Free team = 7-day profiles. **A profile expiry or any uninstall wipes the app container and the Supabase login session on the device** — see the in-place `devicectl` update rule in `CLAUDE.md`. |

Skills are versioned in-repo (`.claude/skills/deploy-web/SKILL.md`); the rest of
`.claude/` is gitignored deliberately.

### Toolchain at handoff
Flutter 3.44.2 stable (engine `04efd7c093`) · Dart 3.12.2 · Xcode 26.6 ·
Node v23.11.0 · wrangler 4.119.0 · ChromeDriver 150.0.7871.124 (must match the
installed Chrome for Testing major version, or `tool/drive_web.sh` fails).

Homebrew Flutter: **PATH does not persist between shell calls** — prefix every
command with `export PATH="/opt/homebrew/bin:$PATH" && `. iOS uses Swift Package
Manager; there is intentionally no `ios/Podfile`.

### Two more things that will not come with a clone
- **The #54 bounded-queries design plan** lives at
  `~/.claude/plans/masi-54-bounded-queries.md` — outside the repo, machine-local, gone
  on a fresh clone. This repo already lost one task breakdown that was never written to
  disk (the T1–T14 list mentioned under "Closed since this file was written" below);
  that loss is *why* the #54 plan was written to a file instead of staying in-session.
  If you pick #54 up on a new machine, that plan will not be there — re-derive it from
  the commits (`08dca8c`, `2a7f128`, `1027f61`, `86ad565`, `92d3bad`) or write a new one.
- **The per-project memory directory** `~/.claude/projects/-Users-kerip-Projects-masi/memory/`
  is the same story: machine-local, not part of the repo, not part of a clone.

## 3. Open work

Verified on this machine (2026-08-06): `flutter analyze` → **No issues found!**.
`flutter test` → **2508 passing** (last independently verified count; the full suite
takes ~2.5 min and was not re-run here — see the note at the top of this section
before trusting a stale number). `tool/build_web.sh` is fully green, including the
bundled-Roboto font gate (see `b46d716`/`ff56692` below) and the `dart:io` import gate
(`grep -r "dart:io" lib --include="*.dart" | grep -v _native.dart`, **0 offenders**).
Production is live at <https://climb-masi.pages.dev> — deployment `05ad30fb`, shell
version `72af9a370b94e68f`, built from commit `92d3bad`.

See `docs/DEVICE_TEST_CHECKLIST.md` for the full list of things that need a physical
device and can't be proven from a desktop — the two device-blocked items below are a
subset of it, tracked here because they're the ones with unresolved history. New
machine, no Mac/iPhone handy? `docs/DEV_SETUP.md` is the Windows-agent setup guide;
every Windows-specific instruction in it is marked `[UNVERIFIED on Windows]`, and
`tool/drive_web.sh` is **known broken** on Windows (it shells out to `lsof` and
`ps -o comm=`, neither of which exists there) — don't spend time debugging that script
there, it needs a rewrite first.

### Blocked on a physical device (cannot be closed from a desktop)
- **Post-commit flush on real iOS Safari** (#36) — the fix is pinned by
  `test/core/db/post_commit_flush_test.dart`; the device leg is unverified.
- **#53 Android installed PWA storage message** — device only; likely affected by the
  renderer-precache fix below (`b46d716`/`c19dde5`/`53313b8`), worth re-testing before
  spending time debugging it fresh.

### Closed as a dead end — do not retry as specified
- **In-page Google sign-in (GIS + `signInWithIdToken`) for the standalone PWA.**
  No COOP value on WebKit both keeps `crossOriginIsolated` and lets the GIS popup
  complete (Safari has no FedCM → popup fallback → needs
  `same-origin-allow-popups`; the only value granting both, `restrict-properties`,
  is Chrome-only). Dropping isolation would push drift off OPFS onto the IndexedDB
  VFS, whose `xSync` is a documented no-op — measured as the backend that loses
  trailing transactions. Unevaluated alternative: a separate non-isolated
  `/auth.html` on the same origin, complicated by Cloudflare `_headers` append
  semantics.

### Closed since this file was written
- **iOS PWA viewport / hit-test family — DONE, device-confirmed.** Root-caused and
  fixed in `2350756`; the user confirmed the fix on the physical device ("Good the
  shift has been fixed now").

  The cause, worth keeping because it's load-bearing and not obvious from the diff:
  `full_page_embedding_strategy.dart` **removes every `<meta name="viewport">` on the
  page — unconditionally, in release too — and appends its own** without
  `viewport-fit=cover`, *after* the browser has laid the page out with ours. Since ours
  carried `cover`, the swap flipped viewport-fit a beat after boot. On iOS the engine's
  only geometry input is `documentElement.clientWidth/clientHeight` (the **layout**
  viewport, `full_page_dimensions_provider.dart:71-84`) while the only resize it
  subscribes to is the **visual** viewport (`:29-36`) — so it cannot observe a
  layout-viewport-only change and has no path to invalidate one. The fix ships the
  engine's viewport string byte-for-byte, so the swap is a no-op. Pinned by
  `test/web_geometry_source_test.dart`, which compares our meta against the installed
  SDK's string and so also fails on an SDK upgrade. **Do not re-add
  `viewport-fit=cover`** — that's exactly what caused the original flip, and three
  point-fixes were shipped and reverted here before the real cause was found.

  Facts worth not re-deriving: **`MediaQuery.viewPadding`/`padding` are a const zero on
  Flutter web** (`window.dart:97`), so every `SafeArea(top:)` in this app contributes
  nothing and the notch clearance comes from the engine's own viewport. The bottom nav
  clears the home indicator via an explicit 32px floor in `nav_shell.dart:79-84` — an
  unaudited magic number, calibrated under a status-bar style we no longer use, and
  applied to Android PWAs too where nothing needs it. **Custom-element (`hostElement`)
  embedding was evaluated and rejected**: it would avoid the meta rewrite entirely, but
  its `computeKeyboardInsets` returns hardcoded zero
  (`custom_element_dimensions_provider.dart:93-96`), killing `viewInsets.bottom` and
  breaking keyboard avoidance in every bottom sheet.
- **Sync own-rows FK abort — DONE (`7e7318c`).** The own batch legitimately contains
  your ascents/comments/likes on OTHER owners' topos, but structurally cannot contain
  those owners' parent rows. Per-table transactions meant one such row rolled back the
  *whole table*, so a foreign-key violation on an own row lost the user's own topos too,
  not just the offending row. Now FK-checked and deferred: those rows are re-imported
  after the shared batch lands the missing parents, and residual deferrals surface as a
  visible retry instead of a silent drop.
- **Storage/boot honesty batch — DONE.** `340ba7b` stops the stall verdict from
  clobbering the connection layer's own report; `d546993` bounds the web database open
  instead of waiting forever; `e9235f3` fixes per-subsystem boot attribution (a stall
  elsewhere was being blamed on storage); `2d86634` stops the retry button from wedging
  itself permanently; `8f04fe0` collapses two competing storage-unavailable notices into
  one.
- **The blank-text bug — DONE (`b46d716`).** The app bundled no text font at all, so the
  web engine fetched Roboto from `fonts.gstatic.com` on the *awaited, pre-first-frame*
  boot path — unbounded, cross-origin, and therefore uncacheable by our service worker.
  Anything that blocked it (a content blocker, iCloud Private Relay, carrier DNS)
  rendered every label blank. Fixed by bundling Roboto locally under the family name
  **exactly `Roboto`**, which is what both renderers' font-fetch-suppression logic keys
  on. Deliberately did *not* set `ThemeData.fontFamily` — the engine already requests
  Roboto by default, so web is unchanged and native keeps San Francisco.
- **The offline splash hang — DONE (`c19dde5`, `53313b8`).** iPhone Safari never loads
  our wasm build — the loader's `wasmAllowList` is blink-only, so WebKit takes the
  dart2js/canvaskit path and needs `main.dart.js` plus the full canvaskit, none of which
  was precached. The old runtime warm was posted from a `flutter-first-frame` listener,
  so on a load that failed to paint it could never run. The page now reports what the
  loader actually fetched via a `PerformanceObserver`, before first paint, posting to
  `registration.active` (**not** `controller`, which is null on a first visit).
- **`ff56692`: the font build gate couldn't pass.** It checked
  `build/web/assets/fonts/...`, but Flutter emits
  `build/web/assets/assets/fonts/...`; the gate's `exit 1` fired before the
  service-worker stamp, so a build that "failed" the gate could still ship with an empty
  precache. Also fixed both SDK-agreement guard tests, which were skipping green instead
  of failing when they couldn't run.
- **#54 bounded post-boot queries — DONE (`08dca8c`, `2a7f128`, `1027f61`, `86ad565`)**
  and **#57 persistence re-ask — DONE (`92d3bad`)**. Say plainly: #54 does **not** cure a
  hang. `Atomics.wait(int32View, _responseIndex, -1)` has no timeout, and a Dart-side
  timeout does not release drift's `_openingLock` — it bounds what the *app* reports,
  not what the browser is actually blocked on.
- **Dismissible offline banner — DONE (`a5226ba`).** Dismissal is per offline episode,
  not permanent.
- **Stage 3 offline reads — DONE.** Acceptance criteria are in
  `docs/superpowers/specs/2026-07-30-web-offline-reliability-design.md`. Most of it had
  already shipped; the three real gaps were closed in `bcac977` (docs), `e9c6eb6` (a
  real-browser tile-cache proof) and `ece5f05` (offline empty states). **The T1–T14 task
  breakdown was never written to disk and is gone** — if you see T-numbers referenced
  anywhere, re-measure against the design doc instead.
- **Proactive storage-nearly-full warning — DONE**, `89d4004` + `b235693`.
- **Canvas geometry — DONE.** `ac9c67d` reconciles the overlay/hit-test box against the
  real *decoded* photo size: the box used `PhotoRef`'s persisted dimensions while the
  photo itself was `BoxFit.contain`-ed and centred inside it, so an EXIF-orientation
  disagreement gave a permanent, per-photo, purely **vertical** touch offset (X is
  scale-invariant under the fill-width fit rule). `5666248` stops a pending auto-fit
  write being mistaken for a user pan, which could leave a fit stale indefinitely.
  Note the decoded-size probe must never become an error/latching state — a previous
  decode probe blanked the canvas permanently on any hiccup; see
  `topo_canvas_missing_bytes_test.dart`.

### Still open
- **#36 post-commit flush on real iOS Safari** (device only).
- **#53 Android installed PWA storage message** (device only; likely affected by the
  renderer-precache fix above, worth re-testing before debugging).
- **#58 prune pressure counts service-worker + map-tile bytes the pruner cannot free.**
  Structurally established, magnitude unmeasured — needs a real-device quota reading
  first, don't guess at a fix before that.
- **#59 `probeDatabaseUsable` still hard-zeroes `measuredBackend`** — same class of bug
  as `340ba7b`, now more visible because the new Account diagnostics row reads it.
- **#60 real-browser proof for the four web-gated paths that `flutter test` cannot
  execute** — `kIsWeb` is permanently `false` under `flutter test`, so those paths have
  no automated coverage at all; only a real-browser run proves them.
- **The pre-existing canvas bottom cluster sits inside the home-indicator band** on a
  standalone PWA: `topo_canvas_screen.dart:1483-1497` has `SafeArea(top: false)` + 12px
  and no standalone floor, and that screen is a root route with no
  `bottomNavigationBar`, so `padding.bottom` is 0 there. Found while tracing the
  viewport bug above, not fixed.
- **Beware tautological positional tests.** The canvas's original fit tests computed the
  tap point as `MatrixUtils.transformPoint(controller.value, …)` and then asserted
  `toScene(M · p) == p` — true for any `M`. They proved arithmetic, not geometry. New
  tests hand-compute expected values; keep it that way.

### Standing decisions that constrain all of the above
Offline scope is all four (create end-to-end, read own topos, read previously-seen
public topos, offline map). Durability net is "make sync bulletproof" — no export
escape hatch. Conflict policy: local wins for the user's own data. **Keep the
full-state re-push and fix the scheduler — do not build an outbox** (D-4; the engine
re-reading and re-sending its own rows is what makes it idempotent). Own photos are
never evicted; own photos stay full resolution and fail loudly on quota rather than
downscaling.
