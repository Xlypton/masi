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
- **PWA hit-test offset** — *fixed and deployed*, awaiting confirmation only. Two
  hacks added for the cosmetic #74 hairline were displacing every touch target in
  the installed home-screen PWA: a `defineProperty` override of
  `document.documentElement.clientWidth/clientHeight`, and `flutter-view { top: -2px }`
  under `display-mode: standalone`. On iOS the engine reads `clientHeight`
  *deliberately* (a WebKit rotation workaround) and hit-tests pointer events against
  that same `<flutter-view>` box, so overriding it offset touch from paint. Removed in
  `6be3959`; confirmed absent from production. **To close: open the home-screen PWA
  and tap directly on "Continue with Google".** If it is still dead, the new watchdog
  in `oauth_redirect_web.dart` now reports a real error naming the step and host.
- **Post-commit flush on real iOS Safari** — the fix is pinned by
  `test/core/db/post_commit_flush_test.dart`; the device leg is unverified.

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

### Genuinely remaining
- **Stage 3 offline reads.** The acceptance criteria live in
  `docs/superpowers/specs/2026-07-30-web-offline-reliability-design.md` (§"Stage 3 —
  Offline reads": four deliverables, three assertions). The map-tile half shipped
  (`lib/core/map/masi_tile_caching_provider.dart`). **The T1–T14 task breakdown was
  never written to disk and is gone** — re-measure against the design doc, not
  against any T-numbers you find referenced elsewhere.
- **Proactive storage-nearly-full warning** with an explicitly consented "clear
  cached community photos" action — the only path permitted to touch the protected
  floor of newest foreign photos.

### Standing decisions that constrain all of the above
Offline scope is all four (create end-to-end, read own topos, read previously-seen
public topos, offline map). Durability net is "make sync bulletproof" — no export
escape hatch. Conflict policy: local wins for the user's own data. **Keep the
full-state re-push and fix the scheduler — do not build an outbox** (D-4; the engine
re-reading and re-sending its own rows is what makes it idempotent). Own photos are
never evicted; own photos stay full resolution and fail loudly on quota rather than
downscaling.
