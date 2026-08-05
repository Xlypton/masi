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

## 3. Open work

Green at handoff: `flutter analyze` **0 issues**, `flutter test` **2330 passing**.
Live at <https://climb-masi.pages.dev>.

### Blocked on a physical device (cannot be closed from a desktop)
- **iOS PWA viewport / hit-test family** — root-caused and fixed in `2350756`, live in
  production, **awaiting the device check**. Read that commit message before touching
  `web/index.html`; three separate point-fixes were shipped and reverted here first.

  The cause: `full_page_embedding_strategy.dart` **removes every
  `<meta name="viewport">` on the page — unconditionally, in release too — and appends
  its own** without `viewport-fit=cover`, *after* the browser has laid the page out with
  ours. Since ours carried `cover`, the swap flipped viewport-fit a beat after boot. On
  iOS the engine's only geometry input is `documentElement.clientWidth/clientHeight`
  (the **layout** viewport, `full_page_dimensions_provider.dart:71-84`) while the only
  resize it subscribes to is the **visual** viewport (`:29-36`) — so it cannot observe a
  layout-viewport-only change and has no path to invalidate one. Fix: ship the engine's
  viewport string byte-for-byte, so the swap is a no-op. Pinned by
  `test/web_geometry_source_test.dart`, which compares our meta against the installed
  SDK's string and so also fails on an SDK upgrade.

  **Device check:** cold-launch from the home screen; it must look identical at 0.3s and
  2s, and **rotating must now be a no-op**. Rotation being a *fix* was the symptom — it
  is the only thing that forces WebKit to re-resolve the viewport. If rotation still
  changes anything, WebKit is reacting to the element removal itself rather than the
  argument change, and the next lever is `apple-mobile-web-app-status-bar-style`
  (`black-translucent` → `default`), which costs an opaque non-theme-aware status strip
  and #74's seam as a hard edge — decide it on measurements, not another guess.

  Facts worth not re-deriving: **`MediaQuery.viewPadding`/`padding` are a const zero on
  Flutter web** (`window.dart:97`), so every `SafeArea(top:)` in this app contributes
  nothing and the notch clearance comes from the engine's own viewport. The bottom nav
  clears the home indicator via an explicit 32px floor in `nav_shell.dart:79-84` — an
  unaudited magic number, calibrated under a status-bar style we no longer use, and
  applied to Android PWAs too where nothing needs it. **Custom-element (`hostElement`)
  embedding is evaluated and rejected**: it would avoid the meta rewrite entirely, but
  its `computeKeyboardInsets` returns hardcoded zero
  (`custom_element_dimensions_provider.dart:93-96`), killing `viewInsets.bottom` and
  breaking keyboard avoidance in every bottom sheet.
- **Post-commit flush on real iOS Safari** — the fix is pinned by
  `test/core/db/post_commit_flush_test.dart`; the device leg is unverified.
- **The canvas bottom cluster sits inside the home-indicator band** on a standalone PWA:
  `topo_canvas_screen.dart:1483-1497` has `SafeArea(top: false)` + 12px and no standalone
  floor, and that screen is a root route with no `bottomNavigationBar`, so
  `padding.bottom` is 0 there. Pre-existing, found while tracing the above, not fixed.

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
- The two device-blocked items above, plus the canvas bottom-cluster inset.
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
