---
name: deploy-web
description: Use when deploying the Masi web/PWA build to Cloudflare Pages — triggered by "deploy", "deploy the web app", "ship it to the web", "push the PWA live", "redeploy", or any request to get the current code onto https://climb-masi.pages.dev. Also use when a deploy needs verifying (did the live site actually get the new build?), when a deploy fails, or when only the pre-deploy gates need running. Covers the gate → build → deploy → verify sequence and the traps at each step.
---

# Deploying Masi to the web

Web/PWA is the primary target for this project (the native iOS app is deprioritized). The whole
deploy is four steps, and **the fourth is not optional** — Cloudflare's success message names a
per-deployment preview URL, not the production alias, so "Deployment complete!" is not evidence
that the site users visit changed.

**PATH does not persist between shell calls.** Prefix every `flutter`/`dart` command with
`export PATH="/opt/homebrew/bin:$PATH" && `.

Live URL: **https://climb-masi.pages.dev** · Cloudflare Pages project: `climb-masi`

## The sequence

### 1. Gate (do not skip)

```bash
export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter analyze
export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test
```

`flutter analyze` must be **0 issues**; `flutter test` must be **green**. Note the passing count and
compare it to the previous known-good count — a *drop* with everything still "green" means tests
stopped being collected, which reads identically to success.

Two traps:

- **Gate the commit you are about to ship.** If the work lives on a branch or in a git worktree,
  `cd` into that directory explicitly and confirm `git log --oneline -1` prints the expected SHA
  before running anything. A gate run from the wrong working directory passes cleanly and proves
  nothing about the code being deployed. This has actually happened here.
- **The machine is load-sensitive.** The suite is unreliable above roughly 150 load average.
  Check `uptime` first; don't run the full suite alongside several other heavy jobs, and don't
  chase a failure that only appears under load before re-running it clean.

### 2. Build

```bash
export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && tool/build_web.sh
```

| invocation | effect |
|---|---|
| `tool/build_web.sh` | **wasm build — the intended default** |
| `tool/build_web.sh --js` | legacy dart2js/canvaskit fallback (one-flag flip) |
| `tool/build_web.sh --gate` | run the guardrails only, no build |

`build_web.sh` is the definition of done, not a convenience wrapper. It enforces, in order:

1. **`dart:io` grep gate** — no `import`/`export 'dart:io'` outside `*_native.dart`. This is a
   *runtime-correctness* guardrail, not a compile gate: `dart:io` is stubbed on web, so the build
   would succeed and then throw when the code is actually reached. Never satisfy it with `kIsWeb`;
   use the conditional-import seam
   (`import 'x_stub.dart' if (dart.library.io) 'x_native.dart' if (dart.library.js_interop) 'x_web.dart';`).
2. **drift/sqlite3 asset pin check** — warns if `pubspec.lock`'s drift version moved but the
   committed `web/sqlite3.wasm` + `web/drift_worker.js` did not. A stale asset here is silent
   data-layer breakage. The refresh commands are printed in the warning itself.
3. **`useLocalCanvasKit` gate** — proves `--no-web-resources-cdn` took effect. Without it the
   renderer resolves against `gstatic.com` and offline first paint dies on a cross-origin fetch.
   (Do not "fix" this by grepping for `gstatic` — that string is always present as the fallback
   branch; the `buildConfig` key is the real signal.)
4. **Service-worker gates** — proves `--pwa-strategy=none` took effect: the bootstrap must end in a
   bare `_flutter.loader.load();`, must *not* pass a settings object, and
   `flutter_service_worker.js` must be empty. Otherwise Flutter registers its deprecated cleanup
   worker over `web/sw.js` and every returning visitor gets a forced reload (bug #55) with no
   offline shell at all.
5. **Precache manifest stamp** — `dart run tool/gen_sw_manifest.dart build/web` rewrites `sw.js`
   with this build's file list and a content-derived `SHELL_VERSION`. **Record that version**; it
   is how step 4 verifies the deploy. A build still carrying `SHELL_VERSION = 'dev'` fails the
   gate, because it would ship a worker that precaches nothing.

If any gate fails, fix the cause. Do not deploy `build/web` from a previous successful build.

### 3. Deploy

```bash
cd /Users/kerip/Projects/masi && npx wrangler pages deploy build/web --project-name=climb-masi --commit-dirty=true
```

- Check `npx wrangler whoami` first if auth is in doubt. It can be slow — background it rather than
  letting it eat a foreground timeout.
- `--commit-dirty=true` suppresses the dirty-working-tree prompt. This repo routinely has
  uncommitted `ios/` AR work, so without it the deploy blocks on an interactive question.
- Only changed files upload; "N already uploaded" is normal.
- `_headers` and `_redirects` upload separately — watch for both in the output.

### 4. Verify production (the step that catches a no-op deploy)

Wrangler prints a URL like `https://<hash>.climb-masi.pages.dev`. That is the **preview alias for
this deployment**, not production. Verify the production hostname directly:

```bash
curl -sS https://climb-masi.pages.dev/sw.js | grep -m1 -i "SHELL_VERSION"
curl -sSI https://climb-masi.pages.dev/ | grep -iE "cross-origin|cache-control|HTTP/"
```

Pass conditions:

- `SHELL_VERSION` **equals the value `build_web.sh` printed in step 2.** A different value means
  production is still serving an older shell — **but allow for edge propagation first.** Immediately
  after `wrangler` reports success, `climb-masi.pages.dev` can still answer with the previous
  deployment's `sw.js` for a few tens of seconds. This has been mistaken for a failed deploy. Before
  concluding anything, re-curl after ~30-60s and cross-check with
  `npx wrangler pages deployment list --project-name=climb-masi` — the top row must read
  `Production`, the expected branch, and the SHA you just gated. If the list says Production and the
  SHA is right, it deployed; you are looking at cache lag, not a no-op.
- `cross-origin-opener-policy: same-origin` **and** `cross-origin-embedder-policy: require-corp`
  are present. These are a **hard hosting requirement**, not hardening — wasm and drift's OPFS
  worker need the document cross-origin isolated. If they are missing, `crossOriginIsolated` is
  false and the data layer is degraded or dead.
- `cache-control: no-cache` on the shell. This means "cache but always revalidate", which is what
  keeps a returning visitor from booting a stale shell against new app code.

### 5. Prove it BOOTS — headers are not evidence of function

**Steps 1-4 can all pass on a site that is completely broken.** This has happened: a deploy was
verified by shell version + headers, declared live and ready to test, and the app was in fact stuck
on the splash screen forever. Correct bytes and correct headers say the *server* is right; they say
nothing about whether the app runs.

Load the production URL in a real browser and confirm the app actually paints:

```bash
rm -rf /tmp/masi-boot-check && "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless=new --disable-gpu --no-first-run --user-data-dir=/tmp/masi-boot-check \
  --virtual-time-budget=30000 --screenshot=/tmp/masi-boot-check.png --window-size=430,900 \
  https://climb-masi.pages.dev/
```

Then **read `/tmp/masi-boot-check.png` as an image.** Pass = real app UI. Fail = the purple splash
with the boulder logo (that is `index.html`, meaning Flutter never took over), or a blank page.

Two things about this check, both learned the hard way:

- **A fresh profile is structurally blind to the service-worker path.** Nothing controls the very
  first navigation, so a first-visit screenshot cannot exercise the worker at all — and the Safari
  redirect bug lived *only* on the worker-controlled path. So run it **twice against the same
  `--user-data-dir`**: load 1 installs the worker, load 2 is the one that proves the controlled
  navigation renders. (Still use a fresh dir per *deploy* — a stale profile carries the previous
  build's worker and masks the failure you are checking for.)
- **`--window-size` below 500px is silently ignored — this makes headless screenshots useless for
  phone-width layout checks.** Chrome `--headless=new` floors the window width at exactly 500 CSS px:
  requesting 200/300/390/430/499 all render at **500**, while 501 and up are honored exactly. It
  happens with the launch flag *and* with WebDriver `window/rect`. The trap is that the screenshot is
  then *cropped* to the width you asked for, so content looks clipped at the right edge and the
  layout appears not to respond to width — two different "widths" produce an identical render with
  different crops. This was misread here as a real horizontal overflow in the sign-in card. To
  measure a genuine phone viewport, use CDP emulation instead:
  `Emulation.setDeviceMetricsOverride({width:390, height:844, deviceScaleFactor:2, mobile:true})`
  (via chromedriver's `chromium/send_command_and_get_result`), then confirm `window.innerWidth` really
  reads 390 before trusting the screenshot.
  Also note the render surface lives in a **shadow root**: `document.querySelectorAll('canvas')` finds
  nothing, and `flt-glass-pane`'s own light-DOM rect is `0x0`. Pierce `flt-glass-pane.shadowRoot` to
  find the real `<canvas>` and its size.

Kill any Chrome you start (`pkill -f masi-boot-check`); headless Chrome with a virtual time budget
does not always exit on its own.

If it fails, get the real console error — do not guess. `--enable-logging`/`--v=1` do **not** surface
page-level console messages in `headless=new`; they emit only Chrome's own GCM/GPU noise. Use
chromedriver's WebDriver API with `"goog:loggingPrefs": {"browser": "ALL", "performance": "ALL"}`
and pull `/session/<id>/log`, or drive CDP directly. Start chromedriver on a port other than **4444**,
which `tool/drive_web.sh` uses.

### 5b. "It paints" is not "it works" — exercise sign-in

A deploy verified only as far as first paint shipped a **total sign-in lockout**: the app rendered
its sign-in screen perfectly and "Continue with Google" did nothing at all. Google is the only
working sign-in path on iOS (email OTP is blocked on the Supabase free tier), so painting correctly
and being completely unusable looked identical.

After the boot check, drive the sign-in button and confirm a navigation is actually attempted. It is
a Flutter canvas app, so there is no real DOM button — click by coordinates taken from the
screenshot, or use CDP `Input.dispatchMouseEvent`. Then assert that a request toward
`*.supabase.co/auth/v1/authorize` or `accounts.google.com` appears in the network log.

The decisive question is binary: **does the click produce any network attempt at all?** If yes, any
failure is downstream and diagnosable. If nothing leaves the browser, the failure is in Dart before
the network — and the likeliest shape is a swallowed error, because `url_launcher_web`'s
`openNewWindow` **hardcodes `return true`** (it cannot detect success when `noopener` is set), so a
refused navigation is indistinguishable from a successful one all the way up the stack.

### 5c. What automation here CANNOT cover — say so, every time

**No automation available on this machine can drive an iOS home-screen (standalone) PWA.** Not
headless Chrome, not Playwright WebKit, not the simulator. That is not a gap to work around; it is a
permanent limit to disclose.

It matters because standalone mode has genuinely different behaviour: it silently refuses
`window.open(url, '_self', 'noopener,noreferrer')`, which is exactly how the sign-in lockout above
happened, and it can hand out-of-scope navigations to Safari — whose storage does not hold the PKCE
verifier the PWA just wrote. Both failures are invisible to every browser this machine can drive,
and both were measured working in headless Chrome and real headless WebKit while broken on the
phone.

So when a change touches auth, storage, navigation, or the service worker, the report must say which
claims are proven and which need a manual check on the device — and the device check must be run in
the **installed home-screen app**, not a Safari tab, because a tab can pass while the installed app
fails.

### 6. Report honestly

Say the production URL, and say what was verified versus what was not. Distinguish "the server
serves the right build" from "the app works" — they are separate claims needing separate evidence,
and conflating them is how a broken deploy gets announced as ready.

Two limits worth stating explicitly every time:

- **Headless Chrome passing is not evidence about iOS Safari**, which is where this PWA actually
  gets used, and where tab reclaim and WebKit quirks bite. If a change is proven only in Chrome,
  say so.
- **The local harness is not cross-origin isolated; production is.** `tool/drive_web.sh` serves via
  `-d web-server` with no COOP/COEP, so `crossOriginIsolated === false` and drift selects an
  IndexedDB backend. The deployed site sets COOP/COEP, so `crossOriginIsolated === true` and the
  OPFS / threaded paths come into play. **A green local suite therefore cannot speak for the code
  path the live site runs.** To test that path locally, serve `build/web` from a static server that
  sets the COOP/COEP headers itself and load that.

## Caching model (why the headers are the way they are)

`web/_headers` is the source of truth. **Cloudflare Pages APPENDS the value of every matching rule
into one comma-joined header — it does NOT resolve by path specificity, and it does not let the most
specific rule win.** `*` also spans path separators, so `/*.wasm` already matches
`/canvaskit/skwasm.wasm`.

This caused a total outage: a `/*.wasm` block and a `/canvaskit/*.wasm` block both matched, so
canvaskit was served `Content-Type: application/wasm, application/wasm` — not a valid MIME type, and
Pages sets `nosniff`, so the browser could not recover. `WebAssembly.compile` threw inside
`flutter_bootstrap.js` **before Dart's `main()` ran**, so the app's own boot deadlines could never
fire and the page sat on the splash forever. Each individual block read perfectly well on its own.

**The rule: for any given header name, exactly one block in this file may set it for a given path.**
Do not add a narrower block to "override" a broader one — that appends instead. `test/web_hosting_config_test.dart`
models the append semantics over the real build paths and fails if any header is set twice.

- `/*` → COOP/COEP/CORP + `Cache-Control: no-cache`. Deliberately **not** `immutable`: Flutter does
  not content-hash `main.dart.wasm` / `flutter_bootstrap.js` / `index.html` per build, so
  `immutable` would pin stale code forever. Deliberately not `no-store` either — cheap 304s are
  wanted.
- `/*.wasm` → `Content-Type: application/wasm`, and **nothing else sets Content-Type anywhere**.
- **There are no `immutable` blocks any more, and no dedicated `/sw.js` block.** Both were removed
  when the append semantics above were understood. The old `immutable` rules for `/sqlite3.wasm` and
  `/drift_worker.js` appended onto the blanket rule and produced the self-contradictory
  `Cache-Control: no-cache, public, max-age=31536000, immutable`. A `/sw.js` block saying `no-cache`
  is equally wrong — it appends to give `no-cache, no-cache`. The blanket `/*` rule already delivers
  `no-cache` to `sw.js`, which is what matters: `sw.js` is the mechanism by which a new build reaches
  an existing installation, so a long-cached one would freeze a user on a stale shell forever.

So the whole file is two blocks. Adding a third to say something more specific is almost always the
bug, not the fix.

## Rules

- **Never push to a git remote and never open a PR as part of deploying.** Deploying to Cloudflare
  is expected; publishing the repo is a separate, explicitly-requested action. Commit freely.
- Never commit or print secrets. The client uses only the Supabase anon/publishable key; the
  `sbp_…` admin token in `~/.config/climbtopo-mgmt-token` has nothing to do with deploying.
- Leave `ios/` alone — uncommitted AR work lives there, and it is why `--commit-dirty=true` exists
  in the deploy line.
- If a schema change ships with the build, the Supabase migration must be applied to the live
  project **before** the deploy, or the new client hits a schema-drift error against the old
  database. Schema drift is the recurring bug class in this project. See the Management API recipe
  in the project's `CLAUDE.md`.

## Deeper verification (optional, when a deploy is risky)

The headless-Chrome harness is the autonomous way to prove the deployed *code* actually works,
not just that it was uploaded:

```bash
export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && \
  tool/drive_web.sh integration_test/web_smoke_test.dart
ls build/screenshots/    # then read the PNGs
```

Requires `chromedriver` on PATH matching the installed Chrome major version. Note the limit of
what the smoke test proves: it boots the app and walks Area→Sector→Wall without throwing, and it
contains **zero `expect()` calls** — it is not a persistence test. `tool/drive_web_photo_offline.sh`
and `tool/drive_web_write_order.sh` are the durability harnesses (cold-restart survival, and which
writes survive a kill).
