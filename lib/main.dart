import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_web_plugins/url_strategy.dart';

import 'app/app.dart';
import 'core/config/supabase_init_provider.dart';
import 'core/db/database_provider.dart';
import 'core/db/storage_durability_provider.dart';
import 'core/storage/storage_persistence.dart' show listenForAppInstalled;
import 'core/storage/storage_persistence_providers.dart';
import 'features/account/application/auth_providers.dart';
import 'features/account/application/pwa_install.dart' show pwaIsStandalone;

Future<void> main() => bootApp();

/// Guards [usePathUrlStrategy] so it's only ever invoked once per page.
/// `usePathUrlStrategy()` sets a one-time browser global (`dart:ui_web`) and
/// throws "Cannot set URL strategy a second time or after the app has been
/// initialized." if called twice on the same page. Production `main()` calls
/// `bootApp()` exactly once (unaffected), but tests/integration tests may
/// call `bootApp()` multiple times in one headless-Chrome page.
bool _urlStrategyConfigured = false;

/// Does everything `main()` needs to boot the real app, with the container's
/// [overrides] exposed as a seam — production code (`main()` below) always
/// calls this with the default empty list, so its behavior is byte-identical
/// to the inline `main()` this was extracted from; `integration_test/` files
/// call it directly with real overrides (e.g. `webAuthGateEnabledProvider` or
/// a fake `authRepositoryProvider`) to reach app states a plain `app.main()`
/// can't (see `web_smoke_test.dart` / `web_boot_stability_test.dart`), since
/// `main()` previously built its `ProviderContainer` with no way to inject
/// overrides at all.
Future<void> bootApp({List<Override> overrides = const []}) async {
  WidgetsFlutterBinding.ensureInitialized();
  // Path-based (rather than the default `#/`-hash) browser URLs, so shared
  // links like `/community/topo/<wallId>` are real, shareable paths instead
  // of `/#/community/topo/<wallId>`. `usePathUrlStrategy()` itself is a
  // no-op on native (see `flutter_web_plugins`' `url_strategy.dart`: it's
  // conditionally implemented per-platform, `dart.library.ui_web` selecting
  // the real browser-history version, everything else a no-op stub) — safe
  // to call unconditionally rather than gating on `kIsWeb`.
  if (!_urlStrategyConfigured) {
    usePathUrlStrategy();
    _urlStrategyConfigured = true;
  }
  // Pre-warm the shared PhotoFiles' docs-path cache BEFORE the first frame,
  // so the synchronous, cache-backed `resolvePhotoPathSync` (used by
  // `watchTopos`'s thumbnail column and the canvas's first
  // loadOriginal) resolves stored relative `Photos.localPath`
  // values to absolute paths from the very first render, instead of a cold
  // cache silently passing the bare relative path through (unresolvable
  // against the process CWD) until some later, unrelated resolution
  // happens to warm it. Built off a manual ProviderContainer (rather than
  // ProviderScope + a FutureProvider) so this can be awaited here, before
  // runApp, guaranteeing the warm completes before any provider reads the
  // DB; the container is then handed to the app via
  // UncontrolledProviderScope so every provider still resolves against this
  // same container/cache.
  final container = ProviderContainer(overrides: overrides);
  // `_initSupabase()` (a network round trip: session restore/token refresh)
  // and `warmDocsPath()` (a native path_provider lookup; a no-op on web) are
  // independent of each other, so run them concurrently rather than
  // sequentially — this cuts the boot-to-first-frame latency from the SUM of
  // both down to the MAX of the two.
  //
  // Both must still be fully AWAITED before `runApp`, though — that part is
  // not just a style choice. `MasiApp.build()` (`app/app.dart`) synchronously
  // constructs `authStateProvider` on its very first build via
  // `ref.listen(authStateProvider, ...)`, which eagerly reads
  // `Supabase.instance.client` (see `supabaseClientProvider` in
  // `core/config/supabase_providers.dart`). `Supabase.instance.client` is a
  // `late` field on the package's singleton that throws
  // `LateInitializationError` if read before `Supabase.initialize()` has
  // completed — so a fire-and-forget (un-awaited) `Supabase.initialize()`
  // here would crash the very first frame, on both web and native, the
  // moment auth state is touched. If that ever changes (e.g. the auth layer
  // moves behind a provider that tolerates a not-yet-initialized Supabase),
  // this can become non-blocking too.
  //
  // `LastKnownUid.hydrate()` joins them for a different reason: it must
  // complete before the first frame so no provider ever observes a
  // spuriously-null uid. `effectiveUidProvider` — THE single "who am I, for
  // LOCAL data" door (`features/account/application/auth_providers.dart`) —
  // falls back to this persisted uid whenever there is no live session, which
  // is what makes local data ownership survive a cold restart with no
  // network. Skipping it would leave §1c's fix half-applied: the uid is
  // remembered within a run but forgotten across a restart, so a captive
  // portal that triggers gotrue's hard sign-out (audit item L4) still
  // collapses every owner filter to `ownerId IS NULL` — an invisible library
  // whose subsequent edits are silently written to the wrong owner. It is
  // independent of the other two and, unlike them, cannot throw at all (it
  // catches its own database failures and degrades to "no last-known uid"),
  // so it costs the boot path nothing but the one indexed read it already
  // needs before any query runs.
  //
  // `verifyDatabaseUsable` rides along for a fourth reason: `hydrate()`
  // swallows its own database failures by design, so a database that opens
  // and then FAILS its first query would leave the connection layer's
  // (optimistic, pre-query) verdict standing — creation enabled, no warning
  // banner. The probe shares `hydrate()`'s `ensureOpen`, so it costs one
  // trivial statement rather than a second open. See its doc in
  // `core/db/database_provider.dart`.
  //
  // …and all four go through [awaitBootWork], which is what guarantees this
  // `await` terminates. `hydrate()` is the first REAL query against the local
  // database, so it is what actually opens it — and drift 2.34.2 has no
  // timeout anywhere on that path (see [awaitBootWork]'s doc for the four
  // unbounded awaits). Awaiting it bare is a boot-time hang: no frame, no
  // error, no retry, no way in.
  //
  // Each one is NAMED and individually tracked ([BootTask]) rather than merged
  // into one `Future.wait` the gate can only observe as a single yes/no. The
  // gate used to see exactly that, and when it did not settle it published
  // "the local database did not answer its first query" — unconditionally. Only
  // two of these four are the local database. A `Supabase.initialize` that
  // never came back on flaky mobile data was therefore reported to the user as
  // DEAD STORAGE, with the create-topo interlock turned on and a banner telling
  // them their device could not save topos. `blamesStorage` is what stops a
  // network stall being answerable with a storage verdict.
  await awaitBootWork(container, <BootTask>[
    // A network round trip (session restore/token refresh). It bounds itself
    // at `kCloudInitTimeout` and records the outcome on `cloudInitProvider`,
    // so a stall here has its OWN honest report and needs none from storage.
    BootTask(
      'the cloud sign-in',
      _initSupabase(container),
      blamesStorage: false,
    ),
    // A `path_provider` lookup on native, inert on web. Not the database.
    BootTask(
      'the photo folder lookup',
      container.read(photoFilesProvider).warmDocsPath(),
      blamesStorage: false,
    ),
    // The first REAL query against the local database — this is what forces
    // drift to open it, so a stall here IS evidence about storage.
    BootTask(
      "the local database's first query",
      container.read(lastKnownUidProvider.notifier).hydrate(),
      blamesStorage: true,
    ),
    BootTask(
      'the local database probe',
      verifyDatabaseUsable(container),
      blamesStorage: true,
    ),
  ]);
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
  // of the `Future.wait` above. `_initSupabase()`, `warmDocsPath()` and
  // `hydrate()` are awaited because the first frame genuinely depends on them
  // (see the long comment above); nothing rendered depends on this, so it
  // must never sit between boot and the first frame.
  // `requestPersistenceOnce()` can never complete with an error (see its
  // doc), so the `unawaited` inside `requestPersistentStorageAtBoot` cannot
  // produce an unhandled async error, and the call is INERT off the browser
  // (`storage_persistence_stub.dart` answers `notApplicable`) — the same
  // "call it unconditionally, the seam no-ops on native" shape as
  // `installWebLifecycleFlush` in `app/app.dart`, never a `kIsWeb` gate.
  requestPersistentStorageAtBoot(container);
}

/// One NAMED unit of [bootApp]'s pre-first-frame work, and whether a stall in
/// it says anything about local storage.
///
/// [awaitBootWork] used to receive a single `Future.wait` over four unrelated
/// futures — a Supabase network round trip, a `path_provider` lookup, the
/// database's first query and the database probe — and could observe only
/// whether that ONE future had settled. When it had not, it published "the
/// local database did not answer its first query within Ns". Two of the four
/// are not the database at all, and the loudest of them is a network call, so a
/// `Supabase.initialize` that never came back on flaky mobile data was reported
/// to the user as dead storage: create-topo disabled, a banner saying this
/// device could not save their topos, and a diagnosis pointing at the one
/// subsystem that was fine.
///
/// Naming the futures is the whole fix. The gate tracks each one separately,
/// says which ones did not settle, and only reaches for a storage verdict when
/// a [blamesStorage] task is among them.
@immutable
class BootTask {
  const BootTask(this.name, this.future, {required this.blamesStorage});

  /// Short label, phrased so it can be dropped into a user-visible sentence
  /// and a log line unchanged (e.g. "the cloud sign-in").
  final String name;

  final Future<void> future;

  /// Whether a stall in this task is EVIDENCE ABOUT LOCAL STORAGE.
  ///
  /// True only for work that actually queries the local database. Everything
  /// else must report its own failure through its own provider
  /// (`cloudInitProvider` for the Supabase init) rather than borrowing
  /// storage's verdict, because a message that names the wrong subsystem sends
  /// the user to fix the wrong thing — and, on the storage path specifically,
  /// disables topo creation for a database that was never broken.
  final bool blamesStorage;

  @override
  String toString() => 'BootTask($name, blamesStorage: $blamesStorage)';
}

/// [tasks]' names, sorted, for a log line or a reason string.
String _taskNames(Iterable<BootTask> tasks) =>
    (tasks.map((task) => task.name).toList()..sort()).join(', ');

/// How long [bootApp] blocks the FIRST FRAME on its pre-`runApp` work.
///
/// Sized to comfortably outlast every LEGITIMATE cold start:
///  - native steady state is a `NativeDatabase` file open plus one
///    `PRAGMA foreign_keys = ON` and a single indexed read of a one-row
///    table — milliseconds;
///  - the one-time v1->v9 upgrade launch is the expensive case (the v5->v6
///    step in `app_database.dart` runs one `UPDATE` per original photo, and
///    v6->v7 rebuilds two small tables), but it runs ONCE, on the single
///    launch that upgrades, and it is a few hundred small statements inside
///    one transaction;
///  - web's first-ever load fetches `sqlite3.wasm`, spins up two workers and
///    acquires OPFS handles, which is the slowest realistic path.
///
/// Past this the app renders ANYWAY and the open keeps running in the
/// background. That is not a degraded state so much as the pre-§1b one: an
/// app shell with the topos list on its normal loading spinner. `hydrate()`
/// landing late still self-heals, because `effectiveUidProvider` watches
/// `lastKnownUidProvider` and every uid-scoped query rebuilds off it.
const Duration kBootFirstFrameDeadline = Duration(seconds: 8);

/// How long [bootApp] waits for a [BootTask.blamesStorage] task before
/// publishing [StorageDurability.unavailable].
///
/// Nothing legitimate takes this long; only drift's unbounded awaits do (see
/// [awaitBootWork]). Deliberately far beyond [kBootFirstFrameDeadline] so a
/// merely-slow migration is never mistaken for a dead database — and even
/// then the verdict is REVERSIBLE, see [awaitBootWork].
///
/// It is also deliberately LONGER than every per-subsystem bound that feeds it
/// (`kStorageOpenTimeout` 20s in `connection/storage_durability.dart`,
/// `kCloudInitTimeout` 15s in `core/config/supabase_init_provider.dart`), so a
/// subsystem that can name its own failure always gets to do so first and this
/// generic "did not answer" verdict is the last resort it is meant to be.
const Duration kBootStorageDeadline = Duration(seconds: 30);

/// Awaits [tasks] — [bootApp]'s pre-first-frame work — but never lets it
/// hold the first frame hostage, and never lets it reach `main()` as an
/// error. Booting always terminates in a usable or an EXPLAINED state.
///
/// §1b moved the first real query against the local database onto the
/// pre-`runApp` path: `LastKnownUid.hydrate()` reads the `AppSettings` table,
/// which is what forces drift to actually open the database. drift 2.34.2 has
/// no timeout ANYWHERE on that path (`grep -rE 'timeout|Future\.any'` over
/// `drift-2.34.2/lib/src/web/` and `lib/wasm.dart` finds nothing) and has at
/// least four awaits that can never complete:
///
///  1. `src/web/wasm_setup.dart:123` — `_probeDedicated` awaits the dedicated
///     worker's first message. The `error` listener only fires on a worker
///     LOAD failure, so a worker that loads and then wedges hangs here.
///  2. `src/web/wasm_setup.dart:155` — `_probeShared`, same shape.
///  3. `src/web/wasm_setup.dart:329` — `connectToRemoteAndInitialize`'s
///     handshake over the `MessageChannel`.
///  4. `src/web/wasm_setup/shared.dart:390` — `_loadLockedWasmVfs` awaits
///     `messageEvent.forTarget(worker).first` with NO error listener at all.
///     This is the worst one: it is on the `opfsLocks` backend a
///     cross-origin-isolated Chrome actually selects, and it runs inside the
///     worker's own `LazyDatabase` (`shared.dart:284`) — i.e. on the FIRST
///     QUERY, long after `WasmDatabase.open` reported a green verdict. A
///     healthy-looking `opfsLocks` report is therefore not evidence that
///     storage works; only a completed query is.
///
/// Two deadlines, because "slow" and "hung" deserve different answers:
///  - at [kBootFirstFrameDeadline] this returns so `runApp` happens. The open
///    is NOT abandoned — it keeps running, and a late `hydrate()` still
///    restores the uid through the normal provider graph.
///  - at [kBootStorageDeadline], if a [BootTask.blamesStorage] task is STILL
///    unanswered, the verdict is published as [StorageDurability.unavailable]
///    so `topos_screen`'s existing `_StorageWarningBanner` explains it and the
///    create-topo interlock stops writes into a store that may never land. No
///    parallel error UI is invented for this.
///  - if the open eventually completes after all, that pessimism is UNDONE
///    (unless a newer verdict arrived meanwhile, which always wins). A
///    timeout that permanently declared a merely-slow database dead would be
///    its own bug.
///
/// ATTRIBUTION IS PART OF THE BOUND. Each task is tracked on its own, so a
/// stall in a task that is not the local database gets a truthful log line and
/// NO storage verdict — see [BootTask] for the misdiagnosis this replaces.
Future<void> awaitBootWork(
  ProviderContainer container,
  List<BootTask> tasks, {
  Duration firstFrameDeadline = kBootFirstFrameDeadline,
  Duration storageDeadline = kBootStorageDeadline,
}) async {
  // Shared, mutated as each task settles, and read by the second stage — which
  // is how the stall report can name the tasks that are STILL outstanding at
  // `storageDeadline` rather than the ones that were outstanding at the first
  // frame.
  final pending = <BootTask>{...tasks};
  // Errors are absorbed PER TASK rather than left to `Future.wait`'s
  // all-or-nothing rejection: every individual boot future already degrades
  // internally (`_initSupabase`, `PhotoFiles.warmDocsPath` and
  // `LastKnownUid.hydrate` each catch their own failures), so anything that
  // still escapes is unforeseen — and an unforeseen throw out of `bootApp`
  // means `runApp` is never called, i.e. the same blank page the deadlines
  // below exist to prevent. Per-task also means one task's throw cannot mask
  // which OTHER tasks were still running, which the merged version did.
  final guarded = Future.wait(<Future<void>>[
    for (final task in tasks)
      task.future
          .then<void>(
            (_) {},
            onError: (Object error, StackTrace stackTrace) {
              debugPrint(
                'masi/boot: ${task.name} failed before the first frame: '
                '$error\n$stackTrace',
              );
            },
          )
          .whenComplete(() => pending.remove(task)),
  ]).then<void>((_) {});

  await guarded.timeout(firstFrameDeadline, onTimeout: () {});
  if (pending.isEmpty) return;

  debugPrint(
    'masi/boot: did not finish within ${firstFrameDeadline.inSeconds}s: '
    '${_taskNames(pending)} — showing the app anyway',
  );
  unawaited(
    _reportStalledStorageAtBoot(
      container,
      guarded,
      pending: pending,
      remaining: storageDeadline - firstFrameDeadline,
      total: storageDeadline,
    ),
  );
}

/// Second stage of [awaitBootWork]'s bound, split out so the two stages read
/// as the two separate decisions they are. Driven through [awaitBootWork]'s
/// injectable deadlines in `test/main_boot_timeout_test.dart`.
///
/// Runs entirely AFTER the first frame. Publishes
/// [StorageDurability.unavailable] if a [BootTask.blamesStorage] task is still
/// unanswered [remaining] later, then keeps waiting and reverts to the snapshot
/// it replaced if the database proves itself after all.
///
/// [pending] is live: [awaitBootWork] removes each task from it as that task
/// settles, so an empty set here means everything answered in the meantime.
Future<void> _reportStalledStorageAtBoot(
  ProviderContainer container,
  Future<void> work, {
  required Set<BootTask> pending,
  required Duration remaining,
  required Duration total,
}) async {
  await work.timeout(remaining, onTimeout: () {});
  final stalled = pending.toList();
  if (stalled.isEmpty) return;

  if (!stalled.any((task) => task.blamesStorage)) {
    // THE B1 FIX. A stalled `Supabase.initialize` on flaky mobile data used to
    // land here and be published as "the local database did not answer its
    // first query" — a message that is simply false, that disables topo
    // creation on a healthy database, and that sends the user to look at their
    // browser's storage settings. Nothing about local storage is known at this
    // point, so nothing about local storage is claimed: the offending
    // subsystems are named in the log, and each already reports its own failure
    // through its own provider (`cloudInitProvider` for the cloud, which bounds
    // itself at `kCloudInitTimeout`).
    debugPrint(
      'masi/boot: ${_taskNames(stalled)} did not finish within '
      '${total.inSeconds}s — none of these touches the local database, so the '
      'storage verdict is left exactly as the connection layer reported it',
    );
    return;
  }

  // Everything below runs tens of seconds after boot, so the container can in
  // principle be gone by then (a hot restart tears one down mid-flight).
  // `report()` is itself `ref.mounted`-guarded, but `container.read` on a
  // disposed container throws — and an unhandled async error out of a
  // fire-and-forget boot task is not worth any of this. Log and stop.
  try {
    // Snapshotted as late as possible: on web the connection layer's real
    // verdict has long since landed by now (`WasmDatabase.open` resolves
    // before the first query), and that is precisely the value worth
    // restoring.
    final replaced = container.read(storageDurabilityProvider);
    // `unavailableOver`, NOT `StorageDurability.unavailable`: the plain
    // constructor hard-zeroes `measuredBackend` and `missingFeatures`, so this
    // overlay used to DESTROY the connection layer's real report — the one
    // production measures as `opfsLocks / {dedicatedWorkersInSharedWorkers}`
    // seconds earlier, and the only field-diagnosable fact the app ever learns
    // about a browser's storage. A field report's banner came back with no
    // `· missing: …` segment for exactly that reason. The overlay carries the
    // measurement forward verbatim and stays null/empty when the probe had not
    // answered yet.
    final verdict = StorageDurability.unavailableOver(
      replaced,
      _stalledStorageReason(stalled, total),
    );
    container.read(storageDurabilityProvider.notifier).report(verdict);

    await work;
    // Only revert what is still ours. A verdict reported after the timeout is
    // fresher than the snapshot and must survive.
    if (container.read(storageDurabilityProvider) == verdict) {
      container.read(storageDurabilityProvider.notifier).report(replaced);
    }
  } catch (error, stackTrace) {
    debugPrint(
      'masi/boot: stalled-storage report abandoned: $error\n'
      '$stackTrace',
    );
  }
}

/// The [StorageDurability.unavailableReason] for a boot stall that DID include
/// the local database.
///
/// Leads with the database, because that is the news the banner is about and
/// the fact the create-topo interlock acts on. But when other boot work is
/// hanging too, that is said out loud rather than hidden: two subsystems wedged
/// at once usually means one common cause (a suspended tab, a killed worker),
/// and the field report that has to explain it should not have had half its
/// evidence rounded away. Only tasks the caller marked
/// [BootTask.blamesStorage] contribute to the leading claim.
String _stalledStorageReason(List<BootTask> stalled, Duration total) {
  final reason =
      'the local database did not answer its first query within '
      '${total.inSeconds}s';
  final others = stalled.where((task) => !task.blamesStorage);
  if (others.isEmpty) return reason;
  return '$reason (${_taskNames(others)} had not finished either)';
}

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
/// `StoragePersistenceController.requestPersistenceOnce()` (and
/// `requestPersistenceAgain()`, used below) is documented and tested never to
/// complete with an error.
///
/// Two re-ask paths were layered on top of the original one-shot boot
/// request (see its own placement comment above, in [bootApp]) — both fixing
/// the same defect: `persist()` used to be asked exactly once, at the one
/// instant (pre-first-frame, zero interaction) the browser's grant heuristics
/// have provably earned nothing, and installation is the single strongest
/// input to both engines' heuristics, yet was never consulted.
///
///  1. **Standalone-at-boot, moments later.** `pwaIsStandalone()` reads a
///     `window` global that `web/index.html`'s bootstrap script sets
///     synchronously, long before Dart's `main()` even starts (the Flutter
///     engine itself takes far longer to load/init) — so it is already
///     accurate at the instant `requestPersistenceOnce()` above fires, and
///     that first call already runs INSIDE whatever standalone context this
///     page load has. This second call therefore does NOT hand the browser
///     new information the first call lacked; it supplements rather than
///     replaces. It exists as cheap insurance for the case the very first,
///     pre-anything-else ask was denied: on the strongest known signal, ask
///     once more, a beat after boot's other work has run.
///     `requestPersistenceAgain()`'s own guard (skip once granted/persisted
///     or unsupported) is what keeps this from ever being a second real ask
///     once the first one already succeeded.
///  2. **`appinstalled`, whenever it fires.** This is a GENUINELY new signal
///     mid-session — the moment a user who started this session NOT
///     installed becomes installed — and today it is thrown away entirely
///     (`web/index.html`'s own handler only resets its deferred-prompt
///     bookkeeping). `listenForAppInstalled` wires a direct browser listener
///     (inert off the browser) that re-asks right when that signal appears.
void requestPersistentStorageAtBoot(ProviderContainer container) {
  final controller = container.read(storagePersistenceProvider.notifier);
  unawaited(
    controller.requestPersistenceOnce().then((_) {
      if (pwaIsStandalone()) {
        unawaited(controller.requestPersistenceAgain());
      }
    }),
  );
  listenForAppInstalled(() {
    unawaited(controller.requestPersistenceAgain());
  });
}

/// Defensive hardening: a failed/unreachable Supabase init (bad config, no
/// network on first launch, etc.) must never crash app boot — this app is
/// local-first (Drift/SQLite) and fully usable with sync/backup/auth
/// unavailable, so record the failure and continue rather than letting the
/// exception propagate out of [bootApp].
///
/// UF-6: this used to be a bare `try`/`catch` around `Supabase.initialize`
/// whose entire response to a failure was one `debugPrint`. Continuing was
/// right; forgetting was not. Every cloud provider then degraded to a
/// signed-out no-op that reports SUCCESS — `SyncService` answers
/// `skippedSignedOut`, `SyncOrchestrator` reads that as [SyncStatus.idle] —
/// so the app told the user it was synced while their topos existed on
/// exactly one device.
///
/// [CloudInitController.initialize] does the same call and the same
/// swallowing, but RECORDS the outcome on [cloudInitProvider], which is what
/// `SyncOrchestrator` reads to refuse to claim success, and what its retry
/// re-attempts. Boot's contract is unchanged: this never throws.
Future<void> _initSupabase(ProviderContainer container) =>
    container.read(cloudInitProvider.notifier).initialize();
