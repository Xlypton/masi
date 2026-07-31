# §1b — Persistent Storage (`navigator.storage` seam)

> §1b Persistent storage (mitigates L2) — a `navigator.storage` conditional-export seam, a one-shot boot request, and a Riverpod v3 provider exposing the result for §2c diagnostics

## Reconciliation corrections applied

This fragment was checked against `reconciled.md` (the cross-fragment reconciliation pass) and against the live repo. The following corrections are folded in below; nothing here changes the shape of the seam, only how five specific risks are handled.

- **D-21 (cast risk, most likely failure in this fragment).** Task 2's `_storageManager()` narrows `navigator.storage` with `storage.isA<JSObject>()` and then does `return storage as web.StorageManager;` — but the static type at that cast site is still `JSAny?`, not `JSObject`. `isA<T>()` is a runtime check; it does not change the compile-time type of `storage`, so the analyzer may reject a direct `JSAny? -> StorageManager` cast. **`flutter analyze` is the gate** (Task 2 already runs it right after this file is created). If it complains, the fallback is a double cast: `(storage as JSObject) as web.StorageManager`. Flagged inline at the exact step below.
- **D-13 (absolute test counts).** The fragment's own step/assertion text asserts whole-project `flutter test` totals ("1598", computed as baseline 1576 + 22) as if this workstream had sole occupancy of the repo. Every such whole-project count below has been restated as **"baseline + N for this task"**, gated on `flutter test` exiting green — never on an absolute total. Per-new-file test counts (e.g. "6 tests" for `storage_persistence_types_test.dart`) are left as-is; those are deterministic since the file is new and owned entirely by this workstream.
- **Decision #16 (rejected fold-in).** §1a's fragment demanded §1b fold its state into §1a's `StorageDurability` ("§2c's diagnostics row is specified to read one provider, not three"). **Reconciliation rejected this.** `storagePersistenceProvider` (this fragment) and `storageDurabilityProvider` (§1a) stay **two separate providers** — different lifecycles: an origin-level permission requested once at boot vs. a connection-layer verdict fed asynchronously by drift's probe. §2c composes two `ref.watch`es in one diagnostics row; this is not a Stage-1 task for either fragment. **No implementer should merge these two providers.**
- **Sequencing.** §1b owns `lib/main.dart` among the five Stage-1 fragments (§1a, §1b, §1d, §1e, §1f — §1c is currently unowned, see reconciled.md's top line). A future §1c (uid-scoping / `lastKnownUid` hydration) will also need `lib/main.dart`, so **Task 4 (the boot-wiring task) must be serialised against §1c** — check `git log`/`git status` for a concurrent `main.dart` edit before starting it. Tasks 1, 2, 3 and 5 touch nothing outside `lib/core/storage/`, `test/core/storage/` and `integration_test/`, so they are fully file-disjoint from §1a, §1d, §1e and §1f and can run in parallel with all of them (and with each other, in dependency order).
- **Riverpod v3 compliance — confirmed.** `StoragePersistenceController` is a `Notifier<StoragePersistenceStatus>` wired via `NotifierProvider<StoragePersistenceController, StoragePersistenceStatus>(StoragePersistenceController.new)` — never `StateProvider`. `ref.mounted` guards the post-await `state =` writes in `_request()` and `refresh()`, which is the correct usage for riverpod 3.3.2 (a fire-and-forget future can outlive a disposed container, e.g. in tests).
- **Verification note (found while opening the real files, not in reconciled.md).** Task 4's replacement code for `lib/main.dart:1-9` adds `import 'package:flutter_riverpod/misc.dart';`. The live `lib/main.dart` does **not** currently import `misc.dart` at all, and `Override` (the only symbol from it this file would need) is already visible through the existing `package:flutter_riverpod/flutter_riverpod.dart` import — `bootApp`'s current signature (`{List<Override> overrides = const []}`) already compiles without it. Adding the import is therefore unnecessary and, since `flutter_lints` 6.0.0 includes `unnecessary_import` (inherited from `package:lints/recommended.yaml`), may itself trip `flutter analyze`. Flagged inline at the exact step below; the implementer should drop that one import line unless `flutter analyze` says otherwise. All other `lib/main.dart` line numbers this fragment cites (`:30`, `:56`, `:76-79`, `:80-85`, `:86`) were opened and verified byte-accurate against the current file.

**Resolved `web:` package version:** `pubspec.yaml` pins `web: ^1.1.0`; `pubspec.lock` resolves it to **`1.1.1`** — matches this fragment's citations exactly.

## Files touched

- **create** `lib/core/storage/storage_persistence_types.dart` — Platform-agnostic value types: `StoragePersistOutcome` enum, `StorageEstimateSnapshot` (usage/quota bytes), `StoragePersistenceStatus` (the provider's state). Separate file so BOTH backends can import them without importing the facade that exports them (that would be a cycle) — same layout as `lib/features/account/application/pwa_install_types.dart`.
- **create** `lib/core/storage/storage_persistence.dart` — Conditional-export facade: `export 'storage_persistence_stub.dart' if (dart.library.js_interop) 'storage_persistence_web.dart';`. Two-way split (web-only capability), matching `lib/app/web_lifecycle.dart:33-34`, `lib/features/account/application/pwa_install.dart:8`, `lib/app/is_safari.dart:12`.
- **create** `lib/core/storage/storage_persistence_stub.dart` — Inert backend selected on native (iOS/Android/desktop) and in plain-VM `flutter test`: `notApplicable` / `false` / `null`. Zero imports beyond the types file.
- **create** `lib/core/storage/storage_persistence_web.dart` — Real browser backend: `navigator.storage.persist()` / `persisted()` / `estimate()` via `package:web` 1.1.1 + `dart:js_interop` + `dart:js_interop_unsafe` only (wasm-clean, no `dart:html`).
- **create** `lib/core/storage/storage_persistence_service.dart` — `abstract class StoragePersistenceService` (3 methods) + `const PlatformStoragePersistenceService()` delegating to the facade. Exists because the web backend's code NEVER runs under `flutter test`, so the controller must talk to an override-able interface (same reason `PhotoByteStore`/`ConnectivityService` are interfaces).
- **create** `lib/core/storage/storage_persistence_providers.dart` — `storagePersistenceServiceProvider` (override point for tests) + `StoragePersistenceController extends Notifier<StoragePersistenceStatus>` with `requestPersistenceOnce()` (memoized, never throws) and `refresh()` (re-reads persisted/estimate, never re-requests) + `storagePersistenceProvider` (NotifierProvider). This is the provider §2c reads.
- **modify** `lib/main.dart` — Add `import 'dart:async';` + the providers import; call the new `requestPersistentStorageAtBoot(container)` immediately AFTER `runApp(...)` (line 85), never inside the `Future.wait` at :76-79; add that named, sync, fire-and-forget helper function after `bootApp`'s closing brace.
- **create** `test/core/storage/storage_persistence_types_test.dart` — Value-type coverage: `usedFraction` maths + null/zero-quota guards, defaults, real (non-canonicalised) value equality.
- **create** `test/core/storage/storage_persistence_stub_test.dart` — Proves the native/test path is inert THROUGH the facade (VM has no `dart.library.js_interop`, so the stub is what native gets) — mirrors `test/features/account/application/pwa_install_stub_test.dart`.
- **create** `test/core/storage/storage_persistence_providers_test.dart` — Controller behaviour against a counting fake: exactly-one persist(), granted/denied/failed recording, per-call failure isolation, `refresh()` never re-requests, and the un-overridden default service reporting `notApplicable` on the VM.
- **create** `test/main_boot_storage_persistence_test.dart` — Boot-wiring coverage: `requestPersistentStorageAtBoot` returns before the request resolves (cannot delay the first frame), records the outcome exactly once, and a throwing platform produces no unhandled async error.
- **create** `integration_test/web_storage_persistence_test.dart` — The ONLY execution of `storage_persistence_web.dart`: real headless Chrome asserts persist()/persisted()/estimate() are reachable and correctly typed, plus the boot wiring end-to-end against a real browser. Run via `tool/drive_web.sh`.

## Interfaces produced/consumed

### Produces

- enum StoragePersistOutcome { notRequested, notApplicable, unsupported, granted, denied, failed } — lib/core/storage/storage_persistence_types.dart
- class StorageEstimateSnapshot { const StorageEstimateSnapshot({int? usageBytes, int? quotaBytes}); final int? usageBytes; final int? quotaBytes; double? get usedFraction; } — value-equal, @immutable
- class StoragePersistenceStatus { const StoragePersistenceStatus({StoragePersistOutcome outcome = StoragePersistOutcome.notRequested, bool persisted = false, StorageEstimateSnapshot? estimate}); final StoragePersistOutcome outcome; final bool persisted; final StorageEstimateSnapshot? estimate; } — value-equal, @immutable
- Future<StoragePersistOutcome> requestPersistentStorage() — seam fn, lib/core/storage/storage_persistence.dart
- Future<bool> isStoragePersisted() — seam fn
- Future<StorageEstimateSnapshot?> estimateStorage() — seam fn
- abstract class StoragePersistenceService { Future<StoragePersistOutcome> requestPersist(); Future<bool> isPersisted(); Future<StorageEstimateSnapshot?> estimate(); }
- class PlatformStoragePersistenceService implements StoragePersistenceService { const PlatformStoragePersistenceService(); }
- final storagePersistenceServiceProvider = Provider<StoragePersistenceService>((ref) => const PlatformStoragePersistenceService());
- class StoragePersistenceController extends Notifier<StoragePersistenceStatus> { StoragePersistenceStatus build(); Future<void> requestPersistenceOnce(); Future<void> refresh(); }
- final storagePersistenceProvider = NotifierProvider<StoragePersistenceController, StoragePersistenceStatus>(StoragePersistenceController.new);
- void requestPersistentStorageAtBoot(ProviderContainer container) — lib/main.dart, public (not private) so tests can call it without calling bootApp()
- FOR §2c: read `ref.watch(storagePersistenceProvider)` -> `.outcome` (enum, use `.name` for the row label), `.persisted` (bool), `.estimate?.usageBytes` / `.quotaBytes` / `.usedFraction`; call `ref.read(storagePersistenceProvider.notifier).refresh()` when the Account screen opens to re-read usage without re-requesting persistence.

### Consumes

- lib/main.dart:30 — `Future<void> bootApp({List<Override> overrides = const []}) async` (the boot seam being extended)
- lib/main.dart:76-79 — `await Future.wait([_initSupabase(), container.read(photoFilesProvider).warmDocsPath()]);` (the existing warmDocsPath await; the new call is deliberately NOT added here)
- lib/main.dart:80-85 — `runApp(UncontrolledProviderScope(container: container, child: const MasiApp()));` (insertion point is immediately after line 85, before bootApp's closing `}` on line 86)
- lib/main.dart:56 — `final container = ProviderContainer(overrides: overrides);` (the container handed to the new helper)
- package:web 1.1.1 (pubspec.yaml:71 `web: ^1.1.0`; pubspec.lock:1527-1533 resolves to `version: "1.1.1"`) — ~/.pub-cache/hosted/pub.dev/web-1.1.1/lib/src/dom/html.dart:11703 `extension type Navigator._(JSObject _) implements JSObject`, :12288 `external StorageManager get storage;`
- ~/.pub-cache/hosted/pub.dev/web-1.1.1/lib/src/dom/storage.dart:30 `extension type StorageManager._(JSObject _) implements JSObject`, :34 `external JSPromise<JSBoolean> persisted();`, :46 `external JSPromise<JSBoolean> persist();`, :56 `external JSPromise<StorageEstimate> estimate();`
- ~/.pub-cache/hosted/pub.dev/web-1.1.1/lib/src/dom/storage.dart:65-75 `extension type StorageEstimate._(JSObject _)` with `external int get usage;` / `external int get quota;` — NOTE both are declared NON-nullable `int` although the IDL dictionary members are optional, which is why this plan reads them property-by-property through `dart:js_interop_unsafe` instead of via the typed getters
- dart:js_interop_unsafe (SDK) — `extension JSObjectUnsafeUtilExtension on JSObject { bool has(String property); external R getProperty<R extends JSAny?>(JSAny property); }`
- dart:js_interop (SDK) — `JSPromise<T>.toDart` -> `Future<T>`, `JSBoolean.toDart` -> `bool`, `JSNumber.toDartInt` -> `int`, `JSAny?.isA<T>()`, `JSAny?.isUndefinedOrNull`
- lib/app/web_lifecycle.dart:33-34 — the two-way conditional-export precedent (`export 'web_lifecycle_native.dart' if (dart.library.js_interop) 'web_lifecycle_web.dart';`) and its facade doc explaining why a web-only capability is a two-way split
- lib/features/account/application/pwa_install_web.dart:52-60 — the repo's promise-await + undefined-safe property-read interop style (`globalContext.has(name)`, `(await promise.toDart).toDart`, `(value as JSBoolean).toDart`)
- lib/features/account/application/pwa_install_providers.dart:16-22 — the seam -> Provider wiring precedent
- lib/features/backup/application/backup_providers.dart:42-51 — Riverpod v3 `Notifier` + `NotifierProvider(X.new)` precedent (`WifiOnlySetting`)
- lib/features/backup/application/sync_orchestrator.dart:207 — precedent for `ref.read(...)` inside a Notifier method (not just build)
- lib/core/db/connection/connection_web.dart:19-25 — the `if (kDebugMode) debugPrint('drift/web storage backend: ...')` that §1a un-gates; this workstream's own log is deliberately NOT kDebugMode-gated for the same reason
- lib/app/app.dart:40-42 — `installWebLifecycleFlush(...)` called unconditionally with no `kIsWeb` gate because the seam no-ops off-browser; the boot call copies that shape
- test/main_boot_app_seam_test.dart:1-36 — the existing main.dart seam test and its header explaining why bootApp() itself must never be called from a unit test

## Conventions

RIVERPOD v3 ONLY: `class X extends Notifier<T> { @override T build() => ...; }` + `final xProvider = NotifierProvider<X, T>(X.new);` — see `WifiOnlySetting` at lib/features/backup/application/backup_providers.dart:42-51. NEVER `StateProvider`. `ref.read(...)` inside Notifier methods is fine (sync_orchestrator.dart:207). `ref.mounted` exists in riverpod 3.3.2 (riverpod-3.3.2/lib/src/core/ref.dart:112) and is used here to guard post-await `state =` writes.

PLATFORM SPLITS: conditional export from a facade, never `kIsWeb`, for anything platform-shaped. A WEB-ONLY capability is a TWO-way split (stub + web), which is the established repo pattern for exactly this case — `lib/app/web_lifecycle.dart:33-34`, `lib/features/account/application/pwa_install.dart:8`, `lib/app/is_safari.dart:12` all do `export '<x>_stub.dart' if (dart.library.js_interop) '<x>_web.dart';` and their facade docs explicitly say "this is a two-way split, not the three-way native/web/stub split used elsewhere". Three-way (`if (dart.library.io) ..._native.dart`) is only for capabilities with a REAL native backend (lib/core/platform/ar_support.dart:23-25). Native inertness is therefore satisfied by native selecting the stub — there is no `_native.dart` file to write here, and adding one would be a byte-copy of the stub.

INTEROP STYLE (copy pwa_install_web.dart:52-72 exactly): `package:web` + `dart:js_interop` (+ `dart:js_interop_unsafe` when reading possibly-absent properties) ONLY; never `dart:html`. Promise unwrap is `(await promise.toDart).toDart`. Possibly-missing JS values are read defensively: `if (!obj.has('x')) return <fallback>; final v = obj.getProperty<JSAny?>('x'.toJS); if (v == null || v.isUndefinedOrNull) return <fallback>;` then a typed cast. `avoid_web_libraries_in_flutter` (active via flutter_lints 6.0.0) does not flag `dart:js_interop`/`package:web`.

GREP GATE: the ENFORCED gate is `tool/build_web.sh:40`'s directive-anchored regex (`^\s*(import|export)\s+['\"]dart:io['\"]`), currently empty. CLAUDE.md quotes a naive substring form which ALREADY has 34 prose hits in lib/ (ar_support.dart, web_lifecycle.dart, …). To keep even the naive form's hit-set byte-identical, the new files must not contain the literal token `dart:io` anywhere, including comments — say "the native file-system backends" or "`*_native.dart`" instead.

TESTS: plain `test()`/`group()` from flutter_test; `ProviderContainer(overrides: [...])` + `addTearDown(container.dispose)` (sync_orchestrator_test.dart:185-205). Fakes are `class _FakeX implements X` declared privately per test file and duplicated across files with a "mirrors <other file>" comment — that IS the convention here (see the three separate `_FakeAuthRepository`s in test/app/router_test.dart, test/features/backup/application/sync_orchestrator_test.dart:122 and integration_test/web_boot_stability_test.dart); there is no shared test-helpers directory (`test/shared/` mirrors `lib/shared/`).

LINTS: flutter_lints 6.0.0 (`prefer_const_constructors` is NOT enabled; `prefer_const_constructors_in_immutables` IS, so every `@immutable` class needs a `const` constructor). A file-level doc comment must be followed by `library;` (dangling_library_doc_comments) — see lib/features/topo/data/photo_byte_store.dart:18; facade files avoid this by using `//` comments instead of `///`.

COMMITS: conventional `type(scope): summary`, one logical change each, straight to `main`, and every message ends with the trailer `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>` (project CLAUDE.md).

COMMANDS: every flutter/dart invocation must be prefixed `export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && …` — Homebrew Flutter's PATH does not persist between shell calls.

### Task 1: Value types for the storage-persistence seam

**Files:** Create: `lib/core/storage/storage_persistence_types.dart`, `test/core/storage/storage_persistence_types_test.dart`  
Modify: (none)  
Test: `test/core/storage/storage_persistence_types_test.dart`

**Interfaces:**

Produces:
- `enum StoragePersistOutcome { notRequested, notApplicable, unsupported, granted, denied, failed }`
- `class StorageEstimateSnapshot` (value-equal, `@immutable`, `usedFraction` getter)
- `class StoragePersistenceStatus` (value-equal, `@immutable`)

Consumes:
- None — pure value types, zero imports beyond `package:flutter/foundation.dart`.

- [ ] **Step 1: Write the failing test file first.**

  ```dart
  // test/core/storage/storage_persistence_types_test.dart
  import 'package:flutter_test/flutter_test.dart';
  import 'package:masi/core/storage/storage_persistence_types.dart';

  void main() {
    group('StorageEstimateSnapshot', () {
      test('usedFraction is usage/quota', () {
        const snapshot = StorageEstimateSnapshot(
          usageBytes: 512,
          quotaBytes: 2048,
        );

        expect(snapshot.usedFraction, 0.25);
      });

      test('usedFraction is null when either number is missing', () {
        expect(
          const StorageEstimateSnapshot(quotaBytes: 2048).usedFraction,
          isNull,
        );
        expect(
          const StorageEstimateSnapshot(usageBytes: 512).usedFraction,
          isNull,
        );
        expect(const StorageEstimateSnapshot().usedFraction, isNull);
      });

      test('usedFraction is null for a zero quota (never divides by zero)', () {
        expect(
          const StorageEstimateSnapshot(usageBytes: 512, quotaBytes: 0)
              .usedFraction,
          isNull,
        );
      });

      test('is value-equal on both numbers', () {
        // Deliberately NON-const so the two instances are genuinely distinct
        // objects: two identical `const` literals are canonicalised to the
        // same instance and would pass even without an `operator ==`.
        final a = StorageEstimateSnapshot(usageBytes: 1, quotaBytes: 2);
        final b = StorageEstimateSnapshot(usageBytes: 1, quotaBytes: 2);
        final c = StorageEstimateSnapshot(usageBytes: 1, quotaBytes: 3);

        expect(a, b);
        expect(a.hashCode, b.hashCode);
        expect(a, isNot(c));
      });
    });

    group('StoragePersistenceStatus', () {
      test('defaults to notRequested / not persisted / unknown estimate', () {
        const status = StoragePersistenceStatus();

        expect(status.outcome, StoragePersistOutcome.notRequested);
        expect(status.persisted, isFalse);
        expect(status.estimate, isNull);
      });

      test('is value-equal on all three fields', () {
        final a = StoragePersistenceStatus(
          outcome: StoragePersistOutcome.granted,
          persisted: true,
          estimate: StorageEstimateSnapshot(usageBytes: 1, quotaBytes: 2),
        );
        final b = StoragePersistenceStatus(
          outcome: StoragePersistOutcome.granted,
          persisted: true,
          estimate: StorageEstimateSnapshot(usageBytes: 1, quotaBytes: 2),
        );
        final differentOutcome = StoragePersistenceStatus(
          outcome: StoragePersistOutcome.denied,
          persisted: true,
          estimate: StorageEstimateSnapshot(usageBytes: 1, quotaBytes: 2),
        );
        final differentEstimate = StoragePersistenceStatus(
          outcome: StoragePersistOutcome.granted,
          persisted: true,
          estimate: StorageEstimateSnapshot(usageBytes: 9, quotaBytes: 2),
        );

        expect(a, b);
        expect(a.hashCode, b.hashCode);
        expect(a, isNot(differentOutcome));
        expect(a, isNot(differentEstimate));
      });
    });
  }

  ```

- [ ] **Step 2: Run it and watch it fail because the library does not exist yet.**

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/core/storage/storage_persistence_types_test.dart
  ```

  Expected: Compile error: "Error when reading 'lib/core/storage/storage_persistence_types.dart': No such file or directory" / "Target of URI doesn't exist".

- [ ] **Step 3: Create the types file with the real code.**

  ```dart
  // lib/core/storage/storage_persistence_types.dart
  /// Value types for the browser storage-persistence seam
  /// (`storage_persistence.dart`).
  ///
  /// Kept in their own file — rather than beside the seam — so BOTH backends
  /// (`storage_persistence_stub.dart`, `storage_persistence_web.dart`) can
  /// import them without importing the facade that exports those backends,
  /// which would be a circular import. Same layout as
  /// `lib/features/account/application/pwa_install_types.dart`.
  library;

  import 'package:flutter/foundation.dart';

  /// Result of the ONE-SHOT "please make this origin's storage persistent"
  /// request the app fires during boot (see `StoragePersistenceController`).
  ///
  /// Why this exists (design doc §1b, data-loss path L2): both of this app's
  /// browser stores — the drift database `climbtopo`
  /// (`lib/core/db/connection/connection_web.dart`) and the photo bytes
  /// `climbtopo-photos` (`lib/features/topo/data/photo_byte_store.dart`) — are
  /// BEST-EFFORT storage by default, i.e. the browser may evict them: iOS
  /// Safari purges an unused origin after about 7 days, and Chrome evicts
  /// non-persistent origins under storage pressure. A granted
  /// `navigator.storage.persist()` exempts the origin from that ordinary
  /// eviction. Nothing outside a browser can evict this app's data, which is
  /// why the whole seam is web-only.
  enum StoragePersistOutcome {
    /// Nothing has been asked yet — the initial `storagePersistenceProvider`
    /// state, and what it still reads as synchronously after boot has *started*
    /// the request.
    notRequested,

    /// This platform has no evictable-storage concept to protect: every
    /// non-browser build (iOS/Android/desktop, and plain-Dart `flutter test`)
    /// writes to a real file system that nothing silently purges. Terminal
    /// state off the browser.
    notApplicable,

    /// Running in a browser, but one that exposes no
    /// `navigator.storage.persist` to call. Also what an insecure context looks
    /// like: `navigator.storage` is only exposed to secure contexts (HTTPS or
    /// localhost).
    unsupported,

    /// The browser granted persistence — this origin's storage is now exempt
    /// from ordinary eviction.
    granted,

    /// The browser refused: its own engagement heuristics, or the user declined
    /// on the engines that show a prompt. Storage still works, it is simply
    /// best-effort/evictable.
    denied,

    /// The request threw/rejected. Recorded rather than propagated — a failed
    /// persistence request must never affect boot.
    failed,
  }

  /// `navigator.storage.estimate()`'s two numbers, in bytes, with `null`
  /// meaning "the browser did not report it" (never zero — zero usage and
  /// unknown usage are different facts).
  ///
  /// Both numbers are ORIGIN-WIDE: they cover the drift database, the photo
  /// byte store, the Cache API and everything else this origin stores, not any
  /// single store. Browsers also deliberately pad/round them, so treat them as
  /// approximate.
  @immutable
  class StorageEstimateSnapshot {
    const StorageEstimateSnapshot({this.usageBytes, this.quotaBytes});

    final int? usageBytes;
    final int? quotaBytes;

    /// `usage / quota` in `0.0 .. 1.0`, or `null` when either number is missing
    /// or the quota is not a positive number.
    double? get usedFraction {
      final usage = usageBytes;
      final quota = quotaBytes;
      if (usage == null || quota == null || quota <= 0) return null;
      return usage / quota;
    }

    @override
    bool operator ==(Object other) =>
        identical(this, other) ||
        (other is StorageEstimateSnapshot &&
            other.usageBytes == usageBytes &&
            other.quotaBytes == quotaBytes);

    @override
    int get hashCode => Object.hash(usageBytes, quotaBytes);

    @override
    String toString() =>
        'StorageEstimateSnapshot(usageBytes: $usageBytes, '
        'quotaBytes: $quotaBytes)';
  }

  /// Everything the app knows about how durable this origin's local storage is.
  /// Written once at boot by `requestPersistentStorageAtBoot` (`lib/main.dart`)
  /// and read by the Account screen's storage-diagnostics row (design doc §2c).
  @immutable
  class StoragePersistenceStatus {
    const StoragePersistenceStatus({
      this.outcome = StoragePersistOutcome.notRequested,
      this.persisted = false,
      this.estimate,
    });

    /// What boot's one-shot `persist()` request answered.
    final StoragePersistOutcome outcome;

    /// Last known `navigator.storage.persisted()`: whether this origin's
    /// storage IS persistent right now, independent of whether our own request
    /// is what made it so (a previously-granted grant survives reloads).
    /// Always `false` off the browser — use [outcome] `notApplicable` to tell
    /// "no browser" apart from "browser said no".
    final bool persisted;

    /// Last known `navigator.storage.estimate()`, or `null` when it was never
    /// read or is unavailable.
    final StorageEstimateSnapshot? estimate;

    @override
    bool operator ==(Object other) =>
        identical(this, other) ||
        (other is StoragePersistenceStatus &&
            other.outcome == outcome &&
            other.persisted == persisted &&
            other.estimate == estimate);

    @override
    int get hashCode => Object.hash(outcome, persisted, estimate);

    @override
    String toString() =>
        'StoragePersistenceStatus(outcome: $outcome, persisted: $persisted, '
        'estimate: $estimate)';
  }

  ```

- [ ] **Step 4: Re-run the test and watch it pass.**

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/core/storage/storage_persistence_types_test.dart
  ```

  Expected: All 6 tests pass.

- [ ] **Step 5: Confirm the whole project still analyzes clean.**

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter analyze
  ```

  Expected: No issues found!

- [ ] **Step 6: Commit.**

**Assertions:**

- `flutter test test/core/storage/storage_persistence_types_test.dart` passes with 6 tests.
- `flutter analyze` reports 0 issues.
- `StoragePersistenceStatus()` with no arguments has `outcome == StoragePersistOutcome.notRequested`, `persisted == false`, `estimate == null`.
- `StorageEstimateSnapshot(usageBytes: 512, quotaBytes: 2048).usedFraction == 0.25`, and it is `null` whenever either number is null or quota <= 0.
- The equality tests use non-const instances, so they genuinely exercise `operator ==` rather than const canonicalisation.

**Commit message:** `feat(storage): value types for the web storage-persistence seam`

### Task 2: Conditional-export seam over navigator.storage (stub + web backends)

**Files:** Create: `lib/core/storage/storage_persistence.dart`, `lib/core/storage/storage_persistence_stub.dart`, `lib/core/storage/storage_persistence_web.dart`, `test/core/storage/storage_persistence_stub_test.dart`  
Modify: (none)  
Test: `test/core/storage/storage_persistence_stub_test.dart`

**Interfaces:**

Produces:
- `Future<StoragePersistOutcome> requestPersistentStorage()` — seam fn, `lib/core/storage/storage_persistence.dart`
- `Future<bool> isStoragePersisted()` — seam fn
- `Future<StorageEstimateSnapshot?> estimateStorage()` — seam fn

Consumes:
- `lib/app/web_lifecycle.dart:25-26`, `lib/features/account/application/pwa_install.dart:8`, `lib/app/is_safari.dart:12` — the two-way conditional-export precedent for a web-only capability
- `package:web` 1.1.1 (`Navigator.storage`, `StorageManager.persist()/persisted()/estimate()`, `StorageEstimate.usage/quota`)
- `dart:js_interop` / `dart:js_interop_unsafe` (SDK) — `JSPromise<T>.toDart`, `JSBoolean.toDart`, `JSNumber.toDartInt`, `JSAny?.isA<T>()`, `.isUndefinedOrNull`, `JSObject.has()/getProperty()`
- `lib/features/account/application/pwa_install_web.dart:43-62` — promise-await + undefined-safe property-read interop style precedent
- Value types from Task 1 (`storage_persistence_types.dart`)

- [ ] **Step 1: Write the failing stub test first. It imports the FACADE (not the stub directly) so it also proves which backend native/VM selects — mirroring test/features/account/application/pwa_install_stub_test.dart.**

  ```dart
  // test/core/storage/storage_persistence_stub_test.dart
  import 'package:flutter_test/flutter_test.dart';
  import 'package:masi/core/storage/storage_persistence.dart';
  import 'package:masi/core/storage/storage_persistence_types.dart';

  /// Verifies the native/test storage-persistence backend
  /// (`storage_persistence_stub.dart`, reached here through the
  /// `storage_persistence.dart` facade because plain-VM `flutter_test` has no
  /// `dart.library.js_interop`) is completely inert: nothing outside a browser
  /// can evict this app's local data, so there is nothing to request and
  /// nothing to measure. Mirrors
  /// `test/features/account/application/pwa_install_stub_test.dart`.
  void main() {
    group('storage_persistence stub backend', () {
      test('requestPersistentStorage reports notApplicable', () async {
        expect(
          await requestPersistentStorage(),
          StoragePersistOutcome.notApplicable,
        );
      });

      test('requestPersistentStorage is inert when called repeatedly', () async {
        expect(
          await requestPersistentStorage(),
          StoragePersistOutcome.notApplicable,
        );
        expect(
          await requestPersistentStorage(),
          StoragePersistOutcome.notApplicable,
        );
      });

      test('isStoragePersisted is always false', () async {
        expect(await isStoragePersisted(), isFalse);
      });

      test('estimateStorage is always null (unknown, not zero)', () async {
        expect(await estimateStorage(), isNull);
      });
    });
  }

  ```

- [ ] **Step 2: Run it and watch it fail because the facade does not exist yet.**

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/core/storage/storage_persistence_stub_test.dart
  ```

  Expected: Compile error: "Error when reading 'lib/core/storage/storage_persistence.dart': No such file or directory".

- [ ] **Step 3: Create the facade. Note the comment style is `//` (not `///`) to match web_lifecycle.dart / pwa_install.dart and avoid the dangling_library_doc_comments lint, and the word for native file access is spelled `*_native.dart` so the literal token the web grep gate scans for never appears in this directory.**

  ```dart
  // lib/core/storage/storage_persistence.dart
  // Facade for the browser's storage-persistence API:
  // `navigator.storage.persist()` / `persisted()` / `estimate()`.
  //
  // This is a WEB-ONLY capability — nothing outside a browser can silently
  // evict this app's local data — so, exactly like
  // `lib/features/account/application/pwa_install.dart`,
  // `lib/app/web_lifecycle.dart` and `lib/app/is_safari.dart`, this is a
  // TWO-way split rather than the three-way stub/native/web split used where a
  // real native backend exists (e.g. `lib/core/platform/ar_support.dart`):
  //  - native (iOS/Android/desktop) AND plain-Dart `flutter test`: the inert
  //    stub, picked whenever `dart.library.js_interop` is unavailable. Every
  //    entry point answers "not applicable" and touches nothing, so native
  //    behaviour is completely unchanged by this seam's existence. There is
  //    deliberately no `*_native.dart` file: it would be a byte-copy of the
  //    stub.
  //  - web: real `navigator.storage` reads via `package:web` +
  //    `dart:js_interop` ONLY — never `dart:html` — so this stays
  //    dart2wasm-clean (wasm is the default web build here) and introduces no
  //    file-system library that `tool/build_web.sh`'s grep gate would flag.
  //
  // Value types live in `storage_persistence_types.dart` so both backends can
  // import them without importing this facade (which would be a cycle).
  export 'storage_persistence_stub.dart'
      if (dart.library.js_interop) 'storage_persistence_web.dart';

  ```

- [ ] **Step 4: Create the inert stub backend.**

  ```dart
  // lib/core/storage/storage_persistence_stub.dart
  import 'storage_persistence_types.dart';

  /// Inert fallback used on native (iOS/Android/desktop) and in plain-Dart
  /// `flutter test`, i.e. whenever `dart.library.js_interop` is unavailable
  /// (see `storage_persistence.dart`'s facade doc). There is no browser to ask
  /// and nothing that evicts local data on those platforms, so this always
  /// answers [StoragePersistOutcome.notApplicable] and touches nothing.
  Future<StoragePersistOutcome> requestPersistentStorage() async =>
      StoragePersistOutcome.notApplicable;

  /// See [requestPersistentStorage]. There is no browser storage bucket here,
  /// so "is it persistent?" is always `false`. Callers must NOT read that as
  /// "native storage is fragile" — [StoragePersistOutcome.notApplicable] from
  /// [requestPersistentStorage] is what distinguishes "no such concept" from
  /// "the browser said no".
  Future<bool> isStoragePersisted() async => false;

  /// See [requestPersistentStorage]. No `navigator.storage.estimate()` to read,
  /// so usage/quota are unknown (`null`), never zero.
  Future<StorageEstimateSnapshot?> estimateStorage() async => null;

  ```

- [ ] **Step 5: Create the real web backend. Every entry point is total: it can only return a value, never throw. Reads go through dart:js_interop_unsafe rather than package:web's typed getters because `StorageEstimate.usage`/`.quota` are declared non-nullable `int` even though the IDL dictionary members are optional, and because `navigator.storage` is absent entirely in an insecure context — a typed read of either would risk a compiler-inserted conversion failure instead of a clean 'unsupported'/'unknown' answer.**

  ```dart
  // lib/core/storage/storage_persistence_web.dart
  import 'dart:js_interop';
  import 'dart:js_interop_unsafe';

  import 'package:web/web.dart' as web;

  import 'storage_persistence_types.dart';

  // Real browser implementation of the storage-persistence seam, picked
  // whenever `dart.library.js_interop` is available (see
  // `storage_persistence.dart`'s facade doc). Wasm-clean: only `package:web`
  // and `dart:js_interop`/`dart:js_interop_unsafe`, never `dart:html`.
  //
  // Every function here is TOTAL: it returns a value for every browser and
  // every failure mode and never throws, because its only caller
  // (`StoragePersistenceController.requestPersistenceOnce`) runs
  // fire-and-forget at boot.

  /// Requests persistent storage for this origin via
  /// `navigator.storage.persist()`, which returns `Promise<boolean>`:
  /// `true` when the origin's bucket is now persistent (including when it
  /// already was — the call is idempotent and does not re-prompt), `false`
  /// when the browser declines.
  ///
  /// Engine notes worth knowing: Chromium grants silently based on engagement/
  /// installed-ness and never prompts; Firefox may show a one-time
  /// "persistent storage" permission prompt; iOS Safari grants for
  /// home-screen-installed web apps and applies its ~7-day unused-origin purge
  /// to the rest — which is precisely the loss this seam mitigates.
  Future<StoragePersistOutcome> requestPersistentStorage() async {
    final manager = _storageManager();
    if (manager == null || !manager.has('persist')) {
      return StoragePersistOutcome.unsupported;
    }
    try {
      final granted = (await manager.persist().toDart).toDart;
      return granted
          ? StoragePersistOutcome.granted
          : StoragePersistOutcome.denied;
    } catch (_) {
      return StoragePersistOutcome.failed;
    }
  }

  /// Whether this origin's storage is persistent RIGHT NOW
  /// (`navigator.storage.persisted()`, also a `Promise<boolean>`), independent
  /// of whether this app's own request is what made it so. Reports `false`
  /// rather than throwing when the API is missing or rejects.
  Future<bool> isStoragePersisted() async {
    final manager = _storageManager();
    if (manager == null || !manager.has('persisted')) return false;
    try {
      return (await manager.persisted().toDart).toDart;
    } catch (_) {
      return false;
    }
  }

  /// Reads `navigator.storage.estimate()`, which resolves to a DICTIONARY
  /// (`{usage, quota}`) — not a class instance — whose members are both
  /// optional per spec.
  ///
  /// `package:web` models it as `StorageEstimate` with `external int get usage`
  /// / `external int get quota`, i.e. NON-nullable, so a browser that omits
  /// either member would make a typed read fail. Each member is therefore read
  /// individually and defensively: a missing `usage` still yields the `quota`
  /// we did get, instead of collapsing the whole estimate to `null`.
  Future<StorageEstimateSnapshot?> estimateStorage() async {
    final manager = _storageManager();
    if (manager == null || !manager.has('estimate')) return null;
    try {
      final estimate = await manager.estimate().toDart;
      return StorageEstimateSnapshot(
        usageBytes: _readIntProperty(estimate, 'usage'),
        quotaBytes: _readIntProperty(estimate, 'quota'),
      );
    } catch (_) {
      return null;
    }
  }

  /// `navigator.storage`, or `null` when this browser/context does not expose
  /// it at all — `StorageManager` is `[SecureContext]`, so the property is
  /// absent over plain HTTP (localhost counts as secure). Read through
  /// `getProperty` + an explicit object check rather than `navigator.storage`
  /// so an absent API becomes a clean
  /// [StoragePersistOutcome.unsupported] instead of relying on a typed
  /// getter's behaviour for `undefined`. Mirrors the undefined-safe global
  /// reads in `lib/features/account/application/pwa_install_web.dart`.
  web.StorageManager? _storageManager() {
    final JSObject navigator = web.window.navigator;
    if (!navigator.has('storage')) return null;
    final storage = navigator.getProperty<JSAny?>('storage'.toJS);
    if (storage == null || storage.isUndefinedOrNull) return null;
    if (!storage.isA<JSObject>()) return null;
    return storage as web.StorageManager;
  }

  /// Reads [name] off [object] as a Dart `int`, or `null` when the property is
  /// absent, `undefined`/`null`, or not a JS number.
  int? _readIntProperty(JSObject object, String name) {
    if (!object.has(name)) return null;
    final value = object.getProperty<JSAny?>(name.toJS);
    if (value == null || value.isUndefinedOrNull) return null;
    if (!value.isA<JSNumber>()) return null;
    return (value as JSNumber).toDartInt;
  }

  ```

  > **[D-21 correction]** `_storageManager()`'s final line — `return storage as web.StorageManager;` — casts from the static type `JSAny?` (the declared type of `storage`, only *narrowed at runtime* by the preceding `storage.isA<JSObject>()` check, which does not change its compile-time type). This is the single most likely `flutter analyze` failure in this fragment. The gate is `flutter analyze` (run immediately after this step, below). **If it complains, use the fallback double cast:** `return (storage as JSObject) as web.StorageManager;`

- [ ] **Step 6: Re-run the stub test and watch it pass.**

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/core/storage/storage_persistence_stub_test.dart
  ```

  Expected: All 4 tests pass.

- [ ] **Step 7: Analyze — this is what type-checks the web backend, which no VM test can execute.**

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter analyze
  ```

  Expected: No issues found!

- [ ] **Step 8: Prove the enforced web grep gate is still empty and that the new directory contains no reference to the native file-system library at all (so even the naive substring form of the gate quoted in CLAUDE.md keeps its exact current hit-set).**

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && tool/build_web.sh --gate && grep -rn 'dart:io' lib/core/storage || echo 'NO HITS IN lib/core/storage'
  ```

  Expected: "ok: no dart:io outside *_native.dart" then "==> gate-only run complete", followed by "NO HITS IN lib/core/storage".

- [ ] **Step 9: Commit.**

**Assertions:**

- `flutter test test/core/storage/storage_persistence_stub_test.dart` passes with 4 tests: the facade resolves to the stub on the VM and every entry point is inert (`notApplicable` / `false` / `null`).
- `flutter analyze` reports 0 issues — this is the compile-level check on `storage_persistence_web.dart`'s js_interop, since that file never executes under `flutter test`.
- `tool/build_web.sh --gate` exits 0.
- `grep -rn 'dart:io' lib/core/storage` produces no output.
- `lib/core/storage/storage_persistence.dart` is a two-way conditional export (`storage_persistence_stub.dart` / `if (dart.library.js_interop) storage_persistence_web.dart`) with no `dart.library.io` branch and no `kIsWeb` anywhere in the directory: `grep -rn 'kIsWeb' lib/core/storage` is empty.
- Every function in `storage_persistence_web.dart` is wrapped so it can only return a value: `grep -c 'catch (_)' lib/core/storage/storage_persistence_web.dart` is 3, and the file contains no `rethrow` or `throw`.

**Commit message:** `feat(storage): navigator.storage persistence seam (web + inert stub)`

### Task 3: Service interface + one-shot persistence controller and provider

> **[Decision #16]** `storagePersistenceProvider` (defined in this task) stays a **separate** provider from §1a's `storageDurabilityProvider` — this was a live conflict in reconciliation (§1a's fragment demanded a fold-in) and was **rejected**: the two track different lifecycles (origin-level permission requested once at boot vs. a connection-layer verdict fed asynchronously by drift's probe). §2c composes both via two separate `ref.watch`es in one diagnostics row. Do not merge these two providers.

**Files:** Create: `lib/core/storage/storage_persistence_service.dart`, `lib/core/storage/storage_persistence_providers.dart`, `test/core/storage/storage_persistence_providers_test.dart`  
Modify: (none)  
Test: `test/core/storage/storage_persistence_providers_test.dart`

**Interfaces:**

Produces:
- `abstract class StoragePersistenceService { Future<StoragePersistOutcome> requestPersist(); Future<bool> isPersisted(); Future<StorageEstimateSnapshot?> estimate(); }`
- `class PlatformStoragePersistenceService implements StoragePersistenceService`
- `final storagePersistenceServiceProvider = Provider<StoragePersistenceService>(...)`
- `class StoragePersistenceController extends Notifier<StoragePersistenceStatus>` (`requestPersistenceOnce()`, `refresh()`)
- `final storagePersistenceProvider = NotifierProvider<StoragePersistenceController, StoragePersistenceStatus>(StoragePersistenceController.new);` — **this is the provider §2c reads** (see Decision #16 above — stays separate from `storageDurabilityProvider`)

Consumes:
- Seam functions from Task 2 (`storage_persistence.dart`)
- `lib/features/backup/application/backup_providers.dart:42-51` — `WifiOnlySetting`, the Riverpod v3 `Notifier` + `NotifierProvider(X.new)` precedent
- `lib/features/backup/application/sync_orchestrator.dart:207` — precedent for `ref.read(...)` inside a Notifier method (not just `build()`)
- `lib/core/db/connection/connection_web.dart:19-25` — the `if (kDebugMode) debugPrint(...)` pattern that §1a un-gates; this workstream's own log is deliberately **not** `kDebugMode`-gated, for the same reason (release builds are exactly where storage-loss reports come from)

- [ ] **Step 1: Write the failing controller test first, with a counting fake service.**

  ```dart
  // test/core/storage/storage_persistence_providers_test.dart
  import 'package:flutter_riverpod/flutter_riverpod.dart';
  import 'package:flutter_test/flutter_test.dart';
  import 'package:masi/core/storage/storage_persistence_providers.dart';
  import 'package:masi/core/storage/storage_persistence_service.dart';
  import 'package:masi/core/storage/storage_persistence_types.dart';

  /// Counting [StoragePersistenceService] double.
  ///
  /// The real browser backend (`storage_persistence_web.dart`) NEVER executes
  /// under `flutter test` — the VM has no `dart.library.js_interop`, so the
  /// facade resolves to the inert stub — which is exactly why
  /// [StoragePersistenceController] talks to this interface instead of calling
  /// the seam functions directly. The browser code itself is covered by
  /// `integration_test/web_storage_persistence_test.dart`.
  class _FakeStoragePersistenceService implements StoragePersistenceService {
    _FakeStoragePersistenceService({
      this.outcome = StoragePersistOutcome.granted,
      this.persisted = true,
      this.estimateSnapshot = const StorageEstimateSnapshot(
        usageBytes: 1024,
        quotaBytes: 8192,
      ),
      this.throwOnRequest = false,
      this.throwOnPersisted = false,
      this.throwOnEstimate = false,
    });

    final StoragePersistOutcome outcome;
    final bool throwOnRequest;
    final bool throwOnPersisted;
    final bool throwOnEstimate;

    // Mutable so a test can change what the browser "reports" between the
    // boot request and a later refresh().
    bool persisted;
    StorageEstimateSnapshot? estimateSnapshot;

    int requestCalls = 0;
    int persistedCalls = 0;
    int estimateCalls = 0;

    @override
    Future<StoragePersistOutcome> requestPersist() async {
      requestCalls++;
      if (throwOnRequest) throw StateError('persist-boom');
      return outcome;
    }

    @override
    Future<bool> isPersisted() async {
      persistedCalls++;
      if (throwOnPersisted) throw StateError('persisted-boom');
      return persisted;
    }

    @override
    Future<StorageEstimateSnapshot?> estimate() async {
      estimateCalls++;
      if (throwOnEstimate) throw StateError('estimate-boom');
      return estimateSnapshot;
    }
  }

  /// Container over [service], or over the production default when omitted.
  ProviderContainer _makeContainer([StoragePersistenceService? service]) {
    final container = ProviderContainer(
      overrides: [
        if (service != null)
          storagePersistenceServiceProvider.overrideWithValue(service),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  void main() {
    test('starts at notRequested without touching the platform', () {
      final fake = _FakeStoragePersistenceService();
      final container = _makeContainer(fake);

      expect(
        container.read(storagePersistenceProvider),
        const StoragePersistenceStatus(),
      );
      expect(fake.requestCalls, 0);
      expect(fake.persistedCalls, 0);
      expect(fake.estimateCalls, 0);
    });

    test('records a granted request plus persisted() and estimate()', () async {
      final fake = _FakeStoragePersistenceService();
      final container = _makeContainer(fake);

      await container
          .read(storagePersistenceProvider.notifier)
          .requestPersistenceOnce();

      expect(
        container.read(storagePersistenceProvider),
        const StoragePersistenceStatus(
          outcome: StoragePersistOutcome.granted,
          persisted: true,
          estimate: StorageEstimateSnapshot(usageBytes: 1024, quotaBytes: 8192),
        ),
      );
      expect(fake.requestCalls, 1);
      expect(fake.persistedCalls, 1);
      expect(fake.estimateCalls, 1);
    });

    test('records a denied request without throwing', () async {
      final fake = _FakeStoragePersistenceService(
        outcome: StoragePersistOutcome.denied,
        persisted: false,
      );
      final container = _makeContainer(fake);

      await container
          .read(storagePersistenceProvider.notifier)
          .requestPersistenceOnce();

      final status = container.read(storagePersistenceProvider);
      expect(status.outcome, StoragePersistOutcome.denied);
      expect(status.persisted, isFalse);
      expect(status.estimate?.quotaBytes, 8192);
    });

    test('a throwing persist() degrades to failed; the future completes '
        'normally (an await that rethrew would fail this test)', () async {
      final fake = _FakeStoragePersistenceService(throwOnRequest: true);
      final container = _makeContainer(fake);

      await container
          .read(storagePersistenceProvider.notifier)
          .requestPersistenceOnce();

      final status = container.read(storagePersistenceProvider);
      expect(status.outcome, StoragePersistOutcome.failed);
      // The remaining reads still happen: a refused/broken persist() must not
      // cost us the diagnostics.
      expect(status.persisted, isTrue);
      expect(status.estimate?.usageBytes, 1024);
    });

    test('persist() is requested EXACTLY ONCE however many callers ask',
        () async {
      final fake = _FakeStoragePersistenceService();
      final container = _makeContainer(fake);
      final controller = container.read(storagePersistenceProvider.notifier);

      // Two callers in the same microtask, then a third after completion.
      await Future.wait([
        controller.requestPersistenceOnce(),
        controller.requestPersistenceOnce(),
      ]);
      await controller.requestPersistenceOnce();

      expect(fake.requestCalls, 1);
      expect(fake.persistedCalls, 1);
      expect(fake.estimateCalls, 1);
      expect(
        container.read(storagePersistenceProvider).outcome,
        StoragePersistOutcome.granted,
      );
    });

    test('an estimate() failure leaves usage/quota unknown but keeps the '
        'outcome', () async {
      final fake = _FakeStoragePersistenceService(throwOnEstimate: true);
      final container = _makeContainer(fake);

      await container
          .read(storagePersistenceProvider.notifier)
          .requestPersistenceOnce();

      final status = container.read(storagePersistenceProvider);
      expect(status.outcome, StoragePersistOutcome.granted);
      expect(status.persisted, isTrue);
      expect(status.estimate, isNull);
    });

    test('a persisted() failure reads as not-persistent and never throws',
        () async {
      final fake = _FakeStoragePersistenceService(throwOnPersisted: true);
      final container = _makeContainer(fake);

      await container
          .read(storagePersistenceProvider.notifier)
          .requestPersistenceOnce();

      final status = container.read(storagePersistenceProvider);
      expect(status.outcome, StoragePersistOutcome.granted);
      expect(status.persisted, isFalse);
      expect(status.estimate?.quotaBytes, 8192);
    });

    test('refresh() re-reads persisted()/estimate() and never re-requests '
        'persist()', () async {
      final fake = _FakeStoragePersistenceService();
      final container = _makeContainer(fake);
      final controller = container.read(storagePersistenceProvider.notifier);

      await controller.requestPersistenceOnce();
      fake.estimateSnapshot = const StorageEstimateSnapshot(
        usageBytes: 4096,
        quotaBytes: 8192,
      );

      await controller.refresh();

      final status = container.read(storagePersistenceProvider);
      expect(status.estimate?.usageBytes, 4096);
      expect(status.outcome, StoragePersistOutcome.granted,
          reason: 'refresh must preserve the boot request outcome');
      expect(fake.requestCalls, 1, reason: 'refresh must not re-request');
      expect(fake.estimateCalls, 2);
      expect(fake.persistedCalls, 2);
    });

    test('the production default service is inert off the browser', () async {
      // No override: `PlatformStoragePersistenceService` delegates to the
      // conditionally-exported seam, which on the Dart VM is the stub — the
      // same code path every native (iOS/Android) build takes.
      final container = _makeContainer();

      expect(
        container.read(storagePersistenceServiceProvider),
        isA<PlatformStoragePersistenceService>(),
      );

      await container
          .read(storagePersistenceProvider.notifier)
          .requestPersistenceOnce();

      expect(
        container.read(storagePersistenceProvider),
        const StoragePersistenceStatus(
          outcome: StoragePersistOutcome.notApplicable,
        ),
      );
    });
  }

  ```

- [ ] **Step 2: Run it and watch it fail because neither library exists yet.**

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/core/storage/storage_persistence_providers_test.dart
  ```

  Expected: Compile error: "Error when reading 'lib/core/storage/storage_persistence_service.dart': No such file or directory" (and the same for storage_persistence_providers.dart).

- [ ] **Step 3: Create the service interface plus its platform-delegating default.**

  ```dart
  // lib/core/storage/storage_persistence_service.dart
  import 'storage_persistence.dart';
  import 'storage_persistence_types.dart';

  /// The three storage-persistence capabilities behind an interface, purely so
  /// tests can substitute a fake — the same reason
  /// `ConnectivityService` (`lib/features/backup/data/connectivity_service.dart`)
  /// and `PhotoByteStore` (`lib/features/topo/data/photo_byte_store.dart`) are
  /// interfaces.
  ///
  /// This matters more than usual here: the real implementation
  /// (`storage_persistence_web.dart`) is only selected when
  /// `dart.library.js_interop` is available, so its code NEVER runs under
  /// `flutter test`. Every VM test of the controller and the boot wiring runs
  /// against a fake through this interface, and the browser code itself is
  /// covered by `integration_test/web_storage_persistence_test.dart` in real
  /// headless Chrome.
  abstract class StoragePersistenceService {
    /// Asks the platform to make this origin's storage persistent. Implementations
    /// must never throw — they report failure as
    /// [StoragePersistOutcome.failed].
    Future<StoragePersistOutcome> requestPersist();

    /// Whether storage IS persistent right now, regardless of who made it so.
    Future<bool> isPersisted();

    /// Current origin-wide usage/quota, or `null` when unavailable.
    Future<StorageEstimateSnapshot?> estimate();
  }

  /// Production [StoragePersistenceService]: a thin delegate to the
  /// conditionally-exported platform functions in `storage_persistence.dart`
  /// (web: real `navigator.storage`; native and `flutter test`: the inert
  /// stub).
  class PlatformStoragePersistenceService implements StoragePersistenceService {
    const PlatformStoragePersistenceService();

    @override
    Future<StoragePersistOutcome> requestPersist() => requestPersistentStorage();

    @override
    Future<bool> isPersisted() => isStoragePersisted();

    @override
    Future<StorageEstimateSnapshot?> estimate() => estimateStorage();
  }

  ```

- [ ] **Step 4: Create the providers + controller.**

  ```dart
  // lib/core/storage/storage_persistence_providers.dart
  import 'package:flutter/foundation.dart';
  import 'package:flutter_riverpod/flutter_riverpod.dart';

  import 'storage_persistence_service.dart';
  import 'storage_persistence_types.dart';

  /// The [StoragePersistenceService] boot's request and the Account screen's
  /// diagnostics row go through. Defaults to the real platform delegate (web:
  /// `navigator.storage`; native/tests: the inert stub); override it in tests
  /// with a fake — see
  /// `test/core/storage/storage_persistence_providers_test.dart`.
  final storagePersistenceServiceProvider = Provider<StoragePersistenceService>(
    (ref) => const PlatformStoragePersistenceService(),
  );

  /// Owns the app's single [StoragePersistenceStatus]: the outcome of boot's
  /// one-shot `navigator.storage.persist()` request plus the last known
  /// `persisted()` / `estimate()` readings.
  ///
  /// Riverpod v3 [Notifier] (never `StateProvider` — see CLAUDE.md), mirroring
  /// `WifiOnlySetting` in
  /// `lib/features/backup/application/backup_providers.dart`.
  class StoragePersistenceController extends Notifier<StoragePersistenceStatus> {
    /// Memoised [requestPersistenceOnce] future — the "exactly once" guard.
    /// Assigned SYNCHRONOUSLY on the first call (before [_request] reaches its
    /// first `await`), so even two callers in the same microtask can only
    /// produce one `persist()`; kept after it completes, so a later caller gets
    /// the same already-completed future instead of a second request.
    Future<void>? _requestOnce;

    @override
    StoragePersistenceStatus build() => const StoragePersistenceStatus();

    /// Boot entry point (`requestPersistentStorageAtBoot` in `lib/main.dart`):
    /// requests persistent storage once, then records `persisted()` +
    /// `estimate()` into [state].
    ///
    /// NEVER completes with an error — every `await` inside is guarded — so the
    /// fire-and-forget `unawaited(...)` at boot cannot produce an unhandled
    /// async error, and a browser that refuses, lacks, or throws from the
    /// Storage API cannot affect boot. It also never blocks anything: boot
    /// starts the returned future and drops it.
    ///
    /// Idempotent PER CONTAINER. Production calls it once per page load;
    /// `integration_test/` files that call `bootApp()` repeatedly in one
    /// headless-Chrome page build a fresh container each time and so request
    /// once per boot — harmless, since `persist()` is itself idempotent in the
    /// browser and does not re-prompt.
    Future<void> requestPersistenceOnce() => _requestOnce ??= _request();

    Future<void> _request() async {
      final service = ref.read(storagePersistenceServiceProvider);
      StoragePersistOutcome outcome;
      try {
        outcome = await service.requestPersist();
      } catch (e) {
        debugPrint('storage-persistence: persist() threw: $e');
        outcome = StoragePersistOutcome.failed;
      }
      // Read the diagnostics even when the request itself failed: "denied, and
      // here is how full you are" is the interesting case.
      final persisted = await _readPersisted(service);
      final estimate = await _readEstimate(service);
      // This future can outlive its container (a disposed test container, a
      // torn-down page), and writing `state` after disposal throws.
      if (!ref.mounted) return;
      state = StoragePersistenceStatus(
        outcome: outcome,
        persisted: persisted,
        estimate: estimate,
      );
      if (outcome != StoragePersistOutcome.notApplicable) {
        // Deliberately NOT behind `kDebugMode`: alongside the drift storage
        // backend logged by `connection_web.dart`, this is the first thing to
        // check in any "my data vanished" web report — and release builds are
        // exactly where those come from. Silent on native, where the outcome
        // is always `notApplicable`.
        debugPrint(
          'storage-persistence: outcome=${outcome.name} persisted=$persisted '
          'estimate=$estimate',
        );
      }
    }

    /// Re-reads `persisted()` + `estimate()` WITHOUT re-requesting persistence
    /// — the refresh path for the Account screen's diagnostics row (usage grows
    /// as photos are imported). Preserves
    /// [StoragePersistenceStatus.outcome] and never throws.
    Future<void> refresh() async {
      final service = ref.read(storagePersistenceServiceProvider);
      final persisted = await _readPersisted(service);
      final estimate = await _readEstimate(service);
      if (!ref.mounted) return;
      state = StoragePersistenceStatus(
        outcome: state.outcome,
        persisted: persisted,
        estimate: estimate,
      );
    }

    Future<bool> _readPersisted(StoragePersistenceService service) async {
      try {
        return await service.isPersisted();
      } catch (e) {
        debugPrint('storage-persistence: persisted() threw: $e');
        return false;
      }
    }

    Future<StorageEstimateSnapshot?> _readEstimate(
      StoragePersistenceService service,
    ) async {
      try {
        return await service.estimate();
      } catch (e) {
        debugPrint('storage-persistence: estimate() threw: $e');
        return null;
      }
    }
  }

  /// App-wide storage-durability snapshot: written once at boot by
  /// `requestPersistentStorageAtBoot` (`lib/main.dart`) and read by the Account
  /// screen's storage-diagnostics row (design doc §2c), which can call
  /// `ref.read(storagePersistenceProvider.notifier).refresh()` for a live
  /// usage/quota re-read.
  final storagePersistenceProvider =
      NotifierProvider<StoragePersistenceController, StoragePersistenceStatus>(
        StoragePersistenceController.new,
      );

  ```

- [ ] **Step 5: Re-run the controller test and watch it pass.**

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/core/storage/storage_persistence_providers_test.dart
  ```

  Expected: All 9 tests pass.

- [ ] **Step 6: Analyze.**

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter analyze
  ```

  Expected: No issues found!

- [ ] **Step 7: Commit.**

**Assertions:**

- `flutter test test/core/storage/storage_persistence_providers_test.dart` passes with 9 tests.
- Calling `requestPersistenceOnce()` twice concurrently plus once afterwards results in `requestCalls == 1`, `persistedCalls == 1`, `estimateCalls == 1` (this is the "persist() exactly once" assertion of §1b).
- With `throwOnRequest: true` the awaited `requestPersistenceOnce()` completes normally and state records `StoragePersistOutcome.failed` — an implementation that rethrew would fail this test.
- With `throwOnEstimate: true` the outcome is still `granted` and `estimate` is `null`: a diagnostics failure degrades independently of the request.
- `refresh()` updates persisted/estimate, preserves `outcome`, and leaves `requestCalls == 1`.
- With NO override, `storagePersistenceServiceProvider` is a `PlatformStoragePersistenceService` and the recorded status is exactly `StoragePersistenceStatus(outcome: notApplicable)` — the native/stub path is inert end-to-end.
- `storagePersistenceProvider` is a `NotifierProvider` over a `Notifier` subclass; `grep -rn 'StateProvider' lib/core/storage` is empty.
- `flutter analyze` reports 0 issues.

**Commit message:** `feat(storage): one-shot persistence controller + provider (Riverpod v3)`

### Task 4: Request persistent storage exactly once at boot, after the first frame is scheduled

> **[Sequencing correction]** `lib/main.dart` is the one file this fragment shares with anything else in Stage 1. A future §1c (uid-scoping / `lastKnownUid` hydration) will also need `lib/main.dart` — **serialise this task against it** (check `git log`/`git status` for a concurrent `main.dart` edit before starting, and reconcile rather than rebuild if one exists). This task is otherwise the only file-non-disjoint point in §1b: Tasks 1, 2, 3 and 5 can run fully in parallel with §1a, §1d, §1e and §1f.

**Files:** Create: `test/main_boot_storage_persistence_test.dart`  
Modify: `lib/main.dart:1-9`, `lib/main.dart:80-86`  
Test: `test/main_boot_storage_persistence_test.dart`

**Interfaces:**

Produces:
- `void requestPersistentStorageAtBoot(ProviderContainer container)` — `lib/main.dart`, public (not private) so tests can call it without calling `bootApp()`

Consumes:
- `lib/main.dart:30` — `Future<void> bootApp({List<Override> overrides = const []}) async` (the boot seam being extended) — **verified accurate**
- `lib/main.dart:56` — `final container = ProviderContainer(overrides: overrides);` — **verified accurate**
- `lib/main.dart:76-79` — the existing `Future.wait([_initSupabase(), warmDocsPath()])` (the new call is deliberately NOT added here) — **verified accurate**
- `lib/main.dart:80-85` — `runApp(UncontrolledProviderScope(...))`; insertion point is immediately after line 85, before `bootApp`'s closing `}` on line 86 — **verified accurate**
- `lib/app/app.dart:40-42` — `installWebLifecycleFlush(...)` called unconditionally with no `kIsWeb` gate; the boot call copies that shape — **verified accurate**
- `test/main_boot_app_seam_test.dart:1-36` — the existing seam test and its header explaining why `bootApp()` itself must never be called from a unit test
- `storagePersistenceProvider` / `StoragePersistenceController.requestPersistenceOnce()` from Task 3

- [ ] **Step 1: Write the failing boot-wiring test first.**

  ```dart
  // test/main_boot_storage_persistence_test.dart
  // Boot-wiring coverage for the §1b persistent-storage request.
  //
  // Like `test/main_boot_app_seam_test.dart`, this deliberately does NOT call
  // `bootApp()` — that performs real side effects (a real
  // `Supabase.initialize`, `path_provider`) and builds its own container with
  // no way to observe it. `requestPersistentStorageAtBoot` exists as a named
  // top-level function precisely so the wiring can be driven against a test
  // container instead.
  import 'package:flutter_riverpod/flutter_riverpod.dart';
  import 'package:flutter_test/flutter_test.dart';
  import 'package:masi/core/storage/storage_persistence_providers.dart';
  import 'package:masi/core/storage/storage_persistence_service.dart';
  import 'package:masi/core/storage/storage_persistence_types.dart';
  import 'package:masi/main.dart' show requestPersistentStorageAtBoot;

  /// Trimmed copy of `_FakeStoragePersistenceService` in
  /// `test/core/storage/storage_persistence_providers_test.dart` (per-file
  /// fakes are this repo's convention — cf. the three `_FakeAuthRepository`
  /// declarations): just enough to count calls and to throw on demand.
  class _FakeStoragePersistenceService implements StoragePersistenceService {
    _FakeStoragePersistenceService({this.throwEverything = false});

    final bool throwEverything;
    int requestCalls = 0;

    @override
    Future<StoragePersistOutcome> requestPersist() async {
      requestCalls++;
      if (throwEverything) throw StateError('persist-boom');
      return StoragePersistOutcome.granted;
    }

    @override
    Future<bool> isPersisted() async {
      if (throwEverything) throw StateError('persisted-boom');
      return true;
    }

    @override
    Future<StorageEstimateSnapshot?> estimate() async {
      if (throwEverything) throw StateError('estimate-boom');
      return const StorageEstimateSnapshot(usageBytes: 1024, quotaBytes: 8192);
    }
  }

  ProviderContainer _containerWith(StoragePersistenceService service) {
    final container = ProviderContainer(
      overrides: [
        storagePersistenceServiceProvider.overrideWithValue(service),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  void main() {
    test('returns before the request resolves, so it can never delay the '
        'first frame', () async {
      final fake = _FakeStoragePersistenceService();
      final container = _containerWith(fake);

      requestPersistentStorageAtBoot(container);

      // Synchronously after the call the request is still in flight: the boot
      // wiring started it and returned, exactly as `runApp` needs.
      expect(
        container.read(storagePersistenceProvider).outcome,
        StoragePersistOutcome.notRequested,
      );

      // Calling the controller again returns the SAME memoised future, so this
      // awaits the in-flight boot request rather than starting a second one.
      await container
          .read(storagePersistenceProvider.notifier)
          .requestPersistenceOnce();

      expect(fake.requestCalls, 1);
      final status = container.read(storagePersistenceProvider);
      expect(status.outcome, StoragePersistOutcome.granted);
      expect(status.persisted, isTrue);
      expect(status.estimate?.quotaBytes, 8192);
    });

    test('a platform that throws everywhere can never surface an unhandled '
        'boot error', () async {
      final fake = _FakeStoragePersistenceService(throwEverything: true);
      final container = _containerWith(fake);

      // Fire-and-forget, exactly as boot does. If the controller propagated
      // instead of recording, this `unawaited` future would complete with an
      // error and the test zone would fail this test.
      requestPersistentStorageAtBoot(container);

      await container
          .read(storagePersistenceProvider.notifier)
          .requestPersistenceOnce();

      final status = container.read(storagePersistenceProvider);
      expect(status.outcome, StoragePersistOutcome.failed);
      expect(status.persisted, isFalse);
      expect(status.estimate, isNull);
    });

    test('boot wiring is idempotent per container', () async {
      final fake = _FakeStoragePersistenceService();
      final container = _containerWith(fake);

      requestPersistentStorageAtBoot(container);
      requestPersistentStorageAtBoot(container);
      await container
          .read(storagePersistenceProvider.notifier)
          .requestPersistenceOnce();

      expect(fake.requestCalls, 1);
    });
  }

  ```

- [ ] **Step 2: Run it and watch it fail: `requestPersistentStorageAtBoot` is not defined in lib/main.dart yet.**

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/main_boot_storage_persistence_test.dart
  ```

  Expected: Compile error: "Undefined name 'requestPersistentStorageAtBoot'" / "'requestPersistentStorageAtBoot' isn't a top-level declaration in 'package:masi/main.dart'".

- [ ] **Step 3: Add the two imports to lib/main.dart. `dart:async` goes first (matching lib/app/app.dart:1, which imports it for the same `unawaited`); the storage import slots after the existing `core/db/database_provider.dart` line 9, keeping the relative-import block alphabetical (app, core/config, core/db, core/storage).**

  ```dart
  // lib/main.dart — replace lines 1-9 with:
  import 'dart:async';

  import 'package:flutter/material.dart';
  import 'package:flutter_riverpod/flutter_riverpod.dart';
  import 'package:flutter_riverpod/misc.dart';
  import 'package:flutter_web_plugins/url_strategy.dart';
  import 'package:supabase_flutter/supabase_flutter.dart';

  import 'app/app.dart';
  import 'core/config/supabase_config.dart';
  import 'core/db/database_provider.dart';
  import 'core/storage/storage_persistence_providers.dart';
  ```

  > **[Verification note]** The live `lib/main.dart` does not currently import `package:flutter_riverpod/misc.dart`, and nothing new in this task needs a symbol from it — `Override` (used in `bootApp`'s existing signature) already resolves via the `package:flutter_riverpod/flutter_riverpod.dart` import on the line above. Adding it is very likely a no-op at best and an `unnecessary_import` lint hit at worst (`flutter_lints` 6.0.0 includes `unnecessary_import`, inherited from `package:lints/recommended.yaml`). Drop that import line unless `flutter analyze` (Task 4's own gate, a few steps down) says it's actually required.

- [ ] **Step 4: Insert the boot call immediately AFTER the existing `runApp(...)` statement (currently lines 80-85) and before `bootApp`'s closing brace (currently line 86) — NOT inside the `Future.wait([_initSupabase(), warmDocsPath()])` at lines 76-79.**

  ```dart
  // lib/main.dart — after the existing runApp(...) call, still inside bootApp:
    runApp(
      UncontrolledProviderScope(
        container: container,
        child: const MasiApp(),
      ),
    );
    // §1b of the web-offline-reliability design (mitigates data-loss path L2,
    // "storage eviction with no cloud copy"): ask the browser ONCE to make
    // this origin's storage persistent — the drift `climbtopo` database and
    // the `climbtopo-photos` photo bytes are evictable best-effort storage
    // otherwise — and record the answer for the Account screen's
    // storage-diagnostics row.
    //
    // Placement is deliberate: AFTER `runApp`, fire-and-forget, and NOT part
    // of the `Future.wait` above. `_initSupabase()` and `warmDocsPath()` are
    // awaited because the first frame genuinely depends on them (see the long
    // comment above); nothing rendered depends on this, so it must never sit
    // between boot and the first frame. `requestPersistenceOnce()` can never
    // complete with an error (see its doc), so the `unawaited` inside
    // `requestPersistentStorageAtBoot` cannot produce an unhandled async
    // error, and the call is INERT off the browser
    // (`storage_persistence_stub.dart` answers `notApplicable`) — the same
    // "call it unconditionally, the seam no-ops on native" shape as
    // `installWebLifecycleFlush` in `app/app.dart`, never a `kIsWeb` gate.
    requestPersistentStorageAtBoot(container);
  }
  ```

- [ ] **Step 5: Add the named helper as a top-level function right after `bootApp`'s closing brace, before `_initSupabase`'s doc comment.**

  ```dart
  // lib/main.dart — new top-level function between bootApp and _initSupabase:

  /// Starts boot's one-shot persistent-storage request against [container] and
  /// returns IMMEDIATELY — synchronous by design so it can never delay the
  /// first frame (see the call site at the end of [bootApp]).
  ///
  /// A named top-level function rather than an inline `unawaited(...)` purely
  /// so the wiring is unit-testable without calling [bootApp], which performs
  /// real side effects a plain `flutter test` cannot have (see
  /// `test/main_boot_app_seam_test.dart`'s header). Its tests live in
  /// `test/main_boot_storage_persistence_test.dart`; the real browser side is
  /// covered by `integration_test/web_storage_persistence_test.dart`.
  ///
  /// `unawaited` is safe here specifically because
  /// `StoragePersistenceController.requestPersistenceOnce()` is documented and
  /// tested never to complete with an error.
  void requestPersistentStorageAtBoot(ProviderContainer container) {
    unawaited(
      container
          .read(storagePersistenceProvider.notifier)
          .requestPersistenceOnce(),
    );
  }
  ```

- [ ] **Step 6: Re-run the boot test and watch it pass.**

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test test/main_boot_storage_persistence_test.dart
  ```

  Expected: All 3 tests pass.

- [ ] **Step 7: Run the whole suite and analyze — this is the regression gate for touching main.dart.**

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter analyze && flutter test
  ```

  Expected: **[D-13 corrected]** No issues found!, and `flutter test` exits green. Do NOT gate on an absolute total (the fragment's own text claimed "baseline 1576 plus the 22 added by tasks 1, 3 and 4 (6 + 4 + 9 + 3 = 22, so 1598)" — that assumed sole occupancy of the repo). Gate on: whatever `flutter test` reports today (the baseline) plus exactly 22 new tests from this workstream's tasks 1/3/4 (6 + 9 + 3 — task 2's 4 are already counted once task 2 lands), and a green exit code.

- [ ] **Step 8: Commit.**

**Assertions:**

- `flutter test test/main_boot_storage_persistence_test.dart` passes with 3 tests.
- Immediately (synchronously) after `requestPersistentStorageAtBoot(container)` the provider still reads `StoragePersistOutcome.notRequested` — proof the call does not await the request and therefore cannot delay the first frame.
- After awaiting, `requestCalls == 1` and the status records the platform's answer; calling `requestPersistentStorageAtBoot` twice still yields `requestCalls == 1`.
- With a service that throws from all three methods, the test passes with `outcome == failed` and no unhandled async error is reported by the test zone.
- In `lib/main.dart`, `requestPersistentStorageAtBoot(container);` appears AFTER the `runApp(...)` statement and is NOT inside the `Future.wait([...])` list that awaits `_initSupabase()` and `warmDocsPath()`: `grep -n 'requestPersistentStorageAtBoot\|runApp\|Future.wait' lib/main.dart` shows Future.wait < runApp < requestPersistentStorageAtBoot in line order.
- `lib/main.dart` contains no `kIsWeb` and no `await` on the persistence call: `grep -n 'kIsWeb\|await requestPersistentStorage' lib/main.dart` is empty.
- **[D-13 corrected]** Whole-project `flutter analyze` = 0 issues and `flutter test` exits green at baseline + 22 (this workstream's own new tests from tasks 1/3/4: 6 + 9 + 3) — assert the *delta*, never a hardcoded absolute total.

**Commit message:** `feat(web): request persistent storage once at boot (L2)`

### Task 5: Browser-executed assertions for the navigator.storage interop

**Files:** Create: `integration_test/web_storage_persistence_test.dart`  
Modify: (none)  
Test: `integration_test/web_storage_persistence_test.dart`

**Interfaces:**

Produces:
- `integration_test/web_storage_persistence_test.dart` — the only real execution of `storage_persistence_web.dart`'s js_interop

Consumes:
- `requestPersistentStorage()` / `isStoragePersisted()` / `estimateStorage()` (Task 2)
- `storagePersistenceProvider` + `requestPersistentStorageAtBoot` (Tasks 3 and 4)
- `tool/drive_web.sh` (headless Chrome runner) and `tool/build_web.sh` (dart2wasm compile gate)

- [ ] **Step 1: Write the browser test. This is the ONLY thing that executes storage_persistence_web.dart, so it is where the js_interop types are actually proven.**

  ```dart
  // integration_test/web_storage_persistence_test.dart
  // Browser-executed coverage for the §1b storage-persistence seam.
  //
  // This is the ONLY place `lib/core/storage/storage_persistence_web.dart`
  // ever runs: the facade selects it only when `dart.library.js_interop` is
  // available, so `flutter test` (Dart VM) always gets the inert stub and can
  // never catch a wrong interop type. Run it with:
  //
  //   tool/drive_web.sh integration_test/web_storage_persistence_test.dart
  //
  // Deliberately dependency-light: it does not boot the whole app (no router,
  // no Supabase, no drift), it drives the seam and the boot wiring directly.
  import 'package:flutter_riverpod/flutter_riverpod.dart';
  import 'package:flutter_test/flutter_test.dart';
  import 'package:integration_test/integration_test.dart';
  import 'package:masi/core/storage/storage_persistence.dart';
  import 'package:masi/core/storage/storage_persistence_providers.dart';
  import 'package:masi/core/storage/storage_persistence_types.dart';
  import 'package:masi/main.dart' show requestPersistentStorageAtBoot;

  void main() {
    IntegrationTestWidgetsFlutterBinding.ensureInitialized();

    group('web navigator.storage seam', () {
      testWidgets('persist() resolves to a real grant decision', (tester) async {
        final outcome = await requestPersistentStorage();

        // Headless Chrome on localhost IS a secure context and does expose
        // `navigator.storage.persist`. Which way it decides depends on
        // engagement heuristics (a fresh profile is usually denied), so both
        // answers are acceptable — but `unsupported` or `failed` here means
        // the js_interop binding is wrong, not that the browser lacks the API.
        expect(
          outcome,
          anyOf(
            StoragePersistOutcome.granted,
            StoragePersistOutcome.denied,
          ),
          reason: 'persist() must resolve to a real boolean decision; '
              'got $outcome',
        );
      });

      testWidgets('persisted() agrees with a granted request', (tester) async {
        final outcome = await requestPersistentStorage();
        final persisted = await isStoragePersisted();

        if (outcome == StoragePersistOutcome.granted) {
          expect(persisted, isTrue);
        } else {
          // Nothing to assert about a denied bucket beyond "it answered a
          // boolean without throwing", which the type already guarantees.
          expect(persisted, isA<bool>());
        }
      });

      testWidgets('estimate() returns real usage and quota numbers',
          (tester) async {
        final estimate = await estimateStorage();

        expect(estimate, isNotNull,
            reason: 'navigator.storage.estimate() is available in headless '
                'Chrome; null means the interop read failed');
        expect(estimate!.quotaBytes, isNotNull);
        expect(estimate.quotaBytes! > 0, isTrue);
        expect(estimate.usageBytes, isNotNull);
        expect(estimate.usageBytes! >= 0, isTrue);
        expect(estimate.usedFraction, isNotNull);
      });

      testWidgets('the boot wiring records the real browser outcome exactly '
          'once', (tester) async {
        // No provider overrides: this runs the production
        // PlatformStoragePersistenceService against the real browser.
        final container = ProviderContainer();
        addTearDown(container.dispose);

        requestPersistentStorageAtBoot(container);
        expect(
          container.read(storagePersistenceProvider).outcome,
          StoragePersistOutcome.notRequested,
          reason: 'boot must not block on the request',
        );

        await container
            .read(storagePersistenceProvider.notifier)
            .requestPersistenceOnce();

        final status = container.read(storagePersistenceProvider);
        expect(
          status.outcome,
          anyOf(
            StoragePersistOutcome.granted,
            StoragePersistOutcome.denied,
          ),
        );
        expect(status.estimate, isNotNull);
        expect(status.estimate!.quotaBytes, isNotNull);

        // refresh() must not re-request, and must still produce numbers.
        await container.read(storagePersistenceProvider.notifier).refresh();
        final refreshed = container.read(storagePersistenceProvider);
        expect(refreshed.outcome, status.outcome);
        expect(refreshed.estimate, isNotNull);
      });
    });
  }

  ```

- [ ] **Step 2: Analyze first (the file must be clean against the VM/stub resolution too, since `flutter analyze` covers integration_test/).**

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter analyze
  ```

  Expected: No issues found!

- [ ] **Step 3: Run it in real headless Chrome. Requires `chromedriver` on PATH matching the installed Chrome major version (see CLAUDE.md).**

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && tool/drive_web.sh integration_test/web_storage_persistence_test.dart
  ```

  Expected: "==> flutter drive PASSED". If it FAILS with `unsupported` or `failed`, the js_interop binding in storage_persistence_web.dart is wrong — do not weaken the assertion, fix the binding.

- [ ] **Step 4: Run the production wasm build as the dart2wasm compile gate (drive_web compiles with the JS pipeline, not wasm, so this is the only check that the interop code also compiles under dart2wasm).**

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && tool/build_web.sh
  ```

  Expected: "ok: no dart:io outside *_native.dart", then "==> build complete: build/web".

- [ ] **Step 5: Full suite one more time to confirm nothing regressed.**

  ```bash
  export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi && flutter test
  ```

  Expected: **[D-13 corrected]** `flutter test` exits green with baseline + 22 (this workstream's tasks 1/3/4 tests: 6 + 9 + 3; task 5 adds no VM tests, only the browser suite). Do not assert an absolute total like "1598" — restate relative to whatever the baseline is at implementation time.

- [ ] **Step 6: Commit.**

**Assertions:**

- `tool/drive_web.sh integration_test/web_storage_persistence_test.dart` prints "==> flutter drive PASSED" — 4 browser tests green.
- In real headless Chrome, `requestPersistentStorage()` returns `granted` or `denied` (never `unsupported`/`failed`), proving `navigator.storage.persist()`'s `JSPromise<JSBoolean>` unwrap is correct.
- `estimateStorage()` returns a non-null snapshot whose `quotaBytes > 0` and `usageBytes >= 0`, proving the `StorageEstimate` dictionary read (`usage`/`quota` as `JSNumber` -> `toDartInt`) is correct.
- The boot wiring test inside the browser shows `notRequested` synchronously after `requestPersistentStorageAtBoot`, then a real outcome after awaiting, using the un-overridden production `PlatformStoragePersistenceService`.
- `tool/build_web.sh` (wasm, the production build) succeeds with the grep gate green — the interop compiles under dart2wasm, not just the JS pipeline.
- **[D-13 corrected]** `flutter analyze` = 0 and `flutter test` exits green at baseline + 22 — assert the delta against whatever `flutter test` reports before this workstream starts, never a hardcoded absolute total.

**Commit message:** `test(storage): browser-executed navigator.storage interop assertions`
