# §1e — Sync as soon as possible (fixes S2, S3, S9, S10)

Connectivity change stream, exponential backoff with jitter, push in-flight guard, resume-push, and making `dirty` real — set on write, cleared only on a confirmed push, stripped from the pushed payload.

*Rendered from the §1e plan fragment (`raw/1e-scheduler.raw.json`) with the §1e-relevant corrections from the Stage-1 reconciliation pass (`reconciliation.md`) applied, plus four further blocking defects and eight line-number drifts found while verifying every citation against the real source. Every Dart/bash code block below is byte-for-byte from the source fragment **except** where a correction required a change; each changed block carries a `> Corrected (D-N): …` line directly above it.*

**This fragment lands in Phase 3, strictly serial, on top of §1d (Phase 2).** Two of its tasks are orphan leaves runnable in Phase 1 — see [Ordering](#ordering).

---

## Reconciliation corrections applied

### Blocking — would not compile or would reintroduce a spec-level bug

- **D-3 — three test doubles here declare the old `Future<void> upsertOwnRows`.** §1d task 2 changes `SyncRemote.upsertOwnRows` to `Future<List<TablePushOutcome>>`, so all three fail to compile as written.
  - **`_ThrowingUpsertRemote` (Task 4) — DELETED entirely.** §1d task 3 introduces a public `ThrowingUpsertSyncRemote` in the *same file* (`sync_service_test.dart`) with the correct signature; Task 4's test uses that instead. Note its thrown message is `'upsertOwnRows boom'`, not §1e's `'upsertOwnRows failed: simulated network error'` — any assertion on the message text must follow §1d's.
  - **`_MidPushWriteRemote` (Task 4) — retyped** to `Future<List<TablePushOutcome>>`. Reconciliation's literal instruction is `return await super.upsertOwnRows(...)`, but that would strand the `onPush()` call that is the entire point of the double. The correct composition captures the outcomes, runs `onPush()`, then returns them — written out in Task 4.
  - **`_OfflineToggleSyncRemote` (Task 6) — retyped** to return outcomes when online. Constructor used: **`TablePushOutcome.ok({required String table, required int rowsUpserted, int rowsSkippedNewerRemote = 0})`** — the `const` "ok" constructor from §1d task 1 (`sync_remote.dart`), with `rowsSkippedNewerRemote` left at its default. This is byte-identical in shape to §1d's own `_FailingPushSyncRemote`/`_CountingSyncRemote` outcome literals (`TablePushOutcome.ok(table: entry.key, rowsUpserted: entry.value.length)`), so the two files stay consistent. The alternative — `TablePushOutcome.failed({required String table, required int rowsFailed, required Object error})` — is used only for the offline branch, and there the double throws instead, which §1d's `pushOwn` converts to failed outcomes for us.

- **D-25 (NEW — not in `reconciliation.md`; the most dangerous defect in this fragment).** After §1d task 3, **`pushOwn` no longer throws when the row push fails.** §1d wraps `_remote.upsertOwnRows(...)` in a `try`/`catch` and converts a whole-call throw into an all-tables-`failed` `PushSyncResult`. This fragment's `await _clearDirty(tablesToRows);` is unconditional and was designed on the assumption that "the push completed without throwing" == "everything landed". Applied literally on top of §1d it would **clear `dirty` for every row of every table that failed to reach the cloud** — silently and permanently losing exactly the offline edits this entire workstream exists to protect, and doing so *more* destructively than the pre-fix code (which at least never claimed a row was clean). The clear is therefore narrowed to the tables whose `TablePushOutcome.ok` is `true`. The fragment's own risk list anticipated this as a future note ("*When 1d lands, narrow T4's clear from `tablesToRows` to `tablesToRows` minus 1d's failed-table set*"); because §1d lands **first** in the reconciled order, it is a required change here, not a note. Reconciliation decision #14 restates the composed ordering with a plain `_clearDirty(tablesToRows)` and does not catch it.

- **D-26 (NEW).** Following from D-25: Task 4's third test asserts `await expectLater(c.service.pushOwn(), throwsA(isA<Exception>()));`. Post-§1d `pushOwn` returns normally with `rowsFailed > 0`, so this assertion can never pass. Rewritten as a result assertion (`fullyLanded == false`, `rowsFailed == 1`, `errors` mentions the error) followed by the real subject of the test — that `dirty` is still set.

- **D-27 (NEW — compile error).** Task 9's new `testWidgets` reads `remote.pushCallCount` twice, but `test/app/app_test.dart`'s file-private `_CountingSyncRemote` has **only `pullCallCount`**; its `upsertOwnRows` body is `async {}` and increments nothing (verified at `app_test.dart:30-101` — and the class starts at **:30**, not the cited `:34`, which is the `upsertOwnRows` signature line). Unlike its identically-named twin in `sync_orchestrator_test.dart:26-102`, this copy never counted pushes. Task 9 must add `int pushCallCount = 0;` and increment it. §1d task 2 owns retyping that same override (it is row 6 of reconciliation's *Signature blast radius* table), so §1e task 9 adds **only** the field and the increment — it must not restate the signature.

- **D-28 (NEW — semantic; kills the retry loop).** This fragment's `_runPush` calls `_scheduleRetry()` **only from its `catch` block**. Post-§1d the dominant failure mode is a push that *returns* with `fullyLanded == false` (a per-table cloud rejection, an expired JWT, a required-field exclusion) and never throws. Without a `_scheduleRetry()` on that branch the whole "retry until clean" mechanism is dead for the most common real failure. Reconciliation decision #15 flags the composition in prose ("*1e's failure branch must call `await _failedPushStatus()` (1d) and `_scheduleRetry()` (1e)*") but this fragment's code block does not do it. Task 6's `_runPush` is rewritten against §1d's post-task-5/7 body with the retry armed on **both** failure paths.

- **Decisions #1, #2, #3 — `connectivity_service.dart` must be patched additively, never re-emitted.** This fragment's Task 7 emits the whole file, and its `abstract class ConnectivityService` declares only `currentStatus()` + `statusChanges()` — which would **delete §1d's `Future<bool> isBackendReachable();`** — while its `SystemConnectivityService([Connectivity? connectivity, bool? isWeb])` would **delete §1d's third positional `http.Client?`**. Both are silent regressions of a task that already landed. Task 7 below is restructured as an additive patch: `statusChanges()` is *added to* the abstract class §1d already modified, the 3-positional constructor is inherited untouched, and `enum NetworkStatus` (`:7-19`, doc from `:4`) is simply not touched — which also dissolves the fragment's `// ... NetworkStatus enum unchanged (lines 4-19) ...` placeholder. This fragment **does** own extracting `classifyConnectivityResults(List<ConnectivityResult>)` as a top-level function that `currentStatus()` delegates to; per decision #3, §1d's task-6 block must not re-inline the if-chain (verified: `currentStatus`'s classification is still an inline if-chain at `:55-65`, and the 8-line web short-circuit comment at `:45-52` is preserved verbatim).

- **Decisions #4, #6 — the four connectivity fakes and `makeContainer` are written as a union ONCE, by §1d task 6/7.** This fragment's Task 7 only *extends* the four fakes with `statusChanges()`/`emit()`/`dispose()`; it must not restate `isBackendReachable`/`reachable`/`probeThrows`/`probeCallCount`. In `sync_orchestrator_test.makeContainer` (`:175-207`), §1d task 7 writes the `_FakeConnectivityService? connectivityService` parameter, the `connectivityServiceProvider.overrideWithValue(connectivityFake)` override and the `SyncService(connectivity: connectivityFake)` reuse; **this fragment appends only `SyncRetrySchedule? retrySchedule`, the `syncRetryScheduleProvider` override, and `addTearDown(connectivityFake.dispose)`. Duplicating the `connectivityService` parameter is a compile error.**

- **Decision #14 — final composed ordering inside `pushOwn`.** The end state, after all three sync fragments:

  snapshot (+ `wallVisibility`) → `_uploadOwnPhotos` (§1f) → `pushablePhotos` filter (§1f) → `tablesToRows` with dirty scoping + the required-field guard (§1d + §1e) → `upsertOwnRows` (§1d) → `_clearDirty` over the **landed** tables (§1e, per D-25) → merged result.

  **This fragment's stated rationale for clearing `dirty` after *both* phases is superseded.** Its reasoning was "clearing straight after `upsertOwnRows` would leave a row clean while its pixels are still missing". Once §1f puts the byte upload *first*, a failed byte upload keeps that photo's row out of `tablesToRows` entirely, so it **stays dirty by construction** and needs no ordering trick. `_clearDirty` still goes last, for the D-25 reason (it must see `outcomes`), not the original one. The doc comment is rewritten accordingly in Task 4. **Do NOT "restore" the old ordering** when §1f lands — §1f moves `_uploadOwnPhotos` above `upsertOwnRows` and `_clearDirty` stays at the bottom.

- **Decision #13 — this fragment's `wallVisibility` WINS.** The `selectOnly` projection over **all** own walls, read inside the snapshot transaction, is the surviving definition; §1f's `{for (final wall in walls) wall.id: wall.visibility}` derivation from the dirty-filtered `walls` list is silently wrong under `PushScope.dirtyOnly` (a new photo on an already-pushed, therefore clean, shared wall would stop getting its shared copy). **§1f task 9 consumes this fragment's `wallVisibility`; it must not rebuild it.** Note also that §1d task 3's replacement block for `pushOwn`'s tail contains that same wrong one-liner — Task 4 below **deletes** it as part of installing the `selectOnly` version.

- **Decision #12 — `_uploadOwnPhotos` keeps `Future<int>` here.** Verified: it is `Future<int>` today (`sync_service.dart:364`, with `if (photos.isEmpty) return 0;` at `:369`). §1f later changes it to a record type and rewrites this fragment's `final photosUploaded = await _uploadOwnPhotos(uid, photos, wallVisibility);` call site. **This fragment lands first**; do not pre-emptively widen the return type.

### Correctness / counts

- **D-12 — all nine `_clearDirty` table names verified present.** `profiles, areas, sectors, walls, photos, routes, ascents, comments, likes` — **9 of 9**, in that order, matching `syncTableNames` (`sync_remote.dart:34-44`) and `hasPendingLocalChanges`'s nine probes. A silently missing table would mean those rows never go clean and the retry loop never terminates for them, so the count is asserted explicitly in Task 4's assertions.

- **D-13 — every absolute test-count assertion restated as "baseline + N for this task".** The fragment's "1576 + ~25" assumed sole occupancy of the repo. **The live baseline is 1586, not 1576**, because §1b tasks 1–2 have landed (commits `694e7f2` "feat(storage): value types for the web storage-persistence seam" and `02b854b` "feat(storage): conditional-export seam over navigator.storage"). Re-measure at execution time rather than trusting either number; every gate below is "`flutter test` fully green, +N new tests for this task", never an absolute total. This fragment adds **31** tests, not ~25: 2 + 1 + 3 + 5 + 6 + 5 + 3 + 3 + 1 + 2 across Tasks 1–10.

- **D-16 — drift is 2.34.2, not 2.34.1.** Corrected in *Interfaces consumed* below. Verified `pubspec.lock:292` (`drift:`, `dependency: "direct main"`, version at `:299`). The API cited (`Expression<D>.isIn`, `extension BooleanExpressionOperators on Expression<bool>`) is identical in both.

- **D-18 — `fake_async` is transitive-only and must stay unimported.** Verified `pubspec.lock:316`, `dependency: transitive`, version 1.3.3 — not a declared dev-dependency, so importing it trips `depend_on_referenced_packages` from `package:flutter_lints`. **Recorded here so a verifier does not demand it:** avoiding it is correct, and adding it to `pubspec.yaml` would collide with every other Stage-1 workstream. The brief's real requirement — never wait out a production interval — is met and strengthened by the D-17 rewrite below.

- **Duplication #8 — the CLAUDE.md doc corrections are NOT this fragment's.** The "~377 tests" fix, the "outbox push/pull" fix and the `web_smoke_test` wording all belong to **§1f's final task**, which owns the whole doc block. The claim is struck from this fragment's risks.

### Timing — D-17, the genuine flake

The spec's Testing section says backoff tests use the injected seams, never real delays. This fragment correctly keeps the **growth law** clock-free in Task 5, but three of its orchestrator tests count *completions* inside a wall-clock budget, and one of those cannot pass reliably:

| Where | As written | Verdict | Fix applied |
|---|---|---|---|
| **Task 10, second test** | 200 ms wall-clock, then `expect(schedule.attempts.length, greaterThan(5))` | **Genuine flake.** Six full retry cycles, each running `hasPendingLocalChanges()` (nine indexed `LIMIT 1` probes), a nine-select `pushOwn` transaction and a `_clearDirty` transaction against a real `NativeDatabase.memory()`, inside 200 ms. | **Rewritten clock-free:** the retry is driven by `await notifier.pushNow()` in a loop and the assertion is on the **requested attempt numbers** — `schedule.attempts == [1, 2, 3, 4, 5, 6, 7, 8]`, exact. `pushNow()` cancels the armed `_retryTimer` on entry, so an explicitly-invoked push *is* one deterministic retry cycle; the schedule's fixed delay is set to an hour so no timer can ever interleave. No `>= 3` fallback needed — the test now asserts more than the original and cannot flake. |
| **Task 6, first backoff test** | `await Future<void>.delayed(120 ms)` then `expect(schedule.attempts.take(3), [1, 2, 3])` with a 15 ms schedule | **Tighter than it reads** — needs a 15 ms debounce plus three 15 ms retries plus four rounds of real Drift I/O in 120 ms. | Same treatment: three awaited `pushNow()` calls, `expect(schedule.attempts, [1, 2, 3])` — exact, not `.take(3)`. |
| **Task 6, reset test / termination test** | 60 ms + 60 ms + 40 ms budgets; 60 ms then 120 ms | Same defect class (counting completions in a budget; the termination test can even capture `settled` mid-flight and then fail spuriously as the in-flight push lands). | Both rewritten around awaited `pushNow()` calls. |
| **Task 8, third regain test** | `await 60 ms` then `expect(schedule.attempts, isNotEmpty)` | Weakest case — one entry in 60 ms — but still a budget for a *precondition*. | Precondition established deterministically with one awaited `pushNow()`; the regain half stays event-driven on the clock, which is what that test is actually about. |
| **Task 10, first test** | 60 ms to fail, then 150 ms to recover after `offline = false` | **Kept on the clock, deliberately.** This is the one test whose subject *is* the autonomous timer — "no user action, no further local write" is only meaningful if nothing in the test triggers the recovery. Margin widened (10 ms fixed schedule, 250 ms recovery window) and the assertions kept count-free (`greaterThanOrEqualTo(1)`, `isNotEmpty`). | Margin + rationale documented inline. |
| **Task 5** | Clock-free already — no `Timer`, no `Future.delayed`, no `fake_async` | ✅ Unchanged. | The growth/ceiling/jitter law stays the only place the arithmetic is asserted. |

### Line-number drifts found while verifying every citation

Every load-bearing anchor was checked against the real file. Eight citations had drifted; none of the drifted ones is used as an insertion point except where noted.

| Cited | Actual | Impact |
|---|---|---|
| `sync_remote.dart:86` `abstract class SyncRemote` | **:80** (`:86` is the `upsertOwnRows` declaration inside it) | Informational. Also drifted in `reconciliation.md`'s blast-radius table. |
| `sync_remote.dart:355` `SupabaseSyncRemote` | **:347** (`:355` is its `upsertOwnRows` signature) | Informational; same drift in `reconciliation.md`. |
| `sync_remote.dart:247-259` `hasRequiredSyncFields` doc | doc is **236-259** | Informational (cited as a doc-density example). |
| `sync_service.dart:10` `enum SyncPushOutcome` | **:11** (`:10` is its doc line) | **Insertion point** — `PushScope` goes immediately above the enum's doc, i.e. before `:10`. |
| `sync_providers.dart:75` `_UnavailableSyncRemote` | **:65** | Informational; same drift in `reconciliation.md`. |
| `backup_providers.dart:41` `WifiOnlySetting` | class at **:42** (41 is the doc tail) | Informational. |
| `sync_orchestrator.dart:126` / `:138` (`_pullInFlight` / `_resumePullThrottle` docs) | **:127** and **:136**; the *fields* at `:134` and `:146` are correct | Informational. |
| `photo_repository.dart:370-378` heal block | **:371-377** (the write statement `372-375` is exact) | Read-only check step; harmless. |
| `app_test.dart:34` `_CountingSyncRemote` | class at **:30** | **Insertion point** — see D-27. |
| `app_test.dart:390-479` resume group | group `#57: resumed lifecycle triggers a pull` is **:385-555**; its first `testWidgets` is **:386-479** | **Insertion point** — Task 9 appends after `:479`, which is correct. |
| `library_crud_repository.dart` — "18 → 30" `dirty: const Value(true)` | **17 today → 29** after this fragment's +12 | **Gate assertion** — corrected in Task 3. Repo-wide the count is **35**, not the fragment's "30". |

Everything else matched exactly, including all twelve `library_crud_repository.dart` write anchors, all three `route_repository.dart` anchors, all nine `fromJson` call lines in `backup_repository.dart`, both stale comments (`1325-1331`, `418-422`), the canonical companion shape (`442-447`), the local-only path heal (`667-670`), and every `sync_service.dart` / `sync_orchestrator.dart` / `connectivity_service.dart` anchor.

### ⚠️ Critical non-collision hazard — do not "simplify" the plugin probe

After **Task 8**, `SyncOrchestrator.build()` unconditionally executes:

```dart
final connectivity = ref.watch(connectivityServiceProvider);
_connectivitySubscription = connectivity.statusChanges().listen(_onConnectivityChanged, onError: ...);
```

Three test sites mount `MasiApp` **without** overriding `connectivityServiceProvider`, so they construct the real `SystemConnectivityService()` (verified: `connectivityServiceProvider` is overridden by **zero** tests in the repo today):

- `test/widget_test.dart:73-81` — `ProviderScope(` at `:74`, `child: const MasiApp()` at `:79`. Overrides only `appDatabaseProvider` + `nowMsProvider`.
- `test/widget_test.dart:2116-2121` — a second mount at `:2119` with the same two overrides. **`reconciliation.md` cites only `:74` and misses this one**; the fragment's own risk list has both (`:79`, `:2119`) and is the more complete source here.
- `test/app/app_test.dart:148` (`_makeContainer`) and `:318` (inline) — neither overrides `syncServiceProvider` either, so the real `syncServiceProvider` builds and reads `connectivityServiceProvider`.

`Connectivity.onConnectivityChanged` is an **`EventChannel`**, and an EventChannel whose plugin is unregistered reports through `FlutterError.reportError` — which `testWidgets` converts into a hard failure that **no caller-side `try`/`catch` and no `Stream.onError` can intercept**. The only thing that keeps those mounts green is Task 7's **`checkConnectivity()` plugin-availability probe**: a plain `MethodChannel` call on the same plugin, which throws a *catchable* `MissingPluginException`, gating the event-channel subscription behind it.

**Do not "simplify" that probe away.** `test/widget_test.dart` is owned by no Stage-1 fragment and cannot be given the override. Separately, **all four `app_test.dart` containers must get `connectivityServiceProvider.overrideWithValue(...)`** — `:148`, `:318`, `:401-433`, `:493-517` — not the two "#57" containers §1d task 7 names (reconciliation D-6, restated in Task 9). Note this already matters at §1d time, because §1d's `_failedPushStatus()` does `ref.read(connectivityServiceProvider).isBackendReachable()` on the failure path; §1e task 8 only makes it unconditional.

---

## Files touched

| Path | Action | Responsibility |
|---|---|---|
| `lib/features/backup/data/backup_repository.dart` | modify | `importSnapshot` forces `dirty: false` on every decoded row (fixes S9's root and makes the stripped payload decodable). Add private static `_notDirty` helper; use it in all 9 `_import*` methods (verified at `:164-389`; `_importProfiles` `:164`, `_importAreas` `:185`, `_importSectors` `:206`, `_importWalls` `:227`, `_importPhotos` `:255`, `_importRoutes` `:291`, `_importComments` `:312`, `_importLikes` `:333`, `_importAscents` `:366`). |
| `lib/features/backup/data/sync_remote.dart` | modify | Add `localOnlySyncColumns` + `stripLocalOnlySyncColumns(row)` after `filterValidSyncRows` (`:317-334` today) — the single definition of "columns that never travel to the cloud" (`dirty`, `remoteId`). §1d task 1 rewrites `filterValidSyncRows`'s body into a delegation first, so anchor on the *symbol*, not the line. |
| `lib/features/backup/data/sync_service.dart` | modify | Add `enum PushScope { full, dirtyOnly }`; `pushOwn({PushScope scope = PushScope.full})` narrows its 9 snapshot selects with `& t.dirty.equals(true)` when `dirtyOnly`; strips local-only columns from each row payload; reads wall visibility via a dedicated `selectOnly` (so a dirty photo on a clean shared wall still gets its shared copy); clears `dirty` via an (id, updatedAt) compare-and-swap **over the tables §1d reported as landed** (D-25) after both the row push and the photo phase; adds `hasPendingLocalChanges()`. |
| `lib/features/backup/application/sync_retry_schedule.dart` | **create** | `SyncRetrySchedule` (deterministic `envelopeFor(attempt)` = base·2^(attempt−1) clamped to a ceiling, plus equal-jitter `delayFor(attempt)` in `[envelope/2, envelope]`) and `syncRetryScheduleProvider`. Own file so §1d's edits to `sync_orchestrator.dart` don't collide with it. |
| `lib/features/backup/application/sync_orchestrator.dart` | modify | Add `_pushInFlight`/`_pushRequestedWhileInFlight` guard + public `pushNow()`; `_consecutivePushFailures` + `_retryTimer` + `_scheduleRetry()`; `_fullResyncDue` (full-scope safety-net push on app start and connectivity regain); nothing-pending early-out in `_runPush`; retry armed on **both** §1d failure paths (D-28); connectivity-regain subscription; cancel the new timer/subscription in `onDispose`. |
| `lib/features/backup/data/connectivity_service.dart` | modify | **Additively**: add `Stream<NetworkStatus> statusChanges()` to the abstract class §1d already modified; extract `classifyConnectivityResults` as a testable top-level function and delegate `currentStatus` to it; implement `statusChanges()` in `SystemConnectivityService` — browser `online`/`offline` events on web (via the new seam), `connectivity_plus.onConnectivityChanged` on native behind a catchable plugin-availability probe. `enum NetworkStatus` and the 3-positional constructor are untouched. |
| `lib/features/backup/data/online_events.dart` | **create** | Conditional-export facade: `export 'online_events_native.dart' if (dart.library.js_interop) 'online_events_web.dart';` — two-way split modelled exactly on `lib/app/web_lifecycle.dart` (verified: that file's whole body is the two-way export at `:25-26`). |
| `lib/features/backup/data/online_events_native.dart` | **create** | `Stream<bool> onlineEvents() => const Stream<bool>.empty();` — inert on native and in plain-Dart tests. |
| `lib/features/backup/data/online_events_web.dart` | **create** | Real browser implementation: `package:web` + `dart:js_interop` only (wasm-clean, no `dart:io`, no `dart:html`); lazily adds/removes `online`/`offline` window listeners around a broadcast controller. |
| `lib/features/library/data/library_crud_repository.dart` | modify | Add `dirty: const Value(true)` to the 12 push-worthy writes that omit it today: `_insertArea` (`161-169`), `renameArea` (`183`), `_insertSector` (`262-271`), `renameSector` (`285`), `createWall` (`347-357`), `renameWall` (`375`), `attachPhotoToWall` (`606-619`), and the tombstone writes at `1286`, `1310`, `1318`, `1323`, `1361` — all twelve anchors verified exact, all twelve confirmed to set no `dirty` today. Deliberately **NOT** the local-only path heal at `667-670`. |
| `lib/features/topo/data/route_repository.dart` | modify | Add `dirty: const Value(true)` to `upsertRoute`'s insert (`73-95`) and update (`101-118`) and to `softDeleteRoute` (`205-208`) — all three verified, none marks dirty today (`grep -c` = 0), so a dirty-gated push would never see a route edit. |
| `lib/app/app.dart` | modify | The `AppLifecycleState.resumed` branch (`75-79`) also fires `pushNow()`, not only the throttled `pullNow()`. |
| `test/features/backup/data/backup_repository_test.dart` | modify | New group asserting imported rows are never dirty (both when the payload says `dirty: true` and when the key is absent entirely). Appends after `group('S3-d: lww conflict mode', …)`, which ends at `:509`. |
| `test/features/backup/data/sync_service_test.dart` | modify | `import 'dart:async';` (confirmed absent today); `FakeConnectivityService` gains `statusChanges()`/`emit`/`dispose`; new groups for payload stripping, `PushScope.dirtyOnly`, the confirmed-push dirty clear, the mid-push-write CAS race, and `hasPendingLocalChanges()`. |
| `test/features/backup/application/sync_orchestrator_test.dart` | modify | `_FakeConnectivityService` gains a controllable stream; `makeContainer` gains **only** `retrySchedule` + the `syncRetryScheduleProvider` override + `addTearDown(connectivityFake.dispose)` (§1d task 7 owns `connectivityService`); `insertArea` seeds `dirty: true`; new fakes `_OfflineToggleSyncRemote`, `_SeededPullSyncRemote`, `_RecordingRetrySchedule`; new groups for the push in-flight guard, retry/backoff, regain, S9, and the end-to-end offline→online test. Needs `import 'dart:math';` only — `dart:async` is already imported at `:1`. |
| `test/features/backup/application/sync_retry_schedule_test.dart` | **create** | Pure, clock-free tests for growth, the 5-min ceiling, jitter bounds and no-overflow at high attempt counts. |
| `test/features/backup/data/connectivity_service_test.dart` | modify | Tests for `classifyConnectivityResults` and for `statusChanges()` being inert (never emitting, never reporting a `FlutterError`) when the plugin is absent. File is 39 lines with two imports today; §1d task 6 will have added its own. |
| `test/features/backup/data/cloud_backup_service_test.dart` | modify | `FakeConnectivityService` (`:74-81`) gains `statusChanges() => const Stream<NetworkStatus>.empty();` (compile fix for the new interface member). |
| `test/app/app_test.dart` | modify | `_FakeConnectivityService` (`:132-135`) gains `statusChanges()`; `_CountingSyncRemote` (`:30`) gains `pushCallCount` (D-27); **all four** containers (`:148`, `:318`, `:401-433`, `:493-517`) override `connectivityServiceProvider`; new `testWidgets` asserting resume pushes. Needs a new `backup_providers.dart` import (confirmed absent; `sync_providers.dart` is already imported at `:10`). |
| `test/features/library/data/library_crud_repository_test.dart` | modify | Assertions that create/rename/attach/soft-delete all leave `dirty == true`. Already imports `BooleanExpressionOperators, Value` at `:8`; `group('A1: create/rename/sortOrder', …)` at `:27`; `repo` is `LibraryCrudRepository(db, nowMs: () => 1000)` at `:20`. |
| `test/features/topo/data/route_repository_test.dart` | modify | Assertions that upsert (insert + update) and `softDeleteRoute` all leave `dirty == true`. **Must add `import 'package:drift/drift.dart' show Value;`** — confirmed absent (the file's only imports are `:1-6`). |

## Interfaces produced/consumed

### Produces

- `lib/features/backup/data/sync_service.dart`: `enum PushScope { full, dirtyOnly }`
- `lib/features/backup/data/sync_service.dart`: `Future<PushSyncResult> SyncService.pushOwn({PushScope scope = PushScope.full})` — default unchanged, so every existing caller/test is behaviourally identical
- `lib/features/backup/data/sync_service.dart`: `Future<bool> SyncService.hasPendingLocalChanges()`
- `lib/features/backup/data/sync_service.dart`: `Map<String, String> wallVisibility` inside `pushOwn` — a `selectOnly` projection over **all** own walls, read inside the snapshot transaction. **§1f task 9 consumes this** (decision #13); it must not rebuild it from the dirty-filtered `walls` list.
- `lib/features/backup/data/sync_remote.dart`: `const Set<String> localOnlySyncColumns = {'dirty', 'remoteId'};`
- `lib/features/backup/data/sync_remote.dart`: `Map<String, dynamic> stripLocalOnlySyncColumns(Map<String, dynamic> row)`
- `lib/features/backup/data/connectivity_service.dart`: `Stream<NetworkStatus> ConnectivityService.statusChanges();` — new abstract member, **added to** the class §1d already modified; every implementer must add it (all four fakes use `implements`, so a concrete default would not help)
- `lib/features/backup/data/connectivity_service.dart`: `NetworkStatus classifyConnectivityResults(List<ConnectivityResult> results)` — top-level, `currentStatus()` delegates to it
- `lib/features/backup/data/online_events.dart`: `Stream<bool> onlineEvents()` (conditional-export facade)
- `lib/features/backup/application/sync_retry_schedule.dart`: `class SyncRetrySchedule { SyncRetrySchedule({Duration base = const Duration(seconds: 2), Duration ceiling = const Duration(minutes: 5), Random? random}); Duration envelopeFor(int attempt); Duration delayFor(int attempt); }`
- `lib/features/backup/application/sync_retry_schedule.dart`: `final syncRetryScheduleProvider = Provider<SyncRetrySchedule>(...)`
- `lib/features/backup/application/sync_orchestrator.dart`: `Future<void> SyncOrchestrator.pushNow()` — public, in-flight-coalescing; **the single funnel for every push trigger** (debounce timer, `onAppPaused`, `_scheduleRetry`, `_onConnectivityChanged`, and `app.dart`'s resume branch = five triggers)
- Reshaped shared test helpers other workstreams should build on rather than duplicate: `makeContainer` (`sync_orchestrator_test.dart:175-207`) gains `retrySchedule` on top of §1d's `connectivityService`; `insertArea` (`:209-219`) now seeds `dirty: true`.

### Consumes

- `lib/features/backup/application/sync_orchestrator.dart:92` `syncDebounceDurationProvider` — existing time seam, reused unchanged ✅ verified
- `lib/features/backup/application/sync_orchestrator.dart:134` `_pullInFlight` (doc `127-133`) / `:146` `_resumePullThrottle` (doc `136-145`) / `:254` `pullNow({bool throttled})` — the pull-side guard the new push guard mirrors
- `lib/features/backup/application/sync_orchestrator.dart:159` `db.tableUpdates().listen((_) => _scheduleDebouncedPush())` ✅
- `lib/features/backup/application/sync_orchestrator.dart:189-194` `_scheduleDebouncedPush()`; `:199-202` `onAppPaused()`; `:204-220` `_runPush()`; `:327` `_now()` — all four ✅ exact
- **§1d's post-task-5/7 `_runPush`** — `switch (result.outcome)` with the `result.fullyLanded` gate, the explicit `SyncOrchestratorState(...)` constructor (not `copyWith`), `lastPushError`, and `await _failedPushStatus()` on both failure paths. §1e layers `PushScope` selection, the nothing-pending early-out and `_scheduleRetry()` onto it.
- **§1d's `TablePushOutcome`** (`sync_remote.dart`, immediately before `abstract class SyncRemote` at `:80`) — `const TablePushOutcome.ok({required String table, required int rowsUpserted, int rowsSkippedNewerRemote = 0})`, `TablePushOutcome.failed({required String table, required int rowsFailed, required Object error})`, fields `table`/`rowsUpserted`/`rowsSkippedNewerRemote`/`rowsFailed`/`error`, getter `bool get ok => error == null;`
- **§1d's `ThrowingUpsertSyncRemote`** (`sync_service_test.dart`, public, throws `Exception('upsertOwnRows boom')`) — replaces this fragment's deleted `_ThrowingUpsertRemote`
- **§1d's `PushSyncResult`** — `rowsFailed`, `errors`, `fullyLanded`, and the `outcomes` local in `pushOwn` that `_clearDirty`'s narrowing reads (D-25)
- **§1d's `ConnectivityService.isBackendReachable()`** and the 3-positional `SystemConnectivityService([Connectivity?, bool?, http.Client?])` — inherited untouched (decisions #1/#2)
- **§1d's union fakes** — `_FakeConnectivityService(this.status, {this.reachable = true, this.probeThrows = false})` with `probeCallCount`. `reachable` defaulting to **true** is load-bearing for this fragment: it is why a failed push in §1e's tests classifies as `SyncStatus.error` rather than `SyncStatus.offline`.
- `lib/features/backup/application/backup_providers.dart:35-37` `connectivityServiceProvider` ✅ — overridden by **no** test in the repo today; becomes a primary override point
- `lib/features/backup/application/sync_providers.dart:155-179` `syncServiceProvider` ✅; `:65` `_UnavailableSyncRemote` (cited `:75` — drifted)
- `lib/core/db/database_provider.dart:24-27` `nowMsProvider` — existing clock seam ✅
- `lib/core/db/tables.dart:20-21` `remoteId` / `dirty` columns ✅ — `BoolColumn get dirty => boolean().withDefault(const Constant(false))();` confirmed verbatim; doc at `:8`
- `lib/features/backup/data/sync_service.dart:265-275` the single-transaction 9-table own-row snapshot read ✅; `:288-336` `tablesToRows` + the nine `filterValidSyncRows` calls ✅; `:338` `upsertOwnRows` ✅; `:340-341` `wallVisibility` + `_uploadOwnPhotos` ✅; `:343` `rowsPushed` ✅; `:364` `_uploadOwnPhotos` (`Future<int>`, `if (photos.isEmpty) return 0;` at `:369`) ✅; `:226-237` `pushOwn` doc + `:238` signature ✅; `enum SyncPushOutcome` at **`:11`** (cited `:10`)
- `lib/features/backup/data/sync_remote.dart:289-310` `syncRequiredFields` ✅ — never lists `dirty`/`remoteId`, so stripping them cannot trip the NOT-NULL guard; `:317-334` `filterValidSyncRows` ✅; `:233-234` `shouldPushLww` ✅; `:34-44` `syncTableNames` (9 entries, FK order)
- `lib/features/backup/data/backup_repository.dart:72-149` `importSnapshot` ✅ exact + its nine `_import*` methods (`:164-389` ✅); `_shouldWriteLww` ends `:162` ✅
- `supabase/schema.sql:23` `"remoteId" TEXT` and `:24` `"dirty" BOOLEAN NOT NULL DEFAULT false` ✅ both exact — both omittable from an upsert payload without failing the INSERT
- `lib/app/web_lifecycle.dart:25-26` — the two-way conditional export to copy verbatim in structure; `lib/app/web_lifecycle_web.dart:41-48` — `web.document.addEventListener('visibilitychange', ((web.Event _) {…}).toJS)` ✅ both confirmed
- `test/features/backup/application/sync_orchestrator_test.dart:26-102` `_CountingSyncRemote` ✅ (`upsertOwnRows` at `:30-31`); `:110-115` `_ThrowingSharedToposSyncRemote` ✅; `:143-150` `_FakeConnectivityService` ✅; `:163-165` `primeOrchestrator` ✅; `:175-207` `makeContainer` ✅; `:209-219` `insertArea` ✅; `:689` inline container in the `status transitions` group (`:681-725`) ✅
- `test/features/backup/data/sync_service_test.dart:23-260` `FakeSyncRemote` ✅ (`upsertOwnRows` `:35-36`); `:267-272` `ThrowingFetchSharedToposRemote` ✅; `:276-283` `FakeConnectivityService` ✅; `:287-307` `FakeAuthRepository` ✅; `:309-313` `_signedOut`/`_uidU1`/`_uidU2`/`_signedInU1`/`_signedInU2` ✅; `:333-352` `makeContainer` ✅ (returns a *record*, not a `ProviderContainer`, despite the name); `:364-436` `seedWallHierarchy` ✅; `group('pushOwn', …)` at `:438` with its first test ending `:494` ✅
- `test/app/app_test.dart:30-101` `_CountingSyncRemote` (cited `:34`); `:128-131` the "duplicated locally…" convention comment ✅; `:132-135` `_FakeConnectivityService` ✅ (no constructor, no `status` field — unlike its orchestrator-test twin); `:177-185` `_drain` ✅; `:205-211` `_setAppLifecycleState`; four `MasiApp` mounts at `:228`, `:340`, `:439`, `:523`
- `package:connectivity_plus` **7.3.0** (`pubspec.lock:196`, direct main) `Stream<List<ConnectivityResult>> Connectivity.onConnectivityChanged` (getter). `grep -rn "onConnectivityChanged" lib` = **0 hits** ✅ — nothing reacts to connectivity returning today, which is S3.
- `package:drift` **2.34.2** (corrected per D-16; `pubspec.lock:292/299`) — `Expression<D>.isIn(Iterable<D>)` (instance method, `expression.dart:159`) and `extension BooleanExpressionOperators on Expression<bool>` (`bools.dart:4`); the latter must be `show`n to use `&`

## Conventions

**Riverpod v3 only:** `Notifier`/`NotifierProvider` (`SyncOrchestrator extends Notifier<SyncOrchestratorState>`, `sync_orchestrator.dart:123`), plain `Provider` for injectable collaborators. **Never `StateProvider`.** New seams are `Provider`s next to their consumer — `syncDebounceDurationProvider` (`sync_orchestrator.dart:92`) is the template for `syncRetryScheduleProvider`.

**Platform splits use conditional exports, never `kIsWeb`,** and the two-way (native/web) shape is already established for web-only browser hooks — copy `lib/app/web_lifecycle.dart` verbatim in structure: a facade file whose entire body is `export 'x_native.dart' if (dart.library.js_interop) 'x_web.dart';` plus a long doc comment explaining why the split is two-way rather than the three-way `_stub`/`_native`/`_web` used by `lib/features/topo/data/photo_files.dart`. The `_web.dart` half uses `package:web` + `dart:js_interop` ONLY (see `lib/app/web_lifecycle_web.dart:41-48`). `kIsWeb` **is** allowed in `connectivity_service.dart` — it already imports `package:flutter/foundation.dart show kIsWeb` and gates on the injectable `SystemConnectivityService([Connectivity? connectivity, bool? isWeb, http.Client? httpClient])` positional seam (§1d's 3-positional form; `:31-41` before §1d), which `connectivity_service_test.dart:21` drives as `SystemConnectivityService(null, true)`. **Keep that seam.** Nothing here touches `dart:io`, so the directive-anchored gate `grep -rlE "^[[:space:]]*(import|export)[[:space:]]+['\"]dart:io['\"]" lib --include="*.dart" | grep -v '_native.dart'` stays empty.

**Drift:** repositories mutate through typed companions, always bumping `updatedAt` in the same write — `db.WallsCompanion(latitude: Value(latitude), longitude: Value(longitude), updatedAt: Value(now), dirty: const Value(true))` (`library_crud_repository.dart:442-447`, verified exact) is the canonical shape and the reason the (id, updatedAt) compare-and-swap is sound.

> Corrected (D-16 / count audit): the fragment claimed "all 30 existing `dirty: const Value(true)` writes". The real repo-wide count is **35** (`grep -rn "dirty: const Value(true)" lib --include="*.dart" | wc -l` = 35), of which **17** are in `library_crud_repository.dart` (the fragment said 18).

Verified: all **35** existing `dirty: const Value(true)` writes set `updatedAt: Value(now)` too. To use `&` inside a `where` from a file that doesn't import drift wholesale, follow `library_crud_repository_test.dart:8`: `import 'package:drift/drift.dart' show BooleanExpressionOperators, Value;`.

**Doc comments carry the *why*,** cite the bug/spec id they fix, and name the alternative that was rejected — e.g. `sync_orchestrator.dart:127-133` on `_pullInFlight`, `:136-145` on `_resumePullThrottle`, `sync_remote.dart:236-259` on `hasRequiredSyncFields`. Match that density; a terse comment reads as out of place here.

**Tests:** plain `test()` with an in-memory `AppDatabase(NativeDatabase.memory())`, `addTearDown(db.close)`, `addTearDown(container.dispose)`, fakes declared locally per file and deliberately duplicated across files (`app_test.dart:128-131` literally documents "duplicated locally from `sync_orchestrator_test.dart`'s identically-named class"). Orchestrator tests must call `primeOrchestrator(container)` (`sync_orchestrator_test.dart:163-165`), never a bare `container.read`, or the `ref.listen(authStateProvider)` edge goes dead. Timing is driven by shrinking the injected seam (`debounce: const Duration(milliseconds: 25)`) plus short `await Future<void>.delayed(...)`; widget tests use `_drain(tester)` (`app_test.dart:177-185`). Never drive a real image-codec decode in a widget test.

> Corrected (D-17): **no assertion in this fragment may count retry completions inside a wall-clock budget.** Where a test needs N retry cycles, drive them with `await notifier.pushNow()` (which cancels the armed `_retryTimer` on entry, making each explicit call exactly one deterministic cycle) and assert the *requested attempt numbers* on `_RecordingRetrySchedule.attempts`. Only one test in this fragment — Task 10's first, whose subject *is* the autonomous timer — may depend on a timer firing, and its schedule/window are sized with margin.

> Corrected (D-18): **`fake_async` must not be imported.** It is transitive-only (`pubspec.lock:316`, `dependency: transitive`, 1.3.3), so `depend_on_referenced_packages` from `package:flutter_lints` would fire, and adding it to `pubspec.yaml` collides with every other Stage-1 workstream. Recorded so a verifier does not demand it. The existing seams (`syncDebounceDurationProvider`, `nowMsProvider`, `syncRetryScheduleProvider`) plus the D-17 rewrite cover everything it would have bought.

**Commits:** `type(scope): summary`, one logical change each, straight to `main`, ending with the trailer `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`. Never push, never open a PR.

## Ordering

**This fragment is Phase 3 — strictly serial, on top of §1d (Phase 2).** Nothing else may touch `lib/features/backup/**` or `test/app/app_test.dart` while it runs. §1f's sync half (Phase 4) sits on top of it.

### The two orphan leaves are runnable in Phase 1

Two tasks have **no dependency on Phase 2 whatsoever** and are file-disjoint from every other Phase-1 workstream (§1a, §1b, §1f's photo half) and from each other:

- **Task 1** — `importSnapshot` never marks an imported row dirty. Touches only `lib/features/backup/data/backup_repository.dart` + `test/features/backup/data/backup_repository_test.dart`, neither of which any other fragment touches. It changes no signature and no shared symbol.
- **Task 5** — the new `lib/features/backup/application/sync_retry_schedule.dart` + its new test file. Both files are new; `SyncRetrySchedule` was *deliberately* put in its own file precisely so §1d's large `sync_orchestrator.dart` diff cannot collide with it.

Running these two in Phase 1 shortens the serial Phase-3 critical path by two tasks. They are also parallel-safe with each other (`reconciliation.md`'s parallel-safe table lists the pair explicitly).

### Hard ordering *within* this fragment

- **Task 1 → Task 2.** After Task 2 a cloud row comes back with **no `dirty` key**, and `<Table>.fromJson`'s `serializer.fromJson<bool>(json['dirty'])` throws on `null`. Shipping Task 2 first red-fails every device-A→device-B round-trip test in `sync_service_test.dart`.
- **Task 3 → Tasks 4 and 6.** Gating the push on `dirty` before completing the writer surface would silently stop syncing every create, every rename, every route edit and most tombstones. See the first risk.
- **Task 5 → Task 6** (`syncRetryScheduleProvider`).
- **Task 4 → Task 6** (`PushScope`, `hasPendingLocalChanges`).
- **Task 7 → Task 8** (`statusChanges()`).
- **Task 6 → Task 9** (`pushNow()`).
- **Task 10 last** — it composes everything.

### Cross-fragment serialisation (from `reconciliation.md`, verified)

| File | Order |
|---|---|
| `sync_remote.dart` | §1d T1 → §1d T2 → **§1e T2** → §1f T7 |
| `sync_service.dart` | §1d T3 → §1d T4 → **§1e T4** → §1f T8 → §1f T9 |
| `sync_orchestrator.dart` | §1d T5 → §1d T7 → **§1e T6** → **§1e T8** |
| `connectivity_service.dart` | §1d T6 → **§1e T7** |
| `library_crud_repository.dart` | §1f's orphan-row task → **§1e T3** (code) |
| `test/app/app_test.dart` | §1d T2 → §1d T6 → §1d T7 → **§1e T7** → **§1e T9** |
| `test/features/backup/data/sync_service_test.dart` | §1d T2/T3/T4/T6 → **§1e T2** → **§1e T4** → **§1e T7** → §1f T8/T9/T10 |
| `test/features/backup/application/sync_orchestrator_test.dart` | §1d T2/T5/T6/T7 → **§1e T6** → **§1e T7** → **§1e T8** → **§1e T10** |
| `test/features/backup/data/{connectivity_service,cloud_backup_service}_test.dart` | §1d T6 → **§1e T7** |

**Never run in parallel:** any two of {§1d, §1e, §1f-sync}. Also note the master plan's *actual* execution order supersedes the phase grouping: everything runs sequentially in the main working tree, because the git index is shared state even between file-disjoint implementers.

---

### Task 1: `importSnapshot` never marks an imported row dirty (S9 root fix, and prerequisite for Task 2)

**Runnable in Phase 1** — orphan leaf, no dependency on §1d.

**Files:**
- Modify: `lib/features/backup/data/backup_repository.dart` (`:164-389` ✅ verified exact)
- Test: `test/features/backup/data/backup_repository_test.dart`

**Interfaces:**
- Produces: `BackupRepository._notDirty(Map<String, dynamic>)` (private static) and the invariant "every row written by `importSnapshot` is `dirty: false`".
- Consumes: `importSnapshot` (`:72-149` ✅) and its nine `_import*` methods; `_shouldWriteLww` (ends `:162` ✅). Test file: `db`/`repo` from `setUp` (`:16`/`:17`), `group('S3-d: lww conflict mode', …)` at `:387-509`, `main()` closes at `:510`.

- [ ] **Step 1: Append a failing group to `test/features/backup/data/backup_repository_test.dart`** (after the existing `S3-d: lww conflict mode` group's closing `});` at `:509`, at end of `main()`). It uses the file's existing `db`/`repo` from `setUp`.
  ```dart
  group('sync bookkeeping: imported rows are never locally dirty (S9)', () {
    test(
      'a row whose incoming payload says dirty:true is imported dirty:false '
      '-- a pulled row is by definition NOT a local change awaiting push',
      () async {
        await repo.importSnapshot({
          'tables': {
            'areas': [
              {
                'id': 'area-cloud',
                'createdAt': 100,
                'updatedAt': 100,
                'name': 'Cloud Area',
                'dirty': true,
                'ownerId': 'u1',
              },
            ],
          },
        });

        final row = await (db.select(
          db.areas,
        )..where((t) => t.id.equals('area-cloud'))).getSingle();
        expect(row.dirty, isFalse);
      },
    );

    test(
      'a row payload with NO dirty key at all still decodes (this is the '
      'shape a cloud row comes back in once the push strips dirty/remoteId)',
      () async {
        await repo.importSnapshot({
          'tables': {
            'areas': [
              {
                'id': 'area-stripped',
                'createdAt': 100,
                'updatedAt': 100,
                'name': 'Stripped Area',
                'ownerId': 'u1',
              },
            ],
          },
        });

        final row = await (db.select(
          db.areas,
        )..where((t) => t.id.equals('area-stripped'))).getSingle();
        expect(row.dirty, isFalse);
        expect(row.remoteId, isNull);
      },
    );
  });
  ```

- [ ] **Step 2: Run the new group and watch both tests fail** (the first on `dirty == true`, the second on a null-cast inside `Area.fromJson`).
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/backup/data/backup_repository_test.dart
  ```
  Expected: 2 failing — `Expected: false Actual: <true>` and a type error from `serializer.fromJson<bool>(json['dirty'])` receiving null.

- [ ] **Step 3: Add the normalizing helper to `BackupRepository`** in `lib/features/backup/data/backup_repository.dart`, immediately after `_shouldWriteLww` (which ends at line 162).
  ```dart
  /// Every row arriving through [importSnapshot] is written `dirty: false`,
  /// unconditionally, whatever the incoming payload says.
  ///
  /// TWO reasons, both load-bearing:
  ///  1. S9 — an imported row is BY DEFINITION not a local change awaiting a
  ///     push. `importSnapshot`'s writes fire the same `tableUpdates()`
  ///     `SyncOrchestrator` debounces on, so before this every pull that
  ///     wrote anything scheduled a full re-push ~2s later. Now that the
  ///     push is gated on `dirty` (see `SyncService.hasPendingLocalChanges`),
  ///     a pull's writes are correctly invisible to it.
  ///  2. Decodability — `SyncService.pushOwn` no longer SENDS `dirty`/
  ///     `remoteId` (see `stripLocalOnlySyncColumns`), so a cloud row fetched
  ///     back may lack the key entirely, or carry the Postgres column default
  ///     rather than anything meaningful. `<Table>.fromJson`'s
  ///     `serializer.fromJson<bool>(json['dirty'])` throws on a null, so the
  ///     key must always be present here. Forcing it AFTER the spread (rather
  ///     than defaulting it before, the way `visibility`/`sortOrder`/
  ///     `isPrimary` are defaulted in [_importWalls]/[_importPhotos]/
  ///     [_importAscents]) is deliberate: those are "absent means use the
  ///     column default", this is "whatever arrived is wrong".
  static Map<String, dynamic> _notDirty(Map<String, dynamic> json) => {
    ...json,
    'dirty': false,
  };
  ```

- [ ] **Step 4: Wrap every `<Table>.fromJson(...)` argument in `_notDirty(...)`.** Nine edits, all inside the `_import*` methods; the three that already inject column defaults keep them. **All nine call lines verified exact against the current file.**
  ```dart
  // _importProfiles (was line 173):
        final profile = db.Profile.fromJson(_notDirty(json));
  // _importAreas (was 194):
        final area = db.Area.fromJson(_notDirty(json));
  // _importSectors (was 215):
        final sector = db.Sector.fromJson(_notDirty(json));
  // _importWalls (was 239):
        final wall = db.Wall.fromJson(_notDirty({'visibility': 'private', ...json}));
  // _importPhotos (was 268-275):
      final photos = [
        for (final json in rows)
          db.Photo.fromJson(_notDirty({
            'sortOrder': 0,
            'isPrimary': false,
            ...json,
          })),
      ];
  // _importRoutes (was 300):
        final route = db.Route.fromJson(_notDirty(json));
  // _importComments (was 321):
        final comment = db.Comment.fromJson(_notDirty(json));
  // _importLikes (was 342):
        final like = db.Like.fromJson(_notDirty(json));
  // _importAscents (was 379):
        final ascent = db.Ascent.fromJson(_notDirty({'visibility': 'private', ...json}));
  ```

- [ ] **Step 5: Update the `importSnapshot` class doc** (`backup_repository.dart:26-39` — the `[importSnapshot]` paragraph inside the class doc block that spans `:19-39`) to record the new invariant.
  ```dart
  /// [importSnapshot] upserts every row by its `id` primary key, in FK
  /// dependency order (Profiles → Areas → Sectors → Walls → Photos → Routes →
  /// Ascents → Comments → Likes), and writes every row `dirty: false` — see
  /// [_notDirty] for why that is a correctness requirement, not a detail.
  ```

- [ ] **Step 6: Re-run the file** — both new tests pass and the pre-existing export/import round-trip + LWW tests stay green.
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/backup/data/backup_repository_test.dart
  ```
  Expected: all tests pass.

**Assertions:**
- `flutter test test/features/backup/data/backup_repository_test.dart` is green, including both new tests.
- Importing a payload with `'dirty': true` yields a local row with `dirty == false`.
- Importing a payload with **no** `dirty` key succeeds instead of throwing, and yields `dirty == false`.
- `grep -c '_notDirty(' lib/features/backup/data/backup_repository.dart` is **10** (1 declaration + 9 call sites).
- `flutter analyze` reports 0 issues.
- **Test count: baseline + 2** for this task. Gate on `flutter test` being fully green, never on an absolute total (D-13).

**Commit:** `fix(sync): import every pulled row as not-dirty (S9)`

---

### Task 2: Strip `dirty`/`remoteId` from the pushed row payload

**Files:**
- Modify: `lib/features/backup/data/sync_remote.dart` (append after `filterValidSyncRows`, `:317-334` today — **anchor on the symbol, not the line**: §1d task 1 rewrites that function's body into a delegation first), `lib/features/backup/data/sync_service.dart` (`:288-336` ✅)
- Test: `test/features/backup/data/sync_service_test.dart`

**Interfaces:**
- Produces: `const Set<String> localOnlySyncColumns = {'dirty', 'remoteId'};`, `Map<String, dynamic> stripLocalOnlySyncColumns(Map<String, dynamic> row)`.
- Consumes: `syncTableNames` (`sync_remote.dart:34-44`), `syncRequiredFields` (`:289-310`), `filterValidSyncRows` (`:317-334`), `supabase/schema.sql:23-24`; test-side `FakeSyncRemote` (`:23-260`), `makeContainer` (`:333-352`), `FakeAuthRepository` (`:287-307`), `seedWallHierarchy` (`:364-436`), `_uidU1`/`_signedInU1` (`:310`/`:312`).

- [ ] **Step 1: Add a failing test to the existing `group('pushOwn', …)`** in `test/features/backup/data/sync_service_test.dart` (the group opens at `:438`; insert after its first test, which ends at `:494` ✅). It reuses `FakeSyncRemote`, `makeContainer`, `FakeAuthRepository`, `seedWallHierarchy` and the `_uidU1`/`_signedInU1` constants already in the file.
  ```dart
      test(
        'the pushed row payload carries neither dirty nor remoteId -- both are '
        'LOCAL-ONLY bookkeeping columns (S8) that used to ship inside every '
        "row's JSON",
        () async {
          final remote = FakeSyncRemote();
          final c = makeContainer(remote: remote, auth: FakeAuthRepository(_signedInU1));
          addTearDown(() => c.db.close());

          await seedWallHierarchy(
            c.db,
            ownerId: _uidU1,
            areaId: 'area-1',
            sectorId: 'sector-1',
            wallId: 'wall-1',
            photoId: 'photo-1',
            routeId: 'route-1',
          );

          await c.service.pushOwn();

          final ownRows = await remote.fetchOwnRows(_uidU1);
          for (final tableName in syncTableNames) {
            for (final row in ownRows[tableName]!) {
              expect(
                row.keys,
                isNot(contains('dirty')),
                reason: '$tableName row ${row['id']} still ships dirty',
              );
              expect(
                row.keys,
                isNot(contains('remoteId')),
                reason: '$tableName row ${row['id']} still ships remoteId',
              );
            }
          }
          expect(
            ownRows['areas']!.single['id'],
            'area-1',
            reason: 'stripping must not drop the row itself',
          );
        },
      );
  ```

- [ ] **Step 2: Run it and watch it fail on `dirty`.**
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/backup/data/sync_service_test.dart --plain-name 'the pushed row payload carries neither dirty nor remoteId'
  ```
  Expected: fails with `Expected: not contains 'dirty'`.

- [ ] **Step 3: Add the shared strip helper to `lib/features/backup/data/sync_remote.dart`,** immediately after `filterValidSyncRows` — i.e. after whatever §1d task 1 left in place of the old `:317-334` body, at the end of the top-level-helper block.
  ```dart
  /// The columns present in every `<TableRow>.toJson()` that are LOCAL-ONLY
  /// sync bookkeeping and must never travel to the cloud.
  ///
  /// - `dirty` is this device's "has an unpushed local change" flag (see
  ///   `tables.dart`'s `SyncColumns` and `SyncService.hasPendingLocalChanges`).
  ///   Sending it is worse than useless: it is per-DEVICE state, so device A's
  ///   flag would land in the shared cloud row and come back down to device B
  ///   as if B had a pending change.
  /// - `remoteId` is a reserved, never-written local column.
  ///
  /// Both used to ship inside every pushed row (S8). Stripping them is safe on
  /// the wire in both directions: `supabase/schema.sql` declares
  /// `"dirty" BOOLEAN NOT NULL DEFAULT false` and `"remoteId" TEXT`, so an
  /// INSERT that omits them takes the default / NULL and an
  /// `ON CONFLICT DO UPDATE` leaves the stored value untouched; and on the way
  /// back `BackupRepository.importSnapshot` forces `dirty: false` on every row
  /// regardless (see its `_notDirty`). Neither name appears in
  /// [syncRequiredFields], so stripping can never trip the NOT-NULL guard.
  const Set<String> localOnlySyncColumns = {'dirty', 'remoteId'};

  /// [row] without any [localOnlySyncColumns] key. Returns a COPY — the caller
  /// still holds the original `toJson()` map, and `SyncService.pushOwn` relies
  /// on the stripped map keeping `id` and `updatedAt` (both required, both
  /// retained) for its confirmed-push `dirty` clear.
  Map<String, dynamic> stripLocalOnlySyncColumns(Map<String, dynamic> row) {
    final stripped = Map<String, dynamic>.of(row);
    stripped.removeWhere((key, _) => localOnlySyncColumns.contains(key));
    return stripped;
  }
  ```

- [ ] **Step 4: In `lib/features/backup/data/sync_service.dart`, wrap each of the nine `row.toJson()` calls inside the `tablesToRows` literal (`:288-336` ✅) with `stripLocalOnlySyncColumns(...)`.** Pattern, applied identically to profiles/areas/sectors/walls/photos/routes/comments/likes/ascents. **Note:** §1d task 4 converts the nine `filterValidSyncRows(...)` calls to its `pushRequiredFields` seam — apply this change on top of whatever §1d left, changing only the inner list comprehension.
  ```dart
      final tablesToRows = <String, List<Map<String, dynamic>>>{
        'profiles': filterValidSyncRows(
          [for (final row in profiles) stripLocalOnlySyncColumns(row.toJson())],
          syncRequiredFields['profiles'] ?? const ['id'],
          debugLabel: 'local profiles (push)',
        ),
        'areas': filterValidSyncRows(
          [for (final row in areas) stripLocalOnlySyncColumns(row.toJson())],
          syncRequiredFields['areas'] ?? const ['id'],
          debugLabel: 'local areas (push)',
        ),
        // ... same single-line change for sectors, walls, photos, routes,
        // comments, likes, ascents.
      };
  ```

- [ ] **Step 5: Run the whole `sync_service` + `backup_repository` suites** — the new test passes and every device-A→device-B round-trip test still passes (they only work because Task 1 already forces `dirty` on import).
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/backup/
  ```
  Expected: all tests pass.

**Assertions:**
- Every row in `FakeSyncRemote.fetchOwnRows` after a `pushOwn()` has neither a `dirty` nor a `remoteId` key.
- The pre-existing `pullOwnAndShared: own-row round trip` and `pullOwnAndShared: shared topo (headline feature)` tests still pass — proving a stripped payload is still importable end to end.
- `grep -c 'stripLocalOnlySyncColumns(row.toJson())' lib/features/backup/data/sync_service.dart` is **9**.
- `flutter test test/features/backup/` is green; `flutter analyze` reports 0 issues.
- **Test count: baseline + 1** for this task (D-13).

**Commit:** `fix(sync): strip dirty/remoteId from the pushed row payload (S8)`

---

### Task 3: Every push-worthy local write marks the row dirty

**Files:**
- Modify: `lib/features/library/data/library_crud_repository.dart` (`161-169`, `183`, `262-271`, `285`, `347-357`, `375`, `606-619`, `1286`, `1310`, `1318`, `1323`, `1361` — **all twelve verified exact, all twelve confirmed to set no `dirty` today**), `lib/features/topo/data/route_repository.dart` (`73-95`, `101-118`, `205-208` — all three verified, `grep -c 'dirty: const Value(true)'` = 0)
- Test: `test/features/library/data/library_crud_repository_test.dart`, `test/features/topo/data/route_repository_test.dart`

**Interfaces:**
- Produces: the invariant "every push-worthy write in `LibraryCrudRepository` and `RouteRepository` sets `dirty: true` alongside `updatedAt: Value(now)`" — the precondition Task 4's dirty gate depends on.
- Consumes: the canonical companion shape at `library_crud_repository.dart:442-447` ✅; `library_crud_repository_test.dart:8` (drift `show BooleanExpressionOperators, Value`) and `group('A1: create/rename/sortOrder', …)` at `:27`; `route_repository_test.dart`'s `repo` (`:16`), `wallId` (`:11`), `photoId` (`:12`).

> **Sequencing note:** `reconciliation.md` orders this as *§1f task 3 (doc-only) → §1e task 3 (code)*. In the master plan's actual execution order §1f's photo half (including its `attachPhotoToWall` orphan-row change) runs at position 6, before §1d and §1e — so **§1f's `library_crud_repository.dart` diff lands first and this task rebases onto it.** `attachPhotoToWall`'s companion may have moved; re-locate it by symbol.

- [ ] **Step 1: AUDIT FIRST** — the spec's S8 claim that `dirty` is "written `true` by every repository" is **WRONG**, and the plan depends on it. Confirm the writers that omit it before changing anything.
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && grep -rn "Companion" lib/features/library/data/library_crud_repository.dart lib/features/topo/data/route_repository.dart | grep -v "dirty"
  ```
  Expected: lists exactly the 15 sites named in this task's modify list (12 in `library_crud_repository`, 3 in `route_repository`) plus the two deliberate exclusions discussed below.

- [ ] **Step 2: Add failing assertions to `test/features/library/data/library_crud_repository_test.dart`,** inside the existing `group('A1: create/rename/sortOrder', …)` (`:27`). `repo` is the file's `LibraryCrudRepository(db, nowMs: () => 1000)` from `setUp` (`:20`); the file already imports `Value` and `BooleanExpressionOperators` from drift (`:8` ✅).
  ```dart
      test(
        'create/rename mark the row dirty -- the push is gated on `dirty` '
        '(S8), so a write that leaves it false would never sync',
        () async {
          final area = await repo.createArea('Squamish');
          var areaRow = await (db.select(
            db.areas,
          )..where((t) => t.id.equals(area.id))).getSingle();
          expect(areaRow.dirty, isTrue, reason: 'createArea');

          // Clear it the way a confirmed push does, then prove the rename
          // re-dirties it.
          await (db.update(db.areas)..where((t) => t.id.equals(area.id)))
              .write(const AreasCompanion(dirty: Value(false)));
          await repo.renameArea(area.id, 'Squamish Renamed');
          areaRow = await (db.select(
            db.areas,
          )..where((t) => t.id.equals(area.id))).getSingle();
          expect(areaRow.dirty, isTrue, reason: 'renameArea');

          final sector = await repo.createSector(area.id, 'Sector');
          final sectorRow = await (db.select(
            db.sectors,
          )..where((t) => t.id.equals(sector.id))).getSingle();
          expect(sectorRow.dirty, isTrue, reason: 'createSector');

          await repo.renameSector(sector.id, 'Sector Renamed');
          expect(
            (await (db.select(db.sectors)
                  ..where((t) => t.id.equals(sector.id)))
                .getSingle())
                .dirty,
            isTrue,
            reason: 'renameSector',
          );

          final wall = await repo.createWall(sector.id, 'Wall');
          expect(
            (await (db.select(db.walls)..where((t) => t.id.equals(wall.id)))
                    .getSingle())
                .dirty,
            isTrue,
            reason: 'createWall',
          );

          await repo.renameWall(wall.id, 'Wall Renamed');
          expect(
            (await (db.select(db.walls)..where((t) => t.id.equals(wall.id)))
                    .getSingle())
                .dirty,
            isTrue,
            reason: 'renameWall',
          );
        },
      );

      test(
        'softDeleteArea leaves every tombstone in the cascaded subtree dirty '
        '-- a tombstone that never reaches the cloud resurrects the row on '
        'another device',
        () async {
          final area = await repo.createArea('Doomed');
          final sector = await repo.createSector(area.id, 'Sector');
          final wall = await repo.createWall(sector.id, 'Wall');
          for (final table in <String>['areas', 'sectors', 'walls']) {
            // Start from a clean slate so the assertion below can only be
            // satisfied by the soft-delete itself.
            switch (table) {
              case 'areas':
                await db.update(db.areas).write(
                  const AreasCompanion(dirty: Value(false)),
                );
              case 'sectors':
                await db.update(db.sectors).write(
                  const SectorsCompanion(dirty: Value(false)),
                );
              case 'walls':
                await db.update(db.walls).write(
                  const WallsCompanion(dirty: Value(false)),
                );
            }
          }

          await repo.softDeleteArea(area.id);

          expect(
            (await (db.select(db.areas)..where((t) => t.id.equals(area.id)))
                    .getSingle())
                .dirty,
            isTrue,
            reason: 'area tombstone',
          );
          expect(
            (await (db.select(db.sectors)
                  ..where((t) => t.id.equals(sector.id)))
                .getSingle())
                .dirty,
            isTrue,
            reason: 'sector tombstone',
          );
          expect(
            (await (db.select(db.walls)..where((t) => t.id.equals(wall.id)))
                    .getSingle())
                .dirty,
            isTrue,
            reason: 'wall tombstone',
          );
        },
      );
  ```

- [ ] **Step 3: Add failing assertions to `test/features/topo/data/route_repository_test.dart`** at the end of `main()`. `repo` is the file's `RouteRepository(db, nowMs: () => 1000)` (`:16`).
  > Corrected (verification): the fragment said "add `import 'package:drift/drift.dart' show Value;` **if absent**". It **is** absent — the file's only imports are `:1-6` (`app_database.dart`, `grade_system.dart`, `route_repository.dart`, `topo_route.dart`, `drift/native.dart`, `flutter_test`). Adding it is **required**, not conditional. Also note the file constructs `TopoRoute(...)` non-`const` everywhere today; the `const` literal below compiles against the real constructor (`lib/features/topo/domain/topo_route.dart:51-67`) but is a new construct in this file.
  ```dart
    group('sync bookkeeping: every route write marks the row dirty (S8)', () {
      test(
        'upsertRoute (insert AND update) and softDeleteRoute all leave '
        'dirty:true -- none of the three did before, so a dirty-gated push '
        'would never have seen a route edit at all',
        () async {
          await repo.upsertRoute(
            wallId,
            photoId,
            const TopoRoute(id: 1, number: 1, points: [], symbols: [], colorIndex: 0),
          );
          var row = await (db.select(
            db.routes,
          )..where((t) => t.number.equals(1))).getSingle();
          expect(row.dirty, isTrue, reason: 'upsertRoute insert');

          await (db.update(db.routes)..where((t) => t.id.equals(row.id)))
              .write(const RoutesCompanion(dirty: Value(false)));
          await repo.upsertRoute(
            wallId,
            photoId,
            const TopoRoute(
              id: 1,
              number: 1,
              points: [],
              symbols: [],
              colorIndex: 3,
            ),
          );
          row = await (db.select(
            db.routes,
          )..where((t) => t.number.equals(1))).getSingle();
          expect(row.dirty, isTrue, reason: 'upsertRoute update');

          await (db.update(db.routes)..where((t) => t.id.equals(row.id)))
              .write(const RoutesCompanion(dirty: Value(false)));
          await repo.softDeleteRoute(wallId, photoId, 1);
          row = await (db.select(
            db.routes,
          )..where((t) => t.number.equals(1))).getSingle();
          expect(row.deletedAt, isNotNull);
          expect(row.dirty, isTrue, reason: 'softDeleteRoute tombstone');
        },
      );
    });
  ```

- [ ] **Step 4: Run both files and watch every new assertion fail.**
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/library/data/library_crud_repository_test.dart test/features/topo/data/route_repository_test.dart
  ```
  Expected: 3 failing tests (`Expected: true Actual: <false>`) — one per new test.

- [ ] **Step 5: Add `dirty: const Value(true)` to `route_repository.dart`'s three writes.** Insert it directly under each `updatedAt` line so the pairing stays visually obvious.
  ```dart
  // upsertRoute insert (was lines 73-95):
              db.RoutesCompanion.insert(
                id: _uuid.v4(),
                createdAt: now,
                updatedAt: now,
                dirty: const Value(true),
                wallId: wallId,
                // ... rest unchanged
              ),
  // upsertRoute update (was 101-118):
          db.RoutesCompanion(
            updatedAt: Value(now),
            dirty: const Value(true),
            photoId: Value(photoId),
            // ... rest unchanged
          ),
  // softDeleteRoute (was 205-208):
            db.RoutesCompanion(
              deletedAt: Value(now),
              updatedAt: Value(now),
              dirty: const Value(true),
            ),
  ```

- [ ] **Step 6: Update `RouteRepository`'s two method docs** (`route_repository.dart:44-46` and `:183-185` ✅ both verified) to state the new behaviour.
  ```dart
    /// Inserts a new route row, or updates the existing non-deleted row for
    /// `(photoId, route.number)` if one exists. Sets `createdAt` only on
    /// insert; always refreshes `updatedAt` to `nowMs()` AND marks the row
    /// `dirty` so the (dirty-gated) sync push picks the edit up — see
    /// `SyncService.hasPendingLocalChanges`.

    /// Soft-deletes the non-deleted route identified by `(photoId, number)`
    /// by setting `deletedAt`/`updatedAt` to `nowMs()` and marking the row
    /// `dirty`. The row remains physically present (tombstone) so the
    /// tombstone itself propagates on the next push.
  ```

- [ ] **Step 7: Add `dirty: const Value(true)` to the 12 `library_crud_repository.dart` writes.** Same placement rule: directly under `updatedAt`.
  ```dart
  // _insertArea (161-169)          -> AreasCompanion.insert(..., updatedAt: now, dirty: const Value(true), ...)
  // renameArea (183)               -> db.AreasCompanion(name: Value(name), updatedAt: Value(now), dirty: const Value(true))
  // _insertSector (262-271)        -> SectorsCompanion.insert(..., updatedAt: now, dirty: const Value(true), ...)
  // renameSector (285)             -> db.SectorsCompanion(name: Value(name), updatedAt: Value(now), dirty: const Value(true))
  // createWall (347-357)           -> WallsCompanion.insert(..., updatedAt: now, dirty: const Value(true), ...)
  // renameWall (375)               -> db.WallsCompanion(name: Value(name), updatedAt: Value(now), dirty: const Value(true))
  // attachPhotoToWall (606-619)    -> PhotosCompanion.insert(..., updatedAt: now, dirty: const Value(true), ...)
  // _cascadeSoftDeleteAreaSubtree (1286)
  //        -> db.AreasCompanion(deletedAt: Value(now), updatedAt: Value(now), dirty: const Value(true))
  // _cascadeSoftDeleteSectorSubtree (1310)
  //        -> db.SectorsCompanion(deletedAt: Value(now), updatedAt: Value(now), dirty: const Value(true))
  // _cascadeSoftDeleteWallSubtree photos (1318)
  //        -> db.PhotosCompanion(deletedAt: Value(now), updatedAt: Value(now), dirty: const Value(true))
  // _cascadeSoftDeleteWallSubtree routes (1323)
  //        -> db.RoutesCompanion(deletedAt: Value(now), updatedAt: Value(now), dirty: const Value(true))
  // _cascadeSoftDeleteWallSubtree wall (1361)
  //        -> db.WallsCompanion(deletedAt: Value(now), updatedAt: Value(now), dirty: const Value(true))
  ```

- [ ] **Step 8: Fix the now-stale comments** at `library_crud_repository.dart:1325-1331` ✅ (which claims Photos/Routes/Walls are deliberately NOT marked dirty — that asymmetry is exactly the bug this task removes) and at `:418-422` ✅ (whose `:420-421` describes `renameWall` as leaving `dirty` untouched).
  ```dart
      // Bug #5: a soft-deleted wall's live Ascents (Logbook entries) were
      // previously left untouched, so a deleted topo's ascents lingered in
      // the Logbook forever. Comments/Likes are cascaded alongside for the
      // same reason. Every row in the cascade — Photos/Routes/Walls included —
      // is marked `dirty`: the push is gated on that flag (see
      // `SyncService.hasPendingLocalChanges`), so an unflagged tombstone would
      // never reach the backend and the row would resurrect on another device.

    /// Records [latitude]/[longitude] as [wallId]'s GPS coordinates and marks
    /// the wall dirty for sync, bumping `updatedAt` — the same wall-row update
    /// shape [_setWallVisibility] and [renameWall] use (every push-worthy write
    /// in this class now bumps `updatedAt` and sets `dirty` together).
  ```

- [ ] **Step 9: Confirm the two deliberate exclusions are still untouched** — both are local-only self-heals that must NOT trigger a push.
  > Corrected (line drift): the `photo_repository.dart` heal block is at **`:371-377`**, not `370-378`; the write statement `372-375` is exact. `sed` range widened accordingly.
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && sed -n '666,672p' lib/features/library/data/library_crud_repository.dart && sed -n '369,379p' lib/features/topo/data/photo_repository.dart
  ```
  Expected: both writes are still `db.PhotosCompanion(localPath: Value(healed))` with no `dirty`/`updatedAt`. (`library_crud_repository.dart`: `if (healed != null)` at `:667`, the write `:668-670` ✅.)

- [ ] **Step 10: Run the two touched suites, then the whole suite** (the write surface is broad — creates now dirty rows in dozens of unrelated tests).
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/library/ test/features/topo/ && flutter test
  ```
  Expected: all green.

**Assertions:**
- `createArea`/`renameArea`/`createSector`/`renameSector`/`createWall`/`renameWall`/`attachPhotoToWall` each leave `dirty == true`.
- `softDeleteArea` leaves the area, sector **and** wall tombstones all `dirty == true`.
- `upsertRoute` (both insert and update branches) and `softDeleteRoute` each leave `dirty == true`.
  > Corrected (count audit): the fragment asserted the `library_crud_repository.dart` grep "rises from 18 to 30". The measured count today is **17** (occurrences at `446, 489, 525, 544, 550, 555, 1338, 1347, 1356, 1392, 1402, 1412, 1422, 1432, 1442, 1452, 1462`), so with this task's +12 the target is **29**. Repo-wide the count is **35** today, not 30.
- `grep -c 'dirty: const Value(true)' lib/features/library/data/library_crud_repository.dart` rises from **17 to 29**; the same grep on `lib/features/topo/data/route_repository.dart` rises from **0 to 3**.
- The two local-only path-heal writes (`library_crud_repository.dart:668-670`, `photo_repository.dart:372-375`) still set neither `dirty` nor `updatedAt`.
- Whole-suite `flutter test` is green and `flutter analyze` reports 0 issues.
- **Test count: baseline + 3** for this task (D-13).

**Commit:** `fix(sync): mark every push-worthy local write dirty (S8)`

---

### Task 4: Dirty-scoped push, `hasPendingLocalChanges()`, and the race-safe confirmed-push dirty clear

**The most heavily corrected task in this fragment** — D-3, D-12, D-25, D-26, and decisions #12/#13/#14 all land here.

**Files:**
- Modify: `lib/features/backup/data/sync_service.dart` (imports `:1-8`; `pushOwn` doc `:226-237`, signature `:238`, snapshot `:265-275`, tail `:338-343`; `_uploadOwnPhotos` `:364` — all ✅ verified, but apply on top of §1d tasks 3/4, which rewrote `PushSyncResult` and the tail)
- Test: `test/features/backup/data/sync_service_test.dart`

**Interfaces:**
- Produces: `enum PushScope { full, dirtyOnly }`, `pushOwn({PushScope scope = PushScope.full})`, `hasPendingLocalChanges()`, `_clearDirty`/`_clearDirtyRows`, and the `wallVisibility` `selectOnly` projection §1f task 9 consumes (decision #13).
- Consumes: §1d's `PushSyncResult` (`rowsFailed`/`errors`/`fullyLanded`), §1d's `outcomes` local + `TablePushOutcome.ok`, §1d's public `ThrowingUpsertSyncRemote`; `_uploadOwnPhotos`'s `Future<int>` (decision #12 — unchanged here); drift's `Expression.isIn` + `BooleanExpressionOperators`.

- [ ] **Step 1: Add the failing group to `test/features/backup/data/sync_service_test.dart`,** after the existing `group('pushOwn', …)` closes. Add `import 'dart:async';` at the top of the file (confirmed absent today — the file imports `dart:io` at `:1`); Task 7 needs it too.
  > Corrected (D-3 + D-26): the third test's double `_ThrowingUpsertRemote` is **deleted** — §1d task 3's public `ThrowingUpsertSyncRemote` is used instead (same file, correct signature). And because §1d's `pushOwn` converts a whole-call `upsertOwnRows` throw into an all-tables-`failed` **result** rather than propagating it, `expectLater(..., throwsA(isA<Exception>()))` can never pass — the test now asserts on the result and then on the thing it actually exists to prove: `dirty` survives a failed push. §1d's double throws `Exception('upsertOwnRows boom')`, so the error-text assertion follows that message.
  ```dart
    group('dirty gating + confirmed-push clear (S2/S7/S8)', () {
      test('hasPendingLocalChanges is false when signed out', () async {
        final remote = FakeSyncRemote();
        final c = makeContainer(remote: remote, auth: FakeAuthRepository(_signedOut));
        addTearDown(() => c.db.close());
        expect(await c.service.hasPendingLocalChanges(), isFalse);
      });

      test(
        'hasPendingLocalChanges tracks the dirty flag: true with a dirty own '
        'row, false once a confirmed push has cleared it',
        () async {
          final remote = FakeSyncRemote();
          final c = makeContainer(remote: remote, auth: FakeAuthRepository(_signedInU1));
          addTearDown(() => c.db.close());

          await c.db.into(c.db.areas).insert(
            AreasCompanion.insert(
              id: 'area-dirty',
              createdAt: 100,
              updatedAt: 100,
              dirty: const Value(true),
              ownerId: const Value(_uidU1),
              name: 'Dirty',
            ),
          );
          expect(await c.service.hasPendingLocalChanges(), isTrue);

          await c.service.pushOwn();

          expect(await c.service.hasPendingLocalChanges(), isFalse);
          final row = await (c.db.select(
            c.db.areas,
          )..where((t) => t.id.equals('area-dirty'))).getSingle();
          expect(row.dirty, isFalse);
        },
      );

      test(
        'a FAILED push leaves dirty set -- the flag is cleared only for the '
        'tables the push CONFIRMED, which is what makes "retry until clean" '
        'terminate. Note pushOwn does NOT throw here: §1d converts a '
        'whole-call upsert throw into an all-tables-failed RESULT, which is '
        'exactly why the clear must be narrowed to the landed tables.',
        () async {
          final remote = ThrowingUpsertSyncRemote();
          final c = makeContainer(remote: remote, auth: FakeAuthRepository(_signedInU1));
          addTearDown(() => c.db.close());

          await c.db.into(c.db.areas).insert(
            AreasCompanion.insert(
              id: 'area-dirty',
              createdAt: 100,
              updatedAt: 100,
              dirty: const Value(true),
              ownerId: const Value(_uidU1),
              name: 'Dirty',
            ),
          );

          final result = await c.service.pushOwn();

          expect(result.fullyLanded, isFalse);
          expect(result.rowsFailed, 1);
          expect(result.errors.join(' '), contains('upsertOwnRows boom'));

          final row = await (c.db.select(
            c.db.areas
          )..where((t) => t.id.equals('area-dirty'))).getSingle();
          expect(row.dirty, isTrue);
          expect(await c.service.hasPendingLocalChanges(), isTrue);
        },
      );

      test(
        'PushScope.dirtyOnly sends ONLY the dirty rows (S7), while the default '
        'PushScope.full still sends everything',
        () async {
          final remote = FakeSyncRemote();
          final c = makeContainer(remote: remote, auth: FakeAuthRepository(_signedInU1));
          addTearDown(() => c.db.close());

          await seedWallHierarchy(
            c.db,
            ownerId: _uidU1,
            areaId: 'area-clean',
            sectorId: 'sector-clean',
            wallId: 'wall-clean',
            photoId: 'photo-clean',
            routeId: 'route-clean',
          );
          await c.db.into(c.db.areas).insert(
            AreasCompanion.insert(
              id: 'area-dirty',
              createdAt: 100,
              updatedAt: 100,
              dirty: const Value(true),
              ownerId: const Value(_uidU1),
              name: 'Dirty',
            ),
          );

          final dirtyPush = await c.service.pushOwn(scope: PushScope.dirtyOnly);
          expect(dirtyPush.rowsPushed, 1);
          expect(
            (await remote.fetchOwnRows(_uidU1))['areas']!.map((r) => r['id']),
            ['area-dirty'],
            reason: 'the seeded clean hierarchy must not be re-sent',
          );

          final fullPush = await c.service.pushOwn();
          expect(fullPush.rowsPushed, 6);
        },
      );

      test(
        'a local write that lands DURING an in-flight push keeps its dirty '
        'flag -- the clear is an (id, updatedAt) compare-and-swap, so the '
        'newer edit is picked up by the next push instead of being lost',
        () async {
          late final AppDatabase raceDb;
          final remote = _MidPushWriteRemote(() async {
            // Simulates the user editing the same row while the push is
            // awaiting the network: a fresh updatedAt AND dirty re-set, exactly
            // what every repository write does.
            await (raceDb.update(raceDb.areas)
                  ..where((t) => t.id.equals('area-dirty')))
                .write(
                  const AreasCompanion(
                    updatedAt: Value(999),
                    dirty: Value(true),
                    name: Value('Edited mid-push'),
                  ),
                );
          });
          final c = makeContainer(remote: remote, auth: FakeAuthRepository(_signedInU1));
          raceDb = c.db;
          addTearDown(() => c.db.close());

          await c.db.into(c.db.areas).insert(
            AreasCompanion.insert(
              id: 'area-dirty',
              createdAt: 100,
              updatedAt: 100,
              dirty: const Value(true),
              ownerId: const Value(_uidU1),
              name: 'Original',
            ),
          );

          await c.service.pushOwn(scope: PushScope.dirtyOnly);

          final row = await (c.db.select(
            c.db.areas,
          )..where((t) => t.id.equals('area-dirty'))).getSingle();
          expect(
            row.dirty,
            isTrue,
            reason: 'the mid-push edit must NOT be marked as pushed',
          );
          expect(row.updatedAt, 999);
          expect(await c.service.hasPendingLocalChanges(), isTrue);
        },
      );
    });
  ```

- [ ] **Step 2: Add the ONE new remote double** next to `ThrowingFetchSharedToposRemote` (`sync_service_test.dart:267-272` ✅) and §1d's three doubles.
  > Corrected (D-3): `_ThrowingUpsertRemote` is **gone** — §1d's `ThrowingUpsertSyncRemote` replaces it. `_MidPushWriteRemote` is retyped to `Future<List<TablePushOutcome>>`. Reconciliation's literal `return await super.upsertOwnRows(...)` would strand `onPush()`, which is the entire point of the double; the outcomes are captured, `onPush()` runs, then they are returned.
  ```dart
  /// [FakeSyncRemote] variant that runs [onPush] (a local DB write) in the
  /// MIDDLE of the row push — i.e. after `SyncService.pushOwn` has taken its
  /// snapshot but before it clears any `dirty` flag. This is the only way to
  /// exercise the compare-and-swap window deterministically from a unit test.
  ///
  /// The per-table outcomes from `super` are returned UNCHANGED: this double
  /// simulates a successful push that races a local write, not a failure.
  class _MidPushWriteRemote extends FakeSyncRemote {
    _MidPushWriteRemote(this.onPush);

    final Future<void> Function() onPush;

    @override
    Future<List<TablePushOutcome>> upsertOwnRows(
      String uid,
      Map<String, List<Map<String, dynamic>>> tablesToRows,
    ) async {
      final outcomes = await super.upsertOwnRows(uid, tablesToRows);
      await onPush();
      return outcomes;
    }
  }
  ```

- [ ] **Step 3: Run the new group and watch it fail to compile** (`PushScope` and `hasPendingLocalChanges` do not exist yet).
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/backup/data/sync_service_test.dart
  ```
  Expected: compile errors — `Undefined name 'PushScope'`, `The method 'hasPendingLocalChanges' isn't defined`.

- [ ] **Step 4: Add the drift import to `lib/features/backup/data/sync_service.dart`'s import block** (`:1-8` ✅). `BooleanExpressionOperators` is required for `&` inside a `where`; `Value` for the clearing companions. **Merge into whatever §1d left** — do not replace the block wholesale (§1d may have added `http`/other imports).
  ```dart
  import 'package:drift/drift.dart' show BooleanExpressionOperators, Value;
  import 'package:path/path.dart' as p;

  import '../../../core/db/app_database.dart' as db;
  import '../../account/data/auth_repository.dart';
  import '../../topo/data/photo_files.dart';
  import 'backup_repository.dart';
  import 'connectivity_service.dart';
  import 'sync_remote.dart';
  ```

- [ ] **Step 5: Add `PushScope` above `SyncPushOutcome`.**
  > Corrected (line drift): `enum SyncPushOutcome` is at **`:11`**, not `:10` — `:10` is its doc line. Insert `PushScope` **before `:10`**, i.e. above the enum's doc comment.
  ```dart
  /// How much of the signed-in user's own data one [SyncService.pushOwn] call
  /// sends.
  ///
  /// D-4 keeps the full-state re-push engine and fixes the SCHEDULER; this enum
  /// is that split made explicit rather than an outbox:
  ///  - [full] re-reads and re-sends EVERY own row, exactly as `pushOwn` always
  ///    did. Idempotent and loss-proof: it cannot be defeated by a `dirty` flag
  ///    that was cleared without the row actually landing. `SyncOrchestrator`
  ///    runs one of these on app start and on every connectivity regain.
  ///  - [dirtyOnly] sends just the rows whose `dirty` flag is still set — the
  ///    fast path, and the fix for push cost scaling with library size instead
  ///    of change count (S7).
  ///
  /// Defaults to [full] everywhere, so no existing caller changes behaviour.
  enum PushScope { full, dirtyOnly }
  ```

- [ ] **Step 6: Change `pushOwn`'s signature (`:238` ✅) and narrow its nine snapshot selects.** Also read wall visibility inside the same transaction, so a dirty photo hanging off a CLEAN shared wall still gets its shared copy uploaded.
  ```dart
    Future<PushSyncResult> pushOwn({PushScope scope = PushScope.full}) async {
      final uid = _authRepository.currentSession.uid;
      if (uid == null) return const PushSyncResult.skippedSignedOut();

      if (_wifiOnly()) {
        final status = await _connectivity.currentStatus();
        if (status != NetworkStatus.wifi) {
          return const PushSyncResult.skippedNotWifi();
        }
      }

      final dirtyOnly = scope == PushScope.dirtyOnly;

      // (existing single-transaction rationale comment stays verbatim)
      late List<db.Profile> profiles;
      late List<db.Area> areas;
      late List<db.Sector> sectors;
      late List<db.Wall> walls;
      late List<db.Photo> photos;
      late List<db.Route> routes;
      late List<db.Comment> comments;
      late List<db.Like> likes;
      late List<db.Ascent> ascents;
      // wallId -> visibility for EVERY own wall, dirty or not. Read separately
      // (and as a projection, not whole rows) because `_uploadOwnPhotos` needs a
      // photo's wall visibility to decide whether a SHARED copy is owed — and
      // under [PushScope.dirtyOnly] `walls` above may not contain that wall at
      // all. Deriving the map from `walls` (as this used to) would silently stop
      // uploading the shared copy of a newly-added photo on an already-pushed,
      // therefore clean, shared wall.
      late Map<String, String> wallVisibility;
      await _db.transaction(() async {
        profiles = await (_db.select(_db.profiles)..where((t) => dirtyOnly ? t.ownerId.equals(uid) & t.dirty.equals(true) : t.ownerId.equals(uid))).get();
        areas = await (_db.select(_db.areas)..where((t) => dirtyOnly ? t.ownerId.equals(uid) & t.dirty.equals(true) : t.ownerId.equals(uid))).get();
        sectors = await (_db.select(_db.sectors)..where((t) => dirtyOnly ? t.ownerId.equals(uid) & t.dirty.equals(true) : t.ownerId.equals(uid))).get();
        walls = await (_db.select(_db.walls)..where((t) => dirtyOnly ? t.ownerId.equals(uid) & t.dirty.equals(true) : t.ownerId.equals(uid))).get();
        photos = await (_db.select(_db.photos)..where((t) => dirtyOnly ? t.ownerId.equals(uid) & t.dirty.equals(true) : t.ownerId.equals(uid))).get();
        routes = await (_db.select(_db.routes)..where((t) => dirtyOnly ? t.ownerId.equals(uid) & t.dirty.equals(true) : t.ownerId.equals(uid))).get();
        comments = await (_db.select(_db.comments)..where((t) => dirtyOnly ? t.ownerId.equals(uid) & t.dirty.equals(true) : t.ownerId.equals(uid))).get();
        likes = await (_db.select(_db.likes)..where((t) => dirtyOnly ? t.ownerId.equals(uid) & t.dirty.equals(true) : t.ownerId.equals(uid))).get();
        ascents = await (_db.select(_db.ascents)..where((t) => dirtyOnly ? t.ownerId.equals(uid) & t.dirty.equals(true) : t.ownerId.equals(uid))).get();

        final visibilityQuery = _db.selectOnly(_db.walls)
          ..addColumns([_db.walls.id, _db.walls.visibility])
          ..where(_db.walls.ownerId.equals(uid));
        wallVisibility = {
          for (final row in await visibilityQuery.get())
            row.read(_db.walls.id)!: row.read(_db.walls.visibility)!,
        };
      });
  ```

- [ ] **Step 7: Replace the tail of `pushOwn`.** The fragment's original block replaced the pre-§1d tail (`:338-344`); §1d task 3 already rewrote that region into an `outcomes` aggregation. This step edits §1d's version.
  > Corrected (Decision #13 + #14 + D-25), three separate changes to §1d's tail:
  > 1. **Delete** §1d's `final wallVisibility = {for (final wall in walls) wall.id: wall.visibility};` — Step 6's `selectOnly` projection replaces it (decision #13; that derivation is silently wrong under `dirtyOnly`).
  > 2. **Narrow the dirty clear to the tables §1d reported as landed** (D-25). §1d's `pushOwn` no longer throws on a failed row push — it returns an all-tables-`failed` result — so an unconditional `_clearDirty(tablesToRows)` would mark rows clean that never reached the cloud. This is the single most destructive way to get this wrong.
  > 3. **Rewrite the rationale comment** (decision #14). The original "clear after BOTH phases because bytes might still be missing" reasoning is superseded: once §1f puts the byte upload first, a failed byte upload keeps the row out of `tablesToRows` entirely, so it stays dirty by construction. `_clearDirty` still goes last — because it needs `outcomes` — but for that reason, not the old one. **Do NOT restore the old ordering when §1f lands.**
  ```dart
      // ... §1d's `outcomes` try/catch and its rowsPushed/rowsFailed/errors
      // accumulation loop stay EXACTLY as §1d task 3 wrote them ...

      final photosUploaded = await _uploadOwnPhotos(uid, photos, wallVisibility);

      // Dirty flags are cleared HERE, LAST, and ONLY for the tables this push
      // CONFIRMED.
      //
      // WHY ONLY THE CONFIRMED TABLES (§1d interaction, load-bearing):
      // `upsertOwnRows` reports per-table outcomes and `pushOwn` converts even
      // a whole-call throw into an all-tables-`failed` result rather than
      // propagating it — so "pushOwn returned" is NOT "everything landed".
      // Clearing `dirty` for a table that came back `TablePushOutcome.failed`
      // would mark rows clean that are not in the cloud, and since the retry
      // loop is gated on `dirty` those rows would never be sent again. That is
      // strictly worse than the pre-fix behaviour, which at least never
      // claimed they were clean.
      //
      // WHY LAST, after the photo phase: it needs `outcomes`, which only exist
      // after the row push. Note this is NOT the original §1e reasoning ("a row
      // must not go clean while its pixels are missing") — once §1f flips the
      // order to bytes-then-metadata, a failed byte upload keeps that photo's
      // row out of `tablesToRows` altogether and it stays dirty by
      // construction. §1f moves `_uploadOwnPhotos` ABOVE `upsertOwnRows`; this
      // clear stays at the bottom. Do not "restore" the old ordering.
      final failedTables = <String>{
        for (final outcome in outcomes)
          if (!outcome.ok) outcome.table,
      };
      await _clearDirty({
        for (final entry in tablesToRows.entries)
          if (!failedTables.contains(entry.key)) entry.key: entry.value,
      });

      return PushSyncResult.pushed(
        rowsPushed: rowsPushed,
        photosUploaded: photosUploaded,
        rowsFailed: rowsFailed,
        errors: errors,
      );
    }
  ```

- [ ] **Step 8: Add `_clearDirty`, `_clearDirtyRows` and `hasPendingLocalChanges`** after `pushOwn`, before `_uploadOwnPhotos` (`:364` ✅). **All nine table names are present and verified (D-12): `profiles, areas, sectors, walls, photos, routes, ascents, comments, likes`.**
  ```dart
    /// Clears `dirty` for exactly the rows this push CONFIRMED, matched by the
    /// (`id`, `updatedAt`) PAIR — never by `id` alone.
    ///
    /// THE RACE THIS PREVENTS (the single most dangerous bug in this area): a
    /// local write can land while the push above is awaiting the network. Every
    /// repository write bumps that row's `updatedAt` to a fresh `nowMs()` AND
    /// re-sets `dirty: true` in the SAME companion — verified for all 35 such
    /// writes across `LibraryCrudRepository`, `RouteRepository`,
    /// `PhotoRepository`, `AscentsRepository`, `CommentsRepository`,
    /// `LikesRepository` and `ProfileRepository`. [tablesToRows] was snapshotted
    /// BEFORE the push and therefore carries the OLD `updatedAt`, so requiring
    /// `updatedAt` to still equal the pushed value turns this into a
    /// compare-and-swap: a row rewritten mid-push matches 0 rows, keeps
    /// `dirty: true`, and is picked up by the next push. A clear keyed on `id`
    /// alone would mark that newer edit as pushed and silently lose it.
    ///
    /// The CALLER is responsible for passing only the tables whose
    /// [TablePushOutcome] came back ok — see `pushOwn`'s `failedTables`.
    ///
    /// Rows are grouped by `updatedAt` so ONE statement covers every row a
    /// single user operation touched (a cascade delete stamps one `now` across
    /// area+sector+wall+photos+routes) instead of one statement per row.
    ///
    /// KNOWN, ACCEPTED, NARROW HOLE: two writes to the SAME row inside one
    /// millisecond share an `updatedAt`, so the second would be cleared by this
    /// push. That is the same resolution [shouldPushLww] already relies on, it
    /// needs two distinct user operations on one row within 1 ms, and the
    /// retained [PushScope.full] re-push (app start + every connectivity
    /// regain) re-sends the row regardless of its flag. Closing it properly
    /// needs a monotonic local revision column, i.e. a schema migration — out
    /// of scope here.
    Future<void> _clearDirty(
      Map<String, List<Map<String, dynamic>>> tablesToRows,
    ) async {
      await _db.transaction(() async {
        await _clearDirtyRows(
          tablesToRows['profiles'],
          (ids, updatedAt) => (_db.update(_db.profiles)
                ..where((t) => t.id.isIn(ids) & t.updatedAt.equals(updatedAt)))
              .write(const db.ProfilesCompanion(dirty: Value(false))),
        );
        await _clearDirtyRows(
          tablesToRows['areas'],
          (ids, updatedAt) => (_db.update(_db.areas)
                ..where((t) => t.id.isIn(ids) & t.updatedAt.equals(updatedAt)))
              .write(const db.AreasCompanion(dirty: Value(false))),
        );
        await _clearDirtyRows(
          tablesToRows['sectors'],
          (ids, updatedAt) => (_db.update(_db.sectors)
                ..where((t) => t.id.isIn(ids) & t.updatedAt.equals(updatedAt)))
              .write(const db.SectorsCompanion(dirty: Value(false))),
        );
        await _clearDirtyRows(
          tablesToRows['walls'],
          (ids, updatedAt) => (_db.update(_db.walls)
                ..where((t) => t.id.isIn(ids) & t.updatedAt.equals(updatedAt)))
              .write(const db.WallsCompanion(dirty: Value(false))),
        );
        await _clearDirtyRows(
          tablesToRows['photos'],
          (ids, updatedAt) => (_db.update(_db.photos)
                ..where((t) => t.id.isIn(ids) & t.updatedAt.equals(updatedAt)))
              .write(const db.PhotosCompanion(dirty: Value(false))),
        );
        await _clearDirtyRows(
          tablesToRows['routes'],
          (ids, updatedAt) => (_db.update(_db.routes)
                ..where((t) => t.id.isIn(ids) & t.updatedAt.equals(updatedAt)))
              .write(const db.RoutesCompanion(dirty: Value(false))),
        );
        await _clearDirtyRows(
          tablesToRows['ascents'],
          (ids, updatedAt) => (_db.update(_db.ascents)
                ..where((t) => t.id.isIn(ids) & t.updatedAt.equals(updatedAt)))
              .write(const db.AscentsCompanion(dirty: Value(false))),
        );
        await _clearDirtyRows(
          tablesToRows['comments'],
          (ids, updatedAt) => (_db.update(_db.comments)
                ..where((t) => t.id.isIn(ids) & t.updatedAt.equals(updatedAt)))
              .write(const db.CommentsCompanion(dirty: Value(false))),
        );
        await _clearDirtyRows(
          tablesToRows['likes'],
          (ids, updatedAt) => (_db.update(_db.likes)
                ..where((t) => t.id.isIn(ids) & t.updatedAt.equals(updatedAt)))
              .write(const db.LikesCompanion(dirty: Value(false))),
        );
      });
    }

    /// Groups [rows] by `updatedAt` and hands each `(ids, updatedAt)` batch to
    /// [clearBatch] — the shared body of [_clearDirty]'s nine per-table clears
    /// (each table needs its own statically-typed companion, so only the
    /// grouping can be factored out).
    Future<void> _clearDirtyRows(
      List<Map<String, dynamic>>? rows,
      Future<void> Function(List<String> ids, int updatedAt) clearBatch,
    ) async {
      if (rows == null || rows.isEmpty) return;
      final byUpdatedAt = <int, List<String>>{};
      for (final row in rows) {
        (byUpdatedAt[row['updatedAt'] as int] ??= <String>[])
            .add(row['id'] as String);
      }
      for (final entry in byUpdatedAt.entries) {
        await clearBatch(entry.value, entry.key);
      }
    }

    /// True when at least one row owned by the signed-in user is still `dirty`
    /// — i.e. carries a local change no push has ever CONFIRMED.
    ///
    /// This is the definition of "anything pending" that makes
    /// `SyncOrchestrator`'s retry loop well-defined and terminating (S2: retry
    /// until clean, never give up), and it is what stops a pull's own writes
    /// from triggering a pointless full re-push ~2s later (S9 —
    /// `BackupRepository.importSnapshot` writes every imported row
    /// `dirty: false`).
    ///
    /// `false` when signed out: there is nothing to push, which is not an error
    /// (mirrors [pushOwn]'s `skippedSignedOut`). Deliberately a LIMIT-1
    /// existence probe per table, short-circuiting on the first hit, rather
    /// than a count — the answer is a bool.
    Future<bool> hasPendingLocalChanges() async {
      final uid = _authRepository.currentSession.uid;
      if (uid == null) return false;
      final probes = <Future<Object?> Function()>[
        () => (_db.select(_db.profiles)..where((t) => t.ownerId.equals(uid) & t.dirty.equals(true))..limit(1)).getSingleOrNull(),
        () => (_db.select(_db.areas)..where((t) => t.ownerId.equals(uid) & t.dirty.equals(true))..limit(1)).getSingleOrNull(),
        () => (_db.select(_db.sectors)..where((t) => t.ownerId.equals(uid) & t.dirty.equals(true))..limit(1)).getSingleOrNull(),
        () => (_db.select(_db.walls)..where((t) => t.ownerId.equals(uid) & t.dirty.equals(true))..limit(1)).getSingleOrNull(),
        () => (_db.select(_db.photos)..where((t) => t.ownerId.equals(uid) & t.dirty.equals(true))..limit(1)).getSingleOrNull(),
        () => (_db.select(_db.routes)..where((t) => t.ownerId.equals(uid) & t.dirty.equals(true))..limit(1)).getSingleOrNull(),
        () => (_db.select(_db.ascents)..where((t) => t.ownerId.equals(uid) & t.dirty.equals(true))..limit(1)).getSingleOrNull(),
        () => (_db.select(_db.comments)..where((t) => t.ownerId.equals(uid) & t.dirty.equals(true))..limit(1)).getSingleOrNull(),
        () => (_db.select(_db.likes)..where((t) => t.ownerId.equals(uid) & t.dirty.equals(true))..limit(1)).getSingleOrNull(),
      ];
      for (final probe in probes) {
        if (await probe() != null) return true;
      }
      return false;
    }
  ```

- [ ] **Step 9: Update `pushOwn`'s doc comment (`:226-237` ✅)** to describe the scope parameter and the clear-on-confirm contract.
  > Corrected (D-25): the last paragraph's "on a push that completes without throwing … every row it sent has its `dirty` flag cleared" is false post-§1d. Reworded to "every row in a table the remote CONFIRMED".
  ```dart
    /// Pushes the signed-in user's own rows (all nine tables, INCLUDING
    /// soft-deleted tombstones) up to [SyncRemote.upsertOwnRows], then uploads
    /// each distinct not-yet-uploaded photo file those rows reference — a
    /// private copy always, plus a SECOND shared copy for any photo whose wall
    /// has `visibility == 'shared'` (see [SyncRemote.uploadSharedPhoto]).
    ///
    /// [scope] selects how much is sent: [PushScope.full] (the default, and
    /// what every pre-existing caller gets) re-sends everything;
    /// [PushScope.dirtyOnly] sends only rows still flagged `dirty`. See
    /// [PushScope] for why BOTH exist.
    ///
    /// Every row in a table the remote CONFIRMED (`TablePushOutcome.ok`) has
    /// its `dirty` flag cleared — by an (`id`, `updatedAt`) compare-and-swap
    /// that cannot clobber a local write made mid-push. Rows in a table that
    /// came back `failed` keep their flag, which is what makes the
    /// orchestrator's retry-until-clean loop both correct and terminating. See
    /// [_clearDirty].
    ///
    /// No-ops (never throws) when signed out, or when `wifiOnly` is on and the
    /// current connection isn't wifi — both report a `skipped*` outcome rather
    /// than pushing partial data. Idempotent.
  ```

- [ ] **Step 10: Run the sync_service suite** — the five new tests pass and every pre-existing `pushOwn`/LWW/round-trip test still passes (they all use the unchanged `full` default), including §1d's `§1d (S1): pushOwn tells the truth about what landed` group.
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/backup/data/sync_service_test.dart
  ```
  Expected: all tests pass.

**Assertions:**
- `hasPendingLocalChanges()` is `false` signed out, `true` with a dirty own row, and `false` again after a successful `pushOwn()`.
- A `pushOwn()` against `ThrowingUpsertSyncRemote` returns `fullyLanded == false`, `rowsFailed == 1`, an error mentioning `upsertOwnRows boom`, and **leaves `dirty == true`** on the affected row. **This is the D-25 regression guard** — an unconditional `_clearDirty(tablesToRows)` fails exactly here.
- `pushOwn(scope: PushScope.dirtyOnly)` reports `rowsPushed == 1` for one dirty row alongside a 5-row clean hierarchy, and the remote received only `area-dirty`; the same service's default `pushOwn()` then reports `rowsPushed == 6`.
- A write landing mid-push (fresh `updatedAt` + `dirty: true`) still has `dirty == true` after the push completes, and `hasPendingLocalChanges()` is `true` — the pre-fix id-only clear fails this test.
- **`_clearDirty` covers all nine sync tables** — `grep -c "tablesToRows\['" lib/features/backup/data/sync_service.dart` counts **9** inside `_clearDirty`, and the names are exactly `profiles, areas, sectors, walls, photos, routes, ascents, comments, likes` (D-12: a missing table means those rows never go clean and the retry loop never terminates for them). `hasPendingLocalChanges` probes the same nine.
- No `wallVisibility` derivation from the `walls` list survives anywhere in `pushOwn`: `grep -c 'for (final wall in walls)' lib/features/backup/data/sync_service.dart` is **0** (decision #13).
- Every pre-existing test in `sync_service_test.dart` still passes; `flutter analyze` is 0.
- **Test count: baseline + 5** for this task (D-13).

**Commit:** `feat(sync): dirty-scoped push + race-safe confirmed-push dirty clear`

---

### Task 5: `SyncRetrySchedule` — exponential backoff with jitter, 2s → 5min ceiling

**Runnable in Phase 1** — orphan leaf, two brand-new files, no dependency on §1d. Put in its own file precisely so §1d's large `sync_orchestrator.dart` diff cannot collide with it.

**Files:**
- Create: `lib/features/backup/application/sync_retry_schedule.dart`, `test/features/backup/application/sync_retry_schedule_test.dart`
- Test: `test/features/backup/application/sync_retry_schedule_test.dart`

**Interfaces:**
- Produces: `class SyncRetrySchedule` (`base`, `ceiling`, `envelopeFor(int)`, `delayFor(int)`) and `syncRetryScheduleProvider`.
- Consumes: `dart:math`, `package:flutter_riverpod/flutter_riverpod.dart`; `syncDebounceDurationProvider` (`sync_orchestrator.dart:92`) as the provider-shape template.

**This task's tests are the ONLY place the backoff arithmetic is asserted, and they are entirely clock-free** — no `Timer`, no `Future.delayed`, no `fake_async` (D-18). Keep it that way; Task 6 and Task 10 assert *requested attempt numbers*, never elapsed time.

- [ ] **Step 1: Write the failing test file.** Completely clock-free: the growth/ceiling properties live on the deterministic `envelopeFor`, and jitter is asserted as a bound on `delayFor`.
  ```dart
  import 'dart:math';

  import 'package:masi/features/backup/application/sync_retry_schedule.dart';
  import 'package:flutter_test/flutter_test.dart';

  void main() {
    group('SyncRetrySchedule', () {
      test('production defaults are ~2s doubling to a 5min ceiling', () {
        final schedule = SyncRetrySchedule();
        expect(schedule.base, const Duration(seconds: 2));
        expect(schedule.ceiling, const Duration(minutes: 5));
        expect(schedule.envelopeFor(1), const Duration(seconds: 2));
        expect(schedule.envelopeFor(2), const Duration(seconds: 4));
        expect(schedule.envelopeFor(3), const Duration(seconds: 8));
        expect(schedule.envelopeFor(8), const Duration(seconds: 256));
      });

      test(
        'the envelope grows monotonically and is CLAMPED at the ceiling -- '
        'bounded interval, so it never drifts into never-retrying',
        () {
          final schedule = SyncRetrySchedule();
          for (var attempt = 1; attempt < 40; attempt++) {
            expect(
              schedule.envelopeFor(attempt + 1),
              greaterThanOrEqualTo(schedule.envelopeFor(attempt)),
              reason: 'attempt $attempt -> ${attempt + 1} must not shrink',
            );
            expect(
              schedule.envelopeFor(attempt),
              lessThanOrEqualTo(const Duration(minutes: 5)),
            );
          }
          expect(schedule.envelopeFor(9), const Duration(minutes: 5));
          expect(schedule.envelopeFor(1000), const Duration(minutes: 5));
        },
      );

      test(
        'unbounded attempts: a very high attempt number neither overflows nor '
        'throws -- "never give up" (D-2) means the loop must survive an '
        'outage of any length',
        () {
          final schedule = SyncRetrySchedule(random: Random(7));
          for (final attempt in <int>[0, -1, 1, 100, 1000000]) {
            final delay = schedule.delayFor(attempt);
            expect(delay, greaterThanOrEqualTo(Duration.zero));
            expect(delay, lessThanOrEqualTo(const Duration(minutes: 5)));
          }
        },
      );

      test(
        'delayFor jitters INSIDE [envelope/2, envelope] -- equal jitter, so '
        'consecutive attempts still separate while avoiding a thundering herd',
        () {
          final schedule = SyncRetrySchedule(random: Random(42));
          for (var attempt = 1; attempt <= 12; attempt++) {
            final envelope = schedule.envelopeFor(attempt);
            for (var i = 0; i < 50; i++) {
              final delay = schedule.delayFor(attempt);
              expect(
                delay.inMilliseconds,
                inInclusiveRange(
                  envelope.inMilliseconds ~/ 2,
                  envelope.inMilliseconds,
                ),
                reason: 'attempt $attempt delay $delay outside envelope '
                    '$envelope',
              );
            }
          }
        },
      );

      test('a seeded Random makes delayFor reproducible', () {
        expect(
          [for (var a = 1; a <= 5; a++) SyncRetrySchedule(random: Random(1)).delayFor(a)],
          [for (var a = 1; a <= 5; a++) SyncRetrySchedule(random: Random(1)).delayFor(a)],
        );
      });

      test('base/ceiling are injectable so tests never wait out 2s', () {
        final schedule = SyncRetrySchedule(
          base: const Duration(milliseconds: 10),
          ceiling: const Duration(milliseconds: 40),
          random: Random(3),
        );
        expect(schedule.envelopeFor(1), const Duration(milliseconds: 10));
        expect(schedule.envelopeFor(2), const Duration(milliseconds: 20));
        expect(schedule.envelopeFor(3), const Duration(milliseconds: 40));
        expect(schedule.envelopeFor(9), const Duration(milliseconds: 40));
      });
    });
  }
  ```

- [ ] **Step 2: Run it and watch it fail to resolve the import.**
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/backup/application/sync_retry_schedule_test.dart
  ```
  Expected: `Error: Couldn't resolve the package 'masi' … sync_retry_schedule.dart` / URI does not exist.

- [ ] **Step 3: Create `lib/features/backup/application/sync_retry_schedule.dart`** with the full implementation.
  ```dart
  import 'dart:math';

  import 'package:flutter_riverpod/flutter_riverpod.dart';

  /// The retry cadence `SyncOrchestrator` uses after a FAILED push: exponential
  /// backoff with equal jitter, a bounded interval, and deliberately UNBOUNDED
  /// attempts.
  ///
  /// Why unbounded (D-2, "just make sync bulletproof"): giving up is the one
  /// outcome that loses a topo recorded offline. There is no attempt cap, no
  /// terminal state and no "gave up" status anywhere in this class. What IS
  /// bounded is the INTERVAL — [ceiling] — so a device that has been offline for
  /// a week retries every ~5 minutes forever instead of once a fortnight. The
  /// loop terminates by itself, not by exhaustion: `SyncOrchestrator._runPush`
  /// stops re-arming the timer as soon as nothing is `dirty` (see
  /// `SyncService.hasPendingLocalChanges`).
  ///
  /// Two layers, split so the growth law is testable without a clock:
  ///  - [envelopeFor] is pure and deterministic: `base * 2^(attempt-1)`, clamped
  ///    to [ceiling]. Monotonic non-decreasing.
  ///  - [delayFor] draws the actual delay uniformly from
  ///    `[envelope / 2, envelope]` ("equal jitter"). Full jitter — `[0,
  ///    envelope]` — was rejected: it lets a late attempt fire sooner than an
  ///    early one, which makes "backoff grows on repeated failure" untestable
  ///    and, worse, hammers a struggling backend.
  ///
  /// Injected via [syncRetryScheduleProvider], exactly like
  /// `syncDebounceDurationProvider` (`sync_orchestrator.dart`) — so tests shrink
  /// [base]/[ceiling] to milliseconds and seed [random], instead of waiting out
  /// the production cadence.
  class SyncRetrySchedule {
    SyncRetrySchedule({
      this.base = const Duration(seconds: 2),
      this.ceiling = const Duration(minutes: 5),
      Random? random,
    }) : _random = random ?? Random();

    /// Delay envelope for the FIRST retry.
    final Duration base;

    /// Hard upper bound on any delay this schedule ever returns.
    final Duration ceiling;

    final Random _random;

    /// The un-jittered delay envelope for [attempt] (1-based: 1 is the first
    /// retry after the first failure) — `base * 2^(attempt-1)`, clamped to
    /// [ceiling].
    ///
    /// Computed by an early-returning loop rather than `pow`/`<<`: [attempt] is
    /// unbounded, and `base.inMilliseconds << 60` overflows. The loop can never
    /// run more than ~ceil(log2(ceiling/base)) times (9 with the production
    /// defaults) because it returns the moment it reaches the ceiling.
    Duration envelopeFor(int attempt) {
      if (attempt <= 1) return base <= ceiling ? base : ceiling;
      final ceilingMs = ceiling.inMilliseconds;
      var ms = base.inMilliseconds;
      if (ms >= ceilingMs) return ceiling;
      for (var i = 1; i < attempt; i++) {
        ms *= 2;
        if (ms >= ceilingMs) return ceiling;
      }
      return Duration(milliseconds: ms);
    }

    /// The delay to wait before retry [attempt]: uniform in
    /// `[envelopeFor(attempt) / 2, envelopeFor(attempt)]`.
    Duration delayFor(int attempt) {
      final envelopeMs = envelopeFor(attempt).inMilliseconds;
      final half = envelopeMs ~/ 2;
      // `nextInt`'s argument is exclusive and must be positive; `envelopeMs -
      // half + 1` is >= 1 for every non-negative envelope, so this is safe even
      // for a zero-length envelope (an injected `Duration.zero` base in a test).
      return Duration(milliseconds: half + _random.nextInt(envelopeMs - half + 1));
    }
  }

  /// The [SyncRetrySchedule] `SyncOrchestrator` reads its backoff from —
  /// production defaults (~2s → 5min). Override in tests with millisecond
  /// [SyncRetrySchedule.base]/[SyncRetrySchedule.ceiling] values and a seeded
  /// `Random`, the same way `syncDebounceDurationProvider` is shrunk.
  final syncRetryScheduleProvider = Provider<SyncRetrySchedule>(
    (ref) => SyncRetrySchedule(),
  );
  ```

- [ ] **Step 4: Re-run — all six tests pass.**
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/backup/application/sync_retry_schedule_test.dart
  ```
  Expected: all tests pass.

**Assertions:**
- `envelopeFor` yields 2s, 4s, 8s, …, 256s, then exactly 5min from attempt 9 onward, including at attempt 1000000 (no overflow, no throw).
- `envelopeFor(n+1) >= envelopeFor(n)` for n in 1..39, and every value is `<= 5min`.
- `delayFor(attempt)` always lands in `[envelope/2, envelope]` across 12 attempts × 50 draws.
- `delayFor` is reproducible for a fixed `Random` seed, and `base`/`ceiling` are injectable to millisecond values.
- The test file contains no `Timer`, no `Future.delayed` and no `fake_async` import — `grep -cE 'Timer|Future.delayed|fake_async' test/features/backup/application/sync_retry_schedule_test.dart` is **0**.
- `flutter analyze` reports 0 issues.
- **Test count: baseline + 6** for this task (D-13).

**Commit:** `feat(sync): exponential-backoff retry schedule with jitter (S2)`

---

### Task 6: Orchestrator — push in-flight guard, `pushNow()`, retry-until-clean, nothing-pending early-out

**Corrections here:** D-3 (`_OfflineToggleSyncRemote` retype), D-17 (all three backoff tests rewritten clock-free), D-28 (retry armed on §1d's `!fullyLanded` path, not only in `catch`), decision #6 (`makeContainer` gains only `retrySchedule`), decision #15 (layer on §1d's `_runPush`, don't replace it).

**Files:**
- Modify: `lib/features/backup/application/sync_orchestrator.dart` (imports `:1-10`; fields after `_lastPullStartedAt` `:154`; `_scheduleDebouncedPush` `:189-194`, `onAppPaused` `:199-202`, `_runPush` `:204-220`; `onDispose` `:178-181`; class doc `:94-96` — all ✅ verified), `test/features/backup/application/sync_orchestrator_test.dart`
- Test: `test/features/backup/application/sync_orchestrator_test.dart`

**Interfaces:**
- Produces: `Future<void> SyncOrchestrator.pushNow()`, `_scheduleRetry()`, `_pushInFlight`/`_pushRequestedWhileInFlight`/`_consecutivePushFailures`/`_retryTimer`/`_fullResyncDue`; test doubles `_RecordingRetrySchedule`, `_OfflineToggleSyncRemote`, `_SeededPullSyncRemote`; `insertArea` now seeds `dirty: true`.
- Consumes: §1d's `_runPush` body (`fullyLanded` gate, explicit `SyncOrchestratorState(...)` ctor, `lastPushError`, `await _failedPushStatus()`); §1d's `makeContainer` `connectivityService` param + override; Task 4's `PushScope`/`hasPendingLocalChanges`; Task 5's `syncRetryScheduleProvider`.

- [ ] **Step 1: Replace `insertArea` (`:209-219` ✅) so it seeds `dirty: true`** — the old fixture was unrealistic; every real repository write sets it (Task 3).
  ```dart
    // Replaces the existing insertArea (was lines 209-219).
    /// Inserts one own-row Area, `dirty: true` — the shape EVERY repository
    /// write actually produces (see `LibraryCrudRepository._insertArea`). The
    /// flag matters now that the push is dirty-gated: a fixture row left clean
    /// would be correctly ignored by the orchestrator and every
    /// debounced-push assertion below would vacuously "pass".
    Future<void> insertArea(AppDatabase db, String id, {String? ownerId}) {
      return db.into(db.areas).insert(
        AreasCompanion.insert(
          id: id,
          createdAt: 100,
          updatedAt: 100,
          dirty: const Value(true),
          ownerId: Value(ownerId),
          name: 'Area $id',
        ),
      );
    }
  ```

- [ ] **Step 2: Add ONLY the `retrySchedule` parameter + override to `makeContainer` (`:175-207` ✅),** plus the `syncRetryScheduleProvider` import.
  > Corrected (Decision #6 / D-8): §1d task 7 already added the `_FakeConnectivityService? connectivityService` parameter, the `connectivityServiceProvider.overrideWithValue(connectivityFake)` override and the `SyncService(connectivity: connectivityFake)` reuse. **Restating any of those here is a duplicate-declaration compile error.** This fragment appends `retrySchedule`, its override, and `addTearDown(connectivityFake.dispose)` (which Task 7 makes necessary by giving the fake a `StreamController`).
  ```dart
  import 'package:masi/features/backup/application/sync_retry_schedule.dart';

  // ... inside makeContainer's parameter list, after §1d's `connectivityService`:
      SyncRetrySchedule? retrySchedule,

  // ... inside the overrides list, after syncDebounceDurationProvider:
          if (retrySchedule != null)
            syncRetryScheduleProvider.overrideWithValue(retrySchedule),

  // ... next to §1d's `final connectivityFake = ...` line:
      addTearDown(connectivityFake.dispose);
  ```

- [ ] **Step 3: Add the recording schedule double and the failure-injecting remote** near the top of `sync_orchestrator_test.dart` (after `_ThrowingSharedToposSyncRemote`, which ends at `:115` ✅).
  > Corrected (D-3): `_OfflineToggleSyncRemote.upsertOwnRows` is retyped from `Future<void>` to **`Future<List<TablePushOutcome>>`** — it would not compile after §1d task 2. The online branch returns one `TablePushOutcome.ok(table:, rowsUpserted:)` per non-empty table, using §1d's `const TablePushOutcome.ok({required String table, required int rowsUpserted, int rowsSkippedNewerRemote = 0})` constructor with `rowsSkippedNewerRemote` at its default — byte-identical in shape to §1d's own `_CountingSyncRemote`/`_FailingPushSyncRemote` literals. The offline branch keeps throwing; §1d's `pushOwn` converts that into an all-tables-`failed` result, which is what drives the `!fullyLanded` path this task's retry hangs off.
  ```dart
  /// A [SyncRetrySchedule] that returns a FIXED delay and records the attempt
  /// number it was asked for.
  ///
  /// This is what makes the backoff assertions deterministic without a clock:
  /// growth is asserted on [attempts] (`[1, 2, 3, ...]`, and back to `1` after a
  /// success), NOT by measuring elapsed time — the actual GROWTH LAW is covered
  /// clock-free in `sync_retry_schedule_test.dart`. No test in this file ever
  /// waits out a production interval, and the tests that need N cycles drive
  /// them with N explicit `await pushNow()` calls while [fixed] is set long
  /// enough that the armed timer can never fire on its own.
  class _RecordingRetrySchedule extends SyncRetrySchedule {
    _RecordingRetrySchedule(this.fixed)
      : super(base: fixed, ceiling: fixed, random: Random(1));

    final Duration fixed;
    final List<int> attempts = <int>[];

    @override
    Duration delayFor(int attempt) {
      attempts.add(attempt);
      return fixed;
    }
  }

  /// A [_CountingSyncRemote] whose ROW push fails while [offline] is `true`,
  /// and records what actually landed once it isn't — the "remote unreachable,
  /// then reachable" half of §1e's end-to-end assertion.
  ///
  /// [pushCallCount] is bumped on every ATTEMPT (before the throw), so a test
  /// can distinguish "tried and failed" from "never tried". The throw is NOT
  /// what the orchestrator observes: §1d's `pushOwn` converts a whole-call
  /// upsert throw into an all-tables-`failed` [PushSyncResult], so the
  /// orchestrator sees `fullyLanded == false` and arms the retry from there.
  class _OfflineToggleSyncRemote extends _CountingSyncRemote {
    bool offline = true;
    final Map<String, Map<String, dynamic>> pushedAreas = {};

    @override
    Future<List<TablePushOutcome>> upsertOwnRows(
      String uid,
      Map<String, List<Map<String, dynamic>>> tablesToRows,
    ) async {
      pushCallCount++;
      if (offline) throw Exception('network unreachable');
      for (final row in tablesToRows['areas'] ?? const <Map<String, dynamic>>[]) {
        pushedAreas[row['id'] as String] = Map<String, dynamic>.from(row);
      }
      return [
        for (final entry in tablesToRows.entries)
          if (entry.value.isNotEmpty)
            TablePushOutcome.ok(table: entry.key, rowsUpserted: entry.value.length),
      ];
    }
  }
  ```

- [ ] **Step 4: Add `import 'dart:math';` to `sync_orchestrator_test.dart`'s imports** (needed by `_RecordingRetrySchedule`).
  > Corrected (verification): the fragment's block added both `dart:async` and `dart:math`. **`dart:async` is already imported at `:1`** — adding it again is a duplicate-import analyzer error. Only `dart:math` is new.
  ```dart
  import 'dart:async';
  import 'dart:math';
  ```

- [ ] **Step 5: Append the new failing groups at the end of `main()`.**
  > Corrected (D-17), applied to all three tests in the `S2` group: none of them may count retry completions inside a `Future.delayed` budget. Each now drives its cycles with explicit, fully-awaited `pushNow()` calls — legitimate because `pushNow()` cancels the armed `_retryTimer` on entry, so one explicit call *is* one deterministic retry cycle — and the fixed schedule delay is set long enough (1 hour) that no armed timer can ever interleave. The assertions are strengthened from `take(3)`/`greaterThan` to exact lists and exact counts. The S10 and S9 groups are unchanged apart from the S9 group's unchanged budget, which is an *absence* check with a 15 ms debounce and an 80 ms window.
  ```dart
    group('S10: push in-flight guard', () {
      test(
        'two concurrent push triggers result in exactly ONE in-flight push '
        '(the second returns the SAME Future) -- before this, onAppPaused() '
        'firing mid-push ran a second concurrent full push, duplicating the '
        'LWW pre-check, the upserts and the photo uploads',
        () async {
          final db = AppDatabase(NativeDatabase.memory());
          addTearDown(db.close);
          final remote = _CountingSyncRemote();
          final container = makeContainer(
            db: db,
            remote: remote,
            syncServiceAuth: _FakeAuthRepository(
              const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
            ),
            // Long window so the coalesced follow-up cannot fire mid-test.
            debounce: const Duration(seconds: 30),
          );

          primeOrchestrator(container);
          await Future<void>.delayed(const Duration(milliseconds: 5));

          final notifier = container.read(syncOrchestratorProvider.notifier);
          final first = notifier.pushNow();
          final second = notifier.pushNow();
          expect(
            identical(first, second),
            isTrue,
            reason: 'an overlapping call must return the SAME in-flight Future',
          );

          await Future.wait([first, second]);
          expect(remote.pushCallCount, 1);

          // The guard must release once the push settles.
          await notifier.pushNow();
          expect(remote.pushCallCount, 2);
        },
      );
    });

    group('S2: retry with backoff until clean', () {
      test(
        'a push that fails is retried on the injected backoff, with NO '
        'further user action and NO further local write, and the attempt '
        'number handed to the schedule grows 1, 2, 3',
        () async {
          final db = AppDatabase(NativeDatabase.memory());
          addTearDown(db.close);
          final remote = _OfflineToggleSyncRemote();
          // An hour-long fixed delay: the armed retry timer can NEVER fire
          // inside this test, so each cycle below is exactly one explicit,
          // fully-awaited pushNow() and the recorded attempt numbers are exact
          // rather than "however many happened to complete in N ms".
          final schedule = _RecordingRetrySchedule(const Duration(hours: 1));
          final container = makeContainer(
            db: db,
            remote: remote,
            syncServiceAuth: _FakeAuthRepository(
              const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
            ),
            // Far longer than the test: no debounced push can interleave.
            debounce: const Duration(seconds: 30),
            retrySchedule: schedule,
          );

          primeOrchestrator(container);
          await Future<void>.delayed(const Duration(milliseconds: 5));

          final notifier = container.read(syncOrchestratorProvider.notifier);
          await insertArea(db, 'a1', ownerId: 'u1');

          // Three consecutive FAILED pushes. pushNow() cancels the armed
          // _retryTimer on entry, so an explicit call is one retry cycle.
          for (var i = 0; i < 3; i++) {
            await notifier.pushNow();
          }

          expect(
            remote.pushCallCount,
            3,
            reason: 'each retry must re-attempt without another local write',
          );
          expect(
            schedule.attempts,
            [1, 2, 3],
            reason: 'consecutive failures must escalate the attempt number',
          );
          expect(
            container.read(syncOrchestratorProvider).status,
            SyncStatus.error,
            reason: 'the §1d probe reports reachable by default, so a failed '
                'push classifies as error rather than offline',
          );
        },
      );

      test(
        'the backoff RESETS after a success: a later failure starts again at '
        'attempt 1',
        () async {
          final db = AppDatabase(NativeDatabase.memory());
          addTearDown(db.close);
          final remote = _OfflineToggleSyncRemote();
          final schedule = _RecordingRetrySchedule(const Duration(hours: 1));
          final container = makeContainer(
            db: db,
            remote: remote,
            syncServiceAuth: _FakeAuthRepository(
              const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
            ),
            debounce: const Duration(seconds: 30),
            retrySchedule: schedule,
          );

          primeOrchestrator(container);
          await Future<void>.delayed(const Duration(milliseconds: 5));

          final notifier = container.read(syncOrchestratorProvider.notifier);
          await insertArea(db, 'a1', ownerId: 'u1');

          await notifier.pushNow();
          expect(schedule.attempts, [1]);

          remote.offline = false;
          await notifier.pushNow();
          expect(container.read(syncOrchestratorProvider).status, SyncStatus.idle);

          schedule.attempts.clear();
          remote.offline = true;
          await insertArea(db, 'a2', ownerId: 'u1');
          await notifier.pushNow();

          expect(
            schedule.attempts,
            [1],
            reason: 'a confirmed push must reset the failure counter',
          );
        },
      );

      test(
        'the retry loop TERMINATES once nothing is dirty -- a clean database '
        'hits the nothing-pending early-out and never reaches the remote, so '
        'this is a loop with unbounded attempts, not an unbounded loop',
        () async {
          final db = AppDatabase(NativeDatabase.memory());
          addTearDown(db.close);
          final remote = _CountingSyncRemote();
          final schedule = _RecordingRetrySchedule(const Duration(hours: 1));
          final container = makeContainer(
            db: db,
            remote: remote,
            syncServiceAuth: _FakeAuthRepository(
              const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
            ),
            debounce: const Duration(seconds: 30),
            retrySchedule: schedule,
          );

          primeOrchestrator(container);
          await Future<void>.delayed(const Duration(milliseconds: 5));

          final notifier = container.read(syncOrchestratorProvider.notifier);
          await insertArea(db, 'a1', ownerId: 'u1');

          await notifier.pushNow();
          final settled = remote.pushCallCount;
          expect(settled, 1, reason: 'the dirty row was pushed exactly once');

          // The confirmed push cleared `dirty`, which itself fires
          // tableUpdates(). A follow-up push must find nothing pending and
          // never touch the network.
          await notifier.pushNow();
          expect(
            remote.pushCallCount,
            settled,
            reason: 'a clean database must not keep re-pushing',
          );
          expect(schedule.attempts, isEmpty, reason: 'nothing ever failed');
        },
      );
    });

    group('S9: a pull does not trigger a re-push', () {
      test(
        'importing a pulled snapshot marks nothing dirty and reaches the '
        'remote with no push -- before this, every pull that wrote anything '
        "fired the same tableUpdates() the debounced push listens to",
        () async {
          final db = AppDatabase(NativeDatabase.memory());
          addTearDown(db.close);
          final remote = _SeededPullSyncRemote();
          final container = makeContainer(
            db: db,
            remote: remote,
            syncServiceAuth: _FakeAuthRepository(
              const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
            ),
            debounce: const Duration(milliseconds: 15),
          );

          primeOrchestrator(container);
          await Future<void>.delayed(const Duration(milliseconds: 5));

          final notifier = container.read(syncOrchestratorProvider.notifier);
          // Consume the app-start full-resync push so the assertion below is
          // about the PULL, not about that one-off safety net.
          await notifier.pushNow();
          final pushesBefore = remote.pushCallCount;

          await notifier.pullNow();
          await Future<void>.delayed(const Duration(milliseconds: 80));

          expect(
            remote.pushCallCount,
            pushesBefore,
            reason: "a pull's own writes must not schedule a push",
          );
          final imported = await (db.select(
            db.areas,
          )..where((t) => t.id.equals('area-cloud'))).getSingle();
          expect(imported.dirty, isFalse);
        },
      );
    });
  ```

- [ ] **Step 6: Add the `_SeededPullSyncRemote` double** used by the S9 test, next to the other doubles. Its area row deliberately omits `dirty`/`remoteId` — the exact shape a cloud row comes back in after Task 2. (It overrides `fetchOwnRows` only, so §1d's signature change does not touch it.)
  ```dart
  /// A [_CountingSyncRemote] whose own-row fetch returns one real Area row, so
  /// `pullOwnAndShared()` actually WRITES to the local database (which is what
  /// used to trigger the spurious re-push). The row omits `dirty`/`remoteId`
  /// entirely — the shape a cloud row has now that the push strips them (see
  /// `stripLocalOnlySyncColumns`).
  class _SeededPullSyncRemote extends _CountingSyncRemote {
    @override
    Future<Map<String, List<Map<String, dynamic>>>> fetchOwnRows(String uid) async {
      pullCallCount++;
      return {
        for (final t in syncTableNames) t: <Map<String, dynamic>>[],
        'areas': <Map<String, dynamic>>[
          {
            'id': 'area-cloud',
            'createdAt': 100,
            'updatedAt': 100,
            'ownerId': uid,
            'name': 'Cloud Area',
          },
        ],
      };
    }
  }
  ```

- [ ] **Step 7: Run the file and watch the new groups fail to compile** (`pushNow` does not exist).
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/backup/application/sync_orchestrator_test.dart
  ```
  Expected: compile error — `The method 'pushNow' isn't defined for the class 'SyncOrchestrator'`.

- [ ] **Step 8: Add the new imports to `lib/features/backup/application/sync_orchestrator.dart`** (`:1-10` ✅). Merge with whatever §1d left there.
  ```dart
  import 'dart:async';

  import 'package:flutter/foundation.dart';
  import 'package:flutter_riverpod/flutter_riverpod.dart';

  import '../../../core/db/database_provider.dart';
  import '../../account/application/auth_providers.dart';
  import '../../account/data/auth_repository.dart';
  import '../data/sync_service.dart';
  import 'sync_providers.dart';
  import 'sync_retry_schedule.dart';
  ```

- [ ] **Step 9: Add the new fields to `SyncOrchestrator`,** after `_lastPullStartedAt` (`:154` ✅).
  ```dart
    /// The currently in-flight [pushNow] call's [Future], or `null` when no
    /// push is running — the push-side twin of [_pullInFlight].
    ///
    /// S10: there was NO push guard at all. `onAppPaused()` cancelled the
    /// debounce timer but not a running `_runPush`, so backgrounding the app
    /// mid-push ran a SECOND concurrent full push — duplicating the per-table
    /// LWW pre-check, the upserts and the photo uploads.
    Future<void>? _pushInFlight;

    /// Set when a push trigger arrives while [_pushInFlight] is non-null.
    ///
    /// The coalesced trigger is NOT simply dropped: it may be the only signal
    /// that a local write landed DURING the in-flight push (whose snapshot
    /// predates it). Instead it re-arms the debounce window once the push
    /// settles, so a follow-up push sees the newer `dirty` rows. When the
    /// trigger really was redundant the follow-up is free — [_runPush] finds
    /// nothing dirty and never touches the network.
    bool _pushRequestedWhileInFlight = false;

    /// Consecutive FAILED pushes since the last confirmed one — the attempt
    /// number handed to [SyncRetrySchedule.delayFor]. Deliberately uncapped
    /// (D-2: bounded interval, unbounded attempts, never give up). Reset by a
    /// confirmed push, by a push that found nothing pending, and by a
    /// connectivity regain.
    int _consecutivePushFailures = 0;

    /// The pending backoff retry armed by [_scheduleRetry], or `null`.
    Timer? _retryTimer;

    /// True while a [PushScope.full] push is still owed.
    ///
    /// Starts `true` so the FIRST push of every app run re-sends every own row:
    /// the D-4 loss-proof safety net that recovers any row whose `dirty` flag
    /// was cleared without the row actually landing. Set again on every
    /// connectivity regain; cleared only by a CONFIRMED full push
    /// ([PushSyncResult.fullyLanded]).
    bool _fullResyncDue = true;
  ```
  > Corrected (§1d interaction): the fragment's doc for `_fullResyncDue` said "*today `SupabaseSyncRemote.upsertOwnRows` still swallows a per-table failure — that is S1/§1d's job, and this flag is what bounds its blast radius meanwhile*". §1d has already landed by the time this task runs, so that parenthetical is stale and is dropped; the flag's remaining job is recovering from a `dirty` flag cleared without the row landing (which Task 4's `failedTables` narrowing makes much rarer, but does not make impossible — e.g. a clear that succeeds while a later table's upsert is rejected).

- [ ] **Step 10: Replace `_scheduleDebouncedPush`, `onAppPaused` and `_runPush`** (`:186-220` ✅) with the guarded versions, and add `pushNow`/`_scheduleRetry`.
  > Corrected (D-28 + decision #15): `_runPush` is written **against §1d's post-task-5/7 body**, not the pre-§1d one. Two changes beyond the fragment's version: (a) the `SyncStatus.idle`/failure states use §1d's explicit `SyncOrchestratorState(...)` constructor with `lastPushError` and `await _failedPushStatus()`, not `copyWith(status: …)`; (b) **`_scheduleRetry()` is called on BOTH failure paths** — the `!fullyLanded` branch as well as the `catch`. The fragment armed the retry only in `catch`, but post-§1d the dominant failure mode is a push that *returns* with `fullyLanded == false` and never throws, so the retry loop would have been dead for the most common real failure (a per-table cloud rejection, an expired JWT, a required-field exclusion).
  ```dart
    /// (Re)schedules a single push [syncDebounceDurationProvider] from NOW —
    /// every call before the window elapses cancels and restarts the timer, so
    /// N rapid local writes coalesce into exactly one push.
    void _scheduleDebouncedPush() {
      _debounceTimer?.cancel();
      _debounceTimer = Timer(ref.read(syncDebounceDurationProvider), () {
        unawaited(pushNow());
      });
    }

    /// Pushes immediately, cancelling any still-pending debounced push —
    /// called when the app is about to leave the foreground and might get
    /// killed before a debounced push would otherwise have fired. Funnels
    /// through [pushNow], so it can no longer race a push already in flight
    /// (S10).
    void onAppPaused() {
      unawaited(pushNow());
    }

    /// Pushes NOW, cancelling any pending debounced push or armed retry — the
    /// push-side twin of [pullNow], and the SINGLE funnel every push trigger in
    /// this class goes through: the debounce timer, [onAppPaused], app-resume
    /// (`app.dart`), connectivity regain, and the backoff retry. Exactly one
    /// push can therefore be in flight at a time (S10).
    ///
    /// A call made while an earlier push is still in flight returns THAT SAME
    /// [Future] instead of starting a second one, and re-arms the debounce
    /// window once it settles so a write that landed mid-push is not dropped
    /// (see [_pushRequestedWhileInFlight]). A call made once the in-flight push
    /// has completed starts a fresh one.
    ///
    /// Never throws, and is a safe no-op when signed out, when nothing is
    /// locally dirty, or when Supabase is unavailable — [_runPush] catches
    /// everything and translates it into a [SyncStatus] plus, on failure, a
    /// scheduled retry.
    Future<void> pushNow() {
      final inFlight = _pushInFlight;
      if (inFlight != null) {
        _pushRequestedWhileInFlight = true;
        return inFlight;
      }
      _debounceTimer?.cancel();
      _retryTimer?.cancel();
      final future = _runPush();
      _pushInFlight = future;
      unawaited(
        future.whenComplete(() {
          if (identical(_pushInFlight, future)) {
            _pushInFlight = null;
          }
          if (_pushRequestedWhileInFlight) {
            _pushRequestedWhileInFlight = false;
            _scheduleDebouncedPush();
          }
        }),
      );
      return future;
    }

    /// S1 fix (§1d): only a push where EVERYTHING landed
    /// ([PushSyncResult.fullyLanded]) may report [SyncStatus.idle] and stamp a
    /// fresh `lastSyncedAt`.
    ///
    /// S2 fix (§1e), layered on top: the scope is chosen from [_fullResyncDue],
    /// a push with nothing pending is a no-op that never touches `state`, and
    /// EVERY failure path arms a backoff retry. Note a failed push does NOT
    /// throw — §1d converts a whole-call upsert throw into an
    /// all-tables-failed RESULT — so the `!fullyLanded` branch, not the
    /// `catch`, is the one that fires in practice.
    Future<void> _runPush() async {
      final service = ref.read(syncServiceProvider);
      final scope = _fullResyncDue ? PushScope.full : PushScope.dirtyOnly;

      // S9: `BackupRepository.importSnapshot`'s writes fire the same
      // `tableUpdates()` this class debounces on, so before the `dirty` gate
      // every pull that wrote anything scheduled a full re-push ~2s later.
      // Imported rows are written `dirty: false`, so "nothing pending" is now a
      // cheap, correct no-op. It returns WITHOUT touching `state`, deliberately:
      // flipping to `syncing`/`idle` here would clobber a real `error` status or
      // a live `lastPullError`/`lastPushError` with the outcome of a push that
      // never happened.
      if (scope == PushScope.dirtyOnly &&
          !await service.hasPendingLocalChanges()) {
        _consecutivePushFailures = 0;
        return;
      }

      state = state.copyWith(status: SyncStatus.syncing);
      try {
        final result = await service.pushOwn(scope: scope);
        switch (result.outcome) {
          case SyncPushOutcome.pushed:
            if (result.fullyLanded) {
              // Only a CONFIRMED full push retires the safety net.
              if (scope == PushScope.full) _fullResyncDue = false;
              _consecutivePushFailures = 0;
              _retryTimer?.cancel();
              state = SyncOrchestratorState(
                status: SyncStatus.idle,
                lastSyncedAt: _now(),
                lastPullError: state.lastPullError,
              );
            } else {
              state = SyncOrchestratorState(
                status: await _failedPushStatus(),
                lastSyncedAt: state.lastSyncedAt,
                lastPullError: state.lastPullError,
                lastPushError:
                    'Sync failed: ${result.rowsFailed} change(s) not uploaded — '
                    '${result.errors.join('; ')}',
              );
              _scheduleRetry();
            }
          case SyncPushOutcome.skippedSignedOut:
            _consecutivePushFailures = 0;
            _retryTimer?.cancel();
            state = state.copyWith(status: SyncStatus.idle);
          case SyncPushOutcome.skippedNotWifi:
            // Not a failure, and deliberately NOT retried on a timer: this
            // condition only changes when the network changes, and
            // [_onConnectivityChanged] already pushes on every regain. Arming a
            // backoff here would spin a timer that can never succeed.
            state = state.copyWith(status: SyncStatus.offline);
        }
      } catch (e, st) {
        debugPrint('SyncOrchestrator: pushOwn failed: $e\n$st');
        state = SyncOrchestratorState(
          status: await _failedPushStatus(),
          lastSyncedAt: state.lastSyncedAt,
          lastPullError: state.lastPullError,
          lastPushError: 'Sync failed: $e',
        );
        _scheduleRetry();
      }
    }

    /// Arms the next retry, [SyncRetrySchedule.delayFor] from now.
    ///
    /// Bounded interval (~2s doubling to a 5min ceiling, jittered), unbounded
    /// attempts: this NEVER gives up while anything is still `dirty` (D-2). The
    /// loop terminates by SUCCESS, not by exhaustion — a retry that finds a
    /// clean database hits [_runPush]'s nothing-pending early-out and simply
    /// returns without re-arming.
    void _scheduleRetry() {
      _consecutivePushFailures++;
      _retryTimer?.cancel();
      final delay = ref
          .read(syncRetryScheduleProvider)
          .delayFor(_consecutivePushFailures);
      _retryTimer = Timer(delay, () => unawaited(pushNow()));
    }
  ```

- [ ] **Step 11: Extend `ref.onDispose`** (`:178-181` ✅) to cancel the retry timer.
  ```dart
      ref.onDispose(() {
        _debounceTimer?.cancel();
        _retryTimer?.cancel();
        _dbSubscription?.cancel();
      });
  ```

- [ ] **Step 12: Update the class doc** (`:94-96` — the first paragraph of the block spanning `:94-122`) so it stops describing the pre-fix trigger set.
  ```dart
  /// Opportunistic background-sync controller: debounced push-on-local-write,
  /// pull-once-on-sign-in, push-on-app-background/resume, push+pull on
  /// connectivity regain, and — when a push fails — an exponential-backoff
  /// retry that keeps going until nothing is locally `dirty` (§1e; S2/S3/S10).
  /// Every push trigger funnels through [pushNow], every pull trigger through
  /// [pullNow], so at most one of each can be in flight at a time.
  ```

- [ ] **Step 13: Run the orchestrator suite** — the new groups pass, and the pre-existing E1a/E1b/E1c/onAppPaused/#57/#72/status-transition groups (`:221`, `:270`, `:324`, `:390`, `:430`, `:531`, `:615`, `:681`) stay green.
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/backup/application/sync_orchestrator_test.dart
  ```
  Expected: all tests pass.

**Assertions:**
- Two back-to-back `pushNow()` calls return an identical `Future` and produce exactly ONE `upsertOwnRows` call; a third call after they settle produces a second.
- Three consecutive failing `pushNow()` calls produce `pushCallCount == 3` with no further local write, and `schedule.attempts == [1, 2, 3]` **exactly** — asserted on the *requested attempt numbers*, with **no wall-clock budget anywhere** (D-17). Status is `SyncStatus.error` (the §1d probe fake reports reachable by default).
- After a success the failure counter resets: the next failure records `attempts == [1]`.
- With a clean database a second `pushNow()` adds no remote call and the retry schedule is never consulted — the loop terminates via the nothing-pending early-out.
- A `pullNow()` that imports a row adds no `upsertOwnRows` call, and the imported row has `dirty == false`.
- **`_scheduleRetry()` is reachable from both failure paths:** `grep -c '_scheduleRetry();' lib/features/backup/application/sync_orchestrator.dart` is **2** (D-28). A count of 1 means the retry loop is dead for §1d's non-throwing failure.
- No test in this file contains a retry-count assertion inside a `Future.delayed` window: `grep -n 'attempts' test/features/backup/application/sync_orchestrator_test.dart` shows only exact-list/`isEmpty`/`isNotEmpty` comparisons.
- Pre-existing assertions still hold: 3 rapid writes coalesce to 1 push and a 4th write pushes again (E1a); signed-out never reaches the remote and status is not `error` (E1c); `wifiOnly` + cellular yields `SyncStatus.offline`; `onAppPaused` pushes once and cancels the pending debounce; a successful push stamps `lastSyncedAt` from `nowMsProvider`.
- `flutter analyze` reports 0 issues.
- **Test count: baseline + 5** for this task (D-13).

**Commit:** `feat(sync): push in-flight guard + retry-until-clean backoff loop (S2, S10)`

---

### Task 7: `ConnectivityService.statusChanges()` — `connectivity_plus` on native, browser `online`/`offline` on web

**Corrections here:** decisions #1/#2/#3 (additive patch, never a whole-file re-emit), decisions #4/#5/#6 (extend §1d's union fakes, don't restate them), and D-9's placeholder problem dissolved by not touching `NetworkStatus` at all.

**Files:**
- Create: `lib/features/backup/data/online_events.dart`, `lib/features/backup/data/online_events_native.dart`, `lib/features/backup/data/online_events_web.dart`
- Modify: `lib/features/backup/data/connectivity_service.dart` (additively), `test/features/backup/data/sync_service_test.dart` (`FakeConnectivityService`, `:276-283` ✅), `test/features/backup/data/cloud_backup_service_test.dart` (`:74-81` ✅), `test/app/app_test.dart` (`:132-135` ✅), `test/features/backup/application/sync_orchestrator_test.dart` (`_FakeConnectivityService`, `:143-150` ✅)
- Test: `test/features/backup/data/connectivity_service_test.dart`

**Interfaces:**
- Produces: `Stream<NetworkStatus> ConnectivityService.statusChanges();` (new abstract member), `NetworkStatus classifyConnectivityResults(List<ConnectivityResult>)`, `Stream<bool> onlineEvents()` (two-way conditional-export seam), `_FakeConnectivityService.emit`/`.dispose`.
- Consumes: §1d's `ConnectivityService` (with `isBackendReachable()`) and its 3-positional `SystemConnectivityService([Connectivity?, bool?, http.Client?])`; `enum NetworkStatus` (`:7-19`, doc from `:4`); `currentStatus()`'s 8-line web short-circuit comment (`:45-52` ✅) and its inline if-chain (`:55-65`); `lib/app/web_lifecycle.dart:25-26` as the facade template; `connectivity_plus` 7.3.0 `Connectivity.onConnectivityChanged`.

> ⚠️ **Read the [critical non-collision hazard](#️-critical-non-collision-hazard--do-not-simplify-the-plugin-probe) before writing the probe.** `test/widget_test.dart` mounts `MasiApp` twice with no `connectivityServiceProvider` override and is owned by no Stage-1 fragment. The `checkConnectivity()` `MethodChannel` probe is the only thing that keeps it green once Task 8 subscribes unconditionally.

- [ ] **Step 1: Append the failing group to `test/features/backup/data/connectivity_service_test.dart`.** (39 lines today, one group `SystemConnectivityService web short-circuit` at `:14-38`; §1d task 6 will have added its own probe group.)
  ```dart
    group('classifyConnectivityResults', () {
      test('wifi/ethernet -> wifi, mobile -> cellular, none/empty -> none, '
          'anything else -> other', () {
        expect(
          classifyConnectivityResults([ConnectivityResult.wifi]),
          NetworkStatus.wifi,
        );
        expect(
          classifyConnectivityResults([ConnectivityResult.ethernet]),
          NetworkStatus.wifi,
        );
        expect(
          classifyConnectivityResults([
            ConnectivityResult.mobile,
            ConnectivityResult.wifi,
          ]),
          NetworkStatus.wifi,
          reason: 'wifi wins when both are reported',
        );
        expect(
          classifyConnectivityResults([ConnectivityResult.mobile]),
          NetworkStatus.cellular,
        );
        expect(
          classifyConnectivityResults([ConnectivityResult.none]),
          NetworkStatus.none,
        );
        expect(classifyConnectivityResults([]), NetworkStatus.none);
        expect(
          classifyConnectivityResults([ConnectivityResult.vpn]),
          NetworkStatus.other,
        );
      });
    });

    group('SystemConnectivityService.statusChanges', () {
      test(
        'with no registered plugin the stream is INERT: it completes without '
        'emitting and without reporting a FlutterError. This is the contract '
        'every widget test that mounts MasiApp without overriding '
        'connectivityServiceProvider depends on -- an EventChannel whose '
        'plugin is missing reports through FlutterError.reportError, which no '
        'caller-side try/catch or Stream.onError can intercept.',
        () async {
          final errors = <FlutterErrorDetails>[];
          final previousOnError = FlutterError.onError;
          FlutterError.onError = errors.add;
          addTearDown(() => FlutterError.onError = previousOnError);

          final service = SystemConnectivityService(null, false);
          final emitted = await service.statusChanges().toList();

          expect(emitted, isEmpty);
          expect(errors, isEmpty);
        },
      );

      test('on web the stream maps browser online/offline onto wifi/none '
          '(inert under the VM target, where the native seam half is picked)',
          () async {
        final service = SystemConnectivityService(null, true);
        expect(await service.statusChanges().toList(), isEmpty);
      });
    });
  ```

- [ ] **Step 2: Add the imports the new group needs.** Merge with whatever §1d task 6 left in place — do not replace the import block.
  ```dart
  import 'package:connectivity_plus/connectivity_plus.dart';
  import 'package:masi/features/backup/data/connectivity_service.dart';
  import 'package:flutter/foundation.dart';
  import 'package:flutter_test/flutter_test.dart';
  ```

- [ ] **Step 3: Run it and watch it fail to compile.**
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/backup/data/connectivity_service_test.dart
  ```
  Expected: compile errors — `Undefined name 'classifyConnectivityResults'`, `The method 'statusChanges' isn't defined`.

- [ ] **Step 4: Create the facade `lib/features/backup/data/online_events.dart`.**
  ```dart
  // Facade for the browser's `online`/`offline` window events — the WEB half of
  // [ConnectivityService.statusChanges] (`connectivity_service.dart`).
  //
  // Two-way split (native/web, no `_stub.dart`), exactly like
  // `lib/app/web_lifecycle.dart` and for the same reason: this is a web-only
  // affordance. Native platforms already have a real connectivity signal —
  // `connectivity_plus`'s `onConnectivityChanged` — so there is nothing for a
  // browser event hook to add there; the three-way split used by
  // `lib/features/topo/data/photo_files.dart` exists for APIs that need a
  // distinct plain-Dart stub, which this does not.
  //  - native (iOS/Android/desktop) AND plain-Dart tests: an inert,
  //    never-emitting stream — picked whenever `dart.library.js_interop` is
  //    unavailable. Native behaviour is completely unchanged by this facade's
  //    existence.
  //  - web: real `online`/`offline` window listeners, implemented with
  //    `package:web` + `dart:js_interop` ONLY — never `dart:html`, never
  //    `dart:io` — so this stays wasm-clean and keeps the repo's
  //    `grep -r "dart:io" lib --include="*.dart" | grep -v _native.dart` gate
  //    green.
  export 'online_events_native.dart'
      if (dart.library.js_interop) 'online_events_web.dart';
  ```

- [ ] **Step 5: Create `lib/features/backup/data/online_events_native.dart`.**
  ```dart
  /// No-op on native platforms (iOS/Android/desktop) and plain-Dart tests —
  /// picked whenever `dart.library.js_interop` is unavailable (see
  /// `online_events.dart`'s facade doc).
  ///
  /// Native connectivity transitions come from `connectivity_plus`'s
  /// `Connectivity.onConnectivityChanged` instead (see
  /// `SystemConnectivityService.statusChanges`), so there is nothing for a
  /// browser event hook to contribute here: this stream never emits and closes
  /// immediately.
  Stream<bool> onlineEvents() => const Stream<bool>.empty();
  ```

- [ ] **Step 6: Create `lib/features/backup/data/online_events_web.dart`.**
  ```dart
  import 'dart:async';
  import 'dart:js_interop';

  import 'package:web/web.dart' as web;

  /// Real web implementation (see `online_events.dart`'s facade doc): emits
  /// `true` on every `online` window event and `false` on every `offline` one.
  ///
  /// Listeners are wired LAZILY — added on the first subscription, removed again
  /// when the last subscriber cancels — so an unlistened stream leaves no
  /// `window` listener behind and a disposed `SyncOrchestrator` detaches cleanly.
  /// Broadcast, because these are ambient page events with no backpressure and
  /// no meaningful buffering: an event that fires while nobody is listening is
  /// correctly dropped.
  ///
  /// HONEST LIMITATION (same shape as `web_lifecycle_web.dart`'s): `online` is a
  /// heuristic — the browser reports it for any network interface being up, so a
  /// captive portal still says "online". That is fine for this use: the event
  /// only ever TRIGGERS a sync attempt, and the attempt itself is what
  /// establishes real reachability (§1d's probe). A false positive costs one
  /// failed push that the backoff loop retries; a missed event costs nothing,
  /// because the debounce/resume triggers still exist.
  Stream<bool> onlineEvents() {
    final controller = StreamController<bool>.broadcast();
    final onOnline = ((web.Event _) => controller.add(true)).toJS;
    final onOffline = ((web.Event _) => controller.add(false)).toJS;
    controller
      ..onListen = () {
        web.window.addEventListener('online', onOnline);
        web.window.addEventListener('offline', onOffline);
      }
      ..onCancel = () {
        web.window.removeEventListener('online', onOnline);
        web.window.removeEventListener('offline', onOffline);
      };
    return controller.stream;
  }
  ```

- [ ] **Step 7: Patch `lib/features/backup/data/connectivity_service.dart` ADDITIVELY.**
  > Corrected (Decisions #1, #2, #3 / D-9): the fragment emitted the **whole file**, whose `abstract class ConnectivityService` listed only `currentStatus()` + `statusChanges()` — silently **deleting §1d's `Future<bool> isBackendReachable();`** — and whose `SystemConnectivityService([Connectivity? connectivity, bool? isWeb])` silently **deleted §1d's third positional `http.Client?`**. It also carried three `// ... unchanged ...` placeholders that would not compile. This step is therefore restructured as four surgical additions. `enum NetworkStatus` (`:7-19`, doc from `:4`) is **not touched**, which dissolves the placeholder entirely. Never re-emit the abstract class wholesale.

  **7a. Add the facade import** next to the existing ones (`connectivity_plus`, `flutter/foundation.dart show kIsWeb`, plus §1d's `http`):
  ```dart
  import 'online_events.dart';
  ```

  **7b. ADD one member to the existing `abstract class ConnectivityService`** (`:25`), below `currentStatus()` and alongside §1d's `isBackendReachable()`. Do not restate the class header or §1d's member.
  ```dart
    /// Emits the NEW [NetworkStatus] every time the platform reports a
    /// connectivity transition — the signal `SyncOrchestrator` listens on to
    /// push AND pull the moment the network comes back.
    ///
    /// S3: nothing reacted to connectivity returning at all before this
    /// (`grep -rn "onConnectivityChanged" lib` returned zero hits), so a user
    /// who edited offline and then neither wrote again nor backgrounded the app
    /// stayed unsynced indefinitely.
    ///
    /// CONTRACT — implementations MUST NOT throw, and MUST degrade to a stream
    /// that simply never emits when the underlying platform signal is
    /// unavailable (an unsupported platform, or a unit/widget test with no
    /// registered plugin). Subscribers read "no events" as "no transitions",
    /// never as an error.
    Stream<NetworkStatus> statusChanges();
  ```

  **7c. Extract the classifier as a top-level function** (decision #3) and insert it between the abstract class and `SystemConnectivityService`:
  ```dart
  /// Collapses `connectivity_plus`'s finer-grained [ConnectivityResult] list
  /// into this app's [NetworkStatus].
  ///
  /// Shared by [SystemConnectivityService.currentStatus] and
  /// [SystemConnectivityService.statusChanges] so a one-shot read and a stream
  /// event can never disagree; top-level (rather than a private method) purely
  /// so the mapping is directly unit-testable without a platform channel.
  NetworkStatus classifyConnectivityResults(List<ConnectivityResult> results) {
    if (results.contains(ConnectivityResult.wifi) ||
        results.contains(ConnectivityResult.ethernet)) {
      return NetworkStatus.wifi;
    }
    if (results.contains(ConnectivityResult.mobile)) {
      return NetworkStatus.cellular;
    }
    if (results.isEmpty || results.contains(ConnectivityResult.none)) {
      return NetworkStatus.none;
    }
    return NetworkStatus.other;
  }
  ```
  Then replace **only** `currentStatus`'s if-chain body (`:55-65`) with the delegation, keeping the 8-line web short-circuit comment (`:45-52`) and the `if (_isWeb) return NetworkStatus.wifi;` line (`:53`) byte-for-byte:
  ```dart
      return classifyConnectivityResults(await _connectivity.checkConnectivity());
  ```

  **7d. Add the two new methods to `SystemConnectivityService`,** alongside §1d's `isBackendReachable`. The constructor and both existing fields are inherited untouched — §1d's 3-positional `([Connectivity? connectivity, bool? isWeb, http.Client? httpClient])` form stands.
  ```dart
    @override
    Stream<NetworkStatus> statusChanges() {
      // Web: `connectivity_plus`'s browser implementation can only distinguish
      // online from offline, and [currentStatus] deliberately reports `wifi`
      // unconditionally there (see its comment), so use the browser's own
      // `online`/`offline` window events — behind the conditional-import seam
      // in `online_events.dart` — and map them onto the only two values a
      // browser can actually tell apart.
      if (_isWeb) {
        return onlineEvents().map(
          (online) => online ? NetworkStatus.wifi : NetworkStatus.none,
        );
      }
      return _nativeStatusChanges();
    }

    /// Native transitions, gated behind a CATCHABLE plugin-availability probe.
    ///
    /// `Connectivity.onConnectivityChanged` is an `EventChannel`, and an
    /// EventChannel whose plugin isn't registered reports its failure through
    /// `FlutterError.reportError` — which `testWidgets` turns into a HARD test
    /// failure that no caller-side `try`/`catch` or `Stream.onError` can
    /// intercept. `checkConnectivity()` is a plain `MethodChannel` call on the
    /// same plugin, so it throws a catchable `MissingPluginException` instead:
    /// probe with that FIRST and only subscribe to the event channel once the
    /// plugin has proven itself present.
    ///
    /// This is what makes the contract on [ConnectivityService.statusChanges]
    /// hold for free in every unit/widget test that mounts `MasiApp` without
    /// overriding `connectivityServiceProvider` (`widget_test.dart:79` and
    /// `:2119`, `app_test.dart:148` and `:318`) — the stream silently never
    /// emits instead of failing the test. On a real device the probe succeeds
    /// and costs one extra platform call on first listen. DO NOT remove it.
    Stream<NetworkStatus> _nativeStatusChanges() async* {
      try {
        await _connectivity.checkConnectivity();
      } catch (_) {
        return;
      }
      yield* _connectivity.onConnectivityChanged.map(classifyConnectivityResults);
    }
  ```

- [ ] **Step 8: Extend the four existing test doubles with `statusChanges()`.**
  > Corrected (Decisions #4, #5, #6): §1d task 6 already rewrote all four fakes as the union — `_FakeConnectivityService(this.status, {this.reachable = true, this.probeThrows = false})` with `probeCallCount` and `isBackendReachable()`. **This step adds only the stream members**; re-emitting the class header or §1d's members is a duplicate-declaration compile error. Note `app_test.dart`'s fake (`:132-135`) has **no constructor and no `status` field** — unlike its orchestrator-test twin — so it gets the empty-stream form.
  ```dart
  // ADD to test/features/backup/application/sync_orchestrator_test.dart's
  // _FakeConnectivityService (§1d's union class at :143) and to
  // test/features/backup/data/sync_service_test.dart's FakeConnectivityService
  // (:276) — both need `import 'dart:async';` (already added to
  // sync_service_test.dart by Task 4; already present at :1 in
  // sync_orchestrator_test.dart):

    final StreamController<NetworkStatus> _controller =
        StreamController<NetworkStatus>.broadcast();

    @override
    Stream<NetworkStatus> statusChanges() => _controller.stream;

    /// Test hook: simulate the platform reporting a transition to [next].
    /// Updates [status] too, so a subsequent `currentStatus()` agrees with the
    /// event a listener just saw.
    void emit(NetworkStatus next) {
      status = next;
      _controller.add(next);
    }

    void dispose() => _controller.close();

  // ADD to test/app/app_test.dart's _FakeConnectivityService (:132-135) and
  // test/features/backup/data/cloud_backup_service_test.dart's
  // FakeConnectivityService (:74-81) — these two only satisfy the interface:

    @override
    Stream<NetworkStatus> statusChanges() => const Stream<NetworkStatus>.empty();
  ```

- [ ] **Step 9: Verify the `dart:io` gate is still empty** and no new `dart:io` crept in via the seam. (Uses the directive-anchored form from Global Constraints — the naive substring form matches 35 legitimate doc comments and can never be empty.)
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && grep -rlE "^[[:space:]]*(import|export)[[:space:]]+['\"]dart:io['\"]" lib --include="*.dart" | grep -v '_native.dart'; echo "gate exit: $?"
  ```
  Expected: no output before `gate exit:` (grep finds nothing, so the pipeline reports 1).

- [ ] **Step 10: Run the connectivity + backup suites, then the whole suite** (the interface change touches four test files).
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/backup/ test/app/ && flutter test
  ```
  Expected: all green — **including `test/widget_test.dart`, which has no override and is protected only by the Step 7d probe.**

- [ ] **Step 11: Confirm the web half still compiles for the wasm target** (the seam's web file is never exercised by `flutter test`).
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && tool/build_web.sh
  ```
  Expected: build succeeds; the `dart:io` grep gate and drift asset pin both pass.

**Assertions:**
- `classifyConnectivityResults` maps wifi/ethernet→wifi, mobile→cellular, none/empty→none, vpn→other, and wifi wins over a simultaneous mobile.
- `currentStatus()` delegates to `classifyConnectivityResults` — `grep -c 'classifyConnectivityResults' lib/features/backup/data/connectivity_service.dart` is **3** (declaration + `currentStatus` + `_nativeStatusChanges`); no if-chain over `ConnectivityResult` survives inside `currentStatus`.
- **§1d's members survive:** `grep -c 'isBackendReachable' lib/features/backup/data/connectivity_service.dart` is **≥ 2** (abstract declaration + implementation), and `SystemConnectivityService`'s constructor still takes **three** positional parameters. A whole-file re-emit fails both checks.
- `SystemConnectivityService(null, false).statusChanges().toList()` completes empty AND records zero `FlutterErrorDetails` — proving a missing plugin cannot fail a widget test.
- `SystemConnectivityService(null, true).statusChanges()` resolves through the seam and completes empty under the VM target.
- The directive-anchored `dart:io` gate produces no output.
- `online_events_web.dart` imports only `dart:async`, `dart:js_interop` and `package:web/web.dart` — no `dart:html`, no `dart:io`.
- `tool/build_web.sh` succeeds; whole-suite `flutter test` is green (including `widget_test.dart`); `flutter analyze` reports 0 issues.
- **Test count: baseline + 3** for this task (D-13).

**Commit:** `feat(sync): ConnectivityService change stream (native + browser online) (S3)`

---

### Task 8: Connectivity regain triggers BOTH a push and a pull (S3)

**This is the task that makes the [critical non-collision hazard](#️-critical-non-collision-hazard--do-not-simplify-the-plugin-probe) live.** After this task `build()` subscribes to `statusChanges()` unconditionally, for every consumer of `syncOrchestratorProvider`, including the three `MasiApp` mounts that override nothing.

**Files:**
- Modify: `lib/features/backup/application/sync_orchestrator.dart` (imports `:1-10`; a field after `_fullResyncDue`; `build()` between the `tableUpdates()` listener `:159` and the auth listener `:170`; `onDispose` `:178-181`), `test/features/backup/application/sync_orchestrator_test.dart`
- Test: `test/features/backup/application/sync_orchestrator_test.dart`

**Interfaces:**
- Produces: `_connectivitySubscription`, `_onConnectivityChanged(NetworkStatus)`.
- Consumes: Task 7's `statusChanges()` + `_FakeConnectivityService.emit`; §1d task 7's `connectivityService` parameter on `makeContainer`; `connectivityServiceProvider` (`backup_providers.dart:35-37` ✅); `pushNow()`/`pullNow()` from Task 6 and `:254`.

- [ ] **Step 1: `makeContainer` — verify, don't duplicate.**
  > Corrected (Decision #6 / D-8): the fragment's version of this step added the `_FakeConnectivityService? connectivityService` parameter, the `connectivityServiceProvider` override and the `SyncService(connectivity: connectivityFake)` reuse. **§1d task 7 already wrote all three.** Applying both patches literally is a duplicate-parameter compile error. This step is reduced to (a) confirming §1d's version is present and passes the same instance to both the provider and the `SyncService` — which is what makes a test's `emit` visible to both — and (b) adding the one override §1d does not cover: the inline container in the `status transitions` group (`:689` ✅, inside the group at `:681-725`), which overrides `syncServiceProvider` but not `connectivityServiceProvider`.
  ```dart
  // VERIFY only — written by §1d task 7, do NOT re-add:
  //   import 'package:masi/features/backup/application/backup_providers.dart';
  //   makeContainer param:  _FakeConnectivityService? connectivityService,
  //   makeContainer body:   final connectivityFake =
  //                             connectivityService ?? _FakeConnectivityService(connectivity);
  //   overrides:            connectivityServiceProvider.overrideWithValue(connectivityFake),
  //   SyncService(...):     connectivity: connectivityFake,
  // Task 6 of THIS fragment adds `addTearDown(connectivityFake.dispose);`.

  // ADD: the `status transitions` group's inline container (:689) gains, alongside
  // its other overrides, so it is hermetic rather than relying on the probe guard:
              connectivityServiceProvider.overrideWithValue(
                _FakeConnectivityService(NetworkStatus.wifi),
              ),
  ```

- [ ] **Step 2: Append the failing group to `sync_orchestrator_test.dart`.**
  > Corrected (D-17), third test only: its `await insertArea(...)` + `await Future<void>.delayed(60 ms)` + `expect(schedule.attempts, isNotEmpty)` established the "we are mid-backoff" **precondition** inside a wall-clock budget. The precondition is now established deterministically with one awaited `pushNow()`. The regain half stays event-driven on the clock — that is what the test is actually about — and the schedule's fixed delay is lengthened to an hour so an armed retry can never masquerade as the regain-triggered push.
  ```dart
    group('S3: connectivity regain', () {
      test(
        'a regain event triggers BOTH a push and a pull, well inside the '
        'debounce window and with no further local write -- before this, '
        'nothing in lib reacted to the network coming back at all',
        () async {
          final db = AppDatabase(NativeDatabase.memory());
          addTearDown(db.close);
          final remote = _CountingSyncRemote();
          final connectivity = _FakeConnectivityService(NetworkStatus.none);
          final container = makeContainer(
            db: db,
            remote: remote,
            syncServiceAuth: _FakeAuthRepository(
              const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
            ),
            // Deliberately far longer than the test: only the regain event can
            // possibly produce the push asserted below.
            debounce: const Duration(seconds: 30),
            connectivityService: connectivity,
          );

          primeOrchestrator(container);
          await Future<void>.delayed(const Duration(milliseconds: 5));

          await insertArea(db, 'a1', ownerId: 'u1');
          await Future<void>.delayed(const Duration(milliseconds: 10));
          expect(remote.pushCallCount, 0, reason: 'the 30s debounce is pending');
          expect(remote.pullCallCount, 0);

          connectivity.emit(NetworkStatus.wifi);
          await Future<void>.delayed(const Duration(milliseconds: 40));

          expect(remote.pushCallCount, 1);
          expect(remote.pullCallCount, 1);
          expect(
            container.read(syncOrchestratorProvider).status,
            SyncStatus.idle,
          );
        },
      );

      test(
        'a transition to NetworkStatus.none triggers nothing -- losing the '
        'network is not a reason to attempt a sync',
        () async {
          final db = AppDatabase(NativeDatabase.memory());
          addTearDown(db.close);
          final remote = _CountingSyncRemote();
          final connectivity = _FakeConnectivityService(NetworkStatus.wifi);
          final container = makeContainer(
            db: db,
            remote: remote,
            syncServiceAuth: _FakeAuthRepository(
              const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
            ),
            debounce: const Duration(seconds: 30),
            connectivityService: connectivity,
          );

          primeOrchestrator(container);
          await Future<void>.delayed(const Duration(milliseconds: 5));

          await insertArea(db, 'a1', ownerId: 'u1');
          connectivity.emit(NetworkStatus.none);
          await Future<void>.delayed(const Duration(milliseconds: 40));

          expect(remote.pushCallCount, 0);
          expect(remote.pullCallCount, 0);
        },
      );

      test(
        'a regain RESETS the backoff and re-arms the full-scope safety net, so '
        'a device that comes back after a long outage re-sends everything '
        'rather than trusting flags a swallowed failure may have cleared',
        () async {
          final db = AppDatabase(NativeDatabase.memory());
          addTearDown(db.close);
          final remote = _OfflineToggleSyncRemote();
          // An hour, so an armed retry can never be mistaken for the
          // regain-triggered push asserted below.
          final schedule = _RecordingRetrySchedule(const Duration(hours: 1));
          final connectivity = _FakeConnectivityService(NetworkStatus.none);
          final container = makeContainer(
            db: db,
            remote: remote,
            syncServiceAuth: _FakeAuthRepository(
              const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
            ),
            debounce: const Duration(seconds: 30),
            retrySchedule: schedule,
            connectivityService: connectivity,
          );

          primeOrchestrator(container);
          await Future<void>.delayed(const Duration(milliseconds: 5));

          final notifier = container.read(syncOrchestratorProvider.notifier);
          await insertArea(db, 'a1', ownerId: 'u1');

          // Establish "mid-backoff" DETERMINISTICALLY rather than by waiting.
          await notifier.pushNow();
          expect(schedule.attempts, [1]);
          expect(remote.pushedAreas, isEmpty);

          schedule.attempts.clear();
          remote.offline = false;
          connectivity.emit(NetworkStatus.wifi);
          await Future<void>.delayed(const Duration(milliseconds: 60));

          expect(remote.pushedAreas.keys, contains('a1'));
          expect(
            schedule.attempts,
            isEmpty,
            reason: 'the regain push succeeded, so no retry was ever armed',
          );
        },
      );
    });
  ```

- [ ] **Step 3: Run it and watch the first and third tests fail** (nothing subscribes to the stream yet).
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/backup/application/sync_orchestrator_test.dart --plain-name 'S3: connectivity regain'
  ```
  Expected: `Expected: <1> Actual: <0>` for `pushCallCount`/`pullCallCount` on the regain tests.

- [ ] **Step 4: Add the imports and the subscription field** to `lib/features/backup/application/sync_orchestrator.dart`.
  ```dart
  import '../data/connectivity_service.dart';
  import 'backup_providers.dart';

  // ... field, after _fullResyncDue:
    /// The connectivity-transition subscription installed in [build], or `null`.
    StreamSubscription<NetworkStatus>? _connectivitySubscription;
  ```

- [ ] **Step 5: Subscribe in `build()`** — insert between the `tableUpdates()` listener (`:159` ✅) and the auth listener (`:170` ✅) — and cancel in `onDispose`.
  ```dart
      // S3: react to the network coming back. `statusChanges()` is
      // contractually non-throwing and degrades to a never-emitting stream when
      // the platform signal is unavailable (see its doc), which is exactly what
      // makes this inert in every unit/widget test that doesn't override
      // `connectivityServiceProvider`; `onError` below is belt-and-braces on top
      // of that, never the primary defence.
      final connectivity = ref.watch(connectivityServiceProvider);
      _connectivitySubscription = connectivity.statusChanges().listen(
        _onConnectivityChanged,
        onError: (Object error) {
          debugPrint(
            'SyncOrchestrator: connectivity stream error (ignored): $error',
          );
        },
      );

      // ... existing ref.listen(authStateProvider, ...) unchanged ...

      ref.onDispose(() {
        _debounceTimer?.cancel();
        _retryTimer?.cancel();
        _dbSubscription?.cancel();
        _connectivitySubscription?.cancel();
      });
  ```

- [ ] **Step 6: Add `_onConnectivityChanged`** after `_scheduleRetry`.
  ```dart
    /// A connectivity transition arrived.
    ///
    /// Anything other than [NetworkStatus.none] means "the network may be usable
    /// again", which is genuinely NEW information, so three things happen:
    ///  - the backoff resets — the accumulated failures were about the OLD
    ///    network state, and making the user wait out a 5-minute ceiling after
    ///    reconnecting is the opposite of "sync as soon as possible";
    ///  - [_fullResyncDue] is re-armed, so the catch-up push re-sends EVERY own
    ///    row rather than trusting `dirty` flags that a swallowed per-table
    ///    failure during the outage may have cleared (D-4's loss-proofness);
    ///  - BOTH a push and a pull fire immediately — the push flushes whatever
    ///    was edited offline, the pull picks up what changed in the cloud
    ///    meanwhile. §1e requires both; pushing only would leave another user's
    ///    newly-published topo invisible until the next resume.
    ///
    /// Losing the network ([NetworkStatus.none]) triggers nothing: there is
    /// nothing to attempt, and attempting anyway would just burn a retry
    /// attempt and flip the status to `error`.
    ///
    /// Both entry points self-guard against overlapping runs ([pushNow] /
    /// [pullNow]), so a flapping connection cannot stack up concurrent syncs —
    /// at most one push and one pull are ever in flight. [pullNow] is called
    /// UNTHROTTLED on purpose: a genuine offline→online transition is precisely
    /// when fresh data matters, and its in-flight guard already collapses a
    /// burst of `online` events (browsers fire them liberally) into a single
    /// pull.
    void _onConnectivityChanged(NetworkStatus status) {
      if (status == NetworkStatus.none) return;
      _consecutivePushFailures = 0;
      _retryTimer?.cancel();
      _fullResyncDue = true;
      unawaited(pushNow());
      unawaited(pullNow());
    }
  ```

- [ ] **Step 7: Run the orchestrator suite, then the whole suite.** Pay attention to `test/widget_test.dart` and to `app_test.dart`'s un-overridden containers — this is the step where the probe earns its keep.
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/backup/application/sync_orchestrator_test.dart && flutter test
  ```
  Expected: all green. If `widget_test.dart` starts reporting a `FlutterError` from an `EventChannel`, the Step 7d probe in Task 7 has been weakened — restore it rather than editing `widget_test.dart`.

**Assertions:**
- A `NetworkStatus.wifi` emission with a 30 s debounce pending produces exactly one `upsertOwnRows` **and** one `fetchOwnRows` call, with no further local write, and leaves status `idle`.
- A `NetworkStatus.none` emission produces zero push and zero pull calls.
- A regain after a deterministic failure clears the failure counter (`schedule.attempts` empty after the regain) and the previously-stuck row reaches the remote.
- `ref.onDispose` cancels `_connectivitySubscription` — `container.dispose()` in every test leaves no live subscription (no "stream still listened to after test" warnings).
- `test/widget_test.dart` and both un-overridden `app_test.dart` containers stay green, proving the probe contract holds.
- Whole-suite `flutter test` is green; `flutter analyze` reports 0 issues.
- **Test count: baseline + 3** for this task (D-13).

**Commit:** `feat(sync): push and pull on connectivity regain (S3)`

---

### Task 9: App resume flushes a push, not only the throttled pull (S2)

**Corrections here:** D-27 (`app_test.dart`'s `_CountingSyncRemote` has no `pushCallCount`), D-6 (all four containers get the override, not two), and two line drifts.

**Files:**
- Modify: `lib/app/app.dart` (`:52-80`, `resumed` branch `:75-79` ✅), `test/app/app_test.dart`
- Test: `test/app/app_test.dart`

**Interfaces:**
- Produces: `pushNow()` wired into the `resumed` lifecycle branch — the fifth and last push trigger.
- Consumes: Task 6's `pushNow()`; `app_test.dart`'s `_CountingSyncRemote` (`:30-101`), `_FakeAuthRepository` (`:104`), `_FakeConnectivityService` (`:132-135`), `_setAppLifecycleState` (`:205-211`), `_drain` (`:177-185`).

- [ ] **Step 1: Give `app_test.dart`'s `_CountingSyncRemote` a push counter.**
  > Corrected (D-27 — compile error): the class is at **`:30`**, not the cited `:34` (which is its `upsertOwnRows` signature), and it declares **only `int pullCallCount = 0;`** — its `upsertOwnRows` body is `async {}` and counts nothing. Task 9's test reads `remote.pushCallCount` twice, so without this step the file does not compile. §1d task 2 owns the **signature** change on this same override (blast-radius row 6), so add only the field and the increment on top of §1d's retyped body.
  ```dart
  // ADD to test/app/app_test.dart's _CountingSyncRemote (class at :30), next to
  // `int pullCallCount = 0;`:
    int pushCallCount = 0;

  // and increment it inside §1d's retyped upsertOwnRows body (which returns
  // List<TablePushOutcome>) — do NOT restate the signature:
      pushCallCount++;
  ```

- [ ] **Step 2: Add the failing `testWidgets` to the existing resume group in `test/app/app_test.dart`.**
  > Corrected (line drift): the group is `#57: resumed lifecycle triggers a pull` at **`:385-555`** (the fragment cited `390-479`); its first `testWidgets` is `:386-479`, so appending after `:479` is the right anchor. A second `testWidgets` follows at `:481-554`.

  It reuses the file's `_CountingSyncRemote`, `_FakeAuthRepository`, `_FakeConnectivityService`, `_setAppLifecycleState` and `_drain`.
  ```dart
      testWidgets(
        'returning to the foreground also PUSHES, not only pulls -- a user who '
        'edited offline and then merely backgrounded/foregrounded the app used '
        'to stay unsynced until their next local write (S2)',
        (tester) async {
          final db = AppDatabase(NativeDatabase.memory());
          addTearDown(db.close);
          final remote = _CountingSyncRemote();
          final container = ProviderContainer(
            overrides: [
              appDatabaseProvider.overrideWithValue(db),
              nowMsProvider.overrideWithValue(() => 1000),
              authStateProvider.overrideWith(
                (ref) => Stream.value(
                  const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
                ),
              ),
              syncDebounceDurationProvider.overrideWithValue(
                const Duration(milliseconds: 5),
              ),
              connectivityServiceProvider.overrideWithValue(
                _FakeConnectivityService(),
              ),
              syncServiceProvider.overrideWithValue(
                SyncService(
                  db: db,
                  backupRepository: BackupRepository(db),
                  remote: remote,
                  authRepository: _FakeAuthRepository(
                    const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
                  ),
                  connectivity: _FakeConnectivityService(),
                ),
              ),
            ],
          );
          addTearDown(container.dispose);

          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: const MasiApp(),
            ),
          );
          await _drain(tester);
          final pushesBeforeResume = remote.pushCallCount;

          await _setAppLifecycleState(tester, AppLifecycleState.paused);
          await _drain(tester);
          await _setAppLifecycleState(tester, AppLifecycleState.resumed);
          await _drain(tester);

          expect(
            remote.pushCallCount,
            greaterThan(pushesBeforeResume),
            reason: 'resume must flush a push, not only a throttled pull',
          );
        },
      );
  ```

- [ ] **Step 3: Add the imports the new test needs.**
  > Verified: `sync_providers.dart` is already imported at `:10`; **`backup_providers.dart` is NOT imported today** — it is required for `connectivityServiceProvider`.
  ```dart
  import 'package:masi/features/backup/application/backup_providers.dart';
  import 'package:masi/features/backup/application/sync_providers.dart';
  ```

- [ ] **Step 4: Add `connectivityServiceProvider.overrideWithValue(_FakeConnectivityService())` to ALL FOUR containers.**
  > Corrected (D-6): the fragment named only the two "#57" containers (`:401-433`, `:493-517`). Verified: there are exactly four `ProviderContainer(` constructions in the file and **all four mount `MasiApp`** (at `:228`, `:340`, `:439`, `:523`), and **none** overrides `connectivityServiceProvider` today. The two the fragment missed — `_makeContainer` (`:148-172`) and the inline C3 sign-in container (`:318-334`) — additionally do not override `syncServiceProvider`, so the real `syncServiceProvider` builds and resolves the real `SystemConnectivityService()`. Benign under §1d alone (signed-out ⇒ `skippedSignedOut`, the probe is never reached); **fatal-shaped under Task 8's unconditional `statusChanges()`**, which is only survivable via Task 7's probe. Make them hermetic.
  ```dart
              connectivityServiceProvider.overrideWithValue(
                _FakeConnectivityService(),
              ),
  ```
  Apply at: `_makeContainer` (`:148`), the C3 inline container (`:318`), and both "#57" containers (`:401-433`, `:493-517`).

- [ ] **Step 5: Run the file and watch the new test fail.**
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/app/app_test.dart
  ```
  Expected: fails with `Expected: a value greater than <N> Actual: <N>` — resume currently only pulls.

- [ ] **Step 6: Add the push to `lib/app/app.dart`'s `resumed` branch,** inside the same `if` as the existing `pullNow` (`:75-79` ✅).
  ```dart
      if (state == AppLifecycleState.resumed) {
        unawaited(
          ref.read(syncOrchestratorProvider.notifier).pullNow(throttled: true),
        );
        // §1e (S2): a resume is also the moment to FLUSH anything that never
        // made it up — an edit made offline, or a push that failed while the
        // app was backgrounded. Before this, resume only ever pulled, so a user
        // who edited offline and then merely backgrounded/foregrounded the app
        // stayed unsynced indefinitely (the only push triggers were a local
        // write's 2s debounce and `onAppPaused()`).
        //
        // Deliberately UNthrottled, unlike the pull above: `pushNow()` is
        // already self-limiting in three independent ways — it coalesces
        // against an in-flight push, it no-ops when nothing is locally `dirty`
        // (so web's resume-on-every-tab-focus costs one indexed LIMIT-1 query,
        // not a network round trip), and it is a safe no-op when signed out.
        // Fire-and-forget: this lifecycle callback must return immediately.
        unawaited(ref.read(syncOrchestratorProvider.notifier).pushNow());
      }
  ```

- [ ] **Step 7: Run the app suite, then the whole suite.**
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/app/ && flutter test
  ```
  Expected: all green; the pre-existing resume-throttle tests still assert `pullCallCount` 1→2→3 and the within-window no-op.

- [ ] **Step 8: Sanity-check the whole trigger set is now the one the class doc claims.**
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && grep -n "pushNow()" lib/features/backup/application/sync_orchestrator.dart lib/app/app.dart
  ```
  Expected: `pushNow()` is called from the debounce timer, `onAppPaused`, `_scheduleRetry`, `_onConnectivityChanged` (`sync_orchestrator.dart`) and the `resumed` branch (`app.dart`) — **five triggers, one funnel** (plus the declaration itself).

**Assertions:**
- A background→foreground cycle increases `_CountingSyncRemote.pushCallCount`.
- `test/app/app_test.dart`'s `_CountingSyncRemote` declares `pushCallCount` and increments it in `upsertOwnRows` — `grep -c 'pushCallCount' test/app/app_test.dart` is **≥ 3** (field, increment, and the new test's two reads). Without this the file does not compile (D-27).
- **All four** `ProviderContainer(` constructions in `app_test.dart` override `connectivityServiceProvider` — `grep -c 'connectivityServiceProvider.overrideWithValue' test/app/app_test.dart` is **5** (four containers + the new test's own). A count of 2 or 3 means D-6 was not applied.
- The pre-existing #57 resume-pull tests still pass unchanged (pull count 1→2→3 across throttle-elapsed resumes; no-op within the window; `paused` pushes and never pulls).
- `grep -n "pushNow()" …` shows exactly five call sites, all funnelling through the one guarded method.
- Whole-suite `flutter test` is green; `flutter analyze` reports 0 issues.
- **Test count: baseline + 1** for this task (D-13).

**Commit:** `feat(sync): app resume flushes a push, not only a throttled pull (S2)`

---

### Task 10: End-to-end — create offline, remote becomes reachable with no further local write, topo arrives

**This is where D-17's genuine flake lived.** The second test as written waited ~200 ms of wall-clock and asserted `schedule.attempts.length > 5` — six full retry cycles, each doing real Drift I/O, inside 200 ms. It is rewritten clock-free.

**Files:**
- Modify: `test/features/backup/application/sync_orchestrator_test.dart`
- Test: `test/features/backup/application/sync_orchestrator_test.dart`

**Interfaces:**
- Produces: nothing — this task is pure verification. It composes every piece Tasks 1–9 added and is the single test that would catch a regression in any of them.
- Consumes: `_OfflineToggleSyncRemote`, `_RecordingRetrySchedule`, `makeContainer(retrySchedule:)`, `insertArea` (dirty-seeding), `pushNow()`, the `dirty` clear, and the payload stripping from Task 2.

- [ ] **Step 1: Append the headline end-to-end group to `sync_orchestrator_test.dart`.**
  > Corrected (D-17), second test rewritten; first test kept on the clock with widened margin.
  >
  > **Second test** — `await Future<void>.delayed(200 ms)` + `expect(schedule.attempts.length, greaterThan(5))` is a genuine flake: six retry cycles, each running a nine-probe `hasPendingLocalChanges()`, a nine-select `pushOwn` transaction and a `_clearDirty` transaction against a real `NativeDatabase.memory()`, inside 200 ms. It now drives the retries with **eight explicit, fully-awaited `pushNow()` calls** and asserts the **exact requested attempt numbers** — `[1, 2, 3, 4, 5, 6, 7, 8]` — which is a *stronger* claim than "more than 5 completed in time" and cannot flake. The fixed schedule delay is an hour, so no armed timer can interleave. This is the preferred fix from the reconciliation note; the `>= 3` fallback is not needed.
  >
  > **First test** — deliberately left timer-driven, because its whole subject is that recovery happens with **no user action and no further local write**; driving it with an explicit `pushNow()` would destroy the thing being tested. Margin widened instead: a 10 ms fixed schedule and a 250 ms recovery window for one cycle, with count-free assertions (`greaterThanOrEqualTo(1)`, `isNotEmpty`).
  ```dart
    group('§1e end-to-end: nothing recorded offline is ever stranded', () {
      test(
        'create a topo with the remote UNREACHABLE, then make the remote '
        'reachable WITHOUT any further local write and WITHOUT any user '
        'action -> the topo reaches the remote and the local row goes clean',
        () async {
          final db = AppDatabase(NativeDatabase.memory());
          addTearDown(db.close);
          final remote = _OfflineToggleSyncRemote();
          // The ONLY test in this fragment that depends on a timer firing —
          // that is precisely its subject ("no user action"). A 10ms envelope
          // against a 250ms recovery window leaves ~25x headroom for one cycle.
          final schedule = _RecordingRetrySchedule(const Duration(milliseconds: 10));
          final container = makeContainer(
            db: db,
            remote: remote,
            syncServiceAuth: _FakeAuthRepository(
              const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
            ),
            debounce: const Duration(milliseconds: 15),
            retrySchedule: schedule,
          );

          primeOrchestrator(container);
          await Future<void>.delayed(const Duration(milliseconds: 5));

          // ---- 1. The user creates a topo while the network is down. --------
          await insertArea(db, 'a-offline', ownerId: 'u1');
          await Future<void>.delayed(const Duration(milliseconds: 80));

          expect(
            remote.pushCallCount,
            greaterThanOrEqualTo(1),
            reason: 'the debounced push must at least have been ATTEMPTED',
          );
          expect(remote.pushedAreas, isEmpty, reason: 'nothing landed');
          expect(
            container.read(syncOrchestratorProvider).status,
            SyncStatus.error,
            reason: 'a push that did not land must not report success',
          );
          var row = await (db.select(
            db.areas,
          )..where((t) => t.id.equals('a-offline'))).getSingle();
          expect(
            row.dirty,
            isTrue,
            reason: 'a failed push must leave the row flagged for retry',
          );

          // ---- 2. The network comes back. No local write, no user action. ---
          remote.offline = false;
          await Future<void>.delayed(const Duration(milliseconds: 250));

          // ---- 3. The topo is in the cloud and the row is clean. ------------
          expect(remote.pushedAreas.keys, contains('a-offline'));
          expect(
            remote.pushedAreas['a-offline']!['name'],
            'Area a-offline',
            reason: 'the real row, not an empty placeholder, must have landed',
          );
          expect(
            remote.pushedAreas['a-offline']!.keys,
            isNot(contains('dirty')),
            reason: 'the payload must not carry local-only bookkeeping (S8)',
          );
          row = await (db.select(
            db.areas,
          )..where((t) => t.id.equals('a-offline'))).getSingle();
          expect(row.dirty, isFalse);
          expect(
            container.read(syncOrchestratorProvider).status,
            SyncStatus.idle,
          );
          expect(
            schedule.attempts,
            isNotEmpty,
            reason: 'the recovery must have come from the RETRY loop, not from '
                'a fresh trigger',
          );
        },
      );

      test(
        'the retry loop survives a long outage: many consecutive failures '
        'never exhaust it, and the row still lands when the remote returns',
        () async {
          final db = AppDatabase(NativeDatabase.memory());
          addTearDown(db.close);
          final remote = _OfflineToggleSyncRemote();
          // An hour: the armed retry timer can never fire, so every cycle below
          // is one explicit awaited pushNow() and the attempt numbers are
          // EXACT. Asserting the requested attempt numbers is both stronger and
          // deterministic, unlike counting completions in a wall-clock budget.
          final schedule = _RecordingRetrySchedule(const Duration(hours: 1));
          final container = makeContainer(
            db: db,
            remote: remote,
            syncServiceAuth: _FakeAuthRepository(
              const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
            ),
            // Far longer than the test: no debounced push can interleave.
            debounce: const Duration(seconds: 30),
            retrySchedule: schedule,
          );

          primeOrchestrator(container);
          await Future<void>.delayed(const Duration(milliseconds: 5));

          final notifier = container.read(syncOrchestratorProvider.notifier);
          await insertArea(db, 'a-long-outage', ownerId: 'u1');

          const cycles = 8;
          for (var i = 0; i < cycles; i++) {
            await notifier.pushNow();
          }

          expect(
            schedule.attempts,
            [for (var a = 1; a <= cycles; a++) a],
            reason: 'unbounded attempts -- no cap, no terminal give-up state, '
                'and the attempt number escalates by exactly one each time',
          );
          expect(remote.pushCallCount, cycles);
          expect(remote.pushedAreas, isEmpty);
          expect(
            (await (db.select(db.areas)
                  ..where((t) => t.id.equals('a-long-outage')))
                .getSingle())
                .dirty,
            isTrue,
            reason: 'every failed attempt must leave the row flagged',
          );
          expect(
            container.read(syncOrchestratorProvider).status,
            SyncStatus.error,
          );

          remote.offline = false;
          await notifier.pushNow();

          expect(remote.pushedAreas.keys, contains('a-long-outage'));
          expect(
            schedule.attempts,
            hasLength(cycles),
            reason: 'the successful push armed no further retry',
          );
          expect(
            (await (db.select(db.areas)
                  ..where((t) => t.id.equals('a-long-outage')))
                .getSingle())
                .dirty,
            isFalse,
          );
          expect(
            container.read(syncOrchestratorProvider).status,
            SyncStatus.idle,
          );
        },
      );
    });
  ```

- [ ] **Step 2: Run the group.**
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/backup/application/sync_orchestrator_test.dart --plain-name '§1e end-to-end'
  ```
  Expected: both tests pass (all the machinery is already in place from Tasks 1–9).

- [ ] **Step 3: Run the second test 20 times to prove the flake is gone.** (Cheap insurance on the one class of defect this fragment was most likely to ship.)
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && for i in $(seq 1 20); do flutter test test/features/backup/application/sync_orchestrator_test.dart --plain-name 'the retry loop survives a long outage' || break; done
  ```
  Expected: 20 consecutive green runs.

- [ ] **Step 4: Run the full gate.**
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter analyze && flutter test
  ```
  Expected: `No issues found!` and every test green.
  > Corrected (D-13): the fragment expected "1576 baseline + the ~25 tests added by T1-T10". Both numbers are wrong. The live baseline is **1586** (§1b tasks 1–2 landed: `694e7f2`, `02b854b`) and this fragment adds **31** tests (2+1+3+5+6+5+3+3+1+2). Re-measure the baseline at execution time and gate on **green**, never on an absolute total.

- [ ] **Step 5: Run the web gate,** since the workstream added a conditional-import seam.
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && tool/build_web.sh
  ```
  Expected: build succeeds; `dart:io` grep gate and drift asset pin both pass.

**Assertions:**
- With the remote unreachable, a created topo produces at least one push ATTEMPT, nothing lands, status is `error`, and the local row stays `dirty == true`.
- With no further local write and no user action, flipping the remote reachable results in the row landing in the remote, the local row going `dirty == false`, and status `idle`.
- The landed payload contains the real `name` and **no `dirty` key** (Task 2's stripping, proven end to end).
- The recovery is attributable to the retry loop (`schedule.attempts` non-empty), not to a fresh write or resume trigger.
- A prolonged outage records **exactly** `[1 … 8]` escalating attempts — no cap, no give-up state, no wall-clock budget — the row stays dirty throughout, and it lands with `dirty == false` on recovery while the successful push arms no further retry.
- The long-outage test passes 20 consecutive runs.
- `flutter analyze` is 0 issues, `flutter test` is fully green (**baseline + 2** for this task; **baseline + 31** for the fragment), and `tool/build_web.sh` succeeds.

**Commit:** `test(sync): end-to-end offline create -> reachable remote -> topo arrives`

---

## Risks

1. **AUDIT CORRECTION, load-bearing: the spec's S8 claim that `dirty` is "written `true` by every repository" is FALSE.** `grep -rn "dirty: const Value(true)" lib --include="*.dart"` shows **35** writes (the fragment said 30), but 15 push-worthy writes omit it entirely — `LibraryCrudRepository._insertArea`/`renameArea`/`_insertSector`/`renameSector`/`createWall`/`renameWall`/`attachPhotoToWall` and **all five** Area/Sector/Wall/Photo/Route tombstone writes in the soft-delete cascade, plus all three `RouteRepository` writes. All 15 verified in place. Gating the push on `dirty` without Task 3 would silently stop syncing every create, every rename, every route edit and most tombstones. **Task 3 must not be skipped or deferred.**

2. **§1d MUST land before Task 4 — and its landing changes Task 4's contract, not just its ordering.** Pre-§1d, `SupabaseSyncRemote.upsertOwnRows` returned `void` and `continue`d past a per-table failure behind a `debugPrint`, so "the call did not throw" was not "the rows landed". §1d fixes the *reporting*; what it does **not** do is make a failed push throw. Task 4's clear is therefore narrowed to `tablesToRows` **minus §1d's failed-table set** (D-25), which is the difference between "retry until clean" and "silently discard every offline edit on the first per-table rejection". The `PushScope.full` re-push on app start and on every connectivity regain remains the backstop for the residue.

3. **The (id, updatedAt) compare-and-swap has one narrow accepted hole:** two writes to the SAME row within one millisecond share an `updatedAt`, so the second's `dirty` would be cleared by the in-flight push. It needs two distinct user operations on one row inside 1 ms, it is the same resolution `shouldPushLww` already depends on, and the full-scope re-push recovers it. Closing it properly needs a monotonic local revision column, i.e. a schema migration to v9 — deliberately out of scope, and note §1c-A already takes v8→v9 for its `AppSettings` table. Documented in `_clearDirty`'s doc rather than left implicit.

4. **Dirty-scoped push interacts with §1f's photo work.** Task 4 clears `dirty` only after the byte phase, so a failed upload leaves rows dirty and the retry re-attempts both. But a photo whose row is CLEAN and whose bytes failed on an earlier push is not re-attempted by a `dirtyOnly` push — only by the `PushScope.full` catch-up. §1f is where that gets a first-class signal, via `photosFailed` folded into `fullyLanded` (reconciliation decision #9). §1f lands *after* this fragment, so no action here; if the order is ever inverted, extend `hasPendingLocalChanges()` to include "a photo row whose object is missing remotely" rather than reworking the scope enum.

5. **`fake_async` is deliberately NOT used** (D-18) — see Conventions. Three reasons: it is transitive-only (`pubspec.lock:316`) so importing it trips `depend_on_referenced_packages`; the orchestrator tests need a real `AppDatabase(NativeDatabase.memory())` for `tableUpdates()`, whose sqlite3 work does not advance under a fake clock; and the existing suite is built on shrink-the-seam + tiny real delays. The brief's actual requirement — never wait out a production interval — is met and strengthened: the growth law is asserted with zero timers in `sync_retry_schedule_test.dart`, and after the D-17 rewrite **only one test in the whole fragment depends on a timer firing at all** (Task 10's first, whose subject *is* the autonomous timer).

6. **`ConnectivityService.statusChanges()` is a NEW ABSTRACT MEMBER,** so all four existing fakes stop compiling until updated: `sync_orchestrator_test.dart:143`, `sync_service_test.dart:276`, `cloud_backup_service_test.dart:74`, `app_test.dart:132`. Making it a concrete member with a default body would NOT help — all four use `implements`, which requires every member regardless. §1d task 6 absorbs the same churn for `isBackendReachable()`; do both in one pass per class (decisions #4/#5).

7. **The nastiest trap in Task 7 — see the [critical non-collision hazard](#️-critical-non-collision-hazard--do-not-simplify-the-plugin-probe).** `Connectivity.onConnectivityChanged` is an `EventChannel` whose missing-plugin failure arrives via `FlutterError.reportError`, which no `try`/`catch` or `Stream.onError` can intercept. `test/widget_test.dart:79` and `:2119` mount `MasiApp` with only `appDatabaseProvider`/`nowMsProvider` overridden, and `widget_test.dart` is owned by no Stage-1 fragment. **The `checkConnectivity()` probe is the only thing keeping it green. Do not "simplify" it away.**

8. **A confirmed push writes to the DB (`_clearDirty`), which fires `tableUpdates()`, which arms another debounce timer.** That follow-up push finds nothing dirty and writes nothing, so the cycle terminates after exactly one extra indexed `LIMIT 1` query per table — verified by Task 6's "the retry loop TERMINATES" test, which now asserts this deterministically (an explicit second `pushNow()` adds no remote call). Anyone changing the nothing-pending early-out must re-run that test or risk a genuine write loop.

9. **`_fullResyncDue` starts `true`,** so the first push of every app run is a full-state push even when nothing changed, and web's resume-on-tab-focus makes the first tab-focus pay for it. That is the intended D-4 safety net (once per orchestrator lifetime, plus once per connectivity regain), but it is also S7 cost: with no pagination anywhere, a large library means nine unfiltered selects plus one `isIn` per table. If that proves too heavy on device, throttle the regain-triggered full push rather than removing the app-start one.

10. **`SyncPushOutcome` was deliberately NOT extended with a `skippedNothingPending` case,** even though it would read better: the orchestrator's pre-flight `hasPendingLocalChanges()` check achieves the same thing without forcing every exhaustive `switch` on that enum to change — which matters because §1d rewrote `PushSyncResult` in the same file and §1f rewrites it again.

11. **`stripLocalOnlySyncColumns` lives in `sync_remote.dart`,** which §1d (`TablePushOutcome`, `partitionSyncRows`, `upsertOwnRows`) and §1f (paginated object listing) both also edit. It is additive and placed at the end of the top-level-helper block after `filterValidSyncRows`, which minimises but does not eliminate the merge surface. Anchor on the symbol, not the line — §1d task 1 rewrites `filterValidSyncRows`'s body first.

12. **`tables.dart:8`'s `dirty` doc becomes accurate for the first time** as of Tasks 3/4 and could usefully gain a pointer to `SyncService.hasPendingLocalChanges`. Optional; no other fragment touches `tables.dart`.

> **Removed from this fragment's risks (Duplication #8):** the `CLAUDE.md` doc corrections — "~377 tests", "outbox push/pull", and the `web_smoke_test` wording. **All three belong to §1f's final task,** which owns the whole doc block. Do not fix them here; a second fix would collide with §1f's edit to the same lines.

## Sequencing notes

**Hard ordering within this workstream** is listed in [Ordering](#ordering). The cross-fragment file collisions, restated from this fragment's own sequencing notes with reconciliation's resolutions folded in:

- **`lib/features/backup/application/sync_orchestrator.dart`** — shared with §1d (a push that did not land can never produce `idle` + a fresh `lastSyncedAt`; making `SyncStatus.offline` reachable). §1e rewrites `_runPush`'s whole body and adds ~120 lines of fields/methods; §1d rewrites the same `switch (result.outcome)`. Guaranteed conflict. **§1d lands first**, then Task 6 builds on §1d's outcome handling — including its `fullyLanded` gate and `_failedPushStatus()`, which is where D-28's second `_scheduleRetry()` goes. `SyncRetrySchedule` was deliberately put in its OWN file to keep that much out of the contested one.
- **`lib/features/backup/data/sync_service.dart`** — shared with §1d (aggregate `rowsFailed`/`errors` into `PushSyncResult`; surface `filterValidSyncRows` skips) **and** §1f (flip upload order to bytes-then-metadata, count byte failures). All three edit `pushOwn`. **Serialise §1d → §1e → §1f**, and §1f rebases onto Task 4's `_clearDirty` placement: bytes-before-metadata moves the upload above `upsertOwnRows`, and `_clearDirty` **stays at the bottom** (it needs `outcomes`). See decision #14 — do not restore the old ordering.
- **`lib/features/backup/data/connectivity_service.dart`** — shared with §1d (`SyncStatus.offline` via a real reachability probe). Both new members land in one pass over the four implementers; **neither fragment may re-emit the abstract class** (decisions #1/#2/#3, and Task 7's Step 7 correction).
- **`lib/features/backup/data/sync_remote.dart`** — shared with §1d and §1f. §1e's change is purely additive (two new top-level helpers), so it is the least contested of the four, but still not parallel-safe.
- **`lib/features/library/data/library_crud_repository.dart`** — shared with §1c-B's affected-row-count guards (same `_ownOrUnowned`-guarded update statements at `:176-183`, `:278-285`, `:368-375`, `:435-448`, `:1280-1286`, `:1303-1311`) and with §1f's orphan-row task. High-collision, small-diff-vs-large-diff shape — exactly the situation that previously required a git-stash recovery. In the master plan's actual order §1c-B and §1f's photo half both land **before** §1e, so **Task 3 rebases onto them**; re-locate `attachPhotoToWall`'s companion by symbol.
- **`lib/app/app.dart`** — §1e only (§1c touches `lib/app/router.dart`, not `app.dart`). Uncontested.
- **`lib/features/backup/data/backup_repository.dart`** — §1e only. Uncontested, which is what makes Task 1 a Phase-1 orphan leaf.

**Test-file collisions:** `sync_service_test.dart` is edited by §1d, §1e and §1f; `sync_orchestrator_test.dart` by §1d and §1e; `connectivity_service_test.dart` by §1d and §1e; `app_test.dart` by §1d and §1e; `library_crud_repository_test.dart` by §1c and §1e. Note especially that §1e **reshapes two shared helpers** other workstreams will want: `makeContainer` (`sync_orchestrator_test.dart:175-207`) gains `retrySchedule` on top of §1d's `connectivityService` and now overrides `connectivityServiceProvider`, and `insertArea` (`:209-219`) now seeds `dirty: true`. Any workstream writing orchestrator tests should build on the post-§1e versions rather than duplicating them.

**Files §1e does NOT touch,** so they stay free for their owners: `lib/core/db/connection/connection_web.dart` and `lib/core/db/app_database.dart` (§1a, §1c-A's v9 migration, §2b), `lib/features/account/application/auth_providers.dart` and `lib/app/router.dart` (§1c), `lib/features/topo/data/photo_files_web.dart` (§1f), `lib/features/account/presentation/account_screen.dart` (§1d, §2c), `tool/build_web.sh` / `web/` (Stage 2), `test/widget_test.dart` (nobody — which is why the Task 7 probe is load-bearing). `lib/core/db/tables.dart` is READ but not modified — **no schema migration is needed anywhere in this workstream**, which is what keeps it off Stage 2's critical path.








