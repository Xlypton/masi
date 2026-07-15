import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/account/application/auth_providers.dart';
import '../features/account/data/auth_repository.dart';
import '../features/backup/application/sync_orchestrator.dart';
import '../features/library/application/library_providers.dart';
import 'claim_ownership_bootstrap.dart';
import 'router.dart';
import 'theme.dart';

class ClimbTopoApp extends ConsumerStatefulWidget {
  const ClimbTopoApp({super.key});

  @override
  ConsumerState<ClimbTopoApp> createState() => _ClimbTopoAppState();
}

class _ClimbTopoAppState extends ConsumerState<ClimbTopoApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Push immediately (skipping any pending debounce window) whenever the
    // app leaves the foreground — it may get killed before a debounced push
    // would otherwise have fired, silently losing whatever was written
    // since the last sync.
    if (state == AppLifecycleState.paused) {
      ref.read(syncOrchestratorProvider.notifier).onAppPaused();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Keep the opportunistic-sync orchestrator ACTIVELY watched for the
    // entire app run (not just constructed once via `ref.read`). This
    // matters for a non-obvious Riverpod reason spelled out in
    // `sync_orchestrator.dart`'s doc comment: `SyncOrchestrator`'s own
    // `ref.listen(authStateProvider, ...)` (its pull-on-sign-in wiring) only
    // keeps firing while `syncOrchestratorProvider` itself has at least one
    // active watcher/listener — a one-off `ref.read` builds it once but its
    // internal auth listener silently goes dead the moment nothing is left
    // watching it. This widget lives for the whole app run, so watching it
    // here keeps that listener alive permanently. (Its debounced-push
    // subscription to `tableUpdates()` is a plain Stream subscription and
    // would keep working either way — this is specifically about the
    // Riverpod-internal auth listener.)
    ref.watch(syncOrchestratorProvider);

    // Claim-on-sign-in bootstrap (P2): on the signed-out -> signed-in edge
    // of the live auth stream, attribute any locally-created, still-unowned
    // rows to the newly-signed-in uid exactly once. Edge-detection and the
    // "never throw" guard live in `handleAuthStateForClaimOwnership` (unit
    // tested on its own); this listener just wires it to the real
    // providers. Installed at the app root (rather than e.g. only on the
    // Account screen) so it fires regardless of which screen is on-screen
    // when sign-in completes (deep-linked magic-link return can land
    // anywhere the router currently is).
    ref.listen<AsyncValue<AuthSessionState>>(authStateProvider, (
      previous,
      next,
    ) {
      handleAuthStateForClaimOwnership(
        previous,
        next,
        (uid) => ref.read(libraryCrudRepositoryProvider).claimOwnership(uid),
      );
    });

    return MaterialApp.router(
      title: 'masi',
      debugShowCheckedModeBanner: false,
      theme: MasiTheme.light,
      darkTheme: MasiTheme.dark,
      themeMode: ThemeMode.system,
      routerConfig: appRouter,
      // Global tap-to-dismiss-keyboard: a translucent GestureDetector over
      // the whole routed app that unfocuses whatever text field currently
      // has focus whenever the user taps empty space. `translucent` (not
      // `opaque`) so the tap still reaches — and is still handled by — any
      // interactive widget underneath (buttons, text fields, etc.); Flutter's
      // gesture arena resolves the ambiguity in favor of the more specific
      // descendant recognizer when one is hit, so this only ever fires on
      // taps that land on non-interactive space.
      builder: (context, child) => GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
        child: child,
      ),
    );
  }
}
