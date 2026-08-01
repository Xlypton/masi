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
  await Future.wait([
    _initSupabase(),
    container.read(photoFilesProvider).warmDocsPath(),
    container.read(lastKnownUidProvider.notifier).hydrate(),
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
/// unavailable, so log and continue rather than letting the exception
/// propagate out of [bootApp].
Future<void> _initSupabase() async {
  try {
    await Supabase.initialize(
      url: supabaseUrl,
      publishableKey: supabaseAnonKey,
      authOptions: const FlutterAuthClientOptions(
        authFlowType: AuthFlowType.pkce,
      ),
    );
  } catch (e, st) {
    debugPrint('Supabase.initialize failed; continuing without it: $e\n$st');
  }
}
