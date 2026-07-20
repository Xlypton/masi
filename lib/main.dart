import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/app.dart';
import 'core/config/supabase_config.dart';
import 'core/db/database_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Path-based (rather than the default `#/`-hash) browser URLs, so shared
  // links like `/community/topo/<wallId>` are real, shareable paths instead
  // of `/#/community/topo/<wallId>`. `usePathUrlStrategy()` itself is a
  // no-op on native (see `flutter_web_plugins`' `url_strategy.dart`: it's
  // conditionally implemented per-platform, `dart.library.ui_web` selecting
  // the real browser-history version, everything else a no-op stub) — safe
  // to call unconditionally rather than gating on `kIsWeb`.
  usePathUrlStrategy();
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
  // loadOriginal/loadSlices) resolves stored relative `Photos.localPath`
  // values to absolute paths from the very first render, instead of a cold
  // cache silently passing the bare relative path through (unresolvable
  // against the process CWD) until some later, unrelated resolution
  // happens to warm it. Built off a manual ProviderContainer (rather than
  // ProviderScope + a FutureProvider) so this can be awaited here, before
  // runApp, guaranteeing the warm completes before any provider reads the
  // DB; the container is then handed to the app via
  // UncontrolledProviderScope so every provider still resolves against this
  // same container/cache.
  final container = ProviderContainer();
  await container.read(photoFilesProvider).warmDocsPath();
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const ClimbTopoApp(),
    ),
  );
}
