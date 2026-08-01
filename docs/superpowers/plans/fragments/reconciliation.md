# Reconciliation of Stage-1 fragments

**Only five fragments were supplied (§1a, §1b, §1d, §1e, §1f). §1c is absent** — no fragment owns the auth/uid-scoping work (L4 + the native-empty-library bug), and two of the present fragments (1b, 1e) already list §1c as a sequencing hazard, so its omission is an accident, not a scope decision. Five spec assertions have no owner as a result.

Baseline verified in-repo: `flutter test` = **1576 passing**, `flutter analyze` = 0. drift resolves to **2.34.2**. `grep -rn kDebugMode lib` = exactly **1 hit** (`connection_web.dart:19`). `http: ^1.6.0`, `web: ^1.1.0`, `idb_shim`, `connectivity_plus 7.3.0` are direct deps; `fake_async` is transitive-only. `StateProvider` appears nowhere in `lib/`.

---

## Winning interface decisions

| # | Symbol | Conflict | Winning definition |
|---|---|---|---|
| 1 | `abstract class ConnectivityService` (`lib/features/backup/data/connectivity_service.dart:25`) | 1d T6 adds `isBackendReachable()`; 1e T7 adds `statusChanges()`. Both rewrite the same abstract class and the same four fakes. | **Both members**, added in the interface exactly once. `Future<bool> isBackendReachable();` (1d) + `Stream<NetworkStatus> statusChanges();` (1e). 1d lands first; 1e's T7 *adds* to 1d's class rather than re-declaring it. Neither may re-emit the abstract class wholesale. |
| 2 | `SystemConnectivityService` constructor | 1d makes it `([Connectivity?, bool?, http.Client?])`; 1e leaves it at two positionals. | **1d's 3-positional form.** 1e touches only `currentStatus`'s extracted classifier and adds `statusChanges`, so it inherits the 3rd param untouched. (Dart forbids mixing optional-positional with named, so positional is forced — flagged as debt.) |
| 3 | `NetworkStatus` classification | 1e T7 extracts `classifyConnectivityResults(List<ConnectivityResult>)` as a top-level fn; 1d leaves `currentStatus`'s inline if-chain. | **1e's extracted top-level function**, and `currentStatus` delegates to it. 1d's T6 code block must not re-inline the chain (its block currently elides it as a comment — see Defect D-9). |
| 4 | `_FakeConnectivityService` (`test/features/backup/application/sync_orchestrator_test.dart:143`) | 1d: `(status, {reachable, probeThrows})` + `probeCallCount`. 1e: `(status)` + broadcast `StreamController` + `emit()`/`dispose()`. | **Union, one class:** `_FakeConnectivityService(this.status, {this.reachable = true, this.probeThrows = false})` with `probeCallCount`, the controller, `statusChanges()`, `emit(NetworkStatus)` and `dispose()`. Written once, by 1d T6; 1e T7 extends it. |
| 5 | `FakeConnectivityService` (`test/features/backup/data/sync_service_test.dart:276`) | 1d adds `reachable`; 1e adds the stream. | Same union rule. Also applies to the two remaining fakes (`test/app/app_test.dart:132`, `test/features/backup/data/cloud_backup_service_test.dart:74`), which both get `isBackendReachable() async => true` and `statusChanges() => const Stream<NetworkStatus>.empty()`. |
| 6 | `makeContainer(...)` in `sync_orchestrator_test.dart:175` | 1d T7 adds `_FakeConnectivityService? connectivityService` + a `connectivityServiceProvider` override. 1e T8 adds the *same* param plus `SyncRetrySchedule? retrySchedule`, the `syncRetryScheduleProvider` override, and `addTearDown(connectivityFake.dispose)`. | **1e's superset**, but the `connectivityService` param + `connectivityServiceProvider` override are written **once, by 1d T7**; 1e T8 only appends `retrySchedule`/`syncRetryScheduleProvider`/the teardown. Duplicating the param is a compile error. |
| 7 | `_makeContainer()` in `topos_screen_test.dart:123` | 1a T4 adds `StorageDurability storageDurability` (unconditionally overridden). 1f T6 adds `PhotoFiles? photoFiles` (conditionally overridden). | **Union**, in that order: `_makeContainer({LocationService?, SyncOrchestrator?, StorageDurability storageDurability = const StorageDurability.probing(), PhotoFiles? photoFiles})`. |
| 8 | **`PushSyncResult`** | 1d T3 adds `rowsFailed`, `errors`, `fullyLanded`. 1f T8 adds `photosFailed`, `photosMissingLocalBytes`, `photoErrors`, `hasPhotoFailures`. Both rewrite all three constructors + `toString`. | **One merged class, six new fields.** All new params optional-with-defaults on `.pushed`, all initialised in both `skipped*` ctors, one `toString`. |
| 9 | **`PushSyncResult.fullyLanded`** — *semantic conflict, highest severity* | 1d: `didPush && rowsFailed == 0 && errors.isEmpty`. It is the **sole** gate `_runPush` uses for `idle` + fresh `lastSyncedAt`. 1f withholds a failed photo's row *from* `tablesToRows`, so `rowsFailed` stays 0 and `errors` stays empty — a push where **every** photo's bytes failed would report `fullyLanded == true` → "Synced • just now". That is S1 reintroduced through the photo path. | **`bool get fullyLanded => didPush && rowsFailed == 0 && errors.isEmpty && photosFailed == 0;`** and `_runPush`'s `lastPushError` message must concatenate `errors + photoErrors`. `photosMissingLocalBytes` is **deliberately excluded** (non-retryable; including it would stop §1e's retry loop from ever terminating). 1f's own sequencingNotes demand this ("must not add a parallel `photosFailed`-only channel that the orchestrator does not read") but its T8 code does the opposite. |
| 10 | `SyncRemote.upsertOwnRows` return type | 1d: `Future<List<TablePushOutcome>>`. 1e's and 1f's new test doubles still write `Future<void>`. | **1d's `Future<List<TablePushOutcome>>`.** Every double authored after 1d T2 must use it — see *Signature blast radius*. |
| 11 | "upsertOwnRows always throws" double | 1d T3 `ThrowingUpsertSyncRemote` (public, new signature) vs 1e T4 `_ThrowingUpsertRemote` (private, **old** signature). | **Delete 1e's.** Use 1d's `ThrowingUpsertSyncRemote` — same file, public, correct signature. 1e's would not compile. |
| 12 | `_uploadOwnPhotos` return type | 1e T4 keeps `Future<int>`; 1f T8 changes it to `Future<PhotoUploadOutcome>`. | **1f's record type.** 1e T4's call site (`final photosUploaded = await _uploadOwnPhotos(...)`) is superseded by 1f T8/T9 — 1e must land first and 1f rewrites the call. |
| 13 | `wallVisibility` construction in `pushOwn` | 1e T4 reads it as a `selectOnly` projection over **all** own walls inside the snapshot transaction (needed so a dirty photo on a *clean* shared wall still gets its shared copy). 1f T9 derives it from the `walls` list (`{for (final wall in walls) ...}`). | **1e's `selectOnly`.** 1f's derivation is silently wrong under `PushScope.dirtyOnly`. 1f T9 must consume 1e's `wallVisibility`, not rebuild it. |
| 14 | `pushOwn` statement order | 1e T4: snapshot → guard/`tablesToRows` → upsert → upload → `_clearDirty(tablesToRows)`. 1f T9: snapshot → **upload** → filter photos → `tablesToRows` → upsert. | **Composed:** snapshot (+`wallVisibility`, 1e) → `_uploadOwnPhotos` (1f) → `pushablePhotos` filter (1f) → `tablesToRows` with dirty scoping + the required-field guard (1d T4 + 1e T4) → `upsertOwnRows` (1d T2) → `_clearDirty(tablesToRows)` (1e T4) → merged result. Note: 1e's stated rationale for clearing after *both* phases is superseded — with bytes first, a failed byte upload keeps the row out of `tablesToRows` entirely, so it stays dirty by construction. Do not "restore" the old ordering. |
| 15 | `SyncOrchestrator._runPush` | 1d T5/T7 rewrite it (fullyLanded gate, `_failedPushStatus()`, `lastPushError`). 1e T6 rewrites it (`PushScope` selection, nothing-pending early-out, `_consecutivePushFailures`, `_scheduleRetry`, `_fullResyncDue`). | **1d first, 1e layers on top.** 1e's failure branch must call `await _failedPushStatus()` (1d) *and* `_scheduleRetry()` (1e), and must write `lastPushError` via the explicit constructor 1d introduces (not `copyWith`, which drops nothing but obscures intent). |
| 16 | `storageDurabilityProvider` (1a) vs `storagePersistenceProvider` (1b) | 1a's sequencingNotes demand 1b *extend* `StorageDurability` because "§2c's diagnostics row is specified to read one provider, not three." 1b invented a second provider. | **Keep them separate.** They are different lifecycles (connection-layer verdict fed asynchronously by drift's probe vs origin-level permission fed once at boot) and separate value classes; merging would create a write–write dependency between two otherwise perfectly disjoint workstreams for zero Stage-1 benefit. §2c is a downstream reader and composing two `ref.watch`es in one row is trivial. Recorded here so §2c's author does not re-litigate. Both are `NotifierProvider<Notifier<T>>` — Riverpod v3 compliant. |
| 17 | `openConnection` seam signature | 1a adds `{void Function(StorageDurability)? onStorageReport}` to all three variants. | Accepted unchanged. Verified there is exactly **one** production caller (`lib/core/db/database_provider.dart:17`) and zero test callers, so blast radius is nil. |
| 18 | `stripLocalOnlySyncColumns` / `partitionSyncRows` | 1d T1 and 1e T2 both append helpers immediately after `filterValidSyncRows` (`sync_remote.dart:317-334`). | Both, additive, **1d T1 first** (it rewrites `filterValidSyncRows`'s body into a delegation; 1e appends below it). |

---

## Execution order

Ordering is forced by three facts: 1d owns the abstract-signature change and the result-object shape that 1e and 1f both extend; 1e owns the `pushOwn` snapshot/scoping that 1f's reorder sits on top of; and 1a owns the structurally larger `topos_screen.dart` diff that 1f's localized catch nests inside.

**Hard sequential constraints**

- `sync_remote.dart`: 1d T1 → 1d T2 → 1e T2 → 1f T7
- `sync_service.dart`: 1d T3 → 1d T4 → 1e T4 → 1f T8 → 1f T9
- `sync_orchestrator.dart`: 1d T5 → 1d T7 → 1e T6 → 1e T8
- `connectivity_service.dart`: 1d T6 → 1e T7
- `library_crud_repository.dart`: 1f T3 (doc-only) → 1e T3 (code)
- `topos_screen.dart` + `topos_screen_test.dart`: **1a T4 → 1f T6**
- `test/app/app_test.dart`: 1d T2 → 1d T6 → 1d T7 → 1e T7 → 1e T9
- `test/features/backup/data/sync_service_test.dart`: 1d T2 → 1d T3 → 1d T4 → 1d T6 → 1e T2 → 1e T4 → 1e T7 → 1f T8 → 1f T9 → 1f T10
- `test/features/backup/application/sync_orchestrator_test.dart`: 1d T2 → 1d T5 → 1d T6 → 1d T7 → 1e T6 → 1e T7 → 1e T8 → 1e T10
- `test/features/backup/data/{connectivity_service,cloud_backup_service}_test.dart`: 1d T6 → 1e T7

**Phase order**

1. **Phase 1 — three independent trees, fully parallel:** §1a (T1–T5), §1b (T1–T5), §1f-photo (T1–T6), plus the two orphan tasks 1e T1 (`backup_repository.dart`) and 1e T5 (`sync_retry_schedule.dart`, new file). Only intra-phase constraint: **1a T4 before 1f T6.**
2. **Phase 2 — §1d in full (T1→T8), strictly serial.** Nothing else may touch `lib/features/backup/**` or `test/app/app_test.dart` during it.
3. **Phase 3 — §1e (T2, T3, T4, T6, T7, T8, T9, T10), strictly serial**, on top of Phase 2.
4. **Phase 4 — §1f-sync (T7→T10), strictly serial**, on top of Phase 3.

`lib/main.dart` is touched only by 1b T4 among the five fragments — but it is exactly the file a future §1c will need, so §1c must be serialised against 1b T4 (and against 1e T3 / 1a T4 / 1f T6, which own `library_crud_repository.dart` and `topos_screen*`).

---

## Parallel-safe pairs

Strictly file-disjoint, verified against every fragment's `filesTouched`:

| A | B | Shared files |
|---|---|---|
| **§1a T1–T3, T5** | **§1b T1–T5** | none |
| **§1a T1–T3, T5** | **§1f T1–T5** | none |
| **§1b (all)** | **§1f T1–T6** | none |
| **§1a T1–T3, T5** | **§1d (all)** | none |
| **§1b (all)** | **§1d (all)** | none |
| **§1b (all)** | **§1e (all)** | none (1b owns `main.dart`, 1e owns `app.dart`) |
| **§1a (all)** | **§1e (all)** | none |
| **§1f T1–T2, T4–T5** | **§1e T1, T5** | none |
| **§1e T1** (backup_repository) | **§1e T5** (retry schedule) | none — both are orphan leaves, runnable in Phase 1 |

**Never parallel:** any two of {§1d, §1e, §1f-sync}; §1a T4 with §1f T6; §1e T3 with §1f T3.

One caveat that is *not* a file collision but behaves like one: after **1e T8** the orchestrator's `build()` unconditionally does `ref.watch(connectivityServiceProvider).statusChanges().listen(...)`. `test/widget_test.dart:74` and `test/app/app_test.dart:148, :318` all mount `MasiApp` **without** overriding `connectivityServiceProvider`, so they will construct the real `SystemConnectivityService()`. 1e's `checkConnectivity()` plugin-availability probe (catchable `MissingPluginException`, unlike an `EventChannel`'s uncatchable `FlutterError.reportError`) is the **only** thing keeping those green. Do not "simplify" it, and add the `connectivityServiceProvider` override to all four `app_test.dart` containers, not the two 1d names.

---

## Signature blast radius

`1d T2` changes `SyncRemote.upsertOwnRows` from `Future<void>` to `Future<List<TablePushOutcome>>`. Grepped, not guessed.

**Declarations/overrides that MUST move in the same commit (6):**

| File:line | Symbol | Absorbed by |
|---|---|---|
| `lib/features/backup/data/sync_remote.dart:86` | `abstract class SyncRemote` | 1d T2 |
| `lib/features/backup/data/sync_remote.dart:355` | `SupabaseSyncRemote` | 1d T2 |
| `lib/features/backup/application/sync_providers.dart:75` | `_UnavailableSyncRemote` (`=> _unavailable()` returns `Never`, assignable) | 1d T2 |
| `test/features/backup/data/sync_service_test.dart:36` | `FakeSyncRemote` | 1d T2 |
| `test/features/backup/application/sync_orchestrator_test.dart:31` | `_CountingSyncRemote` | 1d T2 |
| `test/app/app_test.dart:34` | `_CountingSyncRemote` (duplicate class, same name) | 1d T2 |

**Subclasses that inherit and need NO change (2):** `ThrowingFetchSharedToposRemote` (`sync_service_test.dart:267`, overrides `fetchSharedTopos` only), `_ThrowingSharedToposSyncRemote` (`sync_orchestrator_test.dart:110`, same).

**Call sites that still compile unchanged (3):** `sync_service.dart:338` (`await`), `sync_service_test.dart:1214` (`expect(() => remote.upsertOwnRows(...), throwsA(isA<AssertionError>()))` — the ownerId `assert` must stay outside any try/catch so this keeps passing), `sync_service_test.dart:1827` (`await`).

**Doubles authored by *later* fragments that must be written against the NEW type (5):**

- 1d's own `AllTablesFailingSyncRemote`, `ThrowingUpsertSyncRemote`, `OneTableFailingSyncRemote` (T3) — already correct.
- 1d's `_FailingPushSyncRemote` (T5) — already correct.
- **1e T4 `_MidPushWriteRemote`** — declares `Future<void>`, calls `super.upsertOwnRows(...)`. Must become `Future<List<TablePushOutcome>>` and `return await super.upsertOwnRows(...)`. **Broken as written.**
- **1e T4 `_ThrowingUpsertRemote`** — declares `Future<void>`. **Delete; use 1d's `ThrowingUpsertSyncRemote`.**
- **1e T6 `_OfflineToggleSyncRemote`** — declares `Future<void>`. Must return outcomes (e.g. `[for (…) TablePushOutcome.ok(…)]` when online).
- 1f T8/T10 `FailingUploadSyncRemote`, `_SinglePageListingRemote` override `uploadPhoto`/`listPhotoObjectPaths` only — unaffected.

**Second signature change, separate radius:** `ConnectivityService` gains **two** members (1d `isBackendReachable`, 1e `statusChanges`). All four fakes use `implements`, so a concrete default on the abstract class would not help — every fake needs both members. The four files are `sync_orchestrator_test.dart:143`, `sync_service_test.dart:276`, `cloud_backup_service_test.dart:74`, `app_test.dart:132`. 1d T6 absorbs the first member's churn across all four; 1e T7 absorbs the second's.

**Third, trivial:** `openConnection()` — one production caller (`database_provider.dart:17`), zero test callers. 1a T2 absorbs it.

---

## Duplications resolved

1. **"upsertOwnRows throws" double** — 1d `ThrowingUpsertSyncRemote` vs 1e `_ThrowingUpsertRemote`. **Keep 1d's** (public, correct signature, same file). Delete 1e's; its T4 test uses 1d's.
2. **`connectivityServiceProvider` override in `sync_orchestrator_test.makeContainer`** — 1d T7 and 1e T8 both add it. **1d T7 writes it once.**
3. **`_FakeConnectivityService`/`FakeConnectivityService` extensions** — 1d and 1e both rewrite all four classes. **One merged rewrite per class**, authored in 1d T6, extended in 1e T7.
4. **`wallVisibility` map** — 1e T4 (`selectOnly` over all own walls) vs 1f T9 (derived from `walls`). **Keep 1e's**; 1f's is wrong under dirty scoping.
5. **`PushSyncResult` rewrite** — 1d T3 and 1f T8 both emit the whole class. **One class**, merged per decision #8/#9 above.
6. **Push-failure reporting channel** — 1d's `errors`/`rowsFailed` vs 1f's `photoErrors`/`photosFailed`. **Keep both fields** (they differ in retryability, which §1e's loop depends on) but fold `photosFailed` into `fullyLanded` and `photoErrors` into `lastPushError`. A single flattened list would make §1e retry forever on `photosMissingLocalBytes`.
7. **`_writeThumbnailBestEffort`** — 1f T2 extracts it in the web backend; the native backend already has an identically-named private helper at `photo_files_native.dart:119`. **Not a duplication to resolve** — deliberate symmetry; keep both names identical.
8. **CLAUDE.md doc corrections** — 1f T10 claims the "~377 tests" fix; 1e's risks list also claims it, plus the "outbox" fix. **Assign the whole doc block to one task (1f T10)**, including the `outbox` and `web_smoke_test` corrections that currently have no owner.
9. **`grep` gate reconciliation** (spec Testing section) — 1a correctly reports this as **already done** by commit `14332a1`; verified `.github/workflows/ci.yml:49` is byte-identical to `tool/build_web.sh:40`. No task needed; the spec text is stale.

---

## Assertion coverage table

| Spec § | Assertion | Owner | Status |
|---|---|---|---|
| §1a | inMemory backend → non-durable state, create-topo affordance disabled | 1a T1 (model) + 1a T4 (widget test, both buttons `onPressed == null`) | ✅ |
| §1a | persistent backend → durable, creation allowed | 1a T4 (`opfsLocks` case) | ✅ |
| §1a | chosen implementation logged outside `kDebugMode` | 1a T1 (`logStorageDurability` captured via mutable `debugPrint`) + 1a T3 (zero `kDebugMode` under `lib/`) | ✅ |
| §1a | ~~`moveExistingIndexedDbToOpfs: true` covered by a browser migration test before shipping~~ | ~~1a T3 (source pin) + 1a T5 (browser: seeded IndexedDB row survives reopen) + `tool/serve_web_isolated.py` for the real OPFS branch~~ | ❌ **Superseded 2026-08-01** — the flag shipped and was **reverted** (`09cf076`). A manual-on-Chrome proof was never sufficient: it cannot exercise a crash mid-move or a second tab, which are the two loss paths. Do not re-add the flag. See `1a-storage-interlock.md` §Risks. |
| §1b | boot on web calls `persist()` exactly once and records the outcome | 1b T3 (memoised `_requestOnce`, 2 concurrent + 1 later ⇒ `requestCalls == 1`) + 1b T4 (boot wiring) + 1b T5 (real Chrome) | ✅ |
| §1b | denied/unavailable `persist()` degrades silently — never blocks boot or throws | 1b T3 (`throwOnRequest` ⇒ `failed`, future completes normally) + 1b T4 (throw-everything fake, no unhandled async error) | ✅ |
| **§1c** | **authStateProvider in error → `toposProvider` still emits the user's topos** | — | ❌ **NO OWNER** |
| **§1c** | **after `sessionExpired` sign-out, local reads/writes still target the right `ownerId`** | — | ❌ **NO OWNER** |
| **§1c** | **after user-initiated sign-out, `lastKnownUid` is cleared** | — | ❌ **NO OWNER** |
| **§1c** | **`_ownOrUnowned` mutation matching 0 rows returns/throws a distinguishable failure** | — | ❌ **NO OWNER** |
| **§1c** | **web router: persisted-session + auth-stream-error does not redirect; no-session does** | — | ❌ **NO OWNER** |
| §1d | remote throws on every table → push reports failure; status not `idle`; `lastSyncedAt` unchanged | 1d T3 (`AllTablesFailingSyncRemote`) + 1d T5 (`_FailingPushSyncRemote`, `lastSyncedAt == null`) | ⚠️ **Conditionally covered** — holds for row failures; **broken for photo-byte failures** until `fullyLanded` is amended (decision #9). |
| §1d | same scenario **with zero photo rows** also reports failure (the S1 regression) | 1d T3, first test — asserts the zero-photo precondition explicitly | ✅ (verified: `sync_service.dart:369`'s `if (photos.isEmpty) return 0;` short-circuit is real and preserved by 1f T8) |
| §1d | a row excluded by `filterValidSyncRows` appears in the push result's failure channel | 1d T1 (`partitionSyncRows`) + 1d T4 (`pushRequiredFields` seam, `rowsFailed == 1`, error names table + row id) | ✅ |
| §1d | reachable-but-not-authenticated vs unreachable are distinguishable; `offline` from a real offline condition | 1d T6 (probe: 2xx/401/503 ⇒ reachable, `ClientException`/`TimeoutException` ⇒ not) + 1d T7 (`offline` vs `error` with `currentStatus()` still reporting `wifi`) | ✅ |
| §1d | the `sync-status` label reports truthfully (prose) | 1d T8 (`idle` + `lastPushError` ⇒ "Sync error", never "Synced • …") | ✅ |
| §1e | a push that fails offline is retried after the backoff, no user action, no further local write | 1e T6 (`_OfflineToggleSyncRemote` + `_RecordingRetrySchedule`) | ⚠️ real-delay flake risk, see D-15 |
| §1e | backoff grows on repeated failure, resets after success, never exceeds the ceiling | 1e T5 (clock-free growth/ceiling/jitter) + 1e T6 (attempt numbers `[1,2,3]`, reset to 1) | ✅ |
| §1e | a connectivity-regain event triggers a push within the debounce window | 1e T8 (30 s debounce pending, regain ⇒ 1 push **and** 1 pull) | ✅ |
| §1e | two concurrent push triggers ⇒ exactly one in-flight push | 1e T6 (`identical(first, second)`, `pushCallCount == 1`) | ✅ |
| §1e | `dirty` cleared only after a confirmed push; a failed push leaves it set | 1e T4 (+ the mid-push (id, updatedAt) CAS test) | ✅ |
| §1e | the pushed row payload contains neither `dirty` nor `remoteId` | 1e T2 | ✅ |
| §1e | importing a pulled snapshot does not mark rows dirty and does not schedule a push | 1e T1 (`_notDirty` on all 9 `_import*`) + 1e T6 (S9 group: `pullNow` adds no push call) | ✅ |
| §1e | **end-to-end** create offline → remote reachable with no local write → topo reaches the remote | 1e T10 | ✅ |
| §1e | app-resume triggers a push, not only the throttled pull (prose) | 1e T9 | ✅ |
| §1e | `ConnectivityService` gains the change stream + browser `online` event (prose) | 1e T7 (`statusChanges` + `online_events` two-way seam) | ✅ |
| §1f | byte store throws on write → `importPhoto` throws and no `Photos` row exists | 1f T2 (`_FailingWriteStore`, store left empty) + 1f T3 (`photos` table empty) | ✅ (VM-importability of `photo_files_web.dart` **proven by probe** this session) |
| §1f | a quota failure is a distinguishable, user-presentable error | 1f T1 (classifier + `userMessage`) + 1f T4 (SnackBar widget test, two distinct wordings) + T5/T6 wiring | ✅ |
| §1f | push uploads bytes before upserting the photo row; when bytes fail, that row's metadata is not pushed | 1f T9 (`callLog` ordering + `fetchOwnRows()['photos']` empty while other tables land + heal-on-retry + slice case) | ✅ |
| §1f | with 150 objects already remote, the skip-set contains all 150 and zero re-uploads occur | 1f T7 (`collectPagedObjects`) + 1f T10 (150-object test + `_SinglePageListingRemote` anti-vacuity proof) | ✅ |
| Testing | web integration: **reload-persistence with real assertions**; correct CLAUDE.md's "web_smoke_test proves drift-on-WASM persistence" | — | ❌ **NO OWNER** (1a T5 asserts the backend is not `inMemory`, which is adjacent but not a reload test) |
| Docs | CLAUDE.md "outbox push/pull" is wrong (S8) | — | ❌ **NO OWNER** (assign to 1f T10) |
| Docs | CLAUDE.md "~377 tests" → 1576 | 1f T10 (final step) | ⚠️ also claimed in 1e's risks — de-duplicate onto 1f T10 |
| Docs | `docs/web-port-backlog.md:27-32` stale; `WEB_PERF_AUDIT.md:86` 7.2 MB → 37 MB | — | ❌ **NO OWNER** |

---

## Defects to fix in the fragments

**Blocking (would break the build or reintroduce a spec-level bug)**

- **D-1. §1c has no fragment.** Five assertions unowned, and the two live bugs it fixes (L4 hard-sign-out silently dropping every edit; the native library silently emptying on an `AsyncError`) are the only Stage-1 items that affect *native today*. Commission it before Phase 2, and serialise it against 1b T4 (`main.dart`), 1e T3 (`library_crud_repository.dart`), 1a T4/1f T6 (`topos_screen*`).
- **D-2. `fullyLanded` ignores photo failures.** See decision #9. As written, 1d T5's `_runPush` will report `idle` + a fresh `lastSyncedAt` for a push in which every photo's bytes failed to upload — i.e. the "Synced • just now" lie the whole of §1d exists to kill, re-entering via §1f. Fix: `&& photosFailed == 0`, and merge `photoErrors` into `lastPushError`.
- **D-3. Three test doubles in §1e declare the old `Future<void> upsertOwnRows`** — `_ThrowingUpsertRemote` and `_MidPushWriteRemote` (T4), `_OfflineToggleSyncRemote` (T6). None compiles after 1d T2. Delete the first (use 1d's `ThrowingUpsertSyncRemote`); retype the other two.
- **D-4. §1f T9's `wallVisibility` derivation is wrong under `PushScope.dirtyOnly`.** `{for (final wall in walls) wall.id: wall.visibility}` over a dirty-filtered `walls` list silently stops uploading the shared copy of a new photo on an already-pushed (clean) shared wall. Use 1e T4's `selectOnly` projection.
- **D-5. §1f T8's two `PushSyncResult` field doc comments are swapped** relative to their declarations — 1f flags this in a follow-up step but leaves the defect in the code block. Pair each doc with its own field and declare `photosFailed` before `photosMissingLocalBytes`.
- **D-6. §1d T7's `app_test.dart` override list is incomplete.** It names the two "#57 containers" (~:401, ~:493) but misses `_makeContainer` (`:148`) and the inline container (`:318`) — both mount `MasiApp` and both would construct the real `SystemConnectivityService`. Benign under 1d alone (signed-out ⇒ `skippedSignedOut`, probe never reached) but **not** under 1e T8's unconditional `statusChanges()`. Override all four.
- **D-7. §1f T9's `FakeSyncRemote.upsertOwnRows` loop replacement drops 1d's return value.** T9's code block replaces only the loop, without restating the signature or the `outcomes` accumulation / `return outcomes;` that 1d T2 introduced. Applied literally after 1d, it produces a method with a non-`void` return type and no return. Rewrite T9's patch against the post-1d body.
- **D-8. Duplicate `connectivityService` parameter** in `sync_orchestrator_test.makeContainer` if both 1d T7 and 1e T8 apply their patches literally. Compile error. 1d T7 writes it; 1e T8 appends only `retrySchedule`.

**Placeholders — descriptions, not real Dart**

- **D-9. §1d T6** emits `connectivity_service.dart` with three elisions: `// ... enum NetworkStatus unchanged (lines 4-19) ...`, `Future<NetworkStatus> currentStatus() async { // ... body unchanged (lines 45-66) ... }`. The `currentStatus` body must be the real delegation to `classifyConnectivityResults` (decision #3), and `NetworkStatus` must be preserved verbatim. As written this file would not compile.
- **D-10. §1d T5** emits `SyncOrchestratorState` with `/// (existing doc for lastPullError preserved verbatim from lines 46-61)` in place of the real 16-line doc comment. Copy the actual text (verified at `sync_orchestrator.dart:46-62`).
- **D-11. §1d T3/T4 hand-off hazard.** T3 declares `final errors = <String>[]; var rowsFailed = 0;` at the top of the upsert block; T4 *moves* those declarations above the `guard` closure and instructs the implementer to delete the T3 copies. Split across two engineers this yields a duplicate-declaration compile error. Fold T3+T4 into one commit, or have T3 declare them where T4 wants them.
- **D-12. §1e T4's `_clearDirty`** lists nine per-table clears but is presented as one code block whose per-table bodies are near-identical — no placeholder, but verify all nine table names appear (`profiles, areas, sectors, walls, photos, routes, ascents, comments, likes`) since a silently missing table means those rows never go clean and §1e's loop never terminates for them.

**Wrong assertions / counts**

- **D-13. Every absolute test-count assertion is mutually inconsistent.** 1a claims 1584/1590/1599/1604; 1b 1598; 1d 1583→1606; 1e "1576 + ~25"; 1f "1576+". Each assumed sole occupancy. Restate all as **"baseline + N for this task"** and gate on `flutter test` being green, never on an absolute number.
- **D-14. §1f T7's assertion "`grep -rn '\.list(' lib` returns exactly two call sites" is wrong — there are three** (`sync_remote.dart` ×2 + `backup_remote.dart` ×1, all three verified). Change to three. 1f T10 repeats the same wrong count.
- **D-15. §1a T1 claims 8 tests; the file contains 7.** §1a T3 claims 9; the file contains 8. Cosmetic but they are written as gate assertions.
- **D-16. §1e cites "drift 2.34.1"**; `pubspec.lock` resolves **2.34.2**. Harmless (identical API) but 1a's citations are the correct ones.

**Timing / realism**

- **D-17. Real-delay flake risk in §1e's orchestrator tests.** The spec's Testing section says "backoff tests use [`syncDebounceDurationProvider`/`nowMsProvider`], never real delays." 1e argues (correctly) that the existing file is built on shrink-the-seam + tiny real waits, and it does keep the *growth law* clock-free in T5. But **1e T10's second test waits 200 ms of wall-clock and asserts `schedule.attempts.length > 5`** — six full retry cycles, each doing real Drift I/O, inside 200 ms. That is a genuine flake. T6's `attempts.take(3) == [1,2,3]` inside 120 ms with a 15 ms schedule is tighter than it reads. Fix: assert `>= 3` (or better, drive the retry by invoking `pushNow()` directly and assert the *requested attempt numbers* rather than counting completions within a wall-clock budget).
- **D-18. `fake_async` is not a declared dependency** — 1e's rationale for avoiding it is correct (`depend_on_referenced_packages` would fire; `pubspec.lock:316` shows it transitive-only). No action, but do not let a verifier demand it without a pubspec change that collides with every other workstream.
- **D-19. Image decode in widget tests.** 1f T6's new-topo tests run the real `ui.instantiateImageCodec` inside `_handleNewTopo`. That is acceptable *only* because the existing A6 group in the same file already does exactly this (with `tester.runAsync` for the file write and `_drain`/`_drainNoSettle` for the pumps) — the CLAUDE.md prohibition is specifically about `TopoCanvas`'s decode under fake-async. 1f T4's SnackBar test correctly avoids `pumpAndSettle`. No canvas decode is introduced anywhere. ✅
- **D-20. Riverpod v3 compliance: clean.** No `StateProvider` in any fragment; every new controller is `Notifier` + `NotifierProvider(X.new)`. `ref.mounted` (riverpod 3.3.2) is used correctly in 1a and 1b. 1a's `Future<void>.microtask` around the synchronous native storage report is load-bearing (`element.dart`'s "Providers are not allowed to modify other providers during their initialization" assert) — do not simplify it away.

**Verify-during-implementation (plausible but unproven)**

- **D-21. §1b's `storage as web.StorageManager`** casts a `JSAny?` to an extension type after only an `isA<JSObject>()` narrowing. The static type at the cast site is still `JSAny?`; this may need `(storage as JSObject) as web.StorageManager`. `flutter analyze` is the gate (1b's own step runs it) — but it is the single most likely analyzer failure in that fragment.
- **D-22. §1d's `/auth/v1/health` probe on web** is a cross-origin `fetch` from a COEP `require-corp` page. 1d flags it; confirm on the deployed origin before shipping, because a blocked probe returns `false` and would make the app permanently claim "Offline".
- **D-23. §1f T2's new `photo_byte_store_test.dart` case** (writing into a DB whose object store was deliberately not created) may not reject with `idb_shim`'s memory factory. 1f already scripts the fallback (delete that one test; the injected-store tests carry the contract). Keep that fallback.
- **D-24. §1a T5's browser test writes to the real `climbtopo` database name** in the headless-Chrome origin and runs the full v8 migration. Harmless in CI, but it is not hermetic and should be noted next to the `masi_move_probe` test-only name used in the second case.

---

## Recommended task numbering

1. §1a — Platform-agnostic storage-durability model + release-visible log — files: lib/core/db/connection/storage_durability.dart, test/core/db/storage_durability_test.dart
2. §1a — Surface the connection layer's verdict through storageDurabilityProvider — files: lib/core/db/storage_durability_provider.dart, lib/core/db/connection/connection.dart, lib/core/db/connection/connection_native.dart, lib/core/db/connection/connection_stub.dart, lib/core/db/connection/connection_web.dart, lib/core/db/database_provider.dart, test/core/db/storage_durability_provider_test.dart
3. §1a — ~~Pass moveExistingIndexedDbToOpfs: true and~~ pin the web seam with a source guard — files: lib/core/db/connection/connection_web.dart, test/core/db/connection_seam_source_test.dart — **(Corrected 2026-08-01: the flag half is reverted (`09cf076`) and must not be re-added; the source guard stands, but pin the flag's ABSENCE, not its presence. See `1a-storage-interlock.md` Task 3.)**
4. §1a — Disable topo creation behind an unmissable warning when storage is ephemeral — files: lib/features/library/presentation/topos_storage_banner.dart, lib/features/library/presentation/topos_screen.dart, test/features/library/presentation/topos_screen_test.dart
5. §1a — Prove it in a real browser: storage verdict + the IndexedDB→OPFS move — files: integration_test/web_storage_backend_test.dart, tool/serve_web_isolated.py
6. §1b — Value types for the storage-persistence seam — files: lib/core/storage/storage_persistence_types.dart, test/core/storage/storage_persistence_types_test.dart
7. §1b — Conditional-export seam over navigator.storage (stub + web backends) — files: lib/core/storage/storage_persistence.dart, lib/core/storage/storage_persistence_stub.dart, lib/core/storage/storage_persistence_web.dart, test/core/storage/storage_persistence_stub_test.dart
8. §1b — Service interface + one-shot persistence controller and provider — files: lib/core/storage/storage_persistence_service.dart, lib/core/storage/storage_persistence_providers.dart, test/core/storage/storage_persistence_providers_test.dart
9. §1b — Request persistent storage exactly once at boot, after the first frame is scheduled — files: lib/main.dart, test/main_boot_storage_persistence_test.dart
10. §1b — Browser-executed assertions for the navigator.storage interop — files: integration_test/web_storage_persistence_test.dart
11. §1f — PhotoWriteException: a distinguishable, user-presentable local byte-write failure — files: lib/features/topo/data/photo_write_exception.dart, lib/features/topo/data/photo_files.dart, test/features/topo/data/photo_write_exception_test.dart
12. §1f — Web importPhoto/writePhotoBytes PROPAGATE the byte-write failure (L3) — files: lib/features/topo/data/photo_files_web.dart, lib/features/topo/data/photo_files_native.dart, test/features/topo/data/photo_files_web_test.dart, test/features/topo/data/photo_byte_store_test.dart
13. §1f — attachPhotoToWall creates NO Photos row when the byte write fails — files: lib/features/library/data/library_crud_repository.dart, test/features/library/data/photo_ownership_test.dart
14. §1f — photoWriteFailureSnackBar + settleFailedPhotoAttach — files: lib/features/topo/presentation/topo_canvas_photo_ops.dart, test/features/topo/presentation/photo_write_failure_snackbar_test.dart, test/features/topo/application/topo_canvas_wall_binding_test.dart
15. §1f — Wire the canvas add/replace-photo flow to the failure path — files: lib/features/topo/presentation/topo_canvas_screen.dart
16. §1f — Wire the Topos-home New topo flow, with orphan-wall cleanup — files: lib/features/library/presentation/topos_screen.dart, test/features/library/presentation/topos_screen_test.dart
17. §1e — importSnapshot never marks an imported row dirty (S9 root fix) — files: lib/features/backup/data/backup_repository.dart, test/features/backup/data/backup_repository_test.dart
18. §1e — SyncRetrySchedule: exponential backoff with jitter, 2s → 5min ceiling — files: lib/features/backup/application/sync_retry_schedule.dart, test/features/backup/application/sync_retry_schedule_test.dart
19. §1d — partitionSyncRows + TablePushOutcome (pure additions) — files: lib/features/backup/data/sync_remote.dart, test/features/backup/data/sync_remote_test.dart
20. §1d — upsertOwnRows returns List&lt;TablePushOutcome&gt; (signature blast radius) — files: lib/features/backup/data/sync_remote.dart, lib/features/backup/application/sync_providers.dart, test/features/backup/data/sync_service_test.dart, test/features/backup/application/sync_orchestrator_test.dart, test/app/app_test.dart
21. §1d — PushSyncResult gains rowsFailed/errors/fullyLanded and pushOwn aggregates them (S1 core) — files: lib/features/backup/data/sync_service.dart, test/features/backup/data/sync_service_test.dart
22. §1d — Required-field exclusions feed the same failure channel (L5), via pushRequiredFields — files: lib/features/backup/data/sync_service.dart, test/features/backup/data/sync_service_test.dart
23. §1d — A push that did not fully land never reports idle or stamps lastSyncedAt (lastPushError) — files: lib/features/backup/application/sync_orchestrator.dart, test/features/backup/application/sync_orchestrator_test.dart
24. §1d — Real Supabase reachability probe behind the ConnectivityService seam (S4) — files: lib/features/backup/data/connectivity_service.dart, test/features/backup/data/connectivity_service_test.dart, test/features/backup/data/sync_service_test.dart, test/features/backup/application/sync_orchestrator_test.dart, test/app/app_test.dart, test/features/backup/data/cloud_backup_service_test.dart
25. §1d — A failed push classifies itself as offline vs error using the probe (S4 end-to-end) — files: lib/features/backup/application/sync_orchestrator.dart, test/features/backup/application/sync_orchestrator_test.dart, test/app/app_test.dart
26. §1d — The sync-status label reports truthfully (no badge, D-2) — files: lib/features/account/presentation/account_screen.dart, test/features/account/presentation/account_screen_test.dart
27. §1e — Strip dirty/remoteId from the pushed row payload (S8) — files: lib/features/backup/data/sync_remote.dart, lib/features/backup/data/sync_service.dart, test/features/backup/data/sync_service_test.dart
28. §1e — Every push-worthy local write marks the row dirty (S8) — files: lib/features/library/data/library_crud_repository.dart, lib/features/topo/data/route_repository.dart, test/features/library/data/library_crud_repository_test.dart, test/features/topo/data/route_repository_test.dart
29. §1e — Dirty-scoped push, hasPendingLocalChanges(), race-safe confirmed-push dirty clear — files: lib/features/backup/data/sync_service.dart, test/features/backup/data/sync_service_test.dart
30. §1e — Orchestrator: push in-flight guard, pushNow(), retry-until-clean, nothing-pending early-out — files: lib/features/backup/application/sync_orchestrator.dart, test/features/backup/application/sync_orchestrator_test.dart
31. §1e — ConnectivityService.statusChanges(): connectivity_plus on native, browser online/offline on web — files: lib/features/backup/data/connectivity_service.dart, lib/features/backup/data/online_events.dart, lib/features/backup/data/online_events_native.dart, lib/features/backup/data/online_events_web.dart, test/features/backup/data/connectivity_service_test.dart, test/features/backup/data/sync_service_test.dart, test/features/backup/data/cloud_backup_service_test.dart, test/features/backup/application/sync_orchestrator_test.dart, test/app/app_test.dart
32. §1e — Connectivity regain triggers BOTH a push and a pull (S3) — files: lib/features/backup/application/sync_orchestrator.dart, test/features/backup/application/sync_orchestrator_test.dart
33. §1e — App resume flushes a push, not only the throttled pull (S2) — files: lib/app/app.dart, test/app/app_test.dart
34. §1e — End-to-end: create offline, remote becomes reachable with no further local write, topo arrives — files: test/features/backup/application/sync_orchestrator_test.dart
35. §1f — Paginate every Supabase Storage listing past its 100-object default (S6) — files: lib/features/backup/data/storage_pagination.dart, lib/features/backup/data/sync_remote.dart, lib/features/backup/data/backup_remote.dart, test/features/backup/data/storage_pagination_test.dart
36. §1f — Count byte-upload failures instead of continuing silently (merge into PushSyncResult; amend fullyLanded) — files: lib/features/backup/data/sync_service.dart, test/features/backup/data/sync_service_test.dart
37. §1f — Flip the push to bytes-then-metadata and withhold failed photo rows (S5) — files: lib/features/backup/data/sync_service.dart, test/features/backup/data/sync_service_test.dart
38. §1f — Prove the skip-set sees all 150 objects and re-uploads nothing; correct the stale docs — files: test/features/backup/data/sync_service_test.dart, CLAUDE.md

**Insert §1c as tasks 6a–6e** (before task 19, after task 5): it must precede task 9 (`lib/main.dart`), task 16 (`topos_screen.dart` + its test), and task 28 (`library_crud_repository.dart`), and its `toposProvider` change lands in `lib/features/library/application/library_providers.dart:66-67`, which no present fragment touches.
