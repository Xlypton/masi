---
name: e2e-verify
description: Use after ANY non-trivial change to Masi's app behaviour, UI, routing, data layer, sync, or moderation — before calling that work done, and always before a deploy. Runs the signed-in end-to-end suite against a REAL Supabase session in headless Chrome, seeded from and torn down against the live DEV project. Also use when asked to "verify signed-in", "run the E2E", "check it actually works", "prove the feature works end to end", when an E2E run fails and needs diagnosing, or when the live E2E fixture needs seeding or cleaning up (tool/e2e_seed.sh / tool/e2e_reset.sh).
---

# Verifying Masi end-to-end, signed in, against the real backend

`flutter analyze` and `flutter test` do not catch a dead button, a screen that renders empty
because a provider threw, a route that no longer resolves, or an RLS policy that rejects the very
call the feature depends on. **Looking at the running app, signed in, is the only thing that
does.** This skill is that check.

It is the **third gate**, not a replacement for the first two:

| gate | proves | cost |
|---|---|---|
| `flutter analyze` | it compiles and is idiom-clean | seconds |
| `flutter test` | units and widgets behave | ~2 min |
| **this skill** | the real app, real router, real drift, real JWT, real RLS | ~5–15 min |

## When it is required

**Required** before declaring done, and before any deploy, when the change touched:

- anything server-gated — sync push/pull, moderation, reports, suggestions, trust, RLS, an RPC
- routing or navigation
- the data layer (drift schema, providers, import/export)
- a screen's structure, or a widget key the suite targets

**Not required** for a pure refactor with no behavioural surface, a comment/doc change, or a
tooling-only edit. Say which case you decided and why — do not silently skip it.

## The one hard rule

`lib/main_e2e.dart` **bypasses authentication and must never be deployed.** It is reachable only
through an explicit `-t`, and `tool/build_web.sh` greps the emitted bundle for `e2e@masi.test` and
fails the build if it appears. Build it to `-o build/web_e2e`, **never** over `build/web` (what the
deploy skill ships). If you ever touch that gate, keep it.

---

## 0. What this does to the live database — read before the first run

There is one Supabase project and it holds **the user's real topos**. The harness does not use a
second project on purpose: the org is on the free plan, so a second project would auto-pause after
7 days of inactivity — exactly when the harness reaches for it — and schema drift between two
projects is this repo's worst recurring bug class (#64/#65/#72).

**Isolation is by ownership, not by database.** Every row the tooling creates is owned by one of
three dedicated E2E uids and carries an `e2e-` id prefix; every delete is filtered on both. The
filter is written once, in `e2e_owner_filter` (`tool/e2e_common.sh`) — read that function before
editing anything destructive. `resolve_e2e_uids` makes a missing uid **fatal** rather than an empty
string, because an empty uid in a `WHERE` clause is how you delete somebody else's rows.

`tool/e2e_reset.sh` prints real (non-E2E) row counts **before and after**, so "the database was
returned to its original state" is a measurement and not a claim. **Quote those counts in the
report.**

Two things that are NOT ours and must never be swept:

- the `shared/` Storage prefix holds every published topo's photo including the user's — only the
  two known fixture object names are removed from it, never a prefix sweep;
- the admin review queue contains the user's own real pending topos — the scripted admin test taps
  `admin-queue-approve-<E2E_WALL_PENDING>` by id and **never "the first row"**. Approving a real
  row would be a destructive edit to the user's data.

---

## 1. One-time setup (idempotent — safe to re-run)

```bash
tool/e2e_accounts.sh ensure
```

Creates or converges three confirmed accounts under `.test` (RFC 2606 — can never be a real
mailbox, and `email_confirm: true` means no mail is ever sent):

| role | email | what it is for |
|---|---|---|
| owner | `e2e-owner@masi.test` | owns the fixture; publishes, receives suggestions |
| reader | `e2e-reader@masi.test` | reports, suggests edits — the "other user" |
| admin | `e2e-admin@masi.test` | seeded into `public.admins`; drives the review queue |

The shared password is generated once into `~/.config/masi-e2e-password` (0600) and **never
printed** by `ensure`/`show`. Re-running does not rotate it — a `--dart-define`d value in a running
build would stop working mid-session.

`tool/e2e_accounts.sh show` prints the uids (uids are not secrets).

**Never print or commit:** the password file, the `sbp_…` management token
(`~/.config/climbtopo-mgmt-token`), or the `service_role` key. The service key is fetched fresh at
runtime and is **shell-side only** — it must never reach a Flutter build or the repo.

---

## 2. The scripted run (the one to reach for)

Needs `chromedriver` already listening on 4444, matching the installed Chrome major version:

```bash
chromedriver --port=4444 &
```

Then:

```bash
tool/drive_e2e.sh
```

| invocation | effect |
|---|---|
| `tool/drive_e2e.sh` | **both suites, real session, seeded first** |
| `tool/drive_e2e.sh signed-in` | `integration_test/e2e_signed_in_test.dart` |
| `tool/drive_e2e.sh community` | `integration_test/e2e_community_test.dart` |
| `tool/drive_e2e.sh --fake signed-in` | fake identity, no JWT — see §5 for what that cannot prove |

It seeds the fixture (`tool/e2e_seed.sh`, which resets first) and **leaves it in place afterwards**
so a failure can be inspected. Clean up with `tool/e2e_reset.sh` when done.

The fixture is area → sector → **two** walls, each with a photo (real bytes in Storage) and routes:

- `e2e-wall-published-0001` — submitted **and approved through the real `review_topo` RPC with the
  admin account's JWT**, not a superuser `UPDATE`. The moderation state and the `moderation_log`
  entry are therefore genuine.
- `e2e-wall-pending-0001` — left pending, so the admin run has something of its own to approve.

**These suites assert.** Unlike `web_smoke_test.dart` — which has zero `expect()` calls and proves
only "boots without throwing" — these fail when a step is unreachable instead of
`if (tester.any(...))`-skipping past it. That is deliberate: a run that reported green by skipping
would be reporting a lie.

Screenshots land in `build/screenshots/`. **Read the PNGs**, don't just note the exit code.

---

## 3. The interactive loop (for diagnosing a failure)

`flutter drive -d web-server` **swallows the app's own console**, so a Dart-side error is invisible
to the scripted run. When a scripted assertion fails and the reason is not obvious, drive it by
hand — this is the loop that actually finds the cause:

```bash
flutter build web --wasm --no-web-resources-cdn --pwa-strategy=none \
  -t lib/main_e2e.dart -o build/web_e2e \
  $(tool/e2e_accounts.sh env owner)
dart run tool/serve_web.dart build/web_e2e 8099
```

Then drive `http://localhost:8099` with the browser tools: `navigate` → `computer{action:"screenshot"}`
→ click by coordinate/ref → screenshot again. **Also read `read_console_messages`** — a Flutter
widget error shows there while the canvas still looks entirely plausible.

`tool/e2e_accounts.sh env owner` emits the two `--dart-define` flags. Only the *password* is a
define; the three emails are ordinary constants in `lib/main_e2e.dart`, which is what lets **one
build** switch role at runtime via `e2eSignInAs`. Never redirect that command's output into a file
inside the repo.

**The server must send COOP/COEP** (`same-origin` / `require-corp`) or drift silently falls off
OPFS onto the IndexedDB VFS, whose `xSync` is a no-op — you would be testing a weaker storage
backend than production and would not be told. Confirm before trusting anything:

```js
self.crossOriginIsolated === true
```
and a `masi/storage: backend=opfsLocks` console line. `python tool/serve_web_isolated.py` does the
same job where Python is installed.

---

## 4. Traps that WILL cost you an hour

All of these have actually happened here.

- **A stale service worker serves the PREVIOUS build and you will debug a ghost.** The worker from
  an earlier build stays registered on the origin and answers from its precache, so a freshly-built
  bundle never loads — the app looks unchanged and you conclude your code did nothing. Symptom: the
  console still prints the OLD `masi/sw: warmed … (version <hash>)`. Before trusting any fresh
  build, run this in the page and reload:
  ```js
  (async () => { for (const r of await navigator.serviceWorker.getRegistrations()) await r.unregister();
                 for (const k of await caches.keys()) await caches.delete(k); })()
  ```
  Then confirm you are actually on the new bundle. Don't grep `main.dart.js` for a source string —
  under `--wasm` that file is only the unused JS fallback, so a hit there proves nothing about the
  code running. Use the console instead: the app prints
  `masi/e2e: REAL session as e2e-owner@masi.test (uid=…) — RLS applies, sync push/pull is live`
  on boot in real mode, and `masi/sw: warmed … (version <hash>)` must show the **new** hash.

- **`dart.bat` is a wrapper — killing its PID does NOT free the port.** It spawns a `dartvm` child
  that keeps the listen socket, so the next server dies with `SocketException … errno = 10048` and
  the OLD server keeps answering. A 200 from the port is therefore **not** proof your new server is
  the one serving. Kill by port owner:
  ```powershell
  Get-Process -Id (Get-NetTCPConnection -LocalPort 8099 -State Listen).OwningProcess | Stop-Process -Force
  ```
  Then confirm the new server bound — it prints `serving <dir> on http://localhost:<port>`; empty
  stdout means it died.

- **The Bash tool caps `timeout` at 600000 ms (10 min).** A larger value is silently clamped and
  kills the run mid-flight. A full two-suite run can exceed that — use `run_in_background: true`.

- **`New topo` opens the native photo picker, which no agent can drive.** Reach the library via the
  **folder icon → Areas → Sectors → Walls** path instead, which needs no photo. This is why the
  fixture seeds photo bytes directly into Storage.

- **Headless Chrome will not composite CanvasKit on the Windows machine** — screenshots come back a
  flat theme background (~4 KB, identical every time) regardless of `--disable-gpu` or SwiftShader.
  If every PNG is the same tiny size, you have no pixel evidence; fall back to
  `read_console_messages` and `javascript_tool`, which do work.

---

## 5. What this harness CANNOT prove — state it every time

- **The `--fake` mode proves nothing server-side.** The fake identity carries no JWT, so
  `auth.uid()` is null and every RLS-gated call is rejected. Repeated `401`s in that mode are
  **expected and are not a bug** — it is also what makes `--fake` safe, since it cannot write to
  the backend. Never report RLS, push/pull, or moderation as verified from a `--fake` run.
- **Headless Chrome says nothing about iOS Safari**, which is where this PWA is actually used, and
  where tab reclaim and WebKit quirks bite.
- **No automation on this machine can drive an iOS home-screen (standalone) PWA.** That is a
  permanent limit to disclose, not a gap to work around: standalone mode silently refuses
  `window.open(url, '_self', 'noopener,noreferrer')` and can hand out-of-scope navigations to
  Safari, whose storage does not hold the PKCE verifier the PWA just wrote. Both failures are
  invisible to every browser here, and both were once measured working in headless Chrome while
  broken on the phone. When a change touches auth, storage, navigation, or the service worker, the
  report must name which claims need a manual check **in the installed home-screen app** — a Safari
  tab can pass while the installed app fails.
- **AR / camera cannot run anywhere but the physical iPhone.**

---

## 6. Known-red as of 2026-08-07 — do not report these as regressions

Two assertions in `e2e_community_test.dart` fail: the seeded fixture never reaches the community
feed on the client. **The harness itself works** — accounts converge, the seed goes through the
real RPC, sign-in is proven (the Account test passes and the app logs
`REAL session as e2e-owner@masi.test … RLS applies, sync push/pull is live`), and teardown is exact.

Already ruled out, so do not re-test:

- timing (identical failure at 150 s as at 40 s);
- server-side visibility (`is_wall_public` returns true for the fixture);
- RLS (the owner's real JWT returns both fixture walls via `curl`);
- missing ancestors (area/sector share the owner uid — this matters because the feed INNER-JOINs
  sectors and areas);
- sync error state (the feed test asserts `community-sync-error-empty` is absent).

The break is between "the pull ran" and "the row is in the local `walls` table". Next step is §3,
the interactive loop, because the driver hides the app console.

**If a run comes back with exactly these two failures, that is the known baseline — say so
explicitly rather than reporting green.** Any *other* failure is a real regression.

---

## 7. Teardown, always

```bash
tool/e2e_reset.sh
```

It deletes every E2E-owned row and Storage object, then **proves** it: a non-zero survivor count
exits 1. `--accounts` also removes the three auth users (rarely wanted — `ensure` is idempotent, so
keeping them saves a setup round-trip).

Teardown goes through the Management API on purpose, and this is not a workaround: phase 5's
withdrawal cooldown means a **published** topo cannot be un-published from the client for ten days
(`protect_published_wall` reverts both the visibility flip and the soft-delete). That is correct
product behaviour, so a client-driven teardown is impossible by construction.

---

## 8. Report honestly

Separate the claims, because they need separate evidence:

1. **which suites ran**, and against a real session or `--fake`;
2. **what passed, what failed**, and whether a failure is the §6 known baseline or new;
3. **what the harness structurally cannot cover** (§5) — every time, not only when asked;
4. **the before/after real row counts** from `e2e_reset.sh`, quoted, as the proof the user's data
   is untouched.

Never let "the suite is green" stand in for "the feature works" when the green came from a mode
that skips the thing being claimed.
