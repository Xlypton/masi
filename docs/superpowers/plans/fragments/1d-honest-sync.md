# §1d — Sync tells the truth (S1, S4)

> Reconciled fragment. Source: `docs/superpowers/plans/fragments/raw/1d-honest-sync.raw.json`,
> corrected against `docs/superpowers/plans/fragments/reconciliation.md` and the Global
> Constraints of `docs/superpowers/plans/2026-07-31-web-offline-stage1.md`.
> Plan numbering: master-plan tasks **19–26**. Execution phase: **Phase 2**.

**Workstream.** `upsertOwnRows` reports per-table outcomes, `pushOwn` aggregates
`rowsFailed`/`errors` (including required-field exclusions, L5), a push that did not fully
land can never report `idle` + `lastSyncedAt`, and `SyncStatus.offline` becomes reachable
through a real Supabase reachability probe behind the `ConnectivityService` seam.

§1d is the **pivot fragment**: it creates the push-failure channel that §1e (retry/scheduling)
and §1f (photo integrity) both fill, and it owns the `SyncRemote.upsertOwnRows` signature
change that every later test double must be written against. Nothing in §1e or §1f may start
until all eight tasks here have landed.

---

## Reconciliation corrections applied

| # | Correction | Where |
|---|---|---|
| **D-9** *(blocking)* | The emitted `connectivity_service.dart` contained three elisions (`// ... enum NetworkStatus unchanged ...`, a `currentStatus()` whose entire body was a comment) and **would not compile**. Rewritten as the real, complete file: `NetworkStatus` verbatim, the 8-line web short-circuit rationale verbatim, and `currentStatus()` delegating to the top-level `classifyConnectivityResults(List<ConnectivityResult>)` per decision #3. **No elisions remain anywhere in this document.** | Task 6, step 3 |
| **D-10** *(blocking)* | `SyncOrchestratorState`'s `/// (existing doc for lastPullError preserved verbatim from lines 46-61)` placeholder replaced with the real 16-line doc from `sync_orchestrator.dart:46-61`. One clause amended on purpose (see the marker on that block). | Task 5, step 4 |
| **D-11** *(blocking)* | Tasks 3 and 4 both declared `final errors = <String>[]; var rowsFailed = 0;` — T4 "moved" T3's and told the implementer to delete them, which across two engineers is a duplicate-declaration compile error. **Task 3 now declares them where Task 4 wants them** (above the guard block); Task 4 only adds usages, and its delete-step is gone. | Task 3 (new step 6), Task 4 |
| **D-6** *(blocking)* | The `app_test.dart` override list named only the two "#57" containers (`:401`, `:493`) and missed `_makeContainer` (`:148`) and the inline C3 container (`:318`). All four mount `MasiApp` and would construct the real `SystemConnectivityService`. **All four now get the `connectivityServiceProvider` override.** | Task 7, step 9 |
| **D-2** *(blocking, cross-fragment)* | `fullyLanded` is defined here **without** `photosFailed` (which §1f adds), and the field's doc now says loudly and in-source that **§1f MUST amend it** to `didPush && rowsFailed == 0 && errors.isEmpty && photosFailed == 0`, with `lastPushError` concatenating `errors + photoErrors` and `photosMissingLocalBytes` deliberately excluded. Without the amendment a push whose every photo's bytes failed reports "Synced • just now" — the S1 lie, re-entering via the photo path. | Task 3, step 5 |
| **Decisions #1/#2/#3** | `ConnectivityService` ends up with BOTH `Future<bool> isBackendReachable()` (this fragment) and `Stream<NetworkStatus> statusChanges()` (§1e). This fragment adds its member and does **not** re-declare the abstract class wholesale beyond that. `SystemConnectivityService`'s constructor becomes 3-positional `([Connectivity?, bool?, http.Client?])`. The `classifyConnectivityResults` extraction lands here (§1d must emit a compiling file); §1e T7 then only adds `statusChanges()`. | Task 6 |
| **Decisions #4/#5** | The four `ConnectivityService` fakes (`sync_orchestrator_test.dart:143`, `sync_service_test.dart:276`, `cloud_backup_service_test.dart:74`, `app_test.dart:132`) are rewritten **once**, here, as the union of §1d's and §1e's additions. `statusChanges()` is written without `@override` (the abstract member does not exist until §1e T7, and `override_on_non_overriding_member` would fail `flutter analyze`); §1e T7's only remaining job on these four classes is to add the annotation. | Task 6, steps 4–7 |
| **Decision #6** | `makeContainer(...)` in `sync_orchestrator_test.dart:175` gets its `connectivityService` param **and** its `connectivityServiceProvider` override written exactly once, here. §1e T8 appends only `retrySchedule` / `syncRetryScheduleProvider` / `addTearDown(connectivityFake.dispose)`. Duplicating the param is a compile error. | Task 7, step 1 |
| **Decision #11** | This fragment's **public** `ThrowingUpsertSyncRemote` is kept; §1e's private `_ThrowingUpsertRemote` (old `Future<void>` signature) is deleted by §1e. | Task 3, step 1 |
| **D-22** | The `/auth/v1/health` probe is a cross-origin `fetch` from a COEP `require-corp` page — flagged as a ship gate with an explicit fallback (see *Risks & ship gates*). | Task 6 |
| **D-13** | Every absolute test-count assertion (the raw fragment claimed 1583 → 1606) is restated as **"baseline + N for this task"**, gating on `flutter test` being green. **The live baseline is 1586, not 1576** — §1b tasks 1–2 landed (`694e7f2`, `02b854b`). | all tasks |

### Additional defects found while reconciling (not in reconciliation.md)

1. **Task 1's test count is wrong.** Its assertion and its `expected` claim **7** tests; the code
   block it emits contains **5** (`partitionSyncRows` ×3, `TablePushOutcome` ×2). This is the same
   class of defect reconciliation.md logged as D-15 for §1a, but it missed it for §1d. Corrected
   to 5 (and the whole §1d chain therefore adds **28** tests, not 30).
2. **`test/app/app_test.dart:506` drifted to `:505`.** The second "#57" container's
   `syncServiceProvider.overrideWithValue(` is at `:505`. Verified in-file.
3. **`account_screen_test.dart:785/:786` drifted to `:786/:787`.** The "Not synced yet" test closes
   at `:786`; the `E1d: sync-status line` group's `});` is at `:787`.
4. **`nowMsProvider` is `database_provider.dart:24`, not `:23`.**
5. **Two import-insertion points were specified out of alphabetical order** (`backup_providers.dart`
   "after `sync_providers.dart`"). Not a compile error (`directives_ordering` is not enabled — the
   test files already put the `package:masi/…` block before `package:drift/…`), but it breaks the
   convention the surrounding blocks follow. Corrected in Task 7.
6. **`SyncStatus.offline`'s doc is `:26-29`, not `:25-29`** — `:25` is the blank separator after
   `error,` and must survive the replacement.
7. **`filterValidSyncRows`'s `debugPrint` is `:327-330`, not `:327-331`.** Cosmetic; the
   surrounding replacement range `:312-334` is correct.
8. **The `lastPullError` doc contains a clause this fragment falsifies** — "`[_runPush] only ever
   changes [status]/[lastSyncedAt]`". D-10 says copy it verbatim; copying a statement that Task 5
   makes false would be worse, so that one parenthetical is amended and the amendment is called out
   at the code block. Everything else is byte-identical.

Everything else in the raw fragment's cited line numbers was opened and verified correct:
`sync_remote.dart` `:34 :80 :86 :233 :260 :289 :312-334 :347 :354-402 :363-368 :369 :394`;
`sync_service.dart` `:23-56 :79 :142 :202-216 :218-224 :238 :277-336 :288 :338-344 :364 :369 :371 :469`;
`sync_orchestrator.dart` `:14 :29 :36 :46-61 :62 :64 :92 :204-220 :209-210 :213-214 :216-219 :292 :305-315 :319-323`;
`connectivity_service.dart` `:7 :25 :26 :30 :31 :53`; `sync_providers.dart` `:74-78 :75 :155 :170-178`;
`backup_providers.dart` `:35`; `supabase_config.dart` `:25 :33`; `account_screen.dart` `:888-908 :895`;
`geocoding_service_test.dart` `:13-29`; `sync_service_test.dart` `:23 :36 :267 :274-283 :276 :287 :309 :310 :312 :333-352 :355 :364 :438 :473 :763 :764 :1171 :1213-1231`;
`sync_orchestrator_test.dart` `:26 :27 :31 :110-115 :143-150 :163 :175-207 :209 :681 :689-711 :725`;
`app_test.dart` `:30 :33-37 :34 :128-135 :132 :146 :148 :318 :401 :421 :493`;
`cloud_backup_service_test.dart` `:72-81 :74`; `connectivity_service_test.dart` `:1-39`;
`account_screen_test.dart` `:28 :142 :692 :693`.

---

## Files touched

| Path | Action | Responsibility |
|---|---|---|
| `lib/features/backup/data/sync_remote.dart` | modify | Add `TablePushOutcome` (per-table push result) + `partitionSyncRows` (reporting counterpart of `filterValidSyncRows`); change `SyncRemote.upsertOwnRows` to return `Future<List<TablePushOutcome>>`; make `SupabaseSyncRemote.upsertOwnRows` report each table's success/failure instead of `continue`-ing behind a debugPrint (current catch at :394). |
| `lib/features/backup/application/sync_providers.dart` | modify | `_UnavailableSyncRemote.upsertOwnRows` (:75) must match the new abstract signature. |
| `lib/features/backup/data/sync_service.dart` | modify | `PushSyncResult` gains `rowsFailed` + `errors` + `fullyLanded` (mirrors `PullResult.errors`); `pushOwn` (:238) aggregates per-table outcomes, converts a whole-call throw into an all-tables-failed result, and routes required-field exclusions into the same channel; new optional `pushRequiredFields` injection seam so the L5 exclusion path is testable end-to-end. |
| `lib/features/backup/application/sync_orchestrator.dart` | modify | `SyncOrchestratorState` gains `lastPushError`; `_runPush` (:204) only reports `idle`+fresh `lastSyncedAt` when `result.fullyLanded`; new `_failedPushStatus()` classifies a failed push as `offline` (backend unreachable) vs `error` via the reachability probe; `SyncStatus.offline`'s doc corrected (it is no longer wifiOnly-only). |
| `lib/features/backup/data/connectivity_service.dart` | modify | `ConnectivityService` gains `Future<bool> isBackendReachable()`; `SystemConnectivityService` implements it as a real GET on `<supabaseUrl>/auth/v1/health` with a 5s timeout via an injectable `http.Client`, deliberately NOT short-circuited by the `_isWeb` branch that makes `currentStatus()` return wifi unconditionally (:53). |
| `lib/features/account/presentation/account_screen.dart` | modify | `_syncStatusLabel` (:895) stops rendering `'Synced • …'` for an `idle` state that carries a `lastPushError` (the case a successful pull creates after a failed push). No new UI, no new strings, no unsynced-count badge (D-2). |
| `test/features/backup/data/sync_remote_test.dart` | create | New pure-Dart unit tests for `partitionSyncRows`, `filterValidSyncRows`'s equivalence to it, and `TablePushOutcome`'s two constructors (there is currently no sync_remote test file at all). |
| `test/features/backup/data/sync_service_test.dart` | modify | `FakeSyncRemote.upsertOwnRows` (:36) returns outcomes; `FakeConnectivityService` (:276) implements `isBackendReachable`; `makeContainer` (:333) gains a `pushRequiredFields` pass-through; new `AllTablesFailingSyncRemote` / `ThrowingUpsertSyncRemote` / `OneTableFailingSyncRemote` doubles; new §1d group incl. the zero-photo S1 regression test and the L5 exclusion test. |
| `test/features/backup/application/sync_orchestrator_test.dart` | modify | `_CountingSyncRemote.upsertOwnRows` (:31) returns outcomes; `_FakeConnectivityService` (:143) gains `isBackendReachable`/`reachable`/`probeThrows`/`probeCallCount`; `makeContainer` (:175) overrides `connectivityServiceProvider` (currently overridden by no test); new `_FailingPushSyncRemote`; new groups for push honesty and for the offline-vs-error classification. |
| `test/app/app_test.dart` | modify | `_CountingSyncRemote.upsertOwnRows` (:34) and `_FakeConnectivityService` (:132) must match the new signatures; add a defensive `connectivityServiceProvider` override to both containers so no widget test can ever issue a live probe. |
| `test/features/backup/data/cloud_backup_service_test.dart` | modify | `FakeConnectivityService` (:74) must implement the new `isBackendReachable` member (compile-only change; `CloudBackupService` itself is untouched). |
| `test/features/backup/data/connectivity_service_test.dart` | modify | New tests for the reachability probe: endpoint/headers, 2xx→true, 5xx→true (any response proves reachability), transport throw→false, timeout→false, probe still runs with `isWeb: true`, and the timeout constant. |
| `test/features/account/presentation/account_screen_test.dart` | modify | Extend the existing `E1d: sync-status line` group (:692) with the `lastPushError` truthfulness cases via the existing `_FixedSyncOrchestrator` (:28) harness. |

Two paths in that table carry corrections that change what the file ends up containing:

- `lib/features/backup/data/connectivity_service.dart` — additionally gains the top-level
  `classifyConnectivityResults(List<ConnectivityResult>)` (decision #3, moved forward from §1e so
  this fragment's file compiles).
- `test/app/app_test.dart` — **four** containers get the `connectivityServiceProvider` override,
  not two (D-6).

Not touched by §1d but worth knowing: `test/widget_test.dart:73` also mounts `MasiApp` through a
plain `ProviderScope` with no `connectivityServiceProvider` override. It survives §1d (the probe is
only reached on a failed push, and that test never pushes) and survives §1e only because §1e's
native `statusChanges()` is gated behind a catchable `checkConnectivity()` plugin probe. That gate
is load-bearing — do not "simplify" it away.

## Interfaces produced / consumed

### Produced

- lib/features/backup/data/sync_remote.dart — `class TablePushOutcome` with `const TablePushOutcome.ok({required String table, required int rowsUpserted, int rowsSkippedNewerRemote = 0})`, `TablePushOutcome.failed({required String table, required int rowsFailed, required Object error})`, fields `final String table; final int rowsUpserted; final int rowsSkippedNewerRemote; final int rowsFailed; final String? error;`, getter `bool get ok => error == null;`
- lib/features/backup/data/sync_remote.dart — `Future<List<TablePushOutcome>> upsertOwnRows(String uid, Map<String, List<Map<String, dynamic>>> tablesToRows)` (was `Future<void>`) on `abstract class SyncRemote`
- lib/features/backup/data/sync_remote.dart — `({List<Map<String, dynamic>> valid, List<Map<String, dynamic>> invalid}) partitionSyncRows(Iterable<Map<String, dynamic>> rows, List<String> requiredFields, {required String debugLabel})`
- lib/features/backup/data/sync_remote.dart — `List<Map<String, dynamic>> filterValidSyncRows(Iterable<Map<String, dynamic>> rows, List<String> requiredFields, {required String debugLabel})` UNCHANGED signature/behaviour, now implemented as `partitionSyncRows(...).valid`
- lib/features/backup/data/sync_service.dart — `const PushSyncResult.pushed({required int rowsPushed, required int photosUploaded, int rowsFailed = 0, List<String> errors = const []})`; new fields `final int rowsFailed; final List<String> errors;`; new getter `bool get fullyLanded => didPush && rowsFailed == 0 && errors.isEmpty;`
- lib/features/backup/data/sync_service.dart — `SyncService({..., Map<String, List<String>>? pushRequiredFields})` (new last optional named param, defaults to `syncRequiredFields`)
- lib/features/backup/application/sync_orchestrator.dart — `const SyncOrchestratorState({SyncStatus status = SyncStatus.idle, DateTime? lastSyncedAt, String? lastPullError, String? lastPushError})`; new field `final String? lastPushError;` (included in `==`/`hashCode`/`toString`/`copyWith` passthrough)
- lib/features/backup/data/connectivity_service.dart — `Future<bool> isBackendReachable()` on `abstract class ConnectivityService`
- lib/features/backup/data/connectivity_service.dart — `SystemConnectivityService([Connectivity? connectivity, bool? isWeb, http.Client? httpClient])` (third positional param added); `@visibleForTesting static Uri get probeUri`; `@visibleForTesting static const Duration probeTimeout = Duration(seconds: 5);`
- test/features/backup/data/sync_service_test.dart — `class AllTablesFailingSyncRemote extends FakeSyncRemote`, `class ThrowingUpsertSyncRemote extends FakeSyncRemote`, `class OneTableFailingSyncRemote extends FakeSyncRemote` (public, so §1e/§1f can reuse them)
- test/features/backup/application/sync_orchestrator_test.dart — `class _FailingPushSyncRemote extends _CountingSyncRemote` with mutable `bool failPush`
- `lib/features/backup/data/connectivity_service.dart` — `NetworkStatus classifyConnectivityResults(List<ConnectivityResult> results)` (top-level; decision #3 assigns the extraction to §1e, but it must physically land here — see Task 6)
- the four merged `ConnectivityService` fakes, each carrying `isBackendReachable()` **and** §1e's
  `statusChanges()` (decisions #4/#5): `FakeConnectivityService` (`sync_service_test.dart:276`,
  `cloud_backup_service_test.dart:74`), `_FakeConnectivityService` (`sync_orchestrator_test.dart:143`,
  `app_test.dart:132`)

**Corrections applied to the produced list above:** `PushSyncResult.fullyLanded` ships here as
`didPush && rowsFailed == 0 && errors.isEmpty` and **§1f must amend it** with `&& photosFailed == 0`
(D-2). `ConnectivityService` gains exactly ONE member here — `isBackendReachable()`; §1e adds
`statusChanges()` to the same abstract class without re-declaring it (decision #1).

### Consumed

- `abstract class SyncRemote` / `upsertOwnRows` — lib/features/backup/data/sync_remote.dart:80, :86
- `shouldPushLww({required int localUpdatedAt, required int? remoteUpdatedAt})` — lib/features/backup/data/sync_remote.dart:233
- `hasRequiredSyncFields(Map<String, dynamic> row, List<String> requiredFields)` — lib/features/backup/data/sync_remote.dart:260
- `const Map<String, List<String>> syncRequiredFields` — lib/features/backup/data/sync_remote.dart:289
- `filterValidSyncRows(...)` — lib/features/backup/data/sync_remote.dart:317 (debugPrint skip at :327-331 = L5's only signal today)
- `const List<String> syncTableNames` — lib/features/backup/data/sync_remote.dart:34
- `SupabaseSyncRemote.upsertOwnRows` — lib/features/backup/data/sync_remote.dart:355 (try at :369, per-table catch at :394)
- `class PushSyncResult` / `PushSyncResult.pushed` — lib/features/backup/data/sync_service.dart:24, :25
- `SyncService.pushOwn()` — lib/features/backup/data/sync_service.dart:238 (guard block :277-336, `await _remote.upsertOwnRows` :338, rowsPushed fold :343-344)
- `SyncService._uploadOwnPhotos` `if (photos.isEmpty) return 0;` — lib/features/backup/data/sync_service.dart:369 (the S1 short-circuit) and the unguarded `listPhotoObjectPaths` at :371
- `PullResult.errors` (the shape to mirror) — lib/features/backup/data/sync_service.dart:142; per-section isolation pattern :455-597
- `enum SyncStatus` — lib/features/backup/application/sync_orchestrator.dart:14 (`offline` at :29)
- `class SyncOrchestratorState` / `copyWith` — lib/features/backup/application/sync_orchestrator.dart:36, :64
- `SyncOrchestrator._runPush` — lib/features/backup/application/sync_orchestrator.dart:204 (idle+stamp at :209-210, skippedNotWifi→offline at :213-214, catch at :216-219)
- `SyncOrchestrator._runPull` — lib/features/backup/application/sync_orchestrator.dart:292 (explicit-constructor state writes at :305-323, the pattern `_runPush` copies)
- `syncDebounceDurationProvider` — lib/features/backup/application/sync_orchestrator.dart:92
- `abstract class ConnectivityService` / `currentStatus()` — lib/features/backup/data/connectivity_service.dart:25, :26
- `SystemConnectivityService` + its `if (_isWeb) return NetworkStatus.wifi;` web short-circuit — lib/features/backup/data/connectivity_service.dart:30, :53
- `enum NetworkStatus` — lib/features/backup/data/connectivity_service.dart:7
- `connectivityServiceProvider` — lib/features/backup/application/backup_providers.dart:35 (currently overridden by NO test; becomes a primary override point)
- `syncServiceProvider` — lib/features/backup/application/sync_providers.dart:155
- `_UnavailableSyncRemote.upsertOwnRows` — lib/features/backup/application/sync_providers.dart:75
- `nowMsProvider` — lib/core/db/database_provider.dart:23
- `const String supabaseUrl` / `const String supabaseAnonKey` — lib/core/config/supabase_config.dart:25, :33
- `_syncStatusLabel(SyncOrchestratorState state)` — lib/features/account/presentation/account_screen.dart:895; the `Key('sync-status')` Text it feeds — :651-659
- `NominatimGeocodingService` (the injectable-`http.Client` + `.timeout(...)` + never-throws convention to copy) — lib/core/location/geocoding_service.dart:52-118
- `FakeSyncRemote` — test/features/backup/data/sync_service_test.dart:23 (`upsertOwnRows` :36, `_rows` :24, LWW mirror :47-56, ownerId `assert` :42-46)
- `ThrowingFetchSharedToposRemote` — test/features/backup/data/sync_service_test.dart:267
- `FakeConnectivityService` — test/features/backup/data/sync_service_test.dart:276
- `FakeAuthRepository`, `_signedInU1`, `_uidU1`, `_signedOut` — test/features/backup/data/sync_service_test.dart:287, :312, :310, :309
- `makeContainer({required SyncRemote remote, required AuthRepository auth, ConnectivityService? connectivity, bool Function()? wifiOnly})` — test/features/backup/data/sync_service_test.dart:333
- `writeFile(Directory dir, String name, [int fill])` — test/features/backup/data/sync_service_test.dart:355
- `seedWallHierarchy(AppDatabase db, {...})` — test/features/backup/data/sync_service_test.dart:364
- existing `rowsPushed` assertions that must stay green — test/features/backup/data/sync_service_test.dart:473 (`6`), :1171 (`8`)
- `_CountingSyncRemote` — test/features/backup/application/sync_orchestrator_test.dart:26 (`upsertOwnRows` :31, `pushCallCount` :27)
- `_ThrowingSharedToposSyncRemote` — test/features/backup/application/sync_orchestrator_test.dart:110
- `_FakeConnectivityService` — test/features/backup/application/sync_orchestrator_test.dart:143
- `primeOrchestrator(ProviderContainer container)` — test/features/backup/application/sync_orchestrator_test.dart:163
- `makeContainer({required AppDatabase db, required SyncRemote remote, required AuthRepository syncServiceAuth, ...})` — test/features/backup/application/sync_orchestrator_test.dart:175
- `insertArea(AppDatabase db, String id, {String? ownerId})` — test/features/backup/application/sync_orchestrator_test.dart:209
- the inline container in the `status transitions` group — test/features/backup/application/sync_orchestrator_test.dart:689-711
- `_CountingSyncRemote` / `_FakeConnectivityService` — test/app/app_test.dart:30, :132; the two `SyncService(...)` overrides at :421-431 and :506-516
- `FakeConnectivityService` — test/features/backup/data/cloud_backup_service_test.dart:74
- `_FixedSyncOrchestrator` — test/features/account/presentation/account_screen_test.dart:28; `_wrap` :142; the `E1d: sync-status line` group + its `makeContainer` :692, :693
- `_FakeHttpClient extends BaseClient` (the fake-client shape to mirror) — test/core/location/geocoding_service_test.dart:13-29

Line-number corrections to the consumed list: `nowMsProvider` is `lib/core/db/database_provider.dart:24`
(not `:23`); `filterValidSyncRows`'s skip `debugPrint` is `sync_remote.dart:327-330` (not `:327-331`);
the two "#57" `SyncService(...)` overrides in `app_test.dart` are `:421-431` and `:505-515` (not
`:506-516`); the `E1d: sync-status line` group runs `:692-787`.

## Conventions

Riverpod **v3** only: `Notifier`/`NotifierProvider` (`SyncOrchestrator extends Notifier<SyncOrchestratorState>` + `final syncOrchestratorProvider = NotifierProvider<SyncOrchestrator, SyncOrchestratorState>(SyncOrchestrator.new);`, sync_orchestrator.dart:123/:330; `class WifiOnlySetting extends Notifier<bool>`, backup_providers.dart:42). NEVER `StateProvider`. Plain seams stay `Provider<T>` (`connectivityServiceProvider`, backup_providers.dart:35).

No `dart:io` may enter `lib/` outside `*_native.dart` — the gate `grep -r "dart:io" lib --include="*.dart" | grep -v _native.dart` must stay empty. This workstream adds only `package:http/http.dart` (already a direct dep, pubspec.yaml `http: ^1.6.0`, declared precisely so `lib/` code can use it) which is web/wasm-safe. No conditional-import seam is needed here: the probe is identical on native and web — that is the point of S4 (`kIsWeb`/`_isWeb` must NOT gate it).

Injectable-collaborator style for testability, copied verbatim from `NominatimGeocodingService` (lib/core/location/geocoding_service.dart:52-56): an optional `http.Client? client` constructor param defaulting to a real one, a `static const _timeout`, `await client.get(uri, headers: ...).timeout(_timeout)`, and a `catch (_)` that returns the safe default instead of throwing ("best-effort, never throws"). `SystemConnectivityService`'s existing test seam is *positional* optionals (`SystemConnectivityService([Connectivity? connectivity, bool? isWeb])`, :31) — extend it positionally; Dart forbids mixing optional-positional and named params.

`@visibleForTesting` for test-only accessors, as `NominatimGeocodingService.debugClient` (geocoding_service.dart:63-64) and `isNotApprovedAuthError` (account_screen.dart:865) do.

Result objects are hand-written immutable classes with named constructors per outcome and a doc comment on every field — copy `PullResult` (sync_service.dart:79-152) exactly: one `const X.pulled({...})` per success shape, one per skip shape with all fields initialised in the initialiser list, an `outcome` enum field, a `bool get didPull`, and a `toString()`. `errors` is `List<String>` of human-readable messages each embedding the caught error's `toString()` (`errors.add('own rows fetch failed: $e')`, sync_service.dart:469). `@immutable` comes from `package:flutter/foundation.dart` (already imported by both sync_remote.dart and sync_orchestrator.dart).

Per-section/per-table isolation is a load-bearing invariant, not a nicety: one failing unit must never abort the others (sync_remote.dart:363-368 comment; sync_service.dart:429-441). §1d keeps every existing isolation boundary and only makes it *report*.

Records are the repo's idiom for multi-value returns (`({AppDatabase db, Directory docsDir, Directory srcDir, SyncService service})`, sync_service_test.dart:333) — use one for `partitionSyncRows`.

Every behavioural change carries an inline comment naming the bug it fixes, in the existing house style: `// P0 fix (#72, "fresh install syncs nothing after login"): ...`, `// S1 fix (§1d): ...`. Tests state the pre-fix behaviour in their name or `reason:` (`reason: 'the shared-topos failure must be reported, not swallowed silently'`, sync_service_test.dart:1845).

Test doubles are file-private (`_`-prefixed) unless another test file must reuse them; duplicating a double across test files is the *stated* convention, not a smell (app_test.dart:26-29, :128-131). Reuse the existing names exactly: `FakeSyncRemote`/`FakeConnectivityService`/`FakeAuthRepository`/`makeContainer`/`seedWallHierarchy`/`writeFile` (sync_service_test.dart), `_CountingSyncRemote`/`_FakeConnectivityService`/`_FakeAuthRepository`/`primeOrchestrator`/`insertArea`/`makeContainer` (sync_orchestrator_test.dart), `_FixedSyncOrchestrator`/`_wrap` (account_screen_test.dart), `_FakeHttpClient extends BaseClient` (geocoding_service_test.dart:13).

Orchestrator tests must keep the provider actively listened — always `primeOrchestrator(container)` then `await Future<void>.delayed(const Duration(milliseconds: 5));`, never a bare `container.read(syncOrchestratorProvider)` (sync_orchestrator.dart:104-115 explains why). Time is seamed via `syncDebounceDurationProvider` and `nowMsProvider` — never real long delays; the short `Future.delayed` waits in that file are real-time waits on a millisecond-scale debounce and are the established pattern there.

Widget tests must never drive a real image-codec decode; the tests in this workstream touch only text labels via `_FixedSyncOrchestrator`, so no `imageSize`/`TopoCanvasBody` harness is involved.

Commits: `type(scope): summary`, one logical change each, straight to `main`, trailer `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`. Never push.

**Corrections to the above.**

- The paragraph on `SystemConnectivityService`'s positional seam stands, and reconciliation
  decision #2 makes the 3-positional form `([Connectivity? connectivity, bool? isWeb, http.Client? httpClient])`
  binding on §1e too — §1e inherits the third param untouched. Recorded as debt: a fourth seam
  should convert the whole constructor to named params.
- Test doubles: the four `ConnectivityService` fakes are the one place where the "duplicate rather
  than share" convention meets a two-fragment signature change. They are rewritten **once**, here,
  as the union with §1e's members (decisions #4/#5) — §1e T7 must not rewrite them a second time.
- `@override` is deliberately **omitted** from the fakes' `statusChanges()` until §1e T7 declares
  the abstract member; annotating a non-overriding member is an analyzer error, and this fragment's
  gate is `flutter analyze` = 0 issues.
- Test-count assertions: per the master plan's Global Constraints and reconciliation D-13, assert
  **"baseline + N for this task"** and gate on `flutter test` being green. The live baseline at the
  start of §1d is **1586** (§1b tasks 1–2 have landed), not the 1576 the raw fragment assumed.

---

## Signature blast radius

*Copied from `reconciliation.md` § "Signature blast radius" — these are §1d's rows. This fragment
owns the `upsertOwnRows` signature change and every double that must move with it.*

`1d T2` changes `SyncRemote.upsertOwnRows` from `Future<void>` to `Future<List<TablePushOutcome>>`.
Grepped, not guessed.

**Declarations/overrides that MUST move in the same commit (6):**

| File:line | Symbol | Absorbed by |
|---|---|---|
| `lib/features/backup/data/sync_remote.dart:86` | `abstract class SyncRemote` | 1d T2 |
| `lib/features/backup/data/sync_remote.dart:355` | `SupabaseSyncRemote` | 1d T2 |
| `lib/features/backup/application/sync_providers.dart:75` | `_UnavailableSyncRemote` (`=> _unavailable()` returns `Never`, assignable) | 1d T2 |
| `test/features/backup/data/sync_service_test.dart:36` | `FakeSyncRemote` | 1d T2 |
| `test/features/backup/application/sync_orchestrator_test.dart:31` | `_CountingSyncRemote` | 1d T2 |
| `test/app/app_test.dart:34` | `_CountingSyncRemote` (duplicate class, same name) | 1d T2 |

**Subclasses that inherit and need NO change (2):** `ThrowingFetchSharedToposRemote`
(`sync_service_test.dart:267`, overrides `fetchSharedTopos` only), `_ThrowingSharedToposSyncRemote`
(`sync_orchestrator_test.dart:110`, same).

**Call sites that still compile unchanged (3):** `sync_service.dart:338` (`await`),
`sync_service_test.dart:1214` (`expect(() => remote.upsertOwnRows(...), throwsA(isA<AssertionError>()))`
— the ownerId `assert` must stay outside any try/catch so this keeps passing),
`sync_service_test.dart:1827` (`await`).

**Doubles authored by *later* fragments that must be written against the NEW type (5):**

- 1d's own `AllTablesFailingSyncRemote`, `ThrowingUpsertSyncRemote`, `OneTableFailingSyncRemote`
  (T3) — already correct.
- 1d's `_FailingPushSyncRemote` (T5) — already correct.
- **1e T4 `_MidPushWriteRemote`** — declares `Future<void>`, calls `super.upsertOwnRows(...)`. Must
  become `Future<List<TablePushOutcome>>` and `return await super.upsertOwnRows(...)`. **Broken as
  written.**
- **1e T4 `_ThrowingUpsertRemote`** — declares `Future<void>`. **Delete; use 1d's
  `ThrowingUpsertSyncRemote`.**
- **1e T6 `_OfflineToggleSyncRemote`** — declares `Future<void>`. Must return outcomes (e.g.
  `[for (…) TablePushOutcome.ok(…)]` when online).
- 1f T8/T10 `FailingUploadSyncRemote`, `_SinglePageListingRemote` override
  `uploadPhoto`/`listPhotoObjectPaths` only — unaffected.

**Second signature change, separate radius:** `ConnectivityService` gains **two** members (1d
`isBackendReachable`, 1e `statusChanges`). All four fakes use `implements`, so a concrete default on
the abstract class would not help — every fake needs both members. The four files are
`sync_orchestrator_test.dart:143`, `sync_service_test.dart:276`, `cloud_backup_service_test.dart:74`,
`app_test.dart:132`. 1d T6 absorbs the first member's churn across all four; 1e T7 absorbs the
second's. *(Correction applied here: 1d T6 writes both members' bodies in one merged rewrite per
decisions #4/#5 — 1e T7 is left with only the abstract declaration and the `@override` annotations.)*

**Third, trivial:** `openConnection()` — one production caller (`database_provider.dart:17`), zero
test callers. 1a T2 absorbs it — not this fragment's concern.

---

## Ordering

**§1d runs in full, strictly serial, as Phase 2. Nothing else may touch
`lib/features/backup/**` or `test/app/app_test.dart` during it.** Phase 1 (§1a, §1b, §1f-photo,
plus the orphan tasks 1e T1 and 1e T5) must be complete; Phase 3 (§1e) and Phase 4 (§1f-sync) start
only after all eight tasks here have landed and been independently verified.

Hard sequential constraints from `reconciliation.md` § "Execution order" that involve §1d:

- `sync_remote.dart`: **1d T1 → 1d T2** → 1e T2 → 1f T7
- `sync_service.dart`: **1d T3 → 1d T4** → 1e T4 → 1f T8 → 1f T9
- `sync_orchestrator.dart`: **1d T5 → 1d T7** → 1e T6 → 1e T8
- `connectivity_service.dart`: **1d T6** → 1e T7
- `test/app/app_test.dart`: **1d T2 → 1d T6 → 1d T7** → 1e T7 → 1e T9
- `test/features/backup/data/sync_service_test.dart`: **1d T2 → 1d T3 → 1d T4 → 1d T6** → 1e T2 → 1e T4 → 1e T7 → 1f T8 → 1f T9 → 1f T10
- `test/features/backup/application/sync_orchestrator_test.dart`: **1d T2 → 1d T5 → 1d T6 → 1d T7** → 1e T6 → 1e T7 → 1e T8 → 1e T10
- `test/features/backup/data/{connectivity_service,cloud_backup_service}_test.dart`: **1d T6** → 1e T7

Intra-fragment order is forced and total: **T1 → T2 → T3 → T4 → T5 → T6 → T7 → T8.** T2 needs T1's
`TablePushOutcome`; T3 needs T2's signature; T4 needs T3's `errors`/`rowsFailed` declarations (D-11
— T3 now places them where T4 uses them, so the two are still ordered but no longer conflicting);
T5 needs T3's `fullyLanded`; T7 needs T5's `_runPush` shape and T6's `isBackendReachable`; T8 needs
T5's `lastPushError`.

Never parallel with §1e or §1f-sync. §1d is file-disjoint from §1a and §1b (reconciliation's
parallel-safe table), but Phase 2 is defined as serial anyway.

**Per-task verify gate** (master plan): the implementer runs its steps, `flutter analyze`,
`flutter test`, then commits; a **separate clean-context verifier** receives only that task's
`**Assertions:**` block, `git show` of the commit, and the Global Constraints, and re-runs the
assertions adversarially. The verifier is read-only on `lib/` and must not build or install.

---

## Tasks

### Task 1: `partitionSyncRows` + `TablePushOutcome` (pure additions, no signature change yet)

**Files:** Create: `test/features/backup/data/sync_remote_test.dart` · Modify: `lib/features/backup/data/sync_remote.dart:312-334` · Test: `test/features/backup/data/sync_remote_test.dart`

**Interfaces:** **Consumes** `hasRequiredSyncFields` (`sync_remote.dart:260`), `syncTableNames` (`:34`), `shouldPushLww` (`:233`, doc reference), `filterValidSyncRows`'s existing doc + `debugPrint` text (`:312-334`), `@immutable` + `debugPrint` from `package:flutter/foundation.dart` (already imported by `sync_remote.dart`). **Produces** `TablePushOutcome` (`.ok` const ctor, `.failed`, `ok` getter, `toString`); `partitionSyncRows(...)` returning `({List<Map<String, dynamic>> valid, List<Map<String, dynamic>> invalid})`; `filterValidSyncRows` with an unchanged signature/doc/log text, now a one-line delegation.

- [ ] **Step 1: Create the new (first-ever) test file for `sync_remote.dart`'s pure helpers.**

  ```dart
  // test/features/backup/data/sync_remote_test.dart
  import 'package:masi/features/backup/data/sync_remote.dart';
  import 'package:flutter_test/flutter_test.dart';

  void main() {
    group('partitionSyncRows', () {
      test(
        'splits rows into valid + invalid by required-field presence, keeping '
        'every valid row and reporting every dropped one (L5: the push side '
        'needs to KNOW what it excluded, not just log it)',
        () {
          final rows = <Map<String, dynamic>>[
            {'id': 'a1', 'createdAt': 1, 'updatedAt': 2, 'name': 'Good'},
            {'id': 'a2', 'createdAt': 1, 'updatedAt': 2, 'name': null},
            {'id': null, 'createdAt': 1, 'updatedAt': 2, 'name': 'No id'},
            {'createdAt': 1, 'updatedAt': 2, 'name': 'Missing the id key'},
          ];

          final split = partitionSyncRows(
            rows,
            const ['id', 'createdAt', 'updatedAt', 'name'],
            debugLabel: 'local areas (push)',
          );

          expect(split.valid.map((r) => r['id']), ['a1']);
          expect(split.invalid, hasLength(3));
          expect(split.invalid.map((r) => r['id']), ['a2', null, null]);
        },
      );

      test('every row valid -> invalid is empty', () {
        final split = partitionSyncRows(
          <Map<String, dynamic>>[
            {'id': 'a1', 'createdAt': 1, 'updatedAt': 2},
            {'id': 'a2', 'createdAt': 1, 'updatedAt': 2},
          ],
          const ['id', 'createdAt', 'updatedAt'],
          debugLabel: 'local areas (push)',
        );

        expect(split.valid, hasLength(2));
        expect(split.invalid, isEmpty);
      });

      test(
        'filterValidSyncRows returns exactly partitionSyncRows(...).valid — the '
        'existing fetch-side callers must be behaviourally untouched',
        () {
          final rows = <Map<String, dynamic>>[
            {'id': 'ok', 'createdAt': 1, 'updatedAt': 1},
            {'id': null, 'createdAt': 1, 'updatedAt': 1},
          ];
          const required = ['id', 'createdAt', 'updatedAt'];

          expect(
            filterValidSyncRows(rows, required, debugLabel: 'own areas')
                .map((r) => r['id']),
            partitionSyncRows(rows, required, debugLabel: 'own areas')
                .valid
                .map((r) => r['id']),
          );
        },
      );
    });

    group('TablePushOutcome', () {
      test('ok carries the upserted/skipped counts and reports no error', () {
        const outcome = TablePushOutcome.ok(
          table: 'areas',
          rowsUpserted: 3,
          rowsSkippedNewerRemote: 1,
        );

        expect(outcome.ok, isTrue);
        expect(outcome.error, isNull);
        expect(outcome.table, 'areas');
        expect(outcome.rowsUpserted, 3);
        expect(outcome.rowsSkippedNewerRemote, 1);
        expect(outcome.rowsFailed, 0);
      });

      test('failed carries the unsynced row count and a stringified error', () {
        final outcome = TablePushOutcome.failed(
          table: 'photos',
          rowsFailed: 4,
          error: Exception('network down'),
        );

        expect(outcome.ok, isFalse);
        expect(outcome.error, contains('network down'));
        expect(outcome.table, 'photos');
        expect(outcome.rowsUpserted, 0);
        expect(outcome.rowsSkippedNewerRemote, 0);
        expect(outcome.rowsFailed, 4);
      });
    });
  }
  ```

- [ ] **Step 2: Run the new test file and watch it FAIL to compile (neither `partitionSyncRows` nor `TablePushOutcome` exists yet).**

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/backup/data/sync_remote_test.dart
  ```

  Expected: Compile error: Undefined name 'partitionSyncRows' / 'TablePushOutcome' isn't a type.

- [ ] **Step 3: In lib/features/backup/data/sync_remote.dart, insert `TablePushOutcome` immediately BEFORE `abstract class SyncRemote` (i.e. before line 80), so `upsertOwnRows`'s doc can reference it.**

  ```dart
  /// Outcome of pushing ONE table's rows within a single
  /// [SyncRemote.upsertOwnRows] call.
  ///
  /// S1 fix (§1d, web-offline reliability): `upsertOwnRows` used to return
  /// `void` and swallow every per-table failure behind a [debugPrint], so
  /// `SyncService.pushOwn` counted rows merely HANDED TO the remote as
  /// "pushed" — a push where every single table's round trip failed still
  /// surfaced as "Synced • just now" on the Account screen. Every attempted
  /// table now reports back, success or failure, so the push result can tell
  /// the truth.
  @immutable
  class TablePushOutcome {
    /// The table landed: [rowsUpserted] rows were written remotely and
    /// [rowsSkippedNewerRemote] were deliberately not sent because the cloud
    /// already holds a strictly newer copy (see [shouldPushLww]) — which is a
    /// SUCCESS, not a failure: there is nothing left to push for them.
    const TablePushOutcome.ok({
      required this.table,
      required this.rowsUpserted,
      this.rowsSkippedNewerRemote = 0,
    }) : rowsFailed = 0,
         error = null;

    /// The table did NOT land: [rowsFailed] rows are still only local and
    /// [error] (stringified, so this type stays free of any backend type)
    /// says why.
    TablePushOutcome.failed({
      required this.table,
      required this.rowsFailed,
      required Object error,
    }) : rowsUpserted = 0,
         rowsSkippedNewerRemote = 0,
         error = '$error';

    /// Table name, one of [syncTableNames].
    final String table;

    /// Rows this call actually upserted remotely.
    final int rowsUpserted;

    /// Rows the last-writer-wins pre-check dropped because the cloud row is
    /// strictly newer — counted separately from [rowsUpserted] so a caller can
    /// tell "nothing needed sending" apart from "nothing was sent".
    final int rowsSkippedNewerRemote;

    /// Rows handed in that did not reach the cloud. 0 on success.
    final int rowsFailed;

    /// `null` iff this table landed.
    final String? error;

    bool get ok => error == null;

    @override
    String toString() => ok
        ? 'TablePushOutcome.ok($table, rowsUpserted: $rowsUpserted, '
              'rowsSkippedNewerRemote: $rowsSkippedNewerRemote)'
        : 'TablePushOutcome.failed($table, rowsFailed: $rowsFailed, '
              'error: $error)';
  }
  ```

- [ ] **Step 4: Replace the body of `filterValidSyncRows` (currently sync_remote.dart:317-334) with `partitionSyncRows` + a one-line delegation, keeping `filterValidSyncRows`'s doc comment (:312-316) and its exact debugPrint text unchanged.**

  ```dart
  /// [filterValidSyncRows]'s reporting counterpart: splits [rows] into those
  /// satisfying [hasRequiredSyncFields] for [requiredFields] (`valid`) and
  /// those that don't (`invalid`), logging each dropped row exactly the same
  /// way [filterValidSyncRows] does.
  ///
  /// L5 fix (§1d): the PUSH side needs to know WHICH rows it excluded so they
  /// can surface in `PushSyncResult.rowsFailed`/`PushSyncResult.errors`. With
  /// no outbox, an excluded row used to be dropped from this and every future
  /// push with nothing but a [debugPrint] to show for it — "excluded once"
  /// meant "excluded forever", invisibly.
  ({List<Map<String, dynamic>> valid, List<Map<String, dynamic>> invalid})
  partitionSyncRows(
    Iterable<Map<String, dynamic>> rows,
    List<String> requiredFields, {
    required String debugLabel,
  }) {
    final valid = <Map<String, dynamic>>[];
    final invalid = <Map<String, dynamic>>[];
    for (final row in rows) {
      if (hasRequiredSyncFields(row, requiredFields)) {
        valid.add(row);
      } else {
        invalid.add(row);
        debugPrint(
          'SyncRemote: skipping malformed $debugLabel row (missing one of '
          '$requiredFields as a non-null value): $row',
        );
      }
    }
    return (valid: valid, invalid: invalid);
  }

  List<Map<String, dynamic>> filterValidSyncRows(
    Iterable<Map<String, dynamic>> rows,
    List<String> requiredFields, {
    required String debugLabel,
  }) => partitionSyncRows(rows, requiredFields, debugLabel: debugLabel).valid;
  ```

- [ ] **Step 5: Re-run the new test file and see it pass.**

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/backup/data/sync_remote_test.dart
  ```

  Expected: `All tests passed!` (**5** tests — see the corrected assertion below.)

- [ ] **Step 6: Confirm the whole project still analyses clean and the full suite is green (filterValidSyncRows has fetch-side callers in sync_remote.dart and sync_service.dart).**

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter analyze && flutter test
  ```

  Expected: `No issues found!` and `flutter test` green at **baseline + 5** (this task adds 5 tests, not the 7 the raw fragment claimed — see the note under Task 1's assertions).

**Assertions:**

- [ ] `flutter test test/features/backup/data/sync_remote_test.dart` is green and contains **5** tests (3 in `partitionSyncRows` + 2 in `TablePushOutcome`). The raw fragment asserted 7; counted against its own code block that is wrong, and it is written as a gate assertion.
- [ ] `partitionSyncRows` returns a record with named fields `valid`/`invalid`; the `invalid` list contains the rows `hasRequiredSyncFields` rejects, in input order.
- [ ] `filterValidSyncRows`'s signature, doc, and debugPrint text are byte-identical to before; its body is a single delegation to `partitionSyncRows(...).valid`.
- [ ] `TablePushOutcome.ok` is a `const` constructor; `TablePushOutcome.failed` accepts `Object error` and stores it stringified; `ok` is `error == null`.
- [ ] `flutter analyze` = 0 issues; `flutter test` green at **baseline + 5 for this task** (D-13: never assert an absolute total).
- [ ] No elision, placeholder or `// ... unchanged ...` comment appears in any file this task writes.

**Commit:** `feat(sync): add partitionSyncRows + TablePushOutcome for reportable pushes`

> Every commit ends with the trailer `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

---

### Task 2: `upsertOwnRows` returns `List<TablePushOutcome>` (abstract-class change: real impl, unavailable fallback, and all three test fakes move together)

**Files:** Create: — · Modify: `lib/features/backup/data/sync_remote.dart:80-90`, `lib/features/backup/data/sync_remote.dart:354-402`, `lib/features/backup/application/sync_providers.dart:74-78`, `test/features/backup/data/sync_service_test.dart:35-60`, `test/features/backup/application/sync_orchestrator_test.dart:30-36`, `test/app/app_test.dart:33-37` · Test: `test/features/backup/data/sync_service_test.dart`

**Interfaces:** **Consumes** `TablePushOutcome` (T1), `syncTableNames`, `shouldPushLww`, `SupabaseSyncRemote._client`, `FakeSyncRemote._rows` (`sync_service_test.dart:24`) and its ownerId `assert` (`:42-46`), `_CountingSyncRemote.pushCallCount`. **Produces** `Future<List<TablePushOutcome>> upsertOwnRows(String, Map<String, List<Map<String, dynamic>>>)` on all six declarations/overrides listed in *Signature blast radius*.

- [ ] **Step 1: Add two failing tests at the END of the existing `group('pushOwn', ...)` in test/features/backup/data/sync_service_test.dart (after the test that closes at :763, before that group's `});` at :764) pinning the new fake contract.**

  ```dart
      test(
        'S1: upsertOwnRows reports ONE ok outcome per non-empty table — it can '
        'no longer return void and swallow what actually happened',
        () async {
          final remote = FakeSyncRemote();

          final outcomes = await remote.upsertOwnRows(_uidU1, {
            'areas': [
              {
                'id': 'area-1',
                'createdAt': 100,
                'updatedAt': 100,
                'deletedAt': null,
                'remoteId': null,
                'dirty': false,
                'ownerId': _uidU1,
                'name': 'Area 1',
              },
            ],
            'sectors': const <Map<String, dynamic>>[],
          });

          expect(
            outcomes,
            hasLength(1),
            reason: 'an empty table is not attempted, so it is not reported',
          );
          expect(outcomes.single.table, 'areas');
          expect(outcomes.single.ok, isTrue);
          expect(outcomes.single.rowsUpserted, 1);
          expect(outcomes.single.rowsSkippedNewerRemote, 0);
          expect(outcomes.single.rowsFailed, 0);
        },
      );

      test(
        'a row the client-side LWW pre-check drops is reported as '
        'rowsSkippedNewerRemote, NOT as a failure — the cloud already holds a '
        'strictly newer copy, so there is nothing left to push for it',
        () async {
          final remote = FakeSyncRemote();
          Map<String, dynamic> areaRow(int updatedAt, String name) => {
            'id': 'area-1',
            'createdAt': 100,
            'updatedAt': updatedAt,
            'deletedAt': null,
            'remoteId': null,
            'dirty': false,
            'ownerId': _uidU1,
            'name': name,
          };

          await remote.upsertOwnRows(_uidU1, {
            'areas': [areaRow(500, 'Cloud (newer)')],
          });
          final outcomes = await remote.upsertOwnRows(_uidU1, {
            'areas': [areaRow(100, 'Local (stale)')],
          });

          expect(outcomes.single.ok, isTrue);
          expect(outcomes.single.rowsUpserted, 0);
          expect(outcomes.single.rowsSkippedNewerRemote, 1);
        },
      );
  ```

- [ ] **Step 2: Run the file and watch it FAIL to compile (`upsertOwnRows` still returns `Future<void>`, so `outcomes.single` does not resolve).**

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/backup/data/sync_service_test.dart
  ```

  Expected: Compile error: 'void' can't be assigned / The getter 'single' isn't defined for the type 'void'.

- [ ] **Step 3: Change the abstract declaration in lib/features/backup/data/sync_remote.dart (replace lines 81-89, keeping the existing doc paragraph and appending the new contract paragraphs).**

  ```dart
    /// Upserts every row in [tablesToRows] (keyed by table name, see
    /// [syncTableNames]) as belonging to [uid], INCLUDING soft-deleted
    /// tombstones (`deletedAt` set) — a tombstone must propagate to other
    /// devices the same as any other row change. Idempotent: re-upserting the
    /// same rows is a no-op change-wise.
    ///
    /// Returns ONE [TablePushOutcome] per table it actually ATTEMPTED — a
    /// table absent from [tablesToRows], or present but empty, is not
    /// attempted and therefore not reported. Real implementations report in
    /// [syncTableNames] (FK-dependency) order.
    ///
    /// S1 fix (§1d): implementations MUST NOT swallow a per-table failure. A
    /// table whose round trip errors comes back as [TablePushOutcome.failed]
    /// so `SyncService.pushOwn` can report `rowsFailed`/`errors` instead of
    /// pretending every handed-in row landed. Per-table isolation is
    /// unchanged and still required: one failing table must not prevent the
    /// remaining tables (nor `pushOwn`'s later photo-upload phase) from
    /// running — so implementations report a single table's failure rather
    /// than throwing. (`pushOwn` additionally defends against a whole-call
    /// throw, e.g. the remote being wholly unreachable.)
    Future<List<TablePushOutcome>> upsertOwnRows(
      String uid,
      Map<String, List<Map<String, dynamic>>> tablesToRows,
    );
  ```

- [ ] **Step 4: Rewrite `SupabaseSyncRemote.upsertOwnRows` (lib/features/backup/data/sync_remote.dart:354-402) to collect and return outcomes.**

  ```dart
    @override
    Future<List<TablePushOutcome>> upsertOwnRows(
      String uid,
      Map<String, List<Map<String, dynamic>>> tablesToRows,
    ) async {
      final outcomes = <TablePushOutcome>[];
      for (final tableName in syncTableNames) {
        final rows = tablesToRows[tableName];
        if (rows == null || rows.isEmpty) continue;

        // Per-table push isolation (sync-resilience hardening): a rejected/
        // erroring table (bad data, a transient network blip on that one round
        // trip, a real backend constraint violation, ...) must not abort the
        // whole loop — every LATER table (and, upstream, `SyncService.pushOwn`'s
        // subsequent photo-upload phase) still needs to run regardless of one
        // earlier table's failure.
        //
        // S1 fix (§1d): the failure is now REPORTED to the caller as well as
        // logged. It used to be a bare `debugPrint` + `continue` under a
        // `Future<void>` return, which is what let a totally-failed offline
        // push read as "Synced • just now".
        try {
          // Client-side last-writer-wins guard on push (#2): fetch the remote's
          // current id+updatedAt for exactly the ids about to be pushed (one
          // batched round trip per table, not one per row), and drop any row a
          // strictly-newer remote row would otherwise get clobbered by. See
          // [shouldPushLww].
          final ids = [for (final row in rows) row['id'] as String];
          final remoteRows = await _client.from(tableName).select('id, updatedAt').inFilter('id', ids);
          final remoteUpdatedAt = <String, int>{
            for (final r in remoteRows) r['id'] as String: r['updatedAt'] as int,
          };
          final survivors = [
            for (final row in rows)
              if (shouldPushLww(
                localUpdatedAt: row['updatedAt'] as int,
                remoteUpdatedAt: remoteUpdatedAt[row['id']],
              ))
                row,
          ];
          final skipped = rows.length - survivors.length;
          if (survivors.isEmpty) {
            outcomes.add(
              TablePushOutcome.ok(
                table: tableName,
                rowsUpserted: 0,
                rowsSkippedNewerRemote: skipped,
              ),
            );
            continue;
          }

          // Confirmed live: the real Postgres tables (see `supabase/schema.sql`)
          // use matching camelCase quoted columns (`"ownerId"`, `"wallId"`, ...)
          // for drift's `toJson()` keys — no snake_case mapping layer needed.
          await _client.from(tableName).upsert(survivors);
          outcomes.add(
            TablePushOutcome.ok(
              table: tableName,
              rowsUpserted: survivors.length,
              rowsSkippedNewerRemote: skipped,
            ),
          );
        } catch (e) {
          debugPrint(
            'SyncRemote: upsertOwnRows failed for table "$tableName" '
            '(${rows.length} row(s)), reported to the caller — other tables '
            'still push: $e',
          );
          // Pessimistic on purpose: `rows.length`, not `survivors.length` —
          // the throw may have come from the LWW pre-check itself, before any
          // row was classified. Over-reporting unsynced work is safe;
          // under-reporting it is exactly the S1 bug.
          outcomes.add(
            TablePushOutcome.failed(
              table: tableName,
              rowsFailed: rows.length,
              error: e,
            ),
          );
        }
      }
      return outcomes;
    }
  ```

- [ ] **Step 5: Update the unavailable fallback in lib/features/backup/application/sync_providers.dart (replace lines 74-78).**

  ```dart
    @override
    Future<List<TablePushOutcome>> upsertOwnRows(
      String uid,
      Map<String, List<Map<String, dynamic>>> tablesToRows,
    ) => _unavailable();
  ```

- [ ] **Step 6: Rewrite `FakeSyncRemote.upsertOwnRows` in test/features/backup/data/sync_service_test.dart (replace lines 35-60), keeping the ownerId `assert` OUTSIDE any try/catch so the C1b test at :1213-1231 still sees an `AssertionError`.**

  ```dart
    @override
    Future<List<TablePushOutcome>> upsertOwnRows(
      String uid,
      Map<String, List<Map<String, dynamic>>> tablesToRows,
    ) async {
      final outcomes = <TablePushOutcome>[];
      for (final tableName in syncTableNames) {
        final rows = tablesToRows[tableName];
        if (rows == null || rows.isEmpty) continue;
        var upserted = 0;
        var skipped = 0;
        for (final row in rows) {
          assert(
            row['ownerId'] == uid,
            'upsertOwnRows($uid): row ${row['id']} in $tableName has ownerId '
            '${row['ownerId']}',
          );
          // Client-side LWW guard on push (#2), mirroring
          // SupabaseSyncRemote.upsertOwnRows: drop the row if a cloud row
          // already exists here with a strictly newer updatedAt.
          final remote = _rows[tableName]![row['id'] as String];
          if (!shouldPushLww(
            localUpdatedAt: row['updatedAt'] as int,
            remoteUpdatedAt: remote?['updatedAt'] as int?,
          )) {
            skipped++;
            continue;
          }
          _rows[tableName]![row['id'] as String] = Map<String, dynamic>.from(row);
          upserted++;
        }
        // Mirrors SupabaseSyncRemote's contract (§1d): one outcome per
        // ATTEMPTED table, LWW-skips counted as a success.
        outcomes.add(
          TablePushOutcome.ok(
            table: tableName,
            rowsUpserted: upserted,
            rowsSkippedNewerRemote: skipped,
          ),
        );
      }
      return outcomes;
    }
  ```

- [ ] **Step 7: Update `_CountingSyncRemote.upsertOwnRows` in test/features/backup/application/sync_orchestrator_test.dart (replace lines 30-36).**

  ```dart
    @override
    Future<List<TablePushOutcome>> upsertOwnRows(
      String uid,
      Map<String, List<Map<String, dynamic>>> tablesToRows,
    ) async {
      pushCallCount++;
      // A clean, fully-landed push: one ok outcome per non-empty table, the
      // shape `SupabaseSyncRemote` returns when every round trip succeeds.
      return [
        for (final entry in tablesToRows.entries)
          if (entry.value.isNotEmpty)
            TablePushOutcome.ok(table: entry.key, rowsUpserted: entry.value.length),
      ];
    }
  ```

- [ ] **Step 8: Update `_CountingSyncRemote.upsertOwnRows` in test/app/app_test.dart (replace lines 33-37).**

  ```dart
    @override
    Future<List<TablePushOutcome>> upsertOwnRows(
      String uid,
      Map<String, List<Map<String, dynamic>>> tablesToRows,
    ) async => [
      for (final entry in tablesToRows.entries)
        if (entry.value.isNotEmpty)
          TablePushOutcome.ok(table: entry.key, rowsUpserted: entry.value.length),
    ];
  ```

- [ ] **Step 9: Run the three touched test files and see them pass.**

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/backup/data/sync_service_test.dart test/features/backup/application/sync_orchestrator_test.dart test/app/app_test.dart
  ```

  Expected: All tests passed! — including the pre-existing `rowsPushed == 6` (:473) and `rowsPushed == 8` (:1171) assertions, which still hold because `pushOwn` has not changed yet.

- [ ] **Step 10: Confirm the whole project analyses clean and the full suite is green.**

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter analyze && flutter test
  ```

  Expected: `No issues found!` and `flutter test` green at **baseline + 2** for this task.

**Assertions:**

- [ ] `grep -rn "Future<void> upsertOwnRows" lib test` returns nothing — every declaration and override now returns `Future<List<TablePushOutcome>>`.
- [ ] All five implementations moved together: `SyncRemote` (abstract), `SupabaseSyncRemote`, `_UnavailableSyncRemote` (sync_providers.dart), `FakeSyncRemote` (sync_service_test.dart), `_CountingSyncRemote` (sync_orchestrator_test.dart AND app_test.dart).
- [ ] `FakeSyncRemote.upsertOwnRows` returns exactly one outcome per non-empty table and none for an empty/absent one.
- [ ] A row dropped by the LWW pre-check is reported as `rowsSkippedNewerRemote`, with `ok == true` and `rowsFailed == 0`.
- [ ] The pre-existing C1b test (`expect(() => remote.upsertOwnRows(...), throwsA(isA<AssertionError>()))`, sync_service_test.dart:1213) still passes — the ownerId assert is not swallowed.
- [ ] `flutter analyze` = 0 issues; `flutter test` green at **baseline + 2 for this task** (D-13).

**Commit:** `refactor(sync)!: upsertOwnRows reports per-table outcomes instead of void`

> Every commit ends with the trailer `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

---

### Task 3: `PushSyncResult` gains `rowsFailed`/`errors`/`fullyLanded` and `pushOwn` aggregates them (S1 core, incl. the zero-photo regression)

**Files:** Create: — · Modify: `lib/features/backup/data/sync_service.dart:23-56`, `lib/features/backup/data/sync_service.dart:338-344`, `test/features/backup/data/sync_service_test.dart:260-272`, `test/features/backup/data/sync_service_test.dart:469-473` · Test: `test/features/backup/data/sync_service_test.dart`

**Interfaces:** **Consumes** the new `upsertOwnRows` return type (T2), `TablePushOutcome` (T1), `PullResult.errors`'s shape (`sync_service.dart:142`) and message style (`:469`), `FakeSyncRemote`, `makeContainer`, `seedWallHierarchy`, `writeFile`, `_signedInU1`/`_uidU1`, `FakeAuthRepository`. **Produces** `PushSyncResult.rowsFailed`/`errors`/`fullyLanded` + amended `.pushed` ctor + `toString`; `pushOwn`'s `errors`/`rowsFailed` accumulators, declared once above the guard block (D-11); the three public doubles `AllTablesFailingSyncRemote` / `ThrowingUpsertSyncRemote` / `OneTableFailingSyncRemote` (§1e and §1f reuse them — decision #11).

- [ ] **Step 1: Add three new `FakeSyncRemote` variants to test/features/backup/data/sync_service_test.dart, immediately after `ThrowingFetchSharedToposRemote` (which ends at :272).**

  ```dart
  /// [FakeSyncRemote] variant whose [upsertOwnRows] reports EVERY attempted
  /// table as failed — exactly the shape `SupabaseSyncRemote.upsertOwnRows`
  /// returns when each table's round trip throws (offline, captive portal,
  /// expired JWT, ...). Storage/photo methods are inherited and keep working,
  /// so a test can isolate "the row phase failed" from "the photo phase
  /// failed".
  ///
  /// S1 regression guard: before §1d this class was unrepresentable —
  /// `upsertOwnRows` returned `void` and swallowed per-table errors, so
  /// `pushOwn` counted the rows it handed over as pushed and reported success.
  class AllTablesFailingSyncRemote extends FakeSyncRemote {
    AllTablesFailingSyncRemote({this.message = 'simulated cloud error'});

    final String message;

    @override
    Future<List<TablePushOutcome>> upsertOwnRows(
      String uid,
      Map<String, List<Map<String, dynamic>>> tablesToRows,
    ) async => [
      for (final entry in tablesToRows.entries)
        if (entry.value.isNotEmpty)
          TablePushOutcome.failed(
            table: entry.key,
            rowsFailed: entry.value.length,
            error: Exception(message),
          ),
    ];
  }

  /// [FakeSyncRemote] variant whose [upsertOwnRows] THROWS outright rather
  /// than reporting per-table failures — the "remote itself is unreachable"
  /// shape. `pushOwn` must convert this into an all-tables-failed RESULT, not
  /// propagate it, so the orchestrator sees a truthful push result either way.
  class ThrowingUpsertSyncRemote extends FakeSyncRemote {
    @override
    Future<List<TablePushOutcome>> upsertOwnRows(
      String uid,
      Map<String, List<Map<String, dynamic>>> tablesToRows,
    ) async {
      throw Exception('upsertOwnRows boom');
    }
  }

  /// [FakeSyncRemote] variant where exactly ONE table fails and every other
  /// table pushes normally — proves per-table isolation is preserved (the
  /// other tables really do land) while the failure is now REPORTED.
  class OneTableFailingSyncRemote extends FakeSyncRemote {
    OneTableFailingSyncRemote(this.failingTable);

    final String failingTable;

    @override
    Future<List<TablePushOutcome>> upsertOwnRows(
      String uid,
      Map<String, List<Map<String, dynamic>>> tablesToRows,
    ) async {
      final failingRows = tablesToRows[failingTable];
      final outcomes = await super.upsertOwnRows(uid, {
        for (final entry in tablesToRows.entries)
          if (entry.key != failingTable) entry.key: entry.value,
      });
      if (failingRows != null && failingRows.isNotEmpty) {
        outcomes.add(
          TablePushOutcome.failed(
            table: failingTable,
            rowsFailed: failingRows.length,
            error: Exception('$failingTable rejected'),
          ),
        );
      }
      return outcomes;
    }
  }
  ```

- [ ] **Step 2: Add a new top-level group to test/features/backup/data/sync_service_test.dart, immediately after the `group('pushOwn', ...)` closing `});` (currently :764).**

  ```dart
    group('§1d (S1): pushOwn tells the truth about what landed', () {
      /// Two own rows and NO photo rows — the exact S1 precondition.
      Future<void> seedAreaAndSectorOnly(AppDatabase db) async {
        await db.into(db.areas).insert(
          AreasCompanion.insert(
            id: 'area-1',
            createdAt: 100,
            updatedAt: 100,
            ownerId: const Value(_uidU1),
            name: 'Area 1',
          ),
        );
        await db.into(db.sectors).insert(
          SectorsCompanion.insert(
            id: 'sector-1',
            createdAt: 100,
            updatedAt: 100,
            ownerId: const Value(_uidU1),
            areaId: 'area-1',
            name: 'Sector 1',
            sortOrder: 0,
          ),
        );
      }

      test(
        'S1 REGRESSION: an account with ZERO photo rows whose every table '
        'failed reports the failure. Pre-fix this exact case reported '
        'outcome=pushed with rowsPushed counting rows merely handed to the '
        'remote, because `_uploadOwnPhotos` short-circuits at '
        '`if (photos.isEmpty) return 0;` BEFORE the unguarded '
        'listPhotoObjectPaths call that was the only thing surfacing a failed '
        'push — so the Account screen rendered "Synced • just now"',
        () async {
          final remote = AllTablesFailingSyncRemote();
          final c = makeContainer(remote: remote, auth: FakeAuthRepository(_signedInU1));
          addTearDown(() => c.db.close());

          await seedAreaAndSectorOnly(c.db);

          final result = await c.service.pushOwn();

          expect(
            await c.db.select(c.db.photos).get(),
            isEmpty,
            reason: 'the zero-photo precondition this regression depends on',
          );
          expect(result.rowsFailed, 2);
          expect(result.rowsPushed, 0);
          expect(result.errors, hasLength(2));
          expect(result.errors.join(' '), contains('simulated cloud error'));
          expect(
            result.fullyLanded,
            isFalse,
            reason: 'nothing reached the cloud — this must never read as a '
                'complete sync',
          );
        },
      );

      test(
        'the same all-tables-failed push with photo rows PRESENT also reports '
        'the failure, and the photo phase still runs (per-phase isolation is '
        'preserved, just no longer silent)',
        () async {
          final remote = AllTablesFailingSyncRemote();
          final c = makeContainer(remote: remote, auth: FakeAuthRepository(_signedInU1));
          addTearDown(() => c.db.close());

          final file = writeFile(c.srcDir, 'wall.jpg');
          await seedWallHierarchy(
            c.db,
            ownerId: _uidU1,
            areaId: 'area-1',
            sectorId: 'sector-1',
            wallId: 'wall-1',
            photoId: 'photo-1',
            routeId: 'route-1',
            localPath: file.path,
          );

          final result = await c.service.pushOwn();

          expect(result.rowsFailed, 5);
          expect(result.rowsPushed, 0);
          expect(result.fullyLanded, isFalse);
          expect(
            result.photosUploaded,
            1,
            reason: 'the byte phase is independent of the row phase and still '
                'ran',
          );
        },
      );

      test(
        'upsertOwnRows throwing outright is converted into an all-tables-failed '
        'RESULT, not propagated out of pushOwn',
        () async {
          final remote = ThrowingUpsertSyncRemote();
          final c = makeContainer(remote: remote, auth: FakeAuthRepository(_signedInU1));
          addTearDown(() => c.db.close());

          await seedAreaAndSectorOnly(c.db);

          final result = await c.service.pushOwn();

          expect(result.didPush, isTrue);
          expect(result.fullyLanded, isFalse);
          expect(result.rowsFailed, 2);
          expect(result.errors.join(' '), contains('upsertOwnRows boom'));
        },
      );

      test(
        'ONE failing table is reported while every OTHER table genuinely lands '
        '— rowsPushed and rowsFailed split the batch, and the partial push is '
        'not fullyLanded',
        () async {
          final remote = OneTableFailingSyncRemote('photos');
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

          final result = await c.service.pushOwn();

          expect(result.rowsPushed, 4, reason: 'area + sector + wall + route');
          expect(result.rowsFailed, 1, reason: 'the one photos row');
          expect(result.errors, hasLength(1));
          expect(result.errors.single, contains('photos'));
          expect(result.fullyLanded, isFalse);

          final ownRows = await remote.fetchOwnRows(_uidU1);
          expect(ownRows['areas']!.map((r) => r['id']), ['area-1']);
          expect(ownRows['routes']!.map((r) => r['id']), ['route-1']);
          expect(
            ownRows['photos'],
            isEmpty,
            reason: 'the failing table really did not land',
          );
        },
      );
    });
  ```

- [ ] **Step 3: Also extend the FIRST existing pushOwn test to pin the clean-path values, by adding three expectations right after `expect(result.rowsPushed, 6);` (sync_service_test.dart:473).**

  ```dart
          expect(result.rowsFailed, 0);
          expect(result.errors, isEmpty);
          expect(
            result.fullyLanded,
            isTrue,
            reason: 'a clean push is the ONLY thing allowed to read as a '
                'complete sync',
          );
  ```

- [ ] **Step 4: Run the file and watch it FAIL (`rowsFailed`/`errors`/`fullyLanded` do not exist on `PushSyncResult`).**

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/backup/data/sync_service_test.dart
  ```

  Expected: Compile error: The getter 'rowsFailed' isn't defined for the type 'PushSyncResult'.

- [ ] **Step 5: Replace `class PushSyncResult` in lib/features/backup/data/sync_service.dart (lines 23-56) with the reporting version.**

  > Corrected (**D-2** — `fullyLanded` is defined here WITHOUT `photosFailed`, because §1f is the fragment that adds that field. The doc comment now states, prominently and in-source, that **§1f MUST amend it**; leaving it silently short would let a push whose every photo failed report `fullyLanded == true` and re-tell the S1 lie.)

  ```dart
  /// Result of a [SyncService.pushOwn] call.
  ///
  /// S1 fix (§1d): [rowsFailed]/[errors] mirror [PullResult.errors]' shape on
  /// the push side. Before this, a push could only report how many rows it
  /// HANDED to the remote — every per-table failure was swallowed inside
  /// [SyncRemote.upsertOwnRows] — so a push where literally nothing landed
  /// still produced `outcome == pushed` with a healthy row count, and the
  /// Account screen's `sync-status` line rendered "Synced • just now".
  class PushSyncResult {
    const PushSyncResult.pushed({
      required this.rowsPushed,
      required this.photosUploaded,
      this.rowsFailed = 0,
      this.errors = const [],
    }) : outcome = SyncPushOutcome.pushed;

    const PushSyncResult.skippedSignedOut()
      : outcome = SyncPushOutcome.skippedSignedOut,
        rowsPushed = 0,
        photosUploaded = 0,
        rowsFailed = 0,
        errors = const [];

    const PushSyncResult.skippedNotWifi()
      : outcome = SyncPushOutcome.skippedNotWifi,
        rowsPushed = 0,
        photosUploaded = 0,
        rowsFailed = 0,
        errors = const [];

    final SyncPushOutcome outcome;

    /// Total row count now KNOWN TO BE IN THE CLOUD across all nine tables
    /// (profiles/areas/sectors/walls/photos/routes/comments/likes/ascents),
    /// INCLUDING tombstones — rows this call upserted, plus rows the
    /// last-writer-wins pre-check skipped because the cloud copy is strictly
    /// newer (nothing left to send for those; see
    /// [TablePushOutcome.rowsSkippedNewerRemote]).
    ///
    /// S1 fix: this used to count rows merely HANDED TO the remote. Rows that
    /// did NOT land are in [rowsFailed]. Always 0 when [outcome] isn't
    /// [SyncPushOutcome.pushed].
    final int rowsPushed;

    /// Number of distinct photo FILES actually uploaded (private copy and/or
    /// shared copy; excludes files already present remotely under a given
    /// path). Always 0 when [outcome] isn't [SyncPushOutcome.pushed].
    final int photosUploaded;

    /// Rows this push did NOT get into the cloud: every row of a table whose
    /// upsert failed (see [TablePushOutcome.failed]) PLUS every local row
    /// excluded by [pushOwn]'s required-NOT-NULL-field guard (L5 — with no
    /// outbox, an excluded row used to be dropped from this and every future
    /// push, visible only as a `debugPrint`).
    final int rowsFailed;

    /// One human-readable message per table that failed to push or that had
    /// rows excluded by the required-field guard, each including the caught
    /// error's `toString()` where there was one. Empty when everything landed
    /// (the common case). Mirrors [PullResult.errors].
    final List<String> errors;

    bool get didPush => outcome == SyncPushOutcome.pushed;

    /// True only when the push actually RAN and every row it was responsible
    /// for reached the cloud. The ONLY condition under which
    /// `SyncOrchestrator._runPush` may report [SyncStatus.idle] and stamp a
    /// fresh `lastSyncedAt` (S1).
    ///
    /// DELIBERATELY INCOMPLETE — **§1f MUST AMEND THIS** (reconciliation D-2 /
    /// decision #9, the highest-severity cross-fragment defect). §1f adds
    /// `photosFailed` and withholds a failed photo's row FROM the push, so
    /// `rowsFailed` stays 0 and `errors` stays empty for a push in which
    /// EVERY photo's bytes failed to upload. Left as written, that push
    /// reports `fullyLanded == true`, `_runPush` stamps a fresh
    /// `lastSyncedAt`, and the Account screen renders "Synced • just now" —
    /// the exact S1 lie this whole workstream exists to kill, re-entering
    /// through the photo path. §1f's reconciled FINAL form is:
    ///
    ///     bool get fullyLanded =>
    ///         didPush && rowsFailed == 0 && errors.isEmpty && photosFailed == 0;
    ///
    /// with `_runPush`'s `lastPushError` message concatenating
    /// `errors + photoErrors`, and `photosMissingLocalBytes` DELIBERATELY
    /// EXCLUDED (it is non-retryable; including it would stop §1e's retry
    /// loop from ever terminating). Do not delete this paragraph until §1f
    /// has landed the amendment.
    bool get fullyLanded => didPush && rowsFailed == 0 && errors.isEmpty;

    @override
    String toString() =>
        'PushSyncResult(outcome: $outcome, rowsPushed: $rowsPushed, '
        'photosUploaded: $photosUploaded, rowsFailed: $rowsFailed, '
        'errors: $errors)';
  }
  ```

- [ ] **Step 6: (NEW STEP, reconciliation D-11) Declare the two push-failure accumulators exactly ONCE, immediately after `pushOwn`'s local-snapshot transaction closes (`});`, sync_service.dart:275) and immediately BEFORE the existing `// Push-side NOT-NULL guard` comment at :277. Task 4 replaces the block from that comment down and must NOT re-declare them. (The last two lines below are the first two existing lines of the guard comment, shown only to pin the insertion point — do not duplicate them.)**

  > Corrected (**D-11** — new step. In the raw fragment Task 3 declared these inside the upsert block and Task 4 then *moved* them, instructing the implementer to delete Task 3's copies. Split across two engineers that is a guaranteed duplicate-declaration compile error, so Task 3 now declares them where Task 4 wants them.)

  ```dart
      // S1/L5 fix (§1d): the two accumulators EVERY push-failure channel
      // writes into — Task 4's required-field guard (immediately below, once
      // it exists) and the per-table upsert outcomes further down. Declared
      // HERE, above both, so they exist exactly once in `pushOwn`
      // (reconciliation D-11). Task 4 replaces the guard block that starts at
      // the `// Push-side NOT-NULL guard` comment BELOW these two lines and
      // must NOT re-declare them.
      final errors = <String>[];
      var rowsFailed = 0;

      // Push-side NOT-NULL guard (sync-resilience hardening): drops (+
      // debugPrints, via filterValidSyncRows) any local row missing a required
  ```

- [ ] **Step 7: Replace `pushOwn`'s upsert + accounting block in lib/features/backup/data/sync_service.dart (lines 338-344) with the aggregating version. (The nine `filterValidSyncRows` calls at :288-336 stay untouched in this task; T4 converts them.)**

  > Corrected (**D-11** — the `final errors` / `var rowsFailed` declarations are NOT here any more; they were declared in the previous step, above the guard block, exactly where Task 4 needs them. Task 4 therefore only ADDS usages and deletes nothing.)

  ```dart
      // S1 fix (§1d): upsertOwnRows now reports per-table outcomes instead of
      // swallowing each table's error behind a debugPrint and returning void.
      // A WHOLE-CALL throw (the remote itself unreachable) is converted into
      // an all-tables-failed result here, so the row phase never propagates
      // and never lies about what landed.
      //
      // `errors`/`rowsFailed` are the accumulators declared in the previous
      // step, ABOVE the `tablesToRows` construction — do NOT declare them
      // again here (reconciliation D-11).
      List<TablePushOutcome> outcomes;
      try {
        outcomes = await _remote.upsertOwnRows(uid, tablesToRows);
      } catch (e) {
        outcomes = [
          for (final entry in tablesToRows.entries)
            if (entry.value.isNotEmpty)
              TablePushOutcome.failed(
                table: entry.key,
                rowsFailed: entry.value.length,
                error: e,
              ),
        ];
      }

      var rowsPushed = 0;
      for (final outcome in outcomes) {
        if (outcome.ok) {
          // A row the LWW pre-check skipped counts as pushed: the cloud holds
          // a strictly NEWER copy of it, so there is nothing left to send.
          rowsPushed += outcome.rowsUpserted + outcome.rowsSkippedNewerRemote;
        } else {
          rowsFailed += outcome.rowsFailed;
          errors.add(
            '${outcome.table}: ${outcome.rowsFailed} row(s) failed to push: '
            '${outcome.error}',
          );
        }
      }

      final wallVisibility = {for (final wall in walls) wall.id: wall.visibility};
      final photosUploaded = await _uploadOwnPhotos(uid, photos, wallVisibility);

      return PushSyncResult.pushed(
        rowsPushed: rowsPushed,
        photosUploaded: photosUploaded,
        rowsFailed: rowsFailed,
        errors: errors,
      );
  ```

- [ ] **Step 8: Re-run the file and see it pass, including the two untouched historical `rowsPushed` assertions.**

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/backup/data/sync_service_test.dart
  ```

  Expected: All tests passed! — `rowsPushed == 6` (:473) and `rowsPushed == 8` (:1171) still hold.

- [ ] **Step 9: Confirm the whole project analyses clean and the full suite is green.**

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter analyze && flutter test
  ```

  Expected: `No issues found!` and `flutter test` green at **baseline + 4** for this task.

**Assertions:**

- [ ] THE S1 REGRESSION TEST: a signed-in account with **zero** `Photos` rows pushing against `AllTablesFailingSyncRemote` yields `rowsFailed == 2`, `rowsPushed == 0`, `errors.length == 2`, `fullyLanded == false`. Reverting only the `pushOwn` accounting block makes this test fail with `rowsPushed == 2 / rowsFailed == 0`.
- [ ] The same remote WITH photo rows still reports `rowsFailed == 5` and `photosUploaded == 1` — the byte phase is not coupled to the row phase.
- [ ] `upsertOwnRows` throwing outright does not propagate out of `pushOwn`: the result is `didPush == true`, `fullyLanded == false`, `rowsFailed == 2`.
- [ ] A single failing table yields `rowsPushed == 4` + `rowsFailed == 1`, and `remote.fetchOwnRows` proves the other four tables really landed while `photos` did not.
- [ ] A clean push yields `fullyLanded == true`, `rowsFailed == 0`, `errors.isEmpty`.
- [ ] `flutter analyze` = 0 issues; `flutter test` green at **baseline + 4 for this task** (D-13).
- [ ] `fullyLanded` is `didPush && rowsFailed == 0 && errors.isEmpty` **and** its doc comment carries the explicit "§1f MUST AMEND THIS" paragraph naming `photosFailed` (D-2). A verifier that finds the paragraph missing must reject the task.
- [ ] `errors` and `rowsFailed` are declared exactly once in `pushOwn`, ABOVE the `// Push-side NOT-NULL guard` comment: `grep -c 'var rowsFailed = 0;' lib/features/backup/data/sync_service.dart` == 1 (D-11).

**Commit:** `fix(sync): pushOwn reports rowsFailed + errors instead of counting handed-off rows`

> Every commit ends with the trailer `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

---

### Task 4: required-field exclusions feed the same failure channel (L5), via an injectable `pushRequiredFields` seam

**Files:** Create: — · Modify: `lib/features/backup/data/sync_service.dart:202-224`, `lib/features/backup/data/sync_service.dart:277-336`, `test/features/backup/data/sync_service_test.dart:333-352` · Test: `test/features/backup/data/sync_service_test.dart`

**Interfaces:** **Consumes** `partitionSyncRows` (T1), the `errors`/`rowsFailed` accumulators declared by T3 (D-11 — **do not re-declare**), `syncRequiredFields` (`sync_remote.dart:289`), `makeContainer` (`sync_service_test.dart:333-352`). **Produces** `SyncService({..., Map<String, List<String>>? pushRequiredFields})` + the `_pushRequiredFields` field; `pushOwn`'s `guard(table, jsonRows)` closure; `makeContainer(..., pushRequiredFields:)` pass-through.

- [ ] **Step 1: Add the `pushRequiredFields` pass-through to the test helper `makeContainer` in test/features/backup/data/sync_service_test.dart (replace lines 333-352).**

  ```dart
    ({AppDatabase db, Directory docsDir, Directory srcDir, SyncService service}) makeContainer({
      required SyncRemote remote,
      required AuthRepository auth,
      ConnectivityService? connectivity,
      bool Function()? wifiOnly,
      Map<String, List<String>>? pushRequiredFields,
    }) {
      final db = AppDatabase(NativeDatabase.memory());
      final docsDir = Directory(p.join(tmp.path, 'docs_${_counter++}'))..createSync();
      final srcDir = Directory(p.join(tmp.path, 'src_${_counter++}'))..createSync();
      final service = SyncService(
        db: db,
        backupRepository: BackupRepository(db),
        remote: remote,
        authRepository: auth,
        connectivity: connectivity ?? FakeConnectivityService(NetworkStatus.wifi),
        photoFiles: PhotoFiles(docsDir: () async => docsDir),
        wifiOnly: wifiOnly,
        pushRequiredFields: pushRequiredFields,
      );
      return (db: db, docsDir: docsDir, srcDir: srcDir, service: service);
    }
  ```

- [ ] **Step 2: Add the L5 test at the END of the `group('§1d (S1): pushOwn tells the truth about what landed', ...)` added in T3.**

  ```dart
      test(
        'L5: a local row excluded by the push-side required-field guard lands '
        'in the push result\'s failure channel (rowsFailed + errors) instead of '
        'being dropped from this and every future push with only a debugPrint '
        '— with no outbox, "excluded once" meant "excluded forever"',
        () async {
          final remote = FakeSyncRemote();
          final c = makeContainer(
            remote: remote,
            auth: FakeAuthRepository(_signedInU1),
            // Every column syncRequiredFields names is NOT NULL in Drift, so a
            // genuinely-missing required value is only reachable through local
            // data corruption. Requiring a column that cannot exist is the
            // faithful stand-in: it is exactly what a corrupted/absent
            // required value looks like TO THE GUARD. Only 'areas' is
            // overridden; every other table falls back to `const ['id']`,
            // which every real row satisfies.
            pushRequiredFields: const {
              'areas': [
                'id',
                'createdAt',
                'updatedAt',
                'name',
                'columnThatCannotExist',
              ],
            },
          );
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

          final result = await c.service.pushOwn();

          expect(result.rowsFailed, 1);
          expect(result.errors, hasLength(1));
          expect(result.errors.single, contains('areas'));
          expect(
            result.errors.single,
            contains('area-1'),
            reason: 'the excluded row must be identifiable, not just counted',
          );
          expect(result.fullyLanded, isFalse);
          expect(
            result.rowsPushed,
            4,
            reason: 'sector + wall + photo + route still pushed — the guard is '
                'per-row, not per-batch',
          );

          final ownRows = await remote.fetchOwnRows(_uidU1);
          expect(
            ownRows['areas'],
            isEmpty,
            reason: 'the excluded row genuinely never reached the cloud',
          );
          expect(ownRows['sectors']!.map((r) => r['id']), ['sector-1']);
        },
      );
  ```

- [ ] **Step 3: Run the file and watch it FAIL (`SyncService` has no `pushRequiredFields` parameter).**

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/backup/data/sync_service_test.dart
  ```

  Expected: Compile error: No named parameter with the name 'pushRequiredFields'.

- [ ] **Step 4: Add the constructor param + field to `SyncService` in lib/features/backup/data/sync_service.dart (extend the constructor at :202-216 and the field block at :218-224).**

  ```dart
    SyncService({
      required db.AppDatabase db,
      required BackupRepository backupRepository,
      required SyncRemote remote,
      required AuthRepository authRepository,
      required ConnectivityService connectivity,
      PhotoFiles? photoFiles,
      bool Function()? wifiOnly,
      Map<String, List<String>>? pushRequiredFields,
    }) : _db = db, // ignore: prefer_initializing_formals
         _backupRepository = backupRepository, // ignore: prefer_initializing_formals
         _remote = remote, // ignore: prefer_initializing_formals
         _authRepository = authRepository, // ignore: prefer_initializing_formals
         _connectivity = connectivity, // ignore: prefer_initializing_formals
         _photoFiles = photoFiles ?? PhotoFiles(),
         _wifiOnly = wifiOnly ?? (() => false),
         _pushRequiredFields = pushRequiredFields ?? syncRequiredFields;

    final db.AppDatabase _db;
    final BackupRepository _backupRepository;
    final SyncRemote _remote;
    final AuthRepository _authRepository;
    final ConnectivityService _connectivity;
    final PhotoFiles _photoFiles;
    final bool Function() _wifiOnly;

    /// The per-table required-NOT-NULL-field map [pushOwn]'s push-side guard
    /// validates each local row against, defaulting to [syncRequiredFields].
    ///
    /// Injectable ONLY so a test can make an ordinary, perfectly valid local
    /// row fail that guard: every column [syncRequiredFields] names is NOT
    /// NULL in Drift, so a genuinely-missing required value is unreachable
    /// from a real local row set (it needs local data corruption) — yet the
    /// guard's reject branch is exactly what L5 is about, and it must be
    /// provable end-to-end that an excluded row reaches
    /// [PushSyncResult.rowsFailed]/[PushSyncResult.errors]. Production always
    /// uses the default.
    final Map<String, List<String>> _pushRequiredFields;
  ```

- [ ] **Step 5: Replace `pushOwn`'s nine-table guard block in lib/features/backup/data/sync_service.dart (lines 277-336) with the partitioning version, and DELETE the `final errors`/`var rowsFailed` declarations added at the top of T3's block (they move up here).**

  > Corrected (**D-11** — this block no longer declares `errors`/`rowsFailed`; Task 3 already did, immediately above the `// Push-side NOT-NULL guard` comment. The raw fragment's follow-up "delete the now-duplicated declarations" step has been removed entirely.)

  ```dart
      // Push-side NOT-NULL guard (sync-resilience hardening): drops any local
      // row missing a required NOT-NULL field before it's ever sent to
      // Supabase, reusing the exact same [syncRequiredFields] map +
      // [hasRequiredSyncFields]/[partitionSyncRows] helpers the fetch side
      // validates with (imported from `sync_remote.dart`) — the symmetric
      // guard to `fetchOwnRows`'s. A normal local row set is unaffected: local
      // Drift NOT-NULL column constraints mean a genuinely null required field
      // can only happen here via local data corruption, not everyday use. The
      // `?? const ['id']` fallback is defensive only — every table name below
      // has a matching entry in [syncRequiredFields].
      //
      // L5 fix (§1d): an excluded row is now REPORTED in [rowsFailed]/
      // [errors] rather than dropped with nothing but a debugPrint. With no
      // outbox, "excluded once" meant "excluded forever" — and invisibly.
      //
      // `errors`/`rowsFailed` were ALREADY declared by Task 3, immediately
      // above this comment. Do NOT re-declare them here (reconciliation
      // D-11 — two engineers each adding their own copy is a
      // duplicate-declaration compile error).
      List<Map<String, dynamic>> guard(
        String table,
        List<Map<String, dynamic>> jsonRows,
      ) {
        final required = _pushRequiredFields[table] ?? const ['id'];
        final split = partitionSyncRows(
          jsonRows,
          required,
          debugLabel: 'local $table (push)',
        );
        if (split.invalid.isNotEmpty) {
          rowsFailed += split.invalid.length;
          errors.add(
            '$table: ${split.invalid.length} local row(s) excluded by the '
            'required-field guard ($required) and NOT pushed: '
            '${[for (final row in split.invalid) row['id']]}',
          );
        }
        return split.valid;
      }

      final tablesToRows = <String, List<Map<String, dynamic>>>{
        'profiles': guard('profiles', [for (final row in profiles) row.toJson()]),
        'areas': guard('areas', [for (final row in areas) row.toJson()]),
        'sectors': guard('sectors', [for (final row in sectors) row.toJson()]),
        'walls': guard('walls', [for (final row in walls) row.toJson()]),
        'photos': guard('photos', [for (final row in photos) row.toJson()]),
        'routes': guard('routes', [for (final row in routes) row.toJson()]),
        'comments': guard('comments', [for (final row in comments) row.toJson()]),
        'likes': guard('likes', [for (final row in likes) row.toJson()]),
        // Ascents ARE pushed here (own-row push, no visibility distinction) —
        // it's fetchSharedTopos (pull side) that keeps them private, not push.
        'ascents': guard('ascents', [for (final row in ascents) row.toJson()]),
      };
  ```

- [ ] **Step 6: Re-run the file and see it pass.**

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/backup/data/sync_service_test.dart
  ```

  Expected: All tests passed!

- [ ] **Step 7: Confirm the whole project analyses clean and the full suite is green.**

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter analyze && flutter test
  ```

  Expected: `No issues found!` and `flutter test` green at **baseline + 1** for this task.

**Assertions:**

- [ ] A row excluded by the push-side required-field guard produces `rowsFailed == 1` and exactly one `errors` entry naming both the table (`areas`) and the row id (`area-1`); `fullyLanded == false`.
- [ ] The excluded row genuinely never reaches the remote (`fetchOwnRows()['areas']` is empty) while the other four tables push (`rowsPushed == 4`, `sectors` present) — per-row, not per-batch, rejection.
- [ ] `_pushRequiredFields` defaults to `syncRequiredFields`; production wiring in `sync_providers.dart:170-178` passes nothing, so behaviour there is unchanged.
- [ ] The nine `debugLabel` strings are still `'local <table> (push)'` — grep `local areas (push)` in lib/features/backup/data/sync_service.dart hits.
- [ ] `errors`/`rowsFailed` are declared exactly once in `pushOwn` (`grep -c "var rowsFailed = 0;" lib/features/backup/data/sync_service.dart` == 1).
- [ ] `flutter analyze` = 0 issues; `flutter test` green at **baseline + 1 for this task** (D-13).
- [ ] This task adds NO new `final errors` / `var rowsFailed` declaration and DELETES none — Task 3 placed them correctly (D-11).

**Commit:** `fix(sync): report push-side required-field exclusions instead of dropping them`

> Every commit ends with the trailer `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

---

### Task 5: a push that did not fully land never reports idle and never stamps `lastSyncedAt` (`SyncOrchestratorState.lastPushError`)

**Files:** Create: — · Modify: `lib/features/backup/application/sync_orchestrator.dart:36-86`, `lib/features/backup/application/sync_orchestrator.dart:204-220`, `test/features/backup/application/sync_orchestrator_test.dart:110-115` · Test: `test/features/backup/application/sync_orchestrator_test.dart`

**Interfaces:** **Consumes** `PushSyncResult.fullyLanded` (T3), the post-T2 `_CountingSyncRemote`, `makeContainer` (`sync_orchestrator_test.dart:175`), `primeOrchestrator` (`:163`), `insertArea` (`:209`), `nowMsProvider` (`database_provider.dart:24`), `syncDebounceDurationProvider` (`sync_orchestrator.dart:92`), `_runPull`'s explicit-constructor pattern (`:305-323`). **Produces** `SyncOrchestratorState.lastPushError` (in ctor/`==`/`hashCode`/`toString`/`copyWith` passthrough); an honest `_runPush`; a `_runPull` that carries `lastPushError` through all three writes; `_FailingPushSyncRemote` with mutable `failPush`.

- [ ] **Step 1: Add `_FailingPushSyncRemote` to test/features/backup/application/sync_orchestrator_test.dart, immediately after `_ThrowingSharedToposSyncRemote` (which ends at :115).**

  ```dart
  /// A [_CountingSyncRemote] whose `upsertOwnRows` reports EVERY attempted
  /// table as failed — the shape `SupabaseSyncRemote.upsertOwnRows` returns
  /// when each table's round trip throws (offline / captive portal / expired
  /// JWT). The push still RUNS (so `pushCallCount` increments) but nothing
  /// lands, so `PushSyncResult.fullyLanded` is false.
  ///
  /// Flip [failPush] to `false` mid-test to make the NEXT push land cleanly.
  class _FailingPushSyncRemote extends _CountingSyncRemote {
    bool failPush = true;

    @override
    Future<List<TablePushOutcome>> upsertOwnRows(
      String uid,
      Map<String, List<Map<String, dynamic>>> tablesToRows,
    ) async {
      if (!failPush) return super.upsertOwnRows(uid, tablesToRows);
      pushCallCount++;
      return [
        for (final entry in tablesToRows.entries)
          if (entry.value.isNotEmpty)
            TablePushOutcome.failed(
              table: entry.key,
              rowsFailed: entry.value.length,
              error: Exception('push-boom'),
            ),
      ];
    }
  }
  ```

- [ ] **Step 2: Add a new group at the END of `main()` in test/features/backup/application/sync_orchestrator_test.dart, after the `group('status transitions', ...)` closing `});` (currently :725).**

  ```dart
    group('§1d (S1): a push that did not land never reports "synced"', () {
      test(
        'a push whose every table failed leaves status NOT idle, leaves '
        'lastSyncedAt untouched, and records lastPushError — pre-fix this set '
        'status: idle + lastSyncedAt: now, which the Account screen rendered '
        'as "Synced • just now"',
        () async {
          final db = AppDatabase(NativeDatabase.memory());
          addTearDown(db.close);
          final remote = _FailingPushSyncRemote();
          final container = makeContainer(
            db: db,
            remote: remote,
            syncServiceAuth: _FakeAuthRepository(
              const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
            ),
            debounce: const Duration(milliseconds: 15),
            nowMs: () => 123456,
          );

          primeOrchestrator(container);
          await Future<void>.delayed(const Duration(milliseconds: 5));

          await insertArea(db, 'a1', ownerId: 'u1');
          await Future<void>.delayed(const Duration(milliseconds: 80));

          final state = container.read(syncOrchestratorProvider);
          expect(remote.pushCallCount, 1, reason: 'the push did run');
          expect(
            state.status,
            isNot(SyncStatus.idle),
            reason: 'a push where nothing landed must never read as idle',
          );
          expect(
            state.lastSyncedAt,
            isNull,
            reason: 'lastSyncedAt must not be stamped by a push that failed',
          );
          expect(
            state.lastPushError,
            allOf(contains('Sync failed'), contains('push-boom')),
          );
        },
      );

      test(
        'a later FULLY-LANDED push clears lastPushError, flips status back to '
        'idle, and stamps lastSyncedAt',
        () async {
          final db = AppDatabase(NativeDatabase.memory());
          addTearDown(db.close);
          final remote = _FailingPushSyncRemote();
          final container = makeContainer(
            db: db,
            remote: remote,
            syncServiceAuth: _FakeAuthRepository(
              const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
            ),
            debounce: const Duration(milliseconds: 15),
            nowMs: () => 123456,
          );

          primeOrchestrator(container);
          await Future<void>.delayed(const Duration(milliseconds: 5));

          await insertArea(db, 'a1', ownerId: 'u1');
          await Future<void>.delayed(const Duration(milliseconds: 80));
          expect(
            container.read(syncOrchestratorProvider).lastPushError,
            isNotNull,
          );

          remote.failPush = false;
          await insertArea(db, 'a2', ownerId: 'u1');
          await Future<void>.delayed(const Duration(milliseconds: 80));

          final state = container.read(syncOrchestratorProvider);
          expect(state.status, SyncStatus.idle);
          expect(state.lastSyncedAt, DateTime.fromMillisecondsSinceEpoch(123456));
          expect(state.lastPushError, isNull);
        },
      );

      test(
        'a failed push does NOT touch lastPullError — the two channels stay '
        'independent (a pull-side retry affordance must not light up because a '
        'push failed, and vice versa)',
        () async {
          final db = AppDatabase(NativeDatabase.memory());
          addTearDown(db.close);
          final remote = _FailingPushSyncRemote();
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

          await insertArea(db, 'a1', ownerId: 'u1');
          await Future<void>.delayed(const Duration(milliseconds: 80));

          expect(container.read(syncOrchestratorProvider).lastPullError, isNull);
          expect(
            container.read(syncOrchestratorProvider).lastPushError,
            isNotNull,
          );
        },
      );
    });
  ```

- [ ] **Step 3: Run the file and watch it FAIL (`lastPushError` does not exist; the failed push currently reports idle + a stamped lastSyncedAt).**

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/backup/application/sync_orchestrator_test.dart
  ```

  Expected: Compile error: The getter 'lastPushError' isn't defined for the type 'SyncOrchestratorState'.

- [ ] **Step 4: Add the `lastPushError` field to `SyncOrchestratorState` in lib/features/backup/application/sync_orchestrator.dart (replace lines 36-86, keeping the existing `lastPullError` doc verbatim).**

  > Corrected (**D-10** — the `/// (existing doc for lastPullError preserved verbatim from lines 46-61)` placeholder is replaced with the real 16-line doc comment, copied from `sync_orchestrator.dart:46-61`. One clause is amended, deliberately and visibly: the parenthetical `([_runPush] only ever changes [status]/[lastSyncedAt])` is now false after this very task, so it reads `([_runPush] writes only [status]/[lastSyncedAt]/[lastPushError])`. Everything else is byte-for-byte the existing text.)

  ```dart
  class SyncOrchestratorState {
    const SyncOrchestratorState({
      this.status = SyncStatus.idle,
      this.lastSyncedAt,
      this.lastPullError,
      this.lastPushError,
    });

    final SyncStatus status;

    /// The last time a push or pull actually completed SUCCESSFULLY. S1 fix
    /// (§1d): a push is only "successful" when [PushSyncResult.fullyLanded] —
    /// a push where some or all rows never reached the cloud leaves this at
    /// its previous value rather than stamping a fresh, false "just now".
    final DateTime? lastSyncedAt;

    /// Human-readable description of why the MOST RECENT `pullOwnAndShared()`
    /// call (via [SyncOrchestrator.pullNow]) reported a problem — #72 P1 fix
    /// (see [SyncOrchestrator._runPull]): set whenever [PullResult.errors]
    /// came back non-empty (own or shared side partially/fully failed — see
    /// that class's doc for what "partial" means; a partial failure is
    /// surfaced here too, NOT discarded and NOT conflated with a total one)
    /// OR the call to `pullOwnAndShared()` itself threw. `null` once a pull
    /// completes with zero errors, or while signed out — this field is
    /// deliberately CLEARED, not left stale, in either of those cases. The
    /// Feed/Library empty states (`community_feed_screen.dart`'s
    /// `_SyncErrorEmptyState`, `topos_empty_states.dart`'s
    /// `_SyncErrorEmptyState`) key their "Couldn't sync — retry" affordance
    /// directly off this being non-null, so it must never linger past a pull
    /// that actually succeeded cleanly. A PUSH failure never touches this
    /// field ([_runPush] writes only [status]/[lastSyncedAt]/[lastPushError])
    /// — it is pull-specific by design.
    final String? lastPullError;

    /// Human-readable description of why the MOST RECENT push did not fully
    /// land — S1 fix (§1d): set whenever [PushSyncResult.fullyLanded] came
    /// back false (one or more tables failed, and/or rows were excluded by the
    /// push-side required-field guard) OR the `pushOwn()` call itself threw.
    /// `null` once a push lands completely.
    ///
    /// Deliberately NOT cleared by a successful PULL, unlike [lastPullError]:
    /// a pull says nothing about whether local changes reached the cloud, and
    /// "Synced • just now" (which a successful pull legitimately produces:
    /// `idle` + a fresh [lastSyncedAt]) while the last push failed was exactly
    /// the S1 lie. `account_screen.dart`'s `_syncStatusLabel` keys off this.
    final String? lastPushError;

    SyncOrchestratorState copyWith({SyncStatus? status, DateTime? lastSyncedAt}) =>
        SyncOrchestratorState(
          status: status ?? this.status,
          lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
          lastPullError: lastPullError,
          lastPushError: lastPushError,
        );

    @override
    bool operator ==(Object other) =>
        identical(this, other) ||
        (other is SyncOrchestratorState &&
            other.status == status &&
            other.lastSyncedAt == lastSyncedAt &&
            other.lastPullError == lastPullError &&
            other.lastPushError == lastPushError);

    @override
    int get hashCode =>
        Object.hash(status, lastSyncedAt, lastPullError, lastPushError);

    @override
    String toString() =>
        'SyncOrchestratorState(status: $status, lastSyncedAt: $lastSyncedAt, '
        'lastPullError: $lastPullError, lastPushError: $lastPushError)';
  }
  ```

- [ ] **Step 5: Replace `_runPush` in lib/features/backup/application/sync_orchestrator.dart (lines 204-220) with the honest version, using the explicit-constructor style `_runPull` already uses so both nullable error fields can be set or cleared. (`SyncStatus.error` is used for every failure for now; T7 splits it into offline vs error.)**

  ```dart
    /// S1 fix (§1d): only a push where EVERYTHING landed
    /// ([PushSyncResult.fullyLanded]) may report [SyncStatus.idle] and stamp a
    /// fresh `lastSyncedAt`. A partial or total failure keeps the previous
    /// timestamp and records [SyncOrchestratorState.lastPushError] — before
    /// this, `upsertOwnRows` swallowed every per-table error, so a totally
    /// failed offline push reported "Synced • just now".
    Future<void> _runPush() async {
      state = state.copyWith(status: SyncStatus.syncing);
      try {
        final result = await ref.read(syncServiceProvider).pushOwn();
        switch (result.outcome) {
          case SyncPushOutcome.pushed:
            if (result.fullyLanded) {
              state = SyncOrchestratorState(
                status: SyncStatus.idle,
                lastSyncedAt: _now(),
                lastPullError: state.lastPullError,
              );
            } else {
              state = SyncOrchestratorState(
                status: SyncStatus.error,
                lastSyncedAt: state.lastSyncedAt,
                lastPullError: state.lastPullError,
                lastPushError:
                    'Sync failed: ${result.rowsFailed} change(s) not uploaded — '
                    '${result.errors.join('; ')}',
              );
            }
          case SyncPushOutcome.skippedSignedOut:
            state = state.copyWith(status: SyncStatus.idle);
          case SyncPushOutcome.skippedNotWifi:
            state = state.copyWith(status: SyncStatus.offline);
        }
      } catch (e, st) {
        debugPrint('SyncOrchestrator: pushOwn failed: $e\n$st');
        state = SyncOrchestratorState(
          status: SyncStatus.error,
          lastSyncedAt: state.lastSyncedAt,
          lastPullError: state.lastPullError,
          lastPushError: 'Sync failed: $e',
        );
      }
    }
  ```

- [ ] **Step 6: Update `_runPull`'s two success branches (lines 305-315) and its catch (319-323) to carry `lastPushError` through, so a push failure survives a later pull.**

  ```dart
        switch (result.outcome) {
          case SyncPullOutcome.pulled:
            state = SyncOrchestratorState(
              status: SyncStatus.idle,
              lastSyncedAt: _now(),
              lastPullError: pullError,
              // A pull says nothing about whether local changes reached the
              // cloud — carrying this through is what stops a successful pull
              // from relabelling an unpushed library as "Synced" (S1).
              lastPushError: state.lastPushError,
            );
          case SyncPullOutcome.skippedSignedOut:
            state = SyncOrchestratorState(
              status: SyncStatus.idle,
              lastSyncedAt: state.lastSyncedAt,
              lastPullError: pullError,
              lastPushError: state.lastPushError,
            );
        }
      } catch (e, st) {
        debugPrint('SyncOrchestrator: pullOwnAndShared failed: $e\n$st');
        state = SyncOrchestratorState(
          status: SyncStatus.error,
          lastSyncedAt: state.lastSyncedAt,
          lastPullError: 'Sync failed: $e',
          lastPushError: state.lastPushError,
        );
      }
  ```

- [ ] **Step 7: Re-run the orchestrator test file and see it pass.**

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/backup/application/sync_orchestrator_test.dart
  ```

  Expected: All tests passed! — including the pre-existing `status transitions` test (:682-723) which still expects idle + lastSyncedAt for a clean push.

- [ ] **Step 8: Confirm the whole project analyses clean and the full suite is green (topos_screen/community tests construct `SyncOrchestratorState` with named args and are unaffected).**

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter analyze && flutter test
  ```

  Expected: `No issues found!` and `flutter test` green at **baseline + 3** for this task.

**Assertions:**

- [ ] With `_FailingPushSyncRemote`, after a debounced push: `status != SyncStatus.idle`, `lastSyncedAt == null`, and `lastPushError` contains both `Sync failed` and `push-boom`. Reverting `_runPush` alone makes this fail with `status == idle` and a stamped `lastSyncedAt`.
- [ ] Flipping `failPush = false` and writing again yields `status == SyncStatus.idle`, `lastSyncedAt == DateTime.fromMillisecondsSinceEpoch(123456)`, `lastPushError == null`.
- [ ] A failed push leaves `lastPullError == null` — the push and pull error channels are independent.
- [ ] `SyncOrchestratorState`'s `==`, `hashCode`, `toString`, and `copyWith` all account for `lastPushError`; `_runPull` carries it through in all three of its state writes.
- [ ] The pre-existing `status transitions` test (a clean push → idle + `lastSyncedAt` from `nowMsProvider`) still passes unchanged.
- [ ] `flutter analyze` = 0 issues; `flutter test` green at **baseline + 3 for this task** (D-13).
- [ ] The `lastPullError` doc comment is the real 16-line text from `sync_orchestrator.dart:46-61`, with the single amended clause `([_runPush] writes only [status]/[lastSyncedAt]/[lastPushError])`. No `(existing doc … preserved verbatim …)` placeholder survives (D-10).

**Commit:** `fix(sync): a push that did not fully land never reports idle or stamps lastSyncedAt`

> Every commit ends with the trailer `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

---

### Task 6: real reachability probe behind the `ConnectivityService` seam (S4): `isBackendReachable()` + all four fakes

**Files:** Create: — · Modify: `lib/features/backup/data/connectivity_service.dart:1-67`, `test/features/backup/data/connectivity_service_test.dart:1-39`, `test/features/backup/data/sync_service_test.dart:274-283`, `test/features/backup/application/sync_orchestrator_test.dart:143-150`, `test/app/app_test.dart:128-135`, `test/features/backup/data/cloud_backup_service_test.dart:72-81` · Test: `test/features/backup/data/connectivity_service_test.dart`

**Interfaces:** **Consumes** `supabaseUrl`/`supabaseAnonKey` (`supabase_config.dart:25`/`:33`), the `NominatimGeocodingService` injectable-client + `.timeout` + never-throws pattern (`geocoding_service.dart:52-56`, `:71`, `:87`), the `_FakeHttpClient extends BaseClient` shape (`geocoding_service_test.dart:13-29`), `package:http/http.dart` (already a direct dep). **Produces** `ConnectivityService.isBackendReachable()`; the top-level `classifyConnectivityResults(List<ConnectivityResult>)` (decision #3); `SystemConnectivityService([Connectivity?, bool?, http.Client?])` + `probeUri` + `probeTimeout`; the four merged `ConnectivityService` fakes (decisions #4/#5).

- [ ] **Step 1: Rewrite test/features/backup/data/connectivity_service_test.dart, keeping both existing tests verbatim and appending the probe group.**

  ```dart
  import 'dart:async';
  import 'dart:convert';

  import 'package:masi/core/config/supabase_config.dart';
  import 'package:masi/features/backup/data/connectivity_service.dart';
  import 'package:flutter_test/flutter_test.dart';
  import 'package:http/http.dart'
      show BaseClient, BaseRequest, ClientException, StreamedResponse;

  /// A fake [BaseClient] that resolves every request synchronously to a
  /// scripted status (or throws [throwOn]) — never touches real DNS/sockets,
  /// mirroring `geocoding_service_test.dart`'s identically-shaped
  /// `_FakeHttpClient`. [lastRequest] lets tests assert on the exact URL and
  /// headers the probe sent.
  class _FakeHttpClient extends BaseClient {
    _FakeHttpClient({this.statusCode = 200, this.throwOn});

    final int statusCode;
    final Object? throwOn;

    BaseRequest? lastRequest;
    int sendCount = 0;

    @override
    Future<StreamedResponse> send(BaseRequest request) async {
      lastRequest = request;
      sendCount++;
      final throwable = throwOn;
      if (throwable != null) throw throwable;
      return StreamedResponse(Stream.value(utf8.encode('{}')), statusCode);
    }
  }

  /// Web port Phase 4 (auth + sync on web), task 4:
  /// `connectivity_plus`'s web implementation can only report online/offline
  /// (no wifi-vs-cellular distinction exists in a browser -- see
  /// WEB_PORT_BRIEF.md ss2), and gating the `wifiOnly` upload gate on an
  /// unreliable web signal would silently strand backups in the `offline`
  /// status forever. [SystemConnectivityService.currentStatus] must
  /// short-circuit to [NetworkStatus.wifi] on web, before ever touching the
  /// real `Connectivity()` platform channel (which `flutter_test`'s VM target
  /// can't service anyway).
  void main() {
    group('SystemConnectivityService web short-circuit', () {
      test(
        'currentStatus() returns wifi on web without ever calling the real '
        'Connectivity() plugin (constructing with isWeb: true and no plugin '
        'instance still resolves -- proving the platform channel is never '
        'touched)',
        () async {
          final service = SystemConnectivityService(null, true);
          expect(await service.currentStatus(), NetworkStatus.wifi);
        },
      );

      test(
        'defaults (isWeb omitted) fall back to the real kIsWeb, which is '
        'false under flutter test\'s VM target',
        () {
          // Constructing with the real Connectivity() plugin and no isWeb
          // override must not throw merely by existing (checkConnectivity()
          // itself is exercised elsewhere/on-device, not here -- this only
          // proves the constructor's default doesn't force the web branch).
          final service = SystemConnectivityService();
          expect(service, isNotNull);
        },
      );
    });

    group('§1d (S4): isBackendReachable — the real reachability probe', () {
      test(
        'a 2xx response means reachable, and the probe hits '
        '<supabaseUrl>/auth/v1/health carrying the publishable apikey',
        () async {
          final client = _FakeHttpClient();
          final service = SystemConnectivityService(null, null, client);

          expect(await service.isBackendReachable(), isTrue);

          final request = client.lastRequest;
          expect(request, isNotNull);
          expect(request!.method, 'GET');
          expect(request.url, SystemConnectivityService.probeUri);
          expect(request.url.toString(), '$supabaseUrl/auth/v1/health');
          expect(request.headers['apikey'], supabaseAnonKey);
        },
      );

      test(
        'a 5xx (or any other) HTTP response ALSO means reachable — the origin '
        'answered, which is precisely what this probe asks. Only a transport '
        'failure means offline; treating a 500 as offline would mislabel a '
        'backend outage as "you have no connection"',
        () async {
          final service = SystemConnectivityService(
            null,
            null,
            _FakeHttpClient(statusCode: 503),
          );

          expect(await service.isBackendReachable(), isTrue);
        },
      );

      test('a 401 also means reachable (reachable-but-not-authenticated)', () async {
        final service = SystemConnectivityService(
          null,
          null,
          _FakeHttpClient(statusCode: 401),
        );

        expect(await service.isBackendReachable(), isTrue);
      });

      test(
        'a transport failure (ClientException — how a failed browser fetch() '
        'surfaces through package:http) means NOT reachable',
        () async {
          final service = SystemConnectivityService(
            null,
            null,
            _FakeHttpClient(throwOn: ClientException('Failed to fetch')),
          );

          expect(await service.isBackendReachable(), isFalse);
        },
      );

      test('a timeout means NOT reachable, and never propagates', () async {
        final service = SystemConnectivityService(
          null,
          null,
          _FakeHttpClient(throwOn: TimeoutException('too slow')),
        );

        expect(await service.isBackendReachable(), isFalse);
      });

      test(
        'the probe runs on WEB too — the isWeb short-circuit that makes '
        'currentStatus() report wifi unconditionally must NOT leak into it, '
        'because that unconditional wifi is exactly why SyncStatus.offline was '
        'unreachable in production (S4)',
        () async {
          final client = _FakeHttpClient();
          final service = SystemConnectivityService(null, true, client);

          expect(await service.currentStatus(), NetworkStatus.wifi);
          expect(await service.isBackendReachable(), isTrue);
          expect(
            client.sendCount,
            1,
            reason: 'the probe really issued a request on the web path',
          );
        },
      );

      test('the probe is bounded by a 5s timeout', () {
        expect(
          SystemConnectivityService.probeTimeout,
          const Duration(seconds: 5),
        );
      });
    });
  }
  ```

- [ ] **Step 2: Run the file and watch it FAIL to compile (no `isBackendReachable`, no `probeUri`, no `probeTimeout`, and no third constructor param).**

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/backup/data/connectivity_service_test.dart
  ```

  Expected: Compile error: The method 'isBackendReachable' isn't defined for the type 'SystemConnectivityService'.

- [ ] **Step 3: Rewrite lib/features/backup/data/connectivity_service.dart — new imports, the seam's new member, and the probe. `NetworkStatus` (:7-19) and `currentStatus()`'s body (:44-66) are unchanged.**

  > Corrected (**D-9** — the raw block had three elisions (`// ... enum NetworkStatus unchanged (lines 4-19) ...` and a `currentStatus()` whose whole body was a comment) and would not have compiled. This is the **real, complete file**: `NetworkStatus` preserved verbatim from `connectivity_service.dart:4-19`, the web short-circuit's 8-line rationale comment preserved verbatim from `:45-52`, and `currentStatus()` delegating to the top-level `classifyConnectivityResults(List<ConnectivityResult>)` (reconciliation decision #3). The extraction is performed HERE rather than in §1e because §1d rewrites this file first and must leave it compiling; §1e T7 then only adds `statusChanges()` and the `online_events.dart` import.)

  ```dart
  import 'package:connectivity_plus/connectivity_plus.dart';
  import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
  import 'package:http/http.dart' as http;

  import '../../../core/config/supabase_config.dart';

  /// Coarse network status the backup engine cares about — collapses
  /// `connectivity_plus`'s finer-grained [ConnectivityResult] list into just
  /// what `wifiOnly` gating needs to decide.
  enum NetworkStatus {
    /// Wifi or ethernet — "unmetered enough" to upload on.
    wifi,

    /// Cellular data only.
    cellular,

    /// No network reachable at all.
    none,

    /// Some other/unclassified transport (e.g. bluetooth, vpn-only).
    other,
  }

  /// Seam over `connectivity_plus`'s platform plugin so tests can force a
  /// status (wifi/cellular/none) without a real platform channel. Mirrors the
  /// `AuthRepository`/`BackupRemote` injectable-abstraction pattern used
  /// elsewhere in this feature.
  abstract class ConnectivityService {
    Future<NetworkStatus> currentStatus();

    /// True when the app can actually reach its backend RIGHT NOW, proven by a
    /// cheap round trip rather than inferred from the network interface.
    ///
    /// S4 fix (§1d): [currentStatus] is INTERFACE state only. It reports
    /// "connected" behind a captive portal, on a wifi network with no route,
    /// and — on web — returns [NetworkStatus.wifi] unconditionally (a browser
    /// cannot distinguish transports at all). `SyncStatus.offline` was
    /// therefore only ever producible by the `wifiOnly` skip, which is off by
    /// default and has no UI, i.e. it was unreachable in production. This is
    /// the signal that makes it both reachable and truthful.
    ///
    /// Never throws: any transport error, non-response or timeout resolves to
    /// `false`, mirroring `NominatimGeocodingService.search`'s best-effort
    /// never-throws contract.
    Future<bool> isBackendReachable();
  }

  /// Collapses `connectivity_plus`'s finer-grained [ConnectivityResult] list
  /// into this app's [NetworkStatus].
  ///
  /// Lifted verbatim out of [SystemConnectivityService.currentStatus]'s former
  /// inline if-chain; top-level (rather than a private method) purely so the
  /// mapping is directly unit-testable without a platform channel. §1e T7
  /// additionally shares it with `statusChanges()`, so a one-shot read and a
  /// stream event can never disagree — the extraction lands HERE rather than
  /// in §1e (reconciliation decision #3) only because §1d rewrites this file
  /// first and every fragment must emit a complete, compiling file.
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

  /// Real [ConnectivityService], backed by `connectivity_plus` (for
  /// [currentStatus]) and a plain HTTP GET against the app's own Supabase
  /// origin (for [isBackendReachable]).
  class SystemConnectivityService implements ConnectivityService {
    SystemConnectivityService([
      Connectivity? connectivity,
      bool? isWeb,
      http.Client? httpClient,
    ]) : _connectivity = connectivity ?? Connectivity(),
         _isWeb = isWeb ?? kIsWeb,
         _httpClient = httpClient;

    final Connectivity _connectivity;

    /// Defaults to the real compile-time [kIsWeb] — only overridable (via the
    /// constructor's `isWeb` positional arg) so a unit test can exercise the
    /// web short-circuit below without a real browser test runner, mirroring
    /// `photo_source_sheet.dart`'s `showCameraOption` seam.
    ///
    /// Deliberately consulted ONLY by [currentStatus]: [isBackendReachable]
    /// behaves identically on every platform (S4).
    final bool _isWeb;

    /// Injected in tests (a fake `BaseClient`); `null` in production, where a
    /// plain `http.Client()` is created per probe and closed again — a probe
    /// happens at most once per failed sync, so there is nothing worth keeping
    /// open. Mirrors `NominatimGeocodingService`'s injectable-client seam.
    final http.Client? _httpClient;

    /// Bound on the probe. Long enough to survive a slow mobile round trip,
    /// short enough that a failed sync classifies itself promptly.
    @visibleForTesting
    static const Duration probeTimeout = Duration(seconds: 5);

    /// GoTrue's unauthenticated health endpoint on the app's OWN Supabase
    /// origin — the cheapest request that proves this backend answered.
    /// Deliberately not a third-party captive-portal-detection URL: what
    /// matters is whether the origin the sync engine talks to is reachable,
    /// not whether the internet at large is.
    @visibleForTesting
    static Uri get probeUri {
      final base = supabaseUrl.endsWith('/')
          ? supabaseUrl.substring(0, supabaseUrl.length - 1)
          : supabaseUrl;
      return Uri.parse('$base/auth/v1/health');
    }

    @override
    Future<bool> isBackendReachable() async {
      final client = _httpClient ?? http.Client();
      try {
        // The publishable/anon key is sent so the request is accepted by the
        // API gateway regardless of route policy; it is the same key the app
        // already ships (see supabase_config.dart) and carries no privilege.
        await client
            .get(probeUri, headers: const {'apikey': supabaseAnonKey})
            .timeout(probeTimeout);
        // ANY HTTP response at all — 2xx, 401, 404, 503 — proves the origin
        // answered, which is exactly what "reachable" means here. Only a
        // transport failure or a timeout lands in the catch below.
        return true;
      } catch (_) {
        return false;
      } finally {
        // Only close what this method created; an injected client belongs to
        // the caller.
        if (_httpClient == null) client.close();
      }
    }

    @override
    Future<NetworkStatus> currentStatus() async {
      // `connectivity_plus`'s web implementation can only report
      // online/offline (no wifi-vs-cellular distinction exists in a browser —
      // see WEB_PORT_BRIEF.md §2) and its exact online mapping varies by
      // browser, so treat any web session as [NetworkStatus.wifi]
      // unconditionally: the `wifiOnly` upload gate exists to avoid burning a
      // user's cellular data plan, a concept that doesn't apply to a desktop/
      // laptop browser tab, and gating web uploads on an unreliable signal
      // would silently strand backups in [SyncStatus.offline] forever.
      if (_isWeb) return NetworkStatus.wifi;
      return classifyConnectivityResults(await _connectivity.checkConnectivity());
    }
  }
  ```

- [ ] **Step 4: Add `isBackendReachable` to `FakeConnectivityService` in test/features/backup/data/sync_service_test.dart (replace lines 274-283).**

  > Corrected (**Decisions #4/#5** — merged union of §1d's and §1e's additions, written ONCE here. `statusChanges()` intentionally carries no `@override`: the abstract class does not declare it until §1e T7, and `override_on_non_overriding_member` would fail `flutter analyze`.)

  ```dart
  /// In-memory [ConnectivityService] test double: reports whatever [status]
  /// is currently set to (no `connectivity_plus` platform channel), and
  /// whatever [reachable] is set to for the §1d reachability probe (no real
  /// HTTP request).
  class FakeConnectivityService implements ConnectivityService {
    FakeConnectivityService(this.status, {this.reachable = true});

    NetworkStatus status;
    bool reachable;

    @override
    Future<NetworkStatus> currentStatus() async => status;

    @override
    Future<bool> isBackendReachable() async => reachable;

    /// §1e's second seam member, written here as part of the ONE merged
    /// rewrite of this class (reconciliation decision #5). No `@override`
    /// yet: `ConnectivityService` does not declare `statusChanges()` until
    /// §1e T7, and annotating a non-overriding member is an analyzer error.
    /// §1e T7's only remaining job on this class is to add that annotation.
    Stream<NetworkStatus> statusChanges() => const Stream<NetworkStatus>.empty();
  }
  ```

- [ ] **Step 5: Add the probe members to `_FakeConnectivityService` in test/features/backup/application/sync_orchestrator_test.dart (replace lines 143-150).**

  > Corrected (**Decision #4** — merged union: §1d's `reachable`/`probeThrows`/`probeCallCount` **and** §1e's broadcast controller + `statusChanges()`/`emit()`/`dispose()`. Requires `dart:async`, already imported at `sync_orchestrator_test.dart:1`.)

  ```dart
  class _FakeConnectivityService implements ConnectivityService {
    _FakeConnectivityService(
      this.status, {
      this.reachable = true,
      this.probeThrows = false,
    });

    NetworkStatus status;

    /// What [isBackendReachable] reports — the ONLY signal allowed to produce
    /// `SyncStatus.offline` for a failed push (S4).
    bool reachable;

    /// When true, [isBackendReachable] throws instead of answering: a broken
    /// probe must degrade to "reachable" and never masquerade as offline.
    bool probeThrows;

    int probeCallCount = 0;

    /// §1e's connectivity-change seam, written here as part of the ONE merged
    /// rewrite of this class (reconciliation decision #4). Broadcast so more
    /// than one subscriber (orchestrator + assertion) can listen.
    final _statusController = StreamController<NetworkStatus>.broadcast();

    @override
    Future<NetworkStatus> currentStatus() async => status;

    @override
    Future<bool> isBackendReachable() async {
      probeCallCount++;
      if (probeThrows) throw Exception('probe-boom');
      return reachable;
    }

    /// No `@override` yet: `ConnectivityService` does not declare
    /// `statusChanges()` until §1e T7, and annotating a non-overriding member
    /// is an analyzer error. §1e T7 adds the annotation and nothing else.
    Stream<NetworkStatus> statusChanges() => _statusController.stream;

    /// Drives a connectivity transition from a test (§1e).
    void emit(NetworkStatus next) {
      status = next;
      _statusController.add(next);
    }

    void dispose() => _statusController.close();
  }
  ```

- [ ] **Step 6: Add the member to `_FakeConnectivityService` in test/app/app_test.dart (replace lines 128-135).**

  > Corrected (**Decision #5** — merged union.)

  ```dart
  /// Always-wifi, always-reachable [ConnectivityService] double — duplicated
  /// locally from `sync_orchestrator_test.dart`'s identically-named class.
  /// [SyncService]'s constructor requires one even though
  /// `pullOwnAndShared()` (the only path this file's #57 test exercises) never
  /// reads it; [isBackendReachable] exists so no widget test can ever fall
  /// through to the real `SystemConnectivityService` and issue a live HTTP
  /// probe.
  class _FakeConnectivityService implements ConnectivityService {
    @override
    Future<NetworkStatus> currentStatus() async => NetworkStatus.wifi;

    @override
    Future<bool> isBackendReachable() async => true;

    /// §1e's second seam member, written here as part of the ONE merged
    /// rewrite (reconciliation decision #5). An inert stream is exactly right
    /// for a widget test: §1e T8 makes `SyncOrchestrator.build()`
    /// unconditionally `statusChanges().listen(...)`, and "never emits" means
    /// "no transitions", never an error. No `@override` until §1e T7 declares
    /// the abstract member.
    Stream<NetworkStatus> statusChanges() => const Stream<NetworkStatus>.empty();
  }
  ```

- [ ] **Step 7: Add the member to `FakeConnectivityService` in test/features/backup/data/cloud_backup_service_test.dart (replace lines 72-81).**

  > Corrected (**Decision #5** — merged union.)

  ```dart
  /// In-memory [ConnectivityService] test double: reports whatever
  /// [status] is currently set to (no `connectivity_plus` platform channel).
  /// [isBackendReachable] is unused by [CloudBackupService] and exists only to
  /// satisfy the seam (§1d added it for the sync engine's offline detection).
  class FakeConnectivityService implements ConnectivityService {
    FakeConnectivityService(this.status);

    NetworkStatus status;

    @override
    Future<NetworkStatus> currentStatus() async => status;

    @override
    Future<bool> isBackendReachable() async => true;

    /// §1e's second seam member, written here as part of the ONE merged
    /// rewrite (reconciliation decision #5). No `@override` until §1e T7
    /// declares the abstract member.
    Stream<NetworkStatus> statusChanges() => const Stream<NetworkStatus>.empty();
  }
  ```

- [ ] **Step 8: Run the touched test files and see them pass.**

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/backup/ test/app/app_test.dart
  ```

  Expected: `All tests passed!` (7 new probe tests included.)

- [ ] **Step 9: Confirm the whole project analyses clean, the full suite is green, and no dart:io crept into lib.**

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter analyze && flutter test && (grep -r "dart:io" lib --include="*.dart" | grep -v _native.dart; echo "grep-gate-exit:$?")
  ```

  Expected: `No issues found!`, `flutter test` green at **baseline + 7** for this task, and the grep gate prints no file matches (exit 1 from grep = empty).

**Assertions:**

- [ ] `grep -rn "isBackendReachable" lib test | wc -l` shows the seam declaration, the `SystemConnectivityService` implementation, and exactly four test-fake implementations (sync_service_test, sync_orchestrator_test, app_test, cloud_backup_service_test) — all moved in one commit.
- [ ] The probe issues `GET <supabaseUrl>/auth/v1/health` with an `apikey` header equal to `supabaseAnonKey`; asserted against `SystemConnectivityService.probeUri`.
- [ ] A 200, a 401 and a 503 all return `true`; a `ClientException` and a `TimeoutException` both return `false` and neither propagates.
- [ ] With `isWeb: true`, `currentStatus()` still returns `wifi` (unchanged) while `isBackendReachable()` still performs exactly one request (`sendCount == 1`) — the web short-circuit does not leak into the probe.
- [ ] `SystemConnectivityService.probeTimeout == const Duration(seconds: 5)`.
- [ ] The grep gate `grep -r "dart:io" lib --include="*.dart" | grep -v _native.dart` is still empty; the only new import is `package:http/http.dart` (already a direct pubspec dep).
- [ ] `flutter analyze` = 0 issues; `flutter test` green at **baseline + 7 for this task** (D-13).
- [ ] `lib/features/backup/data/connectivity_service.dart` contains no elision comment; `NetworkStatus` is byte-identical to its pre-task text; `currentStatus()`'s web short-circuit comment is byte-identical; `currentStatus()`'s body is `if (_isWeb) return NetworkStatus.wifi;` followed by a single delegation to `classifyConnectivityResults` (D-9 / decision #3).
- [ ] All four `ConnectivityService` fakes carry BOTH `isBackendReachable()` and `statusChanges()`; none of the `statusChanges()` members carries `@override` (decisions #4/#5). `grep -rn 'statusChanges' test | wc -l` shows four implementations.
- [ ] The `/auth/v1/health` COEP question is recorded as an open ship gate (D-22) — this task does not close it.

**Commit:** `feat(sync): add a real Supabase reachability probe to ConnectivityService`

> Every commit ends with the trailer `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

---

### Task 7: a failed push classifies itself as `offline` vs `error` using the probe (S4 end-to-end)

**Files:** Create: — · Modify: `lib/features/backup/application/sync_orchestrator.dart:1-30`, `lib/features/backup/application/sync_orchestrator.dart:204-246`, `test/features/backup/application/sync_orchestrator_test.dart:175-207`, `test/features/backup/application/sync_orchestrator_test.dart:689-711`, `test/app/app_test.dart:421-431` · Test: `test/features/backup/application/sync_orchestrator_test.dart`

**Interfaces:** **Consumes** `isBackendReachable` (T6), the merged `_FakeConnectivityService` (T6), the `_runPush` shape (T5), `connectivityServiceProvider` (`backup_providers.dart:35`), the inline `status transitions` container (`sync_orchestrator_test.dart:689-711`), all four `app_test.dart` containers (`:148`, `:318`, `:401`, `:493`). **Produces** `SyncOrchestrator._failedPushStatus()`; a corrected `SyncStatus.offline` doc; `makeContainer({..., _FakeConnectivityService? connectivityService})` + its `connectivityServiceProvider` override, written **once** here (decision #6); `connectivityServiceProvider` overrides in all four `app_test.dart` containers (D-6).

- [ ] **Step 1: Make the fake connectivity service reachable from tests and override `connectivityServiceProvider` in the orchestrator test's `makeContainer` (replace lines 175-207).**

  ```dart
    ProviderContainer makeContainer({
      required AppDatabase db,
      required SyncRemote remote,
      required AuthRepository syncServiceAuth,
      Stream<AuthSessionState>? authStream,
      Duration debounce = const Duration(milliseconds: 25),
      bool wifiOnly = false,
      NetworkStatus connectivity = NetworkStatus.wifi,
      _FakeConnectivityService? connectivityService,
      int Function()? nowMs,
    }) {
      final connectivityFake =
          connectivityService ?? _FakeConnectivityService(connectivity);
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          syncDebounceDurationProvider.overrideWithValue(debounce),
          if (nowMs != null) nowMsProvider.overrideWithValue(nowMs),
          authStateProvider.overrideWith(
            (ref) => authStream ?? Stream.value(const AuthSessionState.signedOut()),
          ),
          // §1d/S4: SyncOrchestrator probes real backend reachability to choose
          // between `error` and `offline` for a failed push. Without this
          // override the REAL SystemConnectivityService would be constructed
          // and would issue a live HTTP request from a unit test.
          connectivityServiceProvider.overrideWithValue(connectivityFake),
          syncServiceProvider.overrideWithValue(
            SyncService(
              db: db,
              backupRepository: BackupRepository(db),
              remote: remote,
              authRepository: syncServiceAuth,
              connectivity: connectivityFake,
              wifiOnly: wifiOnly ? () => true : null,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }
  ```

- [ ] **Step 2: Add the import needed for `connectivityServiceProvider` to test/features/backup/application/sync_orchestrator_test.dart.**

  > Corrected (Import position corrected — alphabetical within the `package:masi/...` block.)

  ```dart
  // test/features/backup/application/sync_orchestrator_test.dart — insert into
  // the `package:masi/...` block so it stays alphabetical, i.e. BEFORE the
  // existing `sync_orchestrator.dart` import at :7 (not after
  // `sync_providers.dart`, which the raw fragment said):
  import 'package:masi/features/backup/application/backup_providers.dart';
  ```

- [ ] **Step 3: Also add the same override to the inline container in the `status transitions` group (test/features/backup/application/sync_orchestrator_test.dart:689-711), right after the `authStateProvider.overrideWith(...)` entry.**

  ```dart
              connectivityServiceProvider.overrideWithValue(
                _FakeConnectivityService(NetworkStatus.wifi),
              ),
  ```

- [ ] **Step 4: Add the S4 classification group at the END of `main()` in test/features/backup/application/sync_orchestrator_test.dart.**

  ```dart
    group('§1d (S4): SyncStatus.offline comes from a real reachability probe', () {
      /// One failed-push run, returning the state it settled on plus the
      /// connectivity fake so the probe can be inspected.
      Future<({SyncOrchestratorState state, _FakeConnectivityService connectivity})>
      runFailedPush({
        bool reachable = true,
        bool probeThrows = false,
        SyncRemote? remote,
      }) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final connectivity = _FakeConnectivityService(
          // Deliberately wifi: connectivity_plus says "connected" behind a
          // captive portal and reports wifi unconditionally on web, so the
          // interface state must NOT be what decides this.
          NetworkStatus.wifi,
          reachable: reachable,
          probeThrows: probeThrows,
        );
        final container = makeContainer(
          db: db,
          remote: remote ?? _FailingPushSyncRemote(),
          syncServiceAuth: _FakeAuthRepository(
            const AuthSessionState.signedIn('u1@example.com', uid: 'u1'),
          ),
          connectivityService: connectivity,
          debounce: const Duration(milliseconds: 15),
        );

        primeOrchestrator(container);
        await Future<void>.delayed(const Duration(milliseconds: 5));

        await insertArea(db, 'a1', ownerId: 'u1');
        await Future<void>.delayed(const Duration(milliseconds: 80));

        return (
          state: container.read(syncOrchestratorProvider),
          connectivity: connectivity,
        );
      }

      test(
        'a failed push with the backend UNREACHABLE reports offline — even '
        'though connectivity_plus reports wifi, which is exactly the captive-'
        'portal / web case that made SyncStatus.offline unreachable before',
        () async {
          final result = await runFailedPush(reachable: false);

          expect(result.state.status, SyncStatus.offline);
          expect(result.state.lastPushError, isNotNull);
          expect(result.state.lastSyncedAt, isNull);
          expect(result.connectivity.probeCallCount, 1);
        },
      );

      test(
        'the SAME failed push with the backend REACHABLE (reachable-but-not-'
        'authenticated, e.g. an expired JWT) reports error, NOT offline — the '
        'two conditions are distinguishable',
        () async {
          final result = await runFailedPush(reachable: true);

          expect(result.state.status, SyncStatus.error);
          expect(result.connectivity.probeCallCount, 1);
        },
      );

      test(
        'a probe that itself throws degrades to error — a broken probe must '
        'never let a genuine backend error masquerade as "you are offline"',
        () async {
          final result = await runFailedPush(probeThrows: true);

          expect(result.state.status, SyncStatus.error);
        },
      );

      test(
        'a SUCCESSFUL push never probes at all — no extra round trip on the '
        'happy path',
        () async {
          final result = await runFailedPush(remote: _CountingSyncRemote());

          expect(result.state.status, SyncStatus.idle);
          expect(result.state.lastPushError, isNull);
          expect(result.connectivity.probeCallCount, 0);
        },
      );
    });
  ```

- [ ] **Step 5: Run the file and watch the first three new tests FAIL (`_runPush` currently hard-codes `SyncStatus.error`, so `offline` never appears and the probe is never called).**

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/backup/application/sync_orchestrator_test.dart
  ```

  Expected: Expected: <SyncStatus.offline> Actual: <SyncStatus.error>; and probeCallCount 0 instead of 1.

- [ ] **Step 6: Add the `backup_providers.dart` import to lib/features/backup/application/sync_orchestrator.dart.**

  > Corrected (Import position corrected — the relative-import block in `sync_orchestrator.dart` is alphabetical, so `backup_providers.dart` goes before `sync_providers.dart`, not after it.)

  ```dart
  // lib/features/backup/application/sync_orchestrator.dart — the relative
  // imports are alphabetical, so this goes BEFORE `sync_providers.dart`
  // (i.e. immediately after `../data/sync_service.dart` at :9), not after it
  // as the raw fragment said:
  import 'backup_providers.dart';
  ```

- [ ] **Step 7: Correct `SyncStatus.offline`'s doc in lib/features/backup/application/sync_orchestrator.dart (replace lines **26-29** — the raw fragment said 25-29, but :25 is the blank separator line after `error,` and must survive).**

  ```dart
    /// The device could not reach the backend. Produced EITHER by a real
    /// reachability probe ([ConnectivityService.isBackendReachable]) coming
    /// back false after a push that didn't land, OR by the `wifiOnly` skip
    /// (see `wifiOnlySettingProvider`).
    ///
    /// S4 fix (§1d): the `wifiOnly` skip used to be the ONLY producer — and
    /// it is off by default with no UI, and `connectivity_plus` reports
    /// interface state only (wifi unconditionally on web), so this status was
    /// unreachable in production and the Account screen's "Offline" label
    /// could never render.
    offline,
  ```

- [ ] **Step 8: Replace the two hard-coded `SyncStatus.error` failure statuses in `_runPush` with `await _failedPushStatus()` and add the helper right after `_runPush`.**

  ```dart
            } else {
              state = SyncOrchestratorState(
                status: await _failedPushStatus(),
                lastSyncedAt: state.lastSyncedAt,
                lastPullError: state.lastPullError,
                lastPushError:
                    'Sync failed: ${result.rowsFailed} change(s) not uploaded — '
                    '${result.errors.join('; ')}',
              );
            }
          case SyncPushOutcome.skippedSignedOut:
            state = state.copyWith(status: SyncStatus.idle);
          case SyncPushOutcome.skippedNotWifi:
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
      }
    }

    /// Whether a push that failed did so because THE BACKEND IS UNREACHABLE
    /// ([SyncStatus.offline]) or for some other reason ([SyncStatus.error]).
    ///
    /// S4 fix (§1d): `connectivity_plus` reports INTERFACE state only — it
    /// answers "connected" behind a captive portal and its web implementation
    /// returns wifi unconditionally — so `currentStatus()` can never be the
    /// signal here. [ConnectivityService.isBackendReachable] does a real round
    /// trip to the Supabase origin instead. Called ONLY on the failure path,
    /// so a healthy push costs no extra request.
    ///
    /// A probe that itself throws is treated as REACHABLE: a broken probe must
    /// never let a genuine backend error masquerade as "you're offline".
    Future<SyncStatus> _failedPushStatus() async {
      try {
        final reachable = await ref
            .read(connectivityServiceProvider)
            .isBackendReachable();
        return reachable ? SyncStatus.error : SyncStatus.offline;
      } catch (e) {
        debugPrint('SyncOrchestrator: reachability probe failed: $e');
        return SyncStatus.error;
      }
    }
  ```

- [ ] **Step 9: Add the defensive `connectivityServiceProvider` override to **all four** containers in test/app/app_test.dart, and import `backup_providers.dart`.**

  > Corrected (**D-6** — the raw fragment overrode only the two "#57" containers. All FOUR containers in `app_test.dart` mount `MasiApp` and need the override. Line `:506` also drifted to `:505`.)

  ```dart
  // test/app/app_test.dart — 1. the import, inserted alphabetically into the
  // `package:masi/...` block, i.e. BEFORE `sync_orchestrator.dart` at :9:
  import 'package:masi/features/backup/application/backup_providers.dart';

  // 2. ALL FOUR containers get the override (reconciliation D-6). Every one of
  //    them mounts `MasiApp`; without the override each constructs the real
  //    `SystemConnectivityService`. Benign under §1d alone (signed-out ⇒
  //    `skippedSignedOut`, the probe is never reached) but FATAL under §1e
  //    T8's unconditional `statusChanges().listen(...)` in
  //    `SyncOrchestrator.build()`.
  //
  // 2a. `_makeContainer()` (:146; its `ProviderContainer(` is :148) — append as
  //     the LAST entry of the overrides list, after
  //     `syncDebounceDurationProvider.overrideWithValue(...)`:
        connectivityServiceProvider.overrideWithValue(
          _FakeConnectivityService(),
        ),

  // 2b. the inline container in `group('MasiApp claim-on-sign-in bootstrap
  //     (C3)')` (:318) — same position, last entry of the overrides list:
              connectivityServiceProvider.overrideWithValue(
                _FakeConnectivityService(),
              ),

  // 2c. the first "#57" container (:401) — immediately BEFORE
  //     `syncServiceProvider.overrideWithValue(` at :421:
              connectivityServiceProvider.overrideWithValue(
                _FakeConnectivityService(),
              ),

  // 2d. the second "#57" container (:493) — immediately BEFORE
  //     `syncServiceProvider.overrideWithValue(` at **:505** (the raw fragment
  //     said :506; verified against the real file, it is :505):
              connectivityServiceProvider.overrideWithValue(
                _FakeConnectivityService(),
              ),
  ```

- [ ] **Step 10: Re-run the orchestrator and app test files and see everything pass.**

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/backup/application/sync_orchestrator_test.dart test/app/app_test.dart
  ```

  Expected: All tests passed! — including the pre-existing wifiOnly test (:357-387) which still expects `SyncStatus.offline` from `skippedNotWifi`.

- [ ] **Step 11: Confirm the whole project analyses clean and the full suite is green.**

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter analyze && flutter test
  ```

  Expected: `No issues found!` and `flutter test` green at **baseline + 4** for this task.

**Assertions:**

- [ ] A failed push with `reachable: false` (while `currentStatus()` still reports `NetworkStatus.wifi`) produces `SyncStatus.offline`, a non-null `lastPushError`, a null `lastSyncedAt`, and exactly one probe call.
- [ ] The identical failed push with `reachable: true` produces `SyncStatus.error` — reachable-but-failing and unreachable are distinguishable.
- [ ] A probe that throws produces `SyncStatus.error`, never `offline`.
- [ ] A successful push produces `SyncStatus.idle` with `probeCallCount == 0` — no extra round trip on the happy path.
- [ ] The pre-existing `wifiOnly=true + cellular` test still yields `SyncStatus.offline` via `skippedNotWifi` — that producer is retained, not replaced.
- [ ] `connectivityServiceProvider` is overridden in every container in sync_orchestrator_test.dart and app_test.dart, so no unit/widget test can construct the real `SystemConnectivityService` and issue a live HTTP probe (`grep -c connectivityServiceProvider test/features/backup/application/sync_orchestrator_test.dart` >= 2).
- [ ] `flutter analyze` = 0 issues; `flutter test` green at **baseline + 4 for this task** (D-13).
- [ ] `connectivityServiceProvider` is overridden in **all four** `app_test.dart` containers (`:148`, `:318`, `:401`, `:493`): `grep -c connectivityServiceProvider test/app/app_test.dart` == 4 (D-6).
- [ ] `makeContainer` in `sync_orchestrator_test.dart` declares the `connectivityService` parameter exactly once (decision #6 — §1e T8 appends only `retrySchedule`).

**Commit:** `fix(sync): classify a failed push as offline vs error via a reachability probe`

> Every commit ends with the trailer `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

---

### Task 8: the `sync-status` label reports truthfully (no badge, D-2)

**Files:** Create: — · Modify: `lib/features/account/presentation/account_screen.dart:888-908`, `test/features/account/presentation/account_screen_test.dart:692-786` · Test: `test/features/account/presentation/account_screen_test.dart`

**Interfaces:** **Consumes** `SyncOrchestratorState.lastPushError` (T5), `_FixedSyncOrchestrator` (`account_screen_test.dart:28`), `_wrap` (`:142`), the `E1d: sync-status line` group's `makeContainer` (`:693`), the `Key('sync-status')` `Text` (`account_screen.dart:651-659`). **Produces** a `_syncStatusLabel` that never renders `'Synced • …'` for an `idle` state carrying a `lastPushError`. No new string, no badge, no new widget (D-2 scope decision).

- [ ] **Step 1: Add two tests at the END of the existing `group('E1d: sync-status line', ...)` in test/features/account/presentation/account_screen_test.dart (after the 'Not synced yet' test, which closes at **:786**, and before that group's `});` at **:787** — the raw fragment said :785/:786; verified against the real file, both are one line later).**

  ```dart
      testWidgets(
        'S1: an idle state carrying a lastPushError renders "Sync error", never '
        '"Synced • …" — a successful PULL legitimately produces idle + a fresh '
        'lastSyncedAt, but local changes that never reached the cloud must not '
        'read as synced',
        (tester) async {
          final container = makeContainer(
            SyncOrchestratorState(
              status: SyncStatus.idle,
              lastSyncedAt: DateTime.now(),
              lastPushError: 'Sync failed: 3 change(s) not uploaded — areas: …',
            ),
          );

          await tester.pumpWidget(_wrap(container, const AccountScreen()));
          await tester.pumpAndSettle();

          expect(find.byKey(const Key('sync-status')), findsOneWidget);
          expect(find.text('Sync error'), findsOneWidget);
          expect(
            find.textContaining('Synced'),
            findsNothing,
            reason: 'this is the exact S1 lie the label must no longer tell',
          );
        },
      );

      testWidgets(
        'a clean idle state (lastPushError null) still renders "Synced • …" — '
        'per D-2 nothing is added to this line, the lying case is just removed',
        (tester) async {
          final container = makeContainer(
            SyncOrchestratorState(
              status: SyncStatus.idle,
              lastSyncedAt: DateTime.now(),
            ),
          );

          await tester.pumpWidget(_wrap(container, const AccountScreen()));
          await tester.pumpAndSettle();

          expect(find.textContaining('Synced'), findsOneWidget);
          expect(find.text('Sync error'), findsNothing);
        },
      );
  ```

- [ ] **Step 2: Run the file and watch the first new test FAIL (the label still renders 'Synced • just now').**

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/account/presentation/account_screen_test.dart
  ```

  Expected: Expected: exactly one matching candidate for text "Sync error" — Actual: zero; and 'Synced • just now' was found.

- [ ] **Step 3: Update `_syncStatusLabel` in lib/features/account/presentation/account_screen.dart (replace lines 888-908).**

  ```dart
  /// The `sync-status` line's text for a given [SyncOrchestratorState] — the
  /// opportunistic-sync counterpart to the (unrelated) sign-in/sign-out
  /// status messages above. `idle` with no [SyncOrchestratorState.lastSyncedAt]
  /// covers both "never signed in a push/pull yet" and "signed out" (see
  /// `sync_orchestrator.dart`'s doc comment on why signed-out maps to `idle`
  /// rather than a distinct status — there's nothing to sync, which isn't an
  /// error or an offline condition).
  ///
  /// S1 fix (§1d): `idle` no longer implies everything reached the cloud, so
  /// [SyncOrchestratorState.lastPushError] is consulted before the "Synced"
  /// branch. Per D-2 no unsynced-count badge or new affordance is added here —
  /// this only stops the existing line from lying.
  String _syncStatusLabel(SyncOrchestratorState state) {
    switch (state.status) {
      case SyncStatus.syncing:
        return 'Syncing…';
      case SyncStatus.error:
        return 'Sync error';
      case SyncStatus.offline:
        return 'Offline';
      case SyncStatus.idle:
        // A push failure survives a later SUCCESSFUL pull (which legitimately
        // sets idle + a fresh lastSyncedAt — the pull really did work), so
        // without this check the line would read "Synced • just now" while the
        // user's own changes were still only on this device.
        if (state.lastPushError != null) return 'Sync error';
        final lastSyncedAt = state.lastSyncedAt;
        if (lastSyncedAt == null) return 'Not synced yet';
        return 'Synced • ${_relativeSyncTime(lastSyncedAt)}';
    }
  }
  ```

- [ ] **Step 4: Re-run the file and see it pass (all five pre-existing E1d tests included).**

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/account/presentation/account_screen_test.dart
  ```

  Expected: All tests passed!

- [ ] **Step 5: Confirm the whole project analyses clean and the full suite is green.**

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter analyze && flutter test
  ```

  Expected: `No issues found!` and `flutter test` green at **baseline + 2** for this task.

**Assertions:**

- [ ] An `idle` state with a non-null `lastSyncedAt` AND a non-null `lastPushError` renders `'Sync error'`, and no widget containing `'Synced'` is found.
- [ ] An `idle` state with a non-null `lastSyncedAt` and null `lastPushError` still renders `'Synced • …'` — the happy path is unchanged.
- [ ] The five pre-existing E1d tests ('Syncing…', 'Offline', 'Sync error', 'Synced • …', 'Not synced yet') all still pass.
- [ ] No new user-facing string was introduced: `git diff lib/features/account/presentation/account_screen.dart` adds only a reused `'Sync error'` return plus comments — no badge, no count, no new widget (D-2).
- [ ] `flutter analyze` = 0 issues; `flutter test` green at **baseline + 2 for this task** (D-13).
- [ ] The `E1d: sync-status line` group ends at `:787` after this task's insertion point, not `:786` — the raw fragment's line numbers were one short.

**Commit:** `fix(account): sync-status line stops reporting "Synced" after a failed push`

> Every commit ends with the trailer `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

---

## Risks & ship gates

- **`SupabaseSyncRemote.upsertOwnRows` has no automated coverage at all** (it needs a live `SupabaseClient`; there is no `sync_remote_test.dart` today and the one T1 creates covers only the pure helpers). Its new outcome-reporting contract is mirrored by `FakeSyncRemote` and must be reviewed by eye against the fake. A divergence between the two is invisible to the suite — this is the single highest-risk part of the workstream.
- On a caught per-table error the real remote reports `rowsFailed: rows.length`, not `survivors.length` — deliberately pessimistic, since the throw may have come from the LWW pre-check before any row was classified. This can over-report unsynced rows (e.g. rows the cloud already has a newer copy of). Over-reporting is safe; under-reporting is the S1 bug. §1e's `dirty`-based accounting will make this exact.
- `rowsPushed`'s MEANING changed (rows now known to be in the cloud, including LWW-skipped ones) while its NAME did not. The two historical assertions (`6` at sync_service_test.dart:473, `8` at :1171) still hold only because those remotes start empty. Any future test that pushes a stale row against a populated remote must reason about `rowsSkippedNewerRemote`.
- **The photo phase can still throw out of `pushOwn`** (`listPhotoObjectPaths`/`uploadPhoto`, sync_service.dart:371-409). §1d deliberately leaves that to §1f-3; until then such a failure surfaces as an orchestrator-level catch → `_failedPushStatus()` (so it is still classified honestly), but its `rowsFailed`/`errors` detail is lost. §1f must route the photo phase into the same `errors`/`rowsFailed` channel §1d creates rather than inventing a second one.
- `/auth/v1/health` is an implementation detail of Supabase's API gateway. If it ever stops routing, the probe still returns `true` (any HTTP response counts as reachable), so the failure mode is "we never say offline", not "we falsely say offline" — the safe direction. Still worth confirming once against the live project.
- **Web/COEP unknown:** the probe is a cross-origin `fetch` from a `require-corp` page. The app already talks to this origin from the web build, so it should be fine, but it must be confirmed on the deployed origin (add it to the Stage-1 `tool/drive_web.sh` pass); a blocked probe would report `false` and make the app permanently claim "Offline".
- One extra HTTP round trip per FAILED push. Harmless today (pushes are debounce- or pause-triggered) but §1e adds an unbounded retry loop — §1e must not probe again on top of this, or a long offline stretch turns into two requests per backoff tick.
- `SyncOrchestratorState` gained a fourth field; four other test files construct it (`topos_screen_test.dart:488`, `community_pull_refresh_test.dart:333`, `library_ui_intent_test.dart:75`, plus `account_screen_test.dart`). All use named args with defaults so they compile unchanged — but any of them asserting on `toString()` or state equality would need updating (none currently do).
- `lastPushError` is set but has no retry affordance anywhere (the pull side has one via `topos_screen.dart:255-264` / `community_feed_screen.dart:201`). That is intentional in §1d (the retry loop is §1e), so between §1d and §1e a user can see "Sync error" with no manual way to retry beyond making another edit or backgrounding the app.
- `SystemConnectivityService`'s constructor now takes THREE positional optionals (`connectivity`, `isWeb`, `httpClient`). Dart forbids mixing optional-positional with named params, so this had to stay positional; `SystemConnectivityService(null, null, client)` reads poorly and a future fourth seam should trigger a conversion of the whole constructor to named params (touching the two existing call sites in connectivity_service_test.dart).

### D-22 — the `/auth/v1/health` probe under COEP (ship gate, must be confirmed before shipping)

The probe is a **cross-origin `fetch` from a `require-corp` COEP page** (the web build sets
COOP/COEP as a hard hosting requirement for wasm + drift's OPFS worker). Under
`Cross-Origin-Embedder-Policy: require-corp`, a cross-origin response without a
`Cross-Origin-Resource-Policy: cross-origin` header — or without a CORS-mode fetch the browser is
happy with — is blocked. A blocked probe lands in `isBackendReachable`'s `catch (_) => false`, so
the classifier would return `SyncStatus.offline` for **every** failed push, and the Account screen
would permanently claim "Offline" on web even when the backend is perfectly healthy.

**Gate:** confirm on the *deployed* origin (`https://climb-masi.pages.dev`), not locally — add the
probe to the Stage-1 `tool/drive_web.sh` pass and assert it returns `true` while online. The app
already talks to this same Supabase origin from the web build, so it is expected to pass; expected
is not confirmed.

**Fallback, in order, if it is blocked:**

1. Route the probe through the transport the app already proves works from that page — issue it via
   the live `Supabase.instance.client` (e.g. a cheap unauthenticated GoTrue/PostgREST call) behind
   the same `isBackendReachable()` seam, keeping the injectable `http.Client` for native and for the
   unit tests. The seam, the tests and every caller are unchanged; only
   `SystemConnectivityService`'s body differs.
2. If that is also blocked, make the **web** path fail *open* — `_isWeb ? true : <probe>` — so a
   failed push degrades to `SyncStatus.error` ("Sync error"), never to a false permanent "Offline".
   This costs S4's offline/error distinction on web and must be recorded as known debt, but a
   truthful "Sync error" beats a false "Offline".
3. Do **not** silently keep a probe that can only ever return `false` on web. A permanent false
   "Offline" is a worse lie than the S1 lie this fragment removes.
