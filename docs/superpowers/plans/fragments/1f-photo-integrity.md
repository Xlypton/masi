# §1f — Photo integrity at full resolution (L3, S5, S6)

*Rendered from the §1f planner fragment (`raw/1f-photo-integrity.raw.json`) with every §1f-relevant correction from the Stage-1 reconciliation pass ([`reconciliation.md`](reconciliation.md)) and the master plan's [Blocking corrections](../2026-07-31-web-offline-stage1.md#blocking-corrections-that-override-the-fragments) applied inline. Every Dart/bash code block is preserved **byte-for-byte** from the source fragment except where a correction required a change — each of those is flagged with a `> Corrected (…)` line immediately above it.*

> ## This fragment spans TWO execution phases
> 
> It is **one workstream in name only**. The two halves share no file and land far apart in plan order:
> 
> | Half | Tasks | Phase | Touches |
> |---|---|---|---|
> | **Photo half** | Tasks 1–6 | **Phase 1** — runs early, alongside §1a/§1b | `lib/features/topo/data/**`, `lib/features/topo/presentation/**`, `lib/features/library/**` + their tests |
> | **Sync half** | Tasks 7–10 | **Phase 4** — strictly serial, LAST, on top of §1d *and* §1e | `lib/features/backup/**` (`sync_service.dart`, `sync_remote.dart`, `backup_remote.dart`, `sync_orchestrator.dart`), `test/features/backup/data/sync_service_test.dart`, `CLAUDE.md` |
> 
> **Do not start the sync half until §1d is fully landed and §1e is fully landed.** `sync_service.dart`, `sync_remote.dart`, `sync_orchestrator.dart` and `sync_service_test.dart` are the four highest-collision files in Stage 1: §1d owns the `PushSyncResult` shape and the `upsertOwnRows` signature this half extends, and §1e owns the `pushOwn` snapshot/dirty-scoping this half's reorder sits on top of.
> 
> **The one intra-Phase-1 ordering constraint: §1a's storage-interlock task (§1a Task 4) must land before this fragment's Task 6, "Wire the Topos-home New topo flow".** Both modify `lib/features/library/presentation/topos_screen.dart` and `test/features/library/presentation/topos_screen_test.dart` — §1a rewrites `_makeContainer`, `canCreate` and `_handleNewTopo`'s guards; §1f Task 6 then appends to all three. Per the repo rule that parallel implementers must be strictly file-disjoint, these two tasks cannot run concurrently.

## Reconciliation corrections applied

- **D-2 — `fullyLanded` must include `photosFailed`. This is the single highest-severity defect in the entire Stage-1 plan, and this fragment owns the fix.** §1d defines `bool get fullyLanded => didPush && rowsFailed == 0 && errors.isEmpty;` and the orchestrator uses it as the **sole** gate for reporting `SyncStatus.idle` and stamping a fresh `lastSyncedAt`. This fragment's Task 9 *withholds* a failed photo's row **from** `tablesToRows` — so that row never reaches `upsertOwnRows`, never fails, and leaves `rowsFailed` at `0` with `errors` empty. Consequence: a push in which **every single photo's bytes failed to upload** reports `fullyLanded == true` → *"Synced • just now"*. That is exactly the S1 lie the whole of §1d exists to kill, re-entering through the photo path. **Required fix, applied below in Task 8:** `bool get fullyLanded => didPush && rowsFailed == 0 && errors.isEmpty && photosFailed == 0;`, plus the orchestrator's `lastPushError` concatenating `errors + photoErrors`. `photosMissingLocalBytes` is **DELIBERATELY EXCLUDED** — it is non-retryable, and including it would pin the app outside `idle` forever and stop §1e's retry loop from ever terminating. Added as explicit Task 8 steps (the class amendment, two regression tests, the orchestrator patch) and as the **top-line assertion** of that task. The orchestrator edit is scoped to the `lastPushError` interpolation alone: cross-checked against §1e's converted fragment, whose own D-28 already arms `_scheduleRetry()` on that same branch and whose §1d inheritance already calls `await _failedPushStatus()` there.
  
  **The fragment demanded this fix and then wrote code that did the opposite.** Its own `sequencingNotes` state: *"§1f-3's 'retried through §1e's loop' is delivered as a SEAM only — `PushSyncResult.hasPhotoFailures` — which §1e must consume in `_runPush` (currently sync_orchestrator.dart:204-220, **which sets `idle` + a fresh `lastSyncedAt` on any `pushed` outcome**)"*, and its risk #5 calls that retry contract *"the single most important cross-workstream contract in this plan."* It identified the exact lie, named the exact line range — and then emitted a `PushSyncResult` whose `fullyLanded` it never touched, handing the fix to §1e, which never picks it up. A seam nobody consumes is not a fix. *(Reconciliation D-2 quotes the fragment as saying it "must not add a parallel `photosFailed`-only channel that the orchestrator does not read" — that exact sentence does **not** appear anywhere in the fragment; the two passages quoted above are the real ones. The conclusion is unchanged.)*

- **D-7 (blocking — the patch does not compile).** Task 9's `FakeSyncRemote.upsertOwnRows` patch replaced only the internal `for` loop, without restating the signature or §1d Task 2's `outcomes` accumulation and `return outcomes;`. Applied literally after §1d it yields a method declared `Future<List<TablePushOutcome>>` with **no return statement** — a hard compile error. **Rewritten below against the post-§1d body, showing the whole method**, with the one genuinely new line (`callLog.add('upsert:$tableName')`) in place.

- **D-4 (blocking — silent correctness bug).** Task 9 derived `wallVisibility` as `{for (final wall in walls) wall.id: wall.visibility}` over the **dirty-filtered** `walls` list. Under `PushScope.dirtyOnly` that silently stops uploading the shared copy of a new photo attached to an already-pushed — and therefore clean — shared wall, so that wall's viewers never see the new photo. **Corrected to consume §1e Task 4's `selectOnly` projection over ALL own walls**, read inside the snapshot transaction. The derivation is deleted, not rebuilt, in both Task 8's call site and Task 9's reorder.

- **D-5.** In Task 8's `PushSyncResult` block the two new field doc comments were **swapped** relative to their declarations — the "RETRYABLE …" doc sat above `final int photosMissingLocalBytes;` and the "NO local bytes …" doc above `final int photosFailed;`. The fragment flagged this in a follow-up step but left the defect in the code. **Each doc is now paired with its own field, and `photosFailed` is declared before `photosMissingLocalBytes`.** The follow-up step is rewritten into a verification step.

- **D-14.** Task 7 asserted that `grep -rn '\.list(' lib` returns **exactly two** call sites. **Grep run against the real tree: there are THREE** — `lib/features/backup/data/sync_remote.dart:638`, `sync_remote.dart:668`, and `lib/features/backup/data/backup_remote.dart:159`. Corrected in **both** places the count appears (Task 7's Step 8 `Expected:` line and Task 7's fourth assertion), and reframed so the assertion pins the invariant that actually matters — *zero un-paged listings* — rather than a number that the refactor itself changes. *Reconciliation claims "1f T10 repeats the same wrong count"; it does not — both occurrences are in T7.*

- **Decision #8 — one merged `PushSyncResult`, six new fields.** §1d adds `rowsFailed`/`errors`/`fullyLanded`; this fragment adds `photosFailed`/`photosMissingLocalBytes`/`photoErrors`/`hasPhotoFailures`. Task 8 below shows **one** class — §1d's, patched — not a competing second version. All new params are optional-with-defaults on `.pushed`, all are initialised in **both** `skipped*` constructors, and there is exactly **one** `toString()`, naming all seven fields.

- **Decision #12.** `_uploadOwnPhotos` becomes this fragment's `PhotoUploadOutcome` record, **superseding §1e Task 4's `Future<int>`**. §1e's call site (`final photosUploaded = await _uploadOwnPhotos(...)`) is rewritten by Task 8 below; §1e must land first.

- **Decision #14 — final composed `pushOwn` statement order.** snapshot (+ `wallVisibility` from §1e) → `_uploadOwnPhotos` → `pushablePhotos` filter → `tablesToRows` with dirty scoping **and** the required-field guard (§1d T4 + §1e T4) → `upsertOwnRows` (§1d T2) → §1e's dirty clear, **narrowed to the tables §1d reported as landed** (§1e's own D-25 — decision #14 writes it as a plain `_clearDirty(tablesToRows)`, which would mark failed-table rows clean; §1e's conversion narrows it and §1f must not un-narrow it) → merged result. §1e's stated rationale for clearing `dirty` after *both* phases is superseded rather than contradicted: with bytes first, a failed byte upload keeps the row out of `tablesToRows` entirely, so it stays dirty by construction. **Do not "restore" the old ordering.**

- **Decision #6 / duplication #6 — keep BOTH failure channels.** `errors`/`rowsFailed` (rows) and `photoErrors`/`photosFailed` (photo bytes) stay separate fields. They differ in **retryability**, which §1e's loop depends on; a single flattened list would make §1e retry forever on `photosMissingLocalBytes`. What *is* merged is the user-visible surface: `fullyLanded` reads both, and `lastPushError` concatenates both.

- **Decision #7 — `_makeContainer()` in `topos_screen_test.dart` is a union point with §1a.** Final signature, in this exact parameter order: `_makeContainer({LocationService?, SyncOrchestrator?, StorageDurability storageDurability = const StorageDurability.probing(), PhotoFiles? photoFiles})`. **§1a Task 4 writes `storageDurability` first; this fragment's Task 6 appends `photoFiles` only.** Task 6's code block is corrected to show the post-§1a union — the fragment's own block would have silently reverted §1a's parameter and its unconditional override.

- **Duplication #7 — `_writeThumbnailBestEffort` is deliberate symmetry, NOT a duplication to resolve.** Task 2 extracts a private `_writeThumbnailBestEffort` in the web backend; the native backend already has an identically-named private helper (verified at `lib/features/topo/data/photo_files_native.dart:119`). **Keep both names identical** — that is the point. Do not rename either, and do not try to share them (they take different arguments and sit on opposite sides of a conditional-export seam).

- **Duplication #8 — this fragment's final task (Task 10) OWNS the whole CLAUDE.md doc-correction block**, including two corrections that had **no owner anywhere in Stage 1**:
  1. **CLAUDE.md line 6 claims "outbox push/pull". There is no outbox** — `grep -rin outbox lib` returns zero hits, and the master plan's out-of-bounds section explicitly forbids building one (decision D-4). The engine is a debounced full-state re-push.
  2. **CLAUDE.md line 64 claims `integration_test/web_smoke_test.dart` proves "drift-on-WASM persistence through real IndexedDB". It contains zero `expect()` calls** — `grep -c 'expect(' integration_test/web_smoke_test.dart` prints `0`. It proves the app boots and the flow does not throw. A real write→reload→assert test is carried to Stage 2.
  3. **CLAUDE.md line 72's "~377 tests"** → the live baseline (**1586**, measured while writing this fragment).
  
  All three are explicit steps in Task 10, with the exact before/after text and the greps that prove them.

- **D-23 — keep the scripted fallback for the new `photo_byte_store_test.dart` case.** Writing into a DB whose object store was deliberately not created may simply *not reject* under `idb_shim`'s memory factory (it may auto-create, or the pre-opened DB may not be the one the store binds to). **If it does not reject, delete that one test rather than weakening it** — the injected-`_FailingWriteStore` tests in `photo_files_web_test.dart` carry the propagation contract, which is the assertion that actually matters. Kept as Task 2's Step 9 and restated inline there.

- **D-19 (recorded, no action — do not reject this at verify time).** Task 6's two new tests run the real `ui.instantiateImageCodec` inside `_handleNewTopo`. This is **acceptable** because the existing `A6: new-topo flow` group in the very same file already does exactly that (`tester.runAsync` for the file write, `_drain`/`_drainNoSettle` for the pumps). CLAUDE.md's "never drive a real image-codec decode in widget tests" prohibition targets **`TopoCanvas`'s** decode under the fake-async clock, and no canvas decode is introduced anywhere in this fragment. Task 4's SnackBar test correctly avoids `pumpAndSettle` for the same family of reasons.

- **D-13 — every absolute test-count assertion is restated as "baseline + N for this task".** The fragment was written assuming sole occupancy and cites `1576+` throughout. **The live baseline is now 1586, not 1576** — §1b tasks 1–2 have landed (`694e7f2`, `02b854b`), adding 10 tests. Measured directly while writing this document: `flutter test` → **`01:22 +1586: All tests passed!`**. Genuine per-file counts are kept, and corrected where they were wrong (see Task 2).

- **Icons.** Checked: **no `Icons.X` or `CupertinoIcons.X` appears in any code block in this fragment.** Task 4's SnackBar already uses `MasiIcon('warning', size: 18)`, mirroring `gpsCaptureResultSnackBar`'s `MasiIcon('pin', size: 18)` (`lib/features/topo/presentation/topo_canvas_gps.dart:135-149`). The only occurrences of the string `Icons.` in this document are inside a grep assertion that **forbids** them. No substitution was needed.

### Line references verified against the real tree

Every line number used below as an **edit anchor** was opened and checked. **Exact:** `photo_files.dart:9`; `photo_files_web.dart` imports `1-8`, class doc `10-14`, `importPhoto` `21-43`, `writePhotoBytes` `45-64`; `photo_files_native.dart`'s `Future<String> importPhoto` at `:90` and `_writeThumbnailBestEffort` at `:119`; `library_crud_repository.dart` best-effort doc `571-573`, `importPhoto` await `:592`, transaction `:601`, `softDeleteWall` `:389`; `topo_canvas_photo_ops.dart` imports `1-5`, `SelectedImageNotifier` `8-18`, `resolveAttachedPhotoPath` ends `:139`; `topo_canvas_screen.dart` `photo_repository.dart` import `:22`, `export 'topo_canvas_photo_ops.dart';` `:43`, FIX #4 doc `593-614`, `_attachPhotoAndLoad` `:615`, `try` `:618`, catch-all `:682`; `topos_screen.dart` import `22-23`, doc `412-415`, `_handleNewTopo` `424-515`, attach `478-480`, catch-all `508-509`; `topos_screen_test.dart` imports end `:32`, `_makeContainer` `123-142`, `_FakeLocationService` `:148`, `A6: new-topo flow` `:871`; `photo_ownership_test.dart` `_testWallId` `:21`, `PhotoFiles helper` group ends `:103`; `photo_byte_store_test.dart` `'distinct keys do not collide'` `70-76`, `main()` ends `:77`; `sync_remote.dart` imports `1-2`, listings `636-640` / `666-670`, `sharedPhotoPath` `:220`, `syncRequiredFields` `:289`, `filterValidSyncRows` `:317`; `backup_remote.dart` listing `157-161`; `sync_service.dart` `pushOwn` `:238`, snapshot txn closes `:275`, guard comment `:277`, `'photos':` entry `309-313`, `upsertOwnRows` `:338`, `wallVisibility` `:340`, `_uploadOwnPhotos` call `:341`, method `:364`, `photos.isEmpty` `:369`, `if (bytes == null) continue;` `:404`, `_canonicalPhotoId` `:663`; `sync_service_test.dart` `FakeSyncRemote` `:23`, tracking lists `28-33`, `upsertOwnRows` `35-60`, `uploadPhoto` `192-201`, `listPhotoObjectPaths` `209-213`, `uploadSharedPhoto` `215-223`, `listSharedPhotoObjectPaths` `229-230`, `ThrowingFetchSharedToposRemote` `267-272`, `group('pushOwn')` `438-764`; `draw_controller.dart` `:149`, `:165`, `:923`, `:989`; `database_provider.dart:47`.

**Drifted — all informational citations, none used as an edit anchor:**

- `masi_icon.dart:21`, not `:22` — the `const MasiIcon(...)` constructor is on line 21. It **is** `const`, so if `prefer_const_constructors` ever fires on the new call site, add `const`; Task 4 Step 9 already scripts that check.
- `topos_screen_test.dart`'s "duplicated locally since that one is file-private" note is at **`:161-162`**, not `:158-160`.
- `topo_canvas_wall_binding_test.dart`: `_testWallId` is at `:35` and `makeContainer` at `:40-49`, not the cited `34-51`.
- `photo_byte_store.dart`: `IdbPhotoByteStore`'s constructor is at `:57-58` (the class opens at `:56`), not `56-58`.
- `photo_files_native.dart`'s `importPhoto` doc begins at `:64`, not `:66`. The declaration anchor `:90` is exact.
- C1a's `expect(result.rowsPushed, 8)` is at **`sync_service_test.dart:1171`** (the test opens at `:1116`). Task 8's prose cited `:1123`; the risks list's `:1171` is the correct one.
- `abstract class SyncRemote` opens at `sync_remote.dart:80`, not `:86` (reconciliation's citation — `:86` is inside it).

## Files touched

| Path | Action | Phase | Responsibility |
|---|---|---|---|
| `lib/features/topo/data/photo_write_exception.dart` | create | 1 | Platform-agnostic, import-free PhotoWriteFailure enum + PhotoWriteException (with userMessage) + string-based classifyPhotoWriteFailure. Must not import dart:io, dart:js_interop or package:idb_shim — the web backend throws it, the platform-agnostic repository propagates it, and two screens present it. |
| `lib/features/topo/data/photo_files.dart` | modify | 1 | Add `export 'photo_write_exception.dart';` next to the existing `export 'photo_path_resolution.dart';` (line 9) so every PhotoFiles caller sees the exception type without a second import. |
| `lib/features/topo/data/photo_files_web.dart` | modify | 1 | L3 fix: importPhoto (lines 25-43) and writePhotoBytes (49-64) stop swallowing the ORIGINAL's byte-write failure and throw a classified PhotoWriteException; thumbnail write stays best-effort, extracted into _writeThumbnailBestEffort. |
| `lib/features/topo/data/photo_files_native.dart` | modify | 1 | Doc-comment only: state that the native backend never throws PhotoWriteException (its best-effort copy contract is deliberate and unchanged), so the shared callers' typed catch is dead code here. Zero behaviour change. |
| `lib/features/library/data/library_crud_repository.dart` | modify | 1 | Doc-comment only on attachPhotoToWall (lines 571-573, which currently claims the copy is best-effort 'so the row is still created'): document that a PhotoWriteException from importPhoto now propagates and the insert transaction is never reached. No code change — the await at :592 already precedes the transaction at :601. |
| `lib/features/topo/presentation/topo_canvas_photo_ops.dart` | modify | 1 | Add photoWriteFailureSnackBar(PhotoWriteException) and settleFailedPhotoAttach(...) — the shared, directly-testable user-facing half of the L3 fix, mirroring topo_canvas_gps.dart's gpsCaptureResultSnackBar. Adds package:flutter/material.dart, masi_icon.dart and photo_write_exception.dart imports. |
| `lib/features/topo/presentation/topo_canvas_screen.dart` | modify | 1 | _attachPhotoAndLoad (615-698): insert an `on PhotoWriteException` clause before the catch-all at :682 that clears the optimistically-selected path, settles the switch generation and shows the SnackBar. Adds the photo_write_exception.dart import. |
| `lib/features/library/presentation/topos_screen.dart` | modify | 1 | _handleNewTopo (424-515): wrap attachPhotoToWall (:480) in a typed catch that soft-deletes the wall createTopo already committed (:479), shows the SnackBar and aborts before GPS capture/navigation. Extends the show-list import at :22-23 and adds photo_write_exception.dart. |
| `lib/features/backup/data/storage_pagination.dart` | create | 4 | kStoragePageSize + collectPagedObjects<T>() — the Supabase-type-free paging loop for Storage object listings, unit-testable with no SupabaseClient fake. |
| `lib/features/backup/data/sync_remote.dart` | modify | 4 | S6: listPhotoObjectPaths (637-640) and listSharedPhotoObjectPaths (667-670) page through a new _listAllObjects(prefix) helper using SearchOptions(limit:, offset:) instead of one un-paged list(path:). |
| `lib/features/backup/data/backup_remote.dart` | modify | 4 | Same S6 fix for the duplicated listing at 158-161, removing the divergence the spec flags between CloudBackupService's photo logic and SyncService's. |
| `lib/features/backup/data/sync_service.dart` | modify | 4 | PushSyncResult gains photosFailed/photosMissingLocalBytes/photoErrors; _uploadOwnPhotos (364-415) returns a PhotoUploadOutcome record counting failures instead of silently continuing (:404); pushOwn reorders bytes-before-metadata (moves :340-341 above the tablesToRows map at :288) and withholds the photo rows whose bytes did not land. |
| `test/features/topo/data/photo_write_exception_test.dart` | create | 1 | Classifier + userMessage contract, on the plain Dart VM (quota shapes fed as DatabaseError strings). |
| `test/features/topo/data/photo_files_web_test.dart` | create | 1 | Drives the WEB PhotoFiles backend directly on the VM (verified importable) with a failing PhotoByteStore: importPhoto throws, nothing is written, thumbnail failures still swallowed, happy path unchanged. |
| `test/features/topo/data/photo_byte_store_test.dart` | modify | 1 | Add a real-IdbPhotoByteStore-over-newIdbFactoryMemory() case proving writeBytes surfaces its store error (the failure importPhoto must now propagate) rather than resolving silently. |
| `test/features/library/data/photo_ownership_test.dart` | modify | 1 | L3 group: attachPhotoToWall rethrows PhotoWriteException and leaves the photos table EMPTY. Adds a file-private _QuotaFailingPhotoFiles subclass. |
| `test/features/topo/presentation/photo_write_failure_snackbar_test.dart` | create | 1 | Widget test that the quota and unknown variants render distinguishable, user-presentable copy in a real SnackBar. |
| `test/features/topo/application/topo_canvas_wall_binding_test.dart` | modify | 1 | Container-level test that settleFailedPhotoAttach clears selectedImageProvider and drops isSwitchingPhoto back to false — the canvas failure path no widget test can reach (TopoCanvasScreen._pickImage has no injectable picker seam). |
| `test/features/library/presentation/topos_screen_test.dart` | modify | 1 | _makeContainer gains a photoFiles override; new test that the New topo flow reports the failure, leaves NO topo behind and does not navigate. |
| `test/features/backup/data/storage_pagination_test.dart` | create | 4 | The paging loop itself: 150 items across two pages with offsets 0/100, exact-page-boundary, empty prefix, injectable pageSize, non-positive pageSize rejected. |
| `test/features/backup/data/sync_service_test.dart` | modify | 4 | FakeSyncRemote gains a faithful truncating _listPage + collectPagedObjects-backed listings + listPageRequests + an ordered callLog; new FailingUploadSyncRemote; tests for bytes-before-metadata ordering, row withholding + heal-on-retry, missing-local-bytes reporting, and the 150-object zero-re-upload skip-set. |
| `lib/features/backup/application/sync_orchestrator.dart` | modify | 4 | **Added by reconciliation D-2.** The fragment deliberately excluded this file, shipping `hasPhotoFailures` as a seam for §1e to consume — but §1e never consumes it. Task 8 therefore makes the two minimal edits D-2 requires inside `_runPush`'s `case SyncPushOutcome.pushed:` arm: `lastPushError` concatenates `errors + photoErrors`, and the not-fully-landed branch enters `_scheduleRetry()`. Everything else in that method stays §1d's and §1e's. **This makes Task 8 depend on §1e Task 8 (the last orchestrator task) as well as on §1e Task 4.** |
| `CLAUDE.md` | modify | 4 | **Duplication #8.** Task 10's final step owns the whole stale-doc block: the non-existent "outbox", the false `web_smoke_test.dart` persistence claim, and the "~377 tests" baseline. No other fragment touches `CLAUDE.md`. |

## Interfaces produced/consumed

### Produces

- enum PhotoWriteFailure { quotaExceeded, unknown } — lib/features/topo/data/photo_write_exception.dart
- class PhotoWriteException implements Exception { const PhotoWriteException({required PhotoWriteFailure failure, required String key, Object? cause}); final PhotoWriteFailure failure; final String key; final Object? cause; String get userMessage; }
- PhotoWriteFailure classifyPhotoWriteFailure(Object error)
- Future<String> PhotoFiles.importPhoto(XFile xfile, String photoId) — web branch now THROWS PhotoWriteException on original-byte-write failure (signature unchanged)
- Future<String> PhotoFiles.writePhotoBytes(String photoId, String ext, List<int> bytes) — web branch now THROWS PhotoWriteException (signature unchanged)
- SnackBar photoWriteFailureSnackBar(PhotoWriteException error) — lib/features/topo/presentation/topo_canvas_photo_ops.dart (re-exported by topo_canvas_screen.dart)
- SnackBar settleFailedPhotoAttach(SelectedImageNotifier selectedImage, DrawController drawController, int generation, PhotoWriteException error)
- const int kStoragePageSize = 100 — lib/features/backup/data/storage_pagination.dart
- Future<List<T>> collectPagedObjects<T>(Future<List<T>> Function(int limit, int offset) fetchPage, {int pageSize = kStoragePageSize})
- typedef PhotoUploadOutcome = ({int uploaded, int failed, int missingLocalBytes, Set<String> failedCanonicalIds, List<String> errors}) — lib/features/backup/data/sync_service.dart
- `const PushSyncResult.pushed({required int rowsPushed, required int photosUploaded, int rowsFailed = 0, List<String> errors = const [], int photosFailed = 0, int photosMissingLocalBytes = 0, List<String> photoErrors = const []})` — **the ONE merged class** (reconciliation decision #8): §1d's three fields plus §1f's three, all optional-with-defaults, all initialised in both `skipped*` ctors, one `toString`
- `final int PushSyncResult.photosFailed` — RETRYABLE byte-upload failures; those rows were WITHHELD from the metadata push. **Feeds `fullyLanded`** (D-2). §1e keys its retry on this, via `hasPhotoFailures`
- `final int PushSyncResult.photosMissingLocalBytes` — non-retryable (no local bytes exist on this device); those rows WERE pushed. **Deliberately NOT part of `fullyLanded`** — including it would stop §1e's retry loop ever terminating
- final List<String> PushSyncResult.photoErrors — one human-readable message per photo in either bucket
- bool get PushSyncResult.hasPhotoFailures => photosFailed > 0
- **`bool get PushSyncResult.fullyLanded => didPush && rowsFailed == 0 && errors.isEmpty && photosFailed == 0;`** — amended by this fragment (reconciliation D-2). The sole gate `SyncOrchestrator._runPush` uses for `SyncStatus.idle` + a fresh `lastSyncedAt`
- `SyncOrchestratorState.lastPushError` now reads BOTH channels: `[...result.errors, ...result.photoErrors].join('; ')` (reconciliation D-2 / duplication #6)

### Consumes

- PhotoByteStore (abstract: writeBytes/readBytes/delete/exists) — lib/features/topo/data/photo_byte_store.dart:26-38
- IdbPhotoByteStore({idb.IdbFactory? factory}) — photo_byte_store.dart:56-58
- String thumbKeyFor(String storedOriginal) — lib/features/topo/data/photo_path_resolution.dart:36-39
- Future<Uint8List> generateThumbnail(Uint8List src, {int maxEdge, int quality}) — lib/features/topo/data/image_ops/image_ops.dart:11-13 (resolves to image_ops_native.dart on the Dart VM, image_ops_web.dart on web)
- Future<String> LibraryCrudRepository.attachPhotoToWall(String wallId, XFile xfile, int width, int height) — library_crud_repository.dart:584-622 (importPhoto awaited at :592, INSERT transaction at :601-620)
- Future<void> LibraryCrudRepository.softDeleteWall(String id) — library_crud_repository.dart:389-398
- final photoFilesProvider = Provider<PhotoFiles> — lib/core/db/database_provider.dart:47
- SelectedImageNotifier.clear() / .select(String) + selectedImageProvider — lib/features/topo/presentation/topo_canvas_photo_ops.dart:8-18
- int DrawController.beginPhotoSwitch() — lib/features/topo/application/draw_controller.dart:923
- void DrawController.cancelPhotoSwitch(int generation) — draw_controller.dart:989
- bool DrawState.isSwitchingPhoto / int DrawState.switchGeneration — draw_controller.dart:149, :165
- SnackBar gpsCaptureResultSnackBar(GpsCaptureResult) — lib/features/topo/presentation/topo_canvas_gps.dart:135-149 (the shape photoWriteFailureSnackBar mirrors)
- MasiIcon(String name, {double? size, Color? color, bool tinted}) — lib/shared/presentation/masi_icon.dart:21 (assets/icons/masi/masi_warning.svg exists)
- Future<List<FileObject>> StorageFileApi.list({String? path, SearchOptions searchOptions = const SearchOptions()}) — storage_client-2.6.0/lib/src/storage_file_api.dart:594-596
- SearchOptions({int? limit = 100, int? offset = 0, SortBy? sortBy = const SortBy(), String? search}) — storage_client-2.6.0/lib/src/types.dart:204-222; SearchOptions + FileObject are both re-exported by package:supabase_flutter/supabase_flutter.dart
- List<Map<String, dynamic>> filterValidSyncRows(Iterable rows, List<String> requiredFields, {required String debugLabel}) — sync_remote.dart:317-334
- const Map<String, List<String>> syncRequiredFields — sync_remote.dart:289-310
- String sharedPhotoPath(String photoId, String ext) — sync_remote.dart:220
- String SyncService._canonicalPhotoId(db.Photo photo) — sync_service.dart:663
- FakeSyncRemote / FakeConnectivityService / FakeAuthRepository / makeContainer(...) / writeFile(...) / seedWallHierarchy(...) — test/features/backup/data/sync_service_test.dart:23-260, :276-307, :333-436
- _makeContainer / _wrap / _drain / _drainNoSettle / _acceptTopoNameDialog / _dbWork / _tinyPngBytes — test/features/library/presentation/topos_screen_test.dart:37, :123-142, :194-239, :246-312
- seedWall() / writeSource() / photosDirPath() / docsDir seam — test/features/library/data/photo_ownership_test.dart:38-66
- makeContainer() + const _testWallId — test/features/topo/application/topo_canvas_wall_binding_test.dart:34-51
- class DatabaseError extends Error { DatabaseError(String message); String toString() => message; } — package:idb_shim/idb.dart (public; DatabaseErrorNative.toString() is '<DOMException.name>: <message>')
- **From §1d** (Phase 2, must be fully landed first): `class TablePushOutcome` with `.ok({table, rowsUpserted, rowsSkippedNewerRemote})` / `.failed({table, rowsFailed, error})` and `bool get ok`; `Future<List<TablePushOutcome>> SyncRemote.upsertOwnRows(String, Map<String, List<Map<String, dynamic>>>)`; `PushSyncResult.rowsFailed`/`errors`/`fullyLanded`; `SyncOrchestratorState.lastPushError`; `_runPush`'s `if (result.fullyLanded)` gate
- **From §1e** (Phase 3, must be fully landed first): `enum PushScope { full, dirtyOnly }`; `Future<PushSyncResult> pushOwn({PushScope scope = PushScope.full})`; the `wallVisibility` `selectOnly` projection over ALL own walls, read inside `pushOwn`'s snapshot transaction (**consume it — do not rebuild it**, D-4); `Future<void> _clearDirty(Map<String, List<Map<String, dynamic>>>)`; `_scheduleRetry()` / `syncRetryScheduleProvider`; `_consecutivePushFailures` / `_fullResyncDue`
- **From §1a** (Phase 1, must land before Task 6): `_makeContainer`'s `StorageDurability storageDurability = const StorageDurability.probing()` parameter and its **unconditional** `storageDurabilityProvider.overrideWith(() => _FakeStorageDurability(storageDurability))`, plus the `_FakeStorageDurability` notifier double — `test/features/library/presentation/topos_screen_test.dart`

## Conventions

- Riverpod v3 only: `Notifier`/`NotifierProvider` (see `SelectedImageNotifier` at topo_canvas_photo_ops.dart:8-18 and `SyncOrchestrator extends Notifier<SyncOrchestratorState>`); never `StateProvider`.
- Platform splits are conditional EXPORT facades, never `kIsWeb`: `lib/features/topo/data/photo_files.dart:10-12` is `export 'photo_files_stub.dart' if (dart.library.io) 'photo_files_native.dart' if (dart.library.js_interop) 'photo_files_web.dart';`, with `export 'photo_path_resolution.dart';` on line 9 for the shared, platform-agnostic types. New shared types go in their own import-free file and get exported from the facade — that is exactly how `photo_path_resolution.dart` and `PhotoPathResolution`/`thumbKeyFor` are structured, and `photo_write_exception.dart` must copy it.
- The analyzer resolves a facade to its UNCONDITIONAL (stub) branch while the compiler picks the platform branch, so every variant must stay signature-compatible; `photo_files_stub.dart:22-23` documents this at length (`PhotoFiles({Object? docsDir, Object? byteStore})` is a permissive superset). A test subclass of `PhotoFiles` must therefore use a no-arg implicit constructor and override only `importPhoto`.
- Grep gate: `grep -r "dart:io" lib --include="*.dart" | grep -v _native.dart` must stay empty (`tool/build_web.sh:41`); `photo_write_exception.dart` and `storage_pagination.dart` must have ZERO platform imports, which is also why the quota classifier is string-based rather than type-based against `DatabaseError`/`FileSystemException`.
- Doc comments are long, name the bug they fix and the regression they prevent (see `sync_service.dart:277-287`, `photo_files_native.dart:66-89`, `topo_canvas_screen.dart:593-614`). Match that density; every new branch gets a "why", and reference the spec's L/S ids (L3, S5, S6) and decision ids (D-5) the way existing comments reference "#17", "#72 P0 fix", "FIX #4".
- Icons: `MasiIcon('warning', size: 18)`, never `Icons.X`/`CupertinoIcons.X`; the snackbar mirrors `gpsCaptureResultSnackBar`'s exact body (`Row(mainAxisSize: MainAxisSize.min, children: [MasiIcon(...), const SizedBox(width: 8), Flexible(child: Text(...))])`, topo_canvas_gps.dart:135-149).
- Records via `typedef X = ({...})` is established (`typedef PhotoGps = ({double latitude, double longitude})` core/location/photo_gps.dart:7; `typedef RouteEntry` community_topo_detail_providers.dart:25).
- Test doubles are hand-written classes named `Fake*` in `test/features/backup/data/sync_service_test.dart` and `_Fake*`/`_Throwing*` when file-private; duplicating a file-private double across test files is accepted and documented (topos_screen_test.dart:158-160). Extend `FakeSyncRemote` by subclassing, as `ThrowingFetchSharedToposRemote` (sync_service_test.dart:267-272) already does.
- Widget tests must never drive a real image-codec decode under the fake clock; use `_drain`/`_drainNoSettle`/`tester.runAsync` (topos_screen_test.dart:246-274) and never `pumpAndSettle` when asserting on a live SnackBar (that helper's own doc, :256-266, explains why).
- Every test command is `export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test <path>`; PATH does not persist between shell calls.

Two citations in the block above are stale and are corrected by the master plan: the `dart:io` gate is the **directive-anchored** regex at `tool/build_web.sh:40` (not the naive substring form at `:41`), and `topos_screen_test.dart`'s "duplicated locally" note is at `:161-162`. `photo_files_native.dart`'s `importPhoto` doc spans `:64-89`.

Plus the master plan's Global Constraints, which every task implicitly includes:

- `flutter analyze` → **0 issues**; `flutter test` → **green**, asserted as **baseline + N for this task**, never as an absolute total (D-13). Live baseline at time of writing: **1586**.
- The `dart:io` gate stays green — `tool/build_web.sh --gate` runs the directive-anchored regex (`^[[:space:]]*(import|export)[[:space:]]+['"]dart:io['"]`, byte-identical in `tool/build_web.sh:40` and `.github/workflows/ci.yml`, reconciled by `14332a1`). It is directive-anchored on purpose: the naive substring form matches 35 legitimate doc comments and can never be empty.
- Do not add or bump any dependency. `fake_async` is transitive-only — do not import it.
- Never `Icons.X` / `CupertinoIcons.X`; always `MasiIcon`.
- Commit after every task that clears its verify gate, one logical change per commit, straight to `main`, never pushed, trailer `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- **The agent that writes a task never verifies it.** A separate clean-context verifier receives only the task's `**Assertions:**` block, `git show` of the commit, and the Global Constraints. Verifiers are read-only on `lib/` and may not run any build or install command.

## Ordering

### Phase 1 — photo half (Tasks 1–6)

Fully write-disjoint from §1d and §1e; safe to reorder relative to them and to §1b.

- **Tasks 1 → 2 → 3 are strictly serial** — each depends on a symbol the previous one creates.
- **Task 4 depends on Task 1** (it renders `PhotoWriteException.userMessage`).
- **Tasks 5 and 6 both depend on Task 4** and are file-disjoint from each other, so they may be reordered freely — Task 5 owns `topo_canvas_screen.dart`, Task 6 owns `topos_screen.dart`.
- **§1a Task 4 must land before Task 6.** Both modify `topos_screen.dart` + `topos_screen_test.dart`. Never parallel.
- **Task 3 (doc-comment only on `library_crud_repository.dart`) must land before §1e Task 3 (code changes to the same file)** — or be rebased onto it. Never parallel.
- §1c also edits `library_crud_repository.dart` and `library_providers.dart`/`toposProvider`, which Task 6's harness reads; the master plan serialises Phase 1.5 (§1c) against Task 6.

### Phase 4 — sync half (Tasks 7–10)

**Strictly serial. LAST. On top of a fully-landed and independently-verified §1d *and* §1e.** These are the reconciliation's hard per-file chains, with §1f's positions in bold:

| File | Chain |
|---|---|
| `lib/features/backup/data/sync_remote.dart` | §1d T1 → §1d T2 → §1e T2 → **§1f Task 7** |
| `lib/features/backup/data/sync_service.dart` | §1d T3 → §1d T4 → §1e T4 → **§1f Task 8** → **§1f Task 9** |
| `lib/features/backup/application/sync_orchestrator.dart` | §1d T5 → §1d T7 → §1e T6 → §1e T8 → **§1f Task 8** *(added by D-2)* |
| `test/features/backup/data/sync_service_test.dart` | §1d T2 → §1d T3 → §1d T4 → §1d T6 → §1e T2 → §1e T4 → §1e T7 → **§1f Task 8** → **§1f Task 9** → **§1f Task 10** |
| `lib/features/backup/data/storage_pagination.dart` | NEW — owned solely by **§1f Task 7** |
| `lib/features/backup/data/backup_remote.dart` | owned solely by **§1f Task 7** |
| `CLAUDE.md` | owned solely by **§1f Task 10** |

Within the half: **Task 7 → Task 8 → Task 9 → Task 10, strictly serial.** Task 10 depends on Task 7's `collectPagedObjects`/`kStoragePageSize` and on Task 9's withholding behaviour.

**Never run in parallel:** any two of {§1d, §1e, §1f-sync}; §1a Task 4 with §1f Task 6; §1e Task 3 with §1f Task 3.

> `test/features/backup/data/sync_service_test.dart` is the **highest-collision file in the whole plan** — §1d extends `FakeSyncRemote` with a per-table throwing variant, §1e adds `syncRemoteProvider`/`connectivityServiceProvider` override points, and §1f Tasks 9–10 add `callLog`, paged listings, `listPageRequests`, `FailingUploadSyncRemote` and `_SinglePageListingRemote` to the same class. A concurrent edit here means a git-stash recovery, which this repo has been bitten by before. Serialize.

---

# Phase 1 — photo half (Tasks 1–6)

*Local byte-write / quota / UI work. Runs early, alongside §1a and §1b. Touches no file under `lib/features/backup/`.*

### Task 1: PhotoWriteException — a distinguishable, user-presentable local byte-write failure

**Files:**
- Create: `lib/features/topo/data/photo_write_exception.dart`, `test/features/topo/data/photo_write_exception_test.dart`
- Modify: `lib/features/topo/data/photo_files.dart:9`
- Test: `test/features/topo/data/photo_write_exception_test.dart`

**Interfaces:**
- Produces: `enum PhotoWriteFailure { quotaExceeded, unknown }`; `class PhotoWriteException implements Exception` (`failure`/`key`/`cause`/`userMessage`/`toString`); `PhotoWriteFailure classifyPhotoWriteFailure(Object error)`; and the `export 'photo_write_exception.dart';` line on the unconditional side of the `photo_files.dart` facade.
- Consumes: **nothing** — the implementation file has ZERO imports, which is load-bearing (it must be reachable from the web backend, the platform-agnostic repository and two screens without dragging `dart:io` or `dart:js_interop` into any of them). The test consumes `package:idb_shim/idb.dart`'s public `DatabaseError`, whose `toString()` is the bare message, to feed the classifier real browser-shaped strings on the plain Dart VM.

- [ ] **Step 1: Write the failing test file. It feeds the classifier the exact shapes idb_shim produces for a browser quota failure, using the public `DatabaseError` (whose `toString()` is the bare message) so no browser is needed.**
  ```dart
  // test/features/topo/data/photo_write_exception_test.dart
  // Pure, dependency-free classification + user-message contract for the L3
  // fix. Runs on the plain Dart VM: classifyPhotoWriteFailure is deliberately
  // string-based (see its doc) precisely so the BROWSER quota shape is testable
  // without a browser test runner.
  import 'package:flutter_test/flutter_test.dart';
  import 'package:idb_shim/idb.dart' show DatabaseError;
  import 'package:masi/features/topo/data/photo_write_exception.dart';

  void main() {
    group('classifyPhotoWriteFailure', () {
      test('a Blink/WebKit DOMException name is quotaExceeded', () {
        // The exact shape idb_shim's DatabaseErrorNative.toString() produces:
        // '<DOMException.name>: <DOMException.message>'.
        expect(
          classifyPhotoWriteFailure(
            DatabaseError('QuotaExceededError: The quota has been exceeded.'),
          ),
          PhotoWriteFailure.quotaExceeded,
        );
      });

      test('legacy Gecko NS_ERROR_DOM_QUOTA_REACHED is quotaExceeded', () {
        expect(
          classifyPhotoWriteFailure(
            DatabaseError('NS_ERROR_DOM_QUOTA_REACHED: persistent storage full'),
          ),
          PhotoWriteFailure.quotaExceeded,
        );
      });

      test('matching is case-insensitive', () {
        expect(
          classifyPhotoWriteFailure(Exception('quotaexceedederror')),
          PhotoWriteFailure.quotaExceeded,
        );
      });

      test('any other store error is unknown', () {
        expect(
          classifyPhotoWriteFailure(
            DatabaseError('InvalidStateError: database is closed'),
          ),
          PhotoWriteFailure.unknown,
        );
      });
    });

    group('PhotoWriteException', () {
      test('quotaExceeded userMessage names running out of space, in plain '
          'words, without leaking the raw exception name', () {
        const e = PhotoWriteException(
          failure: PhotoWriteFailure.quotaExceeded,
          key: 'photos/abc.jpg',
        );
        expect(e.userMessage, contains('Out of storage space'));
        expect(e.userMessage, isNot(contains('QuotaExceededError')));
      });

      test('unknown userMessage is a plain retry prompt', () {
        const e = PhotoWriteException(
          failure: PhotoWriteFailure.unknown,
          key: 'photos/abc.jpg',
        );
        expect(e.userMessage, contains('could not be saved'));
      });

      test('the two userMessages are distinguishable from each other', () {
        const quota = PhotoWriteException(
          failure: PhotoWriteFailure.quotaExceeded,
          key: 'photos/abc.jpg',
        );
        const unknown = PhotoWriteException(
          failure: PhotoWriteFailure.unknown,
          key: 'photos/abc.jpg',
        );
        expect(quota.userMessage, isNot(unknown.userMessage));
      });

      test('toString carries the failure kind, the key and the cause', () {
        final e = PhotoWriteException(
          failure: PhotoWriteFailure.quotaExceeded,
          key: 'photos/abc.jpg',
          cause: DatabaseError('QuotaExceededError'),
        );
        expect(e.toString(), contains('quotaExceeded'));
        expect(e.toString(), contains('photos/abc.jpg'));
        expect(e.toString(), contains('QuotaExceededError'));
      });
    });
  }
  ```

- [ ] **Step 2: Run it and see it fail to compile (the target library does not exist yet).**
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/topo/data/photo_write_exception_test.dart
  ```
  Expected: Compile error: Error: Couldn't resolve the package 'masi' ... photo_write_exception.dart — i.e. RED for the right reason (missing implementation, not a bad test).

- [ ] **Step 3: Create the implementation file. Zero imports — this is load-bearing (see the library doc).**
  ```dart
  // lib/features/topo/data/photo_write_exception.dart
  /// Why a photo's BYTES could not be persisted locally, and the plain words to
  /// tell the user about it.
  ///
  /// Deliberately IMPORT-FREE and platform-agnostic. Three unrelated layers need
  /// this type: the web `PhotoFiles` backend that throws it
  /// (`photo_files_web.dart`), the platform-agnostic repository whose INSERT it
  /// aborts (`LibraryCrudRepository.attachPhotoToWall`), and the two screens that
  /// present it (`topos_screen.dart`'s `_handleNewTopo`,
  /// `topo_canvas_screen.dart`'s `_attachPhotoAndLoad`). So it must be importable
  /// from a file that touches NEITHER `dart:io` (the web grep gate —
  /// `grep -r "dart:io" lib --include="*.dart" | grep -v _native.dart` must stay
  /// empty, `tool/build_web.sh:41`) NOR `dart:js_interop`/`package:idb_shim`
  /// (which would newly drag the browser byte store into the iOS/Android builds).
  /// Hence no imports at all, and a STRING-based classifier — see
  /// [classifyPhotoWriteFailure].
  ///
  /// Structured exactly like this feature's other shared, platform-agnostic type
  /// file (`photo_path_resolution.dart`), and re-exported from the
  /// `photo_files.dart` facade the same way.
  library;

  /// The kind of local byte-write failure a [PhotoWriteException] reports.
  enum PhotoWriteFailure {
    /// The browser (or the device) refused the write because the origin is out of
    /// room. On web this is IndexedDB rejecting the request/transaction with a
    /// `DOMException` named `QuotaExceededError`.
    ///
    /// This is the REALISTIC trigger in ordinary use, not an edge case: photo
    /// originals are deliberately kept at FULL resolution (decision D-5 — quota
    /// is handled by failing loudly, never by shrinking the user's photo), and
    /// only the 512px/q80 thumbnail is downscaled.
    quotaExceeded,

    /// Anything else: the store could not be opened, a version-change upgrade is
    /// blocked, private-browsing storage restrictions, an aborted transaction, or
    /// a failed read of the picked source.
    unknown,
  }

  /// Thrown when a photo's BYTES could not be persisted locally.
  ///
  /// L3 fix (silent data loss): `PhotoFiles.importPhoto` on web used to swallow
  /// this and return the logical key anyway, so
  /// `LibraryCrudRepository.attachPhotoToWall` went on to insert a `Photos` row
  /// whose `localPath` pointed at bytes that were never written — a topo whose
  /// photo is permanently a placeholder, with nothing anywhere reporting why.
  ///
  /// `attachPhotoToWall` awaits `importPhoto` BEFORE opening its insert
  /// transaction, so this exception reaching a caller GUARANTEES no `Photos` row
  /// was created and there is nothing to clean up on the photo side.
  class PhotoWriteException implements Exception {
    const PhotoWriteException({
      required this.failure,
      required this.key,
      this.cause,
    });

    /// What went wrong, classified for presentation.
    final PhotoWriteFailure failure;

    /// The logical store key the write was attempted under (e.g.
    /// `photos/<photoId>.jpg`) — diagnostics only, never shown to the user.
    final String key;

    /// The underlying error, kept for logging only. Callers must present
    /// [userMessage], never this.
    final Object? cause;

    /// A short, complete sentence safe to render straight into a `SnackBar`.
    /// Deliberately free of any exception name or store key — the user gets an
    /// actionable sentence, the log gets [toString].
    String get userMessage => switch (failure) {
      PhotoWriteFailure.quotaExceeded =>
        'Out of storage space — this photo was not saved. Free up space on this '
            'device and try again.',
      PhotoWriteFailure.unknown =>
        'This photo could not be saved on this device. Please try again.',
    };

    @override
    String toString() =>
        'PhotoWriteException(${failure.name}, key: $key, cause: $cause)';
  }

  /// Classifies a raw byte-store error into a [PhotoWriteFailure].
  ///
  /// STRING-based rather than type-based, for two reasons:
  ///  1. This file may not import `package:idb_shim` or `dart:io` (see the
  ///     library doc), so `DatabaseError`/`FileSystemException` are unavailable
  ///     here by construction.
  ///  2. The browser exception shape is not stable across engines OR across
  ///     Dart's two web compilers. IndexedDB signals an exhausted origin quota
  ///     with a `DOMException` whose `name` is `QuotaExceededError`
  ///     (`code == 22`); older Gecko used `NS_ERROR_DOM_QUOTA_REACHED`.
  ///     `idb_shim`'s wasm-clean native backend rethrows that as its own
  ///     `DatabaseErrorNative`, whose `toString()` is `'<name>: <message>'`
  ///     (`idb_shim/lib/src/native_web/native_error.dart`) — e.g.
  ///     `'QuotaExceededError: The quota has been exceeded.'` — while under
  ///     dart2wasm the SAME failure can instead arrive as a plain `DatabaseError`
  ///     carrying the stringified JS error (that file's `_handleError` has an
  ///     explicit "Happens on wasm, very unfortunate" branch for it). Every one
  ///     of those forms carries the marker text, so matching text covers them all
  ///     with no interop — and keeps the whole thing unit-testable on the plain
  ///     Dart VM.
  PhotoWriteFailure classifyPhotoWriteFailure(Object error) {
    final text = error.toString().toLowerCase();
    for (final marker in _quotaMarkers) {
      if (text.contains(marker)) return PhotoWriteFailure.quotaExceeded;
    }
    return PhotoWriteFailure.unknown;
  }

  /// Lower-cased substrings that identify an out-of-room failure across engines:
  /// Blink/WebKit's `QuotaExceededError`, legacy Gecko's
  /// `NS_ERROR_DOM_QUOTA_REACHED`, the DOMException default messages, and POSIX
  /// `ENOSPC` (so the same classifier stays correct if a native backend ever
  /// calls it).
  const List<String> _quotaMarkers = [
    'quotaexceedederror',
    'ns_error_dom_quota_reached',
    'quota has been exceeded',
    'quota exceeded',
    'no space left on device',
  ];
  ```

- [ ] **Step 4: Re-export the new types from the PhotoFiles facade so every existing PhotoFiles caller (including `library_crud_repository.dart`, which already imports it) sees them with no extra import.**
  ```dart
  // lib/features/topo/data/photo_files.dart — replace line 9
  // OLD:
  // export 'photo_path_resolution.dart';
  // NEW:
  export 'photo_path_resolution.dart';
  // L3 fix: the failure type `importPhoto`/`writePhotoBytes` now propagate.
  // Platform-agnostic (no imports at all — see that file's library doc), so it
  // sits alongside `photo_path_resolution.dart` on the unconditional side of
  // this facade rather than inside any one backend.
  export 'photo_write_exception.dart';
  ```

- [ ] **Step 5: Run the test and see it pass.**
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/topo/data/photo_write_exception_test.dart
  ```
  Expected: `+8: All tests passed!` — 8 is a genuine per-file count (4 in `classifyPhotoWriteFailure`, 4 in `PhotoWriteException`), recounted against the block in Step 1.

- [ ] **Step 6: Confirm the new file added no platform imports and the grep gate is still clean.**
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && grep -c "^import" lib/features/topo/data/photo_write_exception.dart; grep -r "dart:io" lib --include="*.dart" | grep -v _native.dart | wc -l; flutter analyze
  ```
  Expected: grep -c prints 0 (no imports); the dart:io grep prints 0; analyze reports 'No issues found!'

- [ ] **Step 7: Confirm the whole-project gates, then commit.**
  > Corrected (D-13 — the fragment gated on the absolute total `1576+`)

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter analyze && flutter test
  ```
  Expected: `No issues found!` and `flutter test` green at **baseline + 8**. Never gate on an absolute total.

**Assertions:**

- `flutter test test/features/topo/data/photo_write_exception_test.dart` is green with 8 tests.
- `grep -c "^import" lib/features/topo/data/photo_write_exception.dart` is `0` — the file has no imports, so neither the iOS build nor the web grep gate is affected.
- The directive-anchored `dart:io` gate (`tool/build_web.sh --gate`) is still empty.
- `classifyPhotoWriteFailure(DatabaseError('QuotaExceededError: The quota has been exceeded.'))` returns `PhotoWriteFailure.quotaExceeded`, and `classifyPhotoWriteFailure(DatabaseError('InvalidStateError: database is closed'))` returns `PhotoWriteFailure.unknown`.
- `PhotoWriteException(failure: quotaExceeded, ...).userMessage != PhotoWriteException(failure: unknown, ...).userMessage`, and neither contains the substring `QuotaExceededError`.
- `lib/features/topo/data/photo_files.dart` exports `photo_write_exception.dart`, so `library_crud_repository.dart` resolves `PhotoWriteException` with no new import.
- `flutter analyze` = 0 issues; `flutter test` green at **baseline + 8** (D-13 — the fragment's `1576+` is stale; the live baseline is 1586).

**Commit message:** `feat(photos): add PhotoWriteException + quota classifier for local byte-write failures`

### Task 2: Web `importPhoto`/`writePhotoBytes` PROPAGATE the byte-write failure (L3)

**Files:**
- Create: `test/features/topo/data/photo_files_web_test.dart`
- Modify: `lib/features/topo/data/photo_files_web.dart:1-64`; `lib/features/topo/data/photo_files_native.dart:64-90` *(doc comment only — verified: the doc starts at `:64`, not the cited `:66`; the `Future<String> importPhoto` anchor at `:90` is exact)*; `test/features/topo/data/photo_byte_store_test.dart:1-77`
- Test: `test/features/topo/data/photo_files_web_test.dart`, `test/features/topo/data/photo_byte_store_test.dart`

**Interfaces:**
- Produces: `Future<String> PhotoFiles.importPhoto(XFile, String)` and `Future<String> PhotoFiles.writePhotoBytes(String, String, List<int>)` on the **web** branch now THROW a classified `PhotoWriteException` instead of swallowing the store error; the private `Future<void> _writeThumbnailBestEffort(String key, Uint8List bytes)` helper.
- Consumes: `PhotoWriteException`/`classifyPhotoWriteFailure` (Task 1); `PhotoByteStore` (`photo_byte_store.dart:26-38`); `IdbPhotoByteStore({idb.IdbFactory? factory})` (`:57-58`); `thumbKeyFor` (`photo_path_resolution.dart:36`); `generateThumbnail` (`image_ops/image_ops.dart`); `XFile.fromData`; `newIdbFactoryMemory()`; `kPhotoByteStoreDbName`/`kPhotoByteStoreName` (`photo_byte_store.dart:44-45`).

> **Duplication #7 — deliberate symmetry, not a duplication to resolve.** The private helper extracted here is named `_writeThumbnailBestEffort`, identical to the native backend's existing private helper at `lib/features/topo/data/photo_files_native.dart:119` (verified). **Keep both names identical.** Do not rename, do not attempt to share them.

- [ ] **Step 1: Write the new web-backend test file. VERIFIED FACT (probed in the planning session): `photo_files_web.dart` imports and RUNS on the plain Dart VM — its only platform-specific dependency is the `image_ops/image_ops.dart` conditional export, which resolves to the pure-Dart `image_ops_native.dart` under `dart.library.io`, and `photo_byte_store.dart` never evaluates its `idbFactoryWeb` default when a store is injected. Import the BRANCH file directly, not the facade (the facade would resolve to the native backend on the VM).**
  ```dart
  // test/features/topo/data/photo_files_web_test.dart
  // Exercises the WEB `PhotoFiles` backend directly, on the plain Dart VM.
  //
  // `photo_files_web.dart` is VM-importable even though it is the web branch of
  // the `photo_files.dart` conditional-export facade: its only
  // platform-specific dependency is `image_ops/image_ops.dart`, itself a
  // conditional export that resolves to the pure-Dart `image_ops_native.dart`
  // here, plus `photo_byte_store.dart` (already VM-tested in
  // `photo_byte_store_test.dart` — its `idb.idbFactoryWeb` default is only ever
  // evaluated when no factory is supplied). Importing the BRANCH file directly
  // rather than the facade — which the VM would resolve to the NATIVE backend —
  // is what makes the L3 fix testable with no browser test runner.
  import 'dart:typed_data';

  import 'package:flutter_test/flutter_test.dart';
  import 'package:idb_shim/idb.dart' show DatabaseError;
  import 'package:idb_shim/idb_client_memory.dart';
  import 'package:image_picker/image_picker.dart';
  import 'package:masi/features/topo/data/photo_byte_store.dart';
  import 'package:masi/features/topo/data/photo_files_web.dart';
  import 'package:masi/features/topo/data/photo_write_exception.dart';

  /// [PhotoByteStore] whose writes under [failPrefix] always throw [error], while
  /// every other operation behaves like a plain in-memory map.
  ///
  /// The prefix seam is what lets a test separate the two write sites
  /// `importPhoto` performs: the ORIGINAL (`photos/…`, which must now FAIL the
  /// call) and the THUMBNAIL (`thumbs/…`, which must still be swallowed).
  class _FailingWriteStore implements PhotoByteStore {
    _FailingWriteStore(this.error, {this.failPrefix = 'photos/'});

    final Object error;
    final String failPrefix;
    final Map<String, Uint8List> written = {};

    @override
    Future<void> writeBytes(String key, Uint8List bytes) async {
      if (key.startsWith(failPrefix)) throw error;
      written[key] = bytes;
    }

    @override
    Future<Uint8List?> readBytes(String key) async => written[key];

    @override
    Future<void> delete(String key) async {
      written.remove(key);
    }

    @override
    Future<bool> exists(String key) async => written.containsKey(key);
  }

  /// A picked photo whose bytes live in memory — `XFile.fromData` short-circuits
  /// `readAsBytes()` to exactly these bytes (no filesystem), and its `name` is
  /// the basename of `path`, which is what `importPhoto` reads the extension
  /// from.
  XFile _pickedJpeg([List<int> bytes = const [1, 2, 3, 4]]) =>
      XFile.fromData(Uint8List.fromList(bytes), path: '/picked/wall.jpg');

  void main() {
    group('importPhoto propagates a byte-write failure (L3)', () {
      test('a QuotaExceededError-shaped failure throws a PhotoWriteException '
          'classified as quotaExceeded, and nothing is left in the store',
          () async {
        final store = _FailingWriteStore(
          DatabaseError('QuotaExceededError: The quota has been exceeded.'),
        );
        final files = PhotoFiles(byteStore: store);

        await expectLater(
          files.importPhoto(_pickedJpeg(), 'abc123'),
          throwsA(
            isA<PhotoWriteException>()
                .having(
                  (e) => e.failure,
                  'failure',
                  PhotoWriteFailure.quotaExceeded,
                )
                .having((e) => e.key, 'key', 'photos/abc123.jpg'),
          ),
        );
        expect(store.written, isEmpty);
      });

      test('any other store failure throws a PhotoWriteException classified as '
          'unknown', () async {
        final files = PhotoFiles(
          byteStore: _FailingWriteStore(
            DatabaseError('InvalidStateError: database is closed'),
          ),
        );

        await expectLater(
          files.importPhoto(_pickedJpeg(), 'abc123'),
          throwsA(
            isA<PhotoWriteException>()
                .having((e) => e.failure, 'failure', PhotoWriteFailure.unknown),
          ),
        );
      });

      test('a THUMBNAIL write failure is still swallowed — the original landed, '
          'so importPhoto succeeds and returns the key', () async {
        final store = _FailingWriteStore(
          DatabaseError('QuotaExceededError'),
          failPrefix: 'thumbs/',
        );
        final files = PhotoFiles(byteStore: store);

        final key = await files.importPhoto(_pickedJpeg(), 'abc123');

        expect(key, 'photos/abc123.jpg');
        expect(store.written.keys, ['photos/abc123.jpg']);
      });

      test('the happy path is unchanged: original AND thumbnail both stored '
          'under their logical keys', () async {
        final store = IdbPhotoByteStore(factory: newIdbFactoryMemory());
        final files = PhotoFiles(byteStore: store);

        final key = await files.importPhoto(_pickedJpeg(), 'abc123');

        expect(key, 'photos/abc123.jpg');
        expect(
          await store.readBytes('photos/abc123.jpg'),
          Uint8List.fromList([1, 2, 3, 4]),
        );
        // 4 undecodable bytes: generateThumbnail returns the SOURCE unchanged
        // rather than throwing (image_ops_native.dart:19-34), so a thumbnail
        // record still exists.
        expect(await store.exists('thumbs/abc123.jpg'), isTrue);
      });

      test('an extensionless picked file still lands under .jpg', () async {
        final store = IdbPhotoByteStore(factory: newIdbFactoryMemory());
        final files = PhotoFiles(byteStore: store);

        final key = await files.importPhoto(
          XFile.fromData(Uint8List.fromList([9]), path: '/picked/noext'),
          'abc123',
        );

        expect(key, 'photos/abc123.jpg');
      });
    });

    group('writePhotoBytes propagates a byte-write failure (cloud restore)', () {
      test('throws a classified PhotoWriteException instead of an opaque store '
          'error', () async {
        final files = PhotoFiles(
          byteStore: _FailingWriteStore(
            DatabaseError('QuotaExceededError: The quota has been exceeded.'),
          ),
        );

        await expectLater(
          files.writePhotoBytes('abc123', '.jpg', const [1, 2, 3]),
          throwsA(
            isA<PhotoWriteException>().having(
              (e) => e.failure,
              'failure',
              PhotoWriteFailure.quotaExceeded,
            ),
          ),
        );
      });

      test('the happy path still returns the key and writes the thumbnail',
          () async {
        final store = IdbPhotoByteStore(factory: newIdbFactoryMemory());
        final files = PhotoFiles(byteStore: store);

        final key = await files.writePhotoBytes('abc123', '.jpg', const [1, 2]);

        expect(key, 'photos/abc123.jpg');
        expect(await store.exists('thumbs/abc123.jpg'), isTrue);
      });
    });
  }
  ```

- [ ] **Step 2: Run it and watch the three failure-path tests fail (importPhoto currently returns the key instead of throwing).**
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/topo/data/photo_files_web_test.dart
  ```
  Expected: RED: the two importPhoto failure tests report 'Expected: throws PhotoWriteException / Actual: <Future> which: returned photos/abc123.jpg', and the writePhotoBytes failure test reports a raw DatabaseError instead of a PhotoWriteException. The three happy-path/thumbnail tests pass.

- [ ] **Step 3: Replace `importPhoto` (currently lines 21-43) in `lib/features/topo/data/photo_files_web.dart` with the propagating version plus an extracted best-effort thumbnail helper. Keep the whole body in ONE try so there is no final-declared-then-assigned definite-assignment question.**
  ```dart
    /// Writes [xfile]'s bytes under `photos/<photoId><ext>` and derives + stores
    /// a downscaled thumbnail under `thumbs/<photoId>.jpg`.
    ///
    /// L3 fix (silent data loss): the ORIGINAL's byte write is NO LONGER
    /// best-effort. It used to sit inside a `catch (_) { return key; }`, so a
    /// browser that refused the write still handed back a key that
    /// `LibraryCrudRepository.attachPhotoToWall` then persisted as a `Photos`
    /// row's `localPath` — a pixel-less row, i.e. a topo whose photo is
    /// permanently a placeholder, with nothing anywhere reporting why. Quota
    /// exhaustion is the realistic trigger and it is reachable in ORDINARY use
    /// because originals are never downscaled (decision D-5): `pickPhotoFrom`
    /// passes no `imageQuality`/`maxWidth` and this backend stores
    /// `readAsBytes()` verbatim; only the 512px/q80 thumbnail is shrunk.
    ///
    /// Any failure now throws a [PhotoWriteException], classified via
    /// [classifyPhotoWriteFailure] so a quota exhaustion is distinguishable and
    /// user-presentable. `attachPhotoToWall` awaits this call BEFORE opening its
    /// insert transaction, so a throw here means no row is ever written and
    /// there is nothing to clean up.
    ///
    /// The THUMBNAIL write stays best-effort (see
    /// [_writeThumbnailBestEffort]) — mirroring the native backend, and because
    /// a thumbnail is derivable and disposable.
    Future<String> importPhoto(XFile xfile, String photoId) async {
      final ext = p.extension(xfile.name).isNotEmpty
          ? p.extension(xfile.name)
          : '.jpg';
      final key = p.join('photos', '$photoId$ext');
      try {
        final bytes = await xfile.readAsBytes();
        await _store.writeBytes(key, bytes);
        await _writeThumbnailBestEffort(key, bytes);
        return key;
      } catch (e) {
        throw PhotoWriteException(
          failure: classifyPhotoWriteFailure(e),
          key: key,
          cause: e,
        );
      }
    }

    /// Best-effort thumbnail for the just-written original at [key]. NEVER
    /// throws, which is what keeps it safe to call from inside [importPhoto]'s
    /// single try block: a thumbnail is always regenerable and the photo strip /
    /// `PhotoImageCache` fall back to the original, so a failed thumbnail must
    /// never turn into a failed import. Mirrors the native backend's
    /// `_writeThumbnailBestEffort`.
    Future<void> _writeThumbnailBestEffort(String key, Uint8List bytes) async {
      try {
        final thumbBytes = await generateThumbnail(bytes);
        await _store.writeBytes(thumbKeyFor(key), thumbBytes);
      } catch (_) {
        // Best-effort — never blocks importPhoto/writePhotoBytes.
      }
    }
  ```

- [ ] **Step 4: Replace `writePhotoBytes` (currently lines 45-64) in the same file so the cloud-restore write is classified too, and reuse the new helper.**
  ```dart
    /// Writes [bytes] under `photos/<photoId><ext>` and regenerates + stores its
    /// thumbnail, mirroring [importPhoto]'s convention. This is the counterpart
    /// used for cloud restore, where bytes arrive already decoded in memory
    /// rather than as a picked [XFile].
    ///
    /// L3 fix (continued): the byte write already propagated its raw store error
    /// here — now it propagates a CLASSIFIED [PhotoWriteException] instead, so
    /// `SyncService._downloadAndRewritePhotos`' caller records a quota
    /// exhaustion as such in `PullResult.errors` rather than an opaque
    /// `DatabaseError` string.
    Future<String> writePhotoBytes(
      String photoId,
      String ext,
      List<int> bytes,
    ) async {
      final key = p.join('photos', '$photoId$ext');
      final byteData = Uint8List.fromList(bytes);
      try {
        await _store.writeBytes(key, byteData);
      } catch (e) {
        throw PhotoWriteException(
          failure: classifyPhotoWriteFailure(e),
          key: key,
          cause: e,
        );
      }
      await _writeThumbnailBestEffort(key, byteData);
      return key;
    }
  ```

- [ ] **Step 5: Add the exception import to `photo_files_web.dart` (after `import 'photo_byte_store.dart';` on line 7) and update the class doc's "best-effort" claim.**
  ```dart
  // lib/features/topo/data/photo_files_web.dart — imports (lines 1-8) become:
  import 'dart:typed_data';

  import 'package:image_picker/image_picker.dart';
  import 'package:path/path.dart' as p;

  import 'image_ops/image_ops.dart';
  import 'photo_byte_store.dart';
  import 'photo_path_resolution.dart';
  import 'photo_write_exception.dart';

  // …and in the class doc (lines 10-14) replace the sentence fragment
  // "Best-effort, mirroring the native backend's contract: any failure is
  // swallowed and the logical key is still returned." — that text lives on
  // importPhoto's own doc and is replaced wholesale by the new doc above.
  ```

- [ ] **Step 6: Add the native-backend doc note. Comment-only: native behaviour must stay bit-identical.**
  ```dart
  // lib/features/topo/data/photo_files_native.dart — append to importPhoto's
  // doc comment (immediately before `Future<String> importPhoto` at line 90):

    /// DELIBERATELY still best-effort, unlike the WEB backend (see
    /// `photo_files_web.dart`'s L3 fix): this backend never throws
    /// [PhotoWriteException]. The two are not symmetric, and that is correct —
    /// here the picked file still exists at [xfile]'s own path even when the
    /// copy into the app-owned directory fails, and `resolvePhotoPath`'s
    /// container-rotation healing can recover it later; on web the byte store IS
    /// the only copy, so a failed write means the pixels do not exist anywhere.
    /// The shared callers' `on PhotoWriteException` clauses are therefore dead
    /// code on native, by design — native behaviour is unchanged by that fix.
  ```

- [ ] **Step 7: Add the store-level companion test to `test/features/topo/data/photo_byte_store_test.dart` (append inside `main()`, after the existing 'distinct keys do not collide' test at lines 70-76), proving the REAL IdbPhotoByteStore surfaces a write error rather than resolving silently — the failure importPhoto now propagates.**
  ```dart
    test(
      'writeBytes surfaces a store-side failure rather than resolving silently '
      '— this is the failure PhotoFiles.importPhoto now propagates as a '
      'PhotoWriteException instead of swallowing (L3)',
      () async {
        final factory = newIdbFactoryMemory();
        final store = IdbPhotoByteStore(factory: factory);
        // Force the write into a store that does not exist: a real IndexedDB
        // transaction against a missing object store rejects, exactly like a
        // quota rejection does from this method's point of view.
        final db = await factory.open(
          kPhotoByteStoreDbName,
          version: 1,
          onUpgradeNeeded: (event) {
            // Deliberately create NOTHING, so `kPhotoByteStoreName` is absent.
          },
        );
        addTearDown(db.close);

        await expectLater(
          store.writeBytes('photos/abc.jpg', Uint8List.fromList([1, 2, 3])),
          throwsA(anything),
        );
      },
    );
  ```

- [ ] **Step 8: Run both files and see them pass.**
  > Corrected (Miscount — the fragment says "8 web-backend"; the block in Step 1 contains **7** tests (5 in the `importPhoto` group, 2 in the `writePhotoBytes` group). The byte-store "8" is correct: 7 existing tests (`grep -c "  test("` = 7) plus the 1 added in Step 7)

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/topo/data/photo_files_web_test.dart test/features/topo/data/photo_byte_store_test.dart
  ```
  Expected: `All tests passed!` — **7** web-backend tests + **8** byte-store tests.

- [ ] **Step 9: **Keep the scripted fallback (D-23).** If the new byte-store test does not reject — `idb_shim`'s memory factory may auto-create the missing object store, or the pre-opened DB may not be the one the store binds to — **delete that ONE test rather than weakening it.** The web-backend tests already cover the propagation contract with an injected failing store, and that is the assertion that matters. Note the deletion in the commit body. Do not replace it with a looser matcher, and do not spend time trying to make the memory factory reject.**
  > Corrected (D-23 — kept verbatim as a first-class step, with the "do not weaken" instruction made explicit)

  Expected: Either the test is green, or it is removed and `flutter test test/features/topo/data/` is green with the web-backend file carrying the contract.

- [ ] **Step 10: Run the whole suite plus analyze to confirm nothing regressed — in particular that no native/other caller depended on importPhoto never throwing. Then commit.**
  > Corrected (D-13 — absolute total replaced by baseline + N)

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter analyze && flutter test
  ```
  Expected: `No issues found!` · `flutter test` green at **baseline + 8** (or **+7** if the byte-store test was removed in Step 9). Native tests are unaffected because `photo_files_native.dart` is byte-identical apart from a doc comment.

**Assertions:**

- `flutter test test/features/topo/data/photo_files_web_test.dart` is green with **7** tests and includes a test where a `_FailingWriteStore` makes `importPhoto` throw `PhotoWriteException(failure: quotaExceeded, key: 'photos/abc123.jpg')` with `store.written` left EMPTY.
- A `thumbs/`-only write failure still lets `importPhoto` return `'photos/abc123.jpg'` — the thumbnail remains best-effort.
- `PhotoFiles.writePhotoBytes` throws `PhotoWriteException` (not a bare `DatabaseError`) when its store write fails.
- `git diff lib/features/topo/data/photo_files_native.dart` shows **comment-only** changes — no executable line differs, so native behaviour is bit-identical.
- `grep -c 'catch (_)' lib/features/topo/data/photo_files_web.dart` no longer counts a catch-all around the ORIGINAL's write: the only remaining `catch (_)` is inside `_writeThumbnailBestEffort`, plus `deletePhotoBytes`' two existing ones.
- The extracted private helper is named exactly `_writeThumbnailBestEffort`, matching `photo_files_native.dart:119` (duplication #7 — deliberate; do not flag as duplication).
- `flutter analyze` = 0 issues; `flutter test` green at **baseline + 8** (or **+7** if D-23's fallback fired), never gated on an absolute total (D-13).

**Commit message:** `fix(photos): propagate byte-write failures from the web PhotoFiles backend (L3)`

### Task 3: `attachPhotoToWall` creates NO `Photos` row when the byte write fails

**Files:**
- Modify: `test/features/library/data/photo_ownership_test.dart:1-103`; `lib/features/library/data/library_crud_repository.dart:571-573` *(doc comment only)*
- Test: `test/features/library/data/photo_ownership_test.dart`

**Interfaces:**
- Produces: the regression lock that `attachPhotoToWall` rethrows `PhotoWriteException` and leaves the `photos` table empty; a corrected `attachPhotoToWall` doc comment naming both caller-side handlers.
- Consumes: `PhotoWriteException`/`PhotoWriteFailure` (Task 1, via the `photo_files.dart` facade already imported at `photo_ownership_test.dart:7`); `LibraryCrudRepository.attachPhotoToWall` (`library_crud_repository.dart:584`, whose `importPhoto` await is at `:592` — **before** the transaction at `:601`); the file's own `seedWall()` (`:62`) / `writeSource()` (`:42`) / `photosDirPath()` (`:38`) helpers; `_testWallId` (`:21`).

> **Ordering:** this task is **doc-comment only** on `library_crud_repository.dart`, but §1e Task 3 makes *code* changes to the same file. Land this first, or rebase it. Never parallel.

- [ ] **Step 1: Add the failing PhotoFiles double to `test/features/library/data/photo_ownership_test.dart` as a top-level file-private class (place it directly after the `_testWallId` const at line 21).**
  ```dart
  /// [PhotoFiles] whose [importPhoto] always fails the way the WEB backend now
  /// does when the browser refuses the byte write (see `photo_files_web.dart`'s
  /// L3 fix). Every other member is inherited, so the rest of the repository's
  /// real path handling still runs.
  ///
  /// `PhotoFiles` is resolved by the ANALYZER to `photo_files_stub.dart` (the
  /// unconditional branch of the `photo_files.dart` facade, whose ctor is
  /// `PhotoFiles({Object? docsDir, Object? byteStore})`) and by the VM compiler
  /// to `photo_files_native.dart` (`PhotoFiles({Future<Directory> Function()?
  /// docsDir})`). Both declare `importPhoto(XFile, String) -> Future<String>`
  /// identically and both accept a zero-argument `super()`, so this subclass
  /// binds under either — see `photo_files_stub.dart`'s own doc for why the
  /// variants are kept signature-compatible.
  class _QuotaFailingPhotoFiles extends PhotoFiles {
    @override
    Future<String> importPhoto(XFile xfile, String photoId) async {
      throw PhotoWriteException(
        failure: PhotoWriteFailure.quotaExceeded,
        key: 'photos/$photoId.jpg',
        cause: Exception('QuotaExceededError: The quota has been exceeded.'),
      );
    }
  }
  ```

- [ ] **Step 2: Add the failing test group. Insert after the existing `group('PhotoFiles helper', …)` block, which currently ends at line 103.**
  ```dart
    group('L3: a failed byte write creates no Photos row', () {
      test(
        "attachPhotoToWall rethrows PhotoFiles.importPhoto's "
        'PhotoWriteException and leaves the photos table EMPTY — the insert '
        'transaction is never reached, so a pixel-less row can no longer exist',
        () async {
          final wall = await seedWall();
          final failingRepo = LibraryCrudRepository(
            db,
            nowMs: () => 1000,
            photoFiles: _QuotaFailingPhotoFiles(),
          );

          await expectLater(
            failingRepo.attachPhotoToWall(
              wall.id,
              XFile(p.join(srcDir.path, 'picked.jpg')),
              640,
              480,
            ),
            throwsA(
              isA<PhotoWriteException>().having(
                (e) => e.failure,
                'failure',
                PhotoWriteFailure.quotaExceeded,
              ),
            ),
          );

          expect(
            await db.select(db.photos).get(),
            isEmpty,
            reason: 'no Photos row may be created when the pixels were never '
                'written (L3) — attachPhotoToWall awaits importPhoto BEFORE its '
                'insert transaction, which is what makes this hold',
          );
        },
      );

      test(
        'the wall itself is untouched — the caller decides whether to undo it '
        "(topos_screen's New topo flow soft-deletes the wall it just created; "
        'the canvas flow has no wall to undo)',
        () async {
          final wall = await seedWall();
          final failingRepo = LibraryCrudRepository(
            db,
            nowMs: () => 1000,
            photoFiles: _QuotaFailingPhotoFiles(),
          );

          await expectLater(
            failingRepo.attachPhotoToWall(wall.id, XFile('/tmp/x.jpg'), 1, 1),
            throwsA(isA<PhotoWriteException>()),
          );

          final row = await (db.select(db.walls)
                ..where((t) => t.id.equals(wall.id)))
              .getSingle();
          expect(row.deletedAt, isNull);
        },
      );
    });
  ```

- [ ] **Step 3: Run it. It should already PASS — `attachPhotoToWall` awaits `importPhoto` at line 592, before the transaction at 601. This task's value is locking that ordering in; if it FAILS, the ordering has drifted and the fix is to move the `importPhoto` await above the transaction.**
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/library/data/photo_ownership_test.dart
  ```
  Expected: All tests passed! — including the two new L3 tests. (Green-on-first-run is expected here and is the point: the guarantee is now regression-locked.)

- [ ] **Step 4: Prove the test is meaningful rather than vacuous by temporarily moving the `importPhoto` await INSIDE the transaction and re-running.**
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/library/data/photo_ownership_test.dart --plain-name 'leaves the photos table EMPTY'
  ```
  Expected: With the await moved inside the transaction the test still passes (drift rolls the transaction back on a throw) — record this in the commit body. The test's real job is guarding against a future refactor that catches the exception and inserts anyway; note that explicitly rather than claiming it catches ordering drift. Restore the file to HEAD afterwards with `git checkout -- lib/features/library/data/library_crud_repository.dart`.

- [ ] **Step 5: Correct `attachPhotoToWall`'s now-false doc claim. Replace lines 571-573 ("The copy is best-effort: if the source doesn't exist (or the copy fails), [PhotoFiles.importPhoto] returns [xfile]'s path unchanged so the row is still created.").**
  ```dart
    /// The copy is best-effort ON NATIVE only: if the source doesn't exist (or
    /// the copy fails) [PhotoFiles.importPhoto] still returns the relative
    /// destination form, so the row is created and the picker's own file remains
    /// recoverable via `resolvePhotoPath`'s container-rotation healing.
    ///
    /// On WEB it is NOT best-effort (L3 fix): the byte store is the only copy of
    /// the pixels, so a refused write — quota exhaustion above all, since
    /// originals stay at FULL resolution per decision D-5 — throws a
    /// [PhotoWriteException] out of [PhotoFiles.importPhoto], which this method
    /// deliberately does NOT catch. Because that await happens BEFORE the insert
    /// transaction below, the throw means no [db.Photos] row is ever created:
    /// there is no such thing as a pixel-less row any more. Callers must handle
    /// it — see `topos_screen.dart`'s `_handleNewTopo` (which soft-deletes the
    /// wall it had just created) and `topo_canvas_screen.dart`'s
    /// `_attachPhotoAndLoad` (which clears the optimistically-selected path);
    /// both present [PhotoWriteException.userMessage] via
    /// `photoWriteFailureSnackBar`.
  ```

- [ ] **Step 6: Re-run the affected suites and analyze, then commit.**
  > Corrected (D-13 — a baseline + N gate added)

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter analyze && flutter test test/features/library/ test/features/topo/
  ```
  Expected: analyze: No issues found! · both directories green. `flutter test` green at **baseline + 2**.

**Assertions:**

- `flutter test test/features/library/data/photo_ownership_test.dart` is green and contains a test where `attachPhotoToWall` with a `PhotoFiles` whose `importPhoto` throws `PhotoWriteException` results in `db.select(db.photos).get()` being EMPTY.
- The same test asserts the exception surfaces to the caller as `PhotoWriteException` with `failure == PhotoWriteFailure.quotaExceeded` (not swallowed, not rewrapped).
- The wall passed to `attachPhotoToWall` still has `deletedAt == null` after the failure — cleanup is the caller's decision, asserted separately.
- `library_crud_repository.dart`'s `attachPhotoToWall` doc no longer claims the row 'is still created' when the copy fails, and names both caller-side handlers.
- `git diff --stat lib/features/library/data/library_crud_repository.dart` shows doc-comment lines only — zero executable change.
- `flutter analyze` = 0 issues.
- `flutter test` is green at **baseline + 2** for this task (D-13 — never an absolute total).

**Commit message:** `test(photos): lock in that a failed byte write creates no Photos row (L3)`

### Task 4: The user-facing half — `photoWriteFailureSnackBar` + `settleFailedPhotoAttach`

**Files:**
- Create: `test/features/topo/presentation/photo_write_failure_snackbar_test.dart`
- Modify: `lib/features/topo/presentation/topo_canvas_photo_ops.dart:1-5` (imports) and `:139` (append); `test/features/topo/application/topo_canvas_wall_binding_test.dart:1-11` (imports) + `main()` (append)
- Test: `test/features/topo/presentation/photo_write_failure_snackbar_test.dart`, `test/features/topo/application/topo_canvas_wall_binding_test.dart`

**Interfaces:**
- Produces: `SnackBar photoWriteFailureSnackBar(PhotoWriteException error)` and `SnackBar settleFailedPhotoAttach(SelectedImageNotifier, DrawController, int generation, PhotoWriteException)` — both in `topo_canvas_photo_ops.dart`, and therefore both reachable through `topo_canvas_screen.dart`'s existing `export 'topo_canvas_photo_ops.dart';` (`:43`), which is how Task 6 imports them.
- Consumes: `PhotoWriteException.userMessage` (Task 1); `MasiIcon(String name, {double? size, Color? color, bool tinted})` (`lib/shared/presentation/masi_icon.dart:21` — **verified `:21`, not `:22`; the constructor IS `const`**); `gpsCaptureResultSnackBar`'s exact body shape (`topo_canvas_gps.dart:135-149`); `SelectedImageNotifier.clear()` and `selectedImageProvider` (`topo_canvas_photo_ops.dart:8-18`); `DrawController.beginPhotoSwitch()` (`draw_controller.dart:923`) / `cancelPhotoSwitch(int)` (`:989`); `DrawState.isSwitchingPhoto` (`:149`) / `switchGeneration` (`:165`); `makeContainer()` + `_testWallId` in `topo_canvas_wall_binding_test.dart` (**`:40-49` and `:35` — the fragment's `34-51` drifted**).

> **Icons:** the SnackBar uses `MasiIcon('warning', size: 18)`. No `Icons.X`/`CupertinoIcons.X` appears anywhere in this fragment; the only `Icons.` strings in this document are inside the grep assertion that forbids them.

- [ ] **Step 1: Write the failing SnackBar widget test. Two pumps, never `pumpAndSettle` — settling would run the SnackBar's full 4s duration and exit animation and take it off-screen before any assertion (the same trap `topos_screen_test.dart`'s `_drainNoSettle` doc documents at :256-266).**
  ```dart
  // test/features/topo/presentation/photo_write_failure_snackbar_test.dart
  // The user-facing half of the L3 fix: a failed photo byte write must surface
  // as a distinguishable, plainly-worded SnackBar — not a debugPrint nobody but
  // a developer attached to a debugger would ever see.
  import 'package:flutter/material.dart';
  import 'package:flutter_test/flutter_test.dart';
  import 'package:masi/features/topo/data/photo_write_exception.dart';
  import 'package:masi/features/topo/presentation/topo_canvas_photo_ops.dart';
  import 'package:masi/shared/presentation/masi_icon.dart';

  /// Pumps a trivial host, taps it to show [snackBar], and advances just far
  /// enough INTO the entrance animation to assert on it. Deliberately NOT
  /// `pumpAndSettle`: that runs the SnackBar's entrance, its full 4s default
  /// duration AND its exit to completion, settling it off-screen before any
  /// `find` could see it (same reasoning as `topos_screen_test.dart`'s
  /// `_drainNoSettle`).
  Future<void> _showSnackBar(WidgetTester tester, SnackBar snackBar) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              key: const Key('show'),
              onPressed: () =>
                  ScaffoldMessenger.of(context).showSnackBar(snackBar),
              child: const Text('show'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('show')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  void main() {
    testWidgets('a quota failure renders its own out-of-space wording behind a '
        'warning glyph', (tester) async {
      await _showSnackBar(
        tester,
        photoWriteFailureSnackBar(
          const PhotoWriteException(
            failure: PhotoWriteFailure.quotaExceeded,
            key: 'photos/abc.jpg',
          ),
        ),
      );

      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.textContaining('Out of storage space'), findsOneWidget);
      expect(find.byType(MasiIcon), findsOneWidget);
    });

    testWidgets('an unknown failure renders the plain retry wording', (
      tester,
    ) async {
      await _showSnackBar(
        tester,
        photoWriteFailureSnackBar(
          const PhotoWriteException(
            failure: PhotoWriteFailure.unknown,
            key: 'photos/abc.jpg',
          ),
        ),
      );

      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.textContaining('could not be saved'), findsOneWidget);
    });

    testWidgets('the two variants are visibly different, so a quota problem is '
        'actionable rather than generic', (tester) async {
      await _showSnackBar(
        tester,
        photoWriteFailureSnackBar(
          const PhotoWriteException(
            failure: PhotoWriteFailure.quotaExceeded,
            key: 'photos/abc.jpg',
          ),
        ),
      );

      expect(find.textContaining('could not be saved'), findsNothing);
    });
  }
  ```

- [ ] **Step 2: Run it and see it fail to compile (`photoWriteFailureSnackBar` does not exist).**
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/topo/presentation/photo_write_failure_snackbar_test.dart
  ```
  Expected: RED: "Error: The method 'photoWriteFailureSnackBar' isn't defined".

- [ ] **Step 3: Extend `topo_canvas_photo_ops.dart`'s imports (currently lines 1-5) — it has no material import yet.**
  ```dart
  // lib/features/topo/presentation/topo_canvas_photo_ops.dart — lines 1-5 become:
  import 'package:flutter/material.dart';
  import 'package:flutter_riverpod/flutter_riverpod.dart';

  import 'package:masi/features/library/data/library_crud_repository.dart';
  import 'package:masi/features/topo/application/draw_controller.dart';
  import 'package:masi/features/topo/data/photo_repository.dart';
  import 'package:masi/features/topo/data/photo_write_exception.dart';
  import 'package:masi/shared/presentation/masi_icon.dart';
  ```

- [ ] **Step 4: Append both functions to the end of `topo_canvas_photo_ops.dart` (after `resolveAttachedPhotoPath`, which currently ends at line 139).**
  ```dart
  /// A [SnackBar] presenting [error]'s [PhotoWriteException.userMessage] behind a
  /// warning glyph — the user-facing half of the L3 fix, replacing a
  /// `debugPrint` no user could ever see.
  ///
  /// Mirrors `topo_canvas_gps.dart`'s [gpsCaptureResultSnackBar] shape so both
  /// photo-attach outcomes read identically, and lives HERE rather than inline in
  /// either screen because BOTH photo-attach entry points must present the same
  /// words for the same failure: the Topos-home "New topo" flow
  /// (`topos_screen.dart`'s `_handleNewTopo`) and the canvas add/replace-photo
  /// flow (`topo_canvas_screen.dart`'s `_attachPhotoAndLoad`).
  SnackBar photoWriteFailureSnackBar(PhotoWriteException error) {
    return SnackBar(
      content: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          MasiIcon('warning', size: 18),
          const SizedBox(width: 8),
          Flexible(child: Text(error.userMessage)),
        ],
      ),
    );
  }

  /// Settles the canvas after a photo attach failed on its BYTE WRITE, and
  /// returns the [SnackBar] the caller should show.
  ///
  /// Three things must happen together, which is exactly why they live in one
  /// function rather than three lines in a catch block:
  ///  - [selectedImage] is CLEARED. `TopoCanvasScreen._pickImage` selects the
  ///    picked path optimistically (so the screen shows a spinner for it
  ///    immediately), but with the write failed there is no [db.Photos] row
  ///    behind that path and never will be — leaving it selected strands the
  ///    canvas on an image it can neither load nor persist against.
  ///  - [drawController]'s switch [generation] is settled via
  ///    [DrawController.cancelPhotoSwitch]. See `_attachPhotoAndLoad`'s FIX #4
  ///    doc: EVERY exit path must settle the switch it opened, or
  ///    `DrawState.isSwitchingPhoto` stays stuck `true` and corrupts the next
  ///    `beginPhotoSwitch`'s routes handling.
  ///  - the user is told why, in plain words.
  ///
  /// Extracted as a standalone function taking its collaborators directly —
  /// mirroring [loadWallOriginalPhoto]/[resolveAttachedPhotoPath] above —
  /// because `TopoCanvasScreen._pickImage` calls the module-level
  /// `showPhotoSourceSheet`/`pickPhotoFrom` with NO injectable seam, so a widget
  /// test cannot drive the canvas pick flow at all. This makes the failure path
  /// testable against a plain `ProviderContainer` instead (see
  /// `test/features/topo/application/topo_canvas_wall_binding_test.dart`).
  SnackBar settleFailedPhotoAttach(
    SelectedImageNotifier selectedImage,
    DrawController drawController,
    int generation,
    PhotoWriteException error,
  ) {
    selectedImage.clear();
    drawController.cancelPhotoSwitch(generation);
    return photoWriteFailureSnackBar(error);
  }
  ```

- [ ] **Step 5: Run the SnackBar test and see it pass.**
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/topo/presentation/photo_write_failure_snackbar_test.dart
  ```
  Expected: `+3: All tests passed!` (a genuine per-file count — 3 `testWidgets`).

- [ ] **Step 6: Add the container-level state test to `test/features/topo/application/topo_canvas_wall_binding_test.dart`. First extend its imports (lines 1-11) with material and the exception type; `selectedImageProvider` and `settleFailedPhotoAttach` already resolve through the existing `topo_canvas_screen.dart` import, which re-exports `topo_canvas_photo_ops.dart` (see that file's line 43).**
  ```dart
  // add to the import block:
  import 'package:flutter/material.dart';
  import 'package:masi/features/topo/data/photo_write_exception.dart';
  ```

- [ ] **Step 7: Append the test inside `main()` of `topo_canvas_wall_binding_test.dart`.**
  ```dart
    test(
      'L3: settleFailedPhotoAttach clears the selected image, settles the switch '
      'generation the failed attach opened (isSwitchingPhoto back to false), and '
      'hands back a SnackBar — the canvas failure path no widget test can reach, '
      'since TopoCanvasScreen._pickImage has no injectable picker seam',
      () async {
        final container = makeContainer();
        final notifier = container.read(
          drawControllerProvider(_testWallId).notifier,
        );

        // Exactly what _pickImage + build's ref.listen do before the attach:
        // select the picked path optimistically, which opens a photo switch.
        container.read(selectedImageProvider.notifier).select('/tmp/picked.jpg');
        final generation = notifier.beginPhotoSwitch();
        expect(
          container.read(drawControllerProvider(_testWallId)).isSwitchingPhoto,
          isTrue,
          reason: 'precondition: the switch this attach would settle is open',
        );

        final snackBar = settleFailedPhotoAttach(
          container.read(selectedImageProvider.notifier),
          notifier,
          generation,
          const PhotoWriteException(
            failure: PhotoWriteFailure.quotaExceeded,
            key: 'photos/abc.jpg',
          ),
        );

        expect(
          container.read(selectedImageProvider),
          isNull,
          reason: 'no Photos row was created, so the canvas must not keep '
              'showing the picked path',
        );
        expect(
          container.read(drawControllerProvider(_testWallId)).isSwitchingPhoto,
          isFalse,
          reason: 'a stuck isSwitchingPhoto corrupts the NEXT beginPhotoSwitch '
              "— see _attachPhotoAndLoad's FIX #4 doc",
        );
        expect(snackBar, isA<SnackBar>());
      },
    );
  ```

- [ ] **Step 8: Run both test files and analyze.**
  > Corrected (D-13 — a baseline + N gate added)

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter analyze && flutter test test/features/topo/presentation/photo_write_failure_snackbar_test.dart test/features/topo/application/topo_canvas_wall_binding_test.dart
  ```
  Expected: `No issues found!` · both files green (3 new SnackBar tests + the existing wall-binding suite plus 1). `flutter test` green at **baseline + 4**.

- [ ] **Step 9: If `flutter analyze` reports `prefer_const_constructors` on `MasiIcon('warning', size: 18)`, add `const`. The constructor at `masi_icon.dart:21` IS `const`, but the identical `MasiIcon('pin', size: 18)` call site in `gpsCaptureResultSnackBar` (`topo_canvas_gps.dart:142`) sits at 0 issues today, so the lint is evidently not firing for this shape — match that call site and leave it non-const unless the analyzer says otherwise. Then commit.**
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter analyze lib/features/topo/presentation/topo_canvas_photo_ops.dart
  ```
  Expected: No issues found!

**Assertions:**

- `flutter test test/features/topo/presentation/photo_write_failure_snackbar_test.dart` is green with 3 tests; the quota variant renders text containing 'Out of storage space' and the unknown variant text containing 'could not be saved', and the quota variant does NOT render the unknown wording.
- `find.byType(MasiIcon)` finds the warning glyph in the rendered SnackBar — no `Icons.*`/`CupertinoIcons.*` is introduced anywhere in the diff (`grep -n 'Icons\.' lib/features/topo/presentation/topo_canvas_photo_ops.dart` is empty).
- `flutter test test/features/topo/application/topo_canvas_wall_binding_test.dart` is green and includes a test where, after `settleFailedPhotoAttach`, `container.read(selectedImageProvider)` is null AND `container.read(drawControllerProvider(_testWallId)).isSwitchingPhoto` is false.
- `photoWriteFailureSnackBar` and `settleFailedPhotoAttach` are reachable from `package:masi/features/topo/presentation/topo_canvas_screen.dart` via its existing `export 'topo_canvas_photo_ops.dart';` (line 43) — verifiable because `topos_screen.dart` will import them through that facade in T6.
- `flutter analyze` = 0 issues.
- `flutter test` is green at **baseline + 4** for this task (D-13).

**Commit message:** `feat(topo): add photoWriteFailureSnackBar + settleFailedPhotoAttach for failed photo writes`

### Task 5: Wire the canvas add/replace-photo flow to the failure path

**Files:**
- Modify: `lib/features/topo/presentation/topo_canvas_screen.dart:22` (import), `:593-614` (doc), `:682` (new clause immediately above the catch-all)
- Test: `test/features/topo/application/draw_controller_persistence_test.dart`, `test/features/topo/application/topo_canvas_wall_binding_test.dart` — both pre-existing. **This task adds no new test**, deliberately: its only state effects go through `settleFailedPhotoAttach`, which Task 4's container test already asserts.

**Interfaces:**
- Produces: an `on PhotoWriteException catch (e)` clause inside `_attachPhotoAndLoad`, positioned **above** the catch-all so Dart's top-down clause matching reaches it.
- Consumes: `settleFailedPhotoAttach` (Task 4); `PhotoWriteException` (Task 1); `_attachPhotoAndLoad`'s existing `generation` local (`:616-617`); the `try` opened at `:618`; the catch-all at `:682`; the FIX #4 doc at `:593-614` — **all four anchors verified exact**.

- [ ] **Step 1: Add the exception import to `topo_canvas_screen.dart`, immediately after `import 'package:masi/features/topo/data/photo_repository.dart';` (line 22).**
  ```dart
  import 'package:masi/features/topo/data/photo_write_exception.dart';
  ```

- [ ] **Step 2: Insert a typed catch clause into `_attachPhotoAndLoad` BEFORE the existing catch-all. The existing clause starts at line 682 with `} catch (e, st) {` — the new clause goes immediately above it, closing the try that opened at line 618.**
  ```dart
      } on PhotoWriteException catch (e) {
        // L3 fix: attachPhotoToWall PROPAGATES a byte-write failure now (quota
        // exhaustion above all — originals stay FULL resolution per decision
        // D-5) and throws BEFORE its insert transaction, so no Photos row was
        // created and there is nothing to undo in the database. What DOES need
        // undoing is the optimistic UI: _pickImage already selected the picked
        // path so this screen would show a spinner for an image that will never
        // have a row. settleFailedPhotoAttach clears it, settles the switch
        // generation THIS call opened (see this method's FIX #4 doc — every exit
        // path must), and hands back the SnackBar to show. Deliberately caught
        // ABOVE the generic clause below so a quota problem gets its own
        // actionable wording instead of the silent debugPrint every other
        // failure still gets. Only while mounted — see this method's doc for why
        // `ref` is unsafe to touch otherwise.
        debugPrint('Failed to store photo bytes for ${xfile.path}: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            settleFailedPhotoAttach(
              ref.read(selectedImageProvider.notifier),
              ref.read(drawControllerProvider(widget.wallId).notifier),
              generation,
              e,
            ),
          );
        }
      } catch (e, st) {
  ```

- [ ] **Step 3: Extend `_attachPhotoAndLoad`'s doc comment (the FIX #4 paragraph at lines 593-614) so the new exit path is documented alongside the others it enumerates.**
  ```dart
    /// L3 fix (photo-byte write failures): a [PhotoWriteException] out of
    /// [LibraryCrudRepository.attachPhotoToWall] is caught in its OWN clause,
    /// above the catch-all — it is the one failure with a specific, actionable
    /// cause to tell the user about (out of storage space), and it is the one
    /// failure that additionally requires clearing `selectedImageProvider`,
    /// since the optimistically-selected picked path has no row behind it and
    /// never will. Both effects plus the SnackBar come from the single
    /// [settleFailedPhotoAttach] call, which settles [generation] exactly like
    /// every other exit path in this method must.
  ```

- [ ] **Step 4: Verify the typed clause precedes the catch-all in the compiled order (Dart matches clauses top-down, so an inverted order would silently swallow the typed case).**
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && grep -n 'on PhotoWriteException catch\|} catch (e, st) {' lib/features/topo/presentation/topo_canvas_screen.dart
  ```
  Expected: The `on PhotoWriteException catch (e) {` line number is LOWER than the `} catch (e, st) {` line that follows it inside _attachPhotoAndLoad.

- [ ] **Step 5: Confirm the pre-existing catch-all contract still holds: `draw_controller_persistence_test.dart:1442-1460` asserts that when attachPhotoToWall/loadForWall throw, the switch is still settled. That test uses a generic throw, so it must still take the catch-all branch.**
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/topo/application/draw_controller_persistence_test.dart
  ```
  Expected: All tests passed! — the generic-throw path is unchanged.

- [ ] **Step 6: Run analyze and the whole topo feature suite, then commit.**
  > Corrected (D-13 — a baseline + N gate added; this task's N is 0)

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter analyze && flutter test test/features/topo/
  ```
  Expected: analyze: No issues found! · test/features/topo/ green. `flutter test` green at **baseline + 0** — this task adds no test.

**Assertions:**

- `grep -n 'on PhotoWriteException catch' lib/features/topo/presentation/topo_canvas_screen.dart` returns exactly one hit, at a LOWER line number than the `} catch (e, st) {` clause it precedes inside `_attachPhotoAndLoad`.
- The new clause's only state effects go through `settleFailedPhotoAttach`, whose two effects (selected image cleared, `isSwitchingPhoto` false) are already asserted by T4's container test — no duplicate inline `clear()`/`cancelPhotoSwitch()` calls appear in the clause (`grep -c 'cancelPhotoSwitch' lib/features/topo/presentation/topo_canvas_screen.dart` is unchanged from HEAD).
- `flutter test test/features/topo/application/draw_controller_persistence_test.dart` is still green — the generic catch-all path (the one that test drives) is untouched.
- `flutter analyze` = 0 issues and `flutter test test/features/topo/` is green.
- Native runtime behaviour is unchanged: `photo_files_native.dart` never throws `PhotoWriteException` (asserted by T2), so the new clause is unreachable on iOS/Android.
- `flutter test` is green at **baseline + 0** — this task adds no test; its two state effects are already covered by Task 4's container test, deliberately (D-13).

**Commit message:** `fix(topo): surface a failed photo byte write on the canvas instead of a debugPrint`

### Task 6: Wire the Topos-home New topo flow, with orphan-wall cleanup

> ### §1a Task 4 MUST land before this task
> Both modify `lib/features/library/presentation/topos_screen.dart` **and** `test/features/library/presentation/topos_screen_test.dart`. §1a adds the storage-durability import, the `part 'topos_storage_banner.dart';` directive, the `canCreate` gate, the banner render call, a third `_handleNewTopo` guard, and the `storageDurability` parameter + `_FakeStorageDurability` double in `_makeContainer`. This task then appends to that same `_makeContainer` and that same `_handleNewTopo`. **Never run these two concurrently** — the repo rule is that parallel implementers must be strictly file-disjoint, and a concurrent edit here means a git-stash recovery.

**Files:**
- Modify: `lib/features/library/presentation/topos_screen.dart:22-23` (imports), `:412-415` (doc), `:478-480` (guarded attach); `test/features/library/presentation/topos_screen_test.dart:123-142` (`_makeContainer`), `:148` (new double), `:32` (import), `:871` (`A6` group)
- Test: `test/features/library/presentation/topos_screen_test.dart`

**Interfaces:**
- Produces: `_handleNewTopo`'s `on PhotoWriteException` clause with `softDeleteWall` orphan cleanup; `_makeContainer`'s `PhotoFiles? photoFiles` parameter — the **fourth and last** parameter of the reconciled union signature.
- Consumes: `photoWriteFailureSnackBar` (Task 4, via `topo_canvas_screen.dart`'s re-export at `:43`); `PhotoWriteException` (Task 1); `LibraryCrudRepository.softDeleteWall` (`library_crud_repository.dart:389`); `photoFilesProvider` (`lib/core/db/database_provider.dart:47`); **§1a Task 4's** `storageDurability` parameter and `_FakeStorageDurability` double in the same `_makeContainer`; the file's `_wrap`/`_drain`/`_drainNoSettle`/`_acceptTopoNameDialog`/`_dbWork`/`_tinyPngBytes` helpers.

> **D-19, recorded so a verifier does not reject it:** the two tests below run the real `ui.instantiateImageCodec` inside `_handleNewTopo`. That is **permitted** — the existing `A6: new-topo flow` group in this very file already does exactly this, with `tester.runAsync` for the file write and `_drain`/`_drainNoSettle` for the pumps. CLAUDE.md's prohibition is specifically about **`TopoCanvas`'s** decode under the fake-async clock, and no canvas decode is introduced here.

- [ ] **Step 1: Teach the test harness to inject a PhotoFiles. Extend `_makeContainer` — which by this point is §1a Task 4's version — with one more parameter and one more conditional override.**
  > Corrected (Decision #7 — the fragment's block silently REVERTS §1a Task 4's `storageDurability` parameter and its unconditional `storageDurabilityProvider` override, which would un-do §1a's interlock in every test in the file. Rewritten as the reconciled **union**, in the mandated parameter order `{LocationService?, SyncOrchestrator?, StorageDurability storageDurability = const StorageDurability.probing(), PhotoFiles? photoFiles}`. §1a writes `storageDurability`; **this task appends `photoFiles` only** — if the file already matches the block below apart from `photoFiles`, add just the parameter and the `if (photoFiles != null)` override and change nothing else)

  ```dart
  /// [storageDurability] is §1a Task 4's parameter and MUST already be present —
  /// it is always overridden (see that task). This task appends only
  /// [photoFiles], which, when given, overrides `photoFilesProvider` (see
  /// `database_provider.dart:47`) so a test can make the photo BYTE WRITE fail
  /// the way the web backend now does — the L3 fix's failure path. Tests that
  /// don't pass it get the real `PhotoFiles`, whose `path_provider` lookup simply
  /// never resolves under `flutter_test` (its own try/catch leaves the docs-path
  /// cache cold), exactly as every pre-existing test here relies on.
  ///
  /// Reconciled union signature, in this exact parameter order (reconciliation
  /// decision #7): `{LocationService?, SyncOrchestrator?, StorageDurability
  /// storageDurability = const StorageDurability.probing(), PhotoFiles?
  /// photoFiles}`.
  ProviderContainer _makeContainer({
    LocationService? locationService,
    SyncOrchestrator? syncOrchestrator,
    StorageDurability storageDurability = const StorageDurability.probing(),
    PhotoFiles? photoFiles,
  }) {
    final db = AppDatabase(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        nowMsProvider.overrideWithValue(() => 1000),
        if (locationService != null)
          locationServiceProvider.overrideWithValue(locationService),
        if (photoFiles != null)
          photoFilesProvider.overrideWithValue(photoFiles),
        syncOrchestratorProvider.overrideWith(
          () => syncOrchestrator ?? _FakeSyncOrchestrator(),
        ),
        storageDurabilityProvider.overrideWith(
          () => _FakeStorageDurability(storageDurability),
        ),
      ],
    );
    addTearDown(db.close);
    addTearDown(container.dispose);
    return container;
  }
  ```

- [ ] **Step 2: Add the failing-PhotoFiles double to `topos_screen_test.dart` (place it beside `_FakeLocationService` at line 148). Duplicating the class from `photo_ownership_test.dart` is deliberate and matches this file's own precedent — `_FakeSyncOrchestrator` is duplicated for exactly the same file-private reason (see its doc, verified at lines 161-162, not the fragment's 158-160).**
  ```dart
  /// [PhotoFiles] whose [importPhoto] always fails the way the WEB backend now
  /// does when the browser refuses the byte write (`photo_files_web.dart`'s L3
  /// fix). Duplicated from `photo_ownership_test.dart` because that copy is
  /// file-private — same reason `_FakeSyncOrchestrator` below is duplicated from
  /// `community_pull_refresh_test.dart`.
  class _QuotaFailingPhotoFiles extends PhotoFiles {
    @override
    Future<String> importPhoto(XFile xfile, String photoId) async {
      throw PhotoWriteException(
        failure: PhotoWriteFailure.quotaExceeded,
        key: 'photos/$photoId.jpg',
        cause: Exception('QuotaExceededError: The quota has been exceeded.'),
      );
    }
  }
  ```

- [ ] **Step 3: Add the required import to `topos_screen_test.dart` (its import block ends at line 32). `photoFilesProvider` already resolves via the existing `database_provider.dart` import at line 7; `PhotoWriteException`/`PhotoWriteFailure` come free from the facade export added in Task 1.**
  ```dart
  import 'package:masi/features/topo/data/photo_files.dart';
  ```

- [ ] **Step 4: Write the failing tests. Append them inside the existing `group('A6: new-topo flow', …)` block (which opens at line 871).**
  ```dart
      testWidgets(
        'L3: when the photo bytes cannot be written, the New topo flow reports '
        'it in a SnackBar, leaves NO topo behind (the wall createTopo had '
        'already committed is soft-deleted), and does not navigate into a canvas '
        'with nothing to show',
        (tester) async {
          final container = _makeContainer(
            photoFiles: _QuotaFailingPhotoFiles(),
          );
          late Directory tempDir;
          late File pngFile;
          await tester.runAsync(() async {
            tempDir = await Directory.systemTemp.createTemp('topos_screen_l3');
            pngFile = File('${tempDir.path}/photo.png');
            await pngFile.writeAsBytes(_tinyPngBytes);
          });
          addTearDown(() {
            if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
          });

          await tester.pumpWidget(
            _wrap(
              container,
              ToposScreen(
                photoSourcePicker: (context) async => ImageSource.gallery,
                photoPicker: (source) async => XFile(pngFile.path),
              ),
            ),
          );
          await _drain(tester);

          await tester.tap(find.byKey(const Key('topos-new-topo')));
          await _acceptTopoNameDialog(tester);
          // No trailing settle: the SnackBar must still be on screen.
          await _drainNoSettle(tester);

          expect(
            find.textContaining('Out of storage space'),
            findsOneWidget,
            reason: 'the failure must be reported to the user, not debugPrinted',
          );

          final topos = await _dbWork(
            tester,
            () =>
                container.read(libraryCrudRepositoryProvider).watchTopos().first,
          );
          expect(
            topos,
            isEmpty,
            reason: 'createTopo committed a wall before attachPhotoToWall threw '
                '— it must be soft-deleted, not left as an empty photo-less '
                'topo on the home screen forever',
          );

          expect(
            find.byKey(const Key('topos-new-topo')),
            findsOneWidget,
            reason: 'still on the Topos home — a successful flow would have '
                'pushed /walls/:wallId (a SizedBox in this harness), removing '
                'this button from the tree',
          );
        },
      );

      testWidgets(
        'L3: the re-entrancy guard is released, so New topo can be retried '
        'straight after a byte-write failure',
        (tester) async {
          final container = _makeContainer(
            photoFiles: _QuotaFailingPhotoFiles(),
          );
          late Directory tempDir;
          late File pngFile;
          await tester.runAsync(() async {
            tempDir = await Directory.systemTemp.createTemp('topos_screen_l3b');
            pngFile = File('${tempDir.path}/photo.png');
            await pngFile.writeAsBytes(_tinyPngBytes);
          });
          addTearDown(() {
            if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
          });

          await tester.pumpWidget(
            _wrap(
              container,
              ToposScreen(
                photoSourcePicker: (context) async => ImageSource.gallery,
                photoPicker: (source) async => XFile(pngFile.path),
              ),
            ),
          );
          await _drain(tester);

          await tester.tap(find.byKey(const Key('topos-new-topo')));
          await _acceptTopoNameDialog(tester);
          await _drain(tester);

          // A SECOND attempt must actually run (the _creating guard released in
          // the finally block), reaching the name dialog again.
          await tester.tap(find.byKey(const Key('topos-new-topo')));
          await _drain(tester);
          expect(find.byKey(const Key('topo-name-field')), findsOneWidget);
        },
      );
  ```

- [ ] **Step 5: Run them and see them fail: today the exception hits `_handleNewTopo`'s bare catch-all at lines 508-509 (`debugPrint` only), so no SnackBar appears and the empty wall survives.**
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/library/presentation/topos_screen_test.dart --plain-name 'L3'
  ```
  Expected: RED: the first test fails on `find.textContaining('Out of storage space')` (findsNothing) and on `topos` having length 1 instead of being empty.

- [ ] **Step 6: Extend the import at `topos_screen.dart` lines 22-23 to pull in the SnackBar builder, and add the exception import.**
  ```dart
  import '../../topo/data/photo_write_exception.dart';
  import '../../topo/presentation/topo_canvas_screen.dart'
      show
          captureWallGpsFromPhoto,
          gpsCaptureResultSnackBar,
          photoWriteFailureSnackBar;
  ```

- [ ] **Step 7: Replace lines 478-480 of `_handleNewTopo` with the guarded attach.**
  ```dart
        final repo = ref.read(libraryCrudRepositoryProvider);
        final wallId = await repo.createTopo(name);
        // L3 fix: attachPhotoToWall PROPAGATES a byte-write failure now (quota
        // exhaustion above all — originals stay FULL resolution per decision
        // D-5) instead of creating a pixel-less Photos row. `createTopo` has
        // ALREADY committed a wall by this point, so letting the throw fall
        // through to the outer catch-all would leave an empty, photo-less topo
        // sitting on this screen forever — the visible half of the very bug this
        // fix exists to prevent. So: undo the wall, say why in plain words, and
        // abort the flow (no GPS capture, no navigation into a canvas with
        // nothing to show). The `finally` below still releases `_creating`, so
        // the user can retry immediately. Every OTHER failure still falls
        // through to the outer catch-all, unchanged.
        try {
          await repo.attachPhotoToWall(wallId, xfile, width, height);
        } on PhotoWriteException catch (e) {
          await repo.softDeleteWall(wallId);
          if (!mounted) return;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(photoWriteFailureSnackBar(e));
          return;
        }
  ```

- [ ] **Step 8: Update `_handleNewTopo`'s doc comment (the 'Deliberately defensive' paragraph at lines 412-415) to record the one non-defensive case.**
  ```dart
    /// ONE failure is not merely debugPrinted: a [PhotoWriteException] from
    /// [LibraryCrudRepository.attachPhotoToWall] (the L3 fix — the photo's bytes
    /// could not be stored, quota exhaustion above all) is caught in its own
    /// clause, which soft-deletes the wall `createTopo` had already committed and
    /// reports the reason via `photoWriteFailureSnackBar`. Without that undo, a
    /// failed byte write would leave an empty photo-less topo on this screen —
    /// so the "never crash the Topos home" rule stays intact while the user
    /// still learns what happened and is left with exactly nothing created,
    /// matching #25's abort semantics.
  ```

- [ ] **Step 9: Run the new tests, then the whole file, then analyze.**
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/library/presentation/topos_screen_test.dart && flutter analyze
  ```
  Expected: All tests passed! (the pre-existing suite plus the 2 new L3 tests) · analyze: No issues found!

- [ ] **Step 10: Run the whole suite to confirm the shared `_makeContainer` change broke nothing — every pre-existing call site must behave identically, and §1a's `storageDurability` override must still be in place and still unconditional. Then commit.**
  > Corrected (D-13 — absolute total replaced by baseline + N)

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test
  ```
  Expected: `flutter test` green at **baseline + 2** for this task.

**Assertions:**

- `flutter test test/features/library/presentation/topos_screen_test.dart` is green and contains a test where, with `photoFilesProvider` overridden by a PhotoFiles whose `importPhoto` throws `PhotoWriteException`, the New topo flow leaves `watchTopos().first` EMPTY and renders text containing 'Out of storage space'.
- The same test asserts `find.byKey(const Key('topos-new-topo'))` still finds one widget — i.e. `context.push('/walls/$wallId')` was NOT reached.
- A second test proves `_creating` is released: a retry immediately after the failure reaches `topo-name-field` again.
- `grep -n 'softDeleteWall' lib/features/library/presentation/topos_screen.dart` returns exactly one hit, inside `_handleNewTopo`'s `on PhotoWriteException` clause.
- `_makeContainer` in `topos_screen_test.dart` accepts an optional `PhotoFiles? photoFiles` and overrides `photoFilesProvider` only when non-null, so every pre-existing call site behaves identically.
- **(Decision #7.)** `_makeContainer`'s signature is exactly `_makeContainer({LocationService? locationService, SyncOrchestrator? syncOrchestrator, StorageDurability storageDurability = const StorageDurability.probing(), PhotoFiles? photoFiles})` — the reconciled union with §1a, in that parameter order. §1a's `storageDurabilityProvider` override is still present and still **unconditional**; only `photoFiles` is conditional.
- `flutter analyze` = 0 issues; `flutter test` green at **baseline + 2** (D-13).

**Commit message:** `fix(library): abort New topo cleanly when photo bytes cannot be stored (L3)`

---

# Phase 4 — sync half (Tasks 7–10)

*Strictly serial. **LAST.** Every task here edits a file §1d and/or §1e own, on top of both. Do not begin until §1d is fully landed and independently verified, and §1e is fully landed and independently verified.*

### Task 7: Paginate every Supabase Storage listing past its 100-object default (S6)

**Files:**
- Create: `lib/features/backup/data/storage_pagination.dart`, `test/features/backup/data/storage_pagination_test.dart`
- Modify: `lib/features/backup/data/sync_remote.dart:1-2` (import), `:636-640`, `:666-670`; `lib/features/backup/data/backup_remote.dart:1-3` (import), `:157-161`
- Test: `test/features/backup/data/storage_pagination_test.dart`

**Interfaces:**
- Produces: `const int kStoragePageSize = 100`; `Future<List<T>> collectPagedObjects<T>(Future<List<T>> Function(int limit, int offset) fetchPage, {int pageSize = kStoragePageSize})`; the private `Future<List<FileObject>> SupabaseSyncRemote._listAllObjects(String prefix)`.
- Consumes: `StorageFileApi.list({String? path, SearchOptions searchOptions = const SearchOptions()})` (`storage_client-2.6.0/lib/src/storage_file_api.dart:594-596`); `SearchOptions({int? limit = 100, int? offset = 0, SortBy? sortBy = const SortBy(), String? search})` (`storage_client-2.6.0/lib/src/types.dart:217-222`); `FileObject`; `sharedPhotoPath` (`sync_remote.dart:220`).

> **Ordering:** on `sync_remote.dart` this is the LAST link in the chain §1d T1 → §1d T2 → §1e T2 → **§1f Task 7**. Low textual overlap — this task touches only the two `list*ObjectPaths` methods and one import — but the same file. Do not run it concurrently with either.

- [ ] **Step 1: Write the failing test for the paging loop. Note the exact `SearchOptions` facts this pins, verified in the pub cache: `list({String? path, SearchOptions searchOptions = const SearchOptions()})` at `storage_client-2.6.0/lib/src/storage_file_api.dart:594-596`, and `SearchOptions({this.limit = 100, this.offset = 0, this.sortBy = const SortBy(), this.search})` at `types.dart:217-222`.**
  ```dart
  // test/features/backup/data/storage_pagination_test.dart
  // S6: every Supabase Storage listing must page. `list()`'s SearchOptions
  // default is `limit: 100, offset: 0`
  // (storage_client-2.6.0/lib/src/types.dart:217-222) and the endpoint returns at
  // most `limit` objects with NO total count and no "there is more" flag — so a
  // single un-paged call silently truncated the sync push's "already uploaded"
  // skip-set at 100, making every push re-read and re-upload the
  // FULL-RESOLUTION bytes of every photo past that cut.
  import 'package:flutter_test/flutter_test.dart';
  import 'package:masi/features/backup/data/storage_pagination.dart';

  void main() {
    /// A page fetcher faithful to the Storage `list()` contract — at most [limit]
    /// items starting at [offset], stable order — that records every request it
    /// received so a test can prove the loop actually PAGED.
    ({
      Future<List<int>> Function(int limit, int offset) fetch,
      List<({int limit, int offset})> requests,
    })
    fetcherOver(int total) {
      final requests = <({int limit, int offset})>[];
      Future<List<int>> fetch(int limit, int offset) async {
        requests.add((limit: limit, offset: offset));
        if (offset >= total) return const [];
        final end = offset + limit;
        final stop = end > total ? total : end;
        return [for (var i = offset; i < stop; i++) i];
      }

      return (fetch: fetch, requests: requests);
    }

    test('kStoragePageSize matches the storage client SearchOptions default', () {
      expect(kStoragePageSize, 100);
    });

    test('150 objects are ALL collected, across two pages at offsets 0 and 100',
        () async {
      final f = fetcherOver(150);

      final all = await collectPagedObjects<int>(f.fetch);

      expect(all, hasLength(150));
      expect(all.first, 0);
      expect(all.last, 149);
      expect(f.requests, [(limit: 100, offset: 0), (limit: 100, offset: 100)]);
    });

    test('an exactly-full final page costs one more request, which comes back '
        'empty — the only way to tell "one page" from "the first of several"',
        () async {
      final f = fetcherOver(100);

      final all = await collectPagedObjects<int>(f.fetch);

      expect(all, hasLength(100));
      expect(f.requests, [(limit: 100, offset: 0), (limit: 100, offset: 100)]);
    });

    test('an empty prefix costs exactly one request', () async {
      final f = fetcherOver(0);

      expect(await collectPagedObjects<int>(f.fetch), isEmpty);
      expect(f.requests, [(limit: 100, offset: 0)]);
    });

    test('a short first page terminates immediately', () async {
      final f = fetcherOver(7);

      expect(await collectPagedObjects<int>(f.fetch), hasLength(7));
      expect(f.requests, [(limit: 100, offset: 0)]);
    });

    test('pageSize is injectable so fixtures stay small', () async {
      final f = fetcherOver(7);

      final all = await collectPagedObjects<int>(f.fetch, pageSize: 3);

      expect(all, [0, 1, 2, 3, 4, 5, 6]);
      expect(f.requests.map((r) => r.offset), [0, 3, 6]);
    });

    test('a non-positive pageSize is rejected rather than looping forever',
        () async {
      await expectLater(
        collectPagedObjects<int>(
          (limit, offset) async => const [],
          pageSize: 0,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  }
  ```

- [ ] **Step 2: Run it and see it fail to compile.**
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/backup/data/storage_pagination_test.dart
  ```
  Expected: RED: "Couldn't resolve … storage_pagination.dart".

- [ ] **Step 3: Create the helper. No Supabase type appears in it, which is what makes the loop unit-testable with no SupabaseClient fake.**
  ```dart
  // lib/features/backup/data/storage_pagination.dart
  /// Paging for Supabase Storage object listings.
  ///
  /// S6 (silent 100-object truncation): `StorageFileApi.list()` takes
  /// `searchOptions: SearchOptions(limit:, offset:, sortBy:, search:)` whose
  /// defaults are `limit: 100, offset: 0, sortBy: name asc`
  /// (`storage_client-2.6.0/lib/src/types.dart:217-222`), and the endpoint
  /// returns AT MOST `limit` objects with no total count and no "there is more"
  /// flag. A single un-paged `list(path: …)` therefore TRUNCATES any prefix
  /// holding more than 100 objects — which is exactly how the sync push's
  /// "already uploaded" skip-set went stale past ~100 photos, making every push
  /// re-read and re-upload bytes already in the cloud. Originals are kept at FULL
  /// resolution (decision D-5), so that re-upload is the dominant push cost AND
  /// the dominant window for the byte phase to fail.
  ///
  /// Deliberately its own file rather than a private method on
  /// `SupabaseSyncRemote`: three listings need it (`SyncRemote`'s private and
  /// shared prefixes, plus `BackupRemote.listPhotoObjectPaths`, whose identical
  /// duplicate is a known divergence risk), and keeping it free of every Supabase
  /// type makes the paging LOOP itself unit-testable against a plain fetcher —
  /// no `SupabaseClient` fake, no network.
  library;

  /// Page size used for every paged Storage listing — the storage client's own
  /// `SearchOptions` default, restated here so the loop and the request it issues
  /// can never drift apart.
  const int kStoragePageSize = 100;

  /// Collects EVERY item a paged listing can return.
  ///
  /// [fetchPage] receives `(limit, offset)` and must behave exactly like the
  /// Storage `list()` endpoint: return at most `limit` items, starting at
  /// `offset`, in a stable order.
  ///
  /// A SHORT page — fewer than `limit` items, the empty page included — is the
  /// ONLY termination signal the REST contract offers, so it is the only one used
  /// here. A page that comes back exactly full therefore always costs one more
  /// request; that is correct rather than wasteful, since it is the sole way to
  /// distinguish "exactly one page of objects" from "the first of several".
  ///
  /// [pageSize] defaults to [kStoragePageSize]; tests shrink it to keep fixtures
  /// small. A non-positive value would spin forever and is rejected.
  Future<List<T>> collectPagedObjects<T>(
    Future<List<T>> Function(int limit, int offset) fetchPage, {
    int pageSize = kStoragePageSize,
  }) async {
    if (pageSize <= 0) {
      throw ArgumentError.value(pageSize, 'pageSize', 'must be positive');
    }
    final all = <T>[];
    var offset = 0;
    while (true) {
      final page = await fetchPage(pageSize, offset);
      all.addAll(page);
      if (page.length < pageSize) return all;
      offset += page.length;
    }
  }
  ```

- [ ] **Step 4: Run the helper test and see it pass.**
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/backup/data/storage_pagination_test.dart
  ```
  Expected: `+7: All tests passed!` (a genuine per-file count — 7 `test(` blocks).

- [ ] **Step 5: Add the import to `sync_remote.dart` (its import block is lines 1-2). `SearchOptions` and `FileObject` are already in scope via `package:supabase_flutter/supabase_flutter.dart` → `package:supabase/supabase.dart` → `package:storage_client/storage_client.dart` (verified).**
  ```dart
  import 'package:flutter/foundation.dart';
  import 'package:supabase_flutter/supabase_flutter.dart';

  import 'storage_pagination.dart';
  ```

- [ ] **Step 6: Add the paging helper as a private method on `SupabaseSyncRemote` and rewrite both listings. Replace lines 636-640 and 666-670.**
  ```dart
    /// Lists EVERY object under [prefix], paging past the storage client's
    /// 100-object `SearchOptions` default (S6 — see `storage_pagination.dart`
    /// for why a single un-paged `list()` silently truncated the skip-set and
    /// what that cost at full resolution).
    Future<List<FileObject>> _listAllObjects(String prefix) {
      return collectPagedObjects<FileObject>(
        (limit, offset) => _client.storage.from(_bucket).list(
          path: prefix,
          searchOptions: SearchOptions(limit: limit, offset: offset),
        ),
      );
    }

    @override
    Future<Set<String>> listPhotoObjectPaths(String uid) async {
      final files = await _listAllObjects(uid);
      return {for (final file in files) '$uid/${file.name}'};
    }

    // … (uploadSharedPhoto / downloadSharedPhoto unchanged in between) …

    @override
    Future<Set<String>> listSharedPhotoObjectPaths() async {
      final files = await _listAllObjects('shared');
      return {for (final file in files) 'shared/${file.name}'};
    }
  ```

- [ ] **Step 7: Apply the same fix to the duplicated listing in `backup_remote.dart` (lines 157-161), removing the divergence the spec explicitly flags between `CloudBackupService`'s photo logic and `SyncService`'s.**
  ```dart
  // lib/features/backup/data/backup_remote.dart — add to the import block:
  import 'storage_pagination.dart';

  // …and replace listPhotoObjectPaths (lines 157-161):
    /// S6: paged, for the identical reason `SupabaseSyncRemote`'s two listings
    /// are — `list()` returns at most 100 objects per request with no signal
    /// that more exist, so an un-paged call truncates the skip-set and makes
    /// [CloudBackupService] re-upload full-resolution bytes already in the
    /// cloud. Fixed here too even though `CloudBackupService` currently has no
    /// caller outside `lib/features/backup/` (decision D-2), because leaving
    /// one of two identical listings unfixed is exactly the divergence risk this
    /// duplication is known for.
    @override
    Future<Set<String>> listPhotoObjectPaths(String uid) async {
      final files = await collectPagedObjects<FileObject>(
        (limit, offset) => _client.storage.from(_bucket).list(
          path: uid,
          searchOptions: SearchOptions(limit: limit, offset: offset),
        ),
      );
      return {for (final file in files) '$uid/${file.name}'};
    }
  ```

- [ ] **Step 8: Confirm no un-paged listing survives anywhere in `lib/`.**
  > Corrected (**D-14.** The fragment expects "Exactly two hits". **Grep run against the real tree: there are THREE** un-paged `.list(` call sites before this task — `sync_remote.dart:638`, `sync_remote.dart:668`, `backup_remote.dart:159`. The expectation is corrected to three *and* reframed, because the post-fix count is a consequence of how the refactor is shaped (the two `sync_remote.dart` sites collapse into the single `_listAllObjects`), whereas "zero un-paged listings" is the invariant that actually matters)

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && grep -rn '\.list(' lib --include="*.dart"
  ```
  Expected: **Before this task: three hits** — `sync_remote.dart:638`, `sync_remote.dart:668`, `backup_remote.dart:159`, none of them passing `searchOptions`. **After: every remaining hit sits inside a `collectPagedObjects` callback and passes `searchOptions: SearchOptions(limit: limit, offset: offset)`.** Expect **two** — one in `SupabaseSyncRemote._listAllObjects` (which now serves both listings) and one in `backup_remote.dart`'s `listPhotoObjectPaths`. Two or three are both fine; **what must not remain is any `.list(` without `searchOptions`.**

- [ ] **Step 9: Run analyze and the backup suite, then commit.**
  > Corrected (D-13 — a baseline + N gate added)

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter analyze && flutter test test/features/backup/
  ```
  Expected: analyze: No issues found! · test/features/backup/ green (the existing `cloud_backup_service_test.dart` and `sync_service_test.dart` suites use fakes, so they are unaffected by the SupabaseSyncRemote/BackupRemote change). `flutter test` green at **baseline + 7**.

**Assertions:**

- `flutter test test/features/backup/data/storage_pagination_test.dart` is green with 7 tests, including one where a 150-item fetcher yields all 150 and receives exactly `[(limit: 100, offset: 0), (limit: 100, offset: 100)]`.
- `kStoragePageSize == 100`, matching `SearchOptions`' documented default (`storage_client-2.6.0/lib/src/types.dart:218`).
- `collectPagedObjects` with `pageSize: 0` rejects with `ArgumentError` instead of looping forever.
- **`grep -rn '\.list(' lib --include="*.dart"` — EVERY remaining hit passes `searchOptions: SearchOptions(limit: limit, offset: offset)` from inside a `collectPagedObjects` callback. No un-paged `list(path: …)` remains anywhere in `lib/`.** *(Corrected per D-14: the fragment asserted "exactly two call sites"; the pre-fix tree has **three** — `sync_remote.dart:638`, `sync_remote.dart:668`, `backup_remote.dart:159`. Post-fix the two `sync_remote.dart` sites collapse into `_listAllObjects`, so the count is an artefact of the refactor. **The contract is "zero un-paged listings", not a particular number.**)*
- `lib/features/backup/data/storage_pagination.dart` references no Supabase type (`grep -c supabase lib/features/backup/data/storage_pagination.dart` is 0), which is what lets the loop be tested with no client fake.
- `flutter analyze` = 0 issues; `flutter test test/features/backup/` is green; `flutter test` green at **baseline + 7** (D-13).

**Commit message:** `fix(sync): paginate Storage object listings past the 100-object default (S6)`

### Task 8: Count byte-upload failures instead of continuing silently — and make `fullyLanded` see them (D-2)

> ### This task carries the highest-severity correction in the whole Stage-1 plan
> Reconciliation **D-2**. Everything else in this task is bookkeeping; the `&& photosFailed == 0` term in `fullyLanded` is what stops a push whose every photo failed from rendering *"Synced • just now"*. Do not treat it as optional polish, and do not let a reviewer argue it away on the grounds that "all the rows landed" — **that is precisely the lie.** The rows landed because the failed photo's row was deliberately withheld.

**Files:**
- Modify: `lib/features/backup/data/sync_service.dart` — `PushSyncResult`, the `PhotoUploadOutcome` typedef (above `class SyncService` at `:196`), `_uploadOwnPhotos` doc `:347-363` and body `:364-415`, and the call site at `:341`; `lib/features/backup/application/sync_orchestrator.dart` — `_runPush`'s `case SyncPushOutcome.pushed:` arm *(added by D-2)*; `test/features/backup/data/sync_service_test.dart` — new double after `ThrowingFetchSharedToposRemote` (`:267-272`) and new tests inside `group('pushOwn', …)` (`:438-764`)
- Test: `test/features/backup/data/sync_service_test.dart`

**Interfaces:**
- Produces: `typedef PhotoUploadOutcome = ({int uploaded, int failed, int missingLocalBytes, Set<String> failedCanonicalIds, List<String> errors})`; `PushSyncResult.photosFailed` / `.photosMissingLocalBytes` / `.photoErrors` / `.hasPhotoFailures`; **the amended `PushSyncResult.fullyLanded`**; a `lastPushError` that reads both channels; `class FailingUploadSyncRemote extends FakeSyncRemote` (public, toggleable via `failUploads`).
- Consumes: **§1d's** `PushSyncResult.rowsPushed`/`photosUploaded`/`rowsFailed`/`errors`/`fullyLanded` and the `upsertOwnRows` → `List<TablePushOutcome>` accounting block; **§1e's** `wallVisibility` `selectOnly` projection, `_clearDirty` **narrowed to the landed tables** (§1e's D-25), `PushScope`, `_scheduleRetry()`, `_consecutivePushFailures`, `_fullResyncDue`; `SyncService._canonicalPhotoId` (`:663`); `sharedPhotoPath` (`sync_remote.dart:220`); the test file's `FakeSyncRemote`/`FakeAuthRepository`/`makeContainer`/`writeFile`/`seedWallHierarchy` helpers.

> **Decision #12:** `_uploadOwnPhotos` changes from §1e Task 4's `Future<int>` to `Future<PhotoUploadOutcome>`. §1e's call site (`final photosUploaded = await _uploadOwnPhotos(...)`) is **rewritten by Step 11 below**. §1e must land first.
> 
> **Decision #8:** there is **one** `PushSyncResult` class. Step 4 shows §1d's class **patched**, not a competing second version.

- [ ] **Step 1: Add the toggleable failing-upload double to `sync_service_test.dart`, next to `ThrowingFetchSharedToposRemote` (which ends at line 272).**
  ```dart
  /// [FakeSyncRemote] variant whose PRIVATE byte upload throws while
  /// [failUploads] is set — used to prove §1f-3 (a byte-upload failure is
  /// COUNTED and reported, never a silent `continue`) and §1f-2 (its `Photos`
  /// row is held back from the metadata push). Toggleable so a single test can
  /// also prove the retry HEALS: flip it off and push again.
  class FailingUploadSyncRemote extends FakeSyncRemote {
    bool failUploads = true;

    @override
    Future<void> uploadPhoto({
      required String uid,
      required String photoId,
      required String ext,
      required List<int> bytes,
    }) async {
      if (failUploads) {
        throw Exception('uploadPhoto failed: simulated storage error');
      }
      await super.uploadPhoto(
        uid: uid,
        photoId: photoId,
        ext: ext,
        bytes: bytes,
      );
    }
  }
  ```

- [ ] **Step 2: Write the failing tests. Append them inside the existing `group('pushOwn', …)` block (which ends at line 764).**
  ```dart
      test(
        '1f-3: a byte-upload failure is COUNTED and reported, not a silent '
        'continue — photosFailed/photoErrors carry it (pre-fix sync_service.dart '
        'skipped the upload with no error and no counter)',
        () async {
          final remote = FailingUploadSyncRemote();
          final c = makeContainer(
            remote: remote,
            auth: FakeAuthRepository(_signedInU1),
          );
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

          expect(result.didPush, isTrue);
          expect(result.photosUploaded, 0);
          expect(result.photosFailed, 1);
          expect(result.hasPhotoFailures, isTrue);
          expect(result.photosMissingLocalBytes, 0);
          expect(result.photoErrors, hasLength(1));
          expect(result.photoErrors.single, contains('photo-1'));
          expect(result.photoErrors.single, contains('byte upload failed'));
        },
      );

      test(
        '1f-3: a photo whose LOCAL bytes are gone is reported separately, in '
        'photosMissingLocalBytes — it is not retryable (nothing will ever make '
        'the bytes appear on this device), so it must not be conflated with a '
        'transient upload failure or the retry loop would never terminate',
        () async {
          final remote = FakeSyncRemote();
          final c = makeContainer(
            remote: remote,
            auth: FakeAuthRepository(_signedInU1),
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
            localPath: 'photos/never-written.jpg',
          );

          final result = await c.service.pushOwn();

          expect(result.photosUploaded, 0);
          expect(result.photosFailed, 0);
          expect(result.hasPhotoFailures, isFalse);
          expect(result.photosMissingLocalBytes, 1);
          expect(result.photoErrors.single, contains('no local bytes'));
        },
      );

      test(
        'a tombstoned photo is neither a failure nor a missing-bytes case — its '
        'bytes are removed deliberately, so the counters stay clean',
        () async {
          final remote = FakeSyncRemote();
          final c = makeContainer(
            remote: remote,
            auth: FakeAuthRepository(_signedInU1),
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
            localPath: 'photos/never-written.jpg',
          );
          await (c.db.update(c.db.photos)
                ..where((t) => t.id.equals('photo-1')))
              .write(
            const PhotosCompanion(
              deletedAt: Value(9999),
              updatedAt: Value(9999),
              dirty: Value(true),
            ),
          );

          final result = await c.service.pushOwn();

          expect(result.photosFailed, 0);
          expect(result.photosMissingLocalBytes, 0);
          expect(result.photoErrors, isEmpty);
          expect(remote.removedPrivatePaths, ['$_uidU1/photo-1.jpg']);
        },
      );
  ```

- [ ] **Step 3: Run and see them fail to compile — `photosFailed`, `photosMissingLocalBytes`, `photoErrors` and `hasPhotoFailures` do not exist yet.**
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/backup/data/sync_service_test.dart
  ```
  Expected: RED: "The getter 'photosFailed' isn't defined for the class 'PushSyncResult'" (and the other three).

- [ ] **Step 4: Replace `PushSyncResult` in `lib/features/backup/data/sync_service.dart` with the ONE merged class — §1d's, patched.**
  > Corrected (Decision #8 + D-5 + **D-2**. Three changes to the fragment's block: **(a) Decision #8** — it is now a patch on §1d's class rather than a competing version, so `rowsFailed`/`errors` and §1d's field docs are present and there is exactly ONE `toString` naming all seven fields; **(b) D-5** — the two swapped field docs are re-paired with their own declarations and `photosFailed` is declared **before** `photosMissingLocalBytes`; **(c) D-2** — `fullyLanded` gains `&& photosFailed == 0`, `photosMissingLocalBytes` is deliberately excluded, and the whole reasoning is written into the doc so nobody deletes the term later)

  ```dart
  /// Result of a [SyncService.pushOwn] call.
  ///
  /// S1 fix (§1d): [rowsFailed]/[errors] mirror [PullResult.errors]' shape on
  /// the push side. Before this, a push could only report how many rows it
  /// HANDED to the remote — every per-table failure was swallowed inside
  /// [SyncRemote.upsertOwnRows] — so a push where literally nothing landed
  /// still produced `outcome == pushed` with a healthy row count, and the
  /// Account screen's `sync-status` line rendered "Synced • just now".
  ///
  /// §1f adds the PHOTO half of that same contract — [photosFailed],
  /// [photosMissingLocalBytes], [photoErrors] — as a SECOND channel rather than
  /// as more entries in [errors]. The two are not interchangeable: they differ
  /// in RETRYABILITY, and §1e's retry loop keys off exactly that difference
  /// (reconciliation duplication #6). Flattening them into one list would make
  /// §1e retry forever on a photo whose bytes can never reappear on this device.
  class PushSyncResult {
    const PushSyncResult.pushed({
      required this.rowsPushed,
      required this.photosUploaded,
      this.rowsFailed = 0,
      this.errors = const [],
      this.photosFailed = 0,
      this.photosMissingLocalBytes = 0,
      this.photoErrors = const [],
    }) : outcome = SyncPushOutcome.pushed;

    const PushSyncResult.skippedSignedOut()
      : outcome = SyncPushOutcome.skippedSignedOut,
        rowsPushed = 0,
        photosUploaded = 0,
        rowsFailed = 0,
        errors = const [],
        photosFailed = 0,
        photosMissingLocalBytes = 0,
        photoErrors = const [];

    const PushSyncResult.skippedNotWifi()
      : outcome = SyncPushOutcome.skippedNotWifi,
        rowsPushed = 0,
        photosUploaded = 0,
        rowsFailed = 0,
        errors = const [],
        photosFailed = 0,
        photosMissingLocalBytes = 0,
        photoErrors = const [];

    final SyncPushOutcome outcome;

    /// Total row count now KNOWN TO BE IN THE CLOUD across all nine tables
    /// (profiles/areas/sectors/walls/photos/routes/comments/likes/ascents),
    /// INCLUDING tombstones — rows this call upserted, plus rows the
    /// last-writer-wins pre-check skipped because the cloud copy is strictly
    /// newer (nothing left to send for those; see
    /// [TablePushOutcome.rowsSkippedNewerRemote]).
    ///
    /// S1 fix: this used to count rows merely HANDED TO the remote. Rows that
    /// did NOT land are in [rowsFailed]. It also EXCLUDES any photo row withheld
    /// because its bytes did not land (§1f — see [photosFailed]): such a row
    /// never entered `tablesToRows` at all. Always 0 when [outcome] isn't
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

    /// Number of distinct photo files whose upload was REQUIRED this push and
    /// FAILED — the byte read threw, or `uploadPhoto`/`uploadSharedPhoto` threw.
    ///
    /// RETRYABLE, and therefore the signal §1e's backoff loop keys off (see
    /// [hasPhotoFailures]): a network blip / transient Storage error will
    /// succeed on a later attempt, at which point the rows withheld below go up
    /// too. Each of these photos' `Photos` rows was HELD BACK from this push's
    /// metadata upsert (S5 — see [SyncService._uploadOwnPhotos]), which is what
    /// stops another device from ever pulling a row pointing at a Storage object
    /// that does not exist.
    ///
    /// Pre-fix this was a bare `continue` with no error and no counter, while
    /// the metadata had already been pushed.
    final int photosFailed;

    /// Number of distinct photo files that have NO local bytes on this device at
    /// all (`PhotoFiles.readPhotoBytes` returned `null`) despite an upload being
    /// required.
    ///
    /// Deliberately SEPARATE from [photosFailed], and deliberately NOT retried:
    /// nothing will ever make those bytes appear on this device (they were
    /// evicted, or the row predates the L3 fix), so counting it as a retryable
    /// failure would spin §1e's "retry until clean" loop forever. Such a row's
    /// metadata IS still pushed — it is the only surviving record of the photo
    /// (wall, dimensions, crop, isPrimary, sortOrder) and another device may
    /// well already hold the object — but it is reported in [photoErrors] rather
    /// than vanishing silently.
    final int photosMissingLocalBytes;

    /// One human-readable message per photo counted in [photosFailed] OR
    /// [photosMissingLocalBytes], each naming the canonical photo id and what
    /// went wrong. Empty on a clean push.
    final List<String> photoErrors;

    bool get didPush => outcome == SyncPushOutcome.pushed;

    /// True only when the push actually RAN and every row AND every photo file
    /// it was responsible for reached the cloud. The ONLY condition under which
    /// `SyncOrchestrator._runPush` may report [SyncStatus.idle] and stamp a
    /// fresh `lastSyncedAt` (S1).
    ///
    /// The `photosFailed == 0` term is load-bearing and closes the single
    /// highest-severity defect in the Stage-1 plan (reconciliation D-2). §1f
    /// WITHHOLDS a failed photo's row from `tablesToRows`, so a push in which
    /// EVERY photo's bytes failed leaves [rowsFailed] at 0 and [errors] empty.
    /// Without this term such a push reports `fullyLanded == true`, the
    /// orchestrator stamps a fresh `lastSyncedAt`, and the Account screen renders
    /// "Synced • just now" — precisely the S1 lie the whole of §1d exists to
    /// kill, re-entering through the photo path.
    ///
    /// [photosMissingLocalBytes] is DELIBERATELY EXCLUDED: it is not retryable,
    /// so including it would pin the app permanently outside [SyncStatus.idle]
    /// and would stop §1e's retry loop from ever terminating. Those photos are
    /// reported through [photoErrors] instead.
    bool get fullyLanded =>
        didPush && rowsFailed == 0 && errors.isEmpty && photosFailed == 0;

    /// True when at least one photo's bytes failed to upload for a RETRYABLE
    /// reason — the condition §1e must schedule a retry on. Deliberately does
    /// NOT include [photosMissingLocalBytes].
    bool get hasPhotoFailures => photosFailed > 0;

    @override
    String toString() =>
        'PushSyncResult(outcome: $outcome, rowsPushed: $rowsPushed, '
        'photosUploaded: $photosUploaded, rowsFailed: $rowsFailed, '
        'errors: $errors, photosFailed: $photosFailed, '
        'photosMissingLocalBytes: $photosMissingLocalBytes, '
        'photoErrors: $photoErrors)';
  }
  ```

- [ ] **Step 5: Verify the D-5 pairing landed. Read the block you just wrote and confirm each doc sits above the field it describes: the paragraph beginning "Number of distinct photo files whose upload was REQUIRED this push and FAILED" must be immediately above `final int photosFailed;`, and the paragraph beginning "Number of distinct photo files that have NO local bytes" immediately above `final int photosMissingLocalBytes;`. The fragment's original block had these two swapped.**
  > Corrected (D-5 — the fragment left this as a warning step *after* a defective code block. The defect is fixed in Step 4; this step is now the verification)

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && grep -n "RETRYABLE, and therefore\|Deliberately SEPARATE from\|final int photosFailed;\|final int photosMissingLocalBytes;" lib/features/backup/data/sync_service.dart
  ```
  Expected: The "RETRYABLE …" line precedes `final int photosFailed;`, and the "Deliberately SEPARATE …" line precedes `final int photosMissingLocalBytes;` — in that order. `flutter analyze` shows no dangling doc references.

- [ ] **Step 6: Add the D-2 regression tests, inside the same `group('pushOwn', …)`. These are what fail loudly if anyone ever removes the `&& photosFailed == 0` term, or ever "tidies" `photosMissingLocalBytes` into it.**
  > Corrected (D-2 — **new, added by this conversion.** The fragment shipped the defect with no test that would have caught it)

  ```dart
      test(
        'D-2: a push in which every photo\'s BYTES failed is NOT fullyLanded — '
        'the withheld row keeps rowsFailed at 0 and errors empty, so without the '
        'photosFailed term the orchestrator would report idle + a fresh '
        'lastSyncedAt and the Account screen would render "Synced • just now" '
        '(S1, re-entering through the photo path)',
        () async {
          final remote = FailingUploadSyncRemote();
          final c = makeContainer(
            remote: remote,
            auth: FakeAuthRepository(_signedInU1),
          );
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

          expect(
            result.rowsFailed,
            0,
            reason: 'the ROW channel is genuinely clean — every row that was '
                'sent landed, and the photo row was never sent',
          );
          expect(result.errors, isEmpty, reason: 'and so is its error list');
          expect(result.photosFailed, 1);
          expect(
            result.fullyLanded,
            isFalse,
            reason: 'photosFailed must gate fullyLanded (reconciliation D-2) — '
                'this expectation IS the S1-through-photos regression test',
          );
        },
      );

      test(
        'D-2: a photo with NO local bytes does NOT block fullyLanded — it is not '
        'retryable, so gating on it would stop §1e\'s retry loop ever '
        'terminating and pin the app outside idle forever',
        () async {
          final remote = FakeSyncRemote();
          final c = makeContainer(
            remote: remote,
            auth: FakeAuthRepository(_signedInU1),
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
            localPath: 'photos/never-written.jpg',
          );

          final result = await c.service.pushOwn();

          expect(result.photosMissingLocalBytes, 1);
          expect(result.photoErrors, hasLength(1));
          expect(
            result.fullyLanded,
            isTrue,
            reason: 'reported, but not treated as a failure to retry',
          );
        },
      );
  ```

- [ ] **Step 7: Make the orchestrator read BOTH channels (D-2, second half). Patch the `lastPushError` expression in `_runPush`'s NOT-fully-landed branch — and NOTHING else in that method. The branch is §1d Task 5's, reshaped by §1e Task 6; leave the `fullyLanded` gate, `await _failedPushStatus()`, the scope bookkeeping, the `catch` clause and §1e's `_scheduleRetry()` exactly as they are.**
  > Corrected (D-2 — **new, added by this conversion.** The fragment deliberately excluded `sync_orchestrator.dart` and handed the fix to §1e via the `hasPhotoFailures` seam; §1e never consumes it, so the seam would ship dead. Reconciliation D-2 and the master plan's blocking-correction #1 both assign this to §1f. **Scoped down after cross-checking §1e's converted fragment:** §1e's own D-28 already arms `_scheduleRetry()` on this exact branch, and its §1d inheritance already calls `await _failedPushStatus()` there — so §1f's edit is the `lastPushError` string ALONE)

  ```dart
  // lib/features/backup/application/sync_orchestrator.dart — inside `_runPush`,
  // in the NOT-fully-landed branch of `case SyncPushOutcome.pushed:`.
  //
  // That branch belongs to §1d Task 5, as reshaped by §1e Task 6 (which adds the
  // `PushScope` selection, the nothing-pending early-out, `await
  // _failedPushStatus()` for the offline-vs-error classification, and
  // `_scheduleRetry()` on BOTH failure paths — §1e's own D-28).
  //
  // §1f changes exactly ONE expression there: the `lastPushError` message.
  //  - do NOT rewrite the branch;
  //  - do NOT touch the `if (result.fullyLanded)` gate (§1d's);
  //  - do NOT add a second `_scheduleRetry()` — §1e already arms the retry on
  //    this path, which is what makes the "heals on the next push" behaviour
  //    Task 9 asserts at the SERVICE level actually happen in the app.

  // BEFORE (§1d Task 5, as §1e Task 6 left it):
                lastPushError:
                    'Sync failed: ${result.rowsFailed} change(s) not uploaded — '
                    '${result.errors.join('; ')}',

  // AFTER (§1f / reconciliation D-2). A push can fail ENTIRELY in the photo
  // channel, with `rowsFailed == 0` and `errors` empty, because the failed
  // photo's row was withheld from `tablesToRows` and so never had a chance to
  // fail. Reading only `errors` would render the useless
  // "Sync failed: 0 change(s) not uploaded — " with an empty reason:
                lastPushError:
                    'Sync failed: ${result.rowsFailed} change(s) and '
                    '${result.photosFailed} photo(s) not uploaded — '
                    '${[...result.errors, ...result.photoErrors].join('; ')}',
  ```

- [ ] **Step 8: Add the outcome record typedef immediately above the `SyncService` class (before line 196's class doc).**
  ```dart
  /// Outcome of one [SyncService._uploadOwnPhotos] pass.
  ///
  /// [failedCanonicalIds] is what makes bytes-before-metadata enforceable (S5):
  /// a photo row whose canonical file id is in this set MUST be held back from
  /// [SyncRemote.upsertOwnRows], so the cloud can never hold a `Photos` row
  /// pointing at a Storage object that does not exist. It contains ONLY the
  /// retryable failures — a photo with no local bytes at all is counted in
  /// [PushSyncResult.photosMissingLocalBytes] and its row still pushes (see that
  /// field's doc).
  typedef PhotoUploadOutcome = ({
    int uploaded,
    int failed,
    int missingLocalBytes,
    Set<String> failedCanonicalIds,
    List<String> errors,
  });
  ```

- [ ] **Step 9: Replace `_uploadOwnPhotos`' signature and body (lines 364-415) so every skip becomes a counted, described outcome. Keep the two `list*ObjectPaths` calls UN-guarded — their throw semantics are §1d's concern, not this workstream's. This is the change decision #12 records: the return type supersedes §1e Task 4's `Future<int>`.**
  ```dart
    Future<PhotoUploadOutcome> _uploadOwnPhotos(
      String uid,
      List<db.Photo> photos,
      Map<String, String> wallVisibility,
    ) async {
      if (photos.isEmpty) {
        return (
          uploaded: 0,
          failed: 0,
          missingLocalBytes: 0,
          failedCanonicalIds: <String>{},
          errors: <String>[],
        );
      }

      final alreadyPrivate = await _remote.listPhotoObjectPaths(uid);
      final alreadyShared = await _remote.listSharedPhotoObjectPaths();
      final seenCanonicalIds = <String>{};
      final failedCanonicalIds = <String>{};
      final errors = <String>[];
      var uploaded = 0;
      var missingLocalBytes = 0;

      for (final photo in photos) {
        final canonicalId = _canonicalPhotoId(photo);
        if (!seenCanonicalIds.add(canonicalId)) {
          continue; // this on-disk file was already handled via another row
        }

        final ext = p.extension(photo.localPath);

        if (photo.deletedAt != null) {
          await _remote.removePhoto(uid: uid, photoId: canonicalId, ext: ext);
          await _remote.removeSharedPhoto(photoId: canonicalId, ext: ext);
          continue;
        }

        final needsPrivate = !alreadyPrivate.contains('$uid/$canonicalId$ext');
        final needsShared =
            wallVisibility[photo.wallId] == 'shared' &&
            !alreadyShared.contains(sharedPhotoPath(canonicalId, ext));
        if (!needsPrivate && !needsShared) continue;

        // `photo.localPath` as stored may be RELATIVE (`photos/<id>.jpg`, the
        // canonical form since #17) or an already-valid legacy ABSOLUTE path —
        // `readPhotoBytes` resolves either against the current platform's
        // storage (app documents dir natively, byte store on web) rather than
        // touching `dart:io` directly. Read at most once even when both copies
        // are missing. Typed `List<int>?` (not `Uint8List?`) purely to avoid a
        // `dart:typed_data` import here; `uploadPhoto` takes `List<int>`.
        List<int>? bytes;
        try {
          bytes = await _photoFiles.readPhotoBytes(photo.localPath);
        } catch (e) {
          // Web only, in practice: the native backend swallows read errors into
          // `null` itself, while the browser byte store can reject the read
          // outright (blocked upgrade, closed connection). Retryable, so this
          // withholds the row.
          failedCanonicalIds.add(canonicalId);
          errors.add('photo $canonicalId: reading local bytes failed: $e');
          continue;
        }
        if (bytes == null) {
          // NOT retryable and NOT withheld — see
          // [PushSyncResult.photosMissingLocalBytes]. Pre-fix this was a bare
          // `continue` with no error and no counter (the S5/1f-3 silent skip).
          missingLocalBytes++;
          errors.add(
            'photo $canonicalId: no local bytes at "${photo.localPath}" — '
            'nothing to upload; the row is still pushed',
          );
          continue;
        }

        try {
          if (needsPrivate) {
            await _remote.uploadPhoto(
              uid: uid,
              photoId: canonicalId,
              ext: ext,
              bytes: bytes,
            );
          }
          if (needsShared) {
            await _remote.uploadSharedPhoto(
              photoId: canonicalId,
              ext: ext,
              bytes: bytes,
            );
          }
          uploaded++;
        } catch (e) {
          failedCanonicalIds.add(canonicalId);
          errors.add('photo $canonicalId: byte upload failed: $e');
        }
      }

      return (
        uploaded: uploaded,
        failed: failedCanonicalIds.length,
        missingLocalBytes: missingLocalBytes,
        failedCanonicalIds: failedCanonicalIds,
        errors: errors,
      );
    }
  ```

- [ ] **Step 10: Extend `_uploadOwnPhotos`' doc comment (lines 347-363) with the new contract.**
  ```dart
    /// §1f-3: every skip is now COUNTED and DESCRIBED rather than a silent
    /// `continue`. Three outcomes are distinguished, because they need three
    /// different responses:
    ///  - upload attempted and THREW (or the local read threw) -> retryable;
    ///    counted in `failed`, id added to `failedCanonicalIds` so `pushOwn`
    ///    withholds that row's metadata (S5), and surfaced so §1e retries;
    ///  - no local bytes AT ALL -> not retryable; counted in
    ///    `missingLocalBytes`, row still pushed (see
    ///    [PushSyncResult.photosMissingLocalBytes]);
    ///  - already present remotely, or tombstoned -> not a problem at all;
    ///    counted nowhere.
    ///
    /// The two `list*ObjectPaths` calls are deliberately left UN-guarded: their
    /// throw semantics (and the `photos.isEmpty` short-circuit above them) are
    /// §1d's honesty fix, not this method's.
  ```

- [ ] **Step 11: Adapt the single existing call site so the file compiles. The ORDER change is Task 9's job — keep the call exactly where §1e left it for now.**
  > Corrected (D-4 + Decision #8/#14 — the fragment's block rebuilt `wallVisibility` from the dirty-filtered `walls` list (**D-4**, silently wrong under `PushScope.dirtyOnly`) and recomputed `rowsPushed` with `tablesToRows.values.fold`, which §1d already replaced with an outcome-derived count. Both are removed; the patch now touches only the upload call and the result construction, and §1e's `_clearDirty` is shown in place so it is not accidentally deleted)

  ```dart
      // ONLY the `_uploadOwnPhotos` call and the result construction change in
      // this task.
      //
      //  - `wallVisibility` is §1e Task 4's `selectOnly` projection over EVERY
      //    own wall, read inside the snapshot transaction. Do NOT rebuild it
      //    from the `walls` list (reconciliation D-4 / duplication #4).
      //  - `rowsPushed` / `rowsFailed` / `errors` are §1d's, computed from
      //    `upsertOwnRows`' `List<TablePushOutcome>`. Leave that block exactly
      //    as §1d left it.
      //  - the dirty clear is §1e's, already narrowed to the tables §1d reported
      //    as LANDED (§1e's D-25 — an unconditional `_clearDirty(tablesToRows)`
      //    would mark rows clean that never reached the cloud). Leave it exactly
      //    as §1e wrote it; it is reproduced here only so it is not accidentally
      //    deleted while editing around it.
      //  - The ORDER change (bytes BEFORE metadata) is Task 9's job; this task
      //    keeps the upload call precisely where §1e left it.
      final photoUpload = await _uploadOwnPhotos(uid, photos, wallVisibility);

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
        photosUploaded: photoUpload.uploaded,
        rowsFailed: rowsFailed,
        errors: errors,
        photosFailed: photoUpload.failed,
        photosMissingLocalBytes: photoUpload.missingLocalBytes,
        photoErrors: photoUpload.errors,
      );
  ```

- [ ] **Step 12: Run the sync suite. The new `photosFailed`/`photosMissingLocalBytes`/`fullyLanded` assertions should now pass; the row-WITHHOLDING assertions arrive in Task 9.**
  > Corrected (D-13 — absolute test totals replaced; C1a's line reference corrected from :1123 to :1171)

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/backup/data/sync_service_test.dart
  ```
  Expected: `All tests passed!` — the pre-existing `sync_service_test.dart` tests plus this task's **5** new ones (3 from Step 2, 2 from Step 6). In particular the many tests seeding the default `localPath: '/tmp/placeholder.jpg'` still pass — notably C1a's `expect(result.rowsPushed, 8)` at **`:1171`** (that test opens at `:1116`) — because a missing-bytes photo row is still pushed.

- [ ] **Step 13: Run analyze and the full suite, then commit.**
  > Corrected (D-13 — absolute test totals replaced)

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter analyze && flutter test
  ```
  Expected: `No issues found!` · `flutter test` green at **baseline + 5** for this task.

**Assertions:**

- **(D-2 — the top-line assertion of this task, and of the whole fragment.) `PushSyncResult.fullyLanded` is `didPush && rowsFailed == 0 && errors.isEmpty && photosFailed == 0`.** With `FailingUploadSyncRemote` and one photo, `pushOwn()` returns `rowsFailed == 0`, `errors.isEmpty`, `photosFailed == 1` and **`fullyLanded == false`** — so `SyncOrchestrator._runPush` cannot report `SyncStatus.idle`, cannot stamp a fresh `lastSyncedAt`, and the Account screen cannot render "Synced • just now". A dedicated test asserts exactly this.
- **(D-2.) `photosMissingLocalBytes` is NOT part of `fullyLanded`.** A push whose only photo issue is `photosMissingLocalBytes == 1` returns `fullyLanded == true` — asserted by its own test — because that condition is non-retryable and gating on it would stop §1e's retry loop from ever terminating.
- **(D-2.) `SyncOrchestrator._runPush`'s not-fully-landed branch builds `lastPushError` from `[...result.errors, ...result.photoErrors].join('; ')`**, so a push that failed only in the photo channel renders a non-empty reason instead of "Sync failed: 0 change(s) not uploaded — ". `grep -n 'photoErrors' lib/features/backup/application/sync_orchestrator.dart` returns at least one hit, and `git diff lib/features/backup/application/sync_orchestrator.dart` touches **only** that one interpolation — §1d's `fullyLanded` gate, §1d's `await _failedPushStatus()` and §1e's `_scheduleRetry()` are unchanged, and no second `_scheduleRetry()` was added.
- **(Decision #8.)** `PushSyncResult.pushed` accepts `rowsFailed`, `errors`, `photosFailed`, `photosMissingLocalBytes` and `photoErrors` as OPTIONAL named params with defaults, so no existing construction site breaks; both `skipped*` constructors initialise all five; `grep -c 'class PushSyncResult' lib/features/backup/data/sync_service.dart` is **1** and there is exactly one `toString()`, naming all seven fields.
- **(D-5.)** Each new field's doc comment sits above its own declaration, and `photosFailed` is declared before `photosMissingLocalBytes`.
- With `FailingUploadSyncRemote`, `pushOwn()` returns `photosUploaded == 0`, `photosFailed == 1`, `hasPhotoFailures == true`, `photosMissingLocalBytes == 0`, and `photoErrors.single` contains both `'photo-1'` and `'byte upload failed'`.
- With a photo whose `localPath` resolves to nothing, `pushOwn()` returns `photosFailed == 0`, `hasPhotoFailures == false`, `photosMissingLocalBytes == 1`, and `photoErrors.single` contains `'no local bytes'`.
- A tombstoned photo leaves all three counters at 0 and still records the removal in `removedPrivatePaths`.
- `grep -n 'if (bytes == null) continue;' lib/features/backup/data/sync_service.dart` is EMPTY — the silent skip at the old line 404 is gone.
- **(D-4.)** `grep -n 'for (final wall in walls)' lib/features/backup/data/sync_service.dart` is EMPTY — `wallVisibility` is §1e's `selectOnly` projection over ALL own walls, not a derivation over the dirty-filtered list.
- `sync_service.dart` gained no new import (the bytes local is typed `List<int>?`, not `Uint8List?`): `git diff lib/features/backup/data/sync_service.dart | grep '^+import'` is empty.
- Pre-existing sync tests that seed the default `/tmp/placeholder.jpg` localPath still pass unchanged — notably C1a's `expect(result.rowsPushed, 8)` at `:1171` — proving a missing-bytes row is still pushed.
- `flutter analyze` = 0 issues; `flutter test` green at **baseline + 5** (D-13 — never an absolute total).

**Commit message:** `fix(sync): count photo byte-upload failures and gate fullyLanded on them (S1/D-2)`

### Task 9: Flip the push to bytes-then-metadata and withhold failed photo rows (S5)

**Files:**
- Modify: `lib/features/backup/data/sync_service.dart` — `pushOwn`'s body between the snapshot transaction (closes `:275`) and the result construction, plus the `'photos':` entry of `tablesToRows` (`:309-313`) and `pushOwn`'s doc (`:226-237`); `test/features/backup/data/sync_service_test.dart` — `FakeSyncRemote`'s tracking lists (`:28-33`), `upsertOwnRows` (`:35-60`), `uploadPhoto` (`:192-201`), `uploadSharedPhoto` (`:215-223`), and new tests inside `group('pushOwn', …)`
- Test: `test/features/backup/data/sync_service_test.dart`

**Interfaces:**
- Produces: the composed `pushOwn` statement order (decision #14); the `pushablePhotos` filter keyed on `_canonicalPhotoId`; `FakeSyncRemote.callLog`.
- Consumes: **§1d's** `Future<List<TablePushOutcome>> upsertOwnRows` (the fake's signature, its `outcomes` accumulation and its `return outcomes;`), `TablePushOutcome.ok`/`.failed`, the outcome-derived `rowsPushed`, and the `errors`/`rowsFailed` locals §1d Task 4 declared above the `guard` closure; **§1e's** `wallVisibility` `selectOnly` projection and its landed-table-narrowed `_clearDirty` (§1e's D-25); Task 8's `PhotoUploadOutcome` and merged `PushSyncResult`.

> **Decision #14 — the final composed order, which this task establishes:** snapshot (+ `wallVisibility` from §1e) → `_uploadOwnPhotos` → `pushablePhotos` filter → `tablesToRows` with dirty scoping **and** the required-field guard → `upsertOwnRows` → §1e's landed-table-narrowed dirty clear (its D-25) → merged result. §1e's rationale for clearing `dirty` after *both* phases is **superseded, not contradicted**: with bytes first, a failed byte upload keeps the row out of `tablesToRows` entirely, so it stays dirty by construction. **Do not "restore" the old ordering.**

- [ ] **Step 1: Give `FakeSyncRemote` an ordered call log so a test can assert the push ORDER, not just the end state. Add the field beside the existing tracking lists (lines 28-33).**
  ```dart
    /// Ordered log of every remote MUTATION this fake received, so a test can
    /// assert the push ORDER (bytes before metadata — S5) rather than only the
    /// end state. Entries are `'upload:<objectPath>'` and `'upsert:<table>'`.
    final List<String> callLog = [];
  ```

- [ ] **Step 2: Add the `callLog` hook to `FakeSyncRemote.upsertOwnRows`.**
  > Corrected (**D-7 — blocking.** The fragment's patch replaced only the internal `for` loop, without restating the signature or §1d Task 2's `outcomes` accumulation and `return outcomes;`. Applied literally after §1d it produces a method declared `Future<List<TablePushOutcome>>` with **no return statement** — a hard compile error. Rewritten below against the POST-§1d body, showing the WHOLE method. Note also that §1d's version already restructures the loop into `final rows = tablesToRows[tableName]; if (rows == null || rows.isEmpty) continue;`, which is exactly the per-table hook point the fragment's loop-header rewrite was trying to manufacture — so that rewrite is redundant as well as broken)

  ```dart
    // The WHOLE method, restated against the POST-§1d body (§1d Task 2 changed
    // `upsertOwnRows` from `Future<void>` to `Future<List<TablePushOutcome>>`
    // and added the `outcomes` accumulation plus `return outcomes;`). §1f adds
    // exactly one line — the `callLog.add('upsert:$tableName')` hook. The
    // ownerId `assert` stays OUTSIDE any try/catch so the C1b test at
    // sync_service_test.dart:1213-1231 still observes an `AssertionError`.
    @override
    Future<List<TablePushOutcome>> upsertOwnRows(
      String uid,
      Map<String, List<Map<String, dynamic>>> tablesToRows,
    ) async {
      final outcomes = <TablePushOutcome>[];
      for (final tableName in syncTableNames) {
        final rows = tablesToRows[tableName];
        if (rows == null || rows.isEmpty) continue;
        callLog.add('upsert:$tableName');
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

- [ ] **Step 3: Log the upload entries in `uploadPhoto` (after `uploadedPrivatePaths.add(path);`, verified at `:200`) and `uploadSharedPhoto` (after `uploadedSharedPaths.add(path);`, verified at `:223`).**
  ```dart
    // in uploadPhoto, after `uploadedPrivatePaths.add(path);`
      callLog.add('upload:$path');

    // in uploadSharedPhoto, after `uploadedSharedPaths.add(path);`
      callLog.add('upload:$path');
  ```

- [ ] **Step 4: Write the failing tests. Append inside `group('pushOwn', …)`.**
  ```dart
      test(
        '1f-2: bytes go up BEFORE the metadata — the photo object is uploaded '
        'before the photos table is upserted, so no window exists in which the '
        'cloud holds a row whose object is missing (S5)',
        () async {
          final remote = FakeSyncRemote();
          final c = makeContainer(
            remote: remote,
            auth: FakeAuthRepository(_signedInU1),
          );
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

          await c.service.pushOwn();

          final uploadIndex = remote.callLog.indexOf(
            'upload:$_uidU1/photo-1.jpg',
          );
          final upsertIndex = remote.callLog.indexOf('upsert:photos');
          expect(uploadIndex, greaterThanOrEqualTo(0));
          expect(upsertIndex, greaterThanOrEqualTo(0));
          expect(
            uploadIndex,
            lessThan(upsertIndex),
            reason: 'pre-fix the metadata upsert ran first '
                '(sync_service.dart:338 then :341)',
          );
        },
      );

      test(
        '1f-2: a photo whose byte upload THROWS has its Photos row held back '
        'from the metadata push, while every other table still pushes — and the '
        'next push, once uploads succeed, heals it',
        () async {
          final remote = FailingUploadSyncRemote();
          final c = makeContainer(
            remote: remote,
            auth: FakeAuthRepository(_signedInU1),
          );
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

          final first = await c.service.pushOwn();

          expect(first.didPush, isTrue);
          expect(first.photosFailed, 1);
          expect(
            first.rowsPushed,
            4,
            reason: 'area + sector + wall + route; the photo row is withheld',
          );

          final afterFailure = await remote.fetchOwnRows(_uidU1);
          expect(
            afterFailure['photos'],
            isEmpty,
            reason: 'no cloud row may point at a Storage object that does not '
                'exist (S5) — another device would keep the ORIGINATING '
                "device's localPath forever, and on web resolvePhotoPath is an "
                'identity passthrough with no existence check',
          );
          expect(afterFailure['walls']!.map((r) => r['id']), ['wall-1']);
          expect(afterFailure['routes']!.map((r) => r['id']), ['route-1']);
          expect(afterFailure['areas']!.map((r) => r['id']), ['area-1']);

          // The retry §1e schedules: uploads now succeed, so both the bytes AND
          // the previously-withheld row land. Nothing was lost — pushOwn re-reads
          // a full own-row snapshot every time (decision D-4).
          remote.failUploads = false;
          final second = await c.service.pushOwn();

          expect(second.photosFailed, 0);
          expect(second.photosUploaded, 1);
          final healed = await remote.fetchOwnRows(_uidU1);
          expect(healed['photos']!.map((r) => r['id']), ['photo-1']);
          expect(
            remote.privateStorage.containsKey('$_uidU1/photo-1.jpg'),
            isTrue,
          );
        },
      );

      test(
        '1f-2: a SLICE sharing a failed original\'s file is withheld too — its '
        'localPath points at the same object, so pushing it would reproduce the '
        'exact orphan-row problem',
        () async {
          final remote = FailingUploadSyncRemote();
          final c = makeContainer(
            remote: remote,
            auth: FakeAuthRepository(_signedInU1),
          );
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
          await c.db.into(c.db.photos).insert(
            PhotosCompanion.insert(
              id: 'slice-1',
              createdAt: 100,
              updatedAt: 100,
              ownerId: const Value(_uidU1),
              wallId: 'wall-1',
              localPath: file.path,
              kind: 'slice',
              width: 800,
              height: 600,
              parentPhotoId: const Value('photo-1'),
            ),
          );

          await c.service.pushOwn();

          final ownRows = await remote.fetchOwnRows(_uidU1);
          expect(
            ownRows['photos'],
            isEmpty,
            reason: 'both the original AND its slice resolve to the same '
                'canonical file id, so both are withheld',
          );
        },
      );
  ```

- [ ] **Step 5: Run and see the three new tests fail: today the upsert precedes the upload, and the photo row is pushed regardless.**
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/backup/data/sync_service_test.dart --plain-name '1f-2'
  ```
  Expected: RED: the ordering test fails with `uploadIndex` NOT less than `upsertIndex`; the withholding tests fail with `ownRows['photos']` containing `photo-1` and `rowsPushed == 5`.

- [ ] **Step 6: Move the upload block above the `tablesToRows` map. Insert this immediately after the snapshot transaction closes (line 275) and BEFORE the push-side NOT-NULL-guard comment at line 277.**
  > Corrected (**D-4 — blocking (silent correctness bug).** The fragment's block opened with `final wallVisibility = {for (final wall in walls) wall.id: wall.visibility};`, derived over the **dirty-filtered** `walls` list. Under `PushScope.dirtyOnly` that silently stops uploading the shared copy of a new photo attached to an already-pushed — therefore clean — shared wall, so that wall's viewers never see the new photo. The derivation is **deleted**: consume §1e Task 4's `selectOnly` projection over ALL own walls, read inside the snapshot transaction (reconciliation D-4 / duplication #4). Everything else in the block is byte-for-byte the fragment's)

  ```dart
      // Bytes BEFORE metadata (S5). A `Photos` row must never reach the cloud
      // ahead of the Storage object it points at: on the receiving device
      // `_downloadAndRewritePhotos` only rewrites `localPath` when bytes actually
      // arrived, so a row whose object is missing keeps the ORIGINATING device's
      // path — and on web `resolvePhotoPath`/`resolvePhotoPathSync` are identity
      // passthroughs with no existence check, making that path permanently dead
      // there. Uploading first and then filtering the photos table down to the
      // rows whose bytes DID land means the cloud can briefly hold an orphan
      // OBJECT (harmless — idempotently overwritten by the next push, and
      // removed outright once the photo is tombstoned) but never an orphan ROW.
      //
      // `wallVisibility` is NOT built here. §1e Task 4 already reads it inside
      // the snapshot transaction as a `selectOnly` projection over EVERY own
      // wall, dirty or not — consume that (reconciliation D-4 / duplication #4).
      // Deriving it from the `walls` list, as this fragment originally did, is
      // silently wrong under `PushScope.dirtyOnly`: it stops uploading the
      // SHARED copy of a newly-added photo whose wall is already pushed and
      // therefore clean, so that wall's viewers never see the new photo.
      final photoUpload = await _uploadOwnPhotos(uid, photos, wallVisibility);

      // Hold back exactly the photo rows whose bytes did NOT land this push.
      // Keyed by CANONICAL id (see [_canonicalPhotoId]) so a slice — which
      // shares its original's single on-disk file, and therefore its single
      // Storage object — is withheld alongside that original rather than
      // becoming an orphan row of its own. Every OTHER photo row (already
      // uploaded, just uploaded, tombstoned, or lacking local bytes entirely —
      // see [PushSyncResult.photosMissingLocalBytes]) still pushes, and every
      // other TABLE is untouched. The withheld rows are not lost: `pushOwn`
      // re-reads a full own-row snapshot every call (decision D-4), so the next
      // successful push carries them.
      final pushablePhotos = photoUpload.failedCanonicalIds.isEmpty
          ? photos
          : [
              for (final photo in photos)
                if (!photoUpload.failedCanonicalIds.contains(
                  _canonicalPhotoId(photo),
                ))
                  photo,
            ];
  ```

- [ ] **Step 7: Point the photos entry of `tablesToRows` (lines 309-313) at the filtered list.**
  ```dart
        'photos': filterValidSyncRows(
          [for (final row in pushablePhotos) row.toJson()],
          syncRequiredFields['photos'] ?? const ['id'],
          debugLabel: 'local photos (push)',
        ),
  ```

- [ ] **Step 8: Delete the now-duplicated lines that followed `upsertOwnRows`, leaving the upsert block followed by the dirty clear and the merged result.**
  > Corrected (Decision #14 + Decision #8 + §1e's D-25. The fragment's tail assumed the pre-§1d single-line `await _remote.upsertOwnRows(...)` and a `tablesToRows.values.fold` row count, and omitted §1e's dirty clear entirely. Rewritten as the composed post-§1d/§1e tail: §1d's outcome-driven upsert block, then §1e's dirty clear **narrowed to the tables §1d reported as landed** — reconciliation decision #14 writes that as a plain `_clearDirty(tablesToRows)`, but §1e's conversion correctly narrows it, because an unconditional clear would mark rows clean that never reached the cloud — then the merged result carrying BOTH failure channels)

  ```dart
      // S1 fix (§1d): upsertOwnRows reports per-table outcomes instead of
      // swallowing each table's error behind a debugPrint and returning void.
      // A WHOLE-CALL throw (the remote itself unreachable) is converted into
      // an all-tables-failed result here, so the row phase never propagates
      // and never lies about what landed. `errors`/`rowsFailed` were declared
      // above the `guard` closure by §1d Task 4 — do not re-declare them.
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

      // §1e Task 4: `dirty` clears only after a CONFIRMED push, by an
      // (id, updatedAt) compare-and-swap, and ONLY for the tables §1d reported
      // as landed (§1e's D-25 — clearing a failed table's rows would mark them
      // clean while they are not in the cloud, and the retry loop is gated on
      // `dirty`). It stays LAST because it needs `outcomes`.
      //
      // Bytes-first makes §1e's ORIGINAL rationale ("a row must not go clean
      // while its pixels are missing") moot rather than wrong: a photo whose
      // bytes failed never reaches `tablesToRows` at all, so it stays dirty by
      // construction. Do not "restore" the old ordering, and do not un-narrow
      // this clear.
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
        photosUploaded: photoUpload.uploaded,
        rowsFailed: rowsFailed,
        errors: errors,
        photosFailed: photoUpload.failed,
        photosMissingLocalBytes: photoUpload.missingLocalBytes,
        photoErrors: photoUpload.errors,
      );
  ```

- [ ] **Step 9: Update `pushOwn`'s doc comment (lines 226-237, as extended by §1e Task 4) so the ordering is documented as a contract, not an accident. APPEND this paragraph — do not delete §1e's `scope` / clear-on-confirm paragraphs.**
  ```dart
    /// ORDER MATTERS (S5): the photo BYTES are uploaded FIRST, and only then are
    /// the metadata rows upserted — with any photo whose bytes did not land held
    /// back from that upsert. Previously the metadata went first, so a failed
    /// byte upload left every OTHER device holding a `Photos` row pointing at a
    /// Storage object that never existed, unhealable on web. See
    /// [_uploadOwnPhotos] for the three outcomes it distinguishes and
    /// [PushSyncResult.photosFailed] for which of them withholds a row.
  ```

- [ ] **Step 10: Run the sync suite.**
  > Corrected (D-13 — absolute test totals replaced)

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/backup/data/sync_service_test.dart
  ```
  Expected: `All tests passed!` — the pre-existing tests, plus Task 8's 5, plus this task's 3. Confirm the pre-existing two-device pull tests (`:766-1112`) and C1a's `rowsPushed == 8` (`:1171`) are still green: their photos either have real bytes or fall in the missing-bytes bucket, which still pushes.

- [ ] **Step 11: Run analyze and the full suite, then commit.**
  > Corrected (D-13 — absolute test totals replaced)

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter analyze && flutter test
  ```
  Expected: `No issues found!` · `flutter test` green at **baseline + 3** for this task.

**Assertions:**

- `FakeSyncRemote.callLog.indexOf('upload:<uid>/photo-1.jpg') < callLog.indexOf('upsert:photos')` after a successful push — bytes precede metadata.
- With `FailingUploadSyncRemote`, `remote.fetchOwnRows(uid)['photos']` is EMPTY while `['walls']`, `['routes']` and `['areas']` each still carry their row, and `rowsPushed == 4` (the withheld photo row excluded from the count).
- Setting `remote.failUploads = false` and pushing again yields `photosFailed == 0`, `photosUploaded == 1`, `fetchOwnRows(uid)['photos']` == `['photo-1']`, and the object present in `privateStorage` — the withheld row heals on retry with no local write, which is what makes §1e's loop terminate.
- A slice row sharing a failed original's file is withheld too (both resolve to the same `_canonicalPhotoId`), so `['photos']` is empty rather than containing the slice alone.
- In `sync_service.dart`, the `await _uploadOwnPhotos(...)` line number is LOWER than the `await _remote.upsertOwnRows(...)` line number: `grep -n '_uploadOwnPhotos(uid\|upsertOwnRows(uid' lib/features/backup/data/sync_service.dart` confirms the order.
- All pre-existing `sync_service_test.dart` tests still pass unchanged, including C1a's `expect(result.rowsPushed, 8)` with the default `/tmp/placeholder.jpg` localPath.
- **(D-7.)** `FakeSyncRemote.upsertOwnRows` still declares `Future<List<TablePushOutcome>>`, still accumulates `outcomes`, and still ends with `return outcomes;` — the `callLog` hook is purely additive, and the file compiles.
- **(D-4.)** `grep -n 'for (final wall in walls)' lib/features/backup/data/sync_service.dart` is EMPTY.
- **(Decision #14.)** In `pushOwn`, the line numbers satisfy `_uploadOwnPhotos(` < `pushablePhotos` < `tablesToRows` < `upsertOwnRows(` < `_clearDirty(` < `return PushSyncResult.pushed(`.
- `flutter analyze` = 0 issues; `flutter test` green at **baseline + 3** (D-13).

**Commit message:** `fix(sync): upload photo bytes before pushing their metadata rows (S5)`

### Task 10: Prove the skip-set sees all 150 objects and re-uploads nothing — and correct the stale docs

**Files:**
- Modify: `test/features/backup/data/sync_service_test.dart` — import block (`:1-16`), `FakeSyncRemote.listPhotoObjectPaths` (`:209-213`), `listSharedPhotoObjectPaths` (`:229-230`), new tests inside `group('pushOwn', …)`, new `_SinglePageListingRemote` beside `FailingUploadSyncRemote`; **`CLAUDE.md`**
- Test: `test/features/backup/data/sync_service_test.dart`

**Interfaces:**
- Produces: `FakeSyncRemote.listPageRequests`; the truncating `_listPage` page function; `class _SinglePageListingRemote extends FakeSyncRemote`; three corrected CLAUDE.md claims.
- Consumes: Task 7's `collectPagedObjects` and `kStoragePageSize`; Task 9's withholding behaviour; the test file's `makeContainer`/`seedWallHierarchy` helpers; `PhotosCompanion.insert`.

> **Duplication #8 — this task owns the ENTIRE CLAUDE.md doc-correction block.** Two of the three corrections had **no owner anywhere in Stage 1** before reconciliation assigned them here. Do not skip them, and do not assume §1d or §1e already did them — neither fragment touches `CLAUDE.md`.

- [ ] **Step 1: Make `FakeSyncRemote`'s listings faithful to the Storage `list()` contract — truncating at a page limit and paging via the SAME `collectPagedObjects` helper `SupabaseSyncRemote` uses. Without the truncation the fake would never reproduce S6 and the 150-object test would be a false green. Add the import first.**
  ```dart
  // add to the import block of sync_service_test.dart:
  import 'package:masi/features/backup/data/storage_pagination.dart';
  ```

- [ ] **Step 2: Replace `FakeSyncRemote.listPhotoObjectPaths` (lines 209-213) and `listSharedPhotoObjectPaths` (lines 229-230) with paged versions over a truncating page function, and add the request log.**
  ```dart
    /// Every `(limit, offset)` pair the two listings below requested, in order —
    /// lets a test prove the listing actually PAGED rather than issuing one
    /// unbounded call.
    final List<({int limit, int offset})> listPageRequests = [];

    /// Simulates ONE Supabase Storage `list()` request over [storage]'s keys
    /// under [prefix]: sorted by name ascending (the API's `SortBy` default) and
    /// TRUNCATED to at most [limit] entries starting at [offset] — exactly the
    /// contract that silently hid every object past the 100th (S6). Both
    /// listings page through [collectPagedObjects], the same helper
    /// `SupabaseSyncRemote._listAllObjects` uses, so this fake exercises the real
    /// paging logic rather than a parallel reimplementation of it.
    List<String> _listPage(
      Map<String, List<int>> storage,
      String prefix,
      int limit,
      int offset,
    ) {
      listPageRequests.add((limit: limit, offset: offset));
      final keys = storage.keys.where((k) => k.startsWith(prefix)).toList()
        ..sort();
      if (offset >= keys.length) return const [];
      final end = offset + limit;
      return keys.sublist(offset, end > keys.length ? keys.length : end);
    }

    @override
    Future<Set<String>> listPhotoObjectPaths(String uid) async {
      final paths = await collectPagedObjects<String>(
        (limit, offset) async => _listPage(privateStorage, '$uid/', limit, offset),
      );
      return paths.toSet();
    }

    @override
    Future<Set<String>> listSharedPhotoObjectPaths() async {
      final paths = await collectPagedObjects<String>(
        (limit, offset) async =>
            _listPage(sharedStorage, 'shared/', limit, offset),
      );
      return paths.toSet();
    }
  ```

- [ ] **Step 3: Write the 150-object test. Append inside `group('pushOwn', …)`. Note the file writes are ESSENTIAL: without real bytes on disk a truncated skip-set would fall into the missing-bytes bucket and `photosUploaded` would stay 0, making the test a false green.**
  ```dart
      test(
        'S6: with 150 objects already in the remote, the skip-set contains all '
        '150 and ZERO bytes are re-uploaded — pre-fix the un-paged 100-object '
        'listing truncated the skip-set and re-uploaded the other 50 at FULL '
        'resolution on every single push',
        () async {
          final remote = FakeSyncRemote();
          final c = makeContainer(
            remote: remote,
            auth: FakeAuthRepository(_signedInU1),
          );
          addTearDown(() => c.db.close());

          // 150 originals on one private wall. Each has REAL bytes under
          // <docsDir>/photos/<id>.jpg (the canonical relative form since #17) AND
          // an already-present private object in the fake bucket. The real files
          // matter: with a truncated skip-set the 50 unseen photos must actually
          // RE-UPLOAD (photosUploaded == 50), not fall into the
          // missing-local-bytes bucket, or this test could not fail.
          final photosDir = Directory(p.join(c.docsDir.path, 'photos'))
            ..createSync(recursive: true);
          final bytes = List<int>.filled(4, 1);

          String idAt(int i) => 'photo-${i.toString().padLeft(3, '0')}';

          await seedWallHierarchy(
            c.db,
            ownerId: _uidU1,
            areaId: 'area-1',
            sectorId: 'sector-1',
            wallId: 'wall-1',
            photoId: idAt(0),
            routeId: 'route-1',
            localPath: 'photos/${idAt(0)}.jpg',
          );
          File(p.join(photosDir.path, '${idAt(0)}.jpg')).writeAsBytesSync(bytes);
          remote.privateStorage['$_uidU1/${idAt(0)}.jpg'] = bytes;

          for (var i = 1; i < 150; i++) {
            final id = idAt(i);
            await c.db.into(c.db.photos).insert(
              PhotosCompanion.insert(
                id: id,
                createdAt: 100,
                updatedAt: 100,
                ownerId: const Value(_uidU1),
                wallId: 'wall-1',
                localPath: 'photos/$id.jpg',
                kind: 'original',
                width: 800,
                height: 600,
                sortOrder: Value(i),
              ),
            );
            File(p.join(photosDir.path, '$id.jpg')).writeAsBytesSync(bytes);
            remote.privateStorage['$_uidU1/$id.jpg'] = bytes;
          }

          final result = await c.service.pushOwn();

          expect(result.didPush, isTrue);
          expect(
            result.photosUploaded,
            0,
            reason: 'all 150 objects are already in the bucket, so the skip-set '
                'must cover every one of them',
          );
          expect(remote.uploadedPrivatePaths, isEmpty);
          expect(result.photosFailed, 0);
          expect(result.photosMissingLocalBytes, 0);
          expect(result.photoErrors, isEmpty);

          // The listing PAGED: the private prefix holds 150 keys, so page 1
          // comes back exactly full at offset 0 and forces a second request at
          // offset 100.
          expect(
            remote.listPageRequests.where((r) => r.offset == 100),
            isNotEmpty,
            reason: 'the private listing must page past the 100-object default',
          );
          expect(
            remote.listPageRequests.every((r) => r.limit == kStoragePageSize),
            isTrue,
          );

          // And all 150 rows still push (nothing withheld — nothing failed).
          final ownRows = await remote.fetchOwnRows(_uidU1);
          expect(ownRows['photos'], hasLength(150));
        },
      );

      test(
        'S6: the paged skip-set is what prevents the re-upload — with the fake '
        'listing artificially truncated to one page, the 50 objects past the '
        'cut ARE re-uploaded (this is the pre-fix behaviour, asserted so the '
        'test above cannot silently become vacuous)',
        () async {
          final remote = _SinglePageListingRemote();
          final c = makeContainer(
            remote: remote,
            auth: FakeAuthRepository(_signedInU1),
          );
          addTearDown(() => c.db.close());

          final photosDir = Directory(p.join(c.docsDir.path, 'photos'))
            ..createSync(recursive: true);
          final bytes = List<int>.filled(4, 1);
          String idAt(int i) => 'photo-${i.toString().padLeft(3, '0')}';

          await seedWallHierarchy(
            c.db,
            ownerId: _uidU1,
            areaId: 'area-1',
            sectorId: 'sector-1',
            wallId: 'wall-1',
            photoId: idAt(0),
            routeId: 'route-1',
            localPath: 'photos/${idAt(0)}.jpg',
          );
          File(p.join(photosDir.path, '${idAt(0)}.jpg')).writeAsBytesSync(bytes);
          remote.privateStorage['$_uidU1/${idAt(0)}.jpg'] = bytes;

          for (var i = 1; i < 150; i++) {
            final id = idAt(i);
            await c.db.into(c.db.photos).insert(
              PhotosCompanion.insert(
                id: id,
                createdAt: 100,
                updatedAt: 100,
                ownerId: const Value(_uidU1),
                wallId: 'wall-1',
                localPath: 'photos/$id.jpg',
                kind: 'original',
                width: 800,
                height: 600,
                sortOrder: Value(i),
              ),
            );
            File(p.join(photosDir.path, '$id.jpg')).writeAsBytesSync(bytes);
            remote.privateStorage['$_uidU1/$id.jpg'] = bytes;
          }

          final result = await c.service.pushOwn();

          expect(
            result.photosUploaded,
            50,
            reason: 'exactly the objects past the 100-object cut — the cost S6 '
                'imposed on every push, at full resolution',
          );
        },
      );
  ```

- [ ] **Step 4: Add the deliberately-truncating subclass beside `FailingUploadSyncRemote`, to make the anti-vacuity test possible.**
  ```dart
  /// [FakeSyncRemote] that lists only the FIRST page of a prefix and stops —
  /// i.e. the pre-fix, un-paged `list(path: …)` behaviour. Exists purely so the
  /// 150-object test above can prove it would FAIL without pagination: an
  /// assertion that "nothing was re-uploaded" is only meaningful next to a
  /// demonstration that the truncated case really does re-upload.
  class _SinglePageListingRemote extends FakeSyncRemote {
    @override
    Future<Set<String>> listPhotoObjectPaths(String uid) async {
      final prefix = '$uid/';
      final keys = privateStorage.keys.where((k) => k.startsWith(prefix)).toList()
        ..sort();
      return keys.take(kStoragePageSize).toSet();
    }
  }
  ```

- [ ] **Step 5: Run just the two new tests.**
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/backup/data/sync_service_test.dart --plain-name 'S6'
  ```
  Expected: Both green: the paged case reports `photosUploaded == 0` with a request at `offset: 100`; the artificially-truncated case reports `photosUploaded == 50`.

- [ ] **Step 6: Run the whole sync suite, then analyze, then the full suite.**
  > Corrected (D-13 — absolute test totals replaced)

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/backup/data/sync_service_test.dart && flutter analyze && flutter test
  ```
  Expected: sync suite green · `No issues found!` · `flutter test` green at **baseline + 2** for this task.

- [ ] **Step 7: Correct ALL THREE stale CLAUDE.md claims this workstream invalidates. Run the greps first, so every correction is evidence-backed rather than asserted.**
  > Corrected (Duplication #8 — the fragment's step covered only the "~377 tests" line, and even that conditionally ("stays for §1d/§1e to fix if they get there first"). Reconciliation assigns the whole block here, unconditionally, including the `outbox` and `web_smoke_test` corrections that had NO owner in any fragment. All three verified against the real tree while writing this document)

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && grep -rin outbox lib --include="*.dart" | wc -l && grep -c "expect(" integration_test/web_smoke_test.dart && flutter test 2>&1 | tail -1
  ```
  Expected: `0` (no outbox anywhere in `lib/`) · `0` (`web_smoke_test.dart` asserts nothing) · the current green total, e.g. `01:22 +1586: All tests passed!`.

  Then apply the three replacements:

  ```dart
  // ---------------------------------------------------------------------------
  // (1) CLAUDE.md line 6 — there is NO outbox. `grep -rin outbox lib` returns
  // ZERO hits (run it); the engine is a debounced FULL-STATE re-push, which the
  // master plan records as decision D-4 and which "Out of bounds for this stage"
  // explicitly forbids replacing. Replace:
  //
  //   outbox push/pull + tombstoned soft-delete sync in `lib/features/backup/` (`sync_service.dart`,
  //
  // with:
  //
  //   debounced full-state re-push/pull + tombstoned soft-delete sync in `lib/features/backup/` (`sync_service.dart`,

  // ---------------------------------------------------------------------------
  // (2) CLAUDE.md line 64 — `integration_test/web_smoke_test.dart` contains ZERO
  // `expect()` calls (`grep -c 'expect(' integration_test/web_smoke_test.dart`
  // prints 0), so it proves the app BOOTS and the Area→Sector→Wall flow does not
  // throw. It does not assert persistence of anything. Replace:
  //
  //   real app boot → Area→Sector→Wall (drift-on-WASM persistence through real IndexedDB) — **both green**.
  //
  // with:
  //
  //   real app boot → Area→Sector→Wall drive-through on drift-on-WASM — **both green**. Neither
  //   asserts anything (`grep -c 'expect(' integration_test/web_smoke_test.dart` is 0); a real
  //   write → reload → assert persistence test is carried to Stage 2.

  // ---------------------------------------------------------------------------
  // (3) CLAUDE.md line 72 — the "~377 tests" baseline is years stale. Replace:
  //
  //   flutter test        # ~377 tests, must be green
  //
  // with (substituting the CURRENT green total from the run in the previous
  // step — 1586 at the time this fragment was written, plus everything Stage 1
  // has added by the time this task runs):
  //
  //   flutter test        # 1586+ tests, must be green
  ```

- [ ] **Step 8: Commit and confirm the tree is clean apart from intended files.**
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && git status --short | grep -E '^\s*M|^\?\?' | grep -v -E 'ios/|masi_icons|android/build|\.wrangler|docs/superpowers'
  ```
  Expected: Only the files listed in filesTouched (plus CLAUDE.md) appear as modified/new. `CLAUDE.md` is expected among them.

**Assertions:**

- `flutter test test/features/backup/data/sync_service_test.dart --plain-name 'S6'` is green with two tests.
- With 150 photo rows all backed by real local files AND all 150 objects pre-present in `FakeSyncRemote.privateStorage`, `pushOwn()` returns `photosUploaded == 0`, `uploadedPrivatePaths` is empty, and `photosFailed`/`photosMissingLocalBytes` are both 0 — the skip-set saw all 150.
- `remote.listPageRequests` contains an entry with `offset == 100` and every entry has `limit == kStoragePageSize`, proving the listing paged rather than issuing one unbounded call.
- `fetchOwnRows(uid)['photos']` has length 150 — pagination did not cause any row to be withheld.
- The anti-vacuity test with `_SinglePageListingRemote` reports `photosUploaded == 50`, demonstrating the un-paged behaviour the fix removes; without it the primary assertion could pass trivially.
- `FakeSyncRemote`'s two listings route through `collectPagedObjects` — the same helper `SupabaseSyncRemote._listAllObjects` uses — so the test exercises the real paging logic, not a parallel reimplementation.
- `flutter analyze` = 0 issues; `flutter test` green at **baseline + 2** for this task (D-13).
- **(Duplication #8, correction 1.)** CLAUDE.md no longer describes the sync engine as "outbox push/pull"; `grep -c outbox CLAUDE.md` is 0. The evidence is `grep -rin outbox lib --include="*.dart"` returning zero hits.
- **(Duplication #8, correction 2.)** CLAUDE.md no longer claims `integration_test/web_smoke_test.dart` proves "drift-on-WASM persistence through real IndexedDB". The evidence is `grep -c 'expect(' integration_test/web_smoke_test.dart` printing `0`, and the corrected text says so explicitly.
- **(Duplication #8, correction 3.)** CLAUDE.md's `flutter test` comment no longer claims "~377 tests"; it carries the current green total (≥ 1586).

**Commit message:** `test(sync): prove a 150-object skip-set is complete and re-uploads nothing (S6)`

---

## Risks

1. SHARED-FILE COLLISION is the top risk. `lib/features/backup/data/sync_service.dart`, `lib/features/backup/data/sync_remote.dart` and `test/features/backup/data/sync_service_test.dart` are all edited by §1d and §1e as well. T7–T10 MUST NOT run in parallel with those workstreams (see sequencingNotes) — a concurrent edit here means a git-stash recovery, which this repo has been bitten by before.

2. `PushSyncResult` is edited by both §1d (adding `rowsFailed` + a table-failure channel) and §1f (adding `photosFailed`/`photosMissingLocalBytes`/`photoErrors`). The three new params are OPTIONAL with defaults specifically so the merge is additive, but the constructor bodies and `toString()` will conflict textually. Reconciliation if §1d landed first: append the three params to the existing `pushed` ctor, add the three `= 0`/`= const []` initializers to BOTH `skipped*` ctors, and extend the single `toString()` interpolation. Do not create a second result class.

3. Withholding a photo row means the RECEIVING device's `routes` import can FK-violate (`Routes.photoId` → `Photos.id`, `PRAGMA foreign_keys = ON`) while the photo row is absent from the cloud. `BackupRepository.importSnapshot` isolates that per table (backup_repository.dart:85-92, and its own comment at :126-129 already anticipates exactly this), so it surfaces as a visible `PullResult.errors` entry and self-heals on the next successful push — but it WILL make the receiving device show 'Couldn't sync' for a cycle. Deliberate: honest and transient beats S5's silent permanent orphan. Verified the live Postgres schema has NO FK on `routes.photoId`/`photos.wallId` (supabase/schema.sql — only `comments.ascentId`/`likes.ascentId` carry REFERENCES), so the push side itself cannot FK-fail.

4. Treating `readPhotoBytes() == null` as WITHHOLDING would have broken ~15 existing tests that seed `seedWallHierarchy`'s default `localPath: '/tmp/placeholder.jpg'` and assert the photo row reaches the remote (C1a's `rowsPushed == 8` at sync_service_test.dart:1171, plus the whole two-device pull suite). It would also spin §1e's retry loop forever on a row whose bytes can never reappear. Hence the deliberate split into `photosFailed` (retryable, withheld) vs `photosMissingLocalBytes` (not retryable, still pushed). If a reviewer wants the spec's assertion read literally for BOTH cases, that is a larger change requiring those fixtures to write real files, and it must be raised before implementing rather than patched mid-task.

5. `§1e` must key its retry on `PushSyncResult.hasPhotoFailures` (i.e. `photosFailed > 0`), NOT on `photoErrors.isNotEmpty`. Keying on the error list would make a permanently-missing-bytes row retry forever at the backoff ceiling. This is the single most important cross-workstream contract in this plan.

6. `test/features/topo/data/photo_files_web_test.dart` imports the WEB branch file directly, which has no precedent in this repo. PROVEN to work in this session (probe test ran green on the VM: `image_ops/image_ops.dart` resolves to the pure-Dart native branch under `dart.library.io`, and `idbFactoryWeb` is never evaluated when a store is injected). If a future change adds a real `dart:js_interop` import to `photo_files_web.dart`, that test file stops compiling — the fallback is to move the propagation contract onto an interface-level test with an injected store abstraction.

7. `_QuotaFailingPhotoFiles extends PhotoFiles` relies on the stub/native constructors both accepting a zero-arg `super()` and on both declaring `importPhoto(XFile, String)` identically. `photo_files_stub.dart:12-21` documents that this signature-compatibility is maintained on purpose, but a future divergence breaks the subclass silently on one platform only. The class is duplicated in two test files (photo_ownership_test.dart, topos_screen_test.dart) because both copies are file-private — matching this repo's `_FakeSyncOrchestrator` precedent, but it is two places to update.

8. `softDeleteWall` in `_handleNewTopo`'s failure path runs a cascade soft-delete transaction (`_cascadeSoftDeleteWallSubtree`). If IT throws, the exception escapes the typed clause into the outer catch-all and the user gets no SnackBar plus an orphan wall — strictly worse than today. Consider wrapping it, or verify by inspection that a freshly-created empty wall's cascade cannot fail. Not covered by a test in this plan.

9. `MasiIcon` renders `SvgPicture.asset`, which needs the asset bundle under `flutter test`. Existing tests do assert `find.byType(MasiIcon)` successfully, so this should be fine — but if the new SnackBar widget test fails on asset loading, drop the icon (matching `gpsCaptureResultSnackBar`'s own icon-less `GpsCaptureResult.none` branch) rather than mocking the bundle.

10. The `removePhoto`/`removeSharedPhoto` calls in the tombstone branch of `_uploadOwnPhotos` are still un-guarded: a non-`StorageException` throw there propagates out of `pushOwn` and lands as `SyncStatus.error`. Pre-existing behaviour, deliberately left alone to keep this diff scoped — but it means the tombstone path has no counter while the upload path now does.

11. The Supabase Storage `list()` endpoint returns a `.emptyFolderPlaceholder` row for some prefixes, which would enter the skip-set as a bogus path. Pre-existing in both listings and not introduced here, but pagination makes the set larger and more visible. Worth a follow-up filter on `file.name`.

12. T3's second verification step showed the 'no Photos row' guarantee ALSO holds if the `importPhoto` await moves inside the transaction (drift rolls back on throw). The test therefore guards against a future refactor that CATCHES the exception and inserts anyway — not against ordering drift. Do not oversell it in the commit message.

13. `writePhotoBytes` now throws `PhotoWriteException` on the pull/restore path, and `_downloadAndRewritePhotos` is NOT per-photo guarded — the first failure aborts that whole section (caught upstream into `PullResult.errors`). The exception TYPE improves, the blast radius does not. Out of scope for §1f's assertions but a real quota-on-restore behaviour worth noting.

**Added by this conversion:**

14. **D-2 widens this fragment's blast radius to `sync_orchestrator.dart`.** The fragment's plan was to ship `hasPhotoFailures` as a seam and let §1e consume it; §1e does not. Task 8 therefore makes two edits inside `_runPush`'s `case SyncPushOutcome.pushed:` arm. That arm is §1d Task 5's code as modified by §1e Task 6, so **Task 8 now depends on §1e Task 8** (the last orchestrator task) as well as on §1e Task 4. If §1e's own conversion reshapes that branch, apply the same two changes to whatever it left behind rather than pasting the block verbatim.

15. **The retry that makes D-2 useful is §1e's, not §1f's — verify it is actually there.** D-2 only makes the app stop *lying*; something must still re-attempt the push. §1e's converted fragment arms `_scheduleRetry()` on both §1d failure paths (its D-28), which covers the not-fully-landed branch this task edits. **If §1e ever regresses that, §1f's "heals on the next push" assertion in Task 9 stays green at the SERVICE level while the running app sits in `SyncStatus.error` forever.** §1f deliberately does not add a second `_scheduleRetry()` — a duplicate would double-arm the backoff — so this is a cross-fragment dependency to check, not a line to write here.

16. **Task 7's `.list(` count is a moving target, so its assertion was reframed.** Pre-fix there are three call sites; post-fix the two in `sync_remote.dart` collapse into one `_listAllObjects`, so the number depends on how the refactor is shaped. The asserted contract is "**zero un-paged listings**", which is stable, with the count reported as supporting evidence.

17. **Task 6's `_makeContainer` block is the one place where a literal application of the fragment would have silently reverted another workstream.** §1a Task 4's `storageDurability` parameter and its *unconditional* `storageDurabilityProvider` override exist so the real notifier — fed by nothing, since `appDatabaseProvider` is overridden — can never leak into a test. The fragment's block omits both. The corrected block restores them; a verifier should diff `_makeContainer` against §1a's version and confirm only `photoFiles` was added.

## Sequencing notes (as written by the planner, with corrections marked)

Split this workstream into two independently-schedulable halves.

**Half A — photo path (T1–T6). Fully write-disjoint from §1d and §1e; can run in parallel with them.** Touches `lib/features/topo/data/{photo_write_exception,photo_files,photo_files_web,photo_files_native}.dart`, `lib/features/topo/presentation/{topo_canvas_photo_ops,topo_canvas_screen}.dart`, `lib/features/library/presentation/topos_screen.dart`, `lib/features/library/data/library_crud_repository.dart` (doc comment only), and their tests. T1→T2→T3 are strictly serial (each depends on the previous symbol). T4 depends on T1. T5 and T6 both depend on T4 and are file-disjoint from each other, so they may run in parallel.

**Half B — sync path (T7–T10). MUST be serialized against §1d and §1e.** Shared files:
- `lib/features/backup/data/sync_service.dart` — §1d rewrites `pushOwn`'s `upsertOwnRows` call and `PushSyncResult`; §1e rewrites the snapshot reads (dirty filter) and strips `dirty`/`remoteId` from the payload. T8/T9 rewrite `PushSyncResult`, `_uploadOwnPhotos` and `pushOwn`'s body. **Recommended order: §1d → §1e → §1f Half B**, so §1d defines the canonical failure-channel shape and §1f slots its photo counters alongside `rowsFailed` rather than the reverse.
- `lib/features/backup/data/sync_remote.dart` — §1d changes `upsertOwnRows`' return type and routes `filterValidSyncRows` skips into the failure channel; T7 changes only the two `list*ObjectPaths` methods and adds one import. Low overlap but still the same file: do not run concurrently.
- `test/features/backup/data/sync_service_test.dart` — §1d and §1e both extend `FakeSyncRemote` (§1d needs a per-table throwing variant, §1e needs `syncRemoteProvider`/`connectivityServiceProvider` override points). T9/T10 add `callLog`, paged listings, `listPageRequests`, `FailingUploadSyncRemote` and `_SinglePageListingRemote` to the same class. **Highest collision risk in the plan** — serialize.
- `lib/features/backup/data/storage_pagination.dart` is NEW and owned solely by §1f; §1d/§1e do not touch it.

**Not touched by §1f, deliberately:** `lib/features/backup/application/sync_orchestrator.dart`. §1f-3's "retried through §1e's loop" is delivered as a SEAM only — `PushSyncResult.hasPhotoFailures` — which §1e must consume in `_runPush` (currently sync_orchestrator.dart:204-220, which sets `idle` + a fresh `lastSyncedAt` on any `pushed` outcome). §1f asserts the count exists and heals on retry; §1e owns scheduling that retry and owns the honesty of the `sync-status` label.

**Other workstreams sharing Half A's files:** §1c edits `lib/features/library/data/library_crud_repository.dart` (row-count guards on `_ownOrUnowned` mutations) — T3 changes only `attachPhotoToWall`'s doc comment there, a small but real textual overlap; land T3 first or rebase it. §1c also edits `library_providers.dart`/`toposProvider`, which T6's `topos_screen_test.dart` harness reads — §1c may touch `_makeContainer` in that same test file, so coordinate the `photoFiles` parameter addition. Stage 3 edits `topos_empty_states.dart`, a `part` of the `topos_screen.dart` library — same library, different file, so no direct conflict.

**Baseline gate after every task:** `export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter analyze && flutter test` → 0 issues, ≥1576 passing. Commit at each task boundary (one logical change per commit, straight to `main`, never pushed).

**Corrections to the above:**

- "**Not touched by §1f, deliberately:** `lib/features/backup/application/sync_orchestrator.dart`" — **no longer true.** Reconciliation D-2 and the master plan's blocking-correction #1 both assign the `lastPushError` concatenation to §1f, and the `fullyLanded` amendment lives in `sync_service.dart` in Task 8. **The seam-only framing is exactly what would have let the S1 lie ship:** §1f asserts `hasPhotoFailures` exists, §1e never reads it, and nothing in between fails.
- "**Baseline gate after every task:** … ≥1576 passing" — the live baseline is **1586** (§1b tasks 1–2 landed). Per D-13, gate on `flutter test` being **green at baseline + N for this task**, never on an absolute total.
- "Half A … can run in parallel with them" — true for file-disjointness, but the master plan's [actual execution order](../2026-07-31-web-offline-stage1.md#actual-execution-order-used-supersedes-the-phase-grouping-above) runs **everything sequentially in the main working tree**, because the git index is shared state that file-disjointness does not protect. Treat the parallelism above as "safe to reorder", not "safe to run concurrently".
- "§1c edits `lib/features/library/data/library_crud_repository.dart` … land T3 first or rebase it" — §1c now exists as two fragments (`1c-a-uid-door.md`, `1c-b-router-rowguards.md`) and the master plan serialises **Phase 1.5** between the photo half and Phase 2. Follow the master plan's order.
- "T4 depends on T1. T5 and T6 both depend on T4" — correct, but add: **§1a Task 4 must precede Task 6**, which the fragment does not state (it mentions §1c's overlap on the same test file but not §1a's, which is the larger diff).

