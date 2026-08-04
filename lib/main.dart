import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_web_plugins/url_strategy.dart';

import 'app/app.dart';
import 'core/config/supabase_init_provider.dart';
import 'core/db/database_provider.dart';
import 'core/db/storage_durability_provider.dart';
import 'core/storage/storage_persistence_providers.dart';
import 'features/account/application/auth_providers.dart';

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
  await awaitBootWork(
    container,
    Future.wait([
      _initSupabase(container),
      container.read(photoFilesProvider).warmDocsPath(),
      container.read(lastKnownUidProvider.notifier).hydrate(),
      verifyDatabaseUsable(container),
    ]),
  );
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

/// How long [bootApp] waits for that same work before publishing
/// [StorageDurability.unavailable].
///
/// Nothing legitimate takes this long; only drift's unbounded awaits do (see
/// [awaitBootWork]). Deliberately far beyond [kBootFirstFrameDeadline] so a
/// merely-slow migration is never mistaken for a dead database — and even
/// then the verdict is REVERSIBLE, see [awaitBootWork].
const Duration kBootStorageDeadline = Duration(seconds: 30);

/// Awaits [work] — [bootApp]'s pre-first-frame futures — but never lets it
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
///  - at [kBootStorageDeadline], if it is STILL unanswered, the verdict is
///    published as [StorageDurability.unavailable] so `topos_screen`'s
///    existing `_StorageWarningBanner` explains it and the create-topo
///    interlock stops writes into a store that may never land. No parallel
///    error UI is invented for this.
///  - if the open eventually completes after all, that pessimism is UNDONE
///    (unless a newer verdict arrived meanwhile, which always wins). A
///    timeout that permanently declared a merely-slow database dead would be
///    its own bug.
Future<void> awaitBootWork(
  ProviderContainer container,
  Future<void> work, {
  Duration firstFrameDeadline = kBootFirstFrameDeadline,
  Duration storageDeadline = kBootStorageDeadline,
}) async {
  var settled = false;
  // Errors are absorbed HERE rather than left to `Future.wait`'s
  // all-or-nothing rejection: every individual boot future already degrades
  // internally (`_initSupabase`, `PhotoFiles.warmDocsPath` and
  // `LastKnownUid.hydrate` each catch their own failures), so anything that
  // still escapes is unforeseen — and an unforeseen throw out of `bootApp`
  // means `runApp` is never called, i.e. the same blank page the deadlines
  // below exist to prevent.
  final guarded = work
      .then<void>(
        (_) {},
        onError: (Object error, StackTrace stackTrace) {
          debugPrint('masi/boot: pre-first-frame work failed: $error\n'
              '$stackTrace');
        },
      )
      .whenComplete(() => settled = true);

  await guarded.timeout(firstFrameDeadline, onTimeout: () {});
  if (settled) return;

  debugPrint(
    'masi/boot: pre-first-frame work did not finish within '
    '${firstFrameDeadline.inSeconds}s — showing the app anyway; the local '
    'database is still opening',
  );
  unawaited(
    _reportStalledStorageAtBoot(
      container,
      guarded,
      isSettled: () => settled,
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
/// [StorageDurability.unavailable] if [work] is still unanswered [remaining]
/// later, then keeps waiting and reverts to the snapshot it replaced if the
/// database proves itself after all.
Future<void> _reportStalledStorageAtBoot(
  ProviderContainer container,
  Future<void> work, {
  required bool Function() isSettled,
  required Duration remaining,
  required Duration total,
}) async {
  await work.timeout(remaining, onTimeout: () {});
  if (isSettled()) return;

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
    final stalled = StorageDurability.unavailable(
      'the local database did not answer its first query within '
      '${total.inSeconds}s',
    );
    container.read(storageDurabilityProvider.notifier).report(stalled);

    await work;
    // Only revert what is still ours. A verdict reported after the timeout is
    // fresher than the snapshot and must survive.
    if (container.read(storageDurabilityProvider) == stalled) {
      container.read(storageDurabilityProvider.notifier).report(replaced);
    }
  } catch (error, stackTrace) {
    debugPrint('masi/boot: stalled-storage report abandoned: $error\n'
        '$stackTrace');
  }
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
/// `StoragePersistenceController.requestPersistenceOnce()` is documented and
/// tested never to complete with an error.
void requestPersistentStorageAtBoot(ProviderContainer container) {
  unawaited(
    container
        .read(storagePersistenceProvider.notifier)
        .requestPersistenceOnce(),
  );
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
