# Device test checklist

Written 2026-08-06, covering production deployment `05ad30fb` (shell `72af9a370b94e68f`,
commit `92d3bad`) at <https://climb-masi.pages.dev>.

**Why this file exists.** Everything in it is something no automation on the dev machine
can prove. Headless Chrome and headless WebKit have both passed while the installed iPhone
PWA was broken — twice. Sections A–C are the ones that matter; the rest is sweep.

Each item says what to do, what **PASS** looks like, and what a failure would *mean* — the
last part matters, because several of these failures look identical to each other from the
outside.

---

## A. Pre-flight — do this first or every result below is invalid

**A1. Get the new build.** A stale service worker is the single biggest source of false
results: the app will happily run last week's shell and you will "reproduce" bugs that are
already fixed.

1. Open <https://climb-masi.pages.dev> in **Safari** (a normal tab, not the home-screen app).
2. Hard-reload twice, with a few seconds between. The first load installs the new worker;
   the second is served by it.
3. Then open the **installed** home-screen app and let it sit for ~10 seconds before
   testing. It updates independently of the Safari tab.

**A2. Confirm you're on the right build.** Account → the new **Storage** section →
**Copy diagnostics**, and paste it somewhere. If that section does not exist, you are on an
old shell — repeat A1.

> If anything below fails, paste that diagnostics line into the report. It contains the
> storage backend, missing browser features, the last storage error, and the persistence
> outcome — the four things needed to tell four completely different bugs apart.

---

## B. P0 — the two bugs just fixed. These are the ones to verify.

### B1. Text renders (the blank-labels bug)

**Do:** cold-launch the installed app. Look at the Library list, the search field, the badge
pills on each topo, and the bottom nav.

**PASS:** every label has visible text — topo names, badge text, button labels, placeholders.

**FAIL means:** the bundled Roboto did not reach the device. Previously the engine fetched
Roboto from `fonts.gstatic.com` on the awaited pre-first-frame path; blocked by a content
blocker, iCloud Private Relay or carrier DNS, that left the app with no font and every label
blank while photos and icons rendered fine. If it recurs, the font either isn't in the bundle
or isn't being picked up — get the diagnostics line and say whether you have Private Relay or
a content blocker on.

**Also worth your eye (not a pass/fail):** headings, labels and button text now use a real
Roboto Bold where the app previously faux-bolded a Regular. `FontWeight.w600` is the most-used
weight in the app and classic Roboto has no SemiBold, so it resolves to 700. **If headings read
too heavy, say so** — it's a one-line change to map 600 to Medium instead.

### B2. Offline cold start (the splash-hang bug)

**Do:**
1. Online, launch the installed app and let it fully load. Force-quit it.
2. Turn on **airplane mode**.
3. Cold-launch from the home screen.

**PASS:** the app paints. You reach the Library and see your saved topos. The offline banner
appears.

**FAIL means:** the renderer still isn't cached. iPhone Safari never loads our wasm build —
the loader's `wasmAllowList` is blink-only, so WebKit takes the dart2js/canvaskit path and
needs `main.dart.js` plus the full canvaskit, none of which used to be precached. The page now
reports what it actually fetched, before first paint, so the worker can cache it. If it hangs
on the logo again, note **whether step 1 was done after A1** — the worker needs one good online
load to fill the cache.

**B3. Offline, second launch.** Repeat B2 without going back online. **PASS:** still paints.
(Catches a cache that fills once and then gets pruned.)

**B4. Offline write.** Still in airplane mode: create an Area → Sector → Wall → attach a photo
→ draw a route. **PASS:** every step works and persists across a force-quit + relaunch, still
offline. **This is the one that matters most** — it's the governing requirement.

**B5. Come back online.** Turn airplane mode off, open the app, wait. **PASS:** the offline
banner goes away and the work from B4 syncs (Account → sync line shows a recent time, not
"Not synced yet"). **FAIL means** the scheduler didn't pick up the reconnect — tell me what
the Account sync line says verbatim.

---

## C. P1 — open items only your device can close

### C1. #53 — Android installed PWA, "storage unavailable"

Previously: the installed Android PWA showed a storage-unavailable screen after ~30s. Android
Chrome was hit by the same missing-renderer gap, and boot now attributes failures per
subsystem instead of blaming storage generically.

**Do:** on the Android phone, repeat A1, then cold-launch the installed PWA.

Three outcomes, all useful:
- **Boots fine** → fixed. Say so and I'll close it.
- **Still fails, but the message now names something other than storage** (e.g. mentions the
  network or a timeout) → the message was lying before; paste the exact wording.
- **Still says storage** → paste the diagnostics line from A2 plus the exact message. Then try
  the airplane-mode variant below.

**The single most informative test:** turn on airplane mode and cold-launch. Offline, the shell
serves from cache and the Supabase init fails fast instead of hanging. **If it boots fine
offline but not online, storage was never broken** — a stalled network call was wearing
storage's error message.

Also try: force-quit and relaunch; and a normal Chrome tab rather than the installed app. A
difference between tab and installed app is itself a strong signal.

### C2. #36 — post-commit flush on real iOS Safari

The fix is pinned by `test/core/db/post_commit_flush_test.dart`; the device leg has never run.

**Do:** in the installed iPhone app — create a topo with a photo and a couple of routes, then
**immediately force-quit** (swipe up, don't wait, don't background it gently). Relaunch.

**PASS:** everything you just made is still there, photo included.

**FAIL means** a committed transaction wasn't flushed before the process died — the exact
measured data-loss bug this guards. Note how fast you quit; "immediately" is the test.

Repeat 3 times, varying the delay before force-quitting (0s, 1s, 3s).

---

## D. P2 — shipped today

**D1. Offline banner closes.** In airplane mode, on the Library: the "You're offline" banner has
an **×**. Tap it. **PASS:** the banner disappears completely and the list moves up to fill the
space (no leftover gap). **PASS:** it's also gone on the Community Feed. **PASS:** go online,
then offline again → **it comes back**. That last one is deliberate: a permanent dismissal
would recreate the original bug where an offline user watched a list silently fail to refresh
with no signal at all.

**D2. Sync-failure banner is NOT closable.** If you ever see "Couldn't sync — …", it should have
a **Retry** and **no ×**. That's intentional — dismissing "your work didn't reach the cloud" is
how data loss becomes invisible.

**D3. Storage diagnostics row.** Account → Storage. **PASS:** shows a backend (`opfsLocks` or
similar — not blank), eviction protection, and space used. **Copy diagnostics** should put one
line on the clipboard and confirm it did. If space used is unknown it must say **"not
reported"**, never `0 B` or `0%`.

**D4. Sync no longer drops rows.** Previously a foreign-key failure aborted three whole tables,
costing ascents/comments/likes — including ones on your *own* topos. **Do:** confirm your
logbook entries, comments and likes are all present, and that no "Couldn't sync" banner
mentions a constraint failure. Cloud data was never damaged, so anything missing before should
have come back on a pull.

**D5. Storage retry → reload.** Hard to trigger deliberately; if you ever land on the
storage-unavailable screen, tap **Try again**, and when it fails a **Reload the app** button
should appear alongside it. Only reachable after a retry has actually failed.

---

## E. P3 — regression sweep (fast, catch collateral damage)

- **E1.** Layout is stable at launch: nothing shifts down a second after the logo, and taps land
  on what you're touching. (This was fixed and confirmed earlier; rotating the phone should now
  change nothing.)
- **E2.** Canvas: open a topo. Image is fitted and centred, not zoomed into a corner. Taps on
  route lines register where you touch.
- **E3.** Map tab renders tiles, including offline (tiles you've viewed before).
- **E4.** Community Feed loads, and photos on other people's topos appear.
- **E5.** Google sign-in works from the installed home-screen app (this has broken twice in
  standalone mode specifically — a Safari tab passing tells you nothing).
- **E6.** Photo picker + camera on a real device.
- **E7.** Nothing overlaps the home-indicator band at the bottom of any screen.

---

## F. Known limits — not bugs, don't chase them

- **No automation can drive an installed iOS PWA.** Everything in sections B–E was verified in
  headless Chrome at best. Standalone mode genuinely differs: it silently refuses
  `window.open(_self, noopener)`, and it can hand out-of-scope navigations to Safari, whose
  storage lacks the PKCE verifier the PWA just wrote. Both were measured *working* in headless
  Chrome and real headless WebKit while broken on the phone.
- **These paths shipped with source-level guards only** (tracked as #60): the query timeout
  actually engaging on web, `watch()` routing through the intercepted executor in a real
  `WasmDatabase`, the `appinstalled` persistence bridge, and `location.reload()`. They are
  pinned at the call site, not the runtime branch.
- **The query bound does not cure a hang.** If the OPFS worker dies, `Atomics.wait(..., -1)` has
  no timeout and drift's lock is never released. The app now names the failure and offers a
  reload; it cannot un-wedge the worker.
- **Persistence is advisory.** A grant is not a guarantee, and eviction is all-or-nothing per
  origin — database, photo bytes and shell cache go together.
- **The top hairline at the notch** on some screens is a WebKit compositor seam, accepted as
  wontfix after being proven not to be a widget bug.

---

## G. Reporting a failure so it's actionable

For anything that fails, the four things that turn a guess into a diagnosis:

1. **The diagnostics line** (Account → Storage → Copy diagnostics).
2. **Installed app or Safari tab?** They fail differently and it's the fastest discriminator.
3. **Online, offline, or flaky?** And if offline — airplane mode, or just no signal?
4. **A screenshot**, for anything positional. Text descriptions misdiagnosed the notch-seam bug
   twice before a screenshot settled it in one look.
