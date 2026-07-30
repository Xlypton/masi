# Web offline reliability — design

**Date:** 2026-07-30
**Goal:** Make the masi PWA work offline as reliably as possible. Priority order:
**(1) never lose a topo recorded offline, (2) sync it as soon as possible.**

Scope is the **web/PWA target**. Native iOS/Android must stay bit-identical except where a fix is
inherently shared (auth/uid scoping and the sync engine live in `lib/` and are platform-agnostic —
those fixes benefit native too, and several of them fix live native bugs).

---

## Approved decisions

| # | Decision | Rationale |
|---|---|---|
| D-1 | All four flows must work offline: create topos end-to-end, view own topos, view previously-seen public topos, map view | User requirement |
| D-2 | **No export/download escape hatch.** Invest in local durability + sync that retries until it succeeds | User choice: "just make sync bulletproof" |
| D-3 | **Conflict policy: local wins for my own data.** Offline work overwrites the cloud copy on push | Guarantees offline work is never silently discarded; matches solo use. Resolves the long-deferred #2 |
| D-4 | **Keep the full-state re-push engine; fix the scheduler.** Do not build an outbox | The re-push is already idempotent and loss-proof; its defects are scheduling and honesty. New sync-core surface = new data-loss bugs |
| D-5 | **Keep photos at full resolution.** Handle quota by failing loudly, not by shrinking | User choice. Raises the priority of quota detection (§1f) and upload-list pagination (§1f-4) |
| D-6 | Sequenced in three stages: data safety → offline shell → offline reads. Each verified and committed separately | User choice |

---

## Current state (audit, 2026-07-30)

Established by a 7-agent audit; contradictions between readers were settled by opening the files.
Everything below is **proven from code**, with the evidence cited. Suspected-only items are labelled.

### The PWA has no offline capability whatsoever

1. Flutter 3.44 **removed the caching service worker.** What ships is a 31-line deprecation shim:
   `install → skipWaiting`, `activate → self.registration.unregister()` + `client.navigate()`,
   and **zero `fetch` listeners**. `tool/build_web.sh:77` runs a bare `flutter build web --wasm`
   with no `--pwa-strategy`.
2. It is usually not even registered — the loader only registers when a registration already exists
   (`flutter_bootstrap.js`: `navigator.serviceWorker.getRegistration().then(r => r ? t() : …)`).
   A first-time visitor ends up with **no** service worker at all.
3. `web/_headers:33-37` sets `Cache-Control: no-cache` on `/*` — cacheable but *must revalidate*.
   Offline revalidation fails, so `index.html`, `flutter_bootstrap.js`, `main.dart.wasm` (3.9 MB)
   and `assets/**` cannot be served from the HTTP cache. This is **deliberate** (`web/_headers:16-31`
   documents it as the fix for the #55 stale-shell reload bug, since Flutter does not content-hash
   those filenames). Only `/sqlite3.wasm` and `/drift_worker.js` are `immutable` (`:58-62`).
4. **The renderer is a cross-origin CDN fetch.** `flutter_bootstrap.js` resolves `skwasm.js`,
   `skwasm.wasm`, `skwasm_heavy.*` against `https://www.gstatic.com/flutter-canvaskit/<engineRevision>/`
   because `buildConfig` sets `engineRevision` and never `useLocalCanvasKit`. The local
   `build/web/canvaskit/` directory (**37 MB** in the current build) is dead weight.
5. **Net effect:** installed PWA + airplane mode = a blank browser error page, with the drift database
   and the `climbtopo-photos` IndexedDB intact on disk and completely unreachable.

### Data-loss paths

- **L1 — Silent `inMemory` drift backend (total loss on reload).** `WasmDatabase.open` never throws;
  drift falls back to `WasmStorageImplementation.inMemory`, documented as "doesn't store anything".
  `lib/core/db/connection/connection_web.dart:26` takes `result.resolvedExecutor` unconditionally and
  **never reads `result.chosenImplementation`**. Writes succeed, lists populate, everything is gone on
  the next load. Reachable via private browsing, blocked/partitioned storage, or a `drift_worker.js`
  404 after a bad deploy combined with unavailable IndexedDB. **Undetectable in production**: the only
  signal is a `debugPrint` behind `if (kDebugMode)` (`connection_web.dart:19-25`).
- **L2 — Storage eviction with no cloud copy.** `grep -rn "storage.persist\|navigator.storage\|estimate()" lib web`
  → **zero hits**. Both stores are best-effort/evictable: drift `climbtopo`
  (`connection_web.dart:15`) and photo bytes `climbtopo-photos` (`photo_byte_store.dart:44-46`,
  opened `:63-74`). iOS Safari purges an unused origin after ~7 days; Chrome evicts non-persistent
  origins under pressure.
- **L3 — `importPhoto` swallows byte-write failure and creates the row anyway.**
  `lib/features/topo/data/photo_files_web.dart:29-42` —
  `try { … _store.writeBytes(key, bytes); return key; } catch (_) { return key; }` (catch at `:40`).
  `LibraryCrudRepository.attachPhotoToWall` then inserts the `Photos` row with that path
  (`library_crud_repository.dart:592-620`). Quota is the realistic trigger and it is reachable in
  ordinary use because **originals are never downscaled** (`photo_source_sheet.dart:94` calls
  `pickImage` with no `imageQuality`/`maxWidth`; the web path stores `readAsBytes()` verbatim — only
  the 512px/q80 thumbnail is downscaled, `image_ops_web.dart:12-46`). Downstream,
  `sync_service.dart:403-404` skips the byte upload with no error and no counter, while `:338` has
  already pushed the metadata.
- **L4 — Hard sign-out silently drops every subsequent library edit.** A captive portal returns a
  non-2xx with an HTML body, which gotrue classifies as `AuthUnknownException` — **not** retryable —
  so `_removeSession()` fires and `removePersistedSession()` erases the localStorage key.
  `currentUidProvider` then returns null, so `_ownOrUnowned`
  (`lib/features/library/data/library_crud_repository.dart:87-92`) collapses to `ownerId.isNull()`
  for every mutation it guards (`:104, :117, :128, :181, :283, :373, :439, :482, :518, :1274-1307`).
  Those are `UPDATE … WHERE` statements **whose row count is discarded**, so a rename/move/GPS-stamp/
  delete against an owner-stamped row updates 0 rows and **reports success**. Nothing in `lib/` reads
  `SignOutReason` (`grep SignOutReason lib` → no hits).
- **L5 — A row failing the push-side NOT-NULL guard is dropped from this and every future push.**
  `sync_service.dart:288-336` filters through `filterValidSyncRows(…, syncRequiredFields[t])`; the
  skip is a `debugPrint` only (`sync_remote.dart:327-331`). No queue entry, no error state, no user
  signal. With no outbox, "excluded once" means "excluded forever".
- **L6 — Metadata and pixels live in two independent, non-transactional web stores.** Drift may sit in
  OPFS while photo bytes are always in a separate IndexedDB database (`climbtopo` vs
  `climbtopo-photos`). No cross-store transaction, so partial eviction or an interrupted import
  leaves `Photos.localPath` pointing at absent blobs.
- **L7 — A stale shell rewrites `user_version` backwards.** `schemaVersion => 8`
  (`lib/core/db/app_database.dart:31`); every branch is `if (from < N)` (`:44, :56, :67, :76, :104,
  :173, :190`) with **no `from > to` guard**. Older code opening a v8 DB skips every branch and stamps
  `user_version = 7`; a later re-upgrade re-runs `from < 8` → `createTable(profiles)` against an
  existing table and throws. **Zero browser-executed migration coverage** — every test in
  `test/core/db/app_database_migration_test.dart` uses `NativeDatabase` (`:178, :392, :635, :869,
  :1141, :1468, :1748`). Low likelihood while `no-cache` holds; the Stage-2 service worker changes
  that risk profile, so the guard must land with it.
- **L8 (suspected) — Multi-tab races on `unsafeIndexedDb`.** drift documents that backend as unable to
  prevent cross-tab data races, and there is no leader-tab election. Two tabs both run the
  orchestrator. Aggravated by **permanent backend lock-in**: `moveExistingIndexedDbToOpfs` defaults
  `false` and is not passed, so `_selectExistingDatabase` downgrades the choice back to the existing
  DB's storage API on every open — any install that first landed on IndexedDB stays there forever.

### Sync-stall paths

- **S1 — A completely failed offline push reports "Synced • just now".**
  `SupabaseSyncRemote.upsertOwnRows` wraps **each table** in try/catch and `continue`s on any error
  with only a `debugPrint` (`sync_remote.dart:355-401`, catch at `:394`), returning `void`.
  `rowsPushed` therefore counts rows merely *handed to* the remote (`sync_service.dart:343-344`), and
  the orchestrator sets `status: SyncStatus.idle, lastSyncedAt: _now()`
  (`sync_orchestrator.dart:209-210`) → `account_screen.dart:904-906` renders `'Synced • …'`.
  **Narrow but real:** it requires zero own photo rows, because `sync_service.dart:369`
  (`if (photos.isEmpty) return 0;`) short-circuits before the un-guarded
  `listPhotoObjectPaths` (`:371` → `sync_remote.dart:637`) which otherwise throws and surfaces
  `SyncStatus.error`.
- **S2 — No retry, no backoff, no bounded attempts.** `grep -niE "retry|backoff" lib/features/backup`
  returns only prose. `_runPush` catches and sets `SyncStatus.error` with no reschedule
  (`sync_orchestrator.dart:216-219`); `_runPull` likewise (`:317-324`). The only push triggers are
  `tableUpdates()` + a 2s debounce (`:159`, `:187-194`) and `onAppPaused()` (`:199-202`). Nothing is
  *lost* — `pushOwn` re-reads a full own-row snapshot every time (`sync_service.dart:265-275`) — but a
  user who edits offline and then neither writes again nor backgrounds the app stays unsynced
  indefinitely.
- **S3 — Nothing reacts to connectivity returning.** `ConnectivityService` exposes only
  `Future<NetworkStatus> currentStatus()` (`connectivity_service.dart:25-27`);
  `grep -rn "onConnectivityChanged" lib` → **zero hits**. App-resume fires a **pull** only
  (`app.dart:75-79`), throttled 30s (`sync_orchestrator.dart:146`).
- **S4 — The connectivity signal is dead code, so `SyncStatus.offline` is unreachable.** Its only
  consumers are two `wifiOnly` gates (`sync_service.dart:242-247`, `cloud_backup_service.dart:139-141`);
  `WifiOnlySetting.build() => false` (`backup_providers.dart:44`), in-memory, with no UI. On web
  `SystemConnectivityService.currentStatus()` returns `NetworkStatus.wifi` **unconditionally**
  (`connectivity_service.dart:53`). `SyncStatus.offline` is produced only by `skippedNotWifi`
  (`sync_orchestrator.dart:213-214`), so `account_screen.dart:901-902`'s "Offline" label can never
  render in production.
- **S5 — Rows are pushed before bytes, producing cloud orphans and unhealable local paths.**
  `sync_service.dart:338` then `:341`, no transaction, no try/catch. On the receiving device
  `_downloadAndRewritePhotos` only rewrites `localPath` when bytes arrived (`:645-648`); otherwise the
  row keeps the **originating device's** path, and on web `resolvePhotoPath`/`resolvePhotoPathSync`
  are identity passthroughs with no existence check (`photo_files_web.dart:74-75, :97-98`).
- **S6 — The "already uploaded" skip-set is truncated at 100 objects.** `sync_remote.dart:637-640`
  and `:667-670` call `.list(path: …)` with no `SearchOptions`; the storage client default is
  `limit = 100`. Past ~100 photos every push re-reads and re-uploads **full-resolution** bytes already
  in the cloud (`sync_service.dart:371-372, :390-393`). Under D-5 (full res retained) this is the
  dominant cost and a long window for the byte phase to fail.
- **S7 — Push and pull cost scale with library size, not change count.** No dirty filter, no
  `updatedAt` cursor, no pagination: nine unfiltered selects (`sync_service.dart:265-275`), one
  `inFilter('id', [every id])` LWW pre-check per table (`sync_remote.dart:375-376`), `fetchOwnRows`
  (`:410`), and `fetchSharedTopos` selecting **every shared wall globally** (`:440`). No `.range(` or
  `.limit(` anywhere. Any PostgREST max-rows cap or URL-length limit truncates or fails **silently**.
- **S8 — `dirty` is vestigial.** Declared `lib/core/db/tables.dart:21` ("true when local changes
  haven't been pushed"), written `true` by every repository, and **never read or cleared by anything**.
  `remoteId` is equally unused. **Both ship to the cloud inside every row's JSON.**
  `grep -rin "outbox" lib` → **zero hits**: CLAUDE.md's "outbox push/pull" describes a debounced
  full-state re-push and is wrong.
- **S9 — Every pull that writes anything triggers a full re-push ~2s later**, because
  `importSnapshot`'s transaction (`backup_repository.dart:87`) fires the same `tableUpdates()` the
  debounced push listens to.
- **S10 — No in-flight guard on push.** `onAppPaused()` cancels the timer but not a running `_runPush`
  (`sync_orchestrator.dart:199-202`), unlike the pull-side guard (`:262-274`). Two concurrent full
  pushes can duplicate the LWW pre-check, upserts and uploads.

### Auth / UI gaps

- **Offline token refresh throws every 10s once the token nears expiry.** gotrue's ticker runs every
  10s and attempts a refresh within 3 ticks of expiry, so a fresh token buys ~1h of quiet. Then each
  tick offline throws `AuthRetryableFetchException` → `notifyException` → `_onAuthStateChangeController.addError(...)`.
  **No sign-out** for the retryable case.
- **Web: the user is ejected to a sign-in screen they cannot use offline.** That stream error makes
  `authStateProvider` an `AsyncError`; `_ensureAuthRefreshWired` calls `appRouter.refresh()` on every
  emission (`lib/app/router.dart:147-154`) and `_webAuthGateRedirect` fails closed at `:132`
  (`if (authAsync.hasError) return webAuthGateSignInPath;`). The gate is on by default
  (`auth_providers.dart:70`). The fail-closed comment at `router.dart:111-113` documents the intent
  as "Supabase never initialized" — it was **not** written against a transient refresh error that
  leaves a valid in-memory session.
- **Native: the library silently empties.** `toposProvider` reads
  `ref.watch(authStateProvider).asData?.value.uid` (`library_providers.dart:66-67`) and `asData` is
  null for `AsyncError` as well as loading. `watchTopos(null)` collapses the owner filter
  (`library_crud_repository.dart:860`) to `owner_id IS NULL`; since `claimOwnership` stamps `ownerId`
  on every unowned row at first sign-in (`:1382-1430`), the whole library vanishes and renders
  **"No topos yet"** (`topos_screen.dart:266-268`) — a *successful empty stream*, so the Retry branch
  never runs.
- **The two "who am I" doors disagree exactly during a blip.** `toposProvider` uses
  `authStateProvider.asData`; every write path and `logbookEntriesProvider:138` use the synchronous
  `currentUidProvider` (`auth_providers.dart:46-54`), which reads `authRepository.currentSession.uid`
  per call inside a try/catch and so survives a retryable error. Write paths therefore keep working
  through a blip and break only on a hard sign-out (L4).
- **Sync errors are invisible unless the list is empty.** The `lastPullError` + Retry affordance is
  gated inside `if (proximityEntries.isEmpty)` (`topos_screen.dart:241-268`), same shape in
  `community_feed_screen.dart:201, :278, :456-474`. **Push failures have no message and no retry
  affordance at all** — `lastPullError` is pull-only by construction
  (`sync_orchestrator.dart:59-62`), `_runPush` only touches `status`/`lastSyncedAt` (`:204-220`), and
  there is no manual "sync now" anywhere.
- **Map and geocoding are blank offline** — plain `TileLayer(urlTemplate:)`
  (`community_map_screen.dart:818`, `set_location_picker.dart:480`) and
  `Uri.https('nominatim.openstreetmap.org', …)` (`lib/core/location/geocoding_service.dart:79`). No
  tile-cache package in `pubspec.yaml`.
- **Cross-origin isolation is a hard runtime requirement that nothing verifies.** `web/_headers:33-37`
  sets COOP/COEP/CORP and `firebase.json:15-42` mirrors it, but `tool/build_web.sh` checks only the
  `dart:io` grep (`:34-46`) and the drift asset pin (`:48-69`); the CI `web-build` job is
  `continue-on-error: true` (`.github/workflows/ci.yml:39`) and uses a *different, naive* substring
  gate (`grep -rl 'dart:io' lib`) than `build_web.sh:41`'s directive-anchored regex. A header
  regression silently downgrades storage to IndexedDB — then pins it there forever (L8).

### What already works (do not rebreak)

- All local writes are offline-agnostic: repositories write drift first; photo bytes go to IndexedDB;
  creating areas/sectors/walls, importing a photo, drawing routes and logging ascents all succeed
  offline in an already-open tab.
- `Supabase.initialize` needs **no network** on its awaited path — it awaits only
  `supabaseAuth.initialize()` (localStorage read + `setInitialSession`) and fires `recoverSession()`
  as a fire-and-forget `CancelableOperation`. The web session lives in `window.localStorage` under
  `sb-mnaipcqbkqzffgvxpato-auth-token` (**not** SharedPreferences — that is native-only).
- Tab-hide/close **does** flush a push: `installWebLifecycleFlush` hooks `visibilitychange`(hidden) +
  `pagehide` → `onAppPaused()` (`lib/app/web_lifecycle_web.dart:40-55`, wired `lib/app/app.dart:40-42`).
  `docs/web-port-backlog.md:27-32` claims this is missing and is **stale** — fix that doc.
- Failed pushes lose nothing: `pushOwn` re-reads a full own-row snapshot every time. This is the
  property D-4 preserves.

---

## Design

### Stage 1 — Nothing can silently lose or hide a topo

#### 1a. Storage-backend interlock (fixes L1)

`connection_web.dart` must stop discarding `WasmDatabase.open`'s verdict. Capture
`chosenImplementation` and `missingFeatures`, expose them through a provider, and **block topo
creation behind an unmissable warning when the backend is `inMemory`**. Log the verdict in release
builds, not behind `kDebugMode`.

Also pass `moveExistingIndexedDbToOpfs: true` so installs pinned to IndexedDB (every visitor served
before COOP/COEP landed) can migrate up, mitigating L8's lock-in. This must be covered by the
browser migration test in §Testing before it ships.

> Assertions
> - A container built over an `inMemory`-backed connection reports a non-durable storage state, and
>   the create-topo affordance is disabled.
> - A container over a persistent backend reports durable and allows creation.
> - The chosen implementation is logged outside `kDebugMode`.

#### 1b. Persistent storage (mitigates L2)

Request `navigator.storage.persist()` during boot, record whether it was granted, and read
`estimate()` for usage/quota. No user-facing UI beyond the diagnostics row in §2c. Web-only, behind
the existing conditional-import convention.

> Assertions
> - Boot on web calls `persist()` exactly once and records the outcome.
> - A denied/unavailable `persist()` degrades silently — it never blocks boot or throws.

#### 1c. Auth can never hide or blackhole local data (fixes L4 + the native-empty-library bug)

Four changes, all in `lib/` so native benefits too:

1. **Persist `lastKnownUid` locally** and scope local reads/writes by it whenever the live session is
   absent or erroring. This is the root fix: local data ownership stops depending on a live network.
   It must survive a `sessionExpired` sign-out and be cleared only on a *user-initiated* sign-out.
2. **`toposProvider` reads uid through the synchronous door**, matching every write path and
   `logbookEntriesProvider:138`, so an `AsyncError` can no longer collapse the owner filter.
3. **The web router stops failing closed on `hasError`.** "Persisted session present, backend
   unreachable" is signed-in-offline; only "no persisted session at all" reaches the sign-in wall.
   Update the `router.dart:111-113` comment to state the distinction.
4. **Guarded mutations verify their affected row count.** A `_ownOrUnowned` update that matches 0 rows
   must surface an error instead of reporting success, and a write attempted with an unexpectedly null
   uid must fail loudly rather than silently target `ownerId IS NULL`.

> Assertions
> - With `authStateProvider` in an error state, `toposProvider` still emits the signed-in user's
>   topos (non-empty) rather than an empty list.
> - After a `sessionExpired` sign-out, local reads still return the user's topos and local writes
>   still target the correct `ownerId`.
> - After a **user-initiated** sign-out, `lastKnownUid` is cleared.
> - An `_ownOrUnowned` mutation that matches 0 rows returns/throws a distinguishable failure; the
>   pre-fix behaviour (silent success) fails the test.
> - Web router: persisted-session + auth-stream-error does **not** redirect to the sign-in path;
>   no-session **does**.

#### 1d. Sync tells the truth (fixes S1, S4)

`upsertOwnRows` returns per-table outcomes instead of swallowing them (`sync_remote.dart:355-401`);
failures aggregate into the push result alongside a `rowsFailed` count, mirroring the existing
`PullResult.errors` shape (`sync_service.dart:463-597`). L5's `filterValidSyncRows` skips feed the
same channel, so an excluded row is visible instead of silently dropped forever.

A push that did not land can never produce `idle` + a fresh `lastSyncedAt`. `SyncStatus.offline`
becomes reachable through an **actual reachability probe** (a cheap request to the Supabase origin),
because `connectivity_plus` reports interface state and says "connected" behind a captive portal —
and on web `currentStatus()` currently returns `wifi` unconditionally.

The existing `sync-status` label (`account_screen.dart:895-912`, key `sync-status`) then reports
truthfully. This is fixing a lying label, not adding UI. Per D-2 no unsynced-count badge is added.

> Assertions
> - With a remote that throws on every table, `pushOwn` reports a failure; the orchestrator status is
>   not `idle` and `lastSyncedAt` is unchanged.
> - The same scenario **with zero photo rows** also reports failure (this is the exact S1 regression;
>   pre-fix it reports success).
> - A row excluded by `filterValidSyncRows` appears in the push result's failure channel.
> - Reachable-but-not-authenticated and unreachable produce distinguishable statuses;
>   `SyncStatus.offline` is produced by a real offline condition, not only by `skippedNotWifi`.

#### 1e. Sync as soon as possible (fixes S2, S3, S10)

- `ConnectivityService` gains the change stream it never had, plus the browser `online` event on web,
  wired to trigger push **and** pull on regain.
- Retry with exponential backoff and jitter (~2s → 5min ceiling), running as long as anything is
  pending, **never giving up**. Bounded interval, unbounded attempts — that is what "bulletproof"
  means under D-2.
- App-resume triggers a push, not only the throttled pull (`app.dart:75-79`).
- Push gets the in-flight guard the pull side already has (`sync_orchestrator.dart:262-274`).
- **`dirty` becomes real** — set on write, cleared only on *confirmed* push — which is what makes
  "retry until clean" a well-defined loop and lets the fast path push only what changed (S7). The
  full-state re-push remains the fallback, preserving D-4's loss-proofness. Since `dirty` and
  `remoteId` currently ship inside every row's JSON (S8), **they must be stripped from the synced
  payload** as part of this change.
- S9 (a pull's writes triggering a re-push) resolves naturally once `dirty` gates the push: imported
  rows are not locally dirty.

> Assertions
> - A push that fails while offline is retried automatically after the backoff interval, with no
>   further user action and no further local write.
> - Backoff grows on repeated failure and resets after a success; the interval never exceeds the
>   ceiling.
> - A connectivity-regain event triggers a push within the debounce window.
> - Two concurrent push triggers result in exactly one in-flight push.
> - `dirty` is cleared only after a confirmed push; a failed push leaves it set.
> - The pushed row payload contains neither `dirty` nor `remoteId`.
> - Importing a pulled snapshot does not mark rows dirty and does not schedule a push.
> - **End-to-end:** create a topo with the remote unreachable, then make the remote reachable without
>   any local write → the topo reaches the remote.

#### 1f. Photo integrity at full resolution (fixes L3, S5, S6)

Under D-5 originals stay full-res, so quota must fail loudly:

1. `importPhoto` **propagates** byte-write failure (`photo_files_web.dart:29-42`) — no pixel-less
   `Photos` row is ever created — and `QuotaExceededError` is detected and reported plainly.
2. Upload order flips to **bytes-then-metadata**, so a failed upload no longer leaves other devices
   with a `Photos` row pointing at a nonexistent Storage object (S5).
3. Byte-upload failures are counted and retried through §1e's loop rather than `continue`-ing
   silently (`sync_service.dart:403-404`).
4. The "already uploaded" listing is **paginated** past its 100-object default
   (`sync_remote.dart:637-640, :667-670`). At full resolution, re-uploading every photo on every push
   is the dominant cost and the dominant failure window.

> Assertions
> - With a byte store that throws on write, `importPhoto` throws and no `Photos` row exists
>   afterwards.
> - A quota failure is reported as a distinguishable, user-presentable error.
> - Push uploads bytes before upserting the corresponding photo row; when bytes fail, that row's
>   metadata is not pushed.
> - With 150 objects already in the remote, the skip-set contains all 150 and zero re-uploads occur.

### Stage 2 — The app actually opens offline

#### 2a. Same-origin renderer

Build with `--no-web-resources-cdn` in `tool/build_web.sh:77` so `skwasm`/CanvasKit are served
same-origin instead of fetched from gstatic. Confirm the build emits `useLocalCanvasKit` and that no
`gstatic.com` reference remains in `build/web/flutter_bootstrap.js`. Drop the dead 37 MB `canvaskit/`
payload if the wasm build does not need it.

> Assertions
> - `grep -c gstatic build/web/flutter_bootstrap.js` is 0 after a release web build.
> - The build gate in `tool/build_web.sh` fails if a `gstatic` reference reappears.

#### 2b. Custom service worker

Add `web/sw.js` with a precache manifest generated at build time by `tool/build_web.sh`. Strategy:

- **Shell: network-first with cache fallback.** This preserves the #55 stale-shell fix — online users
  always get a fresh shell and `web/_headers` stays `no-cache` — while offline users get a working
  shell. The SW is purely the offline layer underneath the existing HTTP policy.
- **Immutable/hashed assets: cache-first.**
- Cache name versioned per build, `skipWaiting` + `clients.claim`, old caches pruned on activate.
- Registered **explicitly from `web/index.html`**, because the Flutter loader will not register one.
- Cached same-origin responses retain their COOP/COEP headers, so cross-origin isolation survives
  being served from the Cache API. Verify `crossOriginIsolated === true` at runtime rather than
  trusting that `_headers` is applied.
- Precache list must include `sqlite3.wasm` and `drift_worker.js` — a `drift_worker.js` 404 is one of
  L1's triggers.

Because a service worker makes a stale shell genuinely possible for the first time, **L7's
`from > to` migration guard must land in this stage**: `app_database.dart` gets an explicit
downgrade guard instead of silently stamping `user_version` backwards.

> Assertions
> - After first load, the SW is registered/active and the precache contains every shell asset needed
>   to boot (enumerated in the plan).
> - A cold start with the network disabled renders the app's first screen.
> - `crossOriginIsolated` is `true` on the deployed origin.
> - A new build's SW version replaces the old cache; the shell served while online is the fresh one.
> - Opening a v8 database with a lower `schemaVersion` fails loudly instead of stamping
>   `user_version` backwards.

#### 2c. Runtime diagnostics

A provider exposing: chosen storage backend, `persist()` grant, storage usage/quota,
`crossOriginIsolated`, SW registration state. Surfaced as a compact diagnostics row on the Account
screen and asserted in tests. This is what makes a future "my data vanished" report answerable —
today there is nothing to consult, and no web crash reporting
(`docs/web-port-backlog.md:47-51`).

### Stage 3 — Offline reads

- **Public/community photo bytes cached locally** under a quota-aware LRU so previously-seen public
  topos render offline, reusing `PhotoByteStore` and the existing `PhotoImageCache` budget/eviction
  machinery (`photo_image_cache_web.dart:48, :99-141`).
- **Map tiles: a service-worker runtime cache** (stale-while-revalidate, capped, LRU-pruned) for tile
  URLs. Tile servers send CORS headers, so COEP `require-corp` is satisfied; this needs no Dart-side
  tile provider. Applies to both `community_map_screen.dart:818` and `set_location_picker.dart:480`.
- **Nominatim geocoding degrades gracefully** offline instead of hanging
  (`lib/core/location/geocoding_service.dart:79`).
- **Offline-aware empty states:** the existing sync-error empty states
  (`topos_empty_states.dart:44-97` key `topos-sync-error-empty`; `community_feed_screen.dart:446-495`
  key `community-sync-error-empty`) gain an offline variant, and the pull-error affordance stops being
  gated on an empty list.

> Assertions
> - A public topo whose bytes were cached renders offline; one never seen does not (and shows the
>   offline variant, not a bare placeholder).
> - The photo cache respects its quota bound and evicts LRU rather than throwing.
> - Tiles previously viewed render offline; the map does not hang waiting on the network.

---

## Testing strategy

The existing web coverage cannot catch any of this: **`integration_test/web_smoke_test.dart` contains
zero `expect()` calls** (`grep -c 'expect('` = 0) and never reloads, so CLAUDE.md's "drift-on-WASM
persistence through real IndexedDB — both green" is screenshot-only and must be corrected.
`integration_test/web_boot_stability_test.dart:127-139` is the only web test with real assertions.

**Unit / widget** (extend, do not rebuild): `FakeSyncRemote`, `ThrowingFetchSharedToposRemote`,
`FakeConnectivityService`, `FakeAuthRepository` and the two-device `makeContainer(...)` +
`seedWallHierarchy(...)` helpers in `test/features/backup/data/sync_service_test.dart:23-364`;
`_CountingSyncRemote` / `primeOrchestrator(container)` in
`test/features/backup/application/sync_orchestrator_test.dart:26-175`; real `IdbPhotoByteStore` over
`newIdbFactoryMemory()` in `test/features/topo/data/photo_byte_store_test.dart`. Time is already
seamed via `syncDebounceDurationProvider` (`sync_orchestrator.dart:92`) and `nowMsProvider`
(`database_provider.dart:24`) — backoff tests use those, never real delays.
Note `syncRemoteProvider` (`sync_providers.dart:22`) is currently overridden by **no** test (they
override `syncServiceProvider` wholesale) and `connectivityServiceProvider` by none — both become
primary override points.

**Web integration** (`tool/drive_web.sh`, chromedriver + headless Chrome): reload-persistence with
real assertions; an assertion that the chosen backend is **not** `inMemory`; `crossOriginIsolated` and
SW-precache assertions; an offline cold-start drive using CDP network emulation.

**Browser-executed migrations:** run v1→v8 against a real `WasmDatabase`, including the v6→v7
`alterTable(TableMigration(...))` rebuilds (`app_database.dart:177-182`). Currently zero coverage.

**Gates:** whole-project `flutter analyze` at 0 and `flutter test` green on every change (baseline
**1576 passing**, ~2min — CLAUDE.md's "~377 tests" is stale). Reconcile the two divergent `dart:io`
grep gates (`tool/build_web.sh:41` directive-anchored vs `.github/workflows/ci.yml`'s naive
substring) onto the stricter one, and evaluate promoting the `web-build` job off
`continue-on-error: true` (`ci.yml:39`).

---

## Out of scope

- Building a real outbox (D-4) — a possible follow-up once offline works end-to-end.
- Any export/download/backup UI (D-2). Note `BackupRepository.exportSnapshot()`
  (`backup_repository.dart:45`) and `CloudBackupService` are fully implemented and tested but have
  **no caller outside `lib/features/backup/`**; leaving them unwired is a deliberate consequence of
  D-2, and the duplication with `SyncService`'s photo logic remains a known divergence risk.
- Downscaling photos (D-5).
- Multi-tab leader election (L8's race half) — the lock-in half is addressed in §1a.
- Pagination of the pull path (S7's `fetchSharedTopos` global select) beyond what `dirty` gives the
  push path.
- Offline sign-in for a user who has never signed in on the device.
- `wifiOnly` becoming user-facing (S4) — it stays a defaulted-off internal setting.

## Open questions (need a device/browser measurement, not a decision)

1. What storage backend does live `climb-masi.pages.dev` actually resolve to on iOS Safari (tab **and**
   installed PWA), Chrome/Android, and desktop Chrome? Never observed. **This single measurement
   decides whether L1 is theoretical or live** — §2c makes it observable, and it should be the first
   thing checked after Stage 1 deploys.
2. Is the deployed origin genuinely cross-origin isolated at runtime? Only `_headers`' *presence* is
   verified; Cloudflare path-specificity resolution is asserted only in a comment
   (`web/_headers:52-57`).
3. Do existing installs already hold `climbtopo` in IndexedDB rather than OPFS? If so they are pinned
   there until §1a's `moveExistingIndexedDbToOpfs` ships.
4. Has any browser DB ever been upgraded through v2→v8? All coverage is Dart-VM/`NativeDatabase`.
5. Does the live project have a PostgREST max-rows cap? Zero pagination anywhere means silent
   truncation (S7).
6. Has a real device already hit `QuotaExceededError` in `importPhoto`? It is swallowed today, so it
   would present as "my photo shows a placeholder" and may be happening unreported.

## Docs to correct as part of this work

- `CLAUDE.md`: "outbox push/pull" — there is no outbox (S8); and "~377 tests" — the baseline is 1576.
- `CLAUDE.md`: the web verification loop's claim that `web_smoke_test.dart` proves drift-on-WASM
  persistence — it asserts nothing.
- `docs/web-port-backlog.md:27-32`: stale, the `visibilitychange`/`pagehide` push flush exists.
- `WEB_PERF_AUDIT.md:86`: records `canvaskit/` as 7.2 MB; it is 37 MB in the current build.
