# Web Offline Stage 1 (Data Safety) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make it impossible for the masi PWA to silently lose, hide, or fail to sync a topo recorded offline.

**Architecture:** Six workstreams over the existing local-first stack. The sync engine keeps its full-state re-push design (decision D-4 — it is already idempotent and loss-proof; its defects are *scheduling* and *honesty*, not the core), gaining per-table failure reporting, a real reachability probe, connectivity-triggered retry with bounded backoff, and a `dirty` flag that finally means something. The web storage layer stops discarding drift's backend verdict and refuses to pretend an in-memory database is durable. Local data ownership stops depending on a live network session. Photos stay full-resolution (decision D-5), so quota failures must surface loudly instead of creating pixel-less rows.

**Tech Stack:** Flutter 3.44.2 · Dart 3.12.2 · Riverpod v3 (`flutter_riverpod` 3.3.2) · drift 2.34.2 (`WasmDatabase` on web, `NativeDatabase` on native) · Supabase (`supabase_flutter`, `gotrue`, `storage_client`) · `connectivity_plus` 7.3.0 · `http` ^1.6.0 · `web` (js_interop) · `idb_shim`.

**Source spec:** [`docs/superpowers/specs/2026-07-30-web-offline-reliability-design.md`](../specs/2026-07-30-web-offline-reliability-design.md)

**Detailed task fragments** (each carries the real, complete code for its tasks):

| § | Fragment | Phase |
|---|---|---|
| 1a | [`fragments/1a-storage-interlock.md`](fragments/1a-storage-interlock.md) | 1 |
| 1b | [`fragments/1b-persistent-storage.md`](fragments/1b-persistent-storage.md) | 1 |
| 1c | [`fragments/1c-a-uid-door.md`](fragments/1c-a-uid-door.md) · [`fragments/1c-b-router-rowguards.md`](fragments/1c-b-router-rowguards.md) | 1.5 |
| 1d | [`fragments/1d-honest-sync.md`](fragments/1d-honest-sync.md) | 2 |
| 1e | [`fragments/1e-scheduler.md`](fragments/1e-scheduler.md) | 3 |
| 1f | [`fragments/1f-photo-integrity.md`](fragments/1f-photo-integrity.md) | 1 (photo half) + 4 (sync half) |

**Cross-fragment reconciliation** (interface decisions, blast radius, defect list): [`fragments/reconciliation.md`](fragments/reconciliation.md). **Read it before starting any task** — it overrides any fragment that disagrees with it.

---

## Status (2026-07-31, 08:00)

Work stopped when the org's **monthly API spend limit** was reached, killing four agents mid-flight. Nothing is broken; the tree is clean and green.

**Done**
- §1b task 1 — `694e7f2` value types for the storage-persistence seam
- §1b task 2 — `02b854b` conditional-export seam over `navigator.storage`
- Gates at that point: `flutter analyze` **0 issues**, `flutter test` **1586 passing** (baseline 1576 + 10), `dart:io` directive gate empty.
- Unrelated but shipped: `14332a1` reconciled the CI `dart:io` gate with `tool/build_web.sh` (it had a false-positive substring grep that would fail on clean code).

- §1b task 3 — `e682e27` one-shot persistence controller + provider. **Independently verified: PASS.**
- §1b tasks 1–2 — **independently verified: PASS.** (D-21 confirmed handled *soundly*, not merely analyzer-clean: the `isA<JSObject>()` guard proves exactly what the `StorageManager` extension-type cast erases to at runtime. The impl also deliberately bypasses `StorageEstimate`'s non-nullable typed getters, so a browser omitting `usage` or `quota` still yields the other instead of collapsing both to null.)
- Live gates after task 3: `flutter analyze` **0 issues**, `flutter test` **1595 passing** (1576 + 19).

### ⚠ §1b task 4 now carries a load-bearing §1c requirement — do not skip it

§1c-A persists `lastKnownUid` and routes all 7 uid doors through `effectiveUidProvider`, **but it could not wire the cold-boot restore**, because `lib/main.dart` belongs to §1b task 4 which has not landed. Consequence: `lastKnownUid` is populated from the auth stream *within* a run but **is not restored across a cold boot**, so the offline-restart half of L4 remains open until this ships. §1b task 4 MUST add to the `Future.wait` in `lib/main.dart` (alongside `import 'features/account/application/auth_providers.dart';`):

```dart
container.read(lastKnownUidProvider.notifier).hydrate(),
```

It is independent of the other entries and cannot throw. Until it lands, treat L4 as only half-fixed.

### Riverpod v3 facts the fragments got wrong (apply to every remaining task)

Found while implementing §1c-A; all three will bite other fragments.

1. **`WidgetRef.listen` has no `fireImmediately` in Riverpod 3.** The fragment's `app.dart` block does not compile. The naive fix is also unsafe — the handler writes notifier state, and Riverpod forbids modifying a provider during a widget build. Correct shape: a plain `ref.listen` for subsequent emissions **plus a one-shot `Future<void>.microtask` seed from `initState`**, sharing one handler. Same deferral `database_provider.dart` already uses, consistent with the load-bearing microtask in §1a.
2. **Riverpod v3 *pauses* a provider's internal stream subscription while nothing is actively listening, and a paused subscription never delivers `done` — so `StreamController.close()` never completes.** This hung 8 tests on 30s timeouts. Reproducible with a bare `container.read(authStateProvider)` and no §1c code involved. **Any test fake that closes a controller must dispose the container BEFORE closing it.** This is a latent trap for every remaining fragment that builds a stream fake.
3. **`Override` is not exported from the `flutter_riverpod` barrel in v3.** A container helper taking overrides needs `import 'package:flutter_riverpod/misc.dart' show Override;` (as `test/main_boot_app_seam_test.dart` already does).

Also: state writes are flushed through Riverpod's own scheduler, not synchronously on assignment, so a test observing an emission *sequence* may need `container.pump()` before asserting.

**§1a hardening follow-ups (from the tasks 1–3 verify pass)**

- **`probing` is terminal if `WasmDatabase.open` itself throws — this is a hole in the interlock.** `onStorageReport` only fires on the success path, so an exception during open leaves the provider at `probing` forever, and `probing` reads as *not* ephemeral, which means **topo creation stays enabled**. It is not a durability mis-report (`isDurable` stays false) and every query would fail loudly, but the interlock's whole job is to refuse creation when storage can't be trusted, and this path evades it. **Fix:** wrap the open, and report an explicit failed verdict that counts as ephemeral, so creation is blocked. Decided: blocking creation when the database cannot even be opened is unambiguously correct.
- **`report()`'s "log before the `ref.mounted` guard" ordering is asserted by nothing.** The post-dispose test only checks `returnsNormally`, so swapping the two lines would silently drop the console line in exactly the teardown/hot-restart case §1a exists to diagnose. Add a `debugPrint` capture to that test.
- **Nothing pins `DatabaseConnection.delayed(...)` / `result.resolvedExecutor`.** The source comment explains that a bare `LazyDatabase` would discard `BroadcastStreamQueryStore` and break cross-tab `watch()`; no test or analyzer check would catch that regression. Add a line to the source guard.
- **Doc fix:** §1a's fragment Task-1 assertion still says `grep -c kDebugMode lib/core/db/connection/storage_durability.dart` is 0. It is 2 — both prose-only doc-comment lines that `df10b6d` deliberately restored. The assertion text contradicts this plan's own token-grep resolution and will read as a false failure.

**Open findings carried forward (non-blocking)**

- **For §1b task 4's implementer and verifier:** `ref.read(storagePersistenceServiceProvider)` at the head of `_request()`/`refresh()` sits **outside** any try/catch. On an already-disposed container the returned future completes with an error, which task 4's `unawaited(...)` would surface as an unhandled async error. Unreachable in the specified boot wiring (the read happens immediately after container creation), but task 4 is exactly where it *could* become reachable — verify it there.
- **Cosmetic, fold into §1b task 4's commit:** `test/core/storage/storage_persistence_providers_test.dart` carries an `// ignore: unused_element_parameter` on the fake's `estimateSnapshot` constructor parameter. The narrowest fix is to delete that parameter and initialise the mutable field directly — `StorageEstimateSnapshot? estimateSnapshot = const StorageEstimateSnapshot(usageBytes: 1024, quotaBytes: 8192);` — which removes the suppression with byte-identical behaviour. Note the sibling `persisted` parameter **must** keep its constructor form (one test passes `persisted: false`). Also note the diagnostic is an **SDK-level analyzer warning**, not a `flutter_lints` rule as the commit implies.
- **Plan bug, §1b task 3 assertion 7:** it asserts `grep -rn 'StateProvider' lib/core/storage` is empty, which the plan's own prescribed code cannot satisfy — that code contains the string in a doc comment ("never `StateProvider`"). The substance (no `StateProvider` *usage*) passes. Anyone re-running that assertion literally will see a false failure.

**Plan fragments — three are not yet converted**
- Corrected and ready: `1a-storage-interlock.md` (1898 lines), `1b-persistent-storage.md` (1599), `1c-a-uid-door.md` (1681), `1c-b-router-rowguards.md` (1701).
- **`1d`, `1e`, `1f` exist only as raw planner JSON** under [`fragments/raw/`](fragments/raw/) — their conversion agents died before writing markdown. The JSON holds complete, real code, but **the reconciliation corrections have NOT been applied to it**. Do not implement from the raw JSON directly. Convert it first, applying every correction listed in "Blocking corrections that override the fragments" below plus the per-fragment items in `reconciliation.md`. The exact conversion briefs used for `1a`/`1b` are the model to follow.

**Next action:** convert `1d`/`1e`/`1f`, then resume the execution order below at position 2 (§1a).

---

## Global Constraints

Every task's requirements implicitly include this section.

**Toolchain**
- Homebrew Flutter: PATH does **not** persist between shell calls. Prefix EVERY flutter/dart command with `export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && `.
- iOS uses Swift Package Manager. There is intentionally no `ios/Podfile`. Never run `pod install`.

**Gates — every task, no exceptions**
- `flutter analyze` → **0 issues**. Verified baseline: `No issues found!`
- `flutter test` → **green**. Verified baseline: **1576 passing**.
- Assert **"baseline + N for this task"**, never an absolute test total. Every fragment was written assuming sole occupancy of the repo, so all absolute counts in them (1583, 1584, 1590, 1598, 1599, 1604, 1606) are wrong by construction (reconciliation D-13).
- The `dart:io` gate must stay green: `grep -rlE "^[[:space:]]*(import|export)[[:space:]]+['\"]dart:io['\"]" lib --include="*.dart" | grep -v '_native.dart'` must be empty. This is **directive-anchored on purpose** — the naive substring form matches the 35 doc comments that legitimately explain the wasm split and can never be empty. The regex is byte-identical in `tool/build_web.sh:40` and `.github/workflows/ci.yml` (reconciled by commit `14332a1`).

**Riverpod v3**
- Use `Notifier` / `NotifierProvider(X.new)`. **Never `StateProvider`** — in the resolved 3.3.2 it exists only behind `package:flutter_riverpod/legacy.dart`, which nothing in the repo imports, so introducing one would not even compile against existing imports. Verified: zero occurrences in `lib/`.
- `ref.mounted` is available in 3.3.2 and is the correct guard for post-await provider writes.
- A provider may **not** modify another provider during its own initialization. Where a synchronous callback would do so, the `Future<void>.microtask(...)` wrapper is **load-bearing** — do not simplify it away (reconciliation D-20).

**Platform splits**
- Conditional export, **never `kIsWeb`**, for anything touching `dart:io`:
  ```dart
  import 'x_stub.dart' if (dart.library.io) 'x_native.dart' if (dart.library.js_interop) 'x_web.dart';
  ```
- `_native.dart` files hold existing code verbatim — **iOS/Android behaviour must stay bit-identical**. `kIsWeb` is reserved for behavioural gates on web-capable plugins.
- Suffixes in use: `_stub.dart` (default), `_native.dart` (`dart.library.io`), `_web.dart` (`dart.library.js_interop`). No `_io.dart`/`_vm.dart` convention exists — do not invent one.

**Dependencies**
- `fake_async` is **transitive-only** (`pubspec.lock:316`). Do not import it — `depend_on_referenced_packages` would fire, and adding it to `pubspec.yaml` would collide with every other workstream (reconciliation D-18). Use the existing time seams instead: `syncDebounceDurationProvider` and `nowMsProvider`.
- Do not add or bump any dependency in this stage.

**Testing rules**
- Never drive a real image-codec decode of `TopoCanvas` in a widget test — it hangs under fake-async. Use the injected `imageSize` / `TopoCanvasBody` harness. (Note: `_handleNewTopo`'s real `instantiateImageCodec` *is* permitted, because the existing A6 group in `topos_screen_test.dart` already does exactly that with `tester.runAsync` + `_drain`; that is not the prohibited canvas decode — reconciliation D-19.)
- Reuse the existing fakes and helpers; do not invent parallel ones. Named in each fragment's Conventions section.
- No wall-clock-budget assertions on retry counts. Assert requested attempt numbers, not completions inside a `Future.delayed` window (reconciliation D-17).

**UI**
- **All icons must use the `MasiIcon` widget** (80 SVGs at `assets/icons/masi/`). Never introduce `Icons.X` or `CupertinoIcons.X`. This applies to §1a's storage-warning banner and §1f's failure SnackBars — check the fragment code and substitute a `MasiIcon` if a Material icon slipped in.

**Version control**
- Commit after every task that clears its verify gate. One logical change per commit. Conventional messages: `type(scope): summary`.
- End every commit message with: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
- Commit straight to `main`. **Never push to a remote. Never open a PR.**
- Never commit secrets. Never touch `~/.config/climbtopo-mgmt-token`.

**Out of bounds for this stage**
- Do not build or install to the physical iPhone. AR/camera and the "which storage backend does iOS Safari actually pick" measurement require the human.
- Do not modify anything under `ios/` — there is uncommitted AR work in the tree (`ios/Runner/AR/*`, `ios/Runner.xcodeproj`, `docs/superpowers/plans/2026-07-28-ar-placement-engines.md`). Leave it alone.
- Do not downscale photos (decision D-5). Do not add export/download UI (decision D-2). Do not build an outbox (decision D-4).

---

## Execution phases

Ordering is forced by three facts: **§1d owns** the `SyncRemote.upsertOwnRows` signature change and the `PushSyncResult` shape that §1e and §1f both extend; **§1e owns** the `pushOwn` snapshot/dirty-scoping that §1f's reorder sits on top of; and **§1a owns** the structurally larger `topos_screen.dart` diff that §1f's localized catch nests inside.

### Phase 1 — three independent trees, fully parallel

Strictly file-disjoint; safe to run concurrently.

- **§1a** tasks 1–5 (storage-durability model → provider → OPFS move → interlock UI → browser proof)
- **§1b** tasks 1–5 (persistence value types → seam → provider → boot wiring → browser proof)
- **§1f photo half** tasks 1–6 (`PhotoWriteException` → propagate the byte-write failure → no orphan `Photos` row → SnackBar → canvas wiring → Topos-home wiring)
- **§1e orphan leaves** — two tasks with no dependency on Phase 2: `importSnapshot` never marks an imported row dirty (`backup_repository.dart`), and the new `sync_retry_schedule.dart`.

**Only intra-phase constraint: §1a task 4 must land before §1f's Topos-home task** (both modify `topos_screen.dart` + `topos_screen_test.dart`).

### Phase 1.5 — §1c (auth/uid), serialised

§1c was commissioned separately (the original planner exceeded its output limit). It must land before Phase 2 and must be serialised against: §1b's boot-wiring task (`lib/main.dart`), §1e's dirty-write task and §1f's orphan-row task (`library_crud_repository.dart`), and §1a task 4 / §1f's Topos-home task (`topos_screen*`). Its `toposProvider` change lands in `lib/features/library/application/library_providers.dart`, which no other fragment touches.

**§1c fixes the only Stage-1 bugs that affect native *today*** — the hard-sign-out silent write loss (L4) and the library silently emptying to "No topos yet" on an auth-stream error. Do not defer it.

### Phase 2 — §1d in full, strictly serial

Nothing else may touch `lib/features/backup/**` or `test/app/app_test.dart` during it. §1d changes an abstract-class signature with a 6-declaration blast radius (see reconciliation) — it must land as a coherent unit.

### Phase 3 — §1e, strictly serial, on top of Phase 2

### Phase 4 — §1f sync half, strictly serial, on top of Phase 3

**Never run in parallel:** any two of {§1d, §1e, §1f-sync}; §1a task 4 with §1f's Topos-home task; §1e's dirty-write task with §1f's orphan-row task.

### Actual execution order used (supersedes the phase grouping above)

The phase grouping describes what is *theoretically* parallelisable. In practice **everything runs sequentially in the main working tree**, for a reason file-disjointness does not cover: **the git index is shared state.** Two implementers that touch no common file can still corrupt each other's commits, because `git add` by one and `git commit` by the other interleave through the same index. Parallelism would require `git worktree` isolation per implementer plus a merge step; the serial cost is dominated by Phases 2–4, which are strictly serial regardless.

1. **§1b tasks 1–3** — persistence value types, seam, provider (new files under `lib/core/storage/`)
2. **§1a tasks 1–5** — storage-durability model → provider → OPFS move → interlock UI → browser proof
3. **§1c-A tasks 1–4** — `lastKnownUid` + uid-door unification
4. **§1c-B** — router fail-open + affected-row-count guards
5. **§1b tasks 4–5** — boot wiring (`lib/main.dart`) + browser proof
6. **§1f photo half** tasks 1–6
7. **§1d** in full (Phase 2)
8. **§1e** (Phase 3)
9. **§1f sync half** (Phase 4)

**Newly discovered collisions** (not in the reconciliation, which was written without §1c):

- **`lib/core/db/database_provider.dart`** — §1a task 2 adds the `storageDurabilityProvider` wiring; §1c-A adds `settingsStoreProvider`. §1a goes first; §1c-A lands on top.
- **`test/core/db/*`** — §1a adds three new test files; §1c-A modifies `app_database_test.dart`. No overlap, but same directory.
- **`lib/main.dart`** — §1b task 4 is the only other claimant besides a possible §1c wiring point; §1b tasks 4–5 are deliberately deferred to position 5 so §1c lands first.

### §1c-A requires a drift schema migration (v8 → v9)

Recorded here because it is the largest structural surprise in Stage 1 and other implementers will trip over it. There is **no `shared_preferences` dependency** (absent from `pubspec.yaml`, zero grep hits) and **no settings/KV table** — the repo's only "setting", `WifiOnlySetting`, persists nothing. So `lastKnownUid` has nowhere to live.

Chosen mechanism: a local-only `AppSettings` drift table at **schemaVersion 8 → 9**, a pure `m.createTable` mirroring the v7→v8 `Profiles` addition. It is deliberately **not** a `SyncColumns` table and is absent from `syncTableNames` and `BackupRepository`'s hand-enumerated lists, so it never syncs and needs no Supabase migration (the schema-parity test is unaffected). Rejected alternatives: adding a dependency (barred by Global Constraints, and a new dep for one string is disproportionate); a `window.localStorage` + native-file conditional-import seam (a whole new platform seam for one string, where drift already works identically on both platforms).

Consequences the implementer must handle:
- A `build_runner` run to regenerate `app_database.g.dart`.
- Edits to `test/core/db/app_database_test.dart` (the schema-version constant and the onCreate table-set assertion).
- Every migration branch in `app_database.dart` is `if (from < N)` with **no `from > to` guard** (audit L7). Adding v9 slightly widens that surface. It stays low-risk while `web/_headers` is `no-cache`, but it makes Stage 2's downgrade guard and browser-executed migration coverage more load-bearing, not less. Do not add the guard here — it ships with Stage 2's service worker, which is what makes a stale shell possible in the first place.

---

## Blocking corrections that override the fragments

The fragments were written independently and five of these would break the build or reintroduce a spec-level bug. Each fragment file has them applied inline; they are restated here because a task's implementer may read only one fragment.

0. **`_clearDirty` must be narrowed to tables that actually landed — THE most dangerous defect found, and it would have caused the very data loss this project prevents.** §1d wraps `upsertOwnRows` in try/catch and converts a throw into an all-tables-`failed` *result*; it **no longer throws**. §1e's unconditional `await _clearDirty(tablesToRows)` therefore clears `dirty` for rows that never reached the cloud. Since `dirty` is what drives "retry until clean", those rows would never be pushed again — an offline edit would be silently and permanently discarded, with the UI reporting success. Narrow the clear to the tables whose outcome is `ok`. Reconciliation decision #14 restates the plain call and misses this; §1e's own risks list flagged it only as a future note. Two knock-on fixes travel with it: a §1e test asserting `pushOwn()` *throws* can never pass post-§1d (rewrite as a result assertion plus a dirty-survival check), and `_scheduleRetry()` must be armed on the returning `!fullyLanded` path as well as in `catch` — post-§1d the dominant failure is a returned result, not an exception, so the retry loop was dead for per-table rejections.

1. **`fullyLanded` must include `photosFailed`** (reconciliation D-2, highest severity). §1d defines `fullyLanded => didPush && rowsFailed == 0 && errors.isEmpty`, and it is the *sole* gate the orchestrator uses for `idle` + a fresh `lastSyncedAt`. §1f withholds a failed photo's row *from* the push, so `rowsFailed` stays 0 — meaning a push where **every photo's bytes failed** would report success and render "Synced • just now". That is precisely the S1 lie §1d exists to kill, re-entering through the photo path. Final form, owned by §1f: `bool get fullyLanded => didPush && rowsFailed == 0 && errors.isEmpty && photosFailed == 0;` with `lastPushError` concatenating `errors + photoErrors`. `photosMissingLocalBytes` is **deliberately excluded** — it is non-retryable, and including it would stop §1e's retry loop from ever terminating.
2. **Three §1e test doubles will not compile after §1d.** `_ThrowingUpsertRemote` → delete, use §1d's public `ThrowingUpsertSyncRemote`. `_MidPushWriteRemote` and `_OfflineToggleSyncRemote` → retype to `Future<List<TablePushOutcome>>`.
3. **§1f's `wallVisibility` derivation is wrong under dirty scoping.** Deriving it from the dirty-filtered `walls` list silently stops uploading the shared copy of a new photo on an already-pushed shared wall. Consume §1e's `selectOnly` projection over *all* own walls.
4. **§1f's `FakeSyncRemote.upsertOwnRows` patch drops §1d's return value**, producing a non-`void` method with no `return`. Rewrite against the post-§1d body.
5. **§1d's `connectivity_service.dart` block has three elisions** (`// ... unchanged ...`) and would not compile; §1d's `SyncOrchestratorState` block elides a real 16-line doc comment. Both must be written out in full.
6. **§1d tasks 3 and 4 both declare `errors`/`rowsFailed`** in different places, yielding a duplicate-declaration error if split across engineers. Task 3 declares them where task 4 wants them.
7. **All four `app_test.dart` containers need the `connectivityServiceProvider` override**, not the two named — `_makeContainer` (`:148`) and the inline container (`:318`) were missed. Benign under §1d alone, fatal under §1e's unconditional `statusChanges()` listener.
8. **`ConnectivityService` gains two members from two fragments** — `isBackendReachable()` (§1d) and `statusChanges()` (§1e). Added once each; neither fragment may re-declare the abstract class wholesale. All four fakes need both.

### Amendments found during §1d's conversion (supersede `reconciliation.md`)

9. **The merged connectivity fakes must NOT carry `@override` on `statusChanges()` yet.** Reconciliation decisions #4/#5 have §1d write the four fakes as the union with §1e's additions — but as written that fails `flutter analyze`, because a fake cannot `@override` an abstract member that does not exist until §1e declares it. §1d omits the annotation; **§1e's task adds `@override` to all four fakes** when it declares the abstract member.
10. **`classifyConnectivityResults` is extracted by §1d, not §1e.** Reconciliation decision #3 assigned the extraction to §1e, but §1d rewrites `connectivity_service.dart` first and must leave it compiling, so the extraction physically lands in §1d's task 6. §1e's task 7 is correspondingly reduced to adding `statusChanges()` plus the `@override` annotations from item 9.
11. **§1d's task 1 adds 5 tests, not the 7 it claims** (same class of error as D-15), so §1d adds **28** tests in total, not 30. Gate on green, not on counts.
12. Line-number drift corrected during conversion: `app_test.dart:506` → `:505`; `account_screen_test.dart:785/:786` → `:786/:787`; `nowMsProvider` is `database_provider.dart:24` (not `:23`); the `SyncStatus.offline` doc is `:26-29` (not `:25-29`).

### Amendments found during §1e/§1f conversion

13. **`_clearDirty` must be narrowed to *landed* tables — reconciliation decision #14 is wrong.** #14 writes the final step as a plain `_clearDirty(tablesToRows)`, which would mark rows from tables that **failed** to push as clean, i.e. silently treat unsynced rows as synced. §1e narrows it to landed tables only; §1f adopts §1e's narrowed form everywhere its composed blocks show a dirty-clear. This is a data-integrity bug, not a style point.
14. **§1e already arms `_scheduleRetry()` on the not-fully-landed branch.** §1f's orchestrator edit is therefore scoped down to the `lastPushError` interpolation alone (`[...result.errors, ...result.photoErrors].join('; ')`) — it must NOT add a second retry call.
15. **§1f's `_makeContainer` block silently reverted §1a's `storageDurability` parameter.** Restored during conversion (reconciliation decision #7). Watch for this when applying §1f's Topos-home task.
16. **The `.list(` invariant is "zero un-paged listings", not a count.** There are three call sites (`sync_remote.dart:638`, `:668`, `backup_remote.dart:159`), not the two D-14 claims — and post-fix the two `sync_remote.dart` sites collapse into one `_listAllObjects`, so a numeric assertion would be wrong either way. D-14's claim that §1f's final task repeats the bad count is also false; both occurrences are in the pagination task.
17. **§1f's web-backend task claims 8 tests; the file has 7.** Same class as D-15/item 11. Gate on green, never on counts.
18. **`app_test.dart`'s `_CountingSyncRemote` has only `pullCallCount`** (it is at `:30`, not the cited `:34`), but §1e's app-resume task reads `remote.pushCallCount` twice — a compile error. The field and its increment must be added.
19. **`widget_test.dart` has a SECOND un-overridden `MasiApp` mount at `:2119`**, which the reconciliation's "One caveat" missed. It matters for the same reason as the others: after §1e's task 8 the orchestrator's `build()` unconditionally subscribes to `statusChanges()`, so an un-overridden mount constructs the real `SystemConnectivityService`.
20. **§1e's whole-file re-emit of `connectivity_service.dart` would have deleted §1d's `isBackendReachable()` and its third positional parameter.** Restructured into four surgical additions. Any "re-emit the whole file" step in a later fragment is a red flag for exactly this.
21. Counts corrected: `library_crud_repository.dart` has **17** `dirty: const Value(true)` sites (→ 29, not 18 → 30); repo-wide **35**, not 30. §1e adds **31** tests, not ~25. Load-bearing line drift: `SyncPushOutcome` `:11` not `:10`; `app_test.dart` resume group `:385-555` not `:390-479`; `SyncRemote` `:80`, `SupabaseSyncRemote` `:347`, `_UnavailableSyncRemote` `:65` (all three also wrong in `reconciliation.md`).
22. **D-17's flake is fixed properly, not weakened.** §1e's retry test now drives eight explicit awaited `pushNow()` calls against a 1-hour fixed schedule and asserts the exact requested attempts `[1…8]` — clock-free and *stronger* than the original `length > 5`. Only the "no user action required" test stays timer-driven, since that property is its actual subject; it gets a widened 10 ms/250 ms margin plus a 20×-rerun step.

### Token-grep assertions keep misfiring — fix the guard, not the prose

Three separate instances now, all the same shape: a source-scan assertion greps for a bare token, and legitimately-written prose that *mentions* the token fails it.

1. The CI `dart:io` gate matched 35 doc comments explaining the wasm split. **Fixed** in `14332a1` by anchoring on import/export *directives*.
2. §1b task 3's assertion 7 greps `StateProvider` in `lib/core/storage`, which the plan's own doc comment ("never `StateProvider`") cannot satisfy.
3. §1a task 3's guard asserts **zero `kDebugMode` anywhere under `lib/`**, which collides with §1b's release-logging doc comment that names the token to explain why the log is *not* gated on it.

**Resolution:** the guard must match real usage — `if (kDebugMode)` / an actual reference in code — and must exclude comment lines, exactly as the `dart:io` gate now does. Rewording good comments to dodge a grep is the wrong layer and degrades the code: during §1a's implementation, §1b's comment was silently edited from naming `kDebugMode` to the vaguer "debug-only build flag" purely to satisfy the scan. **Restore that comment and tighten §1a's guard** as a follow-up. Apply the same rule to any further source-scan assertion in this plan.

---

## Per-task verify gate

Per the project's working discipline, **the agent that writes a task never verifies it.** After each task:

1. The implementer runs its own steps, `flutter analyze`, and `flutter test`, then commits.
2. A **separate, clean-context** verifier receives only (a) that task's `**Assertions:**` block, (b) `git show` of the commit, and (c) the Global Constraints above. It re-runs the assertions independently and reviews adversarially. It has **no** knowledge of the implementer's reasoning.
3. "Done" requires the verifier's verdict. If the verifier rejects, the fix goes back to a fresh implementer with the verifier's findings.

Verifiers must be **read-only on `lib/`** and are forbidden from running any build or install command (a review agent once overstepped, edited source on its own opinion, and installed a wrong-team build to the phone).

---

## Definition of done for Stage 1

- All tasks across §1a–§1f complete and independently verified.
- `flutter analyze` 0; `flutter test` green at ≥ 1576 + the new tests.
- The web verification loop passes: `tool/drive_web.sh integration_test/web_smoke_test.dart` boots and the new browser-executed tests (§1a task 5, §1b task 5) assert real facts.
- Every spec §1a–§1f assertion has a passing test. The reconciliation's coverage table lists five §1c assertions and one reload-persistence assertion that had no owner — §1c's fragments close the first five; the reload-persistence test is tracked below.
- The stale docs are corrected (§1f's final task): CLAUDE.md's "outbox push/pull" (there is no outbox), "~377 tests" → 1576, and the claim that `web_smoke_test.dart` proves drift-on-WASM persistence (it contains zero `expect()` calls).

## Carried to Stage 2 (not in scope here)

- **Reload-persistence integration test with real assertions** — no owner in Stage 1. §1a task 5 asserts the backend is not `inMemory`, which is adjacent but not a write→reload→assert test. Stage 2's service worker makes a stale shell possible for the first time, so this belongs with it, alongside the `from > to` migration downgrade guard (audit L7) and browser-executed v1→v8 migration coverage.
- `docs/web-port-backlog.md:27-32` is stale (the `visibilitychange`/`pagehide` push flush exists); `WEB_PERF_AUDIT.md:86` records `canvaskit/` as 7.2 MB when it is 37 MB.

## Needs the human (queued, cannot be done unattended)

1. **Which storage backend does live `climb-masi.pages.dev` actually resolve to** on iOS Safari (browser tab *and* installed PWA), Chrome/Android, and desktop Chrome? Never observed — the verdict print is `kDebugMode`-only today. §1a makes it release-visible; this single measurement decides whether the silent in-memory total-loss path (L1) is theoretical or live.
2. **Is the deployed origin genuinely cross-origin isolated** (`crossOriginIsolated === true`)? Only the presence of `web/_headers` is verified; Cloudflare path-specificity is asserted only in a comment.
3. **Do existing installs already hold `climbtopo` in IndexedDB rather than OPFS?** If so they are pinned there until §1a's `moveExistingIndexedDbToOpfs` ships.
4. **Is the `/auth/v1/health` reachability probe allowed** from a COEP `require-corp` page on the deployed origin (reconciliation D-22)? A blocked probe returns `false` and would make the app permanently claim "Offline" — verify before shipping §1d.
