# §1a — Storage-backend interlock (fixes L1), including `moveExistingIndexedDbToOpfs: true`

*Rendered from the §1a plan fragment (`fragment-0.json`) with the §1a-relevant corrections from the Stage-1 reconciliation pass (`reconciled.md`) applied. Corrections touch planning prose (test counts, sequencing notes, gate wording) only — every Dart/Python/bash code block below is preserved byte-for-byte from the source fragment.*

## Reconciliation corrections applied

- **D-13** — Every absolute test-count assertion in this fragment (1584 / 1590 / 1599 / 1604, and the risks section's "8 + 6 + 9 + 5 = 28, ending at 1604") assumed sole occupancy of the repo — untrue the moment any other Stage-1 workstream (§1b/§1d/§1e/§1f) commits first. Every such count below is restated as **baseline + N for this task**, gated on `flutter test` being fully green, never on an absolute total. Verified in-repo baseline (per reconciled.md): **1576 passing, 0 analyze issues**.

- **D-15** — The fragment claims Task 1's test file has 8 tests and Task 3's has 9. Recounted directly against the code blocks below: **Task 1 has 7 tests** (1 in `StorageBackend.isDurable`, 4 in `StorageDurability`, 2 in `logStorageDurability`) and **Task 3 has 8 tests** (5 in `connection_web.dart`, 1 in "lib/ has no kDebugMode-gated diagnostics left", 2 in "connection_native.dart is provably unchanged"). Every `expected`/assertion string that cited 8/9 is corrected to 7/8 below; the code blocks themselves are unchanged.

- **D-24** — Task 5's browser test has two cases. The **first** case ("the real `openConnection()` resolves to a DURABLE backend") opens the real, production-named `climbtopo` database in whatever origin headless Chrome serves the test from — it is **not hermetic** (it touches the same database name production uses, just in a throwaway test-run origin). The **second** case is hermetic by construction: it uses the test-only database name `masi_move_probe`, which can never collide with a real user's `climbtopo` database. Noted inline in Task 5 below.

- **Decision #7** — `_makeContainer()` in `topos_screen_test.dart` is a union point with §1f: §1a's Task 4 adds `StorageDurability storageDurability = const StorageDurability.probing()` (unconditionally overridden); §1f's later task adds `PhotoFiles? photoFiles` (conditionally overridden). The reconciled signature, in this exact order, is `_makeContainer({LocationService?, SyncOrchestrator?, StorageDurability storageDurability = const StorageDurability.probing(), PhotoFiles? photoFiles})`. §1a writes the `storageDurability` param **first**; §1f appends `photoFiles` later. Called out again inline in Task 4.

- **Decision #16** — §1a's own `sequencingNotes` (rendered in full near the end of this document) asked §1b to fold its persistent-storage verdict *into* `StorageDurability` so there would be "one provider, not three." **This was rejected during reconciliation**: `storageDurabilityProvider` (this fragment) and §1b's `storagePersistenceProvider` are different lifecycles (an async, drift-fed connection-layer verdict vs. a one-shot boot-time permission) and stay two separate `NotifierProvider`s. The demand is struck through in the sequencing notes below so no §1b implementer tries to satisfy it.

- **Decision #17** — The `openConnection({void Function(StorageDurability)? onStorageReport})` seam change (Task 2) is **accepted as-is**. Verified against the real source: exactly one production caller — `lib/core/db/database_provider.dart:17` (`final db = AppDatabase(openConnection());`) — and zero test callers reference `openConnection` directly (tests override `appDatabaseProvider` wholesale instead). Blast radius is nil.

- **D-20** — The `Future<void>.microtask(...)` wrapper in `appDatabaseProvider` (Task 2), around the *synchronous* native storage report, is **load-bearing** — it is what keeps `connection_native.dart`'s immediate `onStorageReport?.call(...)` from tripping Riverpod's `"Providers are not allowed to modify other providers during their initialization."` assert (`riverpod-3.3.2/lib/src/core/element.dart:795-803`). **Do not simplify it away** — Task 2's own last test exists solely to lock this in.

- **Ordering** — **Task 4 must land before §1f's "Wire the Topos-home New topo flow" task** — both modify `topos_screen.dart` and `topos_screen_test.dart` (§1a adds the storage-durability import, the `part 'topos_storage_banner.dart';` directive, the `canCreate` gate, the banner render call and the third `_handleNewTopo` guard; §1f later adds orphan-wall cleanup to the same flow). Per the repo rule that parallel implementers must be strictly file-disjoint, these two tasks cannot run concurrently — §1a Task 4 goes first.

Verified against the real files while writing this document (see the per-task notes below for specifics): every load-bearing line reference actually used as an insertion point in Task 4's steps (`topos_screen.dart:7,11,43,139,146,225,426` and `topos_screen_test.dart:123-142,166-180,544`) checked out **exactly** against the current source. A handful of purely-informational "interfaces consumed" citations for test helpers were off by one line (noted where they occur) — none of them are used as an edit anchor, so none affect implementation.

## Files touched

| Path | Action | Responsibility |
|---|---|---|
| `lib/core/db/connection/storage_durability.dart` | create | Platform-agnostic (VM-compilable, no dart:io, no dart:js_interop) vocabulary for the connection layer's persistence verdict: `StorageBackend` enum, `StorageMissingFeature` enum, immutable `StorageDurability` value class, and `logStorageDurability()` — the release-visible log that replaces the discarded `if (kDebugMode) debugPrint(...)`. |
| `lib/core/db/storage_durability_provider.dart` | create | Riverpod v3 `StorageDurabilityNotifier extends Notifier<StorageDurability>` + `storageDurabilityProvider`. Starts `probing`, is fed by `appDatabaseProvider`, logs every verdict, and re-exports `connection/storage_durability.dart` so consumers need one import. |
| `lib/features/library/presentation/topos_storage_banner.dart` | create | New `part of 'topos_screen.dart'` file holding `_StorageWarningBanner` — the unmissable, non-dismissible top-of-screen warning (key `topos-storage-warning`) plus its diagnostic detail line (key `topos-storage-warning-detail`). |
| `lib/core/db/connection/connection.dart` | modify | Add `export 'storage_durability.dart';` above the existing 3-line conditional export, mirroring `lib/features/topo/data/photo_files.dart`'s shared-part + conditional-export shape. Currently 3 lines total. |
| `lib/core/db/connection/connection_web.dart` | modify | Stop discarding `WasmDatabase.open`'s verdict: add the `onStorageReport` param, map `result.chosenImplementation`/`result.missingFeatures` onto `StorageDurability` via two exhaustive switches, pass `moveExistingIndexedDbToOpfs: true`, and delete the `if (kDebugMode)` block (lines 19-25) and the now-unused `package:flutter/foundation.dart` import. |
| `lib/core/db/connection/connection_native.dart` | modify | Add the same `onStorageReport` param and call it SYNCHRONOUSLY with `StorageBackend.nativeFile` before returning. The returned `LazyDatabase(...)` expression stays character-identical — asserted by a source test. |
| `lib/core/db/connection/connection_stub.dart` | modify | Signature parity only: add the `onStorageReport` param so the conditional-export seam keeps one signature across all three implementations. Still throws `UnsupportedError`. |
| `lib/core/db/database_provider.dart` | modify | `appDatabaseProvider` (lines 16-20) captures `storageDurabilityProvider.notifier` at build time and hands `report` to `openConnection()`, deferred by one microtask so a synchronous native report cannot trip Riverpod's "Providers are not allowed to modify other providers during their initialization" assert. |
| `lib/features/library/presentation/topos_screen.dart` | modify | Add the storage-durability import + `part 'topos_storage_banner.dart';`; watch `storageDurabilityProvider` in `build`; fold `!storage.isEphemeral` into `canCreate` (line 146, which already gates both `topos-new-topo` at :375 and `topos-empty-new-topo` via `_EmptyState(onNewTopo:)` at :266); render the banner above `_ToposFilterBar` (:225); add a third defensive guard to `_handleNewTopo` (:424-427). |
| `test/core/db/storage_durability_test.dart` | create | Unit tests for the value model + `logStorageDurability` (debugPrint swapped out to capture the emitted line). |
| `test/core/db/storage_durability_provider_test.dart` | create | Provider tests: default `probing`; `report()` publishes + logs; a post-dispose report logs and is dropped; and the native `appDatabaseProvider` ↔ `storageDurabilityProvider` wiring reports `nativeFile`/durable one microtask after the first read, without tripping Riverpod's mid-build-mutation assert. |
| `test/core/db/connection_seam_source_test.dart` | create | Source-scan guard (same shape as `test/ios_info_plist_test.dart` / `test/features/backup/schema_parity_test.dart`) for the properties nothing executable can assert: `connection_web.dart` cannot be compiled by the Dart VM at all. Pins `moveExistingIndexedDbToOpfs: true`, the two drift→masi enum mappings value-for-value, zero `kDebugMode` anywhere under `lib/`, and that `connection_native.dart`'s executor expression is byte-identical to the pre-change one. |
| `test/features/library/presentation/topos_screen_test.dart` | modify | Extend `_makeContainer` (lines 123-142) with a `storageDurability` param that always overrides `storageDurabilityProvider`, add a `_FakeStorageDurability` notifier double next to `_FakeSyncOrchestrator` (:166-180), and add the `§1a: storage-backend interlock (L1)` group. |
| `integration_test/web_storage_backend_test.dart` | create | Real-browser proof via `tool/drive_web.sh`: (1) the REAL `openConnection()` resolves to a non-`inMemory`, durable backend in a real browser; (2) an existing IndexedDB drift database reopened with `moveExistingIndexedDbToOpfs: true` keeps every seeded row — moving to OPFS where OPFS is available, staying put where it is not. |
| `tool/serve_web_isolated.py` | create | 25-line static server for `build/web` that applies (or deliberately omits) the COOP/COEP/CORP headers from `web/_headers`. `flutter drive -d web-server` has no `--web-header` flag, so headless Chrome can never be cross-origin isolated and drift never offers OPFS there — this script is the only way to exercise the real IndexedDB→OPFS move on Chrome before shipping. |

## Interfaces produced/consumed

### Produces

- enum StorageBackend { nativeFile, opfsShared, opfsLocks, sharedIndexedDb, unsafeIndexedDb, inMemory } — with `bool get isDurable => this != StorageBackend.inMemory;` (lib/core/db/connection/storage_durability.dart)
- enum StorageMissingFeature { sharedWorkers, dedicatedWorkers, dedicatedWorkersInSharedWorkers, fileSystemAccess, indexedDb, sharedArrayBuffers, workerError } — name-for-name mirror of drift's MissingBrowserFeature
- class StorageDurability { const StorageDurability({required StorageBackend? backend, Set<StorageMissingFeature> missingFeatures = const {}}); const StorageDurability.probing(); final StorageBackend? backend; final Set<StorageMissingFeature> missingFeatures; bool get isProbing; bool get isDurable; bool get isEphemeral; }
- void logStorageDurability(StorageDurability durability) — unconditional `debugPrint`, NOT behind kDebugMode
- class StorageDurabilityNotifier extends Notifier<StorageDurability> { @override StorageDurability build(); void report(StorageDurability durability); }
- final storageDurabilityProvider = NotifierProvider<StorageDurabilityNotifier, StorageDurability>(StorageDurabilityNotifier.new); (lib/core/db/storage_durability_provider.dart, which also re-exports connection/storage_durability.dart)
- QueryExecutor openConnection({void Function(StorageDurability verdict)? onStorageReport}) — the NEW seam signature, identical in connection_native.dart, connection_web.dart and connection_stub.dart
- Widget keys: 'topos-storage-warning' (the banner Container), 'topos-storage-warning-detail' (the backend/missing-features Text)
- Banner copy (exact): heading "This browser can't save your topos"; body 'Storage is blocked here, so anything you create would be lost the moment this page reloads. Creating topos is turned off until storage works. Private browsing and blocked site data are the usual causes — try a normal window, or install the app to your home screen.'; detail 'Storage: <backend>[ · missing: <f1, f2>]'
- Log line format (exact prefix, greppable in the browser console): 'masi/storage: backend=<name|probing> durable=<bool> missingFeatures=<comma-joined sorted names>'

### Consumes

- QueryExecutor openConnection() — lib/core/db/connection/connection_native.dart:10, connection_web.dart:7, connection_stub.dart:4 (all three signatures change)
- export seam — lib/core/db/connection/connection.dart:1-3
- final appDatabaseProvider = Provider<AppDatabase>((ref) { final db = AppDatabase(openConnection()); ref.onDispose(() => db.close()); return db; }); — lib/core/db/database_provider.dart:16-20
- WasmDatabase.open({required String databaseName, required Uri sqlite3Uri, required Uri driftWorkerUri, ..., bool moveExistingIndexedDbToOpfs = false, bool enableMigrations = true}) → Future<WasmDatabaseResult> — drift-2.34.2/lib/wasm.dart:155
- final class WasmDatabaseResult { final DatabaseConnection resolvedExecutor; final WasmStorageImplementation chosenImplementation; final Set<MissingBrowserFeature> missingFeatures; } — drift-2.34.2/lib/src/web/wasm_setup/types.dart (exported by package:drift/wasm.dart)
- enum WasmStorageImplementation { opfsShared, opfsLocks, sharedIndexedDb, unsafeIndexedDb, inMemory } with `final WebStorageApi? storageApi` — drift-2.34.2/lib/src/web/wasm_setup/types.dart:25-98; `availableImplementations` is seeded with `inMemory` (wasm_setup.dart:48-50) so inMemory is always last-preference, never absent
- enum MissingBrowserFeature { sharedWorkers, dedicatedWorkers, dedicatedWorkersInSharedWorkers, fileSystemAccess, indexedDb, sharedArrayBuffers, workerError } — types.dart:113-159
- abstract interface class WasmProbeResult { List<WasmStorageImplementation> get availableStorages; List<ExistingDatabase> get existingDatabases; Set<MissingBrowserFeature> get missingFeatures; Future<DatabaseConnection> open(WasmStorageImplementation, String name, {...}); Future<void> moveFromIndexedDBToOpfs(String databaseName); } — types.dart:165-233
- enum WebStorageApi { opfs, indexedDb } — types.dart:100-111
- LazyDatabase.close() is a no-op when the database was never opened — drift-2.34.2/lib/src/utils/lazy_database.dart:109-119 (this is what lets a VM test read appDatabaseProvider without touching path_provider)
- assert(_debugCurrentlyBuildingElement == null || _debugCurrentlyBuildingElement == this, 'Providers are not allowed to modify other providers during their initialization.') — riverpod-3.3.2/lib/src/core/element.dart:795-803
- bool get mounted => !_element._disposed && identical(_element.ref, this); — riverpod-3.3.2/lib/src/core/ref.dart:112
- class WifiOnlySetting extends Notifier<bool> { @override bool build() => false; } + NotifierProvider<WifiOnlySetting, bool>(WifiOnlySetting.new) — lib/features/backup/application/backup_providers.dart:41-51 (the repo's Notifier/NotifierProvider convention)
- class ToposScreen extends ConsumerStatefulWidget — lib/features/library/presentation/topos_screen.dart:73-97; part directives at :39-43; `final canCreate = loadedTopos != null && !_creating;` at :146; `key: const Key('topos-new-topo')` at :357 with `onPressed: canCreate ? _handleNewTopo : null` at :375; `_EmptyState(onNewTopo: canCreate ? _handleNewTopo : null)` at :265-267; `_handleNewTopo`'s two existing guards at :425-426
- class _EmptyState with `key: const Key('topos-empty-state')` (:18) and the inline `ElevatedButton(key: const Key('topos-empty-new-topo'), onPressed: onNewTopo)` (:29-37) — lib/features/library/presentation/topos_empty_states.dart
- MasiColors.of(context) fields ink (:48), ink2 (:51), ink3 (:54), gradeHard (:74), accent (:59), onAccent (:61); MasiSpacing.xs/sm/md/lg (:227-230); MasiRadii.card = 14 (:213); TextTheme defines titleMedium/bodyMedium/labelSmall (theme.dart:425/432/441) — lib/app/theme.dart
- MasiIcon(String name, {double? size, Color? color}) — lib/shared/presentation/masi_icon.dart:22; 'warning' exists at assets/icons/masi/masi_warning.svg and already renders inside a widget test via _SyncErrorEmptyState
- ProviderContainer _makeContainer({LocationService? locationService, SyncOrchestrator? syncOrchestrator}) — test/features/library/presentation/topos_screen_test.dart:123-142
- class _FakeSyncOrchestrator extends SyncOrchestrator — test/features/library/presentation/topos_screen_test.dart:166-180 (the Notifier-double pattern to copy)
- Widget _wrap(ProviderContainer container, Widget screen, {double? bottomChromeInset}) — test/features/library/presentation/topos_screen_test.dart:194-238
- Future<void> _drain(WidgetTester tester) — test/features/library/presentation/topos_screen_test.dart:245-253; Future<T> _dbWork<T>(WidgetTester, Future<T> Function()) at :305-312
- AreasCompanion.insert({required String id, required String name, ...}) — generated from `class Areas extends Table with SyncColumns` (lib/core/db/tables.dart:46-55); required non-defaulted columns are id, name, createdAt, updatedAt
- AppDatabase(QueryExecutor e) with `int get schemaVersion => 8` — lib/core/db/app_database.dart:27-31
- Future<void> bootApp({List<Override> overrides = const []}) — lib/main.dart:30

## Conventions

**Riverpod v3.3.2 — `Notifier`/`NotifierProvider` only, never `StateProvider`.** Copy `lib/features/backup/application/backup_providers.dart:41-51` verbatim in shape:
```dart
class WifiOnlySetting extends Notifier<bool> {
  @override
  bool build() => false;
  void set(bool value) => state = value;
}
final wifiOnlySettingProvider = NotifierProvider<WifiOnlySetting, bool>(WifiOnlySetting.new);
```
`Notifier` exposes `ref` from non-`build` methods (see `SyncOrchestrator._scheduleDebouncedPush`'s `ref.read(syncDebounceDurationProvider)`, sync_orchestrator.dart:184-189). `ref.mounted` exists (riverpod-3.3.2/lib/src/core/ref.dart:112).

**A provider may NOT mutate another provider during its own initialization.** riverpod-3.3.2/lib/src/core/element.dart:795-803 asserts exactly that, with the message `Providers are not allowed to modify other providers during their initialization.` This is why `appDatabaseProvider` wraps the native (synchronous) storage report in `Future<void>.microtask(...)`. Do not "simplify" that away.

**Conditional-import seam, never `kIsWeb`, for anything platform-split.** Two shapes exist and this workstream uses both:
```dart
// lib/core/db/connection/connection.dart (a pure conditional export)
export 'connection_stub.dart'
    if (dart.library.io) 'connection_native.dart'
    if (dart.library.js_interop) 'connection_web.dart';
```
```dart
// lib/features/topo/data/photo_files.dart — shared platform-agnostic part FIRST,
// then the conditional export. This is the exact pattern to copy when adding
// storage_durability.dart alongside the seam.
export 'photo_path_resolution.dart';
export 'photo_files_stub.dart'
    if (dart.library.io) 'photo_files_native.dart'
    if (dart.library.js_interop) 'photo_files_web.dart';
```
All three seam implementations must declare the **identical** signature — `flutter analyze` type-checks all three files even though `flutter test` only compiles the native one. The grep gate `grep -rlE "^[[:space:]]*(import|export)[[:space:]]+['\"]dart:io['\"]" lib --include="*.dart" | grep -v '_native.dart'` must stay empty; `storage_durability.dart` therefore imports only `package:flutter/foundation.dart` (for `@immutable`, `setEquals`, `debugPrint`) and NEVER `dart:io` or `dart:js_interop`.

**`package:drift/wasm.dart` cannot be compiled by the Dart VM** (it imports `dart:js_interop`), so `connection_web.dart` is unreachable from `flutter test`. Never import drift's web enums outside `connection_web.dart`; never import `package:drift/src/...` (the `implementation_imports` lint from `lints-6.1.0/lib/recommended.yaml:26` is active).

**Logging = bare `debugPrint`, never `print` (`avoid_print` is on), never behind `kDebugMode`.** 38 `debugPrint` sites exist in `lib/`; `kDebugMode` appears **exactly once**, at `connection_web.dart:19` — the swallowed L1 signal this workstream deletes. After this work `grep -rn kDebugMode lib` must be empty, and a test enforces that. `debugPrint` is a mutable top-level function pointer, so tests capture it:
```dart
final original = debugPrint;
debugPrint = (String? m, {int? wrapWidth}) { if (m != null) captured.add(m); };
addTearDown(() => debugPrint = original);
```

**Immutable state classes carry hand-written `==`/`hashCode`/`toString`** — copy `SyncOrchestratorState` (sync_orchestrator.dart:33-87): `@immutable`, `const` constructor, `identical(this, other) || (other is X && ...)`, `Object.hash(...)`, and a `toString` that names every field.

**Notifier test doubles override `build()` only.** Copy `_FakeSyncOrchestrator` (topos_screen_test.dart:166-180) and wire with `provider.overrideWith(() => _Fake...())`. Test fakes are deliberately duplicated per file when the original is library-private ("duplicated locally since that one is file-private", topos_screen_test.dart:161-162).

**Source-scanning guard tests are an established pattern** for invariants no executable test can reach: `test/ios_info_plist_test.dart` (regex over `ios/Runner/Info.plist`) and `test/features/backup/schema_parity_test.dart:31` (`File('supabase/schema.sql').readAsStringSync()`, paths relative to the repo root). `dart:io` in `test/` is fine — the grep gate covers `lib/` only.

**Widget-test harness in `topos_screen_test.dart`:** `_makeContainer()` builds `AppDatabase(NativeDatabase.memory())` and registers `addTearDown(db.close)` BEFORE `addTearDown(container.dispose)` (teardowns run LIFO, so the container is disposed first — otherwise closing the connection under a live watch stream hangs). `_wrap()` supplies a real minimal `GoRouter` + `MasiTheme.light`. `_drain(tester)` is the only way real Drift async work progresses under `testWidgets` (6 × `tester.runAsync(Future.delayed(20ms))` + `pump(30ms)`, then `pumpAndSettle`). Never drive a real image-codec decode in a widget test.

**Every command is PATH-prefixed** (Homebrew Flutter, PATH does not persist between shell calls): `export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test <path>`.

**Commit style:** `type(scope): summary`, one logical change per commit, straight to `main`, and every message ends with the trailer `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>` (project CLAUDE.md).

## Tasks

### Task 1: Platform-agnostic storage-durability model + release-visible log

**Files:**
- Create: `lib/core/db/connection/storage_durability.dart`, `test/core/db/storage_durability_test.dart`
- Test: `test/core/db/storage_durability_test.dart`

**Interfaces:**
- Produces: `enum StorageBackend` (+ `isDurable`), `enum StorageMissingFeature`, `class StorageDurability` (`.probing()`, `isProbing`/`isDurable`/`isEphemeral`), `void logStorageDurability(StorageDurability)`.
- Consumes: `package:flutter/foundation.dart` only (`@immutable`, `setEquals`, `debugPrint`) — no `dart:io`, no `dart:js_interop`.

- [ ] **Step 1: Confirm the baseline before touching anything.**
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter analyze
  ```
  Expected: No issues found!

- [ ] **Step 2: Read the file this workstream replaces, so you have seen the exact code being deleted (the `if (kDebugMode)` block at lines 19-25 discards `result.chosenImplementation` and `result.missingFeatures`).**
  ```bash
  cat /Users/kerip/Projects/masi/lib/core/db/connection/connection_web.dart
  ```

- [ ] **Step 3: Write the failing test file for the value model + logging. It compiles against symbols that do not exist yet, so it fails to compile — that is the red step.**
  ```dart
  // test/core/db/storage_durability_test.dart
  import 'package:flutter/foundation.dart';
  import 'package:flutter_test/flutter_test.dart';
  import 'package:masi/core/db/connection/storage_durability.dart';

  /// Captures every [debugPrint] emitted while [body] runs, restoring the real
  /// implementation afterwards. `debugPrint` is a plain mutable top-level
  /// function pointer, which is exactly why the release-visible logging in
  /// [logStorageDurability] is assertable without inventing a log-sink seam.
  List<String> _captureDebugPrint(void Function() body) {
    final captured = <String>[];
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) captured.add(message);
    };
    addTearDown(() => debugPrint = original);
    body();
    debugPrint = original;
    return captured;
  }

  void main() {
    group('StorageBackend.isDurable', () {
      test('only inMemory is non-durable', () {
        expect(StorageBackend.inMemory.isDurable, isFalse);
        for (final backend in StorageBackend.values) {
          if (backend == StorageBackend.inMemory) continue;
          expect(
            backend.isDurable,
            isTrue,
            reason: '$backend must count as durable — unsafeIndexedDb is '
                'race-prone across tabs (L8) but it DOES persist',
          );
        }
      });
    });

    group('StorageDurability', () {
      test('probing is neither durable nor ephemeral', () {
        const probing = StorageDurability.probing();
        expect(probing.isProbing, isTrue);
        expect(probing.isDurable, isFalse);
        expect(probing.isEphemeral, isFalse);
        expect(probing.backend, isNull);
        expect(probing.missingFeatures, isEmpty);
      });

      test('an inMemory verdict is ephemeral, not durable', () {
        const verdict = StorageDurability(
          backend: StorageBackend.inMemory,
          missingFeatures: {
            StorageMissingFeature.indexedDb,
            StorageMissingFeature.dedicatedWorkers,
          },
        );
        expect(verdict.isProbing, isFalse);
        expect(verdict.isEphemeral, isTrue);
        expect(verdict.isDurable, isFalse);
      });

      test('native/OPFS/IndexedDB verdicts are durable, not ephemeral', () {
        for (final backend in const [
          StorageBackend.nativeFile,
          StorageBackend.opfsShared,
          StorageBackend.opfsLocks,
          StorageBackend.sharedIndexedDb,
          StorageBackend.unsafeIndexedDb,
        ]) {
          final verdict = StorageDurability(backend: backend);
          expect(verdict.isDurable, isTrue, reason: '$backend');
          expect(verdict.isEphemeral, isFalse, reason: '$backend');
        }
      });

      test('equality covers the missing-feature set, not just the backend', () {
        const a = StorageDurability(
          backend: StorageBackend.inMemory,
          missingFeatures: {StorageMissingFeature.indexedDb},
        );
        const b = StorageDurability(
          backend: StorageBackend.inMemory,
          missingFeatures: {StorageMissingFeature.indexedDb},
        );
        const c = StorageDurability(
          backend: StorageBackend.inMemory,
          missingFeatures: {StorageMissingFeature.sharedWorkers},
        );
        expect(a, b);
        expect(a.hashCode, b.hashCode);
        expect(a, isNot(c));
      });
    });

    group('logStorageDurability', () {
      test('logs the chosen backend + missing features via debugPrint', () {
        final lines = _captureDebugPrint(() {
          logStorageDurability(
            const StorageDurability(
              backend: StorageBackend.inMemory,
              missingFeatures: {StorageMissingFeature.sharedArrayBuffers},
            ),
          );
        });

        expect(lines, hasLength(1));
        expect(lines.single, contains('masi/storage:'));
        expect(lines.single, contains('backend=inMemory'));
        expect(lines.single, contains('durable=false'));
        expect(lines.single, contains('sharedArrayBuffers'));
      });

      test('logs a durable backend too — it is the "my data vanished" answer',
          () {
        final lines = _captureDebugPrint(() {
          logStorageDurability(
            const StorageDurability(backend: StorageBackend.opfsLocks),
          );
        });
        expect(lines.single, contains('backend=opfsLocks'));
        expect(lines.single, contains('durable=true'));
      });
    });
  }

  ```

- [ ] **Step 4: Run the test and see it fail (red).**
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/core/db/storage_durability_test.dart
  ```
  Expected: Compile error: Error: Couldn't resolve the package 'masi/core/db/connection/storage_durability.dart' / undefined name 'StorageBackend'.

- [ ] **Step 5: Write the implementation.**
  ```dart
  // lib/core/db/connection/storage_durability.dart
  import 'package:flutter/foundation.dart';

  /// Where the local database actually ended up living, as reported by the
  /// platform connection layer (`connection_native.dart` on iOS/Android,
  /// `connection_web.dart` in the browser).
  ///
  /// Deliberately a masi-owned enum rather than drift's own
  /// `WasmStorageImplementation`: that type lives behind
  /// `package:drift/wasm.dart`, which imports `dart:js_interop` and therefore
  /// cannot be compiled by the Dart VM — so nothing `flutter test` runs, and
  /// nothing in a native build, may reference it. Keeping the vocabulary here
  /// is what lets the provider, the release logging and the create-topo
  /// interlock all be unit-tested under `flutter test`, while
  /// `connection_web.dart` stays the ONLY file in the repo that knows drift's
  /// web types exist. `connection_web.dart` maps drift's enum onto this one
  /// with an exhaustive `switch`, so a drift upgrade that adds a storage
  /// implementation is a `flutter analyze` error rather than a silent
  /// mis-report.
  enum StorageBackend {
    /// iOS/Android/desktop: a real sqlite file in the app documents directory.
    /// Always durable; there is nothing to probe.
    nativeFile,

    /// drift `WasmStorageImplementation.opfsShared` — OPFS hosted in a shared
    /// worker. drift's preferred web backend.
    opfsShared,

    /// drift `WasmStorageImplementation.opfsLocks` — OPFS behind two dedicated
    /// workers using `Atomics.wait`. Requires cross-origin isolation, i.e. the
    /// COOP/COEP headers in `web/_headers`.
    opfsLocks,

    /// drift `WasmStorageImplementation.sharedIndexedDb` — IndexedDB hosted in
    /// a shared worker.
    sharedIndexedDb,

    /// drift `WasmStorageImplementation.unsafeIndexedDb` — IndexedDB from the
    /// main browsing context. Persistent, but drift documents it as unable to
    /// prevent cross-tab data races (L8; the race half is out of scope here).
    unsafeIndexedDb,

    /// drift `WasmStorageImplementation.inMemory`, which drift documents as
    /// "doesn't store anything".
    ///
    /// This is L1. `WasmDatabase.open` NEVER throws: when none of the browser
    /// features it needs are available it silently returns this. Every write
    /// succeeds, every list populates, and the entire library is gone on the
    /// next page load.
    inMemory;

    /// Whether data written to this backend survives a page reload / app
    /// restart. Note [unsafeIndexedDb] counts as durable — it is race-prone
    /// across tabs, but it does persist.
    bool get isDurable => this != StorageBackend.inMemory;
  }

  /// Browser features drift probed for and did not find. Mirrors drift's
  /// `MissingBrowserFeature` name-for-name without importing it — see
  /// [StorageBackend] for why.
  enum StorageMissingFeature {
    sharedWorkers,
    dedicatedWorkers,
    dedicatedWorkersInSharedWorkers,
    fileSystemAccess,
    indexedDb,
    sharedArrayBuffers,
    workerError,
  }

  /// The platform connection layer's verdict on local persistence.
  @immutable
  class StorageDurability {
    const StorageDurability({
      required this.backend,
      this.missingFeatures = const {},
    });

    /// The state before any verdict has arrived.
    ///
    /// Only ever observed on web, and only for as long as
    /// `WasmDatabase.open`'s browser-feature probe takes — it starts the moment
    /// `appDatabaseProvider` is first read (during boot), well before a user
    /// gesture can reach the "New topo" flow. Native reports synchronously and
    /// is never in this state after its first `appDatabaseProvider` read.
    ///
    /// Deliberately counts as "allow creation": [isEphemeral] is false here, so
    /// the interlock blocks only on a KNOWN-bad backend, never on a
    /// not-yet-known one. Blocking on `probing` would also disable creation in
    /// every widget test (which overrides `appDatabaseProvider` and so never
    /// runs `openConnection`).
    const StorageDurability.probing()
        : backend = null,
          missingFeatures = const {};

    /// `null` while [isProbing].
    final StorageBackend? backend;

    /// Empty on native and whenever drift found everything it looked for.
    final Set<StorageMissingFeature> missingFeatures;

    /// No verdict yet.
    bool get isProbing => backend == null;

    /// The backend is KNOWN to keep data across a reload.
    bool get isDurable => backend?.isDurable ?? false;

    /// The backend is KNOWN to lose data across a reload. This is the single
    /// condition the create-topo interlock blocks on.
    bool get isEphemeral => backend != null && !backend!.isDurable;

    @override
    bool operator ==(Object other) =>
        identical(this, other) ||
        (other is StorageDurability &&
            other.backend == backend &&
            setEquals(other.missingFeatures, missingFeatures));

    @override
    int get hashCode =>
        Object.hash(backend, Object.hashAllUnordered(missingFeatures));

    @override
    String toString() =>
        'StorageDurability(backend: $backend, durable: $isDurable, '
        'missingFeatures: $missingFeatures)';
  }

  /// Logs [durability] — deliberately NOT behind `kDebugMode`.
  ///
  /// This line is the only thing that can answer a "my data vanished" web
  /// report (design doc §1a / L1), and a RELEASE web build is exactly where it
  /// matters, so it must not be compiled out. `debugPrint` is the repo's
  /// standard log call (38 other sites) and is a plain mutable top-level
  /// function that still forwards to `print` in release builds — on web that
  /// reaches the browser console, where `masi/storage:` is greppable.
  /// `test/core/db/storage_durability_test.dart` swaps `debugPrint` out to
  /// assert this fires; `test/core/db/connection_seam_source_test.dart`
  /// asserts no `kDebugMode` gate has crept back into `lib/`.
  void logStorageDurability(StorageDurability durability) {
    final missing = durability.missingFeatures.map((f) => f.name).toList()
      ..sort();
    debugPrint(
      'masi/storage: backend=${durability.backend?.name ?? 'probing'} '
      'durable=${durability.isDurable} '
      'missingFeatures=${missing.join(',')}',
    );
  }

  ```

- [ ] **Step 6: Run the test again and see it pass (green).**
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/core/db/storage_durability_test.dart
  ```
  Expected: All tests passed. (7 tests) — corrected per D-15 (the file contains 7 tests, not 8)

- [ ] **Step 7: Confirm the whole-project gates still hold.**
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter analyze && flutter test
  ```
  Expected: No issues found! and `flutter test` green at baseline + 7 (D-13/D-15 correction: gate on green, not the absolute number 1584; the true new-test count for this task is 7, not 8)

- [ ] **Step 8: Confirm the dart:io grep gate is still empty (the new file must not have introduced one).**
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && tool/build_web.sh --gate
  ```
  Expected: ok: no dart:io outside *_native.dart

- [ ] **Step 9: Commit.**

**Assertions:**
- `flutter test test/core/db/storage_durability_test.dart` passes with 7 tests (D-15 correction: the file contains 7 tests, not 8).
- `StorageBackend.inMemory.isDurable` is `false`; all five other values are `true` (asserted by iterating `StorageBackend.values`).
- `const StorageDurability.probing()` has `isProbing == true`, `isDurable == false`, `isEphemeral == false` — a not-yet-known backend is never treated as non-durable.
- `StorageDurability(backend: StorageBackend.inMemory)` has `isEphemeral == true` and `isDurable == false`.
- `logStorageDurability` emits exactly ONE `debugPrint` line containing `masi/storage:`, `backend=inMemory`, `durable=false` and the missing-feature name — captured by swapping the mutable `debugPrint` top-level.
- `grep -c kDebugMode lib/core/db/connection/storage_durability.dart` is 0.
- `grep -rlE "^[[:space:]]*(import|export)[[:space:]]+['\"]dart:io['\"]" lib --include="*.dart" | grep -v '_native.dart'` is empty.
- `flutter analyze` reports 0 issues; `flutter test` is green at baseline + 7 (D-13 correction: never gate on the absolute number 1584).

**Commit message:** `feat(db): add a platform-agnostic storage-durability model + release-visible log`

### Task 2: Surface the connection layer's verdict through storageDurabilityProvider

**Files:**
- Create: `lib/core/db/storage_durability_provider.dart`, `test/core/db/storage_durability_provider_test.dart`
- Modify: `lib/core/db/connection/connection.dart:1-3`, `lib/core/db/connection/connection_native.dart:1-16`, `lib/core/db/connection/connection_stub.dart:1-5`, `lib/core/db/connection/connection_web.dart:1-28`, `lib/core/db/database_provider.dart:1-20`
- Test: `test/core/db/storage_durability_provider_test.dart`

**Interfaces:**
- Produces: `class StorageDurabilityNotifier extends Notifier<StorageDurability>`, `final storageDurabilityProvider`, the new `QueryExecutor openConnection({void Function(StorageDurability)? onStorageReport})` seam signature (identical across `connection_native.dart`, `connection_web.dart`, `connection_stub.dart`).
- Consumes: the OLD `QueryExecutor openConnection()` zero-arg seam (`connection_native.dart:10`, `connection_web.dart:7`, `connection_stub.dart:4` — verified against the real files), the export seam `connection.dart:1-3`, the old `appDatabaseProvider` body (`database_provider.dart:16-20`, verified), `WasmDatabase.open`/`WasmDatabaseResult`/`WasmStorageImplementation`/`MissingBrowserFeature` (`package:drift/wasm.dart`), Riverpod's mid-build-mutation assert (`riverpod-3.3.2/lib/src/core/element.dart:795-803` — see D-20 above), `ref.mounted`, and the `WifiOnlySetting`/`NotifierProvider` convention (`backup_providers.dart:41-51`). **Decision #17**: the new seam signature has exactly one production caller (`database_provider.dart:17`) and zero test callers.

- [ ] **Step 1: Write the failing provider + wiring test.**
  ```dart
  // test/core/db/storage_durability_provider_test.dart
  import 'package:drift/drift.dart' show LazyDatabase, QueryExecutor;
  import 'package:flutter/foundation.dart';
  import 'package:flutter_riverpod/flutter_riverpod.dart';
  import 'package:flutter_test/flutter_test.dart';
  import 'package:masi/core/db/app_database.dart';
  import 'package:masi/core/db/connection/connection.dart';
  import 'package:masi/core/db/database_provider.dart';
  import 'package:masi/core/db/storage_durability_provider.dart';

  void main() {
    group('storageDurabilityProvider', () {
      test('starts out probing', () {
        final container = ProviderContainer();
        addTearDown(container.dispose);

        expect(container.read(storageDurabilityProvider).isProbing, isTrue);
        expect(container.read(storageDurabilityProvider).isEphemeral, isFalse);
      });

      test('report() publishes the verdict AND logs it', () {
        final container = ProviderContainer();
        addTearDown(container.dispose);

        final captured = <String>[];
        final original = debugPrint;
        debugPrint = (String? m, {int? wrapWidth}) {
          if (m != null) captured.add(m);
        };
        addTearDown(() => debugPrint = original);

        container.read(storageDurabilityProvider.notifier).report(
              const StorageDurability(
                backend: StorageBackend.inMemory,
                missingFeatures: {StorageMissingFeature.sharedArrayBuffers},
              ),
            );
        debugPrint = original;

        expect(
          container.read(storageDurabilityProvider).backend,
          StorageBackend.inMemory,
        );
        expect(container.read(storageDurabilityProvider).isEphemeral, isTrue);
        expect(captured.single, contains('backend=inMemory'));
      });

      test(
        'a verdict that lands after teardown is still logged, then dropped — '
        'never throws',
        () {
          final container = ProviderContainer();
          final notifier = container.read(storageDurabilityProvider.notifier);
          container.dispose();

          expect(
            () => notifier.report(
              const StorageDurability(backend: StorageBackend.nativeFile),
            ),
            returnsNormally,
          );
        },
      );
    });

    group('openConnection (native seam)', () {
      test(
        'reports nativeFile/durable SYNCHRONOUSLY and still returns an '
        'unopened LazyDatabase — no path_provider or filesystem work here',
        () {
          final reports = <StorageDurability>[];
          final QueryExecutor executor = openConnection(
            onStorageReport: reports.add,
          );

          expect(reports, hasLength(1));
          expect(reports.single.backend, StorageBackend.nativeFile);
          expect(reports.single.isDurable, isTrue);
          expect(reports.single.missingFeatures, isEmpty);
          expect(executor, isA<LazyDatabase>());
        },
      );

      test('openConnection() with no callback still works (old call shape)', () {
        expect(openConnection(), isA<LazyDatabase>());
      });
    });

    group('appDatabaseProvider <-> storageDurabilityProvider wiring', () {
      test(
        'the native verdict lands one microtask after the first read, WITHOUT '
        "mutating a provider during appDatabaseProvider's own build",
        () async {
          final container = ProviderContainer();
          addTearDown(container.dispose);

          // Riverpod asserts "Providers are not allowed to modify other
          // providers during their initialization." (riverpod
          // src/core/element.dart). connection_native.dart calls
          // `onStorageReport` synchronously, so this read would trip that
          // assert if appDatabaseProvider did not defer the report by a
          // microtask.
          expect(container.read(appDatabaseProvider), isA<AppDatabase>());
          expect(
            container.read(storageDurabilityProvider).isProbing,
            isTrue,
            reason: 'the report must NOT have been applied synchronously',
          );

          await Future<void>.delayed(Duration.zero);

          expect(
            container.read(storageDurabilityProvider).backend,
            StorageBackend.nativeFile,
          );
          expect(container.read(storageDurabilityProvider).isDurable, isTrue);
          expect(container.read(storageDurabilityProvider).isEphemeral, isFalse);
        },
      );
    });
  }

  ```

- [ ] **Step 2: Run the test and see it fail (red).**
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/core/db/storage_durability_provider_test.dart
  ```
  Expected: Compile error: undefined name 'storageDurabilityProvider'; openConnection does not accept named argument 'onStorageReport'.

- [ ] **Step 3: Create the provider.**
  ```dart
  // lib/core/db/storage_durability_provider.dart
  import 'package:flutter_riverpod/flutter_riverpod.dart';

  import 'connection/storage_durability.dart';

  export 'connection/storage_durability.dart';

  /// App-wide, release-observable answer to "can this device actually keep the
  /// data we write?".
  ///
  /// Fed by `appDatabaseProvider` (`database_provider.dart`), which hands
  /// [StorageDurabilityNotifier.report] to `openConnection()` as its
  /// `onStorageReport` callback:
  ///  - native reports [StorageBackend.nativeFile] synchronously, before the
  ///    executor is even returned, so it is in its final durable state on the
  ///    very first frame;
  ///  - web reports once `WasmDatabase.open`'s browser-feature probe resolves,
  ///    which is what makes L1 (a silent [StorageBackend.inMemory] backend that
  ///    loses the entire library on reload) visible for the first time.
  ///
  /// Read by `topos_screen.dart` to disable BOTH create-topo affordances and
  /// render `_StorageWarningBanner` whenever [StorageDurability.isEphemeral].
  /// Stage 2's runtime-diagnostics row (design doc §2c) is expected to read the
  /// same provider rather than re-probing.
  ///
  /// Not `.autoDispose`: there is exactly one verdict per app run and every
  /// later reader must see it, including ones that mount long after boot.
  class StorageDurabilityNotifier extends Notifier<StorageDurability> {
    @override
    StorageDurability build() => const StorageDurability.probing();

    /// Records — and unconditionally logs — the connection layer's verdict.
    ///
    /// Logs BEFORE the `ref.mounted` check on purpose: a verdict that arrives
    /// after the container was torn down (a web probe resolving during a hot
    /// restart, say) is still the most valuable line in the console, and
    /// dropping it silently is the exact failure mode §1a exists to end.
    /// Assigning `state` after disposal would throw, hence the guard.
    void report(StorageDurability durability) {
      logStorageDurability(durability);
      if (!ref.mounted) return;
      state = durability;
    }
  }

  final storageDurabilityProvider =
      NotifierProvider<StorageDurabilityNotifier, StorageDurability>(
    StorageDurabilityNotifier.new,
  );

  ```

- [ ] **Step 4: Re-export the shared value types from the seam barrel, mirroring `photo_files.dart`'s shape. Replace the whole of `lib/core/db/connection/connection.dart` (currently 3 lines).**
  ```dart
  // lib/core/db/connection/connection.dart
  //
  // Facade for the local-database connection.
  //
  // `storage_durability.dart` is the platform-AGNOSTIC half (the verdict
  // vocabulary every platform reports in, plus its release-visible log) and is
  // exported unconditionally; the conditional export below then picks the right
  // backend for the running platform. Same two-part shape as
  // `lib/features/topo/data/photo_files.dart`.
  export 'storage_durability.dart';
  export 'connection_stub.dart'
      if (dart.library.io) 'connection_native.dart'
      if (dart.library.js_interop) 'connection_web.dart';

  ```

- [ ] **Step 5: Add the `onStorageReport` param to the native seam. The `LazyDatabase(...)` expression is left CHARACTER-IDENTICAL — a source test in task 3 asserts that.**
  ```dart
  // lib/core/db/connection/connection_native.dart
  import 'dart:io';

  import 'package:drift/drift.dart';
  import 'package:drift/native.dart';
  import 'package:path/path.dart' as p;
  import 'package:path_provider/path_provider.dart';

  import 'storage_durability.dart';

  /// Native (iOS/Android/desktop) connection — opens climbtopo.sqlite in the
  /// app documents directory. Byte-identical to the pre-split implementation.
  ///
  /// [onStorageReport] is invoked exactly once, SYNCHRONOUSLY, before the
  /// executor is returned. A real sqlite file on the device filesystem is
  /// unconditionally durable — there is nothing to probe and nothing that can
  /// degrade — so reporting up front means the create-topo interlock
  /// (`topos_screen.dart`) is already in its final `durable` state on the very
  /// first frame, and `StorageDurability.probing` is a web-only state in
  /// practice. Nothing about HOW the database is opened changed: same documents
  /// directory, same filename, same `NativeDatabase`, still lazy.
  QueryExecutor openConnection({
    void Function(StorageDurability verdict)? onStorageReport,
  }) {
    onStorageReport?.call(
      const StorageDurability(backend: StorageBackend.nativeFile),
    );
    return LazyDatabase(() async {
      final dir = await getApplicationDocumentsDirectory();
      final file = File(p.join(dir.path, 'climbtopo.sqlite'));
      return NativeDatabase(file);
    });
  }

  ```

- [ ] **Step 6: Add the same param to the stub so all three seam implementations share one signature (`flutter analyze` type-checks all three even though `flutter test` only compiles the native one).**
  ```dart
  // lib/core/db/connection/connection_stub.dart
  import 'package:drift/drift.dart';

  import 'storage_durability.dart';

  /// Fallback used when neither dart:io nor dart:js_interop is available.
  ///
  /// [onStorageReport] exists purely for signature parity across the
  /// conditional-export seam — this implementation never reaches the point of
  /// having a verdict to report.
  QueryExecutor openConnection({
    void Function(StorageDurability verdict)? onStorageReport,
  }) =>
      throw UnsupportedError('No database connection available on this platform.');

  ```

- [ ] **Step 7: Rewrite the web seam so it stops discarding drift's verdict. `moveExistingIndexedDbToOpfs` is deliberately LEFT OUT here — task 3 adds it, so its own test goes red first.**
  ```dart
  // lib/core/db/connection/connection_web.dart
  import 'package:drift/drift.dart';
  import 'package:drift/wasm.dart';

  import 'storage_durability.dart';

  /// Web connection — drift on WASM (OPFS-via-worker where available, IndexedDB
  /// fallback). Assets `sqlite3.wasm` + `drift_worker.js` are pinned in web/.
  ///
  /// [onStorageReport] receives drift's verdict — which storage implementation
  /// was actually chosen, and which browser features were missing — exactly
  /// once, as soon as `WasmDatabase.open`'s feature probe resolves. That
  /// verdict used to be thrown away behind an `if (kDebugMode) debugPrint(...)`,
  /// which is L1 in
  /// `docs/superpowers/specs/2026-07-30-web-offline-reliability-design.md`:
  /// `WasmDatabase.open` NEVER throws, it silently degrades to
  /// `WasmStorageImplementation.inMemory` ("doesn't store anything"), so every
  /// write succeeds, every list populates, and the whole library is gone on the
  /// next page load with zero production signal.
  QueryExecutor openConnection({
    void Function(StorageDurability verdict)? onStorageReport,
  }) {
    // Wrapping `result.resolvedExecutor` (a `DatabaseConnection`) in a bare
    // `LazyDatabase` would discard its `BroadcastStreamQueryStore`, silently
    // breaking cross-tab watch() invalidation. `DatabaseConnection.delayed`
    // preserves `streamQueries` (via a `DelayedStreamQueryStore`) while still
    // deferring the async WASM setup.
    return DatabaseConnection.delayed(Future(() async {
      final result = await WasmDatabase.open(
        databaseName: 'climbtopo',
        sqlite3Uri: Uri.parse('sqlite3.wasm'),
        driftWorkerUri: Uri.parse('drift_worker.js'),
      );
      onStorageReport?.call(
        StorageDurability(
          backend: _backendOf(result.chosenImplementation),
          missingFeatures: {
            for (final feature in result.missingFeatures) _featureOf(feature),
          },
        ),
      );
      return result.resolvedExecutor;
    }));
  }

  /// Maps drift's web-only `WasmStorageImplementation` onto the
  /// platform-agnostic [StorageBackend] the rest of the app — and every
  /// `flutter test` unit test — speaks.
  ///
  /// Exhaustive by construction: a drift upgrade that adds a storage
  /// implementation makes this `switch` non-exhaustive, which `flutter analyze`
  /// reports as an error. That matters more than convenience here — a mapping
  /// that quietly resolved a new value to "durable" would re-open L1.
  StorageBackend _backendOf(WasmStorageImplementation implementation) {
    return switch (implementation) {
      WasmStorageImplementation.opfsShared => StorageBackend.opfsShared,
      WasmStorageImplementation.opfsLocks => StorageBackend.opfsLocks,
      WasmStorageImplementation.sharedIndexedDb => StorageBackend.sharedIndexedDb,
      WasmStorageImplementation.unsafeIndexedDb => StorageBackend.unsafeIndexedDb,
      WasmStorageImplementation.inMemory => StorageBackend.inMemory,
    };
  }

  /// Same idea as [_backendOf], for drift's `MissingBrowserFeature`. These are
  /// what a support report needs to explain WHY a browser ended up on a weaker
  /// backend (e.g. `sharedArrayBuffers` missing means the COOP/COEP headers in
  /// `web/_headers` did not arrive, so OPFS was never on the table).
  StorageMissingFeature _featureOf(MissingBrowserFeature feature) {
    return switch (feature) {
      MissingBrowserFeature.sharedWorkers => StorageMissingFeature.sharedWorkers,
      MissingBrowserFeature.dedicatedWorkers =>
        StorageMissingFeature.dedicatedWorkers,
      MissingBrowserFeature.dedicatedWorkersInSharedWorkers =>
        StorageMissingFeature.dedicatedWorkersInSharedWorkers,
      MissingBrowserFeature.fileSystemAccess =>
        StorageMissingFeature.fileSystemAccess,
      MissingBrowserFeature.indexedDb => StorageMissingFeature.indexedDb,
      MissingBrowserFeature.sharedArrayBuffers =>
        StorageMissingFeature.sharedArrayBuffers,
      MissingBrowserFeature.workerError => StorageMissingFeature.workerError,
    };
  }

  ```

- [ ] **Step 8: Wire the provider into `appDatabaseProvider`. Add `import 'storage_durability_provider.dart';` after the existing `import 'connection/connection.dart';` (line 4), then replace the provider body at lines 16-20 with this.**
  ```dart
  /// Opens the on-device [AppDatabase], deferring the actual file-system/SQLite
  /// work until first use via [LazyDatabase] so constructing this provider
  /// never blocks.
  ///
  /// Intended to be OVERRIDDEN in tests with an in-memory
  /// `AppDatabase(NativeDatabase.memory())`.
  final appDatabaseProvider = Provider<AppDatabase>((ref) {
    // The connection layer's storage verdict (native: "a real sqlite file, so
    // durable"; web: whatever `WasmDatabase.open`'s browser-feature probe
    // resolved to) is published on `storageDurabilityProvider` instead of being
    // discarded — that discard is L1 in
    // `docs/superpowers/specs/2026-07-30-web-offline-reliability-design.md`.
    //
    // The notifier is captured HERE, at build time, rather than `ref.read` from
    // inside the callback: on web that callback fires long after this build
    // returns, and reaching through a possibly-disposed `ref` then would throw.
    //
    // The report is deferred by one microtask because `connection_native.dart`
    // calls `onStorageReport` SYNCHRONOUSLY, i.e. while this provider is still
    // initializing — and Riverpod asserts "Providers are not allowed to modify
    // other providers during their initialization."
    // (riverpod/src/core/element.dart). One microtask puts the state write
    // safely outside both this build and any widget build that triggered it; on
    // web it changes nothing, since the callback is already asynchronous.
    // `report()` is itself `ref.mounted`-guarded, so a verdict that lands after
    // teardown is logged and dropped rather than crashing.
    final storage = ref.read(storageDurabilityProvider.notifier);
    final db = AppDatabase(
      openConnection(
        onStorageReport: (verdict) =>
            Future<void>.microtask(() => storage.report(verdict)),
      ),
    );
    ref.onDispose(() => db.close());
    return db;
  });

  ```

- [ ] **Step 9: Run the test and see it pass (green).**
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/core/db/storage_durability_provider_test.dart
  ```
  Expected: All tests passed. (6 tests)

- [ ] **Step 10: Confirm the whole-project gates, including that the untouched 1576 tests are unaffected by the new `appDatabaseProvider` dependency (every test overrides `appDatabaseProvider` with a value, so `openConnection` never runs there).**
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter analyze && flutter test
  ```
  Expected: No issues found! and `flutter test` green at baseline + 13 (7 from Task 1 + 6 from this task) — D-13 correction, gate on green not on 1590

- [ ] **Step 11: Confirm the web target still compiles with the new seam signature and the dart:io gate is clean.**
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && tool/build_web.sh
  ```
  Expected: ok: no dart:io outside *_native.dart / ok: assets match drift 2.34.2 / build complete: build/web

- [ ] **Step 12: Commit.**

**Assertions:**
- `flutter test test/core/db/storage_durability_provider_test.dart` passes with 6 tests.
- `container.read(storageDurabilityProvider)` is `probing` on a fresh container.
- `notifier.report(...)` sets the state AND emits one `masi/storage:` log line.
- `notifier.report(...)` after `container.dispose()` returns normally (logs, drops the state write).
- `openConnection(onStorageReport: reports.add)` on native produces exactly ONE report with `backend == StorageBackend.nativeFile`, `isDurable == true`, `missingFeatures` empty, and returns a `LazyDatabase` — proving no path_provider/filesystem work happens at construction.
- `openConnection()` with no arguments still returns a `LazyDatabase` — the old call shape is source-compatible.
- `container.read(appDatabaseProvider)` does not throw Riverpod's "Providers are not allowed to modify other providers during their initialization." assert, `storageDurabilityProvider` is still `probing` immediately after that read, and becomes `nativeFile`/durable after `await Future<void>.delayed(Duration.zero)`.
- `flutter analyze` = 0 issues (this is what type-checks `connection_web.dart` and `connection_stub.dart`, including both switch exhaustiveness checks).
- `flutter test` is green at baseline + 13; no previously-passing test changed behaviour (D-13 correction: never gate on the absolute number 1590).
- `tool/build_web.sh` completes: the wasm build still compiles with the new seam signature.

**Commit message:** `feat(db): surface the drift web storage verdict through a provider instead of discarding it`

### Task 3: Pass moveExistingIndexedDbToOpfs: true and pin the web seam with a source guard

**Files:**
- Create: `test/core/db/connection_seam_source_test.dart`
- Modify: `lib/core/db/connection/connection_web.dart:20-40`
- Test: `test/core/db/connection_seam_source_test.dart`

**Interfaces:**
- Produces: pins `moveExistingIndexedDbToOpfs: true` on the real `WasmDatabase.open` call; no new public symbol.
- Consumes: the source-scanning-guard-test convention (`test/ios_info_plist_test.dart`, `test/features/backup/schema_parity_test.dart`), and Task 2's `onStorageReport`/`_backendOf`/`_featureOf` seam it pins by regex.

- [ ] **Step 1: Write the source-scan guard test. `connection_web.dart` imports `package:drift/wasm.dart` → `dart:js_interop`, so the Dart VM can never compile it; this is the only way to assert its content from `flutter test`. Follows `test/ios_info_plist_test.dart` / `test/features/backup/schema_parity_test.dart` (paths relative to the repo root).**
  ```dart
  // test/core/db/connection_seam_source_test.dart
  import 'dart:io';

  import 'package:flutter_test/flutter_test.dart';

  /// `connection_web.dart` is the single most safety-critical file in the web
  /// build — it is where L1 (a silent `inMemory` drift backend that loses the
  /// whole library on reload) is either caught or missed — and it is the ONE
  /// file `flutter test` can never execute: it imports
  /// `package:drift/wasm.dart`, which imports `dart:js_interop`, so the Dart VM
  /// cannot compile it at all.
  ///
  /// Coverage is therefore split three ways:
  ///  - `flutter analyze` type-checks it, including the exhaustiveness of its
  ///    two enum switches (a drift upgrade adding a storage implementation is
  ///    an analyzer error);
  ///  - `integration_test/web_storage_backend_test.dart` exercises it for real
  ///    in a browser;
  ///  - THIS test pins the properties neither of those can assert: that the
  ///    verdict is surfaced rather than discarded, that the log is not gated
  ///    behind `kDebugMode`, that `moveExistingIndexedDbToOpfs: true` is
  ///    actually passed, and that the drift->masi enum mapping is
  ///    value-for-value correct (analyze proves the switch is TOTAL, not that
  ///    it maps `inMemory` to `inMemory`).
  ///
  /// Whitespace is collapsed before matching so `dart format`'s line breaking
  /// can never make an assertion spuriously fail.
  String _normalized(String path) {
    final file = File(path);
    expect(file.existsSync(), isTrue, reason: 'expected $path to exist');
    return file.readAsStringSync().replaceAll(RegExp(r'\s+'), ' ');
  }

  void main() {
    const webPath = 'lib/core/db/connection/connection_web.dart';
    const nativePath = 'lib/core/db/connection/connection_native.dart';

    group('connection_web.dart', () {
      test("surfaces drift's verdict instead of discarding it", () {
        final source = _normalized(webPath);
        expect(source, contains('onStorageReport?.call('));
        expect(source, contains('_backendOf(result.chosenImplementation)'));
        expect(source, contains('result.missingFeatures'));
      });

      test('logs OUTSIDE kDebugMode — no kDebugMode gate anywhere', () {
        expect(
          _normalized(webPath),
          isNot(contains('kDebugMode')),
          reason: 'the pre-fix code hid the storage verdict behind '
              '`if (kDebugMode)`, which is precisely why total data loss was '
              'invisible in the release web build',
        );
      });

      test('passes moveExistingIndexedDbToOpfs: true', () {
        expect(
          _normalized(webPath),
          contains('moveExistingIndexedDbToOpfs: true'),
          reason: "drift's default is false, which makes "
              '`_selectExistingDatabase` pin every install that first landed '
              'on IndexedDB to IndexedDB forever (L8 lock-in)',
        );
      });

      test('maps every drift storage implementation to the right backend', () {
        final source = _normalized(webPath);
        for (final name in const [
          'opfsShared',
          'opfsLocks',
          'sharedIndexedDb',
          'unsafeIndexedDb',
          'inMemory',
        ]) {
          expect(
            source,
            contains('WasmStorageImplementation.$name => StorageBackend.$name,'),
            reason: "mapping drift's $name onto anything but "
                'StorageBackend.$name would silently mis-report durability',
          );
        }
      });

      test('maps every drift missing-browser-feature', () {
        final source = _normalized(webPath);
        for (final name in const [
          'sharedWorkers',
          'dedicatedWorkers',
          'dedicatedWorkersInSharedWorkers',
          'fileSystemAccess',
          'indexedDb',
          'sharedArrayBuffers',
          'workerError',
        ]) {
          expect(
            source,
            contains(
              'MissingBrowserFeature.$name => StorageMissingFeature.$name,',
            ),
          );
        }
      });
    });

    group('lib/ has no kDebugMode-gated diagnostics left', () {
      test('zero kDebugMode occurrences under lib/', () {
        final offenders = <String>[];
        for (final entity in Directory('lib').listSync(recursive: true)) {
          if (entity is! File) continue;
          if (!entity.path.endsWith('.dart')) continue;
          if (entity.path.endsWith('.g.dart')) continue;
          if (entity.readAsStringSync().contains('kDebugMode')) {
            offenders.add(entity.path);
          }
        }
        expect(
          offenders,
          isEmpty,
          reason: 'lib/ had exactly ONE kDebugMode before this work — the '
              'swallowed drift storage verdict (L1). Any new one is a '
              'diagnostic that will be invisible in the release web build, '
              'which is the only place it matters.',
        );
      });
    });

    group('connection_native.dart is provably unchanged', () {
      test('reports durable BEFORE returning the executor', () {
        final source = _normalized(nativePath);
        final reportAt = source.indexOf('onStorageReport?.call(');
        final lazyAt = source.indexOf('return LazyDatabase(');
        expect(reportAt, greaterThan(-1));
        expect(lazyAt, greaterThan(-1));
        expect(
          reportAt,
          lessThan(lazyAt),
          reason: 'native has nothing to probe, so it must already be in its '
              'final durable state on the very first frame',
        );
        expect(source, contains('StorageBackend.nativeFile'));
      });

      test('opens exactly the same database it always did', () {
        expect(
          _normalized(nativePath),
          contains(
            'return LazyDatabase(() async { '
            'final dir = await getApplicationDocumentsDirectory(); '
            "final file = File(p.join(dir.path, 'climbtopo.sqlite')); "
            'return NativeDatabase(file); });',
          ),
          reason: 'iOS/Android must stay bit-identical: same documents '
              'directory, same filename, same NativeDatabase, still lazy',
        );
      });
    });
  }

  ```

- [ ] **Step 2: Run the test and see the `moveExistingIndexedDbToOpfs` case fail (red). Every other case in this file already passes from task 2 — that is expected; this task's red test is the flag one.**
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/core/db/connection_seam_source_test.dart
  ```
  Expected: 1 test failed: 'passes moveExistingIndexedDbToOpfs: true' — Expected: contains 'moveExistingIndexedDbToOpfs: true'; 7 other tests pass (D-15 correction: the file contains 8 tests total, not 9, so 7 others pass, not 8).

- [ ] **Step 3: Add the flag to the `WasmDatabase.open` call in `lib/core/db/connection/connection_web.dart`, replacing the three-argument call inside `DatabaseConnection.delayed`.**
  ```dart
      final result = await WasmDatabase.open(
        databaseName: 'climbtopo',
        sqlite3Uri: Uri.parse('sqlite3.wasm'),
        driftWorkerUri: Uri.parse('drift_worker.js'),
        // L8 lock-in mitigation. Without this, `WasmDatabase.open`'s
        // `_selectExistingDatabase` downgrades the chosen implementation back
        // to whatever storage API an EXISTING `climbtopo` database already
        // lives in, on EVERY open — so any install that first landed on
        // IndexedDB (i.e. every visitor served before the COOP/COEP headers in
        // `web/_headers` shipped) stays on IndexedDB forever, even once the
        // browser would happily give us OPFS.
        //
        // Safe by drift's own construction: `moveFromIndexedDBToOpfs` COPIES
        // the IndexedDB files into OPFS and only then deletes the IndexedDB
        // originals, and drift wraps the whole move in a try/catch that falls
        // back to "keep using the old IndexedDB database" on any throw
        // (drift-2.34.2/lib/wasm.dart:184-199). The worst case is therefore
        // "no upgrade", never "no data". The browser assertion that seeded
        // rows actually survive it lives in
        // `integration_test/web_storage_backend_test.dart`; the OPFS half of
        // that (which needs cross-origin isolation, and so cannot happen under
        // `flutter drive -d web-server`) is proven on real Chrome via
        // `tool/serve_web_isolated.py`.
        moveExistingIndexedDbToOpfs: true,
      );
  ```

- [ ] **Step 4: Run the test again and see all cases pass (green).**
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/core/db/connection_seam_source_test.dart
  ```
  Expected: All tests passed. (8 tests) — corrected per D-15 (the file contains 8 tests, not 9)

- [ ] **Step 5: Confirm the whole-project gates and that the wasm build still compiles.**
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter analyze && flutter test && tool/build_web.sh
  ```
  Expected: No issues found! / `flutter test` green at baseline + 21 (7 + 6 + 8 so far) / build complete: build/web — D-13 correction, gate on green not on 1599

- [ ] **Step 6: Commit.**

**Assertions:**
- `flutter test test/core/db/connection_seam_source_test.dart` passes with 8 tests (D-15 correction: the file contains 8 tests, not 9).
- `lib/core/db/connection/connection_web.dart` contains `moveExistingIndexedDbToOpfs: true`.
- `lib/core/db/connection/connection_web.dart` contains `onStorageReport?.call(`, `_backendOf(result.chosenImplementation)` and `result.missingFeatures` — the verdict is surfaced, not discarded.
- `lib/core/db/connection/connection_web.dart` contains NO `kDebugMode`, and `Directory('lib')` recursively contains zero `.dart` files (excluding `.g.dart`) mentioning `kDebugMode` — down from exactly one before this work.
- All five `WasmStorageImplementation.X => StorageBackend.X,` pairs and all seven `MissingBrowserFeature.X => StorageMissingFeature.X,` pairs are present verbatim (whitespace-normalised).
- In `connection_native.dart`, the index of `onStorageReport?.call(` is strictly less than the index of `return LazyDatabase(` — native reports before returning.
- `connection_native.dart` still contains the exact executor expression `return LazyDatabase(() async { final dir = await getApplicationDocumentsDirectory(); final file = File(p.join(dir.path, 'climbtopo.sqlite')); return NativeDatabase(file); });` (whitespace-normalised) — native behaviour is provably unchanged.
- `flutter analyze` = 0 issues; `flutter test` is green at baseline + 21 (D-13 correction: never gate on the absolute number 1599); `tool/build_web.sh` completes.

**Commit message:** `feat(db): migrate IndexedDB-pinned web installs to OPFS and guard the web seam`

### Task 4: Disable topo creation behind an unmissable warning when storage is ephemeral

**Files:**
- Create: `lib/features/library/presentation/topos_storage_banner.dart`
- Modify: `lib/features/library/presentation/topos_screen.dart:11-14`, `lib/features/library/presentation/topos_screen.dart:39-43`, `lib/features/library/presentation/topos_screen.dart:135-146`, `lib/features/library/presentation/topos_screen.dart:219-229`, `lib/features/library/presentation/topos_screen.dart:424-428`, `test/features/library/presentation/topos_screen_test.dart:1-32`, `test/features/library/presentation/topos_screen_test.dart:104-142`, `test/features/library/presentation/topos_screen_test.dart:157-181`
- Test: `test/features/library/presentation/topos_screen_test.dart`

**Interfaces:**
- Produces: widget keys `'topos-storage-warning'` / `'topos-storage-warning-detail'`; the exact banner copy and log-line format documented under **Produces** above.
- Consumes: `ToposScreen`/`_ToposScreenState.build` (`topos_screen.dart`), `_EmptyState`/`topos-empty-new-topo` (`topos_empty_states.dart:18,29-37` — verified), `MasiColors`/`MasiSpacing`/`MasiRadii`/`TextTheme` (`app/theme.dart`), `MasiIcon` (`masi_icon.dart` — `'warning'` asset confirmed present at `assets/icons/masi/masi_warning.svg`), and the test harness `_makeContainer`/`_FakeSyncOrchestrator`/`_wrap`/`_drain`/`_dbWork` in `topos_screen_test.dart`.
- **Decision #7**: this task writes `_makeContainer`'s new `StorageDurability storageDurability = const StorageDurability.probing()` parameter. §1f's later task appends its own `PhotoFiles? photoFiles` parameter on top — the reconciled, union signature (in this exact order) is `_makeContainer({LocationService?, SyncOrchestrator?, StorageDurability storageDurability = const StorageDurability.probing(), PhotoFiles? photoFiles})`. **Ordering**: this task (§1a Task 4) must land before §1f's "Wire the Topos-home New topo flow" task — both touch `topos_screen.dart` and `topos_screen_test.dart`, so they cannot run in parallel.

- [ ] **Step 1: Add `import 'package:masi/core/db/storage_durability_provider.dart';` to the test file's import block (after `import 'package:masi/core/db/database_provider.dart';` at line 7).**

- [ ] **Step 2: Add the notifier double next to `_FakeSyncOrchestrator` (which ends at line 180 of the test file).**
  ```dart
  /// A [StorageDurabilityNotifier] double that just reports a fixed verdict —
  /// same shape as [_FakeSyncOrchestrator] above. Widget tests override
  /// `appDatabaseProvider` with an in-memory `NativeDatabase`, so the real
  /// notifier would never be fed by `openConnection()` at all and would sit at
  /// `StorageDurability.probing()` forever; this lets a test choose the verdict
  /// the create-topo interlock sees.
  class _FakeStorageDurability extends StorageDurabilityNotifier {
    _FakeStorageDurability(this._verdict);

    final StorageDurability _verdict;

    @override
    StorageDurability build() => _verdict;
  }
  ```

- [ ] **Step 3: Extend `_makeContainer` (test file lines 123-142) with a `storageDurability` param, ALWAYS overridden so every one of the file's existing tests deterministically sees `probing` (today's behaviour: no banner, creation enabled) and never touches the real `openConnection`. Append this paragraph to the existing doc comment, then replace the function.**
  ```dart
  /// [storageDurability] is the verdict the create-topo interlock sees (see
  /// `ToposScreen.build`'s `storage.isEphemeral` gate and
  /// `_StorageWarningBanner`). Defaults to `StorageDurability.probing()` — the
  /// "no verdict yet" state, which deliberately allows creation — so every
  /// pre-existing test in this file behaves exactly as it did before §1a. The
  /// override is unconditional so the REAL notifier (which would otherwise be
  /// fed by nothing, since `appDatabaseProvider` is overridden here) can never
  /// leak into a test.
  ProviderContainer _makeContainer({
    LocationService? locationService,
    SyncOrchestrator? syncOrchestrator,
    StorageDurability storageDurability = const StorageDurability.probing(),
  }) {
    final db = AppDatabase(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        nowMsProvider.overrideWithValue(() => 1000),
        if (locationService != null)
          locationServiceProvider.overrideWithValue(locationService),
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

- [ ] **Step 4: Add the failing interlock group to the test file (put it directly after the existing `#72: sync-error empty state` group, which ends at line 544).**
  ```dart
    group('§1a: storage-backend interlock (L1)', () {
      testWidgets(
        'an inMemory storage backend shows the topos-storage-warning banner '
        'and disables BOTH create affordances',
        (tester) async {
          final container = _makeContainer(
            storageDurability: const StorageDurability(
              backend: StorageBackend.inMemory,
              missingFeatures: {
                StorageMissingFeature.sharedArrayBuffers,
                StorageMissingFeature.indexedDb,
              },
            ),
          );

          await tester.pumpWidget(_wrap(container, const ToposScreen()));
          await _drain(tester);

          expect(
            find.byKey(const Key('topos-storage-warning')),
            findsOneWidget,
            reason: 'an inMemory drift backend loses everything on reload — the '
                'warning has to be on screen, not in a console nobody reads',
          );
          expect(
            find.text("This browser can't save your topos"),
            findsOneWidget,
          );

          expect(
            tester
                .widget<ElevatedButton>(find.byKey(const Key('topos-new-topo')))
                .onPressed,
            isNull,
            reason: 'topos-new-topo must be disabled on a non-durable backend',
          );
          expect(
            tester
                .widget<ElevatedButton>(
                  find.byKey(const Key('topos-empty-new-topo')),
                )
                .onPressed,
            isNull,
            reason: "the empty state's inline button runs the SAME "
                '_handleNewTopo flow and must be disabled too',
          );
        },
      );

      testWidgets(
        'the banner names the backend and the missing browser features, so a '
        'screenshot alone answers a "my data vanished" report',
        (tester) async {
          final container = _makeContainer(
            storageDurability: const StorageDurability(
              backend: StorageBackend.inMemory,
              missingFeatures: {StorageMissingFeature.sharedArrayBuffers},
            ),
          );

          await tester.pumpWidget(_wrap(container, const ToposScreen()));
          await _drain(tester);

          final detail = tester.widget<Text>(
            find.byKey(const Key('topos-storage-warning-detail')),
          );
          expect(detail.data, contains('inMemory'));
          expect(detail.data, contains('sharedArrayBuffers'));
        },
      );

      testWidgets(
        'a durable backend renders no banner and leaves creation enabled',
        (tester) async {
          final container = _makeContainer(
            storageDurability: const StorageDurability(
              backend: StorageBackend.opfsLocks,
            ),
          );

          await tester.pumpWidget(_wrap(container, const ToposScreen()));
          await _drain(tester);

          expect(find.byKey(const Key('topos-storage-warning')), findsNothing);
          expect(
            tester
                .widget<ElevatedButton>(find.byKey(const Key('topos-new-topo')))
                .onPressed,
            isNotNull,
          );
        },
      );

      testWidgets(
        'the still-probing default (web, the first few hundred ms of boot) is '
        'NOT treated as non-durable — no banner, creation enabled',
        (tester) async {
          final container = _makeContainer();

          await tester.pumpWidget(_wrap(container, const ToposScreen()));
          await _drain(tester);

          expect(find.byKey(const Key('topos-storage-warning')), findsNothing);
          expect(
            tester
                .widget<ElevatedButton>(find.byKey(const Key('topos-new-topo')))
                .onPressed,
            isNotNull,
          );
        },
      );

      testWidgets(
        'tapping the disabled create button on an inMemory backend creates '
        'nothing — the photo picker is never even opened',
        (tester) async {
          var pickerOpened = 0;
          final container = _makeContainer(
            storageDurability: const StorageDurability(
              backend: StorageBackend.inMemory,
            ),
          );

          await tester.pumpWidget(
            _wrap(
              container,
              ToposScreen(
                photoSourcePicker: (context) async {
                  pickerOpened++;
                  return ImageSource.gallery;
                },
                photoPicker: (source) async => null,
              ),
            ),
          );
          await _drain(tester);

          await tester.tap(find.byKey(const Key('topos-new-topo')));
          await _drain(tester);

          expect(pickerOpened, 0);
          final topos = await _dbWork(
            tester,
            () => container.read(libraryCrudRepositoryProvider).watchTopos().first,
          );
          expect(topos, isEmpty);
        },
      );
    });
  ```

- [ ] **Step 5: Run the group and see it fail (red).**
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/library/presentation/topos_screen_test.dart --plain-name "§1a: storage-backend interlock"
  ```
  Expected: Compile error: undefined name 'storageDurabilityProvider' / 'StorageDurabilityNotifier' — then, once the test-side wiring exists, failures on `topos-storage-warning` findsNothing and `onPressed` isNotNull.

- [ ] **Step 6: Create the banner part file.**
  ```dart
  // lib/features/library/presentation/topos_storage_banner.dart
  part of 'topos_screen.dart';

  /// Unmissable, non-dismissible warning pinned to the very top of the Topos
  /// home whenever the connection layer reported a storage backend that cannot
  /// keep data across a page load ([StorageDurability.isEphemeral] — in
  /// practice [StorageBackend.inMemory], which drift documents as "doesn't
  /// store anything").
  ///
  /// This is the visible half of the L1 interlock (design doc
  /// `docs/superpowers/specs/2026-07-30-web-offline-reliability-design.md`
  /// §1a). The invisible half is `canCreate` in [ToposScreen.build] plus the
  /// third guard in `_handleNewTopo`, which together disable BOTH create
  /// affordances (`topos-new-topo` and the empty state's
  /// `topos-empty-new-topo`) so nothing can be written into a store that will
  /// drop it.
  ///
  /// Deliberately NOT dismissible and deliberately NOT a [SnackBar]: the
  /// condition is permanent for the lifetime of the page, and a transient toast
  /// is exactly how the old `kDebugMode`-only `debugPrint` managed to hide
  /// TOTAL data loss in production. Rendered above `_ToposFilterBar` rather
  /// than inside an empty state so it is present in every list state, not just
  /// the empty one.
  ///
  /// The quieter third line names the backend and the missing browser features
  /// verbatim so a "my data vanished" report is answerable from a screenshot
  /// alone — the same values the release log line (`masi/storage: …`) carries.
  class _StorageWarningBanner extends StatelessWidget {
    const _StorageWarningBanner({required this.durability});

    final StorageDurability durability;

    @override
    Widget build(BuildContext context) {
      final colors = MasiColors.of(context);
      final textTheme = Theme.of(context).textTheme;
      final missing = durability.missingFeatures.map((f) => f.name).toList()
        ..sort();

      return Container(
        key: const Key('topos-storage-warning'),
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(
          MasiSpacing.lg,
          MasiSpacing.md,
          MasiSpacing.lg,
          0,
        ),
        padding: const EdgeInsets.all(MasiSpacing.md),
        decoration: BoxDecoration(
          color: colors.gradeHard.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(MasiRadii.card),
          border: Border.all(color: colors.gradeHard),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            MasiIcon('warning', size: 22, color: colors.gradeHard),
            const SizedBox(width: MasiSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "This browser can't save your topos",
                    style: textTheme.titleMedium?.copyWith(
                      color: colors.ink,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: MasiSpacing.xs),
                  Text(
                    'Storage is blocked here, so anything you create would be '
                    'lost the moment this page reloads. Creating topos is '
                    'turned off until storage works. Private browsing and '
                    'blocked site data are the usual causes — try a normal '
                    'window, or install the app to your home screen.',
                    style: textTheme.bodyMedium?.copyWith(color: colors.ink2),
                  ),
                  const SizedBox(height: MasiSpacing.sm),
                  Text(
                    'Storage: ${durability.backend?.name ?? 'unknown'}'
                    '${missing.isEmpty ? '' : ' · missing: ${missing.join(', ')}'}',
                    key: const Key('topos-storage-warning-detail'),
                    style: textTheme.labelSmall?.copyWith(color: colors.ink3),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
  }

  ```

- [ ] **Step 7: Add the storage-durability import to `topos_screen.dart`. Insert immediately after `import '../../../app/theme.dart';` (line 11), keeping the existing `core/...` cluster order (`core/db` sorts before `core/grades`).**
  ```dart
  import '../../../core/db/storage_durability_provider.dart';
  ```

- [ ] **Step 8: Register the new part file in `topos_screen.dart` — append after `part 'topos_dialogs.dart';` (line 43).**
  ```dart
  part 'topos_storage_banner.dart';
  ```

- [ ] **Step 9: Watch the provider and fold it into `canCreate`. In `ToposScreen.build`, insert the `storage` read after `final filter = ref.watch(toposFilterProvider);` (line 139) and replace `canCreate` (line 146).**
  ```dart
      // L1 interlock (design doc §1a): the connection layer's verdict on
      // whether the local database can actually keep what we write. On web,
      // `WasmDatabase.open` silently degrades to an in-memory backend that
      // "doesn't store anything" — writes succeed, lists populate, and the
      // whole library is gone on the next page load. When that is the verdict,
      // creation is turned OFF and `_StorageWarningBanner` says so, rather than
      // letting the user record a topo into a store that will drop it. See
      // `lib/core/db/storage_durability_provider.dart`.
      final storage = ref.watch(storageDurabilityProvider);

      // Only an *actually loaded* topo list (AsyncData) is a safe source for
      // the "New topo" count; while still loading or errored there is no
      // trustworthy count to derive "Topo N+1" from, so the button must be
      // disabled rather than fall back to an empty list and mint "Topo 1"
      // over an existing topo. `storage.isEphemeral` is the third gate: it is
      // false while the verdict is still unknown (`probing`), so the interlock
      // only ever blocks on a KNOWN-bad backend.
      final loadedTopos = asyncTopos.asData?.value;
      final canCreate =
          loadedTopos != null && !_creating && !storage.isEphemeral;
  ```

- [ ] **Step 10: Render the banner. Inside `body: Stack(children: [ SafeArea(bottom: false, child: Column(children: [ ... ])`, insert it as the FIRST child of that `Column`, immediately before `_ToposFilterBar(` (line 225).**
  ```dart
                  if (storage.isEphemeral)
                    _StorageWarningBanner(durability: storage),
  ```

- [ ] **Step 11: Add the third defensive guard to `_handleNewTopo`, immediately after `if (ref.read(toposProvider).asData == null) return;` (line 426).**
  ```dart
      // Belt-and-braces, same shape as the two guards above: both buttons that
      // reach this method are already disabled while the storage backend is
      // known non-durable, so this only fires for a programmatic call — but a
      // creation flow that writes into a store drift told us discards
      // everything must be impossible, not merely hard to trigger.
      if (ref.read(storageDurabilityProvider).isEphemeral) return;
  ```

- [ ] **Step 12: Run the group and see it pass (green).**
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/features/library/presentation/topos_screen_test.dart
  ```
  Expected: All tests passed. — the whole file, including the 5 new interlock tests and every pre-existing test (which now run with an explicit `probing` verdict).

- [ ] **Step 13: Confirm the whole-project gates.**
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter analyze && flutter test
  ```
  Expected: No issues found! and `flutter test` green at baseline + 26 (7 + 6 + 8 + 5 across Tasks 1-4) — D-13 correction, gate on green not on 1604

- [ ] **Step 14: See the banner on a real screen. Boot the iPhone 17 simulator, then drive the existing Topos-home flow — the banner must NOT appear on native (nativeFile is durable), which is the visual half of "native behaviour is unchanged".**
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && xcrun simctl boot C8D8B6F4-1D77-46EF-80BA-2CBD746AC69C; open -a Simulator; flutter drive --driver=test_driver/integration_test.dart --target=integration_test/topos_home_test.dart -d C8D8B6F4-1D77-46EF-80BA-2CBD746AC69C
  ```
  Expected: drive passes; screenshots land in build/screenshots/ — read each PNG and confirm no storage warning is rendered.

- [ ] **Step 15: Commit.**

**Assertions:**
- `flutter test test/features/library/presentation/topos_screen_test.dart` passes in full — 5 new interlock tests plus every pre-existing test in the file, unmodified in behaviour.
- With `StorageDurability(backend: StorageBackend.inMemory)`: `find.byKey(const Key('topos-storage-warning'))` findsOneWidget, `find.text("This browser can't save your topos")` findsOneWidget, and BOTH `topos-new-topo` and `topos-empty-new-topo` have `onPressed == null`.
- The `topos-storage-warning-detail` Text contains the backend name (`inMemory`) and every missing-feature name (`sharedArrayBuffers`).
- With `StorageDurability(backend: StorageBackend.opfsLocks)`: no `topos-storage-warning` widget, and `topos-new-topo.onPressed` is non-null.
- With the default `StorageDurability.probing()`: no banner and creation enabled — a not-yet-known verdict never blocks (this is also the regression guard for the other ~1576 tests).
- Tapping `topos-new-topo` while the backend is `inMemory` opens the photo-source picker ZERO times and leaves `watchTopos()` empty.
- `flutter analyze` = 0 issues; `flutter test` is green at baseline + 26 (D-13 correction: never gate on the absolute number 1604).
- On the iOS simulator the Topos home renders with NO storage warning — native reports `nativeFile`, which is durable.

**Commit message:** `feat(topos): disable topo creation behind a storage warning when the backend can't persist`

### Task 5: Prove it in a real browser: storage verdict + the IndexedDB→OPFS move

**Files:**
- Create: `integration_test/web_storage_backend_test.dart`, `tool/serve_web_isolated.py`
- Test: `integration_test/web_storage_backend_test.dart`

**Interfaces:**
- Produces: the only executable proof that `connection_web.dart`'s `package:drift/wasm.dart` path behaves correctly in a real browser (this file cannot be compiled by the Dart VM, so `flutter test` never reaches it).
- Consumes: `WasmDatabase.open`/`WasmDatabase.probe`, `WasmProbeResult`, `WebStorageApi`, `AreasCompanion.insert`, `AppDatabase`, and Task 2/3's `openConnection(onStorageReport:)` + `moveExistingIndexedDbToOpfs: true`.
- **D-24**: the first test case below opens the real, production-named `climbtopo` database in headless Chrome's throwaway origin — it is **not hermetic**. The second case is hermetic: it uses the test-only database name `masi_move_probe`, which can never collide with a real user's `climbtopo` database.

- [ ] **Step 1: Confirm chromedriver is present and matches the installed Chrome major version (the drive harness needs it).**
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && chromedriver --version && "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --version
  ```
  Expected: ChromeDriver 150.x and Google Chrome 150.x (majors must match)

- [ ] **Step 2: Write the browser test. This is the ONLY place `connection_web.dart` and `package:drift/wasm.dart` actually execute.**
  ```dart
  // integration_test/web_storage_backend_test.dart
  //
  // Browser-executed assertions for design-doc §1a. Driven headless via
  //   tool/drive_web.sh integration_test/web_storage_backend_test.dart
  // (NOT run by `flutter test` — `package:drift/wasm.dart` imports
  // `dart:js_interop`, so the Dart VM cannot compile any of this).
  //
  // Two things are proven here:
  //
  //  1. The REAL `openConnection()` — the same one `appDatabaseProvider` uses —
  //     resolves to a durable backend in a real browser, never drift's silent
  //     `inMemory` fallback (L1). Before §1a there was no way to observe this
  //     at all: the verdict was discarded behind `if (kDebugMode)`.
  //
  //  2. `moveExistingIndexedDbToOpfs: true` is SAFE. A drift database is
  //     deliberately created on IndexedDB (the storage every pre-COOP/COEP
  //     install is pinned to by `_selectExistingDatabase`), seeded with a known
  //     row, closed, then reopened with the flag on. The row must still be
  //     there — moved to OPFS where OPFS is available, left in IndexedDB where
  //     it is not. Either way: nothing lost.
  //
  // IMPORTANT HARNESS LIMIT: `flutter drive` has no `--web-header` flag, so the
  // `-d web-server` device cannot send COOP/COEP. Without cross-origin
  // isolation there is no SharedArrayBuffer, so drift's probe never offers
  // `opfsLocks` (drift wasm_setup.dart:124-131 requires
  // `supportsSharedArrayBuffers`), and `opfsShared` needs nested workers which
  // only Firefox implements. In THIS harness the test therefore exercises the
  // "no OPFS available -> flag is a no-op, data intact" branch, which is
  // exactly the regression that would silently drop a user's library. The OPFS
  // branch is proven on real Chrome via `tool/serve_web_isolated.py` (see that
  // file's header) before this ships.
  import 'package:drift/drift.dart';
  import 'package:drift/wasm.dart';
  import 'package:flutter_test/flutter_test.dart';
  import 'package:integration_test/integration_test.dart';
  import 'package:masi/core/db/app_database.dart';
  import 'package:masi/core/db/connection/connection.dart';

  void main() {
    IntegrationTestWidgetsFlutterBinding.ensureInitialized();

    testWidgets(
      'the real openConnection() resolves to a DURABLE backend, never inMemory',
      (tester) async {
        final verdicts = <StorageDurability>[];
        final db = AppDatabase(openConnection(onStorageReport: verdicts.add));
        addTearDown(db.close);

        // Force the delayed connection to actually resolve (and drift to run
        // its migration) — the verdict is reported inside the same future the
        // executor awaits, so it has necessarily landed by the time this
        // returns.
        await db.customSelect('SELECT 1').get();

        expect(verdicts, hasLength(1));
        final verdict = verdicts.single;
        expect(
          verdict.backend,
          isNot(StorageBackend.inMemory),
          reason: 'drift fell back to inMemory, which stores NOTHING — this is '
              'L1 happening for real. missingFeatures: '
              '${verdict.missingFeatures}',
        );
        expect(verdict.isDurable, isTrue);
        expect(verdict.isEphemeral, isFalse);
      },
    );

    testWidgets(
      'moveExistingIndexedDbToOpfs: an existing IndexedDB database survives a '
      'reopen with the flag on — no rows lost, whether or not OPFS is available',
      (tester) async {
        // A test-only database name: this must never be able to touch the real
        // `climbtopo` database.
        const name = 'masi_move_probe';
        final sqlite3Uri = Uri.parse('sqlite3.wasm');
        final driftWorkerUri = Uri.parse('drift_worker.js');

        final probe = await WasmDatabase.probe(
          sqlite3Uri: sqlite3Uri,
          driftWorkerUri: driftWorkerUri,
          databaseName: name,
        );
        final indexedDbImplementations = probe.availableStorages
            .where((i) => i.storageApi == WebStorageApi.indexedDb)
            .toList();
        expect(
          indexedDbImplementations,
          isNotEmpty,
          reason: 'this browser cannot host the IndexedDB half of this test; '
              'available: ${probe.availableStorages}, missing: '
              '${probe.missingFeatures}',
        );

        // Seed the database ON INDEXEDDB, which is where every install served
        // before COOP/COEP shipped still lives.
        final seedConnection = await probe.open(
          indexedDbImplementations.first,
          name,
        );
        final seedDb = AppDatabase(seedConnection);
        await seedDb.into(seedDb.areas).insert(
              AreasCompanion.insert(
                id: 'move-probe-area',
                name: 'Move probe',
                createdAt: 1,
                updatedAt: 1,
              ),
            );
        await seedDb.close();

        // Reopen exactly the way `connection_web.dart` does.
        final reopened = await WasmDatabase.open(
          databaseName: name,
          sqlite3Uri: sqlite3Uri,
          driftWorkerUri: driftWorkerUri,
          moveExistingIndexedDbToOpfs: true,
        );
        final movedDb = AppDatabase(reopened.resolvedExecutor);
        addTearDown(movedDb.close);

        final areas = await movedDb.select(movedDb.areas).get();
        expect(
          areas.map((a) => a.id),
          contains('move-probe-area'),
          reason: 'THE assertion that makes moveExistingIndexedDbToOpfs safe to '
              'ship: the row seeded in IndexedDB must survive the reopen. '
              'chosenImplementation: ${reopened.chosenImplementation}',
        );
        expect(
          reopened.chosenImplementation,
          isNot(WasmStorageImplementation.inMemory),
        );

        final opfsAvailable = probe.availableStorages.any(
          (i) => i.storageApi == WebStorageApi.opfs,
        );
        if (opfsAvailable) {
          expect(
            reopened.chosenImplementation.storageApi,
            WebStorageApi.opfs,
            reason: 'with OPFS available, the flag must actually migrate the '
                'database up instead of staying pinned to IndexedDB (L8)',
          );
        } else {
          expect(
            reopened.chosenImplementation.storageApi,
            WebStorageApi.indexedDb,
            reason: 'with no OPFS available the flag must be a pure no-op that '
                'leaves the existing IndexedDB database exactly where it is',
          );
        }
      },
    );
  }

  ```

- [ ] **Step 3: Run it in headless Chrome and see both tests pass.**
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && tool/drive_web.sh integration_test/web_storage_backend_test.dart
  ```
  Expected: flutter drive PASSED. Note the reported backend in the console output — headless Chrome without COOP/COEP is expected to resolve to sharedIndexedDb, NOT inMemory.

- [ ] **Step 4: Write the cross-origin-isolated static server, the only way to exercise the real OPFS move on Chrome.**
  ```python
  #!/usr/bin/env python3
  """Static server for build/web that applies (or deliberately omits) the
  cross-origin-isolation headers Cloudflare Pages sets from `web/_headers`.

  Why this exists: `flutter drive` has no `--web-header` flag, so the
  `-d web-server` device used by `tool/drive_web.sh` can never send COOP/COEP.
  Without cross-origin isolation there is no SharedArrayBuffer, drift's probe
  never offers `opfsLocks`, and the OPFS half of §1a's
  `moveExistingIndexedDbToOpfs: true` is unreachable in CI. This script is how
  that half gets proven on real Chrome before shipping.

  Proving the move (run all of it from the repo root):

    tool/build_web.sh
    # 1. Serve WITHOUT isolation so drift lands on IndexedDB, then seed a topo.
    python3 tool/serve_web_isolated.py 8087 --no-coop
    #    open http://localhost:8087 in Chrome, sign in, create a topo,
    #    and confirm the console logs `masi/storage: backend=...IndexedDb`.
    #    Stop the server (ctrl-C).
    # 2. Serve WITH isolation on the SAME PORT (same origin == same stored
    #    databases; a different port is a different origin and proves nothing).
    python3 tool/serve_web_isolated.py 8087
    #    reload http://localhost:8087. Expected:
    #      - DevTools console: `masi/storage: backend=opfsLocks durable=true`
    #      - `crossOriginIsolated` is true in the console
    #      - the topo seeded in step 1 is STILL THERE
    #      - Application > Storage shows the IndexedDB `climbtopo` database gone
    #    That is the IndexedDB -> OPFS migration completing without data loss.
  """
  import functools
  import http.server
  import mimetypes
  import os
  import sys

  # Chrome refuses `WebAssembly.instantiateStreaming` on anything that is not
  # application/wasm, and Python's mimetypes does not always know .wasm.
  mimetypes.add_type("application/wasm", ".wasm")
  mimetypes.add_type("application/javascript", ".js")


  class Handler(http.server.SimpleHTTPRequestHandler):
      isolated = True

      def end_headers(self):
          if self.isolated:
              # Mirrors web/_headers' `/*` block.
              self.send_header("Cross-Origin-Opener-Policy", "same-origin")
              self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
              self.send_header("Cross-Origin-Resource-Policy", "same-origin")
          self.send_header("Cache-Control", "no-cache")
          super().end_headers()


  def main() -> int:
      args = sys.argv[1:]
      isolated = "--no-coop" not in args
      ports = [a for a in args if a.isdigit()]
      port = int(ports[0]) if ports else 8087
      root = os.path.normpath(
          os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "build", "web")
      )
      if not os.path.isdir(root):
          print("FAIL: build/web not found — run tool/build_web.sh first", file=sys.stderr)
          return 2
      Handler.isolated = isolated
      handler = functools.partial(Handler, directory=root)
      print(
          f"serving {root} on http://localhost:{port} "
          f"(cross-origin isolated: {isolated})"
      )
      http.server.ThreadingHTTPServer(("127.0.0.1", port), handler).serve_forever()
      return 0


  if __name__ == "__main__":
      sys.exit(main())

  ```

- [ ] **Step 5: Make it executable and build the web bundle.**
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && chmod +x tool/serve_web_isolated.py && tool/build_web.sh
  ```
  Expected: build complete: build/web

- [ ] **Step 6: Run the NON-isolated pass so drift lands on IndexedDB, and seed a topo. Serve it, then drive Chrome by hand (this step needs a human/Chrome DevTools; it is the pre-ship gate the design doc requires for the flag).**
  ```bash
  cd /Users/kerip/Projects/masi && python3 tool/serve_web_isolated.py 8087 --no-coop
  ```
  Expected: Open http://localhost:8087 in Chrome. DevTools console shows `masi/storage: backend=sharedIndexedDb durable=true missingFeatures=sharedArrayBuffers`; `crossOriginIsolated` is false; create one topo; Application > IndexedDB shows a `climbtopo` database. Stop the server.

- [ ] **Step 7: Run the ISOLATED pass on the SAME port and confirm the migration happened with the topo intact.**
  ```bash
  cd /Users/kerip/Projects/masi && python3 tool/serve_web_isolated.py 8087
  ```
  Expected: Reload http://localhost:8087. `crossOriginIsolated === true`; console shows `masi/storage: backend=opfsLocks durable=true missingFeatures=`; the topo from the previous step is still listed; the `climbtopo` IndexedDB database is gone from Application > Storage. No `topos-storage-warning` banner in either pass.

- [ ] **Step 8: Confirm nothing regressed and the existing web smoke flows still boot with the new provider in the tree.**
  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter analyze && flutter test && tool/drive_web.sh integration_test/web_smoke_test.dart && tool/drive_web.sh integration_test/web_boot_stability_test.dart
  ```
  Expected: No issues found! / `flutter test` green at baseline + 26 (Task 5's 2 browser tests run via `tool/drive_web.sh`, outside the `flutter test` count) / both drives PASSED — D-13 correction, gate on green not on 1604

- [ ] **Step 9: Commit.**

**Assertions:**
- `tool/drive_web.sh integration_test/web_storage_backend_test.dart` passes both tests in headless Chrome.
- In a real browser the REAL `openConnection()` reports exactly ONE verdict, and that verdict's backend is NOT `StorageBackend.inMemory` and `isDurable` is true.
- A drift database seeded on IndexedDB and reopened with `moveExistingIndexedDbToOpfs: true` still returns the seeded `move-probe-area` row — this is the test that makes the flag safe to ship.
- In the same reopen, `chosenImplementation` is never `inMemory`; its `storageApi` is `opfs` when the probe offered an OPFS implementation and `indexedDb` when it did not (so the flag is proven to be a lossless no-op in the non-isolated case CI can reach).
- `tool/serve_web_isolated.py 8087 --no-coop` then `tool/serve_web_isolated.py 8087` on real Chrome: the first pass logs an IndexedDB backend and `crossOriginIsolated === false`; the second logs `backend=opfsLocks durable=true` with `crossOriginIsolated === true`, the topo created in the first pass is still present, and the `climbtopo` IndexedDB database is gone — the OPFS migration completed without data loss.
- `masi/storage: …` appears in the browser console of a RELEASE wasm build (`tool/build_web.sh` produces a release build), proving the log is not compiled out.
- `tool/drive_web.sh integration_test/web_smoke_test.dart` and `integration_test/web_boot_stability_test.dart` both still pass.
- `flutter analyze` = 0 issues; `flutter test` is green at baseline + 26 (D-13 correction: never gate on the absolute number 1604).

**Commit message:** `test(web): browser proof for the storage verdict and the IndexedDB to OPFS move`

## Risks

- **Riverpod's mid-build mutation assert is a real trap here, and I confirmed it in the package source.** `riverpod-3.3.2/lib/src/core/element.dart:795-803` asserts `Providers are not allowed to modify other providers during their initialization.` Because `connection_native.dart` reports SYNCHRONOUSLY, wiring `openConnection(onStorageReport: storage.report)` directly (no microtask) would trip that assert on every native/widget-test read of `appDatabaseProvider` — i.e. it would break a large fraction of the 1576-test suite. The `Future<void>.microtask(...)` wrapper in `appDatabaseProvider` is load-bearing, and task 2's last test exists solely to lock it in. Do not 'simplify' it away.
- **The OPFS half of `moveExistingIndexedDbToOpfs: true` cannot be proven in CI.** `flutter drive --help` has no `--web-header` flag (verified), so `-d web-server` cannot send COOP/COEP; without cross-origin isolation there is no SharedArrayBuffer, so drift's probe never offers `opfsLocks` (`drift/src/web/wasm_setup.dart:124-131`), and `opfsShared` needs nested-workers-in-shared-workers which only Firefox implements (and geckodriver is NOT installed on this machine). The browser test therefore proves the *lossless no-op* branch; the actual migration is proven manually on Chrome via `tool/serve_web_isolated.py`. Do not ship the flag on the CI test alone — the design doc explicitly gates it on a browser migration proof.
- **The move is one-way and destructive by design.** `WasmDatabase.open` calls `probed.moveFromIndexedDBToOpfs(databaseName)`, which drift documents as 'unconditionally copies files stored in IndexedDB to OPFS, and then deletes the old IndexedDB database'. Drift wraps it in a try/catch that falls back to the old database on any throw (`wasm.dart:184-199`), so the failure mode is 'no upgrade'. But a copy that *succeeds* while being subtly wrong would be unrecoverable. This is exactly why the manual Chrome proof (seed → migrate → verify the topo is still there) is a hard gate, not a nice-to-have.
- **`unsafeIndexedDb` is deliberately classified as durable.** It persists; drift only warns it cannot prevent cross-tab races. L8's race half is explicitly out of scope per the design doc, so a user on `unsafeIndexedDb` gets no banner and full creation. If that judgement is wrong, the single line to change is `StorageBackend.isDurable`.
- **The interlock covers the Topos home only.** `/areas` → `CrudListScaffold`'s `area-add-fab` / `sector-add-fab` / `wall-add-fab` (`crud_list_scaffold.dart:157`) stay enabled on an ephemeral backend, as do the canvas's draw/route flows. That matches §1a's wording ('block topo creation') and keeps this workstream write-disjoint from four other screens, but it IS an inconsistency: a user on an inMemory backend can still create an Area that will vanish. Recommend a follow-up that threads a `disabledReason` through `CrudListScaffold` once §1a lands.
- **`probing` allows creation.** On web there is a window (as long as `WasmDatabase.open`'s worker probe takes, typically tens to a few hundred ms from the first `appDatabaseProvider` read, which happens during boot) where the verdict is unknown and creation is enabled. Blocking on `probing` instead would (a) require creation to be disabled for a visible moment on every web boot and (b) disable creation in every widget test, since they all override `appDatabaseProvider` and so never run `openConnection`. The chosen trade-off is documented on `StorageDurability.probing`, and a test pins it.
- **The mapping from drift's enum to `StorageBackend` is guarded by `flutter analyze` (exhaustiveness) plus a source-scan test (value-for-value), not by an executable test** — `connection_web.dart` cannot be compiled by the Dart VM at all. A `dart format` change that reflows those switch arms is handled (the test normalises whitespace), but a *rename* of a masi enum value requires updating `test/core/db/connection_seam_source_test.dart` in the same commit.
- **`debugPrint` now fires unconditionally on every app start.** One line per app run, so throughput is a non-issue, but the release web console will always carry `masi/storage: …`. That is the intended, deliberate outcome (it is the only artefact that can answer open question #1 in the design doc, 'what backend does live climb-masi.pages.dev actually resolve to?'). It also means the very first thing to check after Stage 1 deploys is that console line on iOS Safari tab + installed PWA, Chrome/Android and desktop Chrome.
- **Test-count arithmetic in the assertions assumes nothing else lands concurrently (D-13 correction applied throughout this document).** The verified baseline is 1576; this workstream adds **7 + 6 + 8 + 5 = 26** new `flutter test` cases (corrected per D-15 — the fragment's original 8+6+9+5=28 over-counted Tasks 1 and 3 by one test each), ending at baseline + 26. Task 5's 2 browser tests run via `tool/drive_web.sh`, outside the `flutter test` count. Regardless of another workstream landing first, gate on `flutter test` being green — never on an absolute total.
- **Spec drift found while verifying line refs — report back to the design doc:** (1) The Testing section and §'Cross-origin isolation' claim `.github/workflows/ci.yml` uses 'a *different, naive* substring gate (`grep -rl 'dart:io' lib`)'. That is **stale**: `ci.yml:44-52` already uses the directive-anchored regex `grep -rlE "^[[:space:]]*(import|export)[[:space:]]+['\"]dart:io['\"]" lib --include="*.dart" | grep -v '_native.dart'`, byte-identical to `tool/build_web.sh:41`, and the workflow header comments even say so. The 'reconcile the two divergent grep gates' task in the Testing section is already done. (2) Everything else I checked matches the audit exactly: `connection_web.dart:15` `databaseName: 'climbtopo'`, `:19-25` the `kDebugMode` block, `:22` `chosenImplementation`, `:26` `result.resolvedExecutor`; `app_database.dart:31` `schemaVersion => 8`; `database_provider.dart:24` `nowMsProvider`; `crud_list_scaffold.dart:157` the add-FAB key; `topos_empty_states.dart` keys `topos-empty-state`/`topos-sync-error-empty`. (3) `grep -rn kDebugMode lib` returns exactly ONE hit repo-wide — `connection_web.dart:19` — which corroborates the audit's 'the only signal is a debugPrint behind if (kDebugMode)'.

## Sequencing notes

**Files this workstream WRITES (nothing else may touch these in parallel):** `lib/core/db/connection/{connection,connection_web,connection_native,connection_stub,storage_durability}.dart`, `lib/core/db/storage_durability_provider.dart`, `lib/core/db/database_provider.dart`, `lib/features/library/presentation/{topos_screen,topos_storage_banner}.dart`, `test/core/db/{storage_durability,storage_durability_provider,connection_seam_source}_test.dart`, `test/features/library/presentation/topos_screen_test.dart`, `integration_test/web_storage_backend_test.dart`, `tool/serve_web_isolated.py`.

**Hard conflicts — must NOT run in parallel with §1a:**

- **§1b (persistent storage / `navigator.storage.persist()`).** Highest-risk overlap. It is web-only behind the conditional-import convention and will very likely want to (a) live in or next to `lib/core/db/connection/`, (b) record its outcome on the same kind of provider, and (c) be wired from boot. It should be sequenced **after** §1a. ~~It should *extend* `StorageDurability`/`storageDurabilityProvider` (adding e.g. `persistGranted`, `usageBytes`, `quotaBytes`) rather than inventing a second provider — §2c's diagnostics row is specified to read one provider, not three.~~ **Decision #16 (rejected during reconciliation): keep `storageDurabilityProvider` and §1b's own `storagePersistenceProvider` as two separate providers** — different lifecycles (async drift-fed connection verdict vs. one-shot boot-time permission), and merging them would create a write-write dependency between two otherwise disjoint workstreams for no Stage-1 benefit. §2c composes two `ref.watch`es instead. Do **not** act on the struck-through demand above. If §1b must start early, it should own a genuinely separate file (`lib/core/db/persistent_storage*.dart`) and touch neither `database_provider.dart` nor `connection_*.dart`.
- **§2c (runtime diagnostics row).** Consumes `storageDurabilityProvider` verbatim; it is a strict downstream reader. Sequence after §1a and after §1b so it reads one settled shape.
- **§2b's L7 `from > to` migration guard.** Modifies `lib/core/db/app_database.dart` — which §1a does *not* touch — but its 'browser-executed migrations against a real `WasmDatabase`' test will want to live beside `integration_test/web_storage_backend_test.dart` and will reuse the same `WasmDatabase.probe(...)` + test-only-database-name pattern established here. Sequence after §1a and copy that harness rather than re-deriving it.

**Safe to run fully in parallel (write-disjoint):**

- **§1d (sync tells the truth)** — `lib/features/backup/data/sync_remote.dart`, `sync_service.dart`, `application/sync_orchestrator.dart`, `lib/features/account/presentation/account_screen.dart`.
- **§1e (retry/backoff/connectivity)** — `lib/features/backup/**`, `lib/core/db/tables.dart` (the `dirty` column), `lib/app/app.dart`.
- **§1f (photo integrity)** — `lib/features/topo/data/photo_files_web.dart`, `photo_byte_store.dart`, `lib/features/library/data/library_crud_repository.dart`, `sync_remote.dart`.
- **§2a (`--no-web-resources-cdn`)** — `tool/build_web.sh` only. §1a adds a *new* file under `tool/` and never edits `build_web.sh`.

**Borderline — coordinate, do not assume disjoint:**

- **§1c point 2 ('`toposProvider` reads uid through the synchronous door').** That change lands in `lib/features/library/application/library_providers.dart:66-67`, which §1a does not touch — but if the implementer also adjusts `topos_screen.dart` or adds to `test/features/library/presentation/topos_screen_test.dart`, it collides head-on with task 4. Per the repo rule that parallel implementers must be strictly write-disjoint at the FILE level, either §1c is told to stay out of both of those files, or §1a task 4 runs first.
- **Stage 3's 'offline variant' of the sync-error empty states** touches `lib/features/library/presentation/topos_empty_states.dart`. §1a deliberately puts the banner in a NEW part file (`topos_storage_banner.dart`) instead of extending `topos_empty_states.dart` precisely to keep that seam free — but both add a `part` directive to `topos_screen.dart:39-43`, so they cannot run concurrently.

**Internal ordering is strict:** task 1 → 2 → 3 → 4 → 5. Task 2 changes the seam signature that task 3's guard test asserts; task 3's flag is what task 5's browser test proves; task 4 depends on the provider from task 2.

