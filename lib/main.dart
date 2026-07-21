import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/app.dart';
import 'core/config/supabase_config.dart';
import 'core/db/database_provider.dart';

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
  // Defensive hardening: a failed/unreachable Supabase init (bad config, no
  // network on first launch, etc.) must never crash app boot — this app is
  // local-first (Drift/SQLite) and fully usable with sync/backup/auth
  // unavailable, so log and continue rather than letting the exception
  // propagate out of main().
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
  await container.read(photoFilesProvider).warmDocsPath();
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const ClimbTopoApp(),
    ),
  );
}
